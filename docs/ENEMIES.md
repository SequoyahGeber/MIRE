# MIRE — the enemy ladder

Task 5.11. Five authored enemies, one per escalation step, each with its **own** model, rig,
animation set, stats and one mechanic nothing else in the roster has. Written before any of them was
built so the five read as a ladder rather than five separate good ideas.

Task 5.2 already shipped five `EnemyDef`s (`crawler`, `bog_crawler`, `strider`, `tusker`,
`broodcaller`). Those are **stat variants of one model** — D-073 forbade new art on a stats task, so
all five wear `enemy_crawler.glb` under a `visual_tint` and a scale. They are not deleted and not
wasted: they are the ambient daytime field and the substitution targets systems already name by id
(`WaveSpawner.CORRUPTED_ENEMY_ID`, `HUNT_ELITE_ENEMY_ID`). This ladder is the *night* roster, and it
is the one the player learns.

**F-538 — that daytime sentence was aspirational until it was fixed.** `EnemyWorld.ambient_enemy` was
a single `StringName` pinned to `crawler`, and the ambient loop is the only thing that spawns during
the day, so `strider`, `tusker` and `broodcaller` were designed, tuned, tested and then reachable
from no spawn path in the shipped game. Reported from play as "i still see old default crawlers",
which is exactly what a 100%-`crawler` day looks like. The field now rolls per body across
`ambient_variants` with `ambient_enemy` weighted to about 60% of it — a spread that keeps the
ordinary crawler the common case, rather than a uniform split that would just make every daytime
enemy a tinted special instead. Proven by section 5 of `tools/ambient_spawn_check.gd`.

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
| 2 | **Fen Stalker** | Cycle 2 (night 4) | You cannot stand in the open | Strikes *through* your retreat — the first kind in the game that lunges — and its first strike out of ambush hits far harder |
| 3 | **Bog Bulwark** | Cycle 4 (night 10) | You cannot trade hits head-on | Armoured through a 160-degree frontal arc, and it never stops following you |
| 4 | **Bloatcap** | Cycle 6 (night 16) | You cannot just close the distance | An area burst that ignores facing and dodging entirely — and it bursts again when it dies |
| 5 | **Mire Herald** | Cycle 8 (night 22) | The night stops being survivable by habit | It corrupts the ground it walks on, continuously, without having to die — so every habit made of time and distance is now paid for in land |

All five are now authored — each one designed, built, verified and committed before the next was
begun, because writing five designs at once is how you get five variations of one design. Each has
its own generator in `tools/blender/`, its own headless check in `tools/`, and its own `.tres` in
`content/enemies/`.

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


---

## 4. Tier 2 — **Fen Stalker**

> Two metres of corrupted wading bird, standing motionless in the reeds with its bill in the air. You
> walked past three of them on the way here.

**The verb: you cannot stand in the open.** Tier 1 could always be walked away from, and that was the
point — it made the *ground* the question. The Stalker takes walking away off the table. It moves at
4.8 m/s, faster than your walk (4.0) and slower than your sprint (6.0), so leaving is still possible
but it now costs stamina and a decision. And it is the first enemy in the game that **closes ground
during its own telegraph** (`lunge_speed_m_s`, the field F-240 built and nothing has ever used), so
the habit every player forms against the crawler and the Peatling — *see the tell, take one step
back, watch it whiff* — stops working on night four. `docs/SPECS.md` §5.2 is explicit that this
pressure cannot be bought with a bigger `attack_range_m`; it has to be a lunge. This is the lunge.

The counterplay is not "back up further", it is **turn**. Its neck is a spear and a spear has one
direction: `turn_speed_rad` is 3.2, roughly half the crawler's, so a player who circles instead of
retreating gets behind the strike. And its vision is a 120-degree cone with a real blind side, so a
player who sees it first can walk around it entirely — which is the whole reason the freeze reads as
scenery rather than as a bug.

### 4.1 The real thing it is modelled on

Grey herons and bitterns — specifically the machinery that makes them ambush predators:

- **The legs are nearly half the total height.** That proportion is the whole silhouette; it is why a
  heron reads as a heron from a kilometre away and why this creature reads as *not the last one* the
  instant it enters the pool.
- **The neck is a spring, not a limb.** 20–21 cervical vertebrae with a modified sixth that lets the
  neck fold into a mid-cervical Z-bend; the bird stands with the neck drawn down onto the body,
  waits, and then the retracted neck springs forward and drives a dagger bill at the target. **The
  real animal's hunting anatomy is already a telegraph and a strike, authored by evolution.** The
  tell coils, the attack fires; nothing about that had to be invented.
