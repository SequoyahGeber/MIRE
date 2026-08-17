# MIRE adapted nature additions

This small set contains two models supplied by Sequoyah and adapted to the MIRE production contract:
a mossy hero boulder and a broadleaf tree. The checked-in reference GLBs under
`assets/source/reference_imports/` preserve the supplied geometry; the deterministic generator strips
their presentation scenes and produces the runtime assets here.

## What changed

- `mire_mossy_boulder` keeps the faceted boulder, fracture slabs, moss, and lichen. Its near-black
  underside/fractures were remapped to readable blue-grey stone, the full model was reduced to a
  practical hero-boulder scale, its lowest facets were flattened into a natural ground-contact plane,
  and all transforms and naming were normalized.
- `mire_broadleaf_tree` keeps the authored trunk, collars, roots, branches, canopy clusters, and leaf
  accents. The 6.3 m display island and its loose rocks, grass, and mushrooms were removed so this is
  a portable tree rather than a miniature diorama. The pale canopy was remapped to MIRE's saturated
  forest greens and the model was normalized to ground level.

Runtime GLBs are in `exports/`. The editable combined source is
`assets/source/adapted_nature_set.blend`. `catalog.json` records exact dimensions, part counts,
polygons, and embedded materials. The two preview renders show the final silhouettes and scale.

These are presentation meshes only. They contain no collision, harvest state, drops, placement,
wind, damage, or multiplayer authority. Static collision and gameplay wiring remain separate.

## Rebuild

```bash
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python tools/blender/build_adapted_nature_set.py
```

Requires Blender 5.2. The two source reference GLBs are intentionally below `assets/source/`, whose
`.gdignore` prevents Godot from importing them as runtime duplicates.
