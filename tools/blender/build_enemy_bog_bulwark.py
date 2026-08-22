"""Build the Bog Bulwark — tier 3 of the enemy ladder (docs/ENEMIES.md §5).

Run with:
  Blender --background --python tools/blender/build_enemy_bog_bulwark.py

Outputs three metre-scale GLBs — one rigged and animated Bog Bulwark and its two
death fragments — plus an editable Blender source, its rows merged into the
shared enemy catalog, a group preview and a pose contact sheet. Geometry, rig
and animation are deterministic.

Fourth rigged family in `assets/enemies/`, and it follows every convention the
three before it set: rigid one-bone-per-part skinning, every action keys every
animated bone (rotation, location AND scale), no raw float in any datablock
name, `-loop` only on the two clips that may loop, and every clip authored no
longer than the `EnemyDef` window it plays under — remembering that Godot reports
an imported clip's length as LAST FRAME over fps, so every `*_FRAMES` constant
below is one less than the count it looks like.

The real subject: the alligator snapping turtle, Macrochelys temminckii. Four
facts, and the third of them is the entire tier.

The carapace carries THREE KEELS — one down the centre line and one either side —
formed by pyramid-shaped elevations of the vertebral and pleural scutes, running
front to back and carrying prominent spikes. That is the silhouette, and it is
the reason this reads as armour rather than as a boulder.

The head ends in a SHARP HOOKED BEAK whose upper jaw works as a cleaver against
the lower — shearing, not biting. So the strike is a snap that closes, and the
tell is the jaws opening wide.

**The plastron is small and affords little protection to the underside.** That is
a fact about the animal, not a concession to the game, and it is where
`EnemyDef.armor_arc_degrees` comes from: this creature is a wall from the front
and soft everywhere else, so the fight is about where you are standing.

And the real animal FISHES — it lies with its jaws open and wiggles a pink,
worm-like lure on its tongue until something swims in. The lure is the only
emissive on the creature and it sits inside the mouth, which means it is visible
exactly when the jaws are open: in the idle, and in the tell.

Nothing here writes to `mire_art.py`. The palette is the third distinct one on
the ladder — wet dark stone and peat over a `bone` plastron, where tier 1 is
purple gel and tier 2 is cold grey plumage.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from typing import Callable

import bpy

sys.path.append(str(Path(__file__).resolve().parent))
from mire_art import mat, reset_materials  # noqa: E402
from godot_import_lock import import_cache_guard  # noqa: E402
import numpy as np
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "enemies"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

EXPECTED_NAMES = [
    "enemy_bog_bulwark",
    "enemy_bog_bulwark_fragment_scute",
    "enemy_bog_bulwark_fragment_beak",
]

LOOP_SUFFIX = "-loop"

EXPECTED_ANIMATIONS = [
    "idle" + LOOP_SUFFIX,
    "locomotion" + LOOP_SUFFIX,
    "attack_tell",
    "attack",
    "hit",
    "death",
]

FPS = 30

## Clip lengths in FRAMES. Each clip is keyed 1..`1 + N`, and Godot reports the
## imported length as LAST FRAME over fps — so these are one less than the count
## they look like, and `tools/enemy_bog_bulwark_check.gd` asserts the imported
## result against the authored `.tres` rather than against these numbers.
TELL_FRAMES = 17       # last frame 18 -> 0.600 s, exactly bog_bulwark.tres's tell
ATTACK_FRAMES = 11     # last frame 12 -> 0.400 s, exactly its attack_seconds
HIT_FRAMES = 8         # last frame 9  -> 0.300 s
DEATH_FRAMES = 47      # last frame 48 -> 1.600 s
IDLE_FRAMES = 89       # last frame 90 -> 3.000 s
LOCOMOTION_FRAMES = 41  # last frame 42 -> 1.400 s

FORWARD = -1.0


# ── Primitives ────────────────────────────────────────────────────────────────
#
# Local copies, like every other rigged family here: this kit is skinned, so any
# change to how a part is generated has to be re-verified against the deform. No
# bevel modifier anywhere (F-057).


def assign(obj: bpy.types.Object, material: bpy.types.Material) -> bpy.types.Object:
    obj.data.materials.append(material)
    for polygon in obj.data.polygons:
        polygon.use_smooth = False
    return obj


def box(
    name: str,
    location: tuple[float, float, float],
    dimensions: tuple[float, float, float],
    material: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = tuple(value * 0.5 for value in dimensions)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, material)


def cone(
    name: str,
    radius_bottom: float,
    radius_top: float,
    depth: float,
    location: tuple[float, float, float],
    material: bpy.types.Material,
    vertices: int = 5,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cone_add(
        vertices=vertices,
        radius1=radius_bottom,
        radius2=radius_top,
        depth=depth,
        location=location,
        rotation=rotation,
    )
    obj = bpy.context.object
    obj.name = name
    return assign(obj, material)


def ico(
    name: str,
    location: tuple[float, float, float],
    scale: tuple[float, float, float],
    material: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
    subdivisions: int = 1,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_ico_sphere_add(
        subdivisions=subdivisions,
        radius=1.0,
        location=location,
        rotation=rotation,
    )
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, material)


def limb(
    name: str,
    start: tuple[float, float, float] | Vector,
    end: tuple[float, float, float] | Vector,
    thickness_start: float,
    thickness_end: float,
    material: bpy.types.Material,
    vertices: int = 5,
) -> bpy.types.Object:
    """A tapering segment spanning two points, aligned along its own Z.

    Every leg segment and every neck segment is described by where it begins and
    ends, and the bone that drives it is described the same way — so both come
    from one pair of points in `SKELETON` and cannot disagree. Five-sided: a
    heron's leg is a stick, and at 3 cm across nobody will ever count its facets.
    """
    head = Vector(start)
    tail = Vector(end)
    axis = tail - head
    bpy.ops.mesh.primitive_cone_add(
        vertices=vertices,
        radius1=thickness_start * 0.5,
        radius2=thickness_end * 0.5,
        depth=axis.length,
        location=(head + tail) * 0.5,
        rotation=axis.to_track_quat("Z", "Y").to_euler(),
    )
    obj = bpy.context.object
    obj.name = name
    return assign(obj, material)


def plume(
    name: str,
    root_point: tuple[float, float, float],
    tip_point: tuple[float, float, float],
    width: float,
    material: bpy.types.Material,
) -> bpy.types.Object:
    """One flat feather blade: a four-vertex quad tapering to a point.

    Two triangles each. Feathers are the one place this creature can afford
    detail — the silhouette of a heron's nuchal crest and its shaggy breast
    plumes is most of what says "bird" rather than "lizard on stilts" — and at
    two triangles apiece it can afford a lot of them.
    """
    root = Vector(root_point)
    tip = Vector(tip_point)
    axis = (tip - root).normalized()
    # Any vector not parallel to the blade, so the cross product is stable.
    reference = Vector((0.0, 0.0, 1.0)) if abs(axis.z) < 0.9 else Vector((1.0, 0.0, 0.0))
    side = axis.cross(reference).normalized() * (width * 0.5)
    shoulder = root + (tip - root) * 0.3
    verts = [root, shoulder + side, tip, shoulder - side]
    mesh = bpy.data.meshes.new(f"{name}_Data")
    mesh.from_pydata([tuple(v) for v in verts], [], [(0, 1, 2), (0, 2, 3)])
    mesh.validate()
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return assign(obj, material)


def look_at(obj: bpy.types.Object, target: tuple[float, float, float]) -> None:
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def move_to_collection(objects: list[bpy.types.Object], collection: bpy.types.Collection) -> None:
    for obj in objects:
        for old_collection in list(obj.users_collection):
            old_collection.objects.unlink(obj)
        collection.objects.link(obj)


def world_bounds(objects: list[bpy.types.Object]) -> tuple[Vector, Vector]:
    bpy.context.view_layer.update()
    corners: list[Vector] = []
    for obj in objects:
        if obj.type == "MESH":
            corners.extend(obj.matrix_world @ Vector(corner) for corner in obj.bound_box)
    minimum = Vector((min(v.x for v in corners), min(v.y for v in corners), min(v.z for v in corners)))
    maximum = Vector((max(v.x for v in corners), max(v.y for v in corners), max(v.z for v in corners)))
    return minimum, maximum


# ── The Bog Bulwark's skeleton ────────────────────────────────────────────────
#
# One table, used three times: to build the armature, to name the vertex groups
# the mesh parts bind to, and to place the geometry that rides each bone.
#
# Twenty bones and not one of them is a spine. A turtle's vertebrae are FUSED TO
# ITS SHELL — the carapace is the skeleton — so the body here is a single rigid
# bone and every other bone hangs off it. That is why this creature cannot be
# staggered and why its flinch is a shudder rather than a recoil: there is
# nothing in the middle of it that bends.

SHELL_CENTRE = Vector((0.0, FORWARD * -0.05, 0.70))
SHELL_RADII = Vector((0.82, 0.97, 0.295))

NECK_BASE = Vector((0.0, FORWARD * 0.62, 0.58))
NECK_TIP = Vector((0.0, FORWARD * 1.00, 0.66))
HEAD_TIP = Vector((0.0, FORWARD * 1.34, 0.63))
JAW_BASE = Vector((0.0, FORWARD * 1.10, 0.52))
JAW_TIP = Vector((0.0, FORWARD * 1.44, 0.46))

TAIL_POINTS = [
    Vector((0.0, FORWARD * -0.85, 0.50)),
    Vector((0.0, FORWARD * -1.10, 0.38)),
    Vector((0.0, FORWARD * -1.30, 0.26)),
    Vector((0.0, FORWARD * -1.48, 0.16)),
]

## (id, side sign, shoulder, elbow, foot, toe). Front legs are set slightly
## narrower and further under the shell than the back pair, which is what a
## turtle actually stands like — the drive is at the back and the front legs
## mostly hold the front of the shell off the ground.
LEGS: list[tuple[str, float, Vector, Vector, Vector, Vector]] = []
for _side_name, _side in (("l", 1.0), ("r", -1.0)):
    LEGS.append((
        f"front_{_side_name}", _side,
        Vector((0.52 * _side, FORWARD * 0.42, 0.52)),
        Vector((0.76 * _side, FORWARD * 0.50, 0.30)),
        Vector((0.82 * _side, FORWARD * 0.56, 0.058)),
        Vector((0.88 * _side, FORWARD * 0.74, 0.030)),
    ))
    LEGS.append((
        f"back_{_side_name}", _side,
        Vector((0.52 * _side, FORWARD * -0.45, 0.52)),
        Vector((0.78 * _side, FORWARD * -0.54, 0.30)),
        Vector((0.84 * _side, FORWARD * -0.60, 0.058)),
        Vector((0.90 * _side, FORWARD * -0.76, 0.030)),
    ))


def bone_table() -> list[tuple[str, Vector, Vector, str | None]]:
    """(name, head, tail, parent) for every bone, in creation order."""
    bones: list[tuple[str, Vector, Vector, str | None]] = [
        ("root", Vector((0.0, 0.0, 0.0)), Vector((0.0, 0.0, 0.20)), None),
        ("body", Vector((0.0, FORWARD * -0.30, 0.60)), Vector((0.0, FORWARD * 0.30, 0.64)), "root"),
        ("neck", NECK_BASE, NECK_TIP, "body"),
        ("head", NECK_TIP, HEAD_TIP, "neck"),
        ("jaw", JAW_BASE, JAW_TIP, "head"),
    ]
    for index in range(3):
        parent = "body" if index == 0 else f"tail_{index}"
        bones.append((f"tail_{index + 1}", TAIL_POINTS[index], TAIL_POINTS[index + 1], parent))
    for leg, _side, shoulder, elbow, foot, toe in LEGS:
        bones.append((f"leg_{leg}_upper", shoulder, elbow, "body"))
        bones.append((f"leg_{leg}_lower", elbow, foot, f"leg_{leg}_upper"))
        bones.append((f"leg_{leg}_foot", foot, toe, f"leg_{leg}_lower"))
    return bones


DEFORM_BONES = [name for name, _, _, parent in bone_table() if parent is not None]


# ── The Bog Bulwark's mesh ────────────────────────────────────────────────────


def keel_point(across: float, along: float) -> Vector:
    """A point on the carapace's upper surface.

    [param across] runs -1..1 left to right and [param along] -1..1 back to
    front, both as fractions of the shell's own radii. The height comes off the
    ellipsoid, so a keel spike placed through here sits ON the shell rather than
    floating over it or sinking into it — the same lesson the Peatling's vein
    network paid for.
    """
    reach = min(1.0, math.sqrt(across * across + along * along))
    return Vector((
        SHELL_CENTRE.x + across * SHELL_RADII.x,
        SHELL_CENTRE.y + FORWARD * along * SHELL_RADII.y,
        SHELL_CENTRE.z + SHELL_RADII.z * math.sqrt(max(0.0, 1.0 - reach * reach)),
    ))


def build_bulwark_parts(mats: dict[str, bpy.types.Material]) -> list[tuple[bpy.types.Object, str]]:
    """Every mesh part paired with the single bone that drives it."""
    parts: list[tuple[bpy.types.Object, str]] = []

    def add(obj: bpy.types.Object, bone: str) -> None:
        parts.append((obj, bone))

    # ── The carapace. Wide, low, and flattened on top rather than domed: a
    # snapping turtle's shell is a roof, not a bubble.
    add(
        ico(
            "Bulwark_Carapace",
            tuple(SHELL_CENTRE),
            tuple(SHELL_RADII),
            mats["shell"],
            subdivisions=2,
        ),
        "body",
    )
    # The marginal scutes: a ring of plates around the rim. They are what turn a
    # smooth ellipsoid into something ASSEMBLED, and assembled is what armour
    # looks like.
    # WEDGES sunk into the rim, not boxes sitting on it. The first pass used
    # boxes and the render came back with ten dark blocks bolted around the edge
    # — the shell stopped reading as one grown thing. A four-sided cone laid flat
    # and pushed most of the way in leaves a tapered plate proud of the surface,
    # which is what a scute actually is.
    for index in range(12):
        angle = math.tau * (index + 0.5) / 12.0
        across = math.sin(angle)
        along = math.cos(angle)
        add(
            cone(
                f"Bulwark_Scute_{index}",
                0.20,
                0.115,
                0.26,
                (
                    SHELL_CENTRE.x + across * SHELL_RADII.x * 0.84,
                    SHELL_CENTRE.y + FORWARD * along * SHELL_RADII.y * 0.84,
                    SHELL_CENTRE.z - 0.075,
                ),
                mats["shell_dark"],
                4,
                (math.radians(84.0), 0.0, -angle),
            ),
            "body",
        )

    # ── THE THREE KEELS. One down the centre line and one either side, each a
    # row of pyramid-shaped elevations carrying a spike, running front to back.
    # This is the silhouette and the single most important thing on the model:
    # without it the creature is a boulder with legs.
    for keel_index, across in enumerate((-0.64, 0.0, 0.64)):
        for step in range(4):
            along = 0.62 - step * 0.42
            seat = keel_point(across, along)
            # Tallest in the middle of the shell, shorter fore and aft — the real
            # keels rise and fall with the shell's own curve.
            height = 0.17 - abs(step - 1.2) * 0.030
            width = 0.155 - abs(step - 1.2) * 0.012
            add(
                cone(
                    f"Bulwark_Keel_{keel_index}_{step}",
                    width,
                    0.018,
                    height,
                    (seat.x, seat.y, seat.z + height * 0.34),
                    mats["keel"],
                    4,
                    (math.radians(FORWARD * (10.0 - step * 6.0)), math.radians(across * 16.0), 0.0),
                ),
                "body",
            )

    # The rear of the carapace is strongly SERRATE on the real animal — a row of
    # backward-pointing teeth on the shell's own edge. Cheap, and it is most of
    # what makes the back of this thing look like it would hurt to run into.
    for index, across in enumerate((-0.62, -0.31, 0.0, 0.31, 0.62)):
        seat = keel_point(across, -0.78)
        add(
            cone(
                f"Bulwark_Serration_{index}",
                0.105,
                0.014,
                0.26,
                (seat.x, seat.y - FORWARD * 0.10, seat.z - 0.10),
                mats["shell_dark"],
                4,
                (math.radians(FORWARD * 108.0), 0.0, math.radians(across * -14.0)),
            ),
            "body",
        )

    # Two crystal growths out of the rear keel. The Mire's mark on this one is
    # small and it is at the BACK, on the side you are supposed to be attacking —
    # so the one glowing thing on its armour is also the thing that tells you
    # you are standing in the right place.
    for index, (across, along) in enumerate(((0.18, -0.46), (-0.26, -0.60))):
        seat = keel_point(across, along)
        add(
            cone(
                f"Bulwark_Growth_{index}",
                0.055 - index * 0.010,
                0.012,
                0.28 - index * 0.07,
                (seat.x, seat.y, seat.z + 0.10),
                mats["crystal"],
                5,
                (math.radians(FORWARD * -22.0), math.radians(20.0 - index * 44.0), 0.0),
            ),
            "body",
        )

    # ── The plastron: pale, flat, and SMALL. On the real animal it covers very
    # little of the underside, which is exactly why this creature is a wall from
    # the front and soft from anywhere else (docs/ENEMIES.md §5.2).
    add(box("Bulwark_Plastron", (0.0, FORWARD * -0.02, 0.40), (1.02, 1.30, 0.10), mats["plastron"]), "body")
    add(box("Bulwark_Plastron_Seam", (0.0, FORWARD * -0.02, 0.455), (0.10, 1.24, 0.04), mats["shell_dark"]), "body")

    # ── The neck: short, thick, and skinned in loose folds. It carries the head
    # 0.5 m out and pulls it most of the way back in, which is the whole tell.
    add(limb("Bulwark_Neck", NECK_BASE, NECK_TIP, 0.36, 0.30, mats["hide"], vertices=6), "neck")
    for index, fraction in enumerate((0.25, 0.6)):
        seat = NECK_BASE.lerp(NECK_TIP, fraction)
        add(ico(f"Bulwark_Neck_Fold_{index}", tuple(seat), (0.185 - index * 0.02, 0.075, 0.175 - index * 0.02), mats["hide_dark"]), "neck")

    # ── The head. A broad wedge that ends in a HOOKED BEAK — the upper jaw is a
    # cleaver working against the lower, so the hook is built as a separate
    # downward-curving point rather than as a taper.
    add(ico("Bulwark_Skull", (0.0, FORWARD * 1.12, 0.665), (0.245, 0.270, 0.185), mats["hide"], subdivisions=1), "head")
    add(box("Bulwark_Brow", (0.0, FORWARD * 1.14, 0.785), (0.33, 0.38, 0.080), mats["hide_dark"], (math.radians(FORWARD * -9), 0.0, 0.0)), "head")
    add(cone("Bulwark_Beak_Upper", 0.125, 0.014, 0.34, (0.0, FORWARD * 1.34, 0.645), mats["beak"], 5, (math.radians(FORWARD * 72.0), 0.0, 0.0)), "head")
    for index, side in enumerate((1.0, -1.0)):
        add(ico(f"Bulwark_Eye_{index}", (0.165 * side, FORWARD * 1.19, 0.735), (0.040, 0.040, 0.040), mats["eye"]), "head")
        add(cone(f"Bulwark_Tubercle_{index}", 0.032, 0.006, 0.10, (0.205 * side, FORWARD * 1.02, 0.635), mats["hide_dark"], 4, (0.0, math.radians(58 * side), 0.0)), "head")

    # ── The lower jaw, and the lure. The real animal lies with its jaws open and
    # wiggles a worm-like appendage on its tongue until something swims in, so
    # the ONE emissive on this creature is bait rather than corruption — a warm
    # green that belongs to no other enemy — and it is only visible when the
    # mouth is open, which is the idle and the tell and nothing else.
    add(box("Bulwark_Jaw", (0.0, FORWARD * 1.22, 0.490), (0.285, 0.38, 0.090), mats["hide"], (math.radians(FORWARD * -6), 0.0, 0.0)), "jaw")
    add(cone("Bulwark_Beak_Lower", 0.092, 0.012, 0.22, (0.0, FORWARD * 1.38, 0.490), mats["beak"], 5, (math.radians(FORWARD * 84.0), 0.0, 0.0)), "jaw")
    add(ico("Bulwark_Lure", (0.0, FORWARD * 1.18, 0.530), (0.042, 0.078, 0.040), mats["lure"]), "jaw")
    add(ico("Bulwark_Tongue", (0.0, FORWARD * 1.12, 0.520), (0.092, 0.115, 0.032), mats["hide_dark"]), "jaw")

    # ── The tail: long, thick and muscular, carrying rows of smooth round bumps.
    for index in range(3):
        start = TAIL_POINTS[index]
        end = TAIL_POINTS[index + 1]
        add(
            limb(
                f"Bulwark_Tail_{index}",
                start,
                end,
                0.30 - index * 0.075,
                0.225 - index * 0.070,
                mats["hide"],
                vertices=5,
            ),
            f"tail_{index + 1}",
        )
        seat = start.lerp(end, 0.5)
        add(
            cone(
                f"Bulwark_Tail_Bump_{index}",
                0.075 - index * 0.018,
                0.014,
                0.14 - index * 0.030,
                (seat.x, seat.y, seat.z + 0.10 - index * 0.02),
                mats["keel"],
                4,
                (math.radians(FORWARD * 26.0), 0.0, 0.0),
            ),
            f"tail_{index + 1}",
        )

    # ── The legs: four short columns, thicker than they are long, with three
    # claws each. A turtle does not walk so much as it shoves itself along.
    for leg, side, shoulder, elbow, foot, toe in LEGS:
        add(limb(f"Bulwark_Upper_{leg}", shoulder, elbow, 0.32, 0.26, mats["hide"], vertices=6), f"leg_{leg}_upper")
        add(limb(f"Bulwark_Lower_{leg}", elbow, foot, 0.26, 0.22, mats["hide_dark"], vertices=6), f"leg_{leg}_lower")
        add(ico(f"Bulwark_Foot_{leg}", (foot.x, foot.y, foot.z + 0.004), (0.155, 0.175, 0.062), mats["hide"]), f"leg_{leg}_foot")
        for claw_index, spread in enumerate((-28.0, 0.0, 28.0)):
            angle = math.radians(spread)
            tip = Vector((
                foot.x + math.sin(angle) * 0.14 * side,
                foot.y + FORWARD * math.cos(angle) * 0.19,
                0.014,
            ))
            add(limb(f"Bulwark_Claw_{leg}_{claw_index}", foot, tip, 0.070, 0.020, mats["beak"], vertices=4), f"leg_{leg}_foot")

    return parts


def build_bulwark_rig(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Object, bpy.types.Object]:
    """Build the Bulwark mesh, bind it rigidly to its armature, return both."""
    parts = build_bulwark_parts(mats)

    for obj, bone in parts:
        group = obj.vertex_groups.new(name=bone)
        group.add(range(len(obj.data.vertices)), 1.0, "REPLACE")

    meshes = [obj for obj, _ in parts]
    bpy.ops.object.select_all(action="DESELECT")
    for obj in meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.join()
    mesh = bpy.context.object
    mesh.name = "Bulwark_Mesh"
    mesh.data.name = "Bulwark_Mesh_Data"

    bpy.ops.object.armature_add(location=(0.0, 0.0, 0.0))
    armature = bpy.context.object
    armature.name = "Bulwark_Rig"
    armature.data.name = "Bulwark_Rig_Data"
    bpy.ops.object.mode_set(mode="EDIT")
    edit_bones = armature.data.edit_bones
    for bone in list(edit_bones):
        edit_bones.remove(bone)
    for name, head, tail, parent in bone_table():
        bone = edit_bones.new(name)
        bone.head = head
        bone.tail = tail
        bone.use_deform = parent is not None
        if parent is not None:
            bone.parent = edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")

    mesh.parent = armature
    modifier = mesh.modifiers.new("Bulwark_Armature", "ARMATURE")
    modifier.object = armature

    for pose_bone in armature.pose.bones:
        pose_bone.rotation_mode = "XYZ"
    return armature, mesh


# ── Animation ─────────────────────────────────────────────────────────────────

Pose = dict[str, tuple[float, float, float]]


def apply_pose(
    armature: bpy.types.Object,
    frame: int,
    pose: Pose,
    offsets: dict[str, tuple[float, float, float]] | None = None,
    scales: dict[str, tuple[float, float, float]] | None = None,
) -> None:
    """Key EVERY animated bone's rotation, location and scale at `frame`.

    The defaulting is the point: Blender leaves an unkeyed channel wherever it
    currently sits, so an action that keys only what it moves inherits the tail
    of whichever action was built before it, and the export changes with build
    order. On this rig the tail in question is the death clip's folded neck.
    """
    offsets = offsets or {}
    scales = scales or {}
    for pose_bone in armature.pose.bones:
        rotation = pose.get(pose_bone.name, (0.0, 0.0, 0.0))
        pose_bone.rotation_euler = tuple(math.radians(angle) for angle in rotation)
        pose_bone.keyframe_insert("rotation_euler", frame=frame)
        pose_bone.location = offsets.get(pose_bone.name, (0.0, 0.0, 0.0))
        pose_bone.keyframe_insert("location", frame=frame)
        pose_bone.scale = scales.get(pose_bone.name, (1.0, 1.0, 1.0))
        pose_bone.keyframe_insert("scale", frame=frame)


def clear_pose(armature: bpy.types.Object) -> None:
    armature.animation_data.action = None
    for pose_bone in armature.pose.bones:
        pose_bone.rotation_euler = (0.0, 0.0, 0.0)
        pose_bone.location = (0.0, 0.0, 0.0)
        pose_bone.scale = (1.0, 1.0, 1.0)
    bpy.context.view_layer.update()


def new_action(armature: bpy.types.Object, name: str) -> bpy.types.Action:
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    if armature.animation_data is None:
        armature.animation_data_create()
    armature.animation_data.action = action
    if hasattr(armature.animation_data, "action_slot"):
        slot = action.slots.new(id_type="OBJECT", name="Bulwark") if not action.slots else action.slots[0]
        armature.animation_data.action_slot = slot
    return action


def merge(*poses: Pose) -> Pose:
    merged: Pose = {}
    for pose in poses:
        merged.update(pose)
    return merged


def legs(crouch: float, gait: float = 0.0) -> Pose:
    """All four legs. `crouch` settles the shell; `gait` drives the plod.

    Diagonal pairs, because that is what a heavy tetrapod does — front-left and
    back-right swing together while the other two carry — and because a turtle
    this size never has fewer than two feet planted. Front and back are given
    different amplitudes: the drive is at the back, and the front legs mostly
    hold the front of the shell off the ground.
    """
    pose: Pose = {}
    for leg, side, _shoulder, _elbow, _foot, _toe in LEGS:
        is_front: bool = leg.startswith("front")
        diagonal: float = 1.0 if (leg in ("front_l", "back_r")) else -1.0
        swing: float = math.sin(gait * math.tau + (0.0 if diagonal > 0.0 else math.pi))
        lift: float = max(0.0, swing)
        reach: float = 20.0 if is_front else 27.0
        pose[f"leg_{leg}_upper"] = (-swing * reach - 12.0 * crouch, 0.0, -6.0 * side * crouch)
        pose[f"leg_{leg}_lower"] = (lift * 26.0 + 30.0 * crouch, 0.0, 0.0)
        pose[f"leg_{leg}_foot"] = (-lift * 16.0 - 10.0 * crouch, 0.0, 0.0)
    return pose


def jaws(open_amount: float) -> Pose:
    """The shearing bite. 1.0 is fully gaped, showing the lure.

    The upper jaw is part of the skull and does not move — a snapping turtle's
    beak works as a cleaver against the lower jaw, so ONLY `jaw` opens, and the
    head tips back a little to carry the gape. Animating both halves apart is
    the standard way to make a beaked thing look like a hand puppet.
    """
    return {
        "jaw": (52.0 * open_amount, 0.0, 0.0),
        "head": (-8.0 * open_amount, 0.0, 0.0),
    }


def reach(amount: float) -> tuple[Pose, dict]:
    """The neck, -1 (drawn fully in) to 1 (fully extended).

    Returns rotations and the translation that carries the head, because most of
    a turtle's reach is the neck SLIDING out of the shell rather than swinging —
    a neck that only rotates describes an arc, and this creature strikes along a
    line.
    """
    out = max(0.0, amount)
    tucked = max(0.0, -amount)
    pose: Pose = {
        "neck": (-16.0 * out + 30.0 * tucked, 0.0, 0.0),
        "head": (-10.0 * out + 22.0 * tucked, 0.0, 0.0),
    }
    offsets = {
        "neck": (0.0, FORWARD * 0.30 * out - FORWARD * 0.20 * tucked, -0.02 * out + 0.04 * tucked),
    }
    return pose, offsets


def tail(sway: float, droop: float = 0.0) -> Pose:
    """Three segments, each turning a little more than the last."""
    return {
        "tail_1": (6.0 * droop, 0.0, 7.0 * sway),
        "tail_2": (9.0 * droop, 0.0, 11.0 * sway),
        "tail_3": (12.0 * droop, 0.0, 15.0 * sway),
    }


def build_animations(armature: bpy.types.Object) -> list[tuple[str, int, int]]:
    """Author every clip. Returns (name, first frame, last frame) per clip."""
    clips: list[tuple[str, int, int]] = []

    # ── idle-loop — 3.0 s. It is FISHING.
    #
    # Sat low with the jaws open and the lure showing, which is what the real
    # animal does for hours at a time. Almost nothing moves except the lure's own
    # segment and a slow tail sway — and that is the read: an open mouth with a
    # light in it, at knee height, in fog. A player who has learnt this creature
    # knows an open mouth is not a threat display, it is an invitation.
    new_action(armature, "idle" + LOOP_SUFFIX)
    for frame, gape, sway, breath in (
        (1, 0.62, 0.0, 0.0),
        (24, 0.70, 0.5, 0.010),
        (46, 0.58, 0.0, 0.0),
        (68, 0.66, -0.5, 0.008),
        (90, 0.62, 0.0, 0.0),  # repeats frame 1 exactly, so the loop has no seam
    ):
        neck_pose, neck_offsets = reach(-0.35)
        apply_pose(
            armature,
            frame,
            merge(legs(0.55), neck_pose, jaws(gape), tail(sway)),
            merge_offsets(neck_offsets, {"body": (0.0, 0.0, breath)}),
        )
    clips.append(("idle" + LOOP_SUFFIX, 1, 1 + IDLE_FRAMES))

    # ── locomotion-loop — 1.4 s. The plod.
    #
    # Slow, and it rocks: a shell carried on four short legs cannot help rolling
    # onto whichever diagonal pair is planted, and the roll is most of what sells
    # the mass. The head stays low and level through all of it, because a turtle
    # walking is a turtle still watching.
    new_action(armature, "locomotion" + LOOP_SUFFIX)
    for step in range(LOCOMOTION_FRAMES + 1):
        phase = step / LOCOMOTION_FRAMES
        roll = math.sin(phase * math.tau) * 5.0
        heave = abs(math.sin(phase * math.tau)) * 0.022
        neck_pose, neck_offsets = reach(-0.15)
        apply_pose(
            armature,
            1 + step,
            merge(
                legs(0.30, phase),
                neck_pose,
                jaws(0.10),
                tail(math.sin(phase * math.tau + 1.2)),
                {"body": (2.0, roll, 0.0)},
            ),
            merge_offsets(neck_offsets, {"body": (0.0, 0.0, heave)}),
        )
    clips.append(("locomotion" + LOOP_SUFFIX, 1, 1 + LOCOMOTION_FRAMES))

    # ── attack_tell — 0.6 s. The longest telegraph in the roster, and it has to
    # be: the strike that follows does 26 damage and lunges. What a player reads
    # is the head DISAPPEARING — the neck hauls back until the skull is inside
    # the shell's own shadow, the jaws gape to their widest, and the whole front
    # of the creature rises onto its front legs. The lure goes out of sight at
    # the same moment, which is the one cue that reads even in fog.
    new_action(armature, "attack_tell")
    neck_pose, neck_offsets = reach(-0.35)
    apply_pose(armature, 1, merge(legs(0.45), neck_pose, jaws(0.55), tail(0.0)), neck_offsets)
    neck_pose, neck_offsets = reach(-0.80)
    apply_pose(
        armature,
        7,
        merge(legs(0.20), neck_pose, jaws(0.85), tail(0.3), {"body": (-6.0, 0.0, 0.0)}),
        merge_offsets(neck_offsets, {"body": (0.0, 0.0, 0.05)}),
    )
    neck_pose, neck_offsets = reach(-1.0)
    hold = (
        merge(legs(0.05), neck_pose, jaws(1.0), tail(0.45), {"body": (-11.0, 0.0, 0.0)}),
        merge_offsets(neck_offsets, {"body": (0.0, FORWARD * -0.03, 0.09)}),
    )
    apply_pose(armature, 12, hold[0], hold[1])
    # Holds the extreme for the last third — a tell still moving when the strike
    # begins never registers as a warning.
    apply_pose(armature, 1 + TELL_FRAMES, hold[0], hold[1])
    clips.append(("attack_tell", 1, 1 + TELL_FRAMES))

    # ── attack — 0.4 s. The snap.
    #
    # Frame 1 is the tell's last frame exactly. The neck fires the head out along
    # a line and the jaws shear shut on the way — closed BEFORE full extension,
    # which is what makes it read as a bite rather than as a headbutt — and then
    # the whole creature drops back onto all four legs, which is the 1.6 s of
    # recovery this thing is worth killing during.
    new_action(armature, "attack")
    neck_pose, neck_offsets = reach(-1.0)
    apply_pose(
        armature,
        1,
        merge(legs(0.05), neck_pose, jaws(1.0), tail(0.45), {"body": (-11.0, 0.0, 0.0)}),
        merge_offsets(neck_offsets, {"body": (0.0, FORWARD * -0.03, 0.09)}),
    )
    neck_pose, neck_offsets = reach(0.85)
    apply_pose(
        armature,
        4,
        merge(legs(0.30), neck_pose, jaws(0.15), tail(-0.4), {"body": (5.0, 0.0, 0.0)}),
        merge_offsets(neck_offsets, {"body": (0.0, FORWARD * 0.06, -0.02)}),
    )
    neck_pose, neck_offsets = reach(1.0)
    apply_pose(
        armature,
        6,
        merge(legs(0.42), neck_pose, jaws(0.0), tail(-0.5), {"body": (8.0, 0.0, 0.0)}),
        merge_offsets(neck_offsets, {"body": (0.0, FORWARD * 0.09, -0.03)}),
    )
    neck_pose, neck_offsets = reach(-0.25)
    apply_pose(
        armature,
        1 + ATTACK_FRAMES,
        merge(legs(0.50), neck_pose, jaws(0.35), tail(0.0), {"body": (1.0, 0.0, 0.0)}),
        neck_offsets,
    )
    clips.append(("attack", 1, 1 + ATTACK_FRAMES))

    # ── hit — 0.3 s. It barely notices.
    #
    # A shudder through the shell and the head drawn in a few centimetres, and
    # that is all. This is the one clip in the game that is deliberately a WEAK
    # reaction: the creature's vertebrae are fused to its carapace, so there is
    # nothing in the middle of it that can recoil, and "your hit did not move it"
    # is the exact sentence tier 3 needs a player to hear.
    new_action(armature, "hit")
    neck_pose, neck_offsets = reach(-0.35)
    apply_pose(armature, 1, merge(legs(0.45), neck_pose, jaws(0.55), tail(0.0)), neck_offsets)
    neck_pose, neck_offsets = reach(-0.70)
    apply_pose(
        armature,
        3,
        merge(legs(0.62), neck_pose, jaws(0.30), tail(-0.35), {"body": (3.0, 4.0, 0.0)}),
        merge_offsets(neck_offsets, {"body": (0.0, 0.0, -0.020)}),
    )
    neck_pose, neck_offsets = reach(-0.50)
    apply_pose(
        armature,
        6,
        merge(legs(0.50), neck_pose, jaws(0.45), tail(0.2), {"body": (1.0, -2.0, 0.0)}),
        neck_offsets,
    )
    neck_pose, neck_offsets = reach(-0.35)
    apply_pose(armature, 1 + HIT_FRAMES, merge(legs(0.45), neck_pose, jaws(0.55), tail(0.0)), neck_offsets)
    clips.append(("hit", 1, 1 + HIT_FRAMES))

    # ── death — 1.6 s. The shell comes down.
    #
    # One last gape and a lunge at nothing, then the legs go out sideways and the
    # whole mass settles onto the plastron with the neck slack and the head lying
    # out in front of it — the one thing it never let anybody see while it was
    # alive. The lure goes dark last, which is worth the four frames it costs.
    new_action(armature, "death")
    neck_pose, neck_offsets = reach(-0.35)
    apply_pose(armature, 1, merge(legs(0.45), neck_pose, jaws(0.55), tail(0.0)), neck_offsets)
    neck_pose, neck_offsets = reach(0.30)
    apply_pose(
        armature,
        8,
        merge(legs(0.15), neck_pose, jaws(1.0), tail(-0.5), {"body": (-8.0, 0.0, 0.0)}),
        merge_offsets(neck_offsets, {"body": (0.0, 0.0, 0.06)}),
    )
    collapse: Pose = {}
    for leg, side, _s, _e, _f, _t in LEGS:
        collapse[f"leg_{leg}_upper"] = (14.0, 0.0, -46.0 * side)
        collapse[f"leg_{leg}_lower"] = (-8.0, 0.0, -22.0 * side)
        collapse[f"leg_{leg}_foot"] = (10.0, 0.0, 0.0)
    neck_pose, neck_offsets = reach(0.65)
    apply_pose(
        armature,
        24,
        merge(collapse, neck_pose, jaws(0.45), tail(0.25, 1.0), {"body": (6.0, 9.0, 0.0), "head": (18.0, 0.0, 8.0)}),
        merge_offsets(neck_offsets, {"body": (0.0, 0.0, -0.24)}),
    )
    neck_pose, neck_offsets = reach(0.80)
    apply_pose(
        armature,
        36,
        merge(collapse, neck_pose, jaws(0.20), tail(0.15, 1.0), {"body": (3.0, 12.0, 0.0), "head": (26.0, 0.0, 12.0)}),
        merge_offsets(neck_offsets, {"body": (0.0, 0.0, -0.31)}),
    )
    apply_pose(
        armature,
        1 + DEATH_FRAMES,
        merge(collapse, neck_pose, jaws(0.12), tail(0.10, 1.0), {"body": (2.0, 13.0, 0.0), "head": (28.0, 0.0, 13.0)}),
        merge_offsets(neck_offsets, {"body": (0.0, 0.0, -0.33)}),
    )
    clips.append(("death", 1, 1 + DEATH_FRAMES))

    if [name for name, _, _ in clips] != EXPECTED_ANIMATIONS:
        raise RuntimeError("Bog Bulwark animation specification and expected clip list diverged")
    return clips


def merge_offsets(*channels: dict) -> dict:
    merged: dict = {}
    for channel in channels:
        merged.update(channel)
    return merged


# ── The death fragments ───────────────────────────────────────────────────────


def build_fragment_scute(mats: dict[str, bpy.types.Material]) -> None:
    """A keel plate, cracked off the carapace with its spike still on it."""
    box("Fragment_Scute_Plate", (0.0, 0.0, 0.05), (0.34, 0.30, 0.10), mats["shell"], (math.radians(7), math.radians(-11), math.radians(16)))
    cone("Fragment_Scute_Spike", 0.115, 0.014, 0.19, (0.02, 0.03, 0.15), mats["keel"], 4, (math.radians(16), math.radians(-9), 0.0))
    box("Fragment_Scute_Chip", (-0.17, -0.09, 0.035), (0.13, 0.11, 0.06), mats["shell_dark"], (0.0, math.radians(19), math.radians(-26)))


def build_fragment_beak(mats: dict[str, bpy.types.Material]) -> None:
    """The hooked beak, and the lure still faintly lit behind it.

    The lure is the point. It is the thing that was pretending to be food, lying
    on the ground next to the thing it was attached to, and it is still glowing —
    which is both a nasty image and the clearest possible way to tell a player
    what they had actually been looking at.
    """
    cone("Fragment_Beak_Hook", 0.115, 0.014, 0.28, (0.06, 0.0, 0.055), mats["beak"], 5, (math.radians(84), 0.0, math.radians(12)))
    ico("Fragment_Beak_Root", (-0.10, 0.02, 0.055), (0.105, 0.095, 0.055), mats["hide"])
    ico("Fragment_Beak_Lure", (-0.13, -0.02, 0.075), (0.036, 0.062, 0.034), mats["lure"])


# ── Assembly, catalog and previews ────────────────────────────────────────────


def set_visible(record: dict, visible: bool) -> None:
    record["root"].hide_render = not visible
    for child in record["root"].children_recursive:
        child.hide_render = not visible


def export_selection(name: str, objects: list[bpy.types.Object], active: bpy.types.Object) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = active
    bpy.ops.export_scene.gltf(
        filepath=str(EXPORT_DIR / f"{name}.glb"),
        export_format="GLB",
        use_selection=True,
        export_apply=False,
        export_yup=True,
        export_animations=True,
        export_animation_mode="ACTIONS",
        export_bake_animation=True,
        export_optimize_animation_size=False,
        export_rest_position_armature=True,
    )


def create_static_asset(
    name: str,
    family: str,
    build_fn: Callable[[], None],
    display_location: tuple[float, float, float],
) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)
    before = set(bpy.data.objects)
    build_fn()
    made = [obj for obj in bpy.data.objects if obj not in before]

    minimum, maximum = world_bounds(made)
    offset = Vector((-(minimum.x + maximum.x) * 0.5, -(minimum.y + maximum.y) * 0.5, -minimum.z))
    for obj in made:
        obj.location += offset
    move_to_collection(made, collection)
    for obj in made:
        obj.parent = root
    minimum, maximum = world_bounds(made)
    dimensions = maximum - minimum
    polygons = sum(len(obj.data.polygons) for obj in made if obj.type == "MESH")
    materials = sorted({m.name for obj in made if obj.type == "MESH" for m in obj.data.materials if m})

    export_selection(name, list(collection.objects), root)
    root.location = display_location
    return {
        "name": name,
        "family": family,
        "root": root,
        "width": dimensions.x,
        "depth": dimensions.y,
        "height": dimensions.z,
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons,
        "materials": materials,
        "bones": 0,
        "animations": [],
    }


def create_rigged_asset(
    name: str,
    family: str,
    armature: bpy.types.Object,
    mesh: bpy.types.Object,
    clips: list[tuple[str, int, int]],
    display_location: tuple[float, float, float],
) -> dict:
    """Export the rigged Bulwark.

    Asserts the rest-pose ground contact rather than correcting it: the rig is
    authored standing on z = 0, and shifting a skinned mesh after binding would
    move it out from under its own armature. On a creature this tall the assert
    is worth more than usual — a two-metre model floating a centimetre up is
    invisible in a preview and glaring in first person.
    """
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    move_to_collection([armature, mesh], collection)

    clear_pose(armature)
    minimum, maximum = world_bounds([mesh])
    if abs(minimum.z) > 0.002:
        raise RuntimeError(f"{name}: rest pose does not touch the ground (min z = {minimum.z:.4f} m)")
    dimensions = maximum - minimum
    materials = sorted({m.name for m in mesh.data.materials if m})

    export_selection(name, [armature, mesh], armature)
    armature.location = display_location
    return {
        "name": name,
        "family": family,
        "root": armature,
        "width": dimensions.x,
        "depth": dimensions.y,
        "height": dimensions.z,
        "parts": 1,
        "polygons": len(mesh.data.polygons),
        "materials": materials,
        "bones": len(armature.data.bones),
        "animations": [clip for clip, _, _ in clips],
    }


def merge_catalog(rows: list[dict]) -> None:
    """Write our rows into the shared enemy catalog without touching anyone else's.

    Three generators now share `assets/enemies/catalog.json`. Each replaces only
    the rows whose names it owns and appends anything new at the end, so any one
    of them can be re-run alone and running all three in any order converges on
    the same file.
    """
    path = ASSET_DIR / "catalog.json"
    existing: list[dict] = []
    if path.exists():
        with path.open(encoding="utf-8") as handle:
            existing = json.load(handle)
    by_name = {row["name"]: row for row in rows}
    merged: list[dict] = []
    for row in existing:
        if row["name"] in by_name:
            merged.append(by_name.pop(row["name"]))
        else:
            merged.append(row)
    merged.extend(by_name[name] for name in EXPECTED_NAMES if name in by_name)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(merged, handle, indent=2)
        handle.write("\n")


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
    fill.data.energy = 1600
    fill.data.color = (0.43, 0.28, 0.68)
    fill.data.shape = "DISK"
    fill.data.size = 7.0
    look_at(fill, (0.0, 0.0, 1.0))
    move_to_collection([fill], preview_collection)
    bpy.ops.object.camera_add(location=(10.5, -15.0, 8.5))
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    camera.data.type = "ORTHO"
    bpy.context.scene.camera = camera
    move_to_collection([camera], preview_collection)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.fps = FPS
    scene.render.resolution_x = 1400
    scene.render.resolution_y = 1100
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.012, 0.016, 0.026)
    scene.view_settings.look = "AgX - Medium High Contrast"
    return scene, camera, preview_collection


def render_pose_sheet(
    scene: bpy.types.Scene,
    camera: bpy.types.Object,
    armature: bpy.types.Object,
    records: list[dict],
    poses: list[tuple[str, str, int]],
    columns: int,
    cell: int,
) -> None:
    """One tile per key pose, composited into a contact sheet.

    The tell and the strike are the two tiles that matter: they are the same
    creature at its shortest and its longest, and if the coil does not read as a
    loaded spring in a still frame it will not read in motion either.
    """
    for record in records:
        set_visible(record, record["name"] == "enemy_bog_bulwark")
    original_resolution = (scene.render.resolution_x, scene.render.resolution_y)
    original_camera = (camera.location.copy(), camera.data.ortho_scale)
    scene.render.resolution_x = cell
    scene.render.resolution_y = cell
    focus = armature.location.copy()
    # Framed on the upper body, not the whole creature: the legs are half the
    # height and none of the difference between these poses is in them.
    camera.data.ortho_scale = 2.9
    camera.location = focus + Vector((2.10, -2.90, 2.10))
    look_at(camera, (focus.x, focus.y, focus.z + 1.25))

    rows = math.ceil(len(poses) / columns)
    sheet = np.zeros((rows * cell, columns * cell, 4), dtype=np.float32)
    sheet[:, :, 3] = 1.0
    for index, (clip, _label, frame) in enumerate(poses):
        armature.animation_data.action = bpy.data.actions[clip]
        if hasattr(armature.animation_data, "action_slot"):
            armature.animation_data.action_slot = bpy.data.actions[clip].slots[0]
        scene.frame_set(frame)
        tile_path = PREVIEW_DIR / f"bog_bulwark_pose_tile_{index}.png"
        scene.render.filepath = str(tile_path)
        bpy.ops.render.render(write_still=True)
        image = bpy.data.images.load(str(tile_path))
        pixels = np.array(image.pixels[:], dtype=np.float32).reshape(cell, cell, 4)
        bpy.data.images.remove(image)
        tile_path.unlink()
        row = index // columns
        column_index = index % columns
        top = (rows - 1 - row) * cell
        sheet[top:top + cell, column_index * cell:(column_index + 1) * cell] = pixels

    output = bpy.data.images.new("Bulwark_Pose_Sheet", width=columns * cell, height=rows * cell, alpha=True)
    output.pixels = sheet.reshape(-1)
    output.filepath_raw = str(PREVIEW_DIR / "bog_bulwark_pose_sheet.png")
    output.file_format = "PNG"
    output.save()
    bpy.data.images.remove(output)

    clear_pose(armature)
    scene.frame_set(1)
    scene.render.resolution_x, scene.render.resolution_y = original_resolution
    camera.location, camera.data.ortho_scale = original_camera
    for record in records:
        set_visible(record, True)


def main() -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    for expected in EXPECTED_NAMES:
        (EXPORT_DIR / f"{expected}.glb").unlink(missing_ok=True)

    # Before anything is exported: glTF stores animation in SECONDS and the
    # exporter divides frame numbers by whatever fps the scene holds. Blender's
    # default is 24, and every clip would ship 25% slow with every frame number
    # still correct.
    bpy.context.scene.render.fps = FPS
    reset_materials()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.actions, bpy.data.armatures, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)

    mats = {
        # The third distinct palette on the ladder: WET DARK EARTH. Tier 1 is
        # purple gel, tier 2 is cold grey plumage, and this is peat and charred
        # wood over a `bone` plastron — the pale underside is the only bright
        # thing on the creature's own body, and it is on the half you are meant
        # to be attacking.
        "shell": mat("peat"),
        "shell_dark": mat("wood_charred"),
        "keel": mat("stone_dark"),
        "plastron": mat("bone"),
        "beak": mat("bone"),
        # The soft parts are a MID grey-brown, not the shell's near-black. The
        # first pass gave hide and shell the same dark family and the head
        # vanished into the carapace's own shadow — on a creature whose entire
        # fight is about which end of it you are standing at, the end with the
        # jaws on it has to be the end you can find. `mire_dormant` is the
        # palette's "neither clear nor corrupt" grey, which is also the right
        # thing to say about a thing this old.
        "hide": mat("mire_dormant"),
        "hide_dark": mat("stone_dark"),
        # RED, not the palette's warm gold `eye`. Sequoyah, on seeing the roster:
        # "red eyes on the enemies please, i think its scarier" — and he is right:
        # warm gold reads as alive and curious, and an enemy has to read as hostile
        # at a glance, in fog, at distance. `critical` is the palette's red emissive
        # (#F17661 over a #FF5030 glow). The genuinely correct fix is to change the
        # `eye` token itself in `mire_art.PALETTE`, which would repoint every enemy
        # at once; that file was claimed by another agent (F-473) for the whole of
        # this task, so this is the per-generator override until it is free.
        "eye": mat("critical"),
        # The lure, and the one place `glowcap` is spent on a creature. It is
        # BAIT, not corruption, so it must not be the Mire's purple — a warm
        # bioluminescent green that nothing else in the roster owns.
        "lure": mat("glowcap"),
        "crystal": mat("crystal"),
        "ground": mat("preview_ground"),
        "scale": mat("reference_blue"),
    }

    records: list[dict] = []

    armature, mesh = build_bulwark_rig(mats)
    clips = build_animations(armature)
    records.append(create_rigged_asset("enemy_bog_bulwark", "enemy", armature, mesh, clips, (-0.35, 0.0, 0.0)))

    statics: list[tuple[str, str, Callable[[], None], tuple[float, float, float]]] = [
        ("enemy_bog_bulwark_fragment_scute", "debris", lambda: build_fragment_scute(mats), (1.60, 0.30, 0.0)),
        ("enemy_bog_bulwark_fragment_beak", "debris", lambda: build_fragment_beak(mats), (2.10, -0.25, 0.0)),
    ]
    for name, family, builder, location in statics:
        records.append(create_static_asset(name, family, builder, location))

    if [record["name"] for record in records] != EXPECTED_NAMES:
        raise RuntimeError("Bog Bulwark specification and expected export list diverged")

    merge_catalog(
        [
            {
                "name": record["name"],
                "family": record["family"],
                "width_m": round(record["width"], 3),
                "depth_m": round(record["depth"], 3),
                "height_m": round(record["height"], 3),
                "mesh_parts": record["parts"],
                "polygons": record["polygons"],
                "bones": record["bones"],
                "animations": record["animations"],
                "materials": record["materials"],
            }
            for record in records
        ]
    )

    scene, camera, preview_collection = setup_render(mats)
    scale_parts = [
        box("Scale_Post", (-2.00, -0.55, 0.9), (0.06, 0.06, 1.8), mats["scale"]),
        box("Scale_Tick_50", (-1.92, -0.55, 0.50), (0.20, 0.06, 0.022), mats["scale"]),
        box("Scale_Tick_100", (-1.92, -0.55, 1.00), (0.26, 0.06, 0.028), mats["scale"]),
        box("Scale_Tick_150", (-1.92, -0.55, 1.50), (0.20, 0.06, 0.022), mats["scale"]),
        box("Scale_Tick_180", (-1.92, -0.55, 1.80), (0.30, 0.06, 0.030), mats["scale"]),
        box("Scale_20cm_Cube", (-1.72, -0.62, 0.10), (0.20, 0.20, 0.20), mats["scale"]),
    ]
    move_to_collection(scale_parts, preview_collection)
    # Lower and more side-on than the other families' preview cameras. This
    # creature is 1.2 m tall and 2.9 m long, and from above it is a shell with
    # nothing else visible — the head, the plastron and the leg splay all live in
    # the side view, and so does the entire question the fight asks.
    camera.data.ortho_scale = 4.3
    camera.location = (3.9, -4.6, 1.55)
    look_at(camera, (0.05, -0.05, 0.56))
    scene.render.filepath = str(PREVIEW_DIR / "bog_bulwark_preview.png")
    bpy.ops.render.render(write_still=True)

    reference_cube = scale_parts.pop()
    for scale_part in scale_parts:
        bpy.data.objects.remove(scale_part, do_unlink=True)
    reference_cube.location = (1.05, 0.62, 0.10)

    render_pose_sheet(
        scene,
        camera,
        armature,
        records,
        [
            ("idle" + LOOP_SUFFIX, "fishing", 24),
            ("locomotion" + LOOP_SUFFIX, "plod carry", 11),
            ("locomotion" + LOOP_SUFFIX, "plod swing", 32),
            ("attack_tell", "head withdrawn", 15),
            ("attack", "snap", 4),
            ("attack", "full extension", 6),
            ("hit", "shudder", 3),
            ("death", "settled", 1 + DEATH_FRAMES),
        ],
        columns=4,
        cell=440,
    )

    bpy.data.objects.remove(reference_cube, do_unlink=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "enemy_bog_bulwark.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(
        f"Built {len(records)} Bog Bulwark assets ({total_polygons} polygons total), "
        f"{len(clips)} clips on {len(armature.data.bones)} bones"
    )


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
