"""Close-up, all-sides inspection of a standing asset's lower trunk.

Run with:
  Blender --background --python tools/blender/trunk_inspect.py -- \
      [--only substring] [--dir assets/environment/exports] [--size N] \
      [--band 4.2] [--elev 4] [--out assets/audit/trees/sheets]

Why this exists
---------------
`audit_all_sides.py` frames the WHOLE asset, so a 19 m tree arrives with its
trunk four pixels wide and every defect at its base invisible — which is exactly
the half of the kit trees Sequoyah has now called out twice. This is the same
instrument aimed lower: it renders only the bottom `--band` metres, from a
near-horizontal camera at roughly eye height, which is the sightline a player
actually walks past a trunk on.

It keeps `audit_all_sides`'s contact-sheet contract, and for the same reason —
**a front view is not a check.** Ten views per asset: eight azimuths, then top
and bottom. The top and bottom views are framed on the base rather than on the
whole asset, because the two defects they exist to catch — a root that floats
above the soil, and a hollow trunk with no cap — both live down there.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector

AZIMUTHS = [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]
COLUMNS = 5


def argv() -> list[str]:
    return sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def opt(name: str, default: str) -> str:
    a = argv()
    return a[a.index(name) + 1] if name in a else default


def clear() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for blocks in (bpy.data.meshes, bpy.data.materials, bpy.data.cameras,
                   bpy.data.lights, bpy.data.objects):
        for block in list(blocks):
            try:
                blocks.remove(block, do_unlink=True)
            except (RuntimeError, ReferenceError):
                pass


def eevee_name() -> str:
    items = bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items.keys()
    for candidate in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        if candidate in items:
            return candidate
    return items[0]


def build_rig(size: int) -> tuple[bpy.types.Object, bpy.types.Object, bpy.types.Object]:
    scene = bpy.context.scene
    scene.render.engine = eevee_name()
    scene.render.resolution_x = size
    scene.render.resolution_y = size
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    scene.view_settings.look = "AgX - Punchy"

    world = bpy.data.worlds.new("TrunkWorld")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.13, 0.15, 0.14, 1.0)
    world.node_tree.nodes["Background"].inputs[1].default_value = 1.0
    scene.world = world

    cam_data = bpy.data.cameras.new("TrunkCam")
    cam_data.type = "ORTHO"
    cam = bpy.data.objects.new("TrunkCam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam

    # The key follows the camera, so no view is judged through its own shadow —
    # the same rule `audit_all_sides` runs under, and for the same reason.
    key = bpy.data.objects.new("TrunkKey", bpy.data.lights.new("TrunkKey", type="SUN"))
    key.data.energy = 3.4
    scene.collection.objects.link(key)

    fill = bpy.data.objects.new("TrunkFill", bpy.data.lights.new("TrunkFill", type="SUN"))
    fill.data.energy = 0.9
    fill.rotation_euler = (math.radians(118.0), 0.0, math.radians(40.0))
    scene.collection.objects.link(fill)

    # A ground plane, because half of what this tool checks is how the asset
    # meets the soil — roots that hover, a flare that floats, a trunk that ends
    # in a visible hole. On a transparent floor none of those read as wrong.
    bpy.ops.mesh.primitive_plane_add(size=120.0, location=(0.0, 0.0, -0.004))
    ground = bpy.context.object
    ground.name = "InspectGround"
    return cam, key, ground


def aim(obj: bpy.types.Object, position: Vector, target: Vector) -> None:
    obj.location = position
    obj.rotation_euler = (target - position).to_track_quat("-Z", "Y").to_euler()


def render_to_array(size: int) -> np.ndarray:
    bpy.ops.render.render()
    tmp = Path(bpy.app.tempdir) / "trunk_view.png"
    bpy.data.images["Render Result"].save_render(filepath=str(tmp))
    loaded = bpy.data.images.load(str(tmp))
    arr = np.array(loaded.pixels[:], dtype=np.float32).reshape(size, size, 4)
    bpy.data.images.remove(loaded)
    return arr[::-1]


def bounds(skip: str) -> tuple[Vector, Vector]:
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH" or obj.name == skip:
            continue
        for corner in obj.bound_box:
            point = obj.matrix_world @ Vector(corner)
            lo = Vector((min(lo.x, point.x), min(lo.y, point.y), min(lo.z, point.z)))
            hi = Vector((max(hi.x, point.x), max(hi.y, point.y), max(hi.z, point.z)))
    return lo, hi


def main() -> None:
    only = opt("--only", "tree_")
    source = Path(opt("--dir", "assets/environment/exports"))
    size = int(opt("--size", "440"))
    band = float(opt("--band", "4.2"))
    elevation = math.radians(float(opt("--elev", "4")))
    out = Path(opt("--out", "assets/audit/trees/sheets"))
    out.mkdir(parents=True, exist_ok=True)

    files = sorted(p for p in source.glob("*.glb") if only in p.name)
    if not files:
        print(f"trunk_inspect: nothing matched {only!r} in {source}")
        return

    for index, path in enumerate(files, start=1):
        clear()
        cam, key, ground = build_rig(size)
        bpy.ops.import_scene.gltf(filepath=str(path))
        lo, hi = bounds(ground.name)
        axis = Vector(((lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5, 0.0))
        distance = 60.0
        views: list[np.ndarray] = []

        cam.data.ortho_scale = band
        target = axis + Vector((0.0, 0.0, band * 0.42))
        for azimuth in AZIMUTHS:
            yaw = math.radians(azimuth)
            offset = Vector((math.cos(yaw) * math.cos(elevation),
                             math.sin(yaw) * math.cos(elevation),
                             math.sin(elevation))) * distance
            aim(cam, target + offset, target)
            key.rotation_euler = cam.rotation_euler
            views.append(render_to_array(size))

        # Top and bottom, framed on the base. Two things this view needs that the
        # eight azimuths do not:
        #
        # * The ground plane is hidden. Looking straight down at the soil line,
        #   it would cover the whole frame.
        # * The near clip is pulled in to just above the band, so the CROWN is
        #   cut away. Without it a top-down of a 19 m tree is a picture of
        #   foliage — the first cut of this tool rendered exactly that for all
        #   eighteen trees, which is a view that cannot fail and therefore
        #   cannot check anything.
        base_span = band * 0.55
        cam.data.ortho_scale = base_span
        ground.hide_render = True
        aim(cam, axis + Vector((0.0, 0.0, distance)), axis)
        key.rotation_euler = cam.rotation_euler
        cam.data.clip_start = distance - band * 0.5
        views.append(render_to_array(size))
        cam.data.clip_start = 0.1
        aim(cam, axis + Vector((0.0, 0.0, -distance)), axis)
        key.rotation_euler = cam.rotation_euler
        views.append(render_to_array(size))
        ground.hide_render = False

        rows = math.ceil(len(views) / COLUMNS)
        sheet = np.zeros((rows * size, COLUMNS * size, 4), dtype=np.float32)
        sheet[..., 3] = 1.0
        for view_index, view in enumerate(views):
            row, column = divmod(view_index, COLUMNS)
            sheet[row * size:(row + 1) * size, column * size:(column + 1) * size] = view

        image = bpy.data.images.new(path.stem, width=sheet.shape[1], height=sheet.shape[0],
                                    alpha=True)
        image.pixels = sheet[::-1].ravel().tolist()
        image.filepath_raw = str(out / f"{path.stem}.png")
        image.file_format = "PNG"
        image.save()
        bpy.data.images.remove(image)
        print(f"[{index}/{len(files)}] {path.stem}  height={hi.z - lo.z:.2f} m", flush=True)

    print("View order: azimuth 0/45/90/135/180 (row 0), 225/270/315, top, bottom (row 1)")


main()
