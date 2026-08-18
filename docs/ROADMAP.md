# MIRE — Roadmap

Estimates are in **sessions** (≈3 focused hours). Calendar time is deliberately not used — it means
nothing with a variable schedule.

Every task is tagged with its tier from `AI-WORKFLOW.md`:

- **`[T0]`** — you, in the Godot editor. **Free.** No quota.
- **`[T1]`** — cheap agent (Codex / second Claude). Well-specified, self-contained.
- **`[T2]`** — premium quota. Reasoning other code depends on.

**Per-task execution specs live in [`SPECS.md`](SPECS.md).** A lane or agent given a task id reads
its spec there and should need zero exploration; the director's work orders point at it. If a task's
spec is missing or stale, fixing the spec is part of the task.

---

## Budget at a glance

Recomputed 2026-08-17 by summing the actual task rows below (the previous table understated M2 by
45 sessions after the authored-art program landed there — see the note under M2). If rows change,
re-sum; this table is derived, not authoritative.

| Milestone | Sessions | T0 (free) | T1 (cheap) | T2 (premium) |
|---|---:|---:|---:|---:|
| M0 · Foundations & spikes | 14.5 | 42% | 28% | 30% |
| M1 · Network spine | 23.5 | 13% | 4% | **83%** |
| M2 · Vertical slice ⭐ | 80 | 68% | 12% | 20% |
| M3 · Systems depth | 64.5 | 39% | 22% | 40% |
| M4 · World & the Mire | 47 | 14% | 13% | **73%** |
| M5 · Combat, enemies, bosses | 55 | 69% | 5% | 25% |
| M6 · Cycles, extraction & meta | 37 | 46% | 19% | 35% |
| M7 · Polish & pre-ship | 55 | 75% | 13% | 13% |
| M8 · Ship | 24.5 | 67% | 33% | 0% |
| **Total** | **~400.5** | **~51%** | **~15%** | **~33%** |

**~1,200 hours total, of which ~400 need premium quota.** The premium spend is front-loaded into M1
and M4 — correct, because those are the decisions that are expensive to get wrong. The old
"~1,000 h / ~215 premium" figures predate the art program and the D-036 lanes; with three worker
lanes running in parallel, wall-clock shrinks but the quota split above is what still binds.

⭐ **M2 is the milestone that matters most.** It's the first time you and your friends actually play
this. Everything before it is scaffolding. Protect it — do not let scope creep push it later.

---

## M0 · Foundations & spikes — 11 sessions

**Goal:** a repo you can work in, and answers to the three questions that could sink the project.

**Exit criteria:** you can walk around a grey-box world in first person, and you have measured answers
to R2 and R3 from `ARCHITECTURE.md` §6.

| # | Task | Tier | Est |
|---|---|---|---|
| 0.1 | `git init`, first commit, verify `.gitignore` covers `.godot/`, `export/`, `*.import` cache | T0 | 0.5 |
| 0.2 | Create folder structure from `ARCHITECTURE.md` §3 (empty dirs + `.gdignore` where needed) | T0 | 0.5 |
| 0.3 | Set up input map (move, look, jump, sprint, attack, interact, inventory, build) | T0 | 0.5 |
| 0.4 | First-person character controller: `CharacterBody3D`, mouse look, walk/sprint/jump, coyote time | T1 | 2 |
| 0.5 | Grey-box test level — ramps, stairs, gaps. Tune the controller until movement *feels good*. | T0 | 2 |
| 0.6 | Debug overlay autoload: FPS, position, entity counts, toggleable log channels, `~` console | T1 | 2 |
| 0.7 | **Spike R2** — generate 100 chunked terrain meshes from noise, measure frame times & hitches | T2 | 1.5 |
| 0.8 | **Spike R3** — bake a `NavigationRegion3D` on a runtime-generated chunk, measure the hitch | T2 | 1.5 |
| 0.9 | Record spike results in `DECISIONS.md`. If R3 failed, decide the fallback **now**. | T0 | 0.5 |
| 0.10 | **Spike R6** — run `tools/check_determinism.gd` on Windows and Linux, compare against the macOS baseline in `ARCHITECTURE.md` §6a | T0 | 1 |
| 0.11 | Populate the greybox test level with procedural test props (crates, cover, pillars, platforms) so playtesting isn't just an empty box | T0 | 1 |
| 0.12 | **Orchestration harness** — `agent order/dispatch/lanes/collect/report/reap` + `.agent/bin/lane`, so one director routes work to three headless subscription lanes and watches their quota (`ORCHESTRATION.md`, D-036/D-037) | T2 | 1.5 |