- **Bitterns freeze.** Camouflage and concealment in the reeds, a motionless posture with the bill
  pointed straight up, holding it until the threat leaves. Which is the idle clip: this creature's
  idle is *near-total stillness*, the opposite of every other idle in the game.
- Stand-and-wait alternating with slow stalking is the documented feeding behaviour, so "does not
  wander, then covers ground fast" is not a game concession — it is what the animal does.

### 4.2 The mechanic: the ambush strike

`EnemyDef.ambush_damage_multiplier` (new, default **1.0** — so no existing kind changes). The **first
attack an enemy makes after acquiring a target out of IDLE** is multiplied by it. The Stalker sets
2.0: 12 damage becomes 24, which at night-four gear is most of a health bar in one hit from something
you thought was a reed.

It exists because the freeze needs *teeth* to be a mechanic rather than a flavour. A creature that
stands still and then attacks normally is just an enemy with a quiet idle; a creature whose stillness
is how it earns its opening shot is an enemy that changes how you cross open ground — you start
looking, and looking costs time, and time is what the Mire eats. It spends itself on use: after the
first strike the Stalker is an ordinary, fast, long-reached melee enemy, so the pressure is front-
loaded onto the moment of being surprised and does not turn the whole fight into a damage check.

Host-only, like every other decision in `Enemy`, and replicated by nothing — the damage number
already travels the way every other damage number does.

### 4.3 The asset (`assets/enemies/exports/enemy_fen_stalker.glb`)

0.45 m wide, 1.22 m deep (most of that the bill), **1.94 m tall** — it looks *down* at you — 520
polygons on a 19-bone rig. The proportions are the design: the hip sits at 1.12 m, so the legs are
53% of the height, which is the heron proportion and the whole reason the silhouette works. Tier 1
is a blob under your aim line; tier 2 stands over your head on stilts, and the two can never be
confused at a glance in fog.

The palette is deliberately **cold and almost disjoint from tier 1's**: `fish_scale` — the world's
only cool natural colour and exactly a heron's flank — over `stone_dark`, with a `fish_belly` throat
and a `bone` dagger of a bill that is the brightest thing on the creature and also its aim point. The
Mire appears only as `mire_glow` at the neck joints and two crystal growths on the mantle: enough to
say whose creature this is, never enough to make it the Peatling's cousin. The one warm note is the
`eye` token the crawler already owns.

The rig's neck is **three bones plus a head and a bill**, and that is not decoration — two bones can
only make a V, and a V reads as a broken neck. The ankle is placed *behind* the knee, because a
bird's visible backward-bending joint is its ankle; getting that wrong is the single most common way
a bird model reads as a lizard on stilts.

| Clip | Length | Loops | What it does |
|---|---:|---|---|
| `idle` | 3.00 s | yes | **The freeze.** Bill straight up, neck folded onto the shoulders, and over three seconds a two-degree weight shift and one slow head roll. The least animated clip in the game, on purpose. |
| `locomotion` | 0.90 s | yes | The stalk: high deliberate knee lift, a body that stays perfectly level, and the head counter-bobbing against the stride at twice its frequency. |
| `attack_tell` | 0.50 s | no | The spring loads. The neck folds to its tightest, the head drops and pulls *back*, the body tips forward over the feet. It gets **shorter** as it winds up — nothing else in the roster does. |
| `attack` | 0.23 s | no | The spring releases. Every neck segment turns the same way, which takes the S out and lays the whole chain along one forward line, driving the bill out at chest height. Coiled to extended in 0.1 s. |
| `hit` | 0.30 s | no | A bird's startle: wings off the body, head snapped away and up. Legible from directly behind — the angle a player circling to its blind side is standing at. |
| `death` | 1.43 s | no | **The legs go first.** It does not topple like a statue, it folds: ankles buckle, body drops straight down onto them, and only then does it fall sideways. The neck comes down last, in a slack curl. |

Companions: `enemy_fen_stalker_fragment_plume` (a torn clump of flank feathers with one glowing
quill) and `enemy_fen_stalker_fragment_bill` — the bill, snapped off with a piece of skull attached.
The second is the only debris piece in the game that is a *weapon lying on the ground*, and it is the
same dagger that was pointed at the player thirty seconds earlier.

