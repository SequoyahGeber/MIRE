"""A-011 — gatherable plants and deposits: the things a player walks up to and takes.

  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender/build_gatherable_plants.py

Ten assets in `assets/gatherables/`, built with Blender 5.2.0 LTS (D-038 pins the toolchain).

This family is not decoration. Every asset here is a *node a player interacts with*, so the bar it
has to clear is different from the flora kit's: it must be recognisable as its own item from across
a clearing, and telling two of them apart has to be possible on sight. That drives three choices:

**Silhouette carries the identity, not colour.** A bush, a fan of blades, a rosette, a tubular
clump, a hanging comb, a low mound, a stack of cut blocks, a tapped trunk — no two of these read the
same at ten metres even in fog, which is the condition MIRE is usually viewed in.

**The poison berry bush is a deliberate near-copy.** `ITEMS.md` §4.1 calls for it to look "almost
identical" to the safe bush (the D7 tone rule: the joke is that you have to actually learn it). So
it is built from the identical frame with the identical berry geometry, and carries exactly two
tells: its foliage is `leaf_deep` rather than `leaf`, and its berries wear a pale `berry_bloom` film
on their upward faces. Both are learnable at arm's length and neither is visible across a clearing,
which is the intended trade. The bloom costs zero geometry — it is `paint_faces` on the berry mesh,
not a second berry.

**The two state siblings share an anchor.** `berry_bush_full` and `berry_bush_harvested` are the
same bush with and without fruit, so they are centred on the geometry they SHARE (the woody frame
and foliage) rather than on each one's own bounds. Normalising them independently would shift the
bush sideways at the exact moment gameplay swaps the mesh, which is what A-005 hit on its chests.
The measured drift is asserted below and recorded in the tracker row.
"""

from __future__ import annotations

import json
import math
import random
import sys
from pathlib import Path
from typing import Callable

import bpy
from mathutils import Vector

sys.path.append(str(Path(__file__).resolve().parent))

from mire_art import (  # noqa: E402
    Batch,
    assign,
    cone,
    cylinder_between,
    eevee_engine,
    ground_and_centre,
    hull,
    look_at,
    mat,
    paint_faces,
    radial,
    reset_materials,
    tapered_between,
    world_bounds,
)
from godot_import_lock import import_cache_guard  # noqa: E402


def box(
    name: str,
    location: tuple[float, float, float],
    dimensions: tuple[float, float, float],
    material: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
    bevel: float = 0.0,
) -> bpy.types.Object:
    """Bevel-free box, overriding ``mire_art.box`` on purpose (D-124, F-206).

    A-011's six `bevel=` sites passed straight through to `mire_art.box()`'s live
    BEVEL modifier with no local override — a latent D-124 exposure (F-206) until
    this row claimed a byte-identical rebuild. `bevel` is accepted and ignored so
    every call site below reads unchanged.
    """
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = (dimensions[0] * 0.5, dimensions[1] * 0.5, dimensions[2] * 0.5)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, material)


ROOT = Path(__file__).resolve().parents[2]
EXPORT_DIR = ROOT / "assets" / "gatherables" / "exports"
PREVIEW_DIR = ROOT / "assets" / "gatherables" / "preview"
CATALOG_PATH = ROOT / "assets" / "gatherables" / "catalog.json"
SOURCE_DIR = ROOT / "assets" / "source"
SOURCE_PATH = SOURCE_DIR / "gatherable_plants.blend"

#: Target size in metres, the axis it governs, and a hard footprint ceiling.
#:
#: One exact target rather than the flora kit's band, because these are not seeded
#: variants of each other — there is one wild onion, and it should be the size a
#: wild onion is. The footprint ceiling is separate for the reason A-000V paid to
#: learn: scaling a wide, low thing to a HEIGHT target multiplies its reach by the
#: same factor, and a 0.34 m herb that is two metres across is not a herb.
#:
#: Set against a 1.80 m player: shin 0.2, knee 0.5, waist 1.0, chest 1.4.
SIZE: dict[str, tuple[float, str, float]] = {
    "berry_bush_full": (0.78, "height", 1.10),
    "berry_bush_harvested": (0.78, "height", 1.10),
    "poison_berry_bush": (0.78, "height", 1.10),
    "fibre_plant": (0.88, "height", 0.95),
    "medicinal_herb": (0.34, "height", 0.72),
    "wild_onion": (0.46, "height", 0.62),
    "honeycomb": (0.38, "height", 0.52),
    "clay_deposit": (0.92, "spread", 0.98),
    "peat_deposit": (1.06, "spread", 1.12),
    # 0.64 rather than the 0.58 first guessed: this node is a tree trunk, and the
    # cap exists to stop a gatherable sprawling across ground a player walks on,
    # not to keep a pine thin. Widened deliberately, with the asset measured at
    # 0.59 m across including the needle sprigs at its foot.
    "resin_node": (0.74, "height", 0.64),
}

SIZE_TOLERANCE = 0.02

#: Interaction nodes carry a little more detail than scatter flora, but they are
#: still placed in quantity and props have no LOD yet (F-144), so these stay tight.
TRIANGLE_BUDGET = 900
MAX_MATERIALS = 4
#: Per-asset exceptions to the material cap, each with a reason. The cap is about
#: draw cost, so an exception has to buy something — `poison_berry_bush` spends its
#: fifth material on the pale bloom that is the entire reason the asset exists, and
#: spends no geometry at all doing it (`paint_faces`).
MATERIAL_ALLOWANCE = {"poison_berry_bush": 5}

#: The parts every berry-bush state shares. `create_asset` centres the pair on
#: these and nothing else, so adding fruit cannot move the bush.
BUSH_ANCHOR_PREFIXES = ("frame_", "bush_")

#: The bush's three foliage masses, shared by the frame builder and by
#: `berry_sites` so fruit can be placed on an actual surface rather than at a
#: guessed radius. Overlapping hard and unequal: three masses give a silhouette
#: shoulders, three equal masses sitting apart give it three heads.
BUSH_MASSES = [
    ((0.00, 0.03, 0.44), (0.29, 0.27, 0.25)),
    ((-0.19, -0.10, 0.33), (0.23, 0.22, 0.21)),
    ((0.17, -0.13, 0.30), (0.20, 0.21, 0.18)),
]


