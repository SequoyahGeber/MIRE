# MIRE world pickup kit

Batch A-002 contains the first readable world-pickup meshes for gathering, inventory, crafting, and
loot prototypes. Runtime GLBs are in `exports/`; the editable source is
`../source/pickup_kit.blend`. The source directory is excluded from Godot import by
`../source/.gdignore`.

## Included assets

| Family | Count | Contents |
|---|---:|---|
| Wood | 2 | Log, branch |
| Minerals | 4 | Stone, flint, iron ore, coal |
| Crafted resource | 1 | Iron ingot |
| Organic resource | 1 | Fibre bundle |
| Food | 3 | Berry cluster, mushroom, raw meat |
| Currency | 2 | Coin, coin stack |
| Salvage | 1 | Salvage fragment |

`catalog.json` is the exact inventory and records dimensions, mesh-part counts, polygon counts, and
embedded materials. `preview/pickups_preview.png` shows all 14 assets;
`preview/pickups_scale_preview.png` shows representative pickups beside a one-metre ruler with 20 cm
ticks and a 20 cm cube.

Every asset is horizontally centred with its origin at ground level. These are presentation meshes:
they contain no collision, item definitions, value, collection behavior, or network authority.
Spawning, ownership, pickup requests, validation, and inventory grants remain host-authoritative.

## Rebuild

```bash
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python tools/blender/build_pickup_kit.py
```

Blender 5.2.0 LTS was used for the initial build. The generator cleanly rebuilds all 14 exports, the
catalog, both previews, and the editable source.
