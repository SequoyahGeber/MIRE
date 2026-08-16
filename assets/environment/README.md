# MIRE environment kit

Original low-poly map assets for MIRE. Runtime-ready files are in `exports/`; the editable Blender
source is `../source/mire_map_kit.blend`. The source directory carries `.gdignore` so Godot imports
the portable GLBs without requiring Blender to be configured in Editor Settings.

## Included assets

| Asset | Approximate size | Intended use |
|---|---:|---|
| `tree_pine_a.glb` | 3.5 m wide, 5.3 m tall | Healthy forest canopy |
| `tree_bare_a.glb` | 3.5 m wide, 5.3 m tall | Dead or Mire-adjacent forest |
| `boulder_a.glb` | 2.9 m wide, 1.7 m tall | Landmark and large cover |
| `rock_cluster_a.glb` | 2.0 m wide, 1.4 m tall | Scatter and path edging |
| `stump_a.glb` | 1.8 m wide, 1.1 m tall | Forest floor and harvested-tree stand-in |
| `fallen_log_a.glb` | 3.4 m long, 1.1 m tall | Cover and traversal dressing |
| `grass_clump_a.glb` | 0.9 m wide, 1.0 m tall | Lightweight ground scatter |
| `mushroom_cluster_a.glb` | 1.4 m wide, 0.9 m tall | Mire transition and corrupted ground |

Each export is centred at ground level, uses metres, has flat normals, and embeds its materials. The
meshes intentionally do not contain collision. Add simple primitive collision in Godot when a prop
needs it; grass and mushrooms should normally have none.

## Rebuild

```bash
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python tools/blender/build_mire_map_kit.py
```

The script rebuilds all eight GLBs, the editable `.blend`, and the preview image deterministically.
Blender 5.2.0 LTS was used for the initial build.
