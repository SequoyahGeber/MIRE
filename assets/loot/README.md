# MIRE loot set

Batch A-005 contains the containers and dropped-loot meshes the first reward loop needs: three chest
tiers in closed and open states, plus the carried and dropped pickups that sit outside a chest.
Runtime GLBs are in `exports/`; the editable source is `../source/loot_set.blend`. The source
directory is excluded from Godot import by `../source/.gdignore`.

## Included assets

| Family | Count | Contents |
|---|---:|---|
| Chest — small | 2 | Wooden chest, closed and open |
| Chest — Wellspring | 2 | Mire-corrupted chest, closed and open |
| Chest — reinforced | 2 | Iron-bound chest, closed and open |
| Carried | 2 | Coin pouch, item pickup bag |
| Powerup | 1 | Powerup orb on its rune base |
| Dropped | 1 | Dead player's backpack |

`catalog.json` is the exact inventory and records dimensions, mesh-part counts, polygon counts, and
embedded materials. `preview/loot_preview.png` shows all 10 assets;
`preview/loot_scale_preview.png` shows representative loot beside a one-metre ruler with 20 cm ticks
and a 20 cm cube.

Every asset is horizontally centred with its origin at ground level. These are presentation meshes:
they contain no collision, loot tables, rarity, container capacity, open/locked state, or network
authority. Spawning, loot rolls, open requests, validation, and inventory grants remain
host-authoritative.

## The closed/open pairs

Each chest tier is one builder called twice, so the two states cannot drift apart — the shell, bands
and feet are the same calls, and only the lid transform and the revealed contents differ.

**The two states share a base footprint exactly.** Both are centred horizontally on the shell and
feet rather than on all their geometry, so swapping the mesh when a chest opens does not shift the
chest. Verified at 0.00 mm drift across all three pairs. The open variant's *bounding box* is larger
because the raised lid extends up and back, which is deliberate:

| Tier | Closed (w×d×h m) | Open (w×d×h m) |
|---|---|---|
| Small | 0.749 × 0.486 × 0.566 | 0.749 × 0.752 × 0.848 |
| Wellspring | 0.832 × 0.587 × 0.658 | 0.832 × 0.899 × 0.941 |
| Reinforced | 0.957 × 0.645 × 0.708 | 0.957 × 0.964 × 1.068 |

**Author collision from the closed mesh.** It is the tighter volume and the one that matches the
chest in both states; a body sized to the open bounding box would block a player from walking past an
opened chest.

The chest bodies are hollow — floor plus four walls, not a solid block — so the open state reveals an
interior with loot filling it to the rim. That is what the open variant is for, and it is why these
cost slightly more polygons than a solid box would.

## Rebuild

```bash
Blender --background --python tools/blender/build_loot_set.py
```

Deterministic: two consecutive clean rebuilds produce byte-identical GLBs. Requires Blender 5.2.
