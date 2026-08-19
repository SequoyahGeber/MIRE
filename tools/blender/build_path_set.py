"""A-014 — roads and navigation: the ground a player walks on, and the things that tell them where.

  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender/build_path_set.py

Thirteen assets in `assets/paths/`, built with Blender 5.2.0 LTS (D-038 pins the toolchain).

This batch is governed by two earlier kits at once
-------------------------------------------------
**A-010's module.** Every tiling piece here is exactly `MODULE` = 2.00 m along its run and across
it, the same number `content/buildables/wall.tres` and the whole construction kit are built on, so a
path meets a dock, a bridge or a wall run without a fudge factor. A-010 learned the expensive half of
this the hard way: a piece can measure its module exactly and still leave a seam, because the
*surface* is what tiles, not the bounding box (F-135). So the contract measures the walking surface.

**A-013's carpentry, at the right gauge.** The camp kit is built from 32 mm board stock; A-010's
construction kit uses 55 mm plank. Those are two real products and this batch picks deliberately:
**anything you walk on takes the 55 mm plank**, because a boardwalk is a bridge lying down, not a
shelf. The rule worth carrying: *camp furniture is board stock, anything structural or walked on is
plank stock.*

**The boardwalk joins A-010's deck network.** Its deck sits at `BOARDWALK_Z` = 0.22 m — laid on
sleepers on the ground rather than on piles — and `boardwalk_stairs` is the piece that climbs from it
to A-010's `DECK_Z` = 1.00 m, so a low walkway over mud and a raised dock over water are one
continuous route. That is the whole reason the stairs exist at that rise and no other.

One tile, four surfaces
-----------------------
Dirt, mud, cobble and corruption are the same slab with different surfaces on it. The slab is the
shared frame — identical bounds, so a mixed run tiles — and what sits on it is the identity: puddles,
set stones, or the veins that mean the Mire has reached this road. A player reads the *surface* and
learns one silhouette, which is A-012's lesson applied to ground rather than to bottles.

Previews place every asset once and only move the camera (F-204).
"""

from __future__ import annotations

import json
import math
import random
import sys
from pathlib import Path
from typing import Callable

import bpy
from mathutils import Vector

sys.path.append(str(Path(__file__).resolve().parent))

from mire_art import (  # noqa: E402
    Batch, box, cone, cylinder_between, eevee_engine, ground_and_centre, hull, look_at,
    mat, paint_faces, radial, reset_materials, tapered_between, world_bounds,
)

ROOT = Path(__file__).resolve().parents[2]
EXPORT_DIR = ROOT / "assets" / "paths" / "exports"
PREVIEW_DIR = ROOT / "assets" / "paths" / "preview"
CATALOG_PATH = ROOT / "assets" / "paths" / "catalog.json"
SOURCE_DIR = ROOT / "assets" / "source"
SOURCE_PATH = SOURCE_DIR / "path_set.blend"

# ── Inherited contracts ──────────────────────────────────────────────────────

MODULE = 2.00            # A-010's run pitch, and this kit's tile
DECK_Z = 1.00            # A-010's dock and bridge deck
BOARDWALK_Z = 0.22       # this kit's own deck: sleepers on the ground
PLANK_T = 0.055          # A-010's plank. Walked on, so not A-013's 32 mm board
PLANK_W = 0.19
SLAB_T = 0.045           # how proud a path surface sits over bare ground
POST_R = 0.058

HALF = MODULE * 0.5

#: Tiling pieces and the exact extent their SURFACE must measure, in metres.
#: Measured on the surface rather than on the asset, because a marker stone at the
#: edge of a tile would otherwise make the tile look correct while the ground it
#: lays does not reach the next one (F-135).
RUN_SPAN: dict[str, tuple[float, float | None]] = {
    # Field tiles: neighbours on all four sides, so both axes must reach the module.
    "path_dirt": (MODULE, MODULE), "path_mud": (MODULE, MODULE),
    "path_cobble": (MODULE, MODULE), "path_corrupted": (MODULE, MODULE),
    # Run tiles: a walkway is as wide as a walkway, and only its length has to meet
    # the next piece. `None` means "not checked", not "anything goes" — the width
    # is still governed by the footprint cap below.
    "boardwalk_straight": (MODULE, None), "boardwalk_corner": (MODULE, MODULE),
    "boardwalk_broken": (MODULE, None), "stepping_stones": (MODULE, None),
}

SIZE: dict[str, tuple[float, str, float]] = {
    "path_dirt": (MODULE, "spread", 2.02),
    "path_mud": (MODULE, "spread", 2.02),
    "path_cobble": (MODULE, "spread", 2.02),
    "path_corrupted": (MODULE, "spread", 2.02),
    "boardwalk_straight": (MODULE, "spread", 2.02),
    "boardwalk_corner": (MODULE, "spread", 2.02),
    "boardwalk_broken": (MODULE, "spread", 2.02),
    "boardwalk_stairs": (MODULE, "spread", 2.02),
    "stepping_stones": (MODULE, "spread", 2.02),
    "trail_marker": (0.94, "height", 0.62),
    "rune_marker": (1.32, "height", 0.80),
    "warning_sign": (1.46, "height", 0.86),
    "signpost": (2.05, "height", 1.30),
}

