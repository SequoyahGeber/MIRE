# Decision log

One entry per decision that would be expensive to reverse. **Append, never rewrite the reasoning.**
When you change your mind, add a new entry that supersedes the old one — the reasoning you rejected
is as valuable as the reasoning you kept, and future-you (or an agent) will otherwise re-litigate it
for free. The one permitted retro-edit is a one-line `*Superseded by D-0NN.*` pointer under a
superseded entry's heading, so nobody reads a dead rule as live (D-007, D-012, D-014 and D-005 all
carry one).

Format: `D-NNN · date · decision · why · what would change my mind`

---

### D-001 · 2026-08-15 · Engine: Godot 4.7, pinned
Staying in Godot rather than moving to Unity (which Muck used). You already know it; the project is
already configured with Forward+ and Jolt; the high-level multiplayer API fits host-authoritative co-op
well; no revenue share; text-based project files work well with AI agents and git.
**Pinned version matters** — GodotSteam breaking on a point release produces long, confusing, expensive
debug sessions. Do not upgrade mid-milestone.
**Would change my mind:** spike R2 or R3 (`ARCHITECTURE.md` §6) failing catastrophically with no viable
fallback.

### D-002 · 2026-08-15 · Networking: host-authoritative listen server
No dedicated servers, no host migration, no rollback. Host runs the sim; clients predict their own
movement only. This is what Muck does and it's correct for 3–6 friends.
**Would change my mind:** wanting public matchmaking with strangers (would need dedicated servers and
actual anti-cheat).

### D-003 · 2026-08-15 · Multiplayer built first, before gameplay (M1)
Retrofitting multiplayer is the single most common way co-op hobby projects die — it means rewriting
every system that touches state, which is most of them. Given that quota is the binding constraint, a
rewrite of that size is not survivable.
**Would change my mind:** nothing. This one is load-bearing.

### D-004 · 2026-08-15 · First-person, viewmodel arms only
No full-body character animation pipeline, no locomotion blend trees, no IK, no third-person camera
collision. Saves an estimated 4–6 months of a skill you don't currently have. Muck proves FP melee works.
**Would change my mind:** playtesters consistently reporting they can't read melee range in FP. Mitigate
first with better hit feedback before considering third-person.

### D-005 · 2026-08-15 · Art: CC0 low-poly packs (Quaternius / Kenney), hero assets swapped later
*Superseded by D-038 — the art is authored in Blender in-house; no CC0 pack was ever imported.*
$0, no attribution burden, and stylistically close to Muck already. Removes art as a blocker entirely
and defers all art cost until the project has proven it will survive.
**Would change my mind:** the game succeeding and the generic look becoming the main criticism. That's a
good problem, and the fix is commissioning hero assets, not restarting.

### D-006 · 2026-08-15 · Content is data (`.tres` Resources), not code
Items, powerups, recipes, enemy stats, Cycle Modifiers all live in Godot `Resource` files loaded at boot.
Framework built once with premium quota; content authored by hand in the inspector for free.
**This is a direct quota optimization** — it makes the 60th powerup cost the same as the 2nd, and zero
tokens either way.
**Would change my mind:** nothing. This gets more correct the longer the project runs.

### D-007 · 2026-08-15 · Agents write scripts; the human wires scenes
*Superseded by D-031.*
Godot `.tscn`/`.tres` files do not merge — they carry internal sub-resource and node-path IDs that
conflict badly and can silently corrupt. Restricting agents to `.gd` files makes parallel agent work
safe, and happens to match what each party is actually good at.
See `AI-WORKFLOW.md` §3.
**Would change my mind:** nothing, until Godot scene files become mergeable.

### D-008 · 2026-08-15 · Develop against Steam App ID 480 until M8
Valve's public test app. Full lobby + P2P + overlay with no Steamworks account and no $100. Defers all
cost and paperwork until the project has proven it will ship.
**Would change my mind:** needing achievements or Steam Cloud earlier than expected (both require a real
App ID).

### D-009 · 2026-08-15 · No win condition — endless Cycles with voluntary extraction
*Supersedes the original three-act, boss-at-the-end structure.*
Runs escalate forever via stacking Cycle Modifiers until the island is consumed or the team wipes. The
shipwreck is reframed from win condition to voluntary cash-out.
Three reasons this is better: (1) replayability comes from stacking modifiers rather than authored
content, which scales far better for a solo dev; (2) it removes a final boss — a large, risky, gating
chunk of work; (3) the ending is emergent (the island runs out) rather than something you have to
design, balance, and justify.
The "one evening" identity is preserved by the extraction decision and by tuning the wall to ~2–2.5h,
not by a timer.
**Would change my mind:** playtests showing nobody ever extracts (Q6) *and* the reward curve can't be
tuned to fix it — at which point reconsider a soft cap.

### D-010 · 2026-08-15 · A run is one sitting; no save/resume
Serializing world mutations, entity state, inventories, powerups, and the Mire grid is a large,
bug-prone body of work, and it's the kind of bug that only shows up in front of friends.
**Would change my mind:** 2h+ runs proving to be a real scheduling problem for your group in practice.
This is the #1 post-launch feature candidate.

### D-011 · 2026-08-15 · Multi-agent coordination via files in the repo, not a service
Three agents (Claude Code, Codex, human) share state through `.agent/state.json`, a generated
`.agent/BOARD.md`, and an append-only `.agent/JOURNAL.md`, driven by one small script `.agent/bin/agent`.
Chosen over a hosted tracker or MCP server because: every agent can already read files; it versions with
git for free; it costs almost nothing in tokens to read; and there's no service to break or authenticate
against. `AGENTS.md` is the protocol (now a cross-tool standard read by Codex, Cursor and others) and
`CLAUDE.md` is a thin pointer at it, so the rules live in exactly one place.
Enforcement is mechanical, not honour-system: a git pre-commit hook runs `agent check`, which blocks any
agent from editing a file another agent holds. For Godot-authored files it additionally requires an
exact-file claim and confirms the editor is closed (D-031). A protocol that relies on agents
remembering to follow it will not be followed.
**Would change my mind:** agents working concurrently often enough that file claims become a bottleneck —
at which point move to git worktrees per agent instead of claims.

