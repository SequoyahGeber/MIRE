# MIRE basic Ward set

Batch A-007 contains the visual states and support props for the first Ward: a shared foundation;
healthy, damaged, critical, and destroyed conditions; repair scaffolding; a boundary post; and an
activation crystal. Runtime GLBs are in `exports/`; the editable source is
`../source/ward_set.blend`. The source directory is excluded from Godot import by
`../source/.gdignore`.

## Included assets

| Family | Count | Contents |
|---|---:|---|
| Ward states | 5 | Bare foundation plus healthy, damaged, critical, and destroyed conditions |
| Repair | 1 | Freestanding timber scaffolding with working deck and ladder |
| Boundary | 1 | Ward boundary post with teal activation crystal |
| Activation | 1 | Socketed activation crystal with three orbiting presentation motes |

`catalog.json` is the exact inventory and records dimensions, mesh-part counts, polygon counts, and
embedded materials. `preview/ward_preview.png` shows all eight assets;
`preview/ward_scale_preview.png` shows representative assets beside a two-metre ruler with 25 cm
ticks and a 25 cm cube.

The Ward's warm stone, timber, and bronze body belongs with player construction. Its cyan/teal energy
is deliberately opposite the Mire's desaturated purple-black palette. Damage is communicated through
silhouette rather than recolour alone: supports fall, the ring loses segments, the crystal splits,
the critical core collapses and turns warning-orange, and the destroyed state leaves only low rubble.

## State-swap contract

The four condition states contain the exact same 2.4 m foundation geometry and are centred from that
shared geometry, not from each state's full bounds. A broken support or shard may extend outside the
base without moving the structure when gameplay swaps its visual. The deterministic build verifies
both the foundation centre and size at **0.00 mm drift** across healthy, damaged, critical, and
destroyed states.

Author static collision from `ward_foundation.glb`; do not resize it for a damaged state's debris.
The repair scaffolding is a separate overlay asset so it can appear around any condition without
duplicating the Ward foundation.

These are presentation meshes. They contain no collision, placement rules, health, damage, repair,
activation, protection radius, Mire suppression, or multiplayer authority. The host owns Ward state
and gameplay; clients may animate glow or particles locally.

## Rebuild

```bash
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python tools/blender/build_ward_set.py
```

Requires Blender 5.2. The verification contract expects two consecutive clean builds to produce
byte-identical GLBs and catalog data.
