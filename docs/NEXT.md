# NEXT — what am I doing right now?

> **Open this first, every time.** It exists so that coming back after a week or a month costs you ten
> minutes instead of a weekend. Update it before you stop working. Always.

---

## Status

**Milestone:** M2 · Vertical slice. **M1 closes at 13/14** — 1.12 is deferred, not outstanding
(D-030). M0 is closed, 10/10.
**Tasks 2.3 through 2.5 are playable:** `HarvestableDef` plus the host-authoritative `Harvestable` lifecycle
wires the 11 intact tree/stone/iron props in `playtest_hollow`, and each completed harvest now grants
the validated peer a host-owned inventory stack. Inventory uses 24 stable slots (first eight reserved
for the hotbar), owner-only revisioned snapshots, explicit request confirmations, and atomic crafting
transactions. The always-visible hotbar and Tab field pack render those snapshots, and drag/drop
submits host-validated full-stack moves without prediction. Offline and two-process ENet checks cover
grants, stacking, removal, movement, overspend rejection, peer isolation and cleanup.
**Last session:** 2026-08-16 — task 2.5 completed. The inventory UI is registered and runs without
scene wiring; its focused check passed 29 assertions, the existing inventory checks stayed green, and
Forward+ desktop/narrow screenshots were rendered for visual inspection. Task 2.6 is next.
The deferred 1.12 evidence remains unchanged: all three pinned-engine/GodotSteam
preflights passed and a real Mac-hosted Steam lobby reached three peers across macOS, Windows and
Linux. Code-built remote-player debug capsules made all three spawns visible, and Linux movement
replicated to the host. A later two-platform rerun proved a fresh `origin/main` Windows client can
join the macOS host with Windows Firewall enabled: peer `579922246` reached a two-player STEAM
session and the host despawned it on exit. The formal exit run is still incomplete: the required
simultaneous Linux client, three first-join latency lines, 60-second all-player movement run, and
three screenshots remain.

Connection lifecycle (1.7) completed the code-driven M1 work: readable
admission/version refusals, late joining, automatic LOCAL/LAN rejoin, clean host close, and bounded
dead-peer detection all passed a real multi-process ENet harness. Only the physical cross-platform
Steam join test (1.12) remains. F-009 is fixed: the committed GDExtension registry now makes
GodotSteam loading reproducible in fresh headless environments.

The M0 spikes came back **GREEN**: chunked terrain meshing stays in GDScript (D-015), runtime NavMesh
baking stays and the grid-A* fallback is dropped (D-016). Neither is unconditional — see *M0 debts*.
**R1 (netcode) is AMBER**, which is not a blocker but does promote task 1.8 from optional to required;
the numbers are under *What changed this session*.

**The game runs.** Open the project and press Play: you spawn in Playtest Hollow and can walk, sprint,
jump, look around, and attack intact resource props at close range. **F3** overlay · **`~`** console ·
**Esc** releases the mouse.

**Thirteen autoloads live, verified headlessly 2026-08-16** on
`4.7.1.stable.official.a13da4feb`: `NetSession` is ordered after `NetTransport` and before
`DevLaunch`; `SteamLobby`, `PlayerNet`, `NetDebugPanel`, `TestMapProps`, and `NetInterp` follow their
dependencies; `HarvestWorld` and `InventoryService` follow `Registry`. Boot log reads
`content: loaded 3 item(s), 0 recipe(s)` and `net: NetTransport ready (offline)`. `NetConfig` is a
`class_name`, **not** an autoload; don't add it.

Godot 4.7.1-stable, pinned — don't upgrade mid-milestone. That build hash is also the determinism
baseline in `ARCHITECTURE.md` §6a, so upgrading invalidates R6.

---

## Roles (D-014, superseded by D-020)

No fixed planner/coder split — any agent (Claude Code chat, Codex, a second Claude session) can take
any task; who picks it up depends on which plan has quota available. Sequoyah is the only fixed role:
**Integrator** — Godot editor, assets, tuning, playtesting, commits.

Protocol: [AGENTS.md](../AGENTS.md). Start every session with `.agent/bin/agent start` — no name needed,
it takes one from the chat itself (F-007).

---

## Next task — M2. 1.12 is deferred, not pending (D-030)

**Starting a task no longer means pasting a prompt.** Open a fresh chat, give it the task id, and the
agent runs `agent brief <id>` itself: that prints the task, the open findings, what the last tasks in
this milestone left it, and who holds which files. It claims, works, verifies headless, files what it
learned in the repo, and ships. What comes back to you is what only you can act on.

