"""Author MIRE's compact playtest map as one editable Blender scene and GLB.

Run with:
  Blender --background --python tools/blender/build_playtest_map.py

The result is a fixed, hand-directed layout. Godot loads the exported map as a
single asset; it does not scatter or choose the visible prop locations at boot.
"""

from __future__ import annotations

import math
import random
from pathlib import Path

import bpy


ROOT = Path(__file__).resolve().parents[2]
ENV = ROOT / "assets" / "environment" / "exports"
HARVEST = ROOT / "assets" / "harvestables" / "exports"
STATIONS = ROOT / "assets" / "crafting_stations" / "exports"
SOURCE = ROOT / "assets" / "source" / "playtest_map.blend"
EXPORT = ROOT / "assets" / "maps" / "playtest_map.glb"
PREVIEW = ROOT / "assets" / "maps" / "preview" / "playtest_map_preview.png"
SEED = 20260816


def reset_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.meshes, bpy.data.curves, bpy.data.materials, bpy.data.cameras, bpy.data.lights):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)


def material(name: str, color: tuple[float, float, float, float], roughness: float = 0.9) -> bpy.types.Material:
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = color
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = roughness
    return mat


def box(
    name: str,
    location: tuple[float, float, float],
    dimensions: tuple[float, float, float],
    mat: bpy.types.Material,
    parent: bpy.types.Object,
    rotation_z: float = 0.0,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=(0.0, 0.0, rotation_z))
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = dimensions
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(mat)
    obj.parent = parent
    return obj


def zone(root: bpy.types.Object, name: str) -> bpy.types.Object:
    obj = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = root
    obj["mire_zone"] = name
    return obj


def import_asset(
    folder: Path,
    asset_id: str,
    instance_name: str,
    parent: bpy.types.Object,
    x: float,
    godot_z: float,
    height: float = 0.0,
    yaw: float = 0.0,
    scale: float = 1.0,
) -> bpy.types.Object:
    path = folder / f"{asset_id}.glb"
    if not path.exists():
        raise FileNotFoundError(path)
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    imported = set(bpy.data.objects) - before
    roots = [obj for obj in imported if obj.parent not in imported]

    holder = bpy.data.objects.new(instance_name, None)
    bpy.context.scene.collection.objects.link(holder)
    holder.parent = parent
    # Blender is Z-up and its +Y becomes Godot -Z on glTF import.
    holder.location = (x, -godot_z, height)
    holder.rotation_euler[2] = yaw
    holder.scale = (scale, scale, scale)
    holder["mire_asset"] = asset_id
    for imported_root in roots:
        imported_root.parent = holder
    return holder


def env(asset_id: str, name: str, parent: bpy.types.Object, x: float, z: float, **kwargs) -> bpy.types.Object:
    return import_asset(ENV, asset_id, name, parent, x, z, **kwargs)


def harvest(asset_id: str, name: str, parent: bpy.types.Object, x: float, z: float, **kwargs) -> bpy.types.Object:
    return import_asset(HARVEST, asset_id, name, parent, x, z, **kwargs)


def station(asset_id: str, name: str, parent: bpy.types.Object, x: float, z: float, **kwargs) -> bpy.types.Object:
    return import_asset(STATIONS, asset_id, name, parent, x, z, **kwargs)