### 4.4 Stats (`content/enemies/fen_stalker.tres`)

| Field | Value | Why that number |
|---|---:|---|
| `max_health` | 28 | Twice the Peatling. Still not a sponge — the threat is its opener, not its stamina. |
| `move_speed` | 4.8 | **The load-bearing number.** Between player walk (4.0) and sprint (6.0): walking away fails, sprinting works and costs stamina. `tools/enemy_fen_stalker_check.gd` asserts the band, so a balance pass cannot quietly move it out of it. |
| `turn_speed_rad` | 3.2 | Roughly half the crawler's. Circling beats it; backing up does not. |
| `lunge_speed_m_s` | 3.4 | Closes ground **during its own tell**. The first content in the project to use F-240's field. |
| `attack_range_m` | 3.2 | Its reach is the neck. A distance that is safe from a crawler is inside this thing's strike. |
| `attack_damage` | 12, ×2.0 on the opener | 24 out of ambush is most of a night-four health bar in one hit from something you thought was a reed. |
| `attack_tell_seconds` | 0.5 | Longer than `DESIGN.md` §6's 0.4 s baseline, and the one thing the design gives back: the strike is 0.23 s, reaches 3.2 m and closes while the tell runs. Half a second is what makes it fair. |
| `attack_recovery_seconds` | 1.1 | Long. The neck has to re-coil, and that is the window you take it in. |
| `aggro_radius_m` | 24 / `deaggro` 32 | It sees a long way. It was watching you before you saw it. |
| `vision_angle_deg` | 120 | A real blind side. Spot it first and you can walk around it entirely. |
| `alert_radius_m` | 14 | It calls. Tier 1 never did — this is where "a pack" starts. |
| `max_concurrent_attackers` | 2 | Two at a time commit; the rest circle. A wall of simultaneous 3.2 m strikes is not a fight. |


---

## 5. Tier 3 — **Bog Bulwark**

> Three metres of armoured shell on four short legs, lying in the shallows with its jaws open and a
> pale green light glowing somewhere inside them.

**The verb: you cannot trade hits head-on.** Tiers 1 and 2 were both, in the end, answerable by one
player doing the right thing. This one is not. Its front 160 degrees are armour: hits from inside
that arc land for **30% of their damage and do not even make it flinch**. Everything you know about
fighting works, and works *four times too slowly*, and it keeps coming.

And it does keep coming. `deaggro_radius_m` is 120 m — effectively the whole island — so leaving,
which was the correct answer to the Peatling and a viable one against the Stalker, only postpones it.
A Bulwark that acquired you at dusk is still walking toward you at dawn.

The counterplay is **position, and preferably a second player**. It turns at 1.4 rad/s, less than a
third of the Stalker's, so somebody standing in front of it holding its attention buys somebody else
all the time in the world to get behind it and hit an unarmoured back for full. That is `DESIGN.md`
§P3 — roles without classes — falling out of one enemy's geometry rather than out of a class system.
Solo it is not unwinnable, just slow and expensive: circle-strafe, hit, back off the 1.6 s recovery,
repeat.

**How you find out.** There is no armour meter and there is not going to be one. A deflected hit
simply produces *nothing* — no hit flash, no flinch, no reaction of any kind — where an unarmoured
hit produces all three. "I hit it and it ignored me" is a sentence players read correctly and
immediately, and it costs no new networked state to say it.

### 5.1 The real thing it is modelled on

The alligator snapping turtle, *Macrochelys temminckii*. Four facts, and the third is the tier:

- The carapace carries **three keels** — one down the centre line and one either side — formed by
  pyramid-shaped elevations of the vertebral and pleural scutes, running front to back and carrying
  prominent spikes. That is the silhouette, and without it the creature is a boulder with legs.
- The head ends in a **sharp hooked beak** whose upper jaw works as a *cleaver* against the lower.
  Shearing, not biting — so the strike is a snap that closes, and the tell is the jaws opening.
- **The plastron is small and affords little protection to the underside.** A fact about the animal,
  not a concession to the game, and the entire origin of `armor_arc_degrees`: this thing is a wall
  from the front and soft everywhere else.
- It **fishes**. It lies with its jaws open and wiggles a worm-like lure on its tongue until
  something swims in. So the one emissive on the creature is *bait* rather than corruption — a warm
  `glowcap` green that no other enemy in the roster owns — and it is only visible when the mouth is
  open, which is the idle and the tell and nothing else.

