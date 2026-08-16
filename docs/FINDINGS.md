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

**Correction, 2026-08-15 by nav after 0.8 landed:** 0.8 did **not** cover collision baking. R3 spiked
*navigation* baking only — `world/chunk/nav_bake_probe.gd` feeds triangles straight to Recast via
`NavigationMeshSourceGeometryData3D.add_faces()` and never creates a `CollisionShape3D`. Physics shape
cooking (`ConcavePolygonShape3D` from a chunk mesh) is a different code path and is still unmeasured
by anything. So this entry now covers **two** unmeasured main-thread costs, not one, and neither is on
the roadmap. Recorded in `DECISIONS.md` D-015 as the standing caveat on the R2 green result.

**Now tracked, 2026-08-16 by claude/planner:** both costs are task **`4.0a`** (Spike R2b), a gate at
the top of M4 that must clear before 4.1 starts — `ROADMAP.md` M4, prompt in `DELEGATION.md`. The nav
correction above was right that neither was on the roadmap; that was the actual defect here, since a
finding with no task ID is a finding that gets rediscovered too late. This entry stays open until
4.0a reports numbers, and 4.0a is explicitly required to run windowed rather than headless — running
headless is the specific mistake that produced this finding.

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

- **0.10 — approach confirmed, Linux column done 2026-08-15.** `check_determinism.gd` is headless and
  compute-only; no GPU, no display, no Steam. The Ubuntu guest ran it with no `sudo` and no extra
  packages — `wget` and `rsync` were already present, so the project went over by `rsync` from the Mac
  rather than `git clone`, sidestepping credentials on the guest entirely. Result in **D-017**: noise
  and PRNG are bit-identical, raw libm calls are not. The Windows guest still has to fill the last
  column. Practical note for whoever builds it: drive the guest over SSH, not the noVNC console —
  pasting in is awkward and copying results back out is worse.
- **7.12 — partially, and the gap is now confirmed rather than hypothetical.** The server's GTX 1070
  is already passed through to Ollama and Plex, so it is not available to a VM without taking it from
  services in use. Guests will render in software. **Second obstacle, found 2026-08-15 while building
  the Ubuntu guest:** Unraid reports the 1070 as the host's *primary adapter* ("GPU is primary adapter,
  vbios may be required"), so passing it to a VM also needs a dumped and patched vBIOS and risks
  leaving the host without console output. GPU passthrough here is not a checkbox; treat software
  rendering in the guests as the plan, not the fallback.

  **Sequoyah's call, 2026-08-15:** container contention is *not* a real constraint — Plex does not
  meaningfully need the card and Ollama can be paused on demand. So the only genuine obstacle to GPU
  passthrough is the primary-adapter/vBIOS work above. Do not cite the containers as a blocker. VMs therefore answer "does the export launch and
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

### F-007 · Forgetting `MIRE_AGENT` makes you silently impersonate the last agent to run `agent start`

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-15 by nav during 0.8/0.9

`whoami()` in `.agent/bin/agent:81` resolves identity as `MIRE_AGENT` → the shared `.agent/session`
file → die. The session file holds exactly one name, so whoever ran `agent start` most recently owns
it. With two agents live, the one that forgets the export silently acts as the other:

```
$ export MIRE_AGENT=nav && .agent/bin/agent check    ->  session: nav
$ env -u MIRE_AGENT   .agent/bin/agent check         ->  session: claude   # the other agent's start
```

The consequences are quiet and compounding. Claim checks are evaluated against the wrong agent, so a
real collision can pass. The `in_grace()` window at `:394` is keyed to `r["agent"] == me`, so a
mislabelled session also loses the 6-hour grace on its own just-released claims and gets warned about
files it legitimately owns — which is what produced the spurious warning on `bdf8587`.

This is a known trade-off, not an oversight: the comment at `:82` explains that `MIRE_AGENT` exists
precisely so parallel agents don't clobber the shared session file. The gap is that forgetting it
fails *silently* rather than loudly.

Fix, if we want one: warn when the resolved identity comes from the session file while claims exist
under a different agent — the one case where the fallback is probably wrong. Cheaper alternative: just
make "always export `MIRE_AGENT`" load-bearing in `AGENTS.md` rather than a parenthetical.

**Filed wrong twice, corrected here.** v1 blamed the hook for not inheriting the environment — false,
it inherits normally. v2 claimed a hardcoded fallback to `claude` — also false, there is no such
constant. Both were guesses made without reading `.agent/bin/agent`. Reading it took two minutes and
would have got this right the first time.

