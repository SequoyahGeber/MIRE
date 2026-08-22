"""Build the Fen Stalker — tier 2 of the enemy ladder (docs/ENEMIES.md §4).

Run with:
  Blender --background --python tools/blender/build_enemy_fen_stalker.py

Outputs three metre-scale GLBs — one rigged and animated Fen Stalker and its two
death fragments — plus an editable Blender source, its rows merged into the
shared enemy catalog, a group preview and a pose contact sheet. Geometry, rig
and animation are deterministic.

Third rigged family in `assets/enemies/`, after A-006's crawler and the
Peatling, and it follows both: rigid one-bone-per-part skinning, every action
keys every animated bone (rotation, location AND scale), no raw float in any
datablock name, `-loop` only on the two clips that may loop, every clip authored
no longer than the `EnemyDef` window it plays under.

The real subject, because a generator should never have to guess: grey herons
and bitterns. Three facts do all the work here.

The legs are nearly HALF the total height. That single proportion is what makes
a heron read as a heron at any distance, and it is what makes this creature read
as "not the last one" the instant it enters the night pool — tier 1 is a blob
under your aim line, tier 2 stands over your head on stilts.

The neck is a SPRING, not a limb. Twenty-odd cervical vertebrae with a modified
sixth let a heron fold its neck into a mid-cervical Z-bend, hold it drawn down
onto the body, and then fire the head forward on it, driving a dagger bill into
prey. That anatomy is already a telegraph and a strike; `attack_tell` coils it
and `attack` releases it, and nothing about the timing had to be invented. Note
the neck is built as THREE bones plus a head and a bill, because a two-bone neck
cannot make an S — it can only make a V, which reads as a broken neck.

Bitterns FREEZE. The concealment posture is motionless with the bill pointed
straight up, held until the threat leaves. So `idle` here is near-total
stillness — the opposite of every other idle in the game, and the whole reason
the ambush mechanic in `content/enemies/fen_stalker.tres` has anything to hide
behind.

Nothing here writes to `mire_art.py`. The palette is deliberately COLD, and
almost entirely different from tier 1's: `fish_scale` is the only cool natural
colour the world owns and it is exactly a heron's flank, with `stone_dark` for
the shadowed plumage and `fish_belly` for the throat. The Mire's purple appears
only as glow at the joints and a crystal growth on the mantle — enough to say
whose this is, never enough to make it the same creature as the Peatling.
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
    "enemy_fen_stalker",
    "enemy_fen_stalker_fragment_plume",
    "enemy_fen_stalker_fragment_bill",
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

## Clip lengths in FRAMES, each one no longer than the `EnemyDef` window it plays
## under — `Enemy` starts the next state on its own timer, so a clip that outran
## its window would be cut mid-motion and the next would start from a pose the
## previous one never reached. A clip that ends early holds its last frame.
##
## MIND THE OFF-BY-ONE. Every clip here is keyed from frame 1 to frame
## `1 + N_FRAMES`, and Godot reports the imported length as LAST FRAME over fps,
## not as the number of intervals — so a clip keyed 1..16 arrives as 0.533 s, not
## 0.5 s. Each constant below is therefore one less than the count it looks like.
## `tools/enemy_fen_stalker_check.gd` asserts the result against the authored
## `.tres` rather than against these numbers, which is how the discrepancy was
## found in the first place.
TELL_FRAMES = 14       # last frame 15 -> 0.500 s, exactly fen_stalker.tres's attack_tell_seconds
ATTACK_FRAMES = 6      # last frame 7 -> 0.233 s, under its 0.25 s attack_seconds
HIT_FRAMES = 8         # last frame 9 -> 0.300 s
DEATH_FRAMES = 41      # last frame 42 -> 1.400 s
IDLE_FRAMES = 89       # last frame 90 -> 3.000 s; long, because almost nothing happens in it
LOCOMOTION_FRAMES = 26  # last frame 27 -> 0.900 s

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


# ── The Fen Stalker's skeleton ────────────────────────────────────────────────
#
# One table, used three times: to build the armature, to name the vertex groups
# the mesh parts bind to, and to place the geometry that rides each bone. A limb
# and the bone inside it cannot drift apart because both read these points.
#
# The proportions are the design. Hip at 1.12 m on a creature 2.1 m tall means
# the legs are 53% of the height, which is the heron proportion and the entire
# reason the silhouette works. The ankle is BEHIND the knee, because a bird's
# visible backward-bending joint is its ankle and not its knee, and getting that
# wrong is the single most common way a bird model reads as a lizard.

HIP = Vector((0.13, FORWARD * -0.02, 1.12))
KNEE = Vector((0.15, FORWARD * 0.06, 0.86))
ANKLE = Vector((0.15, FORWARD * -0.10, 0.46))
FOOT = Vector((0.15, FORWARD * 0.02, 0.026))
TOE = Vector((0.15, FORWARD * 0.20, 0.014))


def mirrored(point: Vector, side: float) -> Vector:
    return Vector((point.x * side, point.y, point.z))


## The neck at rest, as a genuine S. Read the Y column: the base goes up and
## BACK (-0.10, then -0.17), the middle swings FORWARD and up (+0.02, +0.15), and
## the head comes forward and slightly DOWN over the breast (+0.25 at 1.85, below
## the 1.87 it just reached). The first pass had every segment further forward
## than the last, which is a C and not an S — and a C reads as a giraffe, or as a
## neck already extended, which is exactly the silhouette the strike is supposed
## to be the only source of.
NECK_BASE = Vector((0.0, FORWARD * -0.10, 1.42))
NECK_1 = Vector((0.0, FORWARD * -0.17, 1.60))
NECK_2 = Vector((0.0, FORWARD * 0.02, 1.80))
NECK_3 = Vector((0.0, FORWARD * 0.15, 1.87))
HEAD = Vector((0.0, FORWARD * 0.25, 1.85))
BILL_TIP = Vector((0.0, FORWARD * 0.67, 1.79))


def bone_table() -> list[tuple[str, Vector, Vector, str | None]]:
    """(name, head, tail, parent) for every bone, in creation order."""
    bones: list[tuple[str, Vector, Vector, str | None]] = [
        ("root", Vector((0.0, 0.0, 0.0)), Vector((0.0, 0.0, 0.14)), None),
        ("hips", Vector((0.0, FORWARD * -0.16, 1.18)), Vector((0.0, FORWARD * 0.02, 1.26)), "root"),
        ("body", Vector((0.0, FORWARD * 0.02, 1.26)), Vector((0.0, FORWARD * -0.12, 1.42)), "hips"),
        ("tail", Vector((0.0, FORWARD * -0.16, 1.18)), Vector((0.0, FORWARD * -0.52, 1.08)), "hips"),
        ("wing_l", Vector((0.17, FORWARD * 0.04, 1.34)), Vector((0.22, FORWARD * -0.26, 1.14)), "body"),
        ("wing_r", Vector((-0.17, FORWARD * 0.04, 1.34)), Vector((-0.22, FORWARD * -0.26, 1.14)), "body"),
        ("neck_1", NECK_BASE, NECK_1, "body"),
        ("neck_2", NECK_1, NECK_2, "neck_1"),
        ("neck_3", NECK_2, NECK_3, "neck_2"),
        ("head", NECK_3, HEAD, "neck_3"),
        ("bill", HEAD, BILL_TIP, "head"),
    ]
    for side_name, side in (("l", 1.0), ("r", -1.0)):
        bones.append((f"leg_{side_name}_thigh", mirrored(HIP, side), mirrored(KNEE, side), "hips"))
        bones.append((f"leg_{side_name}_shin", mirrored(KNEE, side), mirrored(ANKLE, side), f"leg_{side_name}_thigh"))
        bones.append((f"leg_{side_name}_shank", mirrored(ANKLE, side), mirrored(FOOT, side), f"leg_{side_name}_shin"))
        bones.append((f"leg_{side_name}_foot", mirrored(FOOT, side), mirrored(TOE, side), f"leg_{side_name}_shank"))
    return bones


DEFORM_BONES = [name for name, _, _, parent in bone_table() if parent is not None]


# ── The Fen Stalker's mesh ────────────────────────────────────────────────────


def build_stalker_parts(mats: dict[str, bpy.types.Material]) -> list[tuple[bpy.types.Object, str]]:
    """Every mesh part paired with the single bone that drives it."""
    parts: list[tuple[bpy.types.Object, str]] = []

    def add(obj: bpy.types.Object, bone: str) -> None:
        parts.append((obj, bone))

    # ── Body: a deep, narrow ovoid. NARROW is the point — a heron seen head-on
    # is almost a line, and that is what makes one standing in reeds disappear.
    add(ico("Stalker_Body", (0.0, FORWARD * -0.04, 1.30), (0.185, 0.330, 0.215), mats["plume"], subdivisions=2), "body")
    add(ico("Stalker_Breast", (0.0, FORWARD * 0.14, 1.26), (0.150, 0.180, 0.180), mats["belly"], subdivisions=1), "body")
    add(ico("Stalker_Rump", (0.0, FORWARD * -0.22, 1.24), (0.150, 0.160, 0.160), mats["plume_dark"], subdivisions=1), "hips")

    # The mantle — the shoulders a heron hunches its neck down into — and the
    # crystal growth that says whose creature this is. Small and high: the Mire
    # is a mark on this one, not its substance.
    add(box("Stalker_Mantle", (0.0, FORWARD * 0.00, 1.42), (0.26, 0.30, 0.10), mats["plume_dark"], (math.radians(FORWARD * -8), 0.0, 0.0)), "body")
    add(cone("Stalker_Growth_1", 0.042, 0.010, 0.21, (0.05, FORWARD * -0.06, 1.55), mats["crystal"], 5, (math.radians(FORWARD * 16), math.radians(20), 0.0)), "body")
    add(cone("Stalker_Growth_2", 0.030, 0.008, 0.15, (-0.06, FORWARD * -0.12, 1.51), mats["crystal"], 5, (math.radians(FORWARD * 22), math.radians(-24), 0.0)), "body")

    # Folded wings, as flat slabs against the flanks with three primaries each
    # trailing past the tail. A heron at rest is not a bird with wings out; the
    # wing is a shape ON the body, and only the primary tips break the outline.
    for side_name, side in (("l", 1.0), ("r", -1.0)):
        bone = f"wing_{side_name}"
        # A folded wing is a TAPERED PLATE lying along the flank, not a slab. The
        # first pass used a box and the render came back with two black cardboard
        # rectangles bolted to the ribs — the single worst thing in the frame. An
        # ico flattened on X gives the same coverage with a leading edge that
        # thins into the body and a trailing edge that tapers toward the tail,
        # which is what actually reads as a wing at rest.
        add(ico(f"Stalker_Wing_{side_name}", (0.170 * side, FORWARD * -0.05, 1.31), (0.052, 0.235, 0.150), mats["plume"], (math.radians(FORWARD * 6), math.radians(-6 * side), 0.0)), bone)
        add(ico(f"Stalker_Covert_{side_name}", (0.172 * side, FORWARD * 0.04, 1.37), (0.046, 0.130, 0.085), mats["plume_dark"], (math.radians(FORWARD * 10), 0.0, 0.0)), bone)
        for index in range(3):
            add(
                plume(
                    f"Stalker_Primary_{side_name}_{index}",
                    (0.160 * side, FORWARD * (-0.17 - index * 0.02), 1.29 - index * 0.030),
                    (0.132 * side, FORWARD * (-0.46 - index * 0.045), 1.17 - index * 0.048),
                    0.072,
                    mats["plume_dark"],
                ),
                bone,
            )

    # Tail: a short blunt wedge. A heron's tail is almost an afterthought and
    # making it long would read as a pheasant.
    add(cone("Stalker_Tail", 0.105, 0.030, 0.34, (0.0, FORWARD * -0.34, 1.13), mats["plume_dark"], 5, (math.radians(FORWARD * 74), 0.0, 0.0)), "tail")

    # Shaggy breast plumes — the loose hanging feathers under a heron's throat.
    # Cheap (two triangles each) and they do more for "this is alive" than any
    # amount of body detail.
    # Three, narrow, hanging nearly straight down. Five wide ones read as a row of
    # fangs under the throat, which is a different animal entirely.
    for index, (x, drop) in enumerate(((0.045, 0.21), (-0.045, 0.24), (0.0, 0.28))):
        add(
            plume(
                f"Stalker_Breast_Plume_{index}",
                (x, FORWARD * 0.15, 1.29),
                (x * 1.15, FORWARD * (0.17 + drop * 0.18), 1.29 - drop),
                0.048,
                mats["belly"],
            ),
            "body",
        )

    # ── Legs. Four segments a side: thigh (short, tucked), the long tibia, the
    # tarsus that bends BACKWARD at the ankle, and a splayed foot.
    for side_name, side in (("l", 1.0), ("r", -1.0)):
        hip = mirrored(HIP, side)
        knee = mirrored(KNEE, side)
        ankle = mirrored(ANKLE, side)
        foot = mirrored(FOOT, side)
        toe = mirrored(TOE, side)
        add(limb(f"Stalker_Thigh_{side_name}", hip, knee, 0.115, 0.075, mats["plume"]), f"leg_{side_name}_thigh")
        add(limb(f"Stalker_Tibia_{side_name}", knee, ankle, 0.070, 0.046, mats["leg"]), f"leg_{side_name}_shin")
        add(ico(f"Stalker_Ankle_{side_name}", tuple(ankle), (0.036, 0.036, 0.036), mats["leg_dark"]), f"leg_{side_name}_shin")
        add(limb(f"Stalker_Tarsus_{side_name}", ankle, foot, 0.046, 0.038, mats["leg"]), f"leg_{side_name}_shank")
        # Three forward toes and one back, flat on the ground — the wide splay is
        # how a wader stands on ground that will not hold anything else up, and
        # it is also what keeps a two-metre creature from reading as top-heavy.
        for index, spread in enumerate((-26.0, 0.0, 26.0)):
            angle = math.radians(spread)
            tip = Vector((
                foot.x + math.sin(angle) * 0.16 * side,
                foot.y + FORWARD * math.cos(angle) * 0.20,
                # The toe TIP, not the toe joint. A toe is a tapered tube laid
                # almost flat, so its end cap hangs half its own end radius below
                # the point the bone ends at — put the tip at 0.012 and the claw
                # is buried, which the rest-pose contact assert catches. Ground
                # contact is a fact about the mesh, not about the skeleton.
                0.006,
            ))
            add(limb(f"Stalker_Toe_{side_name}_{index}", foot, tip, 0.034, 0.014, mats["leg"]), f"leg_{side_name}_foot")
        add(limb(f"Stalker_Hallux_{side_name}", foot, Vector((foot.x, foot.y - FORWARD * 0.11, 0.006)), 0.028, 0.012, mats["leg"]), f"leg_{side_name}_foot")

    # ── The neck: the spring. Four visible segments over three bones plus the
    # head, each a tapering tube between two points from the table above, with a
    # thicker collar where the Z-bend folds. The corruption glow lives here and
    # nowhere else on the body — so the thing a player actually tracks in the
    # dark is the exact part that is about to be launched at them.
    add(limb("Stalker_Neck_1", NECK_BASE, NECK_1, 0.135, 0.105, mats["plume"]), "neck_1")
    add(limb("Stalker_Neck_2", NECK_1, NECK_2, 0.105, 0.088, mats["plume"]), "neck_2")
    add(limb("Stalker_Neck_3", NECK_2, NECK_3, 0.088, 0.072, mats["plume"]), "neck_3")
    add(ico("Stalker_Neck_Joint_1", tuple(NECK_1), (0.062, 0.062, 0.062), mats["glow"]), "neck_1")
    add(ico("Stalker_Neck_Joint_2", tuple(NECK_2), (0.052, 0.052, 0.052), mats["glow"]), "neck_2")

    # ── Head and bill. The bill is the read and the aim point, so it is long,
    # straight and pale against everything else on the creature.
    add(ico("Stalker_Head", tuple(HEAD), (0.072, 0.098, 0.070), mats["plume"]), "head")
    add(limb("Stalker_Bill", HEAD, BILL_TIP, 0.078, 0.008, mats["bill"], vertices=4), "bill")
    add(box("Stalker_Bill_Ridge", (0.0, FORWARD * 0.50, 1.885), (0.018, 0.30, 0.020), mats["bill_dark"], (math.radians(FORWARD * -6), 0.0, 0.0)), "bill")
    for index, side in enumerate((1.0, -1.0)):
        add(ico(f"Stalker_Eye_{index}", (0.058 * side, FORWARD * 0.36, 1.915), (0.026, 0.026, 0.026), mats["eye"]), "head")
    # The nuchal crest: two long black plumes off the back of the skull. On the
    # real bird they are a breeding display; here they are the one piece of
    # silhouette that survives being seen against a bright sky.
    for index, offset in enumerate((0.022, -0.022)):
        add(
            plume(
                f"Stalker_Crest_{index}",
                (offset, FORWARD * 0.28, 1.94),
                (offset * 2.2, FORWARD * -0.02, 1.90 - index * 0.03),
                0.055,
                mats["plume_dark"],
            ),
            "head",
        )

    return parts


def build_stalker_rig(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Object, bpy.types.Object]:
    """Build the Fen Stalker mesh, bind it rigidly to its armature, return both."""
    parts = build_stalker_parts(mats)

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
    mesh.name = "Stalker_Mesh"
    mesh.data.name = "Stalker_Mesh_Data"

    bpy.ops.object.armature_add(location=(0.0, 0.0, 0.0))
    armature = bpy.context.object
    armature.name = "Stalker_Rig"
    armature.data.name = "Stalker_Rig_Data"
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
    modifier = mesh.modifiers.new("Stalker_Armature", "ARMATURE")
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
        slot = action.slots.new(id_type="OBJECT", name="Stalker") if not action.slots else action.slots[0]
        armature.animation_data.action_slot = slot
    return action


def neck(coil: float, lift: float = 0.0) -> Pose:
    """The neck as a spring, `coil` in -1..1.

    Positive coil FOLDS it — the Z-bend closes, the head is drawn back down onto
    the shoulders, and the bill ends up pointing forward from a neck that has
    become a compressed spring. Negative EXTENDS it, driving the head forward and
    down along the line the bill was already pointing.

    One function rather than hand-authored keys per clip, because the tell and
    the strike have to be exact opposites of each other or the strike does not
    read as a release. `lift` tilts the whole assembly up without changing the
    fold, which is what the bittern freeze needs.
    """
    folded = max(0.0, coil)
    extended = max(0.0, -coil)
    # The signs matter more than the magnitudes. FOLDING alternates them, because
    # that is what a Z-bend is — each segment turning against the one before it.
    # EXTENDING must not: every segment turns the SAME way, which is what takes
    # the S out of the neck and lays the whole chain along one forward line. The
    # first pass alternated the extension too, and the strike came back reading
    # as "the bird looked up" — it kept its S, so it never got longer, which is
    # the only thing the strike is for.
    return {
        "neck_1": (34.0 * folded - 52.0 * extended + lift * -22.0, 0.0, 0.0),
        "neck_2": (-48.0 * folded - 46.0 * extended + lift * -14.0, 0.0, 0.0),
        "neck_3": (44.0 * folded - 38.0 * extended + lift * -20.0, 0.0, 0.0),
        "head": (-30.0 * folded - 22.0 * extended + lift * -26.0, 0.0, 0.0),
        "bill": (-4.0 * folded - 6.0 * extended, 0.0, 0.0),
    }


def stance(crouch: float, stride: float = 0.0) -> Pose:
    """Both legs together. `crouch` bends the whole stack; `stride` splits them.

    A bird crouches by closing the ankle, not the knee — the tibia swings back
    and the tarsus swings forward under it, which is why the two signs differ.
    """
    pose: Pose = {}
    for index, (side_name, direction) in enumerate((("l", 1.0), ("r", -1.0))):
        step = stride * (1.0 if index == 0 else -1.0)
        # `crouch` = 1.0 is a COMPLETE collapse, not a deep bend, because the death
        # clip is the only caller that ever asks for it and a bird on stilts has
        # to fold rather than topple. The walking and idle clips ask for 0.22 and
        # 0.10, which land on the few degrees of give a standing heron actually
        # has. The first pass scaled these for "a crouch" and the death clip came
        # back with the legs still straight under a body that had somehow sunk.
        pose[f"leg_{side_name}_thigh"] = (-34.0 * crouch + 26.0 * step, 0.0, 5.0 * direction * crouch)
        pose[f"leg_{side_name}_shin"] = (74.0 * crouch - 34.0 * step, 0.0, 0.0)
        pose[f"leg_{side_name}_shank"] = (-58.0 * crouch + 20.0 * step, 0.0, 0.0)
        pose[f"leg_{side_name}_foot"] = (16.0 * crouch - 12.0 * step, 0.0, 0.0)
    return pose


def merge(*poses: Pose) -> Pose:
    merged: Pose = {}
    for pose in poses:
        merged.update(pose)
    return merged


def build_animations(armature: bpy.types.Object) -> list[tuple[str, int, int]]:
    """Author every clip. Returns (name, first frame, last frame) per clip."""
    clips: list[tuple[str, int, int]] = []

    # ── idle-loop — 3.0 s of NOT MOVING.
    #
    # This is the bittern freeze and it is deliberately the least animated clip
    # in the game: bill up, neck folded onto the shoulders, and over three
    # seconds a two-degree weight shift and one slow head roll. Anything more
    # would give it away, and giving it away is what the ambush mechanic
    # (`ambush_damage_multiplier`, docs/ENEMIES.md §4.2) is paying for.
    #
    # The long length is part of it. A short loop reads as a repeating twitch;
    # three seconds of near-stillness reads as a thing that is not alive.
    new_action(armature, "idle" + LOOP_SUFFIX)
    for frame, sway, head_roll in (
        (1, 0.0, 0.0),
        (26, 0.8, 1.5),
        (48, 1.2, -1.0),
        (70, 0.4, 2.0),
        (91, 0.0, 0.0),  # repeats frame 1 exactly, so the loop has no seam
    ):
        apply_pose(
            armature,
            frame,
            merge(
                stance(0.10),
                neck(0.85, lift=1.0),
                {"body": (sway * 0.6, sway, 0.0), "head": (neck(0.85, lift=1.0)["head"][0], head_roll, 0.0)},
            ),
        )
    clips.append(("idle" + LOOP_SUFFIX, 1, 1 + IDLE_FRAMES))

    # ── locomotion-loop — 0.9 s. The stalk.
    #
    # High, deliberate knee lift and a body that stays LEVEL: a wading bird
    # carries its mass on a gimbal and picks its feet up out of the mud, and the
    # head counter-bobs against the stride the way every walking bird's does.
    # There is no bounce in the body at all — the give is all in the legs.
    new_action(armature, "locomotion" + LOOP_SUFFIX)
    for step in range(LOCOMOTION_FRAMES + 1):
        phase = step / LOCOMOTION_FRAMES
        stride = math.sin(phase * math.tau)
        # Head bob is at twice the stride frequency and lags it by a quarter
        # cycle — the classic pigeon-walk hold-and-thrust, not a sine on the body.
        bob = math.sin(phase * math.tau - math.pi * 0.5) * 6.0
        apply_pose(
            armature,
            1 + step,
            merge(
                stance(0.22, stride),
                neck(0.62),
                {
                    "body": (2.0, math.sin(phase * math.tau) * 2.5, 0.0),
                    "neck_1": (neck(0.62)["neck_1"][0] + bob * 0.5, 0.0, 0.0),
                    "head": (neck(0.62)["head"][0] - bob, 0.0, 0.0),
                },
            ),
            {"body": (0.0, FORWARD * math.sin(phase * math.tau * 2.0) * 0.012, 0.0)},
        )
    clips.append(("locomotion" + LOOP_SUFFIX, 1, 1 + LOCOMOTION_FRAMES))

    # ── attack_tell — 0.5 s. The spring loads.
    #
    # Longer than DESIGN.md §6's 0.4 s baseline ON PURPOSE, and the one place in
    # this creature's design where the player is given something back: the strike
    # that follows is 0.23 s, has 3.2 m of reach and closes ground while the tell
    # runs (`lunge_speed_m_s`), so it is close to unavoidable once committed.
    # Half a second is what makes it fair. The shape is unmistakable — the neck
    # folds to its tightest, the head DROPS AND PULLS BACK, and the whole body
    # tips forward over the feet. Nothing else in the roster gets shorter as it
    # winds up.
    new_action(armature, "attack_tell")
    apply_pose(armature, 1, merge(stance(0.20), neck(0.60)))
    apply_pose(armature, 6, merge(stance(0.34), neck(0.92), {"body": (-9.0, 0.0, 0.0)}))
    apply_pose(
        armature,
        11,
        merge(stance(0.46), neck(1.0), {"body": (-15.0, 0.0, 0.0), "tail": (12.0, 0.0, 0.0)}),
    )
    # Holds its extreme for the last third. A tell still moving when the strike
    # begins never registers as a warning.
    apply_pose(
        armature,
        1 + TELL_FRAMES,
        merge(stance(0.46), neck(1.0), {"body": (-15.0, 0.0, 0.0), "tail": (12.0, 0.0, 0.0)}),
    )
    clips.append(("attack_tell", 1, 1 + TELL_FRAMES))

    # ── attack — 0.233 s. The spring releases.
    #
    # Frame 1 is the tell's last frame exactly, so the two chain without a pop.
    # The bill is fully out by frame 4 — 0.1 s from coiled to extended, which is
    # as close to the real animal as an animation at 30 fps gets — and the last
    # three frames are the neck starting to gather again, so the clip hands over
    # to RECOVER already moving.
    new_action(armature, "attack")
    apply_pose(armature, 1, merge(stance(0.46), neck(1.0), {"body": (-15.0, 0.0, 0.0), "tail": (12.0, 0.0, 0.0)}))
    apply_pose(
        armature,
        4,
        merge(stance(0.16), neck(-1.0), {"body": (-26.0, 0.0, 0.0), "tail": (-16.0, 0.0, 0.0)}),
        {"body": (0.0, FORWARD * 0.10, -0.02)},
    )
    apply_pose(
        armature,
        1 + ATTACK_FRAMES,
        merge(stance(0.26), neck(-0.35), {"body": (-16.0, 0.0, 0.0)}),
        {"body": (0.0, FORWARD * 0.03, 0.0)},
    )
    clips.append(("attack", 1, 1 + ATTACK_FRAMES))

    # ── hit — 0.3 s. Wings out, head up, one step of stagger.
    #
    # A bird's flinch is a startle: the wings come off the body and the head
    # snaps AWAY and UP, which is legible from any angle including directly
    # behind — the angle a player circling to its blind side is standing at.
    new_action(armature, "hit")
    apply_pose(armature, 1, merge(stance(0.20), neck(0.60)))
    apply_pose(
        armature,
        3,
        merge(
            stance(0.44, 0.30),
            neck(0.35, lift=0.8),
            {"body": (11.0, 9.0, 0.0), "wing_l": (0.0, 0.0, -46.0), "wing_r": (0.0, 0.0, 46.0), "tail": (-14.0, 0.0, 0.0)},
        ),
        {"body": (0.0, FORWARD * -0.05, -0.03)},
    )
    apply_pose(
        armature,
        6,
        merge(
            stance(0.30, 0.10),
            neck(0.52, lift=0.3),
            {"body": (4.0, -4.0, 0.0), "wing_l": (0.0, 0.0, -18.0), "wing_r": (0.0, 0.0, 18.0)},
        ),
    )
    apply_pose(armature, 1 + HIT_FRAMES, merge(stance(0.20), neck(0.60)))
    clips.append(("hit", 1, 1 + HIT_FRAMES))

    # ── death — 1.4 s. The legs go first.
    #
    # Which is the whole point of killing a thing that stands on stilts: it does
    # not topple like a statue, it FOLDS — the ankles buckle, the body drops
    # straight down onto them, and only then does it fall sideways. The neck is
    # last, and it comes down in a slack curl rather than a straight line,
    # because it was never a limb. Ends flat and still: the corpse and the
    # fragments inherit this pose.
    new_action(armature, "death")
    apply_pose(armature, 1, merge(stance(0.20), neck(0.60)))
    apply_pose(
        armature,
        7,
        merge(stance(0.10), neck(0.20, lift=1.0), {"body": (-8.0, 0.0, 0.0), "wing_l": (0.0, 0.0, -30.0), "wing_r": (0.0, 0.0, 30.0)}),
        {"body": (0.0, 0.0, 0.03)},
    )
    apply_pose(
        armature,
        18,
        merge(stance(1.0), neck(0.30, lift=0.2), {"body": (14.0, 16.0, 0.0), "wing_l": (0.0, 0.0, -40.0), "wing_r": (0.0, 0.0, 22.0), "tail": (-10.0, 0.0, 0.0)}),
        {"body": (0.0, 0.0, -0.30)},
    )
    apply_pose(
        armature,
        30,
        merge(stance(1.0, 0.35), neck(0.55), {"body": (8.0, 62.0, 0.0), "neck_1": (52.0, 26.0, 0.0), "neck_2": (-70.0, 0.0, 0.0), "neck_3": (58.0, 0.0, 0.0), "head": (-24.0, 0.0, 18.0), "wing_l": (0.0, 0.0, -52.0), "wing_r": (0.0, 0.0, 10.0)}),
        {"body": (0.0, 0.0, -0.62)},
    )
    apply_pose(
        armature,
        1 + DEATH_FRAMES,
        merge(stance(1.0, 0.35), neck(0.55), {"body": (4.0, 78.0, 0.0), "neck_1": (58.0, 34.0, 0.0), "neck_2": (-76.0, 0.0, 0.0), "neck_3": (62.0, 0.0, 0.0), "head": (-28.0, 0.0, 22.0), "wing_l": (0.0, 0.0, -56.0), "wing_r": (0.0, 0.0, 6.0), "tail": (6.0, 0.0, 0.0)}),
        {"body": (0.0, 0.0, -0.74)},
    )
    clips.append(("death", 1, 1 + DEATH_FRAMES))

    if [name for name, _, _ in clips] != EXPECTED_ANIMATIONS:
        raise RuntimeError("Fen Stalker animation specification and expected clip list diverged")
    return clips


# ── The death fragments ───────────────────────────────────────────────────────


def build_fragment_plume(mats: dict[str, bpy.types.Material]) -> None:
    """A torn clump of flank feathers with one glowing quill still in it."""
    plume("Fragment_Plume_1", (0.0, 0.0, 0.012), (0.24, 0.06, 0.030), 0.10, mats["plume"])
    plume("Fragment_Plume_2", (0.01, 0.02, 0.020), (-0.18, 0.12, 0.026), 0.085, mats["plume_dark"])
    plume("Fragment_Plume_3", (-0.01, -0.01, 0.016), (0.06, -0.20, 0.022), 0.070, mats["belly"])
    ico("Fragment_Plume_Quill", (0.0, 0.0, 0.022), (0.028, 0.028, 0.022), mats["glow"])


def build_fragment_bill(mats: dict[str, bpy.types.Material]) -> None:
    """The bill, snapped off with a piece of skull still attached.

    The one fragment in the family that is a WEAPON lying on the ground. It is
    the same dagger that was pointed at the player thirty seconds ago, and that
    is the whole reason it is the debris piece rather than a generic bone chip.
    """
    limb("Fragment_Bill", (-0.14, 0.0, 0.026), (0.22, 0.05, 0.014), 0.070, 0.010, mats["bill"], vertices=4)
    box("Fragment_Bill_Ridge", (0.04, 0.025, 0.036), (0.016, 0.22, 0.016), mats["bill_dark"], (0.0, 0.0, math.radians(8)))
    ico("Fragment_Bill_Skull", (-0.17, -0.01, 0.034), (0.055, 0.048, 0.034), mats["plume"])


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
    """Export the rigged Stalker.

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
        set_visible(record, record["name"] == "enemy_fen_stalker")
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
        tile_path = PREVIEW_DIR / f"fen_stalker_pose_tile_{index}.png"
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

    output = bpy.data.images.new("Stalker_Pose_Sheet", width=columns * cell, height=rows * cell, alpha=True)
    output.pixels = sheet.reshape(-1)
    output.filepath_raw = str(PREVIEW_DIR / "fen_stalker_pose_sheet.png")
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
        # COLD, and almost entirely disjoint from tier 1's palette. `fish_scale`
        # is the world's only cool natural colour and it is exactly a heron's
        # flank; `stone_dark` shadows it; `fish_belly` is the pale throat. The
        # bill is `bone` because a dagger has to be the brightest thing on the
        # creature. The Mire appears only as glow at the neck joints and two
        # crystal growths on the mantle — enough to say whose this is, never
        # enough to make it the Peatling's cousin.
        "plume": mat("fish_scale"),
        "plume_dark": mat("stone_dark"),
        "belly": mat("fish_belly"),
        "leg": mat("wood_dead"),
        "leg_dark": mat("stone_dark"),
        "bill": mat("bone"),
        "bill_dark": mat("wood_dead"),
        "eye": mat("eye"),
        "glow": mat("mire_glow"),
        "crystal": mat("crystal"),
        "ground": mat("preview_ground"),
        "scale": mat("reference_blue"),
    }

    records: list[dict] = []

    armature, mesh = build_stalker_rig(mats)
    clips = build_animations(armature)
    records.append(create_rigged_asset("enemy_fen_stalker", "enemy", armature, mesh, clips, (-0.30, 0.0, 0.0)))

    statics: list[tuple[str, str, Callable[[], None], tuple[float, float, float]]] = [
        ("enemy_fen_stalker_fragment_plume", "debris", lambda: build_fragment_plume(mats), (0.95, 0.20, 0.0)),
        ("enemy_fen_stalker_fragment_bill", "debris", lambda: build_fragment_bill(mats), (1.45, -0.18, 0.0)),
    ]
    for name, family, builder, location in statics:
        records.append(create_static_asset(name, family, builder, location))

    if [record["name"] for record in records] != EXPECTED_NAMES:
        raise RuntimeError("Fen Stalker specification and expected export list diverged")

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
    # A 1.8 m player-height post as well as the metre ruler. On a creature this
    # tall the number that matters is not "how many centimetres" but "does it
    # look down at you", and only a human-height reference answers that.
    scale_parts = [
        box("Scale_Post", (-1.25, -0.30, 0.9), (0.06, 0.06, 1.8), mats["scale"]),
        box("Scale_Tick_50", (-1.17, -0.30, 0.50), (0.20, 0.06, 0.022), mats["scale"]),
        box("Scale_Tick_100", (-1.17, -0.30, 1.00), (0.26, 0.06, 0.028), mats["scale"]),
        box("Scale_Tick_150", (-1.17, -0.30, 1.50), (0.20, 0.06, 0.022), mats["scale"]),
        box("Scale_Tick_180", (-1.17, -0.30, 1.80), (0.30, 0.06, 0.030), mats["scale"]),
        box("Scale_20cm_Cube", (-0.95, -0.34, 0.10), (0.20, 0.20, 0.20), mats["scale"]),
    ]
    move_to_collection(scale_parts, preview_collection)
    camera.data.ortho_scale = 3.4
    camera.location = (2.9, -4.4, 2.35)
    look_at(camera, (0.05, -0.05, 0.95))
    scene.render.filepath = str(PREVIEW_DIR / "fen_stalker_preview.png")
    bpy.ops.render.render(write_still=True)

    reference_cube = scale_parts.pop()
    for scale_part in scale_parts:
        bpy.data.objects.remove(scale_part, do_unlink=True)
    reference_cube.location = (0.42, 0.34, 0.10)

    render_pose_sheet(
        scene,
        camera,
        armature,
        records,
        [
            ("idle" + LOOP_SUFFIX, "the freeze", 48),
            ("locomotion" + LOOP_SUFFIX, "stalk contact", 8),
            ("locomotion" + LOOP_SUFFIX, "stalk pass", 21),
            ("attack_tell", "spring loaded", 13),
            ("attack", "strike", 4),
            ("attack", "recover", 1 + ATTACK_FRAMES),
            ("hit", "startle", 3),
            ("death", "folded", 1 + DEATH_FRAMES),
        ],
        columns=4,
        cell=440,
    )

    bpy.data.objects.remove(reference_cube, do_unlink=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "enemy_fen_stalker.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(
        f"Built {len(records)} Fen Stalker assets ({total_polygons} polygons total), "
        f"{len(clips)} clips on {len(armature.data.bones)} bones"
    )


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
