"""Build MIRE's practical construction kit (asset batch A-010).

Run with:
  Blender --background --python tools/blender/build_construction_set.py

Outputs 18 individual metre-scale GLBs covering 14 assets, an editable Blender
source, a JSON catalog, and four preview renders. Geometry is deterministic.

What this batch is for
----------------------
Everything here is a piece a player walks through, climbs, crosses or hides
behind: doors, gates, ladders, ramps, bridges, docks, palisades, barricades.
`systems/building/buildable_def.gd` already ships the placement rules and task
3.7 authors the real buildable set against them; this is the art that set needs,
plus the spans world-gen puts over the river.

The hero idea: these pieces are only correct in RELATION to each other
-------------------------------------------------------------------
An extraction ship is judged on its own. A bridge module is not — three of them
in a row either make one continuous bridge or they make a bridge with two seams
in it, and no amount of looking at one module tells you which. So this batch is
authored against a module contract, and the contract is what gets verified:

  MODULE     2.00 m   run pitch and standard piece width, matching
                      `content/buildables/wall.tres` (size.x = 2, snap_step = 1)
  WALL_H     3.00 m   that wall's height. Palisade, both gate frames, the door
                      frame and the ladder all reach exactly it
  DECK_Z     1.00 m   the walking surface of every bridge and dock piece
  RAMP_RISE  1.00 m   over a 2.00 m run: 26.3 degrees, and exactly one deck.
                      Three ramps stack to WALL_H

Every number in the kit is one of those four or a whole multiple, so a run of
pieces mates plane-to-plane instead of nearly. `check()` measures the real
geometry against them and fails the build; `tools/construction_check.gd` then
re-measures in the engine and assembles an actual three-module run, because the
Blender numbers prove the pieces and only the engine can prove the assembly.

The player is what makes the slope numbers non-negotiable.
`entities/player/player.tscn` sets `floor_max_angle` to 46 degrees and the
controller implements no step-up at all, so a vertical lip is a wall no matter
how low it is. That is why the ramp exists at 26.3 degrees, why its toe feathers
to 12 mm rather than starting with a step, and why the deck height is defined as
"one ramp" instead of being picked because it looked right.

Origin rules, by family
-----------------------
GROUND  the usual portable normalization: sits on z = 0, centred in x/y.
JOINT   corner pieces. Ground-level origin ON THE CORNER POST, not centred, so
        the two arms end exactly on the cell edges a straight piece butts to.
        The catalog records where a neighbour goes; nobody guesses an offset.
HINGE   door and gate leaves. Origin ON THE HINGE AXIS at ground level, so a
        scene swings the leaf with `rotate_y()` and nothing else. The catalog
        records `hinge_offset_m`, the leaf's placement inside its own frame,
        which is what makes "working wood door" a thing you can wire without a
        human finding the pivot by eye (D-039).

No bevel modifiers anywhere: `build_ward_set.py` found Blender's bevel changing
float bytes between otherwise identical background exports on Apple Silicon
(F-057), and this batch's contract includes a byte-identical rebuild.

Naming trap (docs/DELEGATION.md): never put a raw float in an object name.
Blender 5.2 reads text after the last "." as a numeric duplicate suffix and a
value like ".30600000000000005" aborts background Blender in libc++ with
"stoi: out of range". Every procedural name below uses an integer index.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from typing import Callable

import bpy
from mathutils import Vector

sys.path.append(str(Path(__file__).resolve().parent))
from mire_art import (  # noqa: E402
    assign, box, check_scale, cone, cylinder_between, eevee_engine, look_at, mat,
    mesh_object, move_to_collection, radial, reset_materials, tapered_between,
    world_bounds,
)
from godot_import_lock import import_cache_guard  # noqa: E402


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "construction"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

# ── The module contract ──────────────────────────────────────────────────────
#
# x is the run axis: walls, palisades, bridges and docks tile along it at MODULE
# pitch. y is across (thickness, deck width). z is up. Blender's z becomes
# Godot's y on export, and Blender's y becomes Godot's -z.

MODULE = 2.00        # run pitch and standard piece width
WALL_H = 3.00        # content/buildables/wall.tres size.y
DECK_Z = 1.00        # bridge and dock walking surface
DECK_W = 2.00        # deck width across the run
RAMP_RISE = 1.00     # one ramp climbs exactly one deck
RAMP_TOE = 0.012     # feathered toe: a wedge with no degenerate edge
PLANK_T = 0.055      # a sawn plank
# F-180: every HINGE leaf is normalized flush to its own hinge axis (x=0) and its own
# back-most extent (see create_asset()) — and the frame's opening was authored so that
# same axis sits exactly on the jamb/post's inner face, so leaf geometry that reaches
# either reference lands exactly on the frame's collision face, not just near it.
# construction_check.gd's swing sweep caught this both closed (0 degrees, the strap and
# leaf boards) and fully open (90 degrees, ledges/rails/braces whose back edge is the
# leaf's own z=0 reference). HINGE_CLEARANCE backs every leaf off by a real few
# millimetres so no vertex sits on the frame face by a coincidental float match.
HINGE_CLEARANCE = 0.008
HALF = MODULE * 0.5

#: Steepest walkable slope, from `entities/player/player.tscn`. The ramp is
#: checked against this, not against taste.
FLOOR_MAX_ANGLE_DEG = 46.0

GROUND = "ground"
JOINT = "joint"
HINGE = "hinge"

EXPECTED_NAMES = [
    "door_wood_frame",
    "door_wood_leaf",
    "gate_double_frame",
    "gate_double_leaf_left",
    "gate_double_leaf_right",
    "ladder",
    "ramp",
    "bridge_straight",
    "bridge_broken",
    "bridge_rope",
    "dock_straight",
    "dock_corner",
    "palisade_straight",
    "palisade_corner",
    "palisade_gate_frame",
    "palisade_gate_leaf",
    "barricade",
    "barricade_spike",
]

FAMILY: dict[str, str] = {
    "door_wood_frame": GROUND,
    "door_wood_leaf": HINGE,
    "gate_double_frame": GROUND,
    "gate_double_leaf_left": HINGE,
    "gate_double_leaf_right": HINGE,
    "ladder": GROUND,
    "ramp": GROUND,
    "bridge_straight": GROUND,
    "bridge_broken": GROUND,
    "bridge_rope": GROUND,
    "dock_straight": GROUND,
    "dock_corner": GROUND,
    "palisade_straight": GROUND,
    "palisade_corner": JOINT,
    "palisade_gate_frame": GROUND,
    "palisade_gate_leaf": HINGE,
    "barricade": GROUND,
    "barricade_spike": GROUND,
}

TRIANGLE_BUDGET = {GROUND: 1400, JOINT: 1400, HINGE: 700}
MAX_MATERIALS = {GROUND: 6, JOINT: 6, HINGE: 5}

#: Pieces that tile along the run axis, and the exact extent they must measure
#: for a run of them to meet plane to plane. This is the batch's whole point, so
#: it is a table rather than a comment.
RUN_SPAN: dict[str, float] = {
    "door_wood_frame": MODULE,
    "gate_double_frame": MODULE * 2.0,
    "bridge_straight": MODULE,
    "bridge_broken": MODULE,
    "dock_straight": MODULE,
    "dock_corner": MODULE,
    "palisade_straight": MODULE,
    "palisade_gate_frame": MODULE,
}

#: Pieces whose walking surface must land exactly on DECK_Z.
DECK_PIECES = ("bridge_straight", "bridge_broken", "dock_straight", "dock_corner", "ramp")

#: Doorway openings, as (centre_x, half_width, top_z). Checked by asserting no
#: part of the frame intrudes into the volume — a doorway you cannot walk
#: through is the one defect a door frame can actually have.
OPENINGS: dict[str, tuple[float, float, float]] = {
    "door_wood_frame": (0.0, 0.55, 2.15),
    "gate_double_frame": (0.0, 1.25, 2.60),
    "palisade_gate_frame": (0.0, 0.68, 2.55),
}

#: Where each leaf's hinge sits inside its frame, and which way it opens.
#: `swing` is +1 for a leaf whose geometry runs +x from the hinge.
HINGES: dict[str, dict] = {
    "door_wood_leaf": {"frame": "door_wood_frame", "offset": (-0.55, -0.02, 0.0), "swing": 1},
    "gate_double_leaf_left": {"frame": "gate_double_frame", "offset": (-1.25, -0.05, 0.0), "swing": 1},
    "gate_double_leaf_right": {"frame": "gate_double_frame", "offset": (1.25, -0.05, 0.0), "swing": -1},
    "palisade_gate_leaf": {"frame": "palisade_gate_frame", "offset": (-0.68, -0.04, 0.0), "swing": 1},
}

#: How far a leaf is documented to open, and how far the swing check sweeps it.
#: A square-edged plank leaf hung on the face of its jamb clears completely at
#: 90 degrees and starts to catch the jamb corner past it — the same reason real
#: doors get a stop or a bevelled edge. 90 leaves the opening fully clear, so
#: nothing in the game wants the extra 20.
SWING_DEG = 90


# ── Joinery ──────────────────────────────────────────────────────────────────
#
# Five primitives, because every piece in this kit is made of the same five
# things a person with a saw and a rope would use. Building them once means the
# door and the dock are made of recognisably the same carpentry, which is the
# difference between a kit and eighteen unrelated objects.


def quad_solid(
    name: str,
    top: list[Vector],
    bottom: list[Vector],
    material: bpy.types.Material,
) -> bpy.types.Object:
    """A solid through two explicit quads, wound outward.

    Exists because a rotated `box()` cannot land on an exact plane: its bounds
    are the box around the rotated box, so a sloped deck built that way always
    overhangs the module edge it was supposed to end on. Here the corners ARE
    the numbers, so the ramp's top really is at z = DECK_Z and its run really is
    MODULE.
    """
    vertices = [tuple(point) for point in list(top) + list(bottom)]
    faces = [
        (0, 1, 2, 3),          # top
        (7, 6, 5, 4),          # bottom
        (4, 5, 1, 0),          # side a
        (5, 6, 2, 1),          # side b
        (6, 7, 3, 2),          # side c
        (7, 4, 0, 3),          # side d
    ]
    return mesh_object(name, vertices, faces, material)


def plank(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    width: float,
    material: bpy.types.Material,
    thickness: float = PLANK_T,
) -> bpy.types.Object:
    """A sawn board from `start` to `end`, lying flat (thickness along z).

    Axis-aligned by construction, so the bounds it reports are the bounds it
    has — which is what the mating-plane contract is measured on.
    """
    first, second = Vector(start), Vector(end)
    centre = (first + second) * 0.5
    span = second - first
    if abs(span.x) >= abs(span.y):
        dimensions = (abs(span.x), width, thickness)
    else:
        dimensions = (width, abs(span.y), thickness)
    return box(name, tuple(centre), dimensions, material)


def upright(
    name: str,
    x: float,
    y: float,
    base: float,
    top: float,
    radius: float,
    material: bpy.types.Material,
    vertices: int = 7,
    taper: float = 0.94,
) -> bpy.types.Object:
    """A round post. Seven sides: a log, not a pipe."""
    return cylinder_between(
        name, (x, y, base), (x, y, top), radius, material, vertices, taper
    )


def sharpened(
    prefix: str,
    x: float,
    y: float,
    base: float,
    top: float,
    radius: float,
    body: bpy.types.Material,
    tip: bpy.types.Material,
    vertices: int = 7,
) -> None:
    """A palisade log: shaft, then a point in fresh cut end-grain.

    The tip material is what makes a palisade read as sharpened from across the
    map. It is one cone and it does the whole job.
    """
    shoulder = top - radius * 2.6
    upright(f"{prefix}_Shaft", x, y, base, shoulder, radius, body, vertices)
    tapered_between(
        f"{prefix}_Point", (x, y, shoulder), (x, y, top), radius * 0.98, radius * 0.16, tip, vertices
    )


def lashing(
    name: str,
    centre: tuple[float, float, float],
    radius: float,
    material: bpy.types.Material,
    axis: str = "z",
    height: float = 0.05,
) -> bpy.types.Object:
    """A rope wrap. A joint nobody tied reads as glue."""
    rotation = {"z": (0.0, 0.0, 0.0), "x": (0.0, math.pi * 0.5, 0.0), "y": (math.pi * 0.5, 0.0, 0.0)}[axis]
    return cone(name, radius, radius, height, centre, material, 8, rotation)


def strap(
    name: str,
    centre: tuple[float, float, float],
    dimensions: tuple[float, float, float],
    material: bpy.types.Material,
) -> bpy.types.Object:
    """Ironwork: a hinge strap, a bracket, a nail plate."""
    return box(name, centre, dimensions, material)


def deck_field(
    prefix: str,
    x_range: tuple[float, float],
    y_range: tuple[float, float],
    count: int,
    z: float,
    materials: tuple[bpy.types.Material, ...],
    along: str = "y",
    gap: float = 0.012,
) -> list[bpy.types.Object]:
    """A run of deck planks filling a rectangle exactly.

    `along` is the direction each plank RUNS, so `y` gives boards laid across a
    run — the way a boardwalk is planked, and the way a seam between two modules
    disappears. The field fills its rectangle to the millimetre: the outermost
    planks' outer edges are the rectangle's edges, so the module's mating plane
    is the deck itself.
    """
    x0, x1 = x_range
    y0, y1 = y_range
    made: list[bpy.types.Object] = []
    low, high = (x0, x1) if along == "y" else (y0, y1)
    pitch = (high - low) / count
    for index in range(count):
        start = low + index * pitch + (gap * 0.5 if index > 0 else 0.0)
        end = low + (index + 1) * pitch - (gap * 0.5 if index < count - 1 else 0.0)
        centre, width = (start + end) * 0.5, end - start
        material = materials[index % len(materials)]
        if along == "y":
            made.append(box(f"{prefix}_{index}", (centre, (y0 + y1) * 0.5, z - PLANK_T * 0.5),
                            (width, y1 - y0, PLANK_T), material))
        else:
            made.append(box(f"{prefix}_{index}", ((x0 + x1) * 0.5, centre, z - PLANK_T * 0.5),
                            (x1 - x0, width, PLANK_T), material))
    return made


def brace(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    width: float,
    thickness: float,
    material: bpy.types.Material,
) -> bpy.types.Object:
    """A diagonal member in the xz plane, from point to point.

    Rotation about +y takes +x toward -z, so the angle is the negated
    atan2 — getting that sign wrong mirrors every brace in the kit and is
    invisible in a front view, which is exactly the class of defect 2.1j is
    about.
    """
    first, second = Vector(start), Vector(end)
    span = second - first
    centre = (first + second) * 0.5
    return box(
        name, tuple(centre), (span.length, width, thickness), material,
        rotation=(0.0, -math.atan2(span.z, span.x), 0.0),
    )


# ── Doors and gates ──────────────────────────────────────────────────────────


def build_door_frame(mats: dict[str, bpy.types.Material]) -> None:
    """A doorway in one module of wall: jambs, header, threshold, infill.

    The opening is 1.10 x 2.15 m — a 1.80 m player walks through it without the
    camera clipping the header, which is the only dimension here that gameplay
    actually feels.
    """
    depth = 0.28
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        box(f"Jamb_{index}", (side * 0.68, 0.0, 1.075), (0.26, depth, 2.15), mats["timber"])
        # A narrow infill panel closes the module out to the mating plane.
        box(f"Infill_{index}", (side * 0.905, 0.0, 1.50), (0.19, depth * 0.86, 3.00), mats["plank"])
        strap(f"Jamb_Plate_{index}", (side * 0.68, -depth * 0.5, 0.16), (0.22, 0.02, 0.10), mats["iron_dark"])

    box("Header", (0.0, 0.0, 2.25), (1.62, depth, 0.20), mats["timber_light"])
    # Boarding above the door, then the top plate that defines z = WALL_H.
    for index in range(6):
        centre = -0.83 + index * 0.332
        box(f"Board_{index}", (centre, 0.0, 2.60), (0.312, depth * 0.86, 0.50),
            mats["plank"] if index % 2 == 0 else mats["plank_light"])
    box("Board_Batten", (0.0, -depth * 0.44, 2.60), (1.72, 0.05, 0.10), mats["timber"])
    box("Top_Plate", (0.0, 0.0, WALL_H - 0.075), (MODULE, depth, 0.15), mats["timber"])
    brace("Head_Brace_0", (-0.80, 0.0, 2.36), (-0.30, 0.0, 2.86), 0.07, 0.10, mats["timber"])
    brace("Head_Brace_1", (0.80, 0.0, 2.36), (0.30, 0.0, 2.86), 0.07, 0.10, mats["timber"])
    for index, z in enumerate((0.42, 1.10, 1.78)):
        strap(f"Hinge_Pintle_{index}", (-0.575, -0.02, z), (0.07, 0.09, 0.09), mats["iron"])


def build_door_leaf(mats: dict[str, bpy.types.Material]) -> None:
    """The swinging half. Origin on the hinge axis: `rotate_y()` is all a scene
    needs, and `hinge_offset_m` in the catalog says where to put it."""
    height, width = 2.08, 1.08
    base = 0.03
    boards = 5
    pitch = width / boards
    for index in range(boards):
        centre = pitch * (index + 0.5)
        box(f"Leaf_Board_{index}", (centre, 0.0, base + height * 0.5),
            (pitch - 0.008, 0.045, height),
            mats["plank"] if index % 2 == 0 else mats["plank_light"])
    for index, z in enumerate((0.34, 1.76)):
        box(f"Leaf_Ledge_{index}", (width * 0.5, 0.045, z), (width - 0.04, 0.045, 0.14), mats["timber"])
    brace("Leaf_Brace", (0.10, 0.045, 0.44), (0.96, 0.045, 1.66), 0.045, 0.12, mats["timber"])
    for index, z in enumerate((0.34, 1.76)):
        strap(f"Leaf_Strap_{index}", (0.31, -0.028, z), (0.62, 0.014, 0.075), mats["iron_dark"])
        strap(f"Leaf_Strap_Tip_{index}", (0.63, -0.028, z), (0.10, 0.014, 0.045), mats["iron_dark"])
        upright(f"Leaf_Knuckle_{index}", 0.03, -0.028, z - 0.055, z + 0.055, 0.03, mats["iron"], 6, 1.0)
    # Ring handle: six segments laid end to end around a circle. Six boxes at
    # six angles is an asterisk; six segments joining those angles is a ring,
    # and the all-sides sheet is what tells you which one you built.
    ring = [
        (0.90 + math.cos(index * math.tau / 6) * 0.075, 1.05 + math.sin(index * math.tau / 6) * 0.075)
        for index in range(7)
    ]
    for index in range(6):
        start, end = ring[index], ring[index + 1]
        brace(f"Handle_{index}", (start[0], -0.038, start[1]), (end[0], -0.038, end[1]),
              0.022, 0.024, mats["iron"])
    strap("Handle_Plate", (0.90, -0.03, 1.05), (0.09, 0.012, 0.09), mats["iron_dark"])


def build_gate_double_frame(mats: dict[str, bpy.types.Material]) -> None:
    """Two modules wide, a 2.50 m opening: the hole a cart, a boss or four
    players running abreast go through."""
    depth = 0.40
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        box(f"Post_{index}", (side * 1.42, 0.0, 1.30), (0.34, depth, 2.60), mats["bark"])
        box(f"Post_Cap_{index}", (side * 1.42, 0.0, 2.66), (0.40, depth * 1.05, 0.12), mats["timber"])
        # Palisade-style wing out to the mating plane at +-2.0 m.
        for wing in range(2):
            x = side * (1.675 + wing * 0.22)
            sharpened(f"Wing_{index}_{wing}", x, 0.0, 0.0, 2.62 + wing * 0.08, 0.105,
                      mats["bark_dark"], mats["cut"])
        brace(f"Post_Brace_{index}", (side * 1.56, depth * 0.32, 1.84),
              (side * 1.30, depth * 0.32, 2.56), 0.10, 0.13, mats["timber"])
        strap(f"Post_Band_{index}", (side * 1.42, 0.0, 1.60), (0.34, depth * 1.16, 0.06), mats["iron"])
    box("Lintel", (0.0, 0.0, 2.73), (MODULE * 2.0, 0.30, 0.26), mats["timber"])
    box("Lintel_Cap", (0.0, 0.0, WALL_H - 0.07), (MODULE * 2.0, 0.36, 0.14), mats["timber_light"])
    for index in range(5):
        x = -1.20 + index * 0.60
        strap(f"Lintel_Peg_{index}", (x, -0.17, 2.73), (0.05, 0.06, 0.05), mats["iron"])
    for index, z in enumerate((0.48, 1.32, 2.16)):
        strap(f"Gate_Pintle_L_{index}", (-1.275, -0.05, z), (0.08, 0.11, 0.10), mats["iron"])
        strap(f"Gate_Pintle_R_{index}", (1.275, -0.05, z), (0.08, 0.11, 0.10), mats["iron"])


def build_gate_leaf(mats: dict[str, bpy.types.Material], side: int) -> None:
    """One half of the double gate. `side` is +1 for the leaf whose boards run
    +x from its hinge and -1 for its opposite number.

    Built by parameter rather than by mirroring: a negative scale flips face
    winding, and a gate whose far leaf is invisible from outside is exactly the
    bug that only shows up after it is placed.
    """
    width, height, base = 1.22, 2.55, 0.03
    boards = 6
    pitch = width / boards
    tag = "L" if side > 0 else "R"
    for index in range(boards):
        centre = side * pitch * (index + 0.5)
        box(f"Gate_{tag}_Board_{index}", (centre, 0.0, base + height * 0.5),
            (pitch - 0.01, 0.055, height),
            mats["plank"] if index % 2 == 0 else mats["plank_light"])
    for index, z in enumerate((0.42, 1.30, 2.34)):
        box(f"Gate_{tag}_Rail_{index}", (side * width * 0.5, 0.055, z),
            (width - 0.03, 0.05, 0.16), mats["timber"])
    brace(f"Gate_{tag}_Brace_0", (side * 0.10, 0.055, 0.52), (side * 1.12, 0.055, 1.20), 0.05, 0.13, mats["timber"])
    brace(f"Gate_{tag}_Brace_1", (side * 0.10, 0.055, 1.42), (side * 1.12, 0.055, 2.24), 0.05, 0.13, mats["timber"])
    for index, z in enumerate((0.42, 1.30, 2.34)):
        strap(f"Gate_{tag}_Strap_{index}", (side * 0.34, -0.036, z), (0.68, 0.016, 0.085), mats["iron_dark"])
        upright(f"Gate_{tag}_Knuckle_{index}", side * 0.035, -0.036, z - 0.07, z + 0.07, 0.035, mats["iron"], 6, 1.0)
    strap(f"Gate_{tag}_Latch", (side * 1.14, -0.05, 1.30), (0.10, 0.05, 0.30), mats["iron"])


# ── Climbing ─────────────────────────────────────────────────────────────────


def build_ladder(mats: dict[str, bpy.types.Material]) -> None:
    """Exactly WALL_H tall, so it tops out level with a palisade or a wall.

    Nine rungs at 0.30 m and then 0.30 m of bare rail above the top one: the
    part you hold while you step off, and the reason the ladder is 3.00 m rather
    than 2.70 m of rungs.
    """
    half_width = 0.235
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        upright(f"Rail_{index}", side * half_width, 0.0, 0.0, WALL_H, 0.048, mats["bark"], 7, 0.90)
    for index in range(9):
        z = 0.30 + index * 0.30
        cylinder_between(
            f"Rung_{index}", (-half_width, 0.0, z), (half_width, 0.0, z), 0.029,
            mats["timber"], 6, 1.0,
        )
    for index, z in enumerate((0.30, 1.50, 2.70)):
        for side in (-1, 1):
            tag = index * 2 + (1 if side > 0 else 0)
            lashing(f"Rail_Lash_{tag}", (side * half_width, 0.0, z), 0.062, mats["rope"], "z", 0.075)
    # Feet cut on a slant so the ladder beds into the ground instead of
    # balancing on two circles.
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        box(f"Foot_{index}", (side * half_width, 0.0, 0.035), (0.11, 0.09, 0.07), mats["cut"])


def build_ramp(mats: dict[str, bpy.types.Material]) -> None:
    """One module of run, exactly one deck of rise: 26.3 degrees.

    The player controller has no step-up logic at all, so the toe feathers to
    12 mm instead of starting with a lip, and the head lands on DECK_Z to the
    millimetre so a dock or bridge butts straight onto it.
    """
    top = [
        Vector((-HALF, -1.0, RAMP_TOE)),
        Vector((HALF, -1.0, DECK_Z)),
        Vector((HALF, 1.0, DECK_Z)),
        Vector((-HALF, 1.0, RAMP_TOE)),
    ]
    bottom = [Vector((point.x, point.y, max(0.0, point.z - 0.14))) for point in top]
    quad_solid("Deck_Slope", top, bottom, mats["plank"])

    slope = math.atan2(DECK_Z - RAMP_TOE, MODULE)
    for index in range(5):
        fraction = 0.12 + index * 0.19
        x = -HALF + MODULE * fraction
        z = RAMP_TOE + (DECK_Z - RAMP_TOE) * fraction
        box(f"Cleat_{index}", (x, 0.0, z + 0.018), (0.075, 1.72, 0.035), mats["timber"],
            rotation=(0.0, -slope, 0.0))
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        kerb_top = [
            Vector((-HALF, side * 1.0, RAMP_TOE + 0.10)),
            Vector((HALF, side * 1.0, DECK_Z + 0.10)),
            Vector((HALF, side * 0.88, DECK_Z + 0.10)),
            Vector((-HALF, side * 0.88, RAMP_TOE + 0.10)),
        ]
        kerb_bottom = [Vector((p.x, p.y, p.z - 0.11)) for p in kerb_top]
        quad_solid(f"Kerb_{index}", kerb_top, kerb_bottom, mats["timber"])
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        brace(f"Stringer_{index}", (-HALF + 0.12, side * 0.62, 0.15),
              (HALF - 0.12, side * 0.62, DECK_Z - 0.20), 0.10, 0.14, mats["bark"])
    upright("Head_Post_0", HALF - 0.10, -0.92, 0.0, DECK_Z - 0.02, 0.075, mats["bark"], 6)
    upright("Head_Post_1", HALF - 0.10, 0.92, 0.0, DECK_Z - 0.02, 0.075, mats["bark"], 6)


# ── Spans and decks ──────────────────────────────────────────────────────────
#
# Every deck in this section is laid by `deck_field`, which fills its rectangle
# to the millimetre. That is what makes a run of modules one surface: the last
# plank of one piece and the first plank of the next share a plane, so there is
# no seam to trip on and no stripe of ground showing through.


def bridge_trestle(mats: dict[str, bpy.types.Material], x: float, prefix: str) -> None:
    """One pair of legs and the bearer they carry.

    The legs stand upright rather than splayed on purpose. A tilted post ends in
    a tilted cap, and that cap put its lowest vertex 8 mm under the ground —
    which the ground rule then corrected by lifting the whole module, quietly
    moving the deck off DECK_Z. The splay is worth less than the deck plane.
    """
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        upright(f"{prefix}_Leg_{index}", x, side * 0.86, 0.0, 0.88, 0.085, mats["bark"], 7, 0.92)
    box(f"{prefix}_Bearer", (x, 0.0, 0.905), (0.16, 1.90, 0.09), mats["timber"])
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        lashing(f"{prefix}_Lash_{index}", (x, side * 0.86, 0.84), 0.105, mats["rope"], "z", 0.055)


def bridge_rails(mats: dict[str, bpy.types.Material], x_range: tuple[float, float], broken: bool) -> None:
    x0, x1 = x_range
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        for post_index, x in enumerate((x0 + 0.10, (x0 + x1) * 0.5, x1 - 0.10)):
            top = DECK_Z + (0.62 if broken and post_index == 2 else 0.95)
            upright(f"Rail_Post_{index}_{post_index}", x, side * 0.90, DECK_Z - 0.06, top,
                    0.055, mats["timber"] if not broken else mats["dead"], 6)
        box(f"Top_Rail_{index}", ((x0 + x1) * 0.5, side * 0.90, DECK_Z + 0.91),
            (x1 - x0, 0.075, 0.08), mats["timber"] if not broken else mats["dead"])
        box(f"Mid_Rail_{index}", ((x0 + x1) * 0.5, side * 0.90, DECK_Z + 0.46),
            (x1 - x0, 0.055, 0.07), mats["timber"] if not broken else mats["dead"])


def build_bridge_straight(mats: dict[str, bpy.types.Material]) -> None:
    """One module of trestle bridge. Deck at DECK_Z, mating planes at +-1.0 m."""
    bridge_trestle(mats, -0.82, "Anchor")
    bridge_trestle(mats, 0.82, "Far")
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        box(f"Beam_{index}", (0.0, side * 0.72, 0.9725), (MODULE, 0.13, 0.055), mats["timber"])
        brace(f"Under_Brace_{index}", (-0.74, side * 0.80, 0.12), (0.74, side * 0.80, 0.82),
              0.07, 0.09, mats["bark"])
    deck_field("Deck", (-HALF, HALF), (-1.0, 1.0), 7, DECK_Z,
               (mats["plank"], mats["plank_light"]), "y")
    bridge_rails(mats, (-HALF, HALF), broken=False)


def build_bridge_broken(mats: dict[str, bpy.types.Material]) -> None:
    """The same module after the far half has gone into the water.

    Geometrically identical where it matters: the near trestle is built by the
    same call with the same numbers, so the two states cannot drift, and one
    beam survives the full module so the piece still mates into a run — and so a
    player can still shimmy across it, which is a better answer than a gap.
    """
    bridge_trestle(mats, -0.82, "Anchor")
    box("Beam_0", (0.0, -0.72, 0.9725), (MODULE, 0.13, 0.055), mats["timber"])
    box("Beam_1", (-0.44, 0.72, 0.9725), (1.12, 0.13, 0.055), mats["timber"])
    tapered_between("Beam_Splinter", (0.12, 0.72, 0.9725), (0.34, 0.74, 0.95),
                    0.06, 0.012, mats["cut"], 5)
    brace("Under_Brace_0", (-0.74, -0.80, 0.12), (0.74, -0.80, 0.82), 0.07, 0.09, mats["bark"])
    deck_field("Deck", (-HALF, -0.14), (-1.0, 1.0), 3, DECK_Z, (mats["plank"],), "y")
    # Three planks hanging off the break, each at its own angle. A break drawn
    # with one dangling plank reads as a shrug.
    for index, (x, y, tilt, length) in enumerate(
        ((-0.02, -0.46, 0.55, 0.62), (0.14, 0.34, 1.05, 0.48), (0.06, 0.72, 0.32, 0.40))
    ):
        box(f"Fallen_Plank_{index}", (x, y, DECK_Z - 0.16 - index * 0.06),
            (length, 0.20, PLANK_T), mats["dead"], rotation=(0.0, tilt, index * 0.4))
    upright("Fallen_Leg", 0.62, -0.88, 0.0, 0.74, 0.085, mats["dead"], 7)
    box("Fallen_Bearer", (0.74, 0.26, 0.23), (0.20, 1.30, 0.09), mats["dead"],
        rotation=(0.26, 0.0, 0.22))
    bridge_rails(mats, (-HALF, HALF), broken=True)
    for index, x in enumerate((0.36, 0.78)):
        box(f"Rail_Stub_{index}", (x, 0.90, DECK_Z + 0.30 + index * 0.08), (0.34, 0.06, 0.07),
            mats["dead"], rotation=(0.0, 0.9 + index * 0.5, 0.0))
    for index, (angle, radius) in enumerate(radial(4, 0.62, seed=31, jitter=0.5)):
        lashing(f"Moss_{index}", (math.cos(angle) * radius * 0.9, math.sin(angle) * radius,
                                  0.16 + index * 0.05), 0.10, mats["moss"], "z", 0.06)


def build_bridge_rope(mats: dict[str, bpy.types.Material]) -> None:
    """Two modules of slung span: what you use when the gap is deeper than a
    trestle. Ends land on DECK_Z so it joins the same deck network; the middle
    sags 0.34 m, which is what tells you at a glance that it will move."""
    span = MODULE * 2.0
    half_span = span * 0.5
    sag = 0.34
    width = 0.58

    def height(x: float) -> float:
        return DECK_Z - sag * (1.0 - (x / half_span) ** 2)

    for end in (-1, 1):
        index = 1 if end > 0 else 0
        box(f"Sill_{index}", (end * (half_span - 0.03), 0.0, DECK_Z - 0.05),
            (0.06, width * 2.0 + 0.24, 0.10), mats["timber"])
        for side in (-1, 1):
            tag = index * 2 + (1 if side > 0 else 0)
            sharpened(f"End_Post_{tag}", end * (half_span - 0.14), side * (width + 0.10),
                      0.0, DECK_Z + 1.02, 0.085, mats["bark"], mats["cut"])
            lashing(f"End_Lash_{tag}", (end * (half_span - 0.14), side * (width + 0.10),
                                           DECK_Z + 0.72), 0.105, mats["rope"], "z", 0.07)

    segments = 11
    for side in (-1, 1):
        base = 0 if side < 0 else segments
        for index in range(segments):
            x0 = -half_span + span * index / segments
            x1 = -half_span + span * (index + 1) / segments
            cylinder_between(
                f"Main_Rope_{base + index}", (x0, side * width, height(x0) - 0.05),
                (x1, side * width, height(x1) - 0.05), 0.028, mats["rope"], 5, 1.0,
            )
            cylinder_between(
                f"Hand_Rope_{base + index}", (x0, side * (width + 0.06), height(x0) + 0.82),
                (x1, side * (width + 0.06), height(x1) + 0.86), 0.024, mats["rope"], 5, 1.0,
            )
    for index in range(7):
        x = -half_span + span * (index + 1) / 8.0
        for side in (-1, 1):
            tag = index * 2 + (1 if side > 0 else 0)
            cylinder_between(
                f"Hanger_{tag}", (x, side * (width + 0.03), height(x)),
                (x, side * (width + 0.06), height(x) + 0.84), 0.014, mats["rope"], 4, 1.0,
            )
    treads = 13
    for index in range(treads):
        x = -half_span + span * (index + 0.5) / treads
        z = height(x)
        slope = math.atan2(height(x + 0.12) - height(x - 0.12), 0.24)
        box(f"Tread_{index}", (x, 0.0, z - 0.028), (span / treads - 0.03, width * 2.0, PLANK_T),
            mats["plank"] if index % 2 == 0 else mats["dead"], rotation=(0.0, -slope, 0.0))


def build_dock_straight(mats: dict[str, bpy.types.Material]) -> None:
    """One module of boardwalk on piles. The deck is the same DECK_Z as the
    bridges, so a dock run and a bridge run are one continuous surface."""
    for xi, x in enumerate((-0.78, 0.78)):
        for yi, y in enumerate((-0.78, 0.78)):
            tag = xi * 2 + yi
            upright(f"Pile_{tag}", x, y, 0.0, 0.90, 0.10, mats["bark"], 7, 0.96)
            lashing(f"Pile_Weed_{tag}", (x, y, 0.15), 0.122, mats["weed"], "z", 0.22)
        box(f"Bearer_{xi}", (x, 0.0, 0.9725 - 0.055), (0.16, 1.86, 0.10), mats["timber"])
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        brace(f"Pile_Brace_{index}", (-0.78, side * 0.78, 0.18), (0.78, side * 0.78, 0.70),
              0.07, 0.08, mats["bark"])
    deck_field("Deck", (-HALF, HALF), (-1.0, 1.0), 7, DECK_Z,
               (mats["plank"], mats["dead"], mats["plank_light"]), "y")
    box("Kerb", (0.0, -0.955, DECK_Z + 0.035), (MODULE, 0.09, 0.07), mats["timber"])
    upright("Bollard", 0.62, 0.84, DECK_Z - 0.06, DECK_Z + 0.46, 0.075, mats["bark"], 7, 0.90)
    lashing("Bollard_Rope", (0.62, 0.84, DECK_Z + 0.30), 0.095, mats["rope"], "z", 0.10)
    lashing("Bollard_Coil", (0.62, 0.84, DECK_Z + 0.08), 0.115, mats["rope"], "z", 0.08)


def build_dock_corner(mats: dict[str, bpy.types.Material]) -> None:
    """The module that turns a boardwalk 90 degrees, open on -x and +y.

    Its two closed edges carry the kerb and the mooring post, and a diagonal
    beam under the mitre line carries the boards where the two runs meet — so
    the turn reads from above and from underneath, not just in plan.
    """
    for xi, x in enumerate((-0.78, 0.78)):
        for yi, y in enumerate((-0.78, 0.78)):
            tag = xi * 2 + yi
            upright(f"Pile_{tag}", x, y, 0.0, 0.90, 0.10, mats["bark"], 7, 0.96)
            lashing(f"Pile_Weed_{tag}", (x, y, 0.15), 0.122, mats["weed"], "z", 0.22)
    for xi, x in enumerate((-0.78, 0.78)):
        box(f"Bearer_{xi}", (x, 0.0, 0.9175), (0.16, 1.86, 0.10), mats["timber"])
    box("Mitre_Beam", (0.0, 0.0, 0.9175), (2.34, 0.16, 0.10), mats["timber"],
        rotation=(0.0, 0.0, math.radians(-45.0)))
    brace("Pile_Brace_0", (-0.78, -0.78, 0.18), (0.78, -0.78, 0.70), 0.07, 0.08, mats["bark"])
    deck_field("Deck", (-HALF, HALF), (-1.0, 1.0), 7, DECK_Z,
               (mats["plank"], mats["dead"], mats["plank_light"]), "y")
    # The mitre itself: a trim board laid on the diagonal the two runs meet on.
    box("Mitre_Trim", (0.0, 0.0, DECK_Z + 0.012), (2.70, 0.10, 0.03), mats["timber_light"],
        rotation=(0.0, 0.0, math.radians(-45.0)))
    box("Kerb_X", (0.955, 0.0, DECK_Z + 0.035), (0.09, MODULE, 0.07), mats["timber"])
    box("Kerb_Y", (0.0, -0.955, DECK_Z + 0.035), (MODULE, 0.09, 0.07), mats["timber"])
    upright("Bollard", 0.80, -0.80, DECK_Z - 0.06, DECK_Z + 0.52, 0.085, mats["bark"], 7, 0.90)
    lashing("Bollard_Rope", (0.80, -0.80, DECK_Z + 0.34), 0.105, mats["rope"], "z", 0.11)
    lashing("Bollard_Coil", (0.80, -0.80, DECK_Z + 0.10), 0.135, mats["rope"], "z", 0.09)


# ── Fortification ────────────────────────────────────────────────────────────


def palisade_logs(mats: dict[str, bpy.types.Material], prefix: str, x0: float, x1: float,
                  count: int, y: float = 0.0, along: str = "x") -> None:
    """A run of sharpened logs spread evenly across a span.

    Heights come from a fixed table rather than a random draw: the tallest log
    is exactly WALL_H so the piece measures the module height it claims, and the
    rest step down so the top line is a fence, not a hedge trimmed with a level.
    """
    steps = (0.00, -0.07, -0.13, -0.04, -0.10, -0.02, -0.16, -0.06)
    pitch = (x1 - x0) / count
    for index in range(count):
        centre = x0 + pitch * (index + 0.5)
        top = WALL_H + steps[index % len(steps)]
        x, yy = (centre, y) if along == "x" else (y, centre)
        sharpened(f"{prefix}_{index}", x, yy, 0.0, top, 0.125, mats["bark_dark"], mats["cut"])


def build_palisade_straight(mats: dict[str, bpy.types.Material]) -> None:
    """One module of sharpened-log wall, WALL_H tall.

    The rails, not the logs, define the mating plane: they run the exact module
    so two pieces butt, while the logs sit on an even pitch that carries
    straight through the joint instead of doubling up at it.
    """
    palisade_logs(mats, "Log", -HALF, HALF, 7)
    for index, z in enumerate((1.10, 2.20)):
        box(f"Rail_{index}", (0.0, 0.155, z), (MODULE, 0.075, 0.11), mats["bark"])
    for index in range(4):
        x = -0.72 + index * 0.48
        z = 1.10 if index % 2 == 0 else 2.20
        lashing(f"Rail_Lash_{index}", (x, 0.155, z), 0.10, mats["rope"], "y", 0.055)
    brace("Prop_0", (-0.62, 0.34, 0.06), (-0.16, 0.34, 1.62), 0.08, 0.10, mats["bark"])
    brace("Prop_1", (0.62, 0.34, 0.06), (0.16, 0.34, 1.62), 0.08, 0.10, mats["bark"])


def build_palisade_corner(mats: dict[str, bpy.types.Material]) -> None:
    """The corner post plus one metre of wall on each arm.

    JOINT origin: the corner post's own axis, at ground level. Arm A ends
    exactly at x = -1.0 and arm B at y = +1.0, so a straight piece placed at
    (-2, 0, 0) — or rotated 90 degrees at (0, +2, 0) — butts to it with no gap
    and nothing for a human to nudge.
    """
    sharpened("Corner_Post", 0.0, 0.0, 0.0, WALL_H + 0.14, 0.17, mats["bark_dark"], mats["cut"])
    palisade_logs(mats, "Arm_A_Log", -1.0, -0.22, 3, y=0.0, along="x")
    palisade_logs(mats, "Arm_B_Log", 0.22, 1.0, 3, y=0.0, along="y")
    for index, z in enumerate((1.10, 2.20)):
        box(f"Arm_A_Rail_{index}", (-0.5, 0.155, z), (1.0, 0.075, 0.11), mats["bark"])
        box(f"Arm_B_Rail_{index}", (0.155, 0.5, z), (0.075, 1.0, 0.11), mats["bark"])
    for index, z in enumerate((1.10, 2.20)):
        lashing(f"Corner_Lash_{index}", (0.0, 0.0, z), 0.20, mats["rope"], "z", 0.08)
    brace("Corner_Prop", (0.30, 0.30, 0.08), (0.06, 0.06, 1.70), 0.09, 0.11, mats["bark"])


def build_palisade_gate_frame(mats: dict[str, bpy.types.Material]) -> None:
    """A gateway through the palisade: two heavy posts and a lintel, in the same
    module a straight section occupies."""
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        sharpened(f"Gate_Post_{index}", side * 0.84, 0.0, 0.0, WALL_H, 0.16,
                  mats["bark_dark"], mats["cut"])
        brace(f"Gate_Prop_{index}", (side * 0.74, 0.34, 0.08), (side * 0.90, 0.34, 1.80),
              0.09, 0.11, mats["bark"])
    box("Lintel", (0.0, 0.0, 2.66), (MODULE, 0.22, 0.22), mats["bark"])
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        lashing(f"Lintel_Lash_{index}", (side * 0.80, 0.0, 2.66), 0.19, mats["rope"], "z", 0.09)
    box("Head_Board", (0.0, 0.0, 2.86), (1.42, 0.10, 0.16), mats["timber"])
    for index, z in enumerate((0.44, 1.30, 2.16)):
        strap(f"Pintle_{index}", (-0.655, -0.04, z), (0.08, 0.10, 0.10), mats["iron"])


def build_palisade_gate_leaf(mats: dict[str, bpy.types.Material]) -> None:
    """The gate itself: barred, not boarded, so you can see what is on the other
    side before you open it. Hinge on the origin, like every leaf in this kit."""
    width, height, base = 1.32, 2.45, 0.05
    for index, z in enumerate((base + 0.14, base + 1.16, base + 2.24)):
        box(f"Gate_Rail_{index}", (width * 0.5, 0.0, z), (width, 0.10, 0.13), mats["bark"])
    bars = 6
    pitch = width / bars
    for index in range(bars):
        x = pitch * (index + 0.5)
        upright(f"Gate_Bar_{index}", x, 0.0, base, base + height, 0.048, mats["bark_dark"], 6, 0.94)
    brace("Gate_Brace", (0.10, 0.075, base + 0.24), (1.20, 0.075, base + 2.10), 0.06, 0.11, mats["timber"])
    for index, z in enumerate((base + 0.14, base + 1.16, base + 2.24)):
        strap(f"Gate_Strap_{index}", (0.32, -0.07, z), (0.64, 0.016, 0.08), mats["iron"])
        upright(f"Gate_Knuckle_{index}", 0.035, -0.07, z - 0.07, z + 0.07, 0.035, mats["iron"], 6, 1.0)
    for index in range(3):
        lashing(f"Gate_Lash_{index}", (0.22 + index * 0.44, 0.0, base + 1.16), 0.085,
                mats["rope"], "y", 0.05)
    strap("Gate_Latch", (1.24, -0.09, base + 1.16), (0.10, 0.06, 0.28), mats["iron"])


def build_barricade(mats: dict[str, bpy.types.Material]) -> None:
    """Chest-high, nailed together out of whatever was to hand. Two metres wide
    so a line of them lines up with everything else in the kit."""
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        brace(f"Leg_A_{index}", (side * 0.62, -0.30, 0.02), (side * 0.86, -0.30, 1.10),
              0.11, 0.09, mats["timber"])
        brace(f"Leg_B_{index}", (side * 0.86, 0.30, 0.02), (side * 0.62, 0.30, 1.10),
              0.11, 0.09, mats["timber"])
        box(f"Foot_{index}", (side * 0.74, 0.0, 0.045), (0.16, 0.78, 0.09), mats["dead"])
    for index, z in enumerate((0.40, 0.72, 1.02)):
        box(f"Board_{index}", (0.0, -0.30, z), (MODULE, 0.06, 0.22),
            mats["plank"] if index % 2 == 0 else mats["dead"])
    tapered_between("Board_Splinter", (0.84, -0.30, 0.72), (0.98, -0.34, 0.78), 0.075, 0.014,
                    mats["dead_cut"], 5)
    brace("Cross_Brace", (-0.80, 0.16, 0.16), (0.80, 0.16, 1.02), 0.06, 0.08, mats["dead"])
    for index, (x, y, z) in enumerate(
        ((-0.62, -0.34, 0.40), (0.62, -0.34, 0.40), (-0.62, -0.34, 0.72),
         (0.62, -0.34, 0.72), (-0.62, -0.34, 1.02), (0.62, -0.34, 1.02))
    ):
        strap(f"Nail_{index}", (x, y, z), (0.035, 0.02, 0.035), mats["iron_dark"])


def build_barricade_spike(mats: dict[str, bpy.types.Material]) -> None:
    """Cheval de frise: a spine on two crossed frames with six stakes fanned out
    of it. The stakes point out and down on both sides — a spike barricade with
    all its points facing the camera is the 2.1j defect in its purest form."""
    cylinder_between("Spine", (-1.0, 0.0, 0.86), (1.0, 0.0, 0.86), 0.095, mats["bark"], 7, 0.98)
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        for leg, y in enumerate((-0.62, 0.62)):
            tag = index * 2 + leg
            cylinder_between(
                f"Cross_{tag}", (side * 0.58, y, 0.0), (side * 0.58, -y * 0.36, 1.16),
                0.075, mats["bark_dark"], 6, 0.92,
            )
        lashing(f"Cross_Lash_{index}", (side * 0.58, 0.0, 0.86), 0.14, mats["rope"], "x", 0.08)
    for index, (angle, radius) in enumerate(radial(6, 0.90, seed=17, jitter=0.28, radius_jitter=0.10)):
        x = -0.78 + index * 0.312
        direction = Vector((math.cos(angle) * 0.22, math.sin(angle), math.cos(angle) * 0.5 - 0.18))
        if abs(direction.y) < 0.35:
            direction.y = 0.35 * (1.0 if index % 2 == 0 else -1.0)
        direction.normalize()
        start = Vector((x, direction.y * 0.06, 0.86))
        end = start + direction * radius
        end.z = max(0.30, min(1.34, end.z))
        tapered_between(f"Spike_{index}", tuple(start), tuple(end), 0.062, 0.014, mats["cut"], 6)
        lashing(f"Spike_Lash_{index}", tuple(start + direction * 0.10), 0.085, mats["rope"], "x", 0.05)


# ── Assembly, contract, catalog and previews ─────────────────────────────────


def set_visible(record: dict, visible: bool) -> None:
    record["root"].hide_render = not visible
    for child in record["root"].children_recursive:
        child.hide_render = not visible


def create_asset(name: str, build_fn: Callable[[], None], display_location: tuple[float, float, float]) -> dict:
    family = FAMILY[name]
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)
    before = set(bpy.data.objects)
    build_fn()
    made = [obj for obj in bpy.data.objects if obj not in before]

    # GROUND is the usual portable normalization. JOINT and HINGE are authored
    # in a frame that MEANS something — the corner post, the hinge axis — so
    # they are moved by exactly nothing, which is what lets a scene assemble
    # them from the catalog's numbers instead of by eye (D-039).
    offset = Vector((0.0, 0.0, 0.0))
    if family == GROUND:
        low, high = world_bounds(made)
        offset = Vector((-(low.x + high.x) * 0.5, -(low.y + high.y) * 0.5, -low.z))
        for obj in made:
            obj.location += offset
    elif family == HINGE:
        low, high = world_bounds(made)
        swing = HINGES[name]["swing"]
        offset = Vector((
            -low.x + HINGE_CLEARANCE if swing > 0 else -high.x - HINGE_CLEARANCE,
            -high.y - HINGE_CLEARANCE,
            0.0,
        ))
        for obj in made:
            obj.location += offset
    move_to_collection(made, collection)
    for obj in made:
        obj.parent = root

    low, high = world_bounds(made)
    dimensions = high - low
    meshes = [obj for obj in made if obj.type == "MESH"]
    polygons = sum(len(obj.data.polygons) for obj in meshes)
    triangles = sum(max(0, len(polygon.vertices) - 2) for obj in meshes for polygon in obj.data.polygons)
    materials = sorted({m.name for obj in meshes for m in obj.data.materials if m})

    def bounds_of(prefix: str) -> tuple[Vector, Vector] | None:
        parts = [obj for obj in meshes if obj.name.startswith(prefix)]
        return world_bounds(parts) if parts else None

    deck = bounds_of("Deck")
    anchor = bounds_of("Anchor")
    points: list[Vector] = []
    if family == HINGE:
        for obj in meshes:
            matrix = obj.matrix_world
            points.extend(matrix @ vertex.co for vertex in obj.data.vertices)

    bpy.ops.object.select_all(action="DESELECT")
    for obj in collection.objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = root
    bpy.ops.export_scene.gltf(
        filepath=str(EXPORT_DIR / f"{name}.glb"),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
    )
    arm_a = bounds_of("Arm_A_Rail")
    arm_b = bounds_of("Arm_B_Rail")
    mesh_boxes = [(obj.name, world_bounds([obj])) for obj in meshes]

    # Only now, with every measurement taken in the authored frame. Moving the
    # root first and measuring afterwards reads every asset at its display slot
    # instead of at its origin — which is silent, because the numbers still look
    # like numbers (F-094's lesson, one fence over).
    root.location = display_location
    return {
        "name": name,
        "family": family,
        "root": root,
        "width": dimensions.x,
        "depth": dimensions.y,
        "height": dimensions.z,
        "low": low,
        "high": high,
        "min_z": low.z,
        "centre_xy": ((low.x + high.x) * 0.5, (low.y + high.y) * 0.5),
        "offset": tuple(offset),
        "parts": len(meshes),
        "polygons": polygons,
        "triangles": triangles,
        "materials": materials,
        "deck_top": None if deck is None else deck[1].z,
        "anchor": None if anchor is None else tuple(round(v, 6) for v in (*anchor[0], *anchor[1])),
        "arm_a": None if arm_a is None else arm_a[0].x,
        "arm_b": None if arm_b is None else arm_b[1].y,
        "meshes": mesh_boxes,
        "points": points,
    }


def check(records: list[dict]) -> list[str]:
    """Everything a machine can judge about this batch, judged. Failing, not warning."""
    problems: list[str] = []
    by_name = {record["name"]: record for record in records}

    for record in records:
        name, family = record["name"], record["family"]
        dimensions = (record["width"], record["depth"], record["height"])
        complaint = check_scale(name, dimensions)
        if complaint:
            problems.append(complaint)
        if record["triangles"] > TRIANGLE_BUDGET[family]:
            problems.append(
                f"{name}: {record['triangles']} triangles over the {family} budget of {TRIANGLE_BUDGET[family]}"
            )
        if not record["materials"]:
            problems.append(f"{name}: no embedded materials")
        if len(record["materials"]) > MAX_MATERIALS[family]:
            problems.append(f"{name}: {len(record['materials'])} materials, {family} cap is {MAX_MATERIALS[family]}")
        if record["polygons"] == 0 or record["parts"] == 0:
            problems.append(f"{name}: exported no geometry")
        if min(dimensions) <= 0.0:
            problems.append(f"{name}: degenerate dimension {dimensions}")
        if not (EXPORT_DIR / f"{name}.glb").exists():
            problems.append(f"{name}: no GLB written")

        if family == GROUND:
            if abs(record["min_z"]) > 0.001:
                problems.append(f"{name}: sits {record['min_z'] * 1000:.1f} mm off the ground plane")
            if max(abs(value) for value in record["centre_xy"]) > 0.001:
                problems.append(f"{name}: not horizontally centred ({record['centre_xy']})")
        elif family == JOINT:
            if any(abs(value) > 1e-9 for value in record["offset"]):
                problems.append(f"{name}: authored-frame asset was moved by {record['offset']}")
            if record["min_z"] < -0.001:
                problems.append(f"{name}: {record['min_z'] * 1000:.1f} mm below the ground plane")
        else:
            # The hinge axis is the leaf's outer back corner: everything hangs
            # in front of it, so opening the door sweeps forward and nothing
            # crosses the jamb plane. F-180: literally flush (0 mm) turned out to mean
            # exactly ON the jamb's collision face rather than in front of it, so the
            # corner sits HINGE_CLEARANCE behind the axis on purpose now.
            if abs(record["high"].y + HINGE_CLEARANCE) > 0.001:
                problems.append(f"{name}: hangs {record['high'].y * 1000:.1f} mm behind its hinge axis")
            if record["min_z"] < -0.001:
                problems.append(f"{name}: {record['min_z'] * 1000:.1f} mm below the ground plane")

        # The module contract. This is what makes the kit a kit.
        if name in RUN_SPAN:
            span = RUN_SPAN[name]
            if abs(record["width"] - span) > 0.001:
                problems.append(
                    f"{name}: runs {record['width']:.4f} m, module wants {span:.2f} m — "
                    f"a run of these would show a {abs(record['width'] - span) * 1000:.1f} mm seam"
                )
        if name in DECK_PIECES:
            top = record["deck_top"]
            if top is None:
                problems.append(f"{name}: no Deck_* geometry, so its walking surface cannot be measured")
            elif abs(top - DECK_Z) > 0.001:
                problems.append(f"{name}: deck at {top:.4f} m, the kit's deck is {DECK_Z:.2f} m")

    # The ramp is the only piece the player's legs can veto.
    ramp = by_name.get("ramp")
    if ramp is not None:
        angle = math.degrees(math.atan2(DECK_Z - RAMP_TOE, MODULE))
        if angle > FLOOR_MAX_ANGLE_DEG:
            problems.append(f"ramp: {angle:.1f} degrees, steeper than the player's {FLOOR_MAX_ANGLE_DEG} floor limit")
        if ramp["min_z"] > 0.02:
            problems.append(f"ramp: toe starts {ramp['min_z'] * 1000:.0f} mm up, and there is no step-up in the controller")

    # Doorways have to be doorways.
    for name, (centre_x, half_width, top_z) in OPENINGS.items():
        record = by_name.get(name)
        if record is None:
            continue
        if half_width * 2.0 < 1.00 or top_z < 2.05:
            problems.append(f"{name}: opening {half_width * 2:.2f} x {top_z:.2f} m is too small for a 1.8 m player")
        corridor = half_width - 0.10
        for mesh_name, (low, high) in record["meshes"]:
            intrudes = (
                low.x < centre_x + corridor and high.x > centre_x - corridor
                and low.z < top_z - 0.01 and high.z > 0.08
            )
            if intrudes:
                problems.append(f"{name}: {mesh_name} stands in the doorway")

    # Leaves: hinged on the origin, fitting their opening, and actually able to
    # swing clear of the jamb they hang on.
    for name, spec in HINGES.items():
        leaf = by_name.get(name)
        frame = by_name.get(spec["frame"])
        if leaf is None or frame is None:
            continue
        swing = spec["swing"]
        hinge_edge = leaf["low"].x if swing > 0 else leaf["high"].x
        # F-180: HINGE_CLEARANCE holds the edge that many mm off its own origin on purpose.
        if abs(abs(hinge_edge) - HINGE_CLEARANCE) > 0.002:
            problems.append(f"{name}: hinge edge at x={hinge_edge:.4f}, not {HINGE_CLEARANCE:.3f} m off its own origin")
        centre_x, half_width, top_z = OPENINGS[spec["frame"]]
        leaf_width = leaf["width"]
        offset_x = spec["offset"][0]
        far_edge = offset_x + swing * leaf_width
        if abs(far_edge) > half_width + 0.001:
            problems.append(f"{name}: closed leaf reaches x={far_edge:.3f}, past the opening edge {half_width:.3f}")
        if leaf["high"].z + 0.0 > top_z:
            problems.append(f"{name}: {leaf['high'].z:.3f} m tall, opening is {top_z:.3f} m")
        # The swing itself: rotate the leaf about its hinge and make sure no
        # part of it ever occupies the jamb it hangs beside.
        offset_y = spec["offset"][1]
        slab = frame["depth"] * 0.5
        jamb_inner, jamb_outer = half_width, half_width + 0.34
        for step in range(0, SWING_DEG // 10 + 1):
            angle = math.radians(step * 10.0)
            cos_a, sin_a = math.cos(angle * swing), math.sin(angle * swing)
            for point in leaf["points"]:
                if math.hypot(point.x, point.y) < 0.10:
                    continue  # hinge hardware, turning on the hinge
                x = offset_x + point.x * cos_a - point.y * sin_a
                y = offset_y + point.x * sin_a + point.y * cos_a
                if abs(y) > slab:
                    continue
                if jamb_inner + 0.005 < abs(x) < jamb_outer and point.z < top_z:
                    problems.append(
                        f"{name}: at {step * 10} degrees it is inside the jamb at x={x:.3f}"
                    )
                    break
            else:
                continue
            break

    # The corner's arms have to end where a straight piece begins.
    corner = by_name.get("palisade_corner")
    if corner is not None:
        if corner["arm_a"] is None or abs(corner["arm_a"] + 1.0) > 0.001:
            problems.append(f"palisade_corner: arm A ends at x={corner['arm_a']}, not -1.000")
        if corner["arm_b"] is None or abs(corner["arm_b"] - 1.0) > 0.001:
            problems.append(f"palisade_corner: arm B ends at y={corner['arm_b']}, not +1.000")

    # State pair: intact and broken bridge share their near trestle exactly.
    anchors = {record["name"]: record["anchor"] for record in records if record["anchor"] is not None}
    if len(anchors) != 2:
        problems.append(f"expected two Anchor_* pieces for the bridge state pair, found {sorted(anchors)}")
    elif len(set(anchors.values())) != 1:
        problems.append(f"bridge states drift: {anchors}")
    return problems


def state_drift(records: list[dict]) -> float:
    anchors = [record["anchor"] for record in records if record["anchor"] is not None]
    if len(anchors) < 2:
        return -1.0
    return max(abs(a - b) for first in anchors for second in anchors for a, b in zip(first, second))


# ── Previews ─────────────────────────────────────────────────────────────────


def reference_figure(material: bpy.types.Material, location: tuple[float, float, float], tag: int) -> list:
    """A 1.79 m blocky person. A ruler cannot answer "can I climb that?"."""
    x, y, z = location
    return [
        box(f"Ref_{tag}_Legs", (x, y, z + 0.42), (0.36, 0.26, 0.84), material),
        box(f"Ref_{tag}_Torso", (x, y, z + 1.15), (0.48, 0.30, 0.64), material),
        box(f"Ref_{tag}_Head", (x, y, z + 1.63), (0.26, 0.26, 0.32), material),
        box(f"Ref_{tag}_Arm_0", (x - 0.31, y, z + 1.12), (0.14, 0.18, 0.62), material),
        box(f"Ref_{tag}_Arm_1", (x + 0.31, y, z + 1.12), (0.14, 0.18, 0.62), material),
    ]


def clone(record: dict, location: tuple[float, float, float], turn: float, collection) -> list:
    """A linked copy of one asset, placed. Previews assemble real runs this way,
    so what is rendered is the same geometry that shipped."""
    originals = [record["root"], *record["root"].children_recursive]
    mapping = {}
    for obj in originals:
        copy = obj.copy()
        if obj.data is not None:
            copy.data = obj.data
        copy.hide_render = False
        collection.objects.link(copy)
        mapping[obj] = copy
    for obj in originals:
        mapping[obj].parent = mapping.get(obj.parent)
    root = mapping[record["root"]]
    root.location = location
    root.rotation_euler = (0.0, 0.0, turn)
    return list(mapping.values())


def setup_render(mats: dict[str, bpy.types.Material]):
    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.mesh.primitive_plane_add(size=160, location=(0.0, 0.0, -0.02))
    floor = bpy.context.object
    floor.name = "Preview_Ground"
    assign(floor, mats["ground"])
    move_to_collection([floor], preview_collection)
    bpy.ops.object.light_add(type="SUN", location=(0.0, 0.0, 30.0))
    sun = bpy.context.object
    sun.name = "Preview_Sun"
    sun.rotation_euler = (math.radians(40), math.radians(-18), math.radians(-38))
    sun.data.energy = 2.8
    sun.data.angle = math.radians(16)
    move_to_collection([sun], preview_collection)
    bpy.ops.object.light_add(type="AREA", location=(-14.0, -18.0, 14.0))
    fill = bpy.context.object
    fill.name = "Preview_Fill"
    fill.data.energy = 22000
    fill.data.color = (0.44, 0.32, 0.62)
    fill.data.shape = "DISK"
    fill.data.size = 16.0
    look_at(fill, (0.0, 0.0, 1.6))
    move_to_collection([fill], preview_collection)
    bpy.ops.object.camera_add(location=(18.0, -20.0, 10.0))
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    camera.data.type = "ORTHO"
    bpy.context.scene.camera = camera
    move_to_collection([camera], preview_collection)
    scene = bpy.context.scene
    scene.render.engine = eevee_engine()
    scene.render.resolution_x = 1920
    scene.render.resolution_y = 1080
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.012, 0.016, 0.026)
    scene.view_settings.look = "AgX - Medium High Contrast"
    return scene, camera, preview_collection


def render_scene(scene, camera, filename: str, eye, target, ortho: float) -> None:
    camera.data.ortho_scale = ortho
    camera.location = eye
    look_at(camera, target)
    scene.render.filepath = str(PREVIEW_DIR / filename)
    bpy.ops.render.render(write_still=True)


def main() -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    for expected in EXPECTED_NAMES:
        (EXPORT_DIR / f"{expected}.glb").unlink(missing_ok=True)

    reset_materials()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)

    mats = {
        "bark_dark": mat("wood_bark_dark"),
        "bark": mat("wood_bark"),
        "timber": mat("wood_timber"),
        "timber_light": mat("wood_timber_light"),
        "plank": mat("wood_timber"),
        "plank_light": mat("wood_timber_light"),
        "cut": mat("wood_cut"),
        "dead": mat("wood_dead"),
        "dead_cut": mat("wood_dead_cut"),
        "iron": mat("iron"),
        "iron_dark": mat("iron_dark"),
        "rope": mat("rope"),
        "moss": mat("moss"),
        "weed": mat("moss_dark"),
        "ground": mat("preview_ground"),
        "scale": mat("reference_blue"),
    }

    builders: list[tuple[str, Callable[[], None]]] = [
        ("door_wood_frame", lambda: build_door_frame(mats)),
        ("door_wood_leaf", lambda: build_door_leaf(mats)),
        ("gate_double_frame", lambda: build_gate_double_frame(mats)),
        ("gate_double_leaf_left", lambda: build_gate_leaf(mats, 1)),
        ("gate_double_leaf_right", lambda: build_gate_leaf(mats, -1)),
        ("ladder", lambda: build_ladder(mats)),
        ("ramp", lambda: build_ramp(mats)),
        ("bridge_straight", lambda: build_bridge_straight(mats)),
        ("bridge_broken", lambda: build_bridge_broken(mats)),
        ("bridge_rope", lambda: build_bridge_rope(mats)),
        ("dock_straight", lambda: build_dock_straight(mats)),
        ("dock_corner", lambda: build_dock_corner(mats)),
        ("palisade_straight", lambda: build_palisade_straight(mats)),
        ("palisade_corner", lambda: build_palisade_corner(mats)),
        ("palisade_gate_frame", lambda: build_palisade_gate_frame(mats)),
        ("palisade_gate_leaf", lambda: build_palisade_gate_leaf(mats)),
        ("barricade", lambda: build_barricade(mats)),
        ("barricade_spike", lambda: build_barricade_spike(mats)),
    ]
    if [name for name, _ in builders] != EXPECTED_NAMES:
        raise RuntimeError("A-010 specification and expected export list diverged")

    records: list[dict] = []
    for index, (name, builder) in enumerate(builders):
        records.append(create_asset(name, builder, (index * 5.0, 0.0, 0.0)))

    problems = check(records)
    for problem in problems:
        print(f"CONTRACT FAIL  {problem}")
    if problems:
        raise RuntimeError(f"A-010 build contract failed with {len(problems)} problem(s)")

    catalog = []
    for record in records:
        entry = {
            "name": record["name"],
            "family": record["family"],
            "width_m": round(record["width"], 3),
            "depth_m": round(record["depth"], 3),
            "height_m": round(record["height"], 3),
            "origin": {GROUND: "ground_centred", JOINT: "corner_post", HINGE: "hinge_axis"}[record["family"]],
            "min_z_m": round(record["min_z"], 4),
            "mesh_parts": record["parts"],
            "polygons": record["polygons"],
            "triangles": record["triangles"],
            "materials": record["materials"],
        }
        if record["name"] in RUN_SPAN:
            entry["run_span_m"] = round(RUN_SPAN[record["name"]], 3)
            entry["mates_m"] = [[-RUN_SPAN[record["name"]], 0.0, 0.0], [RUN_SPAN[record["name"]], 0.0, 0.0]]
        if record["deck_top"] is not None:
            entry["deck_z_m"] = round(record["deck_top"], 4)
        if record["name"] in OPENINGS:
            centre_x, half_width, top_z = OPENINGS[record["name"]]
            entry["opening_m"] = {"centre_x": centre_x, "width": round(half_width * 2.0, 3), "height": top_z}
        if record["name"] in HINGES:
            spec = HINGES[record["name"]]
            entry["hinge"] = {
                "frame": spec["frame"],
                "hinge_offset_m": list(spec["offset"]),
                "opens_toward": "+x" if spec["swing"] > 0 else "-x",
                "swing_deg": SWING_DEG,
            }
        if record["name"] == "palisade_corner":
            entry["mates_m"] = [[-MODULE, 0.0, 0.0], [0.0, MODULE, 0.0]]
            entry["mates_note"] = "second entry is a straight piece turned 90 degrees about y"
        if record["name"] == "ramp":
            entry["slope_deg"] = round(math.degrees(math.atan2(DECK_Z - RAMP_TOE, MODULE)), 2)
        catalog.append(entry)
    with (ASSET_DIR / "catalog.json").open("w", encoding="utf-8") as handle:
        json.dump(catalog, handle, indent=2)
        handle.write("\n")

    scene, camera, preview_collection = setup_render(mats)
    by_name = {record["name"]: record for record in records}
    for record in records:
        set_visible(record, False)

    def stage(assignments: list[tuple[str, tuple[float, float, float], float]]) -> list:
        made = []
        for name, location, turn in assignments:
            made.extend(clone(by_name[name], location, turn, preview_collection))
        return made

    quarter = math.pi * 0.5

    def hung(leaf_name: str, position: tuple[float, float, float], turn: float,
             open_deg: float) -> list[tuple[str, tuple[float, float, float], float]]:
        """A frame at `position`/`turn` with its leaf hung and swung open."""
        spec = HINGES[leaf_name]
        ox, oy, _ = spec["offset"]
        cos_t, sin_t = math.cos(turn), math.sin(turn)
        leaf_at = (position[0] + ox * cos_t - oy * sin_t, position[1] + ox * sin_t + oy * cos_t, position[2])
        return [
            (spec["frame"], position, turn),
            (leaf_name, leaf_at, turn + math.radians(open_deg) * spec["swing"]),
        ]

    def hung_pair(left: str, right: str, position: tuple[float, float, float], turn: float,
                  open_deg: float) -> list[tuple[str, tuple[float, float, float], float]]:
        first = hung(left, position, turn, open_deg)
        return first + hung(right, position, turn, open_deg)[1:]
    # 1. The kit assembled from its own catalog numbers: a palisade run turning
    #    a corner into a gate, and a dock run turning onto a bridge and a ramp.
    staged = stage([
        ("palisade_straight", (-6.0, 4.0, 0.0), 0.0),
        ("palisade_straight", (-4.0, 4.0, 0.0), 0.0),
        *hung("palisade_gate_leaf", (-2.0, 4.0, 0.0), 0.0, 58.0),
        ("palisade_straight", (0.0, 4.0, 0.0), 0.0),
        ("palisade_corner", (1.0, 4.0, 0.0), 0.0),
        ("palisade_straight", (1.0, 6.0, 0.0), quarter),
        ("ladder", (-0.4, 3.6, 0.0), 0.0),
        ("barricade", (-3.6, 1.7, 0.0), math.radians(12.0)),
        ("barricade_spike", (-6.2, 1.5, 0.0), math.radians(-8.0)),
        ("dock_straight", (-5.0, -2.0, 0.0), 0.0),
        ("dock_straight", (-3.0, -2.0, 0.0), 0.0),
        ("dock_corner", (-1.0, -2.0, 0.0), 0.0),
        ("bridge_straight", (-1.0, 0.0, 0.0), quarter),
        ("bridge_broken", (3.4, -4.2, 0.0), quarter),
        ("ramp", (-7.0, -2.0, 0.0), math.pi),
        *hung("door_wood_leaf", (3.6, 2.0, 0.0), math.radians(-24.0), 62.0),
        *hung_pair("gate_double_leaf_left", "gate_double_leaf_right",
                   (5.4, -1.6, 0.0), math.radians(-8.0), 42.0),
        ("bridge_rope", (2.2, -5.4, 0.0), math.radians(90.0)),
    ])
    figures = reference_figure(mats["scale"], (-3.0, -2.0, DECK_Z), 1)
    figures += reference_figure(mats["scale"], (0.6, 2.6, 0.0), 2)
    move_to_collection(figures, preview_collection)
    render_scene(scene, camera, "construction_kit_preview.png",
                 eye=(16.0, -20.0, 12.0), target=(-0.6, 0.4, 1.4), ortho=22.0)
    for obj in staged + figures:
        bpy.data.objects.remove(obj, do_unlink=True)

    # 2. Every piece, in a line, at the same scale.
    staged = []
    for index, record in enumerate(records):
        staged.extend(clone(record, (index * 4.0 - 34.0, 0.0, 0.0), 0.0, preview_collection))
    figures = reference_figure(mats["scale"], (-36.8, 0.0, 0.0), 3)
    move_to_collection(figures, preview_collection)
    scene.render.resolution_x = 2560
    scene.render.resolution_y = 900
    render_scene(scene, camera, "construction_pieces_preview.png",
                 eye=(-1.0, -30.0, 9.0), target=(-1.0, 0.0, 1.5), ortho=80.0)
    for obj in staged + figures:
        bpy.data.objects.remove(obj, do_unlink=True)
    scene.render.resolution_x = 1920
    scene.render.resolution_y = 1080

    # 3. The door actually working: one frame, the leaf at four angles.
    staged = []
    for index, degrees in enumerate((0.0, 35.0, 70.0, float(SWING_DEG))):
        staged.extend(stage(hung("door_wood_leaf", (index * 3.0 - 4.5, 0.0, 0.0), 0.0, degrees)))
    figures = reference_figure(mats["scale"], (5.4, 0.6, 0.0), 4)
    move_to_collection(figures, preview_collection)
    render_scene(scene, camera, "construction_door_preview.png",
                 eye=(-2.0, -16.0, 6.4), target=(-0.4, 0.0, 1.5), ortho=15.0)
    for obj in staged + figures:
        bpy.data.objects.remove(obj, do_unlink=True)

    # 4. Scale, against the thing every one of these numbers is for.
    staged = stage([
        ("palisade_straight", (-3.0, 1.0, 0.0), 0.0),
        ("ladder", (-3.0, 0.6, 0.0), 0.0),
        ("ramp", (0.6, 0.0, 0.0), 0.0),
        ("dock_straight", (2.6, 0.0, 0.0), 0.0),
        ("dock_straight", (4.6, 0.0, 0.0), 0.0),
        ("barricade", (-0.9, -2.2, 0.0), 0.0),
    ])
    figures = reference_figure(mats["scale"], (-1.6, 0.9, 0.0), 5)
    figures += reference_figure(mats["scale"], (3.4, 0.0, DECK_Z), 6)
    move_to_collection(figures, preview_collection)
    render_scene(scene, camera, "construction_scale_preview.png",
                 eye=(9.0, -12.0, 5.6), target=(0.6, -0.2, 1.2), ortho=11.0)
    for obj in staged + figures:
        bpy.data.objects.remove(obj, do_unlink=True)

    for record in records:
        set_visible(record, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "construction_set.blend"))

    total = sum(record["triangles"] for record in records)
    print(f"Built {len(records)} A-010 construction exports ({total} triangles total)")
    print(f"State drift across the bridge pair: {state_drift(records) * 1000:.4f} mm")
    for record in records:
        print(
            f"  {record['name']:24s} {record['width']:5.2f} x {record['depth']:5.2f} x "
            f"{record['height']:5.2f} m  {record['triangles']:5d} tris  "
            f"{len(record['materials'])} mats  origin={record['family']}"
        )


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