> **Do not skip 0.7/0.8.** These are the two things most likely to force a serious redesign, and they
> are far cheaper to discover here than in M4/M5.

---

## M1 · Network spine — 23 sessions

**Goal:** the multiplayer foundation, before any gameplay exists. This is the most important milestone
technically and the heaviest premium-quota spend in the project.

**Exit criteria:** you and a friend, over Steam, in a grey-box level, seeing each other move smoothly.
Plus the same thing in `LOCAL` mode in two windows in under 5 seconds.

| # | Task | Tier | Est |
|---|---|---|---|
| 1.0 | Register the `Registry` autoload in `project.godot` — 2.2 shipped the script but nothing loads it | T0 | 0.25 |
| 1.0b | Register the `NetTransport` autoload in `project.godot` — 1.2 follow-up, shipped under the pre-D-021 prompt | T0 | 0.25 |
| 1.1 | Install GodotSteam GDExtension (4.4+ branch), confirm it loads in stock Godot 4.7, **pin the engine version** | T0 | 1 |
| 1.2 | `NetTransport` autoload — swap between `ENetMultiplayerPeer` and `SteamMultiplayerPeer` behind one interface | T2 | 3 |
| 1.3 | `LOCAL` mode: launch 2 instances, auto-host/auto-join, no menus. **Make this one keypress.** | T2 | 2 |
| 1.4 | Steam lobby: create, invite via overlay, join by ID, leave, member list | T2 | 3 |
| 1.5 | Networked player: `MultiplayerSpawner` + `MultiplayerSynchronizer`, client-auth movement | T2 | 3 |
| 1.6 | Remote-player interpolation so other players don't stutter | T2 | 2 |
| 1.7 | Connection lifecycle: join mid-session, disconnect, host quits, timeout handling | T2 | 2 |
| 1.8 | Interest management: visibility filters + per-class `replication_interval` (`ARCHITECTURE.md` §2.5) | T2 | 1.5 |
| 1.9 | **Spike R1** — 6 peers, 200 synced dummy entities, measure bandwidth and CPU | T2 | 1.5 |
| 1.10 | Network debug panel: ping, bandwidth up/down, entity count, authority display | T1 | 1 |
| 1.11 | Protocol/build version handshake — refuse mismatched builds with a clear message, not a desync | T2 | 1.5 |
| 1.12 | **UNBLOCKED 2026-08-18 — D-030's wait is over: the in-game lobby join shipped (6.10's lobby-UI slice, press M).** Cross-platform join test, Mac ↔ Windows ↔ Linux in one lobby over Steam. Transport is proven; only the evidence ceremony is left, and it now needs only the three machines | T0 | 1.5 |

> **Task 1.3 is worth more than it looks.** One-keypress two-window multiplayer testing is the highest
> ROI thing in this milestone. Every future multiplayer bug gets cheaper to find because of it.

---

## M2 · Vertical slice — 80 sessions ⭐ (43 of them the authored-art program, 2.1b–2.1i)

**Goal:** the thinnest possible complete loop, played with friends. One biome, one tool, one enemy,
one night. If this isn't fun, nothing built on top of it will be.

**Exit criteria:** 3+ people play together for 20 minutes and want to play again.

