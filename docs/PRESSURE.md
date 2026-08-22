# PRESSURE — why the Mire and the enemies don't land, with the numbers

**Status:** diagnosis + plan, 2026-08-22, wick410d34 (director), from Sequoyah after playing:

> *"the actual enemie and mire situation seems have assed, there doesnt seem to be any pressure and
> in terms of the mire spreading and players have to keep it back its super unclear, id like the base
> objective to be pretty simple and make sure the whole thing actually does something"*

He is right, and **the systems are not broken — they are tuned for a run three times longer than
anyone will ever play in one sitting.** Every number below is measured from the shipped constants,
not estimated.

## 1. The Mire is real, and it is far too slow to be felt

    island radius              590 m   (IslandHeightmap.ISLAND_RADIUS)
    grid cell                 4.61 m   (256 cells across 1180 m)
    spread rate            0.0120 /tick, tick = 2 s   (MireGrid.BASE_SPREAD_RATE)
    -> a cell fills in       167 s
    -> the front advances   1.66 m/min = 25 m per 15-minute Cycle

Compounding at +15% per Cycle (`CycleService.SPREAD_ESCALATION_PER_CYCLE`), total advance from the
single seed:

    Cycle  2      54 m          Cycle  8     342 m
    Cycle  4     124 m          Cycle 10     505 m
    Cycle  6     218 m          Cycle 12     722 m   <- island crossed, as DESIGN.md 4.1 promises

**The escalation curve is correct and it works — at Cycle 12.** That is **three hours** at the
shipped `day_length_seconds` of 900. A playtest is one to two hours, i.e. **Cycles 1-8**, in which the
front moves 54-342 m across an 1180 m island. And because there is exactly **one** corruption seed per
run (a deliberate design call), if it seeds on the far side the players will not encounter the Mire
*at all* during the session they are judging the game by.

**So the complaint is not "the Mire doesn't work". It is "the Mire is invisible for the entire
duration of a real play session."**

## 2. The enemies are worse, and this is the bigger cause

    ambient_enemy_population   4      over 1.09 km2  ->  one enemy per 273,000 m2
    wave_base_count            4
    wave_per_player            2      ->  8 enemies a night for two players

Four ambient enemies on the whole island means a player crosses hundreds of metres between
encounters. Eight at a night siege is not a siege. **This is the single largest contributor to "there
doesn't seem to be any pressure", and it is a one-line gamerule change to test.**

## 3. Nothing tells the player what the objective is

There are 19 guide steps including `cap_wellspring`, and `WellspringHud` exists — but there is **no
persistent indication of where the nearest uncapped Wellspring is, how much of the island is
corrupted, or that either fact is changing.** DESIGN §4.1's promise is "the run's state is visible on
the horizon; you never read a UI to know how you're doing". That works only if the horizon has
something on it. At 25 m/Cycle it does not.

## 4. The plan — smallest changes that make the loop legible

Ordered by value per unit of work. **The first three are numbers, not code.**

1. **Raise ambient enemy pressure, and tie it to corruption.** `ambient_enemy_population` 4 -> 24+,
   and weight spawn placement toward corrupted ground so pressure *rises as the Mire grows*. That
   single coupling makes the Mire legible through enemies — you feel it before you see it — and gives
   the enemies a reason to exist. `WaveSpawner` already substitutes corrupted variants by local
   corruption (`:469`), so the vocabulary is there.
2. **Seed the Mire where the players will meet it.** Guarantee the corruption seed lands within a
   bounded distance of the spawn, or start it larger. One seed 500 m away is a run with no antagonist.
   Keep exactly one seed — that is a settled design call — but do not let placement decide whether the
   game has a middle.
3. **Shorten the Cycle for playtests.** `day_length_seconds` 900 -> ~450 doubles how much escalation
   fits in an hour without retuning a single balance number. It is a gamerule, so it costs nothing
   and is reversible.
4. **Make the objective simple and always visible.** One marker to the nearest uncapped Wellspring,
   and one readable measure of how much island is left. He asked for "the base objective to be pretty
   simple" — it already is (cap Wellsprings, hold the Mire back); it is just never stated.
5. **Make capping feel like it did something.** `WELLSPRING_CLEAR_RADIUS_M` is 48 m and the spread
   drops 15% per cap — real, and currently invisible against a front nobody could see. Once (1)-(3)
   land, this reads by itself.

## 5. Combat feel — separate problem, same session

> *"the weapons dont feel like they have an impact, like when i hit something i want it to feel like
> i just hit something"*

Hitstop, shake, impact audio and damage numbers all exist (`combat_feel_check.gd` covers them), so
this is **tuning, not building**. The likely culprits, in order: hitstop duration too short to read,
no hit-flash on the target, impact sound too quiet in the mix against the ambient bed, and no
directional knockback on the victim. Wants A/B tuning against a real target dummy, and it wants
Sequoyah's ears at the end — it is a feel call and the checks cannot grade it.

## 6. What is NOT wrong

Worth stating so nobody "fixes" these: the spread maths is correct and normalised against cell size
(F-368), the escalation compounds as DESIGN §5.1 specifies, corrupted-variant substitution works, and
Blight damage on corrupted ground works. **The machinery is built. It is set to a speed nobody in a
two-hour session can perceive.**
