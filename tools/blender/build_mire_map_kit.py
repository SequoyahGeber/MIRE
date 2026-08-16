"""Build MIRE's original low-poly environment and construction kit.

Run with:
  Blender --background --python tools/blender/build_mire_map_kit.py

Outputs 116 individual, metre-scale GLBs, an editable Blender source file,
a machine-readable catalog, and category preview renders. All variation is
seeded so repeated builds preserve geometry and naming.
"""

from __future__ import annotations

import json
import math
import random
from pathlib import Path
from typing import Callable

import bpy
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "environment"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

CATEGORY_ORDER = ["trees", "rocks", "forest_debris", "ground_cover", "mire_growth", "ruins", "building_pieces"]
CATEGORY_PREVIEWS = {
    "trees": "trees_preview.png",
    "rocks": "rocks_preview.png",
    "forest_debris": "forest_debris_preview.png",
    "ground_cover": "ground_cover_preview.png",
    "mire_growth": "mire_growth_preview.png",
    "ruins": "ruins_preview.png",
    "building_pieces": "building_pieces_preview.png",
}
CATEGORY_TOTALS = {"trees": 18, "rocks": 18, "forest_debris": 12, "ground_cover": 16, "mire_growth": 16, "ruins": 12, "building_pieces": 24}


def material(name: str, color: tuple[float, float, float, float], roughness: float = 0.9, emission: tuple[float, float, float, float] | None = None, emission_strength: float = 0.0) -> bpy.types.Material:
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = color
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = roughness
    if emission is not None:
        shader.inputs["Emission Color"].default_value = emission
        shader.inputs["Emission Strength"].default_value = emission_strength
    return mat


def assign(obj: bpy.types.Object, mat: bpy.types.Material) -> bpy.types.Object:
    obj.data.materials.append(mat)
    for polygon in obj.data.polygons:
        polygon.use_smooth = False
    return obj


def box(name: str, location: tuple[float, float, float], dimensions: tuple[float, float, float], mat: bpy.types.Material, rotation: tuple[float, float, float] = (0.0, 0.0, 0.0)) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = (dimensions[0] * 0.5, dimensions[1] * 0.5, dimensions[2] * 0.5)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, mat)


def cylinder(name: str, radius: float, depth: float, location: tuple[float, float, float], mat: bpy.types.Material, vertices: int = 8) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=location)
    obj = bpy.context.object
    obj.name = name
    return assign(obj, mat)


def cone(name: str, radius_bottom: float, radius_top: float, depth: float, location: tuple[float, float, float], mat: bpy.types.Material, vertices: int = 8) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cone_add(vertices=vertices, radius1=radius_bottom, radius2=radius_top, depth=depth, location=location)
    obj = bpy.context.object
    obj.name = name
    return assign(obj, mat)


def ico(name: str, location: tuple[float, float, float], scale: tuple[float, float, float], mat: bpy.types.Material, rotation: tuple[float, float, float] = (0.0, 0.0, 0.0)) -> bpy.types.Object:
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=1.0, location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, mat)


def cylinder_between(name: str, start: tuple[float, float, float], end: tuple[float, float, float], radius: float, mat: bpy.types.Material, vertices: int = 7) -> bpy.types.Object:
    a = Vector(start)
    b = Vector(end)
    direction = b - a
    obj = cylinder(name, radius, direction.length, tuple((a + b) * 0.5), mat, vertices)
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = direction.to_track_quat("Z", "Y")
    return obj


def mesh_object(name: str, vertices: list[tuple[float, float, float]], faces: list[tuple[int, ...]], mat: bpy.types.Material) -> bpy.types.Object:
    mesh = bpy.data.meshes.new(f"{name}_Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return assign(obj, mat)


def roof_wedge(name: str, width: float, depth: float, rise: float, mat: bpy.types.Material) -> bpy.types.Object:
    vertices = [(-width / 2, -depth / 2, 0.0), (width / 2, -depth / 2, 0.0), (-width / 2, depth / 2, 0.0), (width / 2, depth / 2, 0.0), (-width / 2, depth / 2, rise), (width / 2, depth / 2, rise)]
    faces = [(0, 2, 3, 1), (2, 4, 5, 3), (0, 1, 5, 4), (0, 4, 2), (1, 3, 5)]
    return mesh_object(name, vertices, faces, mat)


def hip_roof(name: str, width: float, depth: float, rise: float, mat: bpy.types.Material) -> bpy.types.Object:
    vertices = [(-width / 2, -depth / 2, 0.0), (width / 2, -depth / 2, 0.0), (width / 2, depth / 2, 0.0), (-width / 2, depth / 2, 0.0), (0.0, 0.0, rise)]
    faces = [(0, 3, 2, 1), (0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4)]
    return mesh_object(name, vertices, faces, mat)


def look_at(obj: bpy.types.Object, target: tuple[float, float, float]) -> None:
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def seed_for(name: str) -> int:
    return sum((index + 1) * ord(char) for index, char in enumerate(name))


def create_asset(name: str, category: str, build_fn: Callable[[], None], display_location: tuple[float, float, float]) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)
    before = set(bpy.data.objects)
    build_fn()
    made = [obj for obj in bpy.data.objects if obj not in before]
    for obj in made:
        for old_collection in list(obj.users_collection):
            old_collection.objects.unlink(obj)
        collection.objects.link(obj)
        obj.parent = root
    bpy.context.view_layer.update()
    corners: list[Vector] = []
    for obj in made:
        if obj.type == "MESH":
            corners.extend(obj.matrix_world @ Vector(corner) for corner in obj.bound_box)
    minimum = Vector((min(v.x for v in corners), min(v.y for v in corners), min(v.z for v in corners)))
    maximum = Vector((max(v.x for v in corners), max(v.y for v in corners), max(v.z for v in corners)))
    dimensions = maximum - minimum
    polygon_count = sum(len(obj.data.polygons) for obj in made if obj.type == "MESH")
    materials = sorted({mat.name for obj in made if obj.type == "MESH" for mat in obj.data.materials if mat})
    bpy.ops.object.select_all(action="DESELECT")
    for obj in collection.objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = root
    bpy.ops.export_scene.gltf(filepath=str(EXPORT_DIR / f"{name}.glb"), export_format="GLB", use_selection=True, export_apply=True, export_yup=True)
    root.location = display_location
    return {"name": name, "category": category, "root": root, "width": dimensions.x, "depth": dimensions.y, "height": dimensions.z, "parts": sum(1 for obj in made if obj.type == "MESH"), "polygons": polygon_count, "materials": materials}


