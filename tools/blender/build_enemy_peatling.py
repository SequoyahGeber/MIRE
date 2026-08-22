"""Build the Peatling — tier 1 of the enemy ladder (docs/ENEMIES.md §3).

Run with:
  Blender --background --python tools/blender/build_enemy_peatling.py

Outputs three metre-scale GLBs — one rigged and animated Peatling and its two
death fragments — plus an editable Blender source, its rows merged into the
shared enemy catalog, a group preview, and a pose contact sheet. Geometry, rig
and animation are deterministic.

It is a sibling of `build_enemy_crawler.py` (asset batch A-006) and follows that
file's conventions exactly: rigid one-bone-per-part skinning, every action keys
every animated bone, no raw float in any datablock name, `-loop` suffix on the
two clips that may loop. Read A-006's module docstring for why each of those is
the way it is. **Three things here are new and are the parts worth reading:**

Scale is a keyed channel, not just rotation and location. A crawler is plates on
a skeleton and never changes volume; a slime mould is a bag of fluid and squash
IS its whole animation language. `apply_pose` therefore keys `scale` alongside
`rotation_euler` and `location`, and defaults it to 1.0 for the same reason the
other two default to rest — an unkeyed scale channel would inherit whatever the
previously built action happened to leave behind.

The parts overlap on purpose, generously. Rigid skinning moves each part as a
solid, so two parts driven by different bones separate when those bones move
apart. On a chitin plate that is correct; on a gel body a visible seam is the
one thing that would break it. Every lobe below is sunk far enough into its
neighbour that the poses in `build_animations()` cannot pull a gap open. If you
retune a pose past roughly +/-30% scale or 0.06 m of translation, re-render the
pose sheet and look before believing it.

Nothing here writes to `mire_art.py`. The gel would genuinely like a low-
roughness palette token of its own — see docs/ENEMIES.md — but that file was
claimed by another agent for the life of this task, so the body is built from
the existing Mire ramp and the wet leading margin borrows `mire_liquid`, which
is semantically exact anyway: the margin IS corrupted liquid.

The real subject, because a generator should never have to guess (docs/ENEMIES.md
§3.1): Physarum polycephalum, the acellular slime mould. A migrating plasmodium
is fan-shaped at the leading edge — a continuous unstructured sheet of protoplasm
advancing, with the mass trailing behind it — and organises behind that fan into
a network of vein-like tubules, thick and unbranched near the base, finer toward
the margin. It moves by shuttle streaming: cytoplasm surges one way for a few
seconds, stops, and reverses. The fan is the silhouette, the veins are the
surface detail and the emissive, and the reversal is why `idle` is asymmetric.
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
    "enemy_peatling",
    "enemy_peatling_fragment_gel",
    "enemy_peatling_fragment_husk",
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

## Clip lengths in FRAMES, and the gameplay seconds each one serves.
##
## Every clip is authored SHORTER THAN OR EQUAL TO the `EnemyDef` window it plays
## under, never longer. `Enemy` starts the next state on its own timer, so a clip
## that outruns its window is cut mid-motion and the following clip starts from a
## pose the previous one never reached — a visible pop. A clip that ends early
## holds its last frame, which is invisible. 0.45 s of tell is 13.5 frames at 30
## fps, so the tell is 13.
TELL_FRAMES = 13       # 0.433 s, under peatling.tres's 0.45 s attack_tell_seconds
ATTACK_FRAMES = 10     # 0.333 s, under its 0.35 s attack_seconds
HIT_FRAMES = 9         # 0.300 s
DEATH_FRAMES = 36      # 1.200 s
IDLE_FRAMES = 72       # 2.400 s
LOCOMOTION_FRAMES = 33  # 1.100 s

## Forward is -Y in Blender, which becomes -Z after the exporter's +Y-up
## conversion — the direction Godot treats as a node's forward.
FORWARD = -1.0

## Where the fan's paler advancing margin starts, as a fraction of its radius.
RIM_FRACTION = 0.84


# ── Primitives ────────────────────────────────────────────────────────────────
#
# Local copies rather than mire_art's, for the same reason A-006 keeps its own:
# this kit is skinned, so any change to how a part is generated has to be
# re-verified against the deform, and a shared helper could move under it. No
# bevel modifier anywhere — it changes float bytes between otherwise identical
# background exports on Apple Silicon (F-057) and this family claims a
# byte-identical rebuild.


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


def vein(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    thickness: float,
    material: bpy.types.Material,
) -> bpy.types.Object:
    """One protoplasmic tubule, tapering from base to margin.

    Real Physarum veins are thick and unbranched near the base of the fan and
    finer toward the advancing edge, so every vein here runs base -> margin and
    tapers to a third of its starting thickness. Four-sided rather than six: a
    vein is 8 mm across on a 0.6 m creature and nobody will ever count its
    facets, but twelve of them will show up in the polygon budget.
    """
    head = Vector(start)
    tail = Vector(end)
    axis = tail - head
    bpy.ops.mesh.primitive_cone_add(
        vertices=4,
        radius1=thickness * 0.5,
        radius2=thickness * 0.17,
        depth=axis.length,
        location=(head + tail) * 0.5,
        rotation=axis.to_track_quat("Z", "Y").to_euler(),
    )
    obj = bpy.context.object
    obj.name = name
    return assign(obj, material)


def fan(
    name: str,
    origin: tuple[float, float, float],
    radius: float,
    half_angle_deg: float,
    segments: int,
    centre_height: float,
    mid_height: float,
    margin_height: float,
    material: bpy.types.Material,
    rim_material: bpy.types.Material | None = None,
) -> bpy.types.Object:
    """The advancing fan: a wedge sheet that thins to nothing at its margin.

    Hand-built rather than assembled from primitives because it is the entire
    silhouette. A blob made of spheres reads as a ball no matter how it is lit;
    what makes a slime mould read as a slime mould is that it has a FRONT — a
    wide, flat, thinning sheet leading a trailing mass. No primitive is that
    shape.

    Three rings: the centre point where the sheet leaves the body, a mid ring
    that carries the volume, and the margin, which sits low and thin. The
    underside is flat at z = 0, so the fan lies on the ground exactly and the
    creature has no gap under its own leading edge.

    `rim_material` paints ONLY the outermost band of quads. The first pass gave
    the whole fan the wet emissive purple and the render came back as a bright
    pink pancake with a rock sitting on it — at that area the emission drowns the
    base colour and the fan stops reading as part of the same creature. The wet
    stop belongs on the advancing margin alone, where it is a thin line that
    catches light exactly the way the real film of protoplasm does, and where it
    is small enough to be an accent instead of a slab.
    """
    ox, oy, oz = origin
    half_angle = math.radians(half_angle_deg)
    verts: list[tuple[float, float, float]] = []
    faces: list[tuple[int, ...]] = []

    def arc(fraction: float, height: float) -> list[int]:
        indices: list[int] = []
        for step in range(segments + 1):
            angle = -half_angle + (2.0 * half_angle) * step / segments
            distance = radius * fraction
            indices.append(len(verts))
            verts.append(
                (
                    ox + math.sin(angle) * distance,
                    oy + FORWARD * math.cos(angle) * distance,
                    oz + height,
                )
            )
        return indices

    # Four rings, not three. With the rim band running from the mid ring to the
    # margin it covered nearly three quarters of the fan's area, and "the outer
    # band is a paler stop" became "the fan is a different colour from the
    # creature" — the second render still read as a pink brim. `RIM_FRACTION` is
    # where the band actually starts, and it is deliberately narrow: a real
    # advancing margin is a thin hyaline edge, not a border.
    centre_top = len(verts)
    verts.append((ox, oy, oz + centre_height))
    mid_top = arc(0.50, mid_height)
    outer_top = arc(RIM_FRACTION, mid_height * 0.42 + margin_height * 0.58)
    margin = arc(1.0, margin_height)
    centre_bottom = len(verts)
    verts.append((ox, oy, oz))
    mid_bottom = arc(0.50, 0.0)
    outer_bottom = arc(RIM_FRACTION, 0.0)

    rim_faces: list[int] = []
    for step in range(segments):
        faces.append((centre_top, mid_top[step], mid_top[step + 1]))
        faces.append((mid_top[step], outer_top[step], outer_top[step + 1], mid_top[step + 1]))
        rim_faces.append(len(faces))
        faces.append((outer_top[step], margin[step], margin[step + 1], outer_top[step + 1]))
        # Underside, wound the other way so its normal points down.
        faces.append((centre_bottom, mid_bottom[step + 1], mid_bottom[step]))
        faces.append((mid_bottom[step + 1], outer_bottom[step + 1], outer_bottom[step], mid_bottom[step]))
        rim_faces.append(len(faces))
        faces.append((outer_bottom[step + 1], margin[step + 1], margin[step], outer_bottom[step]))

    mesh = bpy.data.meshes.new(f"{name}_Data")
    mesh.from_pydata(verts, [], faces)
    mesh.validate()
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    assign(obj, material)
    if rim_material is not None:
        obj.data.materials.append(rim_material)
        for index in rim_faces:
            obj.data.polygons[index].material_index = 1
    return obj


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


# ── The Peatling's skeleton ───────────────────────────────────────────────────
#
# Eight bones, no legs and no head, because it has neither. The chain runs
# TAIL -> REAR -> CORE -> FRONT -> two fan lobes, with a crest hanging off the
# core, and that order is the design: a surge starts at the front and the mass
# follows it, so front-to-back parenting would make the body drag the fan around
# instead of the fan pulling the body. Everything a pose needs to know about
# where the creature bends lives in this one table.

CORE_Z = 0.12

BONES: list[tuple[str, Vector, Vector, str | None]] = [
    ("root", Vector((0.0, 0.0, 0.0)), Vector((0.0, 0.0, 0.07)), None),
    ("mass_rear", Vector((0.0, FORWARD * -0.20, 0.09)), Vector((0.0, FORWARD * -0.06, CORE_Z)), "root"),
    ("mass_tail", Vector((0.0, FORWARD * -0.20, 0.09)), Vector((0.0, FORWARD * -0.34, 0.04)), "mass_rear"),
    ("mass_core", Vector((0.0, FORWARD * -0.06, CORE_Z)), Vector((0.0, FORWARD * 0.10, CORE_Z)), "mass_rear"),
    ("crest", Vector((0.0, FORWARD * 0.00, CORE_Z + 0.04)), Vector((0.0, FORWARD * 0.02, CORE_Z + 0.18)), "mass_core"),
    ("mass_front", Vector((0.0, FORWARD * 0.10, 0.09)), Vector((0.0, FORWARD * 0.26, 0.04)), "mass_core"),
    ("fan_l", Vector((0.0, FORWARD * 0.16, 0.05)), Vector((0.22, FORWARD * 0.30, 0.02)), "mass_front"),
    ("fan_r", Vector((0.0, FORWARD * 0.16, 0.05)), Vector((-0.22, FORWARD * 0.30, 0.02)), "mass_front"),
]

DEFORM_BONES = [name for name, _, _, parent in BONES if parent is not None]


# ── The Peatling's mesh ───────────────────────────────────────────────────────


# The core dome, described once as an ellipsoid so the vein network can be laid
# ON its surface instead of guessed at. The first pass placed veins by eye and
# they ended up INSIDE the body — a handful of white specks poking through a
# seam. A vein is the only thing on this creature that reads at fog distance, so
# where it sits is not a detail.
CORE_CENTRE = Vector((0.0, FORWARD * -0.02, 0.0))
CORE_RADII = Vector((0.245, 0.265, 0.124))
FAN_ORIGIN_Y = FORWARD * 0.08
FAN_RADIUS = 0.315
FAN_INNER_HEIGHT = 0.125
FAN_MID_HEIGHT = 0.070
FAN_MARGIN_HEIGHT = 0.014


def surface_point(azimuth_deg: float, reach: float) -> tuple[float, float, float]:
    """A point sitting just proud of the creature's skin.

    [param azimuth_deg] is measured from straight ahead, positive to the left.
    [param reach] is 0 at the top of the dome and 1 at its equator; past 1 the
    path leaves the dome and runs out across the fan, and the height comes from
    the fan's own three-ring profile instead. So one call walks a vein from the
    crown, down the flank, and out onto the advancing sheet without ever leaving
    the surface — which is what a real protoplasmic tubule does.
    """
    angle = math.radians(azimuth_deg)
    if reach <= 1.0:
        x = math.sin(angle) * CORE_RADII.x * reach
        y = CORE_CENTRE.y + FORWARD * math.cos(angle) * CORE_RADII.y * reach
        z = CORE_RADII.z * math.sqrt(max(0.0, 1.0 - reach * reach)) + CORE_RADII.z + 0.010
        return (x, y, z)
    # Out on the fan: distance from the fan's own origin, and its linear profile.
    overshoot = min(1.0, reach - 1.0)
    span = FAN_RADIUS * (0.35 + 0.65 * overshoot)
    x = math.sin(angle) * span
    y = FAN_ORIGIN_Y + FORWARD * math.cos(angle) * span
    fraction = span / FAN_RADIUS
    if fraction <= 0.50:
        height = FAN_INNER_HEIGHT + (FAN_MID_HEIGHT - FAN_INNER_HEIGHT) * (fraction / 0.50)
    elif fraction <= RIM_FRACTION:
        outer = FAN_MID_HEIGHT * 0.42 + FAN_MARGIN_HEIGHT * 0.58
        height = FAN_MID_HEIGHT + (outer - FAN_MID_HEIGHT) * ((fraction - 0.50) / (RIM_FRACTION - 0.50))
    else:
        outer = FAN_MID_HEIGHT * 0.42 + FAN_MARGIN_HEIGHT * 0.58
        height = outer + (FAN_MARGIN_HEIGHT - outer) * ((fraction - RIM_FRACTION) / (1.0 - RIM_FRACTION))
    return (x, y, height + 0.008)


def build_peatling_parts(mats: dict[str, bpy.types.Material]) -> list[tuple[bpy.types.Object, str]]:
    """Every mesh part paired with the single bone that drives it."""
    parts: list[tuple[bpy.types.Object, str]] = []

    def add(obj: bpy.types.Object, bone: str) -> None:
        parts.append((obj, bone))

    # ── The mass. Read from the side, the profile is a WAVE, not a ball: highest
    # just behind the middle, sloping down and forward until it becomes the fan,
    # and thinning to a film at the back. A plasmodium hauls its bulk along
    # behind its own advancing edge. The first pass built a sphere with a plate
    # under it and the render read as a rock sitting on a pancake — every height
    # below is chosen so that no two lobes meet at a step.
    add(
        ico(
            "Peatling_Core",
            (CORE_CENTRE.x, CORE_CENTRE.y, CORE_RADII.z),
            (CORE_RADII.x, CORE_RADII.y, CORE_RADII.z),
            mats["body"],
            subdivisions=2,
        ),
        "mass_core",
    )
    # A wide low shoulder that breaks the ellipsoid's outline where it would
    # otherwise be widest, so the silhouette has a shelf rather than a curve.
    add(ico("Peatling_Shoulder", (0.0, FORWARD * -0.06, 0.062), (0.268, 0.240, 0.062), mats["body"], subdivisions=1), "mass_core")
    add(ico("Peatling_Rear", (0.0, FORWARD * -0.20, 0.086), (0.192, 0.172, 0.086), mats["body"], subdivisions=1), "mass_rear")
    add(ico("Peatling_Rear_Skirt", (0.0, FORWARD * -0.17, 0.046), (0.215, 0.190, 0.046), mats["body_dark"], subdivisions=1), "mass_rear")
    # The trailing smear, in two flattened lobes rather than one cone. A slime
    # mould does not leave a tapered tail behind it, it leaves a THINNING FILM it
    # has not finished pulling in — and a cone laid on its side also puts its own
    # radius through the ground, which the rest-pose contact assert catches.
    add(ico("Peatling_Tail", (0.0, FORWARD * -0.31, 0.040), (0.140, 0.150, 0.040), mats["body_dark"], subdivisions=1), "mass_tail")
    add(ico("Peatling_Tail_Tip", (0.0, FORWARD * -0.40, 0.020), (0.078, 0.090, 0.020), mats["body_dark"], subdivisions=1), "mass_tail")

    # The crest. Nearly buried at rest — a slight rise on the dome's back — and
    # the tell is the one clip that hauls it up into a column. That is the whole
    # readability plan for a knee-high enemy: the telegraph is a SILHOUETTE
    # change, not a limb moving inside an outline that stays the same.
    add(ico("Peatling_Crest", (0.0, FORWARD * -0.05, 0.196), (0.132, 0.124, 0.062), mats["body_light"], subdivisions=1), "crest")

    # ── The fan: the silhouette, and the reason this reads as a slime mould and
    # not as a boulder. Its inner edge is TALL (0.125 m) so it grows out of the
    # dome's flank instead of butting against it, and only its outermost band
    # carries the wet emissive stop.
    add(
        fan(
            "Peatling_Fan",
            (0.0, FAN_ORIGIN_Y, 0.0),
            FAN_RADIUS,
            76.0,
            9,
            FAN_INNER_HEIGHT,
            FAN_MID_HEIGHT,
            FAN_MARGIN_HEIGHT,
            mats["body"],
            mats["margin"],
        ),
        "mass_front",
    )
    add(ico("Peatling_Front", (0.0, FORWARD * 0.13, 0.075), (0.185, 0.150, 0.075), mats["body"], subdivisions=1), "mass_front")
    add(ico("Peatling_Lobe_L", (0.200, FORWARD * 0.19, 0.038), (0.100, 0.115, 0.038), mats["margin"], subdivisions=1), "fan_l")
    add(ico("Peatling_Lobe_R", (-0.200, FORWARD * 0.19, 0.038), (0.100, 0.115, 0.038), mats["margin"], subdivisions=1), "fan_r")

    # ── The vein network, laid on the skin by `surface_point()`. Five trunks
    # leave the crown, run down the flank and out across the fan, thick at the
    # base and finer at the margin, exactly as a real plasmodium's tubules do.
    # These are the only emissive on the creature, so they are also the only
    # thing that reads at fog distance — and because they all point at the fan, a
    # player who has learnt this enemy can tell which way it faces from the
    # glow alone, which matters at knee height in the dark.
    for index, azimuth in enumerate((-62.0, -31.0, 0.0, 31.0, 62.0)):
        crown = surface_point(azimuth, 0.30)
        flank = surface_point(azimuth, 0.86)
        shelf = surface_point(azimuth, 1.30)
        margin_point = surface_point(azimuth, 1.62)
        add(vein(f"Peatling_Vein_{index}_Trunk", crown, flank, 0.026, mats["vein"]), "mass_core")
        add(vein(f"Peatling_Vein_{index}_Mid", flank, shelf, 0.019, mats["vein"]), "mass_front")
        add(vein(f"Peatling_Vein_{index}_Tip", shelf, margin_point, 0.013, mats["vein"]), "mass_front")

    # Two trunks running the other way, into the trailing mass. Without them the
    # network reads as a lit face and the back half looks unfinished from behind
    # — which is exactly the angle a player fighting several of these has.
    for index, azimuth in enumerate((132.0, -132.0)):
        crown = surface_point(azimuth, 0.34)
        flank = surface_point(azimuth, 0.92)
        add(vein(f"Peatling_Vein_Rear_{index}", crown, flank, 0.023, mats["vein"]), "mass_rear")

    # ── Inclusions: what it has eaten and not finished. They sit PROUD of the
    # skin, not suspended in it — the body is opaque and flat-shaded, so a pebble
    # fully inside it is a pebble nobody will ever see. The bone shard does the
    # real work: it is the sentence "this is not a harmless puddle", and it sits
    # on the crown where it breaks the silhouette.
    pebble_seat = surface_point(58.0, 0.55)
    add(ico("Peatling_Inclusion_Pebble", (pebble_seat[0], pebble_seat[1], pebble_seat[2] + 0.016), (0.056, 0.050, 0.046), mats["stone"], (0.0, math.radians(18), math.radians(24))), "mass_core")
    bone_seat = surface_point(-24.0, 0.36)
    add(ico("Peatling_Inclusion_Bone", (bone_seat[0] - 0.010, bone_seat[1], bone_seat[2] + 0.030), (0.028, 0.088, 0.026), mats["bone"], (math.radians(FORWARD * 26), math.radians(-14), math.radians(-18)), subdivisions=1), "mass_core")
    twig_seat = surface_point(150.0, 0.70)
    add(cone("Peatling_Inclusion_Twig", 0.016, 0.005, 0.175, (twig_seat[0], twig_seat[1], twig_seat[2] + 0.030), mats["wood"], 4, (math.radians(58), 0.0, math.radians(34))), "mass_rear")

    return parts


def build_peatling_rig(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Object, bpy.types.Object]:
    """Build the Peatling mesh, bind it rigidly to its armature, return both."""
    parts = build_peatling_parts(mats)

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
    mesh.name = "Peatling_Mesh"
    mesh.data.name = "Peatling_Mesh_Data"

    bpy.ops.object.armature_add(location=(0.0, 0.0, 0.0))
    armature = bpy.context.object
    armature.name = "Peatling_Rig"
    armature.data.name = "Peatling_Rig_Data"
    bpy.ops.object.mode_set(mode="EDIT")
    edit_bones = armature.data.edit_bones
    for bone in list(edit_bones):
        edit_bones.remove(bone)
    for name, head, tail, parent in BONES:
        bone = edit_bones.new(name)
        bone.head = head
        bone.tail = tail
        bone.use_deform = parent is not None
        if parent is not None:
            bone.parent = edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")

    mesh.parent = armature
    modifier = mesh.modifiers.new("Peatling_Armature", "ARMATURE")
    modifier.object = armature

    for pose_bone in armature.pose.bones:
        pose_bone.rotation_mode = "XYZ"
    return armature, mesh


# ── Animation ─────────────────────────────────────────────────────────────────
#
# A pose is bone -> (rx, ry, rz) in DEGREES. Two optional side channels, keyed by
# bone name in their own dicts: `offsets` for translation in metres and `scales`
# for squash. Degrees and metres because every one of these numbers was chosen by
# eye and will be re-tuned by eye.

Pose = dict[str, tuple[float, float, float]]


def apply_pose(
    armature: bpy.types.Object,
    frame: int,
    pose: Pose,
    offsets: dict[str, tuple[float, float, float]] | None = None,
    scales: dict[str, tuple[float, float, float]] | None = None,
) -> None:
    """Key EVERY animated bone's rotation, location AND scale at `frame`.

    The defaulting is the point, and scale is the channel this rig added. Blender
    leaves an unkeyed channel at whatever value it currently holds, so an action
    that keys only what it moves silently inherits the tail of whichever action
    was built before it — and on this rig that tail is the death clip's collapsed,
    flattened scale. The bug would be a Peatling that spawns already dead.
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
    """Return every bone to rest. Detaching the action does NOT do this."""
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
        slot = action.slots.new(id_type="OBJECT", name="Peatling") if not action.slots else action.slots[0]
        armature.animation_data.action_slot = slot
    return action


