# PROGRESSION — the tool ladder and the guidance layer

> Written 2026-08-21 (birche6b40e) on Sequoyah's directive: *"we gotta get the game progression
> fleshed out, the game feels kind of directionless rn there's no tutorial or tips to guide you and
> the tools don't really have a clear progression, I'm thinking 5 tiers of tools at least that are
> progression gated during each run."*
>
> This is the spec for ROADMAP tasks **3.18** (five-tier ladder) and **3.19** (in-run guidance). It
> sits under `DESIGN.md` §4.3 (forks, not tiers) and beside `ITEMS.md` (the catalog) and
> `GAMELOOP.md` (the minute-by-minute run). Where it disagrees with `ITEMS.md` §3's three-tier
> language, **this document wins and `ITEMS.md` is corrected in place** — the tier count is the
> thing being changed.

---

## 1 · The diagnosis

The run has a shape (`GAMELOOP.md` §1) and almost none of it is legible to the player.

**Two separate defects, one symptom.**

1. **The ladder is over before the run starts.** Three tool tiers ship — wooden (`harvest_power` 1),
   stone (2), iron (3) — and all three are reachable inside the first fifteen minutes by one player
   who knows where a rock is. After that, ninety minutes of Cycles escalate the *threat* with
   nothing escalating the *player's kit* except powerups, which are chest luck rather than
   progression. A survival game whose crafting peak arrives at minute fifteen has no mid-game.
2. **Nothing ever tells you what the game wants.** There is no tutorial, no objective line, no tip,
   no first-time prompt anywhere in the build. `HarvestableDef.wrong_tool_scale`'s comment claims
   the floor-to-zero rule is "the readable version of *you need an axe for this*, without a
   tutorial" — that is true of the *rule* and false of the *player*, who sees a tree take zero
   damage and concludes the tree is broken.

Both are fixed below, and they are fixed together on purpose: **the guidance layer's whole job is to
narrate the ladder.** Build the tips first and you write them twice.

---

## 2 · The ladder — five tiers, five different verbs

The rule that decides the whole design: **each tier is unlocked by a different kind of action**, so
climbing the ladder is how the game teaches itself.