def build_camp(root: bpy.types.Object, rng: random.Random) -> None:
    camp = zone(root, "SpawnCamp")
    # Cabin and open workshop form a readable safe starting courtyard.
    pieces = [
        ("wood_foundation", -6.0, 8.0, 0.0, 0.0),
        ("wood_floor", -6.0, 8.0, 0.4, 0.0),
        ("wood_wall_solid", -6.0, 6.0, 0.4, 0.0),
        ("wood_wall_window", -8.0, 8.0, 0.4, math.pi / 2),
        ("wood_wall_solid", -4.0, 8.0, 0.4, math.pi / 2),
        ("wood_wall_door", -6.0, 10.0, 0.4, 0.0),
        ("wood_roof_corner", -6.0, 8.0, 3.4, 0.0),
        ("wood_foundation", 5.0, 9.0, 0.0, 0.0),
        ("wood_floor", 5.0, 9.0, 0.4, 0.0),
        ("wood_half_wall", 5.0, 7.0, 0.4, 0.0),
        ("wood_railing", 3.0, 9.0, 0.4, math.pi / 2),
        ("wood_railing", 7.0, 9.0, 0.4, math.pi / 2),
    ]
    for index, (asset_id, x, z, height, yaw) in enumerate(pieces):
        env(asset_id, f"Camp_{asset_id}_{index:02d}", camp, x, z, height=height, yaw=yaw)

    for index, x in enumerate((-8.0, -4.0, 4.0, 8.0)):
        env("fence_straight", f"Camp_FenceNorth_{index:02d}", camp, x, 14.0)
    env("fence_gate", "Camp_MainGate", camp, 0.0, 14.0)
    for index, z in enumerate((5.0, 9.0, 13.0)):
        env("fence_straight", f"Camp_FenceWest_{index:02d}", camp, -10.0, z, yaw=math.pi / 2)
        env("fence_straight", f"Camp_FenceEast_{index:02d}", camp, 10.0, z, yaw=math.pi / 2)

    station("station_workbench_primitive", "Camp_Workbench", camp, 5.0, 8.1, height=0.65, yaw=math.pi)
    station("station_repair_bench", "Camp_RepairBench", camp, 5.0, 9.8, height=0.65)
    station("station_campfire", "Camp_Fire", camp, 0.0, 7.0)
    station("station_cooking_spit", "Camp_CookingSpit", camp, 0.0, 4.5, yaw=math.pi / 2)
    station("station_woodcutting_block", "Camp_ChoppingBlock", camp, -1.8, 4.0, yaw=-0.35)
    for index in range(10):
        x = rng.uniform(-9.0, 9.0)
        z = rng.uniform(3.0, 13.0)
        if math.dist((x, z), (0.0, 8.0)) > 3.0:
            env(f"grass_clump_{'abcdef'[index % 6]}", f"Camp_Grass_{index:02d}", camp, x, z, yaw=rng.random() * math.tau)


def build_forest(root: bpy.types.Object, rng: random.Random) -> None:
    forest = zone(root, "WestForest")
    positions = [
        (-25, -15), (-20.5, -14), (-15.5, -17), (-26, -8), (-21, -7), (-16, -10),
        (-27, 0), (-22, 1.5), (-16, -1), (-26, 8), (-21, 9.5), (-16.5, 6.5),
        (-25, 16), (-19.5, 17), (-15, 14),
    ]
    for index, (x, z) in enumerate(positions):
        if index in (2, 7, 12):
            harvest("harvest_tree_intact", f"Forest_HarvestTree_{index:02d}", forest, x, z, yaw=rng.random() * math.tau)
        else:
            family = "pine" if index % 3 else "birch"
            letter = "abcdef"[index % (6 if family == "pine" else 4)]
            env(f"tree_{family}_{letter}", f"Forest_Tree_{index:02d}", forest, x, z, yaw=rng.random() * math.tau)
    for index in range(26):
        x, z = rng.uniform(-27, -14), rng.uniform(-17, 18)
        asset = f"fern_{'abcdef'[index % 6]}" if index % 2 == 0 else f"grass_clump_{'abcdef'[index % 6]}"
        env(asset, f"Forest_Undergrowth_{index:02d}", forest, x, z, yaw=rng.random() * math.tau, scale=rng.uniform(0.8, 1.2))
    env("fallen_log_b", "Forest_FallenLog", forest, -20, 4, yaw=0.8)
    harvest("harvest_tree_felled_trunk", "Forest_FelledTrunk", forest, -23, -11, yaw=-0.4)
    harvest("harvest_tree_fresh_stump", "Forest_FreshStump", forest, -18, -5, yaw=0.4)
    env("root_cluster_c", "Forest_RootCluster", forest, -17, 11, yaw=1.2)
    env("boulder_b", "Forest_BoulderA", forest, -24, 5, yaw=0.2)
    env("boulder_g", "Forest_BoulderB", forest, -15, 2.5, yaw=1.0)


def build_ruins(root: bpy.types.Object) -> None:
    ruins = zone(root, "NorthRuins")
    for asset, name, x, z, yaw in [
        ("ruin_arch_a", "Ruins_MainArch", 0, -13.5, 0),
        ("ruin_wall_a", "Ruins_WestWall", -5, -19, math.pi / 2),
        ("ruin_wall_b", "Ruins_EastWall", 5, -19, math.pi / 2),
        ("ruin_wall_c", "Ruins_BackWallA", -3, -24.5, 0),
        ("ruin_wall_d", "Ruins_BackWallB", 3, -24.5, 0),
        ("ruin_column_a", "Ruins_ColumnA", -3.5, -16.5, 0.1),
        ("ruin_column_c", "Ruins_ColumnB", 3.5, -16.5, -0.1),
        ("stone_marker_a", "Ruins_MarkerA", -6.5, -13, 0.25),
        ("stone_marker_b", "Ruins_MarkerB", 6.5, -13, -0.25),
    ]:
        env(asset, name, ruins, x, z, yaw=yaw)
    env("stone_foundation", "Ruins_ForgeFoundation", ruins, 10, -21)
    env("stone_floor", "Ruins_ForgeFloor", ruins, 10, -21, height=0.72)
    env("stone_half_wall", "Ruins_ForgeWall", ruins, 10, -23, height=0.72)
    env("stone_stairs", "Ruins_ForgeStairs", ruins, 10, -17.3)
    station("station_stone_furnace", "Ruins_Furnace", ruins, 10, -21, height=0.85, yaw=math.pi)
    station("station_anvil", "Ruins_Anvil", ruins, 7.8, -20, height=0.75, yaw=0.35)
    harvest("stone_node_intact", "Ruins_StoneNode", ruins, -8, -22, yaw=0.6)
    harvest("iron_node_intact", "Ruins_IronNode", ruins, 7, -26, yaw=1.1)