Its vertebrae are also fused to its shell, which is why the rig has **no spine chain at all** and why
its `hit` clip is a shudder rather than a recoil. There is nothing in the middle of it that bends.

### 5.2 The mechanic: directional armour

Two new `EnemyDef` fields, both defaulting to "no armour", so nothing authored before the ladder
changes by a byte:

- `armor_arc_degrees` — the arc, centred on the enemy's own facing, that is armoured. 0.0 = none.
- `armor_damage_multiplier` — what a hit inside it is multiplied by. Never 0: a hit that does
  literally nothing reads as a bug, and it would make a solo fight unwinnable rather than merely
  expensive.

Expressed as an **arc** rather than as a flat resistance on purpose. A flat 70% reduction is a health
bar with more numbers in it. A 160-degree frontal arc is a *question about where you are standing*,
and in co-op it is a question two people can answer better than one.

The direction comes from the **instigator's own position at the moment the damage lands**, which
means it works for melee today and will work unchanged for a projectile whose instigator is the
shooter. It is measured against the *body's* facing, not the visual's — the visual can carry a
`model_yaw_offset_degrees` that exists only to correct an exporter's idea of forward (F-039). And it
**fails open** at every step: no armour authored, no instigator, no locatable player, or an attacker
standing exactly on top of it all leave the damage unreduced. Armour must never be able to silently
nullify a damage source it was not designed against.

### 5.3 The asset (`assets/enemies/exports/enemy_bog_bulwark.glb`)

1.96 m wide, **3.03 m long**, 1.18 m tall, 721 polygons on a 20-bone rig — by a distance the largest
thing in the roster, and the first that is wider than a doorway. The palette is the third distinct
one on the ladder: `peat` and `wood_charred` over a `bone` plastron, where tier 1 is purple gel and
tier 2 is cold grey plumage. The soft parts — head, neck, legs, tail — are deliberately a *mid* grey
(`mire_dormant`) rather than the shell's near-black, because on a creature whose whole fight is about
which end of it you are standing at, the end with the jaws on it has to be findable.

The Mire's mark is two crystal growths, and they are on the **rear** keel: the one glowing thing on
its armour is also the thing that tells you you are standing in the right place.

| Clip | Length | Loops | What it does |
|---|---:|---|---|
| `idle` | 3.00 s | yes | **It is fishing.** Sat low with the jaws open and the lure showing. An open mouth with a light in it, at knee height, in fog — and it is not a threat display, it is an invitation. |
| `locomotion` | 1.40 s | yes | The plod. Diagonal pairs, and it *rocks*: a shell on four short legs cannot help rolling onto whichever pair is planted, and the roll is most of what sells the mass. |
| `attack_tell` | 0.60 s | no | The longest telegraph in the roster, and it has to be. What you read is the head **disappearing** — the neck hauls back until the skull is inside the shell's own shadow, and the lure goes out with it. |
| `attack` | 0.40 s | no | The snap. The neck fires the head out along a line and the jaws shear shut *before* full extension, which is what makes it a bite rather than a headbutt. |
| `hit` | 0.30 s | no | It barely notices — deliberately the weakest reaction in the game. And a *deflected* hit does not play it at all. |
| `death` | 1.60 s | no | One last gape at nothing, then the legs go out sideways and the whole mass settles onto the plastron with the head lying out in front of it: the one thing it never let anybody see while it was alive. |

Companions: `enemy_bog_bulwark_fragment_scute` (a keel plate cracked off with its spike still on it)
and `enemy_bog_bulwark_fragment_beak` — the hooked beak, **with the lure still faintly lit behind
it**. The thing that was pretending to be food, lying on the ground next to the thing it was
attached to.

### 5.4 Stats (`content/enemies/bog_bulwark.tres`)

