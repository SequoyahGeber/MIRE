"""Adapt Sequoyah's supplied low-poly rock and tree to MIRE's asset contract.

The checked-in reference GLBs preserve the supplied geometry. This rebuild strips
their preview-scene baggage, normalizes scale/origin/transforms, renames every mesh,
remaps the palette, and exports two portable environment additions.

Run with:
  Blender --background --python tools/blender/build_adapted_nature_set.py
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import bpy
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[2]
REFERENCE_DIR = ROOT / "assets" / "source" / "reference_imports"
ASSET_DIR = ROOT / "assets" / "environment_additions"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"
SOURCE_PATH = ROOT / "assets" / "source" / "adapted_nature_set.blend"

EXPECTED_NAMES = ["mire_mossy_boulder", "mire_broadleaf_tree"]


def material(
    name: str,
    color: tuple[float, float, float, float],
    roughness: float = 0.9,
) -> bpy.types.Material:
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = color
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = roughness
    return mat


def assign_only(obj: bpy.types.Object, mat: bpy.types.Material) -> None:
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    for polygon in obj.data.polygons:
        polygon.material_index = 0
        polygon.use_smooth = False


def box(
    name: str,
    location: tuple[float, float, float],
    dimensions: tuple[float, float, float],
    mat: bpy.types.Material,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cube_add(location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = tuple(value * 0.5 for value in dimensions)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    assign_only(obj, mat)
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
    corners = [obj.matrix_world @ Vector(corner) for obj in objects for corner in obj.bound_box]
    minimum = Vector((min(v.x for v in corners), min(v.y for v in corners), min(v.z for v in corners)))
    maximum = Vector((max(v.x for v in corners), max(v.y for v in corners), max(v.z for v in corners)))
    return minimum, maximum


def imported_objects(path: Path) -> list[bpy.types.Object]:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    return [obj for obj in bpy.data.objects if obj not in before]


def delete_objects(objects: list[bpy.types.Object]) -> None:
    for obj in objects:
        bpy.data.objects.remove(obj, do_unlink=True)


def prepare_asset(
    name: str,
    family: str,
    objects: list[bpy.types.Object],
    scale: float,
    display_location: tuple[float, float, float],
    flatten_lower_ratio: float = 0.0,
) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)
    for obj in objects:
        obj.scale *= scale
        # Imported assemblies are many separate mesh nodes. Scaling only each
        # mesh shrinks it around its own origin but leaves the spacing between
        # parts unchanged, pulling trunk sections and moss patches apart.
        obj.location *= scale
    if flatten_lower_ratio > 0.0:
        minimum, maximum = world_bounds(objects)
        contact_z = minimum.z + (maximum.z - minimum.z) * flatten_lower_ratio
        for obj in objects:
            inverse = obj.matrix_world.inverted()
            for vertex in obj.data.vertices:
                world_position = obj.matrix_world @ vertex.co
                if world_position.z < contact_z:
                    world_position.z = contact_z
                    vertex.co = inverse @ world_position
    minimum, maximum = world_bounds(objects)
    offset = Vector((-(minimum.x + maximum.x) * 0.5, -(minimum.y + maximum.y) * 0.5, -minimum.z))
    for obj in objects:
        obj.location += offset
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
        obj.select_set(False)
    move_to_collection(objects, collection)
    for obj in objects:
        obj.parent = root
    minimum, maximum = world_bounds(objects)
    dimensions = maximum - minimum
    polygons = sum(len(obj.data.polygons) for obj in objects)
    materials = sorted({mat.name for obj in objects for mat in obj.data.materials if mat})

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
        "parts": len(objects),
        "polygons": polygons,
        "materials": materials,
    }


def build_boulder(mats: dict[str, bpy.types.Material]) -> list[bpy.types.Object]:
    imported = imported_objects(REFERENCE_DIR / "low_poly_rock_asset.glb")
    keep_names = (
        "Hero Boulder", "Upper Fracture Slab", "Side Fracture Slab", "Footing Stone",
        "Natural Crack", "Moss Patch", "Lichen",
    )
    kept = [obj for obj in imported if obj.type == "MESH" and obj.name.startswith(keep_names)]
    delete_objects([obj for obj in imported if obj not in kept])
    counters: dict[str, int] = {}
    for obj in kept:
        if obj.name == "Hero Boulder":
            category, mat = "body", mats["rock_mid"]
        elif obj.name == "Upper Fracture Slab":
            category, mat = "upper_slab", mats["rock_light"]
        elif obj.name == "Side Fracture Slab":
            category, mat = "side_slab", mats["rock_blue"]
        elif obj.name == "Footing Stone":
            category, mat = "footing", mats["rock_dark"]
        elif obj.name.startswith("Natural Crack"):
            category, mat = "crack", mats["rock_crack"]
        elif obj.name.startswith("Moss Patch"):
            category = "moss"
            mat = mats[("moss_dark", "moss_mid", "moss_light")[counters.get(category, 0) % 3]]
        else:
            category, mat = "lichen", mats["lichen"]
        counters[category] = counters.get(category, 0) + 1
        obj.name = f"mire_mossy_boulder_{category}_{counters[category]:02d}"
        obj.data.name = f"{obj.name}_mesh"
        assign_only(obj, mat)
    if len(kept) != 19:
        raise RuntimeError(f"Expected 19 supplied boulder meshes, found {len(kept)}")
    return kept


def build_tree(mats: dict[str, bpy.types.Material]) -> list[bpy.types.Object]:
    imported = imported_objects(REFERENCE_DIR / "low_poly_tree_asset.glb")
    keep_names = ("Trunk", "Bark Collar", "Root", "Branch", "Foliage Cluster", "Golden Leaf Accent")
    kept = [obj for obj in imported if obj.type == "MESH" and obj.name.startswith(keep_names)]
    delete_objects([obj for obj in imported if obj not in kept])
    counters: dict[str, int] = {}
    for obj in kept:
        if obj.name.startswith("Trunk"):
            category = "trunk"
            mat = mats["bark"]
        elif obj.name.startswith("Bark Collar"):
            category = "bark_collar"
            mat = mats["bark_light"]
        elif obj.name.startswith("Root"):
            category = "root"
            mat = mats["bark_dark"]
        elif obj.name.startswith("Branch"):
            category = "branch"
            mat = mats["bark"] if counters.get("branch", 0) % 3 else mats["bark_light"]
        elif obj.name.startswith("Foliage Cluster"):
            category = "foliage"
            foliage_index = counters.get(category, 0)
            mat = mats[("leaf_deep", "leaf_mid", "leaf_light")[foliage_index % 3]]
        else:
            category = "leaf_accent"
            mat = mats["leaf_warm"]
        counters[category] = counters.get(category, 0) + 1
        obj.name = f"mire_broadleaf_tree_{category}_{counters[category]:02d}"
        obj.data.name = f"{obj.name}_mesh"
        assign_only(obj, mat)
    if len(kept) != 39:
        raise RuntimeError(f"Expected 39 supplied tree meshes after diorama removal, found {len(kept)}")
    return kept


def setup_render(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Scene, bpy.types.Object, bpy.types.Collection]:
    collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(collection)
    bpy.ops.mesh.primitive_plane_add(size=40, location=(0.0, 0.0, -0.025))
    floor = bpy.context.object
    floor.name = "preview_ground"
    assign_only(floor, mats["ground"])
    move_to_collection([floor], collection)
    bpy.ops.object.light_add(type="SUN", location=(0.0, 0.0, 12.0))
    sun = bpy.context.object
    sun.name = "preview_sun"
    sun.rotation_euler = (math.radians(32), math.radians(-26), math.radians(-28))
    sun.data.energy = 2.35
    sun.data.angle = math.radians(18)
    move_to_collection([sun], collection)
    bpy.ops.object.light_add(type="AREA", location=(-6.0, -8.0, 8.0))
    fill = bpy.context.object
    fill.name = "preview_fill"
    fill.data.energy = 1100
    fill.data.color = (0.30, 0.48, 0.58)
    fill.data.shape = "DISK"
    fill.data.size = 7.0
    look_at(fill, (0.0, 0.0, 1.8))
    move_to_collection([fill], collection)
    bpy.ops.object.camera_add(location=(10.0, -15.0, 8.0))
    camera = bpy.context.object
    camera.name = "preview_camera"
    camera.data.type = "ORTHO"
    bpy.context.scene.camera = camera
    move_to_collection([camera], collection)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1600
    scene.render.resolution_y = 1000
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.world.color = (0.010, 0.016, 0.022)
    scene.view_settings.look = "AgX - Medium High Contrast"
    return scene, camera, collection


def main() -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    SOURCE_PATH.parent.mkdir(parents=True, exist_ok=True)
    for expected in EXPECTED_NAMES:
        (EXPORT_DIR / f"{expected}.glb").unlink(missing_ok=True)

    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)

    mats = {
        "rock_dark": material("MIRE_Adapted_Rock_Dark", (0.12, 0.17, 0.19, 1.0)),
        "rock_mid": material("MIRE_Adapted_Rock_Mid", (0.24, 0.32, 0.34, 1.0)),
        "rock_blue": material("MIRE_Adapted_Rock_Blue", (0.28, 0.39, 0.44, 1.0)),
        "rock_light": material("MIRE_Adapted_Rock_Light", (0.43, 0.48, 0.46, 1.0)),
        "rock_crack": material("MIRE_Adapted_Rock_Crack", (0.07, 0.09, 0.10, 1.0)),
        "moss_dark": material("MIRE_Adapted_Moss_Dark", (0.08, 0.23, 0.10, 1.0)),
        "moss_mid": material("MIRE_Adapted_Moss_Mid", (0.20, 0.40, 0.12, 1.0)),
        "moss_light": material("MIRE_Adapted_Moss_Light", (0.42, 0.55, 0.16, 1.0)),
        "lichen": material("MIRE_Adapted_Lichen", (0.58, 0.62, 0.22, 1.0)),
        "bark_dark": material("MIRE_Adapted_Bark_Dark", (0.15, 0.065, 0.025, 1.0)),
        "bark": material("MIRE_Adapted_Bark", (0.31, 0.13, 0.045, 1.0)),
        "bark_light": material("MIRE_Adapted_Bark_Light", (0.48, 0.23, 0.07, 1.0)),
        "leaf_deep": material("MIRE_Adapted_Leaf_Deep", (0.035, 0.17, 0.085, 1.0)),
        "leaf_mid": material("MIRE_Adapted_Leaf_Mid", (0.07, 0.31, 0.13, 1.0)),
        "leaf_light": material("MIRE_Adapted_Leaf_Light", (0.17, 0.44, 0.18, 1.0)),
        "leaf_warm": material("MIRE_Adapted_Leaf_Warm", (0.43, 0.50, 0.12, 1.0)),
        "ground": material("MIRE_Adapted_Preview_Ground", (0.052, 0.085, 0.060, 1.0)),
        "scale": material("MIRE_Adapted_Scale", (0.18, 0.50, 0.78, 1.0)),
    }

    boulder = prepare_asset(
        "mire_mossy_boulder", "boulder", build_boulder(mats), 0.58, (-2.25, 0.0, 0.0), 0.20
    )
    tree = prepare_asset(
        "mire_broadleaf_tree", "tree", build_tree(mats), 0.82, (2.15, 0.4, 0.0)
    )
    records = [boulder, tree]
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
    camera.data.ortho_scale = 9.2
    camera.location = (10.0, -15.0, 7.2)
    look_at(camera, (0.4, 0.0, 2.55))
    scene.render.filepath = str(PREVIEW_DIR / "adapted_nature_preview.png")
    bpy.ops.render.render(write_still=True)

    ruler_parts = [box("scale_post", (-3.9, -0.35, 3.0), (0.10, 0.10, 6.0), mats["scale"])]
    for index in range(1, 13):
        z = index * 0.5
        length = 0.34 if index % 2 == 0 else 0.23
        ruler_parts.append(box(f"scale_tick_{index:02d}", (-3.9 + length * 0.5, -0.35, z), (length, 0.08, 0.03), mats["scale"]))
    ruler_parts.append(box("scale_half_metre_cube", (-3.30, -0.45, 0.25), (0.5, 0.5, 0.5), mats["scale"]))
    move_to_collection(ruler_parts, preview_collection)
    camera.data.ortho_scale = 9.8
    camera.location = (9.0, -14.0, 6.8)
    look_at(camera, (0.0, 0.0, 2.7))
    scene.render.filepath = str(PREVIEW_DIR / "adapted_nature_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_PATH))
    print(
        f"Built {len(records)} adapted nature assets "
        f"({sum(record['polygons'] for record in records)} polygons total)"
    )


if __name__ == "__main__":
    main()
