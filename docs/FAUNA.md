# FAUNA — animals, and what they are for

**Status:** design spec, 2026-08-22, written by wick410d34 (director) from Sequoyah's brief:
*"we should get animals implemented as well, chickens cows, deer, birds, some atmospheric creatures,
add some fun stuff not just default animals in every game, well need to get all the work related to
animals done though, when you finish they should be part of the game loop and be spawning into the
world and have an actual purpose."*

Three requirements are load-bearing in that sentence and every decision below answers one of them:
**they spawn**, **they are in the game loop**, and **they are not the default animals every survival
game ships**.

---

## 1. Why animals, mechanically

MIRE already has three holes that fauna closes, which is the argument for building this now rather
than as decoration later.

**Cooking has no ingredients.** F-575 found `cooking_spit` and `campfire` with zero food recipes, and
F-439 found all thirteen cooked models in `assets/food/exports/` with no item def naming them. All
seven CONSUMABLE items are raw forage; `raw_meat` has no cooked counterpart. **Animals are the
missing input.** Wire fauna and the cooking half of the game has a reason to exist — one system
unlocks two.

**The bow has nothing to shoot.** Ranged weapons exist (`short_bow`, `longbow`, `crossbow`, `sling`)
and the only targets are enemies that close to melee anyway. A fleeing deer is the thing a bow is
*for*, and it is the only content that makes ranged skill legible.

**The Mire's spread is only visible as terrain.** DESIGN §4.1 says "the run's state is visible on the
horizon. You never read a UI to know how you're doing." Fauna sharpens that enormously: **animals
leave ground the Mire has taken.** A meadow that had deer in it last Cycle and has none now tells you
the corruption arrived, before the fog does. This is the highest-value reason to build them and it
costs almost nothing once they exist.

---

## 2. The roster

Ten designs. **Six are ordinary on purpose** — a spread that is all invented creatures reads as a
theme park, and the unusual ones only land against a baseline of the expected (this is the standing
"variety means a spread" rule; the new thing must never be applied to every instance).

### Ordinary — the baseline that makes the rest read

| # | Animal | Behaviour | Drops | Purpose |
|---|---|---|---|---|
| 1 | **Chicken** (bog fowl) | Skittish, short flee, never leaves its area | Raw meat ×1, Feather ×1–2 | Earliest reliable food. Cheap to kill with anything. |
| 2 | **Cow** (highland-type, shaggy) | Passive, ignores the player, slow | Raw meat ×3, Hide ×2 | Bulk food. A standing decision: kill the herd now or leave it to breed. |
| 3 | **Deer** (red deer) | Flees at long range, fast, hard to approach | Raw meat ×2, Hide ×1, Sinew ×1 | **The bow's reason to exist.** Melee-hunting one should be genuinely hard. |
| 4 | **Hare** | Very fast, erratic, short flee bursts | Raw meat ×1, Pelt ×1 | Skill-shot target; the thing you miss with a bow. |
| 5 | **Boar** | Neutral until provoked, then charges | Raw meat ×2, Hide ×1, Bone ×1 | Bridges animal and enemy. Teaches that not everything flees. |
| 6 | **Songbirds** | Flocking, flush when approached, never land near the player | None | Pure atmosphere. Their *silence* is a tell. |

### The ones that are not in every other survival game

| # | Creature | What it does | Why it earns its place |
|---|---|---|---|
| 7 | **Peat Hog** | A pig that has rooted in the bog so long it is half moss and lichen. Harmless. **Roots up buried items as it wanders** — follow it and it unearths things. | A walking loot node. Turns an animal into a *decision* (follow it or kill it — you cannot do both) rather than a meat dispenser. |
| 8 | **Fen Stilt** (bog heron) | Tall wading bird. Stands **completely motionless** in shallows, sometimes for minutes, then takes off with one enormous slow wingbeat. | Atmosphere with a startle. A player who mistakes it for scenery and walks into it will remember it. Costs one idle animation. |
| 9 | **Lantern Moths** | A drifting swarm that gathers over **uncorrupted Wellsprings after dark** and scatters when corruption reaches them. | Navigation you read from the landscape, not the HUD. Directly serves §4.1. |
| 10 | **Mire-touched variants** | Not a species — a **state**. An animal standing in corrupted ground long enough turns: gaunt, growth-covered, **red eyes**, hostile. | Ties fauna to the signature mechanic. Makes the Mire's spread personal — that was *your* herd. Red eyes are the standing rule for anything hostile in MIRE. |