def seed_for(name: str) -> int:
    """A stable seed per asset name. Deliberately not `hash()`, which is salted
    per process in Python 3 and would make every rebuild a different asset."""
    return sum((index + 3) * ord(char) for index, char in enumerate(name))


#: All three berry-bush states are ONE bush, so they share ONE seed instead of
#: each deriving its own from its name. Seeding them per name is what the first
#: build did, and it quietly produced three different plants: the "state pair"
#: drifted 27.6 mm apart, and the poison bush — which is supposed to be an
#: near-indistinguishable copy — came out 79 mm wider than the safe one with a
#: different number of berries on it. A shared frame has to be literally the same
#: numbers, not the same recipe run twice.
BUSH_SEED = seed_for("berry_bush_full")


# ---------------------------------------------------------------------------
# Shape recipes
# ---------------------------------------------------------------------------


def arc_spine(origin: Vector, angle: float, length: float, rise: float, droop: float,
              segments: int = 4) -> list[Vector]:
    """Points along a stem leaving ``origin`` at ``angle``, lifting then falling over."""
    points = []
    for index in range(segments + 1):
        t = index / segments
        points.append(Vector((
            origin.x + math.cos(angle) * length * t,
            origin.y + math.sin(angle) * length * t,
            origin.z + rise * t - droop * (t ** 2.2),
        )))
    return points


def blade(batch: Batch, token: str, origin: Vector, angle: float, height: float, width: float,
          lean: float, curve: float) -> None:
    """One upright blade that bends over and tapers out.

    Wide and few beats thin and many: a thin blade stops resolving a few metres out
    and turns the plant into fuzz while costing exactly the same triangles.
    """
    spine = [
        Vector((
            origin.x + math.cos(angle) * lean * height * (t ** 1.7),
            origin.y + math.sin(angle) * lean * height * (t ** 1.7),
            origin.z + height * t - curve * height * (t ** 2.4),
        ))
        for t in (0.0, 0.34, 0.68, 1.0)
    ]
    batch.ribbon(token, spine, [width * 0.5, width * 0.44, width * 0.27, 0.004],
                 [width * 0.34, width * 0.28, width * 0.17, 0.002])


def leaf(batch: Batch, token: str, origin: Vector, angle: float, length: float, width: float,
         rise: float, droop: float, fold: float) -> None:
    """One broad leaf, widest a third of the way out and tapering to a point."""
    spine = arc_spine(origin, angle, length, rise, droop, segments=3)
    batch.ribbon(token, spine, [width * 0.5 * v for v in (0.20, 0.95, 0.80, 0.05)],
                 [fold * v for v in (0.35, 1.0, 0.7, 0.1)])


def berry_sites(seed: int) -> list[tuple[Vector, float, int]]:
    """Where fruit hangs on the shared bush: centre, cluster radius, berry count.

    One list, generated once and used by all three states, so the fruiting bush,
    the picked bush's leftover stalks and the poison bush's fruit are in exactly
    the same places.

    Each cluster is placed on the surface of one of the three foliage masses in
    turn, not at a fixed radius from the bush's axis. A fixed radius was the first
    attempt and it buried most of the fruit: the masses are not a sphere, so one
    radius is outside the small masses and well inside the big one, and eight of
    eleven clusters ended up invisible. Elevation is biased downward because that
    is where berries actually hang, and because the underside of the canopy is
    where a player standing next to the bush is looking.
    """
    rng = random.Random(seed + 7)
    sites = []
    for index, (angle, _rad) in enumerate(radial(12, 1.0, seed=seed + 3, jitter=0.42,
                                                 radius_jitter=0.0)):
        (cx, cy, cz), (rx, ry, rz) = BUSH_MASSES[index % len(BUSH_MASSES)]
        elevation = rng.uniform(-0.62, 0.20)
        reach = 0.97
        centre = Vector((
            cx + math.cos(angle) * math.cos(elevation) * rx * reach,
            cy + math.sin(angle) * math.cos(elevation) * ry * reach,
            cz + math.sin(elevation) * rz * reach,
        ))
        sites.append((centre, rng.uniform(0.042, 0.058), rng.randint(4, 6)))
    return sites


def berry_cluster(batch: Batch, rng: random.Random, centre: Vector, radius: float,
                  berries: int, token: str) -> None:
    """A few berries hanging together, which is how berries actually grow.

    One berry per site reads as a speck; a tight group of four reads as fruit and
    tells the player there is something here worth walking to.
    """
    for angle, rad in radial(berries, radius, seed=rng.randint(0, 9999), jitter=0.7,
                             radius_jitter=0.5):
        offset = Vector((math.cos(angle) * abs(rad), math.sin(angle) * abs(rad),
                         -abs(rad) * rng.uniform(0.2, 0.9)))
        size = rng.uniform(0.034, 0.044)
        batch.blob(token, centre + offset, (size, size, size * 0.92), rng)


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------


def build_bush_frame(seed: int, leaf_token: str, leaf_highlight: str) -> list:
    """The woody frame and foliage every berry-bush state shares.

    Three overlapping masses, not one and not eighteen: one reads as an egg,
    eighteen reads as a bag of peas, three gives the silhouette shoulders.
    """
    rng = random.Random(seed)
    made = []
    # Woody stems, fanned so the bush has structure where the foliage parts.
    for index, (angle, rad) in enumerate(radial(4, 0.10, seed=seed, jitter=0.6, radius_jitter=0.4)):
        base = (math.cos(angle) * abs(rad) * 0.4, math.sin(angle) * abs(rad) * 0.4, 0.0)
        tip = (math.cos(angle) * abs(rad) * 1.5, math.sin(angle) * abs(rad) * 1.5,
               rng.uniform(0.30, 0.42))
        # Short, thick and mostly inside the foliage. Long thin stems fanning out
        # below the canopy read as black spider legs at any distance, which is what
        # the first build looked like.
        made.append(cylinder_between(f"frame_stem_{index}", base, tip, 0.026,
                                     mat("wood_bark"), vertices=6))
    for index, (centre, radius) in enumerate(BUSH_MASSES):
        mass = hull(f"bush_mass_{index}", centre, radius, mat(leaf_token), seed=seed + index * 31,
                    lumps=8, lump=0.42, sharpness=1.9, jitter=0.05)
        # Sun-caught crown, painted rather than modelled: costs no geometry and
        # stops the bush reading as one flat green blob.
        #
        # `paint_faces` selects faces whose normal is ABOVE `min_normal_z`, so it
        # can light a crown but cannot shade an underside. Passing -1.0 to mean
        # "the bottom" does not invert it — it accepts every face on the object and
        # `coverage` then scatters the second material at random over the whole
        # bush, which rendered as brown camouflage and read as disease.
        paint_faces(mass, mat(leaf_highlight), min_normal_z=0.34, min_height=0.52,
                    coverage=0.62, seed=seed + index)
        made.append(mass)
    return made