SIZE_TOLERANCE = 0.02
TRIANGLE_BUDGET = 620          # ground tiles are placed by the hundred
BUDGET_ALLOWANCE = {"path_cobble": 1000, "boardwalk_stairs": 760, "signpost": 700}
MAX_MATERIALS = 4
MATERIAL_ALLOWANCE = {"path_corrupted": 5, "signpost": 5, "warning_sign": 5}

#: The path slab: identical in all four surfaces, so a mixed run tiles.
FRAMES: dict[str, tuple[str, ...]] = {
    "path_dirt": ("slab_",), "path_mud": ("slab_",),
    "path_cobble": ("slab_",), "path_corrupted": ("slab_",),
}

SIBLINGS: dict[str, tuple[str, ...]] = {
    "path": ("path_dirt", "path_mud", "path_cobble", "path_corrupted"),
}

FRAME_SEED = {"path": 8101}

#: The geometry that must reach the module edge. A tile whose slab is short by a
#: few millimetres shows a stripe of untouched ground at every joint, while the
#: asset's own bounding box — a marker stone, a kerb — measures a perfect 2.000.
SURFACE_PREFIX: dict[str, tuple[str, ...]] = {
    "path_dirt": ("slab_",), "path_mud": ("slab_",),
    "path_cobble": ("slab_",), "path_corrupted": ("slab_",),
    "boardwalk_straight": ("walk_board_",), "boardwalk_corner": ("walk_board_",),
    "boardwalk_broken": ("walk_board_", "walk_sleeper_"),
    "stepping_stones": ("step_stone_",),
}

LAYOUT: dict[str, tuple[float, float]] = {
    "path_dirt": (-3.30, 0.0), "path_mud": (-1.10, 0.0),
    "path_cobble": (1.10, 0.0), "path_corrupted": (3.30, 0.0),
    "boardwalk_straight": (-3.30, 6.0), "boardwalk_corner": (-1.10, 6.0),
    "boardwalk_stairs": (1.10, 6.0), "boardwalk_broken": (3.30, 6.0),
    "stepping_stones": (5.50, 6.0),
    "trail_marker": (-1.60, 12.0), "rune_marker": (-0.40, 12.0),
    "warning_sign": (0.90, 12.0), "signpost": (2.50, 12.0),
}

#: (file, row y, left edge, half width, camera height, look-at height, assets)
SHEETS: list[tuple[str, float, float, float, float, float, tuple[str, ...]]] = [
    # Ground, from above: a path tile shot from eye height is a stripe.
    ("path_surfaces_preview.png", 0.0, -4.40, 4.60, 7.20, 0.02,
     ("path_dirt", "path_mud", "path_cobble", "path_corrupted")),
    # The boardwalk has height AND surface, so it is shot from a walker's angle.
    ("path_boardwalk_preview.png", 6.0, -4.40, 5.70, 3.40, 0.20,
     ("boardwalk_straight", "boardwalk_corner", "boardwalk_stairs", "boardwalk_broken",
      "stepping_stones")),
    # Markers are read standing up, at the distance you decide to follow one.
    ("path_markers_preview.png", 12.0, -2.40, 3.00, 1.35, 0.78,
     ("trail_marker", "rune_marker", "warning_sign", "signpost")),
]


def seed_for(name: str) -> int:
    return sum((index + 3) * ord(char) for index, char in enumerate(name))


# ── The shared slab ──────────────────────────────────────────────────────────


def path_slab(token: str, verge_token: str | None = None) -> None:
    """One module of worn ground, dead flat at its edges and slightly hollow in
    the middle — a path is where feet have taken the surface DOWN.

    Built as an explicit grid rather than a displaced box so the four edges are
    exactly on the module and cannot wander: the middle of a tile may sag, its
    border may not, or a run of them shows a ridge at every joint (F-135).
    """
    seed = FRAME_SEED["path"]
    rng = random.Random(seed)
    steps = 8
    points: list[list[Vector]] = []
    for row in range(steps + 1):
        line: list[Vector] = []
        for column in range(steps + 1):
            x = -HALF + MODULE * column / steps
            y = -HALF + MODULE * row / steps
            edge = max(abs(x), abs(y)) / HALF
            hollow = (1.0 - edge ** 2) * 0.028
            wobble = 0.0 if edge > 0.98 else rng.uniform(-0.008, 0.008)
            line.append(Vector((x, y, SLAB_T - hollow + wobble)))
        points.append(line)
    batch = Batch()
    for row in range(steps):
        for column in range(steps):
            a, b = points[row][column], points[row][column + 1]
            c, d = points[row + 1][column + 1], points[row + 1][column]
            # The verge: the ring of quads traffic never reaches. Jittered per
            # quad so the boundary is a fringe rather than a drawn square.
            centre_x = (a.x + c.x) * 0.5
            centre_y = (a.y + c.y) * 0.5
            reach = max(abs(centre_x), abs(centre_y)) / HALF
            face_token = token
            if verge_token is not None and reach > 0.70 + rng.uniform(-0.10, 0.10):
                face_token = verge_token
            batch.add(face_token, [tuple(a), tuple(b), tuple(c), tuple(d)], [(0, 1, 2, 3)])
            # A skirt down to the ground on the outer edges only, so the tile has
            # a thickness where it meets untouched ground and none where it meets
            # its neighbour.
            for edge_a, edge_b, at_edge in (
                (a, b, row == 0), (c, d, row == steps - 1),
                (d, a, column == 0), (b, c, column == steps - 1),
            ):
                if at_edge:
                    batch.add(token,
                              [tuple(edge_a), tuple(edge_b),
                               (edge_b.x, edge_b.y, 0.0), (edge_a.x, edge_a.y, 0.0)],
                              [(0, 1, 2, 3)])
    batch.emit("slab")


