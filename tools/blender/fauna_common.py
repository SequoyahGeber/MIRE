"""Shared rig, animation and export machinery for MIRE's fauna (FAUNA.md phase 2, F-596).

Six ordinary species — chicken, cow, deer, hare, boar, songbird — each a model, a
rig and four clips. They are built by six sibling `build_fauna_*.py` scripts and
everything those scripts have in common lives here, because the one property that
matters most about this batch is that the six agree with each other: same clip
names, same rig conventions, same up-axis, same export flags. A batch assembled
six independent ways is a batch where `AnimalDef` needs six special cases.

Conventions inherited from `build_enemy_peatling.py` and `build_enemy_crawler.py`
rather than reinvented — read A-006's docstring for why each is the way it is:
rigid one-bone-per-part skinning, every action keys every animated bone, no raw
float in a datablock name, `-loop` on clips that may loop.

## Scale is against the PLAYER

`entities/player/player_controller.gd` builds its body capsule at **1.8 m**. Every
species is authored against that number and `SPECIES_SCALE` below states each one
as a fraction of it, because the failure this batch is most likely to have is the
one the chest batch is being resized for right now: a set of assets that agree
with each other and are collectively wrong next to the person looking at them. A
deer has to feel big. A chicken has to be underfoot.

Sizes come from the real animals, not from what reads nicely in isolation:

  chicken   0.42 m to the top of the head — a hen stands about knee-high, 23% of
            the player. Body length 0.40 m. Roughly 2 kg of bird.
  hare      0.40 m to the EAR TIPS sitting, 0.24 m at the back, 0.60 m long.
            Brown hare, not rabbit: longer legs, much longer black-tipped ears
            carried upright, and it does not burrow. The declared height is the
            ear tips because that is what the bounds measure and what a player
            sees above the grass.
  songbird  0.14 m. Small enough that the flock, not the bird, is the silhouette.
  boar      0.90 m at the shoulder, 1.5 m long. Front-heavy: the shoulder hump is
            the tallest point and the rump falls away behind it.
  deer      1.15 m at the shoulder, 1.55 m to the top of the head, 1.78 m to the
            ANTLER TIPS, 2.0 m long. Red deer stag. The declared height is the
            antler tips because that is what the bounds measure — the antlers
            reach the player's eye line, which is the whole point of the animal
            reading as big. Shoulder sits just below the player's chest.
  cow       1.30 m at the shoulder, 2.4 m long. Highland type: long horns, heavy
            fringe, shaggy coat. Taller than the player at the horn tips.

## `mire_art.py` is not written to

It is claimed by another session for F-473, which is still open. The peatling
builder set the precedent for exactly this situation — build from the tokens that
exist rather than blocking or editing a claimed file. Fauna would genuinely like
`fur` and `feather` tokens of its own; that is recorded in the finding rather than
taken here.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

sys.path.append(str(Path(__file__).resolve().parent))
from mire_art import mat  # noqa: E402


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "fauna"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"
SOURCE_DIR = ROOT / "assets" / "source"

## D-218. Bare species names: the kit directory already namespaces them.
SPECIES = ["chicken", "cow", "deer", "hare", "boar", "songbird"]

LOOP_SUFFIX = "-loop"

## D-218. Identical across all six, so an `AnimalDef` never carries per-species
## clip names and a behaviour state can pick a clip without knowing what it drives.
CLIP_IDLE = "idle" + LOOP_SUFFIX
CLIP_WALK = "walk" + LOOP_SUFFIX
CLIP_FLEE = "flee"
CLIP_DEATH = "death"
EXPECTED_CLIPS = [CLIP_IDLE, CLIP_WALK, CLIP_FLEE, CLIP_DEATH]

FPS = 30

## The player's own capsule height, from `player_controller.gd`. Every size below
## is a fraction of this and the check asserts the exported bounds against it.
PLAYER_HEIGHT_M = 1.8

## Standing height in metres, top of the head (or shoulder, where noted in the
## module docstring), and the fraction of the player that makes it legible.
SPECIES_HEIGHT_M = {
    "songbird": 0.14,
    "hare": 0.40,
    "chicken": 0.42,
    "boar": 0.90,
    "deer": 1.78,
    "cow": 1.45,
}

## MIND THE OFF-BY-ONE (inherited from the peatling builder, and it has bitten
## twice): clips are keyed from frame 1 to `1 + N`, and Godot reports the imported
## length as LAST FRAME over fps, not as the interval count. A clip keyed 1..14
## arrives as 0.467 s. Every constant is one less than it looks.
IDLE_FRAMES = 71        # last frame 72 -> 2.400 s
WALK_FRAMES = 29        # last frame 30 -> 1.000 s
FLEE_FRAMES = 17        # last frame 18 -> 0.600 s, a faster cycle than the walk
DEATH_FRAMES = 35       # last frame 36 -> 1.200 s


Pose = dict[str, tuple[float, float, float]]


# ── Primitives ────────────────────────────────────────────────────────────────


def assign(obj: bpy.types.Object, material: bpy.types.Material) -> bpy.types.Object:
    obj.data.materials.append(material)
    return obj


def box(
    name: str,
    location: tuple[float, float, float],
    dimensions: tuple[float, float, float],
    material: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cube_add(size=2.0, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = tuple(value * 0.5 for value in dimensions)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.rotation_euler = tuple(math.radians(angle) for angle in rotation)
    return assign(obj, material)


def ico(
    name: str,
    location: tuple[float, float, float],
    dimensions: tuple[float, float, float],
    material: bpy.types.Material,
    subdivisions: int = 2,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    """An ellipsoid. The workhorse — nearly every animal body part here is one."""
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdivisions, radius=1.0, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = tuple(value * 0.5 for value in dimensions)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.rotation_euler = tuple(math.radians(angle) for angle in rotation)
    return assign(obj, material)


def cone(
    name: str,
    location: tuple[float, float, float],
    radius1: float,
    radius2: float,
    depth: float,
    material: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
    vertices: int = 10,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cone_add(
        vertices=vertices, radius1=radius1, radius2=radius2, depth=depth, location=location
    )
    obj = bpy.context.object
    obj.name = name
    obj.rotation_euler = tuple(math.radians(angle) for angle in rotation)
    return assign(obj, material)


def world_bounds(objects: list[bpy.types.Object]) -> tuple[Vector, Vector]:
    """World-space bounds, measured off actual VERTICES.

    Not `obj.bound_box`. That box is cached, is not refreshed by joining meshes or
    binding an armature, and — measured against the engine — was wrong by 18% on
    the first chicken: the catalog claimed 0.499 m for a bird Godot loads at
    0.4115 m. The engine's figure was the correct one; 0.4115 is exactly the top
    of the authored comb, so the geometry was right all along and only the
    measurement of it was wrong.

    That mattered more than an ordinary rounding bug would, because height is the
    one field this batch exists to get right: every species is authored as a
    fraction of the player, and a catalog that overstates by a fifth is a catalog
    that would have let a visibly wrong animal through while reporting it in band.
    Walking the vertices is slower and cannot be stale.
    """
    depsgraph = bpy.context.evaluated_depsgraph_get()
    minimum = Vector((1e9, 1e9, 1e9))
    maximum = Vector((-1e9, -1e9, -1e9))
    for obj in objects:
        if obj.type != "MESH":
            continue
        evaluated = obj.evaluated_get(depsgraph)
        matrix = evaluated.matrix_world
        for vertex in evaluated.data.vertices:
            point = matrix @ vertex.co
            for axis in range(3):
                minimum[axis] = min(minimum[axis], point[axis])
                maximum[axis] = max(maximum[axis], point[axis])
    return minimum, maximum


# ── Rig ───────────────────────────────────────────────────────────────────────


def build_rig(
    species: str,
    parts: list[tuple[bpy.types.Object, str]],
    bones: list[tuple[str, tuple[float, float, float], tuple[float, float, float], str | None]],
) -> tuple[bpy.types.Object, bpy.types.Object]:
    """Join `parts` into one mesh, bind it rigidly to an armature built from `bones`.

    Rigid one-bone-per-part skinning, as everywhere else in this project: each
    part is wholly owned by one bone at weight 1.0. On an animal that means parts
    driven by different bones separate when those bones move apart, so every
    builder sinks a limb generously into the body it hangs off — see the note in
    each species file about how far its poses may be pushed before a seam opens.
    """
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
    title = species.title()
    mesh.name = f"{title}_Mesh"
    mesh.data.name = f"{title}_Mesh_Data"

    bpy.ops.object.armature_add(location=(0.0, 0.0, 0.0))
    armature = bpy.context.object
    armature.name = f"{title}_Rig"
    armature.data.name = f"{title}_Rig_Data"
    bpy.ops.object.mode_set(mode="EDIT")
    edit_bones = armature.data.edit_bones
    for bone in list(edit_bones):
        edit_bones.remove(bone)
    for name, head, tail, parent in bones:
        bone = edit_bones.new(name)
        bone.head = head
        bone.tail = tail
        bone.use_deform = parent is not None
        if parent is not None:
            bone.parent = edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")

    mesh.parent = armature
    modifier = mesh.modifiers.new(f"{title}_Armature", "ARMATURE")
    modifier.object = armature
    for pose_bone in armature.pose.bones:
        pose_bone.rotation_mode = "XYZ"
    return armature, mesh


# ── Animation ─────────────────────────────────────────────────────────────────


def apply_pose(
    armature: bpy.types.Object,
    frame: int,
    pose: Pose,
    offsets: dict[str, tuple[float, float, float]] | None = None,
) -> None:
    """Key EVERY animated bone's rotation and location at `frame`.

    The defaulting is the whole point. Blender leaves an unkeyed channel at
    whatever value it currently holds, so an action that keys only what it moves
    silently inherits the tail of whichever action was built before it — and on
    this batch the action built before is usually `death`. The bug that produces
    is an animal that spawns already collapsed, which is invisible in the source
    and obvious in the game.

    Scale is deliberately NOT keyed here, unlike the peatling. These are animals
    with skeletons: they bend, they do not squash. A keyed scale channel on a
    boned quadruped is an invitation to fix a bad silhouette by inflating a limb.
    """
    offsets = offsets or {}
    for pose_bone in armature.pose.bones:
        rotation = pose.get(pose_bone.name, (0.0, 0.0, 0.0))
        pose_bone.rotation_euler = tuple(math.radians(angle) for angle in rotation)
        pose_bone.keyframe_insert("rotation_euler", frame=frame)
        pose_bone.location = offsets.get(pose_bone.name, (0.0, 0.0, 0.0))
        pose_bone.keyframe_insert("location", frame=frame)


def clear_pose(armature: bpy.types.Object) -> None:
    """Return every bone to rest. Detaching the action does NOT do this."""
    armature.animation_data.action = None
    for pose_bone in armature.pose.bones:
        pose_bone.rotation_euler = (0.0, 0.0, 0.0)
        pose_bone.location = (0.0, 0.0, 0.0)
        pose_bone.scale = (1.0, 1.0, 1.0)
    bpy.context.view_layer.update()


def new_action(armature: bpy.types.Object, name: str, species: str) -> bpy.types.Action:
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    if armature.animation_data is None:
        armature.animation_data_create()
    armature.animation_data.action = action
    # Blender 4.4+ holds an action's channels in a slot; assigning the action
    # alone leaves animation_data pointing at nothing to write into.
    if hasattr(armature.animation_data, "action_slot"):
        slot = (
            action.slots.new(id_type="OBJECT", name=species.title())
            if not action.slots
            else action.slots[0]
        )
        armature.animation_data.action_slot = slot
    return action


def build_cycle(
    armature: bpy.types.Object,
    species: str,
    clip: str,
    frames: int,
    pose_at: "callable",
    samples: int = 8,
) -> bpy.types.Action:
    """Key one clip by sampling `pose_at(phase)` across 0..1.

    `pose_at` returns `(pose, offsets)` for a phase in 0..1, which keeps a gait in
    ONE function of phase rather than a list of hand-authored keyframes. That
    matters for the looping clips specifically: the last sample is the same phase
    as the first, so a cycle closes exactly instead of by eye, and a limb cannot
    drift a few degrees per loop the way hand-keyed cycles do.
    """
    action = new_action(armature, clip, species)
    for index in range(samples + 1):
        phase = index / samples
        frame = 1 + round(phase * frames)
        pose, offsets = pose_at(phase)
        apply_pose(armature, frame, pose, offsets)
    clear_pose(armature)
    return action


def build_oneshot(
    armature: bpy.types.Object,
    species: str,
    clip: str,
    keys: list[tuple[int, Pose, dict]],
) -> bpy.types.Action:
    """Key a non-looping clip from explicit (frame, pose, offsets) keys."""
    action = new_action(armature, clip, species)
    for frame, pose, offsets in keys:
        apply_pose(armature, frame, pose, offsets)
    clear_pose(armature)
    return action


# ── Export and catalog ────────────────────────────────────────────────────────


def export_species(species: str, objects: list[bpy.types.Object], active: bpy.types.Object) -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = active
    bpy.ops.export_scene.gltf(
        filepath=str(EXPORT_DIR / f"{species}.glb"),
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


def merge_catalog(rows: list[dict]) -> None:
    """Write our rows into the shared fauna catalog without touching anyone else's.

    Six sibling scripts write this file and they are not run together, so a
    whole-file rewrite would delete whichever species were built earlier. Keyed
    merge, sorted output, so the file is stable under repeated builds and a diff
    shows only the species that actually changed.
    """
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    path = ASSET_DIR / "catalog.json"
    existing: dict[str, dict] = {}
    if path.exists():
        for row in json.loads(path.read_text()).get("assets", []):
            existing[row["id"]] = row
    for row in rows:
        existing[row["id"]] = row
    payload = {"kit": "fauna", "assets": [existing[key] for key in sorted(existing)]}
    path.write_text(json.dumps(payload, indent=2) + "\n")


def catalog_row(species: str, objects: list[bpy.types.Object], note: str) -> dict:
    minimum, maximum = world_bounds(objects)
    size = maximum - minimum
    polygons = sum(len(obj.data.polygons) for obj in objects if obj.type == "MESH")
    materials = sorted(
        {m.name for obj in objects if obj.type == "MESH" for m in obj.data.materials if m}
    )
    return {
        "id": species,
        "family": "fauna",
        "export": f"exports/{species}.glb",
        "size_m": [round(value, 3) for value in size],
        "height_m": round(size.z, 3),
        # Stated in the catalog, not only in a comment, so the one property this
        # batch is most likely to get wrong is visible in the data itself.
        "player_fraction": round(size.z / PLAYER_HEIGHT_M, 3),
        "polygons": polygons,
        "materials": materials,
        "clips": EXPECTED_CLIPS,
        "note": note,
    }
