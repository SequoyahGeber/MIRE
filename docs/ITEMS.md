# ITEMS.md — the item, loot and chest catalog (the 3.2 / 3.5 / 3.8 authoring spec)

**What this is.** The design catalog for every item, crafting component, chest reward and loot table
in MIRE — the same relationship to tasks 3.2 (item/recipe authoring), 3.5 (coins/chests) and 3.8
(food/consumables) that `POWERUPS.md` has to 3.4. Like that doc's 60-powerup sketch, the tables here
are **proof of coverage and a menu, not a shipping list**: rename, rebalance, cut and replace freely;
what must survive is the *shape*. Values are starting guesses. Content stays hand-authored `.tres`
(D-006) — no agent bulk-generates the files this doc plans.

**The verdict up front: the shipped schemas hold.** Every item below is expressible today as an
`ItemDef` (+ `WeaponDef` where it swings, + `RecipeDef` where it's crafted), and every chest below is
a `LootTableDef` a `Chest` already knows how to roll. The handful of small extensions this catalog
wants are all owned by tasks already on the roadmap, and they are named in §6 so nothing lands as a
surprise field — the F-078 lesson: inventing a name must be a decision you notice.

**Sequoyah's directive (2026-08-18, D-063):** *you should sometimes get something crazy good from a
chest, even if it makes the game too easy for a while — it just is really fun.* The Gleam pool (§4.9)
is that directive made into content. Balance it by making pulls rarer, never by making them weaker.

---

## 1. Research — what we took, and from where

Studied for *method*, per the standing inspiration-not-copying rule (`ASSET_TRACKER.md` A-000V):
measure how it's built, then build our own. No list below is imported from any of these games.

| Game | What we measured | What MIRE takes (the pattern) | What we deliberately don't |
|---|---|---|---|
| **Muck** (the DNA) | ~21 chest powerups in 4 flat stat groups; green chests = coins, priced colour tiers = powerups; a resource economy of ~a dozen items | The coin → priced chest loop works and stays. Free scatter-chests seed the economy | The flatness. 21 items and 4 groups is the P2 problem `DESIGN.md` already fixes; we go an order of magnitude wider |
| **Risk of Rain 2** | Rarity as *design contract*: commons need many stacks, legendaries define a run alone; every legendary is exciting, none are filler; legendaries are ~1% from small chests but reliable from premium sources | The Gleam pool: few, unmissably strong, always worth the slot. Rarity (spawn/weight) is the only balance lever (D-063) | Item count as a goal in itself; 36 legendaries needs a bigger team |
| **Valheim** | Progression gated by *material discovery*; raw → station-refined → gear chains make tiers legible; stations gate recipes | Refine-at-a-station legibility (furnace already ships). Node access gates tiers (D3) | Chain depth. Valheim is a 100-hour game; MIRE is one evening — refinement is capped at 2 steps (§2 R2) |
| **Lethal Company** | The best-loved scrap is the *funny* scrap — near-useless items with personality carry co-op sessions | A deliberate comedy layer (§4.10) and jokes in descriptions everywhere (D7 tone) | Scrap-as-quota economics; MIRE's coins already do the currency job |

Sources: [Muck chest items](https://steamah.com/muck-complete-list-of-all-items-from-chests/) ·
[Muck powerups wiki](https://danimuck.fandom.com/wiki/Power-Ups) ·
[RoR2 items wiki](https://riskofrain2.wiki.gg/wiki/Items) ·
[RoR2 legendaries analysis](https://rogueranker.com/risk-of-rain-2-red-items/) ·
[Valheim progression guide](https://valheim.fandom.com/wiki/Progression_guide) ·
[Lethal Company scrap favourites](https://www.zleague.gg/theportal/exploring-the-quirky-scrap-favorites-in-lethal-company-what-delights-players-the-most/).

---

## 2. The rules that keep ~150 items coherent

- **R1 — every item has a job.** Fuel, food, material, verb, reward, or joke. If a row can't say its
  job in four words, it's filler and gets cut. (Anti-pattern: Muck's bark/dough/bowl chain — three
  items to express one.)
- **R2 — refinement depth is capped at 2.** Gather → refine (one station visit) → use. A run is one
  evening (`DESIGN.md` §1); nobody spends it walking ingots between five stations. Anything wanting a
  third step must collapse one.
- **R3 — no armor items, no equipment slots.** Defense, mobility and utility live in powerups
  (`damage_taken`, `move_speed`, …) and Resonances. This keeps the viewmodel-only pipeline (D-004)
  honest — armor you can't see on your own body is a spreadsheet, not an item. *Would change this:*
  playtesters repeatedly reaching for "I want to gear up defensively" and the powerup pool failing to
  scratch it.
- **R4 — no durability, no ammo anxiety.** Tools/weapons never break (the repair bench serves
  *structures*). Arrows/bolts are cheap mass-craft items; the sling eats plain stones. Scarcity
  pressure comes from the Mire eating the map, not from your axe dissolving.
- **R5 — tone (D7):** dumb names welcome, one-line joke descriptions welcome, zero lore. "Bog Loaf",
  not "Bread of the First Wardens".
- **R6 — jackpots stay (D-063).** The Gleam pool is content, not a balance bug. Tune frequency, never
  potency-until-boring.
- **R7 — corrupted ground yields nothing from nodes** (`DESIGN.md` §4.1 stands). Corruption pays out
  through its *enemies*: Blight Residue (§4.2) drops only from kills made on corrupted ground. The
  Mire stays a place you fight, never a place you farm.
- **R8 — conventions:** ids snake_case; stack sizes — resources 99, coins 999, food/tonics/throwables
  20, tools/weapons/keys 1. Icons come from the `render_item_icons.py` pipeline (append SOURCES,
  A-042 governs); never block authoring on art (POWERUPS.md rule, same here).
- **R9 — one item, many sources.** Bone drops from wildlife *and* skeletons; stones feed building
  *and* the sling. Reuse before invention — the catalog is wide enough already.

---

## 3. Where things come from — the source map

Every acquisition route in the game, so no item below has to invent one:

| Source | Gate | Examples |
|---|---|---|
| Ground scavenge (hands) | none — the D1 bootstrap | branch, stone, fibre, berry, reeds |
| Harvest nodes (tool-gated) | axe / pickaxe tier | log, stone, bog iron, coal, mithril |
| Gatherable plants (A-011 family) | none / knife-fast | mushroom, marshwort, clay, peat, resin, honeycomb |
| Creature drops | kill it | meat, pelts, chitin, spore sac, crystal shard |
| Fish shoals | a **Harvestable** in shallow water hit with spear/skewer — reuses the existing system whole; there is no fishing minigame and no rod (cut, see §9) | raw fish |
| Chests | coins / keys / finding them | powerups, consumables, weapons, Gleam pulls |
| Objectives | Wellspring caps, bosses, the Hunt elite | Wellglass, guardian core, gilded key |
| Corrupted kills | fighting inside the Mire (R7) | Blight Residue |
| Stations | recipe + ingredients | ingots, tar, rope, cloth, tonics, food |

> **Corrected 2026-08-21 by task 3.18 (D-200).** The tier language in this section shipped as three
> rungs with mithril and Wellglass sharing T3. It is now **five**, and `docs/PROGRESSION.md` §2 is the
> authority: **T1** wood · **T2** stone/flint · **T3** iron (*bog iron*) · **T4** **Bogsilver** (the
> rename — "mithril" was an admitted placeholder here and belongs to a different game) · **T5**
> Wellglass. Read every "T3" below that means *the top of the ladder* as T5, and every "mithril" as
> bogsilver; the item ids ship as `bogsilver_ore` / `bogsilver_*`. The one thing that did NOT change is
> this section's closing instinct — there is no sixth rung, and deeper Cycles escalate through
> modifiers and the Gleam pool rather than another ingot.

Tier language used below (D3, `DESIGN.md` §4.3): **T0** bare hands · **T1** wood/stone/flint ·
**T2** iron (*bog iron* — it's real, it forms in bogs, and it's free flavour) · **T3** mithril +
Wellglass. T3 is deliberately the last full tool tier; deeper Cycles escalate through modifiers and
the Gleam pool, not a fourth ingot.

---

## 4. The catalog

### 4.1 Gathered raw materials (22)

| Item | Tier | Source | Job |
|---|---|---|---|
| Branch | T0 | ground / any tree hit | first club, arrows, skewers, torches |
| Stone | T0 | ground / stone node | tools, building, **sling ammo as-is** |
| Flint | T0 | ground, riverbank | T1 blades, fire |
| Fibre Bundle | T0 | fibre plant | rope, cloth, bowstring |
| Cattail Bundle | T0 | reed beds (river/mere) | food (§4.4 Bog Loaf) *and* fibre — one item, two jobs |
| Sphagnum Moss | T0 | fen ground cover | poultices; the real-world antiseptic, free flavour |
| Clay Lump | T0 | riverbank deposit | fired flasks, building daub |
| Peat Brick | T0 | fen deposit | **fuel** (burns longer than logs), tar |
| Resin Lump | T0 | pine tap / resin node | torches, tar, waterproofing |
| Pinecone | T0 | pine floor, bare-handed | **thrown as-is** — the T0 ranged option, no weapon needed (F-492) |
| Berry | T0 | berry bush | snack food |
| Poison Berry | T0 | poison berry bush | looks *almost* identical (D7). Tonic base, bad snack |
| Mushroom | T0 | forest floor | food, skewers |
| Glowcap | T0 | Mire-edge, night-visible | glow tonic, light recipes; marks the corruption border by itself |
| Wild Onion | T0 | meadow plant | stew depth |
| Marshwort | T0 | medicinal herb (A-011) | healing recipes |
| Honeycomb | T0 | bee hollow (angry bees are a later hazard) | food, bee jar |
| Log | T1 | tree (axe) | everything wooden |
| Bog Iron Ore | T2 | iron node (stone pick+) | the iron age. Existing `iron_ore`, display name upgraded |
| Coal | T2 | coal seam (pick) *or* charcoal recipe (§4.3) | smelting fuel |
| Mithril Ore | T3 | deep quarry veins & Blight-border outcrops — **drops as a Heavy Chunk (§4.8) needing a 2-player carry** (3.10's hauled object) | the fork-upgrade tier |
| Wellglass Shard | T3 | Wellspring chests & guardians only | re-fork cost (§4.3 of DESIGN — "pay a heavy cost to re-fork"), late recipes; ties the crafting peak to the objective loop |

### 4.2 Creature drops (22)

One to two drops per creature, reused hard (R9). Each row ships **with its creature** (A-023–A-028,
A-033/A-034) — authoring ahead of the enemy is correct data that waits.

| Item | From | Job |
|---|---|---|
| Raw Meat | boar/deer/rabbit wildlife | food chain (exists) |
| Raw Fish | fish shoal harvestable | food chain |
| Frog Legs | frogs | food + comedy ("tastes like everything else") |
| Feather | crow / heron / owl | arrow fletching |
| Small Pelt | rabbit / rat / deer | cured leather |
| Sinew | any medium wildlife | bowstrings, bindings |
| Bone | wildlife *and* bog skeletons (R9) | arrows, tonics, bone charms |
| Chitin Plate | Mire crawler | light shield facing, tonic grit |
| Spore Sac | sporeling, spore thrower | spore powder → bombs/tonics |
| Fang | Mire hound | barbed arrows, trophies |
| Heartwood | root walker | premium wood — bows, hafts that matter |
| Crystal Shard | crystal crab | lantern cores, frost flask |
| Burlap Scrap | corrupted scarecrow | cheap cloth alternative + decoy duck skin |
| Mud Core | mud elemental | tar bombs, building daub |
| Thorn Quill | thorn beast | bolts, barbed anything |
| Eye Jelly | floating Mire eye | glow tonic, unsettling stew |
| Husk Plate | shielded husk | heavy shield facing |
| Digger Claw | burrower | pick-speed tonic, trophies |
| Blight Residue | **any kill made on corrupted ground** (R7) | Pale Draught, corrupted-flavoured recipes — the only thing the Mire *pays* |
| Corrupted Heart | any elite (A-026) | one per elite; late recipes, big tonics |
| Guardian Core | Wellspring guardian boss | trophy + the biggest recipes |
| Titan Heart | deep-Cycle boss | trophy; bragging in item form |

### 4.3 Refined materials & components (9)

All station-made, all depth-2 compliant (R2). `iron_ingot` exists; the rest are its siblings.

| Item | Recipe (sketch) | Station | Job |
|---|---|---|---|
| Iron Ingot | 2 bog iron + 1 coal | furnace | T2 gear (exists) |
| Mithril Ingot | 1 heavy chunk + 2 coal | furnace | T3 gear |
| Coal (charcoal route) | 3 logs | furnace | fuel when no seam is near (same item, R9) |
| Tar | 2 peat + 1 resin | furnace | ship repair, tar bomb, waterproofing, torches |
| Rope | 3 fibre *or* 2 cattail | workbench | building, bows, hauling |
| Cloth | 4 fibre | workbench | ship sail, bandage-grade padding, decoy duck |
| Cured Leather | 2 pelt + 1 tar | workbench | grips, slings, bucklers |
| Fired Flask | 2 clay | furnace | **the tonic/throwable container** — one component unlocks two whole families |
| Mechanism | **not craftable — salvaged** from ruin chests & strongboxes | — | crossbow, Tinker turrets, "someone smarter than us made this" |

### 4.4 Food & cooking (18)

3.8 consumes these through the shipped `ItemDef` fields (`hunger_restore`, `hp_restore`). **Buff
foods wait** for the timed-surge runtime `POWERUPS.md` §3 already scoped out — until then every food
is hunger and/or hp, which is enough for the M3 loop. Campfire/spit are the stations (A-003).

| Item | Made from | Notes |
|---|---|---|
| Berry / Mushroom / Wild Onion / Honeycomb / Cattail | raw gathers | small hunger, eat-in-a-pinch |
| Raw Meat / Raw Fish / Frog Legs | drops | poor raw, meant for the fire |
| Cooked Meat | raw meat | the staple (A-012 asset) |
| Cooked Fish | raw fish | staple no. 2 |
| Grilled Frog Legs | frog legs | +comedy description |
| Mushroom Skewer | mushroom + branch | early filler food |
| Meat Skewer | meat + branch | id `meat_skewer` — **not** the weapon `skewer` (name collision noted so nobody ships a food you can stab with) |
| Bog Loaf | 2 cattail | bread from cattail flour is real; the name is ours (D7) |
| Hearty Stew | meat + onion + mushroom | big hunger, group-cook payoff |
| Fish Stew | fish + onion + marshwort | hp-leaning |
| Healing Stew | meat + 2 marshwort | the big heal-feed (A-012) |
| Suspicious Sludge | 1 of anything + Blight Residue | huge hunger, description does the joke (A-012 asset). Random effects wait for a runtime; plain numbers ship it |

### 4.5 Tonics & medicine (6)

All Fired Flask + ingredients at the campfire. Instant effects only until the surge runtime exists.

| Item | Recipe (sketch) | Effect | Gate |
|---|---|---|---|
| Moss Poultice | 2 moss + 1 marshwort | flat hp, cheap, no flask needed | ships with 3.8 |
| Healing Draught | flask + 2 marshwort + honeycomb | big hp | 3.8 |
| Stamina Tonic | flask + berry + cattail | stamina refill | 3.8's stamina |
| Pale Draught | flask + Blight Residue + moss | clears Blight stacks | 4.11 (Blight exists) |
| Antivenom | flask + poison berry + bone | clears poison | whenever poison ships |
| Glow Tonic | flask + glowcap + eye jelly | night vision tint | needs a small screen-effect; [code] |

### 4.6 Throwables (9) — one verb unlocks the family

All gated on a **throw verb** riding 5.3's host-validated projectile path (§6). Status-appliers
additionally wait for their status (Burning/Chilled arrive with the Fire/Cold Resonance tasks).

| Item | Recipe (sketch) | Effect |
|---|---|---|
| Tar Bomb | flask + 2 tar | ground slick — enemies slowed in it |
| Spore Bomb | flask + spore powder (2 spore sacs) | poison cloud [status] |
| Fire Flask | flask + resin + coal | ignites [Burning] |
| Frost Flask | flask + crystal shard | slows burst [Chilled] |
| Bee Jar | flask + honeycomb | angry bees seek the nearest enemy [signature-code, keep 1] |
| Smoke Pot | flask + peat + moss | drops aggro briefly |
| Glow Flare | glowcap + resin + branch | thrown light source — the swamp-at-night item |
| Decoy Duck | 2 logs + cloth | quacks. Taunts enemies to it. The team-bonding item (Lethal lesson, D7) |
| The Brick | 2 clay, fired | it's a brick. Big single-target knockback, no other virtue |

### 4.7 Tools & weapons (30 across the run)

The fork structure is `DESIGN.md` §4.3's; A-004/A-021/A-022 already plan most of the art. New rows
this catalog adds are **bolded**.

| Tier | Roster |
|---|---|
| T0 | **Branch Club** (branch + fibre — the first sixty seconds get a weapon), unarmed fallback stays |
| T1 | wooden/stone axe & pickaxe (exist), **Reed Machete** (flint + branch — fast shallow arc, doubles fibre/cattail gather speed: the Forager's weapon), spear (A-021), short bow + arrow (exist), sling (A-022 — **eats plain stones**, R4) |
| T2 forks | cleaver ↔ skewer (exist), iron axe/pickaxe (A-021), iron sword (exists), longbow ↔ crossbow + bolt (A-021, crossbow costs a Mechanism), buckler (A-021) |
| T3 forks | mithril axe/pickaxe (A-022), heavy cleaver ↔ barbed skewer (A-021), throwing axe/knife, wooden shield → ward shield, tinker hammer (A-022) — re-forking costs Wellglass |
| Ammo | arrow (exists), **Iron Arrow** (T2), bolt (A-021), **Tar Arrow** (slows [status]), stones (sling), **pinecone (thrown by hand — it is its own weapon and its own ammo, F-492)** |
| Lights | **Held Torch** (branch + resin — tiny swing, real light), **Storm Lantern** (iron + flask + resin — the good light; the swamp identity item) |
| Utility | repair hammer (exists, structures) |

### 4.8 Special & keys (6)

| Item | Source | Job |
|---|---|---|
| Old Coins | kills, caches (exists as `coins`) | the chest economy |
| Rusted Key | camp chests, hound dens, minibosses | opens Strongboxes without paying |
| Gilded Key | elites, the Hunt, bosses | opens the Gilded Chest (§5) |
| Heavy Mithril Chunk | mithril vein | the 2-player haul object (3.10) — mithril is *earned in pairs* |
| Salvage Trinket (small/large) | rare chest/boss filler | **proposal for 6.6, needs Sequoyah's call:** carried trinkets convert to bonus Salvage *only if you extract* — a physical reason to say "one more Cycle then we leave" (Q6 lever). If declined, cut cleanly; nothing else references them |

### 4.9 The Gleam pool — the jackpot tier (19) · D-063

The user-directive tier. Every entry is a run-warper you tell friends about. Two schema facts make
this pool nearly free: **a unique weapon is just a `WeaponDef` with loud numbers**, and **a jackpot
powerup is stats-only with NO tags** — the `PowerupDef` validator explicitly allows
tags-empty-with-modifiers, so Gleam powerups never pollute the six Resonance families
(`KNOWN_FAMILIES` doesn't grow). Both are authorable today.

**Unique weapons** (data-only; art in A-047; `max` one per run each via table weights):

| Item | The pitch |
|---|---|
| Gutterking | a cleaver the size of a door. Huge damage, huge arc, glacial recovery |
| The Longest Skewer | six metres of reach. Comedy that is also genuinely strong |
| Thumper | mithril maul; its job is the knockback number [waits for knockback] |
| Widow's Whisper | a bow drawing fast and hitting like the crossbow |
| The Bog Unit | an absurd hammer. No gimmick. The numbers ARE the joke |

**Gleam powerups** (untagged, `max_stacks 1`, stats straight from the POWERUPS.md catalog):

| Item | Mods (sketch) |
|---|---|
| Wellspring Heart | `max_hp` +120 flat |
| Seven-League Waders | `move_speed` +35% |
| Foreman's Whistle | `harvest_yield` +100%, `harvest_damage` +50% |
| Coin Worm | `coin_gain` +150% ("it eats copper. it makes more copper. don't ask") |
| Eggshell Warlord | `melee_damage` +75%, `damage_taken` +30% — the tradeoff jackpot |
| Bottomless Quiver | `arrow_save_chance` +0.9 |
| Second Sunrise | `revive_seconds` −60%, `revive_radius_m` +100%, `bleed_out_seconds` +100% — the team jackpot |
| The Landlord | `chest_price` −50%, `loot_luck` +30% — jackpots begetting jackpots |

**Signature Gleams** ([code], the POWERUPS.md escape hatch — `stacks_of(id)` keyed effects; keep to
two so each stays an event): **Pocket Wellspring** — a small personal corruption-suppressing aura
(arrives with the Mire, 4.9+); **Magnet Pouch** — nearby pickups drift to you.

**One-shot jackpots** (granted instantly on open): **King's Purse** (400–800 coins) · **Mithril
Cache** (6 ingots, skipping the haul — feel the heresy) · **Feast Basket** (a stack of stews) ·
**Powerup Piñata** (3 random common powerups at once).

### 4.10 The comedy layer (5) — Lethal's lesson, D7's mandate

Near-useless on purpose; their job is the moment they cause. Cheap rows, high memory-value:
**Decoy Duck** and **The Brick** (§4.6 — already pulling double duty), **World's Okayest Axe** (a
Gilded Chest troll-pull: stone axe stats, gold skin, weight 1 in the Gleam table), **Someone Else's
Lunch** (found food, big hunger, unanswered questions), **Questionable Egg** (food; the description
is a warning, the numbers are fine).

---

## 5. Chests & reward tables — the 3.5 content set

One `LootTableDef` per row below (`content/loot/`), rolled by the shipped `Chest` under the
authority already documented in `chest.gd`. Coin ranges/weights are tuning guesses; **shape** is the
contract. Muck's proven loop stays: free caches seed coins, priced chests spend them.

> **All seven rows are authored as of 2026-08-18** (`content/loot/`), verified by
> `.agent/bin/agent godot --script tools/loot_content_check.gd`, which resolves all 94 entry ids
> against the real Registry. Prices and locks are per-placed-chest (`cost_coins`, `locked_by` on the
> `Chest` node), not on the table — the same tier can be a free scatter-cache in one place and a
> 60-coin box in another, which is what "getting in" in the column below actually means.

| Tier (id) | Getting in | Rolls | Pool shape |
|---|---|---|---|
| Reed Cache (`small`, exists) | free, world-scattered | 2 | coins 5–15 + basic mats. Already shipped; display name "Reed Cache" |
| Bog Chest (`bog`) | priced — ~25 coins, price grows per Cycle | 2 | common powerups 55%, consumables 25%, mats 12%, coin dribble 8% |
| Strongbox (`strongbox`) | ~60 coins **or** a Rusted Key | 2–3 | rare powerups 40%, Mechanism 15%, made weapons (iron tier) 15%, mithril mats 15%, tonics 15% |
| Wellspring Chest (`wellspring`) | granted on a cap — never priced | 3 | guaranteed powerup + Wellglass shot + rare shot; the objective's paycheck |
| **Gilded Chest** (`gilded`) | rare spawn (≈1–2/island) **or** a Gilded Key; unmistakable at distance | 1 | **the Gleam pool only** (§4.9, Okayest Axe included at weight 1). The D-063 box |
| Sunken Cache (`sunken`) | strongbox table + a Gleam-chance entry, placed in *hazard* spots — Mire border, deep fen, drowned cellar | 2 | risk-priced rather than coin-priced |
| Boss Cache (`boss`) | guardian / titan kills | 3 | guaranteed Gleam-or-rare + boss mats + 100+ coins |

Non-chest reward routes, so they're never invented twice: the **Hunt elite** drops a Gilded Key
(the modifier that hunts you pays for the trouble); **elites** drop Corrupted Hearts + Rusted Keys;
**extraction** banks Salvage (plus §4.8's trinket proposal if taken); the ***Static* modifier**
(no chests this Cycle) doubles carried coins exactly as `DESIGN.md` §5.1 wrote it.

---

## 6. What this asks of the code — all owned by existing tasks

- **3.5 (chests):** four small things, named here so they're noticed decisions (F-078 rule):
  1. `LootEntry.kind: ITEM | POWERUP` (default ITEM) — §4.4 of DESIGN says powerups drop from
     chests; today's entries grant only items. POWERUP entries resolve through PowerupService's
     grant seam, host-side, same request flow.
  2. `LootEntry.rarity: int` (default 0) — the hook `loot_luck` (a shipped stat with no consumer)
     biases toward. Without it the stat has nothing to read.
  3. `Chest` price (`cost_coins`, consuming through the existing `chest_price` stat) and
     `locked_by: StringName` (key item id, checked host-side like any other validation).
  4. A placement budget for `gilded` (≈1–2 per island) wherever chest placement lands.
- **3.8 (food):** nothing — `hunger_restore`/`hp_restore` shipped on `ItemDef` already. Buff foods
  wait for the surge runtime exactly as POWERUPS.md §3 recorded; do not sneak one in as a field.
- **5.3 (ranged):** the **throw verb** rides its host-validated projectile path; §4.6 is the payload.
  Status throwables re-gate on Burning/Chilled from the Resonance tasks.
- **3.10 (hauling):** the Heavy Mithril Chunk is its hauled object — the system and the economy
  meet in one item.
- **4.11 (Mire interaction):** the Blight Residue drop rule (R7) and Glowcap's Mire-edge placement.
- **6.6 (Salvage):** the §4.8 trinket proposal — flagged, not assumed.
- **`ItemDef`:** no changes needed now. If display grouping ever wants `Category.COMPONENT` /
  `THROWABLE`, that's a UI nicety, not a data need — decide it in the inventory-UI task.

## 7. Assets this plan needs — tracker rows A-043 … A-047

Queued in `docs/ASSET_TRACKER.md` with gates (never started before their systems/creatures exist).
Summary: **A-043** wetland gatherables II (cattail, moss, glowcap, poison berry bush, fish shoal,
raw fish — ~7) · **A-044** creature-drop pickups (~15) · **A-045** refined/component pickups
(tar, rope, cloth, leather, flask, mechanism, mithril pair, wellglass, heavy chunk — ~10) ·
**A-046** throwables & held lights (~11) · **A-047** Gleam uniques + Gilded/Sunken chests + keys
(~14 exports). Icons ride A-042's pipeline (append `SOURCES`). Existing queue rows A-011 (plants)
and A-012 (food) are unchanged and remain the first wave's art.

## 8. Authoring waves — what ships when

"Fun before content" governs; a wave waits for its gate, authoring earlier is fine (data that waits).

| Wave | With | Content |
|---|---|---|
| W1 | 3.1/3.2 (now) | §4.1 T0–T2 raws, §4.3 refined set, food basics, Branch Club, Reed Machete, torch — the crafting tree's flesh, on A-002/A-011/A-012 art. **First slice shipped 2026-08-18 (`9caef22`):** 7 items (branch, flint, coal, fibre_bundle, berry, mushroom, raw_meat) + 11 recipes making every existing tool/weapon craftable; the rest of W1 waits on A-011/A-012 art because `item_icons_check` requires every ItemDef to carry a real icon |
| W2 | 3.5 | §5 tables, keys, coins flow, **the first Gleam set** — every Gleam *powerup* and one-shot is art-free and ships day one; unique weapons follow A-047. **Shipped 2026-08-18 (3.2, slate17):** all six remaining §5 tables (`bog` `strongbox` `wellspring` `gilded` `sunken` `boss`) and all **eight Gleam powerups** (untagged, `max_stacks 1`), plus the schema they needed — `LootEntry.kind`/`rarity`, `Chest.cost_coins`/`locked_by`, powerups granted through PowerupService (F-140: 3.5 closed without any of it). King's Purse ships as a 400–800 coin line and World's Okayest Axe as `stone_axe` at weight 1 until A-047 (D-091). Still open in W2: Rusted/Gilded **keys** as items (they need A-044 art), the unique weapons, and a placement budget for `gilded` |
| W3 | 3.8 (+stamina) | tonics, cooked-food breadth |
| W4 | M4 Mire | Wellglass, Blight Residue, Pale Draught, Glowcap placement, Sunken Caches |
| W5 | M5 per-enemy | each creature's drops ship *with the creature*; throwables with 5.3 |
| W6 | M6 | Boss Caches, trophies, Salvage trinkets (if taken), comedy breadth |

Rough count: ~136 items in this doc + ~60 powerups in POWERUPS.md ≈ **195 authored things**, of
which ~45 are authorable the day 3.1 lands.

## 9. Cut on purpose (so they aren't proposed twice)

**Fishing rod/minigame** — fish shoals are Harvestables; the whole system costs one placed node
type. **Armor/equipment slots** (R3). **Durability** (R4). **Thirst** — water flask's A-012 asset
becomes the Fired Flask visual. **Shops/trader** — chests are the only coin sink until a playtest
demands otherwise; a shopkeeper who insults you (`DESIGN.md` §6) is M7 flavour on top of a chest,
not a new economy. **A fourth ingot tier** — deep Cycles escalate by modifier and Gleam, not by
mithril-but-purple.

## 10. What would reopen this catalog

- A playtest showing the 2-step refinement cap makes tiers feel *hollow* rather than fast →
  revisit R2 with one added intermediate at T3 only.
- The surge-buff runtime shipping → promote buff foods and Glow Tonic from [gated] to authored.
- 3.5 finding `LootEntry.kind` insufficient (e.g., wanting nested tables) → the answer is a
  `table_id` entry kind, still one field, never a parallel roll system.
- Sequoyah declining the Salvage-trinket proposal → delete §4.8's row and the W6 line; nothing else
  references it.