### D-012 · 2026-08-15 · Agents may touch scene/config files only by claiming them **by name**
*Amended by D-031.*
The blanket ban made bootstrapping impossible — someone has to create `player.tscn` and write the input
map before there is anything to run, and doing that by hand in the editor is a 30-minute typo hazard on
action names the code reads by string.
The amendment: an agent may edit `.tscn`/`.tres`/`project.godot` **only** when it holds an explicit
claim naming that exact file. D-031 adds `.import` and requires Godot to be closed. Drifting into a
scene file is still blocked by the pre-commit hook. This
keeps the protection where it mattered (no accidental scene edits, no two parties in one scene) while
making deliberate, logged bootstrapping possible.
In practice the agent should still generate scenes *via a Godot tool script* rather than hand-writing
`.tscn` text, so Godot serialises its own formats — see `tools/setup_project.gd`.
**Would change my mind:** an agent corrupting a scene the human was actively working in. Then go back
to the blanket ban and accept the manual setup cost.

### D-013 · 2026-08-15 · Ship macOS + Windows + Linux, with cross-play, as a first-class constraint
Not a port done later. Steam P2P is platform-agnostic, so cross-play itself is nearly free — but it
imposes one real architectural risk: §4 has clients regenerating terrain from a shared seed, and
transcendental float results are not guaranteed identical across CPU architectures *or C libraries*.
Divergence would put two players in the same lobby on different islands.
`tools/check_determinism.gd` makes this measurable; the macOS arm64 baseline is recorded in
`ARCHITECTURE.md` §6a. Windows and Linux must be measured before anything is built on §4 (task 0.10).
Native Linux additionally makes Steam Deck support nearly free, and Linux's case-sensitive filesystem
surfaces a whole class of export bug early.
**Would change my mind:** hashes diverging. Then the host ships a compact heightmap and clients stop
regenerating — costs join bandwidth, removes the risk entirely.

### D-014 · 2026-08-15 · Claude Code (this session) is the planner; Codex and the second Claude are coders
*Superseded by D-020 (any agent takes any task), and the scheduling half by D-036 (director + lanes).*
Planner owns: design, architecture, roadmap and task breakdown, decisions, specs, and reviewing work
that lands. Coders own: implementing claimed tasks in `.gd`.
This concentrates the scarce premium quota on exactly the work `AI-WORKFLOW.md` §2 calls Tier 2 —
decisions that are expensive to get wrong — and pushes implementation toward the cheaper plans. It also
matches the constraint that the binding limit is tokens, not hours.
Consequence: the planner writes specs precise enough that a coder needs no exploration, since
exploration is the single most expensive agent activity.
**Would change my mind:** the coders producing work that needs so much rework that planning-then-
delegating costs more than doing it directly.

### D-015 · 2026-08-15 · R2 is GREEN — chunked terrain meshing stays in GDScript
`tools/bench_chunks.gd` builds a 32 m chunk (33×33 verts, 2048 tris) in **0.330 ms single-threaded**,
or 0.112 ms/chunk amortized through `WorkerThreadPool` — 24× under the 8 ms threshold, so we can
build 50 chunks in a single main-thread frame before threading enters the picture. `SurfaceTool` is
7% slower than writing `ArrayMesh` arrays directly, which is close enough that we use whichever reads
better. Memory is 43 KB/chunk live. Seeded generation is deterministic (same seed → identical verts),
which R6 still has to confirm holds across platforms.
No GDExtension, no C#, no threading until something proves it necessary.
**Would change my mind:** the two costs this spike did not measure turning out to dominate — GPU
upload (it ran headless against the dummy renderer) and **collision shape generation, which is still
untested**; R3 measured *navigation* baking, not physics. If `ConcavePolygonShape3D` cooking costs
more than the mesh build, chunk streaming gets rebudgeted around it, not around mesh generation.
**Both are now task `4.0a` (Spike R2b), a gate before 4.1** — this verdict is provisional until it
reports (`FINDINGS.md` F-005).

### D-016 · 2026-08-15 · R3 is GREEN — runtime NavMesh baking stays; enemy AI keeps NavigationServer3D
`tools/bench_navbake.gd` measured **0.034 ms of worst-case main-thread block across a realistic
24-chunk streaming episode** (bake, attach, retire a 3×3 live window), against a 2 ms budget. The
blocking bake costs 9.2 ms per 32 m chunk — 55% of a frame — so the rule is that
`bake_from_source_geometry_data_async` is the only bake we ever call; submitting one costs 0.004 ms
and attaching the finished region to a live map costs 0.003 ms. **The grid-A*-on-heightmap fallback
in `ARCHITECTURE.md` §6 R3 is not needed**, and we keep off-mesh links, dynamic obstacle avoidance
and `NavigationAgent3D` steering for free. R3 was the risk most likely to reshape the enemy design;
it didn't.
Chunk seams connect, but not with the defaults and not by the obvious route. Independent bakes leave
a hole exactly `2 × agent_radius` wide (1.00 m measured) because Recast erodes inward from the
geometry edge, and the default `edge_connection_margin` of 0.25 m cannot bridge it — agents simply
cannot path across a chunk boundary. **Set `map_set_edge_connection_margin` above 2 × agent_radius**
(1.10 m for our 0.5 m radius). `filter_baking_aabb` and `border_size` both *shrink* the result and
make it worse; a negative control confirms the wide margin does not link chunks 32 m apart.
Consequences for M4: one bake in flight at a time (16 fired in one frame blocks 6.8 ms), `cell_size`
stays at 0.25 m (scaling is steeply superlinear — 0.1 m costs 80.7 ms), per-chunk bakes rather than
one large region (a 4×4 bake costs 7.3 ms/chunk vs 9.6 ms for a single chunk, so there is nothing to
amortize), and map `async_iterations` stays on. Pathfinding is host-authoritative per §2.2.
**Would change my mind:** the block reappearing once real geometry — rocks, structures, `MultiMesh`
scatter — is in the source data rather than a bare heightmap, or the 1.10 m margin bridging terrain
that should stay separated once cliffs and water exist. Either pushes us to bake with
`agent_radius = 0` (measured: 0.00 m gap, connects on the default margin) and carry the agent radius
in `NavigationAgent3D` instead.

### D-017 · 2026-08-15 · R6 is GREEN for macOS↔Linux — §4 shared-seed world gen stands, and transcendentals are banned from it
*Windows column closed by D-028 — the conditional verdict is now final for all three desktop targets.*
`tools/check_determinism.gd` on macOS arm64 and Linux x86_64 (Godot 4.7.1-stable `a13da4feb`, both):
`rng_sequence`, `noise_simplex` and `noise_perlin` are **bit-identical**; `float_math` is not
(`063eec62c34fa4ee` vs `187304c753e6e1ce`). A follow-up per-operation probe put the divergence exactly
on the IEEE-754 line. Correctly-rounded-by-spec operations match everywhere: `+ − × ÷`, `sqrt`, and
`Vector2/3.length()` built on it. Everything routed to the platform's libm diverges by ~1 ULP:
`sin`, `cos`, `tan`, `exp`, `log`, and `pow` at any exponent. **`FastNoiseLite` is in the safe group** —
integer hashing plus polynomial interpolation, it never calls libm — and it is the thing that actually
generates the island.

