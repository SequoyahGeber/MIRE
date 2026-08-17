# MIRE Wellspring set

Batch A-008 contains the landmark, modular pieces, condition states, ritual props, boundary stones,
and guardian arena for the first Wellspring objective. Runtime GLBs are in `exports/`; the editable
source is `../source/wellspring_set.blend`. The source directory is excluded from Godot import by
`../source/.gdignore`.

## Included assets

| Family | Count | Contents |
|---|---:|---|
| Landmark | 1 | Seven-metre distant monolith with a simple fog-readable silhouette |
| Modular | 4 | Base, crystal cluster, open basin, and Mire root system |
| Condition states | 4 | Uncapped, capped, re-corrupting, and fully corrupted Wellsprings |
| Ritual | 1 | Activation/defense-wave pedestal |
| Boundary | 1 | Eight-stone boundary ring assembly |
| Arena | 1 | Guardian platform with runes, four pylons, and a readable approach gap |

`catalog.json` is the exact inventory and records dimensions, mesh-part counts, polygons, and
embedded materials. `preview/wellspring_preview.png` shows all 12 assets;
`preview/wellspring_scale_preview.png` shows the landmark and representative condition/ritual assets
beside an eight-metre ruler with 50 cm ticks and a 50 cm cube.

The Wellspring is a fixed objective visible on the horizon. Its ancient grey stone and bronze binders
connect it visually to player Wards, while the condition state carries the run's territory story:

- **Uncapped:** open purple basin, aggressive roots, fractured Mire crystal.
- **Capped:** clear teal basin and crystal held by four bronze braces and two collars.
- **Re-corrupting:** dim leaning crystal, broken cap hardware, returning roots, and purple growth
  visibly overtaking one side.
- **Corrupted:** tallest and widest purple crystal treatment, nine climbing roots, secondary spires,
  and exposed glowing veins.

## State-swap contract

All four condition states contain the exact same 4.6 m foundation geometry and are horizontally
centred from that shared geometry—not from roots, braces, crystals, or debris. The deterministic
build verifies both centre and size at **0.00 mm drift** across all four states. Author static
collision from the shared base footprint; do not expand it to contain roots or a condition's crystal.

The basin is built as an actual depressed floor plus a ring of twelve rim stones. Its liquid surface
sits below the rim, so state colour and contents remain visible from standing first-person height.

These are presentation meshes. They contain no collision, ritual timer, player-count requirement,
wave spawning, corruption clearing/spread, rewards, state authority, guardian logic, or networking.
The host owns objective and condition state; clients may animate liquid, glow, particles, and local
light without gameplay authority.

## Rebuild

```bash
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python tools/blender/build_wellspring_set.py
```

Requires Blender 5.2. Two consecutive clean builds must produce byte-identical GLBs and catalog data.