**Do not start 1.12.** M1 closes at 13/14 on purpose. The thing 1.12 de-risks is proven — three
platforms in one Steam lobby, all three players spawned, Linux movement replicated, and a later
two-platform rerun that joined and despawned cleanly with Windows Firewall enabled. What is missing is
ceremony: 60 s of observed movement, three screenshots, an ordered exit. Collecting it today means a
scheduled three-machine session driven by lobby IDs pasted between terminals, on a VM rendering at
2–3 FPS (F-025) — expensive to arrange and a bad instrument. **It waits for an in-game lobby join
(task 6.10), which makes the test cheap.** Everything needed to resume is in
`docs/STEAM_CROSS_PLATFORM_TEST.md` and will keep.

**The next task is `2.6` — crafting.** It checks recipes, submits a craft request to the host, and
grants output only after host validation at one workbench. Build it on InventoryService's atomic
`host_transaction()` seam. Task 2.7 adds the crafting UI; do not mix it into 2.6.

**The exact 2.4 seams:** local UI reads 24 stable slot dictionaries and never mutates the snapshot;
the first eight are its hotbar. Client remove/move requests carry no peer id and complete through
`operation_confirmed`. Trusted host gameplay uses `host_add` or atomic `host_transaction`; there is
no client grant RPC. Owner-only full snapshots carry monotonic revisions. The new RPC set makes the
current protocol version 3.

**If cross-play testing starts to feel overdue before M6**, the cheap version is a pair of debug
console commands over the `SteamLobby` API that already exists (`host_session()`, `join_by_id()`,
`open_invite_overlay()`). That is a fraction of 6.10 and delivers the whole testing benefit — see
D-030. Worth pulling forward if M2 or M3 stretches out.

---

## What changed this session

**M1 netcode is real.** 1.5 (networked player), 1.9 (R1 spike) and 1.10 (debug panel) all shipped, and
none of them needed anything from you in the editor.

- **Connection lifecycle is now one coherent layer.** `NetSession` owns host admission and readable
  endings above `NetTransport`: late join, capacity refusal without spawning, version mismatch,
  automatic LOCAL/LAN rejoin, dead-process despawn and clean host close all passed in real processes.
  The dead client was detected in 2.6 s; the harness completed 8/8 sections with zero failures.
- **Two players, two windows, each driving their own** — `PlayerNet` spawns one player per peer under
  `/root/PlayerNet/Players`, authority derived from the node's name, position/yaw/pitch replicated at
  30Hz. Verified with two headless processes, both directions.
- **R1 is AMBER, and that has teeth.** 200 entities unfiltered = 918 KB/s host up, 7.3× over the
  125 KB/s ceiling. With §2.5 interest management: 105 KB/s at 30Hz, 57 KB/s at 15Hz. CPU was never
  the constraint (1.18 ms/frame worst case). So the §6 R1 fallback — hand-rolled binary packets — is
  **not** needed, but **1.8 stops being optional**: it is the thing that makes the budget fit.
- **Agents now brief themselves.** `agent brief <id>` plus a close-out contract in `AGENTS.md` step 3
  replaced the hand-written-prompt model. Findings go to `FINDINGS.md`, settled calls to
  `DECISIONS.md`, APIs the next task needs to `DELEGATION.md` *Current state* — so nothing has to
  travel through you to reach the next agent.

---

## Then, in order

| # | Task | Tier | Who | Est |
|---|---|---|---|---|
| 2.3 | Harvestable prop: hit → damage → yield → despawn → respawn, host-authoritative | T2 | done | ✅ |
| 2.4 | Inventory system: stacks, add/remove, host-validated. Data layer only | T2 | done | ✅ |
| 2.5 | Inventory UI — grid, drag/drop, hotbar | T0 | done | ✅ |
| 2.6 | Crafting: recipe check, craft request → host validates → grants. One station | T2 | agent | 3h |
| 2.1d | Next `NEXT` asset batch from `docs/ASSET_TRACKER.md` (A-005, loot) | T0 | you | 4h |
| 1.12 | Cross-platform join test — **deferred to after 6.10**, D-030 | T0 | — | 1.5h |

Tasks 1.6, 1.7, 1.8 and 1.11 are done. Do not reopen any M1 task as a prerequisite for M2 — the
network spine is finished and 2.3 builds directly on it.

