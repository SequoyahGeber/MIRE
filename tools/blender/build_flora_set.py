"""Build MIRE's flora kit — the undergrowth the environment kit never had.

Run with:
  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender/build_flora_set.py

Why a separate kit
------------------
`build_mire_map_kit.py` ships 128 assets and exactly **one** shape of ground
cover: bladed grass, in four sizes. It has no bush, no shrub, no flower, no
broadleaf plant, no sapling, no leaf litter, no moss — so every square metre of
the Hollow is bare ground, bladed grass, or a full-grown tree, and the eye reads
that as one repeated texture however many grass variants get scattered. This kit
fills the middle of that range: knee-to-shoulder plants, ankle-height detail, and
the young and dying trees that break up a treeline.

`docs/ASSET_TRACKER.md` says to prefer a new small generator per coherent family
over growing the map kit further, so this is its own family, catalog and export
directory. Both map consumers resolve an asset as
``assets/<kit>/exports/<name>.glb``, so a prop with ``"kit": "flora"`` works with
no change to either of them.

What was learned from a hand-authored reference, and what was not taken
----------------------------------------------------------------------
Sequoyah supplied a CC0 low-poly nature pack (Quaternius) as a reference. **No
geometry from it is used, imported, traced or shipped** — the instruction was to
learn the technique and build our own. Three measurements from it changed how
this kit is built, and all three are about restraint:

* **One mass, not a heap of ellipsoids.** Its bush is a single 364-triangle mesh
  with one material. MIRE's nearest equivalent was three meshes, five materials
  and 641 triangles for a shape that read as less. Hence `mire_art.hull()`.
* **Twelve blades, not thirty-six.** Its grass tuft is a dozen wide blades. The
  first draft of this kit used up to 46 thin ones per patch: more cost, and less
  legible, because at any real viewing distance thin blades merge into fuzz.
* **Detail that costs no geometry.** Its mossy rock is the *same* 36-face rock
  with some faces assigned a second material. Hence `mire_art.paint_faces()`.

Where the reference and MIRE disagree, MIRE wins: its palette is much darker and
more olive than ours, and ours was deliberately re-anchored bright after being
authored too dark once already (`docs/ASSET_TRACKER.md`, "Pick palette values
from base colour"). We are not undoing that to match somebody else's world.

Construction rules
------------------
* Sizes are **guaranteed, not hoped for**: every asset is scaled to a target
  drawn from its family's band before export, so the kit cannot drift against a
  1.80 m player the way the pickup kit did.
* Placement is angular (`radial`/`around`), never hand-written coordinates — the
  2.1j lesson about detail landing only on the side the author was looking at.
* Repeated small shapes are accumulated per material and emitted as one mesh per
  material, so a bracken bed exports two mesh parts rather than forty.
* No bevel modifier anywhere; F-057 traced non-deterministic rebuilds to it.
"""

from __future__ import annotations

import json
import math
import random
import sys
from pathlib import Path
from typing import Callable

import bpy
from mathutils import Matrix, Quaternion, Vector

sys.path.append(str(Path(__file__).resolve().parent))
from mire_art import (  # noqa: E402
    around,
    cone,
    fork,
    ground_and_centre,
    hull,
    look_at,
    mat,
    mesh_object,
    paint_faces,
    radial,
    reset_materials,
    tapered_between,
    trunk_tube,
    world_bounds,
)
from godot_import_lock import import_cache_guard  # noqa: E402


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "flora"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"
SOURCE_DIR = ROOT / "assets" / "source"
SOURCE_PATH = SOURCE_DIR / "flora_set.blend"

FAMILY_ORDER = ["shrubs", "small_trees", "leafy_plants", "flowers", "grasses", "ground_cover"]
FAMILY_PREVIEWS = {name: f"{name}_preview.png" for name in FAMILY_ORDER}

#: Authored size band per group, in metres, plus which axis the band governs.
#:
#: `mire_art.SCALE` is the wrong instrument here: it holds one exact dimension and
#: fails outside 12%, which suits a coin or an axe but not a seeded family where
#: `bush_round_a` and `bush_round_d` are *supposed* to differ. The contract a
#: randomized family can keep is a band — and it is kept by construction, because
#: `create_asset` scales each finished asset to a target drawn from the band. A
#: mat has no meaningful height, so its band governs spread instead.
#:
#: The fourth field is a hard footprint ceiling, and it exists because scaling to
#: a height band is not enough on its own. A rosette plant is naturally much wider
#: than it is tall, so multiplying it up until its *height* lands in band multiplies
#: its reach by the same factor: `bracken_c` came out a correct 0.95 m tall and
#: **4.34 m across**. Nothing in the build noticed — the all-sides audit did. Height
#: and footprint have to be stated separately or one of them runs away.
#: ``None`` means the band already governs spread directly.
#:
#: Set against a 1.80 m player: shin 0.2, knee 0.5, waist 1.0, chest 1.4.
SIZE_BAND: dict[str, tuple[float, float, str, float | None]] = {
    "bush_round": (0.90, 1.55, "height", 2.0),
    "bush_broadleaf": (1.35, 2.10, "height", 2.4),
    "bush_thorn": (0.80, 1.40, "height", 1.8),
    "bush_dead": (0.85, 1.55, "height", 1.8),
    "sapling": (1.30, 2.55, "height", 1.9),
    #: F-396 raised both of these. They used to sit at 4.2-6.2 m and 3.1-5.2 m
    #: against a 1.7 m player eye, which put the tallest willow in the kit at 3.4x
    #: eye height where a real tree reads at 6-15x; the island looked like scrub
    #: and the canopy never broke the horizon. Note that the band alone is NOT the
    #: fix — `create_asset` scales the finished asset UNIFORMLY to hit it, so
    #: raising only these numbers would have fattened the trunks by the same
    #: factor and produced the same tree seen from closer, which is exactly what
    #: the finding says not to do. The builders below are authored at the new
    #: height with trunk radii chosen independently; the band is what CHECKS them.
    #: F-424 raised the willow's footprint cap from 11.0 m to 13.0 m. The cap is a
    #: scatter-spacing guard, not a style rule, and 11.0 was set when this asset was
    #: a narrow generic tree wearing the name. A mature weeping willow's crown spread
    #: genuinely equals or exceeds its height — a 12.5 m one is 12-15 m across — so
    #: capping it under its own height was forcing the wrong tree. Still capped,
    #: because a prop wider than this overlaps its neighbours in the scatter field.
    "tree_willow": (10.50, 14.50, "height", 13.0),
    "tree_snag": (7.00, 11.00, "height", 5.0),
    "plant_broadleaf": (0.42, 0.90, "height", 1.7),
    "plant_dock": (0.60, 1.10, "height", 1.7),
    "plant_creeper": (0.85, 1.60, "spread", None),
    "bracken": (0.60, 1.15, "height", 2.2),
    "nettle": (0.50, 0.95, "height", 1.4),
    "flowers_meadow": (0.28, 0.58, "height", 1.6),
    "flowers_tall": (0.75, 1.35, "height", 1.4),
    "flowers_bog": (0.34, 0.72, "height", 1.1),
    "flowers_creeping": (0.70, 1.25, "spread", None),
    "grass_tussock": (0.55, 1.10, "height", 1.3),
    "grass_dry": (0.40, 0.82, "height", 1.6),
    "grass_short": (0.12, 0.28, "height", 1.6),
    "sedge": (0.65, 1.25, "height", 1.0),
    "marsh_grass": (0.80, 1.45, "height", 1.5),
    "lily_pad": (0.75, 1.40, "spread", None),
    "moss_patch": (0.55, 1.20, "spread", None),
    "clover_patch": (0.60, 1.15, "spread", None),
    "leaf_litter": (0.70, 1.40, "spread", None),
}

#: Triangle ceiling per family. Deliberately generous where the silhouette is the
#: whole point (a willow is read at 30 m) and tight where the asset is ground
#: texture the player walks over.
TRIANGLE_BUDGET = {
    "shrubs": 900, "small_trees": 2400, "leafy_plants": 700,
    "flowers": 650, "grasses": 520, "ground_cover": 620,
}

#: Preview grid. Ground cover packed at 1.6 m would be lost at tree spacing, and a
#: willow at 1.6 m spacing would overlap its neighbour, so spacing is per family
#: and the camera derives its framing from it rather than from a hand-tuned number
#: that silently stops matching when a family gains an asset.
COLUMNS = 7
#: `small_trees` went from 3.8 to 12.0 with F-396: the willows are 12.5 m tall
#: and 8-9 m across now, so at the old spacing the preview row was one hedge.
FAMILY_SPACING = {"shrubs": 3.0, "small_trees": 12.0, "leafy_plants": 1.7,
                  "flowers": 1.7, "grasses": 1.7, "ground_cover": 1.7}

#: Colours per asset. The first draft of this kit averaged five per asset and
#: several carried twenty-two (that was F-058, not intent), which is how a
#: low-poly scene turns to noise. The reference pack holds one or two — but it is
#: not the standard here, because MIRE's palette is deliberately built from
#: three-stop ramps so a flat-shaded form reads as one substance catching light at
#: three angles. A woody plant therefore legitimately spends four: two bark tones
#: and a two-stop leaf ramp. Ground cover with no wood in it gets three.
MAX_MATERIALS = {
    #: `small_trees` went 4 -> 5 with F-396, and only because a real tree needs
    #: both ramps. The reasoning above allows "two bark tones and a two-stop leaf
    #: ramp"; the willow's leaf ramp has always had three stops (`leaf`,
    #: `leaf_deep`, and `leaf_light` painted onto the canopy by `paint_faces`),
    #: which used up the whole budget and left the trunk on one flat colour —
    #: exactly what F-396 reports as "the trunks look really bad". Five buys the
    #: shadow tone that the flare and the bark ridges are drawn in. It is a
    #: ceiling, not a target: nothing else in the family is near it.
    "shrubs": 4, "small_trees": 5, "leafy_plants": 4,
    "flowers": 3, "grasses": 3, "ground_cover": 4,
}


def family_of(name: str) -> str:
    return name.rsplit("_", 1)[0]


def seed_for(name: str) -> int:
    return sum((index + 1) * ord(char) for index, char in enumerate(name))


# ---------------------------------------------------------------------------
# Batched geometry
# ---------------------------------------------------------------------------