So the §6 R6 fallback (host ships a heightmap) is **not adopted**. Clients keep regenerating from a
seed, and the cost is a coding rule rather than join bandwidth: `ARCHITECTURE.md` §7 now bans
transcendentals from anything regenerated from a seed, and §4's island falloff becomes `1.0 - d*d*d`
instead of `1.0 - pow(d, 3.0)` — exact, and faster. Outside world gen they remain fine.

Method note: measured on an Unraid KVM guest, because the guest is x86_64. A UTM guest on the MacBook
would have held the CPU architecture constant and returned a green result that meant nothing (F-006).
The trap this decision avoided is the reverse of the obvious one — the risk register expected noise to
break and it didn't; what broke was the falloff maths nobody was worried about.

**Would change my mind:** (1) **Windows x86_64 disagreeing on `rng_sequence` or `noise_*`** — MSVC is a
third C library and is still unmeasured; that result would reinstate the fallback outright. (2) World
gen needing `TYPE_CELLULAR` or domain warp, which are separate code paths and untested. (3) Any future
requirement for lockstep simulation beyond terrain, where the ban would have to widen from world gen
to all shared simulation and would start costing real ergonomics.

---

### D-018 · 2026-08-15 · Task 0.5 movement feel — tuned values for `player_controller.gd`
Sequoyah played the greybox (ramps, stairs, gaps) and tuned live. Verdict: acceleration, friction,
jump height, coyote/buffer time and jump-cut all felt right at their defaults and are untouched.
Three values moved:

| | was | now |
|---|---|---|
| `walk_speed` | 5.0 | **4.0** |
| `sprint_speed` | 8.0 | **6.0** |
| `gravity_scale` | 1.6 | **2.0** |

Walk/sprint came down — Muck-fast read as too fast once there was real geometry to navigate, not just
open ground. Gravity went up so falls read heavier; `jump_height` (1.1, apex in metres) is unchanged
and unaffected, since launch velocity is derived from `gravity_scale × jump_height` — raising gravity
alone shortens time-to-apex without changing how high the jump reads.
Written into the script defaults directly rather than left as a live Inspector override, so a fresh
Player instance — or anyone who resets to defaults — doesn't silently revert to the untuned feel.
**Would change my mind:** the values reading differently once ramps/stairs/gaps are dressed with real
art instead of greybox, or co-op play at 3–6 players surfacing a pace mismatch invisible solo.

### D-019 · 2026-08-15 · Stop pinning default-equal project.godot settings by hand — check effective values instead
F-003 was "fixed" twice by hand-writing four settings into `project.godot` that equal the engine
default. Both times an unrelated editor save (once a Project Settings edit, once just setting the main
scene) silently pruned them again. That's not bad luck — Godot's editor prunes any setting matching the
default on *every* save it performs, regardless of how the value got there, so hand-writing it is not a
fix, it's a fix with a timer on it.

Sequoyah caught this: "I don't think it matters... that's why they disappeared before, no?" — correctly
identifying that the second fix attempt (mine) was about to repeat the first one's mistake.

`tools/verify_setup.gd` now asserts the effective value via `ProjectSettings.get_setting()`, which
returns the override when present and the engine default otherwise — correct either way, and it only
fails on the case that's actually dangerous: a value changed *away* from the target, which (unlike the
default) does persist on save. `ARCHITECTURE.md` §5a no longer instructs pinning these by hand.
**Would change my mind:** a future Godot version changing one of these defaults — the actual protection
against that was always "pin the Godot version, don't upgrade mid-milestone" (already policy), not file
text, since file text couldn't survive an editor save either way.

### D-020 · 2026-08-15 · Drop fixed planner/coder roles — any agent takes any task, allocated by quota
*Supersedes D-014's role assignment.* D-014 pinned "Claude Code chat = planner" and "Codex, second
Claude = coders" as fixed identities. Sequoyah: "I don't want specific roles for specific instances of
Codex or Claude. They can all do any task I set to them. What they get just depends on what usage
quotas are available."
The underlying reasoning in D-014 — concentrate expensive decisions, push implementation to whichever
plan has quota room — still holds and isn't rejected here, only the binding of specific roles to
specific agent identities. Any agent (this chat included) may implement `.gd` code; task assignment
follows quota availability, not a fixed table.
**Would change my mind:** quota contention making it valuable again to reserve one plan strictly for
planning — but that would be re-decided explicitly, not assumed from D-014.

### D-021 · 2026-08-16 · Agents wire their own autoloads; the blocker is the editor, not permission
*Amends D-012, does not repeal it.* D-012 already allowed an agent to edit `project.godot` when it
holds a claim naming that file, but every prompt in `DELEGATION.md` said "tell me what to register and
I'll do it" — stricter than the rule, and the reason task 2.2 shipped a `Registry` autoload that
nothing loaded. Sequoyah: "Why are the agents telling me to do stuff? Why can they not do this
themselves? They should just have permissions to do whatever they need within the project folder."

He's right that nothing was ever blocking them but our own prompt text. So: **a task that produces an
autoload registers it, in the same task, under a claim naming `project.godot`.** Shipping a script
nobody loads is not shipping.

This decision's former human-only scene restriction is superseded by D-031. Scene and resource files
remain higher-risk than `project.godot`, but agents may now edit them under an exact claim while the
editor is closed.

**The one real condition, and it is not about trust:** an agent must confirm the Godot editor is not
running before touching `project.godot`. The editor rewrites that file on save and prunes any setting
equal to the engine default (D-019, F-003 — "fixed" twice, un-fixed itself both times). An agent's
edit made while the editor is open is silently discarded. This is a race, not a permission, and no
amount of access changes it.

**Would change my mind:** an agent's `project.godot` edit corrupting the file or clobbering an editor
change despite the check. Then registration goes back to being handed over as a checklist — but as a
deliberate reversal, not by prompt text quietly contradicting the decision log again.

