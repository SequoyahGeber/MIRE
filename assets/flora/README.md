# MIRE flora kit

The undergrowth the environment kit never had. Runtime-ready GLBs are in `exports/`; the editable
Blender source is `../source/flora_set.blend`, rebuilt by
`tools/blender/build_flora_set.py`. `catalog.json` is the exact index — every filename, family,
dimension, mesh part, polygon and triangle count, and embedded material.

## Why it exists

`assets/environment` ships 128 assets and exactly **one** shape of ground cover: bladed grass, in four
sizes. No bush, no shrub, no flower, no broadleaf plant, no sapling, no leaf litter, no moss. Every
square metre of an authored map was therefore bare ground, bladed grass, or a full-grown tree, and the
eye reads that as a single repeated texture no matter how many grass variants get scattered over it.
This kit fills the middle of that range — knee-to-shoulder plants, ankle-height detail, and the young
and dying trees that break up a treeline.

## Contents — 84 GLBs, 30,984 triangles

| Family | Count | Triangles | Groups |
|---|---:|---:|---|
| Shrubs | 13 | 4,580 | `bush_round`, `bush_broadleaf`, `bush_thorn`, `bush_dead` |
| Small trees | 10 | 6,096 | `sapling`, `tree_willow`, `tree_snag` |
| Leafy plants | 16 | 6,136 | `bracken`, `nettle`, `plant_broadleaf`, `plant_creeper`, `plant_dock` |
| Flowers | 13 | 5,580 | `flowers_meadow`, `flowers_tall`, `flowers_bog`, `flowers_creeping` |
| Grasses | 18 | 4,888 | `grass_tussock`, `grass_dry`, `grass_short`, `sedge`, `marsh_grass` |
| Ground cover | 14 | 3,704 | `moss_patch`, `clover_patch`, `leaf_litter`, `lily_pad` |

Family sheets are in `preview/`, each with a 1.80 m reference figure standing in frame.

## Contracts this kit keeps, and how

Every one of these is **enforced by the build**, which fails rather than warns.

- **Size is guaranteed, not hoped for.** Each asset is scaled to a target drawn from its group's band
  before export, so the kit cannot drift against a 1.80 m player the way the pickup kit did. Mats are
  banded on spread instead of height, because a leaf-litter patch has no meaningful height.
- **Footprint is banded separately.** Scaling a sprawling rosette until its *height* lands in band
  multiplies its reach by the same factor: `bracken_c` came out a correct 0.95 m tall and 4.34 m
  across. Height and footprint have to be stated as two contracts or one of them runs away.
- **Nothing floats.** Mesh islands are found through the edge graph; an island must reach the ground
  plane or overlap another island. This caught clover blooms hanging in mid-air.
- **Colour count is capped per family** — four where there is wood to shade, three for ground cover.
- **Ground contact and origin** are checked in Blender *and* independently in Godot.

## Verification

```
/Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender/build_flora_set.py
/Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender/audit_all_sides.py -- --only flora/exports
.agent/bin/agent godot --import
.agent/bin/agent godot --script tools/flora_check.gd
```

**The `--import` step is not optional.** A headless `--script` run never re-imports changed assets, so
a check run straight after a rebuild silently validates the *previous* build, and re-running does not
help (F-059). `tools/flora_check.gd` compares the engine's own measurements against `catalog.json`
rather than merely asserting that files load, which is what makes staleness detectable at all.

All-sides audit: 84 assets from eight azimuths plus top and bottom, **0 numeric defects** — nothing
inside out, no loose vertices, no degenerate faces, no n-gons, no unapplied transforms, every origin
at the base and horizontally centred.

## How these are built, and what they are not

Sequoyah supplied a CC0 low-poly nature pack (Quaternius, `CC0 1.0 Universal`) as a reference, with
the instruction to learn from it and not to copy it. **No geometry from that pack is used, imported,
traced, or shipped here.** What was taken is method, and three measurements from it changed how this
kit is built:

- **One mass, not a heap of ellipsoids.** Its bush is a single 364-triangle mesh with one material;
  MIRE's nearest equivalent was three meshes, five materials and 641 triangles for a shape that read
  as less. That became `mire_art.hull()`.
- **Twelve blades, not thirty-six.** Thin blades stop resolving as blades a few metres out and turn a
  patch into fuzz, while costing exactly as much as wide ones.
- **Detail that costs no geometry.** Its mossy rock is the same 36-face rock with some faces assigned
  a second material. That became `mire_art.paint_faces()`.

Where the reference and MIRE disagree, MIRE wins. Its palette is far darker and more olive than ours,
and ours was deliberately re-anchored bright after being authored too dark once already.

The three primitives this produced — `hull()`, `paint_faces()` and `fork()` — live in
`tools/blender/mire_art.py` and are **not vegetation-specific**. A hull is a boulder, a bush, a crown,
a mushroom cap or a cloud; `paint_faces` is moss, snow, lichen, rust or scorching at zero geometric
cost; `fork` is a dead tree, a root system, a crack or an antler. Vegetation is only the first caller.

## Placement and authority

These are presentation assets with **no network authority and no authored collision**. They are
scattered client-locally and deterministically by `world/gen/undergrowth.gd`, which seeds itself from
the layout file so every peer draws the identical field without a byte crossing the wire. Each asset
is joined to a single mesh with one material slot per colour, so a family placed three hundred times
costs one `MultiMeshInstance3D` and three or four draw calls rather than three hundred nodes.

If undergrowth ever needs to hide a player, be trampled, or be harvested, that is a
host-authoritative system and it does not belong in the scatter.