**Deliberately excluded:** wolves and bears. Every survival game has them, they are just enemies with
fur, and MIRE's enemy roster already covers "thing that attacks you" with more character.

---

## 3. Placement — how they spawn

Mirrors `EnemyWorld`'s ambient field rather than inventing a second pattern.

- **Biome-weighted.** Each `AnimalDef` carries per-biome weights. Deer in `forest`/`birchwood`, cattle
  on `grassland`/`heath`, Fen Stilts on `shore`/`marsh` only, hares on `grassland`/`highland`.
- **Herds, not individuals.** A spawn places a *group* (cows 3–5, deer 2–4, chickens 4–8, hare 1).
  A lone cow in a field reads as a bug; five reads as a place.
- **A population target, topped up over time**, exactly like `ambient_enemy_population` — with its own
  gamerule so it is tunable without a rebuild.
- **Never in corrupted ground.** Corruption above a threshold removes fauna from the spawn mask; the
  animals already there flee outward, and those that cannot become Mire-touched.
- **HOST authority** for spawns, positions and drops (ARCHITECTURE §2.2). Presentation — flocking
  birds, moth swarms, idle animation — is client-local and never networked.

---

## 4. What they drop, and what that unlocks

`docs/ITEMS.md` §4.2 already specifies the creature-drop family, so **this invents nothing**: Raw Meat
(exists), Hide, Pelt, Sinew, Bone, Feather. Ships with its creature, per that section's own rule.

Downstream, and this is the point — every one of these is a hole something else is already blocked on:

- **Raw Meat → the cooking half of F-575.** `cooking_spit` and `campfire` get recipes; the thirteen
  unused food models in `assets/food/exports/` get item defs.
- **Sinew → bowstrings.** The bow tree currently costs fibre; sinew is the tier-2 reason to hunt.
- **Hide/Pelt → bindings, and the armour axis** the game does not have yet.
- **Feather → arrows.** Arrow crafting currently uses no animal input at all.

---

## 5. Build order

Each phase ships something playable. **Nothing is decoration** — if a phase would leave an asset that
nothing places, the phase is wrong (standing rule: a modelled asset nothing places is a bug).

1. **`AnimalDef` + `FaunaService`.** Content family, registry loading, biome-weighted herd placement,
   population gamerule, host authority, a headless check that boots a real procedural island and
   counts what actually spawns. **One placeholder species** so the system is provable before any art.
2. **Art batch A — the ordinary six.** Model + rig + idle/walk/flee/death per species. Research the
   real animal first and check the model against the real thing, not against the style.
3. **Flee/graze AI + drops.** Wire kills to `ItemDropService`; author the six drop items with icons.
4. **Cooking.** Recipes on `cooking_spit`/`campfire`, item defs for the existing food models. This is
   where F-575 and F-439 close.
5. **Art batch B — the four unusual ones**, plus the Mire-touched shader state.
6. **Corruption coupling.** Flee-from-corruption, the Mire-touched turn, moths over Wellsprings.

---

## 6. Open calls for Sequoyah

These are taste, not engineering, and should not be guessed:

- **Do animals breed?** A renewable herd changes hunting from extraction to husbandry, and interacts
  with the Mire eating your grazing land. Cheap to add, big design consequence.
- **Tameable?** The Peat Hog is the obvious candidate — following it is already the mechanic.
- **How hard should the deer be?** It is the bow's whole justification; too easy and the bow is
  pointless, too hard and nobody hunts.
- **Do the ordinary six look like real animals or like MIRE's stylisation?** The enemy roster is
  stylised. A photo-real cow next to a Bloatcap may read wrong.