def build_berry_bush_full(_seed: int) -> None:
    seed = BUSH_SEED
    build_bush_frame(seed, "leaf", "leaf_light")
    rng = random.Random(seed + 101)
    batch = Batch()
    for centre, radius, count in berry_sites(seed):
        berry_cluster(batch, rng, centre, radius, count, "berry")
    batch.emit("berries")


def build_berry_bush_harvested(_seed: int) -> None:
    """The same bush after picking: identical frame, no fruit, bare stalks left.

    The stalks matter. Without them the picked state reads as a different, younger
    plant rather than as this plant a moment later, and the player loses the only
    cue that they already took it.
    """
    seed = BUSH_SEED
    build_bush_frame(seed, "leaf", "leaf_light")
    batch = Batch()
    for centre, _radius, _count in berry_sites(seed):
        tip = centre + Vector((0.0, 0.0, -0.045))
        batch.ribbon("wood_dead", [centre, (centre + tip) * 0.5, tip],
                     [0.008, 0.006, 0.002], [0.005, 0.004, 0.001])
    batch.emit("stalks")


def build_poison_berry_bush(_seed: int) -> None:
    """Deliberately the safe bush, to within one tell (`ITEMS.md` §4.1, D7).

    Identical frame, identical foliage colours, identical berry geometry in the
    identical places — the check below asserts the silhouettes match. The single
    difference is a pale waxy `berry_bloom` film on the fruit's upward faces,
    which costs no geometry because it is `paint_faces` on the berry mesh.

    One tell, not three, and it is on the berries rather than the leaves: the
    berry is the thing a player already leans in to look at before eating, so the
    difference is where they will actually be looking. An earlier cut darkened the
    foliage as well and the two bushes were then trivially separable across a
    clearing, which throws away the entire point of the item.
    """
    seed = BUSH_SEED
    build_bush_frame(seed, "leaf", "leaf_light")
    rng = random.Random(seed + 101)
    batch = Batch()
    for centre, radius, count in berry_sites(seed):
        berry_cluster(batch, rng, centre, radius, count, "berry")
    before = {obj.name for obj in bpy.data.objects}
    batch.emit("berries")
    for obj in bpy.data.objects:
        if obj.name not in before and obj.type == "MESH":
            paint_faces(obj, mat("berry_bloom"), min_normal_z=0.25, min_height=0.0,
                        coverage=0.62, seed=seed)


def build_fibre_plant(seed: int) -> None:
    """A standing fan of stiff, strappy blades — the plant rope comes from.

    Upright and narrow on purpose: it has to be distinguishable from a grass
    tussock, and the difference is that this one stands rather than spills.
    """
    rng = random.Random(seed)
    batch = Batch()
    for index, (angle, rad) in enumerate(radial(14, 0.075, seed=seed, jitter=0.55,
                                                radius_jitter=0.6)):
        origin = Vector((math.cos(angle) * abs(rad), math.sin(angle) * abs(rad), 0.01))
        token = ("fibre", "grass_dry", "reed")[index % 3]
        blade(batch, token, origin, angle + rng.uniform(-0.5, 0.5),
              rng.uniform(0.62, 0.92), rng.uniform(0.030, 0.048),
              rng.uniform(0.06, 0.20), rng.uniform(0.10, 0.26))
    # Loose stripped fibre at the base — the thing the player is actually here for,
    # made visible so the plant advertises its own drop.
    for angle, rad in radial(5, 0.11, seed=seed + 5, jitter=0.8, radius_jitter=0.5):
        origin = Vector((math.cos(angle) * abs(rad), math.sin(angle) * abs(rad), 0.012))
        blade(batch, "fibre", origin, angle, rng.uniform(0.10, 0.19), 0.020, 0.9, 0.72)
    batch.emit("fibre_plant")


def build_medicinal_herb(seed: int) -> None:
    """Marshwort: a low rosette of round leaves under a spray of small white heads.

    Rosette plus white flower is the universal "this one is medicine" shape, and
    white is the only bloom colour left that is neither Mire purple nor Ward teal.
    """
    rng = random.Random(seed)
    batch = Batch()
    for index, (angle, rad) in enumerate(radial(9, 0.10, seed=seed, jitter=0.4,
                                                radius_jitter=0.45)):
        origin = Vector((math.cos(angle) * abs(rad) * 0.4, math.sin(angle) * abs(rad) * 0.4, 0.012))
        leaf(batch, "leaf_pale" if index % 3 else "leaf", origin, angle,
             rng.uniform(0.13, 0.20), rng.uniform(0.075, 0.105),
             rng.uniform(0.02, 0.05), rng.uniform(0.03, 0.06), rng.uniform(0.012, 0.022))
    # Flower stems, spread around the rosette rather than bunched on one side.
    for angle, rad in radial(5, 0.055, seed=seed + 11, jitter=0.7, radius_jitter=0.5):
        base = Vector((math.cos(angle) * abs(rad), math.sin(angle) * abs(rad), 0.01))
        top = base + Vector((math.cos(angle) * 0.035, math.sin(angle) * 0.035,
                             rng.uniform(0.20, 0.29)))
        batch.ribbon("grass_dark", [base, (base + top) * 0.5, top],
                     [0.007, 0.006, 0.004], [0.005, 0.004, 0.002])
        for petal_angle, petal_rad in radial(5, 0.022, seed=seed + int(angle * 100), jitter=0.6):
            batch.blob("flower_white",
                       top + Vector((math.cos(petal_angle) * abs(petal_rad),
                                     math.sin(petal_angle) * abs(petal_rad), 0.004)),
                       (0.012, 0.012, 0.007), rng)
    batch.emit("medicinal_herb")


