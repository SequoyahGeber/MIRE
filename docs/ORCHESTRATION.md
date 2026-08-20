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
.agent/bin/setup-lanes               # creates the auth homes and per-lane config

.agent/bin/lane login LC1            # sign in — run these in YOUR terminal, they're interactive
.agent/bin/lane login LC2
.agent/bin/lane login LP

.agent/bin/agent lanes --doctor      # ✓ ready, or exactly what's missing
```

**An agent must never handle account credentials**, so the three logins are yours to run.

**Sign each into a *different* account.** This is the one step that silently ruins everything: your
browser is already signed into one ChatGPT account, so the ordinary browser flow reuses it and you
end up with `LC1` and `LC2` on a single quota pool — the exact thing the harness exists to avoid.
`lane login` therefore defaults Codex to **device auth**, which gives you a code you can enter in any
browser or profile. `--browser` opts out.

`lane doctor` asks each CLI's own `login status` / `auth status`, so "ready" means that account really
is signed in, not that a directory exists.

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

`--priority 1..9` sets where the order lands in its lane's queue: **1 drains first, 9 last, 5 is the
default**, and an order with no priority keeps plain task-id order, so a queue nobody ranks behaves
exactly as it always did. Rank the queue whenever one lane is doing all the work — a drain sorted by
F-number is sorted by *filing order*, the one attribute of an order that says nothing about how much
the work matters, and with a lane parking on its five-hour wall after a task or two, queue position
is days of latency rather than minutes (F-314). `agent report` prints "Orders waiting" in true drain
order with each rank shown, so that list answers "what will this lane do next".

### `dispatch` — headless, one task at a time

Never batch. One task per dispatch means a quota death costs at most one task.

### `report` — the standing answer to "what's happening"

Lane status, tokens and cost this window, what each lane is on, what's queued, what's parked. Read
this instead of watching three terminals.

---

## 4. Quota: unused is wasted, so keep the lanes full

**The counter-intuitive rule this whole section rests on: idle quota is burned quota.** Subscription
windows reset without carryover, so tokens left unspent when a weekly window rolls are simply gone.
Conserving them is not thrift — it is the most common way to lose them.

### The two windows do different jobs

Claude plans run a **5-hour session** and a **weekly** limit at once, and confusing them leads to the
wrong schedule:

| Window | What it is | Behaviour |
|---|---|---|
| 5-hour session | The **rate limiter** | Fills fast — two tasks took it 15% → 43%. This is what actually stops a lane. Resets every 5h |
| Weekly | The **real budget** | Moved only 73% → 76% over the same work. This is what expires unspent |

The consequence: **to spend the weekly budget you have to be working during each session window.**
Sleeping through a 5-hour park does not save anything — it forfeits a window's worth of weekly quota
that expires anyway. So:

```bash
agent saturate LP --watch
```

`--watch` sleeps out a short wall and resumes on its own, up to 4 times and never for more than 8
hours. It resumes **only** on a quota park; a task that failed for any other reason is left alone,
because retrying a broken task on a loop just burns the window it waited for.

So: **never hold a lane back to "save" quota.** If a window resets in six hours, the correct move is
to keep that account working until it does. The only genuine waste is a task that dies unfinished and
loses its work, and the fix for that is to *size the task to the remaining headroom* — smaller tasks,
not fewer. A nearly-empty window is still worth a review, a check, a doc pass, or one small
self-contained task.

The budget reserve exists for exactly one purpose — leaving enough headroom for a clean close-out —
and never as a savings account. `quota_advice()` therefore suggests a smaller task; it never blocks
one. Only a hard wall (`quota_block()`) refuses a dispatch.

Running out is expected, not exceptional. The design assumption is that a lane *will* die mid-task.

1. **One task per dispatch.** A death loses one task, never a batch.
2. **Keep ~15% for the close-out, and spend the rest.** Set `budget_tokens` once you know a lane's
   real cap. Past 85% the director switches to *smaller* tasks — it does not stop. A lane that dies
   mid-sentence cannot write its own handoff, and that reserve is the only reason the reserve exists.
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

### Autoloads are registered with a lock, not a claim

D-021 is right that a task shipping an autoload must register it in that same task — a script nothing
loads is not shipped. But a *claim* on `project.godot` is held for the task's whole duration, and
**five specs claim it** (2.11, 2.12, 2.13, 3.3, 3.6). Ordering any two of them at once was refused,
which would have collapsed three lanes back to one for most of M2 and M3.

A registration is one appended line, so it takes a lock instead:

```bash
agent autoload DayNight res://systems/environment/day_night.gd
```

Seconds, not an hour. It verifies the editor is closed, appends at the end of `[autoload]` so load
order is preserved, is idempotent, refuses a conflicting path, and never rewrites an existing line
(append-only, D-019). **`agent order` therefore drops `project.godot` from a derived claim set** and
tells the lane to use this instead — so the three M2 tasks above now dispatch to three lanes in
parallel with fully disjoint claim sets.

> Worth filing as a finding against `SPECS.md` (its blocks still list `project.godot` under
> **Claim:**) once `docs/FINDINGS.md` is free — it was held by the audit when this was written.

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

## 7. Running as the director — start here

If you have just been told "you are the director", this is your whole job:

```bash
.agent/bin/agent start          # names you, prints the board
.agent/bin/agent director --take  # claim the routing seat — nobody else may order/dispatch (D-145)
.agent/bin/agent report         # lane health, quota windows, what's queued
.agent/bin/agent collect        # what came back since last time — LEAD WITH THIS
```

**Claim the seat first.** `order`, `dispatch` and `saturate` refuse anyone but the director, and
until somebody takes it they are open to every session on the machine — which is how six unrouted
orders reached the lanes in one day, costing a duplicate dispatch and nearly a wasted window on a
finding a peer chat had already started (D-145). `agent director` shows who holds it; `--clear`
releases it when you hand off.

**You route and verify. You do not implement.** A director writing gameplay code has spent the
project's most expensive quota on work a cheap lane does as well. Your output is orders, routing
decisions, and judgement on what came back. The exception is this harness itself (`.agent/bin/*`,
this file) — that is yours.

### The loop, every time

1. `agent collect` — report what finished **to Sequoyah, in chat**. He cannot see the lanes.
2. `agent report` — is any lane idle while its window burns down? That is the failure mode.
3. Keep the queue full: `agent order <id> --lane <L>` then `agent saturate <L> --watch`.
4. Anything a lane cannot do (it is dry, or the task is T2 design), do it here on Max.

### Things that have already gone wrong — do not rediscover these

- **You are only alive when Sequoyah messages you.** The lanes are not: `.agent/bin/lane` is a plain
  Python wrapper with no quota that keeps running while this chat is closed. Never assume work stopped
  because you stopped.
- **You get no notification when a task finishes mid-chain** — only when the whole background command
  ends. So `agent collect` is the only reliable record. Run it before reporting, every time.
- **Never poll `pgrep -f "agent saturate ..."` to wait for a chain.** A shell whose script text
  contains that string matches it, so the wait never ends. `saturate` serialises on its own lock.
- **Exit 0 does not mean a task finished.** Judge by the board. This is handled in `_finish` now, but
  the same trap applies to anything else you wrap.
- **A model name belongs to its lane.** An order written for LC1 carries a Codex model; running it on
  LP hands that to Claude and the API returns 404. `lane run` now ignores a cross-lane model.
- **`api-equiv` dollars are not a bill.** Every lane is a subscription (`apiKeySource: none`).
- **Fable is for specs, never code** — see `AI-WORKFLOW.md` §2a. Three problems justify it.
- **Detaching a chain costs you the notification.** `saturate --watch --detach` is right — the queue
  survives the chat closing — but a daemon reparented to init cannot wake you when a lane lands. Arm
  a `Monitor` alongside it, on lane landings, lane errors, sustained idle and chain death, or the
  collect-verify-requeue half of your job silently stops until Sequoyah pokes you.
- **A red check is not a regression until you have diagnosed it.** Twice in one day the product was
  fine and the verification was not: F-086 was a false green (a finding marked `**fixed**` in the doc
  before its check ran, which `_sync_findings` then turned into a `done` board entry), and F-107 was a
  false red (a GDScript closure captured the peer id by value, so the *check* was wrong while
  `chest.gd` was correct all along). `agent baseline` proves a failure is not somebody's uncommitted
  work; it cannot tell you the check itself is lying. Do not report "regression in shipped code" off a
  red alone — that call was made here and was wrong.
- **Claim pressure, not quota, is often what stops routing.** At one point five peer chats held ~40
  files — six autoloads, the world gen and the whole art pipeline — and half the open findings were
  unroutable to a lane with quota to burn. When `order` refuses, that is the system working; route
  around it and re-check later, because claims clear in bulk when peers finish.
- **Size the queue to burn rate, not to your estimate of duration.** A queue sized for "this big task
  will eat the window" ran dry in fifteen minutes when the big task stalled early and the rest were
  quick. With one live lane, keep four to six orders parked; the cost of a too-deep queue is zero and
  the cost of a dry one is the window.
- **Read the quota message before believing the park time.** A lane's own failure body states its real
  reset ("try again at Aug 19th, 2026 8:57 PM"); the harness used to ignore that and guess five hours,
  parking a 39-hour wall three times in a row. `parse_reset` reads it now (F-096), but when a lane
  parks oddly, check `last_error` in `.agent/lanes.json` rather than trusting the countdown.
- **A lane parked past the 8h sleep ceiling never restarts itself.** `saturate --watch` stops cleanly
  and leaves the orders queued, which is correct and also permanent. Arm
  `.agent/bin/lane-revive <LANE> <iso-utc>` so the returning window is spent instead of watched.

## 8. When it goes wrong

| Symptom | Do this |
|---|---|
| `dispatch` says not logged in | `.agent/bin/setup-lanes`, run the login it prints |
| Lane parked but you know quota is fine | `.agent/bin/lane reset <LANE>` |
| Task stuck `in_flight`, no process | `agent reap` |
| `order` refuses — claim overlap | Order a different task. Do not work around it |
| Two lanes want one file | That's the system working. Split the task or serialise it |
| A lane's work looks wrong | `agent collect`, read its handoff and `.agent/logs/<LANE>-*.jsonl` |
| Everything feels stuck | `agent report` — it names the blocked lanes and why |
| A window resets soon and a lane is idle | Dispatch something. Anything unspent is lost at reset |
| A lane parks for 5h but you think it is dry for days | Read `last_error` in `.agent/lanes.json` — the CLI states its real reset. Re-park with `lane park`, then `lane-revive` |
| A lane is parked past `--watch`'s 8h ceiling | `.agent/bin/lane-revive <LANE> <iso-utc>` — nothing else will restart it |
| A check fails at HEAD | Diagnose before reporting a regression. `agent baseline` rules out a neighbour's working tree, not a wrong check (F-107) |
| A task is `done` but you never saw a close-out | `agent report` flags it. Its work may be unverified on disk — verify it yourself, then close it honestly or reopen it (F-086) |
| A headless run goes silent after a script error | `agent godot` kills it at 45s now (F-104). If you see that, fix the parse error — a `class_name` is invisible until the editor rescans; use `preload()` |