class Batch:
    """Accumulate many small shapes and emit one mesh per material.

    A bracken bed is forty leaflets. Forty Blender objects export as forty glTF
    nodes with forty primitives, which costs far more at runtime than the
    triangles do. Everything repetitive goes through here instead.
    """

    def __init__(self) -> None:
        self._groups: dict[str, tuple[list, list]] = {}

    def add(self, token: str, vertices: list, faces: list) -> None:
        vert_list, face_list = self._groups.setdefault(token, ([], []))
        offset = len(vert_list)
        vert_list.extend(tuple(float(c) for c in v) for v in vertices)
        face_list.extend(tuple(index + offset for index in face) for face in faces)

    def blob(self, token: str, centre, radius, rng: random.Random) -> None:
        """An 8-triangle irregular octahedron — the cheapest thing that still
        reads as a mass. For anything bigger than a flower head, use `hull`."""
        cx, cy, cz = centre
        rx, ry, rz = (radius, radius, radius) if isinstance(radius, (int, float)) else radius

        def wobble(value: float) -> float:
            return value * rng.uniform(0.74, 1.26)

        vertices = [
            (cx + wobble(rx), cy, cz), (cx - wobble(rx), cy, cz),
            (cx, cy + wobble(ry), cz), (cx, cy - wobble(ry), cz),
            (cx, cy, cz + wobble(rz)), (cx, cy, cz - wobble(rz)),
        ]
        self.add(token, vertices, [
            (0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4),
            (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5),
        ])

    def ribbon(self, token: str, spine: list[Vector], half_widths: list[float], fold: list[float]) -> None:
        """A solid, folded strip along ``spine``: one leaf, one blade, one frond.

        Cross-section is a triangle — left edge, right edge, raised centre — so
        the strip has a top crease and a flat underside and is visible from every
        direction. A one-sided leaf card is an invisible leaf, because Godot
        imports glTF with back-face culling on; the crease is also what catches
        light differently along its length, which is most of why a flat-shaded
        leaf reads as a leaf.
        """
        if len(spine) < 2:
            return
        vertices: list[tuple[float, float, float]] = []
        faces: list[tuple[int, ...]] = []
        for index, point in enumerate(spine):
            nxt = spine[min(index + 1, len(spine) - 1)]
            prv = spine[max(index - 1, 0)]
            tangent = Vector((nxt.x - prv.x, nxt.y - prv.y, 0.0))
            if tangent.length < 1e-6:
                tangent = Vector((1.0, 0.0, 0.0))
            tangent.normalize()
            side = Vector((-tangent.y, tangent.x, 0.0)) * half_widths[index]
            vertices.extend([
                (point.x - side.x, point.y - side.y, point.z),
                (point.x + side.x, point.y + side.y, point.z),
                (point.x, point.y, point.z + fold[index]),
            ])
        for index in range(len(spine) - 1):
            a, b = index * 3, (index + 1) * 3
            faces.extend([
                (a + 0, b + 0, b + 2, a + 2),
                (a + 2, b + 2, b + 1, a + 1),
                (a + 1, b + 1, b + 0, a + 0),
            ])
        last = (len(spine) - 1) * 3
        faces.extend([(0, 2, 1), (last + 1, last + 2, last + 0)])
        self.add(token, vertices, faces)

    def emit(self, prefix: str) -> None:
        for token, (vertices, faces) in sorted(self._groups.items()):
            if vertices:
                mesh_object(f"{prefix}_{token}", vertices, faces, mat(token), recalculate=False)


# ---------------------------------------------------------------------------
# Shape recipes
# ---------------------------------------------------------------------------


def arc_spine(origin: Vector, angle: float, length: float, rise: float, droop: float,
              segments: int = 4) -> list[Vector]:
    """Points along a stem that leaves ``origin`` at ``angle``, lifts by ``rise``
    and falls away by ``droop`` — the arc a leaf or a frond actually makes."""
    return [
        Vector((
            origin.x + math.cos(angle) * length * t,
            origin.y + math.sin(angle) * length * t,
            origin.z + rise * math.sin(t * math.pi * 0.62) - droop * t * t,
        ))
        for t in (step / segments for step in range(segments + 1))
    ]


def leaf(batch: Batch, token: str, origin: Vector, angle: float, length: float, width: float,
         rise: float, droop: float, fold: float, segments: int = 4) -> None:
    """One broad leaf: widest a third of the way out, tapering to a point.

    ``segments=2`` is the cheap version (14 triangles) for leaflets and litter;
    4 is the one to use when the leaf is big enough to see the curve.
    """
    spine = arc_spine(origin, angle, length, rise, droop, segments=segments)
    profile = {1: [0.72, 0.05], 2: [0.30, 1.00, 0.05], 3: [0.20, 0.95, 0.80, 0.05],
               4: [0.10, 0.62, 1.00, 0.74, 0.04]}[segments]
    folds = {1: [1.0, 0.1], 2: [0.5, 1.0, 0.1], 3: [0.35, 1.0, 0.7, 0.1],
             4: [0.2, 0.9, 1.0, 0.7, 0.1]}[segments]
    batch.ribbon(token, spine, [width * 0.5 * v for v in profile], [fold * v for v in folds])


