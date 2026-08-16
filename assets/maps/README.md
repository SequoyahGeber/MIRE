# Authored maps

`playtest_map.glb` is the fixed visual layout for the compact MIRE playtest map. Its editable source
is `assets/source/playtest_map.blend`; rebuild both the GLB and preview with:

```bash
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python tools/blender/build_playtest_map.py
```

The map contains the terrain surface, paths, camp buildings and crafting stations, harvestable forest
and ore nodes, ruins, Mire grove, ridge lookout, boundary dressing, and named zone hierarchy. Godot
loads this as one authored visual asset. Gameplay state and collision remain separate so harvesting,
construction, and damage can stay host-authoritative.