def build_wild_onion(seed: int) -> None:
    """A clump of hollow tubular leaves over a pale bulb that shows above the soil.

    The bulb is the whole reason this is legible: tubular leaves alone are just
    another grass, and a player will not walk across a clearing for grass.
    """
    rng = random.Random(seed)
    made = []
    bulbs = []
    for index, (angle, rad) in enumerate(radial(3, 0.045, seed=seed, jitter=0.5,
                                                radius_jitter=0.35)):
        centre = (math.cos(angle) * abs(rad), math.sin(angle) * abs(rad), 0.042)
        # Built in soil colour and cleaned off on top, not the other way round:
        # `paint_faces` selects faces ABOVE a normal threshold, so the only way to
        # get dirt clinging UNDER a bulb is to make dirt the base material and
        # paint the part that has been rubbed clean.
        bulb = hull(f"onion_bulb_{index}", centre, (0.043, 0.043, 0.052), mat("clay"),
                    seed=seed + index * 17, lumps=5, lump=0.14, sharpness=3.0, taper=0.35)
        paint_faces(bulb, mat("flower_cream"), min_normal_z=0.15, min_height=0.30,
                    coverage=0.85, seed=seed + index)
        made.append(bulb)
        bulbs.append(centre)
    batch = Batch()
    for index, (angle, rad) in enumerate(radial(11, 0.085, seed=seed + 3, jitter=0.6,
                                                radius_jitter=0.55)):
        origin = Vector(bulbs[index % len(bulbs)]) + Vector((0.0, 0.0, 0.035))
        blade(batch, "leaf", origin, angle + rng.uniform(-0.4, 0.4),
              rng.uniform(0.26, 0.40), rng.uniform(0.024, 0.034),
              rng.uniform(0.10, 0.32), rng.uniform(0.18, 0.42))
    # One seed head, because a wild onion in flower is unmistakable.
    head = Vector(bulbs[0]) + Vector((0.02, 0.01, 0.36))
    batch.ribbon("leaf", [Vector(bulbs[0]) + Vector((0, 0, 0.04)), head * 0.7, head],
                 [0.009, 0.007, 0.005], [0.006, 0.005, 0.003])
    for petal_angle, petal_rad in radial(7, 0.030, seed=seed + 21, jitter=0.5):
        batch.blob("flower_white",
                   head + Vector((math.cos(petal_angle) * abs(petal_rad),
                                  math.sin(petal_angle) * abs(petal_rad),
                                  rng.uniform(-0.004, 0.012))),
                   (0.013, 0.013, 0.011), rng)
    batch.emit("wild_onion")


def build_honeycomb(seed: int) -> None:
    """Comb in a bee hollow: a wax sheet against bark, cells facing the player.

    A wax blob is a lump of butter. The cells are the whole read, so they are big,
    deep, and on the face a player approaches — and a third of them are filled,
    because empty comb is the colour of bone and reads as a skull fragment.
    """
    rng = random.Random(seed)
    made = []
    # Bark hollow behind the comb, kept shallow so it frames rather than competes.
    backing = hull("comb_backing", (0.0, 0.075, 0.19), (0.165, 0.048, 0.185),
                   mat("wood_bark_dark"), seed=seed, lumps=6, lump=0.26, sharpness=2.6,
                   flat_base=0.0)
    paint_faces(backing, mat("wood_dead"), min_normal_z=0.35, min_height=0.6, coverage=0.55,
                seed=seed + 1)
    made.append(backing)
    # A sheet, not a ball: comb hangs flat. Thin in Y, wide in X, tall in Z.
    slab = hull("comb_slab", (0.0, 0.005, 0.20), (0.150, 0.032, 0.165), mat("wax"),
                seed=seed + 5, lumps=4, lump=0.12, sharpness=3.6, droop=0.06, droop_lobes=3)
    made.append(slab)
    # Cells in staggered rows — a hex grid is what makes wax read as comb, and it
    # is the one place in this asset worth spending geometry.
    for row in range(3):
        z = 0.135 + row * 0.058
        columns = 4 if row % 2 == 0 else 3
        for column in range(columns):
            x = (column - (columns - 1) * 0.5) * 0.062
            index = row * 4 + column
            filled = index % 3 == 0
            made.append(cone(f"comb_cell_{index}", 0.026, 0.023, 0.034,
                             (x, -0.028, z), mat("honey" if filled else "wax"),
                             vertices=6, rotation=(math.pi * 0.5, 0.0, 0.0)))
    # A run of honey off the bottom edge, so the thing looks worth taking.
    drip_x = rng.uniform(-0.05, 0.05)
    made.append(tapered_between("comb_drip", (drip_x, -0.030, 0.14), (drip_x, -0.026, 0.030),
                                0.015, 0.007, mat("honey"), vertices=6))