def blade(batch: Batch, token: str, origin: Vector, angle: float, height: float, width: float,
          lean: float, curve: float) -> None:
    """One grass blade: rises, bends over, tapers to nothing.

    Wide and few beats thin and many. Thin blades stop resolving as blades a few
    metres out and turn the patch into fuzz, while costing exactly as much.
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


def blade_cluster(batch: Batch, rng: random.Random, count: int, radius: float,
                  height_range: tuple[float, float], width_range: tuple[float, float],
                  tokens: list[str], lean_range: tuple[float, float],
                  curve_range: tuple[float, float], seed: int) -> None:
    for index, (angle, rad) in enumerate(radial(count, radius, seed=seed, jitter=0.55, radius_jitter=0.55)):
        distance = abs(rad) * (rng.random() ** 0.45)
        origin = Vector((math.cos(angle) * distance, math.sin(angle) * distance, 0.012))
        blade(batch, tokens[index % len(tokens)], origin, angle + rng.uniform(-0.9, 0.9),
              rng.uniform(*height_range), rng.uniform(*width_range),
              rng.uniform(*lean_range), rng.uniform(*curve_range))


def spread_pick(items: list, count: int) -> list:
    """Take ``count`` items spaced across ``items``, never the first ``count``.

    `fork()` returns its tips in depth-first order, so a prefix of that list is
    every tip of the *first* branch and nothing from the others. Hanging foliage
    on `tips[:5]` therefore puts all of it on one side of the plant — the exact
    defect task 2.1j exists to stop, reintroduced by a slice that looks harmless.
    """
    if count >= len(items):
        return list(items)
    step = len(items) / count
    return [items[int(index * step)] for index in range(count)]


def notched_disc(name: str, centre: tuple[float, float, float], radius: float, token: str,
                 seed: int, segments: int = 10, notch: float = 0.9,
                 thickness: float = 0.014) -> bpy.types.Object:
    """A flat leaf pad with a wedge cut out of it — a lily pad, in other words.

    Built as a thin *solid* slab rather than a single fan. A one-sided fan is
    cheaper and looks identical in Blender, but Godot imports glTF with back-face
    culling on, so the pad would simply not exist when seen from below the water
    line — and the all-sides audit flagged exactly that, reporting two of the
    three pads as inside out because a zero-volume surface has no inside to be on
    the wrong side of. Twelve extra triangles buys a pad with a real underside.
    """
    rng = random.Random(seed)
    span = math.tau - notch
    rim: list[tuple[float, float, float]] = []
    for step in range(segments + 1):
        angle = notch * 0.5 + span * step / segments
        r = radius * rng.uniform(0.88, 1.06)
        rim.append((centre[0] + math.cos(angle) * r, centre[1] + math.sin(angle) * r,
                    centre[2] + rng.uniform(-0.004, 0.010)))
    top = [centre] + rim
    bottom = [(x, y, z - thickness) for x, y, z in top]
    offset = len(top)
    vertices = top + bottom
    faces: list[tuple[int, ...]] = []
    for i in range(1, segments + 1):
        faces.append((0, i, i + 1))
        faces.append((offset, offset + i + 1, offset + i))
        faces.append((i, offset + i, offset + i + 1, i + 1))
    # Close the notch: the two radial cuts are open edges otherwise.
    faces.append((0, offset, offset + 1, 1))
    faces.append((0, segments + 1, offset + segments + 1, offset))
    return mesh_object(name, vertices, faces, mat(token), recalculate=True)


# ---------------------------------------------------------------------------
# Builders — shrubs
# ---------------------------------------------------------------------------


def build_bush_round(seed: int) -> None:
    """A dense rounded bush: three overlapping lobes, lit crowns painted on.

    Two earlier drafts got this wrong in opposite directions. Eighteen small
    ellipsoids read as a bag of peas; one big displaced sphere read as an egg —
    and adding `droop` to the egg just gave it feet, because hanging lobes are
    what a *crown* does when it is held up in the air, not what a bush does when
    it is sitting on the ground. What actually makes a bush is a small number of
    masses of comparable size overlapping at slightly different heights, so the
    silhouette has shoulders. Three is enough, and three is 240 triangles.
    """
    rng = random.Random(seed)
    tokens = ["leaf", "leaf_deep", "leaf"]
    lit = ["leaf_light", "leaf", "leaf_light"]
    for index, (angle, rad) in enumerate(radial(3, 0.20, seed=seed + 5, jitter=0.5, radius_jitter=0.35)):
        size = rng.uniform(0.38, 0.54)
        centre = around((0.0, 0.0, rng.uniform(0.38, 0.72)), angle, rad)
        lobe = hull(
            f"Lobe_{index + 1}", centre,
            (size, size * rng.uniform(0.86, 1.14), size * rng.uniform(0.80, 1.05)),
            mat(tokens[index]), seed + index * 31,
            subdivisions=1, lumps=3, lump=0.52, sharpness=2.0,
            taper=rng.uniform(0.10, 0.26), flat_base=0.88,
        )
        paint_faces(lobe, mat(lit[index]), min_normal_z=0.34, min_height=0.50,
                    coverage=0.75, seed=seed + index)


def build_bush_broadleaf(seed: int) -> None:
    """Taller and open: real branch structure carrying separate leaf masses, so
    it breaks a treeline instead of adding another green ball."""
    rng = random.Random(seed)
    tips = fork("Stem", (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 0.62, 0.055, mat("wood_bark"), seed + 17,
                depth=3, splits=(2, 3), spread=0.62, shrink=0.66, curve=0.26, vertices=5)
    for index, tip in enumerate(spread_pick(tips, rng.randint(4, 6))):
        size = rng.uniform(0.26, 0.40)
        mass = hull(f"Leaves_{index + 1}", tuple(tip), (size, size * rng.uniform(0.82, 1.1), size * 0.72),
                    mat("leaf" if index % 2 else "leaf_deep"), seed + index * 29,
                    subdivisions=1, lumps=3, lump=0.48, sharpness=2.0, droop=0.22, droop_lobes=2,
                    droop_sharpness=3.2)
        paint_faces(mass, mat("leaf_light"), min_normal_z=0.36, min_height=0.5, coverage=0.55,
                    seed=seed + index)


def build_bush_thorn(seed: int) -> None:
    """Twiggy and half-bare: silhouette rather than mass. Recursive branching is
    what makes the tangle read; a two-level fan of sticks does not."""
    rng = random.Random(seed)
    batch = Batch()
    tips = fork("Thorn", (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 0.46, 0.038, mat("wood_dead"), seed + 19,
                depth=4, splits=(2, 3), spread=0.70, shrink=0.70, curve=0.34, vertices=4)
    for index, tip in enumerate(tips):
        if rng.random() < 0.55:
            size = rng.uniform(0.055, 0.10)
            batch.blob("leaf_deep" if index % 2 else "leaf_dry", tuple(tip), (size, size * 0.8, size * 0.6), rng)
    batch.emit("Thorn")


def build_bush_dead(seed: int) -> None:
    """Grey deadwood, one colour, nothing else. Next to the living ones that is
    the entire job."""
    fork("Dead", (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 0.50, 0.045, mat("wood_dead"), seed + 23,
         depth=4, splits=(2, 3), spread=0.62, shrink=0.68, curve=0.30, vertices=4,
         tip_material=mat("wood_dead_cut"))


# ---------------------------------------------------------------------------
# Builders — small trees
# ---------------------------------------------------------------------------


def build_sapling(seed: int) -> None:
    """A young tree. Between ankle-height grass and a 6 m pine the kit had
    nothing, which is why the forest edge reads as placed rather than grown."""
    rng = random.Random(seed)
    height = 1.9
    lean = Vector((rng.uniform(-0.14, 0.14), rng.uniform(-0.14, 0.14), 0.0))
    mid = lean * 0.4 + Vector((0.0, 0.0, height * 0.46))
    top = lean + Vector((0.0, 0.0, height * 0.84))
    tapered_between("Trunk_Lower", (0.0, 0.0, 0.0), tuple(mid), 0.055, 0.038, mat("wood_bark"), 6)
    tapered_between("Trunk_Upper", tuple(mid), tuple(top), 0.038, 0.016, mat("wood_bark"), 6)
    conifer = seed % 2 == 0
    if conifer:
        for tier in range(3):
            t = tier / 2.0
            z = height * (0.34 + t * 0.46)
            radius = (0.42 - t * 0.20) * rng.uniform(0.9, 1.1)
            cone(f"Tier_{tier + 1}", radius, radius * 0.16, height * 0.30,
                 tuple(lean * (z / height) + Vector((0.0, 0.0, z))),
                 mat(("pine_dark", "pine", "pine_light")[tier]), 7)
        cone("Leader", 0.10, 0.008, height * 0.20, tuple(top + Vector((0.0, 0.0, 0.02))), mat("pine_light"), 6)
        return
    branch_tips = fork("Branch", tuple(lean * 0.28 + Vector((0.0, 0.0, height * 0.34))),
                       tuple((top - mid).normalized()), 0.46, 0.032,
                       mat("wood_bark"), seed + 31, depth=3, splits=(2, 3), spread=0.66,
                       shrink=0.66, curve=0.26, vertices=4)
    for index, tip in enumerate(spread_pick(branch_tips, rng.randint(5, 7))):
        size = rng.uniform(0.20, 0.30)
        mass = hull(f"Crown_{index + 1}", tuple(tip), (size, size * 0.94, size * 0.68),
                    mat("leaf" if index % 2 else "leaf_deep"), seed + index * 37,
                    subdivisions=1, lumps=3, lump=0.46, sharpness=2.0, droop=0.20, droop_lobes=2,
                    droop_sharpness=3.2)
        paint_faces(mass, mat("leaf_light"), min_normal_z=0.36, min_height=0.48, coverage=0.6,
                    seed=seed + index)


def rolled_between(name: str, start, end, radius_start: float, radius_end: float,
                   material, vertices: int = 7, roll: float = 0.0):
    """`tapered_between` with control over the roll about the segment's own axis.

    F-396, "the trunks look really bad": a trunk built as a stack of frusta that
    all share a roll is a smooth extruded polygon with a seam, so the whole column
    shades as one flat band and reads as plastic pipe. Rolling each segment
    separately breaks the facets into plates that catch light on their own. Same
    vertices, different rotation — it is free.
    """
    obj = tapered_between(name, start, end, radius_start, radius_end, material, vertices)
    direction = Vector(end) - Vector(start)
    obj.rotation_quaternion = direction.to_track_quat("Z", "Y") @ Quaternion(Vector((0.0, 0.0, 1.0)), roll)
    return obj


def standing_trunk(height: float, base_radius: float, tip_radius: float, lean: Vector,
                   sway: float, segments: int, tones: tuple, rng: random.Random, seed: int,
                   **kwargs) -> tuple[list[Vector], list[float]]:
    """The trunk both of this kit's real trees stand on — `mire_art.trunk_tube`.

    F-422: this used to be a private copy of the map kit's frustum stack, defect
    for defect — a silhouette that shouldered at every segment joint, a splayed
    "chicken foot" of root cones round the base, a hard tone break where the
    separate flare cone met the column, and bark ridges anchored to the BASE
    radius that finished outside a tapering trunk as a dark stick leaning on it.
    Both copies are gone; the generator lives in `mire_art` and every dimension
    it varies is an explicit argument, so nothing here is reshaped implicitly.

    Kept as a named wrapper because this kit's callers read better for it and
    because the flare rule is this kit's to remember: **the flare tops out below
    half a metre on purpose.** `ResourceScatterField.COLLIDER_TRUNK_BAND_MIN_M`
    is 0.5 m — F-390 lifted the collider's measuring band off the floor precisely
    because the flare, not the trunk, was setting the radius, which is what put
    `tree_willow_a` at a 1.29 m collider around a 0.3 m trunk and had the player
    stopped a metre off the bark. Keeping the flare under that line buys a
    well-planted base for nothing.
    """
    return trunk_tube(height, base_radius, tip_radius, lean, sway, segments, tones, rng, seed,
                      **kwargs)


def spine_point(points: list[Vector], fraction: float) -> Vector:
    """Point at `fraction` of the way up a trunk spine, interpolated between the
    two nearest control points."""
    span = len(points) - 1
    position = max(0.0, min(1.0, fraction)) * span
    low = min(span - 1, int(position))
    return points[low].lerp(points[low + 1], position - low)


def build_tree_willow(seed: int) -> None:
    """A weeping willow, built from what a weeping willow actually is.

    F-424, Sequoyah: *"the leaves don't really fit a willow tree and the trunk is
    wayyy too skinny for a willow tree — try to do some research of the real life
    thing that you're designing in low poly and model the asset after the real
    thing."* The previous version was the kit's standard slim trunk carrying the
    kit's standard round crown, with a handful of fat teardrops hung off the rim.
    That is a generic tree wearing a species name. What `Salix babylonica`
    actually looks like, and what each fact costs here:

    * **The bole is short and very thick.** A mature weeping willow forks into
      several big ascending limbs somewhere between a fifth and a third of its
      height — often barely above head height — and the trunk under that fork is
      commonly 0.8-1.2 m ACROSS. So: `fork_fraction` 0.24 instead of 0.62, and a
      thicker bole than the 0.46 m radius this asset used to carry. This is the
      single biggest change and the one that was complained about; nothing else
      reads right until the tree is standing on a real bole.

      **F-434 corrected the number, not the intent.** F-424 first set
      `base_radius` to 0.78 m — the research figure applied as a RADIUS where it
      states a DIAMETER, so the finished tree stood on a bole 2.2 m across at
      chest height once `create_asset` scaled it into its size band. That is a
      baobab, and because `ResourceScatterField` measures the collider off the
      trunk it honestly gave, `tree_willow_a` collided at r=1.08 m against
      0.48-0.66 m for every pine, birch and broadleaf in either kit — reported
      from play as *"the collision boxs of willows are huge"*. 0.52 m here lands
      the finished bole near 1.4 m across: still visibly the stoutest trunk on
      the island, still nothing like the old 0.46 m stick, and no longer twice
      every other tree to walk around.
    * **The bark is deeply furrowed** — coarse vertical ridges, far rougher than
      a birch or a young pine. That is what `flute` and `grain` are for on
      `trunk_tube`, and this asset takes the highest values in either kit.
    * **The crown is as wide as the tree is tall, or wider,** and it is NOT a
      dome. Its surface is made of hanging strands, so the silhouette is streaked
      vertically and ragged along the bottom. A smooth capping hull — which is
      what the old asset had — is the one shape a willow never makes, so there
      is no capping hull here at all: the top of the crown is the arch of the
      limbs and the tops of the strands that hang off them.
    * **The whips are long, thin and many.** Slender pendulous shoots, 1-3 m,
      falling nearly to the ground on a big tree. Built as tall narrow tapering
      strands in clusters along each arching limb, at mixed lengths and mixed
      widths — a few broad ones carry the mass at distance, the thin ones between
      them carry the streak up close.
    * **The colour is pale.** Willow leaves are narrow, light green above and
      silvery beneath, and a hanging curtain shows a lot of underside. So the
      ramp runs `leaf` -> `leaf_light` -> `leaf_pale` rather than sitting on the
      forest greens the broadleaves use — a willow that reads as dark as an oak
      is wrong even before its shape is.

    Willows want wet feet, which is why this is the tree the marsh biome carries.
    """
    rng = random.Random(seed)
    height = 12.5
    lean = Vector((rng.uniform(-0.40, 0.40), rng.uniform(-0.34, 0.34), 0.0))
    # A short, heavy bole. Everything downstream hangs off how low this forks.
    fork_fraction = 0.24
    points, radii = standing_trunk(
        height * fork_fraction, 0.52, 0.38, lean * fork_fraction, height * 0.006, 3,
        # Two bark tones, not three: the leaf ramp already spends three of this
        # family's five (MAX_MATERIALS), and the one that has to exist is the
        # SHADOW — it is what the deep furrows are drawn in.
        (mat("wood_bark_dark"), mat("wood_bark"), mat("wood_bark")), rng, seed,
        vertices=9, flare=1.70, flare_power=1.4, flare_top=0.40, toe=0.55, toe_top=0.30,
        taper_power=1.0, grain=0.115, flute=0.80, shade_columns=2, lit_columns=0,
    )
    crotch = points[-1]

    leaves = (mat("leaf"), mat("leaf_light"), mat("leaf_pale"))
    # Three or four big ascending limbs out of the low fork, each carrying its own
    # spray of smaller arching branches. A willow's mass comes from this second
    # level: one limb per direction gives a beach umbrella, which is the other
    # half of what made the old asset read wrong.
    limbs = rng.randint(3, 4)
    # Crown spread. A weeping willow's is roughly its own height, and building
    # the crown up to the tree's stated height (see `rise` below) narrowed the
    # footprint to 8.7 m on a 13.6 m tree, which is an oak's proportion, not a
    # willow's. `SIZE_BANDS`' 13.0 m footprint cap is the ceiling.
    reach = 4.85
    for index, (angle, _rad) in enumerate(radial(limbs, 1.0, seed=seed + 43, jitter=0.30)):
        # The limbs have to carry the crown to very near the tree's stated height.
        # This is not a proportion choice, it is the flare rule again: `create_asset`
        # scales the finished asset UNIFORMLY to land inside `SIZE_BANDS`, so a tree
        # whose geometry stops at 10 m and is then stretched to 13.6 m takes its ROOT
        # FLARE up with it — measured at 1.70 m wide at 0.6 m, i.e. straight through
        # `COLLIDER_TRUNK_BAND_MIN_M`, which is the exact defect F-390 lifted that
        # band off the floor to kill. Building to height keeps the scale factor near
        # 1.0 and keeps the flare under the line where it costs nothing.
        rise = height * rng.uniform(0.64, 0.74)
        elbow = Vector((crotch.x + math.cos(angle) * reach * 0.34,
                        crotch.y + math.sin(angle) * reach * 0.34,
                        crotch.z + rise * 0.70))
        shoulder = Vector((crotch.x + math.cos(angle) * reach * 0.82,
                           crotch.y + math.sin(angle) * reach * 0.82,
                           crotch.z + rise))
        tapered_between(f"Limb_{index + 1}_1", tuple(crotch), tuple(elbow),
                        radii[-1] * 0.62, radii[-1] * 0.44, mat("wood_bark"), 6)
        tapered_between(f"Limb_{index + 1}_2", tuple(elbow), tuple(shoulder),
                        radii[-1] * 0.44, radii[-1] * 0.24, mat("wood_bark"), 5)

        # Two more whips hung straight off the limb between elbow and shoulder.
        # A willow's crown is full to its middle; without these the interior is
        # an empty cone with the structural limbs on show inside it.
        for inner in range(2):
            anchor = elbow.lerp(shoulder, 0.35 + 0.40 * inner)
            drop = max(0.8, anchor.z - 0.5)
            fall = drop * rng.uniform(0.45, 0.85)
            width = rng.uniform(0.26, 0.36)
            hull(f"Inner_{index + 1}_{inner + 1}",
                 (anchor.x, anchor.y, anchor.z - width - fall * 0.48),
                 (width, width * rng.uniform(0.82, 1.18), fall * 0.58),
                 leaves[(seed + index + inner) % 3], seed + index * 23 + inner * 7,
                 subdivisions=0, lumps=3, lump=0.34, sharpness=2.4, taper_low=0.66)

        # Each limb divides into arching branches that go OVER and start falling.
        # The arch is where the weeping begins; without it the strands hang off a
        # spike and the tree reads as a mop on a pole.
        for sub in range(4):
            swing = angle + rng.uniform(-0.72, 0.72)
            span = reach * rng.uniform(0.30, 0.54)
            # The branch goes over the top of its arch and starts DOWN again.
            # Ending it above the shoulder left the tops of the whips standing
            # proud of the crown as isolated spikes; a willow's outline above the
            # foliage is bare limb, never leaf-tips pointing up.
            tip = Vector((shoulder.x + math.cos(swing) * span,
                          shoulder.y + math.sin(swing) * span,
                          shoulder.z + rng.uniform(-0.75, 0.30)))
            tapered_between(f"Branch_{index + 1}_{sub + 1}", tuple(shoulder), tuple(tip),
                            radii[-1] * 0.22, radii[-1] * 0.08, mat("wood_bark"), 4)

            # The whips. A weeping willow's shoots are SLENDER — a few centimetres
            # across and metres long — and there are hundreds of them. The first
            # cut of this made six per tree at half a metre wide, which is the
            # shape of a hanging leaf the size of a canoe: the preview read as
            # green footballs strung on a stick. Thin and many is the only way the
            # curtain reads, and it is what hides the limbs, which a real willow's
            # foliage does completely.
            #
            # Mixed widths on purpose: the broad ones are the only thing visible
            # at 60 m, the thin ones the only thing that reads as strands at 3 m,
            # and a curtain of one width is a bedsheet at both distances.
            for strand in range(5):
                # From the shoulder outward, not from a fifth of the way along.
                # Starting at 0.12 left a hole around every limb junction and the
                # tree read as four separate hanging brooms with the bare limbs
                # visible between them.
                along = 0.02 + 0.23 * strand + rng.uniform(-0.05, 0.05)
                anchor = shoulder.lerp(tip, along)
                broad = strand % 3 == 1
                # Length as a FRACTION of how high the shoot starts, not an
                # absolute range. An absolute range clamps against the anchor
                # height and every strand ends up reaching almost the same way
                # down, which gives the curtain a level hem — the one edge a
                # willow never has. Proportional lengths keep the hem ragged at
                # every tree size.
                drop = max(0.8, anchor.z - 0.5)
                fall = drop * (rng.uniform(0.58, 1.0) if broad else rng.uniform(0.38, 0.94))
                width = rng.uniform(0.30, 0.42) if broad else rng.uniform(0.17, 0.26)
                hull(
                    f"Whip_{index + 1}_{sub + 1}_{strand + 1}",
                    # Hung on the branch LINE with no lateral scatter at all, and
                    # overlapping it by a tenth of its own length. Every version
                    # of this that jittered the anchor sideways — even by less
                    # than the strand's own width — detached two to four whips
                    # per tree, because the far end of a branch is 45 mm thick and
                    # there is nothing there to miss by. A shoot with daylight
                    # between it and its own branch is the same defect as a root
                    # cone lying beside a trunk (F-422). Variety comes from length,
                    # width and lump seed instead, which cannot come unstuck.
                    # Tucked down by its own width so the strand's crown sits
                    # INSIDE the branch instead of standing above it. Without the
                    # tuck the top of every whip pokes through as a pale spike and
                    # the crown's upper edge reads as a row of flames; a willow's
                    # outline above its foliage is bare limb.
                    (anchor.x, anchor.y, anchor.z - width * 0.55 - fall * 0.45),
                    (width, width * rng.uniform(0.82, 1.18), fall * 0.62),
                    leaves[(seed + index * 3 + sub + strand) % 3],
                    seed + index * 59 + sub * 17 + strand,
                    subdivisions=0, lumps=3, lump=0.34, sharpness=2.4,
                    # `taper` narrows the top; a hanging shoot thins DOWNWARD, so
                    # this wants `taper_low`, which F-424 added to `hull` for it.
                    # `taper=-0.62` reads like the right answer and is not — a
                    # negative taper FLARES the top, which is what the camp set's
                    # pot rims depend on, so the sign was not free to repurpose.
                    taper_low=0.66,
                )


def build_tree_snag(seed: int) -> None:
    """A dead trunk snapped off partway up: history, at almost no cost, because
    there is no crown to build.

    F-396 took it from 3.4 m to 9 m, and it is the one tree in either kit that is
    *supposed* to be shorter than its neighbours — a snag is what is left of a
    tree that used to be as tall as the pines around it, so it reads correctly at
    roughly two-thirds their height and wrong at either extreme. Its trunk gets
    the same flare and taper as the living ones, because the thing that snapped
    was a full-grown tree.
    """
    rng = random.Random(seed)
    height = 9.0
    lean = Vector((rng.uniform(-0.40, 0.40), rng.uniform(-0.34, 0.34), 0.0))
    points, radii = standing_trunk(
        height, 0.52, 0.24, lean, height * 0.010, 6,
        (mat("wood_dead"), mat("wood_dead"), mat("wood_dead_cut")), rng, seed,
        vertices=8, flare=2.10, flare_power=1.5, toe=0.68, toe_top=0.32, taper_power=1.10,
        # Dead wood weathers into hard vertical grooves and loses its bark in
        # strips, so the snag takes deeper flutes than a living trunk and puts
        # two columns in the pale cut-wood tone rather than one.
        grain=0.100, flute=0.72, shade_columns=1, lit_columns=2,
    )
    top = points[-1]

    for index, (angle, rad) in enumerate(radial(rng.randint(4, 5), radii[-1] * 0.62,
                                                seed=seed + 61, jitter=0.42)):
        base = around((top.x, top.y, top.z - 0.10), angle, rad)
        tapered_between(f"Splinter_{index + 1}", base,
                        (base[0], base[1], base[2] + rng.uniform(0.40, 1.15)),
                        0.075, 0.014, mat("wood_dead_cut"), 4)
    for index, (angle, rad) in enumerate(radial(rng.randint(3, 4), 0.30, seed=seed + 67, jitter=0.48)):
        fraction = rng.uniform(0.42, 0.90)
        anchor = around(tuple(spine_point(points, fraction)), angle, rad * 0.6)
        # 1.0 m, not 1.35: three levels of `fork` compound, and at 1.35 the stubs
        # reached 5.8 m across — wider than the tree is interesting, and wide
        # props are what make a scatter field read as overlapping soup.
        fork(f"Stub_{index + 1}", anchor, (math.cos(angle), math.sin(angle), rng.uniform(0.10, 0.55)),
             1.0, 0.13, mat("wood_dead"), seed + index * 71, depth=3, splits=(2, 2), spread=0.55,
             shrink=0.62, curve=0.26, vertices=4)
    skirt = hull("Moss_Skirt", (0.0, 0.0, 0.14), (0.96, 0.90, 0.20), mat("moss_dark"), seed + 79,
                 subdivisions=1, lumps=6, lump=0.42, flat_base=0.55)
    paint_faces(skirt, mat("moss"), min_normal_z=0.30, min_height=0.42, coverage=0.7, seed=seed + 4)


# ---------------------------------------------------------------------------
# Builders — leafy plants
# ---------------------------------------------------------------------------


def build_plant_broadleaf(seed: int) -> None:
    """A rosette of wide leaves — the ground plant that is not a blade of grass."""
    rng = random.Random(seed)
    batch = Batch()
    tokens = ["leaf_deep", "leaf", "leaf_light"]
    for index, (angle, rad) in enumerate(radial(rng.randint(5, 7), 0.05, seed=seed + 83, jitter=0.5)):
        origin = Vector(around((0.0, 0.0, 0.03), angle, rad))
        length = rng.uniform(0.34, 0.46)
        leaf(batch, tokens[index % 3], origin, angle, length, length * rng.uniform(0.46, 0.64),
             rng.uniform(0.34, 0.50), rng.uniform(0.05, 0.12), rng.uniform(0.035, 0.065))
    batch.emit("Rosette")


def build_plant_dock(seed: int) -> None:
    """Dock: big ragged basal leaves and a rust seed spike. Wet, unlovely, and
    exactly this world's weed."""
    rng = random.Random(seed)
    batch = Batch()
    for index, (angle, rad) in enumerate(radial(rng.randint(4, 6), 0.06, seed=seed + 89, jitter=0.5)):
        origin = Vector(around((0.0, 0.0, 0.03), angle, rad))
        length = rng.uniform(0.34, 0.48)
        leaf(batch, ["leaf_deep", "leaf", "leaf", "leaf_dry"][index % 4], origin, angle, length,
             length * rng.uniform(0.38, 0.52), rng.uniform(0.30, 0.46), rng.uniform(0.06, 0.14),
             rng.uniform(0.032, 0.058))
    for index, (angle, rad) in enumerate(radial(rng.randint(1, 2), 0.09, seed=seed + 97, jitter=0.6)):
        base = around((0.0, 0.0, 0.04), angle, rad)
        top = (base[0] + math.cos(angle) * 0.07, base[1] + math.sin(angle) * 0.07, 0.72)
        tapered_between(f"Spike_{index + 1}", base, top, 0.014, 0.007, mat("leaf_dry"), 4)
        for step in range(5):
            t = 0.44 + step * 0.13
            point = tuple(base[i] + (top[i] - base[i]) * t for i in range(3))
            size = 0.036 * (1.3 - t)
            batch.blob("flower_rust", point, (size, size, size * 1.6), rng)
    batch.emit("Dock")


