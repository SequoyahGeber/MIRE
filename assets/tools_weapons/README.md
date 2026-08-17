# MIRE first tool and weapon set

Batch A-004 contains ten shared designs, each exported as a world pickup and first-person viewmodel
for 20 portable GLBs. Runtime files are in `exports/`; the editable source is
`../source/tool_weapon_set.blend`. The source directory is excluded from Godot import by
`../source/.gdignore`.

**A-004R rebuilt every design.** The originals were flat extrusions: a straight cylinder haft with a
slab head and a bright strip laid on top. They read as mallets. The construction is now:

- **Ground profiles.** A head is a silhouette ring at the mid-plane with inset front and back rings,
  where the inset is a *distance in metres* per point — 0 keeps a square wall (a poll, a spine, a
  tang) and 0.05–0.09 grinds the section to an edge. A fractional inset was tried first and rounded
  off exactly the corners that give a head its silhouette, because the pull scaled with how far each
  point happened to sit from the centroid.
- **Butted body and edge, not an overlaid strip.** The bright cutting material is its own closed
  shape sharing a seam with the body. Laid over the body instead, it loses to the body's own
  silhouette at exactly the rim where it is supposed to be visible, and the head reads as one colour.
- **Swept oval hafts** with a radius per path point, a flared butt cap, wrapped grips, and cord
  lashings with a knot, instead of a constant-radius cylinder with four flat rings.
- **Flared bits and short polls.** A head of even height reads as a mallet from every angle; the
  flare is the whole silhouette.

Polygon counts roughly doubled, to 114–348 per design (12,608 triangles across all 20 exports), and
every export stays within about 6 cm of its A-004 dimensions so grip transforms authored against the
old files still frame correctly. Every design was inspected on a six-azimuth orbit render, not only
from the front — the mallet-shaped poll and the invisible edge strip were both invisible head-on.

## Included designs

| Family | Designs |
|---|---|
| Axes | Wooden axe, stone axe |
| Pickaxes | Wooden pickaxe, stone pickaxe, iron pickaxe |
| Weapons | Cleaver, skewer, short bow |
| Ammunition | Arrow |
| Utility | Repair hammer |

Every design has a `*_world.glb` and matching `*_viewmodel.glb`. Both presentations are rebuilt from
the same geometry function and embedded materials, preventing silhouette drift while allowing Godot
scenes to tune their transforms independently. `catalog.json` records the design, presentation,
dimensions, mesh parts, polygon count, and materials for each export.

The preview set contains:

- `tools_weapons_world_preview.png` — all world exports in a consistent catalog view.
- `tools_weapons_viewmodel_preview.png` — all paired exports tilted for first-person readability.
- `tools_weapons_scale_preview.png` — representative designs beside a 1.8 m figure and metre marker.

All exports are horizontally centred with ground-level origins, following the asset-library contract.
They contain no collision, sockets, animation, hitboxes, damage, durability, harvesting, ammunition,
or network authority. Tool use, combat, repair, inventory consumption, projectile spawning, and hit
validation remain host-authoritative. Sequoyah will create the world/viewmodel scenes and grip
transforms in the Godot editor.

## Rebuild

```bash
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python tools/blender/build_tool_weapon_set.py
```

Blender 5.2.0 LTS was used for the initial build. The generator cleanly rebuilds all 20 exports, the
catalog, three previews, and the editable source.