| Field | Value | Why that number |
|---|---:|---|
| `max_health` | 120 | Four times the Stalker — but the armour is what makes it feel like twelve, and only from the wrong side. |
| `armor_arc_degrees` / `_multiplier` | 160° / 0.30 | Wide enough that "in front of it" is a real place to be standing by accident; not 180, so the sides are already better than the front. |
| `move_speed` | 2.2 | Slower than a walk. It is not going to catch you — it is going to *arrive*. |
| `deaggro_radius_m` | 120 | It never lets go. Slow is only fair if leaving does not solve it. |
| `turn_speed_rad` | 1.4 | Less than a third of the Stalker's. This number is the counterplay. |
| `attack_damage` | 26 | The heaviest hit on the ladder. Standing in front of it is not survivable for long even when you *are* hurting it. |
| `attack_tell_seconds` | 0.6 | The longest telegraph in the game, paid for by the damage and the lunge behind it. |
| `lunge_speed_m_s` | 5.0 | Faster than it walks, by a lot. A creature that shuffles and then *explodes* forward is the actual animal. |
| `attack_recovery_seconds` | 1.6 | The window. Every rung of the ladder has one; this one's is the widest, and it is where the fight is won. |
| `alert_radius_m` | 0 | It calls nobody. It does not need to. |
| `max_concurrent_attackers` | 1 | Only one commits at a time — two simultaneous 26-damage snaps is not a fight, it is a coin flip. |


---

## 6. Tier 4 — **Bloatcap**

> A pale, swollen, spine-covered sac on four root legs, a ring of small red eyes around its middle,
> and a slow purple light pulsing out of a hole in the top of it.

**The verb: you cannot just close the distance.** Every rung so far has ultimately been answered by
walking up to the thing and hitting it — the Peatling somewhere harmless, the Stalker after circling
it, the Bulwark from behind. Against a burst that is the losing move. There is no facing to get
behind and no swing to step around; there is only a **distance**, and if you are inside 4.5 m when
the sac empties you take all 18 of it whether you were its target or not.

And **killing it does not save you**. It bursts again on death for 55%, so the melee answer —
"telegraph is long, I'll just kill it during the wind-up" — costs you ten damage for the privilege.

The counterplay is the one thing the game has been quietly handing players since tier 2 and which
nothing has previously *required*: **shoot it**. The sling, the longbow and the crossbow all ship
(`content/ranged_weapons/`), and this is the enemy that makes a player actually build one. That is
what a tier-4 rung should do — not add a number, but cash in a system the run has been carrying
unused.

Failing that, the tell is 0.7 s, the longest telegraph in the game, and it is enormous: the whole
creature inflates by a third. You *can* outrun it. You just have to start when it starts.

### 6.1 The real thing it is modelled on

Puffball fungi, *Lycoperdon*. Four facts, and the third is the whole fight:

- The fruit body is **pear-shaped with a flattened top and a stem-like base** — not the sphere
  people draw. The flattening is load-bearing, because it is where the ostiole has to sit.
- The surface is covered in **short cone-shaped spines interspersed with granular warts**, which rub
  off and leave pock marks. On a pale sac at night that texture is the only thing giving the
  silhouette any form at all.
- There is a pre-formed hole in the top — the **ostiole** — and the spores leave through it when the
  body is compressed, **ejected at around a metre per second, forming a visible cloud within a
  hundredth of a second**. So this creature's strike is not a swing, it is a *deflation*, and it is
  over before the eye finishes reading it. The tell is the sac filling; the attack is it emptying.
- The **gleba**, the spore mass inside, is white and firm in a young puffball and brown and powdery
  in a mature one. In a corrupted one it is purple and lit, and it is visible through the dilating
  ostiole — which is how a player reads how close this thing is to going off.

### 6.2 The mechanic: the burst

Two new `EnemyDef` fields, both defaulting to "no burst", so nothing authored before it changes:

- `burst_radius_m` — above 0.0, this kind's attack stops being single-target and becomes an **area**
  hit centred on the enemy: every player inside the radius takes `attack_damage`, target or not.
- `death_burst_fraction` — what fraction of the same damage the same radius takes when it **dies**.

Both go out through the *same* `EventBus` event a single-target hit uses, once per player, so
`PlayerHealth` needed no change and dodge i-frames, Blight, downed state and every other consumer
treat a burst hit exactly like any other hit. That is the point of having one seam.

Measured **horizontally**, like every other distance decision in `Enemy`: a burst you escape by
standing on a rock is a burst nobody can reason about. And the burst is reached only *after* the
range check, so a Bloatcap still has to commit to a target in reach before it goes off — the burst is
what its attack does, not a replacement for deciding to attack.

The death burst fires after `_maybe_bloom_split()` and `_stain_ground()`, which means a bloomed
Bloatcap under the `bloom` Cycle Modifier costs the ground **three** bursts. That falls out of the
ordering rather than needing a rule, and it is the correct reading of two modifiers stacking.

