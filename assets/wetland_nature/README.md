# MIRE wetland nature kit

Batch **A-015** — the trees and water cover a mire actually grows. Runtime-ready GLBs are in
`exports/`; the editable Blender source is `../source/wetland_nature.blend`, rebuilt by
`tools/blender/build_wetland_nature.py`.

## Scope: six of the row's twelve

`assets/flora` already ships `tree_willow_a`..`c`, `lily_pad_a`..`c`, `marsh_grass_a`..`c`,
`sedge_a`..`c` and `flowers_bog_a`..`c`; `assets/environment` ships `reeds_a`..`d`. Swamp willow,
lily pads, marsh grass, sedge, bog flowers and water reeds are therefore already in the game, and
remaking them would put two objects in the world competing to be the same plant.

## Contents — 6 GLBs, 3,936 triangles

| Asset | Size | Triangles | The silhouette nothing else makes |
|---|---|---:|---|
| `alder` | 5.60 m | 960 | Several trunks from one stool |
| `hollow_tree` | 4.90 m | 548 | A void through the trunk |
| `uprooted_tree` | 6.40 m | 628 | Horizontal trunk, vertical root plate |
| `mangrove_tree` | 4.60 m | 512 | Trunk standing clear of the ground on stilts |
| `duckweed` | 0.94 m | 592 | A mat on open water |
| `hanging_moss` | 1.65 m | 696 | A curtain off a branch |

## Every tree here earns its place on silhouette

`assets/environment` has pine, birch, bare and crooked; `assets/flora` has willow, snag and sapling.
A seventh trunk-with-a-canopy is scenery nobody notices, so each of these four trees is built around
one shape a forest tree cannot make. The alder forks from the ground because a waterlogged tree
cannot get a heavy crown up without falling over. The mangrove's gap under the crown is daylight and
water a player can wade into. The uprooted tree is the one asset where the **root plate** — a
vertical disc taller than a player — is the whole read, which is what separates it from
`fallen_log_a`..`d`.

## Three lessons this batch paid for or reused

**A crown is the one place "three masses, never eighteen" does not apply.** That A-000V rule is
about a bush — one object you stand next to. A tree crown is seen against sky from tens of metres,
and three masses on a branching tree read as parasols parked on sticks. Seventeen work, and they are
affordable only because the canopy masses are **base icosahedra**: `subdivisions=0` is 20 faces
against 80, so seventeen cost less than five of the subdivided kind. The alder fell from 1,580 to
960 triangles while looking better, which matters because MIRE ships with no prop LOD (F-144).

**A mouth is only a mouth if the rest of the wall is solid.** The hollow tree is a ring of staves
with four missing, and the first cut made the staves too thin to touch — the trunk read as a bundle
of poles with gaps all the way round, so the deliberately-missing ones said nothing. It also follows
A-006's rule that an opening must survive being drawn from standing eye height: the staves either
side of the mouth are cut down so the rim falls away instead of ending in a wall.

**Roots branch; they do not radiate.** The uprooted tree's plate first fired eleven straight tapered
rods out of a disc and rendered as a sea urchin. `fork()` already knows how to make something that
splits, curves and thickens toward its trunk, and roots are exactly that.

## Verification

Built with **Blender 5.2.0 LTS** (D-038).

- **Build-time contract** — `tools/blender/build_wetland_nature.py` fails rather than warns on size,
  footprint, ground contact, floating geometry, triangle budget, material cap and missing exports.
  6/6 pass.
- **All-sides audit** — eight azimuths plus top and bottom, clean `--outdir` (F-110): **0 numeric
  defects** across all 6.
- **Godot import** — `tools/wetland_nature_check.gd`, **25 assertions, 0 failures**, measuring each
  import from its vertices rather than `Transform3D * AABB` (F-108/F-094).

## Known rough edges

The mangrove's trunk is on the spindly side between its stilts and its crown, and the uprooted
tree's root plate is still smoother than a torn plate of soil should be. Both read correctly at
placement distance; neither has had a second art pass.

## Gameplay wiring is not here

Presentation meshes only. Placement, collision and harvesting stay host-authoritative systems
(`ARCHITECTURE.md` §2.2).