def build_clay_deposit(seed: int) -> None:
    """A riverbank clay bank with a dug floor in front of it.

    Deliberately the opposite shape from peat: clay is a damp bank someone has
    prised lumps out of, peat is stacked bricks. Two deposits that both read as
    "brown pile" would be a gathering system nobody can use at a glance.

    Two shapes were tried and thrown away before this one. A low dome over a
    0.92 m spread rendered as a pancake with no silhouette at standing height; a
    taller dome with a separate cut-face box under it read as a boulder perched on
    a crate, because the dome overhung the box like a mushroom cap. What works is
    a bank that is genuinely narrow front-to-back, so its front IS a face, with the
    worked ground lying in front of it where a player stands.
    """
    made = []
    bank = hull("clay_bank", (0.0, 0.13, 0.17), (0.34, 0.155, 0.21), mat("clay"), seed=seed,
                lumps=6, lump=0.22, sharpness=2.5, flat_base=0.0)
    # Dried crust on the crown; the face and the floor stay damp clay colour.
    paint_faces(bank, mat("terrain_path"), min_normal_z=0.45, min_height=0.62, coverage=0.8,
                seed=seed + 2)
    made.append(bank)
    # The worked floor at the bank's foot — flat, scuffed, and the reason the
    # loose lumps have somewhere to sit.
    made.append(box("clay_floor", (0.0, -0.12, 0.020), (0.40, 0.34, 0.040),
                    mat("terrain_path"), bevel=0.010))
    # Prised-out lumps on that floor.
    for index, (angle, rad) in enumerate(radial(4, 0.15, seed=seed + 4, jitter=0.7,
                                                radius_jitter=0.35)):
        centre = (math.cos(angle) * abs(rad), -0.14 + math.sin(angle) * abs(rad), 0.055)
        made.append(hull(f"clay_lump_{index}", centre, (0.068, 0.060, 0.046), mat("clay"),
                         seed=seed + 40 + index, lumps=4, lump=0.30, sharpness=2.4,
                         flat_base=0.0))
    # Half-buried stones in the bank: a clay bank is never clean, and a smooth
    # mass reads as dough.
    for index, (angle, rad) in enumerate(radial(5, 0.22, seed=seed + 8, jitter=0.8,
                                                radius_jitter=0.4)):
        centre = (math.cos(angle) * abs(rad), 0.15 + math.sin(angle) * abs(rad) * 0.45, 0.045)
        made.append(hull(f"clay_stone_{index}", centre, (0.042, 0.038, 0.030), mat("stone_dark"),
                         seed=seed + 70 + index, lumps=4, lump=0.24, sharpness=3.0))


def build_peat_deposit(seed: int) -> None:
    """Cut peat: bricks lifted out of a fen bank and stacked to dry.

    Peat is the one gatherable that is obviously *worked* — somebody cut these.
    That reads instantly and separates it from every natural mound in the kit.
    """
    rng = random.Random(seed)
    made = []
    bank = box("peat_bank", (0.0, 0.13, 0.075), (0.62, 0.30, 0.15), mat("peat"), bevel=0.012)
    # The living surface still on top of the cut bank.
    paint_faces(bank, mat("moss_dark"), min_normal_z=0.6, min_height=0.7, coverage=0.9,
                seed=seed)
    made.append(bank)
    stacks = [
        ((-0.15, -0.11, 0.055), (0.26, 0.15, 0.11), 0.10),
        ((0.14, -0.14, 0.050), (0.24, 0.14, 0.10), -0.22),
        ((0.02, -0.05, 0.155), (0.23, 0.13, 0.095), 0.34),
    ]
    rng_local = random.Random(seed + 3)
    for index, (location, dimensions, spin) in enumerate(stacks):
        brick = box(f"peat_brick_{index}", location, dimensions, mat("peat"),
                    rotation=(0.0, rng_local.uniform(-0.05, 0.05), spin), bevel=0.010)
        paint_faces(brick, mat("leaf_litter"), min_normal_z=0.55, min_height=0.55,
                    coverage=0.45, seed=seed + index)
        made.append(brick)
    # Dry tufts along the cut edge — the bank is still a living fen surface.
    batch = Batch()
    for angle, rad in radial(7, 0.28, seed=seed + 6, jitter=0.9, radius_jitter=0.4):
        origin = Vector((math.cos(angle) * abs(rad), 0.13 + math.sin(angle) * abs(rad) * 0.45,
                         0.150))
        blade(batch, "grass_dry", origin, angle, rng.uniform(0.09, 0.16), 0.022,
              rng.uniform(0.15, 0.4), rng.uniform(0.2, 0.5))
    batch.emit("peat_tufts")
    return None


def build_resin_node(seed: int) -> None:
    """A tapped pine: a cut in the bark with resin running out of it and pooling.

    This is a node on a trunk rather than a plant, and it is the only asset here a
    player looks at rather than down at — so the resin has to be visible on the
    trunk's face at standing eye height, not just puddled at its foot.
    """
    rng = random.Random(seed)
    made = []
    trunk = cone("resin_trunk", 0.152, 0.128, 0.72, (0.0, 0.0, 0.36), mat("wood_bark_dark"),
                 vertices=9)
    # No second bark material here on purpose. The first cut scattered `pine_dark`
    # — a FOLIAGE green — over 28% of the trunk's faces and drew bright green
    # stripes up the full height of the tree; replacing it with weathered grey
    # fixed the colour but pushed the asset to five materials, and the nine-sided
    # cone already facets enough to break up the bark on its own. The material
    # budget is better spent on the resin, which is the thing being gathered.
    made.append(trunk)
    # The tap wound: a pale cut face of exposed wood, angled so it catches light.
    # Inset into the bark, not stuck on the front of it: a panel standing proud of
    # the trunk reads as a label, which is what the first cut looked like.
    made.append(box("resin_cut", (0.0, -0.088, 0.45), (0.165, 0.070, 0.24), mat("wood_cut"),
                    rotation=(0.16, 0.0, 0.0), bevel=0.008))
    # The V-notch the sap actually runs from, cut across the exposed face.
    for sign in (-1.0, 1.0):
        made.append(box(f"resin_notch_{int(sign)}", (sign * 0.042, -0.112, 0.340),
                        (0.14, 0.040, 0.038), mat("wood_cut"),
                        rotation=(0.0, 0.0, sign * 0.42), bevel=0.005))
    # Runs of resin down the trunk face, at different lengths so it reads as flow.
    for index, offset in enumerate((-0.058, -0.005, 0.052)):
        top = (offset, -0.126, 0.33 - index * 0.012)
        bottom = (offset * 1.10, -0.120, rng.uniform(0.08, 0.19))
        made.append(tapered_between(f"resin_run_{index}", top, bottom, 0.024, 0.010,
                                    mat("resin"), vertices=6))
    made.append(hull("resin_pool", (0.0, -0.118, 0.020), (0.085, 0.058, 0.020), mat("resin"),
                     seed=seed + 3, lumps=4, lump=0.20, sharpness=3.0, flat_base=0.0))
    # A second, older tap round the far side: nobody taps a tree once, and it stops
    # the asset being blank from behind (task 2.1j).
    made.append(box("resin_cut_old", (0.03, 0.108, 0.33), (0.095, 0.060, 0.10),
                    mat("wood_cut"), rotation=(-0.12, 0.0, 0.0), bevel=0.006))
    for index, offset in enumerate((-0.018, 0.026)):
        made.append(tapered_between(f"resin_run_old_{index}", (0.03 + offset, 0.126, 0.30),
                                    (0.03 + offset, 0.120, 0.12 + index * 0.04),
                                    0.013, 0.006, mat("resin"), vertices=6))
    # A few needles caught in the sap at the base.
    batch = Batch()
    for angle, rad in radial(7, 0.185, seed=seed + 9, jitter=0.9, radius_jitter=0.4):
        origin = Vector((math.cos(angle) * abs(rad), math.sin(angle) * abs(rad), 0.010))
        blade(batch, "pine_dark", origin, angle, rng.uniform(0.07, 0.12), 0.030,
              rng.uniform(0.5, 0.9), rng.uniform(0.45, 0.7))
    batch.emit("resin_needles")
    return None


