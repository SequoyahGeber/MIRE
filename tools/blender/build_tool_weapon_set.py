"""Build MIRE's first paired world/viewmodel tool and weapon set (A-004).

Run with:
  Blender --background --python tools/blender/build_tool_weapon_set.py

Ten shared designs produce 20 portable GLBs. World and viewmodel exports use
the same geometry and materials so their silhouettes cannot drift.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Callable

import bpy
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "tools_weapons"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

DESIGNS = [
    "wooden_axe",
    "stone_axe",
    "wooden_pickaxe",
    "stone_pickaxe",
    "iron_pickaxe",
    "cleaver",
    "skewer",
    "short_bow",
    "arrow",
    "repair_hammer",
]
EXPECTED_NAMES = [f"{design}_{presentation}" for design in DESIGNS for presentation in ("world", "viewmodel")]


def material(
    name: str,
    color: tuple[float, float, float, float],
    roughness: float = 0.9,
    metallic: float = 0.0,
) -> bpy.types.Material:
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = color
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = roughness
    shader.inputs["Metallic"].default_value = metallic
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
    if bevel > 0.0:
        modifier = obj.modifiers.new("Low_Poly_Bevel", "BEVEL")
        modifier.width = bevel
        modifier.segments = 1
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=modifier.name)
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
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=1.0, location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, mat)


def cylinder_between(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    radius: float,
    mat: bpy.types.Material,
    vertices: int = 8,
    end_radius_ratio: float = 0.94,
) -> bpy.types.Object:
    first = Vector(start)
    second = Vector(end)
    direction = second - first
    obj = cone(
        name,
        radius,
        radius * end_radius_ratio,
        direction.length,
        tuple((first + second) * 0.5),
        mat,
        vertices,
    )
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = direction.to_track_quat("Z", "Y")
    return obj


def tapered_between(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    start_radius: float,
    end_radius: float,
    mat: bpy.types.Material,
    vertices: int = 8,
) -> bpy.types.Object:
    first = Vector(start)
    second = Vector(end)
    direction = second - first
    obj = cone(name, start_radius, end_radius, direction.length, tuple((first + second) * 0.5), mat, vertices)
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = direction.to_track_quat("Z", "Y")
    return obj


def mesh_object(
    name: str,
    vertices: list[tuple[float, float, float]],
    faces: list[tuple[int, ...]],
    mat: bpy.types.Material,
) -> bpy.types.Object:
    mesh = bpy.data.meshes.new(f"{name}_Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return assign(obj, mat)


def extruded_profile(
    name: str,
    points_xz: list[tuple[float, float]],
    thickness: float,
    mat: bpy.types.Material,
) -> bpy.types.Object:
    count = len(points_xz)
    vertices = [(x, -thickness * 0.5, z) for x, z in points_xz] + [(x, thickness * 0.5, z) for x, z in points_xz]
    faces: list[tuple[int, ...]] = [tuple(range(count - 1, -1, -1)), tuple(range(count, count * 2))]
    for index in range(count):
        next_index = (index + 1) % count
        faces.append((index, next_index, count + next_index, count + index))
    return mesh_object(name, vertices, faces, mat)


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


def create_asset(
    name: str,
    design: str,
    presentation: str,
    builder: Callable[[], None],
    display_location: tuple[float, float, float],
) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)
    before = set(bpy.data.objects)
    builder()
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
        "design": design,
        "presentation": presentation,
        "root": root,
        "width": dimensions.x,
        "depth": dimensions.y,
        "height": dimensions.z,
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons,
        "materials": materials,
    }


def add_handle(
    mats: dict[str, bpy.types.Material],
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    radius: float = 0.055,
    wrapped: bool = True,
) -> None:
    cylinder_between("Handle", start, end, radius, mats["handle"], 9)
    if wrapped:
        for index in range(4):
            t = 0.14 + index * 0.065
            center = Vector(start).lerp(Vector(end), t)
            cone(f"Grip_Wrap_{index + 1}", radius * 1.10, radius * 1.10, 0.036, tuple(center), mats["wrap"], 9)
    cone("Pommel", radius * 1.25, radius * 1.05, 0.08, tuple(Vector(start) + (Vector(end) - Vector(start)).normalized() * 0.02), mats["handle_dark"], 9)


def add_lashings(mats: dict[str, bpy.types.Material], center: tuple[float, float, float], width: float) -> None:
    for index, x_offset in enumerate((-width * 0.20, 0.0, width * 0.20)):
        box(
            f"Lashing_{index + 1}",
            (center[0] + x_offset, center[1] - 0.075, center[2]),
            (0.045, 0.035, 0.27),
            mats["rope"],
            (0.0, 0.0, math.radians(18 if index % 2 == 0 else -18)),
            0.008,
        )


def build_wooden_axe(mats: dict[str, bpy.types.Material]) -> None:
    add_handle(mats, (-0.07, 0.0, 0.04), (0.05, 0.0, 1.10), 0.060)
    extruded_profile(
        "Wooden_Axe_Head",
        [(-0.26, 1.05), (-0.10, 0.98), (0.16, 0.99), (0.50, 0.90), (0.57, 1.38), (0.16, 1.30), (-0.10, 1.29), (-0.26, 1.22)],
        0.17,
        mats["wood_blade"],
    )
    extruded_profile("Wooden_Edge", [(0.50, 0.90), (0.57, 1.38), (0.48, 1.35), (0.41, 0.95)], 0.19, mats["wood_cut"])
    add_lashings(mats, (0.0, 0.0, 1.10), 0.42)


def build_stone_axe(mats: dict[str, bpy.types.Material]) -> None:
    add_handle(mats, (-0.08, 0.0, 0.04), (0.05, 0.0, 1.12), 0.060)
    extruded_profile(
        "Stone_Axe_Head",
        [(-0.24, 1.04), (-0.08, 0.98), (0.16, 0.96), (0.48, 0.88), (0.58, 1.12), (0.49, 1.40), (0.14, 1.32), (-0.12, 1.30), (-0.27, 1.20)],
        0.19,
        mats["stone"],
    )
    extruded_profile("Stone_Axe_Edge", [(0.48, 0.88), (0.58, 1.12), (0.49, 1.40), (0.40, 1.34), (0.48, 1.13), (0.39, 0.94)], 0.205, mats["stone_edge"])
    add_lashings(mats, (0.0, 0.0, 1.11), 0.42)


def build_pickaxe(mats: dict[str, bpy.types.Material], tier: str) -> None:
    add_handle(mats, (-0.06, 0.0, 0.04), (0.03, 0.0, 1.06), 0.058)
    if tier == "wooden":
        head_mat = mats["wood_blade"]
        edge_mat = mats["wood_cut"]
        reach = 0.47
        thickness = 0.13
    elif tier == "stone":
        head_mat = mats["stone"]
        edge_mat = mats["stone_edge"]
        reach = 0.54
        thickness = 0.15
    else:
        head_mat = mats["iron"]
        edge_mat = mats["iron_light"]
        reach = 0.62
        thickness = 0.12
    box("Pick_Collar", (0.0, 0.0, 1.10), (0.30, 0.22, 0.24), head_mat, bevel=0.045)
    tapered_between("Pick_Left", (-0.08, 0.0, 1.13), (-reach, 0.0, 1.07), thickness, 0.025, head_mat, 8)
    tapered_between("Pick_Right", (0.08, 0.0, 1.13), (reach, 0.0, 1.02), thickness, 0.018, edge_mat, 8)
    if tier == "stone":
        ico("Stone_Knuckle_Left", (-0.25, 0.0, 1.12), (0.17, 0.13, 0.13), head_mat, (0.2, -0.3, 0.1))
        ico("Stone_Knuckle_Right", (0.25, 0.0, 1.10), (0.17, 0.13, 0.13), head_mat, (-0.2, 0.2, -0.1))
    if tier != "iron":
        add_lashings(mats, (0.0, 0.0, 1.07), 0.38)
    else:
        cone("Iron_Socket", 0.105, 0.09, 0.30, (0.0, 0.0, 1.00), mats["iron_dark"], 9)


def build_cleaver(mats: dict[str, bpy.types.Material]) -> None:
    add_handle(mats, (0.0, 0.0, 0.03), (0.0, 0.0, 0.46), 0.065)
    box("Cleaver_Bolster", (0.0, 0.0, 0.49), (0.26, 0.20, 0.12), mats["brass"], bevel=0.025)
    extruded_profile(
        "Cleaver_Blade",
        [(-0.12, 0.48), (0.27, 0.50), (0.43, 1.15), (-0.16, 1.13), (-0.25, 0.72)],
        0.12,
        mats["iron"],
    )
    extruded_profile("Cleaver_Edge", [(0.25, 0.50), (0.43, 1.15), (0.34, 1.13), (0.18, 0.51)], 0.135, mats["iron_light"])
    cone("Cleaver_Hole", 0.045, 0.045, 0.14, (0.12, 0.0, 1.00), mats["iron_dark"], 10, (math.radians(90), 0.0, 0.0))


def build_skewer(mats: dict[str, bpy.types.Material]) -> None:
    add_handle(mats, (0.0, 0.0, 0.03), (0.0, 0.0, 1.15), 0.045)
    cylinder_between("Skewer_Shaft", (0.0, 0.0, 1.06), (0.0, 0.0, 1.68), 0.028, mats["iron"], 8)
    tapered_between("Skewer_Point", (0.0, 0.0, 1.64), (0.0, 0.0, 1.94), 0.075, 0.004, mats["iron_light"], 8)
    box("Skewer_Guard", (0.0, 0.0, 1.15), (0.42, 0.10, 0.085), mats["iron_dark"], (0.0, 0.0, 0.12), 0.025)
    for index, side in enumerate((-1, 1)):
        tapered_between(
            f"Skewer_Barb_{index + 1}",
            (side * 0.02, 0.0, 1.72),
            (side * 0.14, 0.0, 1.61),
            0.035,
            0.008,
            mats["iron_light"],
            7,
        )


def build_short_bow(mats: dict[str, bpy.types.Material]) -> None:
    upper = [(0.0, 0.0, 0.80), (-0.17, 0.0, 1.03), (-0.29, 0.0, 1.30), (-0.19, 0.0, 1.56)]
    lower = [(0.0, 0.0, 0.72), (-0.17, 0.0, 0.49), (-0.29, 0.0, 0.22), (-0.19, 0.0, 0.02)]
    for prefix, points in (("Upper", upper), ("Lower", lower)):
        for index in range(len(points) - 1):
            cylinder_between(f"Bow_{prefix}_{index + 1}", points[index], points[index + 1], 0.043 - index * 0.005, mats["bow_wood"], 8)
    cylinder_between("Bow_Grip", (0.0, 0.0, 0.62), (0.0, 0.0, 0.90), 0.065, mats["handle_dark"], 9)
    for index in range(4):
        box(f"Bow_Wrap_{index + 1}", (0.0, -0.068, 0.66 + index * 0.065), (0.12, 0.035, 0.035), mats["wrap"], (0.0, 0.0, 0.08 * (index % 2)), 0.008)
    cylinder_between("Bow_String", (-0.19, 0.0, 0.02), (-0.19, 0.0, 1.56), 0.009, mats["string"], 6)
    cylinder_between("Bow_String_Upper", (-0.19, 0.0, 1.56), (0.0, 0.0, 0.80), 0.008, mats["string"], 6)
    cylinder_between("Bow_String_Lower", (-0.19, 0.0, 0.02), (0.0, 0.0, 0.72), 0.008, mats["string"], 6)


def build_arrow(mats: dict[str, bpy.types.Material]) -> None:
    cylinder_between("Arrow_Shaft", (0.0, 0.0, 0.06), (0.0, 0.0, 1.22), 0.022, mats["arrow_wood"], 8)
    tapered_between("Arrow_Head", (0.0, 0.0, 1.18), (0.0, 0.0, 1.48), 0.11, 0.005, mats["stone_edge"], 6)
    for index, rotation in enumerate((0.0, math.radians(120), math.radians(240))):
        box(
            f"Fletching_{index + 1}",
            (0.0, 0.0, 0.20),
            (0.18, 0.025, 0.28),
            mats["fletching" if index % 2 == 0 else "fletching_light"],
            (0.0, 0.0, rotation),
            0.008,
        )
    cone("Arrow_Nock", 0.032, 0.024, 0.10, (0.0, 0.0, 0.05), mats["arrow_wood"], 8)


def build_repair_hammer(mats: dict[str, bpy.types.Material]) -> None:
    add_handle(mats, (0.0, 0.0, 0.03), (0.0, 0.0, 0.88), 0.060)
    box("Hammer_Core", (0.0, 0.0, 0.98), (0.66, 0.24, 0.28), mats["iron"], bevel=0.055)
    box("Hammer_Face", (0.35, 0.0, 0.98), (0.15, 0.30, 0.36), mats["iron_light"], bevel=0.035)
    tapered_between("Hammer_Peen", (-0.30, 0.0, 0.98), (-0.58, 0.0, 0.98), 0.16, 0.045, mats["iron_dark"], 8)
    box("Hammer_Brass_Band", (0.0, -0.145, 0.98), (0.23, 0.04, 0.31), mats["brass"], bevel=0.018)
    for index, z in enumerate((0.34, 0.43, 0.52)):
        box(f"Repair_Grip_Band_{index + 1}", (0.0, -0.067, z), (0.13, 0.03, 0.040), mats["red"], (0.0, 0.0, 0.12), 0.008)


def set_visible(record: dict, visible: bool) -> None:
    record["root"].hide_render = not visible
    for child in record["root"].children_recursive:
        child.hide_render = not visible


def setup_render(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Scene, bpy.types.Object, bpy.types.Collection]:
    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.mesh.primitive_plane_add(size=70, location=(0.0, 0.0, -0.035))
    floor = bpy.context.object
    floor.name = "Preview_Ground"
    assign(floor, mats["ground"])
    move_to_collection([floor], preview_collection)
    bpy.ops.object.light_add(type="SUN", location=(0.0, 0.0, 20.0))
    sun = bpy.context.object
    sun.name = "Preview_Sun"
    sun.rotation_euler = (math.radians(34), math.radians(-22), math.radians(-28))
    sun.data.energy = 2.35
    sun.data.angle = math.radians(18)
    move_to_collection([sun], preview_collection)
    bpy.ops.object.light_add(type="AREA", location=(-9.0, -13.0, 12.0))
    fill = bpy.context.object
    fill.name = "Preview_Fill"
    fill.data.energy = 1450
    fill.data.color = (0.43, 0.28, 0.68)
    fill.data.shape = "DISK"
    fill.data.size = 10.0
    look_at(fill, (0.0, 0.0, 0.8))
    move_to_collection([fill], preview_collection)
    bpy.ops.object.camera_add(location=(0.0, -18.0, 10.0))
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
    scene.world.color = (0.012, 0.016, 0.026)
    scene.view_settings.look = "AgX - Medium High Contrast"
    return scene, camera, preview_collection


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
        "handle": material("MIRE_Tool_Handle", (0.35, 0.12, 0.025, 1.0)),
        "handle_dark": material("MIRE_Tool_Handle_Dark", (0.14, 0.035, 0.012, 1.0)),
        "wood_blade": material("MIRE_Tool_Hardwood", (0.48, 0.19, 0.035, 1.0)),
        "wood_cut": material("MIRE_Tool_Wood_Edge", (0.87, 0.54, 0.16, 1.0)),
        "rope": material("MIRE_Tool_Rope", (0.70, 0.51, 0.13, 1.0)),
        "wrap": material("MIRE_Tool_Grip_Wrap", (0.47, 0.045, 0.025, 1.0)),
        "stone": material("MIRE_Tool_Stone", (0.26, 0.31, 0.33, 1.0)),
        "stone_edge": material("MIRE_Tool_Stone_Edge", (0.60, 0.68, 0.68, 1.0), 0.48),
        "iron": material("MIRE_Tool_Iron", (0.30, 0.38, 0.41, 1.0), 0.38, 0.68),
        "iron_light": material("MIRE_Tool_Iron_Edge", (0.63, 0.72, 0.73, 1.0), 0.28, 0.75),
        "iron_dark": material("MIRE_Tool_Iron_Dark", (0.08, 0.12, 0.14, 1.0), 0.48, 0.58),
        "brass": material("MIRE_Tool_Brass", (0.82, 0.45, 0.055, 1.0), 0.34, 0.56),
        "red": material("MIRE_Tool_Repair_Red", (0.67, 0.04, 0.025, 1.0), 0.55, 0.25),
        "bow_wood": material("MIRE_Tool_Bow_Wood", (0.57, 0.22, 0.045, 1.0)),
        "string": material("MIRE_Tool_Bow_String", (0.80, 0.75, 0.58, 1.0)),
        "arrow_wood": material("MIRE_Tool_Arrow_Shaft", (0.58, 0.30, 0.075, 1.0)),
        "fletching": material("MIRE_Tool_Fletching", (0.12, 0.40, 0.62, 1.0)),
        "fletching_light": material("MIRE_Tool_Fletching_Light", (0.35, 0.72, 0.87, 1.0)),
        "ground": material("MIRE_Tool_Preview_Ground", (0.048, 0.085, 0.056, 1.0)),
        "scale": material("MIRE_Tool_Scale_Reference", (0.15, 0.53, 0.78, 1.0)),
    }

    builders: dict[str, Callable[[], None]] = {
        "wooden_axe": lambda: build_wooden_axe(mats),
        "stone_axe": lambda: build_stone_axe(mats),
        "wooden_pickaxe": lambda: build_pickaxe(mats, "wooden"),
        "stone_pickaxe": lambda: build_pickaxe(mats, "stone"),
        "iron_pickaxe": lambda: build_pickaxe(mats, "iron"),
        "cleaver": lambda: build_cleaver(mats),
        "skewer": lambda: build_skewer(mats),
        "short_bow": lambda: build_short_bow(mats),
        "arrow": lambda: build_arrow(mats),
        "repair_hammer": lambda: build_repair_hammer(mats),
    }
    records: list[dict] = []
    for design_index, design in enumerate(DESIGNS):
        for presentation_index, presentation in enumerate(("world", "viewmodel")):
            name = f"{design}_{presentation}"
            column = design_index % 5
            row = design_index // 5
            if presentation == "world":
                location = ((column - 2) * 3.1, 2.2 - row * 4.2, 0.0)
            else:
                location = ((column - 2) * 3.1, 26.0 + row * 4.2, 0.0)
            records.append(create_asset(name, design, presentation, builders[design], location))
    if [record["name"] for record in records] != EXPECTED_NAMES:
        raise RuntimeError("A-004 specification and export order diverged")

    catalog = [
        {
            "name": record["name"],
            "design": record["design"],
            "presentation": record["presentation"],
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
    for record in records:
        set_visible(record, record["presentation"] == "world")
    camera.data.ortho_scale = 17.2
    camera.location = (0.0, -18.0, 9.0)
    look_at(camera, (0.0, 0.0, 0.80))
    scene.render.filepath = str(PREVIEW_DIR / "tools_weapons_world_preview.png")
    bpy.ops.render.render(write_still=True)

    original_transforms = {
        record["name"]: (record["root"].location.copy(), record["root"].rotation_euler.copy())
        for record in records
    }
    for record in records:
        set_visible(record, record["presentation"] == "viewmodel")
        if record["presentation"] == "viewmodel":
            index = DESIGNS.index(record["design"])
            column = index % 5
            row = index // 5
            record["root"].location = ((column - 2) * 3.1, 2.2 - row * 4.2, 0.0)
            record["root"].rotation_euler = (math.radians(-12), math.radians(18), math.radians(-10))
    camera.data.ortho_scale = 17.2
    camera.location = (0.0, -18.0, 9.0)
    look_at(camera, (0.0, 0.0, 0.82))
    scene.render.filepath = str(PREVIEW_DIR / "tools_weapons_viewmodel_preview.png")
    bpy.ops.render.render(write_still=True)

    showcase_positions = {
        "stone_axe_world": (-3.0, 0.2, 0.0),
        "skewer_world": (-0.8, 0.2, 0.0),
        "short_bow_world": (1.6, 0.2, 0.0),
        "cleaver_world": (3.7, 0.2, 0.0),
    }
    for record in records:
        set_visible(record, record["name"] in showcase_positions)
        if record["name"] in showcase_positions:
            record["root"].location = showcase_positions[record["name"]]
            record["root"].rotation_euler = (0.0, 0.0, 0.0)
    scale_parts = [
        ico("Scale_Head", (-5.1, -0.6, 1.63), (0.16, 0.16, 0.18), mats["scale"]),
        cone("Scale_Body", 0.24, 0.17, 0.92, (-5.1, -0.6, 1.02), mats["scale"], 8),
        cylinder_between("Scale_Leg_L", (-5.20, -0.6, 0.60), (-5.22, -0.6, 0.02), 0.075, mats["scale"], 7),
        cylinder_between("Scale_Leg_R", (-5.00, -0.6, 0.60), (-4.98, -0.6, 0.02), 0.075, mats["scale"], 7),
        box("Scale_Metre", (-4.55, -0.6, 0.50), (0.10, 0.10, 1.0), mats["scale"]),
    ]
    move_to_collection(scale_parts, preview_collection)
    camera.data.ortho_scale = 13.8
    camera.location = (6.0, -16.0, 8.2)
    look_at(camera, (-0.2, 0.0, 0.85))
    scene.render.filepath = str(PREVIEW_DIR / "tools_weapons_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    for record in records:
        location, rotation = original_transforms[record["name"]]
        record["root"].location = location
        record["root"].rotation_euler = rotation
        set_visible(record, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "tool_weapon_set.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(f"Built {len(records)} A-004 exports from {len(DESIGNS)} shared designs ({total_polygons} polygons total)")


if __name__ == "__main__":
    main()
