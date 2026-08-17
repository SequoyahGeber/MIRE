"""Build MIRE's basic Ward set (asset batch A-007).

Run with:
  Blender --background --python tools/blender/build_ward_set.py

Outputs eight metre-scale GLBs, an editable Blender source, a catalog, and two
preview renders. The four Ward condition states use identical foundation calls
and are horizontally anchored to that shared geometry, so runtime state swaps
cannot shift the structure away from collision authored against the foundation.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Callable

import bpy
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "wards"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

EXPECTED_NAMES = [
    "ward_foundation",
    "ward_healthy",
    "ward_damaged",
    "ward_critical",
    "ward_destroyed",
    "ward_repair_scaffolding",
    "ward_boundary_post",
    "ward_activation_crystal",
]
STATE_NAMES = ("ward_healthy", "ward_damaged", "ward_critical", "ward_destroyed")


def material(
    name: str,
    color: tuple[float, float, float, float],
    roughness: float = 0.9,
    metallic: float = 0.0,
    emission: tuple[float, float, float, float] | None = None,
    emission_strength: float = 0.0,
) -> bpy.types.Material:
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = color
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = roughness
    shader.inputs["Metallic"].default_value = metallic
    if emission is not None:
        shader.inputs["Emission Color"].default_value = emission
        shader.inputs["Emission Strength"].default_value = emission_strength
    return mat


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
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = (dimensions[0] * 0.5, dimensions[1] * 0.5, dimensions[2] * 0.5)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    # Keep boxes modifier-free. Blender's bevel modifier changed four float
    # bytes between otherwise identical background exports on Apple Silicon;
    # hard edges also fit this intentionally chunky low-poly family better.
    return assign(obj, mat)


def cone(
    name: str,
    radius_bottom: float,
    radius_top: float,
    depth: float,
    location: tuple[float, float, float],
    mat: bpy.types.Material,
    vertices: int = 8,
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


def beam_between(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    width: float,
    mat: bpy.types.Material,
    depth: float | None = None,
    bevel: float = 0.0,
) -> bpy.types.Object:
    start_v = Vector(start)
    end_v = Vector(end)
    direction = end_v - start_v
    obj = box(
        name,
        tuple((start_v + end_v) * 0.5),
        (width, depth if depth is not None else width, direction.length),
        mat,
        bevel=bevel,
    )
    obj.rotation_euler = direction.to_track_quat("Z", "Y").to_euler()
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
    if not corners:
        raise RuntimeError("Cannot measure an asset with no mesh geometry")
    minimum = Vector((min(v.x for v in corners), min(v.y for v in corners), min(v.z for v in corners)))
    maximum = Vector((max(v.x for v in corners), max(v.y for v in corners), max(v.z for v in corners)))
    return minimum, maximum


# ── Shared Ward foundation and state geometry ────────────────────────────────


def build_foundation(mats: dict[str, bpy.types.Material]) -> None:
    """The immutable 2.4 m footprint shared by every gameplay condition state."""
    cone("Ward_Foundation_Base", 1.20, 1.10, 0.18, (0.0, 0.0, 0.09), mats["stone_dark"], 12)
    cone("Ward_Foundation_Upper", 1.02, 0.93, 0.13, (0.0, 0.0, 0.245), mats["stone"], 12)
    cone("Ward_Foundation_Inlay", 0.80, 0.76, 0.035, (0.0, 0.0, 0.328), mats["bronze"], 12)
    cone("Ward_Foundation_Core", 0.64, 0.62, 0.045, (0.0, 0.0, 0.368), mats["slate"], 12)
    for index in range(4):
        angle = index * math.pi * 0.5
        x = math.cos(angle) * 1.03
        y = math.sin(angle) * 1.03
        box(
            f"Ward_Foundation_Buttress_{index + 1}",
            (x, y, 0.16),
            (0.42, 0.34, 0.24),
            mats["stone"],
            (0.0, 0.0, angle),
            0.035,
        )
    for index in range(8):
        angle = index * math.pi * 0.25
        box(
            f"Ward_Foundation_Rune_{index + 1}",
            (math.cos(angle) * 0.70, math.sin(angle) * 0.70, 0.397),
            (0.22, 0.065, 0.025),
            mats["ward_glow"],
            (0.0, 0.0, angle),
        )


def build_support(
    index: int,
    mats: dict[str, bpy.types.Material],
    broken: bool = False,
    fallen: bool = False,
) -> None:
    angle = index * math.pi * 0.5 + math.pi * 0.25
    radial = Vector((math.cos(angle), math.sin(angle), 0.0))
    tangent = Vector((-math.sin(angle), math.cos(angle), 0.0))
    base = radial * 0.76 + Vector((0.0, 0.0, 0.39))
    if fallen:
        end = radial * 1.48 + tangent * 0.18 + Vector((0.0, 0.0, 0.32))
        beam_between(f"Ward_Fallen_Support_{index + 1}", tuple(base), tuple(end), 0.16, mats["wood_dark"], 0.12, 0.018)
        ico(f"Ward_Fallen_Cap_{index + 1}", tuple(end), (0.13, 0.11, 0.12), mats["bronze"])
        return
    height = 0.83 if broken else 1.43
    top = radial * (0.66 if broken else 0.58) + Vector((0.0, 0.0, height))
    beam_between(
        f"Ward_{'Broken' if broken else 'Support'}_{index + 1}",
        tuple(base),
        tuple(top),
        0.16,
        mats["wood_dark"],
        0.12,
        0.018,
    )
    cone(
        f"Ward_Support_Foot_{index + 1}",
        0.18,
        0.14,
        0.18,
        tuple(base + Vector((0.0, 0.0, 0.05))),
        mats["bronze_dark"],
        8,
    )
    if broken:
        ico(f"Ward_Broken_Top_{index + 1}", tuple(top), (0.14, 0.11, 0.10), mats["wood"])
    else:
        ico(f"Ward_Support_Gem_{index + 1}", tuple(top), (0.12, 0.10, 0.17), mats["ward_glow"])


def build_ring(mats: dict[str, bpy.types.Material], segments: set[int], radius: float = 0.62) -> None:
    for index in sorted(segments):
        angle_a = index * math.pi * 0.25 + math.pi * 0.125
        angle_b = (index + 1) * math.pi * 0.25 + math.pi * 0.125
        start = (math.cos(angle_a) * radius, math.sin(angle_a) * radius, 1.34)
        end = (math.cos(angle_b) * radius, math.sin(angle_b) * radius, 1.34)
        beam_between(f"Ward_Energy_Ring_{index + 1}", start, end, 0.075, mats["bronze"], 0.055)
        midpoint = (Vector(start) + Vector(end)) * 0.5
        ico(f"Ward_Ring_Glyph_{index + 1}", tuple(midpoint), (0.075, 0.06, 0.075), mats["ward_glow"])


def build_crystal(
    mats: dict[str, bpy.types.Material],
    condition: str,
) -> None:
    if condition == "healthy":
        cone("Ward_Crystal_Core", 0.31, 0.19, 1.24, (0.0, 0.0, 1.04), mats["crystal"], 6)
        cone("Ward_Crystal_Tip", 0.19, 0.0, 0.44, (0.0, 0.0, 1.88), mats["crystal_light"], 6)
        ico("Ward_Crystal_Heart", (0.0, 0.0, 0.78), (0.18, 0.18, 0.23), mats["ward_glow"])
    elif condition == "damaged":
        cone("Ward_Crystal_Lower", 0.31, 0.22, 0.68, (0.0, 0.0, 0.76), mats["crystal"], 6)
        upper = cone("Ward_Crystal_Upper", 0.24, 0.06, 0.58, (0.08, 0.0, 1.36), mats["crystal_dim"], 6, (0.0, 0.16, -0.08))
        upper.rotation_euler[1] = 0.14
        box("Ward_Crystal_Fracture", (0.0, -0.235, 1.06), (0.07, 0.035, 0.36), mats["crack"], (0.22, 0.0, -0.18))
        ico("Ward_Damage_Shard", (0.42, -0.10, 0.48), (0.11, 0.07, 0.24), mats["crystal_dim"], (0.2, 0.5, 0.1))
    elif condition == "critical":
        cone("Ward_Crystal_Remainder", 0.31, 0.16, 0.62, (0.0, 0.0, 0.70), mats["critical_glow"], 6, (0.05, -0.12, 0.08))
        ico("Ward_Critical_Heart", (0.0, -0.02, 0.70), (0.19, 0.16, 0.20), mats["critical_light"])
        for index, (x, y, z, rotation) in enumerate((
            (0.39, -0.16, 0.48, (0.3, 0.7, 0.2)),
            (-0.31, 0.18, 0.44, (-0.4, 0.3, -0.3)),
            (0.18, 0.35, 0.43, (0.5, -0.2, 0.1)),
        )):
            ico(f"Ward_Critical_Shard_{index + 1}", (x, y, z), (0.10, 0.07, 0.22), mats["crystal_dim"], rotation)


def build_ward_state(mats: dict[str, bpy.types.Material], condition: str) -> None:
    build_foundation(mats)
    if condition == "healthy":
        for index in range(4):
            build_support(index, mats)
        build_ring(mats, set(range(8)))
        build_crystal(mats, condition)
    elif condition == "damaged":
        for index in range(3):
            build_support(index, mats)
        build_support(3, mats, fallen=True)
        build_ring(mats, {0, 1, 2, 3, 4})
        build_crystal(mats, condition)
        ico("Ward_Damage_Rubble_1", (0.77, -0.55, 0.47), (0.15, 0.12, 0.10), mats["stone"])
        ico("Ward_Damage_Rubble_2", (0.58, -0.78, 0.44), (0.11, 0.09, 0.08), mats["stone_dark"])
    elif condition == "critical":
        build_support(0, mats)
        build_support(1, mats, broken=True)
        build_support(2, mats, fallen=True)
        build_support(3, mats, broken=True)
        build_ring(mats, {0, 1})
        build_crystal(mats, condition)
        for index, angle in enumerate((0.2, 2.4, 4.3)):
            cone(
                f"Ward_Critical_Smoke_Crystal_{index + 1}",
                0.12,
                0.02,
                0.34,
                (math.cos(angle) * 0.45, math.sin(angle) * 0.45, 0.56),
                mats["critical_glow"],
                5,
                (0.25, -0.15, angle),
            )
    elif condition == "destroyed":
        for index in range(4):
            angle = index * math.pi * 0.5 + math.pi * 0.25
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            cone(
                f"Ward_Destroyed_Stump_{index + 1}",
                0.14,
                0.11,
                0.24 + (index % 2) * 0.08,
                tuple(radial * 0.74 + Vector((0.0, 0.0, 0.49))),
                mats["wood_dark"],
                6,
                (0.12 * (index - 1), -0.08, angle),
            )
        for index, (x, y, scale, rotation) in enumerate((
            (-0.42, -0.20, (0.23, 0.15, 0.12), (0.2, 0.1, 0.5)),
            (0.28, -0.38, (0.18, 0.13, 0.10), (-0.2, 0.4, -0.2)),
            (0.46, 0.25, (0.20, 0.14, 0.11), (0.4, -0.1, 0.8)),
            (-0.18, 0.42, (0.16, 0.12, 0.09), (-0.3, 0.2, -0.6)),
        )):
            ico(f"Ward_Destroyed_Rubble_{index + 1}", (x, y, 0.44), scale, mats["stone_dark"], rotation)
        ico("Ward_Destroyed_Heart", (0.0, 0.0, 0.47), (0.13, 0.11, 0.14), mats["critical_glow"])
    else:
        raise ValueError(f"Unknown Ward condition: {condition}")


# ── Support assets ───────────────────────────────────────────────────────────


def build_repair_scaffolding(mats: dict[str, bpy.types.Material]) -> None:
    corners = [(-1.25, -1.25), (1.25, -1.25), (1.25, 1.25), (-1.25, 1.25)]
    for index, (x, y) in enumerate(corners):
        box(f"Scaffold_Foot_{index + 1}", (x, y, 0.08), (0.32, 0.32, 0.16), mats["stone_dark"], bevel=0.025)
        beam_between(f"Scaffold_Post_{index + 1}", (x, y, 0.12), (x, y, 2.15), 0.14, mats["wood"])
    for level_index, z in enumerate((0.72, 1.62)):
        for index in range(4):
            start = (*corners[index], z)
            end = (*corners[(index + 1) % 4], z)
            beam_between(f"Scaffold_Rail_{level_index + 1}_{index + 1}", start, end, 0.11, mats["wood_dark"], 0.08)
    # A deliberately incomplete working deck keeps the Ward visible while it is repaired.
    for index, x in enumerate((-0.92, -0.55, -0.18, 0.19)):
        box(f"Scaffold_Plank_{index + 1}", (x, 0.86, 1.03), (0.30, 1.42, 0.09), mats["wood"], (0.0, 0.0, 0.02 * index), 0.015)
    beam_between("Scaffold_Brace_Left", (-1.25, -1.25, 0.35), (-1.25, 1.25, 1.76), 0.09, mats["wood_dark"], 0.07)
    beam_between("Scaffold_Brace_Right", (1.25, 1.25, 0.35), (1.25, -1.25, 1.76), 0.09, mats["wood_dark"], 0.07)
    for index, z in enumerate((0.35, 0.72, 1.09, 1.46)):
        beam_between(f"Scaffold_Ladder_Rung_{index + 1}", (-1.41, -0.78, z), (-1.41, -0.20, z), 0.07, mats["wood"], 0.07)
    beam_between("Scaffold_Ladder_Left", (-1.41, -0.82, 0.12), (-1.41, -0.82, 1.68), 0.09, mats["wood_dark"], 0.08)
    beam_between("Scaffold_Ladder_Right", (-1.41, -0.16, 0.12), (-1.41, -0.16, 1.68), 0.09, mats["wood_dark"], 0.08)


def build_boundary_post(mats: dict[str, bpy.types.Material]) -> None:
    cone("Boundary_Post_Foot", 0.34, 0.28, 0.20, (0.0, 0.0, 0.10), mats["stone_dark"], 8)
    cone("Boundary_Post_Base", 0.27, 0.22, 0.24, (0.0, 0.0, 0.31), mats["stone"], 8)
    cone("Boundary_Post_Shaft", 0.18, 0.14, 1.10, (0.0, 0.0, 0.96), mats["wood_dark"], 8)
    for index, z in enumerate((0.56, 1.16)):
        cone(f"Boundary_Post_Band_{index + 1}", 0.21, 0.19, 0.10, (0.0, 0.0, z), mats["bronze"], 8)
    ico("Boundary_Post_Crystal", (0.0, 0.0, 1.67), (0.20, 0.17, 0.31), mats["crystal_light"], (0.0, 0.0, math.pi * 0.125))
    for index in range(4):
        angle = index * math.pi * 0.5
        box(
            f"Boundary_Post_Rune_{index + 1}",
            (math.cos(angle) * 0.165, math.sin(angle) * 0.165, 0.94),
            (0.055, 0.025, 0.32),
            mats["ward_glow"],
            (0.0, 0.0, angle),
        )


def build_activation_crystal(mats: dict[str, bpy.types.Material]) -> None:
    cone("Activation_Socket_Base", 0.34, 0.28, 0.14, (0.0, 0.0, 0.07), mats["bronze_dark"], 8)
    cone("Activation_Socket_Ring", 0.27, 0.23, 0.12, (0.0, 0.0, 0.19), mats["bronze"], 8)
    ico("Activation_Crystal", (0.0, 0.0, 0.55), (0.25, 0.21, 0.42), mats["crystal_light"], (0.0, 0.0, math.pi * 0.125))
    ico("Activation_Heart", (0.0, -0.02, 0.54), (0.11, 0.10, 0.15), mats["ward_glow"])
    for index in range(3):
        angle = index * math.pi * 2.0 / 3.0
        ico(
            f"Activation_Mote_{index + 1}",
            (math.cos(angle) * 0.34, math.sin(angle) * 0.34, 0.46 + 0.06 * index),
            (0.055, 0.045, 0.075),
            mats["ward_glow"],
        )


# ── Assembly, catalog, validation data and previews ──────────────────────────


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
        if obj.type == "MESH":
            bpy.context.view_layer.objects.active = obj
            obj.select_set(True)
            bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
            obj.select_set(False)
    move_to_collection(made, collection)
    for obj in made:
        obj.parent = root
    minimum, maximum = world_bounds(made)
    anchor_min, anchor_max = world_bounds(anchors)
    dimensions = maximum - minimum
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
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons,
        "materials": materials,
        "anchor_center": ((anchor_min + anchor_max) * 0.5).copy(),
        "anchor_size": (anchor_max - anchor_min).copy(),
    }


def setup_render(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Scene, bpy.types.Object, bpy.types.Collection]:
    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.mesh.primitive_plane_add(size=50, location=(0.0, 0.0, -0.025))
    floor = bpy.context.object
    floor.name = "Preview_Ground"
    assign(floor, mats["ground"])
    move_to_collection([floor], preview_collection)
    bpy.ops.object.light_add(type="SUN", location=(0.0, 0.0, 15.0))
    sun = bpy.context.object
    sun.name = "Preview_Sun"
    sun.rotation_euler = (math.radians(32), math.radians(-24), math.radians(-30))
    sun.data.energy = 2.4
    sun.data.angle = math.radians(18)
    move_to_collection([sun], preview_collection)
    bpy.ops.object.light_add(type="AREA", location=(-7.0, -9.0, 8.0))
    fill = bpy.context.object
    fill.name = "Preview_Fill"
    fill.data.energy = 1350
    fill.data.color = (0.24, 0.52, 0.64)
    fill.data.shape = "DISK"
    fill.data.size = 8.0
    look_at(fill, (0.0, 0.0, 0.8))
    move_to_collection([fill], preview_collection)
    bpy.ops.object.camera_add(location=(10.5, -16.0, 8.0))
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    camera.data.type = "ORTHO"
    bpy.context.scene.camera = camera
    move_to_collection([camera], preview_collection)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1600
    scene.render.resolution_y = 1000
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.010, 0.018, 0.024)
    scene.view_settings.look = "AgX - Medium High Contrast"
    return scene, camera, preview_collection


def add_scale_reference(mats: dict[str, bpy.types.Material], collection: bpy.types.Collection) -> None:
    parts = [box("Scale_Post", (-3.75, -0.35, 1.0), (0.10, 0.10, 2.0), mats["scale"])]
    for index in range(1, 9):
        z = index * 0.25
        length = 0.34 if index % 4 == 0 else 0.23
        parts.append(box(f"Scale_Tick_{index}", (-3.75 + length * 0.5, -0.35, z), (length, 0.08, 0.025), mats["scale"]))
    parts.append(box("Scale_25cm_Cube", (-3.28, -0.42, 0.125), (0.25, 0.25, 0.25), mats["scale"]))
    move_to_collection(parts, collection)


def main() -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    for expected in EXPECTED_NAMES:
        (EXPORT_DIR / f"{expected}.glb").unlink(missing_ok=True)

    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)

    mats = {
        "stone": material("MIRE_Ward_Stone", (0.36, 0.40, 0.38, 1.0)),
        "stone_dark": material("MIRE_Ward_Stone_Dark", (0.15, 0.19, 0.19, 1.0)),
        "slate": material("MIRE_Ward_Slate", (0.10, 0.15, 0.17, 1.0)),
        "wood": material("MIRE_Ward_Wood", (0.48, 0.27, 0.10, 1.0)),
        "wood_dark": material("MIRE_Ward_Wood_Dark", (0.24, 0.12, 0.045, 1.0)),
        "bronze": material("MIRE_Ward_Bronze", (0.70, 0.43, 0.12, 1.0), 0.42, 0.58),
        "bronze_dark": material("MIRE_Ward_Bronze_Dark", (0.30, 0.18, 0.06, 1.0), 0.48, 0.52),
        "crystal": material("MIRE_Ward_Crystal", (0.06, 0.62, 0.67, 1.0), 0.22, 0.05, (0.05, 0.72, 0.80, 1.0), 2.2),
        "crystal_light": material("MIRE_Ward_Crystal_Light", (0.28, 0.92, 0.88, 1.0), 0.18, 0.02, (0.18, 1.0, 0.90, 1.0), 3.0),
        "crystal_dim": material("MIRE_Ward_Crystal_Dim", (0.16, 0.42, 0.44, 1.0), 0.38, 0.0, (0.08, 0.38, 0.42, 1.0), 0.8),
        "ward_glow": material("MIRE_Ward_Glow", (0.20, 0.86, 0.78, 1.0), 0.20, 0.0, (0.12, 1.0, 0.82, 1.0), 3.4),
        "critical_glow": material("MIRE_Ward_Critical", (0.88, 0.18, 0.12, 1.0), 0.30, 0.0, (1.0, 0.08, 0.03, 1.0), 2.5),
        "critical_light": material("MIRE_Ward_Critical_Light", (1.0, 0.48, 0.08, 1.0), 0.22, 0.0, (1.0, 0.26, 0.03, 1.0), 3.0),
        "crack": material("MIRE_Ward_Crack", (0.035, 0.028, 0.045, 1.0)),
        "ground": material("MIRE_Ward_Preview_Ground", (0.052, 0.085, 0.062, 1.0)),
        "scale": material("MIRE_Ward_Scale_Reference", (0.18, 0.50, 0.78, 1.0)),
    }

    foundation_anchor = ("Ward_Foundation_",)
    builders: list[tuple[str, str, Callable[[], None], tuple[str, ...]]] = [
        ("ward_foundation", "ward_state", lambda: build_foundation(mats), foundation_anchor),
        ("ward_healthy", "ward_state", lambda: build_ward_state(mats, "healthy"), foundation_anchor),
        ("ward_damaged", "ward_state", lambda: build_ward_state(mats, "damaged"), foundation_anchor),
        ("ward_critical", "ward_state", lambda: build_ward_state(mats, "critical"), foundation_anchor),
        ("ward_destroyed", "ward_state", lambda: build_ward_state(mats, "destroyed"), foundation_anchor),
        ("ward_repair_scaffolding", "repair", lambda: build_repair_scaffolding(mats), ()),
        ("ward_boundary_post", "boundary", lambda: build_boundary_post(mats), ()),
        ("ward_activation_crystal", "activation", lambda: build_activation_crystal(mats), ()),
    ]
    if [name for name, _, _, _ in builders] != EXPECTED_NAMES:
        raise RuntimeError("A-007 specification and expected export list diverged")

    positions = [
        (-5.0, 1.65, 0.0), (-2.5, 1.65, 0.0), (0.0, 1.65, 0.0), (2.5, 1.65, 0.0),
        (5.0, 1.65, 0.0), (-3.25, -1.65, 0.0), (0.8, -1.65, 0.0), (3.25, -1.65, 0.0),
    ]
    records: list[dict] = []
    for (name, family, builder, anchor), location in zip(builders, positions, strict=True):
        records.append(create_asset(name, family, builder, location, anchor))

    state_records = [record for record in records if record["name"] in STATE_NAMES]
    reference_anchor = state_records[0]["anchor_center"]
    reference_size = state_records[0]["anchor_size"]
    max_anchor_drift = max((record["anchor_center"] - reference_anchor).length for record in state_records)
    max_anchor_size_delta = max((record["anchor_size"] - reference_size).length for record in state_records)
    if max_anchor_drift > 0.000001 or max_anchor_size_delta > 0.000001:
        raise RuntimeError(
            f"Ward state anchors drift: center={max_anchor_drift:.9f}m size={max_anchor_size_delta:.9f}m"
        )

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
    camera.data.ortho_scale = 13.4
    camera.location = (9.5, -18.5, 9.0)
    look_at(camera, (0.0, 0.0, 0.75))
    scene.render.filepath = str(PREVIEW_DIR / "ward_preview.png")
    bpy.ops.render.render(write_still=True)

    original_locations = {record["name"]: record["root"].location.copy() for record in records}
    showcase_positions = {
        "ward_healthy": (-1.95, 0.40, 0.0),
        "ward_destroyed": (0.80, 0.42, 0.0),
        "ward_boundary_post": (2.70, 0.12, 0.0),
        "ward_activation_crystal": (3.65, -0.10, 0.0),
    }
    for record in records:
        set_visible(record, record["name"] in showcase_positions)
        if record["name"] in showcase_positions:
            record["root"].location = showcase_positions[record["name"]]
    add_scale_reference(mats, preview_collection)
    camera.data.ortho_scale = 9.5
    camera.location = (8.0, -13.0, 6.4)
    look_at(camera, (0.0, 0.0, 0.78))
    scene.render.filepath = str(PREVIEW_DIR / "ward_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    for record in records:
        record["root"].location = original_locations[record["name"]]
        set_visible(record, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "ward_set.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(
        f"Built {len(records)} A-007 Ward assets ({total_polygons} polygons total); "
        f"state anchor drift {max_anchor_drift * 1000.0:.2f} mm"
    )


if __name__ == "__main__":
    main()