def build_plant_creeper(seed: int) -> None:
    """Ground ivy: runners crossing the soil with leaves along them. Almost flat,
    so it dresses ground the eye passes over without adding height."""
    rng = random.Random(seed)
    batch = Batch()
    for index, (angle, rad) in enumerate(radial(rng.randint(3, 4), 0.58, seed=seed + 101, jitter=0.5)):
        length = abs(rad) * rng.uniform(1.1, 1.6)
        points = [
            Vector((math.cos(angle + math.sin(t * 3.0) * 0.45) * length * t,
                    math.sin(angle + math.sin(t * 3.0) * 0.45) * length * t,
                    0.02 + math.sin(t * math.pi) * 0.025))
            for t in (0.0, 0.5, 1.0)
        ]
        for step in range(2):
            tapered_between(f"Runner_{index + 1}_{step + 1}", tuple(points[step]), tuple(points[step + 1]),
                            0.011, 0.009, mat("leaf_deep"), 4)
        for step in (1, 2):
            for side in (-1.0, 1.0):
                leaf(batch, ["leaf", "leaf_light"][(index + step) % 2],
                     points[step] + Vector((0.0, 0.0, 0.006)), angle + side * rng.uniform(0.9, 1.5),
                     rng.uniform(0.13, 0.20), rng.uniform(0.11, 0.17),
                     rng.uniform(0.03, 0.07), 0.006, rng.uniform(0.014, 0.026), segments=3)
    batch.emit("Creeper")


