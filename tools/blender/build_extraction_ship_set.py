"""Build MIRE's extraction ship set (asset batch A-009).

Run with:
  Blender --background --python tools/blender/build_extraction_ship_set.py

Outputs 15 individual metre-scale GLBs, an editable Blender source, a JSON
catalog, and three preview renders. Geometry and layout are deterministic.

What this batch is for
----------------------
`docs/DESIGN.md` §5.2: the wreck is how a run **cashes out**. Every Cycle the
player decides between a guaranteed haul and one more gamble, and this ship is
the object that decision is made in front of. So it is built as one hero
landmark, 10.4 m long and 3.5 m tall on its cradle, rather than as a prop.

Two things here are different from every earlier batch, and both are deliberate.

**The hull is a surface, not an assembly.** ``STATIONS`` is a table of thirteen
cross-sections — half-beam, keel height, sheer height — and the shell is a quad
grid swept through them. A boat assembled out of boxes reads as boxes from every
angle that is not the one its author was looking at, which is the whole of the
2.1j finding. A swept surface has no favoured side because there is no side to
favour: the same table produces the bow, the bilge and the run.

**Eleven of the fifteen exports share one coordinate frame and are NOT
individually ground-centred.** The mast, both sails, the rudder, the ramp and the
hatch are authored in the hull's own coordinates and exported with the hull's
origin, so a gameplay scene assembles the whole ship by adding every part at
``Transform3D.IDENTITY``. Grounding each part on its own bounds — the usual
portable-asset normalization — would put the mast's origin at its heel and the
sail's at its foot, and leave a human to find seven offsets by eye. That is
precisely the hand-off D-039 forbids. The four standalone props (anchor,
donation crate, departure bell, debris cluster) are normalized the usual way,
because they are placed independently.

The consequence is that a ship-framed export legitimately "floats": the raised
sail's lowest vertex is 2.6 m up, because that is where a sail is. The build
contract below checks the right thing for each family — that nothing is below
z = 0 for a fitted part, and that the four hull states sit exactly on it.

State-set drift is zero by construction, not by correction. Nothing is
re-centred, so the four hull states cannot drift; ``check()`` proves it anyway by
measuring the shared cradle in all four and asserting the bounds are identical.

No bevel modifiers anywhere. `build_ward_set.py` found Blender's bevel changing
four float bytes between otherwise identical background exports on Apple
Silicon (F-057), and this batch's contract includes a byte-identical rebuild.

Naming trap (docs/DELEGATION.md): never put a raw float in an object or
datablock name. Blender 5.2 reads the text after the last "." as a numeric
duplicate suffix and a value like ".30600000000000005" aborts background Blender
in libc++ with "stoi: out of range". Every procedural name below uses an integer
index.
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
    assign, box, check_scale, cone, eevee_engine, hull as blob, ico, look_at,
    mat, mesh_object, move_to_collection, paint_faces, radial, reset_materials,
    tapered_between, world_bounds,
)


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "ships"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

EXPECTED_NAMES = [
    "ship_hull_wrecked",
    "ship_hull_repair_1",
    "ship_hull_repair_2",
    "ship_hull_repaired",
    "ship_mast",
    "ship_mast_broken",
    "ship_sail_furled",
    "ship_sail_raised",
    "ship_rudder",
    "ship_boarding_ramp",
    "ship_cargo_hatch",
    "ship_anchor",
    "ship_donation_crate",
    "ship_departure_bell",
    "ship_debris_cluster",
]

#: Families drive the build contract's budgets and which origin rule applies.
FITTED = "fitted"      # authored in the hull frame, exported with the hull origin
STRUCTURE = "hull"     # the four hull states, also in the hull frame
PROP = "prop"          # normalized the usual way: ground-centred, horizontally centred

FAMILY: dict[str, str] = {
    "ship_hull_wrecked": STRUCTURE,
    "ship_hull_repair_1": STRUCTURE,
    "ship_hull_repair_2": STRUCTURE,
    "ship_hull_repaired": STRUCTURE,
    "ship_mast": FITTED,
    "ship_mast_broken": FITTED,
    "ship_sail_furled": FITTED,
    "ship_sail_raised": FITTED,
    "ship_rudder": FITTED,
    "ship_boarding_ramp": FITTED,
    "ship_cargo_hatch": FITTED,
    "ship_anchor": PROP,
    "ship_donation_crate": PROP,
    "ship_departure_bell": PROP,
    "ship_debris_cluster": PROP,
}

TRIANGLE_BUDGET = {STRUCTURE: 3000, FITTED: 1100, PROP: 800}
MAX_MATERIALS = {STRUCTURE: 9, FITTED: 6, PROP: 6}


# ── The ship frame ───────────────────────────────────────────────────────────
#
# Everything below is in metres in the hull's own frame: x runs stern (-) to bow
# (+), y is athwartships, z = 0 is the ground the cradle stands on.

HULL_LENGTH = 10.40
HALF_LENGTH = HULL_LENGTH * 0.5
CRADLE_TOP = 0.26          # keel blocks lift the keel this far off the ground
DECK_Z = 1.78              # walking surface
MAST_X = 1.15              # mast step, forward of midships
GANGWAY_STATIONS = (5, 6)  # port bulwark panels left out for the boarding ramp

#: Thirteen cross-sections, stern to bow: (half_beam, keel_rise, sheer_z).
#: ``keel_rise`` is measured above CRADLE_TOP, so the flat of the keel — stations
#: 4 to 7 — is the only part touching the blocks, which is what a beached hull
#: does. The sheer is a real sheer curve: lowest just aft of midships, sweeping
#: up to the stem. A straight sheer is the single fastest way to make a boat look
#: like a bathtub.
STATIONS: tuple[tuple[float, float, float], ...] = (
    (0.62, 0.36, 2.89),
    (0.98, 0.16, 2.81),
    (1.26, 0.05, 2.74),
    (1.48, 0.01, 2.69),
    (1.62, 0.00, 2.65),
    (1.69, 0.00, 2.63),
    (1.70, 0.00, 2.63),
    (1.67, 0.01, 2.65),
    (1.56, 0.06, 2.70),
    (1.36, 0.18, 2.79),
    (1.06, 0.40, 2.95),
    (0.64, 0.78, 3.17),
    (0.13, 1.30, 3.51),
)

#: Strake boundaries as a fraction from keel (0) to sheer (1). The 0.786 line is
#: chosen so it lands exactly on DECK_Z amidships: the topmost strake is then the
#: bulwark, one continuous band from deck to rail, and the deck edge meets a
#: plank seam instead of cutting across one.
S_RINGS = (0.0, 0.30, 0.55, 0.786, 1.0)
DECK_RING = 3              # index into S_RINGS of the deck line
STATION_COUNT = len(STATIONS)


def station_x(index: int) -> float:
    return -HALF_LENGTH + HULL_LENGTH * index / (STATION_COUNT - 1)


def section_point(index: int, ring: int, side: int) -> Vector:
    """A point on the hull surface. ``side`` is -1 for port, +1 for starboard."""
    half_beam, keel_rise, sheer_z = STATIONS[index]
    keel_z = CRADLE_TOP + keel_rise
    s = S_RINGS[ring]
    # y rises fast and z slowly near the keel, which is what gives a working
    # boat its round bilge. Two exponents, no spline, no control points.
    return Vector((
        station_x(index),
        side * half_beam * (s ** 0.62),
        keel_z + (sheer_z - keel_z) * (s ** 1.85),
    ))


def deck_half_width(index: int) -> float:
    return STATIONS[index][0] * (S_RINGS[DECK_RING] ** 0.62)


def strake_outward(ring: int, side: int) -> Vector:
    """Outward normal of one strake, taken from the midship section curve.

    The section runs keel -> sheer; rotating its tangent by 90 degrees in the
    (y, z) plane gives the outward direction, which on the bottom strake points
    down and on the bulwark points sideways. A single hard-coded (0, side, 0)
    reference gets the bottom strake right only by the sign of a small
    component, which is not a thing to rely on.
    """
    low = section_point(STATION_COUNT // 2, ring, side)
    high = section_point(STATION_COUNT // 2, ring + 1, side)
    return Vector((0.0, side * (high.z - low.z), -abs(high.y - low.y)))


# ── Meshing helpers ──────────────────────────────────────────────────────────


#: Every sheet ``grid_mesh`` emits, with the outward direction it was asked for
#: and the area-weighted normal it actually produced. ``check()`` asserts the two
#: agree for all of them.
#:
#: This exists because the all-sides audit cannot judge these meshes. Its
#: inside-out test is the divergence theorem — sum (n . c) * area over the
#: object, positive when a CLOSED shell faces outward. Every sheet here is an
#: OPEN surface, so that sum is dominated by where the sheet sits relative to
#: the world origin rather than by which way it faces: a bottom-strake patch
#: with a correct downward normal and a positive z centre scores negative and
#: reads as a defect, while a genuinely inverted sheet sitting on the far side
#: of the origin scores positive and reads as fine. The generator is the only
#: place that knows the intended outward direction, so the check belongs here.
WINDING_LOG: list[tuple[str, Vector, Vector]] = []


def grid_mesh(
    name: str,
    grid: list[list[Vector]],
    material: bpy.types.Material,
    skip: frozenset[tuple[int, int]] = frozenset(),
    outward: Vector | None = None,
) -> bpy.types.Object | None:
    """Quads between consecutive rows/columns of ``grid``, as one flat-shaded mesh.

    Winding is decided once per grid by testing the first emitted quad against
    ``outward`` and flipping the whole sheet if it faces the wrong way. Godot
    imports glTF with back-face culling on, so a mis-wound quad is an invisible
    quad rather than a shading nit — and on a hull, "invisible from one side" is
    exactly the defect this batch exists not to ship.

    ``mesh_object``'s normal recalculation is deliberately not used: these grids
    are unwelded face soup, where ``normals_make_consistent`` reports nonsense
    (it claimed 46 of 128 faces inverted on a clean asset — see ASSET_TRACKER).
    """
    # Collected first, wound second. The winding used to be decided from the
    # FIRST quad emitted, and on the transom and the stem that quad is
    # degenerate: both sides meet on the centreline at the keel, so two of its
    # corners coincide, its cross product is the zero vector, and the dot test
    # that decides the sign is reading noise. Every hull state shipped a transom
    # that the all-sides audit flagged as inside out — which under Godot's
    # back-face culling is a hole in the stern, not a shading nit. Deciding from
    # the largest-area quad instead makes the reference well-conditioned by
    # definition, and a quad with two coincident corners is emitted as the
    # triangle it actually is rather than as a zero-area quad.
    quads: list[tuple[list[Vector], Vector]] = []
    for i in range(len(grid) - 1):
        for j in range(len(grid[i]) - 1):
            if (i, j) in skip:
                continue
            corners = [grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]]
            kept = [corners[0]]
            for corner in corners[1:]:
                if (corner - kept[-1]).length > 1e-7:
                    kept.append(corner)
            if len(kept) > 2 and (kept[0] - kept[-1]).length <= 1e-7:
                kept.pop()
            if len(kept) < 3:
                continue
            normal = (kept[1] - kept[0]).cross(kept[2] - kept[0])
            if len(kept) == 4:
                normal += (kept[2] - kept[0]).cross(kept[3] - kept[0])
            quads.append((kept, normal))
    if not quads:
        return None
    flip = False
    if outward is not None:
        reference = max(quads, key=lambda entry: entry[1].length)
        if reference[1].length < 1e-9:
            raise RuntimeError(f"{name}: every face is degenerate, so winding cannot be decided")
        flip = reference[1].dot(outward) < 0.0
    vertices: list[tuple[float, float, float]] = []
    faces: list[tuple[int, ...]] = []
    measured = Vector((0.0, 0.0, 0.0))
    for corners, normal in quads:
        if flip:
            corners = list(reversed(corners))
            normal = -normal
        measured += normal
        base = len(vertices)
        vertices.extend(tuple(corner) for corner in corners)
        faces.append(tuple(range(base, base + len(corners))))
    if outward is not None:
        WINDING_LOG.append((name, outward.normalized(), measured))
    return mesh_object(name, vertices, faces, material, recalculate=False)


def panel(
    name: str,
    grid: list[list[Vector]],
    material: bpy.types.Material,
    thickness: float,
    normal: Vector,
) -> list[bpy.types.Object]:
    """A closed thin shell from one grid: front, back, and a rim joining them.

    A sail or a sheet of canvas built as a single surface is invisible from
    behind under back-face culling, which on a sail means half the approaches to
    the ship show a bare mast. Two offset sheets plus a rim cost about 40% more
    triangles and are visible from everywhere.
    """
    offset = normal.normalized() * (thickness * 0.5)
    front = [[point + offset for point in row] for row in grid]
    back = [[point - offset for point in row] for row in grid]
    made: list[bpy.types.Object] = []
    for tag, sheet, facing in (("Front", front, normal), ("Back", back, -normal)):
        obj = grid_mesh(f"{name}_{tag}", sheet, material, outward=facing)
        if obj is not None:
            made.append(obj)
    rows, columns = len(grid), len(grid[0])
    rims = [
        [[front[0][j], back[0][j]] for j in range(columns)],
        [[back[rows - 1][j], front[rows - 1][j]] for j in range(columns)],
        [[back[i][0], front[i][0]] for i in range(rows)],
        [[front[i][columns - 1], back[i][columns - 1]] for i in range(rows)],
    ]
    centre = sum((point for row in grid for point in row), Vector()) / (rows * columns)
    for index, rim in enumerate(rims):
        seam = grid_mesh(f"{name}_Rim_{index + 1}", rim, material,
                         outward=(Vector(rim[0][0]) + Vector(rim[-1][-1])) * 0.5 - centre)
        if seam is not None:
            made.append(seam)
    return made


def plank(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    width: float,
    thickness: float,
    material: bpy.types.Material,
) -> bpy.types.Object:
    """A board between two points, laid flat. Hand-rotated boxes get roll wrong."""
    first, second = Vector(start), Vector(end)
    direction = second - first
    obj = box(name, tuple((first + second) * 0.5), (direction.length, width, thickness), material)
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = direction.to_track_quat("X", "Z")
    return obj


def ribbon(
    name: str,
    grid: list[list[Vector]],
    material: bpy.types.Material,
    thickness: float,
    skip: frozenset[tuple[int, int]] = frozenset(),
) -> list[bpy.types.Object]:
    """A flat sheet given thickness in z: top, underside and both long edges.

    Separate from ``panel`` because a rail has to be able to skip spans — the
    gangway the boarding ramp lands in is a missing length of rail, not a
    separate model — and because its thickness is along z rather than along a
    surface normal.
    """
    lift = Vector((0.0, 0.0, thickness * 0.5))
    top = [[point + lift for point in row] for row in grid]
    bottom = [[point - lift for point in row] for row in grid]
    columns = len(grid[0])
    # The long edges' outward directions are MEASURED, not assumed. They used to
    # be hard-coded as -y and +y, which is right only for a ribbon that runs
    # along x on the starboard side. The boarding ramp runs along y, so both of
    # its edge sheets came out facing inward — invisible from outside the ramp —
    # and the port cap rail had the same defect mirrored. Taking the direction
    # from the grid's own columns makes it correct for any orientation.
    middle = len(grid) // 2
    outward_low = grid[middle][0] - grid[middle][1]
    outward_high = grid[middle][columns - 1] - grid[middle][columns - 2]
    outward_low.z = outward_high.z = 0.0
    sheets = [
        (f"{name}_Top", top, Vector((0.0, 0.0, 1.0))),
        (f"{name}_Under", bottom, Vector((0.0, 0.0, -1.0))),
        (f"{name}_Edge_1", [[bottom[i][0], top[i][0]] for i in range(len(grid))], outward_low),
        (f"{name}_Edge_2", [[top[i][columns - 1], bottom[i][columns - 1]] for i in range(len(grid))], outward_high),
    ]
    made: list[bpy.types.Object] = []
    for sheet_name, sheet, outward in sheets:
        obj = grid_mesh(sheet_name, sheet, material, skip=skip, outward=outward)
        if obj is not None:
            made.append(obj)
    return made


# ── The hull, and the four states of its repair ──────────────────────────────
#
# One builder, four stages. The states cannot drift apart because they are not
# four models: they are the same calls with a different hole set, a different
# strake palette and a different deck coverage. The shape that carries the
# repair story is the strake colour — weathered grey deadwood becomes worked
# timber, one band at a time — because colour reads at fog distance and a
# missing plank does not.

#: Quads left out of the shell, keyed by side (-1 port, +1 starboard) as
#: (station, strake). Spread deliberately around the whole hull: both sides,
#: bow and stern, bilge and bulwark, including two in the bottom strake that are
#: only visible from underneath or through the deck. The 2.1j defect was detail
#: clustered where its author was looking; a damage set is the easiest place in
#: the whole kit to reintroduce it.
WRECK_HOLES: dict[int, frozenset[tuple[int, int]]] = {
    -1: frozenset({(1, 3), (2, 3), (3, 2), (4, 0), (7, 1), (8, 1), (8, 2), (10, 3)}),
    +1: frozenset({(2, 2), (3, 3), (5, 0), (5, 1), (6, 2), (9, 2), (9, 3), (10, 3)}),
}

#: Which of them each stage has closed. Anything closed gets a fresh-timber
#: patch over the opening, so progress is visible as new wood rather than as
#: absence — an absence is only legible next to the state that had it.
PATCHED: dict[str, dict[int, frozenset[tuple[int, int]]]] = {
    "wrecked": {-1: frozenset(), +1: frozenset()},
    "repair_1": {
        -1: frozenset({(1, 3), (3, 2), (4, 0)}),
        +1: frozenset({(2, 2), (5, 0), (5, 1)}),
    },
    "repair_2": {
        -1: frozenset({(1, 3), (2, 3), (3, 2), (4, 0), (7, 1)}),
        +1: frozenset({(2, 2), (3, 3), (5, 0), (5, 1), (6, 2), (10, 3)}),
    },
    "repaired": WRECK_HOLES,
}

#: Strake tokens keel-outward, one entry per stage. Read the four rows top to
#: bottom and the repair is legible as a colour ramp before a single hole is.
STAGE_STRAKES: dict[str, tuple[str, ...]] = {
    "wrecked": ("wood_dead", "wood_dead_cut", "wood_dead", "wood_dead_cut"),
    "repair_1": ("wood_dead", "wood_dead_cut", "wood_timber", "wood_dead_cut"),
    "repair_2": ("wood_dead", "wood_timber", "wood_timber_light", "wood_timber"),
    "repaired": ("wood_timber", "wood_timber_light", "wood_timber", "wood_timber_light"),
}

STAGE_DECK: dict[str, int] = {"wrecked": 4, "repair_1": 7, "repair_2": 11, "repaired": 11}
STAGE_MOSS: dict[str, float] = {"wrecked": 0.42, "repair_1": 0.26, "repair_2": 0.10, "repaired": 0.0}


def cradle(mats: dict[str, bpy.types.Material]) -> None:
    """Keel blocks and shore timbers. Identical geometry in all four states.

    It is also the answer to a question the art would otherwise raise: a beached
    hull with a rounded bottom cannot stand up. Shored on a slip, it can, and
    "under repair" is exactly what this object is for.
    """
    for index, x in enumerate((-3.30, -1.10, 1.10, 3.30)):
        box(f"Cradle_Block_{index + 1}", (x, 0.0, CRADLE_TOP * 0.5),
            (1.10, 0.86, CRADLE_TOP), mats["cradle"])
    for index, (station, side) in enumerate(((3, -1), (3, 1), (7, -1), (7, 1), (10, -1), (10, 1))):
        head = section_point(station, 1, side)
        # The foot sits on top of its pad, not on the ground. A shore this
        # shallow meets the ground at a steep angle to its own axis, and a
        # cone's end cap is a disc perpendicular to that axis — put the foot at
        # z = 0 and 103 mm of the disc ends up under the ground plane. The build
        # contract caught it; nothing in a preview would have.
        foot = Vector((head.x + 0.18 * (1 if side > 0 else -1), side * (abs(head.y) + 1.05), 0.15))
        tapered_between(f"Cradle_Shore_{index + 1}", tuple(foot), tuple(head),
                        0.115, 0.085, mats["cradle"], 6)
        box(f"Cradle_Pad_{index + 1}", (foot.x, foot.y, 0.075), (0.46, 0.46, 0.15), mats["cradle"])


def keel_and_frames(mats: dict[str, bpy.types.Material], holes: dict[int, frozenset]) -> None:
    """Keelson, floor timbers and the ribs a hole actually exposes.

    Ribs are drawn only at stations a hole opens onto. Framing the whole hull
    would be ~1,400 triangles of structure sealed inside planking where no
    camera can ever reach it, which is the same mistake as modelling a chest's
    contents inside a solid block (A-005).
    """
    box("Keel_Keelson", (0.20, 0.0, CRADLE_TOP + 0.30), (8.60, 0.30, 0.20), mats["frame"])
    for index, station in enumerate((2, 4, 6, 8, 10)):
        width = STATIONS[station][0] * 1.20
        box(f"Keel_Floor_{index + 1}", (station_x(station), 0.0, CRADLE_TOP + 0.16),
            (0.24, width, 0.18), mats["frame"])
    exposed: set[tuple[int, int]] = set()
    for side, quads in holes.items():
        for station, _ in quads:
            exposed.add((station, side))
            exposed.add((station + 1, side))
    for index, (station, side) in enumerate(sorted(exposed)):
        if not 0 < station < STATION_COUNT - 1:
            continue
        for ring in range(len(S_RINGS) - 1):
            inset = strake_outward(ring, side).normalized() * 0.125
            lower = section_point(station, ring, side) - inset
            upper = section_point(station, ring + 1, side) - inset
            lower.x = upper.x = station_x(station)
            tapered_between(f"Frame_{index + 1}_Rib_{ring + 1}", tuple(lower), tuple(upper),
                            0.062, 0.052, mats["frame"], 5)


def hull_shell(
    mats: dict[str, bpy.types.Material],
    strakes: tuple[str, ...],
    holes: dict[int, frozenset],
    patched: dict[int, frozenset],
    gangway: bool,
) -> list[bpy.types.Object]:
    """The planked shell: one quad sheet per strake, both sides, plus repairs."""
    made: list[bpy.types.Object] = []
    for ring in range(len(S_RINGS) - 1):
        for side in (-1, 1):
            missing = set(holes.get(side, frozenset()))
            if gangway and side < 0 and ring == len(S_RINGS) - 2:
                missing.update((station, ring) for station in GANGWAY_STATIONS)
            grid = [
                [section_point(index, ring, side), section_point(index, ring + 1, side)]
                for index in range(STATION_COUNT)
            ]
            skip = frozenset((station, 0) for station, hole_ring in missing if hole_ring == ring)
            tag = "Port" if side < 0 else "Star"
            sheet = grid_mesh(f"Hull_Strake_{ring + 1}_{tag}", grid, mats[strakes[ring]],
                              skip=skip, outward=strake_outward(ring, side))
            if sheet is not None:
                made.append(sheet)
    for side in (-1, 1):
        for count, (station, ring) in enumerate(sorted(patched.get(side, frozenset()))):
            made.extend(hull_patch(mats, station, ring, side, count))
    return made


def hull_patch(
    mats: dict[str, bpy.types.Material], station: int, ring: int, side: int, index: int
) -> list[bpy.types.Object]:
    """Two fresh boards nailed over one opening, proud of the shell."""
    corners = [
        [section_point(station, ring, side), section_point(station, ring + 1, side)],
        [section_point(station + 1, ring, side), section_point(station + 1, ring + 1, side)],
    ]
    normal = (corners[1][0] - corners[0][0]).cross(corners[0][1] - corners[0][0]).normalized()
    if normal.y * side < 0.0:
        normal = -normal
    made: list[bpy.types.Object] = []
    tag = "Port" if side < 0 else "Star"
    for half in range(2):
        low, high = half * 0.5, half * 0.5 + 0.5
        grid = [
            [
                corners[i][0].lerp(corners[i][1], low) + normal * 0.035,
                corners[i][0].lerp(corners[i][1], high) + normal * 0.035,
            ]
            for i in range(2)
        ]
        made.extend(panel(f"Hull_Patch_{tag}_{index + 1}_{half + 1}", grid,
                          mats["fresh"], 0.055, normal))
    return made


def hull_deck(mats: dict[str, bpy.types.Material], last_station: int, aged: bool) -> None:
    """Fore-and-aft planking, laid from the stern forward as repairs progress."""
    token = "deck_old" if aged else "deck_new"
    strips = 5
    for strip in range(strips):
        low = -1.0 + 2.0 * strip / strips
        high = -1.0 + 2.0 * (strip + 1) / strips
        grid = [
            [
                Vector((station_x(index), deck_half_width(index) * low, DECK_Z)),
                Vector((station_x(index), deck_half_width(index) * high, DECK_Z)),
            ]
            for index in range(1, last_station + 1)
        ]
        material = mats[token if strip % 2 == 0 else ("deck_old_alt" if aged else "deck_new_alt")]
        grid_mesh(f"Deck_Strip_{strip + 1}", grid, material, outward=Vector((0.0, 0.0, 1.0)))
    for index, station in enumerate(range(last_station + 1, STATION_COUNT - 1)):
        width = deck_half_width(station) * 2.0
        box(f"Deck_Beam_{index + 1}", (station_x(station), 0.0, DECK_Z - 0.09),
            (0.20, width, 0.16), mats["frame"])


def hull_transom(mats: dict[str, bpy.types.Material], token: str) -> None:
    """The flat stern panel, and the name board the run is remembered by."""
    grid = [
        [section_point(0, ring, side) for ring in range(len(S_RINGS))]
        for side in (-1, 1)
    ]
    grid_mesh("Transom_Panel", grid, mats[token], outward=Vector((-1.0, 0.0, 0.0)))
    box("Transom_Board", (-5.24, 0.0, 2.32), (0.10, 0.84, 0.26), mats["fresh"])
    for index, y in enumerate((-0.30, 0.0, 0.30)):
        box(f"Transom_Stud_{index + 1}", (-5.29, y, 2.32), (0.05, 0.07, 0.07), mats["brass"])


def hull_stem(mats: dict[str, bpy.types.Material], token: str, ornament: bool) -> None:
    """Bow: the two sides close on a stem post, and the repaired ship earns a head."""
    grid = [
        [section_point(STATION_COUNT - 1, ring, side) for ring in range(len(S_RINGS))]
        for side in (-1, 1)
    ]
    grid_mesh("Stem_Panel", grid, mats[token], outward=Vector((1.0, 0.0, 0.0)))
    tapered_between("Stem_Post", (5.14, 0.0, CRADLE_TOP + 1.24), (5.26, 0.0, 3.62),
                    0.16, 0.11, mats[token], 6)
    if not ornament:
        return
    # Tone check, DESIGN.md §6: the game is silly and does not do lore. A carved
    # fish is the right amount of ceremony for a boat somebody just fixed.
    # Built, not blobbed. The first cut of this was a `hull()` with lumps, and a
    # displaced sphere is a lump — at real size it read as a rock somebody had
    # stuck on the bow. A fish is a tapered body, a forked tail and an eye, and
    # those are three shapes low-poly states plainly.
    cone("Stem_Fish_Body", 0.19, 0.055, 0.56, (5.31, 0.0, 3.48), mats["fresh"], 6,
         (0.0, math.radians(90), 0.0))
    for index, sign in enumerate((-1, 1)):
        box(f"Stem_Fish_Tail_{index + 1}", (4.95, 0.0, 3.48 + sign * 0.15),
            (0.30, 0.055, 0.26), mats["fresh"], (0.0, math.radians(sign * 30), 0.0))
    cone("Stem_Fish_Fin", 0.16, 0.02, 0.22, (5.24, 0.0, 3.66), mats["fresh"], 3,
         (0.0, math.radians(24), 0.0))
    for index, sign in enumerate((-1, 1)):
        cone(f"Stem_Fish_Pec_{index + 1}", 0.11, 0.02, 0.18, (5.22, sign * 0.12, 3.40),
             mats["fresh"], 3, (math.radians(sign * 64), 0.0, 0.0))
    for index, y in enumerate((-0.13, 0.13)):
        ico(f"Stem_Fish_Eye_{index + 1}", (5.43, y, 3.53), (0.055, 0.055, 0.055), mats["brass"])


def hull_rail(mats: dict[str, bpy.types.Material], sides: tuple[int, ...], gangway: bool) -> None:
    """Cap rail along the sheer. Its absence is what makes a wreck look unfinished."""
    for side in sides:
        skip = frozenset(
            (station, 0) for station in GANGWAY_STATIONS
        ) if (gangway and side < 0) else frozenset()
        grid = [
            [
                section_point(index, len(S_RINGS) - 1, side) + Vector((0.0, -side * 0.075, 0.055)),
                section_point(index, len(S_RINGS) - 1, side) + Vector((0.0, side * 0.085, 0.055)),
            ]
            for index in range(STATION_COUNT)
        ]
        ribbon(f"Rail_{'Port' if side < 0 else 'Star'}", grid, mats["rail"], 0.075, skip)
    if not gangway:
        return
    # Framed, so it reads as a doorway rather than as one more missing plank. On
    # a hull whose entire visual language is "a gap means damage", an unframed
    # 1.7 m hole in the finished ship's bulwark reads as unrepaired.
    for index, station in enumerate((GANGWAY_STATIONS[0], GANGWAY_STATIONS[-1] + 1)):
        head = section_point(station, len(S_RINGS) - 1, -1)
        foot = section_point(station, DECK_RING, -1)
        tapered_between(f"Gangway_Post_{index + 1}", (foot.x, foot.y * 0.94, DECK_Z),
                        (head.x, head.y * 0.97, head.z + 0.10), 0.085, 0.070, mats["rail"], 6)
        box(f"Gangway_Cap_{index + 1}", (head.x, head.y * 0.97, head.z + 0.16),
            (0.20, 0.20, 0.10), mats["brass"])
    threshold = [
        [section_point(station, DECK_RING, -1) + Vector((0.0, 0.11, 0.02)),
         section_point(station, DECK_RING, -1) + Vector((0.0, -0.09, 0.02))]
        for station in range(GANGWAY_STATIONS[0], GANGWAY_STATIONS[-1] + 2)
    ]
    ribbon("Gangway_Threshold", threshold, mats["fresh"], 0.07)


def hull_fittings(mats: dict[str, bpy.types.Material], stage: str) -> None:
    """Mast step, partner, bitts, cleats and a coil — the deck's own detail.

    Spread around the deck rather than gathered where a preview camera looks:
    the bitts are aft, the cleats are on both rails at different stations, the
    coil is forward. `radial()` is not usable on a deck (it is not round), so the
    spread is written out and stated here so a later hand cannot quietly cluster
    it.
    """
    box("Fit_Mast_Step", (MAST_X, 0.0, CRADLE_TOP + 0.48), (0.52, 0.52, 0.16), mats["frame"])
    if stage in ("repair_2", "repaired"):
        box("Fit_Mast_Partner", (MAST_X, 0.0, DECK_Z + 0.07), (0.66, 0.66, 0.14), mats["rail"])
        for index, x in enumerate((-3.45, -3.05)):
            cone(f"Fit_Bitt_{index + 1}", 0.10, 0.088, 0.62, (x, 0.0, DECK_Z + 0.31), mats["rail"], 6)
        box("Fit_Bitt_Cross", (-3.25, 0.0, DECK_Z + 0.54), (0.72, 0.16, 0.13), mats["rail"])
    if stage != "repaired":
        return
    for index, (station, side) in enumerate(((3, 1), (4, -1), (8, 1), (9, -1))):
        point = section_point(station, len(S_RINGS) - 1, side)
        box(f"Fit_Cleat_{index + 1}", (point.x, point.y * 0.88, point.z + 0.12),
            (0.30, 0.10, 0.09), mats["brass"])
    for index, radius in enumerate((0.34, 0.26, 0.18)):
        cone(f"Fit_Coil_{index + 1}", radius, radius - 0.055, 0.075,
             (3.15, -0.55, DECK_Z + 0.04 + index * 0.07), mats["rope"], 10)
    box("Fit_Lantern_Post", (-4.55, 0.62, DECK_Z + 0.34), (0.09, 0.09, 0.68), mats["rail"])
    box("Fit_Lantern", (-4.55, 0.62, DECK_Z + 0.78), (0.20, 0.20, 0.24), mats["brass"])
    ico("Fit_Lantern_Flame", (-4.55, 0.62, DECK_Z + 0.78), (0.075, 0.075, 0.10), mats["flame"])


def build_hull(mats: dict[str, bpy.types.Material], stage: str) -> None:
    holes = {side: WRECK_HOLES[side] - PATCHED[stage][side] for side in (-1, 1)}
    repaired = stage == "repaired"
    cradle(mats)
    keel_and_frames(mats, holes)
    sheets = hull_shell(mats, STAGE_STRAKES[stage], holes, PATCHED[stage],
                        gangway=stage in ("repair_2", "repaired"))
    hull_deck(mats, STAGE_DECK[stage], aged=stage in ("wrecked", "repair_1"))
    hull_transom(mats, STAGE_STRAKES[stage][-1])
    hull_stem(mats, STAGE_STRAKES[stage][-1], ornament=repaired)
    if stage == "repair_2":
        hull_rail(mats, (-1,), gangway=True)
    elif repaired:
        hull_rail(mats, (-1, 1), gangway=True)
    hull_fittings(mats, stage)
    # Rot reads as colour, and colour costs nothing: moss on the up-facing
    # surfaces of the lower strakes, thinning out as the hull is worked on.
    # paint_faces() rather than a moss ellipsoid stuck to one flank — the same
    # sticker defect the massing primitives were added to kill.
    coverage = STAGE_MOSS[stage]
    if coverage <= 0.0:
        return
    for index, sheet in enumerate(sheets):
        if "Strake_1" not in sheet.name and "Strake_2" not in sheet.name:
            continue
        paint_faces(sheet, mats["moss"], min_normal_z=-1.0, min_height=0.0,
                    coverage=coverage, seed=17 + index)


# ── Rig, fittings and the parts that share the hull's frame ──────────────────

MAST_HEEL_Z = CRADLE_TOP + 0.40
MAST_HEAD_Z = 8.05
BOOM_Z = 3.16
GOOSENECK = Vector((MAST_X - 0.12, 0.0, BOOM_Z))
BOOM_END = Vector((MAST_X - 4.44, 0.0, 3.26))


def shroud(name: str, top: Vector, station: int, side: int, mats: dict) -> None:
    anchor = section_point(station, len(S_RINGS) - 1, side)
    tapered_between(name, tuple(top), (anchor.x, anchor.y * 0.94, anchor.z + 0.05),
                    0.034, 0.026, mats["rope"], 4)


def build_mast(mats: dict[str, bpy.types.Material]) -> None:
    tapered_between("Mast_Spar", (MAST_X, 0.0, MAST_HEEL_Z), (MAST_X, 0.0, MAST_HEAD_Z),
                    0.165, 0.082, mats["rail"], 8)
    box("Mast_Collar", (MAST_X, 0.0, DECK_Z + 0.12), (0.44, 0.44, 0.18), mats["iron"])
    box("Mast_Crosstree", (MAST_X, 0.0, 5.62), (0.22, 1.62, 0.11), mats["rail"])
    for index, y in enumerate((-0.74, 0.74)):
        box(f"Mast_Crosstree_Tip_{index + 1}", (MAST_X, y, 5.68), (0.16, 0.16, 0.10), mats["brass"])
    box("Mast_Cap", (MAST_X, 0.0, MAST_HEAD_Z + 0.06), (0.26, 0.26, 0.12), mats["brass"])
    cone("Mast_Truck", 0.075, 0.03, 0.20, (MAST_X, 0.0, MAST_HEAD_Z + 0.20), mats["brass"], 6)
    for index, (station, side) in enumerate(((4, -1), (4, 1), (8, -1), (8, 1))):
        shroud(f"Mast_Shroud_{index + 1}", Vector((MAST_X, 0.0, 5.48)), station, side, mats)
    tapered_between("Mast_Forestay", (MAST_X, 0.0, 7.72), (5.20, 0.0, 3.46), 0.032, 0.026, mats["rope"], 4)
    tapered_between("Mast_Backstay", (MAST_X, 0.0, 7.72), (-5.14, 0.0, 2.94), 0.032, 0.026, mats["rope"], 4)
    box("Mast_Gooseneck", tuple(GOOSENECK), (0.24, 0.20, 0.20), mats["iron"])


def build_mast_broken(mats: dict[str, bpy.types.Material]) -> None:
    """Snapped at 3.4 m, with the top length down across the port rail.

    The fallen section is the point of the model: a stump alone reads as a post
    somebody installed. It lands over the side rather than neatly along the
    deck, because wreckage that lines up with the hull looks placed.
    """
    tapered_between("Mast_Spar", (MAST_X, 0.0, MAST_HEEL_Z), (MAST_X, 0.0, 4.30),
                    0.165, 0.120, mats["rail"], 8)
    box("Mast_Collar", (MAST_X, 0.0, DECK_Z + 0.12), (0.44, 0.44, 0.18), mats["iron"])
    for index, (angle, radius) in enumerate(radial(5, 0.085, seed=31, jitter=0.4)):
        tip = Vector((MAST_X + math.cos(angle) * radius, math.sin(angle) * radius, 4.30))
        tapered_between(f"Mast_Splinter_{index + 1}", (MAST_X, 0.0, 4.12),
                        (tip.x, tip.y, 4.30 + 0.14 + 0.10 * (index % 3)),
                        0.045, 0.012, mats["wood_dead_cut"], 4)
    # Two legs, because one straight spar from the break to the ground passes
    # clean through the port side. It crosses the rail at station 5, where the
    # cap tops out at 2.72, and only then falls away outboard.
    fallen_head = Vector((MAST_X - 0.06, -0.30, 4.06))
    fallen_rest = Vector((-0.90, -1.74, 2.88))
    fallen_tip = Vector((-3.34, -3.52, 0.26))
    tapered_between("Mast_Fallen", tuple(fallen_head), tuple(fallen_rest), 0.122, 0.100, mats["rail"], 8)
    tapered_between("Mast_Fallen_Tip", tuple(fallen_rest), tuple(fallen_tip), 0.100, 0.070, mats["rail"], 8)
    for index, (angle, radius) in enumerate(radial(4, 0.11, seed=53, jitter=0.5)):
        tapered_between(f"Mast_Fallen_Splinter_{index + 1}", tuple(fallen_head),
                        (fallen_head.x + 0.26, fallen_head.y + math.cos(angle) * radius,
                         fallen_head.z + math.sin(angle) * radius + 0.16),
                        0.038, 0.010, mats["wood_dead_cut"], 4)
    box("Mast_Fallen_Crosstree", (-2.20, -2.66, 1.62), (0.20, 1.30, 0.10), mats["rail"],
        (0.0, math.radians(47), math.radians(-36)))
    for index, (station, side) in enumerate(((4, 1), (8, 1))):
        shroud(f"Mast_Shroud_{index + 1}", Vector((MAST_X, 0.0, 4.08)), station, side, mats)
    for index, target in enumerate(((-2.45, -3.05, 0.34), (-1.30, -2.70, 0.30))):
        tapered_between(f"Mast_Shroud_Loose_{index + 1}", (0.62, -0.86, 3.92), target,
                        0.030, 0.022, mats["rope"], 4)


def sail_grid(rows: int, columns: int, belly: float) -> list[list[Vector]]:
    """Bilinear gaff sail with a wind belly. u: mast -> leech, v: foot -> head."""
    tack = Vector((MAST_X - 0.14, 0.0, 3.30))
    clew = Vector((MAST_X - 4.34, 0.0, 3.42))
    throat = Vector((MAST_X - 0.18, 0.0, 6.86))
    peak = Vector((MAST_X - 3.06, 0.0, 7.56))
    grid: list[list[Vector]] = []
    for i in range(rows):
        u = i / (rows - 1)
        row: list[Vector] = []
        for j in range(columns):
            v = j / (columns - 1)
            point = tack.lerp(clew, u).lerp(throat.lerp(peak, u), v)
            point.y -= belly * math.sin(math.pi * u) * math.sin(math.pi * v)
            row.append(point)
        grid.append(row)
    return grid


def build_sail_raised(mats: dict[str, bpy.types.Material]) -> None:
    tapered_between("Sail_Boom", tuple(GOOSENECK), tuple(BOOM_END), 0.088, 0.070, mats["rail"], 6)
    tapered_between("Sail_Gaff", (MAST_X - 0.16, 0.0, 6.88), (MAST_X - 3.04, 0.0, 7.60),
                    0.078, 0.058, mats["rail"], 6)
    grid = sail_grid(7, 6, 0.46)
    # Two bands so the reef reads as a seam rather than a painted line, and so
    # the canvas has a darker foot: a sail that is one flat value looks like
    # paper at any distance where the ship is a silhouette.
    panel("Sail_Canvas_Foot", [row[:2] for row in grid], mats["canvas_dark"], 0.035, Vector((0.0, -1.0, 0.0)))
    panel("Sail_Canvas", [row[1:] for row in grid], mats["canvas"], 0.035, Vector((0.0, -1.0, 0.0)))
    for index in range(1, 6):
        point = grid[index][1]
        cone(f"Sail_Reef_{index}", 0.028, 0.012, 0.17, (point.x, point.y - 0.10, point.z - 0.05),
             mats["rope"], 4, (math.radians(96), 0.0, 0.0))
    for index in range(len(grid) - 1):
        tapered_between(f"Sail_Leech_{index + 1}", tuple(grid[index][-1]), tuple(grid[index + 1][-1]),
                        0.026, 0.024, mats["rope"], 4)
    tapered_between("Sail_Halyard", (MAST_X - 0.20, 0.0, 6.92), (MAST_X - 0.06, 0.0, 7.90),
                    0.024, 0.022, mats["rope"], 4)
    tapered_between("Sail_Sheet", tuple(BOOM_END), (MAST_X - 3.92, 0.0, DECK_Z + 0.06),
                    0.026, 0.022, mats["rope"], 4)


def build_sail_furled(mats: dict[str, bpy.types.Material]) -> None:
    tapered_between("Sail_Boom", tuple(GOOSENECK), tuple(BOOM_END), 0.088, 0.070, mats["rail"], 6)
    tapered_between("Sail_Gaff", (MAST_X - 0.16, 0.0, 3.52), (MAST_X - 3.08, 0.0, 3.62),
                    0.078, 0.058, mats["rail"], 6)
    for index in range(4):
        centre = GOOSENECK.lerp(BOOM_END, 0.16 + index * 0.23)
        blob(f"Sail_Bundle_{index + 1}", (centre.x, centre.y, centre.z + 0.20),
             (0.62, 0.24, 0.20), mats["canvas"], seed=71 + index, lumps=5, lump=0.26, sharpness=2.0)
    for index in range(5):
        centre = GOOSENECK.lerp(BOOM_END, 0.10 + index * 0.20)
        cone(f"Sail_Lash_{index + 1}", 0.24, 0.24, 0.055, (centre.x, centre.y, centre.z + 0.20),
             mats["rope"], 8, (0.0, math.radians(90), 0.0))
    tapered_between("Sail_Halyard", (MAST_X - 0.20, 0.0, 3.58), (MAST_X - 0.06, 0.0, 5.94),
                    0.024, 0.022, mats["rope"], 4)


def build_rudder(mats: dict[str, bpy.types.Material]) -> None:
    """Blade, stock and tiller, hung on the transom where the frame puts it."""
    rows = [
        [Vector((-5.22, 0.0, 0.64)), Vector((-6.06, 0.0, 0.72))],
        [Vector((-5.20, 0.0, 1.30)), Vector((-5.94, 0.0, 1.34))],
        [Vector((-5.18, 0.0, 1.94)), Vector((-5.72, 0.0, 1.96))],
        [Vector((-5.16, 0.0, 2.44)), Vector((-5.56, 0.0, 2.44))],
    ]
    panel("Rudder_Blade", rows, mats["rail"], 0.135, Vector((0.0, -1.0, 0.0)))
    tapered_between("Rudder_Stock", (-5.16, 0.0, 2.30), (-5.14, 0.0, 3.00), 0.088, 0.072, mats["rail"], 6)
    for index, z in enumerate((0.86, 1.62, 2.26)):
        box(f"Rudder_Pintle_{index + 1}", (-5.19, 0.0, z), (0.30, 0.26, 0.10), mats["iron"])
    tapered_between("Rudder_Tiller", (-5.14, 0.0, 2.96), (-3.70, 0.0, 2.74), 0.070, 0.048, mats["rail"], 6)
    box("Rudder_Tiller_Grip", (-3.80, 0.0, 2.75), (0.26, 0.09, 0.09), mats["leather"])


def build_boarding_ramp(mats: dict[str, bpy.types.Material]) -> None:
    """Ground to gangway. The gangway is a gap the hull states already leave."""
    foot_y, head_y = -4.58, -1.58
    # Centre-line heights: the ribbon is 0.11 thick, so a foot at z = 0 would
    # bury its underside 55 mm. Start it half a thickness up and the ramp
    # touches the ground exactly.
    foot_z, head_z = 0.055, DECK_Z - 0.02
    grid = [
        [Vector((-0.56, foot_y + (head_y - foot_y) * t, foot_z + (head_z - foot_z) * t)),
         Vector((0.56, foot_y + (head_y - foot_y) * t, foot_z + (head_z - foot_z) * t))]
        for t in (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)
    ]
    ribbon("Ramp_Deck", grid, mats["fresh"], 0.11)
    for index in range(7):
        t = 0.07 + index * 0.145
        y = foot_y + (head_y - foot_y) * t
        z = foot_z + (head_z - foot_z) * t
        box(f"Ramp_Cleat_{index + 1}", (0.0, y, z + 0.10), (1.06, 0.10, 0.055), mats["rail"])
    for index, x in enumerate((-0.60, 0.60)):
        tapered_between(f"Ramp_Kerb_{index + 1}", (x, foot_y, 0.10), (x, head_y, head_z + 0.10),
                        0.075, 0.065, mats["rail"], 5)
    for index, (x, t) in enumerate(((-0.62, 0.30), (0.62, 0.30), (-0.62, 0.74), (0.62, 0.74))):
        y = foot_y + (head_y - foot_y) * t
        z = foot_z + (head_z - foot_z) * t
        tapered_between(f"Ramp_Stanchion_{index + 1}", (x, y, z), (x, y - 0.06, z + 0.86),
                        0.048, 0.040, mats["rail"], 5)
        tapered_between(f"Ramp_Rope_{index + 1}", (x, y - 0.06, z + 0.80),
                        (x, y + (head_y - foot_y) * 0.20, z + (head_z - foot_z) * 0.20 + 0.80),
                        0.024, 0.022, mats["rope"], 4)


def build_cargo_hatch(mats: dict[str, bpy.types.Material]) -> None:
    """Deck hatch, propped open on a stick, with the hold's cargo showing.

    The coaming stands proud of the deck and the cargo sits inside it, above
    DECK_Z, rather than in a well cut through the hull's deck sheet. The deck is
    part of the hull model and the hatch is a separate one, so a real well would
    need a permanent hole in all four hull states — a hole that reads as damage
    whenever the hatch is not placed. A tall coaming is the honest trade, and it
    keeps A-005's rule: what opens reveals something, and the something is
    stacked to within 8 cm of the rim so it is visible from standing eye height
    rather than hidden behind the near wall.
    """
    x_aft, x_fore, half_y = -2.52, -1.28, 0.55
    floor_z, rim_z = DECK_Z + 0.04, DECK_Z + 0.46
    box("Hatch_Floor", ((x_aft + x_fore) * 0.5, 0.0, floor_z), (x_fore - x_aft, half_y * 2.0, 0.07), mats["rail"])
    for index, (x, y, width, depth) in enumerate((
        (x_aft, 0.0, 0.09, half_y * 2.0),
        (x_fore, 0.0, 0.09, half_y * 2.0),
        ((x_aft + x_fore) * 0.5, -half_y, x_fore - x_aft, 0.09),
        ((x_aft + x_fore) * 0.5, half_y, x_fore - x_aft, 0.09),
    )):
        box(f"Hatch_Coaming_{index + 1}", (x, y, (floor_z + rim_z) * 0.5), (width, depth, rim_z - floor_z), mats["rail"])
    blob("Hatch_Sack_1", (-2.16, -0.20, floor_z + 0.20), (0.30, 0.24, 0.19), mats["canvas"], seed=41, lumps=5, lump=0.24)
    blob("Hatch_Sack_2", (-1.72, 0.19, floor_z + 0.22), (0.28, 0.26, 0.21), mats["canvas_dark"], seed=43, lumps=5, lump=0.24)
    box("Hatch_Crate", (-2.14, 0.24, floor_z + 0.18), (0.34, 0.32, 0.32), mats["fresh"], (0.0, 0.0, 0.24))
    box("Hatch_Ingot", (-1.66, -0.22, floor_z + 0.28), (0.26, 0.11, 0.07), mats["iron"], (0.0, 0.0, -0.36))
    for index, radius in enumerate((0.17, 0.12)):
        cone(f"Hatch_Coil_{index + 1}", radius, radius - 0.045, 0.06, (-1.46, 0.02, floor_z + 0.32 + index * 0.06), mats["rope"], 10)
    lid_angle = math.radians(55.0)
    lid_length = 1.30
    centre = Vector((
        x_aft - math.cos(lid_angle) * lid_length * 0.5,
        0.0,
        rim_z + math.sin(lid_angle) * lid_length * 0.5,
    ))
    box("Hatch_Lid", tuple(centre), (lid_length, half_y * 2.0 + 0.10, 0.09), mats["rail"], (0.0, lid_angle, 0.0))
    for index, y in enumerate((-0.34, 0.34)):
        box(f"Hatch_Lid_Batten_{index + 1}",
            (centre.x, y, centre.z + 0.06), (lid_length * 0.96, 0.11, 0.06), mats["fresh"], (0.0, lid_angle, 0.0))
    box("Hatch_Hinge", (x_aft - 0.03, 0.0, rim_z + 0.03), (0.12, half_y * 1.5, 0.08), mats["iron"])
    prop_run = 0.34
    tapered_between("Hatch_Prop", (x_aft + 0.02, -0.40, rim_z),
                    (x_aft - prop_run, -0.40, rim_z + prop_run * math.tan(lid_angle)),
                    0.045, 0.038, mats["fresh"], 5)


# ── Standalone props: normalized the usual way ───────────────────────────────


def build_anchor(mats: dict[str, bpy.types.Material]) -> None:
    """An admiralty anchor lying on its side, with its cable flaked beside it."""
    tapered_between("Anchor_Shank", (-0.62, 0.0, 0.24), (0.68, 0.0, 0.27), 0.082, 0.062, mats["iron"], 6)
    box("Anchor_Crown", (-0.66, 0.0, 0.24), (0.20, 0.22, 0.18), mats["iron_dark"])
    for index, side in enumerate((-1, 1)):
        elbow = Vector((-0.60, side * 0.32, 0.20))
        tip = Vector((-0.40, side * 0.56, 0.34))
        tapered_between(f"Anchor_Arm_{index + 1}", (-0.66, 0.0, 0.24), tuple(elbow), 0.072, 0.055, mats["iron"], 6)
        tapered_between(f"Anchor_Arm_Tip_{index + 1}", tuple(elbow), tuple(tip), 0.055, 0.030, mats["iron"], 6)
        cone(f"Anchor_Fluke_{index + 1}", 0.18, 0.02, 0.30, (tip.x + 0.05, tip.y + side * 0.05, tip.z + 0.02),
             mats["iron_dark"], 3, (math.radians(90) * side, 0.0, math.radians(28) * side))
    box("Anchor_Stock", (0.50, 0.0, 0.28), (0.13, 1.14, 0.13), mats["rail"])
    for index, side in enumerate((-1, 1)):
        box(f"Anchor_Stock_Cap_{index + 1}", (0.50, side * 0.60, 0.28), (0.15, 0.10, 0.15), mats["iron_dark"])
    for index, (angle, radius) in enumerate(radial(8, 0.15, seed=61, jitter=0.0, radius_jitter=0.0)):
        nxt = radial(8, 0.15, seed=61, jitter=0.0, radius_jitter=0.0)[(index + 1) % 8]
        tapered_between(
            f"Anchor_Ring_{index + 1}",
            (0.80, math.cos(angle) * radius, 0.27 + math.sin(angle) * radius),
            (0.80, math.cos(nxt[0]) * nxt[1], 0.27 + math.sin(nxt[0]) * nxt[1]),
            0.030, 0.030, mats["iron_dark"], 4,
        )
    for index, radius in enumerate((0.34, 0.26, 0.18)):
        cone(f"Anchor_Cable_{index + 1}", radius, radius - 0.06, 0.075,
             (-0.10, 0.68, 0.04 + index * 0.07), mats["rope"], 10)
    tapered_between("Anchor_Cable_Tail", (0.78, 0.14, 0.28), (0.02, 0.52, 0.10), 0.035, 0.032, mats["rope"], 4)


def build_donation_crate(mats: dict[str, bpy.types.Material]) -> None:
    """Where the repair materials go in. It has to read as a slot, not a box."""
    width, depth, height, wall = 1.00, 0.80, 0.82, 0.07
    box("Crate_Floor", (0.0, 0.0, wall * 0.5), (width, depth, wall), mats["frame"])
    for index, (x, y, sx, sy) in enumerate((
        (0.0, -(depth - wall) * 0.5, width, wall),
        (0.0, (depth - wall) * 0.5, width, wall),
        (-(width - wall) * 0.5, 0.0, wall, depth - wall * 2.0),
        ((width - wall) * 0.5, 0.0, wall, depth - wall * 2.0),
    )):
        box(f"Crate_Wall_{index + 1}", (x, y, height * 0.5), (sx, sy, height), mats["rail"])
    for index, z in enumerate((0.20, 0.62)):
        box(f"Crate_Band_{index + 1}", (0.0, 0.0, z), (width * 1.03, depth * 1.03, 0.075), mats["iron"])
    for index, (x, y) in enumerate(((-0.47, -0.37), (0.47, -0.37), (-0.47, 0.37), (0.47, 0.37))):
        box(f"Crate_Corner_{index + 1}", (x, y, height * 0.5), (0.07, 0.07, height * 1.02), mats["iron"])
    # Contents stacked to 12 cm under the rim, for the same reason A-005's chests
    # fill to near theirs: anything on the floor of a 0.8 m box is invisible.
    box("Crate_Fill_Plank_1", (-0.16, -0.10, 0.58), (0.72, 0.16, 0.06), mats["fresh"], (0.0, 0.0, 0.06))
    box("Crate_Fill_Plank_2", (-0.10, 0.14, 0.65), (0.68, 0.16, 0.06), mats["fresh"], (0.0, 0.0, -0.10))
    box("Crate_Fill_Ingot", (0.24, -0.16, 0.68), (0.26, 0.11, 0.07), mats["iron"], (0.0, 0.0, 0.30))
    for index, radius in enumerate((0.16, 0.11)):
        cone(f"Crate_Fill_Coil_{index + 1}", radius, radius - 0.04, 0.055, (0.26, 0.20, 0.64 + index * 0.055), mats["rope"], 10)
    for index, (x, y) in enumerate(((-0.40, 0.0), (0.40, 0.0))):
        box(f"Crate_Lid_Rail_{index + 1}", (x, y, height + 0.04), (0.20, depth, 0.08), mats["fresh"])
    for index, y in enumerate((-0.30, 0.30)):
        box(f"Crate_Lid_End_{index + 1}", (0.0, y, height + 0.04), (0.62, 0.20, 0.08), mats["fresh"])
    box("Crate_Plate", (0.0, -depth * 0.5 - 0.02, 0.50), (0.34, 0.03, 0.20), mats["brass"])
    for index, x in enumerate((-0.20, -0.12, -0.04, 0.06, 0.16)):
        box(f"Crate_Tally_{index + 1}", (x, -depth * 0.5 - 0.04, 0.26), (0.025, 0.02, 0.16), mats["fresh"])


def build_departure_bell(mats: dict[str, bpy.types.Material]) -> None:
    """Ring it and the run ends. It stands alone, so it reads as an instrument."""
    for index, y in enumerate((-0.52, 0.52)):
        tapered_between(f"Bell_Post_{index + 1}", (0.0, y, 0.0), (0.0, y * 0.92, 1.92), 0.085, 0.070, mats["rail"], 6)
        box(f"Bell_Sill_{index + 1}", (0.0, y, 0.06), (0.62, 0.22, 0.12), mats["frame"])
        tapered_between(f"Bell_Brace_{index + 1}", (0.0, y, 0.52), (0.0, y * 0.55, 1.72), 0.048, 0.042, mats["rail"], 5)
    box("Bell_Beam", (0.0, 0.0, 1.94), (0.20, 1.28, 0.16), mats["rail"])
    box("Bell_Yoke", (0.0, 0.0, 1.80), (0.16, 0.34, 0.14), mats["iron_dark"])
    cone("Bell_Body", 0.30, 0.15, 0.44, (0.0, 0.0, 1.50), mats["brass"], 10)
    cone("Bell_Lip", 0.32, 0.30, 0.07, (0.0, 0.0, 1.30), mats["brass_dark"], 10)
    ico("Bell_Clapper", (0.0, 0.0, 1.34), (0.06, 0.06, 0.09), mats["iron_dark"])
    tapered_between("Bell_Pull", (0.0, 0.0, 1.34), (0.0, -0.16, 0.66), 0.022, 0.020, mats["rope"], 4)
    box("Bell_Toggle", (0.0, -0.17, 0.60), (0.07, 0.07, 0.16), mats["rail"])
    box("Bell_Plaque", (0.05, -0.52, 1.16), (0.03, 0.26, 0.16), mats["brass"])


def build_debris_cluster(mats: dict[str, bpy.types.Material]) -> None:
    """Wreckage the hull shed. Placed by angle, never by hand-written coordinates.

    `radial()` is the whole reason this asset is not the 2.1j defect again: a
    debris pile is exactly the thing an author scatters across the front of the
    preview frame and nowhere else.
    """
    for index, (angle, radius) in enumerate(radial(7, 0.60, seed=101, jitter=0.55, radius_jitter=0.28)):
        start = Vector((math.cos(angle) * radius, math.sin(angle) * radius, 0.05 + 0.03 * (index % 3)))
        end = start + Vector((math.cos(angle + 0.9) * 0.62, math.sin(angle + 0.9) * 0.62, 0.02 * (index % 2)))
        plank(f"Debris_Plank_{index + 1}", tuple(start), tuple(end), 0.19, 0.055,
              mats[("wood_dead", "wood_dead_cut", "frame")[index % 3]])
    for index, (angle, radius) in enumerate(radial(3, 0.48, seed=103, jitter=0.5)):
        foot = Vector((math.cos(angle) * radius, math.sin(angle) * radius, 0.03))
        knee = foot + Vector((math.cos(angle) * 0.34, math.sin(angle) * 0.34, 0.20))
        tip = knee + Vector((math.cos(angle) * 0.38, math.sin(angle) * 0.38, -0.14))
        tapered_between(f"Debris_Rib_{index + 1}", tuple(foot), tuple(knee), 0.075, 0.062, mats["frame"], 5)
        tapered_between(f"Debris_Rib_Tip_{index + 1}", tuple(knee), tuple(tip), 0.062, 0.020, mats["wood_dead_cut"], 5)
    canvas_grid = [
        [Vector((-0.52, 0.28, 0.03)), Vector((-0.42, 0.76, 0.06))],
        [Vector((-0.05, 0.23, 0.14)), Vector((0.03, 0.73, 0.10))],
        [Vector((0.39, 0.33, 0.05)), Vector((0.50, 0.78, 0.03))],
    ]
    panel("Debris_Canvas", canvas_grid, mats["canvas_dark"], 0.03, Vector((0.0, 0.0, 1.0)))
    for index, radius in enumerate((0.30, 0.22, 0.15)):
        cone(f"Debris_Coil_{index + 1}", radius, radius - 0.05, 0.07, (-0.62, -0.42, 0.04 + index * 0.065), mats["rope"], 10)
    for index, (angle, radius) in enumerate(radial(5, 0.50, seed=107, jitter=0.6, radius_jitter=0.45)):
        blob(f"Debris_Chip_{index + 1}",
             (math.cos(angle) * radius, math.sin(angle) * radius, 0.06),
             (0.14, 0.11, 0.06), mats["wood_dead_cut"], seed=113 + index, subdivisions=0, lumps=4, lump=0.3)
    for index, (angle, radius) in enumerate(radial(3, 0.72, seed=109, jitter=0.4)):
        blob(f"Debris_Weed_{index + 1}",
             (math.cos(angle) * radius, math.sin(angle) * radius, 0.05),
             (0.24, 0.20, 0.08), mats["moss"], seed=127 + index, subdivisions=0, lumps=5, lump=0.35, flat_base=0.4)


# ── Assembly, contract, catalog and previews ─────────────────────────────────


def set_visible(record: dict, visible: bool) -> None:
    record["root"].hide_render = not visible
    for child in record["root"].children_recursive:
        child.hide_render = not visible


def create_asset(
    name: str,
    build_fn: Callable[[], None],
    display_location: tuple[float, float, float],
) -> dict:
    family = FAMILY[name]
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)
    before = set(bpy.data.objects)
    build_fn()
    made = [obj for obj in bpy.data.objects if obj not in before]

    # PROP is the usual portable normalization: ground the origin, centre it
    # horizontally. STRUCTURE and FITTED are authored directly in the ship frame
    # and are moved by exactly nothing, which is what makes them assemble at
    # Transform3D.IDENTITY and what makes state drift zero rather than small.
    offset = Vector((0.0, 0.0, 0.0))
    if family == PROP:
        low, high = world_bounds(made)
        offset = Vector((-(low.x + high.x) * 0.5, -(low.y + high.y) * 0.5, -low.z))
        for obj in made:
            obj.location += offset
    move_to_collection(made, collection)
    for obj in made:
        obj.parent = root

    low, high = world_bounds(made)
    dimensions = high - low
    meshes = [obj for obj in made if obj.type == "MESH"]
    polygons = sum(len(obj.data.polygons) for obj in meshes)
    triangles = sum(
        max(0, len(polygon.vertices) - 2) for obj in meshes for polygon in obj.data.polygons
    )
    materials = sorted({m.name for obj in meshes for m in obj.data.materials if m})
    cradle_parts = [obj for obj in meshes if obj.name.startswith("Cradle_")]
    cradle_bounds = None
    if cradle_parts:
        cradle_low, cradle_high = world_bounds(cradle_parts)
        cradle_bounds = tuple(round(value, 6) for value in (*cradle_low, *cradle_high))

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
    root.location = display_location
    return {
        "name": name,
        "family": family,
        "root": root,
        "width": dimensions.x,
        "depth": dimensions.y,
        "height": dimensions.z,
        "min_z": low.z,
        "centre_xy": ((low.x + high.x) * 0.5, (low.y + high.y) * 0.5),
        "offset": tuple(offset),
        "parts": len(meshes),
        "polygons": polygons,
        "triangles": triangles,
        "materials": materials,
        "cradle_bounds": cradle_bounds,
    }


def check(records: list[dict]) -> list[str]:
    """Everything a machine can judge about this batch, judged. Failing, not warning."""
    problems: list[str] = []
    for record in records:
        name, family = record["name"], record["family"]
        dimensions = (record["width"], record["depth"], record["height"])
        complaint = check_scale(name, dimensions)
        if complaint:
            problems.append(complaint)
        if record["triangles"] > TRIANGLE_BUDGET[family]:
            problems.append(
                f"{name}: {record['triangles']} triangles over the {family} budget "
                f"of {TRIANGLE_BUDGET[family]}"
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
        if family == PROP:
            if abs(record["min_z"]) > 0.001:
                problems.append(f"{name}: sits {record['min_z'] * 1000:.1f} mm off the ground plane")
            if max(abs(value) for value in record["centre_xy"]) > 0.001:
                problems.append(f"{name}: not horizontally centred ({record['centre_xy']})")
        else:
            if any(abs(value) > 1e-9 for value in record["offset"]):
                problems.append(f"{name}: ship-frame asset was moved by {record['offset']}; the frame is authored, not fitted")
            if record["min_z"] < -0.001:
                problems.append(f"{name}: {record['min_z'] * 1000:.1f} mm below the ground plane")
        if family == STRUCTURE and abs(record["min_z"]) > 0.001:
            problems.append(f"{name}: hull state does not sit on the ground ({record['min_z'] * 1000:.1f} mm)")

    for name, outward, measured in WINDING_LOG:
        if measured.length < 1e-9:
            problems.append(f"{name}: zero net area, so its facing cannot be proved")
        elif measured.normalized().dot(outward) <= 0.0:
            problems.append(
                f"{name}: faces {tuple(round(v, 2) for v in measured.normalized())} but was asked "
                f"for {tuple(round(v, 2) for v in outward)} — it would be invisible from that side"
            )

    states = [record for record in records if record["family"] == STRUCTURE]
    anchors = {record["name"]: record["cradle_bounds"] for record in states}
    if any(bounds is None for bounds in anchors.values()):
        problems.append("a hull state built no cradle, so state drift cannot be measured")
    elif len(set(anchors.values())) != 1:
        problems.append(f"hull state cradles disagree, so the states drift: {anchors}")
    return problems


def reference_figure(mats: dict[str, bpy.types.Material], location: tuple[float, float, float], tag: int) -> list:
    """A 1.79 m blocky person. A ruler post cannot answer "can I board that?"."""
    x, y, z = location
    return [
        box(f"Ref_{tag}_Legs", (x, y, z + 0.42), (0.36, 0.26, 0.84), mats["scale"]),
        box(f"Ref_{tag}_Torso", (x, y, z + 1.15), (0.48, 0.30, 0.64), mats["scale"]),
        box(f"Ref_{tag}_Head", (x, y, z + 1.63), (0.26, 0.26, 0.32), mats["scale"]),
        box(f"Ref_{tag}_Arm_1", (x - 0.31, y, z + 1.12), (0.14, 0.18, 0.62), mats["scale"]),
        box(f"Ref_{tag}_Arm_2", (x + 0.31, y, z + 1.12), (0.14, 0.18, 0.62), mats["scale"]),
    ]


def setup_render(mats: dict[str, bpy.types.Material]):
    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.mesh.primitive_plane_add(size=120, location=(0.0, 0.0, -0.02))
    floor = bpy.context.object
    floor.name = "Preview_Ground"
    assign(floor, mats["ground"])
    move_to_collection([floor], preview_collection)
    bpy.ops.object.light_add(type="SUN", location=(0.0, 0.0, 30.0))
    sun = bpy.context.object
    sun.name = "Preview_Sun"
    sun.rotation_euler = (math.radians(38), math.radians(-20), math.radians(-34))
    sun.data.energy = 2.6
    sun.data.angle = math.radians(18)
    move_to_collection([sun], preview_collection)
    bpy.ops.object.light_add(type="AREA", location=(-16.0, -20.0, 16.0))
    fill = bpy.context.object
    fill.name = "Preview_Fill"
    fill.data.energy = 26000
    fill.data.color = (0.43, 0.30, 0.66)
    fill.data.shape = "DISK"
    fill.data.size = 18.0
    look_at(fill, (0.0, 0.0, 2.0))
    move_to_collection([fill], preview_collection)
    bpy.ops.object.camera_add(location=(20.0, -24.0, 12.0))
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    camera.data.type = "ORTHO"
    bpy.context.scene.camera = camera
    move_to_collection([camera], preview_collection)
    scene = bpy.context.scene
    scene.render.engine = eevee_engine()
    scene.render.resolution_x = 1920
    scene.render.resolution_y = 1080
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.012, 0.016, 0.026)
    scene.view_settings.look = "AgX - Medium High Contrast"
    return scene, camera, preview_collection


def render(scene, camera, records: list[dict], filename: str, placement: dict,
           eye: tuple[float, float, float], target: tuple[float, float, float], ortho: float) -> None:
    for record in records:
        visible = record["name"] in placement
        set_visible(record, visible)
        if visible:
            record["root"].location = placement[record["name"]]
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
        # Shared palette only. Purple stays reserved for corruption and teal for
        # the Ward, so the ship — the one object in the game that means "safe,
        # and out" — is made entirely of honest wood, iron, brass and canvas.
        "wood_dead": mat("wood_dead"),
        "wood_dead_cut": mat("wood_dead_cut"),
        "wood_timber": mat("wood_timber"),
        "wood_timber_light": mat("wood_timber_light"),
        "cradle": mat("wood_bark_dark"),
        "frame": mat("wood_bark"),
        "fresh": mat("wood_cut"),
        "rail": mat("wood_timber"),
        "deck_old": mat("wood_dead"),
        "deck_old_alt": mat("wood_dead_cut"),
        "deck_new": mat("wood_timber_light"),
        "deck_new_alt": mat("wood_timber"),
        "iron": mat("iron"),
        "iron_dark": mat("iron_dark"),
        "brass": mat("brass"),
        "brass_dark": mat("brass_dark"),
        "rope": mat("rope"),
        "canvas": mat("canvas"),
        "canvas_dark": mat("canvas_dark"),
        "leather": mat("leather"),
        "moss": mat("moss"),
        "flame": mat("flame"),
        "ground": mat("preview_ground"),
        "scale": mat("reference_blue"),
    }

    builders: list[tuple[str, Callable[[], None]]] = [
        ("ship_hull_wrecked", lambda: build_hull(mats, "wrecked")),
        ("ship_hull_repair_1", lambda: build_hull(mats, "repair_1")),
        ("ship_hull_repair_2", lambda: build_hull(mats, "repair_2")),
        ("ship_hull_repaired", lambda: build_hull(mats, "repaired")),
        ("ship_mast", lambda: build_mast(mats)),
        ("ship_mast_broken", lambda: build_mast_broken(mats)),
        ("ship_sail_furled", lambda: build_sail_furled(mats)),
        ("ship_sail_raised", lambda: build_sail_raised(mats)),
        ("ship_rudder", lambda: build_rudder(mats)),
        ("ship_boarding_ramp", lambda: build_boarding_ramp(mats)),
        ("ship_cargo_hatch", lambda: build_cargo_hatch(mats)),
        ("ship_anchor", lambda: build_anchor(mats)),
        ("ship_donation_crate", lambda: build_donation_crate(mats)),
        ("ship_departure_bell", lambda: build_departure_bell(mats)),
        ("ship_debris_cluster", lambda: build_debris_cluster(mats)),
    ]
    if [name for name, _ in builders] != EXPECTED_NAMES:
        raise RuntimeError("A-009 specification and expected export list diverged")

    records: list[dict] = []
    for index, (name, builder) in enumerate(builders):
        records.append(create_asset(name, builder, (0.0, index * 14.0, 0.0)))

    problems = check(records)
    for problem in problems:
        print(f"CONTRACT FAIL  {problem}")
    if problems:
        raise RuntimeError(f"A-009 build contract failed with {len(problems)} problem(s)")

    catalog = [
        {
            "name": record["name"],
            "family": record["family"],
            "width_m": round(record["width"], 3),
            "depth_m": round(record["depth"], 3),
            "height_m": round(record["height"], 3),
            "origin": "ship_frame" if record["family"] != PROP else "ground_centred",
            "min_z_m": round(record["min_z"], 4),
            "mesh_parts": record["parts"],
            "polygons": record["polygons"],
            "triangles": record["triangles"],
            "materials": record["materials"],
        }
        for record in records
    ]
    with (ASSET_DIR / "catalog.json").open("w", encoding="utf-8") as handle:
        json.dump(catalog, handle, indent=2)
        handle.write("\n")

    scene, camera, preview_collection = setup_render(mats)
    origin = (0.0, 0.0, 0.0)
    rig = ["ship_hull_repaired", "ship_mast", "ship_sail_raised", "ship_rudder",
           "ship_boarding_ramp", "ship_cargo_hatch"]

    hero = {name: origin for name in rig}
    hero.update({
        "ship_anchor": (7.10, -3.40, 0.0),
        "ship_donation_crate": (5.60, -5.20, 0.0),
        "ship_departure_bell": (2.90, -5.60, 0.0),
        "ship_debris_cluster": (-7.30, -3.10, 0.0),
    })
    render(scene, camera, records, "ship_preview.png", hero,
           eye=(19.0, -21.0, 11.0), target=(0.0, -1.0, 2.6), ortho=21.0)

    states = {
        "ship_hull_wrecked": (0.0, -7.20, 0.0),
        "ship_hull_repair_1": (0.0, -2.40, 0.0),
        "ship_hull_repair_2": (0.0, 2.40, 0.0),
        "ship_hull_repaired": (0.0, 7.20, 0.0),
    }
    render(scene, camera, records, "ship_states_preview.png", states,
           eye=(15.0, -17.0, 20.0), target=(0.0, 0.0, 1.2), ortho=26.0)

    progression = {
        "ship_hull_wrecked": (0.0, -6.40, 0.0),
        "ship_mast_broken": (0.0, -6.40, 0.0),
        "ship_debris_cluster": (-7.00, -8.60, 0.0),
        "ship_hull_repair_2": (0.0, 6.40, 0.0),
        "ship_mast": (0.0, 6.40, 0.0),
        "ship_sail_furled": (0.0, 6.40, 0.0),
    }
    render(scene, camera, records, "ship_rig_preview.png", progression,
           eye=(17.0, -20.0, 13.0), target=(0.0, 0.0, 3.0), ortho=24.0)

    scale_shot = {name: origin for name in rig}
    scale_shot.update({
        "ship_anchor": (6.40, -3.00, 0.0),
        "ship_donation_crate": (4.60, -4.60, 0.0),
        "ship_departure_bell": (2.20, -5.00, 0.0),
    })
    figures = reference_figure(mats, (0.30, -5.30, 0.0), 1) + reference_figure(mats, (-2.10, 0.0, DECK_Z), 2)
    move_to_collection(figures, preview_collection)
    render(scene, camera, records, "ship_scale_preview.png", scale_shot,
           eye=(15.0, -17.0, 8.0), target=(-0.4, -1.6, 2.0), ortho=15.0)

    for record in records:
        set_visible(record, True)
    for index, record in enumerate(records):
        record["root"].location = (0.0, index * 14.0, 0.0)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "extraction_ship_set.blend"))

    total = sum(record["triangles"] for record in records)
    print(f"Built {len(records)} A-009 extraction ship assets ({total} triangles total)")
    for record in records:
        print(
            f"  {record['name']:24s} {record['width']:6.2f} x {record['depth']:5.2f} x "
            f"{record['height']:5.2f} m  {record['triangles']:5d} tris  "
            f"{len(record['materials'])} mats  origin={record['family']}"
        )


if __name__ == "__main__":
    main()