# ── The four surfaces ────────────────────────────────────────────────────────


def build_path_dirt(seed: int) -> None:
    """Bare worn earth: dry grass surviving at the verge, stones the traffic has
    not yet pushed under, and a track down the middle where boots fall."""
    path_slab("terrain_path", "grass_dry")
    rng = random.Random(seed)
    batch = Batch()
    for angle, radius in radial(14, 0.62, seed=seed, jitter=0.95, radius_jitter=0.55):
        batch.blob("stone_dark" if rng.random() < 0.5 else "stone",
                   (math.cos(angle) * radius, math.sin(angle) * radius, 0.028),
                   (rng.uniform(0.05, 0.10), rng.uniform(0.04, 0.09), rng.uniform(0.010, 0.020)),
                   rng)
    batch.emit("dirt_grit")


def build_path_mud(seed: int) -> None:
    """The same road after rain: standing water in the hollow, churned edges. The
    puddles are flat and dark, which is the whole read — a mud path with texture
    but no water looks like a dirt path somebody made browner."""
    path_slab("peat", "sedge")
    rng = random.Random(seed)
    batch = Batch()
    for index, (angle, radius) in enumerate(radial(5, 0.44, seed=seed + 4, jitter=0.8,
                                                   radius_jitter=0.7)):
        cx, cy = math.cos(angle) * radius, math.sin(angle) * radius
        ring = radial(8, rng.uniform(0.15, 0.27), seed=seed + index * 9, jitter=0.4,
                      radius_jitter=0.34)
        points = [(cx + math.cos(a) * r, cy + math.sin(a) * r, 0.0225) for a, r in ring]
        centre = (cx, cy, 0.0225)
        for step in range(len(points)):
            batch.add("water_still",
                      [centre, points[step], points[(step + 1) % len(points)]], [(0, 1, 2)])
    batch.emit("mud_puddle")
    ridge = Batch()
    for angle, radius in radial(9, 0.64, seed=seed + 11, jitter=0.9, radius_jitter=0.22):
        ridge.blob("peat",
                   (math.cos(angle) * radius, math.sin(angle) * radius, 0.042),
                   (rng.uniform(0.05, 0.09), rng.uniform(0.04, 0.08), rng.uniform(0.012, 0.024)),
                   rng)
    ridge.emit("mud_churn")


def build_path_cobble(seed: int) -> None:
    """Set stones, worn smooth in the middle where boots land and mossy at the
    verge where they do not. The moss is `paint_faces`, so it costs nothing."""
    path_slab("terrain_path", "moss")
    rng = random.Random(seed)
    batch = Batch()
    pitch = MODULE / 8.0
    tones = ("stone", "stone_dark")
    for row in range(8):
        for column in range(8):
            x = -HALF + pitch * (column + 0.5) + rng.uniform(-0.022, 0.022)
            y = -HALF + pitch * (row + 0.5) + rng.uniform(-0.022, 0.022)
            # Big stones and small stones, not one stone eight times: the size
            # spread is what stops a paved road reading as a tiled floor.
            size = pitch * rng.uniform(0.32, 0.56)
            batch.blob(tones[(row * 3 + column * 5 + int(rng.random() * 2)) % 2],
                       (x, y, 0.040),
                       (size, size * rng.uniform(0.72, 1.0), rng.uniform(0.014, 0.028)), rng)
    batch.emit("cobble")


def build_path_corrupted(seed: int) -> None:
    """The road after the Mire has reached it: the surface is still a road, which
    is exactly why it is unsettling. Veins in the cracks, and the one emissive in
    this batch. Purple stays reserved for corruption (`mire_art` palette rule)."""
    path_slab("terrain_mire", "mire_black")
    rng = random.Random(seed)
    batch = Batch()
    for index, (angle, _radius) in enumerate(radial(5, 0.80, seed=seed, jitter=0.7)):
        x, y = math.cos(angle) * 0.86, math.sin(angle) * 0.86
        spine = [Vector((x, y, 0.034))]
        for step in range(3):
            factor = 1.0 - (step + 1) * 0.3
            spine.append(Vector((x * factor + rng.uniform(-0.10, 0.10),
                                 y * factor + rng.uniform(-0.10, 0.10), 0.034)))
        widths = [0.020, 0.016, 0.011, 0.007]
        batch.ribbon("mire_glow", spine, widths, [0.004] * 4)
    batch.emit("corrupt_vein")
    growth = Batch()
    for angle, radius in radial(4, 0.52, seed=seed + 6, jitter=0.9, radius_jitter=0.6):
        growth.blob("mire", (math.cos(angle) * radius, math.sin(angle) * radius, 0.046),
                    (rng.uniform(0.04, 0.075), rng.uniform(0.04, 0.07), rng.uniform(0.02, 0.04)),
                    rng)
    growth.emit("corrupt_growth")


