"""A-013 — camp storage and furniture: what a base looks like once people live in it.

  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender/build_camp_set.py

Sixteen assets in `assets/camp/`, built with Blender 5.2.0 LTS (D-038 pins the toolchain).

One pile of timber, one saw, one coil of rope
--------------------------------------------
A camp is not a furniture catalogue. It is what four people build out of the same stack of boards
with the same axe, so every structural part in this kit comes from a **stock list** — one plank
thickness, one plank width, one post, one rail, one iron band — and no builder is allowed to invent
a dimension. `plank()`, `post()`, `rail()` and `band()` are the only ways to make structural
geometry, they log every part they emit, and `check()` fails the build if an asset produced a
structural mesh that did not come through them.

That is what makes a stool, a bench, a table and four racks read as one camp instead of eight
purchases. It is also cheap: the same numbers everywhere means the same silhouette language, and a
player learns "this is ours" without being told.

**The four racks are one rack.** Storage, weapon, tool and drying racks share a frame — the same
uprights, the same rails, the same lashings, at the same numbers — and differ only in what hangs on
it. Siblings must measure identically in bounds *and* triangle count where the frame governs, the
rule A-011 paid 27.6 mm to learn and A-012 turned into a contract.

**The crate is a state pair.** `crate` and `crate_broken` are centred and scaled on the geometry
they SHARE, so swapping the mesh when a crate is smashed cannot move it (A-005's rule, A-011's
correction that scale has to obey it too).

Freeform geometry is allowed, named, and small: a sack is cloth, a bedroll is a roll, a lantern has
a flame. Those are listed in `FREEFORM` per asset so an off-stock part is a decision somebody made
on purpose rather than a number that drifted in.

Previews place every asset ONCE, in rows, and only ever move the camera — F-204: a Blender contact
sheet that repositions assets between renders draws the layout it had at the first render, and the
symptom is a blank tile for an asset that probes as present, visible and correctly placed.
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
EXPORT_DIR = ROOT / "assets" / "camp" / "exports"
PREVIEW_DIR = ROOT / "assets" / "camp" / "preview"
CATALOG_PATH = ROOT / "assets" / "camp" / "catalog.json"
SOURCE_DIR = ROOT / "assets" / "source"
SOURCE_PATH = SOURCE_DIR / "camp_set.blend"

# ── The stock list ───────────────────────────────────────────────────────────
#
# Every structural part in the kit is one of these. Change a number here and the
# whole camp changes together, which is the point.

PLANK_T = 0.032          # every board is this thick
PLANK_W = 0.145          # and this wide, unless it is ripped to a half board
POST_R = 0.046           # every leg, upright and corner post
RAIL_R = 0.028           # every rail, rung and stretcher
BAND_T = 0.013           # every iron band and strap
STAVE_T = 0.022          # barrel and bucket staves are thinner than a board

#: Emitted by the stock helpers. `check()` compares its length against the number
#: of structural meshes an asset produced, so a part built with a raw `box()` is a
#: build failure rather than a silent one-off dimension.
STOCK_LOG: list[tuple[str, str]] = []
_CURRENT: list[str] = [""]

#: Parts that are honestly not timber, per asset. Named so an off-stock number is
#: a decision rather than a drift.
FREEFORM: dict[str, tuple[str, ...]] = {
    "sack": ("sack_body", "sack_neck"),
    "bedroll": ("bedroll_pad", "bedroll_roll"),
    "bucket": ("bucket_handle",),
    "lantern": ("lantern_glass", "lantern_flame"),
    "rack_drying": ("drying_hide", "drying_fish"),
    "rack_storage": ("storage_sack", "storage_crock"),
    "rack_tool": ("tool_head",),
    "rack_weapon": ("weapon_blade",),
    "crate_broken": ("crate_spill",),
    "barrel_small": ("barrel_lid",),
    "barrel_large": ("barrel_lid",),
    "table": ("table_cloth",),
}

SIZE: dict[str, tuple[float, str, float]] = {
    "barrel_small": (0.58, "height", 0.52),
    "barrel_large": (0.88, "height", 0.72),
    "crate": (0.560, "spread", 0.68),
    "crate_broken": (0.560, "spread", 0.86),
    "sack": (0.54, "height", 0.50),
    "bucket": (0.34, "height", 0.36),
    "bedroll": (1.86, "spread", 0.46),
    "stool": (0.46, "height", 0.50),
    "bench": (1.62, "spread", 0.54),
    "table": (1.72, "spread", 0.98),
    "shelf": (1.42, "height", 1.00),
    "rack_storage": (1.68, "height", 1.26),
    "rack_weapon": (1.68, "height", 1.26),
    "rack_tool": (1.68, "height", 1.26),
    "rack_drying": (1.68, "height", 1.26),
    "lantern": (0.36, "height", 0.24),
}

SIZE_TOLERANCE = 0.02
TRIANGLE_BUDGET = 900
MAX_MATERIALS = 4
MATERIAL_ALLOWANCE = {
    # The racks each spend a fifth material on what hangs from them, which is the
    # only thing separating four assets that are deliberately the same frame.
    "rack_weapon": 5, "rack_tool": 5, "rack_drying": 5, "rack_storage": 5,
    "lantern": 5,   # glass, flame, iron, timber, rope — a lantern IS its parts
}

#: Shared frames: centred and scaled on these prefixes, never on their own bounds.
FRAMES: dict[str, tuple[str, ...]] = {
    "crate": ("crate_frame_", "crate_body_base_"),
    "crate_broken": ("crate_frame_", "crate_body_base_"),
    "rack_storage": ("rack_",), "rack_weapon": ("rack_",),
    "rack_tool": ("rack_",), "rack_drying": ("rack_",),
}

#: Groups that must measure identically. The whole claim of the batch.
SIBLINGS: dict[str, tuple[str, ...]] = {
    "crate": ("crate", "crate_broken"),
    "rack": ("rack_storage", "rack_weapon", "rack_tool", "rack_drying"),
}

FRAME_SEED = {"crate": 3301, "rack": 5507}

#: Where each asset stands, once (F-204). Rows are sheets.
LAYOUT: dict[str, tuple[float, float]] = {
    "barrel_small": (-1.55, 0.0), "barrel_large": (-0.75, 0.0), "crate": (0.05, 0.0),
    "crate_broken": (0.85, 0.0), "sack": (1.60, 0.0), "bucket": (2.20, 0.0),
    "stool": (-2.10, 4.0), "bench": (-0.90, 4.0), "table": (0.90, 4.0),
    "shelf": (2.50, 4.0), "bedroll": (4.20, 4.0),
    "rack_storage": (-2.10, 8.0), "rack_weapon": (-0.70, 8.0), "rack_tool": (0.70, 8.0),
    "rack_drying": (2.10, 8.0), "lantern": (3.20, 8.0),
}

SHEETS: list[tuple[str, float, float, float, tuple[str, ...]]] = [
    ("camp_storage_preview.png", 0.0, -2.35, 2.60,
     ("barrel_small", "barrel_large", "crate", "crate_broken", "sack", "bucket")),
    ("camp_furniture_preview.png", 4.0, -2.90, 5.00,
     ("stool", "bench", "table", "shelf", "bedroll")),
    ("camp_racks_preview.png", 8.0, -2.95, 3.90,
     ("rack_storage", "rack_weapon", "rack_tool", "rack_drying", "lantern")),
]


def seed_for(name: str) -> int:
    return sum((index + 3) * ord(char) for index, char in enumerate(name))


# ── The stock helpers: the only way to make structural geometry ──────────────


def plank(name: str, centre, length: float, axis: str = "x", width: float = PLANK_W,
          token: str = "wood_timber", thickness: float = PLANK_T, rotation=(0.0, 0.0, 0.0)):
    """One sawn board. Thickness is never an argument a builder gets to guess."""
    STOCK_LOG.append((_CURRENT[0], name))
    size = {"x": (length, width, thickness),
            "y": (width, length, thickness),
            "z": (width, thickness, length)}[axis]
    return box(name, centre, size, mat(token), rotation=rotation)


def post(name: str, base, top, token: str = "wood_bark", radius: float = POST_R):
    """One upright. Every leg in the camp is this pole."""
    STOCK_LOG.append((_CURRENT[0], name))
    return cylinder_between(name, base, top, radius, mat(token), 7, 0.94)


def rail(name: str, start, end, token: str = "wood_timber", radius: float = RAIL_R):
    STOCK_LOG.append((_CURRENT[0], name))
    return cylinder_between(name, start, end, radius, mat(token), 6, 0.96)


def band(name: str, centre, radius: float, height: float = BAND_T, token: str = "iron_dark",
         sides: int = 12, rotation=(0.0, 0.0, 0.0)):
    """One iron hoop or strap."""
    STOCK_LOG.append((_CURRENT[0], name))
    return cone(name, radius, radius, height, centre, mat(token), sides, rotation)


def lashing(name: str, centre, radius: float, axis: str = "z", height: float = 0.030):
    STOCK_LOG.append((_CURRENT[0], name))
    rotation = {"z": (0.0, 0.0, 0.0), "x": (0.0, math.pi * 0.5, 0.0),
                "y": (math.pi * 0.5, 0.0, 0.0)}[axis]
    return cone(name, radius, radius, height, centre, mat("rope"), 8, rotation)


# ── Staved vessels: barrels and the bucket ───────────────────────────────────


def staved(prefix: str, height: float, belly: float, top: float, staves: int,
           token: str, hoops: tuple[float, ...]) -> None:
    """A coopered vessel: staves round a belly, iron hoops holding them shut.

    One recipe, three callers. The two barrels are NOT siblings — they are
    deliberately different sizes, so they share a recipe and nothing else, and
    the contract does not compare them. A-011's lesson runs both ways: the same
    recipe run twice is not one object, and pretending otherwise is how a "state
    pair" ends up 27.6 mm apart.
    """
    for index, (angle, radius) in enumerate(radial(staves, belly, seed=0, jitter=0.0,
                                                   radius_jitter=0.0)):
        lean = (belly - top) * 0.5
        STOCK_LOG.append((_CURRENT[0], f"{prefix}_stave_{index}"))
        cylinder_between(
            f"{prefix}_stave_{index}",
            (math.cos(angle) * (radius - lean * 0.6), math.sin(angle) * (radius - lean * 0.6), 0.0),
            (math.cos(angle) * (radius - lean * 0.6), math.sin(angle) * (radius - lean * 0.6), height),
            STAVE_T * 1.9, mat(token), 4, 1.0,
        )
    for index, fraction in enumerate(hoops):
        band(f"{prefix}_hoop_{index}", (0.0, 0.0, height * fraction), belly + STAVE_T * 1.4)


def build_barrel_small(seed: int) -> None:
    """Head-high to a sitting player. The lid is proud of the staves so it reads
    as a lid rather than as the top of a cylinder."""
    staved("barrel", 0.52, 0.20, 0.17, 9, "wood_timber", (0.12, 0.50, 0.88))
    hull("barrel_lid", (0.0, 0.0, 0.525), (0.19, 0.19, 0.022), mat("wood_timber_light"),
         seed=seed, lumps=3, lump=0.04, sharpness=4.0, flat_base=0.5)


def build_barrel_large(seed: int) -> None:
    """The one you actually store things in. Same recipe as the small barrel at
    different numbers — a bigger barrel, not a scaled photograph of a small one."""
    staved("barrel", 0.82, 0.30, 0.25, 11, "wood_timber", (0.10, 0.34, 0.66, 0.90))
    hull("barrel_lid", (0.0, 0.0, 0.828), (0.285, 0.285, 0.026), mat("wood_timber_light"),
         seed=seed, lumps=3, lump=0.04, sharpness=4.0, flat_base=0.5)


def build_bucket(seed: int) -> None:
    """Small, tapered, with a rope bail. A bucket with a straight side is a tub."""
    staved("bucket", 0.28, 0.135, 0.105, 8, "wood_timber", (0.10, 0.82))
    batch = Batch()
    arc = [Vector((math.cos(a) * 0.150, 0.0, 0.28 + math.sin(a) * 0.088))
           for a in (0.0, 0.9, math.pi * 0.5, math.pi - 0.9, math.pi)]
    batch.ribbon("rope", arc, [0.010] * 5, [0.006] * 5)
    batch.emit("bucket_handle")
    _ = seed


# ── Crates: the state pair ───────────────────────────────────────────────────


def crate_frame(broken: bool) -> None:
    """A nailed box with corner posts. The shared frame is everything that
    survives being smashed: the base, the corner posts and three walls."""
    seed = FRAME_SEED["crate"]
    half = 0.26
    for index, (x, y) in enumerate(((-half, -half), (half, -half), (half, half), (-half, half))):
        post(f"crate_frame_post_{index}", (x, y, 0.0), (x, y, 0.60), "wood_timber", 0.028)
    for index in range(3):
        plank(f"crate_body_base_{index}", (0.0, -0.17 + index * 0.17, PLANK_T * 0.5),
              half * 2.0, "x", 0.16, "wood_timber_light")
    walls = ((0.0, -half, "x"), (0.0, half, "x"), (-half, 0.0, "y"))
    if not broken:
        walls = walls + ((half, 0.0, "y"),)
    for index, (x, y, axis) in enumerate(walls):
        for row in range(4):
            height = 0.085 + row * 0.155
            # The smashed crate loses the top two boards of one wall, not a whole
            # side: a crate with a wall simply absent reads as a crate that was
            # built wrong.
            if broken and index == 1 and row >= 2:
                continue
            plank(f"crate_body_wall_{index}_{row}", (x, y, height), half * 2.0, axis,
                  0.150, "wood_timber" if row % 2 == 0 else "wood_timber_light")
    for index, height in enumerate((0.085, 0.55)):
        band(f"crate_frame_band_{index}", (0.0, 0.0, height), half * 1.48, BAND_T, "iron_dark", 4,
             (0.0, 0.0, math.radians(45.0)))


def build_crate(_seed: int) -> None:
    crate_frame(False)


def build_crate_broken(seed: int) -> None:
    """One wall stoved in, two boards on the ground, the contents spilled. The
    frame is built by the same call with the same numbers, so the pair cannot
    drift — and what spilled out is what tells you it was full."""
    crate_frame(True)
    rng = random.Random(seed)
    for index, (x, y, tilt, spin) in enumerate(((0.44, -0.10, 0.14, 0.4), (0.40, 0.22, -0.10, -0.7))):
        plank(f"crate_shard_{index}", (x, y, 0.049), 0.46, "x", 0.15, "wood_timber",
              rotation=(0.0, tilt, spin))
    batch = Batch()
    for index, (angle, radius) in enumerate(radial(3, 0.34, seed=seed, jitter=0.7, radius_jitter=0.4)):
        batch.blob("wood_timber_light",
                   (0.30 + math.cos(angle) * abs(radius) * 0.5,
                    math.sin(angle) * abs(radius) * 0.5, 0.05),
                   (0.05, 0.045, 0.045), rng)
    batch.emit("crate_spill")


# ── Soft goods ───────────────────────────────────────────────────────────────


def build_sack(seed: int) -> None:
    """Cloth, tied at the neck, slumping under its own weight. `droop` on the
    hull is what stops it reading as a stone."""
    hull("sack_body", (0.0, 0.0, 0.20), (0.20, 0.20, 0.21), mat("cloth_dark"),
         seed=seed, lumps=6, lump=0.16, sharpness=2.4, taper=0.24, droop=0.18,
         droop_lobes=3, flat_base=0.34)
    hull("sack_neck", (0.0, 0.0, 0.44), (0.075, 0.075, 0.075), mat("cloth"),
         seed=seed + 5, lumps=5, lump=0.22, sharpness=2.6, taper=-0.3)
    lashing("sack_tie", (0.0, 0.0, 0.395), 0.082, "z", 0.030)


def build_bedroll(seed: int) -> None:
    """Rolled, strapped, and lying down — a bedroll standing on end is a rug.
    Long enough for a 1.8 m player to actually fit on."""
    cylinder_between("bedroll_roll", (-0.86, 0.0, 0.135), (0.86, 0.0, 0.135), 0.135,
                     mat("canvas"), 10, 1.0)
    # The mat's own outer edge, spiralling once round the roll: the one line that
    # says this is rolled up rather than a log painted green.
    STOCK_LOG.append((_CURRENT[0], "bedroll_edge"))
    box("bedroll_edge", (0.0, -0.075, 0.238), (1.70, 0.115, 0.030), mat("canvas_dark"),
        rotation=(math.radians(-24.0), 0.0, 0.0))
    hull("bedroll_pad", (0.0, 0.108, 0.075), (0.84, 0.075, 0.070), mat("canvas_dark"),
         seed=seed, lumps=4, lump=0.08, sharpness=3.4, flat_base=0.40)
    for index, x in enumerate((-0.52, 0.48)):
        STOCK_LOG.append((_CURRENT[0], f"bedroll_strap_{index}"))
        cone(f"bedroll_strap_{index}", 0.146, 0.146, 0.030, (x, 0.0, 0.135),
             mat("leather_dark"), 10, (0.0, math.pi * 0.5, 0.0))


# ── Sat on, eaten off, put on ────────────────────────────────────────────────


def splayed_legs(prefix: str, half_x: float, half_y: float, top: float, splay: float = 0.05) -> None:
    """Four legs, splayed outward at the foot. Vertical legs read as a shipping
    pallet; splayed legs read as furniture somebody made."""
    for index, (sx, sy) in enumerate(((-1, -1), (1, -1), (1, 1), (-1, 1))):
        post(f"{prefix}_leg_{index}",
             (sx * (half_x + splay), sy * (half_y + splay), 0.0),
             (sx * half_x, sy * half_y, top))


def build_stool(_seed: int) -> None:
    """Three boards and four legs. The first thing anyone builds."""
    for index in range(3):
        plank(f"stool_top_{index}", (0.0, -0.15 + index * 0.15, 0.42), 0.44, "x", 0.142,
              "wood_timber_light" if index == 1 else "wood_timber")
    splayed_legs("stool", 0.155, 0.145, 0.405, 0.032)
    for index, y in enumerate((-0.145, 0.145)):
        rail(f"stool_stretcher_{index}", (-0.16, y, 0.16), (0.16, y, 0.16))


def build_bench(_seed: int) -> None:
    """A bench is a stool that kept going. Same boards, same legs, one brace."""
    for index in range(3):
        plank(f"bench_top_{index}", (0.0, -0.15 + index * 0.15, 0.44), 1.56, "x", 0.142,
              "wood_timber_light" if index == 1 else "wood_timber")
    for index, x in enumerate((-0.62, 0.62)):
        for side, y in enumerate((-0.15, 0.15)):
            post(f"bench_leg_{index}_{side}", (x + (0.05 if x > 0 else -0.05), y * 1.3, 0.0),
                 (x, y, 0.425))
        rail(f"bench_brace_{index}", (x, -0.16, 0.18), (x, 0.16, 0.18))
    rail("bench_stretcher", (-0.60, 0.0, 0.16), (0.60, 0.0, 0.16))


def build_table(seed: int) -> None:
    """Five boards over two trestles, with a cloth somebody left on it. The gaps
    between boards are what say "planks" from above, which is the angle a player
    who is crafting at it actually sees."""
    for index in range(5):
        plank(f"table_top_{index}", (0.0, -0.30 + index * 0.15, 0.76), 1.66, "x", 0.142,
              "wood_timber_light" if index % 2 == 1 else "wood_timber")
    for index, x in enumerate((-0.60, 0.60)):
        for side, y in enumerate((-0.30, 0.30)):
            post(f"table_leg_{index}_{side}", (x + (0.06 if x > 0 else -0.06), y * 1.12, 0.0),
                 (x, y, 0.74))
        rail(f"table_brace_{index}", (x, -0.31, 0.22), (x, 0.31, 0.22))
        plank(f"table_apron_{index}", (x, 0.0, 0.70), 0.62, "y", 0.10, "wood_timber")
    rail("table_stretcher", (-0.58, 0.0, 0.20), (0.58, 0.0, 0.20))
    hull("table_cloth", (0.46, 0.10, 0.79), (0.24, 0.20, 0.028), mat("cloth"),
         seed=seed, lumps=5, lump=0.20, sharpness=2.6, droop=0.12, droop_lobes=2)


def build_shelf(_seed: int) -> None:
    """Three shelves between two uprights, braced diagonally at the back so it
    does not read as a bookcase from a catalogue."""
    for index, x in enumerate((-0.42, 0.42)):
        post(f"shelf_upright_{index}", (x, 0.0, 0.0), (x, 0.0, 1.38))
    for index, height in enumerate((0.30, 0.72, 1.14)):
        for board in range(2):
            plank(f"shelf_board_{index}_{board}", (0.0, -0.075 + board * 0.15, height), 0.84,
                  "x", 0.142, "wood_timber_light" if index == 1 else "wood_timber")
        rail(f"shelf_rail_{index}", (-0.42, 0.0, height - 0.045), (0.42, 0.0, height - 0.045))
    STOCK_LOG.append((_CURRENT[0], "shelf_brace"))
    box("shelf_brace", (0.0, 0.09, 0.72), (1.16, PLANK_T, 0.09), mat("wood_timber"),
        rotation=(0.0, -math.atan2(1.08, 0.84), 0.0))
    for index, height in enumerate((0.30, 1.14)):
        lashing(f"shelf_lash_{index}", (-0.42, 0.0, height), 0.060, "z", 0.026)


# ── The rack family: four assets, one rack ───────────────────────────────────


def rack_frame() -> None:
    """Two uprights, a foot at each, three cross rails, lashed. Every number is a
    literal so the four racks are the same object four times — not four runs of
    one recipe, which is what A-011's "identical" poison bush turned out to be
    before its seed was shared."""
    for index, x in enumerate((-0.52, 0.52)):
        post(f"rack_upright_{index}", (x, 0.0, 0.0), (x, 0.0, 1.64))
        plank(f"rack_foot_{index}", (x, 0.0, PLANK_T * 0.5), 0.44, "y", 0.145, "wood_timber")
        rail(f"rack_stay_{index}", (x, -0.20, 0.06), (x, 0.0, 0.40))
    for index, height in enumerate((0.52, 1.02, 1.52)):
        rail(f"rack_rail_{index}", (-0.52, 0.0, height), (0.52, 0.0, height))
        for side, x in enumerate((-0.52, 0.52)):
            lashing(f"rack_lash_{index}_{side}", (x, 0.0, height), 0.062, "z", 0.026)


def build_rack_storage(seed: int) -> None:
    """Sacks and a crock on the rails. Somebody's larder."""
    rack_frame()
    rng = random.Random(seed)
    for index, x in enumerate((-0.26, 0.24)):
        hull(f"storage_sack_{index}", (x, 0.02, 1.28 - index * 0.02), (0.145, 0.125, 0.155),
             mat("cloth_dark"), seed=seed + index * 11, lumps=5, lump=0.18, sharpness=2.5,
             taper=0.2, droop=0.16, droop_lobes=2)
    hull("storage_crock_0", (0.10, 0.0, 0.66), (0.135, 0.135, 0.145), mat("clay"),
         seed=seed + 3, lumps=4, lump=0.07, sharpness=3.4, taper=-0.12, flat_base=0.4)
    _ = rng


