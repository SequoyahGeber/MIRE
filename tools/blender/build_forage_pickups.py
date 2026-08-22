"""Build MIRE's forage pickup kit — the carried form of seven gathered resources (F-490).

Run with:
  Blender --background --python tools/blender/build_forage_pickups.py

Seven GLBs, a JSON catalog, two preview renders and an editable source. Every
asset here exists because `assets/gatherables/` already ships the thing you
harvest — a medicinal herb, a wild onion, a honeycomb, a resin node, a clay
deposit, a peat cutting, a poison berry bush — and none of them could be placed
in the world, because a harvestable needs an item to yield and an item needs its
own art (F-482).

Why a separate kit rather than more of `build_pickup_kit.py`
------------------------------------------------------------
That file owns `assets/pickups/` end to end: it deletes its EXPECTED_NAMES and
rewrites `catalog.json` from its own builder list, so anything a second author
dropped alongside it would fall out of the catalog on the next rebuild. The art
contract in `docs/ASSET_TRACKER.md` prefers a new small kit per coherent family
anyway, and "the things you forage" is one.

Sizes are real
--------------
Measured against the 1.80 m player and against the real objects, not against
each other: a cut peat turf is a hand-sized brick (~0.30 m), a honeycomb chunk is
about a hand span, a wild onion bulb is 40 mm under a fan of greens twice that
long, a resin lump is a walnut on a chip of bark. TARGET_LONGEST is the contract
and `create_asset()` enforces it, the way `mire_art.SCALE` does for the kits that
predate this one.

Detail wraps the form
---------------------
Everything decorative is placed with `mire_art.radial()`, per task 2.1j: these
are dropped on the ground and looked at from wherever the player is standing.
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
    around,
    assign,
    box,
    cone,
    cylinder_between,
    eevee_engine,
    ico,
    look_at,
    mat,
    move_to_collection,
    radial,
    reset_materials,
    tapered_between,
    world_bounds,
)
from godot_import_lock import import_cache_guard  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "forage"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

#: Longest dimension in metres. The size contract for this kit.
TARGET_LONGEST: dict[str, float] = {
    "pickup_herb": 0.30,          # a picked bunch of yarrow, stems and all
    "pickup_wild_onion": 0.24,    # 40 mm bulb, greens folded back over it
    "pickup_honeycomb": 0.20,     # a broken hand-span of comb
    "pickup_resin": 0.13,         # a walnut of resin on the chip it was cut from
    "pickup_clay": 0.17,          # a dug lump, two hands
    "pickup_peat": 0.30,          # a cut turf, the size a spade takes
    "pickup_poison_berry": 0.15,  # a picked cluster, still on its stem
}

EXPECTED_NAMES = list(TARGET_LONGEST)


# ---------------------------------------------------------------------------
# Builders — all dimensions in real metres
# ---------------------------------------------------------------------------


def build_herb() -> None:
    """A bunch of yarrow-like herb: long stems, feathery leaves, white umbels.

    Built lying down, the way it sits on the ground once dropped. The stems fan
    slightly rather than running parallel, because a hand-picked bunch never
    lines up, and the umbels sit at three different heights so the silhouette
    has a top.
    """
    for i, (angle, rad) in enumerate(radial(5, 0.026, seed=1101, jitter=0.5)):
        spread = (i - 2) * 0.018
        base = (-0.13, spread * 0.4, 0.020 + rad * 0.5)
        tip = (0.11 + (i % 3) * 0.012, spread, 0.020 + rad)
        cylinder_between(f"Herb_Stem_{i + 1}", base, tip, 0.0035, mat("grass_dark"), 5, 0.86)
        # Feathery leaves, alternating down each stem and around it.
        for j, (leaf_angle, leaf_rad) in enumerate(radial(3, 0.020, seed=1101 + i * 7, jitter=0.45)):
            x = -0.09 + j * 0.06
            root = (x, spread * 0.6, 0.021 + rad * 0.8)
            tapered_between(
                f"Herb_Leaf_{i + 1}_{j + 1}",
                root,
                around(root, leaf_angle, leaf_rad, axis="x"),
                0.006, 0.001,
                mat("leaf_pale" if j % 2 else "leaf"), 4,
            )
        # The umbel: a flat head of small florets, built as a ring of beads
        # around the stem tip rather than one disc. A disc has a front and a
        # back and goes black the moment the light is behind it — six beads read
        # as white flower from every azimuth, which is the whole point of 2.1j.
        head = (tip[0] + 0.014, tip[1], tip[2] + 0.002)
        ico(f"Herb_Umbel_{i + 1}", head, (0.009, 0.010, 0.005), mat("flower_white"))
        for k, (floret_angle, floret_rad) in enumerate(radial(6, 0.011, seed=1717 + i * 13, jitter=0.3)):
            ico(f"Herb_Floret_{i + 1}_{k + 1}", around(head, floret_angle, floret_rad),
                (0.0055, 0.0055, 0.0035),
                mat("flower_white" if k % 3 else "flower_cream"), (0.2 * k, 0.1, 0.3))
    # The fibre tie. A picked bunch is a bunch because something holds it.
    cylinder_between("Herb_Tie", (-0.035, -0.021, 0.016), (-0.035, 0.021, 0.016),
                     0.0055, mat("fibre"), 6, 1.0)


def build_wild_onion() -> None:
    """One Allium: a papery white bulb, root hairs under it, hollow greens over.

    The greens are folded back over the bulb rather than standing straight up —
    that is what a pulled onion does the moment it is out of the ground, and it
    keeps the silhouette readable lying on grass instead of a stick on end.
    """
    ico("Onion_Bulb", (0.0, 0.0, 0.022), (0.021, 0.020, 0.024), mat("flower_white"), (0.1, 0.2, 0.0))
    ico("Onion_Bulb_Skin", (0.002, 0.0, 0.026), (0.019, 0.018, 0.019), mat("flower_cream"), (0.3, -0.2, 0.4))
    # Root hairs, right around the base.
    for i, (angle, rad) in enumerate(radial(6, 0.014, seed=2202, jitter=0.4)):
        root = (0.0, 0.0, 0.006)
        tapered_between(f"Onion_Root_{i + 1}", root,
                        around((0.0, 0.0, 0.001), angle, rad + 0.010), 0.0026, 0.0006,
                        mat("clay"), 4)
    # Greens: three leaves leaving the neck at three angles, each bending over.
    for i, (angle, rad) in enumerate(radial(3, 0.012, seed=3303, jitter=0.3)):
        neck = (0.0, 0.0, 0.044)
        knee = around((0.03 + i * 0.012, 0.0, 0.052 + i * 0.006), angle, rad + 0.014, axis="z")
        tip = around((0.075 + i * 0.020, 0.0, 0.016 + i * 0.004), angle, rad + 0.026, axis="z")
        tapered_between(f"Onion_Green_{i + 1}", neck, knee, 0.0060, 0.0048, mat("leaf"), 5)
        tapered_between(f"Onion_Green_Tip_{i + 1}", knee, tip, 0.0048, 0.0009,
                        mat("leaf_light" if i % 2 else "leaf"), 5)
    # The papery flower head this species carries, dry and cream at the neck.
    ico("Onion_Flower", (0.006, 0.004, 0.052), (0.009, 0.009, 0.008), mat("flower_cream"), (0.2, 0.0, 0.5))


def build_honeycomb() -> None:
    """A broken chunk of wild comb: hexagonal cells on BOTH faces, honey running.

    Wild comb is built as a double-sided sheet on a midrib, so a piece torn out
    of a nest has cells on the front and the back and a ragged wax edge all the
    way round. Cells are 6-vertex cones sunk into each face, which is the whole
    reason this asset reads as comb and not as a slab of butter.
    """
    box("Comb_Midrib", (0.0, 0.0, 0.045), (0.150, 0.030, 0.090), mat("wax"))
    cell_r = 0.0125
    for face_index, y_face in enumerate((-0.016, 0.016)):
        for row in range(3):
            for column in range(4):
                offset = cell_r * 0.9 if row % 2 else 0.0
                x = -0.052 + column * 0.031 + offset
                z = 0.020 + row * 0.026
                if abs(x) > 0.062 or z > 0.078:
                    continue
                cone(
                    f"Comb_Cell_{face_index}_{row}_{column}",
                    cell_r, cell_r * 0.72, 0.014,
                    (x, y_face, z), mat("wax"), 6,
                    (math.radians(90), 0.0, math.radians(6 * (row + column))),
                )
                # Honey sits in about a third of the cells, never in a stripe.
                if (row * 4 + column + face_index) % 3 == 0:
                    # Sitting PROUD of the cell mouth, not sunk inside it: honey
                    # recessed behind a wax rim is honey nobody ever sees.
                    ico(
                        f"Comb_Honey_{face_index}_{row}_{column}",
                        (x, y_face * 1.42, z), (cell_r * 0.72, 0.005, cell_r * 0.72),
                        mat("honey"),
                    )
    # Ragged torn edge, all the way round rather than along the bottom.
    for i, (angle, rad) in enumerate(radial(7, 0.072, seed=4404, jitter=0.42)):
        p = around((0.0, 0.0, 0.045), angle, rad, axis="y")
        ico(f"Comb_Tear_{i + 1}", p, (0.011, 0.014, 0.010),
            mat("wax" if i % 2 else "wood_dead"), (0.3 * i, 0.2, 0.4))
    # A drip that has run and stopped, so the honey reads as liquid.
    tapered_between("Comb_Drip", (0.028, 0.006, 0.014), (0.030, 0.006, -0.002),
                    0.008, 0.004, mat("honey"), 6)
    ico("Comb_Drip_Bead", (0.030, 0.006, -0.004), (0.008, 0.008, 0.007), mat("honey"))


def build_resin() -> None:
    """A lump of pine resin on the chip of bark it was cut off with.

    Resin on a trunk is a teardrop that ran and set: fat at the bottom, glossy,
    with older cloudier resin under the fresh bead. The bark chip is what makes
    it read as harvested rather than as a stone.
    """
    box("Resin_Bark", (0.0, 0.0, 0.010), (0.090, 0.052, 0.018), mat("wood_bark_dark"),
        (math.radians(3), math.radians(-4), math.radians(7)))
    box("Resin_Bark_Cut", (0.0, 0.0, 0.019), (0.078, 0.040, 0.004), mat("wood_cut"))
    # The main teardrop, wider at the foot than the head.
    tapered_between("Resin_Bead", (0.004, 0.002, 0.019), (-0.002, -0.004, 0.052),
                    0.026, 0.017, mat("resin"), 10)
    ico("Resin_Bead_Belly", (0.002, 0.000, 0.036), (0.027, 0.025, 0.021), mat("resin"), subdivisions=2)
    ico("Resin_Bead_Cap", (-0.002, -0.004, 0.056), (0.017, 0.016, 0.013), mat("resin"), subdivisions=2)
    # Older runs down two sides plus one at the back, cloudier than the fresh bead.
    for i, (angle, rad) in enumerate(radial(4, 0.022, seed=5505, jitter=0.36)):
        foot = around((0.0, 0.0, 0.019), angle, rad)
        head = around((0.0, 0.0, 0.030 + (i % 2) * 0.012), angle, rad * 0.72)
        tapered_between(f"Resin_Run_{i + 1}", foot, head, 0.010, 0.005,
                        mat("pine_dark" if i % 3 == 0 else "resin"), 6)
    # Pine needles stuck in it, because everything sticks to fresh resin.
    for i, (angle, rad) in enumerate(radial(3, 0.026, seed=6606, jitter=0.5, phase=1.1)):
        base = around((0.0, 0.0, 0.030), angle, rad * 0.5)
        tapered_between(f"Resin_Needle_{i + 1}", base, around((0.0, 0.0, 0.024 + i * 0.006), angle, rad + 0.016),
                        0.0022, 0.0006, mat("pine"), 4)


def build_clay() -> None:
    """A dug lump of wet clay: pressed, not round, with the dig marks still on it.

    Clay comes out of a bank in slabs that slump. Three overlapping masses give
    the slump; the flat facets are where the spade went in, and they face
    different ways so it never reads as a sphere.
    """
    ico("Clay_Mass", (0.0, 0.0, 0.048), (0.078, 0.066, 0.046), mat("clay"), (0.2, -0.16, 0.3))
    for i, (angle, rad) in enumerate(radial(3, 0.046, seed=7707, jitter=0.4)):
        p = around((0.0, 0.0, 0.038 + i * 0.010), angle, rad)
        ico(f"Clay_Lobe_{i + 1}", p, (0.038 - i * 0.005, 0.034, 0.030), mat("clay"),
            (0.3 * i, 0.2, 0.4 * i))
    # Spade facets: shallow flat plates pressed into three different faces.
    for i, (angle, rad) in enumerate(radial(4, 0.052, seed=8808, jitter=0.30, phase=0.7)):
        p = around((0.0, 0.0, 0.046 + (i % 2) * 0.014), angle, rad * 0.88)
        box(f"Clay_Facet_{i + 1}", p, (0.034, 0.030, 0.008), mat("terrain_path"),
            (0.0, math.radians(72), angle))
    # Grit and a stone the clay came up with.
    for i, (angle, rad) in enumerate(radial(3, 0.048, seed=9909, jitter=0.5, phase=2.0)):
        ico(f"Clay_Grit_{i + 1}", around((0.0, 0.0, 0.028 + i * 0.016), angle, rad),
            (0.008, 0.007, 0.006), mat("stone_dark"), (0.4 * i, 0.1, 0.2))


def build_peat() -> None:
    """One cut turf: a spade-sized brick, grass on top, black peat underneath.

    This is the shape a peat spade actually leaves — a long brick with square cut
    faces and one ragged end where it broke off the bank. The living layer stays
    on top, which is the only reason a cut turf is recognisable at a glance.
    """
    box("Peat_Body", (0.0, 0.0, 0.038), (0.280, 0.110, 0.076), mat("peat"))
    # The cut faces. A spade shears peat SMOOTHER and slightly darker than the
    # torn body, and it is peat all the way through — an early pass painted these
    # in moss and the turf came out a green brick with a green side.
    for i, (dx, dy, sx, sy) in enumerate((
        (0.141, 0.0, 0.004, 0.106),
        (-0.141, 0.0, 0.004, 0.106),
        (0.0, 0.056, 0.272, 0.004),
        (0.0, -0.056, 0.272, 0.004),
    )):
        box(f"Peat_Cut_{i + 1}", (dx, dy, 0.036), (sx, sy, 0.066), mat("peat"))
    # The fibrous band just under the living lid, where roots are still in it.
    box("Peat_Root_Band", (0.0, 0.0, 0.070), (0.278, 0.109, 0.010), mat("leaf_litter"))
    # The living lid: turf, moss and dry grass, sitting proud of the cut sides.
    box("Peat_Turf", (0.0, 0.0, 0.082), (0.276, 0.108, 0.014), mat("moss"))
    for i, (angle, rad) in enumerate(radial(7, 0.090, seed=1212, jitter=0.5)):
        p = around((0.0, 0.0, 0.089), angle, rad)
        p = (max(-0.128, min(0.128, p[0])), max(-0.046, min(0.046, p[1])), p[2])
        ico(f"Peat_Moss_{i + 1}", p, (0.024, 0.020, 0.008),
            mat("moss_light" if i % 2 else "moss"), (0.1 * i, 0.2, 0.3 * i))
        tapered_between(f"Peat_Grass_{i + 1}", p, (p[0] + 0.012 - (i % 3) * 0.010, p[1] + 0.008, p[2] + 0.036),
                        0.0035, 0.0008, mat("grass_dry" if i % 3 else "grass_dark"), 4)
    # The broken end, and roots hanging out of the black face.
    ico("Peat_Break", (-0.144, 0.008, 0.030), (0.014, 0.040, 0.030), mat("peat"), (0.2, 0.3, 0.1))
    for i, (angle, rad) in enumerate(radial(4, 0.030, seed=1313, jitter=0.45)):
        base = around((0.140, 0.0, 0.034), angle, rad * 0.6, axis="x")
        tapered_between(f"Peat_Root_{i + 1}", base, (base[0] + 0.020, base[1] * 1.3, base[2] - 0.010),
                        0.0030, 0.0008, mat("leaf_litter"), 4)


def build_poison_berry() -> None:
    """A picked cluster of dark berries — the ones you should not eat.

    Everything about it says stop: near-black fruit under a blue-white bloom, a
    red-flushed stem, and the drooping cluster shape of belladonna rather than
    the tight bunch of the edible berry pickup. Held next to `pickup_berry` the
    two must never be confused, so the silhouette differs too — this one hangs.
    """
    cylinder_between("Poison_Stem", (-0.052, 0.004, 0.050), (0.018, -0.002, 0.062),
                     0.0045, mat("flower_rust"), 6, 0.85)
    for i, (angle, rad) in enumerate(radial(7, 0.026, seed=1414, jitter=0.42)):
        hang = 0.030 + (i % 3) * 0.011
        anchor = (0.018 - (i % 4) * 0.013, -0.002, 0.060)
        centre = around((anchor[0], anchor[1], anchor[2] - hang), angle, rad)
        tapered_between(f"Poison_Pedicel_{i + 1}", anchor, centre, 0.0026, 0.0016, mat("flower_rust"), 4)
        # Near-black, not the red of `pickup_berry`. Belladonna fruit is almost
        # black and glossy; if these read as red they read as food.
        ico(f"Poison_Berry_{i + 1}", centre, (0.0135, 0.0130, 0.0125), mat("mire_black"),
            (0.2 * i, 0.3, 0.1 * i))
        # The bloom: a smaller pale shell sitting on the sunward face of each
        # berry, placed radially so no two catch the light the same way.
        ico(f"Poison_Bloom_{i + 1}", around(centre, angle + 0.9, 0.006),
            (0.0075, 0.0072, 0.0060), mat("berry_bloom"), (0.4, 0.1 * i, 0.2))
    # Two leaves left on the stem, on opposite sides.
    for i, (angle, rad) in enumerate(radial(2, 0.030, seed=1515, jitter=0.2, phase=1.4)):
        root = (-0.032 + i * 0.020, 0.002, 0.054)
        tapered_between(f"Poison_Leaf_{i + 1}", root, around(root, angle, rad), 0.011, 0.002,
                        mat("leaf_deep" if i else "leaf"), 4)


# ---------------------------------------------------------------------------
# Export, catalog, preview — the same shape build_pickup_kit.py uses
# ---------------------------------------------------------------------------


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

    # Same contract as `mire_art.SCALE` enforces for the older kits: the builder
    # owns the SHAPE, the table owns the SIZE.
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
        ("pickup_herb", "organic", build_herb),
        ("pickup_wild_onion", "food", build_wild_onion),
        ("pickup_honeycomb", "food", build_honeycomb),
        ("pickup_resin", "organic", build_resin),
        ("pickup_clay", "mineral", build_clay),
        ("pickup_peat", "mineral", build_peat),
        ("pickup_poison_berry", "food", build_poison_berry),
    ]
    if [name for name, _, _ in builders] != EXPECTED_NAMES:
        raise RuntimeError("forage kit specification and expected export list diverged")

    records: list[dict] = []
    for index, (name, family, builder) in enumerate(builders):
        column = index % 4
        row = index // 4
        location = ((column - 1.5) * 0.42, (0.26 - row * 0.46), 0.0)
        records.append(create_asset(name, family, builder, location))

    complaints = [
        f"{r['name']}: longest {max(r['width'], r['depth'], r['height']):.3f} m "
        f"against target {TARGET_LONGEST[r['name']]:.3f} m"
        for r in records
        if abs(max(r["width"], r["depth"], r["height"]) / TARGET_LONGEST[r["name"]] - 1.0) > 0.02
    ]
    if complaints:
        raise SystemExit("scale contract failed:\n  " + "\n  ".join(complaints))

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
            "materials": record["materials"],
        }
        for record in records
    ]
    (ASSET_DIR / "catalog.json").write_text(json.dumps(catalog, indent=2) + "\n")

    scene, camera, preview_collection = setup_render()

    for record in records:
        set_visible(record, True)
    camera.data.ortho_scale = 2.1
    camera.location = (1.6, -2.3, 1.4)
    look_at(camera, (0.0, 0.0, 0.06))
    scene.render.filepath = str(PREVIEW_DIR / "forage_preview.png")
    bpy.ops.render.render(write_still=True)

    for record in records:
        set_visible(record, record["name"] in {"pickup_peat", "pickup_honeycomb", "pickup_herb",
                                               "pickup_wild_onion"})
    ref = box("Scale_Reference_Human", (-1.35, 0.10, 0.90), (0.34, 0.20, 1.80), mat("reference_blue"))
    move_to_collection([ref], preview_collection)
    camera.data.ortho_scale = 3.6
    camera.location = (2.0, -3.4, 1.9)
    look_at(camera, (-0.30, 0.0, 0.90))
    scene.render.filepath = str(PREVIEW_DIR / "forage_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "forage_pickups.blend"))
    total = sum(r["polygons"] for r in records)
    print(f"forage pickups: {len(records)} assets, {total} polygons")
    for r in records:
        print(f"  {r['name']:24s} {r['width']:.3f} x {r['depth']:.3f} x {r['height']:.3f} m  {r['polygons']:4d} polys")


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