| Tier | Material | Tools | `harvest_power` | Unlocked by | The verb it teaches |
|---|---|---|---|---|---|
| **T0** | — | bare hands | 0–1 | — | *(the bootstrap, not a tier)* |
| **T1** | Wood | wooden axe · wooden pickaxe | 1 | branches off the ground, hand-crafted, **no station** | gathering |
| **T2** | Stone | stone axe · stone pickaxe · flint knife | 2 | a **Workbench** (station tier 1) the party places | building |
| **T3** | Iron | iron axe · iron pickaxe · **fork: cleaver / skewer** | 3 | a bog-iron node, which needs a **stone** pick to bite, smelted at a **Furnace** (station tier 2) | exploring |
| **T4** | Bogsilver | bogsilver axe · pickaxe · the fork upgraded | 4 | a **Heavy Chunk** hauled home (3.10's two-player carry) and an **Anvil** (station tier 3), whose own recipe costs a **Wellglass Shard** | the objective loop, and co-op |
| **T5** | Wellglass | wellglass axe · pickaxe · the fork's final form | 6 | a **Guardian Core** from a boss kill (5.6), plus shards | fighting the thing the run is about |

`harvest_power` steps 1 · 2 · 3 · 4 · **6** — the last jump is deliberately oversized. T5 is the end
of the ladder and should land like one.

### 2.1 Why five, and why these gates

- **A run is 60–120 minutes.** Three tiers pace fifteen of them. Five tiers, with the top two hung
  off *world events* rather than off mining, pace the whole thing: there is always a next rung, and
  the next rung is always something the game already wanted you to do.
- **T4 and T5 cannot be rushed by a good gatherer.** This is the entire point of "gated during each
  run". You cannot mine your way to Bogsilver at minute ten however efficient you are, because the
  Anvil needs a Wellglass Shard and shards come only from a capped Wellspring. The ladder is
  therefore a *readout of run progress*, not a readout of time spent harvesting.
- **T4 is the co-op rung.** Its ore drops as a Heavy Chunk (`ITEMS.md` §4.8, task 3.10): two players
  carry it fast, one player drags it slowly. The tier the mid-game hangs on is the tier that is
  meaningfully better with a friend — which is what MIRE is.
- **T5 is the reward for the fight, not for the grind.** Killing a guardian is already the run's
  hardest voluntary act; paying it out in the last tool tier makes "should we take the boss?" a
  progression question rather than a bravery question.
- **Nothing carries between runs.** The ladder resets every run and the meta unlock tree stays
  *variety, never power* (`DESIGN.md` §4.6). Salvage buys new things to find, never a head start.

### 2.2 Forks survive (`DESIGN.md` §4.3)

Tiers are a ladder; **each tier from T3 up is also a fork.** Iron forks into CLEAVER (slow, heavy,
cleaves) and SKEWER (fast, long, bleeds). T4 upgrades *your* fork cheaply or re-forks expensively;
T5 does the same again. Tool *is* weapon — upgrading a pickaxe is an economy decision and a combat
decision in the same breath, and that is what keeps two shallow trees from existing at all.

### 2.3 Naming

`ITEMS.md` called T3 "mithril" as a placeholder and invited a rename. Renamed here to **Bogsilver**
— it is ours, it is a bog, and generic fantasy mithril belongs to a different game. **Wellglass**
(T5) was already in the catalog and stays. The ore item id is `bogsilver_ore`; `mithril` appears
nowhere in shipped content.

### 2.4 What the tier gates actually key off

Gates are *content*, not code branches. Each rung is expressed with mechanisms that already ship:

| Rung | Mechanism | Already ships? |
|---|---|---|
| tool bites node | `HarvestableDef.required_tool` + `max_health` in tool-power units | yes (2.3) |
| recipe needs a station | `RecipeDef.station` → `StationDef.tier` | yes (3.1) |
| recipe needs a rare input | `RecipeDef.inputs` naming `wellglass_shard` / `guardian_core` | yes (2.6) |
| shard drops from a cap | `RewardService` wellspring tier loot table | yes (F-183) |
| core drops from a boss | `RewardService` boss tier loot table | yes (F-183) |
| ore hauls as a heavy chunk | `HaulService` haulable | yes (3.10) |

**So 3.18 is overwhelmingly an authoring task, not an engine task.** The one piece of new code it
needs is §4.

---

## 3 · The nodes and the map

T4 and T5 need somewhere to come from, and that place must be *findable* on a generated island.

- **Bogsilver outcrop** — a `Harvestable` (`required_tool = Mine`, health in T3 units so an iron
  pick is the entry ticket), scattered only in `highland` and on the Mire border, and always at
  least one guaranteed near a Wellspring POI. Yields the Heavy Chunk, not a stack.
- **Wellglass** is not mined. It comes out of the objective loop entirely — caps and guardians —
  which keeps R7 honest: *the Mire is a place you fight, never a place you farm.*

`WORLDGEN.md`'s landmark guarantees are what make "go find the outcrop" a walk rather than a search
grid; the objective marker system (4.8) is what makes it a destination.

---

## 4 · `ProgressionService` — the one new system 3.18 needs

Everything above works without a new autoload, except one thing: **nothing in the build knows what
tier the party has reached**, so nothing can announce it, gate it, or show it. `SalvageService`
already notes the absence — `DESIGN.md` §4.6's scaling factor lists "tiers reached" and there is no
such fact to read.

```
ProgressionService (autoload)
  tier_reached() -> int                 # 0..5, the party's high-water mark this run
  tier_of_item(id) -> int               # authored on ItemDef.tool_tier
  is_tier_unlocked(t) -> bool
  signal-equivalent: EventBus.tier_reached(tier: int, item_id: StringName)
```

**Network authority: HOST-owned, replicated as one small int** (`ARCHITECTURE.md` §2.2, "world
mutation" row). It is a party fact, not a per-player one: if one player forges the first iron pick,
the party has reached the iron age, the fanfare plays for everyone, and `SalvageService` scores it
once. The host raises the high-water mark when a craft transaction commits an item whose
`ItemDef.tool_tier` exceeds the current mark; clients receive it through `WorldDeltaLog` like every
other run fact, so a late joiner is caught up without a bespoke snapshot path.

One new authored field, and it is the only schema change in 3.18:

```gdscript
# ItemDef
@export_range(0, 5, 1) var tool_tier: int = 0
```

Zero means "not a rung" — resources, food, buildables, everything that is not a tool or weapon.
Naming it now, in this doc, is the `F-078` discipline: an invented field must be a decision someone
noticed.

---

## 5 · The guidance layer (task 3.19)

**What it is not:** not a tutorial level, not a forced prompt, not a quest log, not a character who
talks. MIRE is an evening with friends; nothing here may take the cursor, block input, or make a
player wait.

**Three surfaces, and never more than one of them speaks at once.**

### 5.1 The objective line
One line, always present, bottom-left above the hotbar. It names *the next thing*, and only ever
one:

> *Punch a bush for fibre* → *Craft a wooden axe* → *Chop a tree* → *Place a workbench* →
> *Craft a stone pickaxe* → *Find a bog-iron node* → *Smelt iron at a furnace* →
> *Cap the Wellspring — the marker is on your compass* → *Haul a bogsilver chunk to an anvil* →
> *Kill the guardian* → *Repair the wreck, or push one more Cycle*

It is a priority-ordered list of steps; the service shows the highest-priority step whose
precondition holds and whose completion test does not. Once the list is exhausted — roughly, once
the party has capped a Wellspring — it stops naming chores and starts naming the **run's** state:
the Cycle, the modifier drawn, the next rung. A veteran party sees it drain away within ten minutes
and never think about it, which is the intended experience.

### 5.2 Tips
One-shot contextual cards, four seconds, top-centre, no input required:

- first time a tree takes zero damage → *"Bare hands won't fell a tree. Craft an axe."* — this one
  card is the single highest-value line in the game; it is the exact failure §1 describes.
- first crawler sighted → *"It winds up before it strikes. Dodge through it."*
- first night → *"Things come out at night. Walls help."*
- first time standing on corrupted ground → *"The Mire eats your health and pays nothing. Fight
  here; don't farm here."*
- first chest → *"Coins buy the priced ones."*
- first downed teammate → *"Hold [interact] over them."*

Each fires **once per profile**, not once per run, so a returning player is not re-taught. Rate
limit: one card at a time, minimum six seconds apart, tips queue rather than overwrite.

### 5.3 Tier fanfare
When `ProgressionService` raises the mark: a banner naming the age and what it opened —
*"THE IRON AGE — bog iron smelts at a furnace."* This is the payoff that makes a rung feel like a
rung, and it is the reason §2's gates were chosen to be *events* rather than thresholds.

### 5.4 Data, and the deliberate absence of a mini-language

Steps and tips are authored `.tres` (`content/guide/`, `GuideStepDef`), same as every other content
family. Conditions are **not** an expression string — they are a small enum of predicates evaluated
in code, with one argument:

`HAS_ITEM · CRAFTED_ITEM · STATION_BUILT · TIER_REACHED · WELLSPRINGS_CAPPED · CYCLE_AT_LEAST ·
BOSS_KILLED · NIGHT_FALLEN · SAW_ENEMY · WRONG_TOOL_HIT · ON_CORRUPTED_GROUND · TEAMMATE_DOWNED`

**Recorded call:** the moment guidance takes an expression parser, someone writes game logic in
strings and the checks stop being able to prove coverage. New condition ⇒ new enum member ⇒ a
compile-time-visible change. Twelve predicates cover every line in §5.1 and §5.2 with room to spare.

### 5.5 Authority, and why it is client-local

**Network authority: none.** Guidance is presentation (`ARCHITECTURE.md` §2.2, "VFX, audio, camera,
UI" row): each peer evaluates its own steps against state it already has. Two caveats the
implementation must respect:

- **`wellspring_capped`, `boss_defeated` and friends are HOST-only emits.** A client's own bus never
  fires them. Guidance therefore **polls replicated node/service state** for those facts
  (`Wellspring.capped`, `CycleService.current_cycle()`, `ProgressionService.tier_reached()`) rather
  than subscribing — the same trap F-250 and F-254 already cost this repo twice.
- **Party facts advance everyone's line.** If your teammate places the workbench, your objective
  line moves on. Personal facts (your inventory, your hands) stay personal.

### 5.6 Off switches
Settings → **Guidance: Full · Objectives only · Off**. Default Full. Off is honoured immediately and
persists; nothing here is ever the reason a player cannot see the game.

---

## 6 · Order of work

1. **3.18a** — `ItemDef.tool_tier`, `ProgressionService`, the `tier_reached` event, `SalvageService`
   reading it. *(code; ~1 session)*
2. **3.18b** — author T3's missing iron axe, then T4 and T5: items, weapons, recipes, the anvil
   station, the bogsilver outcrop harvestable, the scatter entries, the two reward-table drops.
   One asset at a time (D-073). *(content; the bulk)*
3. **3.19a** — `GuideStepDef`, `GuideService`, `guide_hud`, the settings toggle. *(code)*
4. **3.19b** — author the steps and tips of §5.1/§5.2. *(content)*
5. **Tuning** — is the line patronising? is T4 too far? That is a playtest question (2.14), and per
   D-125 it gates nothing.

## 7 · How each piece is proven

Headless, through `agent godot` (never bare — F-044):

- `tools/tool_ladder_check.gd` — extends the existing `harvest_tool_ladder_check`: every tier's
  tools bite what they should and floor to zero on what they should not, and every rung's recipe is
  reachable only through its gate. **The gate assertion is the one that matters**: it is what proves
  a party cannot reach T4 without a cap.
- `tools/guide_check.gd` — every authored step's condition resolves; the walk-through of a scripted
  run advances the line in the documented order and never shows two steps at once; a tip fires once
  and not twice.
- `tools/progression_net_check.gd` — two processes: the client's tier mark follows the host's, and a
  late joiner receives the current mark.

## 8 · Deliberately not doing

- **No tutorial level or scripted opening.** The first three minutes of a run *are* the tutorial;
  they just needed a narrator.
- **No quest log, no waypoint list.** One line. If a second line is ever needed, the first was wrong.
- **No durability, no ammo anxiety** (`ITEMS.md` R4 stands). The ladder pulls you forward; it never
  pushes you by taking your kit away.
- **No sixth tier.** Past T5 the run escalates through Cycle modifiers, Resonance and the Gleam pool
  — content, not another ingot. `ITEMS.md`'s original instinct here was right; it just stopped one
  rung too early.

---

## 9 · Current state — what shipped, what is left, and what is blocking it

*Written 2026-08-21 (birche6b40e), at commit 5f115a8. This section is here rather than in
`DELEGATION.md`'s Current state because a sibling holds an exact claim on that file; fold it across
when the claim frees.*

### Shipped and pushed — the code half of both tasks

`ProgressionService` (autoload script, **not yet registered**) owns the party's high-water rung:

```gdscript
ProgressionService.tier_reached() -> int          # 0..5, party-wide, high-water
ProgressionService.is_tier_reached(t) -> bool
ProgressionService.tier_of_item(id) -> int        # reads ItemDef.tool_tier
ProgressionService.tier_name(t) -> String         # "" / Wood / Stone / Iron / Bogsilver / Wellglass
ProgressionService.host_raise_tier(t, item_id)    # HOST-only; idempotent, rises only
ProgressionService.host_reset_run()
EventBus.subscribe_tier_reached(func(tier: int, item_id: StringName) -> void)
```

Host-owned, replicated through `WorldDeltaLog` under `kind = &"progression"` and re-derived on every
peer — **no new RPC, so no protocol bump.** `CraftingService._finish_craft()` is the one caller.
`SalvageService` scores `TIER_REACHED_BONUS` per rung, which is the "tiers reached" milestone
`DESIGN.md` §4.6 has always listed and never had a fact for.

`GuideService` + `GuideHud` (both **not yet registered**) ship the objective line, the one-shot tips
and the tier fanfare, over the `content/guide/*.tres` → `GuideStepDef` family that
`Registry.guide_step_defs()` now indexes. `GuideService.evaluate()` is public so a check can step a
scripted run without waiting out real seconds. Off switch: `SettingsService.guidance_mode()`
(0 FULL / 1 OBJECTIVES ONLY / 2 OFF) plus `has_seen_tip()` / `mark_tip_seen()` / `reset_seen_tips()`,
surfaced on Settings → Accessibility. **The settings save schema is now version 3.**

Two small accessors were added for the conditions and are the reusable half: `CraftingService.station_count(id)`
— a PARTY fact, any station anywhere, riding the F-286 cache — and `FocusPrompt.focus_is_blocked()`,
which is whether the player is looking at something their held tool cannot chip.

One new authored field: **`ItemDef.tool_tier` (0..5)**, 0 meaning "not a rung".

### Left to do — all of it `.tres`, all of it editor-gated (D-031/D-021)

The Godot editor was open for the whole of this session, so nothing below could be authored without
risking the editor rewriting it on save.

1. **`content/guide/`** — the objective ladder `tools/guide_check.gd` already names in order
   (`gather_fibre`, `craft_first_axe`, `chop_a_tree`, `place_workbench`, then the Wellspring / anvil /
   guardian rungs) plus the tips of §5.2.
2. **T3's missing iron axe**, then all of T4 and T5: items, `WeaponDef`s, recipes, the **anvil**
   station (tier 3, its recipe costing a Wellglass Shard), the **bogsilver outcrop** harvestable and
   its scatter entries, `wellglass_shard` into the `wellspring` loot table and `guardian_core` into
   the `boss` one.
3. **Register three autoloads** — `agent autoload ProgressionService res://autoload/progression_service.gd`,
   the same for `GuideService` and for `GuideHud` (`res://ui/hud/guide_hud.gd`). Order matters only in
   that `GuideHud` must come after `GuideService`.

`tools/progression_check.gd` and `tools/guide_check.gd` both fail at this commit, and they fail by
**naming exactly what is unauthored** — run them first and treat the output as the worklist.
