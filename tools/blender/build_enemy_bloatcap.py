"""Build the Bloatcap — tier 4 of the enemy ladder (docs/ENEMIES.md §6).

Run with:
  Blender --background --python tools/blender/build_enemy_bloatcap.py

Outputs three metre-scale GLBs — one rigged and animated Bloatcap and its two
death fragments — plus an editable Blender source, its rows merged into the
shared enemy catalog, a group preview and a pose contact sheet. Geometry, rig
and animation are deterministic.

Fifth rigged family in `assets/enemies/`, following every convention the four
before it set: rigid one-bone-per-part skinning, every action keys every animated
bone (rotation, location AND scale), no raw float in any datablock name, `-loop`
only on the two clips that may loop, and every clip authored no longer than the
`EnemyDef` window it plays under — remembering that Godot reports an imported
clip's length as LAST FRAME over fps, so every `*_FRAMES` constant below is one
less than the count it looks like.

The real subject: puffball fungi, Lycoperdon. Four facts.

The fruit body is PEAR-SHAPED with a flattened top and a stem-like base — not the
sphere people draw. The flattening is load-bearing here, because it is where the
ostiole has to sit.

The surface is covered in short cone-shaped SPINES interspersed with granular
WARTS, which rub off and leave pock marks behind. On a pale sac at night that
texture is the only thing giving the silhouette any form at all.

There is a pre-formed hole in the top — the OSTIOLE — and the spores leave
through it when the body is compressed, ejected at around a metre per second and
forming a visible cloud within a hundredth of a second. So this creature's strike
is not a swing, it is a DEFLATION, and it is over before the eye finishes reading
it. The tell is the sac filling; the attack is the sac emptying.

And the GLEBA — the spore mass inside — is white and firm in a young puffball and
brown and powdery in a mature one. In a corrupted one it is purple and lit, and
it is visible through the dilating ostiole, which is how a player reads how close
this thing is to going off.

Nothing here writes to `mire_art.py`. This is the ladder's first PALE creature —
tier 1 is purple gel, tier 2 cold grey plumage, tier 3 near-black peat — and the
visibility is deliberate: a Bloatcap is meant to be seen early and dealt with
from range, so one you failed to notice is a mistake rather than an ambush.
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
    "enemy_bloatcap",
    "enemy_bloatcap_fragment_husk",
    "enemy_bloatcap_fragment_gleba",
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
## they look like, and `tools/enemy_bloatcap_check.gd` asserts the imported result
## against the authored `.tres` rather than against these numbers.
TELL_FRAMES = 20       # last frame 21 -> 0.700 s, exactly bloatcap.tres's tell
ATTACK_FRAMES = 8      # last frame 9  -> 0.300 s, exactly its attack_seconds
HIT_FRAMES = 8         # last frame 9  -> 0.300 s
DEATH_FRAMES = 41      # last frame 42 -> 1.400 s
IDLE_FRAMES = 89       # last frame 90 -> 3.000 s
LOCOMOTION_FRAMES = 29  # last frame 30 -> 1.000 s

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


# ── The Bloatcap's skeleton ───────────────────────────────────────────────────
#
# Eleven bones and the important one is `sac`, which carries almost the entire
# creature and does almost all of its acting through SCALE. This thing's whole
# language is volume: it swells to tell, it collapses to strike, and it sags to
# die. Everything else — a stem, an ostiole, four stubby rhizomorph legs — is
# there so the sac has something to sit on and something to vent through.

BASE_TOP = 0.42
SAC_CENTRE = Vector((0.0, 0.0, 0.80))
SAC_RADII = Vector((0.50, 0.50, 0.42))
OSTIOLE_Z = 1.20

## Four short legs on the diagonals. Not on the axes: a creature with a leg
## directly in front of it reads as facing that way, and this one has no front —
## which is the point of the ring of eyes below.
LEG_ANGLES = (45.0, 135.0, 225.0, 315.0)


def leg_points(angle_deg: float) -> tuple[Vector, Vector, Vector]:
    angle = math.radians(angle_deg)
    hip = Vector((math.sin(angle) * 0.20, math.cos(angle) * 0.20, 0.40))
    knee = Vector((math.sin(angle) * 0.42, math.cos(angle) * 0.42, 0.24))
    foot = Vector((math.sin(angle) * 0.52, math.cos(angle) * 0.52, 0.030))
    return hip, knee, foot


def bone_table() -> list[tuple[str, Vector, Vector, str | None]]:
    """(name, head, tail, parent) for every bone, in creation order."""
    bones: list[tuple[str, Vector, Vector, str | None]] = [
        ("root", Vector((0.0, 0.0, 0.0)), Vector((0.0, 0.0, 0.16)), None),
        ("base", Vector((0.0, 0.0, 0.10)), Vector((0.0, 0.0, BASE_TOP)), "root"),
        ("sac", Vector((0.0, 0.0, BASE_TOP)), Vector((0.0, 0.0, 1.04)), "base"),
        ("ostiole", Vector((0.0, 0.0, 1.04)), Vector((0.0, 0.0, OSTIOLE_Z + 0.06)), "sac"),
    ]
    for index, angle in enumerate(LEG_ANGLES):
        hip, knee, foot = leg_points(angle)
        bones.append((f"leg_{index}_upper", hip, knee, "base"))
        bones.append((f"leg_{index}_lower", knee, foot, f"leg_{index}_upper"))
    return bones


DEFORM_BONES = [name for name, _, _, parent in bone_table() if parent is not None]


# ── The Bloatcap's mesh ───────────────────────────────────────────────────────


def sac_point(azimuth_deg: float, height: float) -> Vector:
    """A point on the sac's skin. [param height] is -1 (bottom) to 1 (top).

    Same trick the Peatling's vein network uses: warts and eyes placed through
    here sit ON the surface instead of floating over it or sinking into it.
    """
    angle = math.radians(azimuth_deg)
    ring = math.sqrt(max(0.0, 1.0 - height * height))
    return Vector((
        math.sin(angle) * SAC_RADII.x * ring,
        math.cos(angle) * SAC_RADII.y * ring,
        SAC_CENTRE.z + height * SAC_RADII.z,
    ))


def build_bloatcap_parts(mats: dict[str, bpy.types.Material]) -> list[tuple[bpy.types.Object, str]]:
    """Every mesh part paired with the single bone that drives it."""
    parts: list[tuple[bpy.types.Object, str]] = []

    def add(obj: bpy.types.Object, bone: str) -> None:
        parts.append((obj, bone))

    # ── The sac. PEAR-SHAPED with a flattened top and a stem-like base, which is
    # the actual shape of Lycoperdon and not the beach ball people draw. The
    # flattening matters: a sphere reads as a boulder, and the flat top is where
    # the ostiole has to sit.
    add(ico("Bloatcap_Sac", tuple(SAC_CENTRE), tuple(SAC_RADII), mats["sac"], subdivisions=2), "sac")
    add(ico("Bloatcap_Shoulder", (0.0, 0.0, 0.96), (0.395, 0.395, 0.185), mats["sac_light"], subdivisions=1), "sac")
    add(cone("Bloatcap_Neck", 0.30, 0.44, 0.30, (0.0, 0.0, 0.50), mats["sac_dark"], 8), "sac")
    add(cone("Bloatcap_Stem", 0.26, 0.19, 0.34, (0.0, 0.0, 0.27), mats["stem"], 8), "base")
    add(ico("Bloatcap_Holdfast", (0.0, 0.0, 0.12), (0.28, 0.28, 0.11), mats["stem_dark"], subdivisions=1), "base")

    # ── Warts and spines. The real thing is "covered in short cone-shaped spines
    # interspersed with granular warts" that rub off and leave pock marks. They
    # are the texture, and on a pale sac at night they are also the only thing
    # that gives it any form at all.
    for index in range(18):
        # Deterministic scatter: a stride that is coprime with the count walks
        # every slot exactly once, so this is even without being a grid and
        # identical on every rebuild without touching a random number.
        azimuth = (index * 137.0) % 360.0
        height = -0.55 + (index % 6) * 0.26
        seat = sac_point(azimuth, height)
        outward = Vector((seat.x, seat.y, 0.0))
        if outward.length > 0.001:
            outward = outward.normalized()
        else:
            outward = Vector((0.0, 1.0, 0.0))
        tip = seat + outward * 0.075 + Vector((0.0, 0.0, 0.035))
        add(
            limb(
                f"Bloatcap_Wart_{index}",
                seat - outward * 0.02,
                tip,
                0.075 - (index % 3) * 0.014,
                0.010,
                mats["wart"],
                vertices=4,
            ),
            "sac",
        )

    # ── The ostiole: the pre-formed hole in the top through which the spores
    # actually leave. Six plates in a ring around a glowing throat — so when the
    # `ostiole` bone scales up in the tell, the plates part and the light gets
    # bigger, which is the entire telegraph on a creature with no limbs to raise.
    for index in range(6):
        angle = math.tau * index / 6.0
        add(
            box(
                f"Bloatcap_Ostiole_Plate_{index}",
                (math.sin(angle) * 0.145, math.cos(angle) * 0.145, OSTIOLE_Z - 0.045),
                (0.135, 0.10, 0.075),
                mats["sac_dark"],
                (math.radians(24.0), 0.0, -angle),
            ),
            "ostiole",
        )
    # The gleba. White and firm in a young puffball, brown and powdery in a
    # mature one — and purple and lit in a corrupted one, because whatever this
    # thing is full of, it is the Mire's now.
    add(ico("Bloatcap_Gleba", (0.0, 0.0, OSTIOLE_Z - 0.10), (0.135, 0.135, 0.075), mats["gleba"]), "ostiole")
    add(ico("Bloatcap_Gleba_Core", (0.0, 0.0, OSTIOLE_Z - 0.16), (0.075, 0.075, 0.06), mats["gleba"]), "sac")

    # ── The eyes: a RING of them, low on the sac, facing outward in every
    # direction. This creature has no front and no head, and a ring of small red
    # points is both the honest way to say that and considerably worse to walk up
    # to than a face would be. Red per the roster-wide directive.
    for index in range(7):
        azimuth = 360.0 * index / 7.0
        seat = sac_point(azimuth, -0.30)
        outward = Vector((seat.x, seat.y, 0.0)).normalized()
        add(
            ico(
                f"Bloatcap_Eye_{index}",
                tuple(seat + outward * 0.012),
                (0.036, 0.036, 0.030),
                mats["eye"],
            ),
            "sac",
        )

    # ── Legs: rhizomorph cords rather than limbs — the tough mycelial strands a
    # real fungus actually runs through the ground, pressed into service as feet.
    for index, angle in enumerate(LEG_ANGLES):
        hip, knee, foot = leg_points(angle)
        add(limb(f"Bloatcap_Upper_{index}", hip, knee, 0.115, 0.085, mats["stem"], vertices=5), f"leg_{index}_upper")
        add(limb(f"Bloatcap_Lower_{index}", knee, foot, 0.085, 0.055, mats["stem_dark"], vertices=5), f"leg_{index}_lower")
        # Splayed root-toes. A creature this bulbous needs a visibly wide base or
        # it reads as a balloon that ought to have fallen over already.
        for toe_index, spread in enumerate((-34.0, 0.0, 34.0)):
            toe_angle = math.radians(angle + spread)
            tip = Vector((
                math.sin(toe_angle) * 0.70,
                math.cos(toe_angle) * 0.70,
                # The root TIP, not the joint: a tapered cord laid nearly flat
                # hangs half its own end radius below the point its bone ends at,
                # which the rest-pose contact assert catches every time.
                0.007,
            ))
            add(limb(f"Bloatcap_Root_{index}_{toe_index}", foot, tip, 0.048, 0.014, mats["stem_dark"], vertices=4), f"leg_{index}_lower")

    return parts


def build_bloatcap_rig(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Object, bpy.types.Object]:
    """Build the Bloatcap mesh, bind it rigidly to its armature, return both."""
    parts = build_bloatcap_parts(mats)

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
    mesh.name = "Bloatcap_Mesh"
    mesh.data.name = "Bloatcap_Mesh_Data"

    bpy.ops.object.armature_add(location=(0.0, 0.0, 0.0))
    armature = bpy.context.object
    armature.name = "Bloatcap_Rig"
    armature.data.name = "Bloatcap_Rig_Data"
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
    modifier = mesh.modifiers.new("Bloatcap_Armature", "ARMATURE")
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
        slot = action.slots.new(id_type="OBJECT", name="Bloatcap") if not action.slots else action.slots[0]
        armature.animation_data.action_slot = slot
    return action


def merge(*poses: Pose) -> Pose:
    merged: Pose = {}
    for pose in poses:
        merged.update(pose)
    return merged


def inflate(amount: float) -> tuple[Pose, dict, dict]:
    """The sac's internal pressure, -1 (collapsed) to 1 (fully swollen).

    One function, because the tell and the strike have to be exact opposites of
    each other. Swelling lifts the whole creature onto its legs and widens it;
    collapsing drops it and spreads it. The ostiole tracks the pressure — it
    dilates as the sac fills and gapes when it vents — so the light at the top
    always says how close this thing is to going off.
    """
    full = max(0.0, amount)
    empty = max(0.0, -amount)
    pose: Pose = {
        "base": (0.0, 0.0, 0.0),
        "sac": (0.0, 0.0, 0.0),
    }
    offsets = {
        "sac": (0.0, 0.0, 0.10 * full - 0.09 * empty),
        "ostiole": (0.0, 0.0, 0.05 * full - 0.05 * empty),
    }
    scales = {
        "sac": (
            1.0 + 0.30 * full - 0.26 * empty,
            1.0 + 0.30 * full - 0.26 * empty,
            1.0 + 0.22 * full - 0.34 * empty,
        ),
        "ostiole": (
            1.0 + 0.55 * full + 0.85 * empty,
            1.0 + 0.55 * full + 0.85 * empty,
            1.0 + 0.20 * full - 0.30 * empty,
        ),
        "base": (1.0 + 0.10 * full - 0.06 * empty, 1.0 + 0.10 * full - 0.06 * empty, 1.0 - 0.14 * full + 0.10 * empty),
    }
    return pose, offsets, scales


def stance(crouch: float, gait: float = 0.0) -> Pose:
    """Four stubby legs. `crouch` settles it; `gait` waddles it."""
    pose: Pose = {}
    for index, angle in enumerate(LEG_ANGLES):
        # Diagonal pairs, one hop out of phase — a four-legged waddle, not a walk.
        phase = gait * math.tau + (0.0 if index % 2 == 0 else math.pi)
        swing = math.sin(phase)
        lift = max(0.0, swing)
        pose[f"leg_{index}_upper"] = (-swing * 16.0 - 22.0 * crouch, 0.0, 0.0)
        pose[f"leg_{index}_lower"] = (lift * 22.0 + 34.0 * crouch, 0.0, 0.0)
    return pose


def merge_channels(*channels: dict) -> dict:
    merged: dict = {}
    for channel in channels:
        merged.update(channel)
    return merged


def keyed(
    armature: bpy.types.Object,
    frame: int,
    pressure: float,
    crouch: float,
    gait: float = 0.0,
    extra_pose: Pose | None = None,
    extra_offsets: dict | None = None,
    extra_scales: dict | None = None,
) -> None:
    pose, offsets, scales = inflate(pressure)
    apply_pose(
        armature,
        frame,
        merge(pose, stance(crouch, gait), extra_pose or {}),
        merge_channels(offsets, extra_offsets or {}),
        merge_channels(scales, extra_scales or {}),
    )


def build_animations(armature: bpy.types.Object) -> list[tuple[str, int, int]]:
    """Author every clip. Returns (name, first frame, last frame) per clip."""
    clips: list[tuple[str, int, int]] = []

    # ── idle-loop — 3.0 s of slow breathing.
    #
    # It fills and empties, gently, on a long asymmetric cycle: the fill takes
    # most of the clip and the release is quicker, because that is what a bellows
    # does and because a symmetric throb would read as a heartbeat. The ostiole's
    # light brightens and dims with it, so from across a clearing a Bloatcap is a
    # slow purple pulse at chest height — which is how a player is supposed to
    # find one before walking into it.
    new_action(armature, "idle" + LOOP_SUFFIX)
    for frame, pressure, crouch in (
        (1, -0.15, 0.30),
        (26, 0.20, 0.24),
        (48, 0.38, 0.20),
        (64, 0.10, 0.26),
        (78, -0.28, 0.34),
        (90, -0.15, 0.30),  # repeats frame 1 exactly, so the loop has no seam
    ):
        keyed(armature, frame, pressure, crouch)
    clips.append(("idle" + LOOP_SUFFIX, 1, 1 + IDLE_FRAMES))

    # ── locomotion-loop — 1.0 s. The waddle.
    #
    # Diagonal pairs, and the sac LAGS the legs — it is a bag of gas balanced on
    # a stem, so it arrives a beat after the body it is riding and rocks past the
    # centre before it settles. That lag is most of what makes it look heavy
    # rather than inflated.
    new_action(armature, "locomotion" + LOOP_SUFFIX)
    for step in range(LOCOMOTION_FRAMES + 1):
        phase = step / LOCOMOTION_FRAMES
        lag = math.sin(phase * math.tau - 0.9)
        keyed(
            armature,
            1 + step,
            0.05 + math.sin(phase * math.tau * 2.0) * 0.10,
            0.28,
            phase,
            extra_pose={"sac": (lag * 5.0, lag * 6.5, 0.0), "base": (0.0, math.sin(phase * math.tau) * 3.0, 0.0)},
        )
    clips.append(("locomotion" + LOOP_SUFFIX, 1, 1 + LOCOMOTION_FRAMES))

    # ── attack_tell — 0.7 s. IT SWELLS.
    #
    # The longest telegraph in the game, and it needs every frame of it: what
    # follows is an area burst that does not care where you dodge to, only how
    # far away you got. So the tell is enormous and unmistakable — the sac
    # inflates by a third, the whole creature rises onto its legs, and the
    # ostiole dilates until the gleba inside is a hole full of light. Nothing
    # else in the roster gets BIGGER as it winds up.
    new_action(armature, "attack_tell")
    keyed(armature, 1, -0.10, 0.30)
    keyed(armature, 6, 0.45, 0.16)
    keyed(armature, 13, 0.88, 0.05)
    keyed(armature, 17, 1.0, 0.02)
    # Holds the extreme, quivering, for the last fifth: a tell still growing when
    # the burst arrives never registers as a warning.
    keyed(armature, 1 + TELL_FRAMES, 1.0, 0.02, extra_pose={"sac": (1.5, -1.5, 0.0)})
    clips.append(("attack_tell", 1, 1 + TELL_FRAMES))

    # ── attack — 0.3 s. It vents.
    #
    # Frame 1 is the tell's last frame exactly. Two frames later the sac has
    # collapsed past its own resting size and the ostiole is gaping — the real
    # thing ejects its spores at about a metre per second and forms the cloud in
    # a hundredth of a second, so on this creature the strike is not a swing, it
    # is a DEFLATION, and it is over before the eye has finished reading it.
    new_action(armature, "attack")
    keyed(armature, 1, 1.0, 0.02)
    keyed(armature, 3, -0.85, 0.30, extra_pose={"sac": (0.0, 0.0, 0.0)})
    keyed(armature, 5, -1.0, 0.42)
    keyed(armature, 1 + ATTACK_FRAMES, -0.55, 0.34)
    clips.append(("attack", 1, 1 + ATTACK_FRAMES))

    # ── hit — 0.3 s. A dent that crosses the skin.
    #
    # It has no skeleton above the stem, so a hit does not move it — it PUSHES
    # IN, and the dent travels. The one thing that must not happen here is a
    # flinch backwards, because that would make it look like a creature with
    # somewhere to flinch to.
    new_action(armature, "hit")
    keyed(armature, 1, -0.15, 0.30)
    keyed(
        armature,
        3,
        -0.45,
        0.44,
        extra_pose={"sac": (8.0, 9.0, 0.0)},
        extra_scales={"sac": (1.16, 0.84, 0.92)},
    )
    keyed(
        armature,
        6,
        0.05,
        0.26,
        extra_pose={"sac": (-4.0, -5.0, 0.0)},
        extra_scales={"sac": (0.93, 1.08, 1.04)},
    )
    keyed(armature, 1 + HIT_FRAMES, -0.15, 0.30)
    clips.append(("hit", 1, 1 + HIT_FRAMES))

    # ── death — 1.4 s. It goes off, and then it goes down.
    #
    # One last involuntary swell — the reflex that makes killing one of these in
    # melee a mistake — then the sac tears, empties, and slumps into a sagging
    # bag on a stem that can no longer hold it up. It ends flat and still, with
    # the ostiole gaping and the gleba dark: an empty husk, which is exactly what
    # a spent puffball looks like on the forest floor.
    new_action(armature, "death")
    keyed(armature, 1, -0.15, 0.30)
    keyed(armature, 7, 0.95, 0.04)
    keyed(armature, 13, -1.0, 0.42, extra_pose={"sac": (0.0, 0.0, 0.0)})
    collapse: Pose = {}
    for index, _angle in enumerate(LEG_ANGLES):
        collapse[f"leg_{index}_upper"] = (46.0, 0.0, 0.0)
        collapse[f"leg_{index}_lower"] = (-38.0, 0.0, 0.0)
    keyed(
        armature,
        26,
        -1.0,
        0.0,
        extra_pose=merge(collapse, {"sac": (14.0, 16.0, 0.0), "base": (10.0, 12.0, 0.0)}),
        extra_offsets={"sac": (0.0, 0.0, -0.20)},
        extra_scales={"sac": (1.30, 1.26, 0.40), "base": (1.10, 1.10, 0.72)},
    )
    keyed(
        armature,
        1 + DEATH_FRAMES,
        -1.0,
        0.0,
        extra_pose=merge(collapse, {"sac": (18.0, 21.0, 0.0), "base": (14.0, 17.0, 0.0)}),
        extra_offsets={"sac": (0.0, 0.0, -0.27)},
        extra_scales={"sac": (1.42, 1.36, 0.28), "base": (1.14, 1.14, 0.62)},
    )
    clips.append(("death", 1, 1 + DEATH_FRAMES))

    if [name for name, _, _ in clips] != EXPECTED_ANIMATIONS:
        raise RuntimeError("Bloatcap animation specification and expected clip list diverged")
    return clips


# ── The death fragments ───────────────────────────────────────────────────────


def build_fragment_husk(mats: dict[str, bpy.types.Material]) -> None:
    """A torn piece of the sac's skin, warts still on the outside of it."""
    ico("Fragment_Husk_Skin", (0.0, 0.0, 0.030), (0.175, 0.145, 0.030), mats["sac"], (math.radians(9), math.radians(-12), 0.0))
    ico("Fragment_Husk_Curl", (0.115, 0.055, 0.045), (0.075, 0.065, 0.026), mats["sac_dark"], (math.radians(28), 0.0, math.radians(21)))
    for index, (x, y) in enumerate(((-0.06, 0.04), (0.05, -0.05), (0.02, 0.07))):
        limb(f"Fragment_Husk_Wart_{index}", (x, y, 0.045), (x * 1.4, y * 1.4, 0.105), 0.060, 0.010, mats["wart"], vertices=4)


