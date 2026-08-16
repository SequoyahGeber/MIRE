# MIRE — Game Design Document

> `MIRE` = a bog you sink into; also "mired" = stuck. Nods to Muck without being derivative.
> Do a Steam + trademark search before the store page (see `STEAM.md`, S1).

---

## 1. The pitch

> A co-op roguelike survival game where the island is being eaten alive, and you are losing.
> Gather, craft, and fight as a spreading corruption consumes the map. You can slow it. You can never
> stop it. Every hour you survive, you have less world left to survive on.

3–6 players. No win condition — **how far did you get?** A run ends when the island takes you, or when
you choose to cut your losses and sail away with what you've earned.

**The identity:** one evening, as deep as you can push. The brag is a number: *"we made it to Cycle 9."*

---

## 2. What we're keeping from Muck (the DNA)

These are non-negotiable. If a design change breaks one of these, it's the wrong change.

| # | DNA element | Why it matters |
|---|---|---|
| D1 | Drop in naked, with nothing | The bootstrap is the best 5 minutes of the genre |
| D2 | Day/night rhythm — gather in light, survive in dark | Creates natural pacing without a UI timer |
| D3 | Resource tiers that gate power | Simple, legible, always-satisfying progression |
| D4 | Stacking powerups that break the game | The reason you replay; the "oh no" moments |
| D5 | Zero-commitment drop-in co-op with friends | This is the actual product. Friction here kills it. |
| D6 | Runs end, and you start over | Roguelike, not survival-sandbox. No 200-hour bases. |
| D7 | Comedy/jank tone | It should never take itself seriously |

---

## 3. What we're fixing (the design problems)

Muck's weaknesses, and the specific system that answers each.

| # | Problem in Muck | Our answer |
|---|---|---|
| P1 | **The turtle problem** — optimal play is "build a box, wait for morning" | **The Mire** (§4.1) eats your base. Standing still loses. |
| P2 | **Powerups are flat** — mostly +X% stats, no build identity | **Tags & Resonance** (§4.4) — 3+ of a tag unlocks a run-defining effect |
| P3 | **Multiplayer is parallel play** — 4 people doing the same thing alone | **Attunements** (§4.5) + 2-player-required actions create real roles |
| P4 | **Losing gives you nothing** — a 45-min failed run is wasted | **Salvage** (§4.6) — every run banks progress, but only unlocks *variety*, never power |
| P5 | **Crafting is a chore ladder** — same 6 items, bigger numbers | **Forks, not tiers** (§4.3) — each tier is a choice you can't un-make |
| P6 | **Building is decorative** — enemies barely care about it | **Wards** (§4.2) — structures hold back the Mire. Building = territory. |
| P7 | **The world is featureless noise** | **Wellsprings & landmarks** (§4.2) give you a reason to go *that* way |
| P8 | **Every night is the same fight, bigger** | **Cycles** (§5) — each one deals a qualitative modifier, not just bigger numbers |
| P9 | **No reason to stop playing a good run, no reason to keep pushing a great one** | **Extraction** (§5.2) — leaving banks your rewards, staying multiplies them |

---

## 4. Core systems

### 4.1 The Mire — signature mechanic

A corruption that spreads across the island over the course of a run.

**Simulation:** a 2D grid over the island (~256×256 cells, one cell ≈ 4m). Each cell has a `corruption` float 0..1. Every tick (2s), corruption flood-fills outward from corrupted cells at a rate set by the current Cycle. Purely 2D — cheap to simulate, cheap to network (send deltas, not the grid).

**What corrupted land does:**
- Resource nodes rot — trees/ore give reduced or no yield
- Enemies spawn continuously, not just at night
- Fog thickens, sightlines collapse, ambient audio shifts
- Player takes stacking `Blight` debuff the longer they stand in it

**The island is the health bar.** This is the core structural idea of the whole game.

You are fighting a losing battle. Capping Wellsprings and building Wards pushes the Mire back, but its base spread rate rises every Cycle, and capped Wellsprings slowly re-corrupt. Early on you take ground easily. By Cycle 6 you're holding even. By Cycle 10 you're being squeezed onto a shrinking peninsula with nothing left to gather.

