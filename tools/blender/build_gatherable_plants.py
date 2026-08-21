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
    trunk_tube,
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
    # A standard orchard apple is 4-8 m and its crown is as wide as it is tall,
    # so the footprint cap here is nearly the height rather than a fraction of it.
    # Capping it tighter would produce the one thing an apple tree must not be:
    # a tall narrow tree with apples on.
    "apple_tree_full": (5.20, "height", 5.30),
    "apple_tree_picked": (5.20, "height", 5.30),
    # Sized on SPREAD, not height, and that is forced rather than preferred: a
    # state pair is scaled on the geometry it SHARES, and what these two share is
    # a flat mat of leaf litter 60 mm tall. Asking for a 0.19 m height measured
    # the litter, found 0.06, and scaled the whole patch up 3.8x — out to 1.70 m
    # across. The shared geometry has to be measured on an axis it actually has.
    "mushroom_patch_full": (0.62, "spread", 0.70),
    "mushroom_patch_harvested": (0.62, "spread", 0.70),
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
MATERIAL_ALLOWANCE = {"poison_berry_bush": 5,
                      # Cap, gill, litter, buried wood and moss. Drop any one and the
                      # troop stops reading as something that GREW there: a mushroom
                      # standing on bare ground reads as placed (see the builder).
                      "mushroom_patch_full": 5,
                      # Two barks, two leaf tones, and the apple's own two: the
                      # blush and the cheek are the asset (see `apple_fruit`).
                      "apple_tree_full": 6, "apple_tree_picked": 5}
#: Per-asset exceptions to the triangle cap, each with a reason, same discipline.
#: The three berry bushes are the game's signature forage node and the ONE thing
#: they have to do is read as fruiting or picked from across a clearing. The 900
#: cap was met by the version that hid its fruit under the canopy, where it cost
#: almost nothing and communicated almost nothing (F-429). Seventy-odd berries on
#: exposed canes is what the read costs; it is spent on the asset's entire point.
TRIANGLE_ALLOWANCE = {"berry_bush_full": 1300, "poison_berry_bush": 1300,
                      "berry_bush_harvested": 1000,
                      # The apple tree is a 5 m landmark, not a shin-high node
                      # placed by the hundred: it is scattered as a find, and the
                      # budget the rest of this kit runs on is sized for props a
                      # player wades through.
                      "apple_tree_full": 2600, "apple_tree_picked": 2000}

#: The parts each state SET shares. `create_asset` centres and scales a state on
#: these and nothing else, so adding fruit cannot move or resize the plant under
#: it. Keyed per asset now rather than one global tuple: the apple tree needs the
#: same guarantee and its shared geometry is a trunk and a canopy, not a bush.
ANCHOR_PREFIXES: dict[str, tuple[str, ...]] = {
    "berry_bush_full": ("frame_", "bush_"),
    "berry_bush_harvested": ("frame_", "bush_"),
    "poison_berry_bush": ("frame_", "bush_"),
    "apple_tree_full": ("apple_frame_",),
    "apple_tree_picked": ("apple_frame_",),
    "mushroom_patch_full": ("patch_frame_",),
    "mushroom_patch_harvested": ("patch_frame_",),
}

#: The bush's three foliage masses, shared by the frame builder and by
#: `berry_sites` so fruit can be placed on an actual surface rather than at a
#: guessed radius. Overlapping hard and unequal: three masses give a silhouette
#: shoulders, three equal masses sitting apart give it three heads.
#: Deliberately SMALL now. They are the body the canes grow out of, not the bush
#: itself: at their first sizes (0.29/0.23/0.20 radius) they engulfed every cane
#: and every leaf spray, and the plant went back to reading as a heap of green
#: rocks with fruit tucked under one edge. A bush's outline should be made by the
#: things that stick out of it.
BUSH_MASSES = [
    ((0.00, 0.02, 0.26), (0.175, 0.165, 0.150)),
    ((-0.13, -0.07, 0.19), (0.140, 0.135, 0.125)),
    ((0.12, -0.09, 0.17), (0.125, 0.130, 0.115)),
]