def surge(amount: float) -> tuple[Pose, dict, dict]:
    """One instant of shuttle streaming, `amount` in -1..1.

    Positive is fluid driven FORWARD into the fan: the front swells and flattens
    as it takes the volume, the core stretches after it, and the rear empties and
    lifts. Negative is the reversal — mass piles back into the rear and the fan
    goes slack and thin. This is one function rather than a set of hand-authored
    keys because the reversal has to be the exact inverse of the surge or the
    creature appears to gain and lose volume, and eyeballing conservation across
    six bones twice is how that goes wrong.
    """
    forward = max(0.0, amount)
    backward = max(0.0, -amount)
    pose: Pose = {
        "mass_front": (-6.0 * forward + 5.0 * backward, 0.0, 0.0),
        "mass_core": (-2.5 * forward + 2.0 * backward, 0.0, 0.0),
        "mass_rear": (3.0 * forward - 2.0 * backward, 0.0, 0.0),
        "mass_tail": (6.0 * forward - 5.0 * backward, 0.0, 0.0),
        "crest": (-4.0 * forward + 3.0 * backward, 0.0, 0.0),
        "fan_l": (0.0, 0.0, -5.0 * forward + 4.0 * backward),
        "fan_r": (0.0, 0.0, 5.0 * forward - 4.0 * backward),
    }
    offsets = {
        "mass_front": (0.0, FORWARD * 0.044 * forward, -0.009 * forward),
        "mass_core": (0.0, FORWARD * 0.020 * forward - FORWARD * 0.022 * backward, 0.013 * backward),
        "mass_rear": (0.0, -FORWARD * 0.016 * forward + FORWARD * 0.010 * backward, -0.006 * forward),
    }
    # Amplitudes are deliberately large. The first pass ran them at roughly 60%
    # of these and the pose sheet came back with four tiles that were hard to
    # tell apart — on a creature with no limbs, volume IS the motion, and a
    # slime whose idle you cannot see across a clearing reads as a rock.
    scales = {
        "mass_front": (1.0 + 0.24 * forward - 0.15 * backward, 1.0 + 0.19 * forward - 0.21 * backward, 1.0 - 0.21 * forward + 0.19 * backward),
        "mass_core": (1.0 - 0.07 * forward + 0.09 * backward, 1.0 + 0.09 * forward - 0.06 * backward, 1.0 - 0.09 * forward + 0.13 * backward),
        "mass_rear": (1.0 - 0.14 * forward + 0.18 * backward, 1.0 - 0.11 * forward + 0.16 * backward, 1.0 - 0.10 * forward + 0.21 * backward),
        "fan_l": (1.0 + 0.16 * forward - 0.14 * backward, 1.0 + 0.13 * forward - 0.12 * backward, 1.0 - 0.16 * forward),
        "fan_r": (1.0 + 0.16 * forward - 0.14 * backward, 1.0 + 0.13 * forward - 0.12 * backward, 1.0 - 0.16 * forward),
    }
    return pose, offsets, scales


