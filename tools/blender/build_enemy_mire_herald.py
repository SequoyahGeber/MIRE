"""Build the Mire Herald — tier 5 of the enemy ladder (docs/ENEMIES.md §7).

Run with:
  Blender --background --python tools/blender/build_enemy_mire_herald.py

Outputs three metre-scale GLBs — one rigged and animated Mire Herald and its two
death fragments — plus an editable Blender source, its rows merged into the
shared enemy catalog, a group preview and a pose contact sheet. Geometry, rig
and animation are deterministic.

The sixth and last rigged family in `assets/enemies/`, and the top of the ladder.
It follows every convention the five before it set: rigid one-bone-per-part
skinning, every action keys every animated bone, no raw float in any datablock
name, `-loop` only on the two clips that may loop, and every clip authored no
longer than the `EnemyDef` window it plays under — remembering that Godot reports
an imported clip's length as LAST FRAME over fps, so every `*_FRAMES` constant
below is one less than the count it looks like.

The real subject: Megaloceros giganteus, the Irish elk — a giant deer whose
best-preserved remains come out of PEAT BOGS, which is not a coincidence this
project is going to pass up.

Four facts, and none of them is softened. The antlers are PALMATE — flattened
palms with points along the outer edge, not a branching tree — and they span up
to three and a half metres and weigh about forty kilos. The shoulder stands
around two metres and the head-to-body length runs over three. The skull is
extra thick and the neck vertebrae unusually sturdy. And the vertebrae over the
shoulders are ELONGATED, forming a hump of muscle whose job is holding that rack
off the ground: the hump is not a stylistic flourish, it is the anatomical reason
the antlers are allowed to exist, and a model without it wears its rack like a
hat.

Nothing here writes to `mire_art.py`. The palette closes the loop the ladder
opened: a body the colour of the peat it came out of, bone showing through it,
and the Mire's purple growing on the antler palms and nowhere else — the same
purple this creature leaves on the ground behind it as it walks.
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
    "enemy_mire_herald",
    "enemy_mire_herald_fragment_antler",
    "enemy_mire_herald_fragment_hide",
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
## they look like, and `tools/enemy_mire_herald_check.gd` asserts the imported
## result against the authored `.tres` rather than against these numbers.
TELL_FRAMES = 18       # last frame 19 -> 0.633 s, under mire_herald.tres's 0.65 s
ATTACK_FRAMES = 13     # last frame 14 -> 0.467 s, under its 0.5 s attack_seconds
HIT_FRAMES = 8         # last frame 9  -> 0.300 s
DEATH_FRAMES = 59      # last frame 60 -> 2.000 s, the longest death in the game
IDLE_FRAMES = 105      # last frame 106 -> 3.533 s
LOCOMOTION_FRAMES = 47  # last frame 48 -> 1.600 s

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


# ── The Mire Herald's skeleton ────────────────────────────────────────────────
#
# Twenty-one bones. The proportions are taken from Megaloceros giganteus and they
# are not softened: shoulder at 2.0 m, head-to-tail over three metres, and an
# antler span of nearly three and a half. It is the largest thing in the game by
# a wide margin and it is supposed to be the moment a player stops thinking about
# this night and starts thinking about the run.
#
# Note the HUMP. The real animal's shoulder vertebrae are elongated, carrying the
# muscle that holds forty kilos of antler off the ground — so the hump is not a
# stylistic flourish, it is the anatomical reason the antlers are allowed to
# exist, and leaving it out makes the rack read as a hat.

SHOULDER_Z = 1.80
HIP_Z = 1.62

NECK_BASE = Vector((0.0, FORWARD * 0.80, SHOULDER_Z))
NECK_TIP = Vector((0.0, FORWARD * 1.28, 2.02))
HEAD_TIP = Vector((0.0, FORWARD * 1.64, 1.90))

## (id, side, shoulder/hip, mid joint, lower joint, hoof). A deer's front leg
## bends forward at the knee and its back leg bends BACKWARD at the hock, and
## getting those two the same way is what makes a quadruped read as a table.
LEGS: list[tuple[str, float, Vector, Vector, Vector, Vector]] = []
for _side_name, _side in (("l", 1.0), ("r", -1.0)):
    LEGS.append((
        f"front_{_side_name}", _side,
        Vector((0.34 * _side, FORWARD * 0.62, SHOULDER_Z - 0.16)),
        Vector((0.39 * _side, FORWARD * 0.74, 1.06)),
        Vector((0.37 * _side, FORWARD * 0.58, 0.52)),
        Vector((0.39 * _side, FORWARD * 0.66, 0.045)),
    ))
    LEGS.append((
        f"back_{_side_name}", _side,
        Vector((0.33 * _side, FORWARD * -0.72, HIP_Z - 0.08)),
        Vector((0.42 * _side, FORWARD * -0.58, 1.10)),
        Vector((0.36 * _side, FORWARD * -0.88, 0.56)),
        Vector((0.38 * _side, FORWARD * -0.76, 0.045)),
    ))


def bone_table() -> list[tuple[str, Vector, Vector, str | None]]:
    """(name, head, tail, parent) for every bone, in creation order."""
    bones: list[tuple[str, Vector, Vector, str | None]] = [
        ("root", Vector((0.0, 0.0, 0.0)), Vector((0.0, 0.0, 0.30)), None),
        ("hips", Vector((0.0, FORWARD * -0.78, HIP_Z)), Vector((0.0, FORWARD * 0.06, 1.70)), "root"),
        ("spine", Vector((0.0, FORWARD * 0.06, 1.70)), Vector((0.0, FORWARD * 0.80, SHOULDER_Z)), "hips"),
        ("neck", NECK_BASE, NECK_TIP, "spine"),
        ("head", NECK_TIP, HEAD_TIP, "neck"),
        ("antler_l", Vector((0.12, FORWARD * 1.32, 2.10)), Vector((0.92, FORWARD * 1.22, 2.42)), "head"),
        ("antler_r", Vector((-0.12, FORWARD * 1.32, 2.10)), Vector((-0.92, FORWARD * 1.22, 2.42)), "head"),
        ("tail", Vector((0.0, FORWARD * -0.78, HIP_Z)), Vector((0.0, FORWARD * -1.16, 1.42)), "hips"),
    ]
    for leg, _side, upper, mid, lower, hoof in LEGS:
        bones.append((f"leg_{leg}_upper", upper, mid, "spine" if leg.startswith("front") else "hips"))
        bones.append((f"leg_{leg}_mid", mid, lower, f"leg_{leg}_upper"))
        bones.append((f"leg_{leg}_lower", lower, hoof, f"leg_{leg}_mid"))
    return bones


DEFORM_BONES = [name for name, _, _, parent in bone_table() if parent is not None]


# ── The Mire Herald's mesh ────────────────────────────────────────────────────


def palm(
    name: str,
    root_point: Vector,
    tip_point: Vector,
    width_root: float,
    width_tip: float,
    thickness: float,
    material: bpy.types.Material,
) -> bpy.types.Object:
    """One flat palmate antler blade: a tapering slab with real thickness.

    PALMATE is the whole point — a Megaloceros rack is not a branching tree of
    tines, it is a pair of flattened palms with points along their outer edge,
    and that flatness is what gives the silhouette its enormous lateral profile.
    Built as an eight-vertex slab rather than as a flat quad, because a
    zero-thickness blade disappears when the creature turns side-on, which on
    this animal is the exact angle its whole read depends on.
    """
    axis = (tip_point - root_point).normalized()
    across = axis.cross(Vector((0.0, 0.0, 1.0)))
    if across.length < 0.001:
        across = Vector((1.0, 0.0, 0.0))
    across = across.normalized()
    up = across.cross(axis).normalized() * (thickness * 0.5)
    verts: list[Vector] = []
    for point, half in ((root_point, width_root * 0.5), (tip_point, width_tip * 0.5)):
        verts.extend([
            point - across * half + up,
            point + across * half + up,
            point + across * half - up,
            point - across * half - up,
        ])
    faces = [
        (0, 1, 2, 3), (7, 6, 5, 4),
        (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0),
    ]
    mesh = bpy.data.meshes.new(f"{name}_Data")
    mesh.from_pydata([tuple(v) for v in verts], [], faces)
    mesh.validate()
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return assign(obj, material)


def build_herald_parts(mats: dict[str, bpy.types.Material]) -> list[tuple[bpy.types.Object, str]]:
    """Every mesh part paired with the single bone that drives it."""
    parts: list[tuple[bpy.types.Object, str]] = []

    def add(obj: bpy.types.Object, bone: str) -> None:
        parts.append((obj, bone))

    # ── Body. Deep chest, drawn-in flank, and the HUMP over the shoulders that
    # the real animal grew to carry its own antlers.
    add(ico("Herald_Chest", (0.0, FORWARD * 0.44, 1.60), (0.44, 0.60, 0.46), mats["hide"], subdivisions=2), "spine")
    add(ico("Herald_Hump", (0.0, FORWARD * 0.52, 1.94), (0.34, 0.44, 0.24), mats["hide_dark"], subdivisions=1), "spine")
    add(ico("Herald_Belly", (0.0, FORWARD * -0.16, 1.48), (0.36, 0.52, 0.34), mats["hide"], subdivisions=1), "spine")
    add(ico("Herald_Haunch", (0.0, FORWARD * -0.70, 1.52), (0.42, 0.46, 0.42), mats["hide"], subdivisions=1), "hips")
    add(cone("Herald_Tail", 0.10, 0.020, 0.44, (0.0, FORWARD * -1.00, 1.50), mats["hide_dark"], 5, (math.radians(FORWARD * -50.0), 0.0, 0.0)), "tail")

    # Ribs, showing through. This thing came out of a bog and it has been dead in
    # every way that matters for a long time; the ribs are the cheapest possible
    # way to say so, and they break up an otherwise smooth flank.
    for index in range(4):
        offset = FORWARD * (0.30 - index * 0.19)
        for side in (1.0, -1.0):
            add(
                box(
                    f"Herald_Rib_{index}_{'l' if side > 0 else 'r'}",
                    (0.345 * side, offset, 1.56 - index * 0.020),
                    (0.050, 0.070, 0.58 - index * 0.035),
                    mats["bone"],
                    (0.0, math.radians(11.0 * side), math.radians(FORWARD * (-4.0 - index * 2.5))),
                ),
                "spine",
            )

    # ── Neck and head. Sturdy neck vertebrae and an extra-thick skull, both real
    # adaptations for carrying the rack, and both worth reading as MASS.
    add(limb("Herald_Neck", NECK_BASE, NECK_TIP, 0.44, 0.30, mats["hide"], vertices=6), "neck")
    add(ico("Herald_Mane", (0.0, FORWARD * 1.00, 1.94), (0.22, 0.30, 0.22), mats["hide_dark"], subdivisions=1), "neck")
    add(ico("Herald_Skull", (0.0, FORWARD * 1.40, 2.00), (0.20, 0.30, 0.22), mats["hide"], subdivisions=1), "head")
    add(cone("Herald_Muzzle", 0.145, 0.075, 0.42, (0.0, FORWARD * 1.62, 1.90), mats["hide_dark"], 5, (math.radians(FORWARD * 74.0), 0.0, 0.0)), "head")
    add(box("Herald_Brow", (0.0, FORWARD * 1.38, 2.14), (0.30, 0.26, 0.09), mats["bone"], (math.radians(FORWARD * -10.0), 0.0, 0.0)), "head")
    for index, side in enumerate((1.0, -1.0)):
        add(ico(f"Herald_Eye_{index}", (0.155 * side, FORWARD * 1.44, 2.06), (0.048, 0.048, 0.044), mats["eye"]), "head")
        add(ico(f"Herald_Ear_{index}", (0.215 * side, FORWARD * 1.20, 2.10), (0.045, 0.115, 0.075), mats["hide_dark"], (0.0, math.radians(38 * side), 0.0)), "head")

    # ── THE ANTLERS. Palmate — flattened blades with points along the outer
    # edge, not a branching tree — because that is what Megaloceros carried and
    # because a flat palm is what gives this silhouette its three-and-a-half
    # metres of lateral profile. They are the single most important thing on the
    # model: everything else about the creature is a large deer, and the rack is
    # what makes it the last thing in the game.
    for side_name, side in (("l", 1.0), ("r", -1.0)):
        bone = f"antler_{side_name}"
        beam_root = Vector((0.12 * side, FORWARD * 1.32, 2.10))
        beam_bend = Vector((0.40 * side, FORWARD * 1.16, 2.28))
        # The palm sweeps OUT and only slightly up. The first pass ran it to
        # z 2.62 and the render came back with a rack that read as tall rather
        # than wide — but span is the whole point of a Megaloceros silhouette,
        # and every centimetre spent going up is a centimetre not spent going
        # sideways. 1.55 m per side is a 3.3 m span at the tips, which is the
        # real animal's.
        palm_root = Vector((0.58 * side, FORWARD * 1.10, 2.36))
        # And FORWARD of the beam, not behind it. A real Megaloceros rack sweeps
        # out and slightly forward, so the palms frame the head like a pair of
        # open hands — which is the iconic read, and also the one that puts the
        # points between the animal and whatever it is facing. Swept back, the
        # same geometry lies across its own shoulders and reads as cargo.
        palm_tip = Vector((1.55 * side, FORWARD * 1.28, 2.46))
        add(limb(f"Herald_Beam_{side_name}", beam_root, beam_bend, 0.115, 0.095, mats["antler"], vertices=5), bone)
        add(limb(f"Herald_Beam_Upper_{side_name}", beam_bend, palm_root, 0.095, 0.085, mats["antler"], vertices=5), bone)
        add(palm(f"Herald_Palm_{side_name}", palm_root, palm_tip, 0.34, 0.52, 0.075, mats["antler"]), bone)
        # The brow tine — the forward-pointing spur every real rack carries, and
        # the part of it that is at a player's head height.
        add(limb(f"Herald_Brow_Tine_{side_name}", beam_root, Vector((0.34 * side, FORWARD * 1.86, 2.16)), 0.075, 0.016, mats["antler"], vertices=4), bone)
        # Points along the palm's outer edge.
        for index in range(5):
            fraction = 0.10 + index * 0.215
            seat = palm_root.lerp(palm_tip, fraction)
            spread = 0.30 + index * 0.055
            # Points fan FORWARD off the palm's leading edge and rise only a
            # little, the way a real palmate rack's do — a row of them standing
            # straight up reads as a comb.
            tip = seat + Vector((0.16 * side, FORWARD * spread, 0.15 + index * 0.030))
            add(limb(f"Herald_Tine_{side_name}_{index}", seat, tip, 0.070, 0.014, mats["antler"], vertices=4), bone)
        # And the Mire, growing out of the bone. It is on the ANTLERS and nowhere
        # else on the body: the crown is what the corruption is wearing.
        for index, fraction in enumerate((0.35, 0.72)):
            seat = palm_root.lerp(palm_tip, fraction)
            add(
                cone(
                    f"Herald_Crystal_{side_name}_{index}",
                    0.062 - index * 0.012,
                    0.014,
                    0.34 - index * 0.08,
                    (seat.x, seat.y, seat.z + 0.14),
                    mats["crystal"],
                    5,
                    (math.radians(FORWARD * 14.0), math.radians(-16.0 * side), 0.0),
                ),
                bone,
            )

    # ── Legs. Long, and thin against the body they carry — which is the read
    # that makes a big deer look FAST as well as heavy, and is also true of the
    # real animal.
    for leg, side, upper, mid, lower, hoof in LEGS:
        add(limb(f"Herald_Upper_{leg}", upper, mid, 0.235, 0.145, mats["hide"], vertices=5), f"leg_{leg}_upper")
        add(limb(f"Herald_Mid_{leg}", mid, lower, 0.145, 0.105, mats["hide_dark"], vertices=5), f"leg_{leg}_mid")
        add(ico(f"Herald_Joint_{leg}", tuple(lower), (0.085, 0.085, 0.085), mats["hide_dark"]), f"leg_{leg}_mid")
        add(limb(f"Herald_Lower_{leg}", lower, hoof, 0.105, 0.080, mats["hide"], vertices=5), f"leg_{leg}_lower")
        # Cloven hooves — two blocks, not one, because a single hoof reads as a
        # peg and this creature has to look like it belongs to a real order of
        # animal even after whatever happened to it.
        for index, offset in enumerate((0.045, -0.045)):
            add(
                box(
                    f"Herald_Hoof_{leg}_{index}",
                    # 0.056 and not 0.045: the hoof is TILTED forward eight
                    # degrees, so its leading bottom corner sits a centimetre
                    # below the box's own centre height and buries itself. The
                    # rest-pose contact assert catches it every time, on every
                    # family, and it is always the same mistake — a rotated part
                    # touches the ground at a corner, not at its face.
                    (hoof.x + offset * side, hoof.y + FORWARD * 0.03, 0.056),
                    (0.075, 0.155, 0.090),
                    mats["bone"],
                    (math.radians(FORWARD * 8.0), 0.0, 0.0),
                ),
                f"leg_{leg}_lower",
            )

    return parts


def build_herald_rig(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Object, bpy.types.Object]:
    """Build the Herald mesh, bind it rigidly to its armature, return both."""
    parts = build_herald_parts(mats)

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
    mesh.name = "Herald_Mesh"
    mesh.data.name = "Herald_Mesh_Data"

    bpy.ops.object.armature_add(location=(0.0, 0.0, 0.0))
    armature = bpy.context.object
    armature.name = "Herald_Rig"
    armature.data.name = "Herald_Rig_Data"
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
    modifier = mesh.modifiers.new("Herald_Armature", "ARMATURE")
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
        slot = action.slots.new(id_type="OBJECT", name="Herald") if not action.slots else action.slots[0]
        armature.animation_data.action_slot = slot
    return action


def merge(*poses: Pose) -> Pose:
    merged: Pose = {}
    for pose in poses:
        merged.update(pose)
    return merged


def gait(phase: float, reach: float = 1.0) -> Pose:
    """One frame of a four-beat walk.

    Four beats and not a trot: a 600 kg animal carrying forty kilos of antler
    keeps three feet on the ground, and the legs come down in the order
    back-left, front-left, back-right, front-right — quarter-cycle offsets, which
    is what the table below encodes. A diagonal trot on this body reads as a
    horse and makes it look light.
    """
    pose: Pose = {}
    offsets = {"front_l": 0.0, "back_l": 0.25, "front_r": 0.5, "back_r": 0.75}
    for leg, _side, _upper, _mid, _lower, _hoof in LEGS:
        theta = ((phase + offsets[leg]) % 1.0) * math.tau
        swing = math.sin(theta) * reach
        lift = max(0.0, math.sin(theta))
        front: bool = leg.startswith("front")
        # A deer's front leg folds forward at the knee and its back leg folds
        # backward at the hock, so the mid joint takes opposite signs.
        pose[f"leg_{leg}_upper"] = (-swing * (17.0 if front else 21.0), 0.0, 0.0)
        pose[f"leg_{leg}_mid"] = (lift * (30.0 if front else -34.0), 0.0, 0.0)
        pose[f"leg_{leg}_lower"] = (-lift * (18.0 if front else -14.0), 0.0, 0.0)
    return pose


def carriage(lift: float, lean: float = 0.0) -> Pose:
    """How the head and rack are carried. `lift` raises them, negative lowers.

    The antlers are a lever forty kilos long, so the neck never moves alone —
    the spine and the hump answer every degree of it. That coupling is most of
    what gives this creature its weight, and it is why the rack is animated
    through the head rather than as its own flourish.
    """
    return {
        "neck": (-26.0 * lift, 0.0, 0.0),
        "head": (-16.0 * lift, 0.0, 0.0),
        "spine": (-6.0 * lift + lean, 0.0, 0.0),
        "hips": (2.0 * lift, 0.0, 0.0),
    }


def build_animations(armature: bpy.types.Object) -> list[tuple[str, int, int]]:
    """Author every clip. Returns (name, first frame, last frame) per clip."""
    clips: list[tuple[str, int, int]] = []

    # ── idle-loop — 3.5 s. It breathes, and the rack moves like weather.
    #
    # Long and slow on purpose. Every other idle in the roster is a creature
    # waiting; this one is a creature that has never once needed to hurry. The
    # only real motion is the head swinging a few degrees and the antlers
    # answering it a beat late — which at three and a half metres of span is an
    # enormous amount of movement in world space out of almost none in degrees.
    new_action(armature, "idle" + LOOP_SUFFIX)
    for frame, lift, sway, breath in (
        (1, 0.0, 0.0, 0.0),
        (28, 0.10, 4.5, 0.020),
        (54, -0.06, 1.0, 0.008),
        (80, 0.06, -5.0, 0.018),
        (100, -0.03, -1.5, 0.006),
        (106, 0.0, 0.0, 0.0),  # repeats frame 1 exactly, so the loop has no seam
    ):
        apply_pose(
            armature,
            frame,
            merge(gait(0.0, 0.0), carriage(lift), {"head": (carriage(lift)["head"][0], 0.0, sway), "neck": (carriage(lift)["neck"][0], sway * 0.3, 0.0)}),
            {"spine": (0.0, 0.0, breath)},
        )
    clips.append(("idle" + LOOP_SUFFIX, 1, 1 + IDLE_FRAMES))

    # ── locomotion-loop — 1.6 s. The walk.
    #
    # Slow, four-beat, and the body rocks nose-to-tail rather than side to side —
    # the mass is high and forward, over the hump, so it pitches. The head bobs
    # against the stride at half its frequency, which is what a heavy-headed
    # ungulate does and the reason the rack never quite settles.
    new_action(armature, "locomotion" + LOOP_SUFFIX)
    for step in range(LOCOMOTION_FRAMES + 1):
        phase = step / LOCOMOTION_FRAMES
        pitch = math.sin(phase * math.tau * 2.0) * 2.4
        bob = math.sin(phase * math.tau) * 0.09
        heave = abs(math.sin(phase * math.tau * 2.0)) * 0.030
        apply_pose(
            armature,
            1 + step,
            merge(
                gait(phase),
                carriage(-0.12 + bob, pitch),
                {"tail": (math.sin(phase * math.tau) * 5.0, 0.0, math.sin(phase * math.tau + 1.0) * 6.0)},
            ),
            {"spine": (0.0, 0.0, heave)},
        )
    clips.append(("locomotion" + LOOP_SUFFIX, 1, 1 + LOCOMOTION_FRAMES))

    # ── attack_tell — 0.65 s. It raises the crown.
    #
    # The head goes UP and BACK until the palms are above its own shoulders, the
    # forelegs plant, and the whole body loads onto the hind pair. Three and a
    # half metres of antler rising is the largest silhouette change in the game
    # and it is visible from anywhere on the island — which is the point: a
    # Herald winding up should be readable by somebody who is not even in the
    # fight yet.
    new_action(armature, "attack_tell")
    apply_pose(armature, 1, merge(gait(0.0, 0.0), carriage(-0.10)))
    apply_pose(
        armature,
        7,
        merge(gait(0.0, 0.0), carriage(0.62), {"leg_front_l_upper": (16.0, 0.0, 0.0), "leg_front_r_upper": (16.0, 0.0, 0.0)}),
        {"spine": (0.0, 0.0, 0.06)},
    )
    hold_pose = merge(
        gait(0.0, 0.0),
        carriage(1.0),
        {
            "leg_front_l_upper": (24.0, 0.0, 0.0), "leg_front_r_upper": (24.0, 0.0, 0.0),
            "leg_front_l_mid": (-18.0, 0.0, 0.0), "leg_front_r_mid": (-18.0, 0.0, 0.0),
            "tail": (-14.0, 0.0, 0.0),
        },
    )
    apply_pose(armature, 13, hold_pose, {"spine": (0.0, 0.0, 0.11)})
    # Holds the extreme for the last third. A tell still moving when the strike
    # begins never registers as a warning.
    apply_pose(armature, 1 + TELL_FRAMES, hold_pose, {"spine": (0.0, 0.0, 0.11)})
    clips.append(("attack_tell", 1, 1 + TELL_FRAMES))

    # ── attack — 0.45 s. The sweep.
    #
    # Frame 1 is the tell's last frame exactly. It drives the rack DOWN and
    # ACROSS in one motion — a real deer's antler strike is a shove of the whole
    # body through the neck, never a swing of the head — so the spine leads, the
    # neck follows, and the palms end up scything through the space in front of
    # its forelegs. That arc is why `attack_range_m` is 4.2 and why standing in
    # front of it is not a position, it is a decision.
    new_action(armature, "attack")
    apply_pose(armature, 1, hold_pose, {"spine": (0.0, 0.0, 0.11)})
    apply_pose(
        armature,
        5,
        merge(
            gait(0.0, 0.0),
            carriage(-0.85, -14.0),
            {"head": (14.0, 0.0, -22.0), "neck": (22.0, 0.0, -12.0), "tail": (10.0, 0.0, 0.0)},
        ),
        {"spine": (0.0, FORWARD * 0.16, -0.05)},
    )
    apply_pose(
        armature,
        9,
        merge(gait(0.0, 0.0), carriage(-0.55, -6.0), {"head": (8.0, 0.0, -12.0), "neck": (12.0, 0.0, -6.0)}),
        {"spine": (0.0, FORWARD * 0.07, -0.02)},
    )
    apply_pose(armature, 1 + ATTACK_FRAMES, merge(gait(0.0, 0.0), carriage(-0.15)))
    clips.append(("attack", 1, 1 + ATTACK_FRAMES))

    # ── hit — 0.3 s. A shudder, and the crown comes up.
    #
    # It does not stagger. What it does is LOOK AT YOU: the head lifts and turns
    # toward the hit, which at this size is a threat rather than a flinch, and is
    # the read a player should get for hurting something that does not care.
    new_action(armature, "hit")
    apply_pose(armature, 1, merge(gait(0.0, 0.0), carriage(-0.10)))
    apply_pose(
        armature,
        3,
        merge(gait(0.0, 0.0), carriage(0.30), {"head": (-6.0, 0.0, 14.0), "spine": (3.0, 5.0, 0.0)}),
        {"spine": (0.0, 0.0, 0.02)},
    )
    apply_pose(
        armature,
        6,
        merge(gait(0.0, 0.0), carriage(0.12), {"head": (-2.0, 0.0, -6.0), "spine": (1.0, -3.0, 0.0)}),
    )
    apply_pose(armature, 1 + HIT_FRAMES, merge(gait(0.0, 0.0), carriage(-0.10)))
    clips.append(("hit", 1, 1 + HIT_FRAMES))

    # ── death — 2.0 s. The longest death in the game, and it earns it.
    #
    # The front legs go first — they always do on a heavy-headed animal — so the
    # chest comes down and the rack drives into the ground ahead of it, and only
    # then does the back end fold and the whole length of it roll onto its side.
    # The head is last, and it goes down slowly, because it is the heaviest thing
    # on the creature and there is nothing left holding it up. Ends flat and
    # still: the corpse and the fragments inherit this pose.
    new_action(armature, "death")
    apply_pose(armature, 1, merge(gait(0.0, 0.0), carriage(-0.10)))
    apply_pose(
        armature,
        10,
        merge(gait(0.0, 0.0), carriage(0.85), {"tail": (-18.0, 0.0, 0.0)}),
        {"spine": (0.0, 0.0, 0.09)},
    )
    front_buckle: Pose = {}
    for leg, _side, _u, _m, _l, _h in LEGS:
        if leg.startswith("front"):
            front_buckle[f"leg_{leg}_upper"] = (54.0, 0.0, 0.0)
            front_buckle[f"leg_{leg}_mid"] = (-72.0, 0.0, 0.0)
            front_buckle[f"leg_{leg}_lower"] = (34.0, 0.0, 0.0)
    apply_pose(
        armature,
        26,
        merge(gait(0.0, 0.0), front_buckle, carriage(-0.90, 22.0), {"head": (26.0, 0.0, 10.0), "hips": (-8.0, 0.0, 0.0)}),
        {"spine": (0.0, FORWARD * 0.10, -0.42)},
    )
    collapse: Pose = dict(front_buckle)
    for leg, side, _u, _m, _l, _h in LEGS:
        if not leg.startswith("front"):
            collapse[f"leg_{leg}_upper"] = (30.0, 0.0, -34.0 * side)
            collapse[f"leg_{leg}_mid"] = (-46.0, 0.0, 0.0)
            collapse[f"leg_{leg}_lower"] = (22.0, 0.0, 0.0)
    apply_pose(
        armature,
        46,
        merge(gait(0.0, 0.0), collapse, carriage(-1.0, 30.0), {"spine": (30.0, 54.0, 0.0), "hips": (-10.0, 42.0, 0.0), "head": (34.0, 0.0, 26.0), "neck": (30.0, 22.0, 0.0), "tail": (14.0, 0.0, 0.0)}),
        {"spine": (0.0, FORWARD * 0.14, -0.86)},
    )
    apply_pose(
        armature,
        1 + DEATH_FRAMES,
        merge(gait(0.0, 0.0), collapse, carriage(-1.0, 32.0), {"spine": (32.0, 62.0, 0.0), "hips": (-11.0, 48.0, 0.0), "head": (40.0, 0.0, 30.0), "neck": (34.0, 26.0, 0.0), "tail": (16.0, 0.0, 0.0)}),
        {"spine": (0.0, FORWARD * 0.16, -0.98)},
    )
    clips.append(("death", 1, 1 + DEATH_FRAMES))

    if [name for name, _, _ in clips] != EXPECTED_ANIMATIONS:
        raise RuntimeError("Mire Herald animation specification and expected clip list diverged")
    return clips


# ── The death fragments ───────────────────────────────────────────────────────


def build_fragment_antler(mats: dict[str, bpy.types.Material]) -> None:
    """A broken piece of palm with two points and a crystal still growing on it.

    The trophy. It is the only debris piece in the roster a player would want to
    keep, and it is deliberately big — a Herald that died left something behind
    that is nearly a metre across, and finding it later should mean something.
    """
    palm("Fragment_Antler_Palm", Vector((-0.30, 0.0, 0.05)), Vector((0.34, 0.10, 0.09)), 0.28, 0.40, 0.07, mats["antler"])
    limb("Fragment_Antler_Tine_0", (0.06, 0.06, 0.08), (0.20, 0.34, 0.16), 0.060, 0.012, mats["antler"], vertices=4)
    limb("Fragment_Antler_Tine_1", (0.22, 0.02, 0.09), (0.42, 0.26, 0.19), 0.052, 0.012, mats["antler"], vertices=4)
    cone("Fragment_Antler_Crystal", 0.050, 0.012, 0.24, (0.02, 0.02, 0.20), mats["crystal"], 5, (math.radians(18), math.radians(-14), 0.0))


def build_fragment_hide(mats: dict[str, bpy.types.Material]) -> None:
    """Sodden hide and a length of rib, the way a bog gives a body back."""
    ico("Fragment_Hide_Sheet", (0.0, 0.0, 0.035), (0.24, 0.19, 0.035), mats["hide"], (math.radians(7), math.radians(-10), 0.0))
    ico("Fragment_Hide_Fold", (0.14, 0.08, 0.055), (0.10, 0.085, 0.032), mats["hide_dark"], (math.radians(26), 0.0, math.radians(18)))
    box("Fragment_Hide_Rib", (-0.10, -0.04, 0.06), (0.05, 0.34, 0.05), mats["bone"], (math.radians(9), math.radians(14), math.radians(-24)))


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
    """Export the rigged Herald.

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
        set_visible(record, record["name"] == "enemy_mire_herald")
    original_resolution = (scene.render.resolution_x, scene.render.resolution_y)
    original_camera = (camera.location.copy(), camera.data.ortho_scale)
    scene.render.resolution_x = cell
    scene.render.resolution_y = cell
    focus = armature.location.copy()
    # Framed on the upper body, not the whole creature: the legs are half the
    # height and none of the difference between these poses is in them.
    camera.data.ortho_scale = 4.6
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
        tile_path = PREVIEW_DIR / f"mire_herald_pose_tile_{index}.png"
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

    output = bpy.data.images.new("Herald_Pose_Sheet", width=columns * cell, height=rows * cell, alpha=True)
    output.pixels = sheet.reshape(-1)
    output.filepath_raw = str(PREVIEW_DIR / "mire_herald_pose_sheet.png")
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

    bpy.context.scene.render.fps = FPS
    reset_materials()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.actions, bpy.data.armatures, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)

    mats = {
        # The fifth palette, and the one that closes the loop. A body the colour
        # of the peat it came out of — `wood_charred` hide over `peat` shadow —
        # with `bone` ribs and hooves showing through it, and BONE-coloured
        # antlers so the crown is the brightest thing on the creature from any
        # distance. The Mire's purple appears only as crystal on the antler
        # palms: the corruption is wearing the crown, and it is the same purple
        # this creature leaves on the ground behind it.
        # `peat` over `wood_charred`, not the other way round. The first pass
        # led with charred wood and the body came back reading as a black
        # cut-out — at night, against a dark sky, a silhouette with no internal
        # value at all stops looking like a creature and starts looking like a
        # hole. Peat is barely lighter, and barely is enough.
        "hide": mat("peat"),
        "hide_dark": mat("wood_charred"),
        "bone": mat("bone"),
        "antler": mat("wood_dead_cut"),
        "crystal": mat("crystal"),
        "eye": mat("critical"),
        "ground": mat("preview_ground"),
        "scale": mat("reference_blue"),
    }

    records: list[dict] = []

    armature, mesh = build_herald_rig(mats)
    clips = build_animations(armature)
    records.append(create_rigged_asset("enemy_mire_herald", "enemy", armature, mesh, clips, (0.0, 0.0, 0.0)))

    statics: list[tuple[str, str, Callable[[], None], tuple[float, float, float]]] = [
        ("enemy_mire_herald_fragment_antler", "debris", lambda: build_fragment_antler(mats), (2.30, 0.55, 0.0)),
        ("enemy_mire_herald_fragment_hide", "debris", lambda: build_fragment_hide(mats), (2.95, -0.30, 0.0)),
    ]
    for name, family, builder, location in statics:
        records.append(create_static_asset(name, family, builder, location))

    if [record["name"] for record in records] != EXPECTED_NAMES:
        raise RuntimeError("Mire Herald specification and expected export list diverged")

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
        box("Scale_Post", (-2.35, -1.20, 0.9), (0.07, 0.07, 1.8), mats["scale"]),
        box("Scale_Tick_50", (-2.26, -1.20, 0.50), (0.22, 0.07, 0.024), mats["scale"]),
        box("Scale_Tick_100", (-2.26, -1.20, 1.00), (0.28, 0.07, 0.030), mats["scale"]),
        box("Scale_Tick_150", (-2.26, -1.20, 1.50), (0.22, 0.07, 0.024), mats["scale"]),
        box("Scale_Tick_180", (-2.26, -1.20, 1.80), (0.34, 0.07, 0.034), mats["scale"]),
        box("Scale_20cm_Cube", (-2.08, -1.28, 0.10), (0.20, 0.20, 0.20), mats["scale"]),
    ]
    move_to_collection(scale_parts, preview_collection)
    # Nearly head-on, unlike every other family's three-quarter preview. This
    # creature's whole read is the SPAN of its rack, and a three-quarter shot
    # foreshortens one palm into its own shoulders and hides the thing the model
    # is for. It faces -Y, so the camera sits out in front of it.
    camera.data.ortho_scale = 6.6
    camera.location = (1.6, -8.2, 3.10)
    look_at(camera, (0.0, 0.30, 1.35))
    scene.render.filepath = str(PREVIEW_DIR / "mire_herald_preview.png")
    bpy.ops.render.render(write_still=True)

    reference_cube = scale_parts.pop()
    for scale_part in scale_parts:
        bpy.data.objects.remove(scale_part, do_unlink=True)
    reference_cube.location = (1.55, 0.85, 0.10)

    render_pose_sheet(
        scene,
        camera,
        armature,
        records,
        [
            ("idle" + LOOP_SUFFIX, "standing", 28),
            ("locomotion" + LOOP_SUFFIX, "walk contact", 12),
            ("locomotion" + LOOP_SUFFIX, "walk pass", 36),
            ("attack_tell", "crown raised", 16),
            ("attack", "sweep", 5),
            ("hit", "it looks at you", 3),
            ("death", "front legs go", 26),
            ("death", "down", 1 + DEATH_FRAMES),
        ],
        columns=4,
        cell=460,
    )

    bpy.data.objects.remove(reference_cube, do_unlink=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "enemy_mire_herald.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(
        f"Built {len(records)} Mire Herald assets ({total_polygons} polygons total), "
        f"{len(clips)} clips on {len(armature.data.bones)} bones"
    )


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
