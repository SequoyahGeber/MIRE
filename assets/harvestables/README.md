# MIRE harvestable resource states

Batch A-001 contains the first state-compatible harvestable meshes for the vertical slice. Runtime
GLBs are in `exports/`; the editable Blender source is `../source/harvestable_resources.blend`.
The source directory is excluded from Godot import by `../source/.gdignore`.

## Included assets

| Family | Count | States |
|---|---:|---|
| Pine tree | 6 | Intact, damage A, damage B, felled trunk, fresh stump, depleted stump |
| Stone node | 3 | Intact, cracked, depleted |
| Iron node | 3 | Intact, cracked, depleted |

`catalog.json` is the exact inventory and records dimensions, mesh-part counts, polygon counts, and
embedded materials. `preview/harvestables_preview.png` shows the full state set;
`preview/harvestables_scale_preview.png` checks the hero assets against a 1.8 m figure and metre
markers.

The tree family was visually rebuilt during task 2.1i: branch-supported faceted crowns replace the
old stacked cones, axe damage is a concave cut in the trunk rather than a surface decal, the second
damage state loses individual limbs and sheds wood chips, and the felled/fresh/depleted states now
retain a coherent tree silhouette with growth rings, splinters, roots, and a weathered hollow.

The standing tree damage states share the same root, trunk, and crown footprint. Stone and iron
intact/cracked states share the same rock layout; their depleted rubble stays inside that footprint.
The meshes contain no collision or gameplay behavior. World mutation, harvesting, yields, respawn,
and state selection remain host-authoritative; clients only render the replicated state.

## Rebuild

```bash
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python tools/blender/build_harvestable_resources.py
```

Blender 5.2.0 LTS was used for the build. The generator cleanly rebuilds all 12 exports, the catalog,
both previews, and the editable source; generated-object ordering is stable by name.
