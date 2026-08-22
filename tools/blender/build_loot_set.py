"""Build MIRE's loot set (asset batch A-005).

Run with:
  Blender --background --python tools/blender/build_loot_set.py

Outputs 16 individual metre-scale GLBs, an editable Blender source, a JSON
catalog, and two preview renders. Geometry and layout are deterministic.

Six chests each ship a closed and an open state. Five of them are the chest
RARITY LADDER — crate (basic), small (common), reinforced (rare), warded (epic),
gilded (legendary) — and each rung has to be told from the one below it at a
glance, by silhouette size and by palette, before any UI resolves. The sixth,
the Wellspring chest, is not on that ladder: it is the Mire's own container. The pair is built from one
shared body function and differs only in lid transform and revealed contents, so
the closed and open meshes keep an identical footprint — the tracker's state-set
rule, and what lets the host swap the mesh on open without a collision surprise.

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

sys.path.append(str(Path(__file__).resolve().parent))
from mire_art import (  # noqa: E402
    assign, cone, eevee_engine, ico, look_at, mat, move_to_collection,
    radial, around, reset_materials, world_bounds,
)
from godot_import_lock import import_cache_guard  # noqa: E402
from mathutils import Vector


def box(
    name: str,
    location: tuple[float, float, float],
    dimensions: tuple[float, float, float],
    mat: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
    bevel: float = 0.0,
) -> bpy.types.Object:
    """Bevel-free box, overriding ``mire_art.box`` on purpose (D-124).

    This family's tracker row claims a byte-identical rebuild; the bevel
    modifier changes float bytes between otherwise identical background
    exports on Apple Silicon (F-057). ``bevel`` is accepted and ignored so
    every call site below reads unchanged.
    """
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = (dimensions[0] * 0.5, dimensions[1] * 0.5, dimensions[2] * 0.5)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, mat)


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "loot"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

EXPECTED_NAMES = [
    "loot_chest_crate_closed",
    "loot_chest_crate_open",
    "loot_chest_small_closed",
    "loot_chest_small_open",
    "loot_chest_wellspring_closed",
    "loot_chest_wellspring_open",
    "loot_chest_reinforced_closed",
    "loot_chest_reinforced_open",
    "loot_chest_warded_closed",
    "loot_chest_warded_open",
    "loot_chest_gilded_closed",
    "loot_chest_gilded_open",
    "loot_coin_pouch",
    "loot_powerup_orb",
    "loot_item_bag",
    "loot_player_backpack",
]

## F-593 — how big the chests stand against the player.
##
## Sequoyah, from a playtest: "chests need to be bigger, there too small." He is
## right, and the measurement says WHERE. The shipped player is exactly 1.8 m —
## `entities/player/player.tscn` is a 1.8 m CapsuleShape3D with its origin at the
## feet, camera at 1.6 m — and the ladder ran 0.464 m to 1.013 m, so the two
## commonest rungs came up to the knee. F-570 puts 100 of an island's 150 chests
## on exactly those two rungs, so two thirds of every chest a player walks up to
## was an ankle-to-knee box. That is the report.
##
##     rung          was     ->  now    lands at (1.8 m player)
##     basic         0.464       0.580  knee to low thigh   (32%)
##     common        0.566       0.707  mid thigh           (39%)
##     Wellspring    0.658       0.823  upper thigh         (46%, off-ladder)
##     rare          0.708       0.885  hip                 (49%)
##     epic          0.748       0.935  hip                 (52%)
##     legendary     1.013       1.266  above the waist     (70%)
##
## ONE factor for the whole family, and that is a correction to my own first
## attempt, which is worth recording because the reasoning that produced it was
## seductive and wrong. I first derived a per-chest factor, placing each rung on
## a chosen part of the body to even out the ladder's uneven height gaps. The
## heights came out exactly as designed and the SILHOUETTE LADDER INVERTED: the
## epic warded chest is a wide low slab (W/H 1.39) and the legendary gilded one
## is a tall box (W/H 1.11), so scaling them to different heights made the epic
## 1.335 m wide against the legendary's 1.220 m. The epic would have read as the
## bigger chest, which is exactly the tier cue `chest_placement_service.gd` says
## silhouette size carries before any UI resolves.
##
## The general rule, and the reason this is a single number: width and height are
## BOTH already monotonic across the ladder, and a uniform scale is the only
## transform that preserves both. Any per-rung factor can invert one of them, and
## it will do so silently, because nothing about the height table shows you what
## happened to the widths. Measure both.
##
## 1.25 rather than the ~1.29 the crate alone wants: it is the smallest factor
## that lifts the two common rungs clear of the knee without pushing the
## legendary chest past chest height on the player. At 1.30 the gilded chest is
## 1.32 m and 1.46 m wide, which reads as furniture.
##
## The ladder's GAPS are still uneven — the rare and epic rungs sit 0.05 m apart,
## which no player can tell across a clearing. That is a PROPORTIONS defect, not
## a scale one: fixing it means re-authoring those two bodies, not scaling them,
## and doing it inside a "make them bigger" change would be a silent redesign of
## the rarity ladder. Recorded in F-593 for Sequoyah instead.
##
## Applied in `create_asset()`, on the whole built set, about the world origin —
## which is the ground contact point, so ground contact and every proportion
## survive it. It is a CONSTANT, so a chest's closed and open builders get the
## identical value: this is the A-005 state-set rule that A-011 and A-051 each
## had to relearn, since a scale derived from each state's own bounds would size
## the two states differently and silently rescale the frame they share.
## `check_state_pairs()` asserts 0.0000 mm drift on that shared frame.
##
## Never a `scale` on the placed node instead: that would break `PropCollider`'s
## fit and the kit's ground-contact and anchor rules, which is why this lives in
## the build and the assets get rebuilt.
CHEST_SCALE = 1.25


def chest_scale(name: str) -> float:
    """The F-593 factor for an asset. Chests only — the pouch, orb, bag and
    backpack are carried or hand-held items whose size was never the complaint."""
    return CHEST_SCALE if name.startswith("loot_chest_") else 1.0


## Lid swing for an open chest, in degrees about the rear hinge. One constant so
## all three pairs read as the same object class rather than three unrelated
## hinges.
##
## NEGATIVE, and the sign is the whole trap. The lid extends forward (-Y) from a
## hinge at the back, so a POSITIVE rotation about +X drives its front edge down
## through the floor: at +104° the front-bottom corner lands at z = -0.046. The
## ground-normalization in create_asset then lifts the entire chest to put that
## buried corner at zero, so all three open chests floated with their bodies off
## the ground and their lids underneath. Negative rotation lifts the tip up and
## back, which is what an opened lid actually does.
OPEN_LID_DEGREES = -104.0


def rotate_about(obj: bpy.types.Object, pivot: tuple[float, float, float], degrees: float) -> None:
    """Swing a lid part about a hinge on the +X axis, pivot in world space."""
    origin = Vector(pivot)
    offset = obj.location - origin
    angle = math.radians(degrees)
    cosine = math.cos(angle)
    sine = math.sin(angle)
    obj.location = origin + Vector((
        offset.x,
        offset.y * cosine - offset.z * sine,
        offset.y * sine + offset.z * cosine,
    ))
    obj.rotation_euler[0] += angle


# ── Chests ────────────────────────────────────────────────────────────────────
#
# One body builder per chest, taking `is_open`. Closed and open therefore cannot
# drift apart: the base, bands and feet are literally the same calls, and only
# the lid group is transformed. Contents are added only when open, inside the
# shell the closed state already occupies, so the footprint is unchanged.


def chest_shell(
    prefix: str,
    base_z: float,
    width: float,
    depth: float,
    height: float,
    mat: bpy.types.Material,
    inner_mat: bpy.types.Material,
    wall: float = 0.055,
) -> list[bpy.types.Object]:
    """A chest body with an actual cavity.

    One solid box is cheaper and was the first attempt, but it makes the open
    state meaningless: lifting the lid revealed a flat sealed top, and the
    contents built inside it were sealed in where nothing could ever see them.
    Five thin boxes cost about fifty polygons and buy an interior that reads
    instantly — which is the entire reason the open variant exists.

    Every part keeps `_Body` in its name so the closed/open anchor filter in
    create_asset still matches the whole shell.
    """
    inner_depth = depth - wall * 2.0
    return [
        box(f"{prefix}_Body_Floor", (0.0, 0.0, base_z + wall * 0.5), (width, depth, wall), inner_mat),
        box(f"{prefix}_Body_Front", (0.0, -(depth - wall) * 0.5, base_z + height * 0.5), (width, wall, height), mat, bevel=0.010),
        box(f"{prefix}_Body_Back", (0.0, (depth - wall) * 0.5, base_z + height * 0.5), (width, wall, height), mat, bevel=0.010),
        box(f"{prefix}_Body_Left", (-(width - wall) * 0.5, 0.0, base_z + height * 0.5), (wall, inner_depth, height), mat, bevel=0.010),
        box(f"{prefix}_Body_Right", ((width - wall) * 0.5, 0.0, base_z + height * 0.5), (wall, inner_depth, height), mat, bevel=0.010),
    ]


def chest_lid_parts(
    prefix: str,
    hinge_y: float,
    width: float,
    depth: float,
    lid_height: float,
    body_top: float,
    mats: dict[str, bpy.types.Material],
    plank_mat: str,
    band_mat: str,
) -> list[bpy.types.Object]:
    parts = [
        box(
            f"{prefix}_Lid",
            (0.0, 0.0, body_top + lid_height * 0.5),
            (width, depth, lid_height),
            mats[plank_mat],
            bevel=0.012,
        )
    ]
    for index, offset in enumerate((-depth * 0.29, depth * 0.29)):
        parts.append(
            box(
                f"{prefix}_Lid_Band_{index + 1}",
                (0.0, offset, body_top + lid_height * 0.5),
                (width * 1.04, depth * 0.10, lid_height * 1.08),
                mats[band_mat],
            )
        )
    parts.append(
        box(
            f"{prefix}_Lid_Lip",
            (0.0, -depth * 0.5 + 0.012, body_top + lid_height * 0.18),
            (width * 0.86, 0.028, lid_height * 0.34),
            mats[band_mat],
        )
    )
    for part in parts:
        part.location.y -= hinge_y
        part.location.y += hinge_y
    return parts


def build_chest_small(mats: dict[str, bpy.types.Material], is_open: bool) -> None:
    width, depth = 0.72, 0.46
    body_height, lid_height = 0.34, 0.16
    for index, (x, y) in enumerate(((-0.30, -0.18), (0.30, -0.18), (-0.30, 0.18), (0.30, 0.18))):
        box(f"Small_Foot_{index + 1}", (x, y, 0.03), (0.10, 0.10, 0.06), mats["wood_dark"])
    chest_shell("Small", 0.06, width, depth, body_height, mats["wood"], mats["wood_dark"])
    for index, offset in enumerate((-depth * 0.29, depth * 0.29)):
        box(f"Small_Band_{index + 1}", (0.0, offset, 0.06 + body_height * 0.5), (width * 1.04, depth * 0.10, body_height), mats["iron"])
    box("Small_Lock", (0.0, -depth * 0.5 - 0.008, 0.06 + body_height * 0.86), (0.13, 0.035, 0.12), mats["iron_light"], bevel=0.012)

    body_top = 0.06 + body_height
    hinge = (0.0, depth * 0.5, body_top)
    lid = chest_lid_parts("Small", depth * 0.5, width, depth, lid_height, body_top, mats, "wood", "iron")
    if is_open:
        for part in lid:
            rotate_about(part, hinge, OPEN_LID_DEGREES)
        # Contents fill the cavity rather than lying on its floor: the rim is at
        # 0.40 and anything below ~0.30 is hidden behind the front wall from a
        # standing player's view, which made the first open chest read as empty.
        box("Small_Cloth", (0.0, 0.0, 0.212), (width * 0.80, depth * 0.66, 0.19), mats["cloth"], bevel=0.02)
        for index, (x, y, scale) in enumerate((
            (-0.18, 0.02, 0.055),
            (0.02, -0.05, 0.048),
            (0.19, 0.04, 0.052),
        )):
            cone(f"Small_Coin_{index + 1}", scale, scale, 0.018, (x, y, 0.320), mats["coin"], 10)


def build_chest_wellspring(mats: dict[str, bpy.types.Material], is_open: bool) -> None:
    width, depth = 0.80, 0.50
    body_height, lid_height = 0.38, 0.20
    for index, (x, y) in enumerate(((-0.33, -0.20), (0.33, -0.20), (-0.33, 0.20), (0.33, 0.20))):
        box(f"Well_Foot_{index + 1}", (x, y, 0.035), (0.12, 0.12, 0.07), mats["mire_dark"])
    chest_shell("Well", 0.07, width, depth, body_height, mats["mire"], mats["mire_dark"])
    for index, offset in enumerate((-depth * 0.30, depth * 0.30)):
        box(f"Well_Band_{index + 1}", (0.0, offset, 0.07 + body_height * 0.5), (width * 1.04, depth * 0.10, body_height), mats["mire_dark"])
    # Emissive veins are the Mire's visual signature (DESIGN.md §6) and are what
    # separates this silhouette from the mundane chests at a glance.
    for index, x in enumerate((-0.22, 0.0, 0.22)):
        box(f"Well_Vein_{index + 1}", (x, -depth * 0.5 - 0.006, 0.07 + body_height * 0.55), (0.045, 0.02, body_height * 0.66), mats["mire_glow"])
    ico("Well_Crystal_Lock", (0.0, -depth * 0.5 - 0.03, 0.07 + body_height * 0.84), (0.075, 0.055, 0.095), mats["mire_crystal"])

    body_top = 0.07 + body_height
    hinge = (0.0, depth * 0.5, body_top)
    lid = chest_lid_parts("Well", depth * 0.5, width, depth, lid_height, body_top, mats, "mire", "mire_dark")
    for index, x in enumerate((-0.20, 0.20)):
        lid.append(box(f"Well_Lid_Vein_{index + 1}", (x, 0.0, body_top + lid_height * 0.5), (0.05, depth * 1.02, lid_height * 1.06), mats["mire_glow"]))
    if is_open:
        for part in lid:
            rotate_about(part, hinge, OPEN_LID_DEGREES)
        ico("Well_Prize", (0.0, 0.0, 0.275), (0.13, 0.11, 0.15), mats["mire_crystal"], subdivisions=2)
        for index, (x, y) in enumerate(((-0.21, 0.03), (0.20, -0.04))):
            ico(f"Well_Shard_{index + 1}", (x, y, 0.295), (0.05, 0.045, 0.075), mats["mire_glow"])


def build_chest_reinforced(mats: dict[str, bpy.types.Material], is_open: bool) -> None:
    width, depth = 0.92, 0.58
    body_height, lid_height = 0.42, 0.20
    for index, (x, y) in enumerate(((-0.39, -0.24), (0.39, -0.24), (-0.39, 0.24), (0.39, 0.24))):
        box(f"Rein_Foot_{index + 1}", (x, y, 0.04), (0.15, 0.15, 0.08), mats["iron_dark"])
    chest_shell("Rein", 0.08, width, depth, body_height, mats["wood_dark"], mats["wood"])
    for index, offset in enumerate((-depth * 0.32, 0.0, depth * 0.32)):
        box(f"Rein_Band_{index + 1}", (0.0, offset, 0.08 + body_height * 0.5), (width * 1.04, depth * 0.11, body_height), mats["iron_dark"])
    for index, (x, y) in enumerate(((-0.44, -0.28), (0.44, -0.28), (-0.44, 0.28), (0.44, 0.28))):
        box(f"Rein_Corner_{index + 1}", (x, y, 0.08 + body_height * 0.5), (0.06, 0.06, body_height * 1.02), mats["iron_light"])
    box("Rein_Lock", (0.0, -depth * 0.5 - 0.012, 0.08 + body_height * 0.82), (0.20, 0.045, 0.17), mats["iron_light"], bevel=0.014)
    box("Rein_Keyhole", (0.0, -depth * 0.5 - 0.03, 0.08 + body_height * 0.80), (0.05, 0.02, 0.06), mats["iron_dark"])

    body_top = 0.08 + body_height
    hinge = (0.0, depth * 0.5, body_top)
    lid = chest_lid_parts("Rein", depth * 0.5, width, depth, lid_height, body_top, mats, "wood_dark", "iron_dark")
    for index, x in enumerate((-0.40, 0.40)):
        lid.append(box(f"Rein_Lid_Corner_{index + 1}", (x, 0.0, body_top + lid_height * 0.52), (0.07, depth * 1.02, lid_height * 1.04), mats["iron_light"]))
    if is_open:
        for part in lid:
            rotate_about(part, hinge, OPEN_LID_DEGREES)
        box("Rein_Cloth", (0.0, 0.0, 0.238), (width * 0.82, depth * 0.70, 0.20), mats["cloth_rich"], bevel=0.022)
        box("Rein_Ingot_1", (-0.16, 0.02, 0.372), (0.24, 0.11, 0.07), mats["ingot"], bevel=0.012)
        box("Rein_Ingot_2", (-0.13, -0.09, 0.438), (0.24, 0.11, 0.07), mats["ingot"], (0.0, 0.0, 0.18), 0.012)
        for index, (x, y) in enumerate(((0.22, 0.03), (0.28, -0.08), (0.16, -0.10))):
            cone(f"Rein_Coin_{index + 1}", 0.058, 0.058, 0.02, (x, y, 0.358), mats["coin"], 10)


def build_chest_crate(mats: dict[str, bpy.types.Material], is_open: bool) -> None:
    """Basic — the free scatter crate, and the bottom rung of the chest ladder.

    Deliberately the ONLY container in the kit with no metal on it anywhere: grey
    weathered deadwood, corner battens and a rope lashing where every richer tier
    puts iron. At range that reads as "nothing was worth locking in here", which
    is exactly what the tier pays out. It is also the smallest silhouette, so the
    ladder reads by size alone before a single colour resolves.
    """
    width, depth = 0.60, 0.40
    body_height, lid_height = 0.30, 0.11
    # Skids, not feet: a crate sits on two runners so it can be dragged.
    for index, y in enumerate((-0.14, 0.14)):
        box(f"Crate_Foot_{index + 1}", (0.0, y, 0.025), (width * 1.02, 0.09, 0.05), mats["crate_wood_dark"])
    chest_shell("Crate", 0.05, width, depth, body_height, mats["crate_wood"], mats["crate_wood_dark"], wall=0.05)
    for index, (x, y) in enumerate(((-0.27, -0.18), (0.27, -0.18), (-0.27, 0.18), (0.27, 0.18))):
        box(f"Crate_Batten_{index + 1}", (x, y, 0.05 + body_height * 0.5), (0.055, 0.055, body_height * 1.02), mats["crate_wood_dark"])
    # The lashing replaces the iron band. Two cords, so it reads as tied shut.
    for index, offset in enumerate((-depth * 0.24, depth * 0.24)):
        box(f"Crate_Cord_{index + 1}", (0.0, offset, 0.05 + body_height * 0.62), (width * 1.04, depth * 0.055, 0.030), mats["cord"])

    body_top = 0.05 + body_height
    hinge = (0.0, depth * 0.5, body_top)
    lid = chest_lid_parts("Crate", depth * 0.5, width, depth, lid_height, body_top, mats, "crate_wood", "cord")
    if is_open:
        for part in lid:
            rotate_about(part, hinge, OPEN_LID_DEGREES)
        # Straw, not cloth: nothing in a crate was packed carefully.
        box("Crate_Straw", (0.0, 0.0, 0.190), (width * 0.80, depth * 0.66, 0.16), mats["straw"], bevel=0.02)
        for index, (x, y, scale) in enumerate((
            (-0.14, 0.02, 0.048),
            (0.13, -0.04, 0.045),
        )):
            cone(f"Crate_Coin_{index + 1}", scale, scale, 0.016, (x, y, 0.278), mats["coin"], 10)


def build_chest_warded(mats: dict[str, bpy.types.Material], is_open: bool) -> None:
    """Epic — the warded chest: dressed ward-slate bound in bogsilver, sealed by
    wellglass runes.

    This is the one tier whose read is COLD. Every other container in the kit is
    warm timber, warm iron or Mire purple, so the teal ward palette (DESIGN.md's
    reserved ward colour) marks the epic rung from across a clearing with no size
    comparison needed. The runes are emissive, which also means it survives the
    night pass that swallows the wooden tiers.
    """
    width, depth = 1.00, 0.62
    body_height, lid_height = 0.44, 0.21
    for index, (x, y) in enumerate(((-0.43, -0.26), (0.43, -0.26), (-0.43, 0.26), (0.43, 0.26))):
        box(f"Ward_Foot_{index + 1}", (x, y, 0.045), (0.15, 0.15, 0.09), mats["bogsilver_dark"])
    chest_shell("Ward", 0.09, width, depth, body_height, mats["ward_slate"], mats["ward_stone_dark"])
    for index, offset in enumerate((-depth * 0.31, depth * 0.31)):
        box(f"Ward_Band_{index + 1}", (0.0, offset, 0.09 + body_height * 0.5), (width * 1.04, depth * 0.10, body_height), mats["bogsilver"])
    for index, (x, y) in enumerate(((-0.48, -0.30), (0.48, -0.30), (-0.48, 0.30), (0.48, 0.30))):
        box(f"Ward_Corner_{index + 1}", (x, y, 0.09 + body_height * 0.5), (0.06, 0.06, body_height * 1.02), mats["bogsilver_light"])
    # Rune row across the front face. Alternating heights so it reads as writing
    # rather than as a row of identical lamps.
    for index, (x, height_scale) in enumerate(((-0.26, 0.52), (-0.09, 0.68), (0.09, 0.52), (0.26, 0.68))):
        box(f"Ward_Rune_{index + 1}", (x, -depth * 0.5 - 0.007, 0.09 + body_height * 0.52), (0.042, 0.022, body_height * height_scale), mats["ward_glow"])
    ico("Ward_Seal", (0.0, -depth * 0.5 - 0.032, 0.09 + body_height * 0.86), (0.085, 0.060, 0.105), mats["ward_crystal"])

    body_top = 0.09 + body_height
    hinge = (0.0, depth * 0.5, body_top)
    lid = chest_lid_parts("Ward", depth * 0.5, width, depth, lid_height, body_top, mats, "ward_slate", "bogsilver")
    for index, x in enumerate((-0.24, 0.24)):
        lid.append(box(f"Ward_Lid_Rune_{index + 1}", (x, 0.0, body_top + lid_height * 0.5), (0.046, depth * 1.02, lid_height * 1.06), mats["ward_glow"]))
    if is_open:
        for part in lid:
            rotate_about(part, hinge, OPEN_LID_DEGREES)
        box("Ward_Cloth", (0.0, 0.0, 0.255), (width * 0.82, depth * 0.70, 0.20), mats["canvas_dark"], bevel=0.022)
        ico("Ward_Prize", (0.0, 0.01, 0.408), (0.15, 0.12, 0.17), mats["ward_crystal_light"], subdivisions=2)
        for index, (x, y) in enumerate(((-0.26, 0.03), (0.26, -0.05))):
            ico(f"Ward_Shard_{index + 1}", (x, y, 0.400), (0.06, 0.05, 0.09), mats["ward_glow"])
        for index, (x, y) in enumerate(((0.14, 0.10), (-0.13, -0.09))):
            cone(f"Ward_Coin_{index + 1}", 0.058, 0.058, 0.02, (x, y, 0.372), mats["coin"], 10)


def build_chest_gilded(mats: dict[str, bpy.types.Material], is_open: bool) -> None:
    """Legendary — the gilded chest: the largest silhouette in the kit, gold on
    dark wood, with a gemmed crest on the lid.

    The top rung has to be unmistakable at the moment of SIGHTING, not at the
    moment of opening, because its price is what a player saves up for. Three
    signals do that and none of them appears on any other tier: full-width gold
    banding, a crest that breaks the lid's flat top, and a red interior that is
    visible the instant it opens.
    """
    width, depth = 1.08, 0.68
    body_height, lid_height = 0.46, 0.24
    for index, (x, y) in enumerate(((-0.46, -0.29), (0.46, -0.29), (-0.46, 0.29), (0.46, 0.29))):
        box(f"Gild_Foot_{index + 1}", (x, y, 0.05), (0.16, 0.16, 0.10), mats["brass_dark"])
    chest_shell("Gild", 0.10, width, depth, body_height, mats["gild_wood"], mats["cloth_rich_red"])
    for index, offset in enumerate((-depth * 0.33, 0.0, depth * 0.33)):
        box(f"Gild_Band_{index + 1}", (0.0, offset, 0.10 + body_height * 0.5), (width * 1.04, depth * 0.10, body_height), mats["gold"])
    for index, (x, y) in enumerate(((-0.52, -0.32), (0.52, -0.32), (-0.52, 0.32), (0.52, 0.32))):
        box(f"Gild_Corner_{index + 1}", (x, y, 0.10 + body_height * 0.5), (0.07, 0.07, body_height * 1.02), mats["brass"])
    # Filigree: a shallow gold scrollwork row that catches the sun and says
    # "someone decorated this", which no other chest in the kit claims.
    for index, x in enumerate((-0.30, -0.10, 0.10, 0.30)):
        box(f"Gild_Filigree_{index + 1}", (x, -depth * 0.5 - 0.006, 0.10 + body_height * 0.34), (0.11, 0.018, 0.035), mats["gold"])
    box("Gild_Lock", (0.0, -depth * 0.5 - 0.013, 0.10 + body_height * 0.80), (0.23, 0.05, 0.19), mats["gold"], bevel=0.014)
    ico("Gild_Lock_Gem", (0.0, -depth * 0.5 - 0.042, 0.10 + body_height * 0.80), (0.070, 0.050, 0.075), mats["gem_red"])

    body_top = 0.10 + body_height
    hinge = (0.0, depth * 0.5, body_top)
    lid = chest_lid_parts("Gild", depth * 0.5, width, depth, lid_height, body_top, mats, "gild_wood", "gold")
    for index, x in enumerate((-0.46, 0.46)):
        lid.append(box(f"Gild_Lid_Corner_{index + 1}", (x, 0.0, body_top + lid_height * 0.52), (0.08, depth * 1.02, lid_height * 1.04), mats["brass"]))
    # The crest. It is part of the LID group, so it swings with the lid and the
    # closed silhouette is the one that carries it.
    lid.append(box("Gild_Crest_Base", (0.0, 0.0, body_top + lid_height + 0.030), (0.26, 0.16, 0.060), mats["gold"]))
    lid.append(ico("Gild_Crest_Gem", (0.0, 0.0, body_top + lid_height + 0.098), (0.115, 0.095, 0.115), mats["gem_red"], subdivisions=2))
    if is_open:
        for part in lid:
            rotate_about(part, hinge, OPEN_LID_DEGREES)
        box("Gild_Velvet", (0.0, 0.0, 0.270), (width * 0.82, depth * 0.72, 0.21), mats["cloth_rich_red"], bevel=0.022)
        box("Gild_Ingot_1", (-0.20, 0.03, 0.412), (0.26, 0.12, 0.075), mats["gold"], bevel=0.012)
        box("Gild_Ingot_2", (-0.17, -0.10, 0.483), (0.26, 0.12, 0.075), mats["gold"], (0.0, 0.0, 0.18), 0.012)
        for index, (x, y) in enumerate(((0.26, 0.04), (0.32, -0.09), (0.19, -0.11), (0.24, -0.02))):
            cone(f"Gild_Coin_{index + 1}", 0.062, 0.062, 0.022, (x, y, 0.398 + index * 0.020), mats["coin"], 10)
        for index, (x, y) in enumerate(((0.05, 0.12), (-0.02, -0.13))):
            ico(f"Gild_Gem_{index + 1}", (x, y, 0.412), (0.062, 0.055, 0.070), mats["gem_red"])


# ── Carried and dropped loot ──────────────────────────────────────────────────


def build_coin_pouch(mats: dict[str, bpy.types.Material]) -> None:
    ico("Pouch_Body", (0.0, 0.0, 0.13), (0.16, 0.15, 0.13), mats["leather"], subdivisions=2)
    cone("Pouch_Neck", 0.085, 0.062, 0.09, (0.0, 0.0, 0.27), mats["leather_dark"], 10)
    for index, angle_index in enumerate((0, 1, 2, 3, 4, 5)):
        angle = angle_index * math.pi / 3.0
        box(
            f"Pouch_Tie_{index + 1}",
            (math.cos(angle) * 0.078, math.sin(angle) * 0.078, 0.255),
            (0.035, 0.02, 0.028),
            mats["cord"],
            (0.0, 0.0, angle),
        )
    cone("Pouch_Mouth", 0.055, 0.048, 0.03, (0.0, 0.0, 0.315), mats["cord"], 10)
    for index, (x, y, z) in enumerate(((-0.055, 0.02, 0.325), (0.05, -0.03, 0.322))):
        cone(f"Pouch_Coin_{index + 1}", 0.042, 0.042, 0.016, (x, y, z), mats["coin"], 10, (0.35, 0.2, 0.0))


def build_powerup_orb(mats: dict[str, bpy.types.Material]) -> None:
    # A floating pickup, so its origin sits at ground level with the orb hovering
    # above: the gap is the asset telling the gameplay code where the ground is.
    box("Orb_Base_Ring", (0.0, 0.0, 0.012), (0.30, 0.30, 0.024), mats["mire_dark"], bevel=0.008)
    for index, angle_index in enumerate((0, 1, 2, 3)):
        angle = angle_index * math.pi / 2.0 + math.pi / 4.0
        box(
            f"Orb_Rune_{index + 1}",
            (math.cos(angle) * 0.115, math.sin(angle) * 0.115, 0.018),
            (0.06, 0.028, 0.016),
            mats["mire_glow"],
            (0.0, 0.0, angle),
        )
    ico("Orb_Core", (0.0, 0.0, 0.30), (0.135, 0.135, 0.135), mats["orb_core"], subdivisions=2)
    ico("Orb_Shell", (0.0, 0.0, 0.30), (0.185, 0.185, 0.185), mats["orb_shell"], subdivisions=1)
    for index, angle_index in enumerate((0, 1, 2)):
        angle = angle_index * 2.0 * math.pi / 3.0
        ico(
            f"Orb_Mote_{index + 1}",
            (math.cos(angle) * 0.235, math.sin(angle) * 0.235, 0.30 + math.sin(angle) * 0.06),
            (0.032, 0.032, 0.032),
            mats["mire_glow"],
        )


def build_item_bag(mats: dict[str, bpy.types.Material]) -> None:
    ico("Bag_Body", (0.0, 0.0, 0.17), (0.22, 0.20, 0.17), mats["sack"], subdivisions=2)
    box("Bag_Slump", (0.0, 0.0, 0.035), (0.40, 0.36, 0.07), mats["sack"], bevel=0.03)
    cone("Bag_Neck", 0.10, 0.075, 0.10, (0.0, 0.0, 0.35), mats["sack_dark"], 10)
    for index, angle_index in enumerate((0, 1, 2, 3)):
        angle = angle_index * math.pi / 2.0
        box(
            f"Bag_Tie_{index + 1}",
            (math.cos(angle) * 0.088, math.sin(angle) * 0.088, 0.335),
            (0.038, 0.022, 0.03),
            mats["cord"],
            (0.0, 0.0, angle),
        )
    box("Bag_Patch", (0.0, -0.19, 0.16), (0.11, 0.03, 0.10), mats["patch"], bevel=0.012)
    for index, (x, y, z) in enumerate(((-0.06, 0.03, 0.40), (0.07, -0.02, 0.39))):
        box(f"Bag_Spill_{index + 1}", (x, y, z), (0.06, 0.05, 0.05), mats["ingot"], (0.3, 0.2, 0.4), 0.01)


def build_player_backpack(mats: dict[str, bpy.types.Material]) -> None:
    # A dead player's dropped pack. It leans rather than standing square, so it
    # reads as dropped at a glance instead of placed.
    body = box("Pack_Body", (0.0, 0.0, 0.24), (0.36, 0.26, 0.46), mats["canvas"], (0.10, 0.0, 0.0), 0.022)
    body.rotation_euler[2] = 0.14
    box("Pack_Flap", (0.0, -0.055, 0.44), (0.37, 0.20, 0.13), mats["canvas_dark"], (0.30, 0.0, 0.14), 0.018)
    box("Pack_Pocket", (0.0, -0.155, 0.16), (0.26, 0.10, 0.19), mats["canvas_dark"], (0.06, 0.0, 0.14), 0.016)
    for index, x in enumerate((-0.115, 0.115)):
        box(f"Pack_Strap_{index + 1}", (x, 0.135, 0.26), (0.055, 0.05, 0.44), mats["leather_dark"], (0.10, 0.0, 0.14), 0.012)
    for index, x in enumerate((-0.115, 0.115)):
        box(f"Pack_Buckle_{index + 1}", (x, -0.145, 0.30), (0.06, 0.035, 0.05), mats["iron_light"], (0.10, 0.0, 0.14))
    box("Pack_Bedroll", (0.0, 0.10, 0.52), (0.40, 0.15, 0.15), mats["cloth"], (0.10, 0.0, 0.14), 0.05)
    # A spilled ingot and the owner's marker: this is somebody's stuff, and the
    # readable "go get it back" silhouette is the whole point of the asset.
    box("Pack_Spill_Ingot", (0.24, -0.16, 0.045), (0.22, 0.10, 0.065), mats["ingot"], (0.0, 0.0, -0.55), 0.012)
    cone("Pack_Spill_Coin", 0.055, 0.055, 0.018, (0.30, 0.02, 0.012), mats["coin"], 10)
    box("Pack_Marker", (-0.02, 0.145, 0.66), (0.03, 0.03, 0.16), mats["mire_glow"], (0.10, 0.0, 0.14))


# ── Assembly, catalog and previews ────────────────────────────────────────────


def set_visible(record: dict, visible: bool) -> None:
    record["root"].hide_render = not visible
    for child in record["root"].children_recursive:
        child.hide_render = not visible


def create_asset(
    name: str,
    family: str,
    build_fn: Callable[[], None],
    display_location: tuple[float, float, float],
    anchor_parts: tuple[str, ...] = (),
) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)
    before = set(bpy.data.objects)
    build_fn()
    made = [obj for obj in bpy.data.objects if obj not in before]

    # F-593, BEFORE the normalization below so the bounds it measures are the
    # final ones. Uniform, about the world origin, and applied to the whole set:
    # every builder authors its geometry with z=0 as the ground, so scaling about
    # the origin keeps the chest on the ground and leaves every proportion,
    # bevel-free face and lid hinge exactly where it was.
    #
    # `box()` bakes its size into mesh data and leaves `obj.scale` at 1, while the
    # cones and icos from `mire_art` do not necessarily — so multiply the existing
    # scale rather than assigning, and let the glTF export's `export_apply` bake
    # the result. Locations scale with it, which is what makes this a scaling of
    # the ASSEMBLY and not of each part in place.
    factor = chest_scale(name)
    if factor != 1.0:
        for obj in made:
            obj.location = obj.location * factor
            obj.scale = Vector(obj.scale) * factor
        # BAKE it into the mesh data, exactly as `box()` does with its own size.
        # Leaving the factor on `obj.scale` exports a GLB whose every node carries
        # scale=(1.25, 1.25, 1.25) — `audit_all_sides.py` reports that as an
        # unapplied transform, and it is a real defect and not a cosmetic one: a
        # node-level scale is a thing a consumer can lose, override or double up
        # on, and `PropCollider` fits colliders to geometry that is supposed to
        # already be at its final size. The audit caught this; the numbers in the
        # catalog were correct either way, which is precisely why it needed an
        # instrument that looks at the mesh rather than at the measurements.
        bpy.ops.object.select_all(action="DESELECT")
        for obj in made:
            obj.select_set(True)
        bpy.context.view_layer.objects.active = made[0]
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        bpy.ops.object.select_all(action="DESELECT")

    # Horizontal centre, origin at ground level — the same normalization every
    # other portable family uses, so these drop into a scene identically.
    #
    # [param anchor_parts] exists for state sets. Centring a chest on ALL of its
    # geometry moves the body when the lid swings, because the open lid extends
    # rearward and drags the bounding centre with it — so swapping closed→open
    # at runtime would visibly shift the chest and desync it from collision
    # authored against the closed mesh. Anchoring the horizontal centre on the
    # parts both states share (body and feet) pins the body in place and lets
    # the lid extend where a real lid does. Z still comes from the full set, so
    # every asset keeps its origin on the ground.
    anchors = [obj for obj in made if any(part in obj.name for part in anchor_parts)] if anchor_parts else made
    if not anchors:
        raise RuntimeError(f"{name}: anchor_parts {anchor_parts} matched no geometry")
    anchor_min, anchor_max = world_bounds(anchors)
    minimum, _ = world_bounds(made)
    offset = Vector((
        -(anchor_min.x + anchor_max.x) * 0.5,
        -(anchor_min.y + anchor_max.y) * 0.5,
        -minimum.z,
    ))
    for obj in made:
        obj.location += offset
    move_to_collection(made, collection)
    for obj in made:
        obj.parent = root
    minimum, maximum = world_bounds(made)
    dimensions = maximum - minimum
    # F-593: the bounds of the geometry the closed and open states SHARE, measured
    # after normalization, so `_check_state_pairs()` can assert the two states did
    # not size their common frame differently. The full bounds cannot answer that
    # — an open chest is legitimately deeper and taller because its lid is up.
    shared_min, shared_max = world_bounds(anchors)
    polygons = sum(len(obj.data.polygons) for obj in made if obj.type == "MESH")
    materials = sorted({mat.name for obj in made if obj.type == "MESH" for mat in obj.data.materials if mat})

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
        "shared_min": Vector(shared_min),
        "shared_max": Vector(shared_max),
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons,
        "materials": materials,
    }


def setup_render(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Scene, bpy.types.Object, bpy.types.Collection]:
    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.mesh.primitive_plane_add(size=40, location=(0.0, 0.0, -0.025))
    floor = bpy.context.object
    floor.name = "Preview_Ground"
    assign(floor, mats["ground"])
    move_to_collection([floor], preview_collection)
    bpy.ops.object.light_add(type="SUN", location=(0.0, 0.0, 15.0))
    sun = bpy.context.object
    sun.name = "Preview_Sun"
    sun.rotation_euler = (math.radians(34), math.radians(-22), math.radians(-28))
    sun.data.energy = 2.35
    sun.data.angle = math.radians(20)
    move_to_collection([sun], preview_collection)
    bpy.ops.object.light_add(type="AREA", location=(-6.0, -8.0, 8.0))
    fill = bpy.context.object
    fill.name = "Preview_Fill"
    fill.data.energy = 1200
    fill.data.color = (0.43, 0.28, 0.68)
    fill.data.shape = "DISK"
    fill.data.size = 7.0
    look_at(fill, (0.0, 0.0, 0.3))
    move_to_collection([fill], preview_collection)
    bpy.ops.object.camera_add(location=(10.5, -15.0, 8.5))
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    camera.data.type = "ORTHO"
    bpy.context.scene.camera = camera
    move_to_collection([camera], preview_collection)
    scene = bpy.context.scene
    scene.render.engine = eevee_engine()
    scene.render.resolution_x = 1600
    scene.render.resolution_y = 1000
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.012, 0.016, 0.026)
    scene.view_settings.look = "AgX - Medium High Contrast"
    return scene, camera, preview_collection


def check_state_pairs(records: list[dict]) -> None:
    """A-005's state-set rule, asserted rather than trusted (F-593).

    Every chest ships a closed and an open mesh, and the host swaps one for the
    other on open. If the two states size the geometry they SHARE even slightly
    differently, the chest visibly jumps and desyncs from a collider authored
    against the closed mesh. A-011 and A-051 both hit this by deriving a scale
    from each state's own bounds; F-593 introduced a per-chest scale factor and
    would have been the third, so the invariant stops being a convention here.

    Compares the shared body-and-feet frame, not the full bounds — an open chest
    is legitimately deeper and taller, because its lid is up. Tolerance is one
    micrometre: this is a shared constant applied to identical geometry, so the
    only honest expectation is exact, and 1e-6 m allows nothing but float noise.
    """
    by_name = {record["name"]: record for record in records}
    tolerance = 1e-6
    for name in EXPECTED_NAMES:
        if not name.endswith("_closed"):
            continue
        open_name = name[: -len("_closed")] + "_open"
        closed, opened = by_name.get(name), by_name.get(open_name)
        if closed is None or opened is None:
            raise RuntimeError(f"{name}: state pair is incomplete")
        for axis, label in enumerate("xyz"):
            low = abs(closed["shared_min"][axis] - opened["shared_min"][axis])
            high = abs(closed["shared_max"][axis] - opened["shared_max"][axis])
            if low > tolerance or high > tolerance:
                raise RuntimeError(
                    f"{name}/{open_name}: shared frame drifts on {label} by "
                    f"{max(low, high) * 1000.0:.4f} mm — the two states are not "
                    "the same object"
                )
    print(f"State pairs: shared frame identical across {len(EXPECTED_NAMES) // 2} pair(s), 0.0000 mm drift")


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
        # Shared palette. Purple stays reserved for corruption, which is why the
        # Wellspring chest's rich lining is the one cloth allowed to use it.
        "wood": mat("wood_timber_light"),
        "wood_dark": mat("wood_timber"),
        "iron": mat("iron"),
        "iron_dark": mat("iron_dark"),
        "iron_light": mat("iron_light"),
        "ingot": mat("iron"),
        "coin": mat("gold"),
        "cloth": mat("cloth_red"),
        "cloth_rich": mat("mire_light"),
        "leather": mat("leather"),
        "leather_dark": mat("leather_dark"),
        "cord": mat("rope"),
        "sack": mat("cloth"),
        "sack_dark": mat("cloth_dark"),
        "patch": mat("leaf"),
        "canvas": mat("canvas"),
        "canvas_dark": mat("canvas_dark"),
        "mire": mat("mire"),
        "mire_dark": mat("mire_black"),
        "mire_glow": mat("mire_glow"),
        "mire_crystal": mat("crystal_tip"),
        # Basic (crate): grey weathered deadwood and rope, no metal anywhere.
        "crate_wood": mat("wood_dead"),
        "crate_wood_dark": mat("wood_bark_dark"),
        "straw": mat("grass_dry"),
        # Epic (warded): the reserved ward teal, on dressed slate bound in bogsilver.
        "ward_slate": mat("ward_slate"),
        "ward_stone_dark": mat("ward_stone_dark"),
        "ward_glow": mat("ward_glow"),
        "ward_crystal": mat("ward_crystal"),
        "ward_crystal_light": mat("ward_crystal_light"),
        "bogsilver": mat("bogsilver"),
        "bogsilver_dark": mat("bogsilver_dark"),
        "bogsilver_light": mat("bogsilver_light"),
        # Legendary (gilded): gold and brass over dark wood, red inside.
        "gold": mat("gold"),
        "brass": mat("brass"),
        "brass_dark": mat("brass_dark"),
        "cloth_rich_red": mat("cloth_red"),
        # Near-black wood, not the mid-brown every other chest uses. Gold on brown reads as
        # brass-on-timber — which is the RARE rung's look — and the top of a ladder cannot afford
        # to resemble the middle of it. Against charred wood the same gold reads as gold.
        "gild_wood": mat("wood_charred"),
        # `tonic_red` is the palette's one glossy deep red (roughness 0.30); it is
        # borrowed here for the crest and lock gems because a gem is exactly a red
        # that reflects, and adding a second near-identical swatch would be worse.
        "gem_red": mat("tonic_red"),
        "orb_core": mat("flame"),
        "orb_shell": mat("ember"),
        "ground": mat("preview_ground"),
        "scale": mat("reference_blue"),
    }

    # The third element is anchor_parts: for a closed/open pair it names the
    # geometry both states share, so the body lands identically in each.
    chest_anchor = ("_Body", "_Foot")
    builders: list[tuple[str, str, Callable[[], None], tuple[str, ...]]] = [
        ("loot_chest_crate_closed", "chest", lambda: build_chest_crate(mats, False), chest_anchor),
        ("loot_chest_crate_open", "chest", lambda: build_chest_crate(mats, True), chest_anchor),
        ("loot_chest_small_closed", "chest", lambda: build_chest_small(mats, False), chest_anchor),
        ("loot_chest_small_open", "chest", lambda: build_chest_small(mats, True), chest_anchor),
        ("loot_chest_wellspring_closed", "chest", lambda: build_chest_wellspring(mats, False), chest_anchor),
        ("loot_chest_wellspring_open", "chest", lambda: build_chest_wellspring(mats, True), chest_anchor),
        ("loot_chest_reinforced_closed", "chest", lambda: build_chest_reinforced(mats, False), chest_anchor),
        ("loot_chest_reinforced_open", "chest", lambda: build_chest_reinforced(mats, True), chest_anchor),
        ("loot_chest_warded_closed", "chest", lambda: build_chest_warded(mats, False), chest_anchor),
        ("loot_chest_warded_open", "chest", lambda: build_chest_warded(mats, True), chest_anchor),
        ("loot_chest_gilded_closed", "chest", lambda: build_chest_gilded(mats, False), chest_anchor),
        ("loot_chest_gilded_open", "chest", lambda: build_chest_gilded(mats, True), chest_anchor),
        ("loot_coin_pouch", "carried", lambda: build_coin_pouch(mats), ()),
        ("loot_powerup_orb", "powerup", lambda: build_powerup_orb(mats), ()),
        ("loot_item_bag", "carried", lambda: build_item_bag(mats), ()),
        ("loot_player_backpack", "dropped", lambda: build_player_backpack(mats), ()),
    ]
    if [name for name, _, _, _ in builders] != EXPECTED_NAMES:
        raise RuntimeError("A-005 specification and expected export list diverged")

    records: list[dict] = []
    for index, (name, family, builder, anchor) in enumerate(builders):
        column = index % 4
        row = index // 4
        location = ((column - 1.5) * 1.76, (2.15 - row * 2.05), 0.0)
        records.append(create_asset(name, family, builder, location, anchor))

    check_state_pairs(records)

    catalog = [
        {
            "name": record["name"],
            "family": record["family"],
            "width_m": round(record["width"], 3),
            "depth_m": round(record["depth"], 3),
            "height_m": round(record["height"], 3),
            "mesh_parts": record["parts"],
            "polygons": record["polygons"],
            "materials": record["materials"],
        }
        for record in records
    ]
    with (ASSET_DIR / "catalog.json").open("w", encoding="utf-8") as handle:
        json.dump(catalog, handle, indent=2)
        handle.write("\n")

    scene, camera, preview_collection = setup_render(mats)
    camera.data.ortho_scale = 9.6
    camera.location = (0.0, -16.0, 11.5)
    look_at(camera, (0.0, -0.95, 0.30))
    scene.render.filepath = str(PREVIEW_DIR / "loot_preview.png")
    bpy.ops.render.render(write_still=True)

    original_locations = {record["name"]: record["root"].location.copy() for record in records}
    # The five ladder rungs in price order, left to right, so the scale render is
    # also the readability test: a player has to tell them apart by silhouette.
    showcase_positions = {
        "loot_chest_crate_closed": (-2.30, 0.55, 0.0),
        "loot_chest_small_closed": (-1.35, 0.52, 0.0),
        "loot_chest_reinforced_closed": (-0.25, 0.50, 0.0),
        "loot_chest_warded_closed": (0.95, 0.48, 0.0),
        "loot_chest_gilded_closed": (2.25, 0.45, 0.0),
        "loot_powerup_orb": (3.30, 0.35, 0.0),
    }
    for record in records:
        set_visible(record, record["name"] in showcase_positions)
        if record["name"] in showcase_positions:
            record["root"].location = showcase_positions[record["name"]]
    scale_parts = [
        box("Scale_Post", (-3.45, -0.55, 0.5), (0.10, 0.10, 1.0), mats["scale"]),
        box("Scale_Tick_20", (-3.35, -0.55, 0.20), (0.22, 0.08, 0.025), mats["scale"]),
        box("Scale_Tick_40", (-3.35, -0.55, 0.40), (0.22, 0.08, 0.025), mats["scale"]),
        box("Scale_Tick_60", (-3.35, -0.55, 0.60), (0.22, 0.08, 0.025), mats["scale"]),
        box("Scale_Tick_80", (-3.35, -0.55, 0.80), (0.22, 0.08, 0.025), mats["scale"]),
        box("Scale_Tick_100", (-3.35, -0.55, 1.00), (0.28, 0.08, 0.03), mats["scale"]),
        box("Scale_20cm_Cube", (-2.95, -0.60, 0.10), (0.20, 0.20, 0.20), mats["scale"]),
    ]
    move_to_collection(scale_parts, preview_collection)
    camera.data.ortho_scale = 9.4
    camera.location = (7.0, -11.0, 5.2)
    look_at(camera, (0.15, 0.0, 0.32))
    scene.render.filepath = str(PREVIEW_DIR / "loot_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    for record in records:
        record["root"].location = original_locations[record["name"]]
        set_visible(record, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "loot_set.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(f"Built {len(records)} A-005 loot assets ({total_polygons} polygons total)")


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