def build_bracken(seed: int) -> None:
    """A proper frond: a rachis carrying pinnae dense enough to touch.

    The kit's existing fern is three ellipsoids on a stick. The first cut of this
    one was worse in a more instructive way — the pinnae were correct but there
    were only three per side on a metre of rachis, so it read as a bare antenna
    with specks on it. **A fern is not its stem, it is the continuous blade the
    pinnae make**, so they have to be long enough and close enough to overlap.
    Getting there inside the triangle budget meant an 8-triangle leaflet and a
    rachis drawn as three cylinders while the pinnae are sampled from a finer
    twelve-point arc — the stem is the cheapest thing on the plant to fake and
    the leaflets are the thing worth paying for.
    """
    rng = random.Random(seed)
    batch = Batch()
    for index, (angle, rad) in enumerate(radial(4, 0.07, seed=seed + 103, jitter=0.45)):
        origin = Vector(around((0.0, 0.0, 0.03), angle, rad))
        length = rng.uniform(0.52, 0.66)
        arc = arc_spine(origin, angle, length, rng.uniform(0.62, 0.86), rng.uniform(0.14, 0.26),
                        segments=12)
        for step in range(3):
            tapered_between(f"Rachis_{index + 1}_{step + 1}", tuple(arc[step * 4]), tuple(arc[step * 4 + 4]),
                            0.013 - step * 0.003, 0.011 - step * 0.003, mat("bracken"), 4)
        token = "bracken" if index % 2 else "leaf_deep"
        for step in range(7):
            t = 0.16 + step * 0.14
            node = arc[min(len(arc) - 1, int(t * 12))]
            pinna = 0.30 * (1.0 - 0.48 * t) * rng.uniform(0.88, 1.12)
            for side in (-1.0, 1.0):
                leaf(batch, token, node, angle + side * rng.uniform(0.92, 1.18),
                     pinna, pinna * 0.46, -0.012, pinna * 0.26, pinna * 0.16, segments=1)
    for index, (angle, rad) in enumerate(radial(2, 0.10, seed=seed + 419, jitter=0.6)):
        base = around((0.0, 0.0, 0.03), angle, rad)
        top = (base[0], base[1], base[2] + rng.uniform(0.20, 0.34))
        tapered_between(f"Crozier_{index + 1}", base, top, 0.012, 0.009, mat("bracken"), 4)
        batch.blob("bracken", top, (0.036, 0.026, 0.036), rng)
    batch.emit("Bracken")


def build_nettle(seed: int) -> None:
    """Paired opposite leaves up a stem — a silhouette that is neither rosette
    nor blade, which is the only reason it earns a slot."""
    rng = random.Random(seed)
    batch = Batch()
    for index, (angle, rad) in enumerate(radial(rng.randint(3, 4), 0.15, seed=seed + 107, jitter=0.55)):
        height = rng.uniform(0.55, 0.80)
        base = around((0.0, 0.0, 0.02), angle, rad)
        top = (base[0] + math.cos(angle) * 0.05, base[1] + math.sin(angle) * 0.05, height)
        tapered_between(f"Stem_{index + 1}", base, top, 0.014, 0.008, mat("grass_dark"), 4)
        for pair in range(3):
            t = 0.32 + pair * 0.22
            node = Vector(tuple(base[i] + (top[i] - base[i]) * t for i in range(3)))
            size = (0.20 - 0.07 * t) * rng.uniform(0.88, 1.15)
            for side in (0.0, math.pi):
                leaf(batch, "leaf_deep" if pair % 2 else "leaf", node,
                     angle + pair * 1.31 + side, size, size * 0.58, size * 0.24, size * 0.30,
                     size * 0.14, segments=3)
    batch.emit("Nettle")


# ---------------------------------------------------------------------------
# Builders — flowers
# ---------------------------------------------------------------------------


def build_flowers_meadow(seed: int) -> None:
    """Low grass with blooms through it. Blossom stays a few percent of the
    silhouette: fire and brass are this world's warm accents and a field of
    solid colour would fight them."""
    rng = random.Random(seed)
    batch = Batch()
    blade_cluster(batch, rng, 11, 0.42, (0.16, 0.34), (0.045, 0.080),
                  ["grass_dark", "grass"], (0.06, 0.24), (0.08, 0.24), seed + 109)
    head = ["flower_white", "flower_cream", "flower_yellow", "flower_pink"][seed % 4]
    for index, (angle, rad) in enumerate(radial(rng.randint(5, 7), 0.36, seed=seed + 113, jitter=0.6)):
        height = rng.uniform(0.26, 0.44)
        base = around((0.0, 0.0, 0.02), angle, rad)
        top = (base[0] + math.cos(angle) * height * 0.14, base[1] + math.sin(angle) * height * 0.14, height)
        tapered_between(f"Stalk_{index + 1}", base, top, 0.009, 0.006, mat("grass_dark"), 4)
        for petal_angle, petal_rad in radial(4, 0.032, seed=seed + index * 13, jitter=0.4):
            batch.blob(head, around(top, petal_angle, petal_rad), (0.022, 0.022, 0.011), rng)
    batch.emit("Meadow")


