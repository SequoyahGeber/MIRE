"""Build MIRE's first low-poly environment kit and export each prop as GLB.

Run with:
  Blender --background --python tools/blender/build_mire_map_kit.py

The generated source file remains editable in Blender. Geometry is intentionally
simple, flat shaded, consistently scaled in metres, and centred at ground level.
"""

from __future__ import annotations

import math
from pathlib import Path

import bpy
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "environment"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"


def material(name: str, color: tuple[float, float, float, float], roughness: float = 0.9) -> bpy.types.Material:
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = color
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = roughness
    return mat


def assign(obj: bpy.types.Object, mat: bpy.types.Material) -> bpy.types.Object:
    obj.data.materials.append(mat)
    for polygon in obj.data.polygons:
        polygon.use_smooth = False
    return obj


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


def create_asset(name: str, build_fn, display_location: tuple[float, float, float]) -> None:
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


def look_at(obj: bpy.types.Object, target: tuple[float, float, float]) -> None:
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


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

    bark = material("MIRE_Bark", (0.18, 0.075, 0.035, 1.0))
    bark_light = material("MIRE_Bark_Light", (0.34, 0.14, 0.055, 1.0))
    cut_wood = material("MIRE_Cut_Wood", (0.68, 0.38, 0.13, 1.0))
    pine_dark = material("MIRE_Pine_Dark", (0.025, 0.22, 0.12, 1.0))
    pine_mid = material("MIRE_Pine_Mid", (0.035, 0.36, 0.18, 1.0))
    pine_tip = material("MIRE_Pine_Tip", (0.10, 0.53, 0.24, 1.0))
    stone = material("MIRE_Stone", (0.23, 0.28, 0.30, 1.0))
    stone_light = material("MIRE_Stone_Light", (0.39, 0.46, 0.45, 1.0))
    grass = material("MIRE_Grass", (0.17, 0.48, 0.18, 1.0))
    grass_light = material("MIRE_Grass_Light", (0.36, 0.67, 0.20, 1.0))
    mushroom = material("MIRE_Mushroom", (0.64, 0.17, 0.55, 1.0))
    mushroom_spot = material("MIRE_Mushroom_Spot", (0.93, 0.67, 0.91, 1.0))
    mire = material("MIRE_Corruption", (0.12, 0.025, 0.17, 1.0))
    ground = material("MIRE_Preview_Ground", (0.10, 0.16, 0.09, 1.0))

    def tree_pine() -> None:
        cone("Trunk", 0.34, 0.22, 3.5, (0.0, 0.0, 1.75), bark, 8)
        cone("Foliage_Low", 1.75, 0.18, 2.0, (0.0, 0.0, 2.35), pine_dark, 9)
        cone("Foliage_Mid", 1.35, 0.12, 1.8, (0.0, 0.0, 3.45), pine_mid, 9)
        cone("Foliage_Top", 0.90, 0.02, 1.65, (0.0, 0.0, 4.50), pine_tip, 8)

    def tree_bare() -> None:
        cone("Trunk", 0.46, 0.20, 4.4, (0.0, 0.0, 2.2), bark_light, 7)
        cylinder_between("Branch_L", (-0.03, 0.0, 2.7), (-1.35, 0.18, 4.25), 0.16, bark_light)
        cylinder_between("Branch_L_Twig", (-1.35, 0.18, 4.25), (-1.75, 0.10, 4.95), 0.08, bark_light, 6)
        cylinder_between("Branch_R", (0.04, 0.0, 3.25), (1.25, -0.18, 4.55), 0.14, bark_light)
        cylinder_between("Branch_R_Twig", (1.25, -0.18, 4.55), (1.70, -0.22, 4.95), 0.065, bark_light, 6)
        cylinder_between("Crown", (0.0, 0.0, 4.1), (0.2, 0.0, 5.25), 0.12, bark_light, 6)

    def boulder() -> None:
        ico("Boulder", (0.0, 0.0, 0.78), (1.45, 1.12, 0.92), stone, (0.18, -0.12, 0.42))
        ico("Boulder_Highlight", (-0.34, -0.64, 0.92), (0.48, 0.23, 0.25), stone_light, (0.2, 0.1, 0.2))

    def rock_cluster() -> None:
        ico("Rock_A", (-0.55, 0.05, 0.42), (0.78, 0.62, 0.52), stone, (0.2, 0.0, 0.5))
        ico("Rock_B", (0.38, 0.16, 0.60), (0.72, 0.55, 0.76), stone_light, (-0.15, 0.2, -0.2))
        ico("Rock_C", (0.72, -0.38, 0.27), (0.46, 0.36, 0.32), stone, (0.1, -0.1, 0.7))

    def stump() -> None:
        cone("Stump", 0.58, 0.47, 1.05, (0.0, 0.0, 0.525), bark, 9)
        cylinder("Cut", 0.47, 0.035, (0.0, 0.0, 1.065), cut_wood, 9)
        cylinder_between("Root_A", (-0.20, 0.0, 0.22), (-0.92, -0.18, 0.05), 0.16, bark, 7)
        cylinder_between("Root_B", (0.15, 0.15, 0.20), (0.67, 0.72, 0.05), 0.14, bark, 7)
        cylinder_between("Root_C", (0.12, -0.12, 0.18), (0.60, -0.72, 0.04), 0.13, bark, 7)

    def fallen_log() -> None:
        cylinder_between("Log", (-1.65, 0.0, 0.42), (1.65, 0.0, 0.42), 0.42, bark, 9)
        cylinder_between("Cut_A", (-1.68, 0.0, 0.42), (-1.70, 0.0, 0.42), 0.36, cut_wood, 9)
        cylinder_between("Branch", (0.45, 0.0, 0.58), (0.90, 0.76, 1.02), 0.10, bark, 7)
        ico("Moss", (-0.22, -0.31, 0.67), (0.78, 0.18, 0.13), pine_mid, (0.0, 0.0, 0.1))

    def grass_clump() -> None:
        blades = [
            (-0.35, 0.00, 0.70, 0.10, grass),
            (-0.12, 0.08, 1.05, -0.06, grass_light),
            (0.10, -0.05, 0.82, 0.04, grass),
            (0.31, 0.10, 0.94, -0.08, grass_light),
            (0.02, 0.25, 0.62, 0.10, grass),
            (-0.24, -0.22, 0.60, -0.09, grass_light),
        ]
        for index, (x, y, height, tilt, mat) in enumerate(blades):
            blade = cone(f"Blade_{index + 1}", 0.13, 0.015, height, (x, y, height * 0.5), mat, 4)
            blade.rotation_euler[1] = tilt

    def mushroom_cluster() -> None:
        specs = [(-0.38, 0.05, 0.55, 0.22), (0.18, 0.10, 0.82, 0.31), (0.48, -0.18, 0.44, 0.18)]
        for index, (x, y, height, cap_radius) in enumerate(specs):
            cylinder(f"Stem_{index + 1}", 0.07, height, (x, y, height * 0.5), cut_wood, 7)
            cap = ico(f"Cap_{index + 1}", (x, y, height), (cap_radius, cap_radius, cap_radius * 0.48), mushroom, (0.0, 0.0, index * 0.35))
            if index == 1:
                ico("Cap_Spot", (x - 0.08, y - 0.06, height + 0.13), (0.055, 0.055, 0.025), mushroom_spot)
        ico("Mire_Growth", (0.06, 0.03, 0.06), (0.72, 0.48, 0.08), mire, (0.0, 0.0, 0.3))

    assets = [
        ("tree_pine_a", tree_pine, (-6.0, 2.6, 0.0)),
        ("tree_bare_a", tree_bare, (-2.2, 2.6, 0.0)),
        ("boulder_a", boulder, (2.2, 3.1, 0.0)),
        ("rock_cluster_a", rock_cluster, (5.2, 3.2, 0.0)),
        ("stump_a", stump, (-5.2, -2.4, 0.0)),
        ("fallen_log_a", fallen_log, (-1.8, -2.4, 0.0)),
        ("grass_clump_a", grass_clump, (2.4, -2.5, 0.0)),
        ("mushroom_cluster_a", mushroom_cluster, (5.1, -2.5, 0.0)),
    ]
    for name, builder, location in assets:
        create_asset(name, builder, location)

    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.mesh.primitive_plane_add(size=18.0, location=(0.0, 0.0, -0.03))
    plane = bpy.context.object
    plane.name = "Preview_Ground"
    assign(plane, ground)
    for old_collection in list(plane.users_collection):
        old_collection.objects.unlink(plane)
    preview_collection.objects.link(plane)

    bpy.ops.object.light_add(type="AREA", location=(-4.0, -5.0, 12.0))
    key = bpy.context.object
    key.name = "Preview_Key"
    key.data.energy = 1700.0
    key.data.shape = "DISK"
    key.data.size = 8.0
    look_at(key, (0.0, 0.0, 1.5))
    bpy.ops.object.light_add(type="AREA", location=(8.0, 4.0, 7.0))
    fill = bpy.context.object
    fill.name = "Preview_Fill"
    fill.data.energy = 1000.0
    fill.data.color = (0.42, 0.26, 0.62)
    fill.data.size = 6.0
    look_at(fill, (0.0, 0.0, 1.0))

    bpy.ops.object.camera_add(location=(13.5, -19.5, 10.0))
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    camera.data.lens = 52.0
    look_at(camera, (0.0, 0.2, 1.75))
    bpy.context.scene.camera = camera

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1280
    scene.render.resolution_y = 720
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = str(PREVIEW_DIR / "mire_map_kit_preview.png")
    scene.render.film_transparent = False
    scene.world.color = (0.018, 0.025, 0.035)
    scene.view_settings.look = "AgX - Medium High Contrast"

    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "mire_map_kit.blend"))
    bpy.ops.render.render(write_still=True)
    print(f"Built {len(assets)} MIRE assets in {ASSET_DIR}")


if __name__ == "__main__":
    main()