# ── The boardwalk: A-010's plank, this kit's height ──────────────────────────


def sleepers(prefix: str, along: str = "x") -> None:
    """Two ground-laid bearers the deck sits on."""
    for index, offset in enumerate((-0.62, 0.62)):
        if along == "x":
            box(f"{prefix}_sleeper_{index}", (0.0, offset, 0.055), (MODULE, 0.16, 0.11),
                mat("wood_bark"))
        else:
            box(f"{prefix}_sleeper_{index}", (offset, 0.0, 0.055), (0.16, MODULE, 0.11),
                mat("wood_bark"))


def deck_boards(prefix: str, x_range: tuple[float, float], y_range: tuple[float, float],
                count: int, along: str = "y", skip: tuple[int, ...] = ()) -> None:
    """Boards filling their rectangle edge to edge, gaps only BETWEEN them — the
    A-010 fix for the seam that made every module short by half a gap (F-135)."""
    x0, x1 = x_range
    y0, y1 = y_range
    low, high = (x0, x1) if along == "y" else (y0, y1)
    pitch = (high - low) / count
    gap = 0.014
    for index in range(count):
        if index in skip:
            continue
        start = low + index * pitch + (gap * 0.5 if index > 0 else 0.0)
        end = low + (index + 1) * pitch - (gap * 0.5 if index < count - 1 else 0.0)
        centre, width = (start + end) * 0.5, end - start
        token = "wood_timber" if index % 2 == 0 else "wood_timber_light"
        if along == "y":
            box(f"{prefix}_board_{index}", (centre, (y0 + y1) * 0.5, BOARDWALK_Z - PLANK_T * 0.5),
                (width, y1 - y0, PLANK_T), mat(token))
        else:
            box(f"{prefix}_board_{index}", ((x0 + x1) * 0.5, centre, BOARDWALK_Z - PLANK_T * 0.5),
                (x1 - x0, width, PLANK_T), mat(token))


def build_boardwalk_straight(_seed: int) -> None:
    """One module of low walkway. Deck at BOARDWALK_Z, boards across the run."""
    sleepers("walk")
    deck_boards("walk", (-HALF, HALF), (-0.92, 0.92), 9, "y")
    for index, x in enumerate((-0.86, 0.86)):
        box(f"walk_kerb_{index}", (x, 0.0, BOARDWALK_Z + 0.012), (0.075, 1.84, 0.05),
            mat("wood_timber"))


def build_boardwalk_corner(_seed: int) -> None:
    """The turn. Boards mitre across the diagonal and the kerbs run the two outer
    edges, so which way it turns is readable from above and from the side."""
    sleepers("walk")
    box("walk_sleeper_2", (0.62, 0.0, 0.055), (0.16, MODULE, 0.11), mat("wood_bark"))
    deck_boards("walk", (-HALF, HALF), (-HALF, HALF), 9, "y")
    box("walk_mitre", (0.0, 0.0, BOARDWALK_Z + 0.006), (2.62, 0.10, 0.028),
        mat("wood_timber_light"), rotation=(0.0, 0.0, math.radians(-45.0)))
    box("walk_kerb_0", (0.955, 0.0, BOARDWALK_Z + 0.012), (0.075, MODULE, 0.05), mat("wood_timber"))
    box("walk_kerb_1", (0.0, -0.955, BOARDWALK_Z + 0.012), (MODULE, 0.075, 0.05), mat("wood_timber"))


def build_boardwalk_broken(seed: int) -> None:
    """Three boards gone and one hanging. What is under a boardwalk is the reason
    to care about the hole, so the sleepers stay and the gap shows them."""
    sleepers("walk")
    deck_boards("walk", (-HALF, HALF), (-0.92, 0.92), 9, "y", skip=(4, 5, 6))
    box("walk_hang", (0.24, 0.30, BOARDWALK_Z - 0.10), (0.19, 1.60, PLANK_T),
        mat("wood_timber"), rotation=(0.42, 0.0, 0.06))
    box("walk_kerb_0", (-0.86, 0.0, BOARDWALK_Z + 0.012), (0.075, 1.84, 0.05), mat("wood_timber"))
    box("walk_kerb_1", (0.86, -0.52, BOARDWALK_Z + 0.012), (0.075, 0.80, 0.05), mat("wood_timber"))
    rng = random.Random(seed)
    batch = Batch()
    for angle, radius in radial(4, 0.42, seed=seed, jitter=0.8, radius_jitter=0.5):
        batch.blob("wood_dead", (math.cos(angle) * radius, math.sin(angle) * radius, 0.03),
                   (rng.uniform(0.05, 0.12), rng.uniform(0.03, 0.06), 0.022), rng)
    batch.emit("walk_debris")


