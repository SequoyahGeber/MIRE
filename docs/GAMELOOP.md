# GAMELOOP — the run, minute by minute

> Written 2026-08-19 (yarrow21) on Sequoyah's directive: *"plan out the game loop and gameplay."*
> This reconciles DESIGN.md's intent (§5 run structure, endless Cycles, extraction) with what has
> actually shipped, states the loop as a player experiences it, and turns every gap into a named
> task. `docs/WORLDGEN.md` is its sibling: the island this loop happens on.

**Reading rule:** every beat below names the shipped system that carries it. A beat with a ⚠ names
a gap and the task that closes it. Nothing here is aspiration without an address.

---

## 1 · One run, as played

### Minutes 0–3 — landfall
Spawn together on the shore (⚠ procedural spawn rule — 4.15; today Hollowmere's authored spawn).
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

Powerups stack toward Resonance (3.3/3.4, 72 authored); Attunements split roles (3.10); the wave
director scales composition with Cycle and player count (5.9). The Hunt modifier can put a boss on
someone (5.5/5.7-class). ⚠ **Enemy variety is the thinnest shipped layer** — 2 definitions live;
the loop needs the roster growth beat to feel real from Cycle 3 on → **5.2 (8–12 types)** is the
single highest-leverage content task in the game.

### The decision — extract or push (from Cycle 3)
The wreck (6.5, A-009 assets) takes staged mid-tier repairs — a *visible* resource sink competing
with walls and weapons. Boarding is the all-aboard-or-cancel group vote, 60 s window. Leaving
banks full Salvage superlinearly (6.6); dying banks the fraction. This is DESIGN §5.2's "one more
Cycle" bet and it is entirely shipped. ⚠ What's missing is the *ceremony*: **6.8 run summary**
(the headline Cycle number, what you drew, what you banked) — without it the bet has no scoreboard
and extraction feels like quitting. Small task, outsized payoff.

### The end — three ways
1. **Extracted** — banked, recorded, "we left at Cycle 7" is a sentence (6.5/6.6).
2. **Wiped** — all downed/dead with no reviver = run over (6.7, D-125-adjacent: solo down IS the
   wipe), defeat screen (defeat_hud), fractional Salvage, ⚠ same 6.8 summary owed here.
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
generated, not authored" applied to geography. 4.18's three-seed walk judges exactly this.

---

## 3 · Gap register — every ⚠ above, as work

| Gap | Task | Size | Why it matters to the loop |
|---|---|---|---|
| Enemy roster (2 defs live) | **5.2** | T0 ×14 | Cycle roster-growth beat is hollow without it |
| Run summary screen | **6.8** | T0 | the bet needs a scoreboard; both endings owe it |
| Procedural spawn/landfall | **4.15** | in 4.15 | minute 0–3 beat on generated islands |
| Island-feel parity | **4.16/4.18** | T1/T0 | the middle game assumes a readable island |
| Movesets / weapon forks | **5.4** | T0/T1 | mid-game craft goals past the first weapon |
| Bosses 1–3 | **5.6–5.8** | T0 | Wellspring defense and Hunt need faces |
| Mire visuals | **4.10** | T0 | the closing wall must *read* (today it's debug tint) |
| Balance across the curve | **5.10/3.12** | T0 | after 5.2 lands, not before |

Nothing else in the loop is unowned: every other beat resolved to a shipped system with a check.

---

## 4 · The questions only playtests answer (unchanged, unblocking — D-125)

- Q1/Q2 (4.12): is the Mire *stressful-fun*; does anyone route around it on purpose?
- Q3/Q6/Q7 (6.11): where's the wall; does anyone extract; are deep modifiers fair?
- 2.14: is the whole thing fun with friends — the only verdict that matters.

Per D-125 these schedule tuning; they gate nothing. Content and cutover work above proceeds.