def merge(*poses: Pose) -> Pose:
    merged: Pose = {}
    for pose in poses:
        merged.update(pose)
    return merged


def merge_channels(*channels: dict) -> dict:
    merged: dict = {}
    for channel in channels:
        merged.update(channel)
    return merged


def column(amount: float) -> tuple[Pose, dict, dict]:
    """Gathering into a raised column, `amount` 0..1 — the tell's shape.

    The fan is not thrown forward here; it is HAULED IN. Everything the creature
    has goes up and back, the crest rises out of the crown, and the veins that
    were pointing at the player now point at the sky. What the player reads is
    the outline getting tall, and tall is the one thing this silhouette never
    otherwise is.
    """
    pose: Pose = {
        "mass_front": (26.0 * amount, 0.0, 0.0),
        "mass_core": (-12.0 * amount, 0.0, 0.0),
        "mass_rear": (8.0 * amount, 0.0, 0.0),
        "mass_tail": (14.0 * amount, 0.0, 0.0),
        "crest": (-14.0 * amount, 0.0, 0.0),
        "fan_l": (0.0, 0.0, 22.0 * amount),
        "fan_r": (0.0, 0.0, -22.0 * amount),
    }
    offsets = {
        "mass_core": (0.0, -FORWARD * 0.030 * amount, 0.052 * amount),
        "mass_front": (0.0, -FORWARD * 0.055 * amount, 0.030 * amount),
        "crest": (0.0, 0.0, 0.045 * amount),
    }
    scales = {
        "mass_core": (1.0 - 0.20 * amount, 1.0 - 0.22 * amount, 1.0 + 0.62 * amount),
        "mass_front": (1.0 - 0.26 * amount, 1.0 - 0.30 * amount, 1.0 + 0.34 * amount),
        "mass_rear": (1.0 - 0.10 * amount, 1.0 - 0.12 * amount, 1.0 + 0.26 * amount),
        "crest": (1.0 + 0.18 * amount, 1.0 + 0.18 * amount, 1.0 + 0.85 * amount),
        "fan_l": (1.0 - 0.24 * amount, 1.0 - 0.24 * amount, 1.0 + 0.20 * amount),
        "fan_r": (1.0 - 0.24 * amount, 1.0 - 0.24 * amount, 1.0 + 0.20 * amount),
    }
    return pose, offsets, scales