def build_boardwalk_stairs(_seed: int) -> None:
    """The piece that joins this kit to A-010's: it climbs from BOARDWALK_Z to
    A-010's DECK_Z over one module — 0.78 m over 2.00 m, 21.3 degrees, which the
    player's 46 degree floor limit accepts with room to spare (F-136)."""
    steps = 5
    rise = (DECK_Z - BOARDWALK_Z) / steps
    run = MODULE / steps
    for index in range(steps):
        top = BOARDWALK_Z + rise * (index + 1)
        x = -HALF + run * (index + 0.5)
        box(f"stair_tread_{index}", (x, 0.0, top - PLANK_T * 0.5), (run, 1.84, PLANK_T),
            mat("wood_timber" if index % 2 == 0 else "wood_timber_light"))
        box(f"stair_riser_{index}", (x - run * 0.5 + 0.03, 0.0, top - rise * 0.5),
            (0.055, 1.76, rise), mat("wood_bark"))
    for index, y in enumerate((-0.90, 0.90)):
        box(f"stair_stringer_{index}", (0.0, y, (BOARDWALK_Z + DECK_Z) * 0.5 - 0.10),
            (2.14, 0.09, 0.30), mat("wood_bark"),
            rotation=(0.0, -math.atan2(DECK_Z - BOARDWALK_Z, MODULE), 0.0))


def build_stepping_stones(seed: int) -> None:
    """Flat stones across one module of water or mud. Spaced for a stride, not
    for a hop: five stones over two metres is a stride each."""
    rng = random.Random(seed)
    for index in range(5):
        x = -HALF + MODULE * (index + 0.5) / 5.0
        y = math.sin(index * 1.7) * 0.26
        stone = hull(f"step_stone_{index}", (x, y, 0.055),
                     (rng.uniform(0.20, 0.27), rng.uniform(0.17, 0.24), 0.055),
                     mat("stone" if index % 2 == 0 else "stone_dark"),
                     seed=seed + index * 13, lumps=4, lump=0.10, sharpness=3.4,
                     flat_base=0.55, taper=0.18)
        paint_faces(stone, mat("moss"), min_normal_z=0.55, min_height=0.72,
                    coverage=0.45, seed=seed + index)


# ── Markers: the things that tell a player where ─────────────────────────────


def build_trail_marker(seed: int) -> None:
    """A cairn. The cheapest possible "somebody came this way", and the one
    marker that needs no carpentry at all."""
    rng = random.Random(seed)
    heights = (0.0, 0.16, 0.30, 0.42, 0.53, 0.62)
    for index, base in enumerate(heights):
        scale = 1.0 - index * 0.13
        stone = hull(f"cairn_stone_{index}", (rng.uniform(-0.03, 0.03), rng.uniform(-0.03, 0.03),
                                              base + 0.085 * scale),
                     (0.20 * scale, 0.17 * scale, 0.085 * scale),
                     mat("stone" if index % 2 == 0 else "stone_dark"),
                     seed=seed + index * 17, lumps=5, lump=0.13, sharpness=3.0, flat_base=0.42)
        if index >= 4:
            paint_faces(stone, mat("lichen"), min_normal_z=0.35, min_height=0.55,
                        coverage=0.55, seed=seed + index)


def build_rune_marker(seed: int) -> None:
    """A standing stone with a cut mark, lichen in the groove. Deliberately NOT
    teal and NOT purple: those two hues mean Ward and Mire, and a wayfinding
    stone that borrows either is telling the player something untrue."""
    stone = hull("rune_stone", (0.0, 0.0, 0.56), (0.24, 0.15, 0.56), mat("stone"),
                 seed=seed, lumps=5, lump=0.10, sharpness=3.2, taper=0.22, flat_base=0.30)
    paint_faces(stone, mat("lichen"), min_normal_z=0.10, min_height=0.62, coverage=0.42,
                seed=seed + 3)
    batch = Batch()
    strokes = (((-0.06, -0.16, 0.78), (0.06, -0.16, 0.60)),
               ((0.06, -0.16, 0.78), (-0.06, -0.16, 0.60)),
               ((0.0, -0.16, 0.86), (0.0, -0.16, 0.52)))
    for start, end in strokes:
        batch.ribbon("stone_dark", [Vector(start), Vector(end)], [0.018, 0.018], [0.010, 0.010])
    batch.emit("rune_cut")
    rng = random.Random(seed)
    base = Batch()
    for angle, radius in radial(5, 0.26, seed=seed + 5, jitter=0.8, radius_jitter=0.4):
        base.blob("stone_dark", (math.cos(angle) * radius, math.sin(angle) * radius, 0.045),
                  (rng.uniform(0.06, 0.10), rng.uniform(0.05, 0.09), 0.045), rng)
    base.emit("rune_base")


def build_warning_sign(seed: int) -> None:
    """A board nailed to a post with a mark daubed on it. The mark is `cloth_red`
    — the palette's only red — because a warning has to be the one thing on a
    grey road that is not the colour of the road."""
    cylinder_between("sign_post", (0.0, 0.0, 0.0), (0.02, 0.0, 1.26), POST_R,
                     mat("wood_bark"), 7, 0.90)
    box("sign_board", (0.0, -0.03, 1.06), (0.72, 0.055, 0.34), mat("wood_timber"),
        rotation=(0.0, 0.0, math.radians(-4.0)))
    for index, x in enumerate((-0.22, 0.22)):
        box(f"sign_nail_{index}", (x, -0.062, 1.06), (0.035, 0.02, 0.035), mat("iron_dark"))
    batch = Batch()
    daub = (((-0.16, -0.065, 1.18), (0.16, -0.065, 0.94)),
            ((0.16, -0.065, 1.18), (-0.16, -0.065, 0.94)))
    for start, end in daub:
        batch.ribbon("cloth_red", [Vector(start), Vector(end)], [0.028, 0.028], [0.004, 0.004])
    batch.emit("sign_daub")
    rng = random.Random(seed)
    heap = Batch()
    for angle, radius in radial(4, 0.20, seed=seed, jitter=0.8, radius_jitter=0.4):
        heap.blob("stone_dark", (math.cos(angle) * radius, math.sin(angle) * radius, 0.04),
                  (rng.uniform(0.05, 0.09), rng.uniform(0.05, 0.08), 0.04), rng)
    heap.emit("sign_heap")


