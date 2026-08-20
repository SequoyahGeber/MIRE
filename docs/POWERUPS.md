# POWERUPS.md — the 3.4 authoring spec and the stat vocabulary

**What this is.** The pre-3.4 design check on the `PowerupDef` schema (2026-08-18, reed16), and the
document task 3.4 authors 40–60 `.tres` files against. The check's question: *can 60 powerups
spanning the whole design space be expressed as `tags` + `max_stacks` + `(stat → Vector2)` pairs,
or does the schema need a field it doesn't have — now, while re-shaping costs one worked example
instead of 60 hand-authored files?*

**The verdict: the schema holds. Zero of the 60 sketched below need a new field.** The §4.4/D-044
stance survives contact — stats are the boring, predictable half on purpose; qualitative power
lives in the 12 Resonances. What the sketch DID surface is that the risk was never in the fields —
it is in the *names*. Every `modifiers` key is a hand-typed promise about a stat some future system
will query, and nothing checked those promises. That is F-078, fixed with this doc:
`PowerupDef.KNOWN_STATS` / `KNOWN_FAMILIES` mirror the catalog below and `validation_errors()`
rejects what they don't contain, so a typo is a named boot error instead of dead content.

**Adding a stat that isn't in the catalog** is deliberate, not forbidden: add the row here, add the
name to `KNOWN_STATS` in `systems/powerups/powerup_def.gd`, done. One line each. The point is that
inventing a name is a *decision you notice*, made once in two places that can't drift silently —
not a thing that happens by accident in file 43 of 60.

---

## 1. The one rule that keeps the maths readable

**A stat is named for the exact quantity the consuming system computes, so D-044's formula reads
literally.** `stat(peer, name, base)` returns `(base + additive·N) · (1 + multiplicative·N)` summed
across held powerups — so:

- A **reduction is a negative value on the same stat**, never a separate inverted "resist" stat.
  Slower hunger is `hunger_drain: Vector2(0, -0.08)`. Armor is `damage_taken: Vector2(0, -0.04)`.
  There is no `hunger_resist`, no `armor` — nobody should ever have to remember which direction a
  name inverts.
- **`Vector2(additive, multiplicative)` per stack.** `Vector2(0, 0.08)` = +8% per stack.
  `Vector2(2, 0)` = +2 flat per stack. Both components legal at once, negatives legal in both.
- **The zero-crossing bound (validator-enforced):** because stacking is linear, a negative
  multiplier must satisfy `1 + mult · max_stacks > 0`. `-0.15` × 7 stacks = −5% hunger drain,
  i.e. hunger that refills itself. Author reductions against the cap you set.

## 2. The stat catalog

`KNOWN_STATS` in `powerup_def.gd` is this table's name column, exactly. **Wiring status** is honest:
per 3.4's spec, no system reads a stat until its own task routes its base value through
`PowerupService.stat()` — authoring against a `pending` stat is correct data that waits, which is
expected, not a bug (and now, not a typo either).

### Live systems (the consuming code exists; wiring is that system's one-line route)

| Stat | Consumed quantity | Sign notes | Consumer |
|---|---|---|---|
| `move_speed` | walk & sprint base speed | | `player_controller.gd` (client-auth own movement → `local_stat`) |
| `sprint_speed` | sprint speed, applied after `move_speed` | | `player_controller.gd` |
| `jump_height` | jump apex height (m) | | `player_controller.gd` |
| `air_control` | air acceleration | | `player_controller.gd` |
| `extra_jumps` | additional mid-air jumps | flat count; `max_stacks 1` typical | `player_controller.gd` |
| `max_hp` | maximum health | flat points | `systems/health/player_health.gd` (host) |
| `damage_taken` | incoming damage after the attacker's calc | negative mult = armor | `player_health.gd` (host) |
| `bleed_out_seconds` | downed timer | positive = longer to save you | `player_health.gd` (host) |
| `revive_seconds` | time THE REVIVER needs | peer = the reviver, not the downed | `player_health.gd` (host) |
| `revive_radius_m` | reviver's reach | peer = the reviver | `player_health.gd` (host) |
| `hunger_drain` | hunger lost per second | negative mult = slower | `player_health.gd` (host) |
| `food_value` | hunger restored per eat | | `player_health.gd` (host) |
| `melee_damage` | weapon damage dealt | | combat path (host), base from `WeaponDef.damage` |
| `melee_range_m` | swing reach (m) | | combat path (host), base `WeaponDef.range_m` |
| `attack_seconds` | swing phase durations (wind-up/commit/recovery scaled together) | negative mult = faster | combat path |
| `bow_damage` | ranged damage dealt | | combat path (host) |
| `harvest_yield` | items per harvest hit | | `harvest_world.gd` (host) |
| `harvest_damage` | damage per hit to a node | | `harvest_world.gd` (host) |
| `craft_seconds` | timed-craft duration | negative mult = faster | `crafting_service.gd` (host) |
| `coin_gain` | coins rolled per kill | | loot/kill reward path (host) |
| `chest_price` | cost to open | negative = discount | `systems/loot/chest.gd` (host) |
| `loot_luck` | weight bias toward higher-tier chest entries | | loot roll (host) |
| `dodge_iframe_seconds` | how long past the dash the i-frame flag stays true | flat seconds; cannot shorten the window below `dodge_duration_sec` (D-087) | `player_controller.gd` `_execute_dodge()` (client-local; the host reads the resulting flag) |

