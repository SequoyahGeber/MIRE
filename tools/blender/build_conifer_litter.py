"""Build MIRE's conifer litter kit — the cones that lie under a pine (F-492).

Run with:
  Blender --background --python tools/blender/build_conifer_litter.py

Three GLBs, a JSON catalog, two preview renders and an editable source. The kit
exists because `tree_pine_*` is one of the most common props in the world —
`content/scatter/highland_pines.tres` and `forest_canopy.tres` both place six
species of it — and standing under one yielded nothing at all. A pinecone is the
thing you actually find there, and it is the throwable the early game was missing:
you gather it bare-handed off the floor and you throw it, so it is its own ammo.

Why a separate kit rather than more of `build_forage_pickups.py`
---------------------------------------------------------------
Same reason that file gives for not extending `build_pickup_kit.py`: each builder
deletes its own EXPECTED_NAMES and rewrites its `catalog.json` from its own list,
so two authors in one kit lose each other's exports on the next rebuild. "The
litter a conifer drops" is its own coherent family, and it has room to grow — a
fallen needle mat and a spruce cone belong here later.

Built from the real cone, not from the idea of one
--------------------------------------------------
Scots pine (*Pinus sylvestris*), the pine these trees are drawn from. A seed cone
is ovoid-conic and 3–8 cm long; the woody ovuliferous scales are **imbricate and
spirally arranged** around one central axis, and each scale's exposed outer end
is an *apophysis* carrying a small central boss, the *umbo*. Three facts drive
the geometry here and none of them are stylistic:

* The spiral is real and it is what makes a cone read as a cone rather than as a
  brown fir tree. Scales are placed at the golden angle (137.5°) up the axis, so
  no two neighbouring scales line up and the parastichies fall out on their own.
* A cone is **ovoid**: fattest a third of the way up from the base, tapering to a
  point at the apex and narrowing again at the stalk. A cylinder of scales reads
  as a corn cob.
* Open and closed are different objects, not the same object at two sizes. A cone
  that has shed its seed flares its scales out and downward and roughly doubles
  its width; an unopened one keeps them pressed flat along the axis, pointing at
  the apex. Both are on the ground under a real pine, so both are here.

Everything is built LYING DOWN, along +X with the axis horizontal, because that
is how a cone sits once it has fallen and it is the silhouette the player sees
from standing height.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from typing import Callable

sys.path.append(str(Path(__file__).resolve().parent))

import bpy
from mathutils import Vector

from mire_art import (
    assign,
    ico,
    box,
    cylinder_between,
    eevee_engine,
    look_at,
    mat,
    move_to_collection,
    reset_materials,
    tapered_between,
    world_bounds,
)
from godot_import_lock import import_cache_guard  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "conifer_litter"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

#: Longest dimension in metres. The size contract for this kit, and it is the
#: real range: Scots pine seed cones run 3–8 cm. The open one is the big mature
#: cone you notice, the small one is the runt you mostly walk past.
TARGET_LONGEST: dict[str, float] = {
    "pinecone_open": 0.075,    # mature, shed, scales flared — the one you pick up
    "pinecone_closed": 0.062,  # unopened, scales pressed flat along the axis
    "pinecone_small": 0.044,   # a second-year runt, half the mass
}

EXPECTED_NAMES = list(TARGET_LONGEST)

#: 137.507°, the golden angle. The spiral is the entire reason a cone reads as a
#: cone; laying scales in rings instead produces a pineapple.
GOLDEN_ANGLE = math.pi * (3.0 - math.sqrt(5.0))

#: Cycled across the spiral so neighbouring scales differ in tone. A cone's
#: scales are never one flat brown, and cycling the material costs nothing —
#: the export joins into one mesh with one slot per colour either way.
SCALE_TONES: tuple[str, ...] = ("wood_bark", "wood_bark_dark", "wood_bark", "wood_bark_light")


def _cone_radius(t: float, waist: float) -> float:
    """Ovoid profile: fat a third up from the base, pointed at the apex.

    ``t`` runs 0 at the stalk to 1 at the tip. The curve is deliberately not a
    straight taper — a linear cone is a party hat, and the shoulder low down is
    what a real seed cone has.
    """
    return waist * math.sin(math.pi * (0.18 + 0.72 * t)) ** 0.72


def _tile_rotation(direction: Vector, width_dir: Vector) -> tuple[float, float, float]:
    """XYZ euler that points a box's local +X down ``direction`` and +Y along ``width_dir``.

    A cone scale is a flat, wide, overlapping TILE, not a spike, so the plate has
    to be steered in two axes at once: which way it runs, and which way it is
    broad. The first pass here used the one-axis `tapered_between` spike and the
    result read as a fish skeleton — the scales stood off the axis like ribs
    instead of tiling over it.

    Blender's XYZ euler composes as ``Rz(yaw) @ Ry(pitch) @ Rx(roll)``, so yaw and
    pitch aim the long axis and roll then spins the plate about it until it is
    broad the way the cone's surface is broad.
    """
    d = direction.normalized()
    yaw = math.atan2(d.y, d.x)
    pitch = -math.asin(max(-1.0, min(1.0, d.z)))
    # Where local +Y has landed once yaw and pitch are applied, and how far it
    # still has to turn about the plate's own long axis to lie tangential.
    cy, sy = math.cos(yaw), math.sin(yaw)
    cp, sp = math.cos(pitch), math.sin(pitch)
    y_axis = Vector((-sy, cy, 0.0))
    z_axis = Vector((cy * sp, sy * sp, cp))
    w = width_dir.normalized()
    roll = math.atan2(w.dot(z_axis), w.dot(y_axis))
    return (roll, pitch, yaw)


def pine_cone(prefix: str, length: float, waist: float, rows: int, openness: float) -> None:
    """One seed cone lying along +X, stalk at -X, apex at +X.

    ``openness`` 0 is an unopened cone — scales appressed, each tile lying back
    along the surface toward the apex and overlapping the one below it, so the
    cone is a closed brown spindle. 1 is a shed cone: the same tiles hinge out
    and back toward the stalk, opening the gaps between them and roughly doubling
    the cone's width. Both are lying under a real pine, so both are built.

    ``rows`` is the number of scales, and it is high on purpose — a Scots pine
    cone carries 80-90 megasporophylls, and a dozen big ones reads as a pine
    branch rather than as a cone.
    """
    axis = Vector((1.0, 0.0, 0.0))
    rest = waist * (1.15 + 0.55 * openness)
    base = Vector((-length * 0.5, 0.0, rest))

    # The rachis. Between the scales on an open cone and completely hidden on a
    # closed one, which is correct for both.
    tapered_between(f"{prefix}_Axis", tuple(base), tuple(base + axis * length),
                    waist * 0.42, waist * 0.10, mat("wood_bark_dark"), 6)

    tile_len = length * (0.20 + 0.06 * openness)
    tile_wide = tile_len * (0.82 + 0.26 * (1.0 - openness))
    tile_thick = length * 0.030

    for i in range(rows):
        t = (i + 0.5) / rows
        angle = i * GOLDEN_ANGLE
        radius = _cone_radius(t, waist)
        seat = base + axis * (t * length)
        outward = Vector((0.0, math.cos(angle), math.sin(angle)))
        tangent = axis.cross(outward).normalized()
        # Which way the tile runs. Appressed cones point their scales at the apex
        # and lie almost flat on the surface (a high positive elevation); a shed
        # cone hinges the same tile out past perpendicular and back down toward
        # the stalk, which is what opens the gaps.
        elevation = math.radians(71.0) * (1.0 - openness) - math.radians(26.0) * openness
        direction = (axis * math.sin(elevation) + outward * math.cos(elevation)).normalized()
        # Seated ON the surface, not radiating from the core: the tile's inner
        # end sits at the cone's own radius and the plate covers outward from
        # there, so consecutive scales overlap like slates.
        inner = seat + outward * (radius * 0.55)
        centre = inner + direction * (tile_len * 0.5)
        rotation = _tile_rotation(direction, tangent)
        box(f"{prefix}_Scale_{i + 1}", tuple(centre), (tile_len, tile_wide, tile_thick),
            mat(SCALE_TONES[i % len(SCALE_TONES)]), rotation)
        # The apophysis: the thickened, paler, outward-facing end of the scale. It
        # is the only part of a cone that catches light, so it is what carries the
        # silhouette at the distance the player actually sees these from — but it
        # is also a second box per scale, and this asset is placed by the hundred.
        # Every OTHER scale gets one: the pale ends still ring the cone, and the
        # tone cycle above keeps the ones without from reading as a bald patch.
        if i % 2 == 0:
            face = inner + direction * (tile_len * 0.92)
            box(f"{prefix}_Apophysis_{i + 1}", tuple(face),
                (tile_len * 0.30, tile_wide * 0.94, tile_thick * 1.5),
                mat("wood_bark_light" if i % 3 else "leaf_dry"), rotation)

    # The stalk. A cone that fell off a branch broke off it, and the short woody
    # stub is what says "this dropped" rather than "this grew here".
    cylinder_between(f"{prefix}_Stalk", tuple(base),
                     tuple(base - axis * (length * 0.10) - Vector((0.0, 0.0, waist * 0.06))),
                     waist * 0.24, mat("wood_bark_dark"), 5, 0.82)


def build_pinecone_open() -> None:
    """The mature, shed cone — the hero of the kit and the item's own model."""
    pine_cone("Cone_Open", 0.068, 0.011, 36, 1.0)


