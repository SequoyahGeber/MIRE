# MIRE conifer litter kit

Batch **F-492** — what a pine drops on the ground under itself. Runtime-ready GLBs are in
`exports/`; the editable Blender source is `../source/conifer_litter.blend`, rebuilt by
`tools/blender/build_conifer_litter.py`. `catalog.json` is the exact index — every filename,
dimension, mesh part, polygon and triangle count, and embedded material.

## Why it exists

`tree_pine_*` is one of the commonest props in the world — `content/scatter/highland_pines.tres`
places six species of it and `forest_canopy.tres` three more — and standing under one yielded
nothing. A pinecone is what is actually on the floor there, and it is the throwable the early game
was missing: you pick it up bare-handed and you throw it, so the item is its own ammunition
(`content/ranged_weapons/pinecone.tres`, where `item_id == ammo_item_id`).

## Contents — 3 GLBs, 1,692 triangles

| Asset | Length | Triangles | What it is |
|---|---|---:|---|
| `pinecone_open` | 0.075 m | 684 | Mature, shed, scales flared. The item's own model and its icon |
| `pinecone_closed` | 0.062 m | 612 | Unopened — scales appressed, a solid brown spindle |
| `pinecone_small` | 0.044 m | 396 | A runt, built with fewer scales rather than shrunk |

## Built from the real cone

Scots pine, *Pinus sylvestris*, which is the pine the tree assets are drawn from. Its seed cones are
ovoid-conic and 3–8 cm long, which is where the size contract comes from — these are not scaled to
look good next to each other, they are scaled to the real object next to a 1.80 m player.

Three facts from the real morphology drive the geometry, and none of them are stylistic:

* **The spiral is real.** Scales are placed at the golden angle (137.5°) up a central axis, the way
  a cone's 80–90 megasporophylls are, so no two neighbours line up and the parastichies emerge on
  their own. Laid in rings instead, a cone reads as a pineapple.
* **The scale is a tile, not a spike.** Each ovuliferous scale is narrow where it meets the axis and
  broad at the exposed end — the *apophysis* — and it overlaps its neighbours like a slate. The
  first pass here built them as radial spikes and the render came back reading as a fish skeleton.
* **Open and closed are different objects.** A shed cone flares its scales out and back toward the
  stalk and roughly doubles its width; an unopened one keeps them pressed along the axis. The
  builder asserts the difference survives (`open_stoutness` against `closed_stoutness`), so the kit
  can never quietly become one spindle at three sizes.

## One mesh per asset, and that is not an optimisation

Each cone is 30-odd `box()` calls, and `world/gen/resource_scatter_field.gd` does **not** merge what
it scatters: it instantiates the GLB and builds one `MultiMeshInstance3D` per mesh part it finds. At
105 loose parts per cone, a chunk holding a hundred of them asked for ten thousand nodes. The
builder therefore joins to a single mesh with one material slot per colour before export — the same
lesson `build_flora_set.py` records, fixed in the same place.

## Everything is built lying down

Along +X with the axis horizontal, because that is how a cone sits once it has fallen, and the
silhouette from standing height is the only one the player ever gets.
