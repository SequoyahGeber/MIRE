# MIRE crafting-station kit

Batch A-003 contains the first station meshes for the vertical-slice crafting and repair loop.
Runtime GLBs are in `exports/`; the editable source is `../source/crafting_stations.blend`. The
source directory is excluded from Godot import by `../source/.gdignore`.

## Included assets

| Family | Count | Contents |
|---|---:|---|
| Workbenches | 2 | Primitive workbench, upgraded workbench |
| Fire cooking | 2 | Campfire, cooking spit |
| Forge | 2 | Stone furnace, anvil on block |
| Repair | 1 | Repair bench |
| Woodworking | 1 | Woodcutting block |

`catalog.json` is the exact inventory and records dimensions, mesh-part counts, polygon counts, and
embedded materials. `preview/crafting_stations_preview.png` shows all eight stations;
`preview/crafting_stations_scale_preview.png` shows representative stations beside a 1.8 m figure
and one-metre marker.

Every station is horizontally centred with its origin at ground level. These are static presentation
meshes with no authored collision, sockets, recipes, fuel, animation, interaction logic, or network
authority. Placement, station use, crafting validation, fuel consumption, repair, and granted items
remain host-authoritative. Fire geometry is cosmetic and may later be replaced or supplemented by
client-local VFX.

## Rebuild

```bash
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python tools/blender/build_crafting_stations.py
```

Blender 5.2.0 LTS was used for the initial build. The generator cleanly rebuilds all eight exports,
the catalog, both previews, and the editable source.
