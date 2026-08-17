# Working with AI agents on MIRE

**Your bottleneck is AI quota, not calendar time.** This document exists to get the most game per
token. It is the most important process document in the project — read it before `ROADMAP.md`.

Available: Claude Code (this plan) · a second Claude Pro account · ChatGPT Plus / Codex.

---

## 1. The core reframe

Most people building a Godot game assume the work is "writing code." It isn't. A rough split of the
hours in a 3D Godot game looks like this:

```
  Editor work (scenes, assets, tuning, playtest)  ████████████████████  ~55%
  Code that agents are good at                    ████████████          ~30%
  Code that needs real reasoning                  ██████                ~15%
```

**Only that bottom 15% genuinely needs your premium quota.** The top 55% costs you nothing but time,
and — critically — LLMs are *bad* at it anyway. Godot node trees, UI anchoring, particle tuning, and
material setup are things an agent will fumble and you will do correctly in five minutes by hand.

So the strategy is not "use less AI." It is: **stop spending AI on work that was never AI work.**

---

## 2. The three tiers

Classify every task before you spend anything on it.

### Tier 0 — Do it yourself in the Godot editor. Costs zero quota.

Scene trees and node hierarchies · collision shapes and areas · materials and `WorldEnvironment` ·
importing and configuring CC0 assets · `AnimationPlayer` / `AnimationTree` setup · `GPUParticles3D` ·
lighting and fog · **all UI layout** (Control anchors and containers — agents are consistently bad at
this) · input map · tuning `@export` values · **authoring `.tres` content resources** · playtesting ·
audio buses · navigation region config.

> This is the majority of your project. Get comfortable here. It's also the fun part.

### Tier 1 — Cheap agent (Codex / secondary Claude Pro). Well-specified, self-contained.

Boilerplate and glue · single-file refactors · unit tests · one-off tooling scripts · shader code from
a clear description · data-generation scripts · docs and comments · converting a written spec into a
first-draft `.gd` file · mechanical repetition across many similar files.

**Rule: if you can write a precise spec for it, it goes to Tier 1.** Writing the spec yourself is
cheap for you and enormously expensive for an agent to infer.

### Tier 2 — Premium quota (Claude Code, this plan). Reasoning that other code depends on.

Netcode and authority design · world generation algorithms · the powerup/Resonance framework ·
save/load and migration · cross-cutting refactors · **hard bugs you've already tried to fix** ·
architecture decisions · anything where being wrong costs a rewrite.

**Rule: spend Tier 2 on things that are expensive to get wrong, not things that are tedious.**

---

## 2a. Which model for which tier

Cost figures are Anthropic API rates (per million tokens). Claude Code plan limits don't map
one-to-one, but the relative ordering does — treat this as which lever costs you more, not as a bill.

| Tier | Model | Cost | Why |
|---|---|---|---|
| **T0** | *(none)* | free | Editor work. No agent involved. |
| **T1** | **Sonnet 5** | $3/$15 | **The default workhorse.** Near-Opus quality on coding and agentic work at a fraction of the cost. Most `.gd` implementation from a written spec belongs here. |
| **T1 (trivial)** | Haiku 4.5 | $1/$5 | Mechanical single-file edits, boilerplate, renames. 200K context — too small for anything cross-cutting. |
| **T2** | **Opus 5** | $5/$25 | Netcode, world gen, the powerup framework, hard bugs, architecture. Things expensive to get wrong. |
| **Design only** | Fable 5 | $10/$50 | Twice Opus. Three problems justify it — see below. Never for implementation. |

### Fable: specs only, never code

The rule that makes scarce Fable quota worth having: **Fable writes the spec, cheap lanes build it.**
One Fable turn producing a design document that three lanes then implement is the best conversion of
premium quota into shipped work available here — and it is exactly what the lane system (D-036) is
built to exploit.

Its edge is one-shot design where the space is wide and being wrong costs a rewrite. Spend it on
exactly three things, in this order:

1. **M4 world generation / Mire replication design.** Thirteen unstarted tasks descend from it. A
   wrong call here is not a bug, it is rewriting M4.
2. **The powerup / Resonance framework.** You then hand-author ~60 `.tres` against it. A bad framework
   means re-authoring *content* — the one thing that cannot be cheaply redone.
3. **Save/load and the migration schema.** Versioned data that ships to players.

**Never** on: debugging (long loops, huge context — Opus at medium is better value *and* usually
better), implementation from a written spec, or anything a `tools/*_check.gd` already proves.

> ⏳ **Sonnet 5 is on introductory pricing ($2/$10) through 2026-08-31.** Until then it's ~40% of Opus's
> cost rather than ~60%. If you're planning a big implementation push, front-load it.

### Effort matters more than the model

The single highest-leverage cost setting, and the one most people get wrong. On Opus 5, `low` and
`medium` effort are unusually strong — Anthropic's own guidance calls effort the primary cost lever
and warns that effort defaults carried over from older models are usually wrong.

**Opus 5 at medium often beats Sonnet 5 at high, and costs less than Opus 5 at xhigh.** Reserve
`xhigh` for M1 netcode and M4 world generation. Use `medium` for everything else, and step up only
when you can see the reasoning is too shallow.

### Ultracode: off by default

Ultracode spawns multi-agent workflows — a dozen or more agents, each re-deriving context from cold.
It is by far the most token-hungry mode available, and running it on routine coding is the most
expensive possible configuration for a quota-bound project.

