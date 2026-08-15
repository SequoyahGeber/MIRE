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

## 3. The parallel-agent trap: Godot scenes do not merge

`.tscn` and `.tres` are text files, but they carry internal `[sub_resource id="..."]` and
`[ext_resource id="..."]` identifiers and node-path references. Two agents editing the same scene
produce conflicts that are painful at best and silently corrupt the scene at worst.

**The partition that solves this, and happens to be optimal anyway:**

> ### Agents write `.gd` scripts. You wire them into scenes.

This is merge-safe, quota-efficient, and plays to everyone's strengths simultaneously. It means:

- Agents produce and edit **code files only**
- You attach scripts to nodes, set exports, and build hierarchies in the editor
- Two agents can safely work in parallel **only if they own disjoint folders** — assign folder
  ownership explicitly at the start of a session and never overlap
- Never run two agents against the same file. Ever.
- Commit before and after each agent session, so a bad run is one `git restore` away

**Practical parallel split:** premium agent works in `core/` or `systems/`; cheap agent works in
`ui/`, `content/`, or tooling. These rarely touch.

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
