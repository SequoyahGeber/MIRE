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

## Playtest Hollow

`playtest_hollow.glb` is the visual half of the larger replacement playtest level. Unlike the older
map, its visual placement and Godot collision are generated from one frozen source of truth:
`world/gen/layouts/playtest_hollow.json`. The layout contains six readable zones, a four-gate camp,
clear expedition roads, an actual lowered Mire basin, two ridge terraces, five traversable ramps,
and deliberate placements from the pickup, loot, tool/weapon, and prototype-enemy kits.

Rebuild and validate it with:

```bash
python3 tools/mapgen/hollow_layout.py
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python tools/blender/build_playtest_hollow.py
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script tools/playtest_hollow_check.gd
```

Editable visual source: `assets/source/playtest_hollow.blend`. Runnable Godot scene:
`levels/playtest_hollow.tscn`. Collision, lights, and gameplay markers are built by
`world/gen/playtest_hollow.gd`; none of this map owns harvesting, inventory, loot, enemy, damage,
or multiplayer authority.

The scene's presentation layer uses a physical sky, a two-layer procedural cloud deck, and a
shadowed directional sun. Open routes remain clear: volumetric fog is authored only in three local
pockets — purple Mire haze, light forest-floor mist, and a thin ruins layer — where it can catch the
sun as light shafts. Runtime tuning lives in `world/environment/playtest_atmosphere.gd`; cloud
shaping lives in `world/environment/cloud_deck.gdshader`. The optional local clock is off by default;
call `set_time_of_day()` from the future host-authoritative day/night system rather than independently
advancing time on each peer.