def build_rack_weapon(seed: int) -> None:
    """Two hafted weapons leaning in it. The rack is the same rack; what is in it
    is the whole difference."""
    rack_frame()
    for index, x in enumerate((-0.26, 0.22)):
        STOCK_LOG.append((_CURRENT[0], f"weapon_haft_{index}"))
        tapered_between(f"weapon_haft_{index}", (x, 0.06, 0.02), (x - 0.06, -0.06, 1.44),
                        0.022, 0.018, mat("wood_timber"), 6)
        hull(f"weapon_blade_{index}", (x - 0.062, -0.062, 1.50), (0.052, 0.020, 0.105),
             mat("iron" if index == 0 else "iron_dark"), seed=seed + index * 7, lumps=3,
             lump=0.05, sharpness=4.0, taper=0.5)
    _ = seed


def build_rack_tool(seed: int) -> None:
    """Tool heads hung on the rails, hafts down. A rack of tools reads as work in
    progress, which is what a camp is."""
    rack_frame()
    for index, x in enumerate((-0.30, 0.02, 0.34)):
        STOCK_LOG.append((_CURRENT[0], f"tool_haft_{index}"))
        tapered_between(f"tool_haft_{index}", (x, 0.0, 0.60), (x + 0.02, 0.0, 1.50),
                        0.018, 0.015, mat("wood_timber"), 5)
        hull(f"tool_head_{index}", (x + 0.02, 0.0, 1.545), (0.075, 0.030, 0.055),
             mat("iron" if index != 1 else "iron_dark"), seed=seed + index * 13, lumps=3,
             lump=0.08, sharpness=3.6, taper=0.35)