def main() -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)

    mats = {
        "bark": material("MIRE_Bark", (0.18, 0.065, 0.025, 1.0)), "bark_light": material("MIRE_Bark_Light", (0.37, 0.15, 0.05, 1.0)), "cut": material("MIRE_Cut_Wood", (0.72, 0.40, 0.13, 1.0)),
        "birch": material("MIRE_Birch", (0.72, 0.74, 0.64, 1.0)), "birch_dark": material("MIRE_Birch_Mark", (0.12, 0.14, 0.12, 1.0)),
        "pine_dark": material("MIRE_Pine_Dark", (0.02, 0.20, 0.10, 1.0)), "pine_mid": material("MIRE_Pine_Mid", (0.03, 0.36, 0.17, 1.0)), "pine_tip": material("MIRE_Pine_Tip", (0.10, 0.55, 0.24, 1.0)),
        "leaf": material("MIRE_Leaf", (0.10, 0.43, 0.13, 1.0)), "leaf_light": material("MIRE_Leaf_Light", (0.30, 0.62, 0.17, 1.0)), "leaf_gold": material("MIRE_Leaf_Gold", (0.66, 0.43, 0.08, 1.0)),
        "stone": material("MIRE_Stone", (0.22, 0.27, 0.29, 1.0)), "stone_light": material("MIRE_Stone_Light", (0.41, 0.47, 0.45, 1.0)), "stone_dark": material("MIRE_Stone_Dark", (0.10, 0.13, 0.15, 1.0)),
        "moss": material("MIRE_Moss", (0.12, 0.35, 0.09, 1.0)), "grass": material("MIRE_Grass", (0.15, 0.46, 0.16, 1.0)), "grass_light": material("MIRE_Grass_Light", (0.37, 0.67, 0.18, 1.0)),
        "reed": material("MIRE_Reed", (0.38, 0.52, 0.12, 1.0)), "cattail": material("MIRE_Cattail", (0.29, 0.10, 0.03, 1.0)),
        "mushroom": material("MIRE_Mushroom", (0.67, 0.14, 0.55, 1.0)), "mushroom_blue": material("MIRE_Mushroom_Blue", (0.16, 0.40, 0.71, 1.0)), "mushroom_spot": material("MIRE_Mushroom_Spot", (0.95, 0.68, 0.92, 1.0)),
        "mire": material("MIRE_Corruption", (0.11, 0.018, 0.17, 1.0)), "mire_mid": material("MIRE_Corruption_Mid", (0.31, 0.045, 0.43, 1.0)),
        "crystal": material("MIRE_Crystal", (0.27, 0.08, 0.52, 1.0), 0.35, (0.50, 0.09, 0.90, 1.0), 1.8), "crystal_tip": material("MIRE_Crystal_Tip", (0.55, 0.20, 0.88, 1.0), 0.25, (0.72, 0.22, 1.0, 1.0), 2.2),
        "ruin": material("MIRE_Ruin_Stone", (0.36, 0.37, 0.32, 1.0)), "rune": material("MIRE_Rune", (0.31, 0.11, 0.48, 1.0), 0.5, (0.52, 0.12, 0.79, 1.0), 1.2),
        "wood_build": material("MIRE_Build_Wood", (0.34, 0.14, 0.045, 1.0)), "wood_build_light": material("MIRE_Build_Wood_Light", (0.53, 0.25, 0.075, 1.0)), "roof": material("MIRE_Wood_Roof", (0.20, 0.07, 0.035, 1.0)),
        "stone_build": material("MIRE_Build_Stone", (0.33, 0.36, 0.35, 1.0)), "ground": material("MIRE_Preview_Ground", (0.075, 0.12, 0.065, 1.0)),
    }

    def build_pine(seed: int) -> None:
        rng = random.Random(seed); height = rng.uniform(4.3, 6.3); lean = (rng.uniform(-0.22, 0.22), rng.uniform(-0.22, 0.22))
        cylinder_between("Trunk", (0, 0, 0), (lean[0], lean[1], height * 0.76), rng.uniform(0.23, 0.39), mats["bark"], 8)
        tiers = rng.randint(3, 5)
        for index in range(tiers):
            t = index / max(1, tiers - 1); z = height * (0.42 + t * 0.45); radius = (1.72 - 1.12 * t) * rng.uniform(0.90, 1.12); depth = rng.uniform(1.25, 1.75)
            foliage = cone(f"Foliage_{index + 1}", radius, max(0.03, radius * 0.08), depth, (lean[0] * z / height, lean[1] * z / height, z), [mats["pine_dark"], mats["pine_mid"], mats["pine_tip"]][min(2, int(t * 3))], rng.randint(7, 10)); foliage.rotation_euler[2] = rng.uniform(0, math.tau)

    def build_bare(seed: int) -> None:
        rng = random.Random(seed); height = rng.uniform(4.1, 6.0); top = (rng.uniform(-0.35, 0.35), rng.uniform(-0.25, 0.25), height)
        trunk = cone("Trunk", rng.uniform(0.38, 0.52), rng.uniform(0.14, 0.23), height, (top[0] * 0.5, top[1] * 0.5, height * 0.5), mats["bark_light"], 7); trunk.rotation_euler[1] = -top[0] / height
        for index in range(rng.randint(4, 7)):
            side = -1 if index % 2 == 0 else 1; start_z = rng.uniform(height * 0.48, height * 0.83); angle = rng.uniform(-0.5, 0.5); length = rng.uniform(1.0, 2.0)
            start = (top[0] * start_z / height, top[1] * start_z / height, start_z); end = (start[0] + side * math.cos(angle) * length, start[1] + math.sin(angle) * length * 0.45, start_z + rng.uniform(0.7, 1.45))
            cylinder_between(f"Branch_{index + 1}", start, end, rng.uniform(0.075, 0.15), mats["bark_light"], 6)

    def build_birch(seed: int) -> None:
        rng = random.Random(seed); height = rng.uniform(4.8, 6.6); lean_x = rng.uniform(-0.28, 0.28)
        cylinder_between("Trunk", (0, 0, 0), (lean_x, 0, height), rng.uniform(0.18, 0.27), mats["birch"], 8)
        for index in range(4):
            z = height * (0.20 + index * 0.17); cylinder(f"Bark_Mark_{index + 1}", 0.285, 0.055, (lean_x * z / height, 0, z), mats["birch_dark"], 8)
        crown_mat = mats["leaf_light"] if seed % 2 == 0 else mats["leaf_gold"]
        for index in range(rng.randint(4, 6)):
            angle = index / 5 * math.tau + rng.uniform(-0.3, 0.3); radius = rng.uniform(0.35, 0.85); z = rng.uniform(height * 0.67, height * 0.98)
            ico(f"Crown_{index + 1}", (lean_x + math.cos(angle) * radius, math.sin(angle) * radius, z), (rng.uniform(0.65, 1.05), rng.uniform(0.55, 0.9), rng.uniform(0.55, 0.9)), crown_mat, (rng.random(), rng.random(), rng.random()))

    def build_crooked(seed: int) -> None:
        rng = random.Random(seed); points = [(0.0, 0.0, 0.0)]
        for index in range(1, 4): points.append((points[-1][0] + rng.uniform(-0.65, 0.65), points[-1][1] + rng.uniform(-0.28, 0.28), index * rng.uniform(1.25, 1.55)))
        for index in range(3): cylinder_between(f"Trunk_{index + 1}", points[index], points[index + 1], 0.34 - index * 0.065, mats["bark"], 7)
        leaf_mat = mats["leaf_gold"] if seed % 3 == 0 else mats["leaf"]
        for index in range(rng.randint(3, 5)):
            anchor = points[-1]; ico(f"Crown_{index + 1}", (anchor[0] + rng.uniform(-1, 1), anchor[1] + rng.uniform(-0.8, 0.8), anchor[2] + rng.uniform(-0.2, 1)), (rng.uniform(0.7, 1.2), rng.uniform(0.6, 1), rng.uniform(0.55, 0.95)), leaf_mat, (rng.random(), rng.random(), rng.random()))

    def build_boulder(seed: int) -> None:
        rng = random.Random(seed); sx, sy, sz = rng.uniform(0.9, 1.8), rng.uniform(0.75, 1.5), rng.uniform(0.65, 1.4)
        ico("Boulder", (0, 0, sz * 0.72), (sx, sy, sz), mats["stone"], (rng.uniform(-0.4, 0.4), rng.uniform(-0.4, 0.4), rng.uniform(0, math.tau)))
        if seed % 2 == 0: ico("Face", (-sx * 0.25, -sy * 0.55, sz * 0.85), (sx * 0.35, sy * 0.16, sz * 0.24), mats["stone_light"], (rng.random(), rng.random(), rng.random()))
        if seed % 3 == 0: ico("Moss", (sx * 0.12, -sy * 0.42, sz * 1.36), (sx * 0.48, sy * 0.16, 0.09), mats["moss"])

    def build_rock_cluster(seed: int) -> None:
        rng = random.Random(seed)
        for index in range(rng.randint(3, 6)):
            size = rng.uniform(0.32, 0.82); angle = rng.uniform(0, math.tau); distance = rng.uniform(0.05, 0.85)
            ico(f"Rock_{index + 1}", (math.cos(angle) * distance, math.sin(angle) * distance, size * 0.65), (size * rng.uniform(0.8, 1.25), size * rng.uniform(0.7, 1.1), size), mats["stone_light"] if index % 3 == 1 else mats["stone"], (rng.random(), rng.random(), rng.random()))

    def build_standing_stone(seed: int) -> None:
        rng = random.Random(seed); height = rng.uniform(2.1, 3.8)
        cone("Monolith", rng.uniform(0.62, 0.95), rng.uniform(0.28, 0.50), height, (0, 0, height * 0.5), mats["stone_dark"], rng.randint(5, 7))
        box("Rune", (0, -0.64, height * 0.57), (0.12, 0.035, height * 0.35), mats["rune"], (0, 0, rng.uniform(-0.35, 0.35)))
        for index in range(rng.randint(2, 4)):
            size = rng.uniform(0.20, 0.38); ico(f"Foot_Rock_{index + 1}", (rng.uniform(-0.75, 0.75), rng.uniform(-0.55, 0.55), size * 0.5), (size, size * 0.8, size * 0.65), mats["stone"])

    def build_stump(seed: int) -> None:
        rng = random.Random(seed); height = rng.uniform(0.65, 1.35); radius = rng.uniform(0.38, 0.67)
        cone("Stump", radius, radius * rng.uniform(0.72, 0.88), height, (0, 0, height * 0.5), mats["bark"], rng.randint(7, 10)); cylinder("Cut", radius * 0.78, 0.035, (0, 0, height + 0.015), mats["cut"], 9)
        for index in range(rng.randint(3, 5)):
            angle = index / 4 * math.tau + rng.uniform(-0.4, 0.4); cylinder_between(f"Root_{index + 1}", (math.cos(angle) * radius * 0.2, math.sin(angle) * radius * 0.2, 0.20), (math.cos(angle) * rng.uniform(0.7, 1.2), math.sin(angle) * rng.uniform(0.7, 1.2), 0.05), rng.uniform(0.09, 0.16), mats["bark"], 7)

    def build_fallen_log(seed: int) -> None:
        rng = random.Random(seed); length = rng.uniform(2.6, 4.5); radius = rng.uniform(0.28, 0.48)
        cylinder_between("Log", (-length * 0.5, 0, radius), (length * 0.5, rng.uniform(-0.22, 0.22), radius), radius, mats["bark"], rng.randint(7, 10)); cylinder_between("Cut", (-length * 0.51, 0, radius), (-length * 0.50, 0, radius), radius * 0.86, mats["cut"], 9)
        for index in range(rng.randint(1, 3)):
            x = rng.uniform(-length * 0.25, length * 0.35); cylinder_between(f"Branch_{index + 1}", (x, 0, radius * 1.4), (x + rng.uniform(0.25, 0.65), rng.choice([-1, 1]) * rng.uniform(0.45, 0.85), radius + rng.uniform(0.35, 0.8)), 0.08, mats["bark"], 6)
        ico("Moss", (rng.uniform(-0.5, 0.5), -radius * 0.72, radius * 1.55), (length * 0.22, radius * 0.22, 0.10), mats["moss"])

    def build_root_cluster(seed: int) -> None:
        rng = random.Random(seed); ico("Root_Knot", (0, 0, 0.28), (0.52, 0.44, 0.38), mats["bark"], (rng.random(), rng.random(), rng.random())); count = rng.randint(5, 8)
        for index in range(count):
            angle = index / count * math.tau + rng.uniform(-0.2, 0.2); length = rng.uniform(0.8, 1.65); start = (math.cos(angle) * 0.18, math.sin(angle) * 0.18, 0.24); middle = (math.cos(angle) * length * 0.55, math.sin(angle) * length * 0.55, rng.uniform(0.10, 0.26)); end = (math.cos(angle) * length, math.sin(angle) * length, 0.035)
            cylinder_between(f"Root_{index + 1}_A", start, middle, rng.uniform(0.09, 0.16), mats["bark"], 6); cylinder_between(f"Root_{index + 1}_B", middle, end, rng.uniform(0.045, 0.09), mats["bark"], 6)

    def build_grass(seed: int) -> None:
        rng = random.Random(seed)
        for index in range(rng.randint(6, 11)):
            angle = rng.uniform(0, math.tau); distance = rng.uniform(0, 0.48); height = rng.uniform(0.42, 1.18); blade = cone(f"Blade_{index + 1}", rng.uniform(0.07, 0.13), 0.01, height, (math.cos(angle) * distance, math.sin(angle) * distance, height * 0.5), mats["grass_light"] if index % 3 == 0 else mats["grass"], 4); blade.rotation_euler[1] = rng.uniform(-0.15, 0.15)

    def build_fern(seed: int) -> None:
        rng = random.Random(seed); fronds = rng.randint(5, 8)
        for index in range(fronds):
            angle = index / fronds * math.tau + rng.uniform(-0.2, 0.2); length = rng.uniform(0.75, 1.35); end = (math.cos(angle) * length, math.sin(angle) * length, rng.uniform(0.25, 0.55)); cylinder_between(f"Stem_{index + 1}", (0, 0, 0.12), end, 0.025, mats["grass"], 5)
            for leaf_index in range(3):
                t = 0.35 + leaf_index * 0.22; pos = (end[0] * t, end[1] * t, 0.12 + (end[2] - 0.12) * t); leaf = ico(f"Leaf_{index + 1}_{leaf_index + 1}", pos, (0.22, 0.055, 0.055), mats["leaf_light"] if leaf_index == 2 else mats["leaf"]); leaf.rotation_euler[2] = angle

    def build_reeds(seed: int) -> None:
        rng = random.Random(seed)
        for index in range(rng.randint(5, 9)):
            angle = rng.uniform(0, math.tau); distance = rng.uniform(0, 0.55); height = rng.uniform(1, 2); x, y = math.cos(angle) * distance, math.sin(angle) * distance; cylinder(f"Reed_{index + 1}", 0.025, height, (x, y, height * 0.5), mats["reed"], 6)
            if index % 2 == 0: cylinder(f"Cattail_{index + 1}", 0.075, 0.32, (x, y, height - 0.18), mats["cattail"], 7)

    def build_mushrooms(seed: int) -> None:
        rng = random.Random(seed); count = rng.randint(3, 8)
        for index in range(count):
            angle = rng.uniform(0, math.tau); distance = rng.uniform(0, 0.72); height = rng.uniform(0.28, 0.95); cap_radius = rng.uniform(0.14, 0.36); x, y = math.cos(angle) * distance, math.sin(angle) * distance
            cylinder(f"Stem_{index + 1}", 0.045 + cap_radius * 0.10, height, (x, y, height * 0.5), mats["cut"], 7); ico(f"Cap_{index + 1}", (x, y, height), (cap_radius, cap_radius, cap_radius * rng.uniform(0.35, 0.58)), mats["mushroom_blue"] if seed % 3 == 0 else mats["mushroom"], (rng.random(), rng.random(), rng.random()))
            if index == 0: ico("Cap_Spot", (x - cap_radius * 0.3, y - cap_radius * 0.2, height + cap_radius * 0.35), (0.045, 0.045, 0.02), mats["mushroom_spot"])
        ico("Mire_Growth", (0, 0, 0.055), (0.95, 0.70, 0.08), mats["mire"])

    def build_crystals(seed: int) -> None:
        rng = random.Random(seed); count = rng.randint(4, 8)
        for index in range(count):
            angle = index / count * math.tau + rng.uniform(-0.35, 0.35); distance = rng.uniform(0.05, 0.55); height = rng.uniform(0.55, 2); crystal = cone(f"Crystal_{index + 1}", rng.uniform(0.12, 0.28), rng.uniform(0.015, 0.055), height, (math.cos(angle) * distance, math.sin(angle) * distance, height * 0.5), mats["crystal_tip"] if index == 0 else mats["crystal"], rng.randint(5, 7)); crystal.rotation_euler[1] = rng.uniform(-0.22, 0.22)
        ico("Mire_Base", (0, 0, 0.07), (0.92, 0.72, 0.10), mats["mire_mid"])

    def build_tendrils(seed: int) -> None:
        rng = random.Random(seed); count = rng.randint(3, 6)
        for index in range(count):
            height = rng.uniform(0.9, 2.2); radius = rng.uniform(0.25, 0.55); phase = index / count * math.tau; points = [(math.cos(phase + step / 4 * 1.4) * radius * (1 - step / 4 * 0.45), math.sin(phase + step / 4 * 1.4) * radius * (1 - step / 4 * 0.45), step / 4 * height) for step in range(5)]
            for step in range(4): cylinder_between(f"Tendril_{index + 1}_{step + 1}", points[step], points[step + 1], 0.07 - step * 0.011, mats["mire_mid"], 6)
            ico(f"Bud_{index + 1}", points[-1], (0.13, 0.13, 0.18), mats["crystal_tip"])
        ico("Mire_Base", (0, 0, 0.055), (0.84, 0.68, 0.08), mats["mire"])

    def build_ruin_wall(seed: int) -> None:
        rng = random.Random(seed)
        for row in range(4):
            for column in range(6):
                if row >= 2 and rng.random() < 0.24 + row * 0.08: continue
                x = (column - 2.5) * 0.72 + (row % 2) * 0.18; z = 0.32 + row * 0.61; box(f"Block_{row}_{column}", (x, rng.uniform(-0.05, 0.05), z), (0.68, 0.58, 0.56), mats["ruin"] if (row + column) % 3 else mats["stone_light"], (rng.uniform(-0.03, 0.03), rng.uniform(-0.03, 0.03), rng.uniform(-0.04, 0.04)))
        ico("Moss", (rng.uniform(-1, 1), -0.34, rng.uniform(0.35, 1.4)), (0.65, 0.12, 0.22), mats["moss"])

    def build_ruin_column(seed: int) -> None:
        rng = random.Random(seed); height = rng.uniform(2.3, 4); box("Base", (0, 0, 0.18), (1.10, 1.10, 0.36), mats["ruin"]); segments = rng.randint(3, 5); segment_h = (height - 0.5) / segments
        for index in range(segments): box(f"Shaft_{index + 1}", (rng.uniform(-0.04, 0.04), rng.uniform(-0.04, 0.04), 0.36 + segment_h * (index + 0.5)), (0.72, 0.72, segment_h * 0.92), mats["ruin"] if index % 2 == 0 else mats["stone_light"], (rng.uniform(-0.025, 0.025), rng.uniform(-0.025, 0.025), rng.uniform(-0.04, 0.04)))
        if seed % 2 == 0: box("Capital", (0, 0, height), (1, 1, 0.28), mats["ruin"])

    def build_ruin_arch(seed: int) -> None:
        rng = random.Random(seed)
        for side in (-1, 1):
            for row in range(5): box(f"Pillar_{side}_{row}", (side * 1.35, 0, 0.30 + row * 0.58), (0.72, 0.72, 0.54), mats["ruin"] if row % 2 else mats["stone_light"], (0, rng.uniform(-0.03, 0.03), rng.uniform(-0.04, 0.04)))
        for index, angle in enumerate((-0.48, -0.16, 0.16, 0.48)): box(f"Arch_{index + 1}", ((index - 1.5) * 0.66, 0, 3.05 - abs(index - 1.5) * 0.12), (0.72, 0.75, 0.58), mats["ruin"], (0, angle * 0.18, angle))

    def build_marker(seed: int) -> None:
        rng = random.Random(seed); box("Base", (0, 0, 0.16), (1.35, 0.85, 0.32), mats["ruin"]); box("Marker", (0, 0, 1.45), (0.78, 0.42, 2.65), mats["stone_dark"], (0, rng.uniform(-0.08, 0.08), rng.uniform(-0.09, 0.09))); box("Rune_V", (0, -0.225, 1.45), (0.11, 0.035, 1.10), mats["rune"], (0, 0, rng.uniform(-0.3, 0.3))); box("Rune_H", (0, -0.225, 1.45), (0.70, 0.035, 0.10), mats["rune"], (0, 0, rng.uniform(-0.18, 0.18)))

    def wood_planks(prefix: str, z: float, height: float, skip: set[int] | None = None) -> None:
        for index in range(8):
            if index in (skip or set()): continue
            box(f"{prefix}_{index + 1}", (-1.75 + index * 0.5, 0, z), (0.46, 0.24, height), mats["wood_build_light"] if index % 3 == 0 else mats["wood_build"], (0, 0, (index % 2 - 0.5) * 0.012))

    def build_wood_foundation() -> None:
        for axis in (-1.75, -0.58, 0.58, 1.75): box(f"Beam_X_{axis}", (0, axis, 0.20), (4, 0.28, 0.40), mats["wood_build"]); box(f"Beam_Y_{axis}", (axis, 0, 0.20), (0.28, 4, 0.40), mats["wood_build_light"])
    def build_wood_floor() -> None:
        for index in range(8): box(f"Floor_{index + 1}", (-1.75 + index * 0.5, 0, 0.12), (0.46, 4, 0.24), mats["wood_build_light"] if index % 3 == 0 else mats["wood_build"])
    def build_wood_wall_solid() -> None: wood_planks("Wall", 1.5, 3); box("Top_Beam", (0, -0.04, 2.87), (4.2, 0.32, 0.26), mats["wood_build"]); box("Bottom_Beam", (0, -0.04, 0.13), (4.2, 0.32, 0.26), mats["wood_build"])
    def build_wood_wall_window() -> None: wood_planks("Wall", 1.5, 3, {3, 4}); box("Window_Sill", (0, -0.02, 0.88), (1.15, 0.34, 0.22), mats["wood_build_light"]); box("Window_Header", (0, -0.02, 2.20), (1.15, 0.34, 0.22), mats["wood_build_light"]); box("Window_Left", (-0.58, -0.02, 1.54), (0.20, 0.34, 1.52), mats["wood_build"]); box("Window_Right", (0.58, -0.02, 1.54), (0.20, 0.34, 1.52), mats["wood_build"])
    def build_wood_wall_door() -> None: wood_planks("Wall", 1.5, 3, {3, 4}); box("Door_Header", (0, -0.02, 2.72), (1.30, 0.36, 0.28), mats["wood_build_light"]); box("Door_Left", (-0.67, -0.02, 1.35), (0.22, 0.36, 2.70), mats["wood_build"]); box("Door_Right", (0.67, -0.02, 1.35), (0.22, 0.36, 2.70), mats["wood_build"])
    def build_wood_half_wall() -> None: wood_planks("Half_Wall", 0.75, 1.5); box("Cap", (0, -0.03, 1.52), (4.2, 0.34, 0.22), mats["wood_build_light"])
    def build_wood_roof_slope() -> None: roof_wedge("Roof", 4.2, 4.2, 2, mats["roof"])
    def build_wood_roof_corner() -> None: hip_roof("Hip_Roof", 4.2, 4.2, 2, mats["roof"])
    def build_wood_stairs() -> None:
        for index in range(8): box(f"Step_{index + 1}", (0, -1.75 + index * 0.5, 0.19 + index * 0.19), (2, 0.52, 0.38), mats["wood_build_light"] if index % 2 else mats["wood_build"])
        for side in (-0.9, 0.9): cylinder_between(f"Stringer_{side}", (side, -2, 0.15), (side, 2, 1.65), 0.10, mats["wood_build"], 6)
    def build_wood_beam() -> None: box("Beam", (0, 0, 0.18), (4, 0.36, 0.36), mats["wood_build"])
    def build_wood_post() -> None: box("Post", (0, 0, 1.5), (0.38, 0.38, 3), mats["wood_build"]); box("Foot", (0, 0, 0.12), (0.62, 0.62, 0.24), mats["wood_build_light"])
    def build_wood_railing() -> None:
        for x in (-1.9, -0.95, 0, 0.95, 1.9): box(f"Post_{x}", (x, 0, 0.62), (0.16, 0.18, 1.24), mats["wood_build"])
        box("Rail_Top", (0, 0, 1.18), (4.1, 0.22, 0.18), mats["wood_build_light"]); box("Rail_Mid", (0, 0, 0.52), (4.1, 0.18, 0.15), mats["wood_build"])

    def stone_block_wall(mode: str) -> None:
        for row in range(5):
            for column in range(8):
                if mode == "window" and 2 <= column <= 5 and 1 <= row <= 3: continue
                if mode == "door" and 2 <= column <= 5 and row <= 3: continue
                box(f"Stone_{row}_{column}", (-1.75 + column * 0.50 + (row % 2) * 0.12, 0, 0.30 + row * 0.60), (0.47, 0.46, 0.55), mats["stone_build"] if (row + column) % 3 else mats["stone_light"])
    def build_stone_foundation() -> None:
        for row in range(2):
            for x in range(4):
                for y in range(4): box(f"Block_{row}_{x}_{y}", (-1.5 + x, -1.5 + y, 0.22 + row * 0.38), (0.94, 0.94, 0.34), mats["stone_build"] if (x + y + row) % 3 else mats["stone_light"])
    def build_stone_floor() -> None:
        for x in range(4):
            for y in range(4): box(f"Tile_{x}_{y}", (-1.5 + x, -1.5 + y, 0.12), (0.94, 0.94, 0.24), mats["stone_build"] if (x + y) % 3 else mats["stone_light"])
    def build_stone_solid() -> None: stone_block_wall("solid")
    def build_stone_window() -> None: stone_block_wall("window"); box("Sill", (0.12, -0.02, 0.88), (2, 0.58, 0.24), mats["stone_light"]); box("Lintel", (0.12, -0.02, 2.48), (2, 0.58, 0.28), mats["stone_light"])
    def build_stone_door() -> None: stone_block_wall("door"); box("Lintel", (0.12, -0.02, 2.72), (2.1, 0.62, 0.30), mats["stone_light"])
    def build_stone_half() -> None:
        for row in range(3):
            for column in range(8): box(f"Stone_{row}_{column}", (-1.75 + column * 0.50 + (row % 2) * 0.12, 0, 0.28 + row * 0.55), (0.47, 0.46, 0.50), mats["stone_build"] if (row + column) % 3 else mats["stone_light"])
    def build_stone_stairs() -> None:
        for index in range(8): box(f"Step_{index + 1}", (0, -1.75 + index * 0.5, 0.18 + index * 0.20), (2.2, 0.54, 0.36), mats["stone_build"] if index % 3 else mats["stone_light"])
    def build_stone_pillar() -> None:
        box("Base", (0, 0, 0.18), (0.90, 0.90, 0.36), mats["stone_light"])
        for index in range(5): box(f"Pillar_{index + 1}", (0, 0, 0.55 + index * 0.54), (0.62, 0.62, 0.50), mats["stone_build"] if index % 2 else mats["stone_light"])
        box("Cap", (0, 0, 3), (0.90, 0.90, 0.30), mats["stone_light"])
    def build_fence_straight() -> None:
        for x in (-2, 0, 2): box(f"Post_{x}", (x, 0, 0.78), (0.24, 0.24, 1.56), mats["wood_build"])
        box("Rail_Low", (0, 0, 0.48), (4.2, 0.18, 0.18), mats["wood_build_light"]); box("Rail_High", (0, 0, 1.08), (4.2, 0.18, 0.18), mats["wood_build_light"])
    def build_fence_corner() -> None:
        build_fence_straight()
        for y in (1, 2): box(f"Corner_Post_{y}", (2, y, 0.78), (0.24, 0.24, 1.56), mats["wood_build"])
        for z in (0.48, 1.08): box(f"Corner_Rail_{z}", (2, 1, z), (0.18, 2.1, 0.18), mats["wood_build_light"])
    def build_fence_gate() -> None:
        for x in (-2, 2): box(f"Post_{x}", (x, 0, 0.92), (0.30, 0.30, 1.84), mats["wood_build"])
        for z in (0.48, 1.10): box(f"Gate_Rail_{z}", (0, 0.02, z), (3.65, 0.18, 0.18), mats["wood_build_light"])
        box("Gate_Brace", (0, 0.04, 0.80), (3.65, 0.16, 0.16), mats["wood_build"], (0, 0, 0.30))
    def build_fence_post() -> None: box("Post", (0, 0, 0.90), (0.34, 0.34, 1.80), mats["wood_build"]); cone("Post_Cap", 0.28, 0.02, 0.38, (0, 0, 1.99), mats["wood_build_light"], 4)

    specs: list[tuple[str, str, Callable[[], None]]] = []
    def add_seeded(names: list[str], category: str, builder: Callable[[int], None]) -> None:
        for asset_name in names: specs.append((asset_name, category, lambda name=asset_name, fn=builder: fn(seed_for(name))))
    add_seeded([f"tree_pine_{x}" for x in "abcdef"], "trees", build_pine); add_seeded([f"tree_bare_{x}" for x in "abcd"], "trees", build_bare); add_seeded([f"tree_birch_{x}" for x in "abcd"], "trees", build_birch); add_seeded([f"tree_crooked_{x}" for x in "abcd"], "trees", build_crooked)
    add_seeded([f"boulder_{x}" for x in "abcdefgh"], "rocks", build_boulder); add_seeded([f"rock_cluster_{x}" for x in "abcdef"], "rocks", build_rock_cluster); add_seeded([f"standing_stone_{x}" for x in "abcd"], "rocks", build_standing_stone)
    add_seeded([f"stump_{x}" for x in "abcd"], "forest_debris", build_stump); add_seeded([f"fallen_log_{x}" for x in "abcd"], "forest_debris", build_fallen_log); add_seeded([f"root_cluster_{x}" for x in "abcd"], "forest_debris", build_root_cluster)
    add_seeded([f"grass_clump_{x}" for x in "abcdef"], "ground_cover", build_grass); add_seeded([f"fern_{x}" for x in "abcdef"], "ground_cover", build_fern); add_seeded([f"reeds_{x}" for x in "abcd"], "ground_cover", build_reeds)
    add_seeded([f"mushroom_cluster_{x}" for x in "abcdef"], "mire_growth", build_mushrooms); add_seeded([f"mire_crystal_{x}" for x in "abcdef"], "mire_growth", build_crystals); add_seeded([f"mire_tendril_{x}" for x in "abcd"], "mire_growth", build_tendrils)
    add_seeded([f"ruin_wall_{x}" for x in "abcd"], "ruins", build_ruin_wall); add_seeded([f"ruin_column_{x}" for x in "abcd"], "ruins", build_ruin_column); add_seeded([f"ruin_arch_{x}" for x in "ab"], "ruins", build_ruin_arch); add_seeded([f"stone_marker_{x}" for x in "ab"], "ruins", build_marker)
    building_specs = [("wood_foundation", build_wood_foundation), ("wood_floor", build_wood_floor), ("wood_wall_solid", build_wood_wall_solid), ("wood_wall_window", build_wood_wall_window), ("wood_wall_door", build_wood_wall_door), ("wood_half_wall", build_wood_half_wall), ("wood_roof_slope", build_wood_roof_slope), ("wood_roof_corner", build_wood_roof_corner), ("wood_stairs", build_wood_stairs), ("wood_beam", build_wood_beam), ("wood_post", build_wood_post), ("wood_railing", build_wood_railing), ("stone_foundation", build_stone_foundation), ("stone_floor", build_stone_floor), ("stone_wall_solid", build_stone_solid), ("stone_wall_window", build_stone_window), ("stone_wall_door", build_stone_door), ("stone_half_wall", build_stone_half), ("stone_stairs", build_stone_stairs), ("stone_pillar", build_stone_pillar), ("fence_straight", build_fence_straight), ("fence_corner", build_fence_corner), ("fence_gate", build_fence_gate), ("fence_post", build_fence_post)]
    specs.extend((name, "building_pieces", builder) for name, builder in building_specs)
    if len(specs) != 116: raise RuntimeError(f"Catalog must contain 116 assets, found {len(specs)}")
    if len({name for name, _, _ in specs}) != len(specs): raise RuntimeError("Asset names must be unique")

    counters = {category: 0 for category in CATEGORY_ORDER}; records: list[dict] = []
    for name, category, builder in specs:
        index = counters[category]; counters[category] += 1; columns = 6; rows = math.ceil(CATEGORY_TOTALS[category] / columns); column = index % columns; row = index // columns; category_y = CATEGORY_ORDER.index(category) * 38.0; location = ((column - 2.5) * 5.5, category_y + (row - (rows - 1) * 0.5) * 6.0, 0.0)
        records.append(create_asset(name, category, builder, location))
    catalog = [{"name": r["name"], "category": r["category"], "width_m": round(r["width"], 3), "depth_m": round(r["depth"], 3), "height_m": round(r["height"], 3), "mesh_parts": r["parts"], "polygons": r["polygons"], "materials": r["materials"]} for r in records]
    with (ASSET_DIR / "catalog.json").open("w", encoding="utf-8") as handle:
        json.dump(catalog, handle, indent=2)
        handle.write("\n")

    preview_collection = bpy.data.collections.new("PREVIEW_ONLY"); bpy.context.scene.collection.children.link(preview_collection); bpy.ops.mesh.primitive_plane_add(size=320, location=(0, 114, -0.04)); plane = bpy.context.object; plane.name = "Preview_Ground"; assign(plane, mats["ground"])
    for old in list(plane.users_collection): old.objects.unlink(plane)
    preview_collection.objects.link(plane)
    bpy.ops.object.light_add(type="SUN", location=(0, 0, 80)); sun = bpy.context.object; sun.name = "Preview_Sun"; sun.rotation_euler = (math.radians(34), math.radians(-22), math.radians(-28)); sun.data.energy = 2.4; sun.data.angle = math.radians(18)
    bpy.ops.object.light_add(type="AREA", location=(-22, 110, 34)); fill = bpy.context.object; fill.name = "Preview_Fill"; fill.data.energy = 1800; fill.data.color = (0.43, 0.28, 0.68); fill.data.shape = "DISK"; fill.data.size = 24; look_at(fill, (0, 110, 1.5))
    bpy.ops.object.camera_add(location=(23, -28, 22)); camera = bpy.context.object; camera.name = "Preview_Camera"; camera.data.type = "ORTHO"; camera.data.ortho_scale = 36; bpy.context.scene.camera = camera
    scene = bpy.context.scene; scene.render.engine = "BLENDER_EEVEE"; scene.render.resolution_x = 1600; scene.render.resolution_y = 900; scene.render.resolution_percentage = 100; scene.render.image_settings.file_format = "PNG"; scene.render.film_transparent = False; scene.world.color = (0.014, 0.019, 0.026); scene.view_settings.look = "AgX - Medium High Contrast"
    def set_visible(record: dict, visible: bool) -> None:
        record["root"].hide_render = not visible
        for child in record["root"].children_recursive:
            child.hide_render = not visible

    preview_scales = {"trees": 43.0, "rocks": 36.0, "forest_debris": 34.0, "ground_cover": 32.0, "mire_growth": 34.0, "ruins": 34.0, "building_pieces": 40.0}
    preview_heights = {"trees": 2.7, "rocks": 1.2, "forest_debris": 0.8, "ground_cover": 0.5, "mire_growth": 0.9, "ruins": 1.6, "building_pieces": 1.5}
    for category in CATEGORY_ORDER:
        category_y = CATEGORY_ORDER.index(category) * 38.0
        for r in records: set_visible(r, r["category"] == category)
        target_height = preview_heights[category]
        camera.location = (22, category_y - 29, 22 + target_height); camera.data.ortho_scale = preview_scales[category]; look_at(camera, (0, category_y, target_height)); scene.render.filepath = str(PREVIEW_DIR / CATEGORY_PREVIEWS[category]); bpy.ops.render.render(write_still=True)

    hero_positions = {
        "tree_pine_c": (-10.0, 3.0, 0.0), "tree_birch_b": (-6.0, 3.0, 0.0), "tree_crooked_b": (-2.0, 3.0, 0.0),
        "boulder_d": (3.0, 3.0, 0.0), "standing_stone_b": (7.0, 3.0, 0.0),
        "fallen_log_c": (-9.0, -3.0, 0.0), "fern_c": (-5.0, -3.0, 0.0), "mire_crystal_c": (-1.0, -3.0, 0.0),
        "ruin_arch_a": (3.5, -3.0, 0.0), "wood_wall_window": (6.7, -3.0, 0.0),
    }
    original_locations: dict[str, Vector] = {}
    for r in records:
        set_visible(r, r["name"] in hero_positions)
        if r["name"] in hero_positions:
            original_locations[r["name"]] = r["root"].location.copy()
            r["root"].location = hero_positions[r["name"]]
    camera.data.type = "PERSP"; camera.data.lens = 56.0; camera.location = (18.0, -25.0, 12.5); look_at(camera, (-0.5, 0.0, 2.0))
    scene.render.resolution_x = 1600; scene.render.resolution_y = 900; scene.render.filepath = str(PREVIEW_DIR / "mire_map_kit_preview.png"); bpy.ops.render.render(write_still=True)
    for r in records:
        if r["name"] in original_locations: r["root"].location = original_locations[r["name"]]
        set_visible(r, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "mire_map_kit.blend")); print(f"Built {len(records)} MIRE assets across {len(CATEGORY_ORDER)} categories")


if __name__ == "__main__":
    main()