def splat(amount: float) -> tuple[Pose, dict, dict]:
    """The opposite of `column`: everything thrown forward and flattened wide."""
    pose: Pose = {
        "mass_front": (-22.0 * amount, 0.0, 0.0),
        "mass_core": (-9.0 * amount, 0.0, 0.0),
        "mass_rear": (10.0 * amount, 0.0, 0.0),
        "mass_tail": (20.0 * amount, 0.0, 0.0),
        "crest": (-20.0 * amount, 0.0, 0.0),
        "fan_l": (0.0, 0.0, -16.0 * amount),
        "fan_r": (0.0, 0.0, 16.0 * amount),
    }
    offsets = {
        "mass_core": (0.0, FORWARD * 0.060 * amount, -0.028 * amount),
        "mass_front": (0.0, FORWARD * 0.105 * amount, -0.022 * amount),
        "crest": (0.0, FORWARD * 0.020 * amount, -0.030 * amount),
    }
    scales = {
        "mass_core": (1.0 + 0.22 * amount, 1.0 + 0.16 * amount, 1.0 - 0.34 * amount),
        "mass_front": (1.0 + 0.40 * amount, 1.0 + 0.30 * amount, 1.0 - 0.44 * amount),
        "mass_rear": (1.0 + 0.10 * amount, 1.0 + 0.08 * amount, 1.0 - 0.22 * amount),
        "crest": (1.0 + 0.20 * amount, 1.0 + 0.20 * amount, 1.0 - 0.55 * amount),
        "fan_l": (1.0 + 0.26 * amount, 1.0 + 0.22 * amount, 1.0 - 0.30 * amount),
        "fan_r": (1.0 + 0.26 * amount, 1.0 + 0.22 * amount, 1.0 - 0.30 * amount),
    }
    return pose, offsets, scales


