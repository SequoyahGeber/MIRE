# MIRE environment kit

Original low-poly map assets for MIRE. Runtime-ready files are in `exports/`; the editable Blender
source is `../source/mire_map_kit.blend`. The source directory carries `.gdignore` so Godot imports
the portable GLBs without requiring Blender to be configured in Editor Settings.

## Included assets

The kit contains **128 individual GLBs** across seven families:

| Family | Count | Contents |
|---|---:|---|
| Trees | 18 | Six pines; four each of bare, birch, and crooked broadleaf trees |
| Rocks | 18 | Eight boulders, six clusters, and four rune-bearing standing stones |
| Forest debris | 12 | Four each of stumps, fallen logs, and exposed root clusters |
| Ground cover | 28 | Six dense grass clumps; four each of meadow patches, tall tufts, and seeded grass; six ferns; four reed/cattail clusters |
| Mire growth | 16 | Six mushroom clusters, six crystal growths, and four tendril clusters |
| Ruins | 12 | Broken walls, columns, arches, and rune markers |
| Building pieces | 24 | Modular wood, stone, roof, stair, railing, fence, corner, and gate pieces |

`catalog.json` is the exact index. It records every filename, family, dimensions, mesh-part count,
polygon count, and embedded materials. Category renders live in `preview/`.

### Construction grid

Building pieces use a **4 m horizontal bay** and **3 m wall/post height**. Origins sit at ground level
and the centre of each bay. The set includes solid, window, doorway, and half walls; foundations;
floors; slope and corner roofs; stairs; beams; posts; railings; straight and corner fences; a gate;
and matching stone pieces. Small trim overlaps are deliberate so adjoining pieces do not show gaps.

Each export is centred at ground level, uses metres, has flat normals, and embeds its materials. The
meshes intentionally do not contain collision. Add simple primitive collision in Godot when a prop
needs it; grass and mushrooms should normally have none.

These files are presentation assets and have no network authority of their own. The future building
system must keep placement, validation, damage, and destruction host-authoritative; clients only
render the selected pieces.

## Rebuild

```bash
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python tools/blender/build_mire_map_kit.py
```

The script rebuilds all 128 GLBs, the editable `.blend`, `catalog.json`, and eight preview images
deterministically. Blender 5.2.0 LTS was used for the initial build.