### 6.3 The asset (`assets/enemies/exports/enemy_bloatcap.glb`)

1.38 m across and **1.22 m tall** — chest height, and by far the widest silhouette per metre of
height in the roster. 592 polygons on a 12-bone rig, of which the one that matters is `sac`: it
carries almost the whole creature and does almost all of its acting through **scale**.

This is the ladder's first **pale** creature. Tier 1 is purple gel, tier 2 cold grey plumage, tier 3
near-black peat; this is a bloated off-white sac, which is both what a puffball actually looks like
and the single most visible thing in a night wave. That visibility is deliberate — a Bloatcap is
meant to be seen early and dealt with from range, so one you failed to notice is a *mistake* rather
than an ambush.

It has **no front**: no face, no limbs to lead with, and a ring of seven small red eyes around its
middle instead of a pair. `vision_angle_deg` is 360 because that is an accurate description of the
model rather than a shortcut, and `tools/enemy_bloatcap_check.gd` asserts the model really is
symmetric so the two cannot drift apart.

| Clip | Length | Loops | What it does |
|---|---:|---|---|
| `idle` | 3.00 s | yes | Slow asymmetric breathing — a long fill, a quicker release, with the ostiole's light brightening and dimming through it. From across a clearing a Bloatcap is a slow purple pulse at chest height, which is how you are supposed to find one. |
| `locomotion` | 1.00 s | yes | The waddle. Diagonal pairs, and the sac **lags** the legs — it is a bag of gas balanced on a stem, so it arrives a beat late and rocks past centre before it settles. |
| `attack_tell` | 0.70 s | no | **It swells.** The longest telegraph in the game and it needs every frame: the sac inflates by a third, the creature rises onto its legs, and the ostiole dilates until the gleba is a hole full of light. Nothing else in the roster gets *bigger* as it winds up. |
| `attack` | 0.30 s | no | It vents. Two frames after the extreme the sac has collapsed past its own resting size and the ostiole is gaping. |
| `hit` | 0.30 s | no | A dent that crosses the skin. Explicitly not a flinch backwards — that would imply somewhere to flinch to. |
| `death` | 1.40 s | no | One last involuntary swell — the reflex that makes killing one in melee a mistake — then it tears, empties, and slumps into a sagging bag on a stem that can no longer hold it up. Ends as an empty husk with the ostiole gaping and the gleba dark. |

Companions: `enemy_bloatcap_fragment_husk` (torn skin with the warts still on the outside) and
`enemy_bloatcap_fragment_gleba` — a clot of the spore mass, still lit, in a scrap of the ostiole. A
player who has been caught by one burst and then finds that on the ground has been told exactly what
happened to them.

### 6.4 Stats (`content/enemies/bloatcap.tres`)

| Field | Value | Why that number |
|---|---:|---|
| `max_health` | 40 | Soft. It is a bomb, not a wall — the Bulwark is the wall. |
| `burst_radius_m` | 4.5 | Wider than any melee reach in the game, so "back off a bit" is not enough; you have to actually leave. |
| `attack_damage` | 18 | Serious but not lethal from full, so the first one teaches instead of killing. |
| `death_burst_fraction` | 0.55 | Ten damage for killing it at your feet. Enough to be a real cost, not enough to make melee suicide. |
| `attack_range_m` | 4.0 | Deliberately **inside** `burst_radius_m`, so a committed burst always reaches whoever it committed against. |
| `attack_tell_seconds` | 0.7 | The longest in the game. A burst does not care which way you dodge, only how far you got, so the warning has to cover the distance. |
| `move_speed` | 3.0 | Below a walk. It cannot chase you out of its own radius, and that is the entire reason 4.5 m is survivable. |
| `alert_radius_m` | 18 | Wide. Two Bloatcaps that go off together cover 9 m, and there is no answer to that but not being there. |
| `max_concurrent_attackers` | 3 | They *do* stack. This is the rung where a night stops being a series of fights and becomes a problem of spacing. |
| `vision_angle_deg` | 360 | It has no front. See §6.3. |


---

## 7. Tier 5 — **Mire Herald**

> A giant deer the colour of the peat it came out of, three and a half metres of pale palmate antler
> above a body with its ribs showing, and the Mire growing on the crown like frost.