def build_signpost(seed: int) -> None:
    """Three arms pointing three ways at head height, because a signpost a player
    has to look down at is a signpost they walk past."""
    cylinder_between("post_shaft", (0.0, 0.0, 0.0), (-0.02, 0.01, 1.92), POST_R * 1.15,
                     mat("wood_bark"), 7, 0.88)
    cone("post_cap", POST_R * 1.3, 0.02, 0.13, (-0.02, 0.01, 1.97), mat("wood_timber"), 7)
    arms = ((1.70, 0.0, 1.0), (1.44, math.radians(122.0), -1.0), (1.18, math.radians(-118.0), 1.0))
    for index, (height, spin, direction) in enumerate(arms):
        length = 0.62
        box(f"post_arm_{index}", (math.cos(spin) * length * 0.5 * direction,
                                  math.sin(spin) * length * 0.5 * direction, height),
            (length, 0.055, 0.17),
            mat("wood_timber" if index % 2 == 0 else "wood_timber_light"),
            rotation=(0.0, 0.0, spin))
        tip = Vector((math.cos(spin) * length * direction, math.sin(spin) * length * direction, height))
        cone(f"post_point_{index}", 0.085, 0.012, 0.14, tuple(tip), mat("wood_timber"), 4,
             (0.0, math.pi * 0.5, spin + (0.0 if direction > 0 else math.pi)))
        box(f"post_peg_{index}", (0.0, 0.0, height), (0.10, 0.10, 0.045), mat("iron_dark"))
    rng = random.Random(seed)
    heap = Batch()
    for angle, radius in radial(5, 0.24, seed=seed, jitter=0.8, radius_jitter=0.4):
        heap.blob("stone_dark", (math.cos(angle) * radius, math.sin(angle) * radius, 0.045),
                  (rng.uniform(0.06, 0.10), rng.uniform(0.05, 0.09), 0.045), rng)
    heap.emit("post_heap")


# ── Assembly ─────────────────────────────────────────────────────────────────


def join_into_one(name: str, made: list) -> bpy.types.Object:
    meshes = [obj for obj in made if obj.type == "MESH"]
    if len(meshes) <= 1:
        if meshes:
            meshes[0].name = name
        return meshes[0] if meshes else made[0]
    bpy.ops.object.select_all(action="DESELECT")
    for obj in meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.join()
    joined = bpy.context.view_layer.objects.active
    joined.name = name
    # Bake the rotation in: `join` inherits whichever rotation the first component
    # carried and the exporter writes it as a node transform, which put A-011's
    # resin node 53 mm underground when measured from mesh data.
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    bpy.ops.object.select_all(action="DESELECT")
    return joined


def floating_islands(objects: list, tolerance: float = 0.02) -> list[str]:
    adrift = []
    for obj in objects:
        if obj.type != "MESH":
            continue
        lowest = min((obj.matrix_world @ v.co).z for v in obj.data.vertices)
        if lowest > tolerance:
            adrift.append(f"{obj.name} @ {lowest * 1000:.0f} mm")
    return adrift


def create_asset(name: str, build_fn: Callable[[int], None], display_location) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)

    before = {obj.name for obj in bpy.data.objects}
    build_fn(seed_for(name))
    made = sorted((obj for obj in bpy.data.objects if obj.name not in before),
                  key=lambda obj: obj.name)

    prefixes = FRAMES.get(name)
    anchor = [obj for obj in made if obj.name.startswith(prefixes)] if prefixes else None
    anchor = anchor or None
    ground_and_centre(made, anchor=anchor)

    target, axis, _cap = SIZE[name]
    measured_on = anchor or made
    low, high = world_bounds(measured_on)
    current = (high.z - low.z) if axis == "height" else max(high.x - low.x, high.y - low.y)
    if current > 1e-6:
        factor = target / current
        for obj in made:
            if obj.parent is None:
                obj.scale = obj.scale * factor
                obj.location = obj.location * factor
        bpy.context.view_layer.update()
        for obj in made:
            bpy.context.view_layer.objects.active = obj
            obj.select_set(True)
        bpy.ops.object.transform_apply(location=True, rotation=False, scale=True)
        bpy.ops.object.select_all(action="DESELECT")
    ground_and_centre(made, anchor=anchor)
    glow, ghigh = world_bounds(measured_on)
    governed = (ghigh.z - glow.z) if axis == "height" else max(ghigh.x - glow.x, ghigh.y - glow.y)

    frame_bounds = None
    if anchor:
        alow, ahigh = world_bounds(anchor)
        frame_bounds = tuple(round(value, 6) for value in (*alow, *ahigh))

    surface_meshes = [obj for obj in made if obj.type == "MESH"
                      and obj.name.startswith(SURFACE_PREFIX.get(name, ("__none__",)))]
    surface_span = None
    if surface_meshes:
        slow, shigh = world_bounds(surface_meshes)
        surface_span = (round(shigh.x - slow.x, 6), round(shigh.y - slow.y, 6))

    made = [join_into_one(name, made)]
    for obj in made:
        for old in list(obj.users_collection):
            old.objects.unlink(obj)
        collection.objects.link(obj)
        obj.parent = root
    bpy.context.view_layer.update()

    adrift = floating_islands(made)
    corners = [obj.matrix_world @ vertex.co
               for obj in made if obj.type == "MESH" for vertex in obj.data.vertices]
    minimum = Vector((min(v.x for v in corners), min(v.y for v in corners),
                      min(v.z for v in corners)))
    maximum = Vector((max(v.x for v in corners), max(v.y for v in corners),
                      max(v.z for v in corners)))
    dimensions = maximum - minimum
    polygons = sum(len(obj.data.polygons) for obj in made if obj.type == "MESH")
    triangles = sum(sum(max(0, len(polygon.vertices) - 2) for polygon in obj.data.polygons)
                    for obj in made if obj.type == "MESH")
    materials = sorted({m.name for obj in made if obj.type == "MESH"
                        for m in obj.data.materials if m})

    bpy.ops.object.select_all(action="DESELECT")
    for obj in collection.objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = root
    bpy.ops.export_scene.gltf(filepath=str(EXPORT_DIR / f"{name}.glb"), export_format="GLB",
                              use_selection=True, export_apply=True, export_yup=True)
    root.location = display_location
    return {
        "name": name, "root": root,
        "width": dimensions.x, "depth": dimensions.y, "height": dimensions.z,
        "ground_offset": minimum.z, "target": target, "axis": axis, "adrift": adrift,
        "frame_bounds": frame_bounds, "governed": governed,
        "surface": surface_span,
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons, "triangles": triangles, "materials": materials,
    }