### Pending systems (the stat waits for its system's task — listed so 3.4 can author toward them without inventing names)

| Stat | Consumed quantity | Arrives with |
|---|---|---|
| `max_stamina` | stamina pool | 3.8 (client-local stamina) |
| `stamina_regen` | stamina per second | 3.8 |
| `stamina_cost` | cost of sprint/jump/dodge actions (negative mult = cheaper) | 3.8 |
| `fall_damage_taken` | landing damage (negative mult = softer) | 3.8-adjacent, if fall damage ships |
| `knockback_taken` | knockback applied to you (negative mult = stability) | enemy knockback |
| `blight_rate` | Blight accumulation while in the Mire (negative mult = resist) | 4.x Mire |
| `aggro_radius_m` | enemy detection radius vs this player (negative = stealth) | enemy AI consult |
| `haul_speed` | heavy-carry drag speed | 3.10 |
| `ward_radius_m` | ward radius of structures YOU placed | 3.7/4.11 — flags the builder-attribution question §4.5's Warden needs answered anyway |
| `on_kill_heal_hp` | flat HP healed per kill you land | kill-attribution site (host) |
| `on_hit_lifesteal` | fraction of dealt damage returned as HP | damage-dealt site (host) |
| `ignite_chance` | chance per hit to apply Burning | the Fire-Resonance task's status effect |
| `slow_chance` | chance per hit to apply Chilled | the Cold-Resonance task's status effect |
| `slow_potency` | strength of Chilled you apply | the Cold-Resonance task |
| `arrow_save_chance` | chance a fired arrow isn't consumed | bow fire site (host) |

### Condition-suffixed stats — a closed set, on purpose

A conditional powerup ("+damage below a third HP") is a **suffixed stat name evaluated by the
consumer that owns the condition**, chained onto the unconditional pass:

```gdscript
var damage: float = PowerupService.stat(peer, &"melee_damage", weapon.damage)
if health_fraction < LOW_HP_FRACTION:
    damage = PowerupService.stat(peer, &"melee_damage_low_hp", damage)
```