---

---

## Resolved

### F-003 · §5a project settings not applied — **fixed**

**Area:** rendering · **Filed:** 2026-08-15 by claude · **Fixed:** 2026-08-15 by sequoyah (`ba5945f`)

All six §5a settings are now explicitly written in `project.godot`, so the contract is visible in the
file rather than inherited. `physics_interpolation=true` with `physics_jitter_fix=0.0` closes the
high-refresh judder risk that motivated this entry — load-bearing on the ProMotion MacBook, which
would have shown it before any other hardware.

**The gotcha, kept because it is not obvious and cost time:** Godot's editor writes only settings whose
value differs from the engine default and prunes the rest on save. `physics_ticks_per_second=60`,
`max_physics_steps_per_frame=8`, `vsync_mode=enabled` and `max_fps=0` all *are* the defaults, so
setting them in Project Settings did nothing to the file and they silently disappeared. They had to be
written into `project.godot` by hand. Now folded into `ARCHITECTURE.md` §5a as a note under the
settings table, so the next person reads it before spending the ten minutes.

**Reopened and closed differently, 2026-08-15, same day:** the prune is not a one-time editor quirk —
it fires on *any* editor save, not just a Project Settings edit. Setting the main scene during task 0.5
resaved `project.godot` and silently dropped all four lines again, proving the original fix (hand-write
the lines) doesn't hold: the next resave strips them regardless of how they got there. Chasing file
presence for a value that equals the engine default is unwinnable, so this stopped being the goal.
`tools/verify_setup.gd` now checks the *effective* runtime value via `ProjectSettings.get_setting()`
instead of raw file text — correct either way the value is sourced, and it can only fail on the thing
that actually matters: someone changing a value away from the target. Genuinely closed this time
because it no longer depends on the file staying in a state Godot won't hold.

### F-001 · Pre-commit hook scans the working tree instead of the staged set — **fixed**

**Area:** tooling · **Filed:** 2026-08-15 by claude during the §5a doc update · **Fixed:** 2026-08-15 by nav

The claim check blocked a commit when *any* file in the working tree was claimed by another agent,
even when that file wasn't staged — so two agents working at once blocked each other regardless of
overlap, and it trained everyone toward `--no-verify`.

Fixed in `cmd_check`: when `GIT_INDEX_FILE` is set, git is running us as a hook, so we judge
`git diff --cached --name-only` — what is actually being committed. Run by hand, `agent check` still
scans the working tree, which is the useful scope there. Falls back to the working tree if the diff
fails (e.g. a repo with no HEAD yet) rather than failing open.

Detecting the hook via `GIT_INDEX_FILE` rather than adding a `--staged` flag was deliberate: the
installed hook in `.git/hooks/` is not version-controlled, so a flag would have needed every clone to
re-run `install-hooks` before the fix took effect.

Verified: with `codex` holding a dirty unstaged `world/chunk/chunk_mesher.gd`, committing an unrelated
staged file now passes; staging `chunk_mesher.gd` itself still blocks.

Noted while testing: `FREE_PREFIXES` (`:32`) exempts `docs/`, `.agent/`, `CLAUDE.md`, `AGENTS.md`,
`README.md` and `.gitignore` from claim checking entirely. Claiming a docs file is therefore
ceremony — harmless, and still useful as a signal to other agents, but it is not enforced.

### F-008 · CLAUDE.md's close-out order makes the hook warn on your own files — **won't fix, not a defect**

**Area:** process · **Filed:** 2026-08-15 by nav during 0.8 · **Resolved:** 2026-08-15 by nav, same day

Filed on the belief that `CLAUDE.md`'s "`agent done`, then commit" ordering causes
`⚠ <file> — edited without a claim`, because `done` releases claims before the commit runs.

**It doesn't.** `.agent/bin/agent` already handles this: `cmd_done` records released files under
`st["recent"]` (`:287`) and `in_grace()` (`:394`) suppresses the warning for `RECENT_GRACE_HOURS = 6`.
The documented order is fine and needs no change.

The warning on `bdf8587` had a different cause. `in_grace()` matches on `r["agent"] == me`, and that
commit resolved `me` to `claude` rather than `nav`, so the grace record didn't match — a symptom of
**F-007**, not of the ordering. Fixing this here would have treated the symptom and left the cause.

Kept as a record so nobody refiles it. Anyone who sees this warning after a correct close-out should
check their `MIRE_AGENT`, not the docs.