### D-022 · 2026-08-16 · GodotSteam pinned to GDExtension 4.21; binaries reinstalled, not committed
Task 1.1. Installed the **GodotSteam GDExtension 4.4+** addon — GodotSteam 4.21, Steamworks SDK 1.65 —
into `addons/godotsteam/`. It loads in the **stock** Godot 4.7.1 editor and stock export templates, so
D-001's "no custom engine build" holds and R5 stays a version-pin problem rather than a build problem.

**The upstream moved to Codeberg.** GodotSteam is no longer developed on GitHub. The addon is the
`gdextension-plugin` branch of `codeberg.org/godotsteam/godotsteam`, pinned at commit
`50cc0b515b749d98940fc3bb42624b139435b6f1` ("Updated to 4.21", 2026-07-29) — which is the exact commit
the Godot Asset Store serves for that asset, so a manual install and an in-editor AssetLib install are
the same bits. Reinstall:

```bash
curl -fL -o /tmp/gs.zip https://codeberg.org/godotsteam/godotsteam/archive/50cc0b515b749d98940fc3bb42624b139435b6f1.zip
unzip -q /tmp/gs.zip 'godotsteam/addons/godotsteam/*' -d /tmp/gs && cp -R /tmp/gs/godotsteam/addons/godotsteam addons/
```

The addon binaries remain ignored, but `.godot/extension_list.cfg` is committed as the sole tracked
file under `.godot/`. Keep it beside the reinstalled addon: without that registry, a fresh headless
environment does not load the GDExtension even when every binary is present (F-009).

**The 95 MB of platform binaries are gitignored, not committed.** Seven platform folders of `.dylib`/
`.dll`/`.so` would sit in git history forever, and again on every GodotSteam bump, to save one command
that is written down above. The Linux test VM syncs by rsync, not git, so it gets them regardless. The
pin is the commit hash, not the bytes.

**Two things this pins beyond the addon.** The engine is pinned at `4.7.1.stable.official.a13da4feb`,
asserted by `tools/steam_check.gd` so an accidental engine upgrade fails a check instead of surfacing
as a confusing Steam bug three tasks later. And `steam_appid.txt` (App ID 480, Spacewar — `STEAM.md`
§2) is committed so the game can initialise Steam when launched outside the Steam client; **it must not
ship in a release build**, which is M8's job when the real App ID lands.

**Would change my mind:** a Godot point release the extension can't follow, or needing a feature only
the compiled module build exposes — either would force the custom-engine-build path D-001 avoids.

### D-023 · 2026-08-16 · Replication nodes are built in code, never authored in a scene
Tasks 1.5, 1.6 and 1.8 sat blocked in `DELEGATION.md` for one reason: `MultiplayerSpawner`,
`MultiplayerSynchronizer` and `SceneReplicationConfig` were assumed to be editor work, which put them
behind D-007's scene-file wall and made four M1 tasks wait on a human. **They don't have to be.** All
three have a complete script API, and task 1.9's spike prompt already required building them in code
because a headless benchmark can't author scenes. What was true for the spike is true for the game.

So: **replication nodes are created in code**, by the script that owns them, identically on every peer.
That last word is the whole constraint — the high-level multiplayer API matches nodes by path, so host
and client must run the same construction code and arrive at the same names. A synchronizer built in
`_ready()` on a scene both sides instantiate satisfies this for free; one built conditionally does not.

Two consequences worth writing down, because they're the parts that look like scene decisions:

- **Networked players live at `/root/<spawner autoload>/Players`, not under the level.** A fixed path
  is identical on every peer and survives the level swaps M4 introduces. Levels are scenery; players
  are session state and outlive them.
- **A player instance placed in a level scene is a spawn point, not a player.** `greybox_test.tscn`
  has one hard-instanced `Player`. On session start the spawner reads its transform, frees it, and
  spawns per-peer copies. Offline, nothing happens and it stays the player you walk around with — so
  "open the project and press Play" keeps working with no scene edit.

**Would change my mind:** a code-built `SceneReplicationConfig` resolving differently on host and
client at the pinned build — that would be a real reason to author it as a `.tres`. Note that even
then the fix is a resource authored in the inspector and loaded by code, not a `.tscn` edit (written
when D-007 stood; D-031 now permits scene edits, and the preference for code-built replication config
still holds). Wanting to tune replication intervals in the inspector is the same story: export the
values, keep the construction in code.

---

### D-024 · 2026-08-16 · `&"synced"` counts synchronizers, not entities
F-013 left a real choice open: the debug panel's synced count is either "every `MultiplayerSynchronizer`"
or "every replicated entity root", and those give different numbers the moment an entity carries more
than one. **It counts synchronizers**, one member each, because the number exists to be read against a
bandwidth budget — 1.9 measured cost per *update stream*, not per entity, and an entity that sends
twice should read as two. The group name lives once, as `NetConfig.SYNCED_GROUP`, and is joined at
construction beside the authority assignment, so a new construction site cannot silently opt out.

**Would change my mind:** 1.8 giving one entity several synchronizers at different intervals, where a
count of streams stops matching anything a human wants to know. Then the panel shows both — entities
and streams — rather than redefining this group.

---

### D-025 · 2026-08-16 · Interest management has hysteresis, and it is evaluated on the physics tick
Two calls inside task 1.8, both of which look like tuning and are not.

