# GAMELOOP — the run, minute by minute

> Written 2026-08-19 (yarrow21) on Sequoyah's directive: *"plan out the game loop and gameplay."*
> This reconciles DESIGN.md's intent (§5 run structure, endless Cycles, extraction) with what has
> actually shipped, states the loop as a player experiences it, and turns every gap into a named
> task. `docs/WORLDGEN.md` is its sibling: the island this loop happens on.
>
> **Current-state refresh 2026-08-20 (ivy1bcae0, F-336).** This document presents itself as the loop
> *as shipped*, which makes a stale claim here a design inconsistency rather than harmless history.
> Four had gone stale behind the procedural and menu cutovers: the map is no longer Hollowmere, the
> enemy roster is no longer two definitions, Attunements are task 3.9 rather than 3.10, and the run
> summary is no longer missing. Each is corrected in place below and re-checked against
> `project.godot`, the `content/` registry and the roadmap's own task status rather than against the
> previous draft.

**Reading rule:** every beat below names the shipped system that carries it. A beat with a ⚠ names
a gap and the task that closes it. Nothing here is aspiration without an address.

---

## 1 · One run, as played

### Minutes 0–3 — landfall
Spawn together on the shore — the procedural spawn rule (4.15, **done**), on the generated island
`project.godot` now boots (`levels/procedural_island.tscn`). ⚠ The rule places co-op offsets against a
shared base height rather than each slot's own surface, so a party can land up to 0.37 m off its own
ground (F-345); solo landfall, collider priming and void recovery are all proven.
Nothing is hostile yet. Punch out the first fibre/wood, first tools from the hand-craft tier
(3.1 recipes), eat what's forageable (A-011's gatherables: berries — and the poison bush that
teaches you to look). The island is readable from the beach: the river mouth, the plateau, smoke or
a landmark on the skyline to walk toward (WORLDGEN §1's landmark guarantees exist for this minute).

### Minutes 3–10 — first camp
Follow the river inland. Workbench down (3.6 building, 3.1 stations), first weapon, first
palisade stakes if cautious. First crawler contact at the Blight's edge teaches the telegraph
(2.10; 0.4 s tell). **Hunger is ticking** (3.8 vitals), night is coming (2.11 DayNight) — the
first night wave (2.12) is survivable in the open but *feels* like it shouldn't be, which sells
walls.

### Minutes 10–25 — the first Wellspring
The objective marker (4.8) is visible from mid-island. Channel to cap it — 2-player ritual, solo
fallback with the longer timer (DESIGN §5) — while the defense wave (2.12 over 4.8's position
override) arrives. Capping grants the reward tier directly (D-123), pushes the Mire back locally,
and **starts the Cycle clock mattering**: capped Wellsprings re-corrode when the Cycle turns
unless Warded (6.4 + 3.6's ward pieces).

### Minutes 25–90 — the middle game: the loop proper
The repeating cycle every survival-roguelike lives or dies on, all shipped:

```
   harvest ──► craft/build ──► push a Wellspring ──► loot (chests: D-063 jackpots)
      ▲                                                        │
      │                                                        ▼
   defend (night waves, 5.9 director) ◄── Cycle turns: Mire faster, modifier drawn,
      │                                        roster grows (6.1/6.2, 5.1 enemies)
      ▼
   the island SHRINKS (4.9 Mire grid) — every trip is longer, every safe zone smaller
```

Powerups stack toward Resonance (3.3/3.4, 72 authored); Attunements split roles (3.9 — 3.10 is
heavy hauling); the wave
director scales composition with Cycle and player count (5.9). The Hunt modifier can put a boss on
someone (5.5/5.7-class). **Enemy variety is no longer the thinnest layer**: 5.2 is done and the
registry loads **5 definitions** — `crawler`, `bog_crawler`, `strider`, `tusker`, `broodcaller`. ⚠ That
is the bottom of 5.2's own 8–12 band, so the Cycle roster-growth beat reads but does not yet surprise
past the first few Cycles; the faces the deep game still lacks are the bosses (5.6–5.8, all todo).

### The decision — extract or push (from Cycle 3)
The wreck (6.5, A-009 assets) takes staged mid-tier repairs — a *visible* resource sink competing
with walls and weapons. Boarding is the all-aboard-or-cancel group vote, 60 s window. Leaving
banks full Salvage superlinearly (6.6); dying banks the fraction. This is DESIGN §5.2's "one more
Cycle" bet and it is entirely shipped — **including the ceremony**. 6.8 and MENU-7 both landed: the
run summary screen (`ui/frontend/run_summary_screen.gd`) shows the headline Cycle number, what you
drew and what you banked, for all three endings, and the `RunRecord` autoload persists the last run so
the title screen can name it. ⚠ What the scoreboard still lacks is the *per-player* rows — nothing
tallies who did what during a run (F-325), so the summary is a party result, not a post-match table.

### The end — three ways
1. **Extracted** — banked, recorded, "we left at Cycle 7" is a sentence (6.5/6.6).
2. **Wiped** — all downed/dead with no reviver = run over (6.7, D-125-adjacent: solo down IS the
   wipe), defeat screen (defeat_hud), fractional Salvage, and the same 6.8 summary — MENU-7 covers
   all three endings, proven by `tools/run_summary_check.gd`.
3. **Consumed** — the Mire took the island (6.7's island_consumed cause). The rarest and most
   dramatic; when 4.12's playtest tunes Mire pressure, this ending is the pressure made legible.

### Between runs — the meta
Salvage spends in the unlock tree (6.9) on **variety, never power** (D-009): new items, recipes,
powerups, cosmetics (hats are canon) enter future pools. Persistence is local per-player
(6.6's versioned save). Next run: new seed, new island (WORLDGEN), knowledge carries.

---

## 2 · The island IS the difficulty curve

The procedural knobs (WORLDGEN §3) are the loop's tuning knobs — this is the design insight that
makes the two plans one plan:

| Knob | Loop effect |
|---|---|
| Island bound (~200 m, D-045-informed) | run length; trip cost as Mire grows |
| Wellspring count (PoiDef budget, 4.7) | number of mid-game objectives ⇒ Cycle pacing |
| Wreck distance from spawn (4.7 priority/clearance) | how *earned* extraction feels |
| Blight/nest placement (enemy_nest markers) | where danger lives; safe-arc size at landfall |
| Mire spread base rate × Cycle (6.1 over 4.9) | the closing wall; time-to-consumed |
| River + shore shape (4.13/4.14) | navigation legibility; building sites |

**Per-seed variance within tuned bounds is the replayability engine** — DESIGN §5.4's "escalation
generated, not authored" applied to geography. 4.18's three-seed walk judged exactly this and is
done; what it produced was tuning input, and the retune it drove is what left the worldgen regression
suite stale (F-340).

---

## 3 · Gap register — every ⚠ above, as work

| Gap | Task | Size | Why it matters to the loop |
|---|---|---|---|
| Movesets / weapon forks | **5.4** | T0 ×6 | mid-game craft goals past the first weapon |
| Bosses 1–3 | **5.6–5.8** | T0 ×15 | Wellspring defense and Hunt need faces |
| Mire visuals | **4.10** | T0 ×4 | the closing wall must *read* (today it's debug tint) |
| Balance across the curve | **5.10/3.12** | T0 | 5.2 has landed, so this is now unblocked |
| Per-player run stats | **F-325** | finding | the summary has a headline but no scoreboard |
| Co-op landfall height | **F-345** | finding | six-player spawn misses its own surface by up to 0.37 m |

Closed since this document was written: **5.2** (5 enemy definitions live), **6.8** and MENU-7 (run
summary for all three endings, `RunRecord` persistence), **4.15** (procedural spawn rule), **4.16**
(map-contract parity) and **4.18** (the three-seed walk). Their ⚠ marks above are gone, not moved.

Nothing else in the loop is unowned: every other beat resolved to a shipped system with a check.

---

## 4 · The questions only playtests answer (unchanged, unblocking — D-125)

- Q1/Q2 (4.12): is the Mire *stressful-fun*; does anyone route around it on purpose?
- Q3/Q6/Q7 (6.11): where's the wall; does anyone extract; are deep modifiers fair?
- 2.14: is the whole thing fun with friends — the only verdict that matters.

Per D-125 these schedule tuning; they gate nothing. Content and cutover work above proceeds.