SPECS: list[tuple[str, Callable[[int], None]]] = [
    ("berry_bush_full", build_berry_bush_full),
    # Poison built right after full, harvested after that: the berry-decision
    # preview reads the three states left-to-right in build order (F-204 — it
    # can no longer relocate them for that shot), and full/poison/harvested is
    # the order the comparison wants.
    ("poison_berry_bush", build_poison_berry_bush),
    ("berry_bush_harvested", build_berry_bush_harvested),
    ("fibre_plant", build_fibre_plant),
    ("medicinal_herb", build_medicinal_herb),
    ("wild_onion", build_wild_onion),
    ("honeycomb", build_honeycomb),
    ("clay_deposit", build_clay_deposit),
    ("peat_deposit", build_peat_deposit),
    ("resin_node", build_resin_node),
]


# ---------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------


def join_into_one(name: str, made: list) -> bpy.types.Object:
    meshes = [obj for obj in made if obj.type == "MESH"]
    if len(meshes) <= 1:
        if meshes:
            meshes[0].name = name
        return meshes[0] if meshes else made[0]
    bpy.ops.object.select_all(action="DESELECT")
    for obj in meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.join()
    joined = bpy.context.view_layer.objects.active
    joined.name = name
    # Bake the rotation into the mesh. `join` gives the result whichever rotation
    # the alphabetically-first component happened to carry — for `resin_node` that
    # was the 0.16 rad tilt on `resin_cut` — and the exporter then writes it as a
    # node transform on top of the geometry. Anything that measures the GLB from
    # its mesh data rather than its world matrix then reads a different asset:
    # the all-sides audit put this node 53 mm underground and 93 mm too tall.
    # Godot would import it correctly, but "correct only if you remember the
    # transform" is exactly the shape of F-094/F-108, and there is no reason for a
    # static prop to ship a rotation at all.
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    bpy.ops.object.select_all(action="DESELECT")
    return joined


def floating_islands(objects: list, tolerance: float = 0.02) -> list[str]:
    """Mesh pieces that never touch the ground plane and hang in mid-air."""
    adrift = []
    for obj in objects:
        if obj.type != "MESH":
            continue
        lowest = min((obj.matrix_world @ v.co).z for v in obj.data.vertices)
        if lowest > tolerance:
            adrift.append(f"{obj.name} @ {lowest * 1000:.0f} mm")
    return adrift


def create_asset(name: str, build_fn: Callable[[int], None], display_location) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)

    before = {obj.name for obj in bpy.data.objects}
    build_fn(seed_for(name))
    made = sorted((obj for obj in bpy.data.objects if obj.name not in before),
                  key=lambda obj: obj.name)

    # The state pair centres on the geometry it SHARES, never on its own bounds.
    # Adding fruit must not move the bush, or the mesh visibly jumps at the moment
    # gameplay swaps it and drifts away from collision authored against its sibling.
    anchor = [obj for obj in made if obj.name.startswith(BUSH_ANCHOR_PREFIXES)] or None
    ground_and_centre(made, anchor=anchor)

    # Scale from the SHARED geometry where there is any. Sizing each state to its
    # own total bounds gives the two states different scale factors — the fruiting
    # bush is a little taller than the picked one — and that rescales the frame
    # they are supposed to have in common. Centring alone does not save it: A-005's
    # rule has to govern the scale as well as the origin.
    target, axis, _cap = SIZE[name]
    measured_on = anchor or made
    low, high = world_bounds(measured_on)
    current = (high.z - low.z) if axis == "height" else max(high.x - low.x, high.y - low.y)
    if current > 1e-6:
        factor = target / current
        for obj in made:
            if obj.parent is None:
                obj.scale = obj.scale * factor
                obj.location = obj.location * factor
        bpy.context.view_layer.update()
        for obj in made:
            bpy.context.view_layer.objects.active = obj
            obj.select_set(True)
        bpy.ops.object.transform_apply(location=True, rotation=False, scale=True)
        bpy.ops.object.select_all(action="DESELECT")
    ground_and_centre(made, anchor=anchor)
    glow, ghigh = world_bounds(measured_on)
    governed = (ghigh.z - glow.z) if axis == "height" else max(ghigh.x - glow.x, ghigh.y - glow.y)

    # Anchor offset BEFORE the join, while the shared parts are still identifiable.
    # This is the number the tracker row records for the state pair.
    anchor_centre = None
    anchor_bounds = None
    if anchor:
        alow, ahigh = world_bounds(anchor)
        anchor_centre = ((alow.x + ahigh.x) * 0.5, (alow.y + ahigh.y) * 0.5)
        anchor_bounds = (alow.x, alow.y, alow.z, ahigh.x, ahigh.y, ahigh.z)

    made = [join_into_one(name, made)]
    for obj in made:
        for old in list(obj.users_collection):
            old.objects.unlink(obj)
        collection.objects.link(obj)
        obj.parent = root
    bpy.context.view_layer.update()

    adrift = floating_islands(made)
    # Measure from vertices, never `obj.bound_box`: Blender does not refresh the
    # cached box after a join, so a joined asset otherwise measures as whatever its
    # first component was.
    corners = [obj.matrix_world @ vertex.co
               for obj in made if obj.type == "MESH" for vertex in obj.data.vertices]
    minimum = Vector((min(v.x for v in corners), min(v.y for v in corners),
                      min(v.z for v in corners)))
    maximum = Vector((max(v.x for v in corners), max(v.y for v in corners),
                      max(v.z for v in corners)))
    dimensions = maximum - minimum
    polygons = sum(len(obj.data.polygons) for obj in made if obj.type == "MESH")
    triangles = sum(sum(max(0, len(polygon.vertices) - 2) for polygon in obj.data.polygons)
                    for obj in made if obj.type == "MESH")
    materials = sorted({m.name for obj in made if obj.type == "MESH"
                        for m in obj.data.materials if m})

    bpy.ops.object.select_all(action="DESELECT")
    for obj in collection.objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = root
    bpy.ops.export_scene.gltf(filepath=str(EXPORT_DIR / f"{name}.glb"), export_format="GLB",
                              use_selection=True, export_apply=True, export_yup=True)
    root.location = display_location
    return {
        "name": name, "root": root,
        "width": dimensions.x, "depth": dimensions.y, "height": dimensions.z,
        "ground_offset": minimum.z, "target": target, "axis": axis, "adrift": adrift,
        "anchor_centre": anchor_centre, "anchor_bounds": anchor_bounds,
        "governed": governed,
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons, "triangles": triangles, "materials": materials,
    }


