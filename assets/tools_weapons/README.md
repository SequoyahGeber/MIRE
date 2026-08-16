# MIRE first tool and weapon set

Batch A-004 contains ten shared designs, each exported as a world pickup and first-person viewmodel
for 20 portable GLBs. Runtime files are in `exports/`; the editable source is
`../source/tool_weapon_set.blend`. The source directory is excluded from Godot import by
`../source/.gdignore`.

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