#: The arching canes. A real bramble or blueberry does not grow as a pile of
#: foliage with fruit tucked underneath it — it throws canes up and over, and the
#: fruit hangs at their OUTER ends, past the leaves, where the light is. That is
#: not a stylistic note: it is the whole reason a berry bush is visible as a berry
#: bush from across a clearing, and the first build got it exactly backwards.
#: `berry_sites` reads this table so the fruit is on the canes rather than at a
#: guessed point on a leaf mass.
#:
#: (heading angle, cane length, rise, droop) — see `arc_spine`.
#: Authored at FINAL size so `create_asset`'s scale-to-band comes out near 1.0.
#: Sized by the rise and droop rather than by eye: a cane peaks where
#: `rise == droop * 2.2 * t^1.2`, so droop has to be the larger share for the cane
#: to come over at all. The first retune used a rise that never turned, the height
#: then measured 0.44 m against a 0.78 m band, and the 1.8x scale-up that followed
#: threw the bush out to 2.25 m across — three times its footprint cap.
BUSH_CANES = [
    (0.35, 0.41, 1.45, 0.88),
    (1.62, 0.36, 1.32, 0.80),
    (2.74, 0.39, 1.40, 0.85),
    (3.86, 0.33, 1.24, 0.76),
    (4.98, 0.37, 1.36, 0.82),
    (5.70, 0.31, 1.18, 0.72),
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

    F-429: these now sit on the OUTER THIRD OF EACH CANE, hanging just below it,
    which is where a bramble or a blueberry actually fruits. The first version
    placed them on the surface of the foliage masses with the elevation biased
    downward — under the canopy, in its shadow, from every angle a player is
    likely to stand. Eleven of twelve clusters were effectively invisible, which
    is why the fruiting bush and the picked bush looked the same.
    """
    rng = random.Random(seed + 7)
    origin = Vector((0.0, 0.0, 0.06))
    sites = []
    for index, (angle, length, rise, droop) in enumerate(BUSH_CANES):
        spine = arc_spine(origin, angle, length, rise, droop, segments=8)
        for step, fraction in enumerate((0.72, 1.0)):
            point = spine[min(len(spine) - 1, int(fraction * (len(spine) - 1)))]
            hang = Vector((rng.uniform(-0.02, 0.02), rng.uniform(-0.02, 0.02),
                           -rng.uniform(0.045, 0.075)))
            sites.append((point + hang, rng.uniform(0.038, 0.050), rng.randint(6, 7)))
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
        # ~30-40 mm across, which is a big blackberry. The first build used this
        # number as a RADIUS, making every berry 7-9 cm — bigger than the leaves
        # around it. It went unnoticed for as long as the fruit was buried under
        # the canopy where nothing could be compared against it.
        size = rng.uniform(0.015, 0.020)
        batch.blob(token, centre + offset, (size, size, size * 0.92), rng)


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------


def build_bush_frame(seed: int, leaf_token: str, leaf_highlight: str) -> list:
    """The woody frame and foliage every berry-bush state shares.

    Rebuilt for F-429. The first version was three overlapping foliage blobs with
    four short stems buried inside them, and it read as a heap of green rocks:
    the preview render shows three of them side by side and the only difference
    between the fruiting bush and the picked one is a few red specks along the
    bottom edge, which is the one thing this asset exists to communicate.

    A bramble or a blueberry is a set of ARCHING CANES. They leave the crown of
    the root, lift, and fall over; the leaves ride along them; and the fruit hangs
    at their outer ends, past the foliage, where light reaches it. Building that
    shape gets the berries out where they can be seen for free — no bigger fruit,
    no brighter red, just the fruit where the plant actually puts it.

    The three foliage masses stay, because a bush still needs a body under the
    canes and they are what the silhouette's shoulders come from.
    """
    rng = random.Random(seed)
    made = []
    origin = Vector((0.0, 0.0, 0.06))
    for index, (angle, length, rise, droop) in enumerate(BUSH_CANES):
        spine = arc_spine(origin, angle, length, rise, droop, segments=3)
        for step in range(len(spine) - 1):
            made.append(cylinder_between(
                f"frame_cane_{index}_{step}", spine[step], spine[step + 1],
                0.012 - step * 0.0022, mat("wood_bark"), vertices=4))
        # Leaves ride the cane rather than sitting in one mass at the middle, so
        # the outer half of the plant is leafy and the fruit hangs past THAT.
        # Leaf sprays ELONGATED ALONG the cane. Round flat hulls parked at two
        # points on a visible stick read as parasols — the preview showed a row of
        # little green umbrellas — because a disc on a pole is a mushroom, whatever
        # colour it is. Stretching them down the cane's own heading turns them back
        # into foliage riding a branch.
        # Sampled on the SPINE, not on a chord between its ends. Lerping base to
        # tip walks a straight line under an arc, so every leaf spray hung below
        # the cane it belongs to and the canes came out as bare brown antennae
        # over the foliage — which is the one thing a live bush never looks like.
        for step, point in enumerate(spine[1:]):
            spray = hull(f"frame_leaf_{index}_{step}", point,
                         (0.098, 0.086, 0.052), mat(leaf_token),
                         seed=seed + index * 17 + step,
                         subdivisions=0, lumps=4, lump=0.46, sharpness=2.0)
            spray.rotation_euler = (0.0, 0.0, angle)
            made.append(spray)
    for index, (centre, radius) in enumerate(BUSH_MASSES):
        mass = hull(f"bush_mass_{index}", centre, radius, mat(leaf_token), seed=seed + index * 31,
                    subdivisions=0, lumps=8, lump=0.42, sharpness=1.9, jitter=0.05)
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


# ---------------------------------------------------------------------------
# The apple tree (F-429)
# ---------------------------------------------------------------------------
#
# Sequoyah asked for "a beautiful apple tree", and the way to get one is to build
# a `Malus domestica` rather than a generic tree with red dots on it. What the
# real thing is, and what each fact costs here:
#
#   * A **short, thick trunk that forks LOW** — a standard orchard apple breaks
#     into three to five scaffold limbs between about 1.2 m and 1.8 m, which is
#     barely above head height. That low fork is most of the tree's character and
#     it is the first thing a generic tree gets wrong.
#   * A crown **as wide as the tree is tall, or wider**, and rounded rather than
#     conical. An apple spends its growth sideways.
#   * **Gnarled, angular limbs.** Apple wood grows in kinks, not sweeps; the
#     limbs change direction at every fork, which is why an old apple tree reads
#     as characterful where a birch reads as clean.
#   * Fruit at the **periphery**, on short spurs, singly and in pairs — never in
#     bunches, and never deep inside the crown where there is no light. This is
#     also what makes the picked state legible: the fruit is on the outside, so
#     removing it changes the silhouette's edge.
#   * Apples are **two-toned**. A sunward blush and a green-gold cheek, on every
#     fruit. One flat red is a cherry.

#: The scaffold limbs: (heading, tilt from vertical, length). Deliberately uneven
#: — an apple tree that is symmetrical is a lollipop, and the asymmetry is free.
#: Authored at FINAL size, so `create_asset`'s scale-to-band lands near 1.0. The
#: first cut built a 3.8 m tree and let the 5.2 m band stretch it, which took the
#: crown out to 7.5 m across — an apple tree is as wide as it is tall, not half
#: as wide again.
APPLE_LIMBS = [
    (0.42, 0.55, 2.45),
    (1.78, 0.64, 2.20),
    (3.05, 0.48, 2.65),
    (4.31, 0.68, 2.10),
    (5.42, 0.58, 2.35),
]
APPLE_FORK_Z = 1.55
APPLE_SEED = 4409


def apple_limb_tips(seed: int) -> list[tuple[Vector, Vector]]:
    """Where each scaffold limb ends up, and the direction it got there by.

    Shared by the frame builder and by `apple_sites`, so the fruit hangs on the
    limbs the tree actually has rather than at a guessed radius — the same
    mistake `berry_sites` was making before F-429, one scale up.
    """
    rng = random.Random(seed + 3)
    tips = []
    for heading, tilt, length in APPLE_LIMBS:
        base = Vector((0.0, 0.0, APPLE_FORK_Z))
        direction = Vector((math.cos(heading) * math.sin(tilt),
                            math.sin(heading) * math.sin(tilt),
                            math.cos(tilt))).normalized()
        # One kink per limb. Apple wood does not sweep, it turns.
        knee = base + direction * (length * 0.52)
        turn = Vector((rng.uniform(-0.28, 0.28), rng.uniform(-0.28, 0.28),
                       rng.uniform(-0.16, 0.20)))
        onward = (direction + turn).normalized()
        tip = knee + onward * (length * 0.48)
        tips.append((knee, tip))
    return tips


def apple_canopy_masses(seed: int) -> list[tuple[Vector, float]]:
    """The crown's leaf masses: centre and radius, in build order.

    Shared by the frame builder and by `apple_sites`, so the fruit can be placed
    on the crown's actual surface. Placing it at a guessed offset below the limb
    is what the first cut did, and it put every apple inside the canopy's shadow
    where nothing could see it — the identical mistake the berry bush had, one
    scale up, discovered in the same afternoon.
    """
    masses = []
    for knee, tip in apple_limb_tips(seed):
        for fraction, size in ((0.55, 0.70), (0.88, 0.89), (1.06, 0.65)):
            masses.append((knee.lerp(tip, fraction) + Vector((0.0, 0.0, 0.10)), size))
    masses.append((Vector((0.0, 0.0, APPLE_FORK_Z + 1.72)), 1.16))
    return masses


def build_apple_frame(seed: int) -> list:
    """Trunk, scaffold limbs and canopy — everything both apple states share."""
    rng = random.Random(seed)
    made = []
    points, radii = trunk_tube(
        APPLE_FORK_Z, 0.240, 0.196, Vector((0.06, -0.04, 0.0)), 0.010, 3,
        (mat("wood_bark_dark"), mat("wood_bark"), mat("wood_bark")), rng, seed,
        vertices=8, flare=1.95, flare_power=1.4, flare_top=0.34, toe=0.55, toe_top=0.26,
        taper_power=1.05, grain=0.095, flute=0.66, shade_columns=1, lit_columns=0,
    )
    # `trunk_tube` names its mesh "Trunk", which is not in this asset's anchor
    # prefix — so the state pair grounded and scaled on the LIMBS alone and the
    # whole tree sat three metres underground. Renamed into the anchor rather
    # than special-cased, because the trunk is exactly the geometry the two
    # states must be measured on.
    for obj in list(bpy.context.scene.objects):
        if obj.type == "MESH" and obj.name.startswith("Trunk"):
            obj.name = f"apple_frame_{obj.name.lower()}"
            made.append(obj)

    tips = apple_limb_tips(seed)
    for index, (knee, tip) in enumerate(tips):
        base = Vector((0.0, 0.0, APPLE_FORK_Z - 0.10))
        made.append(tapered_between(f"apple_frame_limb_{index}_a", base, knee,
                                    radii[-1] * 0.52, radii[-1] * 0.36,
                                    mat("wood_bark"), 6))
        made.append(tapered_between(f"apple_frame_limb_{index}_b", knee, tip,
                                    radii[-1] * 0.36, radii[-1] * 0.18,
                                    mat("wood_bark"), 5))
        # Two twigs off each limb tip, so the crown has something to sit on and
        # the picked tree is not a bare fork.
        for step in range(2):
            spur = tip + Vector((rng.uniform(-0.34, 0.34), rng.uniform(-0.34, 0.34),
                                 rng.uniform(0.10, 0.42)))
            made.append(tapered_between(f"apple_frame_spur_{index}_{step}", tip, spur,
                                        radii[-1] * 0.16, radii[-1] * 0.07,
                                        mat("wood_bark"), 4))
    # Canopy: leaf masses riding the limbs, biggest at the outside. A single
    # capping ball would be a lollipop; the point of an apple tree is that the
    # crown is broad and lumpy and you can see the limbs inside it.
    for index, (centre, size) in enumerate(apple_canopy_masses(seed)):
        mass = hull(f"apple_frame_canopy_{index}", centre,
                    (size, size * 0.94, size * 0.68), mat("leaf"),
                    seed=seed + index * 23, subdivisions=0,
                    lumps=5, lump=0.40, sharpness=2.0, droop=0.24, droop_lobes=2)
        paint_faces(mass, mat("leaf_light"), min_normal_z=0.32, min_height=0.50,
                    coverage=0.58, seed=seed + index * 7)
        made.append(mass)
    return made


def apple_sites(seed: int) -> list[Vector]:
    """Where the fruit hangs: ON the crown's outer surface, singly and in pairs.

    Each site sits just proud of one leaf mass, biased outward and downward but
    never far enough under it to be in its shadow — which is exactly how an apple
    spur bears, and also the only way the fruit is visible at the range a player
    decides whether to walk over.
    """
    rng = random.Random(seed + 11)
    sites = []
    for index, (centre, size) in enumerate(apple_canopy_masses(seed)):
        for step in range(rng.randint(3, 5)):
            angle = rng.uniform(0.0, math.tau)
            elevation = rng.uniform(-0.55, 0.10)
            reach = 1.02
            sites.append(Vector((
                centre.x + math.cos(angle) * math.cos(elevation) * size * reach,
                centre.y + math.sin(angle) * math.cos(elevation) * size * 0.94 * reach,
                centre.z + math.sin(elevation) * size * 0.68 * reach - 0.04,
            )))
    return sites


def apple_fruit(batch: Batch, rng: random.Random, centre: Vector) -> None:
    """One apple: a blushed body, a shaded cheek and a stalk.

    The two tones are not decoration. A single flat red sphere at this size is a
    cherry; the green-gold cheek is what makes the eye read "apple", and it costs
    one extra blob."""
    # ~12 cm, against a real 7-9 cm apple. The one deliberate exaggeration in
    # this asset: at true scale the fruit on a 5.2 m tree is a couple of pixels
    # at the range a player decides whether to walk over, and a fruit tree whose
    # fruit you cannot see is the picked state with extra steps.
    size = rng.uniform(0.062, 0.074)
    batch.blob("apple", centre, (size, size, size * 0.90), rng)
    cheek = centre + Vector((rng.uniform(-0.4, 0.4), rng.uniform(-0.4, 0.4), 0.0)) * size
    batch.blob("apple_shade", cheek, (size * 0.62, size * 0.62, size * 0.58), rng)


def build_apple_tree_full(_seed: int) -> None:
    """In fruit. The state a player walks toward."""
    seed = APPLE_SEED
    build_apple_frame(seed)
    rng = random.Random(seed + 101)
    batch = Batch()
    for centre in apple_sites(seed):
        apple_fruit(batch, rng, centre)
        batch.ribbon("wood_bark", [centre + Vector((0.0, 0.0, 0.055)), centre],
                     [0.007, 0.005], [0.005, 0.003])
    batch.emit("apples")


def build_apple_tree_picked(_seed: int) -> None:
    """The same tree after picking: identical frame, bare spurs where fruit was.

    The spurs matter for the same reason the berry bush's stalks do — without
    them the picked tree reads as a different, barren tree rather than as THIS
    tree a moment later, and the player loses the only cue that they already
    took it."""
    seed = APPLE_SEED
    build_apple_frame(seed)
    batch = Batch()
    for centre in apple_sites(seed):
        batch.ribbon("wood_dead", [centre + Vector((0.0, 0.0, 0.055)), centre],
                     [0.007, 0.004], [0.005, 0.002])
    batch.emit("spurs")


# ---------------------------------------------------------------------------
# The mushroom patch (F-429)
# ---------------------------------------------------------------------------
#
# The kit already had toadstools — six `mushroom_cluster_*` in the environment
# kit — but those are DECORATION in the mire's signal colours, and there was no
# node a player walks up to and forages. This is that node, and it is a different
# object from a toadstool in three ways that all matter:
#
#   * **It is buff-brown, not pink or blue.** `fungus_cap` and `fungus_blue` mean
#     "this grew out of the corruption". A mushroom the player is meant to eat
#     cannot wear either, or the palette is lying to them.
#   * **It is a TROOP**, not one mushroom. Field mushrooms come up in a ring or a
#     scatter of six or eight at mixed ages — buttons beside open caps — and that
#     mixture is what says "forage" rather than "prop".
#   * **It grows out of something.** Leaf litter and a piece of buried deadwood,
#     because a mushroom standing on bare ground reads as placed.

MUSHROOM_SEED = 8821

#: The mushrooms grow OUT OF the litter mat, so they start at its surface rather
#: than at z = 0. Without this the troop's stems begin under the litter, the pair
#: grounds on the litter (its shared anchor), and the whole asset ends up sitting
#: 13 mm below the soil line — which the build contract catches and a player would
#: read as mushrooms sunk into the mud.
MUSHROOM_BASE_Z = 0.030

#: (x, y, cap radius, stem height). Mixed ages on purpose — the two smallest are
#: buttons that have not opened yet, which is what stops the troop reading as one
#: mushroom stamped six times.
MUSHROOM_SITES = [
    (0.000, 0.000, 0.105, 0.150),
    (0.145, -0.075, 0.082, 0.115),
    (-0.130, 0.060, 0.093, 0.132),
    (0.055, 0.155, 0.060, 0.082),
    (-0.155, -0.115, 0.048, 0.062),
    (0.185, 0.095, 0.038, 0.050),
]


def build_mushroom_frame(seed: int) -> list:
    """The litter, the buried wood and the ground the troop comes out of."""
    rng = random.Random(seed)
    made = []
    made.append(hull("patch_frame_litter", Vector((0.0, 0.0, 0.034)),
                     (0.30, 0.27, 0.030), mat("leaf_litter"), seed=seed,
                     subdivisions=0, lumps=5, lump=0.44, sharpness=1.9, flat_base=0.5))
    made.append(cylinder_between("patch_frame_wood", (-0.24, -0.10, 0.042),
                                 (0.19, 0.13, 0.054), 0.036, mat("wood_dead"), vertices=6))
    for index, (angle, rad) in enumerate(radial(3, 0.22, seed=seed + 5, jitter=0.7,
                                                radius_jitter=0.4)):
        made.append(hull(f"patch_frame_moss_{index}",
                         Vector((math.cos(angle) * abs(rad), math.sin(angle) * abs(rad), 0.028)),
                         (0.072, 0.066, 0.024), mat("moss_dark"), seed=seed + index * 13,
                         subdivisions=0, lumps=3, lump=0.40, flat_base=0.5))
    return made


def mushroom(batch: Batch, rng: random.Random, x: float, y: float,
             radius: float, height: float, button: bool) -> None:
    """One mushroom. A cap, a stem, and gills where the cap overhangs.

    The gills are the whole difference between a mushroom and a nail: a cap with
    nothing under its rim reads as a disc on a pin from any angle below its own
    height, which is every angle a standing player has.
    """
    lean = Vector((rng.uniform(-0.012, 0.012), rng.uniform(-0.012, 0.012), 0.0))
    top = Vector((x, y, MUSHROOM_BASE_Z + height)) + lean
    batch.blob("fungus_gill", Vector((x, y, MUSHROOM_BASE_Z + height * 0.5)),
               (radius * 0.30, radius * 0.30, height * 0.5), rng)
    if button:
        batch.blob("fungus_edible", top, (radius * 0.86, radius * 0.84, radius * 0.82), rng)
        return
    batch.blob("fungus_gill", top + Vector((0.0, 0.0, -0.012)),
               (radius * 0.92, radius * 0.90, radius * 0.14), rng)
    batch.blob("fungus_edible", top, (radius, radius * 0.96, radius * 0.44), rng)


def build_mushroom_patch_full(_seed: int) -> None:
    """The troop, uncut."""
    seed = MUSHROOM_SEED
    build_mushroom_frame(seed)
    rng = random.Random(seed + 101)
    batch = Batch()
    for index, (x, y, radius, height) in enumerate(MUSHROOM_SITES):
        mushroom(batch, rng, x, y, radius, height, button=index >= 4)
    batch.emit("mushrooms")


def build_mushroom_patch_harvested(_seed: int) -> None:
    """Picked: the same litter and wood, with cut stems left standing.

    Same rule as the berry bush's stalks and the apple tree's spurs — a picked
    node has to read as THIS node a moment later, not as bare ground, or the
    player has no way to know they already took it.
    """
    seed = MUSHROOM_SEED
    build_mushroom_frame(seed)
    rng = random.Random(seed + 101)
    batch = Batch()
    for x, y, radius, height in MUSHROOM_SITES:
        batch.blob("fungus_gill", Vector((x, y, MUSHROOM_BASE_Z + height * 0.16)),
                   (radius * 0.30, radius * 0.30, height * 0.16), rng)
        batch.blob("wood_dead", Vector((x, y, MUSHROOM_BASE_Z + height * 0.30)),
                   (radius * 0.28, radius * 0.28, radius * 0.05), rng)
    batch.emit("stumps")


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
    ("apple_tree_full", build_apple_tree_full),
    ("apple_tree_picked", build_apple_tree_picked),
    ("mushroom_patch_full", build_mushroom_patch_full),
    ("mushroom_patch_harvested", build_mushroom_patch_harvested),
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
    prefixes = ANCHOR_PREFIXES.get(name, ())
    anchor = ([obj for obj in made if obj.name.startswith(prefixes)] if prefixes else None) or None
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
        cap_triangles = TRIANGLE_ALLOWANCE.get(name, TRIANGLE_BUDGET)
        if record["triangles"] > cap_triangles:
            problems.append(f"{name}: {record['triangles']} triangles over the "
                            f"{cap_triangles} budget")
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