def check(records: list[dict]) -> list[str]:
    problems: list[str] = []
    by_name = {record["name"]: record for record in records}
    for record in records:
        name = record["name"]
        target, axis, cap = SIZE[name]
        if abs(record["governed"] - target) > SIZE_TOLERANCE:
            problems.append(f"{name}: {axis} {record['governed']:.3f} m vs target {target:.3f} m")
        footprint = min(record["width"], record["depth"]) if axis == "spread" \
            else max(record["width"], record["depth"])
        if footprint > cap:
            problems.append(
                f"{name}: {footprint:.3f} m {'deep' if axis == 'spread' else 'across'}, "
                f"footprint cap is {cap} m"
            )
        if abs(record["ground_offset"]) > 0.005:
            problems.append(f"{name}: sits {record['ground_offset'] * 1000:.1f} mm off the ground")
        if record["adrift"]:
            problems.append(f"{name}: floating geometry: {record['adrift'][:3]}")
        if name in RUN_SPAN:
            span_x, span_y = RUN_SPAN[name]
            surface = record["surface"]
            if surface is None:
                problems.append(f"{name}: no surface geometry, so its tiling cannot be measured")
            else:
                for axis_name, measured, wanted in (("run", surface[0], span_x),
                                                    ("width", surface[1], span_y)):
                    if wanted is not None and abs(measured - wanted) > 0.001:
                        problems.append(
                            f"{name}: surface {axis_name} is {measured:.4f} m, module is "
                            f"{wanted:.2f} — a run of these would show a seam"
                        )
        if record["parts"] == 0 or record["polygons"] == 0:
            problems.append(f"{name}: exported no geometry")
        budget = BUDGET_ALLOWANCE.get(name, TRIANGLE_BUDGET)
        if record["triangles"] > budget:
            problems.append(f"{name}: {record['triangles']} triangles over the {budget} budget")
        allowance = MATERIAL_ALLOWANCE.get(name, MAX_MATERIALS)
        if len(record["materials"]) > allowance:
            problems.append(f"{name}: {len(record['materials'])} materials, cap is {allowance}")
        if not (EXPORT_DIR / f"{name}.glb").exists():
            problems.append(f"{name}: no GLB written")

    for family, names in SIBLINGS.items():
        present = [by_name[n] for n in names if n in by_name]
        if len(present) != len(names):
            problems.append(f"{family}: only {len(present)} of {len(names)} siblings built")
            continue
        reference = present[0]
        for record in present[1:]:
            if record["frame_bounds"] != reference["frame_bounds"]:
                problems.append(
                    f"{family}: {record['name']}'s frame is not {reference['name']}'s frame"
                )
            if record["surface"] != reference["surface"]:
                problems.append(
                    f"{family}: {record['name']}'s surface is {record['surface']}, "
                    f"{reference['name']}'s is {reference['surface']} — a mixed run would not tile"
                )
    return problems


def frame_drift(records: list[dict]) -> float:
    by_name = {record["name"]: record for record in records}
    worst = 0.0
    for names in SIBLINGS.values():
        present = [by_name[n] for n in names if n in by_name and by_name[n]["frame_bounds"]]
        for record in present[1:]:
            worst = max(worst, max(abs(a - b) for a, b in
                                   zip(record["frame_bounds"], present[0]["frame_bounds"])))
    return worst




