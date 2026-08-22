# MIRE — the enemy ladder

Task 5.11. Five authored enemies, one per escalation step, each with its **own** model, rig,
animation set, stats and one mechanic nothing else in the roster has. Written before any of them was
built so the five read as a ladder rather than five separate good ideas.

Task 5.2 already shipped five `EnemyDef`s (`crawler`, `bog_crawler`, `strider`, `tusker`,
`broodcaller`). Those are **stat variants of one model** — D-073 forbade new art on a stats task, so
all five wear `enemy_crawler.glb` under a tint. They are not deleted and not wasted: they stay as the
ambient daytime field and as the substitution targets systems already name by id
(`WaveSpawner.CORRUPTED_ENEMY_ID`, `HUNT_ELITE_ENEMY_ID`). This ladder is the *night* roster, and it
is the one the player learns.

---

## 1. The rule the ladder is built on

> **Each tier must change what the player has to DO, not what the numbers say.**

A tier that is the previous tier with more HP is not a tier. Every entry below is written as a
*verb* first, and its stats exist to serve that verb. If a design can be beaten by the same habit
that beat the tier below it, it goes back.

The second rule, from `docs/DESIGN.md` §6 and `docs/SPECS.md` §5.2's standing note: the state
machine resolves a hit at the **end** of the tell against the target's **then-current** position, so
*any* nonzero movement during a tell beats it unless the enemy is still closing ground
(`lunge_speed_m_s`, F-240). Pressure that is supposed to be un-backpedal-able must be bought with a
lunge or with a mechanic, never with a bigger `attack_range_m`.

## 2. The ladder

| Tier | Kind | Enters | The verb it adds | Its one mechanic |
|---|---|---|---|---|
| 1 | **Peatling** | Cycle 1 (night 1) | *Where* you fight starts to matter | Dies into a stain of corruption — it spreads the Mire by being killed |
| 2 | **Fen Stalker** | Cycle 2 (night 4) | You cannot stand in the open | (authored at tier 2) |
| 3 | *tier 3* | Cycle 4 (night 10) | You cannot trade hits head-on | (authored at tier 3) |
| 4 | *tier 4* | Cycle 6 (night 16) | You cannot just close the distance | (authored at tier 4) |
| 5 | *tier 5* | Cycle 8 (night 22) | The night stops being survivable by habit | (authored at tier 5) |

Tiers 2–5 are named and specified in full **in their own pass**, one at a time, each one authored and
verified before the next is designed. The verbs above are the contract those passes have to meet; the
rest is deliberately not written yet, because writing five designs at once is how you get five
variations of one design.

**Cadence.** `WaveSpawner` unlocks one entry of `roster_order` per Cycle advance and a Cycle is
`CycleService.DAYS_PER_CYCLE` = 3 nights, which would put all five in the pool by night 13. That is
faster than the ladder wants: each tier needs a few nights of being *the* new problem before the next
one lands. So `WaveSpawner.roster_unlock_stride` (this task) unlocks on every **second** Cycle
instead — tiers land on nights 4, 10, 16 and 22, about six nights apart, and tier 5 arrives inside
`DESIGN.md` §5.3's own "the wall lands around Cycle 8–12" window. The last tier *is* the wall.

Nothing is ever removed from the pool. `_roll_roster()` weights later unlocks more heavily, so a
night at Cycle 8 is mostly the top of the ladder with the bottom of it still underfoot.

---

## 3. Tier 1 — **Peatling**

> A knee-high blob of corrupted peat-slime. It is the slowest, weakest thing in the game and it is
> the reason your camp is rotting.

**The verb: *where* you fight starts to matter.** Every other enemy in a survival game is a question
about your own position. The Peatling is a question about the ground's. It cannot catch you, cannot
meaningfully hurt you, and cannot be ignored, because **killing one leaves corruption behind** — and
corruption is the one resource in this game that only ever goes the wrong way (`DESIGN.md` §4.1).
Kill six of them at your fire on night one and by night three the fire is standing in the Mire, your
trees rot, Blight ticks on you while you craft, and the ambient spawn rate at your own camp has gone
up. Nothing warns you. The lesson is supposed to arrive late and be entirely your fault.