def keyed(
    armature: bpy.types.Object,
    frame: int,
    *layers: tuple[Pose, dict, dict],
    extra_pose: Pose | None = None,
    extra_offsets: dict | None = None,
    extra_scales: dict | None = None,
) -> None:
    """Key one frame from any number of (pose, offsets, scales) layers.

    Later layers win outright rather than adding — every shape function above
    writes the same bones, so adding them would double-count the mass and the
    creature would inflate. Layering is for combining a shape with a hand tweak,
    not for blending two shapes; blend by passing a smaller `amount`.
    """
    pose: Pose = {}
    offsets: dict = {}
    scales: dict = {}
    for layer_pose, layer_offsets, layer_scales in layers:
        pose.update(layer_pose)
        offsets.update(layer_offsets)
        scales.update(layer_scales)
    if extra_pose:
        pose.update(extra_pose)
    if extra_offsets:
        offsets.update(extra_offsets)
    if extra_scales:
        scales.update(extra_scales)
    apply_pose(armature, frame, pose, offsets, scales)


def build_animations(armature: bpy.types.Object) -> list[tuple[str, int, int]]:
    """Author every clip. Returns (name, first frame, last frame) per clip."""
    clips: list[tuple[str, int, int]] = []

    # ── idle-loop — 2.4 s of shuttle streaming.
    #
    # Deliberately ASYMMETRIC. Real Physarum streams one way for a few seconds,
    # stops, and reverses; the two directions are not the same length and there
    # is a visible pause at the turn. A symmetric in-out throb would read as
    # breathing, and breathing is a lung, which this creature does not have. The
    # forward surge takes ~1.0 s, holds briefly, and the reversal takes the rest.
    new_action(armature, "idle" + LOOP_SUFFIX)
    for frame, amount in (
        (1, 0.0),
        (10, 0.55),
        (19, 0.95),
        (27, 0.80),      # the stall at the top of the surge
        (40, 0.10),
        (52, -0.70),
        (60, -0.95),     # the reversal, briefer and sharper than the surge
        (72, -0.30),
        (73, 0.0),       # repeats frame 1 exactly, so the loop has no seam
    ):
        keyed(armature, frame, surge(amount))
    clips.append(("idle" + LOOP_SUFFIX, 1, 1 + IDLE_FRAMES))

    # ── locomotion-loop — 1.1 s. One surge cycle IS one step.
    #
    # No bob, no feet, no gait phase: the entire body is the locomotion. The fan
    # extends and thins as it grips ground ahead, the mass flows into it, then
    # the tail releases and catches up. The forward half is slower than the
    # recovery — a plasmodium advances by pouring, not by stepping — so the curve
    # below is not a sine.
    new_action(armature, "locomotion" + LOOP_SUFFIX)
    for step in range(LOCOMOTION_FRAMES + 1):
        phase = step / LOCOMOTION_FRAMES
        # A slow push out to +1 over the first 62% of the cycle, then a quicker
        # gather back through -0.55. Piecewise on purpose; see above.
        if phase < 0.62:
            amount = math.sin(phase / 0.62 * math.pi * 0.5) ** 0.8
        else:
            amount = math.cos((phase - 0.62) / 0.38 * math.pi * 0.5) * 1.55 - 0.55
        # A shallow side-to-side wander, so a group of them does not march.
        yaw = math.sin(phase * math.tau) * 3.2
        keyed(
            armature,
            1 + step,
            surge(amount),
            extra_pose={"mass_core": (surge(amount)[0]["mass_core"][0], 0.0, yaw)},
        )
    clips.append(("locomotion" + LOOP_SUFFIX, 1, 1 + LOCOMOTION_FRAMES))

    # ── attack_tell — 0.433 s. It gathers.
    #
    # Holds its extreme for the back third rather than easing straight into the
    # strike: this clip exists to be READ, and a shape that is still moving when
    # the strike begins never registers as a warning.
    new_action(armature, "attack_tell")
    keyed(armature, 1, surge(0.15))
    keyed(armature, 5, column(0.62))
    keyed(armature, 9, column(1.0))
    keyed(armature, 1 + TELL_FRAMES, column(1.0))
    clips.append(("attack_tell", 1, 1 + TELL_FRAMES))

    # ── attack — 0.333 s. The column throws itself flat.
    #
    # Frame 1 is the tell's last frame exactly, so the two chain without a pop.
    # The strike lands by frame 4 and the rest is the body pulling itself back
    # into a creature — a slime has no skeleton to snap back with, so the
    # recovery is slack and slow rather than springy.
    new_action(armature, "attack")
    keyed(armature, 1, column(1.0))
    keyed(armature, 4, splat(1.0))
    keyed(armature, 7, splat(0.45))
    keyed(armature, 1 + ATTACK_FRAMES, surge(0.15))
    clips.append(("attack", 1, 1 + ATTACK_FRAMES))

    # ── hit — 0.3 s. A ripple, not a flinch.
    #
    # It has no skeleton to recoil with, so the impact dents the surface and the
    # wave crosses the body front-to-back instead of the whole thing jerking
    # backward. Readable because the veins move: the network compresses on the
    # struck side and stretches on the other.
    new_action(armature, "hit")
    keyed(armature, 1, surge(0.15))
    keyed(
        armature,
        3,
        surge(-0.35),
        extra_pose={"mass_core": (7.0, 9.0, -6.0), "crest": (11.0, 12.0, 0.0)},
        extra_offsets={"mass_core": (0.0, -FORWARD * 0.022, -0.030)},
        extra_scales={"mass_core": (1.18, 0.86, 0.74), "crest": (1.12, 0.90, 0.72)},
    )
    keyed(
        armature,
        6,
        surge(0.20),
        extra_pose={"mass_core": (-3.0, -5.0, 3.0), "mass_rear": (8.0, 0.0, 0.0)},
        extra_scales={"mass_core": (0.94, 1.06, 1.08), "mass_rear": (1.10, 1.06, 0.90)},
    )
    keyed(armature, 1 + HIT_FRAMES, surge(0.15))
    clips.append(("hit", 1, 1 + HIT_FRAMES))

    # ── death — 1.2 s. Surface tension fails.
    #
    # Not a collapse onto its side, which is what a thing with a skeleton does.
    # It swells once — the last pump — then loses its hold and SPREADS, going
    # wider and flatter until it is a stain with a lump in it. The last frame is
    # flat and still, because the corpse, the fragments and the corruption the
    # host stamps into the Mire grid all inherit this pose.
    new_action(armature, "death")
    flat = {
        "mass_core": (1.44, 1.38, 0.22),
        "mass_front": (1.48, 1.40, 0.18),
        "mass_rear": (1.34, 1.30, 0.22),
        "crest": (1.22, 1.22, 0.12),
        "fan_l": (1.24, 1.20, 0.24),
        "fan_r": (1.24, 1.20, 0.24),
    }
    keyed(armature, 1, surge(0.15))
    keyed(armature, 6, column(0.55), extra_scales={"crest": (1.35, 1.35, 1.30)})
    keyed(
        armature,
        16,
        splat(0.85),
        extra_scales={key: tuple(1.0 + (value - 1.0) * 0.55 for value in scale) for key, scale in flat.items()},
    )
    keyed(
        armature,
        26,
        splat(0.55),
        extra_pose={"crest": (-26.0, 0.0, 0.0), "mass_tail": (24.0, 0.0, 0.0)},
        extra_scales={key: tuple(1.0 + (value - 1.0) * 0.88 for value in scale) for key, scale in flat.items()},
    )
    keyed(
        armature,
        1 + DEATH_FRAMES,
        splat(0.42),
        extra_pose={"crest": (-30.0, 0.0, 0.0), "mass_tail": (26.0, 0.0, 0.0)},
        extra_offsets={"mass_core": (0.0, 0.0, -0.055), "mass_front": (0.0, FORWARD * 0.030, -0.030)},
        extra_scales=flat,
    )
    clips.append(("death", 1, 1 + DEATH_FRAMES))

    if [name for name, _, _ in clips] != EXPECTED_ANIMATIONS:
        raise RuntimeError("Peatling animation specification and expected clip list diverged")
    return clips