def build_pinecone_closed() -> None:
    """Unopened: scales shut along the axis, so it reads as a solid brown spindle."""
    pine_cone("Cone_Closed", 0.058, 0.0075, 32, 0.10)


def build_pinecone_small() -> None:
    """A runt. Same construction, fewer scales — not the open cone shrunk."""
    pine_cone("Cone_Small", 0.040, 0.0072, 20, 0.62)


# ---------------------------------------------------------------------------
# Export, catalog, preview — the same shape build_forage_pickups.py uses
# ---------------------------------------------------------------------------



def _join_into_one(name: str, made: list) -> bpy.types.Object:
    """Collapse an asset to ONE mesh with one material slot per colour.

    Not an optimisation — a correctness fix. Every `box()` is its own Blender
    object, so a cone exported as 105 separate mesh parts, and
    `world/gen/resource_scatter_field.gd` does not merge: it instantiates the GLB
    and builds one `MultiMeshInstance3D` per part it finds. A hundred cones in a
    chunk therefore asked for ten thousand nodes, and the headless
    `tools/resource_scatter_check.gd` run segfaulted inside `_load_mesh_parts()`
    roughly one run in three. `build_flora_set.py` learnt the same lesson (its
    first scatter built 757 nodes across 78 assets) and fixed it the same way:
    join at export time, which is where the fix belongs.

    Joining LAST matters. Blender does not refresh a cached bound box after
    `bpy.ops.object.join()`, so anything that measures the asset has to run
    before this or it measures whichever component happened to be first.
    """
    meshes = [obj for obj in made if obj.type == "MESH"]
    if not meshes:
        raise RuntimeError(f"{name} produced no mesh objects")
    bpy.ops.object.select_all(action="DESELECT")
    for obj in meshes:
        obj.select_set(True)
    target = meshes[0]
    bpy.context.view_layer.objects.active = target
    if len(meshes) > 1:
        bpy.ops.object.join()
    # An identity node transform on the far side of the export: the join keeps
    # whichever rotation the first component carried, and Godot's local
    # `get_aabb()` would then have to rotate an axis-aligned box and answer too
    # large.
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    bpy.ops.object.select_all(action="DESELECT")
    target.name = name.title().replace("_", "")
    for polygon in target.data.polygons:
        polygon.use_smooth = False
    return target