Turn it on deliberately, for problems where being wrong costs a rewrite: the authority model, the
Mire replication design, a bug you've already failed to fix twice. Turn it off again afterwards.

---

## 3. The parallel-agent trap: Godot scenes do not merge

`.tscn` and `.tres` are text files, but they carry internal `[sub_resource id="..."]` and
`[ext_resource id="..."]` identifiers and node-path references. Two agents editing the same scene
produce conflicts that are painful at best and silently corrupt the scene at worst.

The protection is exact file ownership plus a closed editor (D-031):

- Agents may edit `.tscn`, `.tres`, and `.import` files only under an explicit exact-file claim.
- Before touching any Godot-authored file, run `pgrep -fl Godot`. If Godot is open, stop; it can
  overwrite an agent's work on save.
- Two agents may work in parallel only on disjoint claimed files. Never overlap a scene or resource.
- Prefer a Godot tool script for complex scene/resource generation so Godot serializes its own format.
- Visual layout, tuning, and playtesting remain good Tier 0 editor work, but they are no longer a
  mandatory human handoff when an agent can safely implement and verify the change.
- Commit before and after each agent session, so a bad run is one `git restore` away.

**Practical parallel split:** premium agent works in `core/` or `systems/`; cheap agent works in
`ui/`, `content/`, or tooling. These rarely touch.

**This split is now mechanical.** Each paid account is a *lane* with an area, and one director routes
work to all three — see **`ORCHESTRATION.md`** (D-036):

| Lane | Account | Tier | Area |
|---|---|---|---|
| `LD` | Claude Max 5x (Opus) | T2 | routing, design, verification — does not implement |
| `LC1` | ChatGPT Plus #1 (codex) | T1 | `systems/` `core/` `entities/` |
| `LC2` | ChatGPT Plus #2 (codex) | T1 | `ui/` `tools/` `world/` |
| `LP` | Claude Pro (Sonnet) | T1-heavy | `systems/` `ui/` `autoload/` |
| `L0` | Sequoyah | T0 | the editor. Free, never dispatched |

```bash
agent order 2.11 --lane LC2 --files systems/environment/day_night.gd
agent dispatch LC2          # headless, on that account's quota
agent report                # who's working, what it cost, what's stuck
```

One more rule the lanes make load-bearing: **launch the engine with `agent godot`, never bare.** All
~49 checks share one import cache and concurrent runs race on it (F-044).

---

## 4. Techniques that multiply your quota

Ordered by impact.

1. **Build debug infrastructure early (M0/M1).** An in-game debug overlay, a state inspector, verbose
   toggleable logging, deterministic seeds, and instant restart convert *expensive AI debugging* into
   *free self-debugging*. Debugging is by far the most token-hungry AI activity — long loops, huge
   context, lots of guessing. Every hour spent on debug tooling saves many multiples in quota.

2. **Never ask an agent to explore.** "Look through the codebase and figure out where…" is the single
   most expensive prompt you can write. Always point at the file: *"In `systems/crafting/crafter.gd`,
   the `try_craft` function…"* Keep a mental map of your own project.

3. **Keep `CLAUDE.md` short and current.** It's loaded into context on every single request. Bloat
   there is a tax on every future call, forever. Prune it when it grows.

4. **Small files.** A 200-line file costs a tenth of a 2,000-line file to read. The folder structure in
   `ARCHITECTURE.md` §3 exists partly for this reason.

5. **Spec first, in your own words.** Write what you want by hand, then hand it over. This turns a
   Tier 2 task into a Tier 1 task, which is a direct quota saving.

6. **Batch while context is warm.** Loading context is the expensive part; the second and third related
   task in the same session are much cheaper than the first. Do all the inventory work at once.

7. **Clear context between unrelated tasks.** Carrying stale context into a new problem means paying to
   re-read irrelevant material on every turn.

8. **Never generate content data with an agent.** Do not ask for 60 powerups. Build the framework once
   (Tier 2), then author the 60 `.tres` files yourself (Tier 0). Content should be free.

9. **Ask for targeted edits, not rewrites.** "Change `try_craft` to validate on the host" not "rewrite
   the crafting system."

10. **Pin your Godot version.** Version-drift bugs produce long, expensive, confusing debug sessions
    where the agent is reasoning about a different engine than the one you're running.

---

## 5. Cold-start ritual

Because you'll be away for stretches, re-entry must be cheap. Every session:

1. Open `docs/NEXT.md` — it says exactly what you're doing and why
2. `git log --oneline -10` — what did past-you actually finish?
3. Run the game in `LOCAL` two-window mode — confirm nothing is broken before you change anything
4. Do the work
5. **Before you stop:** update `NEXT.md` with the next concrete task, and commit

**Rule: never end a session mid-task without writing down where you are.** The cost of reconstructing
lost mental state is paid in quota.

---

## 6. What to do when you run out of quota

This will happen. Have a queue ready so it isn't a stop.

- Author `.tres` content (items, powerups, recipes) — endless, valuable, free
- Import and configure CC0 assets; build the asset library
- Build and polish scenes and UI in the editor
- Tune and balance numbers
- **Playtest with friends** — the most valuable non-code activity in the project
- Write specs for the next batch of agent tasks (this makes future quota go further)
- Trailer capture, capsule art, store page copy (see `STEAM.md`)
- Learn: Godot docs on the system you're about to build

> Keeping a stocked Tier 0 backlog is what turns a quota wall from a blocker into a scheduling detail.