The service stays condition-blind (D-179: pushing condition state INTO PowerupService would invert
the one seam and put every peer's hp/position on the wire). Three conditions exist; each is one
`if` in the system that already owns the fact:

| Suffix | Condition | Evaluated by |
|---|---|---|
| `_low_hp` | health below ⅓ | the consumer, from `PlayerHealth` |
| `_in_mire` | standing in corrupted cells | the consumer, from the Mire grid (4.x) |
| `_at_night` | night phase active | the consumer, from day/night state |

Authorized combos (each is a `KNOWN_STATS` entry — a new combo is a new line, not free-form):
`melee_damage_low_hp` · `move_speed_low_hp` · `melee_damage_at_night` · `move_speed_in_mire`.

## 3. What is NOT a powerup stat — the design boundary, restated so 3.4 doesn't fight it

- **Bespoke qualitative behavior** (corpses sprout clouds, blinks leave rifts, chains, explosions)
  is **Resonance territory** — §4.4 puts the run-defining payoffs at the 3+/6+ tiers, D-044 keeps
  stats boring on purpose. Don't author a powerup that needs its own behavior script.
- **The escape hatch, if a signature-behavior powerup is ever wanted anyway:** its effect task keys
  off `PowerupService.stacks_of(peer, &"the_id")`. Zero schema change — it's just code keyed to an
  id, exactly like a Resonance is code keyed to a family. Costs quota per powerup, which is why
  it's the exception.
- **Timed surges** ("+speed for 4s after a kill") are excluded from the 60 by design: they need a
  buff-bookkeeping runtime no system has. If wanted later: one surge mechanic task + two catalog
  names (magnitude, duration). Not a field.
- **On-pickup one-shots** ("+50 coins now") are chest-loot's job (coins are an item, 3.5), not a
  held powerup.

**Tag-only feeders are legal and good.** A powerup with tags and NO modifiers ("Open Flame — pure
Fire essence") is pure Resonance commitment — cheap chest filler that makes the §4.4 decision
("commit to your tag or branch?") appear even when no stat powerup rolls. The validator allows
exactly this; what it rejects is no-tags-AND-no-modifiers.

**`max_stacks` guidance.** Percent always-on stats: 5 (D-044 linear = tune the 5th stack, trust
the middle). Conditional/tradeoff stats: 3 (they spike). Capabilities (`extra_jumps`): 1.
Tag-only feeders: 9 (commitment should be deep). Ceiling is 99; these are conventions, not rules.

**Icons.** `icon` may be left empty at author time — validation doesn't require it, and the F-061
icon pipeline (`render_item_icons.py` SOURCES) can batch them later. Don't block authoring on art.

## 4. The 60-powerup sketch

Proof of coverage, and a menu — **not a shipping list**. Rename, rebalance, cut, replace freely;
what must survive contact is the *shape*: every entry below is expressible today as catalog names,
and that stays true for anything else built from §2. Values are starting guesses at D-044 maths.
`Mods` reads `stat (additive, multiplicative) per stack`.

Archetype key: **A** always-on stat · **C** condition-suffixed · **E** event-site scalar ·
**P** proc/status chance · **K** capability count · **T** tradeoff (negative component) ·
**Ø** tag-only feeder.

### Fire — aggression, heat, the forge

| Powerup | Tags | Mods | Max | |
|---|---|---|---|---|
| Ember Knuckle | Fire | `melee_damage` (0, 0.06) | 5 | A |
| Tinder Snap | Fire | `attack_seconds` (0, −0.05) | 5 | A |
| Ashen Temper | Fire | `ignite_chance` (0.08, 0) | 5 | P |
| Flashover | Fire | `melee_damage_low_hp` (0, 0.12) | 3 | C |
| Cauter Seal | Fire, Blood | `on_kill_heal_hp` (1, 0) | 5 | E |
| Forge Blood | Fire | `craft_seconds` (0, −0.08) | 5 | A |
| Night Pyre | Fire | `melee_damage_at_night` (0, 0.08) | 5 | C |
| Warm Marrow | Fire, Cold | `blight_rate` (0, −0.06) | 5 | A |
| Cinder Tithe | Fire, Void | `coin_gain` (0, 0.08) | 5 | A |
| Open Flame | Fire | — | 9 | Ø |

### Blood — vitality, cost, the wound

| Powerup | Tags | Mods | Max | |
|---|---|---|---|---|
| Thick Hide | Blood | `max_hp` (8, 0) | 5 | A |
| Red Quench | Blood | `on_hit_lifesteal` (0.02, 0) | 5 | E |
| Adrenal Bloom | Blood, Kinetic | `move_speed_low_hp` (0, 0.08) | 3 | C |
| Pact Cut | Blood | `melee_damage` (0, 0.10) · `max_hp` (−4, 0) | 5 | T |
| Sealed Veins | Blood | `damage_taken` (0, −0.04) | 5 | A |
| Steady Hands | Blood, Cold | `revive_seconds` (0, −0.10) | 3 | A |
| Stubborn Heart | Blood | `bleed_out_seconds` (0, 0.15) | 3 | A |
| Scab Feast | Blood, Fungal | `on_kill_heal_hp` (1, 0) | 5 | E |
| Iron Tongue | Blood | `food_value` (0, 0.10) | 5 | A |
| Whetted Thirst | Blood | — | 9 | Ø |

### Kinetic — momentum, breath, the leap

| Powerup | Tags | Mods | Max | |
|---|---|---|---|---|
| Swift Stride *(shipped)* | Kinetic | `move_speed` (0, 0.08) | 5 | A |
| Long Bound | Kinetic | `jump_height` (0, 0.07) | 5 | A |
| Bellows Lung | Kinetic | `max_stamina` (0, 0.08) | 5 | A |
| Second Wind | Kinetic | `stamina_regen` (0, 0.10) | 5 | A |
| Loping Gait | Kinetic | `sprint_speed` (0, 0.05) | 5 | A |
| Skip Step | Kinetic, Void | `extra_jumps` (1, 0) | 1 | K |
| Cat Fall | Kinetic | `fall_damage_taken` (0, −0.15) | 5 | A |
| Pack Frame | Kinetic, Fungal | `haul_speed` (0, 0.10) | 3 | A |
| Air Writ | Kinetic | `air_control` (0, 0.12) | 5 | A |
| Spent Spring | Kinetic | `stamina_cost` (0, −0.06) | 5 | A |

### Fungal — growth, rot, the meal

| Powerup | Tags | Mods | Max | |
|---|---|---|---|---|
| Wide Cap | Fungal | `harvest_yield` (0, 0.08) | 5 | A |
| Rot Chew | Fungal | `harvest_damage` (0, 0.10) | 5 | A |
| Slow Gut | Fungal | `hunger_drain` (0, −0.08) | 5 | A |
| Spore Sole | Fungal | `blight_rate` (0, −0.08) | 5 | A |
| Damp Stride | Fungal | `move_speed_in_mire` (0, 0.06) | 5 | C |
| Rich Marrow | Fungal, Blood | `food_value` (0, 0.12) | 5 | A |
| Moss Shroud | Fungal, Void | `aggro_radius_m` (0, −0.05) | 3 | A |
| Fruiting Call | Fungal | `loot_luck` (0, 0.06) | 5 | A |
| Root Hold | Fungal, Cold | `knockback_taken` (0, −0.12) | 3 | A |
| Quiet Bloom | Fungal | — | 9 | Ø |

### Cold — patience, preservation, the edge

| Powerup | Tags | Mods | Max | |
|---|---|---|---|---|
| Rime Shell | Cold | `damage_taken` (0, −0.05) | 5 | A |
| Chill Edge | Cold | `slow_chance` (0.08, 0) | 5 | P |
| Deep Frost | Cold | `slow_potency` (0, 0.10) | 5 | P |
| Still Breath | Cold | `stamina_cost` (0, −0.05) | 5 | A |
| Cellar Cache | Cold, Fungal | `hunger_drain` (0, −0.06) | 5 | A |
| Pale Guard | Cold | `max_hp` (6, 0) | 5 | A |
| Patient Draw | Cold | `bow_damage` (0, 0.08) | 5 | A |
| Sanctum Frost | Cold | `ward_radius_m` (0, 0.04) | 3 | A |
| Numb Skin | Cold | `blight_rate` (0, −0.06) | 5 | A |
| White Quiet | Cold | — | 9 | Ø |

### Void — absence, bargain, the step between

| Powerup | Tags | Mods | Max | |
|---|---|---|---|---|
| Far Grasp | Void | `melee_range_m` (0, 0.04) | 5 | A |
| Deep Pocket | Void | `coin_gain` (0, 0.08) | 5 | A |
| Hollow Bargain | Void | `chest_price` (0, −0.05) | 5 | A |
| Thin Step | Void | `dodge_iframe_seconds` (0.04, 0) | 3 | A |
| Unseen Seam | Void | `aggro_radius_m` (0, −0.06) | 3 | A |
| Fletcher's Debt | Void | `arrow_save_chance` (0.08, 0) | 5 | E |
| Gaunt Frame | Void, Kinetic | `move_speed` (0, 0.04) · `damage_taken` (0, 0.02) | 5 | T |
| Grave Due | Void, Blood | `revive_radius_m` (0, 0.08) | 3 | A |
| Second Glance | Void | `loot_luck` (0, 0.06) | 5 | A |
| Empty Vessel | Void | — | 9 | Ø |

**Coverage tally.** 60 total: 38 always-on stats, 4 condition-suffixed, 4 event-site, 3
proc/status, 1 capability, 2 tradeoffs (negative components), 5 tag-only feeders (+ 3 more
always-on carrying dual tags). 12 dual-tag bridges spread so every family pair that shares a theme
has one. **Fields required beyond the shipped schema: 0.** Stats requiring a shared consuming hook
that doesn't exist yet: the `pending` table — every one arrives inside a task that is already on
the roadmap, and D-179 records why hooks-at-the-consumer beats fields-on-the-def.

## 5. What would reopen the schema question

Honesty about the boundary. The evidence that should trigger a revisit, and the minimal shape each
would take (per D-044's template — none of these are speculatively built):

- **Per-powerup condition thresholds as data** ("this one triggers below 50%, that one below 20%")
  → the suffix convention stops working; that's an `@export var condition: StringName` +
  `condition_value: float` pair, service-filtered. Until a designer actually asks for two
  different thresholds, the closed suffix set is simpler and replication-free.
- **More than ~3 timed-surge powerups wanted** → the surge mechanic task, two catalog names, still
  no field.
- **A powerup that must display under one family while counting toward another** → D-044 already
  reserved the answer: `resonance_family` returns as an explicit override defaulting to `tags`.
