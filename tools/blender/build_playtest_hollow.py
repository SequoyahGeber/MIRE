"""Build the visual half of playtest_hollow from its shared JSON layout.

Run with:
  Blender --background --python tools/blender/build_playtest_hollow.py

The script makes no placement decisions. It imports the asset named by each JSON record, converts
Godot coordinates to Blender coordinates, saves an editable .blend, renders a preview, and exports
the single GLB instanced by levels/playtest_hollow.tscn.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import bpy


ROOT = Path(__file__).resolve().parents[2]
LAYOUT = ROOT / "world" / "gen" / "layouts" / "playtest_hollow.json"
SOURCE = ROOT / "assets" / "source" / "playtest_hollow.blend"
EXPORT = ROOT / "assets" / "maps" / "playtest_hollow.glb"
PREVIEW = ROOT / "assets" / "maps" / "preview" / "playtest_hollow_preview.png"


def reset_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for collection in list(bpy.data.collections):
        if collection.name != "Collection":
            bpy.data.collections.remove(collection)
    for datablocks in (bpy.data.meshes, bpy.data.curves, bpy.data.materials, bpy.data.cameras, bpy.data.lights):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)


def empty(name: str, parent: bpy.types.Object | None = None) -> bpy.types.Object:
    obj = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = parent
    return obj


def make_material(name: str, definition: dict) -> bpy.types.Material:
    mat = bpy.data.materials.new("MIRE_Hollow_%s" % name.title())
    color = tuple(definition["color"])
    mat.diffuse_color = color
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = float(definition.get("roughness", 0.9))
    return mat


def terrain_box(data: dict, mat: bpy.types.Material, parent: bpy.types.Object) -> bpy.types.Object:
    px, py, pz = data["pos"]
    sx, sy, sz = data["size"]
    bpy.ops.mesh.primitive_cube_add(location=(px, -pz, py))
    obj = bpy.context.object
    obj.name = data["name"]
    obj.dimensions = (sx, sz, sy)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    tilt = float(data.get("tilt", 0.0))
    if data.get("axis") == "z":
        obj.rotation_euler[1] = -tilt
    else:
        obj.rotation_euler[0] = tilt
    obj.rotation_euler[2] = float(data.get("yaw", 0.0))
    obj.data.materials.append(mat)
    obj.parent = parent
    obj["mire_zone"] = data["zone"]
    obj["mire_collides"] = bool(data.get("collide", False))
    return obj


class AssetLibrary:
    def __init__(self) -> None:
        self.templates: dict[tuple[str, str], list[bpy.types.Object]] = {}
        self.template_root = empty("_AssetTemplates")
        self.template_root.hide_render = True
        self.template_root.hide_viewport = True

    def _load(self, kit: str, asset: str) -> list[bpy.types.Object]:
        key = (kit, asset)
        if key in self.templates:
            return self.templates[key]
        path = ROOT / "assets" / kit / "exports" / (asset + ".glb")
        if not path.exists():
            raise FileNotFoundError(path)
        before = set(bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=str(path))
        imported = set(bpy.data.objects) - before
        roots = [obj for obj in imported if obj.parent not in imported]
        holder = empty("Template_%s" % asset, self.template_root)
        for root in roots:
            root.parent = holder
        holder.hide_render = True
        holder.hide_viewport = True
        self.templates[key] = roots
        return roots

    def _clone_tree(self, source: bpy.types.Object, parent: bpy.types.Object) -> bpy.types.Object:
        clone = source.copy()
        if source.data is not None:
            clone.data = source.data
        bpy.context.scene.collection.objects.link(clone)
        clone.parent = parent
        clone.hide_render = False
        clone.hide_viewport = False
        for child in source.children:
            self._clone_tree(child, clone)
        return clone

    def instance(self, data: dict, index: int, parent: bpy.types.Object) -> bpy.types.Object:
        asset = data["asset"]
        holder = empty("Placed_%03d_%s" % (index, asset), parent)
        x, y, z = data["pos"]
        holder.location = (x, -z, y)
        holder.rotation_euler[2] = float(data.get("yaw", 0.0))
        scale = float(data.get("scale", 1.0))
        holder.scale = (scale, scale, scale)
        holder["mire_asset"] = asset
        holder["mire_kit"] = data["kit"]
        for root in self._load(data["kit"], asset):
            self._clone_tree(root, holder)
        return holder


def setup_preview(root: bpy.types.Object) -> None:
    bpy.ops.object.camera_add(location=(94.0, -116.0, 88.0))
    camera = bpy.context.object
    camera.name = "PreviewCamera"
    camera.data.lens = 52
    direction = root.location - camera.location
    camera.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = camera

    bpy.ops.object.light_add(type="SUN", location=(0.0, 0.0, 45.0))
    sun = bpy.context.object
    sun.name = "PreviewSun"
    sun.rotation_euler = (math.radians(38), math.radians(-24), math.radians(30))
    sun.data.energy = 2.7
    sun.data.color = (1.0, 0.82, 0.65)
    bpy.ops.object.light_add(type="AREA", location=(-28.0, -18.0, 48.0))
    fill = bpy.context.object
    fill.name = "PreviewFill"
    fill.data.energy = 2200
    fill.data.shape = "DISK"
    fill.data.size = 34.0

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1440
    scene.render.resolution_y = 900
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = str(PREVIEW)
    scene.world.color = (0.035, 0.05, 0.075)


def descendants(root: bpy.types.Object) -> list[bpy.types.Object]:
    result = [root]
    for child in root.children:
        result.extend(descendants(child))
    return result


def main() -> None:
    data = json.loads(LAYOUT.read_text())
    reset_scene()
    bpy.context.preferences.filepaths.save_version = 0
    SOURCE.parent.mkdir(parents=True, exist_ok=True)
    EXPORT.parent.mkdir(parents=True, exist_ok=True)
    PREVIEW.parent.mkdir(parents=True, exist_ok=True)

    root = empty("MIRE_PlaytestHollow")
    root["mire_layout"] = str(LAYOUT.relative_to(ROOT))
    root["mire_seed"] = int(data["seed"])
    materials = {name: make_material(name, definition) for name, definition in data["materials"].items()}
    terrain_root = empty("AuthoredTerrain", root)
    for record in data["terrain"]:
        terrain_box(record, materials[record["mat"]], terrain_root)

    zones = {name: empty(name, root) for name in data["zones"]}
    library = AssetLibrary()
    for index, record in enumerate(data["props"]):
        library.instance(record, index, zones[record["zone"]])

    # Templates are kept in the .blend for fast iteration but are outside the exported hierarchy.
    setup_preview(root)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE))
    bpy.context.scene.render.filepath = str(PREVIEW)
    bpy.ops.render.render(write_still=True)

    bpy.ops.object.select_all(action="DESELECT")
    for obj in descendants(root):
        obj.hide_set(False)
        obj.hide_render = False
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
    print(
        "PLAYTEST_HOLLOW_BUILD props=%d terrain=%d blend=%s glb=%s preview=%s"
        % (len(data["props"]), len(data["terrain"]), SOURCE, EXPORT, PREVIEW)
    )


if __name__ == "__main__":
    main()