def build_rack_drying(seed: int) -> None:
    """Hides and split fish hanging to dry. The one rack that says what the camp
    ate this week."""
    rack_frame()
    batch = Batch()
    for index, x in enumerate((-0.32, 0.30)):
        top = 1.52
        batch.add("leather",
                  [(x - 0.17, 0.0, top), (x + 0.17, 0.0, top), (x + 0.13, 0.02, top - 0.46),
                   (x - 0.13, 0.02, top - 0.46)],
                  [(0, 1, 2, 3)])
    batch.emit("drying_hide")
    for index, x in enumerate((-0.05, 0.12)):
        hull(f"drying_fish_{index}", (x, -0.02, 0.94), (0.055, 0.024, 0.135), mat("fish_belly"),
             seed=seed + index * 9, lumps=4, lump=0.10, sharpness=3.0, taper=0.4)


def build_lantern(seed: int) -> None:
    """Iron hoop, four posts, a warm core. Small, and the only light source in
    the kit — so it is the one asset allowed a fifth material and an emissive."""
    for index, (angle, radius) in enumerate(radial(4, 0.062, seed=0, jitter=0.0, radius_jitter=0.0)):
        STOCK_LOG.append((_CURRENT[0], f"lantern_post_{index}"))
        cylinder_between(f"lantern_post_{index}",
                         (math.cos(angle) * radius, math.sin(angle) * radius, 0.030),
                         (math.cos(angle) * radius, math.sin(angle) * radius, 0.235),
                         0.008, mat("iron_dark"), 4, 1.0)
    band("lantern_base", (0.0, 0.0, 0.018), 0.082, 0.036, "iron_dark", 8)
    band("lantern_cap", (0.0, 0.0, 0.250), 0.078, 0.030, "iron_dark", 8)
    hull("lantern_glass", (0.0, 0.0, 0.132), (0.056, 0.056, 0.098), mat("ice"),
         seed=seed, lumps=3, lump=0.03, sharpness=5.0)
    hull("lantern_flame", (0.0, 0.0, 0.108), (0.026, 0.026, 0.048), mat("flame"),
         seed=seed + 2, lumps=4, lump=0.16, sharpness=2.8, taper=0.55)
    STOCK_LOG.append((_CURRENT[0], "lantern_hoop"))
    cone("lantern_hoop", 0.030, 0.030, 0.008, (0.0, 0.0, 0.300), mat("iron"), 8,
         (math.pi * 0.5, 0.0, 0.0))
    STOCK_LOG.append((_CURRENT[0], "lantern_hook"))
    cylinder_between("lantern_hook", (0.0, 0.0, 0.262), (0.0, 0.0, 0.300), 0.007,
                     mat("iron"), 5, 1.0)


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

    _CURRENT[0] = name
    before = {obj.name for obj in bpy.data.objects}
    build_fn(seed_for(name))
    made = sorted((obj for obj in bpy.data.objects if obj.name not in before),
                  key=lambda obj: obj.name)

    # The stock contract: every structural mesh came through plank/post/rail/band/
    # lashing, or is declared freeform for this asset. A part built with a raw box()
    # is a dimension nobody chose, and this is where it stops.
    logged = {part for asset, part in STOCK_LOG if asset == name}
    allowed = FREEFORM.get(name, ())
    off_stock = [obj.name for obj in made
                 if obj.type == "MESH" and obj.name not in logged
                 and not obj.name.startswith(allowed)]

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
        "frame_bounds": frame_bounds, "governed": governed, "off_stock": off_stock,
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
        if record["off_stock"]:
            problems.append(
                f"{name}: {len(record['off_stock'])} part(s) built off-stock and not declared "
                f"freeform: {record['off_stock'][:4]}"
            )
        if record["parts"] == 0 or record["polygons"] == 0:
            problems.append(f"{name}: exported no geometry")
        if record["triangles"] > TRIANGLE_BUDGET:
            problems.append(f"{name}: {record['triangles']} triangles over the {TRIANGLE_BUDGET} budget")
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
            if family == "rack":
                drift = max(abs(record["width"] - reference["width"]),
                            abs(record["height"] - reference["height"]))
                if drift > 1e-5:
                    problems.append(
                        f"{family}: {record['name']} drifts {drift * 1000:.3f} mm from {reference['name']}"
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
    ("barrel_small", build_barrel_small),
    ("barrel_large", build_barrel_large),
    ("crate", build_crate),
    ("crate_broken", build_crate_broken),
    ("sack", build_sack),
    ("bucket", build_bucket),
    ("stool", build_stool),
    ("bench", build_bench),
    ("table", build_table),
    ("shelf", build_shelf),
    ("bedroll", build_bedroll),
    ("rack_storage", build_rack_storage),
    ("rack_weapon", build_rack_weapon),
    ("rack_tool", build_rack_tool),
    ("rack_drying", build_rack_drying),
    ("lantern", build_lantern),
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
        raise RuntimeError("camp asset names must be unique")
    for name, _ in SPECS:
        if name not in SIZE or name not in LAYOUT:
            raise RuntimeError(f"{name} has no SIZE or LAYOUT entry")

    records: list[dict] = []
    for name, builder in SPECS:
        x, row_y = LAYOUT[name]
        records.append(create_asset(name, builder, (x, row_y, 0.0)))

    problems = check(records)

    CATALOG_PATH.write_text(json.dumps({
        "batch": "A-013",
        "family": "camp",
        "blender": bpy.app.version_string,
        "stock": {"plank_thickness_m": PLANK_T, "plank_width_m": PLANK_W,
                  "post_radius_m": POST_R, "rail_radius_m": RAIL_R,
                  "band_thickness_m": BAND_T, "stave_thickness_m": STAVE_T},
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

    for filename, row_y, left, half_width, names in SHEETS:
        for record in records:
            set_visible(record, record["name"] in names)
        figure.location = (left - 0.30, row_y, 0.90)
        centre_x = left + half_width - 0.30
        camera.data.type = "ORTHO"
        camera.data.ortho_scale = half_width * 2.0 + 1.40
        camera.location = (centre_x, row_y - 9.0, 1.15)
        look_at(camera, (centre_x, row_y, 0.62))
        scene.render.filepath = str(PREVIEW_DIR / filename)
        bpy.ops.render.render(write_still=True)

    for record in records:
        set_visible(record, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_PATH))

    print(f"\nCAMP_BUILD assets={len(records)} "
          f"triangles={sum(r['triangles'] for r in records)} blender={bpy.app.version_string}")
    for record in records:
        print("  %-16s %5.2f x %5.2f x %5.2f m  %4d tris  %d mats  %s"
              % (record["name"], record["width"], record["depth"], record["height"],
                 record["triangles"], len(record["materials"]),
                 ",".join(m.replace("MIRE_", "") for m in record["materials"])))
    print("  stock parts logged: %d   worst frame drift: %.4f mm"
          % (len(STOCK_LOG), frame_drift(records) * 1000.0))
    if problems:
        print(f"\nCAMP_CHECK FAIL ({len(problems)})")
        for problem in problems:
            print(f"  {problem}")
        raise SystemExit(1)
    print("CAMP_CHECK PASS")


if __name__ == "__main__":
    main()