**The verb: the night stops being survivable by habit.** Look at what the ladder has taught by now.
Walk the Peatling off your ground. Circle the Stalker instead of retreating. Get behind the Bulwark.
Back out of the Bloatcap's radius. **Every one of those answers is made of time and distance** — and
against the Herald both are paid for in *land*, because the ground it stands on corrupts while it
stands there, and the ground it walks over corrupts as it passes.

Kiting it across your own territory is how you lose the territory. Ignoring it is how you lose the
territory faster, because it does not need you: it corrupts an empty field just as well. There is no
version of this fight where the answer is "later".

And it is genuinely dangerous while you are solving that: 260 health, 34 damage through a four-metre
antler sweep, and an alert radius of 34 m, which means a Herald arriving does not arrive alone — it
wakes everything between it and you.

**It is the wall.** It enters at Cycle 8, inside `DESIGN.md` §5.3's own "the wall lands around Cycle
8–12" window, and that is not a coincidence: the top of the ladder is supposed to be the thing that
ends runs.

### 7.1 The real thing it is modelled on

*Megaloceros giganteus*, the Irish elk — a giant deer whose best-preserved remains come out of **peat
bogs**, which is not a coincidence this project was going to pass up either.

- The antlers are **palmate**: flattened palms with points along the outer edge, not a branching
  tree. They span up to **3.5 m** and weigh about 40 kg. Ours measures 3.36 m tip to tip, and
  `tools/enemy_mire_herald_check.gd` asserts the span, because if a future tweak quietly costs it
  that number it has stopped being the thing this rung is for.
- The shoulder stands around **2.1 m** and head-to-body runs over three metres.
- The skull is extra thick and the neck vertebrae unusually sturdy — both adaptations for carrying
  the rack, and both worth reading as *mass* in the model.
- The vertebrae over the shoulders are **elongated**, forming a hump of muscle whose job is holding
  those antlers off the ground. **The hump is the anatomical reason the antlers are allowed to
  exist**, and a model without it wears its rack like a hat.

### 7.2 The mechanic: the aura

Two new `EnemyDef` fields, both defaulting to "no aura":

- `aura_corruption_per_second` — how much corruption it adds to the Mire grid around itself, per
  second, while alive.
- `aura_corruption_radius_m` — how far, falling off to nothing at the edge.