# ── The death fragments ───────────────────────────────────────────────────────


def build_fragment_gel(mats: dict[str, bpy.types.Material]) -> None:
    """A thrown gobbet of gel with a dying vein still lit inside it."""
    ico("Fragment_Gel_Body", (0.0, 0.0, 0.040), (0.105, 0.085, 0.045), mats["body"], subdivisions=1)
    ico("Fragment_Gel_Lobe", (0.075, 0.045, 0.026), (0.055, 0.048, 0.028), mats["margin"], subdivisions=1)
    vein("Fragment_Gel_Vein", (-0.075, -0.028, 0.038), (0.060, 0.038, 0.052), 0.024, mats["vein"])


def build_fragment_husk(mats: dict[str, bpy.types.Material]) -> None:
    """The dried skin the gel leaves behind, and the pebble it never digested.

    The pebble is the point. It is the same inclusion that was visible in the
    living creature, now lying on the ground next to the film it came out of —
    so the debris answers the question the model asked.
    """
    box("Fragment_Husk_Film", (0.0, 0.0, 0.011), (0.185, 0.150, 0.020), mats["body_dark"], (math.radians(4), math.radians(-7), math.radians(21)))
    box("Fragment_Husk_Curl", (-0.080, 0.055, 0.030), (0.085, 0.070, 0.016), mats["body_dark"], (math.radians(34), math.radians(12), math.radians(-14)))
    ico("Fragment_Husk_Pebble", (0.082, -0.048, 0.030), (0.048, 0.042, 0.038), mats["stone"], (0.0, math.radians(22), math.radians(-31)))


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
    """Export the rigged Peatling.

    No ground-normalisation, unlike the static path: the rig is authored sitting
    on z = 0 already, and shifting a skinned mesh after binding would move it out
    from under its own armature. So this ASSERTS the contact instead of
    correcting it. The tolerance is tighter than A-006's because this creature
    has no legs — it is a puddle, and a puddle floating one millimetre off the
    ground is visible from a metre away in a way a crawler's claw is not.
    """
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    move_to_collection([armature, mesh], collection)

    clear_pose(armature)
    minimum, maximum = world_bounds([mesh])
    if abs(minimum.z) > 0.0005:
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

    `assets/enemies/catalog.json` is the whole family's inventory and A-006's
    generator also writes it. That generator rewrites the file wholesale, which
    is correct for the assets it owns and would silently delete ours. So this one
    reads what is there, REPLACES the rows whose names are in `EXPECTED_NAMES`,
    keeps every other row exactly as it found it, and appends anything new at the
    end. Either generator can now be re-run alone without erasing the other's
    work, and re-running both in either order converges on the same file.
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
    fill.data.energy = 1200
    fill.data.color = (0.43, 0.28, 0.68)
    fill.data.shape = "DISK"
    fill.data.size = 7.0
    look_at(fill, (0.0, 0.0, 0.2))
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

    On a rig whose whole animation language is squash, this is not a nicety. A
    still of the rest pose proves the mesh is bound; only a sheet of extremes
    shows whether a 60% scale on one bone has torn a hole between two lobes.
    """
    for record in records:
        set_visible(record, record["name"] == "enemy_peatling")
    original_resolution = (scene.render.resolution_x, scene.render.resolution_y)
    original_camera = (camera.location.copy(), camera.data.ortho_scale)
    scene.render.resolution_x = cell
    scene.render.resolution_y = cell
    focus = armature.location.copy()
    camera.data.ortho_scale = 1.52
    # Lower than A-006's sheet camera. This creature is 0.34 m tall and the tell
    # is a vertical change, so the sheet is shot from nearer eye level than the
    # crawler's three-quarter-from-above — from directly above, a column and a
    # puddle look identical, which would hide the exact thing being checked.
    camera.location = focus + Vector((1.15, -1.55, 0.52))
    look_at(camera, (focus.x, focus.y, focus.z + 0.16))

    rows = math.ceil(len(poses) / columns)
    sheet = np.zeros((rows * cell, columns * cell, 4), dtype=np.float32)
    sheet[:, :, 3] = 1.0
    for index, (clip, _label, frame) in enumerate(poses):
        armature.animation_data.action = bpy.data.actions[clip]
        if hasattr(armature.animation_data, "action_slot"):
            armature.animation_data.action_slot = bpy.data.actions[clip].slots[0]
        scene.frame_set(frame)
        tile_path = PREVIEW_DIR / f"peatling_pose_tile_{index}.png"
        scene.render.filepath = str(tile_path)
        bpy.ops.render.render(write_still=True)
        image = bpy.data.images.load(str(tile_path))
        pixels = np.array(image.pixels[:], dtype=np.float32).reshape(cell, cell, 4)
        bpy.data.images.remove(image)
        tile_path.unlink()
        row = index // columns
        column_index = index % columns
        # Blender's pixel buffer is bottom-up; the sheet is laid out top-down.
        top = (rows - 1 - row) * cell
        sheet[top:top + cell, column_index * cell:(column_index + 1) * cell] = pixels

    output = bpy.data.images.new("Peatling_Pose_Sheet", width=columns * cell, height=rows * cell, alpha=True)
    output.pixels = sheet.reshape(-1)
    output.filepath_raw = str(PREVIEW_DIR / "peatling_pose_sheet.png")
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
    # whatever fps the scene holds, and Blender's default is 24 — every clip
    # would ship 25% slow with every frame number still correct (A-006's note).
    bpy.context.scene.render.fps = FPS
    reset_materials()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.actions, bpy.data.armatures, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)

    mats = {
        # The Mire ramp, dark to light, plus the one wet stop. `mire_liquid` is
        # the margin because the margin genuinely IS corrupted liquid — a thin
        # advancing film of it — and it is the only low-roughness purple in the
        # palette, so the leading edge catches light the way wet gel does while
        # the body stays matte and flat-shaded like everything else in the world.
        "body_dark": mat("mire_black"),
        "body": mat("mire"),
        "body_light": mat("mire_flesh"),
        # The advancing margin. `mire_flesh` and NOT `mire_liquid`: the first pass
        # gave the whole fan the wet emissive purple and it rendered as a bright
        # pink slab with a rock on it — at that area an emission of 1.8 drowns
        # the base colour and the fan stops belonging to the same creature. Pale
        # matte flesh on the outer band alone reads as a thinning film, which is
        # what it is.
        "margin": mat("mire_flesh"),
        "vein": mat("mire_glow"),
        "stone": mat("stone"),
        "bone": mat("bone"),
        "wood": mat("wood_dead"),
        "ground": mat("preview_ground"),
        "scale": mat("reference_blue"),
    }

    records: list[dict] = []

    armature, mesh = build_peatling_rig(mats)
    clips = build_animations(armature)
    records.append(create_rigged_asset("enemy_peatling", "enemy", armature, mesh, clips, (-0.42, 0.0, 0.0)))

    statics: list[tuple[str, str, Callable[[], None], tuple[float, float, float]]] = [
        ("enemy_peatling_fragment_gel", "debris", lambda: build_fragment_gel(mats), (0.42, 0.16, 0.0)),
        ("enemy_peatling_fragment_husk", "debris", lambda: build_fragment_husk(mats), (0.80, -0.16, 0.0)),
    ]
    for name, family, builder, location in statics:
        records.append(create_static_asset(name, family, builder, location))

    if [record["name"] for record in records] != EXPECTED_NAMES:
        raise RuntimeError("Peatling specification and expected export list diverged")

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
        box("Scale_Post", (-1.10, -0.26, 0.5), (0.055, 0.055, 1.0), mats["scale"]),
        box("Scale_Tick_20", (-1.02, -0.26, 0.20), (0.18, 0.06, 0.020), mats["scale"]),
        box("Scale_Tick_40", (-1.02, -0.26, 0.40), (0.18, 0.06, 0.020), mats["scale"]),
        box("Scale_Tick_60", (-1.02, -0.26, 0.60), (0.18, 0.06, 0.020), mats["scale"]),
        box("Scale_Tick_80", (-1.02, -0.26, 0.80), (0.18, 0.06, 0.020), mats["scale"]),
        box("Scale_Tick_100", (-1.02, -0.26, 1.00), (0.24, 0.06, 0.026), mats["scale"]),
        box("Scale_20cm_Cube", (-0.86, -0.30, 0.10), (0.20, 0.20, 0.20), mats["scale"]),
    ]
    move_to_collection(scale_parts, preview_collection)
    camera.data.ortho_scale = 2.05
    camera.location = (2.2, -3.4, 1.28)
    look_at(camera, (-0.16, -0.02, 0.13))
    scene.render.filepath = str(PREVIEW_DIR / "peatling_preview.png")
    bpy.ops.render.render(write_still=True)

    # The ruler stands beside the GROUP shot and would only clip a tight pose
    # tile, so it goes; the 20 cm cube stays and moves in next to the creature,
    # keeping a scale reference in every tile of the contact sheet.
    reference_cube = scale_parts.pop()
    for scale_part in scale_parts:
        bpy.data.objects.remove(scale_part, do_unlink=True)
    reference_cube.location = (-0.42 + 0.46, 0.28, 0.10)

    # Two frames of the surge, both ends of the shuttle-streaming idle, the tell
    # at its readable extreme, the splat, the ripple and the final spread — the
    # poses a reviewer actually has to see to believe the rig.
    render_pose_sheet(
        scene,
        camera,
        armature,
        records,
        [
            ("idle" + LOOP_SUFFIX, "idle surge", 19),
            ("idle" + LOOP_SUFFIX, "idle reversal", 60),
            ("locomotion" + LOOP_SUFFIX, "flow out", 14),
            ("locomotion" + LOOP_SUFFIX, "gather", 30),
            ("attack_tell", "tell hold", 11),
            ("attack", "splat", 4),
            ("hit", "ripple", 3),
            ("death", "spread", 1 + DEATH_FRAMES),
        ],
        columns=4,
        cell=420,
    )

    bpy.data.objects.remove(reference_cube, do_unlink=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "enemy_peatling.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(
        f"Built {len(records)} Peatling assets ({total_polygons} polygons total), "
        f"{len(clips)} clips on {len(armature.data.bones)} bones"
    )


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