| # | Task | Tier | Est |
|---|---|---|---|
| 2.1 | Import a CC0 low-poly pack (Quaternius/Kenney) — trees, rocks, props. Set up import presets & materials. | T0 | 3 |
| 2.1b | Expand the original Blender environment kit from 8 to 116 assets across trees, rocks, forest debris, ground cover, Mire growths, ruins, and modular wood/stone building pieces | T0 | 8 |
| 2.1c | Build a compact runtime-generated playtest map from the environment kit: camp, forest, ruins, Mire grove, ridge, routes, and collision | T0 | 4 |
| 2.1d | Produce the single `NEXT` batch in `docs/ASSET_TRACKER.md`; verify, advance the queue, hand off rather than close | T0 | 4 |
| 2.1e | Replace the runtime-scattered playtest visuals with an authored Blender map asset, incorporating harvestables and crafting stations | T0 | 6 |
| 2.1f | Author `playtest_hollow` — one shared layout file driving both the Blender visuals and the Godot collision, with elevation, a closed boundary, road clearance, and the loot/pickup/enemy kits placed | T0 | 6 |
| 2.1g | Animate environmental presentation: client-local foliage wind and campfire flame, spark, smoke, and light VFX; scalable and scene-safe | T1 | 3 |
| 2.1h | Polish `playtest_hollow`: open the spawn-camp gates, enlarge and better connect the zones, improve grass, and add complementary ground-cover variants | T0 | 6 |
| 2.1i | Audit existing art and improve the highest-impact hero/environment assets without bypassing their gameplay-review gates | T0 | 6 |
| 2.1j | Cross-family art overhaul: one shared palette/primitive library, an all-sides inspection harness, a canonical scale table, and rebuilds of the assets authored for a single camera angle | T0 | 8 |
| 2.1k | Revise `hollowmere`: shrink the valley to a walkable size, re-author the layout and placement with intent, ground everything, fix grass-through-props, bridge railings and the water, raise tree/harvestable density, use every kit asset, and give the crawlers a corrupt zone to spawn from | T0 | 6 |
| 2.2 | `Resource` scripts for `ItemDef`, `RecipeDef` + `registry.gd` boot loader | T2 | 2 |
| 2.3 | Harvestable prop: hit → damage → yield → despawn → respawn. **Host-authoritative** (`ARCHITECTURE.md` §2.2). | T2 | 3 |
| 2.4 | Inventory system: stacks, add/remove, host-validated. Data layer only. | T2 | 3 |
| 2.5 | Inventory UI — grid, drag/drop, hotbar | T0 | 4 |
| 2.6 | Crafting: recipe check, craft request → host validates → grants. One station (workbench). | T2 | 3 |
| 2.7 | Crafting UI | T0 | 3 |
| 2.8 | Melee combat v1: wind-up → commit → recovery, hitbox, hitstop, screenshake, impact SFX | T1 | 3 |
| 2.9 | **Tune combat feel until one enemy with one weapon feels great.** Do not proceed otherwise. *(Order swapped with 2.10 — F-036 option 1. Code, content and the `combat_feel_check` instrument shipped; only the human verdict is open.)* | T0 | 3 |
| 2.10 | Enemy v1: host-authoritative chase + attack, nav-driven, health, death, ragdoll or dissolve *(shipped before 2.9, per F-036)* | T2 | 3 |
| 2.11 | Day/night cycle: sun rotation, `WorldEnvironment` transitions, replicated time-of-day | T1 | 2 |
| 2.12 | Night wave spawner: N enemies at night, despawn at dawn, scales with player count | T1 | 2 |
| 2.13 | Death & respawn: downed → bleed-out → revive by teammate (`DESIGN.md` §4.5) | T2 | 2 |
| 2.14 | **Playtest with friends. Write down what they said, not what you think they meant.** | T0 | 1 |

> After 2.14, stop and re-read `DESIGN.md` §8. You now have real answers to Q5 (player count), and
> early signal on combat feel. Update the design before building more on top of it.

---

## M3 · Systems depth — 64.5 sessions

**Goal:** the systems that make it a *game* rather than a demo. Heavy on Tier 0 — this is where the
"content is data" decision starts paying you back.

