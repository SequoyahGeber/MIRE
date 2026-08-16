# FINDINGS — problems noticed, not yet fixed

> **For the thing you spotted while working on something else.** You're deep in task 4.3 and you
> notice the inventory code double-counts stacks. Fixing it now blows your scope and your quota;
> saying nothing loses it forever. Write it here and move on.

This file is the gap between "I found a problem" and "there's a task for it." Nothing here is
scheduled. Nothing here blocks anyone. It exists so that a real observation survives the session that
produced it.

**This is not:**

- a bug tracker for the current task — fix those, or note them on the task with `agent note`
- a wishlist — features and design ideas go to `DESIGN.md` or the roadmap
- a decision log — settled calls with rationale go to `DECISIONS.md`
- a to-do list you're allowed to ignore forever — see *Triage* below

---

## How to file one

Append to the bottom of **Open**. Take the next `F-###`. Thirty seconds, not five minutes — if it
takes longer than that you're either fixing it or writing a spec, both of which belong elsewhere.

```markdown
### F-012 · Short statement of the problem

**Area:** netcode · **Severity:** medium · **Found:** 2026-08-20 by codex during 4.3

What's wrong, in a sentence or three. What goes wrong as a result — the concrete failure, not
"this is bad practice." Where it lives, as `path/to/file.gd:42`.

Optionally: what fixing it would take, if you already know.
```

**Severity** — what happens if this is never fixed:

| | Meaning |
|---|---|
| **high** | Ships broken, corrupts saves, desyncs players, or blocks a later milestone. Escalate to a roadmap task at the next triage. |
| **medium** | Real bug or real friction, survivable for now. The default. |
| **low** | Untidiness, a missing comment, a mild inefficiency. Fix it opportunistically when you're already in the file. |

**Be specific or don't file.** "The netcode feels fragile" is unactionable and will rot here forever.
"`net_transport.gd:88` retries forever with no backoff, so a dead host hangs the client on a black
screen" is a finding. If you can't name a file or a concrete failure, you have a hunch — sit on it
until it's a finding.

---

## Triage

**At the end of each milestone, the planner walks this file** and gives every open entry one of four
outcomes:

- **Promote** — becomes a numbered roadmap task, gets scheduled. Move to *Resolved*, noting the task id.
- **Fix now** — small enough to do inline during milestone cleanup.
- **Won't fix** — a deliberate call. Move to *Resolved* with the reason. This is a legitimate outcome;
  say why, so nobody refiles it.
- **Still open** — genuinely not worth acting on yet. Stays.

An entry that survives three triages without being promoted or fixed is probably a *won't fix* nobody
wants to say out loud. Say it.

Never delete an entry. Move it to *Resolved* with its outcome. The record of what we decided not to
do is worth as much as the record of what we did.

---

## Open

### F-001 · Pre-commit hook scans the working tree instead of the staged set

**Area:** tooling · **Severity:** high · **Found:** 2026-08-15 by claude during the §5a doc update

The claim check blocks a commit when *any* file in the working tree is claimed by another agent, even
when that file isn't staged. Committing `docs/ARCHITECTURE.md` while the nav agent had uncommitted
work on `world/chunk/nav_bake_probe.gd` was refused, and only went through with `--no-verify`.

This defeats the parallel-agent workflow that `MIRE_AGENT` was added to enable (`598523c`): any two
agents working simultaneously block each other's commits regardless of overlap. Worse, it trains
everyone to reach for `--no-verify`, which is exactly when the check would have caught a real
conflict.

Fix: check `git diff --cached --name-only` rather than `git status`.

---

### F-002 · Sprint-FOV lerp uses the framerate-dependent smoothing form

**Area:** gameplay feel · **Severity:** low · **Found:** 2026-08-15 by claude during the §5a doc update

`entities/player/player_camera.gd:66` uses `lerpf(camera.fov, target_fov, minf(fov_lerp_speed * delta,
1.0))`. This converges at slightly different rates at 60 vs 240 fps, so the sprint FOV punch feels
marginally snappier on faster hardware.

Purely cosmetic, and `ARCHITECTURE.md` §5a rule 6 explicitly permits the naive form for cosmetics —
but it wants a comment marking the choice as deliberate, which isn't there. Either add the comment or
switch to `1.0 - exp(-speed * delta)`.

Flagged mainly because this is the pattern most likely to get copy-pasted into something that *does*
affect gameplay.

---

### F-003 · Physics interpolation is off; §5a settings not yet applied

**Area:** rendering · **Severity:** medium · **Found:** 2026-08-15 by claude during the §5a doc update

`ARCHITECTURE.md` §5a requires four `project.godot` settings. None are set explicitly, and
`physics/common/physics_interpolation` defaults to **off** — so at 60 Hz simulation on a high-refresh
display, anything not directly player-controlled (remote players, enemies, physics props) will judder.

Blocked on Sequoyah: agents can't edit `project.godot`. Not urgent while the only moving thing is the
local player, who is updated in the same tick that reads input. It becomes visible the moment a second
player or the first enemy exists — **M1/M2**.