def check(records: list[dict]) -> list[str]:
    """Everything a machine can judge about this batch, judged — and failed on."""
    problems: list[str] = []
    by_name = {record["name"]: record for record in records}
    for record in records:
        name = record["name"]
        target, axis, cap = SIZE[name]
        # For a state set the target governs the SHARED frame, not the total —
        # otherwise fruit would count toward the bush's height and the two states
        # could not both be 0.78 m.
        if abs(record["governed"] - target) > SIZE_TOLERANCE:
            problems.append(f"{name}: {axis} {record['governed']:.3f} m vs target {target:.3f} m")
        spread = max(record["width"], record["depth"])
        if spread > cap:
            problems.append(f"{name}: {spread:.2f} m across, footprint cap is {cap} m")
        if abs(record["ground_offset"]) > 0.005:
            problems.append(f"{name}: sits {record['ground_offset'] * 1000:.1f} mm off the ground")
        if record["adrift"]:
            problems.append(f"{name}: floating geometry: {record['adrift'][:3]}")
        if record["parts"] == 0 or record["polygons"] == 0:
            problems.append(f"{name}: exported no geometry")
        if record["triangles"] > TRIANGLE_BUDGET:
            problems.append(f"{name}: {record['triangles']} triangles over the "
                            f"{TRIANGLE_BUDGET} budget")
        cap_materials = MATERIAL_ALLOWANCE.get(name, MAX_MATERIALS)
        if len(record["materials"]) > cap_materials:
            problems.append(f"{name}: {len(record['materials'])} materials, cap is {cap_materials}")
        if not record["materials"]:
            problems.append(f"{name}: no embedded materials")
        if not (EXPORT_DIR / f"{name}.glb").exists():
            problems.append(f"{name}: no GLB written")

    # The state pair's shared frame must land on the same spot in both states.
    full, harvested = by_name["berry_bush_full"], by_name["berry_bush_harvested"]
    if full["anchor_centre"] and harvested["anchor_centre"]:
        drift = math.dist(full["anchor_centre"], harvested["anchor_centre"])
        if drift > 0.0005:
            problems.append(f"berry bush states drift {drift * 1000:.2f} mm apart")
        # Centring both on their own frame makes the centres match by construction.
        # The claim worth testing is stronger: that the shared frame is the SAME
        # geometry in the same place, so the swap moves nothing a player can see.
        if full["anchor_bounds"] and harvested["anchor_bounds"]:
            worst = max(abs(a - b) for a, b in zip(full["anchor_bounds"],
                                                   harvested["anchor_bounds"]))
            if worst > 0.0005:
                problems.append(
                    f"berry bush shared frame differs by {worst * 1000:.2f} mm between states"
                )
    else:
        problems.append("berry bush states have no shared anchor — the pair cannot be swapped safely")

    # The poison bush is supposed to be a near-copy. If its silhouette ever stops
    # matching the safe bush, the design intent has quietly been lost.
    safe, poison = by_name["berry_bush_full"], by_name["poison_berry_bush"]
    for axis_name in ("width", "depth", "height"):
        if abs(safe[axis_name] - poison[axis_name]) > 0.05:
            problems.append(
                f"poison_berry_bush {axis_name} {poison[axis_name]:.3f} m differs from the safe "
                f"bush's {safe[axis_name]:.3f} m by more than 50 mm — it must read as a near-copy"
            )
    return problems