| # | Task | Tier | Est |
|---|---|---|---|
| 3.1 | Full tier/fork crafting tree, stations (workbench → furnace → anvil) (`DESIGN.md` §4.3) | T2 | 4 |
| 3.2 | Author all item/recipe `.tres` content | T0 | 8 |
| 3.3 | Powerup framework: effect hooks, stacking, tags, Resonance thresholds (`DESIGN.md` §4.4) | T2 | 5 |
| 3.4 | Author 40–60 powerup `.tres` files | T0 | 10 |
| 3.5 | Coins, chest tiers, chest-opening UI and flow | T1 | 3 |
| 3.6 | Building system: placement ghost, snapping, rotate, validate, destroy | T2 | 5 |
| 3.7 | Buildable pieces (walls/floors/ramps/doors) + Ward structures | T0 | 4 |
| 3.8 | Hunger/health/stamina, food items, consumables | T1 | 3 |
| 3.8b | Dodge: stamina-gated dash, client-auth own movement. `DESIGN.md` §6 says stamina gates *dodging*, and Void Resonance's "dodge blinks" (§4.4) needs the verb to hook | T1 | 2 |
| 3.9 | Attunement system + selection UI (`DESIGN.md` §4.5) | T2 | 3 |
| 3.10 | Heavy hauling (2-player carry; solo fallback = slow one-player drag, `DESIGN.md` §5 solo rule) | T1 | 2 |
| 3.11 | **Playtest — does the Attunement split create roles or resentment? (Q4)** | T0 | 1 |
| 3.12 | Balance pass on everything above | T0 | 2 |
| 3.13 | **Command core** — `CommandService` front door: typed arg specs, LOCAL/HOST scopes, client→host RPC + op permissions, migrate every existing console command (`docs/COMMANDS.md` §1–2) | T2 | 3 |
| 3.14 | Gamerules — `RuleDef` content family + host-replicated `RuleService`, `rule`/`rules` commands, first-wave knob migration with export fallback (`COMMANDS.md` §4) | T2 | 2.5 |
| 3.15 | EntityDirectory + selectors (`@a @p @e[...]`) + entity verbs `tp`/`kill`/`tag`/`entities`, authority-respecting player moves (`COMMANDS.md` §3) | T2 | 3 |
| 3.16 | Command catalog sweep — every system verb in `COMMANDS.md` §7 incl. D-030's `lobby host/join/invite`, plus the coverage check | T1 | 2 |
| 3.17 | Functions + hooks + autoexec + headless `tools/run_commands.gd` scenario runner (`COMMANDS.md` §5–6) | T1 | 2 |

> **3.13–3.17 are the command track** (added 2026-08-18): runtime data control over every system,
> Minecraft-style — the full spec is [`COMMANDS.md`](COMMANDS.md). Order: 3.13 first; 3.14/3.15
> independent after it; 3.16 last. **Recorded call: this track is exempt from the "start M3 only
> after 2.14's §8 re-read" gate** — it encodes no design answers (all defaults untouched) and
> 3.13/3.17 directly help *run* 2.14 and D-030's cross-play test. Sequoyah overrides by note.

---

## M4 · World & the Mire — 45 sessions

**Goal:** a real procedural island, and the signature mechanic. Second-heaviest premium spend.

**Two gates must clear before anything else in M4 starts.** Both are M0 debts — measurements M0
recorded as green while leaving half the question unanswered. Both are cheap now and expensive later,
because 4.3 and 4.6 get designed against whatever they return.

| # | Task | Tier | Est |
|---|---|---|---|
| 4.0a | **Spike R2b** — `ConcavePolygonShape3D` cooking + GPU mesh upload cost per chunk, on a real renderer (`FINDINGS.md` F-005) | T2 | 1.5 |
| 4.0b | **Finish Spike R6** — determinism probe on Windows x86_64, fill the third column in `ARCHITECTURE.md` §6a | T0 | 0.5 |

> **4.0a:** R2 measured 0.330 ms/chunk headless — no GPU upload, no material, no collision shape. R3
> measured *navigation* baking, which is a different code path from physics cooking. The chunk
> streaming budget in 4.3 is being set from a number that excludes both. Measure before you commit.
>
> **4.0b:** MSVC is a third C library. `rng_sequence` and `noise_*` must match the macOS/Linux hashes,
> and so must the first group of the ops probe. If they don't, shared-seed world gen (§4) is dead on
> Windows and 4.6 changes shape entirely.