def build_flowers_tall(seed: int) -> None:
    """Waist-high flowering spires. Vertical accents read at a distance where a
    ground rosette does not."""
    rng = random.Random(seed)
    batch = Batch()
    head = ["flower_pink", "flower_white", "flower_cream"][seed % 3]
    for index, (angle, rad) in enumerate(radial(rng.randint(3, 4), 0.20, seed=seed + 127, jitter=0.55)):
        height = rng.uniform(0.85, 1.15)
        base = around((0.0, 0.0, 0.02), angle, rad)
        top = (base[0] + math.cos(angle) * 0.10, base[1] + math.sin(angle) * 0.10, height)
        tapered_between(f"Stalk_{index + 1}", base, top, 0.015, 0.007, mat("grass_dark"), 5)
        for pair in range(2):
            t = 0.20 + pair * 0.20
            node = Vector(tuple(base[i] + (top[i] - base[i]) * t for i in range(3)))
            for side in (0.0, math.pi):
                leaf(batch, "grass_dark", node, angle + side + rng.uniform(-0.3, 0.3),
                     rng.uniform(0.13, 0.20), rng.uniform(0.045, 0.070), 0.02, 0.05, 0.014, segments=2)
        for step in range(5):
            t = 0.52 + (step / 5.0) * 0.46
            node = tuple(base[i] + (top[i] - base[i]) * t for i in range(3))
            for bloom_angle, bloom_rad in radial(2, 0.034 * (1.35 - t), seed=seed + index * 19 + step,
                                                 jitter=0.5):
                size = 0.026 * (1.35 - t)
                batch.blob(head, around(node, bloom_angle, bloom_rad), (size, size, size * 0.8), rng)
    batch.emit("TallFlowers")


def build_flowers_bog(seed: int) -> None:
    """Bog cotton: white tufts on bare stalks over wet ground. The only thing in
    the kit brighter than the sky, and deliberately tiny."""
    rng = random.Random(seed)
    batch = Batch()
    blade_cluster(batch, rng, 8, 0.32, (0.18, 0.34), (0.030, 0.055),
                  ["sedge", "grass_dry"], (0.05, 0.18), (0.06, 0.20), seed + 131)
    for index, (angle, rad) in enumerate(radial(rng.randint(5, 7), 0.30, seed=seed + 137, jitter=0.6)):
        height = rng.uniform(0.34, 0.56)
        base = around((0.0, 0.0, 0.02), angle, rad)
        top = (base[0] + math.cos(angle) * 0.03, base[1] + math.sin(angle) * 0.03, height)
        tapered_between(f"Stalk_{index + 1}", base, top, 0.008, 0.005, mat("grass_dry"), 4)
        for tuft_angle, tuft_rad in radial(3, 0.024, seed=seed + index * 23, jitter=0.5):
            batch.blob("flower_white", around(top, tuft_angle, tuft_rad), (0.024, 0.024, 0.019), rng)
    batch.emit("BogCotton")


def build_flowers_creeping(seed: int) -> None:
    """A flat mat of tiny blooms — ankle detail for paths and clearings."""
    rng = random.Random(seed)
    batch = Batch()
    blade_cluster(batch, rng, 10, 0.40, (0.06, 0.14), (0.026, 0.048),
                  ["grass_dark", "grass"], (0.12, 0.34), (0.12, 0.32), seed + 139)
    head = ["flower_white", "flower_yellow"][seed % 2]
    for index, (angle, rad) in enumerate(radial(rng.randint(7, 10), 0.40, seed=seed + 149, jitter=0.65)):
        point = around((0.0, 0.0, rng.uniform(0.04, 0.10)), angle, rad)
        for petal_angle, petal_rad in radial(2, 0.020, seed=seed + index * 29, jitter=0.5):
            batch.blob(head, around(point, petal_angle, petal_rad), (0.016, 0.016, 0.009), rng)
    batch.emit("Creeping")


# ---------------------------------------------------------------------------
# Builders — grasses
# ---------------------------------------------------------------------------


def build_grass_tussock(seed: int) -> None:
    """One dense tall clump rather than a spread patch, so it reads as an object
    and not as ground texture."""
    rng = random.Random(seed)
    batch = Batch()
    blade_cluster(batch, rng, 14, 0.16, (0.58, 0.98), (0.055, 0.100),
                  ["grass_dark", "grass", "grass_light"], (0.14, 0.34), (0.14, 0.30), seed + 151)
    batch.emit("Tussock")


def build_grass_dry(seed: int) -> None:
    """Straw. Dead cover next to living cover is most of what makes a field read
    as varied at all."""
    rng = random.Random(seed)
    batch = Batch()
    blade_cluster(batch, rng, 11, 0.40, (0.32, 0.62), (0.045, 0.085),
                  ["grass_dry", "grass_seed"], (0.22, 0.54), (0.24, 0.50), seed + 157)
    for index, (angle, rad) in enumerate(radial(3, 0.34, seed=seed + 163, jitter=0.6)):
        height = rng.uniform(0.50, 0.72)
        base = around((0.0, 0.0, 0.02), angle, rad)
        top = (base[0] + math.cos(angle) * 0.11, base[1] + math.sin(angle) * 0.11, height)
        tapered_between(f"Stalk_{index + 1}", base, top, 0.009, 0.005, mat("grass_dry"), 4)
        cone(f"Head_{index + 1}", 0.030, 0.006, rng.uniform(0.11, 0.17),
             (top[0], top[1], top[2] + 0.06), mat("grass_seed"), 5)
    batch.emit("DryGrass")


def build_grass_short(seed: int) -> None:
    """Ankle turf. Cheap enough to carpet with, and it stops bare ground showing
    between the bigger pieces."""
    rng = random.Random(seed)
    batch = Batch()
    blade_cluster(batch, rng, 13, 0.46, (0.10, 0.22), (0.038, 0.070),
                  ["grass_dark", "grass", "grass_light"], (0.14, 0.42), (0.16, 0.40), seed + 167)
    batch.emit("ShortGrass")


def build_sedge(seed: int) -> None:
    """Stiff upright blades in a tight fan: wet-ground grass does not bend the
    way meadow grass does, and that difference is the whole asset."""
    rng = random.Random(seed)
    batch = Batch()
    blade_cluster(batch, rng, 13, 0.14, (0.62, 1.00), (0.038, 0.065),
                  ["sedge", "reed"], (0.05, 0.18), (0.03, 0.14), seed + 173)
    batch.emit("Sedge")


def build_marsh_grass(seed: int) -> None:
    """Tall, sparse, arching blades for basin edges and standing water."""
    rng = random.Random(seed)
    batch = Batch()
    blade_cluster(batch, rng, 9, 0.34, (0.72, 1.15), (0.042, 0.075),
                  ["sedge", "reed"], (0.18, 0.42), (0.22, 0.46), seed + 179)
    for index, (angle, rad) in enumerate(radial(2, 0.26, seed=seed + 181, jitter=0.6)):
        height = rng.uniform(0.95, 1.20)
        base = around((0.0, 0.0, 0.02), angle, rad)
        top = (base[0] + math.cos(angle) * 0.09, base[1] + math.sin(angle) * 0.09, height)
        tapered_between(f"Culm_{index + 1}", base, top, 0.013, 0.008, mat("reed"), 5)
        cone(f"Plume_{index + 1}", 0.032, 0.004, rng.uniform(0.15, 0.22),
             (top[0], top[1], top[2] + 0.09), mat("grass_seed"), 5)
    batch.emit("MarshGrass")


# ---------------------------------------------------------------------------
# Builders — ground cover
# ---------------------------------------------------------------------------


def build_lily_pad(seed: int) -> None:
    """Floating pads for the Mire basin — the one place in the Hollow that is
    water and currently has nothing growing on it."""
    rng = random.Random(seed)
    for index, (angle, rad) in enumerate(radial(rng.randint(4, 6), 0.44, seed=seed + 191, jitter=0.6,
                                                radius_jitter=0.5)):
        centre = around((0.0, 0.0, 0.012 + rng.uniform(0.0, 0.010)), angle, rad)
        notched_disc(f"Pad_{index + 1}", centre, rng.uniform(0.13, 0.24),
                     "leaf" if index % 2 else "leaf_deep", seed + index * 17,
                     segments=8, notch=rng.uniform(0.7, 1.1))
    if seed % 2 == 0:
        bloom = hull("Bloom", (rng.uniform(-0.2, 0.2), rng.uniform(-0.2, 0.2), 0.055), 0.055,
                     mat("flower_white"), seed + 193, subdivisions=0, lumps=4, lump=0.5)
        paint_faces(bloom, mat("flower_pink"), min_normal_z=0.2, min_height=0.4, coverage=0.6, seed=seed)


def build_moss_patch(seed: int) -> None:
    """Lumpy ground moss: one displaced mass with its lit crowns painted on,
    rather than a dozen separate blobs pretending to be one."""
    rng = random.Random(seed)
    main = hull("Moss_Bed", (0.0, 0.0, 0.030), (0.48, 0.44, 0.042), mat("moss_dark"), seed + 197,
                subdivisions=1, lumps=7, lump=0.40, sharpness=1.8, flat_base=0.45)
    paint_faces(main, mat("moss"), min_normal_z=0.35, min_height=0.52, coverage=0.55, seed=seed + 6)
    for index, (angle, rad) in enumerate(radial(rng.randint(3, 5), 0.40, seed=seed + 199, jitter=0.65,
                                                radius_jitter=0.4)):
        size = rng.uniform(0.11, 0.19)
        cushion = hull(f"Cushion_{index + 1}", around((0.0, 0.0, 0.026), angle, rad),
                       (size, size * rng.uniform(0.75, 1.3), size * 0.26), mat("moss"),
                       seed + index * 23, subdivisions=0, lumps=4, lump=0.40, flat_base=0.45)
        paint_faces(cushion, mat("moss_light"), min_normal_z=0.40, min_height=0.50,
                    coverage=0.6, seed=seed + index)


def build_clover_patch(seed: int) -> None:
    """Three-lobed leaves on short stalks: a ground texture that is recognisably
    not grass at the distance a player actually looks at their feet."""
    rng = random.Random(seed)
    batch = Batch()
    for index, (angle, rad) in enumerate(radial(rng.randint(12, 15), 0.42, seed=seed + 211, jitter=0.7,
                                                radius_jitter=0.5)):
        height = rng.uniform(0.07, 0.17)
        base = around((0.0, 0.0, 0.01), angle, rad)
        top = Vector((base[0], base[1], height))
        tapered_between(f"Stalk_{index + 1}", base, tuple(top), 0.007, 0.006, mat("grass_dark"), 4)
        token = ["leaf", "leaf_light"][index % 2]
        for lobe in range(3):
            leaf(batch, token, top, angle + lobe * math.tau / 3.0 + rng.uniform(-0.2, 0.2),
                 rng.uniform(0.062, 0.092), rng.uniform(0.052, 0.078), 0.006, 0.002, 0.010, segments=1)
        # A bloom belongs on the stalk it grew from. Scattering them at free
        # points is how three of these shipped with flowers hovering in mid-air.
        if index % 3 == 1:
            batch.blob("flower_white", (top.x, top.y, top.z + 0.014), (0.024, 0.024, 0.022), rng)
    batch.emit("Clover")