def create_asset(name: str, family: str, build_fn: Callable[[], None],
                 display_location: tuple[float, float, float]) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(f"{name}_root", None)
    collection.objects.link(root)
    before = set(bpy.data.objects)
    build_fn()
    made = [obj for obj in bpy.data.objects if obj not in before]

    bpy.context.view_layer.update()
    minimum, maximum = world_bounds(made)
    offset = Vector((-(minimum.x + maximum.x) * 0.5, -(minimum.y + maximum.y) * 0.5, -minimum.z))
    for obj in made:
        obj.location += offset
    move_to_collection(made, collection)
    for obj in made:
        obj.parent = root
    bpy.context.view_layer.update()
    minimum, maximum = world_bounds(made)

    target = TARGET_LONGEST[name]
    longest = max((maximum - minimum).x, (maximum - minimum).y, (maximum - minimum).z)
    if longest > 1e-6 and abs(longest / target - 1.0) > 1e-4:
        factor = target / longest
        for obj in made:
            obj.scale = (factor, factor, factor)
            obj.location = obj.location * factor
        bpy.ops.object.select_all(action="DESELECT")
        for obj in made:
            obj.select_set(True)
        bpy.context.view_layer.objects.active = made[0]
        bpy.ops.object.transform_apply(scale=True)
        bpy.ops.object.select_all(action="DESELECT")
        bpy.context.view_layer.update()
        minimum, maximum = world_bounds(made)
        offset = Vector((-(minimum.x + maximum.x) * 0.5,
                         -(minimum.y + maximum.y) * 0.5, -minimum.z))
        for obj in made:
            obj.location += offset
        bpy.context.view_layer.update()
        minimum, maximum = world_bounds(made)

    dimensions = maximum - minimum
    # Everything above measures; the join goes here, after the last measurement
    # and before the export.
    made = [_join_into_one(name, made)]
    for obj in made:
        for old in list(obj.users_collection):
            old.objects.unlink(obj)
        collection.objects.link(obj)
        obj.parent = root
    bpy.context.view_layer.update()
    polygons = sum(len(obj.data.polygons) for obj in made if obj.type == "MESH")
    materials = sorted({m.name for obj in made if obj.type == "MESH" for m in obj.data.materials if m})

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
        "name": name, "family": family, "root": root,
        "width": dimensions.x, "depth": dimensions.y, "height": dimensions.z,
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons, "materials": materials,
        "triangles": sum(
            sum(max(0, len(polygon.vertices) - 2) for polygon in obj.data.polygons)
            for obj in made if obj.type == "MESH"
        ),
    }


