"""Build MIRE's first world-pickup kit (asset batch A-002).

Run with:
  Blender --background --python tools/blender/build_pickup_kit.py

Outputs 14 individual metre-scale GLBs, an editable Blender source, a JSON
catalog, and two preview renders. Geometry and layout are deterministic.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Callable

import bpy
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "pickups"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

EXPECTED_NAMES = [
    "pickup_log",
    "pickup_branch",
    "pickup_stone",
    "pickup_flint",
    "pickup_iron_ore",
    "pickup_iron_ingot",
    "pickup_coal",
    "pickup_fibre_bundle",
    "pickup_berry",
    "pickup_mushroom",
    "pickup_raw_meat",
    "pickup_coin",
    "pickup_coin_stack",
    "pickup_salvage_fragment",
]


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


def cylinder_between(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    radius: float,
    mat: bpy.types.Material,
    vertices: int = 8,
) -> bpy.types.Object:
    first = Vector(start)
    second = Vector(end)
    direction = second - first
    obj = cone(name, radius, radius * 0.92, direction.length, tuple((first + second) * 0.5), mat, vertices)
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


def shard(
    name: str,
    location: tuple[float, float, float],
    scale: tuple[float, float, float],
    mat: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    vertices = [
        (0.0, 0.0, 0.55),
        (-0.50, -0.30, 0.0),
        (0.42, -0.36, 0.0),
        (0.50, 0.28, 0.0),
        (-0.38, 0.38, 0.0),
        (0.0, 0.0, -0.45),
    ]
    faces = [(0, 1, 2), (0, 2, 3), (0, 3, 4), (0, 4, 1), (5, 2, 1), (5, 3, 2), (5, 4, 3), (5, 1, 4)]
    obj = mesh_object(name, vertices, faces, mat)
    obj.location = location
    obj.scale = scale
    obj.rotation_euler = rotation
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.select_set(False)
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


def create_asset(
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

    # Normalize every pickup to a horizontal centre origin at ground level.
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
        "family": family,
        "root": root,
        "width": dimensions.x,
        "depth": dimensions.y,
        "height": dimensions.z,
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons,
        "materials": materials,
    }


def build_log(mats: dict[str, bpy.types.Material]) -> None:
    cylinder_between("Log", (-0.72, 0.0, 0.23), (0.72, 0.04, 0.27), 0.23, mats["bark"], 10)
    cone("Cut_Left", 0.215, 0.215, 0.028, (-0.735, -0.001, 0.228), mats["wood"], 10, (0.0, math.radians(89), 0.0))
    cone("Cut_Right", 0.205, 0.205, 0.028, (0.735, 0.041, 0.268), mats["wood"], 10, (0.0, math.radians(89), 0.0))
    for index, x in enumerate((-0.38, 0.18, 0.48)):
        cylinder_between(f"Bark_Ridge_{index + 1}", (x, -0.20, 0.19), (x + 0.12, -0.19, 0.39), 0.025, mats["bark_light"], 5)


def build_branch(mats: dict[str, bpy.types.Material]) -> None:
    cylinder_between("Branch_Main", (-0.62, 0.0, 0.10), (0.58, 0.04, 0.16), 0.085, mats["bark_light"], 8)
    cylinder_between("Branch_Fork", (0.18, 0.02, 0.14), (0.55, 0.34, 0.38), 0.055, mats["bark"], 7)
    cylinder_between("Branch_Twig", (-0.16, 0.0, 0.13), (0.05, -0.26, 0.29), 0.038, mats["bark"], 6)
    cone("Broken_End", 0.074, 0.074, 0.025, (-0.635, 0.0, 0.098), mats["wood"], 8, (0.0, math.radians(88), 0.0))


def build_stone(mats: dict[str, bpy.types.Material]) -> None:
    ico("Stone_Main", (-0.12, 0.02, 0.23), (0.38, 0.31, 0.27), mats["stone"], (0.18, -0.12, 0.34))
    ico("Stone_Side", (0.27, -0.08, 0.14), (0.22, 0.19, 0.17), mats["stone_light"], (-0.22, 0.34, 0.10))
    ico("Stone_Chip", (-0.31, -0.20, 0.08), (0.13, 0.11, 0.09), mats["stone_dark"], (0.4, 0.1, -0.2))


def build_flint(mats: dict[str, bpy.types.Material]) -> None:
    shard("Flint_Main", (0.0, 0.0, 0.22), (0.58, 0.36, 0.48), mats["flint"], (0.12, -0.28, 0.18))
    shard("Flint_Flake", (0.31, -0.10, 0.075), (0.20, 0.14, 0.13), mats["flint_edge"], (-0.2, 0.4, 0.5))
    box("Flint_Edge", (0.0, -0.29, 0.26), (0.58, 0.035, 0.055), mats["flint_edge"], (0.0, 0.0, -0.08))


def build_iron_ore(mats: dict[str, bpy.types.Material]) -> None:
    ico("Ore_Rock", (0.0, 0.0, 0.26), (0.42, 0.35, 0.31), mats["iron_stone"], (0.2, -0.3, 0.4))
    for index, (location, scale, rotation) in enumerate(
        (
            ((-0.20, -0.29, 0.28), (0.17, 0.09, 0.12), (0.2, 0.4, 0.1)),
            ((0.15, -0.31, 0.18), (0.14, 0.08, 0.10), (-0.3, 0.1, 0.5)),
            ((0.24, -0.10, 0.42), (0.12, 0.08, 0.09), (0.3, -0.4, 0.2)),
            ((-0.10, 0.08, 0.50), (0.13, 0.10, 0.08), (-0.2, 0.3, -0.1)),
        )
    ):
        ico(f"Ore_Seam_{index + 1}", location, scale, mats["iron"], rotation)


def build_ingot(mats: dict[str, bpy.types.Material]) -> None:
    vertices = [
        (-0.48, -0.22, 0.0), (0.48, -0.22, 0.0), (0.48, 0.22, 0.0), (-0.48, 0.22, 0.0),
        (-0.35, -0.15, 0.19), (0.35, -0.15, 0.19), (0.35, 0.15, 0.19), (-0.35, 0.15, 0.19),
    ]
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    mesh_object("Iron_Ingot", vertices, faces, mats["ingot"])
    box("Ingot_Stamp", (0.0, 0.0, 0.198), (0.25, 0.11, 0.018), mats["ingot_dark"], (0.0, 0.0, math.radians(-8)), 0.015)


def build_coal(mats: dict[str, bpy.types.Material]) -> None:
    chunks = (
        ((-0.20, 0.02, 0.18), (0.30, 0.25, 0.22), (0.2, 0.4, 0.1)),
        ((0.17, -0.08, 0.14), (0.26, 0.22, 0.18), (-0.3, 0.1, 0.5)),
        ((0.02, 0.23, 0.11), (0.21, 0.18, 0.15), (0.3, -0.4, 0.2)),
        ((0.32, 0.18, 0.08), (0.14, 0.13, 0.11), (-0.2, 0.3, -0.1)),
    )
    for index, (location, scale, rotation) in enumerate(chunks):
        ico(f"Coal_{index + 1}", location, scale, mats["coal" if index < 3 else "coal_glint"], rotation)


def build_fibre(mats: dict[str, bpy.types.Material]) -> None:
    strands = ((-0.14, -0.07, -0.08), (-0.07, 0.08, 0.10), (0.0, -0.03, -0.04), (0.07, 0.07, 0.06), (0.14, -0.06, -0.10), (-0.18, 0.03, 0.14), (0.18, 0.02, -0.15))
    for index, (y, z_offset, angle) in enumerate(strands):
        cylinder_between(
            f"Fibre_{index + 1}",
            (-0.50, y, 0.13 + z_offset * 0.10),
            (0.50, y + angle * 0.18, 0.14 - z_offset * 0.10),
            0.035,
            mats["fibre_light" if index % 3 == 0 else "fibre"],
            6,
        )
    for x in (-0.25, 0.25):
        cone(f"Binding_{x}", 0.21, 0.21, 0.045, (x, 0.0, 0.14), mats["binding"], 8, (0.0, math.radians(90), 0.0))


def build_berry(mats: dict[str, bpy.types.Material]) -> None:
    berries = ((-0.12, 0.0, 0.14), (0.10, -0.03, 0.13), (0.0, 0.12, 0.15), (-0.02, -0.13, 0.17), (0.02, 0.0, 0.29))
    for index, location in enumerate(berries):
        ico(f"Berry_{index + 1}", location, (0.14, 0.14, 0.14), mats["berry" if index % 2 == 0 else "berry_light"], subdivisions=2)
    cylinder_between("Berry_Stem", (0.02, 0.0, 0.34), (0.10, 0.02, 0.52), 0.025, mats["stem"], 6)
    leaf_a = ico("Berry_Leaf_A", (-0.08, 0.0, 0.46), (0.22, 0.055, 0.10), mats["leaf"], (0.1, 0.3, -0.2))
    leaf_a.rotation_euler[2] = 0.4
    leaf_b = ico("Berry_Leaf_B", (0.22, 0.02, 0.43), (0.19, 0.05, 0.09), mats["leaf_light"], (-0.2, 0.1, 0.3))
    leaf_b.rotation_euler[2] = -0.5


def build_mushroom(mats: dict[str, bpy.types.Material]) -> None:
    cone("Mushroom_Stem", 0.13, 0.09, 0.42, (0.0, 0.0, 0.21), mats["stem_pale"], 9)
    ico("Mushroom_Cap", (0.0, 0.0, 0.48), (0.38, 0.34, 0.144), mats["mushroom"], (0.0, 0.0, 0.18), 2)
    for index, location in enumerate(((-0.15, -0.25, 0.53), (0.08, -0.31, 0.57), (0.18, -0.18, 0.50))):
        ico(f"Cap_Spot_{index + 1}", location, (0.045, 0.025, 0.035), mats["spot"], subdivisions=1)


def build_meat(mats: dict[str, bpy.types.Material]) -> None:
    vertices = [
        (-0.46, -0.22, 0.02), (0.36, -0.28, 0.02), (0.50, 0.02, 0.02), (0.22, 0.28, 0.02), (-0.32, 0.24, 0.02),
        (-0.40, -0.18, 0.20), (0.30, -0.22, 0.22), (0.42, 0.02, 0.20), (0.18, 0.22, 0.21), (-0.28, 0.19, 0.20),
    ]
    faces = [(0, 4, 3, 2, 1), (5, 6, 7, 8, 9), (0, 1, 6, 5), (1, 2, 7, 6), (2, 3, 8, 7), (3, 4, 9, 8), (4, 0, 5, 9)]
    mesh_object("Raw_Meat", vertices, faces, mats["meat"])
    cylinder_between("Bone", (-0.34, 0.02, 0.23), (0.31, 0.03, 0.25), 0.055, mats["bone"], 8)
    ico("Bone_End_L", (-0.37, 0.02, 0.23), (0.10, 0.075, 0.075), mats["bone"], subdivisions=1)
    ico("Bone_End_R", (0.34, 0.03, 0.25), (0.10, 0.075, 0.075), mats["bone"], subdivisions=1)
    box("Fat_Strip", (0.02, -0.225, 0.16), (0.54, 0.035, 0.065), mats["fat"], (0.0, 0.0, -0.07), 0.015)


def add_coin(name: str, location: tuple[float, float, float], mats: dict[str, bpy.types.Material], upright: bool) -> None:
    rotation = (math.radians(90), 0.0, 0.12) if upright else (0.0, 0.0, 0.0)
    coin = cone(name, 0.18, 0.18, 0.055, location, mats["coin"], 12, rotation)
    coin.data.materials.append(mats["coin_edge"])
    cone(f"{name}_Face", 0.112, 0.112, 0.020, location, mats["coin_face"], 12, rotation)


def build_coin(mats: dict[str, bpy.types.Material]) -> None:
    add_coin("Coin", (0.0, 0.0, 0.19), mats, True)
    box("Coin_Rune", (0.0, -0.038, 0.19), (0.045, 0.018, 0.15), mats["coin_edge"], (0.0, 0.0, 0.22), 0.01)


def build_coin_stack(mats: dict[str, bpy.types.Material]) -> None:
    for index, (x, y) in enumerate(((0.0, 0.0), (0.015, -0.005), (-0.012, 0.01), (0.01, 0.0), (-0.008, -0.008))):
        add_coin(f"Coin_{index + 1}", (x, y, 0.03 + index * 0.058), mats, False)
    add_coin("Coin_Leaning", (0.23, -0.02, 0.18), mats, True)


def build_salvage(mats: dict[str, bpy.types.Material]) -> None:
    plate = box("Salvage_Plate", (0.0, 0.0, 0.18), (0.62, 0.38, 0.12), mats["salvage"], (0.05, -0.15, 0.28), 0.07)
    plate.rotation_euler[2] += 0.12
    box("Salvage_Brace", (-0.18, -0.20, 0.20), (0.12, 0.46, 0.10), mats["salvage_dark"], (0.2, -0.1, -0.38), 0.025)
    for index, location in enumerate(((-0.17, -0.205, 0.25), (0.03, -0.225, 0.29), (0.22, -0.19, 0.25))):
        ico(f"Salvage_Node_{index + 1}", location, (0.055, 0.025, 0.055), mats["salvage_glow"], subdivisions=1)
    cylinder_between("Loose_Wire", (0.22, 0.10, 0.22), (0.45, 0.24, 0.10), 0.018, mats["wire"], 6)


def set_visible(record: dict, visible: bool) -> None:
    record["root"].hide_render = not visible
    for child in record["root"].children_recursive:
        child.hide_render = not visible


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
    fill.data.energy = 1000
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
        "bark": material("MIRE_Pickup_Bark", (0.22, 0.065, 0.022, 1.0)),
        "bark_light": material("MIRE_Pickup_Bark_Light", (0.43, 0.16, 0.04, 1.0)),
        "wood": material("MIRE_Pickup_Fresh_Wood", (0.84, 0.47, 0.13, 1.0)),
        "stone": material("MIRE_Pickup_Stone", (0.34, 0.39, 0.40, 1.0)),
        "stone_light": material("MIRE_Pickup_Stone_Light", (0.53, 0.58, 0.57, 1.0)),
        "stone_dark": material("MIRE_Pickup_Stone_Dark", (0.15, 0.18, 0.20, 1.0)),
        "flint": material("MIRE_Pickup_Flint", (0.16, 0.21, 0.25, 1.0), 0.45),
        "flint_edge": material("MIRE_Pickup_Flint_Edge", (0.57, 0.68, 0.71, 1.0), 0.35),
        "iron_stone": material("MIRE_Pickup_Iron_Stone", (0.23, 0.24, 0.24, 1.0)),
        "iron": material("MIRE_Pickup_Iron_Ore", (0.74, 0.23, 0.05, 1.0), 0.55, 0.40),
        "ingot": material("MIRE_Pickup_Iron_Ingot", (0.42, 0.50, 0.53, 1.0), 0.35, 0.68),
        "ingot_dark": material("MIRE_Pickup_Ingot_Stamp", (0.12, 0.16, 0.18, 1.0), 0.42, 0.55),
        "coal": material("MIRE_Pickup_Coal", (0.025, 0.031, 0.040, 1.0), 0.48),
        "coal_glint": material("MIRE_Pickup_Coal_Glint", (0.10, 0.14, 0.19, 1.0), 0.30),
        "fibre": material("MIRE_Pickup_Fibre", (0.55, 0.48, 0.12, 1.0)),
        "fibre_light": material("MIRE_Pickup_Fibre_Light", (0.82, 0.70, 0.20, 1.0)),
        "binding": material("MIRE_Pickup_Fibre_Binding", (0.25, 0.11, 0.035, 1.0)),
        "berry": material("MIRE_Pickup_Berry", (0.62, 0.025, 0.08, 1.0)),
        "berry_light": material("MIRE_Pickup_Berry_Light", (0.93, 0.06, 0.17, 1.0)),
        "leaf": material("MIRE_Pickup_Leaf", (0.06, 0.35, 0.10, 1.0)),
        "leaf_light": material("MIRE_Pickup_Leaf_Light", (0.16, 0.58, 0.18, 1.0)),
        "stem": material("MIRE_Pickup_Stem", (0.12, 0.28, 0.06, 1.0)),
        "stem_pale": material("MIRE_Pickup_Mushroom_Stem", (0.77, 0.66, 0.46, 1.0)),
        "mushroom": material("MIRE_Pickup_Mushroom_Cap", (0.63, 0.08, 0.46, 1.0)),
        "spot": material("MIRE_Pickup_Mushroom_Spot", (0.98, 0.68, 0.89, 1.0)),
        "meat": material("MIRE_Pickup_Raw_Meat", (0.68, 0.06, 0.09, 1.0)),
        "fat": material("MIRE_Pickup_Fat", (0.95, 0.64, 0.55, 1.0)),
        "bone": material("MIRE_Pickup_Bone", (0.84, 0.79, 0.62, 1.0)),
        "coin": material("MIRE_Pickup_Coin", (1.0, 0.68, 0.04, 1.0), 0.35, 0.45),
        "coin_face": material("MIRE_Pickup_Coin_Face", (1.0, 0.88, 0.22, 1.0), 0.30, 0.50),
        "coin_edge": material("MIRE_Pickup_Coin_Edge", (0.67, 0.30, 0.018, 1.0), 0.38, 0.42),
        "salvage": material("MIRE_Pickup_Salvage", (0.22, 0.29, 0.32, 1.0), 0.38, 0.62),
        "salvage_dark": material("MIRE_Pickup_Salvage_Dark", (0.075, 0.095, 0.11, 1.0), 0.45, 0.50),
        "salvage_glow": material("MIRE_Pickup_Salvage_Glow", (0.37, 0.04, 0.65, 1.0), 0.25, 0.18, (0.65, 0.08, 1.0, 1.0), 2.2),
        "wire": material("MIRE_Pickup_Wire", (0.83, 0.22, 0.04, 1.0), 0.45, 0.45),
        "ground": material("MIRE_Pickup_Preview_Ground", (0.048, 0.085, 0.056, 1.0)),
        "scale": material("MIRE_Pickup_Scale_Reference", (0.15, 0.53, 0.78, 1.0)),
    }

    builders: list[tuple[str, str, Callable[[], None]]] = [
        ("pickup_log", "wood", lambda: build_log(mats)),
        ("pickup_branch", "wood", lambda: build_branch(mats)),
        ("pickup_stone", "mineral", lambda: build_stone(mats)),
        ("pickup_flint", "mineral", lambda: build_flint(mats)),
        ("pickup_iron_ore", "mineral", lambda: build_iron_ore(mats)),
        ("pickup_iron_ingot", "crafted", lambda: build_ingot(mats)),
        ("pickup_coal", "mineral", lambda: build_coal(mats)),
        ("pickup_fibre_bundle", "organic", lambda: build_fibre(mats)),
        ("pickup_berry", "food", lambda: build_berry(mats)),
        ("pickup_mushroom", "food", lambda: build_mushroom(mats)),
        ("pickup_raw_meat", "food", lambda: build_meat(mats)),
        ("pickup_coin", "currency", lambda: build_coin(mats)),
        ("pickup_coin_stack", "currency", lambda: build_coin_stack(mats)),
        ("pickup_salvage_fragment", "salvage", lambda: build_salvage(mats)),
    ]
    if [name for name, _, _ in builders] != EXPECTED_NAMES:
        raise RuntimeError("A-002 specification and expected export list diverged")

    records: list[dict] = []
    for index, (name, family, builder) in enumerate(builders):
        column = index % 7
        row = index // 7
        location = ((column - 3) * 2.05, (0.95 - row * 2.35), 0.0)
        records.append(create_asset(name, family, builder, location))

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
    camera.data.ortho_scale = 16.8
    camera.location = (0.0, -16.0, 10.0)
    look_at(camera, (0.0, -0.15, 0.28))
    scene.render.filepath = str(PREVIEW_DIR / "pickups_preview.png")
    bpy.ops.render.render(write_still=True)

    original_locations = {record["name"]: record["root"].location.copy() for record in records}
    showcase_positions = {
        "pickup_log": (-3.6, 0.6, 0.0),
        "pickup_iron_ore": (-1.8, 0.4, 0.0),
        "pickup_fibre_bundle": (0.0, 0.45, 0.0),
        "pickup_berry": (1.55, 0.35, 0.0),
        "pickup_coin_stack": (2.75, 0.35, 0.0),
        "pickup_salvage_fragment": (4.0, 0.40, 0.0),
    }
    for record in records:
        set_visible(record, record["name"] in showcase_positions)
        if record["name"] in showcase_positions:
            record["root"].location = showcase_positions[record["name"]]
    scale_parts = [
        box("Scale_Post", (-4.8, -0.65, 0.5), (0.10, 0.10, 1.0), mats["scale"]),
        box("Scale_Tick_20", (-4.70, -0.65, 0.20), (0.22, 0.08, 0.025), mats["scale"]),
        box("Scale_Tick_40", (-4.70, -0.65, 0.40), (0.22, 0.08, 0.025), mats["scale"]),
        box("Scale_Tick_60", (-4.70, -0.65, 0.60), (0.22, 0.08, 0.025), mats["scale"]),
        box("Scale_Tick_80", (-4.70, -0.65, 0.80), (0.22, 0.08, 0.025), mats["scale"]),
        box("Scale_Tick_100", (-4.70, -0.65, 1.00), (0.28, 0.08, 0.03), mats["scale"]),
        box("Scale_20cm_Cube", (-4.25, -0.65, 0.10), (0.20, 0.20, 0.20), mats["scale"]),
    ]
    move_to_collection(scale_parts, preview_collection)
    camera.data.ortho_scale = 12.5
    camera.location = (8.5, -12.5, 6.5)
    look_at(camera, (-0.1, 0.0, 0.35))
    scene.render.filepath = str(PREVIEW_DIR / "pickups_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    for record in records:
        record["root"].location = original_locations[record["name"]]
        set_visible(record, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "pickup_kit.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(f"Built {len(records)} A-002 pickup assets ({total_polygons} polygons total)")


if __name__ == "__main__":
    main()