def build_leaf_litter(seed: int) -> None:
    """Fallen leaves lying flat. Under the trees, the ground is not green — and
    nothing else in either kit says so."""
    rng = random.Random(seed)
    batch = Batch()
    tokens = ["leaf_litter", "leaf_dry"]
    for index, (angle, rad) in enumerate(radial(rng.randint(11, 14), 0.50, seed=seed + 227, jitter=0.7,
                                                radius_jitter=0.5)):
        origin = Vector(around((0.0, 0.0, 0.012 + rng.uniform(0.0, 0.018)), angle, rad))
        leaf(batch, tokens[index % 2], origin, rng.uniform(0.0, math.tau),
             rng.uniform(0.13, 0.22), rng.uniform(0.09, 0.16),
             rng.uniform(0.004, 0.020), rng.uniform(0.0, 0.010), rng.uniform(0.008, 0.020), segments=3)
    for index, (angle, rad) in enumerate(radial(2, 0.44, seed=seed + 229, jitter=0.65)):
        start = Vector(around((0.0, 0.0, 0.018), angle, rad))
        end = start + Vector((math.cos(angle + 1.4) * rng.uniform(0.12, 0.26),
                              math.sin(angle + 1.4) * rng.uniform(0.12, 0.26),
                              rng.uniform(-0.004, 0.014)))
        tapered_between(f"Twig_{index + 1}", tuple(start), tuple(end), 0.011, 0.007, mat("wood_dead"), 4)
    batch.emit("Litter")


# ---------------------------------------------------------------------------
# Catalog assembly
# ---------------------------------------------------------------------------

SPECS: list[tuple[str, str, Callable[[int], None]]] = []


def register(stem: str, letters: str, family: str, builder: Callable[[int], None]) -> None:
    for letter in letters:
        SPECS.append((f"{stem}_{letter}", family, builder))


register("bush_round", "abcd", "shrubs", build_bush_round)
register("bush_broadleaf", "abc", "shrubs", build_bush_broadleaf)
register("bush_thorn", "abc", "shrubs", build_bush_thorn)
register("bush_dead", "abc", "shrubs", build_bush_dead)

register("sapling", "abcd", "small_trees", build_sapling)
register("tree_willow", "abc", "small_trees", build_tree_willow)
register("tree_snag", "abc", "small_trees", build_tree_snag)

register("plant_broadleaf", "abc", "leafy_plants", build_plant_broadleaf)
register("plant_dock", "abc", "leafy_plants", build_plant_dock)
register("plant_creeper", "abc", "leafy_plants", build_plant_creeper)
register("bracken", "abcd", "leafy_plants", build_bracken)
register("nettle", "abc", "leafy_plants", build_nettle)

register("flowers_meadow", "abcd", "flowers", build_flowers_meadow)
register("flowers_tall", "abc", "flowers", build_flowers_tall)
register("flowers_bog", "abc", "flowers", build_flowers_bog)
register("flowers_creeping", "abc", "flowers", build_flowers_creeping)

register("grass_tussock", "abcd", "grasses", build_grass_tussock)
register("grass_dry", "abcd", "grasses", build_grass_dry)
register("grass_short", "abcd", "grasses", build_grass_short)
register("sedge", "abc", "grasses", build_sedge)
register("marsh_grass", "abc", "grasses", build_marsh_grass)

register("lily_pad", "abc", "ground_cover", build_lily_pad)
register("moss_patch", "abcd", "ground_cover", build_moss_patch)
register("clover_patch", "abc", "ground_cover", build_clover_patch)
register("leaf_litter", "abcd", "ground_cover", build_leaf_litter)