def set_visible(record: dict, visible: bool) -> None:
    record["root"].hide_render = not visible
    for child in record["root"].children_recursive:
        child.hide_render = not visible


def setup_render() -> tuple[bpy.types.Scene, bpy.types.Object, bpy.types.Collection]:
    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.mesh.primitive_plane_add(size=40, location=(0.0, 0.0, -0.004))
    floor = bpy.context.object
    floor.name = "Preview_Ground"
    assign(floor, mat("preview_ground"))
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
    scene.render.engine = eevee_engine()
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
    reset_materials()

    builders: list[tuple[str, str, Callable[[], None]]] = [
        ("pinecone_open", "conifer", build_pinecone_open),
        ("pinecone_closed", "conifer", build_pinecone_closed),
        ("pinecone_small", "conifer", build_pinecone_small),
    ]
    if [name for name, _, _ in builders] != EXPECTED_NAMES:
        raise RuntimeError("conifer litter specification and expected export list diverged")

    records: list[dict] = []
    for index, (name, family, builder) in enumerate(builders):
        records.append(create_asset(name, family, builder, ((index - 1) * 0.16, 0.0, 0.0)))

    complaints = [
        f"{r['name']}: longest {max(r['width'], r['depth'], r['height']):.3f} m "
        f"against target {TARGET_LONGEST[r['name']]:.3f} m"
        for r in records
        if abs(max(r["width"], r["depth"], r["height"]) / TARGET_LONGEST[r["name"]] - 1.0) > 0.02
    ]
    # The open cone must actually be OPEN: flared scales roughly double a cone's
    # width, and if this ever stops holding, the kit has silently become three
    # copies of the same spindle at three sizes.
    open_record = next(r for r in records if r["name"] == "pinecone_open")
    closed_record = next(r for r in records if r["name"] == "pinecone_closed")
    open_stoutness = max(open_record["depth"], open_record["height"]) / open_record["width"]
    closed_stoutness = max(closed_record["depth"], closed_record["height"]) / closed_record["width"]
    if open_stoutness < closed_stoutness * 1.35:
        complaints.append(
            f"open cone is not visibly open: stoutness {open_stoutness:.2f} "
            f"against the closed cone's {closed_stoutness:.2f}"
        )
    if complaints:
        raise SystemExit("conifer litter contract failed:\n  " + "\n  ".join(complaints))

    catalog = [
        {
            "name": record["name"],
            "family": record["family"],
            "file": f"exports/{record['name']}.glb",
            "width_m": round(record["width"], 4),
            "depth_m": round(record["depth"], 4),
            "height_m": round(record["height"], 4),
            "target_m": TARGET_LONGEST[record["name"]],
            "mesh_parts": record["parts"],
            "polygons": record["polygons"],
            "triangles": record["triangles"],
            "materials": record["materials"],
        }
        for record in records
    ]
    (ASSET_DIR / "catalog.json").write_text(json.dumps(catalog, indent=2) + "\n")

    scene, camera, preview_collection = setup_render()

    for record in records:
        set_visible(record, True)
    camera.data.ortho_scale = 0.42
    camera.location = (0.30, -0.44, 0.24)
    look_at(camera, (0.0, 0.0, 0.022))
    scene.render.filepath = str(PREVIEW_DIR / "conifer_litter_preview.png")
    bpy.ops.render.render(write_still=True)

    for record in records:
        set_visible(record, record["name"] == "pinecone_open")
    open_record["root"].location = (0.0, 0.0, 0.0)
    ref = ico("Scale_Reference_Hand", (0.0, 0.10, 0.009), (0.090, 0.045, 0.009), mat("reference_blue"))
    move_to_collection([ref], preview_collection)
    camera.data.ortho_scale = 0.34
    camera.location = (0.26, -0.34, 0.20)
    look_at(camera, (0.0, 0.045, 0.02))
    scene.render.filepath = str(PREVIEW_DIR / "conifer_litter_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "conifer_litter.blend"))
    total = sum(r["polygons"] for r in records)
    print(f"conifer litter: {len(records)} assets, {total} polygons")
    for r in records:
        print(f"  {r['name']:18s} {r['width']:.3f} x {r['depth']:.3f} x {r['height']:.3f} m  "
              f"{r['parts']:3d} parts  {r['polygons']:4d} polys")


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