```
 Cycle  1  ░░░░░░░░░░░░░░░░░░░▓░   the island is yours
 Cycle  5  ░░░░░░░░░▓▓▓▓░░░░▓▓▓▓   holding the line, contested
 Cycle  9  ▓▓▓▓▓▓░░░▓▓▓▓▓▓▓▓▓▓▓▓   three safe pockets, resources thin
 Cycle 12  ▓▓▓▓▓▓▓▓▓▓▓▓░▓▓▓▓▓▓▓▓   one hill. this is where it ends.
```

**Why it's the right mechanic:**
- Solves the turtle problem structurally, not with a nag timer
- Gives endless escalation a **natural, dramatic, readable ending** — you don't lose to a number going up, you lose because there is no more island
- The run's state is *visible on the horizon*. You never read a UI to know how you're doing.
- Difficulty escalates by shrinking the safe space **and thinning the resource economy**, which is far more interesting than inflating enemy HP
- **Technically cheap.** A 2D scalar grid is one of the easiest things to simulate and replicate. High design value, low engineering risk — this is the correct kind of signature mechanic for a solo dev.

**Pushing back:** capping a Wellspring (§4.2) clears corruption in a radius and temporarily reduces the global spread rate. This is the run's objective loop, and it never stops being necessary.

### 4.2 Wellsprings & Wards

**Wellsprings** — 5–7 fixed POIs per island, visible from distance (tall, glowing, readable silhouette). Capping one requires:
- A short **ritual** (~60s) that spawns a defense wave
- **At least 2 players present** — the first hard interdependence

Capping grants: local corruption cleared, global spread rate reduced, a powerup chest, and (first cap only) Attunement selection.

**Wards** — player-built structures project a corruption-resisting radius. Enemies actively target Wards. This turns base-building from "box to hide in" into territory control, and gives defense structures an actual job.

> Design rule: building is **optional but rewarded**. Never require it. Muck players who don't like building should still be able to win.

### 4.3 Crafting — forks, not tiers