| # | Task | Tier | Est |
|---|---|---|---|
| 4.1 | Seeded island heightmap: layered noise + island falloff, deterministic RNG per subsystem | T2 | 4 |
| 4.2 | Biome assignment (height × moisture), biome `.tres` definitions | T2 | 3 |
| 4.3 | Chunk streaming + LOD, `WorkerThreadPool` mesh generation | T2 | 6 |
| 4.4 | Resource scatter via `MultiMeshInstance3D`, per-biome tables | T2 | 4 |
| 4.5 | Runtime nav baking per chunk — **or the R3 fallback decided in M0** | T2 | 5 |
| 4.6 | Seed replication + client-side regeneration; mutable-state delta sync (`ARCHITECTURE.md` §4) | T2 | 4 |
| 4.7 | POI placement: seeded Poisson-disc, Wellsprings + landmarks | T2 | 3 |
| 4.8 | Wellspring scene, capture ritual, 2-player requirement, defense wave (solo fallback: 1-player ritual with a longer timer, `DESIGN.md` §5 solo rule) | T1 | 3 |
| 4.9 | **Mire grid simulation** + delta replication (`ARCHITECTURE.md` §5) | T2 | 4 |
| 4.10 | Mire visuals: shader ground tint, fog density, particles, audio shift | T0 | 4 |
| 4.11 | Mire ↔ world interaction: rotted resources, Blight debuff, corrupted spawns, Ward resistance | T1 | 3 |
| 4.12 | **Playtest — is the Mire stressful-fun or just stressful? (Q1, Q2)** | T0 | 2 |

> 4.12 is a genuine go/no-go. The Mire is the game's identity; if it doesn't land, tune it hard or
> replace it, but find out here — not in M7.

---

## M5 · Combat, enemies & bosses — 55 sessions

**Goal:** content volume. Mostly Tier 0 once the frameworks from M2/M3 exist — that's the payoff for
building them properly.

| # | Task | Tier | Est |
|---|---|---|---|
| 5.1 | Enemy AI framework: state machine, perception, telegraphed attacks, group behaviour | T2 | 5 |
| 5.2 | 8–12 enemy types (scenes + `.tres` stats + animation setup) | T0 | 14 |
| 5.3 | Ranged combat: bow, projectiles, host-authoritative hit validation | T2 | 4 |
| 5.4 | Weapon variety per fork, weapon-specific movesets | T0 | 6 |
| 5.5 | Boss framework: phases, arena, telegraphs, health bar, music stinger | T2 | 5 |
| 5.6 | Boss 1 — Wellspring guardian (recurring, scales with Cycle) | T0 | 5 |
| 5.7 | Boss 2 — roaming elite, spawned by the *Hunt* modifier | T0 | 5 |
| 5.8 | Boss 3 — deep-Cycle threat (appears Cycle 7+) | T0 | 5 |
| 5.9 | Wave director: Cycle-aware pacing, composition, player-count scaling | T1 | 3 |
| 5.10 | Combat balance pass **across the Cycle curve**, not at one difficulty | T0 | 3 |

---

## M6 · Cycles, extraction & meta — 34 sessions

**Goal:** endless escalation that has a shape. This milestone contains the hardest *tuning* problem in
the project (Q3) — budget real playtest time, not just build time.

| # | Task | Tier | Est |
|---|---|---|---|
| 6.1 | Cycle state machine: advance, escalate spread rate, expand enemy pool, announce (`DESIGN.md` §5.1) | T2 | 3 |
| 6.2 | Cycle Modifier framework: deck, draw, stacking, Cycle-weighted rules, incompatibility tags | T2 | 4 |
| 6.3 | Author 20–30 Cycle Modifier `.tres` files | T0 | 5 |
| 6.4 | Wellspring re-corruption over time | T1 | 1 |
| 6.5 | **Extraction:** shipwreck POI, repair recipe, board-to-leave, group confirm flow (`DESIGN.md` §5.2) | T2 | 3 |
| 6.6 | Salvage: superlinear reward curve, extract-vs-die split, persistence, save-file versioning | T2 | 3 |
| 6.7 | Lose condition: team wipe / island consumed, defeat flow | T1 | 2 |
| 6.8 | Run summary: **headline Cycle number**, stats, modifiers drawn, Salvage earned | T0 | 3 |
| 6.9 | Unlock tree + UI. **Variety only, never power** (`DESIGN.md` §4.6) | T1 | 4 |
| 6.10 | Main menu, lobby UI, settings, seed entry | T0 | 5 |
| 6.11 | **Long playtests — find the wall (Q3), check anyone ever extracts (Q6), check deep modifiers stay fair (Q7)** | T0 | 4 |

---

## M7 · Polish & pre-ship — 55 sessions