Raised in severity by the VRR case (§5a *Variable refresh rate*): interpolation is the load-bearing
fix there, and `physics_jitter_fix` must go to `0` at the same time or the two corrections fight.
Development happens exclusively on a ProMotion MacBook Pro (48–120 Hz adaptive), so this judder will
appear on the only machine we have long before anyone else sees it.

---

### F-004 · Interpolation is only planned for remote players, not enemies or props

**Area:** rendering · **Severity:** medium · **Found:** 2026-08-15 by claude during the §5a doc update

Task 1.6 covers remote-player interpolation. Nothing covers enemies (2.10, M5), physics props, or
harvestables — all of which move under host authority at replication intervals well below the render
rate, and will judder identically.

If F-003's engine-level `physics_interpolation` is enabled it may cover all of these at once, making
1.6's hand-rolled approach partly redundant. Worth resolving which mechanism owns this **before**
building 1.6, so we don't write and then delete a system.

---

### F-005 · R2's chunk benchmark excludes GPU upload cost

**Area:** worldgen · **Severity:** medium · **Found:** 2026-08-15 by terrain during 0.7

Spike R2 came back green at 0.330 ms/chunk, but ran under the headless dummy renderer — no GPU upload,
no material, no collision shape, no LOD. Its own writeup flags this.

The risk is that the green result gets treated as "chunk streaming is solved" when the measurement
excludes a cost that could dominate. Mesh upload and collision-shape creation are both real
main-thread work in Godot.

0.8 (R3) covers collision/nav baking. **GPU upload remains unmeasured by any planned spike** — worth
re-running the bench with a real renderer before 4.3 commits to a streaming budget.

---

### F-006 · Three roadmap tasks assume a Windows or Linux machine we don't have

**Area:** process · **Severity:** high · **Found:** 2026-08-15 by claude

Development happens exclusively on a 14-inch M5 Pro MacBook Pro, permanently — there is no second
machine and no plan to get one. Three tasks are written as though there is:

| Task | Assumes |
|---|---|
| **0.10** (M0) | Running `tools/check_determinism.gd` on Windows and Linux to fill in the `ARCHITECTURE.md` §6a baseline table |
| **1.12** (M1) | A Mac ↔ Windows ↔ Linux lobby over Steam |
| **7.12** (M7) | Testing each export on its real OS, plus Steam Deck |

**0.10 is the urgent one.** R6 asks whether seeded world gen diverges between macOS arm64 and Windows
x86_64. If it does, §4's "clients regenerate the world from a seed" design is invalid and the fallback
— host ships a compact heightmap — has to be adopted *before* M4 is built on the current assumption.
That question is unanswerable on this hardware, and it is a genuine architectural fork, not a
verification chore. The macOS column of the §6a table is filled in; the other two cannot be.

**Resolution path: VMs on the Unraid server.** Unraid is x86_64 and ships with KVM, so it can host
Windows and Linux guests on the architecture that actually matters here.

The distinction that decides where these VMs live:

| Host | Guest arch | Answers R6? |
|---|---|---|
| MacBook (UTM) | **arm64** | **No** — holds the CPU architecture constant, so it tests OS divergence only. A green result here would be misleading. |
| Unraid (KVM) | **x86_64** | **Yes** — this is the macOS-arm64 vs Windows-x86_64 comparison R6 is actually asking about. |

Use Unraid for anything determinism- or architecture-sensitive. UTM on the MacBook is still useful for
quick "does it launch on Linux" checks where architecture is irrelevant.

What this does and doesn't close:

- **0.10 — fully closed.** `check_determinism.gd` is headless and compute-only; no GPU, no display, no
  Steam. A Godot headless binary in an x86_64 Linux guest and an x86_64 Windows guest fills in both
  empty columns of the §6a table.
- **7.12 — partially, and the gap is now confirmed rather than hypothetical.** The server's GTX 1070
  is already passed through to Ollama and Plex, so it is not available to a VM without taking it from
  services in use. Guests will render in software. VMs therefore answer "does the export launch and
  behave correctly on this OS" — most of the value — but frame rate and rendering artifacts need real
  hardware. Steam Deck remains a separate purchase decision.
- **1.12 — partially, with friction.** LAN testing over `ENetMultiplayerPeer` works fine between
  guests. Testing the *Steam* transport needs a Steam client running in each guest and a distinct
  Steam account per instance, which is a real constraint worth planning for rather than discovering
  during M1.

Practical notes for whoever builds the guests: the host is a Ryzen 5 3600X with 32 GB, shared with the
Ollama and Plex containers — assume only part of that RAM is free, and don't run both guests plus a
loaded Ollama at once. Put the vdisks on the 2 TB NVMe, not the HDD array.

Worth noting for later: Zen 2 is also the Steam Deck's CPU architecture, so CPU-side determinism
results from this box are a closer proxy for the Deck than anything else available here.

Still worth a `DECISIONS.md` entry: "cross-platform verification happens on Unraid x86_64 VMs, with
these known gaps" is a standing decision that shapes M7 and M8, not just a finding.

---

## Resolved

_Nothing yet._