It runs on a 1 s interval from `Enemy._physics_process` — **outside the state machine**, which is the
whole point. This is not something the creature does while chasing or attacking; it is something it
does while *existing*, including standing in an empty field with nobody within a hundred metres. A
Herald nobody is fighting is still eating the island. (The first implementation put the tick inside
`_tick_attack()`, where it only ran during TELL/ATTACK/RECOVER, and an idle Herald corrupted nothing
at all — the tier's entire mechanic was invisible.)

It is the **same `MireGrid.host_add_corruption()` seam the tier-1 Peatling's death stain uses**. That
is deliberate and it is the ladder's bookend: rung one corrupts a patch of ground by dying, rung five
does not have to die and does not stop. The check asserts both still share that seam, because if they
ever stop, the ladder has stopped being a ladder.

A corpse stops corrupting. The aura is what the creature *does*, not what its body is — and a
carcass that kept eating the island for its eight-second corpse timer would be a bug that read as a
mechanic.

### 7.3 The asset (`assets/enemies/exports/enemy_mire_herald.glb`)

**3.36 m across the antlers, 3.10 m long, 2.73 m tall.** 688 polygons on a 20-bone rig. The largest
thing in the game by a wide margin, and it is meant to be the moment a player stops thinking about
this night and starts thinking about the run.

Its preview is shot nearly head-on, unlike every other family's three-quarter view, because this
creature's whole read is the **span** and a three-quarter shot foreshortens one palm into its own
shoulders. Its palette closes the loop the ladder opened: `peat` hide over `wood_charred` shadow with
`bone` ribs and hooves showing through, pale antlers that are the brightest thing on it from any
distance, and the Mire's purple as crystal on the antler palms and nowhere else. The corruption is
wearing the crown — and it is the same purple the creature leaves on the ground behind it.

| Clip | Length | Loops | What it does |
|---|---:|---|---|
| `idle` | 3.53 s | yes | It breathes, and the rack moves like weather. Every other idle in the roster is a creature waiting; this is a creature that has never once needed to hurry. A few degrees of head sway is an enormous amount of movement at three and a half metres of span. |
| `locomotion` | 1.60 s | yes | A four-beat walk — three feet down at all times, back-left, front-left, back-right, front-right. The body pitches nose-to-tail rather than rolling, because the mass is high and forward over the hump. |
| `attack_tell` | 0.63 s | no | **It raises the crown.** Head up and back until the palms are above its own shoulders, forelegs planted, weight loaded onto the hind pair. The largest silhouette change in the game — a Herald winding up is readable by somebody who is not even in the fight. |
| `attack` | 0.47 s | no | The sweep. It drives the rack down and across in one motion; a real deer's antler strike is a shove of the whole *body* through the neck, never a swing of the head, so the spine leads and the palms scythe through the space in front of its forelegs. |
| `hit` | 0.30 s | no | It does not stagger. It **looks at you** — the head lifts and turns toward the hit, which at this size is a threat rather than a flinch. |
| `death` | 2.00 s | no | The longest death in the game and it earns it. The front legs go first, as they always do on a heavy-headed animal, so the chest comes down and the rack drives into the ground ahead of it; only then does the back fold and the whole length roll onto its side. The head is last, and slow, because there is nothing left holding it up. |

Companions: `enemy_mire_herald_fragment_antler` — a broken palm with two points and a crystal still
growing on it, nearly a metre across, and the only debris piece in the roster a player would want to
*keep* — and `enemy_mire_herald_fragment_hide`, sodden hide and a length of rib, the way a bog gives
a body back.

### 7.4 Stats (`content/enemies/mire_herald.tres`)

| Field | Value | Why that number |
|---|---:|---|
| `max_health` | 260 | The deepest pool in the roster. It is not armoured — that is tier 3 — it is simply an enormous amount of animal. |
| `aura_corruption_per_second` | 0.05 over 9 m | Slow enough that one Herald is a problem rather than a disaster, and fast enough that ignoring it for a night is not a plan. |
| `attack_damage` | 34 | The heaviest hit in the game, through a 4.2 m sweep. |
| `move_speed` | 2.9 | Below a walk. It does not need to catch you — everywhere it goes is worse afterwards. |
| `lunge_speed_m_s` | 4.0 | It still closes during its own tell. Slow does not mean safe to stand near. |
| `alert_radius_m` | 34 | The widest in the roster. A Herald arriving brings the night with it. |
| `deaggro_radius_m` | 80 | It gives up eventually — unlike the Bulwark — because a Herald that follows you forever is a Herald whose aura follows you forever, and that is not a fight, it is an eviction. |
| `max_concurrent_attackers` | 1 | There is only ever going to be one of these committing at a time. That is mercy, and it is the only mercy in the row. |

---

## 8. The ladder, finished

| Tier | Kind | Model | Rig | Polys | Bounty | Its mechanic |
|---|---|---|---|---:|---:|---|
| 1 | Peatling | slime mould | 8 bones | 502 | 3–7 | Dies into a stain of corruption |
| 2 | Fen Stalker | heron / bittern | 19 bones | 578 | 8–14 | Lunges through your retreat; doubled opener out of ambush |
| 3 | Bog Bulwark | snapping turtle | 20 bones | 721 | 18–30 | 160° of frontal armour, and it never lets go |
| 4 | Bloatcap | puffball | 12 bones | 592 | 32–48 | Area burst, and it bursts again when it dies |
| 5 | Mire Herald | Irish elk | 20 bones | 688 | 55–90 | Corrupts the ground it walks on, without dying and without stopping |

**The bounty column is a pay scale, not flavour** (F-539/D-210). Killing one of these pays coins to
whoever landed the blow, rolled in the range its `.tres` authors on `EnemyDef.coin_drop_min`/
`coin_drop_max`. Every rung's floor sits above the rung below's ceiling, so climbing the ladder
always pays better than farming the bottom of it — priced against a ~25-coin Bog Chest and a
~60-coin Strongbox, and against the off-ladder kinds (Marsh Strider 1–3, Hollow Crawler 2–4,
Broodcaller 2–5, Bog Crawler 3–6, Mire Tusker 12–20). The values are authored per kind rather than
derived from health: a Bulwark is a long fight because of its armour and a Bloatcap is a short one
that costs you a burst, and only authoring prices that. `tools/kill_bounty_check.gd` asserts the
ordering, which is the property a balance pass breaks silently.

Six new `EnemyDef` mechanics, every one of them defaulting to off, so the five kinds task 5.2
authored are unchanged byte for byte. Five generators, five headless checks, five real animals
researched before anything was modelled. Each rung changes what the player has to *do*; none of them
is the rung below it with more health.
