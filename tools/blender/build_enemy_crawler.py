"""Build MIRE's prototype enemy set (asset batch A-006).

Run with:
  Blender --background --python tools/blender/build_enemy_crawler.py

Outputs four metre-scale GLBs — one rigged and animated Mire crawler, its spawn
nest, and two death fragments — plus an editable Blender source, a JSON catalog,
two preview renders, and a pose contact sheet. Geometry, rig and animation are
deterministic.

This is the first rigged batch, so three things here are new and are the parts
worth reading before extending it:

Rigid skinning, not automatic weights. Every mesh part is built separately, has
all of its vertices assigned to exactly one vertex group named for its bone at
weight 1.0, and only then is joined into one mesh. Automatic weights would smear
influence across a flat-shaded chitin plate and warp it; rigid, one-bone-per-part
skinning is what a low-poly insect actually wants, and it is reproducible.

Every action keys every animated bone. `apply_pose` writes a full pose — bones
absent from a keyframe's dict are keyed at rest, not left alone. Blender keeps
whatever pose was last set when a channel is missing, so a partial action would
inherit leftovers from whichever action happened to be built before it, and the
exported clip would differ depending on build order.

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
from mire_art import mat, radial, around, reset_materials  # noqa: E402
from godot_import_lock import import_cache_guard  # noqa: E402
import numpy as np
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "enemies"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

EXPECTED_NAMES = [
    "enemy_crawler",
    "enemy_crawler_nest",
    "enemy_crawler_fragment_shell",
    "enemy_crawler_fragment_leg",
]

## Godot 4 sets an imported animation to loop when its name ends in "-loop".
## Idle and locomotion are the only two clips that may loop: a tell, a strike, a
## flinch and a death must each play once and stop, or the enemy twitches
## forever on a corpse.
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

## docs/DESIGN.md §6: enemies telegraph clearly with roughly a 0.4 s tell. That
## is the whole reason the tell is a separate clip from the attack — the tell is
## the readable window, the attack is the commit, and gameplay must be able to
## time them independently.
TELL_FRAMES = 12
ATTACK_FRAMES = 12

## Forward is -Y in Blender, which becomes -Z after the exporter's +Y-up
## conversion — the direction Godot treats as a node's forward.
FORWARD = -1.0


# ── Primitives ────────────────────────────────────────────────────────────────


def assign(obj: bpy.types.Object, mat: bpy.types.Material) -> bpy.types.Object:
    obj.data.materials.append(mat)
    for polygon in obj.data.polygons:
        polygon.use_smooth = False
    return obj


def box(
    name: str,
    location: tuple[float, float, float],
    dimensions: tuple[float, float, float],
    mat: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
    bevel: float = 0.0,
) -> bpy.types.Object:
    """Bevel-free box (D-124).

    This override predates F-198's discovery that it still copied
    ``mire_art.box()``'s bevel-applying body verbatim, despite looking like
    the ward-set bevel-free pattern at a glance. This family's tracker row
    claims a byte-identical rebuild; the bevel modifier changes float bytes
    between otherwise identical background exports on Apple Silicon (F-057).
    ``bevel`` is accepted and ignored so the five call sites below read
    unchanged.
    """
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = (dimensions[0] * 0.5, dimensions[1] * 0.5, dimensions[2] * 0.5)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, mat)


def cone(
    name: str,
    radius_bottom: float,
    radius_top: float,
    depth: float,
    location: tuple[float, float, float],
    mat: bpy.types.Material,
    vertices: int = 6,
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
    return assign(obj, mat)


def ico(
    name: str,
    location: tuple[float, float, float],
    scale: tuple[float, float, float],
    mat: bpy.types.Material,
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
    return assign(obj, mat)


def strut(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    thickness: float,
    mat: bpy.types.Material,
) -> bpy.types.Object:
    """A tapering limb segment spanning two points, aligned along its own Z.

    Legs are the one part of the crawler that is easier to describe by where it
    begins and ends than by a centre and a rotation, and the bone that drives
    each segment is described the same way — so both come from one pair of
    points and cannot disagree.
    """
    head = Vector(start)
    tail = Vector(end)
    axis = tail - head
    length = axis.length
    bpy.ops.mesh.primitive_cone_add(
        vertices=6,
        radius1=thickness * 0.5,
        radius2=thickness * 0.34,
        depth=length,
        location=(head + tail) * 0.5,
        rotation=axis.to_track_quat("Z", "Y").to_euler(),
    )
    obj = bpy.context.object
    obj.name = name
    return assign(obj, mat)


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


# ── The crawler's skeleton ────────────────────────────────────────────────────
#
# One table, used three times: to build the armature, to name the vertex groups
# the mesh parts bind to, and to drive the poses. Anything that needs to know
# where a joint is reads it from here, so a limb and the bone inside it cannot
# drift apart.
#
# Legs are lettered fl/fr/bl/br (front/back, left/right). "Left" is +X.

HIP_Z = 0.30

## The foot JOINT sits fractionally above the ground so the foot GEOMETRY lands
## on it. A leg segment is a tapered cone spanning hip→knee→foot, and its end cap
## is perpendicular to a tilted axis, so the cap's leading corner hangs 3.3 mm
## below the joint the bone ends at. Placing the joint at exactly z = 0 therefore
## buries the claws, and the rest-pose contact assert below catches it — which is
## the assert doing its job, not a tolerance to relax. Ground contact is a fact
## about the mesh, not about the skeleton.
FOOT_Z = 0.0033

## Six legs, in a tripod gait: front-left, middle-right and back-left swing
## together while the opposite three carry the body, then they swap. It is what
## real insects do and the reason is mechanical — three planted feet are the
## minimum for a stable base, so the crawler never has a frame where it should
## fall over. A four-legged diagonal gait on a body this wide reads as a limp.
LEGS: list[tuple[str, float, float, float]] = [
    # (leg id, side sign on X, hip Y, gait phase offset)
    ("fl", 1.0, FORWARD * 0.19, 0.0),
    ("fr", -1.0, FORWARD * 0.19, 0.5),
    ("ml", 1.0, FORWARD * 0.02, 0.5),
    ("mr", -1.0, FORWARD * 0.02, 0.0),
    ("bl", 1.0, FORWARD * -0.16, 0.0),
    ("br", -1.0, FORWARD * -0.16, 0.5),
]


def leg_points(side: float, hip_y: float) -> tuple[Vector, Vector, Vector]:
    """Hip, knee and foot of one leg, in world space.

    The knee sits high and wide of the body so the silhouette reads as an insect
    from any angle — a crawler with its knees tucked under it reads as a lump in
    fog, which is the one thing an enemy must never do.
    """
    hip = Vector((0.13 * side, hip_y, HIP_Z))
    knee = Vector((0.32 * side, hip_y + FORWARD * 0.05, HIP_Z + 0.13))
    foot = Vector((0.37 * side, hip_y + FORWARD * 0.09, FOOT_Z))
    return hip, knee, foot


def bone_table() -> list[tuple[str, Vector, Vector, str | None]]:
    """(name, head, tail, parent) for every bone, in creation order."""
    bones: list[tuple[str, Vector, Vector, str | None]] = [
        ("root", Vector((0.0, 0.0, 0.0)), Vector((0.0, 0.0, 0.09)), None),
        ("body", Vector((0.0, FORWARD * -0.16, HIP_Z)), Vector((0.0, FORWARD * 0.18, HIP_Z + 0.02)), "root"),
        ("abdomen", Vector((0.0, FORWARD * -0.16, HIP_Z)), Vector((0.0, FORWARD * -0.44, HIP_Z + 0.06)), "body"),
        ("head", Vector((0.0, FORWARD * 0.18, HIP_Z + 0.02)), Vector((0.0, FORWARD * 0.40, HIP_Z - 0.01)), "body"),
        ("jaw", Vector((0.0, FORWARD * 0.36, HIP_Z - 0.06)), Vector((0.0, FORWARD * 0.56, HIP_Z - 0.10)), "head"),
    ]
    for leg, side, hip_y, _phase in LEGS:
        hip, knee, foot = leg_points(side, hip_y)
        bones.append((f"leg_{leg}_upper", hip, knee, "body"))
        bones.append((f"leg_{leg}_lower", knee, foot, f"leg_{leg}_upper"))
    return bones


DEFORM_BONES = [name for name, _, _, _ in bone_table() if name != "root"]


# ── The crawler's mesh ────────────────────────────────────────────────────────


def build_crawler_parts(mats: dict[str, bpy.types.Material]) -> list[tuple[bpy.types.Object, str]]:
    """Every mesh part paired with the single bone that drives it."""
    parts: list[tuple[bpy.types.Object, str]] = []

    def add(obj: bpy.types.Object, bone: str) -> None:
        parts.append((obj, bone))

    # Thorax: a wide, low, bevelled carapace. Wide reads as "low and fast" in
    # first-person; a tall body would read as a humanoid at fog distance.
    add(box("Crawler_Thorax", (0.0, FORWARD * 0.0, HIP_Z + 0.03), (0.34, 0.46, 0.20), mats["chitin"], bevel=0.03), "body")
    add(box("Crawler_Plate_1", (0.0, FORWARD * 0.06, HIP_Z + 0.14), (0.28, 0.22, 0.06), mats["chitin_dark"], (math.radians(-7), 0.0, 0.0), 0.02), "body")
    add(box("Crawler_Plate_2", (0.0, FORWARD * -0.09, HIP_Z + 0.15), (0.24, 0.16, 0.05), mats["chitin_dark"], (math.radians(6), 0.0, 0.0), 0.02), "body")
    add(box("Crawler_Collar", (0.0, FORWARD * 0.20, HIP_Z + 0.02), (0.28, 0.08, 0.16), mats["chitin_dark"], bevel=0.02), "body")

    # Abdomen and the crystal growth that marks it as the Mire's, not nature's.
    add(box("Crawler_Waist", (0.0, FORWARD * -0.21, HIP_Z + 0.02), (0.20, 0.10, 0.14), mats["chitin_dark"], bevel=0.02), "body")
    for index, (x, spike) in enumerate(((0.10, 0.09), (-0.10, 0.09), (0.0, 0.12))):
        add(cone(f"Crawler_Spine_{index}", 0.028, 0.006, spike, (x, FORWARD * (0.02 - index * 0.06), HIP_Z + 0.17 + spike * 0.5), mats["chitin_light"], 5, (math.radians(-20), 0.0, 0.0)), "body")
    add(ico("Crawler_Abdomen", (0.0, FORWARD * -0.32, HIP_Z + 0.04), (0.16, 0.20, 0.15), mats["chitin"], subdivisions=2), "abdomen")
    add(cone("Crawler_Crystal_1", 0.055, 0.012, 0.20, (0.0, FORWARD * -0.30, HIP_Z + 0.19), mats["crystal"], 5, (math.radians(-16), 0.0, 0.0)), "abdomen")
    add(cone("Crawler_Crystal_2", 0.04, 0.01, 0.14, (0.09, FORWARD * -0.38, HIP_Z + 0.14), mats["crystal"], 5, (math.radians(-22), math.radians(26), 0.0)), "abdomen")
    add(cone("Crawler_Crystal_3", 0.04, 0.01, 0.13, (-0.09, FORWARD * -0.38, HIP_Z + 0.13), mats["crystal"], 5, (math.radians(-22), math.radians(-26), 0.0)), "abdomen")
    add(ico("Crawler_Sac", (0.0, FORWARD * -0.44, HIP_Z - 0.01), (0.08, 0.09, 0.07), mats["glow"]), "abdomen")

    # Head: a blunt wedge, two big emissive eyes. The eyes are the aim point and
    # the read at distance, so they are oversized on purpose.
    add(box("Crawler_Head", (0.0, FORWARD * 0.28, HIP_Z + 0.01), (0.26, 0.22, 0.17), mats["chitin"], bevel=0.03), "head")
    add(box("Crawler_Brow", (0.0, FORWARD * 0.30, HIP_Z + 0.10), (0.22, 0.14, 0.05), mats["chitin_dark"], (math.radians(-12), 0.0, 0.0), 0.015), "head")
    add(ico("Crawler_Eye_L", (0.085, FORWARD * 0.37, HIP_Z + 0.04), (0.045, 0.035, 0.045), mats["eye"], subdivisions=2), "head")
    add(ico("Crawler_Eye_R", (-0.085, FORWARD * 0.37, HIP_Z + 0.04), (0.045, 0.035, 0.045), mats["eye"], subdivisions=2), "head")
    for index, side in enumerate((1.0, -1.0)):
        add(ico(f"Crawler_Ocellus_{index}", (0.05 * side, FORWARD * 0.33, HIP_Z + 0.11), (0.018, 0.014, 0.018), mats["eye"]), "head")
        add(cone(f"Crawler_Palp_{index}", 0.022, 0.006, 0.13, (0.10 * side, FORWARD * 0.42, HIP_Z - 0.09), mats["chitin_light"], 5, (math.radians(FORWARD * 62), 0.0, math.radians(-24 * side))), "jaw")
    add(box("Crawler_Jaw_Plate", (0.0, FORWARD * 0.40, HIP_Z - 0.08), (0.18, 0.16, 0.06), mats["chitin_dark"], bevel=0.015), "jaw")
    add(cone("Crawler_Mandible_L", 0.035, 0.008, 0.22, (0.075, FORWARD * 0.46, HIP_Z - 0.08), mats["chitin_light"], 5, (math.radians(FORWARD * 78), 0.0, math.radians(-10))), "jaw")
    add(cone("Crawler_Mandible_R", 0.035, 0.008, 0.22, (-0.075, FORWARD * 0.46, HIP_Z - 0.08), mats["chitin_light"], 5, (math.radians(FORWARD * 78), 0.0, math.radians(10))), "jaw")

    for leg, side, hip_y, _phase in LEGS:
        hip, knee, foot = leg_points(side, hip_y)
        add(strut(f"Crawler_Leg_{leg}_Upper", hip, knee, 0.085, mats["chitin"]), f"leg_{leg}_upper")
        add(strut(f"Crawler_Leg_{leg}_Lower", knee, foot, 0.065, mats["chitin_dark"]), f"leg_{leg}_lower")
        add(ico(f"Crawler_Knee_{leg}", knee, (0.045, 0.045, 0.045), mats["chitin_light"]), f"leg_{leg}_upper")

    return parts


def build_crawler_rig(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Object, bpy.types.Object]:
    """Build the crawler mesh, bind it rigidly to its armature, return both."""
    parts = build_crawler_parts(mats)

    # Bind BEFORE joining: a vertex group per part, every vertex at weight 1.0.
    # After the join these groups are the only record of which bone owns which
    # face, so anything not assigned here would be left behind by the armature.
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
    mesh.name = "Crawler_Mesh"
    mesh.data.name = "Crawler_Mesh_Data"

    bpy.ops.object.armature_add(location=(0.0, 0.0, 0.0))
    armature = bpy.context.object
    armature.name = "Crawler_Rig"
    armature.data.name = "Crawler_Rig_Data"
    bpy.ops.object.mode_set(mode="EDIT")
    edit_bones = armature.data.edit_bones
    for bone in list(edit_bones):
        edit_bones.remove(bone)
    for name, head, tail, parent in bone_table():
        bone = edit_bones.new(name)
        bone.head = head
        bone.tail = tail
        bone.use_deform = name != "root"
        if parent is not None:
            bone.parent = edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")

    mesh.parent = armature
    modifier = mesh.modifiers.new("Crawler_Armature", "ARMATURE")
    modifier.object = armature

    for pose_bone in armature.pose.bones:
        pose_bone.rotation_mode = "XYZ"
    return armature, mesh


# ── Animation ─────────────────────────────────────────────────────────────────
#
# Poses are plain dictionaries of bone -> (rx, ry, rz) in DEGREES, plus an
# optional "@loc" entry per bone for translation in metres. Degrees because
# every one of these numbers was chosen by eye and will be re-tuned by eye.

Pose = dict[str, tuple[float, float, float]]


def apply_pose(armature: bpy.types.Object, frame: int, pose: Pose, offsets: dict[str, tuple[float, float, float]] | None = None) -> None:
    """Key EVERY animated bone at `frame`, defaulting to rest.

    The defaulting is the point. Blender leaves an unkeyed channel at whatever
    value it currently holds, so an action that keys only the bones it moves
    silently inherits the tail of whichever action was built before it, and the
    exported clip changes if the build order changes.
    """
    offsets = offsets or {}
    for pose_bone in armature.pose.bones:
        rotation = pose.get(pose_bone.name, (0.0, 0.0, 0.0))
        pose_bone.rotation_euler = tuple(math.radians(angle) for angle in rotation)
        pose_bone.keyframe_insert("rotation_euler", frame=frame)
        pose_bone.location = offsets.get(pose_bone.name, (0.0, 0.0, 0.0))
        pose_bone.keyframe_insert("location", frame=frame)


def clear_pose(armature: bpy.types.Object) -> None:
    """Return every bone to rest.

    Detaching the action does NOT do this. Blender keeps the pose the action
    last evaluated, so the armature stays frozen in whatever frame was set — for
    this rig, the final collapsed frame of the death clip. Measuring or
    exporting after that ships a corpse as the rest pose.
    """
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
    # Blender 4.4+ actions hold their channels in a slot; assigning the action
    # alone leaves animation_data pointing at nothing to write into.
    if hasattr(armature.animation_data, "action_slot"):
        slot = action.slots.new(id_type="OBJECT", name="Crawler") if not action.slots else action.slots[0]
        armature.animation_data.action_slot = slot
    return action


def leg_pose(phase: float, reach: float = 34.0, lift: float = 34.0) -> Pose:
    """One frame of the tripod walk cycle.

    [param phase] runs 0..1 over the cycle; each leg's own offset comes from the
    LEGS table, so the gait is defined in exactly one place and adding or moving
    a leg cannot leave the animation describing a different creature than the
    mesh does.
    """
    pose: Pose = {}
    for leg, _side, _hip_y, offset in LEGS:
        theta = (phase + offset) % 1.0 * math.tau
        swing = math.sin(theta) * reach
        # Foot clears the ground only on the forward half of the stroke.
        clearance = max(0.0, math.sin(theta)) * lift
        pose[f"leg_{leg}_upper"] = (swing, 0.0, 0.0)
        pose[f"leg_{leg}_lower"] = (-clearance, 0.0, 0.0)
    return pose


def crouch(amount: float) -> Pose:
    """Legs folding under the body — used by the tell, the flinch and the death."""
    pose: Pose = {}
    for leg, _side, _hip_y, _phase in LEGS:
        pose[f"leg_{leg}_upper"] = (-14.0 * amount, 0.0, 0.0)
        pose[f"leg_{leg}_lower"] = (30.0 * amount, 0.0, 0.0)
    return pose


def merge(*poses: Pose) -> Pose:
    merged: Pose = {}
    for pose in poses:
        merged.update(pose)
    return merged


def build_animations(armature: bpy.types.Object) -> list[tuple[str, int, int]]:
    """Author every clip. Returns (name, first frame, last frame) per clip."""
    clips: list[tuple[str, int, int]] = []

    # idle-loop — 2 s. Breathing, a slow head sway, and crystals riding the body.
    # Frame 61 repeats frame 1 exactly so the loop has no seam.
    new_action(armature, "idle" + LOOP_SUFFIX)
    for frame, body_pitch, head_yaw, sway in (
        (1, 0.0, 0.0, 0.0),
        (16, -2.5, 5.0, 0.010),
        (31, 0.0, 0.0, 0.0),
        (46, -2.5, -5.0, 0.010),
        (61, 0.0, 0.0, 0.0),
    ):
        apply_pose(
            armature,
            frame,
            merge({"body": (body_pitch, 0.0, 0.0), "head": (0.0, 0.0, head_yaw), "abdomen": (-body_pitch * 0.6, 0.0, 0.0)}, crouch(0.12)),
            {"body": (0.0, 0.0, sway)},
        )
    clips.append(("idle" + LOOP_SUFFIX, 1, 61))

    # locomotion-loop — 0.8 s cycle. Body counter-rocks against the gait.
    new_action(armature, "locomotion" + LOOP_SUFFIX)
    cycle_frames = 24
    for step in range(cycle_frames + 1):
        phase = step / cycle_frames
        bob = math.sin(phase * math.tau * 2.0) * 0.018
        roll = math.sin(phase * math.tau) * 4.0
        apply_pose(
            armature,
            1 + step,
            merge(
                leg_pose(phase),
                {"body": (-3.0, roll, 0.0), "head": (2.0, -roll * 0.5, 0.0), "abdomen": (2.0, -roll, 0.0)},
            ),
            {"body": (0.0, 0.0, bob)},
        )
    clips.append(("locomotion" + LOOP_SUFFIX, 1, 1 + cycle_frames))

    # attack_tell — 0.4 s. Rear up, jaws open, crystals raised. This clip exists
    # to be READ, so it holds its extreme for the back half rather than easing
    # straight into the strike.
    new_action(armature, "attack_tell")
    apply_pose(armature, 1, crouch(0.12))
    apply_pose(armature, 5, merge(crouch(0.5), {"body": (-22.0, 0.0, 0.0), "head": (-10.0, 0.0, 0.0), "jaw": (26.0, 0.0, 0.0), "abdomen": (16.0, 0.0, 0.0)}))
    apply_pose(armature, 1 + TELL_FRAMES, merge(crouch(0.62), {"body": (-27.0, 0.0, 0.0), "head": (-13.0, 0.0, 0.0), "jaw": (34.0, 0.0, 0.0), "abdomen": (20.0, 0.0, 0.0)}))
    clips.append(("attack_tell", 1, 1 + TELL_FRAMES))

    # attack — 0.4 s. Starts where the tell ended, so the two clips chain without
    # a pop, snaps through the bite by frame 5, then recovers.
    new_action(armature, "attack")
    apply_pose(armature, 1, merge(crouch(0.62), {"body": (-27.0, 0.0, 0.0), "head": (-13.0, 0.0, 0.0), "jaw": (34.0, 0.0, 0.0), "abdomen": (20.0, 0.0, 0.0)}))
    apply_pose(armature, 5, merge(crouch(0.1), {"body": (16.0, 0.0, 0.0), "head": (14.0, 0.0, 0.0), "jaw": (-6.0, 0.0, 0.0), "abdomen": (-12.0, 0.0, 0.0)}), {"body": (0.0, FORWARD * 0.12, -0.02)})
    apply_pose(armature, 9, merge(crouch(0.2), {"body": (6.0, 0.0, 0.0), "head": (4.0, 0.0, 0.0), "jaw": (8.0, 0.0, 0.0)}), {"body": (0.0, FORWARD * 0.04, 0.0)})
    apply_pose(armature, 1 + ATTACK_FRAMES, crouch(0.12))
    clips.append(("attack", 1, 1 + ATTACK_FRAMES))

    # hit — 0.3 s flinch. Recoils backward and drops, so a hit is legible even
    # when the crawler is mid-stride and the health bar is off-screen.
    new_action(armature, "hit")
    apply_pose(armature, 1, crouch(0.12))
    apply_pose(armature, 3, merge(crouch(0.55), {"body": (14.0, 7.0, 0.0), "head": (18.0, 0.0, 12.0), "jaw": (18.0, 0.0, 0.0), "abdomen": (-10.0, 0.0, 0.0)}), {"body": (0.0, FORWARD * -0.07, -0.03)})
    apply_pose(armature, 6, merge(crouch(0.3), {"body": (4.0, -3.0, 0.0), "head": (6.0, 0.0, -5.0), "jaw": (6.0, 0.0, 0.0)}), {"body": (0.0, FORWARD * -0.02, -0.01)})
    apply_pose(armature, 10, crouch(0.12))
    clips.append(("hit", 1, 10))

    # death — 1 s. Rears, then collapses onto its side and settles. The last
    # frame is the pose the death fragments and any ragdoll hand-off inherit, so
    # it ends flat and still rather than mid-fall.
    new_action(armature, "death")
    apply_pose(armature, 1, crouch(0.12))
    apply_pose(armature, 5, merge(crouch(0.45), {"body": (-24.0, 0.0, 0.0), "head": (-20.0, 0.0, 0.0), "jaw": (30.0, 0.0, 0.0), "abdomen": (18.0, 0.0, 0.0)}), {"body": (0.0, 0.0, 0.03)})
    apply_pose(armature, 14, merge(crouch(0.85), {"body": (10.0, 42.0, 0.0), "head": (12.0, 20.0, -14.0), "jaw": (22.0, 0.0, 0.0), "abdomen": (-8.0, 26.0, 0.0)}), {"body": (0.0, 0.0, -0.13)})
    apply_pose(armature, 22, merge(crouch(1.0), {"body": (4.0, 64.0, 0.0), "head": (6.0, 30.0, -20.0), "jaw": (10.0, 0.0, 0.0), "abdomen": (-4.0, 40.0, 0.0)}), {"body": (0.0, 0.0, -0.19)})
    apply_pose(armature, 31, merge(crouch(1.0), {"body": (0.0, 68.0, 0.0), "head": (2.0, 32.0, -22.0), "jaw": (4.0, 0.0, 0.0), "abdomen": (0.0, 44.0, 0.0)}), {"body": (0.0, 0.0, -0.20)})
    clips.append(("death", 1, 31))

    if [name for name, _, _ in clips] != EXPECTED_ANIMATIONS:
        raise RuntimeError("A-006 animation specification and expected clip list diverged")
    return clips


# ── The static companions ─────────────────────────────────────────────────────


def build_nest(mats: dict[str, bpy.types.Material]) -> None:
    """The spawn nest: a Mire growth with an open mouth crawlers come out of.

    Hollow and open on purpose (A-005's third trap). A nest modelled as a solid
    mound has nowhere for a crawler to come from, and the spawn reads as a
    monster appearing out of a rock.
    """
    # The rim is a RING of eight leaning lobes, not one dome. A dome with a
    # throat modelled inside it is A-005's third trap in a new costume: the
    # cavity exists in the file, nothing can see it, and the asset reads as a
    # spiky rock. Building the opening as an absence of geometry is the only way
    # it survives being looked at.
    # The lobes must be SMALLER than the hole they surround. Sized to meet at the
    # centre they simply reseal it, which is how the first attempt turned into a
    # pile of boulders — the opening has to survive being drawn, not merely exist
    # in the coordinates.
    rim_radius = 0.50
    for index in range(8):
        angle = index / 8.0 * math.tau
        lean = 0.09 + 0.03 * math.cos(angle * 3.0)
        # The rim drops away toward -Y, the side the preview and the player see
        # from. A ring of even height is open only when viewed from above, and
        # nothing in a first-person game is ever viewed from above — at standing
        # eye height the far wall simply becomes the near wall's backdrop and the
        # mouth disappears. The notch is what makes the opening legible from the
        # ground, and it doubles as the obvious place a crawler climbs out.
        notch = max(0.0, -math.sin(angle)) ** 1.5
        height = (0.17 + lean) * (1.0 - 0.82 * notch)
        ico(
            f"Nest_Rim_{index}",
            (math.cos(angle) * rim_radius, math.sin(angle) * rim_radius, 0.10 + height * 0.55),
            (0.20, 0.20, height),
            mats["nest"] if index % 2 == 0 else mats["nest_dark"],
            (math.radians(-26) * math.sin(angle), math.radians(26) * math.cos(angle), 0.0),
        )
    # A low skirt fills the gaps between the lobes so the nest reads as one
    # organism sitting on the ground rather than eight boulders in a circle. It
    # is kept flat and wide so it never rises into the mouth.
    ico("Nest_Skirt", (0.0, 0.0, 0.035), (0.74, 0.74, 0.09), mats["nest_dark"])

    # The throat is a shallow bowl at the BOTTOM of the ring, well below the rim,
    # so it is visible down the hole from standing eye height.
    ico("Nest_Throat", (0.0, FORWARD * 0.04, 0.09), (0.30, 0.32, 0.14), mats["throat"])
    ico("Nest_Glow", (0.0, FORWARD * 0.06, 0.16), (0.17, 0.17, 0.07), mats["glow"])
    for index in range(6):
        angle = index / 6.0 * math.tau + 0.26
        cone(
            f"Nest_Tooth_{index}",
            0.05,
            0.008,
            0.26,
            (math.cos(angle) * 0.32, math.sin(angle) * 0.32, 0.30),
            mats["chitin_light"],
            5,
            (math.radians(30) * math.sin(angle), math.radians(-30) * math.cos(angle), 0.0),
        )
    for index, (x, y, height) in enumerate(((0.50, -0.40, 0.40), (-0.54, 0.26, 0.32), (0.14, 0.60, 0.26))):
        cone(f"Nest_Crystal_{index}", 0.06, 0.012, height, (x, y, 0.22 + height * 0.5), mats["crystal"], 5, (math.radians(14), math.radians(-12), 0.0))


def build_fragment_shell(mats: dict[str, bpy.types.Material]) -> None:
    """A carapace shard — the big piece a killed crawler leaves behind."""
    box("Fragment_Shell_Plate", (0.0, 0.0, 0.045), (0.26, 0.19, 0.05), mats["chitin"], (math.radians(9), math.radians(-6), math.radians(14)), 0.012)
    box("Fragment_Shell_Chip", (0.10, -0.08, 0.035), (0.10, 0.08, 0.035), mats["chitin_dark"], (0.0, math.radians(16), math.radians(-22)), 0.008)
    cone("Fragment_Shell_Crystal", 0.03, 0.008, 0.11, (-0.05, 0.04, 0.10), mats["crystal"], 5, (math.radians(22), math.radians(-18), 0.0))


def build_fragment_leg(mats: dict[str, bpy.types.Material]) -> None:
    """A severed leg, bent at the knee and lying where it fell."""
    strut("Fragment_Leg_Upper", (-0.13, -0.02, 0.035), (0.04, 0.05, 0.045), 0.075, mats["chitin"])
    strut("Fragment_Leg_Lower", (0.04, 0.05, 0.045), (0.17, -0.04, 0.03), 0.055, mats["chitin_dark"])
    ico("Fragment_Leg_Knee", (0.04, 0.05, 0.045), (0.04, 0.04, 0.04), mats["chitin_light"])


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
    """Build, ground-centre and export one unrigged mesh, as A-002..A-005 do."""
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
    materials = sorted({mat.name for obj in made if obj.type == "MESH" for mat in obj.data.materials if mat})

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
    """Export the rigged crawler.

    No ground-normalization here, unlike the static path. The rig is authored
    with its feet on z = 0 already, and shifting a skinned mesh after binding
    would move it out from under its own armature — so this asserts the contact
    instead of correcting it.
    """
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    move_to_collection([armature, mesh], collection)

    clear_pose(armature)
    minimum, maximum = world_bounds([mesh])
    if abs(minimum.z) > 0.0005:
        raise RuntimeError(f"{name}: rest pose does not touch the ground (min z = {minimum.z:.4f} m)")
    dimensions = maximum - minimum
    materials = sorted({mat.name for mat in mesh.data.materials if mat})

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
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.fps = FPS
    scene.render.resolution_x = 1600
    scene.render.resolution_y = 1000
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
    """Render one tile per key pose and composite them into a contact sheet.

    The rig verification the earlier batches never had to run: a still of the
    rest pose proves the mesh is bound, but only a sheet of extremes shows
    whether the poses themselves deform cleanly.
    """
    for record in records:
        set_visible(record, record["name"] == "enemy_crawler")
    original_resolution = (scene.render.resolution_x, scene.render.resolution_y)
    original_camera = (camera.location.copy(), camera.data.ortho_scale)
    scene.render.resolution_x = cell
    scene.render.resolution_y = cell
    # Frame the CRAWLER, not the world origin — it is parked at its preview
    # position, and a sheet aimed at (0,0,0) renders eight tiles of empty ground
    # with one leg in the corner.
    focus = armature.location.copy()
    camera.data.ortho_scale = 1.65
    camera.location = focus + Vector((1.60, -1.95, 0.92))
    look_at(camera, (focus.x, focus.y, focus.z + 0.26))

    rows = math.ceil(len(poses) / columns)
    sheet = np.zeros((rows * cell, columns * cell, 4), dtype=np.float32)
    sheet[:, :, 3] = 1.0
    for index, (clip, _label, frame) in enumerate(poses):
        armature.animation_data.action = bpy.data.actions[clip]
        if hasattr(armature.animation_data, "action_slot"):
            armature.animation_data.action_slot = bpy.data.actions[clip].slots[0]
        scene.frame_set(frame)
        tile_path = PREVIEW_DIR / f"pose_tile_{index}.png"
        scene.render.filepath = str(tile_path)
        bpy.ops.render.render(write_still=True)
        image = bpy.data.images.load(str(tile_path))
        pixels = np.array(image.pixels[:], dtype=np.float32).reshape(cell, cell, 4)
        bpy.data.images.remove(image)
        tile_path.unlink()
        row = index // columns
        column = index % columns
        # Blender's pixel buffer is bottom-up; the sheet is laid out top-down.
        top = (rows - 1 - row) * cell
        sheet[top:top + cell, column * cell:(column + 1) * cell] = pixels

    output = bpy.data.images.new("Crawler_Pose_Sheet", width=columns * cell, height=rows * cell, alpha=True)
    output.pixels = sheet.reshape(-1)
    output.filepath_raw = str(PREVIEW_DIR / "crawler_pose_sheet.png")
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

    # Set the frame rate BEFORE anything is exported. Keyframes are authored in
    # frames but glTF stores animation in SECONDS, so the exporter divides by
    # whatever fps the scene happens to hold — and Blender's default is 24. Left
    # until the render setup runs, every clip shipped 25% slow: the 0.4 s tell
    # that docs/DESIGN.md §6 asks for arrived as 0.5 s, and nothing in the file
    # looked wrong, because the frame numbers were right.
    bpy.context.scene.render.fps = FPS
    reset_materials()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.actions, bpy.data.armatures, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)

    mats = {
        # Shared palette. Geometry helpers stay local: this kit's cone defaults
        # to 6 vertices where mire_art's uses 8, and the mesh is skinned — any
        # geometry change needs the deform check re-run.
        "chitin": mat("chitin"),
        "chitin_dark": mat("chitin_dark"),
        "chitin_light": mat("chitin_light"),
        "crystal": mat("crystal_tip"),
        "glow": mat("mire_glow"),
        # RED, not the palette's warm gold `eye`. Sequoyah, on seeing the roster:
        # "red eyes on the enemies please, i think its scarier" — and he is right:
        # warm gold reads as alive and curious, and an enemy has to read as hostile
        # at a glance, in fog, at distance. `critical` is the palette's red emissive
        # (#F17661 over a #FF5030 glow). The genuinely correct fix is to change the
        # `eye` token itself in `mire_art.PALETTE`, which would repoint every enemy
        # at once; that file was claimed by another agent (F-473) for the whole of
        # this task, so this is the per-generator override until it is free.
        "eye": mat("critical"),
        "nest": mat("nest"),
        "nest_dark": mat("nest_dark"),
        "throat": mat("throat"),
        "ground": mat("preview_ground"),
        "scale": mat("reference_blue"),
    }

    records: list[dict] = []

    armature, mesh = build_crawler_rig(mats)
    clips = build_animations(armature)
    records.append(create_rigged_asset("enemy_crawler", "enemy", armature, mesh, clips, (-1.30, 0.0, 0.0)))

    statics: list[tuple[str, str, Callable[[], None], tuple[float, float, float]]] = [
        ("enemy_crawler_nest", "spawner", lambda: build_nest(mats), (0.45, 0.0, 0.0)),
        ("enemy_crawler_fragment_shell", "debris", lambda: build_fragment_shell(mats), (1.55, 0.20, 0.0)),
        ("enemy_crawler_fragment_leg", "debris", lambda: build_fragment_leg(mats), (2.15, -0.30, 0.0)),
    ]
    for name, family, builder, location in statics:
        records.append(create_static_asset(name, family, builder, location))

    if [record["name"] for record in records] != EXPECTED_NAMES:
        raise RuntimeError("A-006 specification and expected export list diverged")

    catalog = [
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
    with (ASSET_DIR / "catalog.json").open("w", encoding="utf-8") as handle:
        json.dump(catalog, handle, indent=2)
        handle.write("\n")

    scene, camera, preview_collection = setup_render(mats)
    camera.data.ortho_scale = 4.6
    camera.location = (4.0, -6.4, 3.1)
    look_at(camera, (0.35, -0.05, 0.28))
    scene.render.filepath = str(PREVIEW_DIR / "enemies_preview.png")
    bpy.ops.render.render(write_still=True)

    original_locations = {record["name"]: record["root"].location.copy() for record in records}
    showcase_positions = {
        "enemy_crawler": (-0.95, 0.10, 0.0),
        "enemy_crawler_nest": (0.55, -0.05, 0.0),
        "enemy_crawler_fragment_shell": (1.55, 0.15, 0.0),
    }
    for record in records:
        set_visible(record, record["name"] in showcase_positions)
        if record["name"] in showcase_positions:
            record["root"].location = showcase_positions[record["name"]]
    scale_parts = [
        box("Scale_Post", (-2.15, -0.35, 0.5), (0.09, 0.09, 1.0), mats["scale"]),
        box("Scale_Tick_20", (-2.05, -0.35, 0.20), (0.20, 0.07, 0.022), mats["scale"]),
        box("Scale_Tick_40", (-2.05, -0.35, 0.40), (0.20, 0.07, 0.022), mats["scale"]),
        box("Scale_Tick_60", (-2.05, -0.35, 0.60), (0.20, 0.07, 0.022), mats["scale"]),
        box("Scale_Tick_80", (-2.05, -0.35, 0.80), (0.20, 0.07, 0.022), mats["scale"]),
        box("Scale_Tick_100", (-2.05, -0.35, 1.00), (0.26, 0.07, 0.028), mats["scale"]),
        box("Scale_20cm_Cube", (-1.72, -0.40, 0.10), (0.20, 0.20, 0.20), mats["scale"]),
    ]
    move_to_collection(scale_parts, preview_collection)
    camera.data.ortho_scale = 4.1
    camera.location = (3.4, -5.6, 2.5)
    look_at(camera, (-0.20, -0.05, 0.30))
    scene.render.filepath = str(PREVIEW_DIR / "enemies_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    for record in records:
        record["root"].location = original_locations[record["name"]]
        set_visible(record, True)

    # The ruler goes before the contact sheet — it stands beside the group shot,
    # not beside the crawler, so in a tight pose tile it only clips the frame.
    # The 20 cm cube stays and moves in next to the crawler, which keeps a scale
    # reference in every tile of the sheet.
    reference_cube = scale_parts.pop()
    for scale_part in scale_parts:
        bpy.data.objects.remove(scale_part, do_unlink=True)
    scale_parts = []
    reference_cube.location = (-1.30 + 0.52, 0.34, 0.10)

    # Two frames of the walk, the tell at its readable extreme, the bite, the
    # flinch and the collapse — the poses a reviewer actually has to see.
    render_pose_sheet(
        scene,
        camera,
        armature,
        records,
        [
            ("idle" + LOOP_SUFFIX, "idle", 16),
            ("locomotion" + LOOP_SUFFIX, "locomotion contact", 1),
            ("locomotion" + LOOP_SUFFIX, "locomotion pass", 13),
            ("attack_tell", "tell rise", 5),
            ("attack_tell", "tell hold", 13),
            ("attack", "bite", 5),
            ("hit", "flinch", 3),
            ("death", "collapse", 14),
        ],
        columns=4,
        cell=420,
    )

    bpy.data.objects.remove(reference_cube, do_unlink=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "enemy_crawler.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(f"Built {len(records)} A-006 enemy assets ({total_polygons} polygons total), {len(clips)} clips on {len(armature.data.bones)} bones")


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