def main() -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    reset_materials()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)

    if len({name for name, _ in SPECS}) != len(SPECS):
        raise RuntimeError("gatherable asset names must be unique")
    for name, _ in SPECS:
        if name not in SIZE:
            raise RuntimeError(f"{name} has no SIZE entry")

    records: list[dict] = []
    for index, (name, builder) in enumerate(SPECS):
        column, row = index % 6, index // 6
        records.append(create_asset(name, builder, (column * 1.35 - 3.4, row * 8.0, 0.0)))

    problems = check(records)

    CATALOG_PATH.write_text(json.dumps({
        "batch": "A-011",
        "family": "gatherables",
        "blender": bpy.app.version_string,
        "assets": [
            {
                "name": r["name"], "file": f"exports/{r['name']}.glb",
                "width_m": round(r["width"], 4), "depth_m": round(r["depth"], 4),
                "height_m": round(r["height"], 4), "target_m": r["target"], "axis": r["axis"],
                "parts": r["parts"], "polygons": r["polygons"], "triangles": r["triangles"],
                "materials": r["materials"],
            }
            for r in records
        ],
    }, indent=2) + "\n")

    # -- previews ----------------------------------------------------------
    preview_collection = bpy.data.collections.new("Preview")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.object.light_add(type="SUN", location=(4.0, -6.0, 8.0))
    key = bpy.context.object
    key.data.energy = 4.0
    look_at(key, (0.0, 0.0, 0.0))
    bpy.ops.object.light_add(type="SUN", location=(-6.0, 4.0, 5.0))
    fill = bpy.context.object
    fill.data.energy = 1.4
    look_at(fill, (0.0, 0.0, 0.0))
    for light in (key, fill):
        for old in list(light.users_collection):
            old.objects.unlink(light)
        preview_collection.objects.link(light)

    bpy.ops.object.camera_add()
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    scene = bpy.context.scene
    scene.camera = camera
    scene.render.engine = eevee_engine()
    scene.render.resolution_x = 1800
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.016, 0.021, 0.028)
    scene.view_settings.look = "AgX - Medium High Contrast"
    for old in list(camera.users_collection):
        old.objects.unlink(camera)
    preview_collection.objects.link(camera)

    # A 1.80 m reference stands in every sheet. A kit whose sizes are only ever
    # compared against each other is exactly how the pickup kit shipped a 0.71 m
    # berry next to a 1.08 m stone.
    #
    # One cube cannot serve every sheet: `object.location` set after this
    # process's FIRST render never takes effect (F-204) — only camera moves and
    # `hide_render` toggles do. The original code moved one "figure" object
    # between all three renders, so only the first sheet's reference cube ever
    # actually appeared where intended. Each sheet below gets its own cube
    # instead, placed once here and only ever hidden or shown.
    def make_reference(tag: str, location) -> bpy.types.Object:
        bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0.9))
        fig = bpy.context.object
        fig.name = f"Scale_Reference_{tag}"
        fig.scale = (0.20, 0.13, 0.90)
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        fig.data.materials.append(mat("reference_blue"))
        fig.location = location
        for old in list(fig.users_collection):
            old.objects.unlink(fig)
        preview_collection.objects.link(fig)
        fig.hide_render = True
        return fig

    def set_visible(record: dict, visible: bool) -> None:
        record["root"].hide_render = not visible
        for child in record["root"].children_recursive:
            child.hide_render = not visible

    def sheet_geometry(names: list) -> tuple[float, float, float]:
        first_x = -3.4
        last_x = first_x + (len(names) - 1) * 1.35
        figure_x = first_x - 1.15
        span = (last_x + 0.75) - (figure_x - 0.45)
        centre_x = ((figure_x - 0.45) + (last_x + 0.75)) * 0.5
        return figure_x, span, centre_x

    by_name = {record["name"]: record for record in records}
    sheets = [
        ("gatherable_plants_preview.png", 0.0,
         ["berry_bush_full", "poison_berry_bush", "berry_bush_harvested",
          "fibre_plant", "medicinal_herb", "wild_onion"]),
        ("gatherable_deposits_preview.png", 8.0,
         ["honeycomb", "clay_deposit", "peat_deposit", "resin_node"]),
    ]
    # Every reference cube any render below will need, built now — before the
    # first `bpy.ops.render.render()` call — so each one's placement actually
    # takes effect (F-204).
    sheet_rigs = []
    for filename, sheet_y, names in sheets:
        figure_x, span, centre_x = sheet_geometry(names)
        figure = make_reference(filename, (figure_x, sheet_y, 0.9))
        sheet_rigs.append((filename, sheet_y, names, span, centre_x, figure))
    decision_names = ("berry_bush_full", "poison_berry_bush", "berry_bush_harvested")
    # SPECS builds these three adjacent, in exactly this order, so their real
    # grid positions already read left-to-right the way the comparison wants —
    # this shot only ever aims a camera at them, it never relocates them.
    decision_centre_x = by_name["poison_berry_bush"]["root"].location.x
    decision_figure = make_reference(
        "decision", (by_name["berry_bush_full"]["root"].location.x - 1.2, 0.80, 0.9))

    camera.data.type = "ORTHO"
    scene.render.resolution_y = 760
    for filename, sheet_y, names, span, centre_x, figure in sheet_rigs:
        for record in records:
            set_visible(record, record["name"] in names)
        # Frame the assets actually on this sheet, with the 1.80 m figure standing
        # clear to the left of the row rather than in front of the first asset.
        camera.data.ortho_scale = span
        figure.hide_render = False
        camera.location = (centre_x, sheet_y - 12.0, 1.9)
        look_at(camera, (centre_x, sheet_y, 0.72))
        scene.render.filepath = str(PREVIEW_DIR / filename)
        bpy.ops.render.render(write_still=True)
        figure.hide_render = True

    # The berry decision, at the distance the decision is actually made — standing
    # in front of the bushes rather than looking down on them, because "almost
    # identical" is a claim about what a player sees on approach.
    for record in records:
        set_visible(record, record["name"] in decision_names)
    decision_figure.hide_render = False
    camera.data.type = "PERSP"
    camera.data.lens = 40.0
    scene.render.resolution_y = 760
    # Far enough back that all three bushes are in frame at once. The first cut
    # sat 3.15 m out on a 45 mm lens, which frames 2.5 m of a 3.2 m row — it
    # rendered as a macro shot of one bush, which cannot answer the question this
    # sheet exists to answer.
    camera.location = (decision_centre_x, -5.95, 1.22)
    look_at(camera, (decision_centre_x, 0.0, 0.42))
    scene.render.filepath = str(PREVIEW_DIR / "berry_decision_preview.png")
    bpy.ops.render.render(write_still=True)
    for record in records:
        set_visible(record, True)

    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_PATH))

    print(f"\nGATHERABLES_BUILD assets={len(records)} "
          f"triangles={sum(r['triangles'] for r in records)} blender={bpy.app.version_string}")
    for record in records:
        print("  %-22s %5.2f x %5.2f x %5.2f m  %4d tris  %d parts  %d mats  %s"
              % (record["name"], record["width"], record["depth"], record["height"],
                 record["triangles"], record["parts"], len(record["materials"]),
                 ",".join(m.replace("MIRE_", "") for m in record["materials"])))
    pair = [r for r in records if r["name"].startswith("berry_bush")]
    if all(r["anchor_centre"] for r in pair):
        print("  berry bush state drift: %.3f mm"
              % (math.dist(pair[0]["anchor_centre"], pair[1]["anchor_centre"]) * 1000))
    if problems:
        print(f"\nGATHERABLES_CHECK FAIL ({len(problems)})")
        for problem in problems:
            print(f"  {problem}")
        raise SystemExit(1)
    print("GATHERABLES_CHECK PASS")


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
