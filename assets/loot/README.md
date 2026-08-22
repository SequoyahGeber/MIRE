# MIRE loot set

Batch A-005 contains the containers and dropped-loot meshes the reward loop needs: six chest
families in closed and open states, plus the carried and dropped pickups that sit outside a chest.

**Five of the six are the chest rarity ladder** (D-215) — crate, small, reinforced, warded, gilded,
in price order. A player has to be able to tell what a container is worth from across a clearing,
before any prompt or UI resolves, so each rung is separated on two axes at once: it is bigger than
the rung below it (0.62 m to 1.12 m wide, monotonically), and its palette shares nothing with its
neighbours (grey deadwood and rope, warm timber and iron, dark timber and heavy iron, ward teal on
slate, gold on charred wood). The sixth family, the Wellspring chest, is not on the ladder at all:
it is the Mire's own container, and purple stays reserved for corruption.

Runtime GLBs are in `exports/`; the editable source is `../source/loot_set.blend`. The source
directory is excluded from Godot import by `../source/.gdignore`.

## Included assets

| Family | Count | Contents |
|---|---:|---|
| Chest — crate (basic) | 2 | Weathered plank crate, rope-lashed, closed and open |
| Chest — small (common) | 2 | Wooden chest, closed and open |
| Chest — reinforced (rare) | 2 | Iron-bound chest, closed and open |
| Chest — warded (epic) | 2 | Bogsilver-bound slate with wellglass runes, closed and open |
| Chest — gilded (legendary) | 2 | Gold on charred wood with a gemmed crest, closed and open |
| Chest — Wellspring | 2 | Mire-corrupted chest, closed and open |
| Carried | 2 | Coin pouch, item pickup bag |
| Powerup | 1 | Powerup orb on its rune base |
| Dropped | 1 | Dead player's backpack |

`catalog.json` is the exact inventory and records dimensions, mesh-part counts, polygon counts, and
embedded materials. `preview/loot_preview.png` shows all 16 assets;
`preview/loot_scale_preview.png` is the ladder's readability test — the five rungs in price order
beside a one-metre ruler with 20 cm ticks and a 20 cm cube. If two of them stop being tellable apart
in that render, they have stopped being tellable apart in the game.

Every asset is horizontally centred with its origin at ground level. These are presentation meshes:
they contain no collision, loot tables, rarity, container capacity, open/locked state, or network
authority. Spawning, loot rolls, open requests, validation, and inventory grants remain
host-authoritative.

## The closed/open pairs

Each chest family is one builder called twice, so the two states cannot drift apart — the shell, bands
and feet are the same calls, and only the lid transform and the revealed contents differ.

**The two states share a base footprint exactly.** Both are centred horizontally on the shell and
feet rather than on all their geometry, so swapping the mesh when a chest opens does not shift the
chest. Verified at 0.00 mm drift across all six pairs. The open variant's *bounding box* is larger
because the raised lid extends up and back, which is deliberate:

| Family | Closed (w×d×h m) | Open (w×d×h m) |
|---|---|---|
| Crate (basic) | 0.624 × 0.415 × 0.464 | 0.624 × 0.611 × 0.740 |
| Small (common) | 0.749 × 0.486 × 0.566 | 0.749 × 0.752 × 0.848 |
| Reinforced (rare) | 0.957 × 0.645 × 0.708 | 0.957 × 0.964 × 1.068 |
| Warded (epic) | 1.040 × 0.728 × 0.748 | 1.040 × 1.064 × 1.139 |
| Gilded (legendary) | 1.123 × 0.795 × 1.013 | 1.123 × 1.286 × 1.226 |
| Wellspring | 0.832 × 0.587 × 0.658 | 0.832 × 0.899 × 0.941 |

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