**One radius became two.** An entity is visible to a peer inside `INTEREST_ENTER_RADIUS_M` (120 m,
§2.5's number) and stops being visible outside the larger `INTEREST_LEAVE_RADIUS_M` (144 m); between
them the answer is whatever it was last evaluation. This is not smoothing — losing visibility
*despawns* the entity on that client and regaining it *respawns* it, both on the reliable channel, so
a single radius makes an entity standing on the boundary pay a spawn packet per peer per tick. 1.9
measured the bill without being able to name it: clustered players cost 100 KB/s and spread ones 180
KB/s at an *identical* 11.6% visible fraction, with the difference falling on reliable traffic and
host ACK volume at ~2×. 24 m of band is ~2 s of closing at sprint speed, so the worst case becomes
one transition every couple of seconds. `NetInterest.RadiusFilter.transitions` counts them, so the
next person can measure this instead of inferring it.

**`VISIBILITY_PROCESS_PHYSICS`, not `IDLE`.** How often visibility is re-evaluated decides how much
spawn/despawn traffic a given amount of movement generates, which makes it a bandwidth decision, and
§5a is unconditional that nothing about how the game plays may follow the monitor. On `IDLE` a 240 Hz
host would re-evaluate four times as often as a 60 Hz one and pay up to four times the churn for the
same walk. `PHYSICS` is 60 Hz on every machine.

**Would change my mind:** on the band — a measurement showing hysteresis costs more in stale
subscriptions (an entity kept for 24 m past the point anyone can see it, times every peer) than it
saves in churn. Widen or narrow the band then; do not go back to one radius. On the tick — evidence
that 60 Hz evaluation is a CPU problem at real entity counts. It is not one today: 1.9 measured
replication as bandwidth-bound, peaking at 1.18 ms of a 16.67 ms frame. The answer then is to
evaluate on a slower accumulator, still not to hang it off the render frame.

---

### D-026 · 2026-08-16 · Engine physics interpolation and network interpolation are both needed, and they fight
F-004 asked which mechanism owns smoothing before 1.6 was written, since `physics_interpolation=true`
has been on project-wide since F-003 and might have made 1.6 redundant. It does not, and the two are
not alternatives. Engine interpolation smooths the **60 Hz physics grid up to the render rate**;
replication arrives at **30 Hz, at arbitrary idle-frame times, with jitter and loss**, so a 33 ms
staircase survives a 16.7 ms smoothing window — and the engine could not jitter-buffer it even in
principle, because it has no notion of when a packet arrived. Measured, not argued
(`tools/interp_check.gd`, and the control stream is read through `get_global_transform_interpolated()`
so the engine's own smoothing is included in it): **engine interpolation alone leaves 67% of frames
motionless with a per-frame-distance CV of 1.64; adding snapshot interpolation gives 1.5% and 0.21.**

They also actively conflict. A node driven every rendered frame by `RemoteInterpolator` must have
`physics_interpolation_mode = OFF`, or the engine resamples our already-smooth output back onto the
60 Hz grid and adds a tick of lag doing it. `configure()` sets that, and `_exit_tree()` puts it back.

Consequences worth stating, because they are not obvious from either half:
- **Interpolation is client-local presentation** (§2.2, last row), not replication. Its constants
  live in `core/net/remote_interp.gd`, deliberately **not** in `NetConfig` — nothing in NetConfig may
  differ between peers, and every one of these may.
- **Nothing gameplay-authoritative may read an interpolated transform.** The host speed check reads
  the replicated value, which this never touches, and must keep doing so.
- The delay is **derived from the observed arrival interval**, not configured, so the same component
  covers 15 Hz enemies and on-change props without a second set of numbers — the rest of F-004.

**Would change my mind:** Godot growing a transform-history/interpolation mode that is fed by
arrival time rather than physics ticks. Then this becomes a thin adapter over it. Also — if profiling
ever shows the per-frame `_process` write is the cost at hundreds of interpolated entities, the fix is
to drive the buffer on the physics tick and let engine interpolation cover the last hop, accepting one
tick of extra lag. That is a real alternative for enemies; it is the wrong trade for players.

---

### D-027 · 2026-08-16 · Session admission is host policy, with two backend slack connections
`NetSession` is the host-authoritative policy layer for capacity and temporary join closure;
`NetTransport` remains the mechanism that accepts, announces, and closes peers. ENet accepts two
connections beyond `MAX_CLIENTS` so simultaneous over-capacity joiners reach the policy layer and
receive a reliable human-readable refusal before disconnect, rather than timing out at the socket.
Capacity/policy checks run before `peer_joined`, so refused peers never spawn. Protocol version is
checked by a client hello immediately after connection; a mismatch may exist for a few milliseconds
and is then refused and despawned through the same notice/flush/close path.

**Would change my mind:** a measured denial-of-service or backend resource problem from the two slack
slots, or Godot exposing a pre-admission authentication callback that can deliver a structured refusal
without first admitting the peer. Either would move version checking earlier; neither changes host
authority over admission.

---

### D-028 · 2026-08-16 · R6 is GREEN on Windows too; shared-seed world generation is cleared for M4
The last unmeasured platform is now measured. A physical Windows 11 25H2 x86_64 PC (Ryzen 5 5600)
ran `check_determinism.gd` and `check_determinism_ops.gd` twice on the pinned stock Godot
`4.7.1.stable.official.a13da4feb`. Both runs were internally identical. The three values that build
the island matched macOS arm64 and Linux x86_64 exactly: `rng_sequence 0077d6b42cd6f78f`,
`noise_simplex 181e558b7b4841cf`, and `noise_perlin 6c7a944516e3e64f`. The safe operation group also
matched macOS exactly: `arith a26c08c6939c9c70`, `sqrt 8df50e64f11d53c4`,
`vec2_length baa1bfdb8ba31f7b`, and `falloff_safe fd601eb57df68bf0`. Windows `float_math` was
`9a92d5895a7daf08`, different from both other platforms exactly where D-017 predicted.

So D-017's conditional verdict is now final for all three desktop targets: clients regenerate terrain
from the shared seed, and world generation stays inside the §7 safe set. The heightmap fallback is not
adopted. The physical Windows PC also becomes the preferred Windows export/GPU target; Linux remains
the Unraid KVM guest, and Steam Deck hardware remains unprovisioned.

The run's formal report said `FAIL` because a raw clone emitted 306 startup errors before each probe.
That does not reverse the R6 evidence: the probes use engine built-ins, printed complete stable values,
and exited 0. The errors were independently reproduced and traced to skipping D-022's intentionally
gitignored GodotSteam install plus the first editor filesystem scan. This run therefore clears
determinism but does **not** verify that the game boots cleanly on Windows.

**Would change my mind:** a future Windows run on the pinned engine disagreeing on a required hash;
world gen adding cellular noise/domain warp without a new cross-platform probe; or expanding shared
deterministic simulation beyond the currently tested terrain inputs.

### D-029 · 2026-08-16 · Steam gets its own connect budget, and NetSession retries a first join that times out
F-023 read as "the 10 s deadline is too short". It is not primarily a number problem. The deadline was
shared with ENet, which is a different mechanism — an ENet client already knows the host's address,
while a Steam client has to be rendezvoused through NAT traversal with a relay fallback behind it — so
STEAM now has `STEAM_CONNECT_TIMEOUT_SEC` of its own. But the larger half is that **nothing retried a
first join at all**: `dev_launch.gd` excludes STEAM from its retry by hand, NetSession never listened to
`connection_failed`, and SteamLobby does not either. The retry that "worked" in the 1.12 run was a human
relaunching the game. Retrying is therefore NetSession's, as policy, alongside the rejoin loop it
already owns; `EndKind` splits `CONNECT_TIMEOUT` from `CONNECT_FAILED` so only an attempt that got no
verdict is repeated, never a refusal.

The retry is STEAM-only, and the reason is a specific invariant rather than caution: a timed-out attempt
tears down *without announcing*, so SteamLobby never sees `disconnected`, never leaves the lobby, and we
are still a member — which is the one precondition `connect_to_lobby()` has. **That is what makes this
not F-020.** F-020 is the rejoin-after-drop case, where the session was announced, the lobby *was* left,
and getting back in genuinely needs SteamLobby's asynchronous flow. On final give-up the lobby is handed
back, because a member with no session cannot re-run `join_by_id()` — it refuses while `_state` is
`IN_LOBBY`, so holding it would break the player's own manual retry.

`STEAM_CONNECT_TIMEOUT_SEC = 20.0` is explicitly **provisional**: no first-join latency had ever been
recorded when it was chosen. `NetTransport.last_connect_msec()` now records one on every successful
join and logs it, so 1.12's next run yields the real distribution as a side effect.

**Would change my mind:** measured Windows first-join latency showing the tail sits well under 10 s
(then the budget was never the issue and the retry alone is the fix, or something else is wrong); a
Steam retry that fails where a full lobby re-join succeeds (then membership does not survive teardown
the way the code above reads, and the retry belongs in SteamLobby); or GodotSteam exposing connection-
state callbacks, which would let a live rendezvous extend its own deadline instead of being guessed at.

### D-030 · 2026-08-16 · 1.12's formal evidence run is deferred until a lobby can be joined from inside the game; M1 closes at 13/14
The thing 1.12 exists to de-risk — that macOS, Windows and Linux can share one Steam session — is
proven. All three platforms passed preflight, three peers shared one lobby, all three players spawned,
and Linux movement replicated; a later two-platform rerun joined cleanly with Windows Firewall enabled
and despawned cleanly on exit. What is missing is *ceremony*: 60 seconds of observed movement, three
screenshots, and a clean ordered exit.

Collecting that ceremony currently costs a scheduled three-machine session driven by command-line
lobby IDs pasted between terminals, on a Windows VM that renders in software at 2–3 FPS (F-025). That
is a bad instrument: it is expensive to arrange, it is the slowest possible way to iterate, and the
frame rate contaminates the one measurement the run still owes. **The test gets cheap the moment a
player can pick a lobby in-game and join it** — which is roadmap task 6.10 — so the run waits for that
rather than for more netcode.

M1 therefore closes at **13/14** with 1.12 deferred rather than failed, and this is deliberate: the
milestone's purpose was a working network spine, and it has one. Development continues into M2.

**Would change my mind:** a cross-play regression appearing in normal LOCAL/LAN development, which
would mean the deferral is hiding real breakage and the run has to happen on whatever rig exists; the
physical Ryzen PC becoming routinely available, which removes the software-rendering objection and most
of the scheduling cost; or M6 slipping far enough that cross-play would go untested for months — in
which case pull a minimal in-game join forward (see below) instead of waiting for the full menu.

**The cheap version, if 6.10 is too far away:** `SteamLobby` already exposes `host_session()`,
`join_by_id()` and `open_invite_overlay()`, and the game already has a debug console. A pair of console
commands is a fraction of 6.10 and would deliver the whole testing benefit without a menu.

### D-031 · 2026-08-16 · Agents may edit Godot scenes, resources, and import metadata while the editor is closed
*Supersedes D-007's human-only restriction and amends D-012 and D-021.*

Agents may edit `.tscn`, `.tres`, `.import`, `project.godot`, and `export_presets.cfg` when they hold
an explicit claim naming each exact file and have confirmed Godot is not running. Required wiring
belongs in the same task instead of being handed to Sequoyah solely because it lives in a Godot file.

The original merge-risk reasoning still applies: these formats carry internal IDs and Godot rewrites
them on save. The protection is therefore exclusivity plus elimination of the editor race, not a
blanket human-only ban. The pre-commit checker enforces both conditions. Complex authored changes
should preferably be produced through a Godot tool script so the engine serializes its own format;
visual judgment, tuning, and playtesting may still be handed to Sequoyah when genuinely appropriate.

**Would change my mind:** a claimed, closed-editor workflow still causing repeated corruption or lost
work. Then move scene/resource work to isolated worktrees or restore a narrower editor-only rule.

### D-032 · 2026-08-16 · One cursor-owning UI at a time, and `blocks_gameplay_input` is the interlock

The group `&"blocks_gameplay_input"` already told `player_controller.gd` to suppress movement without
pausing the tree (2.5). From 2.7 it is also how cursor UIs exclude each other: a UI refuses to open —
and hides its world prompt — while any *other* node is in that group. The workbench panel therefore
cannot stack on the field pack, and a future build menu, ward panel or map inherits the rule for free
by joining the group and checking it. World-proximity UIs additionally close themselves when the
player leaves the station's range, because presenting a craft the host will reject is a lie.

The alternative — a UI manager autoload owning a stack of open panels — buys ordering and z-index
policy we do not need for 3–6 players and one panel at a time, and it would be a second source of
truth next to a group the player controller already reads.

**Would change my mind:** a case where two panels genuinely must be open together (an inventory
beside a container, drag-and-drop between them). That needs a real stack, and this rule should be
replaced rather than special-cased per pair.

### D-033 · 2026-08-16 · Inventory icons are rendered from the shipped GLBs, never drawn

`assets/icons/` holds no original art. Every icon is an orthographic render of a model that already
ships in `assets/`, produced by `tools/blender/render_item_icons.py`, so an icon cannot drift from the
thing it stands for: when a model changes, re-running the script is the entire update. Framing is
measured rather than hand-tuned — vertices are projected into camera space and the script keeps
whichever of upright or 45°-rolled packs the silhouette into the smaller square — so a 1.97 m skewer
and a 12 cm coin both fill their slot with only a yaw authored per asset.

The rig renders in Cycles with a pinned seed. EEVEE resolved anti-aliasing on thin silhouettes (a
cleaver edge, a pick tip) a few samples differently between runs, which cost the batch its
deterministic rebuild for no visual gain; 24 icons at 256px cost about ten seconds in Cycles. Verify
icons by comparing decoded pixels, not file hashes — the PNG encoder emits a few bytes of differing
metadata even when the image is identical.

**Would change my mind:** icons that need art direction a render cannot give — a readable silhouette
for a 32px slot, a rarity frame, a damaged-state overlay. Hand-authored icons then become a real asset
family with its own batch, and this script becomes the base pass they are painted over.

### D-034 · 2026-08-16 · Melee splits across two authority rows, and hitstop is never `Engine.time_scale`

Task 2.8 puts the *swing* and the *hit* in different rows of ARCHITECTURE.md §2.2 on purpose. The
swing animation is the owning player's own action, so it starts locally the frame the button goes
down and never waits on a round trip — but it decides nothing. The hit is host: a client sends only a
hotbar slot index, and the **host reads its own authoritative inventory for that slot** to decide
which weapon swung. The worst a lying client can do is swing one of the eight items it genuinely
holds. Aim is not sent either; the host uses the body yaw and camera pitch the player's own
synchronizer already replicates.

Targets join `&"damageable"` and implement `host_apply_damage(amount, instigator_peer_id) -> bool`.
Harvestable implements it today and 2.10's enemies join the same group with no change to
`CombatService`. A target that returns false is a miss, not a phantom hit.

Hitstop, screenshake and impact audio are client-local and follow one host broadcast that says a
connect happened. Hitstop stalls **the attacker's own swing clock**, never `Engine.time_scale`:
time_scale slows the whole frame loop, and every transport's pump is polled from that loop (the same
mechanism as F-025, where a slow frame rate slows Steam's callbacks). A feel effect must never be
able to throttle networking.

**Would change my mind:** on the authority split, evidence that host-side swing clocks do not scale
to a night wave with six players attacking — then the host resolves on the request itself and pays
for it with a worse tell. On hitstop, a single-player-only context where time_scale is measurably
better; it would still have to be off in a session.

### D-035 · 2026-08-17 · A run-player is a host-issued opaque token, and peer_left is not a departure

An ENet client that reconnects gets a new peer id — 1.7 measured it, and the lifecycle check now
asserts it. Every host-owned system keys state by peer id, so without a stable identity a reconnect
is indistinguishable from one player leaving and another arriving (F-032).

The host mints an opaque 16-byte token per run-player, hands each client only its own, and takes it
back on the next hello. Two rules make trusting a client-presented token safe: a token whose peer is
still connected is never reassigned, so a live player's state cannot be stolen; and a parked token
expires after 90 s, so state is not held for someone who is not coming back. Tokens are in memory
only — a run is one sitting (D-010), so there is nothing to persist.

**The consumer contract is the load-bearing half: a gameplay system must NOT release peer-keyed state
on `peer_left`.** It waits for `NetSession.run_player_rebound(old, new)` to move it or
`run_player_expired(peer)` to drop it. Between a drop and a rejoin a player is still a player, and
`peer_left` cannot tell the two apart — which is exactly why `InventoryService` used to wipe an
inventory on every reconnect.

Rejected: reusing the Steam ID, which only works in one of three transports; and matching an orphan
to "the next joiner", which hands the wrong inventory over the moment two players reconnect together.

**Would change my mind:** needing identity to survive the process (a save/resume feature would
supersede D-010 first), or a transport that already guarantees stable ids across a reconnect for all
three modes — then this becomes a shim over that instead of its own registry.

### D-036 · 2026-08-17 · One director routes work to three subscription lanes; it does not implement

The coordination system was pull-based: an agent opens a chat, runs `agent start`, picks a task. That
works, but it makes Sequoyah the scheduler — he opens every chat, chooses every task, and is the one
who notices when an account runs dry. Meanwhile four paid plans sit on one MacBook and only one of
them is ever working.

So: a **director** (Claude Max, Opus) routes tasks to three **lanes**, each pinned to one paid account
with its own auth home — `LC1`/`LC2` on ChatGPT Plus via `codex`, `LP` on Claude Pro via `claude`.
`CODEX_HOME` and `CLAUDE_CONFIG_DIR` are what let two Codex accounts and a second Claude account
coexist without fighting over one credential file. Each lane runs with `MIRE_AGENT=<lane>`, so it
inherits the whole existing claim/journal protocol unchanged — the orchestration is additive, and
`start`/`claim`/`ship` behave exactly as before for a human or a chat agent.

**The director's rule is that it routes and verifies, and does not write gameplay code.** A director
that implements has spent the most expensive quota in the project on work a $2/Mtok lane would have
done as well. Its output is orders, routing decisions, and judgement on what came back.

The lane split follows `AI-WORKFLOW.md` §3 — premium in `core/`/`systems/`, cheap in `ui/`/`tools/` —
because those areas rarely touch and so rarely block each other.

**Would change my mind:** if collisions between lanes turn out to cost more than the parallelism buys
(watch `agent report` for lanes idling on refused orders), or if a single account's quota grows
enough that fanning out stops being the binding constraint.

### D-037 · 2026-08-17 · Lanes share one working directory; two locks cover what they actually contend on

The obvious isolation for three concurrent lanes is a git worktree each. Rejected: `.godot/` is
gitignored, so every worktree reimports 71 MB of `assets/` into its own 42 MB cache, and the reimport
is paid per worktree and again after every asset change. That is a large, recurring cost to solve a
problem the claim system already solves — two agents cannot hold the same file, and `ship` stages only
the claiming task's files.

What a shared directory genuinely contends on is two things, and both get a lock
(`.agent/locks/`): **`godot`**, because all ~49 checks share one import cache (F-044), and **`git`**,
because three `ship`s at once means three processes in one index. `agent godot` and `agent ship` take
them; nothing else needs one.

**Would change my mind:** measurable lock starvation — a lane spending more time waiting on
`godot.lock` than running — or a check suite that grows long enough that serialising it dominates the
wall clock. Then give each lane a worktree and eat the reimport.

### D-038 · 2026-08-17 · The art is authored in Blender, not imported CC0; the Blender toolchain is pinned like the engine

D-005 chose CC0 packs to remove art as a blocker. In practice no pack was ever imported: task 2.1 was
satisfied by an original 8-asset Blender kit, 2.1b grew it to 116, and every batch since — thirteen
source kits, 128 environment models, a rigged crawler, a Cycles icon renderer with
deterministic-rebuild verification — is authored in-house under `docs/ASSET_TRACKER.md`'s contracts.
Recorded so D-005 stops describing a pipeline that does not exist, and so `DESIGN.md`'s "it's what
CC0 asset packs give you for free" rationale stops misleading the asset agents who are ordered to
read it.

Consequence: those batches' byte-identical-rebuild evidence depends on the Blender version and the
Cycles seed exactly the way gameplay determinism depends on the pinned Godot build (D-001). Treat
Blender as pinned; the next asset batch records the version in `ASSET_TRACKER.md`'s verification
contract, and any Blender upgrade re-verifies a rebuild before the next batch ships.

**Would change my mind:** the queue outpacing what authored batches can deliver before M7 — then CC0
fills the gaps and hero assets stay authored, which is D-005's original shape run in reverse.

### D-039 · 2026-08-17 · Do-it-yourself disposition: an agent never hands Sequoyah work it could do itself

From Sequoyah directly, after one too many "you'll need to wire this in the editor" endings: agents
may edit **whatever files the task needs** — scene files included — being careful when something is
high-stakes; and *"if an agent can do something, I never want it to tell me to do it unless I could
do it significantly faster."* Per-task commits are the accepted safety model: a bad edit costs one
`git revert`, not a catastrophe.

So the disposition flips, while the mechanics stay exactly as D-031 wrote them — exact per-file
claims, and the Godot editor closed for Godot-authored files (that is corruption physics, not a
permission gate). What changes: **"left for the editor" is no longer a valid way to end a task.**
Wire the node, set the export, add the collision shape, register the autoload — then verify
headlessly and *report what you did*, not what remains. Hand-off to Sequoyah is reserved for three
things: genuine visual/taste/playfeel judgment (2.9's gate is the canonical example), work that
needs his accounts or hardware, and work he is *significantly* faster at. "Careful on high-stakes"
means verify and note the risk — not stop and ask.

The tier labels in `AI-WORKFLOW.md` survive as a **cost model** (T0 = zero quota when Sequoyah does
it), not an ownership rule: a dispatched agent takes a T0 task like any other.

**Would change my mind:** an agent-authored scene edit that costs more than one revert — corruption
a commit boundary didn't contain — argues for review-first on `.tscn` specifically, never for
bringing back hand-offs.

### D-040 · 2026-08-17 · Stamina's host-side copy is advisory only; the host never gates on it

Task 3.8 put stamina under §2.2's "own player movement" row (CLIENT), not the hp/hunger row (HOST),
because it gates sprint/jump/dodge and a host-gated stamina check would reintroduce exactly the input
lag every other client-authoritative system in this codebase exists to avoid. But an all-client value
has no story for anti-cheat or for a future teammate HUD, so the owning client periodically reports
its stamina to the host (`net_report_local_stamina`, unreliable, ~2s interval) purely so
`PlayerHealth.host_stamina(peer_id)` has something recent — never as a source of truth the host
enforces anything against. Losing a report changes nothing; the next one supersedes it.

This matters most for **3.8b's dodge i-frames**, the next task built directly on this file: it must
NOT assume `host_stamina()` is authoritative enough to reject a dodge for insufficient stamina — a
report can be up to the reconcile interval stale, and a host-side rejection on stale data would deny
a legitimate dodge the client's own (correct, fresher) stamina already paid for. 3.8b's spec already
frames the host's job as the i-frame *decision* (whether the `dodging` flag blocks a landed hit), not
a stamina *re-check* — this decision is what that framing rests on.

**Would change my mind:** evidence that players can trivially fake `net_report_local_stamina` to grant
themselves free dodges in a way that matters for a co-op game among friends (D-039's "cheating is
irrelevant among friends" already covers movement speed on the same row) — or a design change that
moves dodge off the client-authoritative movement row entirely.

### D-041 · 2026-08-17 · Chest loot rolls seed from boot-time entropy, not a fixed constant — provisional until a real per-run seed exists

Task 3.5's work order says "a per-run seeded `RandomNumberGenerator`," but no `GameState.run_seed`
(or any per-run seed authority) exists yet in this codebase — `enemy_world.gd`'s ambient scatter and
`combat_service.gd`'s placeholder impact sound are the only precedents, and both seed from a **fixed**
magic constant (`0x4352414d`, `0x4d495245`) because their reason for using `RandomNumberGenerator` at
all is cross-peer determinism for a value every peer independently computes, not run-to-run variety.

`Chest`'s roll is different: it happens exactly once, host-only, and is granted directly through
`InventoryService.host_add()` — no other peer ever recomputes it, so nothing requires a fixed seed for
agreement. What "per-run" is actually asking for is that two separate playthroughs get different loot,
which a fixed constant would not provide. Each `Chest.host_seed_rng()`-eligible instance calls
`RandomNumberGenerator.randomize()` once in `_ready()` (host-only) instead — real entropy, per chest,
per boot — which satisfies "never `randi()`" (a dedicated instance, not the global function) and
varies across runs, without inventing a `GameState.run_seed` this task has no claim to add.

**Would change my mind:** the moment a real per-run seed authority exists (a `GameState` autoload,
most likely — 4.x Cycle work is the probable place), `Chest` should switch to deriving its seed from
`(run_seed, a stable per-chest id)` instead of `randomize()`, the same way a save-scummed run would
want reproducible loot. `Chest.host_seed_rng(seed_value)` already exists as the seam that switch would
call into — it does not need new API, only a new caller.

### D-042 · 2026-08-17 · The night sky is geometry, not `PhysicalSkyMaterial.night_sky`

F-065's star field could have been a panorama texture handed to `PhysicalSkyMaterial.night_sky`, which
is the engine's own designed path and costs no draw call. It is geometry instead
(`world/environment/star_field.gd`: a 380 m dome of soft hexagonal points that rides the camera),
for three reasons in increasing order of weight. It matches the language `low_poly_clouds.gd` already
set for this sky. A texture sits behind the engine's scattering term, where the dusk fade cannot be
tuned independently of the sky's own brightness. And decisively on a project whose rule is *verify it
yourself, headless* — a texture's appearance can only be judged with a framebuffer, whereas every
claim about geometry (vertex count, per-star alpha, fade monotonicity, determinism across two peers)
is readable from a headless run, which is what `tools/atmosphere_night_check.gd` does.

The cost is real and accepted: one extra transparent draw call and ~9,400 vertices while the field is
visible, and nothing at all during daylight (the dome is hidden and stops processing at
`night_amount <= 0.001`).

**Would change my mind:** a measured frame cost that matters on the minimum spec, or a night sky that
wants real detail — a Milky Way band, nebulae, anything with structure a few hundred quads cannot
carry. Both point at a texture, and `set_night_amount()` is the seam that would keep its fade.

---

## Template

```
### D-0NN · YYYY-MM-DD · <one-line decision>
<why, in 2–4 sentences>
**Would change my mind:** <the specific evidence that should make you revisit this>
```
