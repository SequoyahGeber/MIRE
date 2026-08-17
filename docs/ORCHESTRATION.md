# Orchestration — one director, three paid lanes

How MIRE turns four AI subscriptions on one MacBook into parallel work. This is the *push* half of
the protocol in `AGENTS.md`; everything there still applies unchanged. Read `AGENTS.md` first.

**The constraint this exists to fight:** quota, not time (`AI-WORKFLOW.md`). Four plans sit on this
machine and, before this, exactly one of them was ever working — because a human had to open each
chat and pick each task.

---

## 1. The lanes

| Lane | Account | CLI · model | Tier | Owns |
|---|---|---|---|---|
| **LD** | Claude Max 5x | Opus 5 | T2 | Routing, netcode & world-gen design, verifying failures, integration |
| **LC1** | ChatGPT Plus #1 | `codex` · gpt-5.6-sol | T1 | `systems/` `core/` `entities/` |
| **LC2** | ChatGPT Plus #2 | `codex` · gpt-5.6-sol | T1 | `ui/` `tools/` `world/` |
| **LP** | Claude Pro | `claude` · Sonnet 5 | T1-heavy | `systems/` `ui/` `autoload/` — refactors and glue |
| **L0** | Sequoyah | — | T0 | Godot editor, `.tres` content, playtest. Free. Never dispatched. |

Each lane authenticates from its own home, which is the whole reason two ChatGPT Plus accounts can
run side by side:

```
LC1  CODEX_HOME=~/.mire/lanes/codex-a
LC2  CODEX_HOME=~/.mire/lanes/codex-b
LP   CLAUDE_CONFIG_DIR=~/.mire/lanes/claude-pro
```

A lane runs with `MIRE_AGENT=<lane>`, so it inherits the existing claim, journal, and commit protocol
with **no changes** — its claims say `lc1`, its commits say `lc1`, `agent board` shows it like any
other agent.

> **The director does not implement.** It routes, verifies, and decides. A director writing gameplay
> code has spent the project's most expensive quota on work a cheap lane does just as well (D-036).

---

## 2. Setup — once per machine

Both CLIs already ship inside the desktop apps, so there is nothing to install:

```
codex    /Applications/ChatGPT.app/Contents/Resources/codex
claude   ~/Library/Application Support/Claude/claude-code/<version>/claude.app/Contents/MacOS/claude
```

```bash
.agent/bin/setup-lanes
```

It creates the three auth homes, writes each Codex lane's `config.toml`, and prints three `login`
commands. **Run those yourself** — an agent must never handle account credentials. Sign each into a
*different* account, or two lanes share one quota pool and the point is lost.

```bash
.agent/bin/agent lanes --doctor      # ✓ ready, or exactly what's missing
```

---

## 3. The loop

```bash
agent order 2.11 --lane LC2 --files systems/environment/day_night.gd
agent dispatch LC2                   # add --dry-run to see the command without spending anything
agent report                         # who's working, what it cost, what's stuck
agent collect                        # what shipped, what stopped, what needs you
```

### `order` — a work order is generated, never hand-written

`agent order` composes a self-contained prompt from `agent brief` plus the claim set, the headless
check that proves the task, and the close-out rules. Hand-written prompts are what made Sequoyah the
courier; **anything a lane needs that isn't in the order is a bug in the docs, not a missing prompt.**

It refuses to issue an order whose claim set overlaps a live claim or another open order. That check
is the most important safety property once three lanes run at once: the claim system catches a
collision too, but only *after* a lane has spent quota getting to its first edit.

`--files` is optional. Without it the lane claims as it goes and collisions surface later, which is
strictly worse — pass it when you know.

### `dispatch` — headless, one task at a time

Never batch. One task per dispatch means a quota death costs at most one task.

### `report` — the standing answer to "what's happening"

Lane status, tokens and cost this window, what each lane is on, what's queued, what's parked. Read
this instead of watching three terminals.

---

## 4. Quota: how a wall stops costing you work

Running out is expected, not exceptional. The design assumption is that a lane *will* die mid-task.

1. **One task per dispatch.** A death loses one task, never a batch.
2. **Stop at 85% of a window, not 100%.** Set `budget_tokens` on a lane in `.agent/lanes.json` once
   you know its real cap; the director then holds it back early. A lane that dies mid-sentence cannot
   write its own handoff — the headroom is what makes the handoff possible.
3. **Death files the handoff the lane couldn't.** On any non-zero exit, `lane run` runs
   `agent handoff` under the lane's own identity: claims released, working diff untouched, journal
   entry naming the log, the token count, and the failure tail. **This is the mechanism that matters.**
   Without it a dead lane holds its claims forever and every other lane is blocked behind a corpse.
4. **Parked lanes are skipped,** until `exhausted_until`. Clear early with `lane reset <LANE>`.
5. **`agent reap`** frees claims from lanes whose process vanished — the backstop for exits too
   sudden for step 3 (closed laptop, OOM, `kill -9`).

Quota exhaustion is classified from the *failure text of a failed run only*, and the pattern demands
account-limit wording. This matters more than it sounds: MIRE is a netcode project, so `rate_limit_ms`,
`429`, and "too many requests" are ordinary vocabulary here, and a compile error that mentions them
must not park a healthy lane for five hours. Verify the classifier any time you touch it:

```bash
.agent/bin/lane selftest
```

---

## 5. Concurrency — what three lanes actually share

They share one working directory (D-037). Claims stop them touching the same file; two locks cover
the rest:

- **`agent godot --script tools/x_check.gd`** — always launch the engine this way, never bare. All
  ~49 checks share one 42 MB import cache and concurrent runs race on it (F-044).
- **`agent ship`** — takes the git lock automatically. Nothing to remember.

Godot-authored files (`.tscn` `.tres` `.import` `project.godot`) still need an exact claim and a
closed **editor** (D-021, D-031). `agent order` refuses such an order while the editor is open, and
checks for the real thing rather than trusting `pgrep -fl Godot`, which matches nine processes when
one engine is running (F-045).

---

## 6. Routing: which lane gets what

Classify by `AI-WORKFLOW.md`'s tiers first, then by area.

- **T0 → L0.** Editor work, `.tres` content, playtest. Free, and agents are bad at it. Never dispatch.
- **T1 with a written spec → LC1/LC2.** The default. Pick by area so claim sets don't overlap.
- **T1 needing more reasoning than a spec-follow → LP.** Multi-file refactors, glue across systems.
- **T2 → LD.** Netcode, world gen, the powerup framework, save/load, hard bugs. Expensive to get wrong.

**Fable (this account's scarcest resource) — specs only, never code.** One Fable turn producing a
design document that three cheap lanes then implement is the best conversion of premium quota into
shipped work available here. Spend it on M4 world generation and Mire replication, the powerup /
Resonance framework, and the save-format migration schema — in that order, and on nothing else.
Never on debugging: that is long loops and huge context, where Opus at medium is both better value
and, in practice, better.

---

## 7. When it goes wrong

| Symptom | Do this |
|---|---|
| `dispatch` says not logged in | `.agent/bin/setup-lanes`, run the login it prints |
| Lane parked but you know quota is fine | `.agent/bin/lane reset <LANE>` |
| Task stuck `in_flight`, no process | `agent reap` |
| `order` refuses — claim overlap | Order a different task. Do not work around it |
| Two lanes want one file | That's the system working. Split the task or serialise it |
| A lane's work looks wrong | `agent collect`, read its handoff and `.agent/logs/<LANE>-*.jsonl` |
| Everything feels stuck | `agent report` — it names the blocked lanes and why |