The counterplay is real and cheap once you see it: **walk them out.** They are slower than a walk, so
you lead them off your ground and kill them somewhere you don't care about — or you kill them on
ground that is *already* corrupt, where the stain costs nothing. That is a habit the game wants the
player to build on night one, because tiers 3 and 5 are both fights you would rather not have on
ground you need.

### 3.1 The real thing it is modelled on

Not "generic RPG slime". The reference is **Physarum polycephalum**, the acellular slime mould, which
is exactly what MIRE's bog would actually grow:

- A migrating plasmodium is **fan-shaped at the leading edge** — a continuous unstructured sheet of
  protoplasm advancing — with the mass trailing behind it. It is not a ball. The silhouette has a
  front.
- Behind the fan the body organises into a **network of vein-like tubules**, thick and unbranched
  near the base, finer toward the margin. Those veins are the creature's whole visual signature.
- It moves by **shuttle streaming**: cytoplasm surges along the veins in one direction for a few
  seconds, stops, and reverses. The body visibly pulses, and the pulse *reverses* — it does not
  simply throb in and out on one beat.
- It is coated in a glycoprotein gel, so it reads wet and slightly translucent, and it is
  **yellowish** in life — which is the one thing this design overrules, because in MIRE it is a Mire
  organism and the Mire owns purple (`mire_art.PALETTE`'s standing rule: purple means corruption and
  is spent on nothing else).

Everything in §3.2 and §3.3 comes off that list. The fan front is the silhouette, the veins are the
surface detail *and* the emissive, and shuttle streaming is the idle animation and the reason the
locomotion cycle surges instead of walking.

### 3.2 The asset (`assets/enemies/exports/enemy_peatling.glb`)

- **Scale:** 0.61 m wide, 0.87 m deep, **0.32 m tall**, 462 polygons on an 8-bone rig. Deliberately
  *low and wide*, not a ball: knee
  height, so it is under the player's natural aim line and reads as ground rather than as a creature
  at the exact moment a new player is deciding whether to be afraid of it.
- **Silhouette:** a wide fan-shaped leading edge, thinning to a translucent margin; the mass swells
  behind it and drags a low tail. Flat-shaded, faceted — the gel is faceted planes catching light,
  not a smooth sphere, so it survives the game's flat-shaded look instead of fighting it.
- **Surface:** a raised vein network over the dome, thick at the base and branching thinner toward
  the fan. The veins are the emissive (`mire_glow`); the body is `mire_flesh` over `mire_black`, wet
  (low roughness), and the margin is the palest stop so the front edge catches light and the
  silhouette stays readable in fog.
- **Inclusions:** two or three undigested things suspended in the gel — a pebble, a twig, a bone
  shard. This is the detail that makes it look authored rather than generated: you can see what it
  ate, and the bone shard tells you what it eats.
- **Companions:** `enemy_peatling_fragment_gel` and `enemy_peatling_fragment_husk` for the death
  burst, matching the crawler family's existing debris convention.

### 3.3 Animation (the six clips `Enemy` drives, engine-side names)

| Clip | Length | Loops | What it does |
|---|---:|---|---|
| `idle` | 2.43 s | yes | Shuttle streaming: the mass surges forward over ~1.0 s, holds, then **reverses** back over the rest. Asymmetric on purpose — a symmetric throb reads as breathing, which is a lung, which this thing does not have. |
| `locomotion` | 1.13 s | yes | One surge cycle: the fan front extends, thins and grips; the mass flows into it; the tail releases and catches up. No feet, no bob — the whole body is the gait. |
| `attack_tell` | 0.43 s | no | It gathers. The fan retracts, the mass hauls up and back into a raised column, veins brighten as fluid is pumped into them. The tallest it ever gets — the tell is a *silhouette* change, which is what makes it readable at knee height in fog. |
| `attack` | 0.33 s | no | The column throws itself forward and flattens — a slap, not a bite. Lands wide and low. |
| `hit` | 0.33 s | no | A ripple, not a flinch: the impact point dents and the wave crosses the body. It has no skeleton to recoil with. |
| `death` | 1.23 s | no | Surface tension fails. The dome slumps, the veins go dark from the margin inward, and the whole thing spreads out flat and stops. It ends flat and still, so the corpse and the stain it leaves inherit a settled pose. |