def build_mire(root: bpy.types.Object, rng: random.Random) -> None:
    mire = zone(root, "EastMire")
    dead_trees = [(16, -10), (22, -12), (26, -7), (17, 0), (24, 2), (27, 8)]
    for index, (x, z) in enumerate(dead_trees):
        family = "bare" if index % 2 == 0 else "crooked"
        env(f"tree_{family}_{'abcd'[index % 4]}", f"Mire_Tree_{index:02d}", mire, x, z, yaw=rng.random() * math.tau)
    crystals = [(18, -7), (22, -5), (25, -1), (19, 3), (23, 6), (16, 7)]
    for index, (x, z) in enumerate(crystals):
        env(f"mire_crystal_{'abcdef'[index]}", f"Mire_Crystal_{index:02d}", mire, x, z, yaw=rng.random() * math.tau)
    for index in range(10):
        env(f"mushroom_cluster_{'abcdef'[index % 6]}", f"Mire_Mushrooms_{index:02d}", mire, rng.uniform(15, 27), rng.uniform(-10, 10), yaw=rng.random() * math.tau)
    for index in range(4):
        env(f"mire_tendril_{'abcd'[index]}", f"Mire_Tendril_{index:02d}", mire, 18 + index * 2.2, -3 + (index % 2) * 8, yaw=rng.random() * math.tau)
    env("standing_stone_a", "Mire_StandingStoneA", mire, 14.5, -4, yaw=0.2)
    env("standing_stone_c", "Mire_StandingStoneB", mire, 27, 3, yaw=-0.3)


def build_ridge(root: bpy.types.Object, rng: random.Random) -> None:
    ridge = zone(root, "SouthRidge")
    rocks = [(-10, 23), (-5, 25), (1, 22), (8, 25), (15, 23), (22, 25), (26, 20), (18, 18)]
    for index, (x, z) in enumerate(rocks):
        if index in (1, 4):
            harvest("stone_node_intact", f"Ridge_StoneNode_{index:02d}", ridge, x, z, yaw=rng.random() * math.tau)
        else:
            env(f"boulder_{'abcdefgh'[index]}", f"Ridge_Boulder_{index:02d}", ridge, x, z, yaw=rng.random() * math.tau)
    for asset, name, x, z, height, yaw in [
        ("wood_foundation", "Ridge_Foundation", 12, 20, 0, 0),
        ("wood_floor", "Ridge_Floor", 12, 20, 0.4, 0),
        ("wood_stairs", "Ridge_Stairs", 12, 16.2, 0, 0),
        ("wood_railing", "Ridge_BackRail", 12, 22, 0.4, 0),
        ("wood_railing", "Ridge_WestRail", 10, 20, 0.4, math.pi / 2),
        ("wood_railing", "Ridge_EastRail", 14, 20, 0.4, math.pi / 2),
        ("wood_post", "Ridge_PostA", 10.1, 18.1, 0.4, 0),
        ("wood_post", "Ridge_PostB", 13.9, 18.1, 0.4, 0),
    ]:
        env(asset, name, ridge, x, z, height=height, yaw=yaw)