**Goal:** the difference between "my friend's game" and "a game." Almost entirely Tier 0 — polish is
craft, not code, and this is where you can work indefinitely without spending quota.

| # | Task | Tier | Est |
|---|---|---|---|
| 7.1 | Audio pass: SFX for every action, ambience per biome, mix, buses | T0 | 10 |
| 7.2 | Music: 4–6 tracks (act themes, boss, menu). CC0/licensed or commissioned. | T0 | 4 |
| 7.3 | VFX pass: impacts, deaths, gathering, Mire, weather | T0 | 8 |
| 7.4 | UI/UX polish pass, consistent visual language, transitions | T0 | 6 |
| 7.5 | Settings: graphics, audio, sensitivity, keybinds, FOV, accessibility basics | T1 | 4 |
| 7.6 | Gamepad support + Steam Deck compatibility (not verification) | T1 | 3 |
| 7.7 | Performance pass: profile, LOD tuning, draw calls, target 60fps mid-range | T2 | 4 |
| 7.8 | Network robustness: packet loss, high latency, hostile disconnect timing | T2 | 3 |
| 7.9 | Bug bash from playtest backlog | T0 | 6 |
| 7.10 | Replace hero CC0 assets if desired (player hands, bosses, key items) | T0 | 2 |
| 7.11 | Export presets for macOS (universal), Windows, Linux — Steam redistributables bundled per platform, case-sensitivity audit | T0 | 3 |
| 7.12 | Test each export on its real OS, plus Steam Deck | T0 | 2 |

---

## M8 · Ship — 24 sessions

See `STEAM.md` for the full checklist and the hard scheduling constraints.

| # | Task | Tier | Est |
|---|---|---|---|
| 8.0 | **Name search** — Steam store + trademark search for "MIRE" (`STEAM.md` S1 calls this blocking; `DESIGN.md` header repeats it). Do before any store-page work; a rename after 8.5/8.7 costs the Coming Soon clock | T0 | 0.5 |
| 8.1 | Steamworks account, tax/banking, $100 Steam Direct fee, real App ID | T0 | 2 |
| 8.2 | Swap App ID 480 → real App ID; verify all Steam features | T0 | 1 |
| 8.3 | Achievements, stats, rich presence | T1 | 3 |
| 8.4 | Depots, build pipeline, `steamcmd` upload script, branches | T1 | 3 |
| 8.5 | Store page: description, tags, screenshots, capsule art | T0 | 4 |
| 8.6 | Trailer: capture, cut, audio | T0 | 4 |
| 8.7 | Coming Soon page live (starts the mandatory 2-week clock) | T0 | 1 |
| 8.8 | Closed beta on a password-protected branch with friends | T0 | 1 |
| 8.9 | Build review submission, fix findings, release | T0 | 1 |
| 8.10 | macOS codesign + notarisation (needs an Apple Developer account, $99/yr) | T0 | 2 |
| 8.11 | Three depots wired to one app, per-platform launch options | T1 | 2 |

---

## Scope-cut levers — pull these, in this order

If the project is dragging, cut from the bottom of this list first. Deciding the order *now*, while
you're not stressed, is what prevents cutting the wrong thing later.

1. Enemy count: 12 → 6 (saves ~7 sessions)
2. Bosses: 3 → 2 (saves ~5)
3. Powerups: 60 → 30 (saves ~5)
4. Biomes: 5 → 3 (saves ~4)
5. Building system → simplified prefab camps only (saves ~7)
6. Attunements: 4 → 2 (saves ~2)
7. Meta-progression / Salvage → ship without it, patch it in (saves ~10)

**Never cut:** the network spine (M1), combat feel (2.9), the M2 playtest gate, **Cycle Modifiers (6.2/6.3)**, or **extraction (6.5)**. Those are load-bearing — modifiers are where replayability comes from, and extraction is what gives an endless run a satisfying end.

---

## The three rules

1. **M2 is sacred.** Playing this with friends is the whole point, and it is also your motivation
   engine. Do not let anything push it later.
2. **Fun before content.** If one weapon against one enemy isn't fun, building the tenth weapon is
   wasted work.
3. **Playtest every milestone.** Your friends are the only reliable signal about whether this is
   working. Use them.