Tiers still exist (they're satisfying and legible). But each tier presents a **fork**, and you can't have both cheaply.

```
Tier 2 (Iron)      →  CLEAVER  (slow, heavy, cleaves multiple enemies)
                   →  SKEWER   (fast, long reach, applies Bleed)

Tier 3 (Mithril)   →  upgrade your existing fork, or pay a heavy cost to re-fork
```

**Tool = weapon.** Your pickaxe is a real weapon. Upgrading it is simultaneously an economy decision and a combat decision. This collapses two shallow trees into one interesting one.

### 4.4 Powerups — Tags & Resonance

Powerups drop from chests (bought with coins from kills, Muck-style — that part works).

Each powerup has 1–2 **tags**: `Fire` `Blood` `Kinetic` `Fungal` `Cold` `Void`

Holding **3+ of a tag** triggers a **Resonance** — a qualitative, run-defining effect, not a stat:

| Tag | Resonance (3+) | Greater Resonance (6+) |
|---|---|---|
| Blood | Kills heal you | Kills heal the whole team, you take double damage |
| Fungal | Corpses sprout spore clouds | Spores spread to nearby enemies; you can walk in Mire safely |
| Kinetic | Sprinting builds a damage charge | Charge releases as a shockwave that knocks back and staggers |
| Fire | Attacks ignite | Ignited enemies explode, chaining |
| Cold | Attacks slow | Frozen enemies shatter for area damage |
| Void | Dodge blinks | Blinking leaves a damaging rift |

Every chest is now a decision — commit to your tag, or branch. This is the single highest-value system for replayability, and it's mostly **data, not code**: once the tag/resonance framework exists, new content is a resource file.

### 4.5 Attunements — roles without classes

At your first Wellspring cap, each player picks one. Run-scoped, not permanent.

| Attunement | Better at | Worse at |
|---|---|---|
| **Warden** | Ward radius, structure HP, taunts | Movement speed, gather rate |
| **Forager** | Gather yield & speed, food, sees resources through terrain | Melee damage |
| **Tinker** | Craft cost, station tiers, can build Ward turrets | Health pool |
| **Reaver** | Melee/ranged damage, coin drops | Takes Blight faster, can't build Wards |

Nobody is locked out of anything — you're just clearly *the best* at your thing, so the group self-organizes without a lobby role-picker.

**Additional interdependence:**
- **Heavy hauling** — high-tier ore requires 2 players to carry
- **Downed, not dead** — bleed-out state with revive, keeps people together
- **Wellspring ritual** — needs 2+ players present

> Solo play must remain possible (friends flake). Solo scales down: rituals become single-player with a longer timer, heavy hauling becomes a slow drag.

### 4.6 Meta-progression — Salvage

Every run banks **Salvage**, whether you extract or die, scaled primarily by **the Cycle you reached** and secondarily by milestones (Wellsprings capped, bosses killed, tiers reached). Extracting banks it all; dying banks a fraction (§5.2).

**Hard rule, never break it: Salvage unlocks variety, never power.**

Unlockable: new powerups in the pool, new Attunements, new POI types, new enemy types, **new Cycle Modifiers**, new island modifiers, cosmetics, new starting loadout *options* (sidegrades).

Never unlockable: +damage, +health, permanent stat boosts.

This keeps run 1 and run 100 equally fair, makes losses productive (P4), and — critically — means **the meta-progression system is a content unlock table, which is cheap to build.**

---

## 5. Run structure — endless Cycles

**There is no win condition.** The run escalates until it kills you, or until you choose to leave. The
question the game asks is *how far did you get*, and the answer is a number you can say out loud.

### 5.1 Cycles

A **Cycle** is roughly 3 in-game days (~8–12 real minutes early, stretching as runs get harder). At the
end of each Cycle, three things happen:

1. **Mire base spread rate increases**, permanently. Capped Wellsprings begin re-corrupting.
2. **A Cycle Modifier is drawn** from a deck and announced. This is the qualitative escalation that
   fixes P8 — the fight *changes*, it doesn't just get bigger.
3. **Enemy roster expands** — a new archetype enters the pool and stays.

Example Cycle Modifiers (each is a `.tres` file — cheap to author, endless variety):

| Modifier | Effect |
|---|---|
| *Long Night* | Nights last twice as long |
| *Rooted* | The Mire no longer recedes from Wards, only from Wellsprings |
| *The Hunt* | A roaming elite tracks the player with the most powerups |
| *Bloom* | Corrupted enemies split into two smaller ones on death |
| *Drought* | Resource nodes yield half until the next Wellspring cap |
| *Static* | No powerup chests this Cycle. Coins carry over doubled. |

Because modifiers stack across a run, Cycle 9 is chaotic in a way you couldn't design by hand. **This is
where endless replayability actually comes from** — not from content volume.

### 5.2 Extraction — the "one more Cycle" decision

The shipwreck from Muck returns, but its meaning is inverted. It is not how you win. It is how you
**cash out**.

- From Cycle 3, the wreck can be repaired with mid-tier resources
- Boarding it ends the run **successfully**: you bank your full Salvage, and your run is recorded at the
  Cycle you reached
- **Dying instead banks a fraction** of what you'd earned

So every Cycle you're making a real bet: leave now with a guaranteed haul, or push one more Cycle for a
significantly larger one, knowing the Mire is faster and the island is smaller than it was an hour ago.

This is the mechanic that preserves the "one evening" identity **without a timer**. There is always a
clean, satisfying, player-chosen place to stop — and choosing to stop still feels like winning.

> Design note: the reward curve for pushing deeper must be **superlinear** (Cycle 9 worth much more than
> 3× Cycle 3), or nobody ever gambles. Tune this in M6.

### 5.3 Pacing target

Difficulty is tuned so that a competent group hits a wall somewhere around **Cycle 8–12, at roughly two
to two and a half hours**. Not a hard stop — a soft wall, where the island is nearly gone and the
resource economy has collapsed. Exceptional groups push past it and that's a genuine achievement.

```
  Cycle    1    2    3    4    5    6    7    8    9   10   11   12
  Feel   ─── comfortable ───┼── contested ──┼── desperate ──┼─ the end ─
  Boat            available from here ▲
```

**Losing** = all players down simultaneously with no revive available, or the Mire consumes the island.

### 5.4 Why this is better than the three-act version

- Escalation is generated by stacking modifiers, so content scales sublinearly with replay value
- No "final boss" to build, balance, and gate everything behind — a large, risky chunk of work removed
- The natural ending is emergent (the island runs out) rather than authored
- Extraction creates the strongest tension in the design, and it's ~2 sessions of work
- **A run has a headline number**, which drives comparison, bragging, and repeat play with friends

---

## 6. Feel & moment-to-moment

**Perspective:** first-person. Viewmodel arms only — no full-body animation pipeline. (This decision saves roughly 4–6 months. See `DECISIONS.md` D-004.)

**Combat targets:**
- Chunky, readable melee: wind-up → commit → recovery. You can't cancel a swing.
- Enemies telegraph clearly (~0.4s tell) — the fix for Muck's "backpedal spam"
- Stamina gates *dodging*, not attacking (attacking-costs-stamina feels bad in co-op chaos)
- Hitstop + screenshake + a loud, satisfying impact sound on every connect

> Rule of thumb: **if hitting one enemy with one weapon doesn't feel great, do not build the second weapon.** Content built on bad feel is wasted content.

**Art direction:** flat-shaded low-poly, saturated palette, strong silhouettes, heavy fog for depth. Chosen because it's what CC0 asset packs give you for free, it hides animation weaknesses, it renders fast, and it reads clearly in first-person. The Mire is the visual contrast — desaturated, foggy, purple-black.

**Tone:** silly. Dumb item names, ragdolls, a shopkeeper who insults you. Do not write lore.

---

## 7. Explicit cut list

Not doing these. Revisit only after ship. Writing them down is what stops them from creeping in.

- Dedicated servers (host-authoritative listen server only)
- Host migration
- PvP
- Console / Steam Deck verification (Deck *compatible* is fine, verification is a process cost)
- Mod support / Steam Workshop
- Voice chat (Discord exists)
- Persistent cross-run bases
- Character customization beyond a color
- Story, cutscenes, lore
- Localization (English only at launch)
- Anti-cheat (it's co-op with friends)
- **Saving and resuming a run across sessions** — a run is one sitting. Serializing the full world
  mutation set, entity state, inventories, powerups, and the Mire grid is a large, bug-prone chunk of
  work. This is the **#1 post-launch candidate** if 2h+ runs turn out to be a problem in practice.

---

## 8. Open design questions

Resolve these *by playtesting*, not by thinking. Each has a milestone where it gets answered.

- **Q1** — Is the Mire stressful-fun or just stressful? (Answer in M4 playtest. Mitigation: tune spread rate; add safe pockets.)
- **Q2** — Does forced migration make base-building feel pointless? (Answer in M4. Mitigation: cheap portable Wards, fast rebuild.)
- **Q3** — Where's the wall? Does the difficulty curve actually produce a satisfying ~2h ceiling, or does it either wall out at Cycle 4 or never wall at all? (Answer in M6. This is the hardest tuning problem in the game.)
- **Q4** — Do Attunements create roles or resentment? (Answer in M3 playtest.)
- **Q5** — Is 6 players chaos-fun or unreadable? (Answer in M2. Might cap at 4.)
- **Q6** — Does anyone ever actually extract, or does the group always gamble until they die? If nobody extracts, the mechanic isn't doing its job — raise the reward for banking. (Answer in M6.)
- **Q7** — Do stacked Cycle Modifiers stay fun deep into a run, or do they produce unfair nonsense at Cycle 10+? (Answer in M6. Mitigation: tag modifiers as incompatible; weight the deck by Cycle.)