def build_routes(root: bpy.types.Object, rng: random.Random) -> None:
    routes = zone(root, "RoutesAndBoundary")
    for index in range(18):
        z = 3.0 - index * 1.05
        side = -1 if index % 2 == 0 else 1
        env(
            f"grass_clump_{'abcdef'[index % 6]}",
            f"Route_Grass_{index:02d}",
            routes,
            side * rng.uniform(3.6, 5.8),
            z,
            yaw=rng.random() * math.tau,
            scale=rng.uniform(0.75, 1.05),
        )
    boundary_trees = [(-27, -25), (-20, -27), (-12, -27), (12, -27), (20, -27), (27, -24), (28, 13), (27, 18), (25, 27), (-25, 27), (-28, 20), (-28, 13)]
    for index, (x, z) in enumerate(boundary_trees):
        family = "pine" if index % 2 == 0 else "birch"
        letters = "abcdef" if family == "pine" else "abcd"
        env(f"tree_{family}_{letters[index % len(letters)]}", f"Boundary_Tree_{index:02d}", routes, x, z, yaw=rng.random() * math.tau)
    for index, (x, z) in enumerate(((-5, -28), (4, -27.5), (28, -16), (28, 14), (6, 28), (-5, 28), (-28, -19), (-28, -3))):
        env(f"boulder_{'abcdefgh'[index]}", f"Boundary_Rock_{index:02d}", routes, x, z, yaw=rng.random() * math.tau)


def add_ground(root: bpy.types.Object) -> None:
    terrain = zone(root, "AuthoredTerrain")
    ground = material("MIRE_Map_Ground", (0.075, 0.16, 0.065, 1.0), 0.98)
    path = material("MIRE_Map_Path", (0.19, 0.135, 0.075, 1.0), 1.0)
    mire = material("MIRE_Map_Mire", (0.12, 0.105, 0.16, 1.0), 0.72)
    box("Map_Ground", (0, 0, -0.18), (60, 60, 0.36), ground, terrain)
    box("Path_CampToRuins", (0, 5.5, 0.025), (5.5, 34, 0.05), path, terrain)
    box("Path_CampToMire", (10.5, -1.5, 0.03), (22, 4.0, 0.06), path, terrain, rotation_z=-0.08)
    box("Path_CampToForest", (-10.5, -0.5, 0.03), (21, 3.5, 0.06), path, terrain, rotation_z=0.05)
    box("Mire_Pool", (22.5, 1.5, 0.035), (11, 16, 0.07), mire, terrain, rotation_z=0.05)


def setup_preview(root: bpy.types.Object) -> None:
    bpy.ops.object.camera_add(location=(54, -68, 54))
    camera = bpy.context.object
    camera.name = "PreviewCamera"
    camera.data.lens = 48
    direction = root.location - camera.location
    camera.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = camera

    bpy.ops.object.light_add(type="SUN", location=(0, 0, 35))
    sun = bpy.context.object
    sun.name = "PreviewSun"
    sun.rotation_euler = (math.radians(32), math.radians(-18), math.radians(28))
    sun.data.energy = 3.0
    sun.data.color = (1.0, 0.83, 0.66)
    bpy.ops.object.light_add(type="AREA", location=(-20, -8, 42))
    fill = bpy.context.object
    fill.name = "PreviewFill"
    fill.data.energy = 1800
    fill.data.shape = "DISK"
    fill.data.size = 25

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1280
    scene.render.resolution_y = 720
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = str(PREVIEW)
    scene.world.color = (0.055, 0.075, 0.105)


def descendants(root: bpy.types.Object) -> list[bpy.types.Object]:
    result = [root]
    for child in root.children:
        result.extend(descendants(child))
    return result


def main() -> None:
    reset_scene()
    EXPORT.parent.mkdir(parents=True, exist_ok=True)
    PREVIEW.parent.mkdir(parents=True, exist_ok=True)
    SOURCE.parent.mkdir(parents=True, exist_ok=True)
    rng = random.Random(SEED)

    root = bpy.data.objects.new("MIRE_PlaytestMap", None)
    bpy.context.scene.collection.objects.link(root)
    root["mire_map_seed"] = SEED
    root["mire_authored_map"] = True
    add_ground(root)
    build_camp(root, rng)
    build_forest(root, rng)
    build_ruins(root)
    build_mire(root, rng)
    build_ridge(root, rng)
    build_routes(root, rng)
    setup_preview(root)

    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE))
    bpy.context.scene.render.filepath = str(PREVIEW)
    bpy.ops.render.render(write_still=True)

    bpy.ops.object.select_all(action="DESELECT")
    for obj in descendants(root):
        obj.select_set(True)
    bpy.context.view_layer.objects.active = root
    bpy.ops.export_scene.gltf(
        filepath=str(EXPORT),
        export_format="GLB",
        use_selection=True,
        export_apply=False,
        export_yup=True,
        export_extras=True,
        export_cameras=False,
        export_lights=False,
    )
    print(f"PLAYTEST_MAP_BUILD blend={SOURCE} glb={EXPORT} preview={PREVIEW}")


if __name__ == "__main__":
    main()