SPECS: list[tuple[str, Callable[[int], None]]] = [
    ("path_dirt", build_path_dirt),
    ("path_mud", build_path_mud),
    ("path_cobble", build_path_cobble),
    ("path_corrupted", build_path_corrupted),
    ("boardwalk_straight", build_boardwalk_straight),
    ("boardwalk_corner", build_boardwalk_corner),
    ("boardwalk_stairs", build_boardwalk_stairs),
    ("boardwalk_broken", build_boardwalk_broken),
    ("stepping_stones", build_stepping_stones),
    ("trail_marker", build_trail_marker),
    ("rune_marker", build_rune_marker),
    ("warning_sign", build_warning_sign),
    ("signpost", build_signpost),
]


def main() -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    reset_materials()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)

    if len({name for name, _ in SPECS}) != len(SPECS):
        raise RuntimeError("path asset names must be unique")
    for name, _ in SPECS:
        if name not in SIZE or name not in LAYOUT:
            raise RuntimeError(f"{name} has no SIZE or LAYOUT entry")

    records: list[dict] = []
    for name, builder in SPECS:
        x, row_y = LAYOUT[name]
        records.append(create_asset(name, builder, (x, row_y, 0.0)))

    problems = check(records)

    CATALOG_PATH.write_text(json.dumps({
        "batch": "A-014",
        "family": "paths",
        "blender": bpy.app.version_string,
        "module_m": MODULE,
        "deck_z_m": {"boardwalk": BOARDWALK_Z, "construction_kit": DECK_Z},
        "plank_thickness_m": PLANK_T,
        "run_span_m": {name: span for name, span in RUN_SPAN.items()},
        "frames": {family: list(names) for family, names in SIBLINGS.items()},
        "assets": [
            {
                "name": r["name"], "file": f"exports/{r['name']}.glb",
                "width_m": round(r["width"], 4), "depth_m": round(r["depth"], 4),
                "height_m": round(r["height"], 4), "target_m": r["target"], "axis": r["axis"],
                "frame": next((f for f, n in SIBLINGS.items() if r["name"] in n), None),
                "parts": r["parts"], "polygons": r["polygons"], "triangles": r["triangles"],
                "materials": r["materials"],
            }
            for r in records
        ],
    }, indent=2) + "\n")

    # -- previews: place once, aim the camera (F-204) -----------------------
    preview_collection = bpy.data.collections.new("Preview")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.object.light_add(type="SUN", location=(4.0, -6.0, 8.0))
    key = bpy.context.object
    key.data.energy = 4.0
    look_at(key, (0.0, 0.0, 0.0))
    bpy.ops.object.light_add(type="SUN", location=(-6.0, 4.0, 5.0))
    fill = bpy.context.object
    fill.data.energy = 1.4
    look_at(fill, (0.0, 0.0, 0.0))
    for light in (key, fill):
        for old in list(light.users_collection):
            old.objects.unlink(light)
        preview_collection.objects.link(light)

    bpy.ops.object.camera_add()
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    scene = bpy.context.scene
    scene.camera = camera
    scene.render.engine = eevee_engine()
    scene.render.resolution_x = 1900
    scene.render.resolution_y = 780
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.016, 0.021, 0.028)
    scene.view_settings.look = "AgX - Medium High Contrast"
    for old in list(camera.users_collection):
        old.objects.unlink(camera)
    preview_collection.objects.link(camera)

    # A 1.80 m reference in every sheet: furniture is judged against the person
    # who sits on it, and a bench that is only ever compared to a barrel is how a
    # kit ships at the wrong scale.
    bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0.90))
    figure = bpy.context.object
    figure.name = "Scale_Reference"
    figure.scale = (0.20, 0.13, 0.90)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    figure.data.materials.append(mat("reference_blue"))
    for old in list(figure.users_collection):
        old.objects.unlink(figure)
    preview_collection.objects.link(figure)

    def set_visible(record: dict, visible: bool) -> None:
        record["root"].hide_render = not visible
        for child in record["root"].children_recursive:
            child.hide_render = not visible

    for filename, row_y, left, half_width, eye_z, target_z, names in SHEETS:
        for record in records:
            set_visible(record, record["name"] in names)
        figure.location = (left - 0.30, row_y, 0.90)
        centre_x = left + half_width - 0.30
        camera.data.type = "ORTHO"
        camera.data.ortho_scale = half_width * 2.0 + 1.40
        camera.location = (centre_x, row_y - 9.0, eye_z)
        look_at(camera, (centre_x, row_y, target_z))
        scene.render.filepath = str(PREVIEW_DIR / filename)
        bpy.ops.render.render(write_still=True)

    for record in records:
        set_visible(record, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_PATH))

    print(f"\nPATH_BUILD assets={len(records)} "
          f"triangles={sum(r['triangles'] for r in records)} blender={bpy.app.version_string}")
    for record in records:
        print("  %-16s %5.2f x %5.2f x %5.2f m  %4d tris  %d mats  %s"
              % (record["name"], record["width"], record["depth"], record["height"],
                 record["triangles"], len(record["materials"]),
                 ",".join(m.replace("MIRE_", "") for m in record["materials"])))
    print("  worst frame drift: %.4f mm" % (frame_drift(records) * 1000.0))
    if problems:
        print(f"\nPATH_CHECK FAIL ({len(problems)})")
        for problem in problems:
            print(f"  {problem}")
        raise SystemExit(1)
    print("PATH_CHECK PASS")


if __name__ == "__main__":
    main()