Every clip is authored **shorter than or equal to** the `EnemyDef` window it plays under (the tell
is 0.43 s under a 0.45 s `attack_tell_seconds`, and so on). `Enemy` starts the next state on its own
timer, so a clip that outran its window would be cut mid-motion and the next clip would start from a
pose the previous one never reached — a visible pop. A clip that ends early holds its last frame,
which is invisible.

The rig is a chain of "mass" bones — no legs, no head. Rigid one-bone-per-part skinning like the
crawler (`assets/enemies/README.md`), because flat gel facets must not smear.

### 3.4 Stats (`content/enemies/peatling.tres`)

| Field | Value | Why that number |
|---|---:|---|
| `max_health` | 14 | Two hits with the starting tool, three if you miss the second. Never a threat; never free. |
| `move_speed` | 1.6 | Below player **walk** (4.0). This is the load-bearing number: you can always leave, so choosing to fight it *here* is a choice, and the mechanic punishes the choice, not the reflex. |
| `turn_speed_rad` | 2.5 | Slow to come about. Circling it works, and that is the first spacing lesson the game teaches. |
| `attack_damage` | 5 | Real but survivable at starting HP. It has to be worth not eating. |
| `attack_range_m` | 1.6 / `stop_distance_m` 1.2 | Short. It has to be close enough that its own stain lands where you were standing. |
| `attack_tell_seconds` | 0.45 | Slightly over `DESIGN.md` §6's 0.4 s. The tell is the tutorial. |
| `attack_recovery_seconds` | 0.9 | Long. Punishing the recovery is free damage — teaching that trade is the point. |
| `aggro_radius_m` | 12 / `deaggro` 20 | Short-sighted. You have to walk near it, or it is scenery. |
| `vision_angle_deg` | 360 | It has no front to see with. The fan is a mouth, not a face. |
| `alert_radius_m` | 0 | **No pack.** It never calls friends. Tier 1's pressure is the ground, not the crowd. |
| `max_concurrent_attackers` | 3 | Enough that a cluster is a real fight while you stand in it. |

### 3.5 The mechanic: the stain

New `EnemyDef` fields, consumed by `Enemy` on death (host-only, like everything else in §2.2's
"Enemies (spawn, AI, damage): HOST" row):

- `death_corruption_amount` — how much corruption to add, 0..1 per cell.
- `death_corruption_radius_m` — how wide, falling off to nothing at the edge.

Both default to 0.0, so **every existing `EnemyDef` is unaffected, bit for bit.** The Peatling sets
0.35 over **6.0 m**, and `EnemyDef.validation_errors()` rejects one of the two being set without the
other, because either alone stains nothing and does it silently.

Six metres and not three, which was the first value: a Mire grid cell is `MireGridSim.CELL_SIZE_M`
across — 4.6 m at the shipped island radius — so a three-metre stain was smaller than one cell and
its distance test missed every cell centre including its own. It landed nowhere at all, and nothing
said so. `stain_radius()` now always gives the cell the death happened in the full amount whatever
the radius, so the radius governs how far a stain REACHES and can never again govern whether it
exists; the Peatling's own six metres then covers a real neighbourhood on top of that.

It is implemented against `MireGrid.host_add_corruption()` (added by this task next to the existing
host-only `host_set_corruption_at()` debug seam) and it therefore needs **no new hazard system, no
new RPC and no new VFX**: corruption already replicates through `WorldDeltaLog`, already stains the
ground purple through `terrain_flat.gdshader`, already thickens the fog, already ticks Blight on a
player standing in it (`PlayerHealth._tick_blight()`), and already raises ambient spawns and rots
resources. The stain is *the game's own existing signature mechanic, handed to the player as a
weapon pointed the wrong way.*

It also composes correctly with everything above it: the stain feeds `WaveSpawner`'s corrupted-spawn
substitution, so a camp that farmed Peatlings starts fielding `bog_crawler`s in its own wave rolls.
And it is self-limiting — a Peatling killed on already-saturated ground costs nothing, so the
mechanic stops mattering exactly where the Mire has already won, which is the correct place for a
tier-1 mechanic to stop mattering.