def _join_into_one(name: str, made: list) -> bpy.types.Object:
    """Collapse an asset to a single mesh carrying one material slot per colour.

    Every `tapered_between` call is its own Blender object, so a clover patch
    exported as **sixteen** mesh parts — thirteen stalks and three batched leaf
    meshes. Scattered through `MultiMeshInstance3D`, each part becomes its own
    node and its own draw call: the first scatter of this kit built 757 of them
    across 78 assets. Joining first takes that to one node per asset and as many
    draw calls as the asset has colours, which is three or four.

    Joining after the build rather than batching everything by hand keeps the
    builders readable — they get to say `tapered_between(...)` and mean it.
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
    # Bake the transform away. The join keeps whichever rotation the first
    # component happened to carry — every `tapered_between` cone has one — and
    # that rotation then rides out on the glTF node. Godot's `get_aabb()` is
    # local, so anything measuring the imported asset has to rotate an
    # axis-aligned box and gets a conservative, too-large answer: the same
    # over-measurement that was leaving assets floating in Blender, reappearing
    # on the far side of the export. An identity node transform removes the
    # question entirely, and makes the scatter's instance maths trivial.
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    bpy.ops.object.select_all(action="DESELECT")
    target.name = name.title().replace("_", "")
    for polygon in target.data.polygons:
        polygon.use_smooth = False
    return target


def floating_islands(objects: list, tolerance: float = 0.02) -> list[str]:
    """Names of mesh islands that neither touch the ground nor touch anything else.

    `tools/mapgen/hollow_layout.py` validates that no *prop* floats above the
    terrain, but nothing has ever checked inside an asset — a blade whose base
    got lifted, or a leaf hung off a branch that later moved, exports happily and
    is only ever caught by somebody squinting at a preview. Islands are found
    through the edge graph and judged by axis-aligned bounds: an island is
    supported if it reaches the ground plane or its bounds overlap another
    island's. Bounds overlap is deliberately permissive — this is here to catch
    geometry adrift in open air, not to adjudicate near-misses.
    """
    islands: list[tuple[str, Vector, Vector]] = []
    for obj in objects:
        if obj.type != "MESH":
            continue
        mesh = obj.data
        parent = list(range(len(mesh.vertices)))

        def find(i: int) -> int:
            while parent[i] != i:
                parent[i] = parent[parent[i]]
                i = parent[i]
            return i

        for edge in mesh.edges:
            a, b = find(edge.vertices[0]), find(edge.vertices[1])
            if a != b:
                parent[a] = b
        groups: dict[int, list[int]] = {}
        for index in range(len(mesh.vertices)):
            groups.setdefault(find(index), []).append(index)
        for key, members in groups.items():
            points = [obj.matrix_world @ mesh.vertices[i].co for i in members]
            lo = Vector((min(p[i] for p in points) for i in range(3)))
            hi = Vector((max(p[i] for p in points) for i in range(3)))
            islands.append((f"{obj.name}#{key}", lo, hi))

    adrift: list[str] = []
    for index, (label, lo, hi) in enumerate(islands):
        if lo.z <= 0.05:
            continue
        supported = False
        for other, other_lo, other_hi in islands:
            if other == label:
                continue
            if all(lo[a] - tolerance <= other_hi[a] and hi[a] + tolerance >= other_lo[a] for a in range(3)):
                supported = True
                break
        if not supported:
            adrift.append(f"{label} at z={lo.z:.3f}")
    return adrift


def create_asset(name: str, family: str, build_fn: Callable[[], None], display_location) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)
    before = {obj.name for obj in bpy.data.objects}
    build_fn()
    made = sorted((obj for obj in bpy.data.objects if obj.name not in before), key=lambda obj: obj.name)

    # Ground, then size, then ground again. Sizing is deterministic per asset and
    # drawn from the family band, so scale is a guarantee rather than something a
    # later audit discovers — the pickup kit shipped a 0.71 m berry precisely
    # because every asset was only ever compared against its own preview frame.
    ground_and_centre(made)
    low, high, axis = SIZE_BAND[family_of(name)][:3]
    target = low + (high - low) * random.Random(seed_for(name) + 977).random()
    lo, hi = world_bounds(made)
    current = (hi.z - lo.z) if axis == "height" else max(hi.x - lo.x, hi.y - lo.y)
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
    ground_and_centre(made)
    # Join LAST. Joining before this point measures the asset through the stale
    # bounding box of whichever part happened to be alphabetically first, so the
    # scale-to-band step divides by the size of a single twig and the whole plant
    # comes out several times too big. The join is an export optimisation and it
    # belongs after everything that measures.
    made = [_join_into_one(name, made)]

    for obj in made:
        for old in list(obj.users_collection):
            old.objects.unlink(obj)
        collection.objects.link(obj)
        obj.parent = root
    bpy.context.view_layer.update()

    adrift = floating_islands(made)
    # Measure from vertices, not `obj.bound_box`. Blender does not refresh a
    # cached bounding box after `bpy.ops.object.join()`, even through a depsgraph
    # update, so a joined asset measures as whatever its first component was —
    # which put a willow at 6.97 m tall and 800 mm underground before anything
    # noticed. Vertices are never stale.
    corners = [
        obj.matrix_world @ vertex.co
        for obj in made if obj.type == "MESH" for vertex in obj.data.vertices
    ]
    minimum = Vector((min(v.x for v in corners), min(v.y for v in corners), min(v.z for v in corners)))
    maximum = Vector((max(v.x for v in corners), max(v.y for v in corners), max(v.z for v in corners)))
    dimensions = maximum - minimum
    polygons = sum(len(obj.data.polygons) for obj in made if obj.type == "MESH")
    triangles = sum(
        sum(max(0, len(polygon.vertices) - 2) for polygon in obj.data.polygons)
        for obj in made if obj.type == "MESH"
    )
    materials = sorted({m.name for obj in made if obj.type == "MESH" for m in obj.data.materials if m})

    bpy.ops.object.select_all(action="DESELECT")
    for obj in collection.objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = root
    bpy.ops.export_scene.gltf(
        filepath=str(EXPORT_DIR / f"{name}.glb"), export_format="GLB",
        use_selection=True, export_apply=True, export_yup=True,
    )
    root.location = display_location
    return {
        "name": name, "family": family, "root": root,
        "width": dimensions.x, "depth": dimensions.y, "height": dimensions.z,
        "ground_offset": minimum.z, "target": target, "axis": axis, "adrift": adrift,
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons, "triangles": triangles, "materials": materials,
    }


def check(records: list[dict]) -> list[str]:
    """Everything a machine can judge about this batch, judged."""
    problems: list[str] = []
    for record in records:
        name, family = record["name"], record["family"]
        low, high, axis, max_spread = SIZE_BAND[family_of(name)]
        measured = record["height"] if axis == "height" else max(record["width"], record["depth"])
        if not low - 0.02 <= measured <= high + 0.02:
            problems.append(f"{name}: {axis} {measured:.3f} m outside band {low}-{high} m")
        if record["adrift"]:
            problems.append(f"{name}: {len(record['adrift'])} floating island(s): {record['adrift'][:3]}")
        spread = max(record["width"], record["depth"])
        if max_spread is not None and spread > max_spread:
            problems.append(f"{name}: {spread:.2f} m across, {family_of(name)} footprint cap is {max_spread} m")
        if abs(record["ground_offset"]) > 0.005:
            problems.append(f"{name}: sits {record['ground_offset'] * 1000:.1f} mm off the ground plane")
        if record["parts"] == 0 or record["polygons"] == 0:
            problems.append(f"{name}: exported no geometry")
        if record["triangles"] > TRIANGLE_BUDGET[family]:
            problems.append(
                f"{name}: {record['triangles']} triangles over the {family} budget "
                f"of {TRIANGLE_BUDGET[family]}"
            )
        if len(record["materials"]) > MAX_MATERIALS[family]:
            problems.append(
                f"{name}: {len(record['materials'])} materials, {family} cap is {MAX_MATERIALS[family]}"
            )
        if not record["materials"]:
            problems.append(f"{name}: no embedded materials")
        if not (EXPORT_DIR / f"{name}.glb").exists():
            problems.append(f"{name}: no GLB written")
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

    if len({name for name, _, _ in SPECS}) != len(SPECS):
        raise RuntimeError("flora asset names must be unique")
    for name, _, _ in SPECS:
        if family_of(name) not in SIZE_BAND:
            raise RuntimeError(f"{name} has no SIZE_BAND entry")

    counters = {family: 0 for family in FAMILY_ORDER}
    totals = {family: sum(1 for _, f, _ in SPECS if f == family) for family in FAMILY_ORDER}
    records: list[dict] = []
    for name, family, builder in SPECS:
        index = counters[family]
        counters[family] += 1
        spacing = FAMILY_SPACING[family]
        rows = math.ceil(totals[family] / COLUMNS)
        column, row = index % COLUMNS, index // COLUMNS
        family_y = FAMILY_ORDER.index(family) * 26.0
        location = ((column - (COLUMNS - 1) * 0.5) * spacing,
                    family_y + (row - (rows - 1) * 0.5) * spacing * 1.15, 0.0)
        records.append(create_asset(name, family, lambda n=name, fn=builder: fn(seed_for(n)), location))
        print(f"  built {name}", flush=True)

    problems = check(records)
    catalog = [
        {
            "name": r["name"], "family": r["family"],
            "width_m": round(r["width"], 3), "depth_m": round(r["depth"], 3), "height_m": round(r["height"], 3),
            "mesh_parts": r["parts"], "polygons": r["polygons"], "triangles": r["triangles"],
            "materials": r["materials"],
        }
        for r in records
    ]
    with (ASSET_DIR / "catalog.json").open("w", encoding="utf-8") as handle:
        json.dump(catalog, handle, indent=2)
        handle.write("\n")

    # -- previews -----------------------------------------------------------
    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.mesh.primitive_plane_add(size=220, location=(0, 70, -0.03))
    plane = bpy.context.object
    plane.name = "Preview_Ground"
    plane.data.materials.append(mat("preview_ground"))
    for old in list(plane.users_collection):
        old.objects.unlink(plane)
    preview_collection.objects.link(plane)

    bpy.ops.object.light_add(type="SUN", location=(0, 0, 60))
    sun = bpy.context.object
    sun.name = "Preview_Sun"
    sun.rotation_euler = (math.radians(38), math.radians(-20), math.radians(-30))
    sun.data.energy = 2.6
    sun.data.angle = math.radians(16)

    bpy.ops.object.camera_add(location=(16, -20, 14))
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    camera.data.type = "ORTHO"
    scene = bpy.context.scene
    scene.camera = camera
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1800
    scene.render.resolution_y = 1000
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.016, 0.021, 0.028)
    scene.view_settings.look = "AgX - Medium High Contrast"

    def set_visible(record: dict, visible: bool) -> None:
        record["root"].hide_render = not visible
        for child in record["root"].children_recursive:
            child.hide_render = not visible

    # A 1.80 m reference stands in every family sheet. A plant kit whose sizes are
    # only ever compared against each other is exactly how the pickup kit ended up
    # with a 0.71 m berry.
    #
    # One cube cannot serve six family sheets plus the hero shot: `object.location`
    # set after this process's FIRST render never takes effect (F-204) — only
    # camera moves and `hide_render` toggles do. The original code moved a single
    # "figure" object between all seven renders, so only "shrubs" (the first
    # family rendered) ever actually showed a reference cube; every later sheet
    # silently shipped without one. Each render gets its own cube below, placed
    # once here and only ever hidden or shown.
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

    def hero_duplicate(record: dict, location) -> bpy.types.Object:
        """A standalone, positioned copy of one asset's exported mesh, for the one
        shot that pulls specific assets together from across six family grids
        spaced 26 m apart. Repositioning `record["root"]` itself hits the same
        F-204 problem the figure had — the original code did exactly that, so the
        hero shot drew every asset at its family-grid position, not its curated
        spot. A linked duplicate placed HERE, before any render, then only ever
        hidden or shown, does not have that problem."""
        source = record["root"].children[0]
        delta = Vector(location) - record["root"].location
        dup = source.copy()
        dup.name = f"{record['name']}_hero"
        dup.parent = None
        dup.matrix_world = Matrix.Translation(delta) @ source.matrix_world
        dup.hide_render = True
        for old in list(dup.users_collection):
            old.objects.unlink(dup)
        preview_collection.objects.link(dup)
        return dup

    def rows_in(family: str) -> int:
        return math.ceil(sum(1 for r in records if r["family"] == family) / COLUMNS)

    # Every family sheet's own reference cube, and every hero duplicate, built
    # now — before the first `bpy.ops.render.render()` call — so each placement
    # actually takes effect.
    family_rigs = []
    for family in FAMILY_ORDER:
        family_y = FAMILY_ORDER.index(family) * 26.0
        spacing = FAMILY_SPACING[family]
        half = (COLUMNS * spacing) * 0.5
        figure = make_reference(family, (-half - 1.1, family_y, 0.9))
        family_rigs.append((family, family_y, spacing, half, figure))

    hero = ["sapling_c", "sapling_a", "bush_round_b",
            "bush_broadleaf_a", "bush_thorn_a", "bush_dead_b", "bracken_b", "plant_dock_a",
            "flowers_tall_b", "flowers_meadow_c", "grass_tussock_a", "moss_patch_b",
            "clover_patch_a", "leaf_litter_a", "lily_pad_a", "sedge_b"]
    hero_spots = {name: ((index % 8) * 2.5 - 9.0, -3.6 + (index // 8) * 3.4, 0.0)
                  for index, name in enumerate(hero)}
    # F-396: the willow and the snag are 12.5 m and 9 m now, not 5 m and 3.4 m, so
    # they cannot stand in the undergrowth row any more — at 2.5 m spacing they
    # simply filled the frame. They go behind the ground plants instead, which is
    # a better shot anyway: the whole point of this sheet is the size relationship
    # between a tree, a bush and a clover patch, and that only reads when the tree
    # is far enough back to fit in it.
    hero_spots["tree_willow_a"] = (-7.0, 9.0, 0.0)
    hero_spots["tree_snag_b"] = (5.5, 8.0, 0.0)
    by_name = {record["name"]: record for record in records}
    hero_duplicates = {name: hero_duplicate(by_name[name], spot)
                        for name, spot in hero_spots.items()}
    hero_figure = make_reference("hero", (-12.4, -1.2, 0.9))

    for family, family_y, spacing, half, figure in family_rigs:
        for record in records:
            set_visible(record, record["family"] == family)
        width = (half + 1.4) * 2.0
        tallest = max([r["height"] for r in records if r["family"] == family] + [1.85])
        content = tallest * 0.90 + (rows_in(family) - 1) * spacing * 1.15 * 0.47 + 0.9
        camera.data.ortho_scale = width
        scene.render.resolution_y = int(min(1400, max(560, 1800 * content * 1.22 / width)))
        camera.location = (0.0, family_y - 18.0, 9.5)
        look_at(camera, (0.0, family_y, content * 0.34))
        figure.hide_render = False
        scene.render.filepath = str(PREVIEW_DIR / FAMILY_PREVIEWS[family])
        bpy.ops.render.render(write_still=True)
        figure.hide_render = True

    for record in records:
        set_visible(record, False)
    for dup in hero_duplicates.values():
        dup.hide_render = False
    hero_figure.hide_render = False
    scene.render.resolution_y = 1000
    camera.data.type = "PERSP"
    camera.data.lens = 42.0
    camera.location = (10.5, -20.0, 6.2)
    look_at(camera, (-1.0, 0.8, 3.4))
    scene.render.filepath = str(PREVIEW_DIR / "flora_set_preview.png")
    bpy.ops.render.render(write_still=True)
    for record in records:
        set_visible(record, True)
    for dup in hero_duplicates.values():
        dup.hide_render = True
    hero_figure.hide_render = True

    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_PATH))

    print(f"\nFLORA_BUILD assets={len(records)} triangles={sum(r['triangles'] for r in records)}")
    for family in FAMILY_ORDER:
        rows = [r for r in records if r["family"] == family]
        print(
            "  %-14s %2d assets  %5d tris  max %3d tris  max %d materials  %s %.2f-%.2f m"
            % (family, len(rows), sum(r["triangles"] for r in rows), max(r["triangles"] for r in rows),
               max(len(r["materials"]) for r in rows), rows[0]["axis"],
               min(r["height"] if r["axis"] == "height" else max(r["width"], r["depth"]) for r in rows),
               max(r["height"] if r["axis"] == "height" else max(r["width"], r["depth"]) for r in rows))
        )
    if problems:
        print(f"\nFLORA_CHECK FAIL ({len(problems)})")
        for problem in problems:
            print(f"  {problem}")
        raise SystemExit(1)
    print("FLORA_CHECK PASS")


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