**Playtest Hollow environmental motion is implemented as task 2.1g.** Grass, ferns, reeds and sedges
receive client-local vertex wind automatically, and authored fire placeholders become procedural
flame, spark and smoke particles with flickering light. No scene wiring is required; the shared
layout runtime creates the controller. The dedicated headless check covers 1,772 foliage mesh parts
and four fire sources, and a Forward+ rendered run held the existing 120 FPS cap on the test Mac.

---

## M0 debts — booked as M4 gates, don't lose them

Both spikes went green with half the question unanswered. Both are now real tasks (`4.0a`, `4.0b`) at
the top of M4 rather than notes in a findings file, because M4's chunk streaming budget gets designed
against whatever they return.

| # | What's actually unmeasured | Who | Est |
|---|---|---|---|
| 4.0a | `ConcavePolygonShape3D` cooking + GPU mesh upload per chunk. R2 ran headless — no upload, no material, no collision. R3 measured *navigation* baking, a different code path. F-005, and the standing caveat on D-015. | agent | 1.5h |
| 4.0b | Determinism on Windows x86_64 — all required hashes matched on a physical Ryzen 5 5600 PC. | done | ✅ |

Nothing in M1 depends on either. Don't pull them forward; just don't start 4.1 without them.

---

## Cross-platform (D-013)

Shipping macOS + Windows + Linux with cross-play. Steam P2P makes cross-play itself nearly free, but it
creates one real risk: clients regenerate terrain from a shared seed, and float results aren't
guaranteed identical across architectures and C libraries.

**Linux is done — see D-017.** Noise and PRNG are bit-identical across macOS arm64 and Linux x86_64;
raw `sin`/`cos`/`pow`/`exp`/`log` are not. §4 stands, and the price is the world-gen safe set now
written into `ARCHITECTURE.md` §7.

**Task 4.0b — DONE 2026-08-16 on a physical Windows x86_64 PC:**

```bash
godot.exe --headless --path . --script tools/check_determinism.gd
```

```bash
godot.exe --headless --path . --script tools/check_determinism_ops.gd
```

Godot **4.7.1-stable build `a13da4feb`** ran both probes twice on Windows 11 25H2, Ryzen 5 5600.
`rng_sequence`, both noise hashes, and all four safe-operation hashes matched macOS exactly;
`float_math` differed as expected. See `ARCHITECTURE.md` §6a and D-028. M4 may build on seeded
generation under the §7 safe-set rule.

The run also exposed a separate harness trap: a raw clone lacks the intentionally gitignored
GodotSteam binaries and the generated global class cache. Install the D-022-pinned addon and run one
headless editor import before treating startup errors as game defects. The probes still completed and
their built-in-only hashes were valid, but that run did not verify a clean Windows game boot.

---

## Tools

**You don't run these — ask an agent chat to.** Your side of this project is the Godot editor, asset
work, tuning, playtesting and pasting task prompts. Anything with a shell belongs to an agent.

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/verify_setup.gd
```

Input map responds to real key presses, autoloads registered, scenes have the node names the scripts
expect, the player actually falls and lands, and the §5a physics/vsync/fps settings resolve to their
correct *effective* values regardless of whether `project.godot` spells them out or Godot is silently
supplying its own default (F-003) — no need to re-run this after every editor save just to catch a
prune, since a pruned default-equal value still reads correct. Run it after anything structural.

`tools/setup_project.gd` regenerates the input map, autoloads and both scenes. **Don't re-run it once
you start tuning in the editor** — it overwrites the scenes.

---

## Open questions waiting on playtests

None yet — first real answers arrive at **M2 task 2.14**. Tracked in `DESIGN.md` §8.

---

## Cold-start ritual

**Yours, coming back after a break:**

1. Read this file — the *Next task* section is the answer
2. Open `.agent/BOARD.md` if you want the full picture of what's done
3. Copy the matching block out of `DELEGATION.md` into a fresh chat at the model it names

**The agent's, in that fresh chat** (already written into every prompt, listed here for reference):

1. `.agent/bin/agent start` — names this chat and prints what's in flight
2. Read `AGENTS.md`, then this file
3. Skim the last entry or two in `.agent/JOURNAL.md` if someone handed off
4. `.agent/bin/agent claim <id> <files...>` **before** editing
5. Do the work
6. `done` or `handoff`, then `ship`, and update this file

No `MIRE_AGENT=` prefix on any of them, and no name to pass: identity comes from the chat's own
session id, which git inherits too, so commits resolve to the same agent (F-007).

---

## Parking lot

- Seed sharing / daily seed with a friends leaderboard by Cycle depth
- Spectator mode for dead players
- A "Cycle 1 speedrun" mode
- Cosmetic hats. There must be hats.
