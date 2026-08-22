# COOKING — the work order

**Status:** executable plan, 2026-08-22, wick410d34 (director). **This invents almost nothing.**
`docs/ITEMS.md` §4.4/§4.5 already specify the food and tonic tables and `A-012` already built all
thirteen models. What did not exist was a reconciliation of that spec against what actually ships,
which is why this has stalled twice: every previous attempt hit a missing ingredient and stopped.

## Why this is worth doing now

Three open findings close here, and a fourth system depends on it:

- **F-575** — `cooking_spit` and `woodcutting_block` have **zero recipes**. A player pays real
  resources for a station that opens an empty list.
- **F-439** — all thirteen models in `assets/food/exports/` are reachable from nothing. The art is
  done and has been since A-012.
- **F-439 again** — `cattail_bundle` and `fish_shoal` in `assets/wetland/exports/` are on the same
  never-placed list, and cooking is the thing that wants them. **Two dead assets become live.**
- **`docs/FAUNA.md` Phase 4** is cooking. Animals are the meat supply; without recipes they are a
  hunting minigame that produces an item with nowhere to go.

## The reconciliation — what blocks on what

**Tier 1 — ships today, every ingredient already exists.** Nothing here needs a new item, a new
harvestable, or a new system. This is the batch to do first and it is most of the value.

| Recipe | Station | Ingredients (all shipped) | Model |
|---|---|---|---|
| Cooked Meat | campfire | 1 raw_meat | `cooked_meat` |
| Meat Skewer | cooking_spit | 1 raw_meat + 1 branch | `meat_skewer` |
| Mushroom Skewer | cooking_spit | 2 mushroom + 1 branch | *(reuse `meat_skewer`, retinted — or defer)* |
| Hearty Stew | cooking_spit | 2 raw_meat + 1 wild_onion + 2 mushroom | `hearty_stew` |
| Healing Stew | cooking_spit | 2 raw_meat + 2 herb | `healing_stew` |
| Honey Jar | campfire | 2 honey + 1 clay | `honey_jar` |

**Tier 2 — needs one new harvestable each, and the art is already built and unplaced.**

| Recipe | Blocked on | The asset that already exists |
|---|---|---|
| Bog Loaf | a `cattail` item + a reed-bed harvestable | `assets/wetland/exports/cattail_bundle.glb` |
| Raw Fish → Cooked Fish | a `raw_fish` item + a fishing/shoal harvestable | `assets/wetland/exports/fish_shoal.glb` |

**Tier 3 — genuinely blocked, do not attempt.** `suspicious_sludge` and `pale_draught` need Blight
Residue, which does not exist. Every buff food waits on the timed-surge runtime (`POWERUPS.md` §3).
`fired_flask`-based tonics need the flask as a craftable item first. Say this in the report rather
than shipping a stub.

## Settled calls

**`herb` IS marshwort.** ITEMS.md's recipes name "marshwort"; `content/items/herb.tres` is
"Medicinal Herb — bitter leaves and a white flower head, chewed for what it mends". That is the same
item with two names, and authoring a second one would give the player two indistinguishable green
things. Recipes use `herb`. Recorded as a decision so nobody re-adds marshwort later.

**Every food is hunger and/or hp, and nothing else** — ITEMS.md §4.4's own rule until the surge
runtime exists. `ItemDef` already ships `hunger_restore` and `hp_restore`;
`PlayerHealth.request_consume_item()` already works. **No new systems code is needed for Tier 1.**

**Stations are family+tier now** (D-217), so a recipe naming `campfire` is also makeable at the
`cooking_spit` if and only if the spit declares `upgrades_from = &"campfire"`. It does not today.
Decide that deliberately: a spit that cannot do what a campfire does is the F-575 bug again.

## Order of work

1. **Tier 1 recipes + item defs + icons.** Six items. Icons are the long pole — every shipped item
   authors one and `item_icons_check` enforces it.
2. **Settle the campfire/spit family question**, which is one line in `content/stations/`.
3. **Tier 2**: the cattail and fish harvestables, which also closes two F-439 rows.
4. Re-run `chest_gate_check`-style verification: `recipe_station_check`, `station_tier_check`,
   `item_icons_check`, `art_coverage_check`, `asset_usage_check`. The last one should drop by **two
   kits' worth** of entries; that drop is the proof this worked.
