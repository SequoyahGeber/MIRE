# MIRE terrain accents kit

Batch **A-016a** — the rock half of A-016: cliffs, slopes and the ways up them. GLBs in `exports/`,
source `../source/terrain_accents.blend`, rebuilt by `tools/blender/build_terrain_accents.py`.

## The gate is met, not waived

A-016 waited on "world-gen terrain shape is settled". **D-142 settled it on 2026-08-19** — fBm +
falloff base, domain warp, a masked ridged layer, steepest-descent river tracing with arithmetic
carving. Everything here sits ON that heightfield and needs nothing it cannot produce.

That same decision cost the batch one asset. D-142 rejects 3D density and caves outright ("2D Mire
grid, low-end target, cut list"), and a 2D heightfield cannot express an overhung void, so A-016's
**cave entrance is filed as F-237 rather than built**. A prop that reads as an entrance backed by
solid ground is a bug report from every playtester who finds one. `cliff_overhang` survives that
limit only because it is honest about being a rock ledge *placed on* a slope, never a claim that the
terrain itself overhangs.

## Contents — 6 GLBs, 3,184 triangles

| Asset | Size | Triangles |
|---|---|---:|
| `cliff_face` | 5.00 m | 484 |
| `cliff_corner` | 5.00 m | 920 |
| `cliff_overhang` | 2.60 m | 420 |
| `rocky_slope` | 3.90 m | 340 |
| `scree_pile` | 2.60 m | 740 |
| `stone_steps` | 4.40 m | 280 |

## Modularity is the point

A cliff is not one hero rock, it is a run of wall a placer repeats along a contour. `cliff_face` and
`cliff_corner` share one **4.00 m module width and 5.00 m height**, their backs are flat and vertical
at y = 0 so they can be pushed into a slope with no gap, and the build **asserts** both — a corner
that disagrees with its wall staircases the whole run.

Bed width is clamped to never exceed the module. Jitter that could exceed 1.0 turned a "4.00 m
module" into 4.48 m, and two of those placed side by side push beds through each other, which is the
one thing a modular piece must not do. Variation goes into depth, thickness and tilt instead.

## Four things this batch got wrong first

**Boxes make masonry.** The first cut stacked near-identical boxes of equal thickness and rendered
as a course of concrete blocks. `assets/environment` already ships `stone_wall_solid`; a cliff that
reads as masonry is worse than no cliff, because it tells the player somebody built it. Bed
thickness now varies nearly 3:1, a third of the beds take the darker stone, and angular outcrops
(`hull` at `subdivisions=0` — 20 faces of hard-edged rock) break up the face.

**Anything whose read is its profile must present that profile.** Three assets were built extending
along +Y while the preview camera looks down Y, so a 4.4 m cliff rendered as a 2.7 m tower and the
ramp and the steps were seen end-on as a mound and a pile.

**A "depth, width" tuple unpacked the other way round rotates the module 90°.** Every cliff bed was
built 4 m deep and 1.15 m wide — a buttress sticking out of the hillside rather than a wall.

**A negative base to a fractional power is complex, not small.** The scree fan's cone falloff used
`(1 - reach/spread) ** 1.6`, and `radial`'s jitter can push a stone past `spread`; Python raised
rather than flattening the fan.

## An unused material slot is a lie in the catalog

`paint_faces` appends a material and then assigns it to whichever faces qualify. On the overhang the
thresholds were strict enough that **zero faces took it** — Blender counted the empty slot, the glTF
exporter (which only writes materials a primitive uses) did not, and the catalog claimed three
materials for a GLB carrying two. `tools/terrain_accents_check.gd` caught it engine-side. The
generator now counts only materials referenced by at least one polygon, so the catalog reports what
ships.

## Verification

Blender **5.2.0 LTS** (D-038). Build contract fails-not-warns on 8 conditions including the module
contract, 6/6 pass · all-sides audit against a clean `--outdir` (F-110), **0 numeric defects** ·
`tools/terrain_accents_check.gd`, **24 assertions, 0 failures**, measuring from vertices rather than
`Transform3D * AABB` (F-108).

## Known rough

`cliff_corner` is still the weakest of the six — the L reads well from the front but is thick
through the corner itself. It has had one pass, not two.

## A-016b

Still to build: mud bank, riverbank, streambed, sinkhole, burrow entrance. `sinkhole` needs
re-scoping to a shallow surface depression for the same F-237 reason — a 2D heightfield has nothing
for a hole to go into.