def build_fragment_gleba(mats: dict[str, bpy.types.Material]) -> None:
    """A clot of the spore mass, still lit, sitting in a scrap of the ostiole.

    The nastiest of the four families' debris pieces and the most informative:
    it is the stuff that was inside, on the outside, still glowing. A player who
    has been caught by one burst and then finds this on the ground has been told
    exactly what happened to them.
    """
    ico("Fragment_Gleba_Clot", (0.0, 0.0, 0.045), (0.105, 0.095, 0.045), mats["gleba"])
    ico("Fragment_Gleba_Rim", (-0.085, 0.02, 0.028), (0.085, 0.075, 0.026), mats["sac_dark"], (0.0, math.radians(22), 0.0))
    ico("Fragment_Gleba_Spatter", (0.115, -0.055, 0.018), (0.048, 0.042, 0.018), mats["gleba"])


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
    """Export the rigged Bloatcap.

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
        set_visible(record, record["name"] == "enemy_bloatcap")
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
        tile_path = PREVIEW_DIR / f"bloatcap_pose_tile_{index}.png"
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

    output = bpy.data.images.new("Bloatcap_Pose_Sheet", width=columns * cell, height=rows * cell, alpha=True)
    output.pixels = sheet.reshape(-1)
    output.filepath_raw = str(PREVIEW_DIR / "bloatcap_pose_sheet.png")
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
        # The fourth distinct palette on the ladder, and the first PALE one. Tier
        # 1 is purple gel, tier 2 cold grey plumage, tier 3 near-black peat — so
        # this one is a bloated off-white sac, which is both what a puffball
        # actually looks like and the single most visible thing in a night wave.
        # That visibility is deliberate: this is the enemy you are supposed to
        # see early and deal with from range, and one you failed to notice is
        # already a mistake rather than an ambush.
        "sac": mat("fungus_gill"),
        "sac_light": mat("flower_white"),
        "sac_dark": mat("fungus_edible"),
        "wart": mat("bone"),
        "stem": mat("wood_dead"),
        "stem_dark": mat("peat"),
        # The gleba is the Mire's purple, not the Bulwark's green: the lure was
        # BAIT and this is CORRUPTION, and the roster should never say those two
        # things in the same colour.
        "gleba": mat("mire_glow"),
        "eye": mat("critical"),
        "ground": mat("preview_ground"),
        "scale": mat("reference_blue"),
    }

    records: list[dict] = []

    armature, mesh = build_bloatcap_rig(mats)
    clips = build_animations(armature)
    records.append(create_rigged_asset("enemy_bloatcap", "enemy", armature, mesh, clips, (-0.30, 0.0, 0.0)))

    statics: list[tuple[str, str, Callable[[], None], tuple[float, float, float]]] = [
        ("enemy_bloatcap_fragment_husk", "debris", lambda: build_fragment_husk(mats), (0.95, 0.22, 0.0)),
        ("enemy_bloatcap_fragment_gleba", "debris", lambda: build_fragment_gleba(mats), (1.45, -0.20, 0.0)),
    ]
    for name, family, builder, location in statics:
        records.append(create_static_asset(name, family, builder, location))

    if [record["name"] for record in records] != EXPECTED_NAMES:
        raise RuntimeError("Bloatcap specification and expected export list diverged")

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
        box("Scale_Post", (-1.35, -0.40, 0.9), (0.06, 0.06, 1.8), mats["scale"]),
        box("Scale_Tick_50", (-1.27, -0.40, 0.50), (0.20, 0.06, 0.022), mats["scale"]),
        box("Scale_Tick_100", (-1.27, -0.40, 1.00), (0.26, 0.06, 0.028), mats["scale"]),
        box("Scale_Tick_150", (-1.27, -0.40, 1.50), (0.20, 0.06, 0.022), mats["scale"]),
        box("Scale_Tick_180", (-1.27, -0.40, 1.80), (0.30, 0.06, 0.030), mats["scale"]),
        box("Scale_20cm_Cube", (-1.12, -0.46, 0.10), (0.20, 0.20, 0.20), mats["scale"]),
    ]
    move_to_collection(scale_parts, preview_collection)
    camera.data.ortho_scale = 3.3
    camera.location = (2.7, -3.9, 1.85)
    look_at(camera, (0.05, -0.05, 0.72))
    scene.render.filepath = str(PREVIEW_DIR / "bloatcap_preview.png")
    bpy.ops.render.render(write_still=True)

    reference_cube = scale_parts.pop()
    for scale_part in scale_parts:
        bpy.data.objects.remove(scale_part, do_unlink=True)
    reference_cube.location = (0.55, 0.44, 0.10)

    render_pose_sheet(
        scene,
        camera,
        armature,
        records,
        [
            ("idle" + LOOP_SUFFIX, "breathing in", 48),
            ("idle" + LOOP_SUFFIX, "breathing out", 78),
            ("locomotion" + LOOP_SUFFIX, "waddle", 8),
            ("attack_tell", "swollen", 19),
            ("attack", "vented", 5),
            ("hit", "dented", 3),
            ("death", "last swell", 7),
            ("death", "spent", 1 + DEATH_FRAMES),
        ],
        columns=4,
        cell=440,
    )

    bpy.data.objects.remove(reference_cube, do_unlink=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "enemy_bloatcap.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(
        f"Built {len(records)} Bloatcap assets ({total_polygons} polygons total), "
        f"{len(clips)} clips on {len(armature.data.bones)} bones"
    )


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
