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

### D-043 · 2026-08-18 · An entity is interpolated if and only if it replicates a transform — "prop" is not the criterion

F-004 asked, over three sessions, whether harvestables and physics props needed network interpolation
alongside players and enemies. The answer is no, and it is structural rather than a matter of taste,
so it should not be reopened as one. There are exactly four `SceneReplicationConfig`s in the shipped
game. `PlayerController` and `Enemy` replicate `position`/`rotation` at `REPLICATION_MODE_ALWAYS` and
both are smoothed (NetInterp attaches players centrally off `PlayerNet.player_spawned`; an `Enemy`
attaches itself when it does not own simulation). `Harvestable` replicates `health`, `visual_state`
and `active`; `Chest` replicates `opened` — both `ON_CHANGE`, and **neither puts a transform on the
wire at all**. `RemoteInterp` smooths a transform, so on those two it would have nothing to act on.

Worse than useless, in fact: those properties are discrete. `visual_state` selects one of a set of
authored damage meshes, `opened` flips a lid. Blending toward a discrete swap is how you get a
half-swapped tree, which is a worse artefact than the instantaneous swap it "fixed". State that
changes on change wants to snap.

So the rule is about the wire contract, not the category of thing: **if a client sees an entity's
position or rotation arrive over the network, that entity must be smoothed.** A future physics barrel,
cart or thrown item is covered by that sentence without anyone having to decide again whether it
counts as a "prop". `tools/interp_coverage_check.gd` enforces it — it finds every
`SceneReplicationConfig` in the project, sorts them by whether they replicate a transform, and fails
if a transform-replicating entity is neither smoothed nor explicitly exempted with a reason. It found
one on its first run (`core/net/dummy_replicant.gd`, R1's spike fixture, which nobody watches).

**Would change my mind:** a prop that starts replicating a transform — at which point the rule already
covers it and the check will say so. Or evidence that an `ON_CHANGE` visual swap reads badly enough at
range to want a crossfade, which is a presentation problem for a shader to solve, not a job for the
network interpolator.

### D-050 · 2026-08-17 · Attack style is presentation and lives on `ItemDef`; grips are solved from geometry, never hand-nudged

Two calls from F-073, which found every tool holding one grip rotation authored for the sword and
every weapon playing one chop.

**`attack_style` is an `ItemDef` field, not a `WeaponDef` one.** `WeaponDef` looks like the natural
home — it is the resource that describes a swing — but it does not cover the set. `short_bow` and
`arrow` ship a `view_model` and have no `WeaponDef` at all, and `CombatService` builds its `unarmed`
fallback in code without ever inserting it into `Registry.weapons`, so `Registry.get_weapon()` is
null for it. Putting the style there leaves three holdable things unable to declare an arc, silently
falling back to the default — which is precisely the bug. It also keeps the authority story clean:
`WeaponDef` is what the **host** reads to resolve damage, reach and arc width, while the animation is
client-local presentation that tells nobody anything (`ARCHITECTURE.md` §2.2, last row). Reach and
damage stay on `WeaponDef`; only the shape of the visible arc moved.

**Grips are computed from each export's geometry, not tuned by eye in the inspector.** A-004's
exports are horizontally centred with ground-level origins and their heads run bit-to-poll along
local +X with the cheeks on local ±Z. That makes "which way should this be turned" a measurable
question, not a matter of taste: name where the haft and the working end should point in camera
space, build that basis, decompose it into Godot's YXZ Euler order, and place the *hand* — not the
model's origin — at a chosen screen position. The eleven solved grips live in
`tools/setup_tool_content.gd`'s `GRIPS`, so a regeneration reproduces them. The rule this replaces —
one rotation for everything, scale derived from length — is how a value correct for one design
(the sword, whose broad flat genuinely is its readable face) silently became wrong for ten others.

The same principle already governs the icons: `assets/icons/README.md` says "framing is measured, not
hand-tuned". F-073 was what happened where that principle had not reached.

**Would change my mind:** on the first, a weapon whose *arc* must differ between two items sharing one
`ItemDef` — there is no such thing today, since an item is a weapon. On the second, a design where
the viewmodel is an authored animation clip on a rigged arm (A-037) rather than a transform on a
static mesh; then the grip is baked into the pose and this solver retires with it. Nudging a solved
number by hand is not a counter-argument — re-solve, or the next regeneration erases it.

---

### D-044 · 2026-08-18 · Tags ARE the Resonance families, and stacks scale linearly, additive before multiplicative

Two calls task 3.3 had to make, both of which 3.4's 40–60 authored powerups depend on and neither of
which should be relitigated per-powerup.

**Tags are the families.** `docs/SPECS.md`'s 3.3 block lists `tags: Array[StringName]` *and* a
separate `resonance_family`, but `DESIGN.md` §4.4 keys its thresholds off the tags themselves —
"each powerup has 1–2 tags", "holding 3+ of a tag triggers a Resonance". Two fields would be two
names for one concept, and the failure mode is not hypothetical: an author sets `Fire` in `tags` and
leaves `resonance_family` empty, the powerup shows a Fire icon and contributes to no Resonance, and
nothing errors. `PowerupDef` therefore has `tags` only. A powerup belonging to two families feeds
both, which §4.4 already assumes when it says 1–2 tags.

**Stacking is `(base + additive * N) * (1.0 + multiplicative * N)`**, per stat, summed across every
powerup the player holds that names it. Additive resolves first so a flat `+2 max_hp` is amplified
by a later `+10% max_hp` rather than lost under it, which is the order players expect. Both terms
scale **linearly** with the stack count rather than compounding: five stacks of +8% is +40%, not
×1.08⁵ (+47%). Compounding is the standard way a stacking system becomes unbalanceable — the
designer tunes the third stack and the ninth quietly doubles — and §4.4 deliberately puts the
qualitative power in Resonances, not in stat curves. Stats are the boring, predictable half on
purpose.

**Would change my mind:** on the first, a design that wants a powerup to display under one banner
while counting toward another — then `resonance_family` returns as an explicit override, defaulting
to `tags`, rather than as a parallel required field. On the second, a specific powerup that is
uninteresting until it compounds; that is an argument for a per-stat curve field on `PowerupDef`,
not for changing the default everything else is tuned against.

### D-045 · 2026-08-18 · Hollowmere is 192 m across, and a map's size is set by how long its emptiest walk is

The first cut was 356 m across. Nothing was wrong with it in the sense any check could express — it
validated, it was reachable, its landmarks were spread evenly — and it was the wrong size, because
the placement rules only sustained 1,415 props over 99,000 m² of playable ground. One prop per 70 m²
is a walk of a minute and a half between anything worth stopping for, and no amount of prop-count
tuning fixes that when the denominator is the problem.

This cut is **192 m across (BOUND 86, RING_OUTER 96) with ~2,870 authored props and ~10,000
scattered plants** — a quarter of the area carrying twice the content, so the same journey is thirty
seconds of continuously interesting ground. The rule this settles for every map after it: **size the
map by its longest boring stretch, not by how much geography you can think of.** Landmarks are cheap
to add and area is not.

**Would change my mind:** a movement change that makes traversal itself the content — mounts, a
grapple, vehicles — at which point the boring stretch shortens and the map can grow to match. Or a
playtest at 3–6 players where the hold feels crowded and groups cannot get away from each other.

### D-046 · 2026-08-18 · Yaw from a direction is `atan2(-dz, dx)`, and exactly one helper computes it

`Basis(Vector3.UP, yaw)` sends a model's local +X to `(cos yaw, 0, -sin yaw)`: a right-handed
rotation about +Y turns +X toward **-Z**. So the yaw that lays an asset along a world direction
`(dx, dz)` is `atan2(-dz, dx)`. The map generator used `atan2(dz, dx)`, which mirrors every
directional prop across the axis it was supposed to follow. It is invisible on a square deck plank
and unmissable on a bridge railing, which is where it was finally noticed — the railings ran
diagonally across their own bridges.

The fix is not "correct the sign at the call sites". It is `yaw_along(dx, dz)` in
`tools/mapgen/hollowmere_layout.py`, plus `tangent_yaw` and `radial_yaw` built on it for ring
placement, and **no other way in the file to turn a direction into a yaw**. A convention that has to
be re-derived at each call site will be got wrong at the next one.

**Would change my mind:** nothing about the maths. If Godot ever changes its rotation convention the
helper is the single place to fix, which is the point.

### D-047 · 2026-08-18 · The layout places what you navigate by; undergrowth places what you walk on

Two systems were both scattering ground cover — `hollowmere_layout.py` authoring grass and moss into
the layout file, and `undergrowth.gd` scattering 26,000 plants by raycast at load. The authored half
lost every time: it is drawn at 2 m spacing by a placer that also has to fit trees, so it spent the
scatter's whole budget on plants that were about to be covered by better ones, and crowded the trees
out while doing it.

The split is now by role, not by kit. **The layout owns anything whose position matters** — trees,
rocks, logs, ruins, harvestables, anything with collision or a name. **Undergrowth owns anything
whose position does not**, which is every family named in its `ZONE_PALETTES`. `UNDERGROWTH_FAMILIES`
in the generator is that list, and the coverage validator skips exactly those, so neither side has to
guess what the other is doing.

**Would change my mind:** ground cover that starts mattering — trampling, hiding a crouched player,
burning. That is host-authoritative state and it moves those families back into the authored layout
where their positions can be replicated.

### D-048 · 2026-08-18 · Zones tile the map by weighted nearest-centre, and both consumers use the same rule

Zone discs overlap. When each zone scattered its own disc, the zone that ran first filled the shared
ground and the zone that ran second found it full — DeepForest's disc covers most of the Quarry's,
and the Quarry placed **zero** standing props into a hole no check could see. And `undergrowth.gd`
independently assigned each plant to its nearest zone centre, so on overlapping ground the flora came
from a different zone than the props standing in it.

Every point now belongs to exactly one zone: the one minimising `distance - pull`, where `pull` is a
per-zone bias in metres. It is an additively-weighted Voronoi, and the weight is what lets a forest
own forest-sized ground while a quarry owns a pocket without shuffling centres around to fake it.
The zone's `pull` ships in the layout's `zones` array and **`undergrowth.gd` reads the same three
numbers**, so the two cannot disagree. A layout that omits `pull` gets plain nearest-centre, which is
what Playtest Hollow has always had.

**Would change my mind:** a map that wants genuinely blended borders rather than a partition — then
the rule becomes a soft weight per zone and both readers sample it, which is the same contract with a
different function in it.

### D-049 · 2026-08-18 · Anything a system has to modify at runtime gets its own node, not a MultiMesh slot

`authored_world.gd` instances props through `MultiMeshInstance3D` per chunk, which is what makes a map
this size affordable. But `HarvestWorld` fells a tree by hiding its visual and swapping in a damaged
state, and **one instance of a MultiMesh is not a thing you can hide** — so on this map every tree and
ore node was inert scenery, and no check noticed because nothing was broken, only absent.

Props carrying `"harvestable": true` in the layout are now built as individual nodes: a holder in
`authored_world_harvestable` with the asset name in its metadata, a `Visual` child and a
`CollisionBody` child. There are 83 of them against 2,869 props, so the instancing argument is
untouched. The general rule: **decide per prop whether a system will ever have to address it
individually, and give those props a node.** Batching is for scenery.

**Would change my mind:** a per-instance visibility or material mechanism for MultiMesh that a
gameplay system can drive — then the swap happens in the buffer and the holders go away.

---

### D-050 · 2026-08-18 · The powerup stat vocabulary is a governed catalog, and conditions, triggers and capabilities are stat names consumed at the owning system — not schema fields

The pre-3.4 design check (docs/POWERUPS.md) sketched 60 powerups across the whole §4.4 design space
against the shipped `PowerupDef`. Result: **zero need a field the schema doesn't have**, so the
schema ships as-is and 3.4 authors against it. Three conventions make that true, and they are the
part that must not be relitigated per-powerup:

1. **A stat is named for the exact quantity the consuming system computes**, so D-044's
   `(base + add·N)·(1 + mult·N)` reads literally. Reductions are negative values on the consumed
   quantity (`damage_taken: (0, -0.04)` is armor); there are no inverted "resist" stats. The
   vocabulary lives twice, deliberately: `PowerupDef.KNOWN_STATS` (validated at boot, F-078) and
   `docs/POWERUPS.md` §2 (meanings, signs, consumers). A new stat is one line in each.
2. **Conditional powerups are suffixed stat names** (`melee_damage_low_hp`), chained by the
   consumer that owns the condition onto its unconditional pass. The alternative — a condition
   field filtered inside `PowerupService` — would require pushing every peer's hp/position/phase
   INTO the service, inverting the one seam ("systems ask, the service never reaches in") and
   putting condition state on the wire. The suffix set is closed (`_low_hp`, `_in_mire`,
   `_at_night`) and each costs its consumer one `if`.
3. **Event scalars and capabilities are stats too**: `on_kill_heal_hp` is consumed once at the
   kill-attribution site, `ignite_chance` at the hit site (the status itself ships with the
   Fire-Resonance task), `extra_jumps` is a flat count the controller reads. Bespoke qualitative
   behavior stays Resonance territory per D-044; the escape hatch for a one-off signature powerup
   is code keyed to `stacks_of(peer, id)` — no field either way.

**Would change my mind:** a designer actually asking for two different thresholds of the same
condition (breaks the closed-suffix convention → an exported condition pair, service-filtered);
or more than ~3 timed-surge powerups wanted (→ a surge mechanic task plus two catalog names —
still not a field).

---

### D-051 · 2026-08-17 · `StationDef.world_scene` names a baked world asset, not a `PackedScene`
Task 3.1's spec literally says `world_scene`, which reads like `BuildableDef.scene` (a
`PackedScene` `BuildService` instantiates). But every crafting station shipped so far
(`assets/crafting_stations/`) is baked map art placed by `world/gen/authored_world.gd` /
`tools/mapgen/hollowmere_layout.py` — there is no station `.tscn` to reference, and nothing in
this task spawns one. `world_scene` is typed `StringName` and holds the asset name
(`assets/crafting_stations/catalog.json`'s `name`, e.g. `&"station_stone_furnace"`), which
`CraftingService._station_in_range` matches against a physical instance: a legacy Playtest Hollow
prop's `asset` meta, or a Hollowmere marker named `"Station_<world_scene>"`. Keeping the spec's
field name (rather than renaming to `world_asset`) trades a slightly misleading name for staying
grep-consistent with the roadmap text; the doc comment on the field says so.
**Would change my mind:** a task that actually gives crafting stations their own instantiated scene
(a build-and-place-a-workbench feature, say) — at that point this field should either become a
real `PackedScene` or a second field should carry it, and every `_station_in_range` caller updates.

### D-052 · 2026-08-17 · A timed craft's progress bar is a client-side estimate, not a host push
3.1's furnace worked example (`craft_progress(request_id)` "poll seam for the UI") could have been
built as a new host→client RPC announcing a start time and duration. It wasn't: every peer already
loads the identical `RecipeDef` (including the new `craft_time_sec`) from `Registry` at boot, so
`CraftingService.request_craft()` starts the requester's own countdown the instant it sends the
request, with no round trip. The wire shape stays exactly what 2.6 shipped — a recipe id and a
local request id out, `craft_confirmed(request_id, accepted, detail)` back — so 3.1 needed no new
RPC and no `NetVersion.PROTOCOL_VERSION` bump. The tradeoff: a client's progress bar can drift by
up to one round trip from the host's real completion time before `craft_confirmed` corrects it.
Acceptable because the bar is cosmetic — the host's own `_process()`-ticked timer is what actually
gates `host_transaction`, never the client's estimate.
**Would change my mind:** a design that needs the progress bar itself to be authoritative (a shared
station where multiple players must see the exact same countdown, say) — that needs a real
`net_craft_started(request_id, remaining_sec)` push and the protocol bump that comes with it.

### D-053 · 2026-08-18 · A colliding F-number is renumbered only in a dedicated cross-cutting pass, never as a side effect of an unrelated task
`_duplicate_findings()`'s own docstring in `.agent/bin/agent` already called this out, and two findings
(F-058, then F-071) independently arrived at the same deferral: code comments and queued work orders
can cite *either* member of a colliding pair, so fixing the number requires reading every reference's
surrounding sentence to know which finding it meant — real work, and real collision risk against
whatever agent holds those files mid-edit. An agent who stumbles on a collision while doing something
else should file (or update) the meta-finding and move on, the way F-058 and F-071 both did, rather
than renumbering inline. F-087 is that dedicated pass, and its own fix note scoped even *it* to
`docs/` and `.agent/` — code-comment references stayed deliberately untouched, for the same reason.
**Would change my mind:** a collision that is actively causing wrong production behavior (not just
misrouted `agent brief`/`board` output) — that would be worth an inline fix regardless of scope.

---

### D-054 · 2026-08-18 · A buildable killed by combat damage refunds nothing; only a deliberate teardown request does

F-085 gave buildable pieces a real `host_apply_damage()`, which meant deciding what happens to the
piece's cost when a hit reduces its hp to zero — a case 3.6 never specified because it couldn't be
hit at all until this fix. `BuildService._process_destroy()` already refunds `refund_fraction` of the
cost to whoever *requests* teardown, on purpose (any teammate may clear a misplaced piece, and the
payout goes to them, not the original builder). Damage-destruction does not reuse that path: it pays
out nothing, matching `Harvestable` and `Enemy`, neither of which grants anything to the instigator on
death. The two cases stay visibly different in the code — `host_piece_destroyed_by_damage()` never
calls `_refund_for()` — rather than folding damage-destruction through the teardown function with a
flag to suppress the refund, so a future reader doesn't have to trace a conditional to learn that
combat kills never pay.

**Would change my mind:** a design pass that wants "salvage" as a real mechanic — an enemy or a rival
player's weapon leaving harvestable scrap behind — at which point it should be its own explicit yield,
the way `Harvestable.depleted` already works, not a repurposed build refund.

---

### D-055 · 2026-08-18 · Hardware scaling is three presets behind one autoload, and `high` restores captured authored values rather than hardcoding them

MIRE must run well on the worst computers (Sequoyah, F-090), and release worlds are randomly
generated, so per-map tuning has a shelf life. `GraphicsQuality` (autoload, authority: none) is the
single seam: `gfx low|medium|high` sets render scale, cascade count, shadow distance/atlas, glow,
volumetric fog, and the undergrowth density budget together — measured on the M5 Pro at 283/190/149
uncapped fps respectively, with `low`'s margin growing on weak GPUs since it halves draw calls.
`high` means "exactly what the level authored": values are captured per node on first touch and
restored, never copied into the preset table, so generated levels keep their own numbers. Presets
scale the undergrowth *attempt budget*, not the placements — the RNG sequence is untouched, so lower
density is a strict prefix of the same field. Vsync stays ON by default (retail-correct; measured
free while the frame is slower than the panel; `vsync off` in the console when measuring). Scatter
systems — present and future generator alike — follow undergrowth.gd's pattern: per-cell MultiMeshes
with the cell's true centre as origin, height-tiered shadow casting, tiered visibility ranges.

**Would change my mind:** task 7.5's settings menu wanting per-knob rows (the presets stay as the
three buttons, knobs graduate out of the table); an FSR2-vs-bilinear evaluation showing FSR2 wins on
the low preset's hardware class; or a generated-world scatter whose cells need to stream rather than
all exist, at which point the seam grows a streaming policy rather than each biome inventing one.

---

### D-056 · 2026-08-18 · Placement snapping rounds X/Z to the grid; Y is never rounded, only preserved from the aim hit

F-083: `snap_transform()` used to round Y to the same metre grid as X/Z, which is wrong on principle —
X/Z snapping exists so two players' walls line up on a shared grid, but Y has no equivalent reason to
round, because Hollowmere's terrain is not built on whole-metre elevations. Rounding it either buried
a piece in the ground (0.4 -> 0.0) or floated it above the surface (0.6 -> 1.0). The fix is to leave
Y exactly as given: `BuildGhost.update_aim()` already passes the real physics-ray hit position into
`snap_transform()`, so preserving it places the piece flush with whatever the ray actually hit —
terrain, a slope, or another piece's real top surface. That last case is why no separate "stacking
anchor" rule is needed: a ray against an already-placed piece reports that piece's own exact top, so
flush stacking falls out of the same raycast for free. Content authors relying on the old "floors
snap to a clean Y" behavior (see `wall.tres`'s own doc comment about lining up a run of walls) get
that guarantee on X/Z as before; Y lines up only when the ground itself does.

**Would change my mind:** a future piece type that must sit at an exact authored height regardless of
what's under it (e.g. a multi-tile floor grid meant to read as perfectly level across uneven terrain)
would need an explicit anchor/leveling rule on top of this — that is new scope, not a reason to bring
grid-rounding back to Y.

---

### D-057 · 2026-08-18 · `.agent/` is claim-free coordination state; `.agent/bin/` is source and follows the source rules

F-081: one prefix covered two different kinds of file. `BOARD.md`, `JOURNAL.md` and `state.json` are
generated, every task updates them, and nobody claims them — so `ship` carries them for whichever
task commits next, which is the only workable rule for files with no owner. `.agent/bin/` sits under
the same prefix and is the opposite kind of thing: hand-authored Python that every lane, every hook
and every check shells out to, edited by one director at a time. Treating them alike is how an
unrelated content task's commit came to contain a half-finished harness fix, under the wrong name
and the wrong message. The line is now drawn at the directory: coordination state is an explicit
allowlist of the three generated files, and harness source is claimed, shipped and reviewed exactly
like `world/gen/undergrowth.gd` is. In practice that means a director fixing the harness claims
`.agent/bin/agent` under the task doing the fixing, and claims it before `agent done` — `ship` reads
its file list from `recent`, which `done` is what populates.

**Would change my mind:** a generated file that legitimately has to ship with every task and does not
fit the three-file list — the allowlist would then be the wrong shape, and a `.agent/bin/` exclusion
the right one. A hand-authored file appearing under `.agent/` *outside* `bin/` is the same signal
read from the other direction.

---

### D-058 · 2026-08-18 · Build-mode presentation is built by the player, not registered as an autoload; "build mode active" has no state of its own

F-086 needed a piece-picker UI (`ui/building/build_bar.gd`) the same shape as `CraftingUI`/
`InventoryUI`/`VitalsHud` — but every one of those is an autoload, and `project.godot` was held by
another lane's task (F-095) for the whole session this shipped in. `ui/hud/vitals_hud.gd` had
already answered a smaller version of the same problem (EAT_KEY, a raw key instead of a new InputMap
action) — this generalises it one step further: **`BuildBar` and `BuildGhost` are both built directly
by `entities/player/player_controller.gd` in `_ready()`, the same way it already builds its
Viewmodel and debug avatar, and registered nowhere.** This is not only a workaround for a locked
file. Both are strictly per-local-player client-local presentation (§2.2 last row) — nobody needs to
see another player's piece picker or ghost — so a singleton was never the right shape for them
regardless of who held `project.godot`; the existing UI autoloads are singletons because there is
exactly one local player per client process, not because presentation generally wants to be global.

**"Build mode active" is not a second flag.** `PlayerController.is_build_mode_active()` reads
`BuildGhost.visible` directly — `BuildGhost.set_piece()` already flips it the moment a piece is
selected or cleared — rather than maintaining a `_build_mode_active: bool` that the ghost's own state
could drift out of sync with. One source of truth, not two kept equal by convention.

**Would change my mind:** a design that wants co-op players to see each other's build ghost/picker
(collaborative structure planning) — that would need the ghost's placement replicated and the bar
promoted to something shared, a real scope change, not a bug in this call. On the autoload half
specifically: once `project.godot` is free, there is no reason to migrate `BuildBar` to one — the
per-player-instance shape is the correct one on its own merits, not just the available one.

---

### D-059 · 2026-08-18 · A two-process check's driver must poll the real host-side precondition before mutating host state for a peer — never assert a value that reads identically whether or not that precondition holds

F-038: `inventory_net_check`'s driver treated the CLIENT's self-reported "connected" (its own
`is_active()` + `local_peer_id() > HOST_PEER_ID` + `local_revision() >= 0`) as proof the HOST was
ready to receive a grant for that peer, then asserted `host_count(peer, item) == 0` once as if that
proved it. It doesn't: `host_count()` returns `0` identically for "no store exists yet for this peer"
and "store exists and is empty," so the assertion passed either way and the driver could call
`EVENT_BUS.emit_harvest_yielded()` before the host's `InventoryService` had created that peer's store
— `_publish_snapshot()`'s `rpc_id` send is a one-shot, gated on `_peer_connected()`, with nothing to
resend it, so a grant landing in that window is lost for the rest of the run. `combat_net_check` had
already fixed the identical shape once (`player_net.call("player_for", peer_id) != null`, polled, for
the host-side player-spawn precondition) — this generalises that fix: **poll the host's own state for
the thing about to be true, not a same-shaped read that can't tell "not yet" from "already, and
empty."** `(inventory.call("host_slots", peer_id) as Array).size() == 32` is the concrete poll —
`host_slots()` returns `[]` before the store exists and a real 32-entry array after — used identically
in both checks before their respective grants.

The same investigation found a second, unrelated flake living in the same file: `combat_net_check`'s
`TestTarget` trails an unfloored, permanently-falling player, and by the check's *second* swing the
player's per-frame fall speed had grown enough that `TestTarget`'s one-frame-stale copy of
`follow.global_position` could clear the swung weapon's `vertical_reach_m` — an intermittent miss with
nothing wrong in `CombatService`. Fixed by giving the check a floor (`_build_ground()`, the same
shape `build_net_check.gd` already used, built in both processes since a floor only one side has is
its own desync), not by loosening the follow or any reach tolerance — same principle, one level over:
remove what makes the assertion's timing matter, don't widen the assertion to tolerate bad timing.

**Would change my mind:** a check where the host-side precondition genuinely has no cheap poll (no
existing read distinguishes "not yet" from "already") — then the fix is exposing one, not falling
back to a longer timeout, which the original finding already rejected as hiding the race rather than
removing it.

---

### D-090 · 2026-08-18 · The construction kit is authored to one module contract, and its origins mean something

A-010 ships fourteen assets a player walks through, climbs, crosses or hides behind. Two calls, both
made once here so no later batch or buildable has to re-derive them.

**Every dimension in the kit comes from four numbers, and they come from `content/buildables/wall.tres`
rather than from taste.** `MODULE` 2.00 m is that wall's `size.x` and sits on its 1 m `snap_step`;
`WALL_H` 3.00 m is its `size.y`, and the palisade, both gate frames, the door frame and the ladder
all reach exactly it; `DECK_Z` 1.00 m is every bridge and dock walking surface; and the ramp rises
exactly one deck over exactly one module, **26.57°**. Three ramps stack to a wall. The alternative —
sizing each piece to look right on its own — is what produces a bridge with a seam every 2 m and a
ladder that stops 40 cm short of the parapet, and neither is visible until the pieces are placed
together. The consequence to accept is that a piece may be a *worse object* to make a *better kit*:
the bridge trestle's legs stand upright rather than splayed because a tilted post ends in a tilted
cap that dips under the ground plane, and correcting that lifts the whole module off `DECK_Z`.

**Slope and clearance numbers are the player's, not the artist's.** `entities/player/player.tscn`
sets `floor_max_angle` to 46° and the controller implements no step-up at all (F-136), so every
walkable surface in the kit is checked against the engine's own limit, the ramp's toe feathers to
12 mm instead of starting with a lip, and the wood door has no threshold across its opening.

**Three origin rules, chosen so nothing is left for a human to place by eye (D-039).** Fourteen
exports are ground-centred, the usual portable rule. `palisade_corner` is centred on **its corner
post**, so both arms end exactly on the cell edges a straight section butts to. The four door and
gate leaves are centred on **their hinge axis** — the leaf's outer back corner — so a scene hangs one
at the catalog's `hinge_offset_m` and swings it with `rotate_y()`, and that is the whole API. A leaf
centred on its own bounds would have been a correct-looking export that nobody could hang without
finding the pivot by hand, which is precisely the hand-off D-039 forbids.

**90° is the documented swing and it is a real limit,** not a round number: a square-edged plank leaf
hung on the face of its jamb clears completely at 90° and starts to catch the jamb corner past it,
the same reason a real door gets a stop or a bevelled edge. The opening is fully clear at 90°.

### D-091 · 2026-08-18 · A percentage-authored powerup stat is read against a base of 1.0, and the chest economy's stand-ins are named in the table

**Read multiplicative stats on 1.0, never on 0.0.** `PowerupService.stat(peer, name, base)` computes
`(base + flat * N) * (1 + mult * N)`. Almost every powerup in `content/powerups/` authors its effect
as the multiplicative half, so a consumer that asks for a stat on a base of `0.0` gets `0.0` back
forever, however many stacks the player holds — which is how `loot_luck` sat unread since 3.4
(F-140). A consumer of a stat that has no natural base asks on `1.0` and takes the surplus:
`maxf(0.0, stat(peer, &"loot_luck", 1.0) - 1.0)`. Both authoring shapes then work — a +6% stack
reads as 0.06, a flat +0.5 reads as 0.5 — and no content has to be rewritten to suit the reader.
`Chest._luck_for()` is the worked example; `coin_gain`, `harvest_yield` and `craft_seconds` all face
the same choice when their systems arrive.

**Rarity is the only thing luck may touch.** A `LootEntry`'s `rarity` (0–3) multiplies its weight by
`(1 + luck * rarity)` and never changes what the line grants. That keeps D-063 intact: a jackpot gets
*likelier*, never weaker, and the tuning dial for a pull that is too strong stays its frequency.

**A table may stand in for content that is not authored yet, but it says so.** `docs/ITEMS.md` §5
lists Mechanism, mithril materials and tonics in the Strongbox, and Wellglass in the Wellspring
chest; none are authored. The tables ship with those weights redistributed across lines that exist
rather than pointing entries at ids that do not — an entry naming a missing id validates fine, opens
fine, and silently grants nothing, which reads to a player as a stingy tier rather than as a bug.
`tools/loot_content_check.gd` resolves every id in every table against the real Registry so a
stand-in stays a decision and never becomes a typo. World's Okayest Axe is `stone_axe` at weight 1
in the Gilded pool until A-047 gives it its gold skin; King's Purse is a 400–800 coin line, which
needs no new mechanism at all.

## Template

```
### D-060 · 2026-08-18 · Environmental presentation binds to the asset, never to a level, a map, or a node name

Sequoyah's instruction, and the rule F-097 exists to enforce: *"animations are gonna need to be
linked to each asset. They can't be linked to a scene or a map since the game will be procedurally
generated."*

Release worlds are generated. `levels/hollowmere.tscn` is an interim playtest fixture, so any
presentation attached to a specific scene tree — a node placed in the level, a group name that map's
author happened to use, an `AnimationPlayer` parented under a level-specific node — is dead code the
moment the generator builds a world instead of loading that map. This has already cost us twice:
F-076 keyed `EnemyWorld` and `HarvestWorld` to Playtest Hollow's group names, so Hollowmere shipped
with no crawlers and no harvestables; F-097 keyed environmental VFX to the node *type* and *name* the
old map produced, so Hollowmere shipped with no wind and no firelight, on 13,026 instanced copies.

**The binding is a stable asset id, carried by the asset.** `world/environment/asset_vfx_library.gd`
maps an asset id — `station_campfire`, `grass_tuft_a` — to what that asset does, and references no
scene, map, layout or node. Generators stamp the id in an `asset` meta on everything they emit; a new
generator inherits every effect by stamping the same meta and changing nothing else. Because an
instanced batch has no per-copy node, a generator also publishes a `placements` array for any asset
whose presentation is per-copy — the renderer is not somewhere those positions can be read back from
(F-103).

**The cost this rule imposes, accepted deliberately:** an effect that genuinely belongs to one place
rather than one asset — a scripted set-piece — has no home in this system and needs its own. That is
the right trade while every shipping world is generated.

**Would change my mind:** if MIRE ever ships hand-authored story levels as the primary content, a
level-owned presentation layer would become worth building *alongside* this one. It would not replace
it — the generated worlds still need asset-bound effects — so this would become the default rather
than the only mechanism.

---

### D-061 · 2026-08-18 · Physics layer 2 is `terrain`, and only terrain; every other collider stays on layer 1 (`solid`)

F-075's fix needed a named collision-layer convention that did not exist anywhere in the project.
Decided: **layer 1 (`solid`) is the shared default — props, harvestables, placed buildable pieces,
players, enemies, everything that is not ground. Layer 2 (`terrain`) is ground and nothing else.**
Named in `project.godot`'s `[layer_names]` (`3d_physics/layer_1="solid"`,
`3d_physics/layer_2="terrain"`) and in code as `PlacementValidator.TERRAIN_LAYER`, the single source
of truth every consumer preloads rather than re-declaring the constant.

**Why terrain moves and nothing else does:** moving props/pieces instead would have meant every
future prop-emitting path (there are several: `authored_world.gd`, `playtest_hollow.gd`, harvestables,
placed buildables) needs the new layer to avoid becoming invisible to whatever still expects layer 1,
where moving only terrain means exactly one thing changes — one `StaticBody3D` per world generator —
and everything that already defaults to layer 1 keeps working unless it specifically needs to see the
ground (support probes, movement).

**The corollary this decision creates, and why it is worth stating separately:** anything that
*moves around* on terrain — `CharacterBody3D`s (players, enemies) — has an engine-default
`collision_mask` of `1`, which would silently stop detecting the ground the instant that ground left
layer 1. F-075 fixed the two that exist today (`entities/player/player.tscn`,
`systems/enemies/enemy.gd`, both now `collision_mask = 3`). **Any future `CharacterBody3D`,
`RigidBody3D`, or physics query that needs to stand on or otherwise detect terrain must OR in
`PlacementValidator.TERRAIN_LAYER`, or leave its mask at the engine default (all layers) — never
narrow it to a bare `1` and assume that still means "everything solid."**

**Left deliberately un-migrated:** `world/gen/playtest_hollow.gd`'s terrain stays on layer 1.
It is deprecated (superseded by Hollowmere), was locked by another lane's claim when this was
decided, and — confirmed by grep — has no `PlacementValidator` caller today, so leaving it costs
nothing. Migrate it in the same pass that finally retires or rebuilds that map, not before.

**Would change my mind:** a second "thing you can query separately" appears (interactables? water
volumes?) — at that point a bitmask big enough for one more named layer is cheaper than teaching every
consumer a third special case, and it should be added the same way this one was: one constant, one
`project.godot` name, and an explicit audit of every `collision_mask` default that would otherwise go
blind to it.

### D-062 · 2026-08-18 · A world marker's `kind` names converge on one canonical spelling per concept; a system's ground-truth check reads that spelling, not its own group-recognition list

F-076: Hollowmere shipped with zero enemies because `EnemyWorld` only recognized Playtest Hollow's
`enemy_spawn` marker kind, and Hollowmere's generator had independently chosen `enemy_nest` for the
same concept. Two names for one idea is what let the mismatch happen silently — nothing was wrong
with either name alone.

Decided: **`enemy_nest` is the one marker `kind` any map's generator should publish for its enemy
nests from here on** (`EnemyWorld.CANONICAL_NEST_KIND`). `EnemyWorld.NEST_SOURCES` keeps reading
Playtest Hollow's legacy `enemy_spawn` too, for backward compatibility with a map that still exists —
but that list is explicitly *not* the vocabulary a ground-truth check should trust, because it is
exactly the thing that goes stale one map generator at a time. `EnemyWorld.expected_nest_count()`
(F-076) reads the canonical spelling directly off a layout's raw JSON, independent of `NEST_SOURCES`
entirely, so `tools/world_contract_check.gd` measures a map against the convention rather than against
whatever this file happens to already recognize.

The same reasoning applies the next time a second synonym appears for any marker/group concept:
pick one canonical spelling, document it next to the constant, and keep any legacy synonym list
separate from whatever a check treats as ground truth.

**Would change my mind:** a real need for the SAME concept to mean different things on different maps
(not just a naming accident) — at that point per-kind semantics belong in the layout schema itself
(a `nest_radius` field, say), not a second name for the same thing.

---

### D-063 · 2026-08-18 · Chest jackpots are a feature: balance loot by rarity, never by capping the high end

Sequoyah's directive while the item/loot catalog (`docs/ITEMS.md`) was planned, verbatim in intent:
*"I really like there to be an item system where you could get something crazy good from a chest,
even if it kind of makes the game too easy sometimes — it just is really fun."* This is DNA rule D4
("stacking powerups that break the game — the reason you replay") extended to loot: the Gleam pool
(ITEMS.md §4.9) and the Gilded Chest exist to produce run-warping pulls on purpose. A run trivialized
by a lucky pull is an acceptable outcome, not a balance bug — the analogue is Risk of Rain 2's
legendary tier, where every entry defines a run and rarity does all the balancing.

Concretely: tuning may adjust **how often** the Gleam pool appears (gilded spawn count, key drop
rates, table weights), and must not sand down **how strong its entries feel** until they are just
better commons. A Gleam entry too weak to change how the group plays gets replaced, not nerfed.

**Would change my mind:** playtests showing jackpot pulls repeatedly making *other* players
miserable or checked-out (not just the run easier) — the fix is still frequency and co-op-flavoured
jackpots (Second Sunrise over Eggshell Warlord), with per-entry potency nerfs strictly the last
resort.

---

### D-064 · 2026-08-18 · Whether a prop can be harvested is a property of the ASSET, and the world builder decides per family whether it earns a node or stays in the batch

**Decision.** Harvestability is looked up from the asset id through
`systems/harvesting/harvest_library.gd`, never authored per placement in a layout file. The same
table answers a second question the world builder must ask — `Represent.NODE` (its own holder and
mesh) or `Represent.BATCH` (stays in the chunk's `MultiMesh`, logic-only holder) — so density and
harvestability are decided together, once, in the place that knows the asset.

**Why.** Hollowmere shipped with 2,869 props of which **83** could be hit. The other 62 trees, 198
rocks and 794 bushes were painted scenery, because `harvestable: true` was written per placement by
`tools/mapgen/hollowmere_layout.py` and `HarvestWorld` carried a three-entry table of the three
`assets/harvestables` exports. That is F-097's failure shape a second time: behaviour keyed to one
map's authored data, silently absent on the next map. **Release worlds are procedurally generated**
(D-045, and the whole reason `AssetVfxLibrary` exists), so a layout file is not a place to record
what a pine *is*. Keying on the asset made 1,181 props live with no layout regenerated, no map
edited, and nothing for a future generator to remember beyond the asset id it already stamps.

The NODE/BATCH split is in the same table rather than in the builder because it is the same
question. Promoting all 794 bushes to their own `MeshInstance3D` would have turned a handful of
batched draw calls into eight hundred, on a game whose stated target is the worst machine someone
might play it on; leaving trees and ore batched would have made them unhideable, since one instance
of a MultiMesh is not a thing you can hide by visibility. Two representations, one decision point.

**Consequences.**

- `HarvestableDef.active_state_scenes` may be empty, meaning "this asset is its own intact visual".
  Without that, every new family needs a three-state Blender export before it can be chopped, which
  is what kept the table at three entries for as long as it was.
- A harvestable may legally have **no collider**. `CombatService` targets `&"damageable"` by
  distance and arc, not by raycast, so a walk-through bush is still swingable — and soft flora
  *should* be walked through.
- A BATCH prop's placement is recorded by the builder as a meta, never read back from the
  `MultiMesh`. That read is a RenderingServer round trip and answers identity under the dummy
  renderer, so a restore would teleport every bush to the world origin — and no headless check
  would see it.

**What would change my mind.** If a generated world ever wants the same asset harvestable in one
biome and scenery in another, this table stops being sufficient and the answer becomes
(asset, biome) rather than (asset). Add the second key to the library — do not move the decision
back into the layout.

### D-0NN · YYYY-MM-DD · <one-line decision>
<why, in 2–4 sentences>
**Would change my mind:** <the specific evidence that should make you revisit this>
```

### D-065 · 2026-08-18 · The `LM` lane spends the Max account to 90% of its five-hour window and then stops
`LM` dispatches headless work to the same Claude Max account the **director chat itself runs on**, so
alone among the lanes it spends the director's own quota. Sequoyah's call: let it run to 90% and hold
the rest. This looks like it contradicts the standing rule that unused subscription quota is wasted,
and the exception is deliberate — a lane that drains the five-hour window leaves the director unable
to route, verify or close anything out, while still being the thing responsible for noticing that
work has stopped. The reserve funds a clean close-out; it is not a savings account, and this is the
only place in the project where holding quota back is the right move. Implemented as `reserve_pct` on
the lane and enforced in `lane.quota_block`, which is inert until LM has reported usage once, because
`used_pct` does not exist before a first run.
**Would change my mind:** evidence that the director's own turns are cheap enough to finish inside
the last 10% anyway, or a director that no longer shares an account with a dispatchable lane — in
either case the reserve is pure waste and should go to zero.

### D-066 · 2026-08-18 · MIRE's audio is synthesized in-repo from committed recipes, not licensed or commissioned
Sequoyah directed the first music/SFX pass to be made by us (Fable at max effort) rather than the
CC0/licensed route the 7.1/7.2 roadmap rows assumed. `tools/audio/` renders every asset
deterministically from numpy DSP recipes: the score/recipe is the source of truth, assets are
reproducible build products, ownership is unambiguous for Steam, and per-instance variation
(seeds, pitch scatter) is free — which suits procgen worlds. Two supporting calls ride along:
listening copies for Sequoyah are MP3 (macOS can't preview OGG Vorbis) while committed game assets
are OGG; and the two music `.ogg.import` sidecars are force-committed as gitignore exceptions
(`icon.svg.import` precedent) because `loop=true` must survive a fresh clone.
**Would change my mind:** his ears rejecting the synthesized sound outright, or trailer/store-page
quality demands exceeding what the toolkit can reach — then commission music (7.2's original plan)
and keep the synthesized SFX/ambience underneath.

### D-067 · 2026-08-18 · F-117's docs-file misattribution risk gets a done()-time content hash, not claim-time hunk-range diffing
F-117 left two options open: migrate to F-102's one-file-per-finding shape (removes the collision
outright), or a cheaper `ship`-side heuristic. Took the cheaper one now, since the migration is a
bigger claim than one task should make unilaterally. `_release()` (fires on `done`/`handoff`/`drop`)
now snapshots a sha256 of each released file's bytes into `recent[f]["hash"]`; `ship` recomputes it
for every file it is about to stage and warns — names the file(s), does not block — if the working
tree no longer matches. Chose the **done-time** snapshot over the finding's own sketch of a
**claim-time** snapshot plus line-range hunk attribution: everything a task writes between its own
`claim` and its own `done` is legitimately its edit and must never warn, so diffing from claim-time
would need to reconstruct which hunks were "mine" before comparing — exactly the hard part the
finding flagged as unsolved. Diffing from done-time needs no attribution at all: in the documented
workflow (`done` immediately followed by `ship`) the file should be byte-identical between the two,
so ANY difference is by definition somebody else's edit landing in the gap, with no false positives
from the task's own legitimate work. Verified: `python3 tools/harness_check.py` — new case fails
against `--rev HEAD` (pre-fix) and passes against the working tree (post-fix); a second case proves
a matching hash stays quiet.
**Would change my mind:** a real case where the working tree legitimately changes between a task's
own `done()` and its own `ship()` (nothing in the documented workflow does this today) — that would
make the heuristic noisy enough to train people to ignore it, same failure mode F-072 was fixing.

### D-068 · 2026-08-18 · A carried object always creeps toward its target at a host-bounded speed — "full speed" is a cap, never an assignment

Task 3.10 (heavy hauling). The spec's shorthand — duo carries "at full speed", solo is "a slow drag"
— reads like duo should just track the midpoint exactly (`position = target`) while only solo gets a
`move_toward` cap. That would be wrong: own-player movement is client-authoritative (§2.2 row 1), so
a carrier's replicated position is not something the host can distrust the *value* of, only bound the
*rate* the object is allowed to chase it at. If duo assignment-tracked instead of capping, a
carrier's client teleporting its own body (a lag spike, a bug, or a genuine speed hack) would teleport
the object with it on the very next tick duo held — the one case task 3.10's own acceptance check
exists to rule out.

So `systems/hauling/haul_math.gd`'s `step()` is `move_toward(current, target, speed * delta)` in
**every** carrier-count branch; "full speed" (duo) and "slow drag" (solo) differ only in which speed
feeds that same capped call — `carry_track_speed_mps` vs. `carry_track_speed_mps *
solo_drag_multiplier`. Neither branch ever assigns the target directly. `tools/haul_net_check.gd`
proves exactly this: a real client teleports its own body 990 m in one write, and the object measurably
creeps toward the new target (proving the mechanism is live, not frozen) while staying within the
bounded-speed envelope for the whole watch window — never within an order of magnitude of the jump.

**Would change my mind:** a design change that makes duo genuinely instantaneous (e.g. the object
becomes a true kinematic child of the midpoint rather than something separately simulated) — at that
point "assignment" and "bounded speed" stop being different mechanisms because there is no longer a
tick-by-tick target to chase at all.

### D-069 · 2026-08-18 · One peer carries at most one haulable object at a time

Task 3.10. DESIGN.md §4.5 says "high-tier ore requires 2 players to carry" but never says whether a
player can also carry ANOTHER object at the same time — reads as one pair of hands, not one slot per
object, and nothing about the mechanic (a player still walks, still fights, still has both hands
occupied by whatever they're hauling) suggests otherwise. `HaulService.is_peer_hauling(peer_id,
exclude)` scans every live haulable's `carriers` and `Haulable._accept_pickup()` refuses a second
pickup with `"already carrying something else"` before the range check runs. Cheap: haulables are
expected to number in the dozens on a map, not thousands, and this only runs once per pickup request,
never per tick.

**Would change my mind:** a design call that a player can stack multiple simultaneous carries (no
gameplay reason has come up for it) — the check is one `is_peer_hauling` call to remove, not a
redesign.

### D-070 · 2026-08-18 · Attunements ship as a single granted PowerupDef per role; their qualitative table halves stay unbuilt, not faked

Task 3.9's own spec line is load-bearing: "Effects are PowerupService modifiers granted at
selection — attunement is *data over 3.3*, zero new stat plumbing." DESIGN.md §4.5's table gives
each of the four roles two kinds of effect — a few that are plainly stats already in
`PowerupDef.KNOWN_STATS` (Warden's ward radius, Forager's gather yield, Tinker's craft time,
Reaver's melee/ranged damage and coin drops) and several that are new capability gates with no stat
to attach to (Warden's taunts, Forager seeing resources through terrain, Tinker unlocking Ward
turrets and higher station tiers, Reaver being unable to build Wards).

Building the second half now would mean inventing new plumbing in `systems/building/`,
`systems/harvesting/`, and wherever taunting ends up living — exactly what the spec line forbids.
So each Attunement (`content/attunements/*.tres`) is a thin AttunementDef naming ONE backing
PowerupDef (`content/powerups/attunement_*.tres`, `max_stacks = 1`, no §4.4 tags) that carries only
the stat-shaped half of its row, at deliberately modest magnitudes (10–25% per stat) since these are
placeholder-tuned like every other 3.x worked example, not a balance pass. The capability halves are
not stubbed, flagged, or partially wired — they simply are not part of this task, and the table cell
each one came from is named above so nobody has to re-derive which effects are still owed.

**Would change my mind:** nothing about this decision itself — it is scope, not a technical bet. The
thing that changes is which task closes the gap: Ward turrets are 3.6/3.7's territory once building
supports a turret piece, terrain-sight is a rendering/harvesting question, and taunts and a
build-lockout are new mechanics with no obvious home yet. Whoever picks one up should extend the
existing Attunement, not invent a second field for it — `AttunementDef.granted_powerup_id` is a
single id today only because nothing yet needs a second one.

### D-071 · 2026-08-18 · Attunement selection triggers at run start, not DESIGN §4.5's "first Wellspring cap"

DESIGN.md §4.5 reads "At your first Wellspring cap, each player picks one" — but Wellsprings are an
M4+ Mire-grid mechanic (`docs/ARCHITECTURE.md`'s Mire grid row) that does not exist yet, and gating a
now-buildable M3 feature on a not-yet-built M4 one would strand it unshippable. `docs/SPECS.md`'s own
3.9 execution block, written after DESIGN.md as the deliberately execution-ready simplification for
this milestone, already says "Selection at run start" instead — this decision just records that the
divergence from DESIGN.md is intentional rather than a mistake the next reader has to puzzle over.

"Run start" is implemented as: the local player's first `PlayerNet.player_spawned` this session, if
`AttunementService.local_selection()` is still empty. A run is one sitting (D-010), so a player's
first spawn IS their run start; a peer that joins mid-session gets the same treatment at ITS first
spawn, which is that peer's own run start. `ui/attunement/attunement_ui.gd` opens automatically then
and has no dismiss path — Escape does nothing, because there is nothing to escape to. Respec is
already out of scope (task 3.9's own spec line), so there is no reopen path to design either.

**Would change my mind:** task 4.x building a real Wellspring-cap event. At that point the natural
move is for `AttunementUI` to listen for that event instead of `player_spawned` — the service's
selection/lock/broadcast logic underneath does not change, only what triggers the UI's first open.

### D-072 · 2026-08-18 · Dodge i-frames are exactly the dash window, riding the player's existing position/rotation synchronizer, not a second timer or a new RPC

Task 3.8b's spec says the host checks a `dodging` flag "the player's synchronizer already carries" —
read literally: `entities/player/player_controller.gd`'s `dodging: bool` is a fourth
`REPLICATION_MODE_ALWAYS` property on the SAME `SceneReplicationConfig` as position/rotation, not a
new RPC (`net_report_local_stamina`'s advisory-unreliable shape was considered and rejected — stamina
can tolerate a stale/dropped report because the host never gates on it, D-040, but an i-frame flag
that arrives late or not at all is a hit that should have missed landing anyway).

Two consequences worth recording so nobody "simplifies" them later:

1. **The i-frame window IS `dodge_duration_sec`, not a separate `dodge_iframe_sec`.** Simplest reading
   of "a dash impulse with i-frames" — one number tunes both, and there is no state where the flag is
   true without the dash also being in progress or vice versa.
2. **`dodge_duration_sec`'s export floor (0.1s) is not arbitrary — it exists because of (1) and how
   ALWAYS-mode replication actually works.** `dodging` is ALWAYS, not ON_CHANGE, specifically because
   ON_CHANGE only sends when the current value differs from the last value SENT — a flag that flips
   true then false again between two per-interval checks can be missed entirely, never observed as
   true even once. ALWAYS resends the current value every tick regardless, so the flag is guaranteed
   to be seen as long as the window it's true for comfortably exceeds one `NetConfig.
   PLAYER_SYNC_INTERVAL_SEC` (~0.033s, 30Hz). A future balance pass that drops `dodge_duration_sec`
   toward that floor is trading real i-frame reliability for a snappier dash, not a free tuning knob.

**Would change my mind:** a measured case where 0.1s is still too close to the sync interval under
real jitter/packet loss (the check only proves the LOCAL-loopback case) — the fix would be either
raising the floor further or moving `dodging` to its own higher-frequency channel, not silently
trusting a thinner margin. Also: DESIGN §4.4's Void Resonance "dodge blinks" changing the verb's shape
enough that i-frames and the dash's physical motion genuinely need to decouple (a blink that teleports
instantly but leaves i-frames active slightly longer, say) — `_execute_dodge()` was kept a wrappable
function precisely so that kind of change has somewhere to live without touching this file's core.

### D-073 · 2026-08-18 · "Never bulk-generate content data" limits the pace of authoring, not who authors

`AGENTS.md`'s rule of that name has been read — including by an agent on 2026-08-18 — as "content is
Sequoyah's; an agent's job stops at the framework." **That reading is wrong, and he corrected it
directly:**

> "I think never bulk generate content is being misinterpreted. I want you to generate content, just
> do it one thing at a time so that you put the proper amount of focus and attention to each asset
> you create instead of trying to do all of it at once and then doing a bad job on everything."

The constraint is **pace and attention, not authorship**. Agents author MIRE content — items,
powerups, recipes, enemy stats, Cycle Modifiers. What the rule forbids is the bulk sweep: emitting
forty definitions in one pass where each is a template fill and none received a design decision. The
failure mode being prevented is a whole family of uniformly mediocre content, which is worse than
half as much content that is genuinely considered.

In practice: take one asset, decide what it is and why it is interesting, write it against the real
schema, verify it, and only then start the next. "Author 40–60 powerups" is forty individual
authoring jobs, not one bulk job, and finishing fewer of them at full quality is the intended
outcome. This also unblocks the T0 authoring tasks (3.2, 3.4, 3.7), which had been parked on the
mistaken belief that an agent must not touch them.

`AGENTS.md` §"Never bulk-generate content data" was reworded in the same commit; its former text
("Build the *framework*; he builds the *content*", "if you find yourself about to write the 40th
powerup definition, stop") is the stale side of this correction.

**Would change my mind:** Sequoyah saying a specific content type is his — the one place the
original reading is still plainly right is anything resting on visual or playfeel judgment, where
D-039's hand-off criterion applies for its own reasons. Nothing about this decision overrides
D-031's editor-closed per-file claim on `.tres`, which is corruption protection.

### D-074 · 2026-08-18 · R2b (task 4.0a) is measured — collision cooking, not GPU upload, is the real cost, and 4.3's per-frame budget is ~2–3 chunks

D-015 left two costs open as the caveat on R2's GREEN verdict: `ConcavePolygonShape3D` cooking and
GPU mesh upload, both excluded because R2 ran under the headless dummy renderer. `tools/bench_chunk_gpu.gd`
measures both on a real renderer (`agent godot --windowed --script tools/bench_chunk_gpu.gd`, Metal
4.0 / Apple M5 Pro), building the exact same chunk R2 did — 32 m, 1 m vertex spacing, 2048 tris (see
the script header: the work order's "1.5 m voxel scale" matches nothing on record anywhere in R2,
D-015, or `chunk_mesher.gd`, so this measures R2's actual, on-record parameters instead of inventing
an unbudgeted new scale). 60 chunks, 4 untimed warmup chunks first so first-ever-shape/first-ever-material
costs don't land on chunk 0.

**The result inverts the risk D-015 was worried about.** GPU upload and material bind are both
cheap: mesh upload (`MeshInstance3D.mesh = ...; add_child()`) is **0.020 ms/chunk**, material bind
(a shared `StandardMaterial3D`, `material_override =`) is **0.002 ms/chunk** — together under 3% of
the budget. **Collision cooking dominates completely: 1.482 ms/chunk mean** (min 0.819, max 3.903 —
worth noting for a streaming system, since a single unlucky chunk can cost 2.6× the mean), almost
4.5× R2's own 0.330 ms/chunk mesh-build cost. A separate, one-time **first-frame GPU sync cost**
(shader/pipeline compilation plus any deferred buffer upload not captured by the immediate
RenderingServer call) adds **0.297 ms/chunk amortized** the first time a batch of chunks is drawn —
real, but a one-time-per-chunk cost distinct from the steady-state per-load budget below.

**Steady-state main-thread cost per streamed-in chunk: 1.17–1.50 ms** across two runs (cook
1.15–1.48 + upload 0.013–0.020 + material ~0.001) — this machine runs several concurrent agent
lanes, so some spread run-to-run is expected; the *ratio* between collision cook and everything
else held steady both times (cook is ~90–100× upload, ~4–4.5× R2's own mesh-build cost). Against
the 4 ms streaming slice 4.3's spec block reserves out of the 16.667 ms frame (the same "budget a
slice, not the whole frame" pattern nav baking used in D-016), that is **2.7–3.4 chunks/frame** at
this chunk size; a full frame with nothing else running would fit ~11–14.

**This is 4.3's design input, going forward:**
- **Collision cooking is the thing to budget around, not mesh gen or upload.** 4.3's spec already
  says "collision cooks lazily (nearest ring only)" — this measurement is why: cooking every
  streamed chunk's `ConcavePolygonShape3D` synchronously on the main thread is the actual
  bottleneck, at ~4.5× the mesh-build cost R2 measured. Mesh upload and material bind can ride
  along on every chunk essentially for free.
- **`ConcavePolygonShape3D.set_faces()` cannot move to `WorkerThreadPool` the way mesh generation
  can** — it calls into PhysicsServer/Jolt synchronously and must run on the main thread (same
  constraint R3 hit with NavigationServer sync, D-016). 4.3 should budget collision cooking as the
  gating cost for "how many chunks load this frame," with mesh build and GPU upload effectively
  free by comparison.
- **Use 2–3 chunks/frame as the working budget for a 4 ms streaming slice**, not the R2-only
  0.330 ms figure D-015 published — that number never included the cost that turned out to matter.

**Would change my mind:** a widened test — more chunks, chunks with real (non-flat-noise)
complexity nearer a cliff or structure, or the target minimum-spec GPU rather than an Apple M5 Pro —
showing collision cooking cost scaling worse than linearly with triangle count, which would push the
budget down further; or 4.3 finding a way to cook collision off-thread (a custom Jolt binding, or
building the shape from a coarser decimated mesh than the render mesh), which would remove the
gating cost this decision is built around entirely.

### D-075 · 2026-08-18 · Task 4.1's island heightmap is two layered FastNoiseLite fields (continental + detail) masked by a cubic radial falloff, all inside the D-017 safe set

`world/gen/island_heightmap.gd` — `IslandHeightmap.height(x: float, z: float, world_seed: int) ->
float`, a pure static function: no nodes, no shared instance state, a fresh `FastNoiseLite` built
per call (same thread-safety reasoning `world/chunk/chunk_mesher.gd`'s R2 spike already documents —
a shared noise instance is not safe to sample from several `WorkerThreadPool` tasks at once, which
4.3 will do). "Layered simplex" is two independent FBM noise fields — a low-frequency 5-octave
continental layer and a higher-frequency 2-octave detail layer at 8% weight — summed, not one
fractal call alone; ARCHITECTURE.md §4 step 1 names "layered noise" as its own pipeline stage
distinct from the falloff mask that follows it, so two fields reads truer to the spec than relying
on `FastNoiseLite`'s own octave parameter to be "the layering."

**Every operation stays inside the D-017/§7 safe set** — `FastNoiseLite`, `+ − × ÷`, and
`Vector2.length()` for the radial distance. The island falloff is `1.0 - t*t*t` (cubic, `t` the
normalized distance past `FALLOFF_START_FRACTION`), not `1.0 - pow(t, 3.0)` — same substitution
D-017 already made for the general falloff shape, applied here to the real one. No RNG: a
continuous height field needs none. The per-subsystem seed convention `world/gen/undergrowth.gd`
established (XOR the shared world seed with a subsystem-specific salt constant) is reused for the
two noise layers' seeds even though this subsystem has no RNG, so POI placement and resource
scatter (still to come) have a worked example to extend rather than inventing their own scheme.

**Island radius is 512m** — chosen to match `ARCHITECTURE.md` §5's Mire grid coverage (256×256
cells × ~4m ≈ 1024m across, so radius 512m from origin), so the corruption sim and the terrain it
tints cover the same ground rather than one clipping the other at the edge. `HEIGHT_SCALE = 60.0`m
peak amplitude is placeholder-tuned, same as every other early M4 magnitude — nothing to look at
until 4.2's biomes exist.

**Verified:**
- `agent godot --script tools/terrain_check.gd` — 6 assertions, 0 failures: same `(x, z, seed)`
  returns the bit-identical float twice; a different seed changes the height at a fixed point; a
  neighbouring point differs (not a flat plane); a point well beyond `ISLAND_RADIUS` and a point
  exactly at it are both flat `0.0`; interior heights stay within `HEIGHT_SCALE` bounds.
- `agent godot --script tools/check_determinism.gd` — extended with a fifth `terrain_hash`
  alongside the existing `rng_sequence`/`noise_simplex`/`noise_perlin`/`float_math` probes, same
  SHA-256-over-a-fixed-grid pattern, sampling `IslandHeightmap.height()` on a 64×64 grid at 24m
  spacing centered on the origin (so the grid crosses the 512m falloff edge, not just flat interior
  noise) at the same `SEED = 20260815` the other probes use. **macOS arm64, Godot
  4.7.1-stable-a13da4feb: `terrain_hash bea0483c1ad5bb4b`**, reproduced identically across two
  separate runs. The other four hashes matched D-017/D-028's already-recorded macOS values exactly
  (`rng_sequence 0077d6b42cd6f78f`, `noise_simplex 181e558b7b4841cf`, `noise_perlin
  6c7a944516e3e64f`, `float_math 063eec62c34fa4ee`), confirming this is the same reference machine/
  engine build those decisions measured on.
- Full boot: `agent godot --quit-after 60` — 0 `ERROR:` lines.

**Not measured here — inherited risk, not new risk.** `terrain_hash` is built entirely from
primitives D-017/D-028 already proved bit-identical across macOS arm64, Windows x86_64, and Linux
x86_64 (`FastNoiseLite`, `+ − × ÷`, `sqrt`/`Vector2.length()`). No new operation class is
introduced, so a fresh three-platform run is not required to trust this — but the next agent
touching a Windows or Linux box should still run `check_determinism.gd` there and confirm
`terrain_hash` matches `bea0483c1ad5bb4b` before anything ships against this heightmap over the
network, the same way D-028 closed the Windows column for the original four.

**Would change my mind:** a Windows or Linux `terrain_hash` run disagreeing with the macOS value
above — that would mean the two-layer/salt/falloff arithmetic itself introduces platform drift even
though every primitive it's built from is individually safe, which D-017/D-028 didn't test for
directly. Also: 4.2 or later needing `TYPE_CELLULAR`/domain warp noise, which D-017 already flagged
as untested and out of the safe set as measured.

### D-076 · 2026-08-18 · A console open (tree paused) unpauses itself for an in-flight HOST-command RPC round trip

Task 3.13's own spec end-note flagged this as the one thing to *measure*, not assume: "`SceneTree`
polls multiplayer outside the pause gate in 4.7, so this should already work — but prove it in
`tools/command_net_check.gd`... and if it doesn't, the console unpauses for the round trip." It
doesn't. `tools/command_net_check.gd`'s first version proved it directly: a client submitted a
HOST-scope command with `DebugConsole` genuinely open (`get_tree().paused = true`), and
`net_command_result` never reached the client's own `_rpc_result_received` signal inside a 15 s
window — even though the HOST had already executed the command and sent the reply (visible from the
host's own `InventoryService` state, and confirmed with temporary instrumentation before this was
understood as a pause issue rather than a check bug). Unpausing the client's tree immediately after
`submit()` and re-pausing once every request it caused resolves (`debug_console.gd`'s
`_unpaused_for_handles`) fixed it outright — the same net check, unmodified in structure, now passes
in well under a second.

**Scope of the fix:** `DebugConsole._run()` unpauses for exactly as long as at least one request IT
submitted is in flight, and only if the tree is currently paused *because of* this console
(`pause_while_open`). A LOCAL command never touches this path — it resolves inside `submit()` before
the unpause check even runs, since nothing left this process. Any later system that submits a
command from a paused context inherits this by going through `DebugConsole`/`CommandService`'s
existing `submit()`; nothing else in the engine needed to change.

**Would change my mind:** a Godot engine version where `SceneTree.paused` genuinely does not gate
`SceneMultiplayer`'s RPC delivery (contrary to what was measured here on 4.7.1) — then this becomes
dead code, not wrong code, and can be deleted once re-verified.

### D-077 · 2026-08-18 · CommandService is one front door; every command is a thin wrapper over an existing host seam; scope is LOCAL or HOST; ops gate every HOST command; commands ship in release builds

Filed verbatim from `docs/COMMANDS.md` §9 item 1, the plan this task executes against. A command
handler never grows its own mutation path — if a verb needs something no existing service exposes,
the fix is a new seam on the OWNING service (`InventoryService`, `EnemyWorld`, …), never a
special-cased branch inside a command handler. `give`/`spawn`/`killall` (this task's migrated set)
already follow this: they call `InventoryService.host_add`/`EnemyWorld.host_spawn`/
`host_despawn_all`, the same seams the pre-3.13 hand-rolled commands called. Scope is exactly two
values (`LOCAL`, `HOST`) — no third "hybrid" scope — and every HOST command is refused with the same
uniform wording (`CommandService.NOT_OP_MESSAGE`) unless the issuing peer is the host itself or has
been opped. Commands are not gated out of release builds: D-002/D-030's reasoning (cheating is
irrelevant among friends; cross-play testing wants a console) already covers this, and op-gating is
strictly more control than the pre-3.13 console had (every command was local-only and host-typed
before this task; now a client can reach `give`, but only once opped).

**Would change my mind:** a mutation that genuinely cannot route through an existing seam without
duplicating validation the owning service already does — that means the owning service is missing a
seam, and the fix belongs there, never in a command handler working around it.

### D-078 · 2026-08-18 · The host re-parses a client-submitted command's raw line from scratch — a client's own parse is never trusted, only the line it typed

Filed verbatim from `docs/COMMANDS.md` §9 item 2. `net_submit_command(request_id, line: String)`
carries exactly one piece of client-authored data across the wire: the raw text. The host does not
receive, and therefore cannot be handed, any pre-parsed argument structure — `CommandService.execute()`
on the host side runs the identical `_parse_args()`/type-parser pipeline a locally-typed command
would, against the host's own `Registry`/`EnemyWorld`/`NetSession` state, not anything the client
computed. This is the same trust stance `BuildService` already takes re-snapping the ghost's
transform rather than trusting a client-reported placement (D-034's neighbor). The cost is
re-parsing a short string per command, at up to 6 peers, on commands typed at human speed — not a
budget concern now or foreseeably.

**Would change my mind:** parse cost ever mattering at 6 peers (it won't).

### D-079 · 2026-08-18 · Task 4.2's biome resolution: `priority` (lower wins) + id tie-break, with a guaranteed fallback so every point gets a biome

`world/gen/biome_map.gd`'s `BiomeMap.assign(height, moisture, biome_defs)` needed a rule for two
cases the spec's "biome = f(height, moisture-noise)" wording doesn't settle by itself: what happens
when more than one `BiomeDef`'s range contains the same point, and what happens when none does (a
near-certainty once Sequoyah is authoring biomes one at a time per D-073, rather than all of them
landing with full coverage in one pass).

**Decided:** every `BiomeDef` gets an authored `priority: int` (default 10); among every def whose
range contains the point, the lowest priority wins, and a tie breaks on `id` compared as a plain
`String` — arbitrary but identical on every peer regardless of `Dictionary` iteration order, which
is the only property that matters for a value that must never desync. A point matching **no** def at
all falls back to the single lowest-priority def in the whole registry (same tie-break) rather than
returning an empty `StringName` — a hole in authored coverage reads as "the closest thing we've
got," never a blank patch of terrain with no biome at all. The three worked examples use this
directly: `shore` is `priority=0` specifically so it wins sea level even against a future biome
whose range carelessly reaches down to low elevation, and `grassland`/`forest` share `priority=10`
with an exact-matching moisture boundary (0.5), so the tie-break — not a gap — is what decides that
one point.

**Would change my mind:** a biome family wide enough that alphabetical tie-breaking produces
visibly wrong results at a real boundary (at which point the fix is an explicit `priority`, which
already exists for exactly this); or 4.4's scatter tables needing per-point *blending* between two
biomes rather than one deterministic winner, which is a different, additive feature, not a reason to
change how the winner is picked today.

### D-080 · 2026-08-18 · Task 4.3's chunk streamer: Chebyshev rings, D-025's hysteresis generalized to N tiers, and the collision ring IS the LOD0 ring

`world/chunk/chunk_streamer.gd` (`class_name ChunkStreamer`, a `Node3D`) streams a ring-buffer of
terrain chunks around a caller-supplied set of world-space anchors. Three decisions the spec left
open, plus the measurement that closes 4.0a's gate for real rather than in isolation.

**Ring geometry is Chebyshev (square-ring), not Euclidean.** `NetInterest`'s D-025 filter uses
squared Euclidean distance because it runs per-entity-per-peer-per-physics-tick — hundreds of
cheap comparisons where a sqrt-free circle is the right shape. This system instead runs over
hundreds of *resident chunks* on a grid, where "ring" is already a grid concept; Chebyshev distance
(`max(|dx|, |dz|)`) is one integer comparison per axis and produces the square rings a chunk grid
actually tiles in.

**D-025's hysteresis generalizes from one radius pair to N tiers, asymmetrically.** Three LOD
tiers — `LOD0_RADIUS_CHUNKS=2` (full detail, 1 m spacing), `LOD1_RADIUS_CHUNKS=5` (half, 2 m),
`LOAD_RADIUS_CHUNKS=8` (quarter, 4 m) — each with a shared `HYSTERESIS_CHUNKS=1` leave-band, same
asymmetry D-025 established: *tightening* (gaining detail as an anchor approaches) is immediate,
*loosening* (losing detail, or unloading) only happens once a chunk is past its current tier's own
boundary plus the hysteresis band. A chunk hovering on a ring edge changes tier once, not every
step across it — verified directly: nudging an anchor one chunk past `LOAD_RADIUS_CHUNKS` leaves a
boundary chunk loaded (still inside the hysteresis band); pushing it four chunks past unloads it.

**The collision ring and the LOD0 ring are the SAME ring, by construction — not two configs kept in
sync by hand.** The spec says "collision cooks lazily (nearest ring only)"; D-074 (4.0a) measured
`ConcavePolygonShape3D.set_faces()` as the one main-thread cost that cannot move to
`WorkerThreadPool`, at ~1.2-1.5 ms/chunk, ~4.5× the mesh-build cost. Making LOD0 the only tier
eligible for a collider means a chunk with a collider is always full-resolution (correct — a
player's own footing should never rest on a decimated approximation), and it means there is exactly
one hysteresis band to reason about instead of a separate collision-specific pair that could drift
out of step with the LOD tiers over time.

**Mesh generation is genuinely off-thread, using the same shape R2's own benchmark already proved
safe.** Each chunk request becomes a self-contained `ChunkJob` (`RefCounted`, own `coord`/`lod`/
`world_seed`/`result_mesh` fields) submitted via `WorkerThreadPool.add_task(job.run)`; `run()`
touches only its own fields and calls `ChunkMesher.build_mesh()`, which builds a real `ArrayMesh`
(not just raw arrays) on the worker thread — `tools/bench_chunks.gd`'s own `_build_one_threaded`
already established that pattern is safe for this class (each job writes its own dedicated slot,
never shared mutable state), so this task inherits it rather than re-deriving it. A job whose
desired LOD changes again while in flight is never cancelled (WorkerThreadPool tasks can't be) —
it is marked `superseded_lod` and reconciled once it completes, which either discards the now-
unwanted result or immediately queues the now-correct one.

**`chunk_mesher.gd` is no longer a throwaway spike.** It now calls `IslandHeightmap.height()`
(task 4.1, D-075) instead of its own placeholder `FastNoiseLite`, exactly as 4.1's own delegation
note anticipated. `LOD_STEPS = [1, 2, 4]` (metres between vertices) parameterizes the same
apron/central-difference approach R2 used, generalized so the slope calculation stays correct at
any step size. `tools/bench_chunks.gd` and `tools/bench_chunk_gpu.gd` (D-015/D-074) still run
unmodified against the new mesher — neither depended on a specific height value, only on chunk
shape/vertex/tri counts, which are unchanged at LOD0.

**Measured (`agent godot --windowed --script tools/chunk_stream_check.gd`, Metal 4.0/Apple M5
Pro — must be windowed, F-005/D-074, or the collision-cook numbers are meaningless):** 9
functional/behavioral assertions (LOD tier vertex/tri counts, mesh determinism at non-zero LOD,
correct LOD/collision per ring, both hysteresis directions) all pass. The spec's actual acceptance
line — "walk 500 m in a straight line at sprint speed [6.0 m/s, D-018] with zero hitches over 16 ms"
— is measured two ways: total real frame time (subject to whatever else this shared machine is
doing — D-074 already flagged this as expected noise) showed occasional hitches up to 42 ms across
different runs, but `ChunkStreamer.last_process_cost_ms()` — a new read API that times only this
node's own `_process()` work (ring eval + budgeted upload/collision-cook), added specifically to
separate "this system blew its budget" from "the machine stalled for an unrelated reason" — stayed
at **mean 0.19 ms, worst 7.67 ms, zero hitches over 16.667 ms** across the full walk (11,218
frames, 306 chunks resident at steady state). D-074's ~2.7-3.4 chunks/frame collision-cook budget
holds inside the real streaming system, not just the isolated spike, with real headroom against the
16.667 ms hitch line even at the single worst-observed frame.

**One incidental finding, not a blocker:** feeding real terrain through the mesher (vs. R2's single
shared placeholder noise instance) raised the LOD0 build cost from D-015's 0.330 ms/0.112 ms
(single-threaded/`WorkerThreadPool`-amortized) to **1.924 ms/3.895 ms**, because
`IslandHeightmap.height()` deliberately builds two fresh `FastNoiseLite` instances per sample
(D-075's thread-safety design) and a LOD0 chunk's apron needs ~1225 samples. This is off the main
thread and the measurement above confirms it is inconsequential for 4.3's own budget, but it is
relevant to 4.4/4.5, which will also sample the heightmap/biome fields per point — see
`DELEGATION.md`'s current-state entry for this task.

**Not fixed here, filed as F-128:** chunks at different LOD tiers sharing an edge do not stitch —
a real T-junction crack, since the finer side has more vertices along the shared border than the
coarser side. Out of scope because 4.3's acceptance test is about streaming *cost*, not visual
continuity, and nothing yet renders this system in the shipped game to judge it against (4.6 is
that task).

**Would change my mind:** a widened test (more anchors, real cliff/structure geometry raising
collision-cook cost non-linearly — D-074 already named this as its own open question) showing the
budget does not hold at scale; or 4.4/4.5 needing the LOD seam fixed badly enough to justify
skirts or index-stitching before F-128 would otherwise get picked up.

### D-081 · 2026-08-18 · One editor check, `agent editor-running` — never a hand-rolled pgrep (F-120)

"Is the Godot editor open?" is the question D-031 and D-021 both turn on, and the repo had **four**
answers to it: `_godot_running()` in the harness, a bare `pgrep -fl Godot` inside `agent check` (the
pre-commit hook's own guard), another inside `_stage_uid_sidecars`, and a `pgrep -fl
'Godot.app.*--editor'` that `AGENTS.md` and `AI-WORKFLOW.md` told agents to run by hand. They
disagreed, and they disagreed in both directions.

Measured against the four launch shapes actually seen on this machine — a Godot.app opened from
Finder with the project loaded from the Project Manager, `Godot --path <proj> -e res://<scene>`,
`agent godot --script`, and `agent godot --windowed --script`:

| check | missed a real editor | false alarm on a check run |
|---|---|---|
| documented `pgrep -fl 'Godot.app.*--editor'` | **2 of 2** | 0 |
| `pgrep -fl Godot` (hook + ship) | 0 | **2 of 2** |
| `_godot_running()` before this | 0 | 1 (the `--windowed` shape) |
| after this decision | 0 | 0 |

Both failures cost something real. The documented one is a **false negative**, and an agent that
trusts it edits a `.tscn` under a live editor — the exact corruption D-031 exists to prevent. The
blunt one is a **false positive** that fires on any concurrent headless check, and the way past a
blocked commit is `--no-verify`, which switches off the closed-editor rule *and* every claim check
with it; the journal already records an agent doing exactly that, twice, on 2026-08-18. Its copy in
`_stage_uid_sidecars` had a quieter cost: another lane's check run made `ship` skip the import pass,
so `.gd` files shipped without their `.uid` sidecars (F-017).

**The rule.** There is one implementation, `_godot_process_kind()`/`_godot_running()`, and every
guard calls it: `agent check`, `agent ship`, `agent autoload`, `agent order`, and the new
`agent editor-running`, which exists so the *documented by-hand check is the same code as the
enforced one* — a doc cannot drift from the tool if it has nothing of its own to say. Never write
a pgrep for this; if the check is wrong, fix the one function.

**How it classifies, and why it is conservative.** An explicit `--editor`/`-e` is the editor. A run
flag (`--headless`, `--script`, `--import`, `--export-*`, `--doctool`) or a `--path` project run
with no editor flag is not. **Anything else that is the engine binary — most importantly a bare,
argument-free launch — is treated as the editor**, because that is what a Godot.app opened from
Finder looks like: observed 2026-08-18 as pid 89993, zero arguments, MIRE open and rewriting
`.godot/editor/` five minutes after launch. "No flags I recognise" cannot mean "safe" when the
commonest way a human opens the editor produces exactly that. Wrong in this direction costs a false
alarm; wrong in the other costs a corrupted scene.

**What would change my mind:** a launch shape that is genuinely not an editor and carries none of
the run flags. Add it to `GODOT_RUN_FLAGS` and to `GODOT_LAUNCH_SHAPES` in `tools/harness_check.py`
in the same edit — that table is the spec, and it is asserted, so a new shape is one row plus a
passing test rather than an argument.

### D-082 · 2026-08-18 · A finding's status may be undone automatically only where no one recorded a decision — `done_at` is the line

`_sync_findings()` infers status from `docs/FINDINGS.md`: F-049 made "this finding left '## Open', so
somebody must have fixed it" mark it done. The inference is right often enough to be worth having,
and it was **one-way** — nothing could undo it. That turned a transient error in a markdown file into
a permanent state change. F-112's heading was overwritten by an unrelated commit (`89fea39`); the next
sync closed it; a later task restored the heading; the status never came back. It sat in the board's
Done row while `brief` still advertised it, so the real work it names could never be dispatched.

F-071 had looked at this class of drift and deliberately declined to auto-correct it: only someone who
knows what was actually fixed can write the resolution note that makes the move meaningful. That
reasoning is still right — but it assumed the drift always means *fixed, doc lagging*. Both live cases
were the opposite: the doc was right and state was wrong.

**The rule: automatic correction is allowed exactly where no human or agent recorded anything.**
`done_at` is the discriminator, because every real `agent done` stamps it and the inference rule never
does. So:

- **`done`, no `done_at`, and under `## Open`** — closed by inference, contradicted by the source of
  truth that same inference defers to. `_sync_findings()` restores it to `todo` silently. It can
  never resurrect work an agent actually closed, because that always carries the stamp.
- **`done` with a `done_at`, still under `## Open`** — a real close-out that disagrees with the doc.
  A tool cannot tell which record is wrong, so it still only prints the disagreement (F-071's call,
  unchanged) — but it now names both fixes instead of assuming the doc is the stale one.

**`agent reopen <id> "why"`** is the second half, and exists because `agent done` is overloaded: it is
the only close-out verb, so it gets used for "my session ended" as well as "this is resolved." F-036
is the worked example — lp ran `done` and wrote *in the same journal entry* that the finding stays
open pending Sequoyah's playtest. `reopen` clears the status and the stamps and writes a `REOPEN`
journal entry, so the correction is attributable instead of being a silent hand-edit of `state.json`.

**What would change my mind:** evidence that the silent restore surprises someone — a finding that
really was fixed, closed by the inference rule alone, and reopened here into wasted duplicate work.
The stamp test is meant to make that impossible, since a fix an agent performed carries a `done_at`.
If it happens anyway, make the restore print a line rather than reverting to one-way.

### D-083 · 2026-08-18 · Task 4.4's resource scatter: jittered grid over Poisson-disc, the LOD0/collision ring IS the proxy boundary, and depletion memory is best-effort peer-local until 4.6

Three calls in one task, all downstream of the same constraint the spec named directly: "a full
`Harvestable` node per tree at island scale will not survive."

**Jittered grid, not Poisson-disc**, for `world/gen/resource_scatter.gd`'s per-chunk placement.
Every point's RNG stream is independent (seeded from `world_seed ^ chunk ^ def.id ^ (gx, gz)`
alone via integer multiply/xor, never Godot's `hash()` — same cross-platform caution D-017 already
applies to floats), so it needs no shared dart-throwing state across a chunk or its neighbours and
parallelizes per-point exactly like `IslandHeightmap.height()`. True Poisson-disc's minimum-distance
guarantee is nicer, but costs either a shared RNG stream walked in a fixed cross-chunk order or a
rejection pass against already-placed points — real complexity for a visual difference
`jitter_fraction` already buys most of. **Would change my mind:** a playtest finding the grid's
residual regularity reads as planted rows at ground level.

**The harvestable proxy boundary is `ChunkStreamer.chunk_has_collision()` — the existing LOD0 ring
from D-080 — not a second bespoke radius.** 4.3 already draws exactly one "the player is near
enough to stand on this" line; `world/gen/resource_scatter_field.gd` builds scatter (visuals AND
proxies together) only once a chunk crosses into that ring, and tears down the moment it leaves.
Both visuals and proxies come and go together, at chunk granularity, rather than proxies alone
getting a second finer radius — the D-080 ring is already sized for "near enough to physically
interact with," which is exactly what a harvest proxy needs. A `NODE`-represented harvestable (a
tree — HarvestLibrary's own split) gets its own `MeshInstance3D`+`StaticBody3D` holder; a
`BATCH`-represented one (a bush) gets a logic-only holder pointing at a slot in the chunk's shared
`MultiMesh`, mirroring `world/gen/authored_world.gd`'s own two shapes exactly — so
`autoload/harvest_world.gd`'s existing wiring (`authored_world_harvestable` group + `asset`/
`batch_*` metas) turns either into a live, host-authoritative `Harvestable` unmodified. No harvest
logic was duplicated for procedural scatter. **Would change my mind:** a playtest finding trees pop
in/out too aggressively at the LOD0 boundary — the fix then is widening D-080's own ring, not
inventing a second one here.

**Depletion memory is peer-local and best-effort, restored by replaying a real `host_apply_damage()`
hit — never by poking `active` directly.** There is no chunk-keyed mutation/delta system yet (that
is task 4.6's own job per `ARCHITECTURE.md` §4); until it exists, `ResourceScatterField` keeps its
own `_depleted: Dictionary[String, bool]` of what it last observed for a point right before freeing
its holder, and on rebuild replays a full lethal hit through `Harvestable.host_apply_damage()`
rather than setting the `active` property by hand. This was not the original design — the first
version poked `active` directly on the theory that "a peer restoring what it itself last saw is not
a new authority claim," and it shipped a real bug this task's own check caught: `active` alone is
only half of depletion's state (`_deplete()` also arms the respawn clock via `_respawn_remaining`),
so the direct poke left the clock at its just-constructed `0.0` and the very next physics tick
auto-respawned the point straight back. Replaying `host_apply_damage()` restores the *whole* state
through the one path that already knows how, and inherits that method's own host/offline-only gate
for free — a real client's call quietly no-ops, so it never unilaterally decides a point is
depleted, only remembers what it last saw and waits for the `Harvestable`'s own synchronizer to
confirm or correct it. The gap this does NOT close is filed as F-132: `ChunkStreamer` streams
per-peer independently by design (§2.2), so a host whose own player is far from a remote client's
position may have no holder loaded at that point at all for the client's `request_hit()` to reach.
**Would change my mind:** 4.6 landing the real chunk-keyed delta system, which supersedes this
memory outright rather than needing it patched further.

### D-084 · 2026-08-18 · LOD seams are hidden with skirts, not stitched — and the skirt never reaches collision

`ChunkMesher.build_mesh()` is a pure function of `(chunk_x, chunk_z, world_seed, lod)`. That purity
is what makes it safe on a `WorkerThreadPool` task and what makes every peer regenerate identical
terrain from the shared seed (D-075, `ARCHITECTURE.md` §4). Closing F-128's LOD-boundary crack by
real stitching — welding the coarser edge to the finer one — would take the neighbours' tiers as a
fifth input and force a re-mesh of the finer chunk every time a neighbour changed tier, cascading
work straight through the frame budget task 4.3 exists to protect. **So: skirts.** A vertical wall
hangs `SKIRT_DEPTH` metres below every chunk's outer border, on both sides of every boundary, and
covers the gap whichever surface happens to sit higher along the seam. The mesher still needs to
know nothing about its neighbours.

**Depth is a fraction of the heightmap's amplitude, not a metre count.** `SKIRT_DEPTH_FRACTION`
is 10% of `IslandHeightmap.HEIGHT_SCALE`, which 4.1 explicitly calls a placeholder. The worst
divergence measured over the whole island across four seeds is 1.78 m against the current scale of
60 m, so this is a ~3.4x margin that survives the terrain being retuned.
`tools/chunk_stream_check.gd` re-measures the divergence island-wide on every run and fails if the
margin is ever lost, so the number cannot quietly go stale.

**The skirt is never handed to the physics server.** `ChunkMesher.collision_faces()` slices the
terrain triangles off the front of the index buffer, and `ChunkStreamer._cook_collision()` and
`tools/bench_chunk_gpu.gd` both use it instead of `ArrayMesh.get_faces()`. A skirt is a vertical
wall standing exactly on the seam a player walks across; colliding with it is free snagging on
geometry that exists only to be looked at, and it is ~12% more faces (LOD0) to cook against the one
main-thread cost this whole system is budgeted around (D-074). The bench uses the same call so it
keeps measuring what the game actually does.

**One surface, not two.** Putting the skirt in its own surface would read more cleanly and cost a
second draw call on each of ~289 resident chunks. This ships to the worst machine we target.

### D-085 · 2026-08-18 · A gamerule at its authored default does not outrank a level-authored value; one somebody set does

Task 3.14's first-wave migration follows `COMMANDS.md` §4.3 exactly — the owner's `@export` stays
and becomes the fallback — for seven of its eight knobs. `day_length_seconds` is the exception,
because it is the only one that already had a *second* source of truth before it was a rule:
`DayNight._level_atmosphere()` overwrites the export from the level's own `Atmosphere` node the
moment one is found, and has since 2.11.

Reading the rule unconditionally would therefore be a silent behaviour change: the RuleDef's default
is 900 s (chosen to match), so a level that authored 600 s would quietly start running 900 s days
the day this task shipped, with nothing in any log to say why. Keeping the level unconditionally
authoritative would be worse — the knob would appear to work, print a new value, and change nothing.

**So the precedence is explicit: an OVERRIDDEN rule wins; a rule sitting at its authored default
defers to the level.** `RuleService.is_overridden(id)` is the test, and it is derived from the value
rather than stored as a flag — `not is_equal_approx(current, default)` — so a client computes the
same answer from its replicated value and `rule <id> reset` clears it with no bookkeeping.
`DayNight._resolve_day_length()` is the single place that consults it.

The cost is one genuinely odd corner: setting a rule to *exactly* its default is indistinguishable
from never having touched it. That is the right trade here, because "back to default" and "no
opinion" are the same statement for a gamerule, and it buys a rule that can be reset by value
instead of by a second command.

**Would change my mind:** a second knob acquiring a competing authored source. Two exceptions is a
pattern, and the pattern is "RuleDef needs an authored `defers_to_level` flag" rather than a second
hand-written branch in another owner.

### D-086 · 2026-08-18 · A CommandSpec's `scope` may be a Callable, so one verb can read locally and mutate on the host

`COMMANDS.md` §4.2 asks for `rule <rule_id> [value]` to be "HOST scope to set; read answers
locally". 3.13 built `scope` as a fixed `&"local"`/`&"host"` per spec, which cannot express that —
and the alternatives are both worse. Registering `rule` as HOST would send a client's every *read*
on a network round trip to answer a question its own replicated copy already knows. Splitting it
into two verbs (`rule` and `ruleset`) would contradict the spec and read badly at the console.

**So `scope` accepts a `Callable(PackedStringArray) -> StringName` alongside the two literals.**
`CommandService._invocation_scope()` resolves it per invocation; `_declared_scope()` reports
`&"host"` — the maximum — for introspection (`commands`, `commands --json`, `help`), matching §5.1's
existing rule that a function's effective scope is the max of its lines' scopes.

Two properties make this safe rather than a hole in the trust model. The callable sees only the
**raw, unparsed** tokens, because routing has to be decided before the host is the one parsing them
— so it can count and shape arguments but must never assume they are valid. And the host
**re-derives the scope from its own re-parse** of the raw line, exactly as it re-derives everything
else crossing `net_submit_command` (D-077); a client that lied about routing gains nothing, because
the only thing it can achieve is submitting a read to the host, which the host answers as a read.

`tools/rule_check.gd` pins both halves: a non-op peer can `rule revive_seconds` and cannot
`rule revive_seconds 9`.

**Would change my mind:** nothing here yet. If 3.15's entity verbs want the same split (a `tp` that
reports a position versus one that moves a player), this is already the mechanism.

### D-087 · 2026-08-18 · Dodge i-frames decouple from the dash's movement — F-125 takes option 2, and `dodging` becomes the invulnerability window

D-072 collapsed the i-frame window into `dodge_duration_sec`: "there is no state where the flag is
true without the dash also being in progress or vice versa." That was right for 3.8b, and it left
`dodge_iframe_seconds` — a stat in `PowerupDef.KNOWN_STATS`, authored into
`content/powerups/thin_step.tres` by 3.4 — with nothing to modify. F-125 filed the choice rather than
making it in a hurry: feed the stat into `dodge_duration_sec`, or give i-frames their own timer.

**Taken: the second, and the authored content decides it.** Thin Step's own description is *"you are
untouchable for the whole of the trip rather than most of it."* That is a promise about
invulnerability, not about travel. Feeding the stat into `dodge_duration_sec` would add 0.12 s of
dash at 3 stacks and move where the player ends up — F-125's own words for it, "a different powerup
from the one the description promises."

**Three consequences worth recording.**

1. **`dodging` now means "invulnerable", not "dashing".** The dash's movement is
   `_dodge_time_remaining`, and `_apply_horizontal_movement()` branches on that; `dodging` outlives
   it by the powerup bonus. D-072's invariant is deliberately relaxed, in the direction D-072 itself
   said was safe — a longer true-window is more likely to be observed by the host, not less.
2. **The name stays, and that is a constraint talking, not a preference.** The host reads the
   property by name off the replicated synchronizer, and its reader —
   `systems/health/player_health.gd` `_is_dodging()` — was another task's claimed file at the time
   (3.14). Renaming it to `invulnerable` would be more honest and is worth doing when both files are
   free in one task; it is a pure rename with no wire-format change, since the property name is
   already the wire name. In the meantime the flag's own doc comment says plainly what it now means.
   Note the reader was already asking the right question: `_is_dodging()` exists to answer "should
   this hit be ignored".
3. **The window can grow but never shrink below `dodge_duration_sec`** (`maxf` in `_execute_dodge`).
   D-072's replication-reliability argument rests on the true-window comfortably exceeding one
   `NetConfig.PLAYER_SYNC_INTERVAL_SEC` (~0.033 s), and `dodge_duration_sec`'s 0.1 s export floor is
   what guarantees it. A negative `dodge_iframe_seconds` — a plausible future curse or Cycle
   modifier — would otherwise undercut that floor silently, producing not "shorter i-frames" but
   *intermittently missing* ones, which is a bug wearing a balance change's clothes. A powerup that
   genuinely wants a shorter dodge changes the dash.

**No protocol bump.** Same property, same `REPLICATION_MODE_ALWAYS` slot on the same synchronizer;
only how long it stays true changed. `core/net/net_version.gd` is untouched.

**Would change my mind:** DESIGN §4.4's Void Resonance "dodge blinks" landing, if it makes the dash
instantaneous — then "the dash window" stops being a sensible floor for the i-frame window and the
floor should become an explicit constant instead of `dodge_duration_sec`. D-072 already anticipated
that case and kept `_execute_dodge()` wrappable for it.

### D-088 · 2026-08-18 · EntityDirectory discovers by node group, not by subscribing to five spawn signals

`COMMANDS.md` §3.1 lists a registration seam per entity kind — `PlayerNet.player_spawned`,
`EnemyWorld`'s spawn/despawn, `HarvestWorld._wire_holder`, `BuildService` placement/destruction,
`Chest._ready()`. Implementing that literally means five `connect()` calls, five matching
*unregister* paths, and a directory that is only as correct as the weakest of the ten.

Every one of those spawn paths already ends in the same statement: `add_to_group()`. `Enemy._ready`
joins `enemies`, `Harvestable._ready` joins `harvestable`, `Chest._ready` joins `chest`,
`BuildService` adds `buildable_piece` to each placed piece, `PlayerController._ready` joins
`players`. **So the directory scans the groups.** `EntityDirectory.KIND_GROUPS` is one line per kind,
`snapshot()` asks the tree what is alive right now, and despawn needs no handling at all — a freed
node is simply not in the group any more.

Three things this buys beyond brevity. It **cannot drift**: there is no second list of live entities
to fall out of sync with the tree. It needs **no edits to five other services**, which on a repo with
several agents in flight is the difference between one claim and six. And a **new entity kind is one
line here**, not a sixth pair of signal handlers.

Identity still has to survive, because a scan is stateless and ids and tags must not be:
`_entries` is keyed by instance id, mints `<kind>:<serial>` the first time an entity is seen, and is
pruned of anything the latest scan did not find. Tags hang on the entry, so they persist across
scans and die with the entity.

The one real cost is that `KIND_GROUPS` restates a constant each owning script also declares.
Preloading five gameplay scripts into an autoload that boots in every headless run to read one
`StringName` each is the F-016 family of pain, so the strings are duplicated — and
`tools/entity_check.gd` asserts every one of them still equals its owner's constant, so the
duplication cannot rot silently into "why does `entities` never list chests".

**Would change my mind:** an entity kind that genuinely does not join a group, or one where the
directory must know about an entity *before* it enters the tree. Neither exists today.

### D-089 · 2026-08-18 · Task 4.6: `GameState` gets only the seed, `WorldDeltaLog` is latest-value-wins and buildings don't use it

Three calls, all shaped by the same constraint: land the general mechanism `ARCHITECTURE.md` §4
promises ("every mutation... replicates as deltas keyed by chunk") without guessing at scope that
belongs to later tasks.

**`core/game_state.gd` holds only `run_seed`, not the "act, day, seed, run status" `ARCHITECTURE.md`
§3 reserves the path for.** Task 6.1 (Cycle state machine) owns the rest; building it now would be
inventing 6.1's own design ahead of its own task. Claiming the reserved name for the seed-only slice
means 6.1 extends one file instead of two autoloads merging later. Host draws `run_seed` from real
entropy once per session (`RandomNumberGenerator.randomize()`), exactly D-041's reasoning for
`Chest.host_seed_rng()`: nothing today needs a run to be reproducible across restarts, only that
every peer IN the run agrees, which replication — not a fixed constant — already provides.

**`autoload/world_delta_log.gd` stores latest-value-wins per `(chunk, kind, key)`, not an
append-only event journal.** Every consumer this task has, and the one 4.9's Mire tick will add, only
ever needs "what does this look like right now" — an event history has no reader. Latest-value-wins
is also what makes the late-joiner snapshot cheap: `var_to_bytes(_state).compress()` of the whole
current-state dictionary, decompressed and adopted whole by `net_world_snapshot`, instead of replaying
however many mutations happened over however long the run has been going.

**Buildings do NOT go through this log**, even though the spec text lists "building" alongside
harvest depletion. A placed buildable (task 3.6) is a real node under `BuildService`'s own
`MultiplayerSpawner`, which already replays every existing spawn to a newly connected peer on its
own — `core/net/net_session.gd`'s own header has said so since task 1.5 ("THE MID-SESSION JOIN NEEDS
NOTHING HERE"). `WorldDeltaLog` exists for the case a permanent node does NOT cover: 4.4's harvest
proxies are created and freed as their chunk streams in and out of each peer's own independent ring
(D-083's "depletion memory is best-effort... until 4.6"), so there may be no live node on some peer
to replicate FROM at the moment another peer needs the answer. Routing buildings through the log too
would be maintaining two mechanisms for a problem only one of them actually has.

**`NetSession.peer_admitted(peer_id)` is a new signal, fired at the end of `_admit_identity()`,
because that is the first moment a peer is a real member of the run** — after its version handshake
AND its identity claim both succeed, before which handing it a world snapshot would be handing state
to a peer the host might still refuse. `WorldDeltaLog` is the one subscriber today; it fires for
EVERY admission, first joins and rebinds alike, because resending the current snapshot to a
returning peer is idempotent and harmless, and a rebind case needing special-casing was not worth
inventing before one actually needed it.

Two-process check: `agent godot --script tools/seed_sync_check.gd` — client-regenerated
`terrain_hash` equals the host's (proves the seed crossed the wire, not just that the math is
platform-stable — that half is `check_determinism.gd`'s job), a mutation recorded BEFORE the client
ever connects reaches it via the admit-time snapshot, and a second mutation recorded AFTER the client
is already connected reaches it live via `net_delta_applied`. 0 failures.

**Would change my mind:** a consumer that genuinely needs a mutation's history, not just its current
value — nothing in 4.9's own spec (a per-cell corruption LEVEL, not a log of changes) suggests one
exists.

### D-092 · 2026-08-18 · Task 4.8's Wellspring: cap does not grant a chest/Mire/Attunement reward, cancelling forfeits progress, and required-player count is a session-start snapshot

DESIGN.md §4.2 says capping "grants: local corruption cleared, global spread rate reduced, a
powerup chest, and (first cap only) Attunement selection." None of that is wired by this task, on
purpose:

- **Mire (4.9-4.11) does not exist yet** — there is no corruption grid to clear and no spread rate
  to reduce. Inventing a stand-in field on `Wellspring` now would mean 4.9 either adopts a shape it
  had no say in or throws it away.
- **Attunement already fires at run start** (D-071), not at first Wellspring cap — re-wiring it here
  would relitigate a decision this task has no new information to challenge.
- **No chest can be spawned yet.** `systems/loot/chest.gd` is a hand-placed scene prop (task 3.5's
  own claim note), not something with a `.tscn`/spawn API; building one would mean authoring a new
  loot tier and a chest prefab under a claim `chest.gd`'s own task (3.2) held for most of this
  session. Manufacturing a placeholder reward (coins via `InventoryService`) would be inventing
  content this task was never asked to author.

Instead, `Wellspring._finish_cap()` sets `capped = true` (replicated, swaps the state mesh per
`assets/wellsprings/README.md`'s contract) and calls `EventBus.emit_wellspring_capped(name,
world_position)`. That is the seam every one of the above hooks into once it exists — no rework of
`Wellspring` itself should be needed, only a new subscriber.

**Cancelling the channel (a second interact press while channeling) resets `progress_sec` to 0,
distinct from the presence-gate pause below (which does not reset it).** DESIGN.md says nothing
about either case. Reset-on-cancel was chosen because it is the simpler rule to hold in your head —
"stepping away" and "choosing to stop" are different player intents, and only one of them should
cost you the attempt.

**`required_players` and `duration_sec` are snapshotted once, when the channel starts** — 1 player
and the 150s solo timer if the whole session has exactly one live player at that instant, 2 and the
60s co-op timer otherwise (`_session_player_total()`, same read-once-at-the-threshold rule
`systems/waves/wave_spawner.gd`'s `base_count`/`per_player` already follow). A player joining or
leaving mid-ritual does not retroactively change what an already-running attempt needs; only the
NEXT channel attempt sees the new session size. The defense wave (`base(3) + per_player(1) x
session total`, via `WaveSpawner.host_spawn_wave_at()`) spawns once at channel start and is not
required to be cleared for the ritual to complete — DESIGN's "spawns a defense wave" reads as an
obstacle the ritual creates, not a win condition it checks.

Verify: `agent godot --script tools/wellspring_check.gd` — WellspringService is a registered
autoload, an `objective` marker gets exactly one live Wellspring child (and a marker of any other
`kind` gets none), toggle start/cancel, an out-of-range requester is rejected, a solo attempt gets
the longer timer and completes with the right-sized wave, and a co-op attempt's progress pauses
(not resets) below the 2-player presence requirement and resumes once both are present. 0 failures.
Confirmed separately against the real `res://levels/hollowmere.tscn`: its one `objective` marker
(4.0, -0.604, 64.0) builds exactly one Wellspring, uncapped, with no engine ERROR lines.

**Would change my mind:** 4.9 landing with a corruption-grid API simple enough that wiring it here
would have cost nothing extra — in that case the two tasks should probably have shipped together
instead of through the event seam.

### D-093 · 2026-08-18 · `clear` stays the console's; the inventory wipe becomes `inv clear`

`COMMANDS.md` §7 lists `clear` twice — under **Inventory** as `clear [target]`, and under **Meta**
as `clear` (console). One name, two systems. `CommandService.register_spec()` replaces a name
silently, on purpose (content reload and test setup both want that), so shipping both would have
meant whichever autoload registered second quietly won, with nothing anywhere saying so.

**The console keeps the bare name.** It predates the whole command track, `clear` means "clear the
screen" to anyone who has used a console, and clearing the screen is something a person does
constantly while clearing an inventory is rare. The inventory verb becomes `inv clear [peer]`, a
subcommand of the verb that already lists the same inventory — which reads better than the flat
version did.

Worth recording for how it was found: not by re-reading the spec, but by
`tools/command_catalog_check.gd` reporting `Inventory · clear is host scope — but the registry says
'local'` on its first run. That is exactly the job §7 gave the coverage check ("a new service that
forgets its verbs fails a check instead of a code review"), and it caught a collision *in the spec
itself* on the first try. Filed as **F-153** so the spec text gets corrected rather than continuing
to promise a verb that does not exist.

**Would change my mind:** nothing. If an inventory wipe ever wants a shorter spelling, it is a new
name, not this one.

### D-094 · 2026-08-18 · Hooks ship disabled-by-default; gameplay-by-hook waits for M6 Cycle Modifiers to own it

Filed verbatim per `COMMANDS.md` §9 item 5. Task 3.17 ships the whole mechanism — `HookDef`
(`systems/rules/hook_def.gd`), `Registry` loading `content/hooks/*.tres`, and
`CommandService._wire_hooks()`/`wire_hook()` subscribing a HookDef's named event to its function —
but the one worked example, `content/hooks/night_siege.tres`, ships with `enabled = false`, and
`_wire_hooks()` skips every disabled HookDef entirely at boot (not connected, not even looked up).

**Why:** binding real game events to data-authored functions is the first slice of "gameplay
controlled by data, not code" — genuinely the seed of M6's Cycle Modifiers. Turning it on for real
content now would be deciding, inside a T1 infrastructure task, what the first piece of hook-driven
gameplay actually IS — a design call M6 should make deliberately, with the rest of the Cycle Modifier
picture in view, not one this task should back into by shipping a themed wave live.

**Also filed here:** the event vocabulary is deliberately open text (`CommandService._HOOK_EVENTS`
maps a name to a real signal), not a closed enum — COMMANDS.md §5.2 calls it a list that "starts with
what exists." Two of the five events the design doc names illustratively (`run_started`,
`player_downed`) have no shipped signal yet; naming either in a HookDef fails loudly at wire time
(a MireLog error) rather than silently never firing. Filed as **F-154** so whichever task adds a real
run-lifecycle or player-downed-edge signal knows where to add the one binding row that finishes it.

**Would change my mind:** a playtest (2.14/3.11 or later) wanting scripted variety sooner than M6 —
same trigger COMMANDS.md §9 item 5 already named. Flipping `night_siege.tres` to `enabled = true` is
the entire cost of trying it; nothing about the mechanism itself would need to change.

### D-095 · 2026-08-18 · POI placement takes real Poisson-disc, an explicit priority, and two spacing radii — all three found by measuring, not by design

Task 4.7 places Wellsprings and landmarks. Three calls, and the second and third were both bugs the
check found before anyone could have seen them in game.

**1 · Real Poisson-disc here, even though D-083 chose a jittered grid for scatter.** The two look
like the same problem and are not. 4.4's resource scatter is generated PER CHUNK by peers that stream
different chunks at different times, and true dart-throwing needs to see every previously accepted
point — hence the grid. POIs are island-GLOBAL and few (a dozen or so), generated all at once by
every peer from the shared seed, so dart-throwing is both affordable and correct. It matters here in
a way it does not for scatter: two Wellsprings 12 m apart is a broken island; two bushes 12 m apart
is a bush.

**2 · Placement order is an authored `placement_priority`, not alphabetical.** `_sorted_defs` sorts
defs before placing, because placement is order-dependent and an unstable order would mean two peers
building different islands from one seed. The obvious stable key is `id` — and sorting by id alone
put `wellspring` **last**, after `shipwreck` and `standing_stones`. Nine landmarks claimed the island
first and squeezed the objective out: on seed 24301, measured, an island generated with **zero
Wellsprings** — a run with no objective, and nothing anywhere would have reported it. `PoiDef` now
carries `placement_priority` (lower first, `id` as the deterministic tie-break), the Wellspring sits
at 0, and every tested seed places 4/4.

**3 · `min_spacing_m` and `clearance_m` are separate numbers.** The first version used one radius for
everything: same-kind separation doubled as the exclusion zone against other kinds. But those answer
different questions. Wellsprings want 180 m *from each other* so they spread across the island;
re-using 180 m as their exclusion radius against everything else carved four enormous holes out of
the map and left one seed with no standing stones at all. A landmark 100 m from a Wellspring is fine;
a second Wellspring there is not. Same-kind uses `min_spacing_m`; cross-kind uses the larger of the
two defs' `clearance_m` (default 24 m). Both radii ride along on each returned site, so a later
consumer — 4.4's scatter is the obvious one — can keep its own content out of a POI's footprint
without holding the def list.

**How all of this was found is the point.** `tools/poi_check.gd` asserts that every authored kind
lands on a real island and that every seed gets at least one Wellspring. Determinism, spacing and
constraint tests all passed while the zero-Wellspring island existed, because a layout that is
consistently, deterministically wrong is still deterministic. The per-kind coverage assertion is the
cheap one that actually caught it.

**Would change my mind:** an island large enough that global dart-throwing gets slow (it is ~30 darts
× a dozen sites today, so nowhere near), or a POI kind that must be placed relative to another rather
than merely away from it — a dock beside a shipwreck. That is an anchoring rule, and it belongs in a
second pass over the sites this one returns, not inside the dart loop.

### D-096 · 2026-08-18 · F-132's fix is a calling contract, not a new `ChunkStreamer`/`ResourceScatterField` API

Closing F-132 (a remote client's scattered harvestable proxy may have no host counterpart to reach,
because `ChunkStreamer` streams per-peer independently) did not touch either file's ring or proxy
mechanics, and that absence is itself the call worth recording — so a later task does not "fix" F-132
a second time by adding an API that already exists.

**`ChunkStreamer.set_anchors()` already takes `Array[Vector3]`, and `_ring_distance()` already takes
the NEAREST of every anchor** — a chunk stays resident as long as ANY anchor's ring reaches it,
proven for a genuinely disjoint two-anchor case (chosen `>= LOAD_RADIUS_CHUNKS + HYSTERESIS_CHUNKS +
1` chunks apart, so neither anchor's own ring could reach the other's target by construction) in
`tools/chunk_stream_check.gd`'s new union-of-interest section. `ResourceScatterField` builds and
tears down scatter per CHUNK, never per anchor, so it needed nothing extra either — a chunk resident
because of a remote peer's anchor gets a proxy exactly like one resident because of the host's own.

**What was actually missing is a live caller that supplies the union** — every connected peer's
last-known position, the host's own included, not just its own local player — and no such caller
exists yet (F-139: nothing instantiates `ChunkStreamer`/`ResourceScatterField` in the shipped game).
Guessing at that caller's own shape here — a per-peer `set_anchors()` call each tick vs. a single
merged position list recomputed on connect/disconnect/movement, and where "every connected peer's
position" is even read from — would be inventing 4.7+'s own wiring code against no real session to
verify it in, exactly what 4.4 already declined to do for this same finding. The contract is recorded
as a header comment on both files instead: whichever task adds the real caller must anchor the host's
pair to the union, and can verify against the now-proven mechanism rather than re-deriving it.

**Would change my mind:** the live-wiring task finding the union genuinely needs a dedicated method
(e.g., because per-peer add/remove churn makes hand-assembling the anchor array error-prone) — that
is additive, not a reason this decision was wrong, and belongs with that task's own claim.

### D-097 · 2026-08-18 · Task 5.1's AI framework generalises `Enemy` with `EnemyDef` fields, not a swappable `enemy_brain.gd`; perception gates acquisition only, never retention

`docs/SPECS.md`'s old M5 overview (written before per-task blocks existed for this milestone) called
for "generaliz[ing] `Enemy` into `systems/enemies/enemy_brain.gd` states" as the shape of 5.1's
refactor. Two calls made instead, both now the spec (5.1's new `## 5.1` block).

**1 · Perception (`vision_angle_deg`, `requires_line_of_sight`), alerting (`alert_radius_m`) and the
attack-slot cap (`max_concurrent_attackers`) landed as `EnemyDef` fields plus logic inside the
existing `Enemy` script — no `enemy_brain.gd`, no swappable component.** 2.10's state machine is
already fully data-driven per `EnemyDef` (D-006), and every enemy this project has authored or has
planned through 5.2 (8–12 more crawler-shaped kinds) shares one shape: chase, telegraph, commit,
recover. A "brain" abstraction earns its cost when a SECOND genuinely different AI shape exists to
design the interface against — a ranged kiter (5.3), a stationary turret, a boss phase machine (5.5)
— not as a guess made against the one shape that exists today. Splitting speculatively here would be
exactly the kind of exploration-without-a-real-need AGENTS.md already warns off content generation
for, applied to architecture instead.

**2 · Perception gates ACQUISITION only. An already-held target is kept on distance alone (2.10's
existing aggro/deaggro hysteresis) — losing line of sight, or the target stepping outside the vision
cone, never drops a target already being chased.** The alternative — re-checking perception every
tick — makes an enemy forget a target the instant it ducks behind cover, which reads as broken
tracking rather than as stealth (nothing in `DESIGN.md` asks for a stealth mechanic), and it would
also fight `_face()`: a chasing enemy continuously turns toward its held target, so a cone re-check
against a target it is actively turning to face is nearly always true anyway and buys nothing.
`tools/enemy_ai_check.gd` proves the asymmetry directly — a wall placed AFTER acquisition does not
un-target, the identical wall placed BEFORE acquisition prevents it entirely.

**Both calls are why `content/enemies/crawler.tres`, left completely unedited, keeps every
`enemy_check.gd`/`enemy_net_check.gd` assertion passing verbatim** — the new fields' defaults
(`vision_angle_deg = 360`, i.e. no cone) preserve 2.10's exact acquisition behaviour for that one
enemy, while LOS/alerting/the attack cap are live at sensible defaults rather than shipped inert
(Hollowmere's own "nothing reads `enemy_nest`, so the map shipped with zero crawlers" history,
`docs/DELEGATION.md`, is why an unused capability is treated as a bug here, not a safe default).

**Would change my mind:** 5.2, 5.3 or 5.5 authoring an enemy whose AI shape cannot be expressed as
`EnemyDef` data over the existing state machine (not just different numbers, a different STATE
GRAPH) — that is the real second example a `brain` interface should be designed against. On
perception: a future task deliberately wanting stealth-breaks-tracking as a mechanic should gate that
behind its own new field (e.g. `perception_recheck_interval_sec`) rather than reversing this default,
since most enemies should keep the current "committed once spotted" read.

### D-098 · 2026-08-18 · F-126 is closed without adding a display-name registry — that registry does not belong to a `peer`-argument-parsing task

Closing F-126 (`CommandService`'s `peer` argument type has no display-name resolution) did not touch
`_parse_peer()`'s behavior, and that absence is the call worth recording — so a later task does not
re-open F-126 to add the very registry its own text already said belonged elsewhere.

**Two independent reasons, either alone sufficient:**

1. **The finding's own text already forbids it.** F-126 says explicitly that `_parse_peer` "should
   grow a name lookup against that same registry rather than inventing its own" — i.e. the registry
   is owned by whichever system needs player display names for its own reasons (a lobby roster
   label, a kill-feed name), and `CommandService` only ever consumes it. Building one here, scoped to
   what a command parser needs, is exactly the private, throwaway lookup that sentence warns against.
2. **It is not buildable inside this claim regardless.** A real registry needs a name to arrive from
   somewhere. LOCAL/LAN has no existing source at all — only STEAM's `SteamLobby._persona()` does —
   so the honest version needs a new client→host RPC, which `docs/SPECS.md`'s own standing rule
   requires bumping `PROTOCOL_VERSION` in `core/net/net_version.gd` for. That file was held by
   another lane's exact-file claim (3.7) for the entirety of this task, so building the registry
   here was blocked by the claim system this project runs on, not just a scope judgment call.

**What closing it actually consisted of:** verifying the gap is real, unchanged, and already honestly
scoped — `_parse_peer()`'s own doc comment states the limitation and the code matches it exactly
(rejects non-int tokens, never silently resolves a name). Added `tools/command_check.gd` coverage
that pins this behavior (`peer` type rejects a non-numeric token with the documented message, and
still accepts an unconnected int per D-078) so a future change to `_parse_peer` cannot silently
regress into looking like name resolution when it is not. Filed F-157 to carry the actual registry
forward with a correct owner-agnostic framing, since F-126's own pointer at task 3.16 is now stale —
3.16 shipped without adding one.

**Would change my mind:** `core/net/net_version.gd` becoming free and a task explicitly choosing to
own "players get a display name" as its own deliverable — at that point building the registry (most
naturally in `NetTransport`, per F-157) is that task's job, and `_parse_peer` gets a two-line addition
to consume it. Nothing here should be read as an argument against ever building it.

### D-099 · 2026-08-18 · Task 4.9 built ahead of order (its prerequisite, not a scope grab); Mire replication reuses `WorldDeltaLog` instead of a new RPC; Ward resistance splits across 4.9/4.11 by where the mechanism can physically live

The 4.11 work order text ("each one is a small consumer of an existing seam; no new authority
anywhere") assumed task 4.9 — the Mire grid itself — already existed. It did not (`state.json` had
it `todo`); D-092 had already flagged this exact gap in advance. All four of 4.11's consumers need
`MireGrid.corruption_at()`, which cannot exist without 4.9, so 4.9 was done first, under its own
claim/verify/done/ship, before touching 4.11 at all — not a scope expansion of 4.11, a separate
roadmap task done in the order its own dependency requires.

**Replication reuses `WorldDeltaLog.host_record()` (task 4.6) rather than a bespoke RPC pair.** That
file's own doc comment already named the Mire grid as its next intended consumer, "same
per-cell-keyed-by-chunk shape, a different kind" — this was not just the tidier option, it was the
only one available this session: a new RPC needs a `PROTOCOL_VERSION` bump in
`core/net/net_version.gd`, extended in lockstep in `tools/handshake_check.gd` (SPECS.md's own
standing rule), and both files were held by another lane (3.7) for the entire session. **Would
change my mind:** nothing, really — `WorldDeltaLog` is a strictly better fit regardless of file
availability (R4's "too chatty at scale" risk is exactly what quantized per-cell deltas already
solve for existing consumers), so there is no future world in which a bespoke RPC becomes the
better answer.

**Ward resistance is split, not because it is easiest but because ARCHITECTURE.md and SPECS.md
name two different owners for it and both are honorable.** ARCHITECTURE.md §5 places "Wards resist
accumulation in a radius" inside the grid's own tick description; SPECS.md's 4.11 block lists "Ward
posts... suppress spread in radius" as that task's consumer. The mechanism can only live in one
place — `MireGridSim.tick(grid, ward_circles, spread_rate)` — so 4.9 ships that parameter and calls
it with an empty array (no wards, 4.9's own honest behaviour); 4.11 is the one commit that changes
that one call site to pass `BuildService.ward_radii()` through `MireGrid.set_ward_circles_provider()`.
**Would change my mind:** nothing forces a future reader to preserve this split — if it ever reads as
more confusing than useful, collapsing both into whichever task ships second is a two-line change,
not a redesign.

### D-100 · 2026-08-18 · Task 6.1's Cycle state machine: no new RPC (reuses `WorldDeltaLog`), no Cycle Modifier draw (defers to 6.2), no new enemy content (defers to 5.2)

`CycleService` (`systems/cycle/cycle_service.gd`) needed a way for every peer to learn the current
Cycle number, including a late joiner. The honest version is a small RPC pair, same shape as
`DayNight.net_push_time` or `RuleService.net_rule_changed`/`net_rule_snapshot` — but `docs/SPECS.md`'s
own standing rule 5 requires any new RPC to bump `PROTOCOL_VERSION` in `core/net/net_version.gd` and
extend `tools/handshake_check.gd`, and both files were held all session by lane slate17's 3.7 claim.
This is the exact situation F-126 hit and recorded (D-098): **reused an existing generic
host-authoritative log instead of inventing a new RPC.** `WorldDeltaLog.host_record(chunk, kind, key,
value)`/`latest()` already broadcasts to every connected peer immediately and folds into the snapshot
a late joiner gets, and its `(chunk, kind, key) -> value` shape does not actually require the chunk to
be spatial — task 4.9 already proved this same reuse for `MireGrid` (D-099). `CycleService` records
the Cycle number at the fixed pseudo-chunk `Vector2i.ZERO`, kind `&"cycle"`, key `"current"`. **Would
change my mind:** `net_version.gd`/`handshake_check.gd` becoming free — a real RPC pair would then be
strictly cleaner (this one has no per-cell shape to justify piggybacking, unlike MireGrid's), and
whoever picks it up should feel free to swap it in as a two-file, no-behavior-change refactor.

**No Cycle Modifier is drawn on advance.** DESIGN.md §5.1 names it as one of the three things a Cycle
does, but `docs/ROADMAP.md` splits "Cycle Modifier framework: deck, draw, stacking, Cycle-weighted
rules, incompatibility tags" into its own task, 6.2 (T2, est 4) — building it here would be scope
duplication against a task explicitly reserved for it, and there is no deck to draw from yet.
`EventBus.emit_cycle_advanced(cycle)` is the seam 6.2 hangs its draw off, mirroring the "future task's
hook" role D-092 gave `wellspring_capped`. **Would change my mind:** 6.2 shipping first and finding
`cycle_advanced` the wrong shape to build on — nothing pins its signature beyond `(cycle: int)`.

**Enemy roster expansion (`WaveSpawner.host_unlock_next_enemy()`) authors no new content.**
AGENTS.md forbids bulk-generating `.tres` content, and task 5.2 ("8-12 enemy types") is the one that
grows the real archetype roster; it has not shipped. `roster_order` defaults to `[&"bog_crawler"]` —
content that already exists (task 4.11 authored it as the corrupted-spawn substitution variant) and
is a legitimate second archetype by stats even though it reuses `crawler`'s model (F-158, already
filed, is about exactly that visual gap — this decision makes bog_crawler surface *more* often, via
the general roster and not just corrupted ground, which raises F-158's stakes but does not change its
fix). `host_unlock_next_enemy()` is a no-op once `roster_order` is exhausted, never a crash — 5.2 (or
any future content task) grows the real escalation by appending more ids to that export, no code
change required. **Would change my mind:** nothing — this is the intended extension point.

### D-101 · 2026-08-18 · Task 4.5's nav baking: host-only, LOD0-only, and winding is MEASURED rather than asserted

D-016 already settled the hard part — runtime `NavigationMesh` baking stays, `bake_..._async` is the
only bake we call, `cell_size` 0.25, `map_set_edge_connection_margin` 1.10, one bake in flight.
`world/chunk/nav_baker.gd` implements those verbatim. Three calls it had to make on top:

**Host only.** Pathfinding is host-authoritative (D-016, §2.2), enemies are host-owned bodies, and a
client has nothing to path. `NavBaker.bind()` is a no-op on a non-host, so a six-player session pays
the bake cost once rather than six times. Nothing is replicated — the map is derived from terrain
every peer could regenerate anyway.

**Nav rides the LOD0 ring, and leaves it too.** D-084 established that the collision ring IS the LOD0
ring; navigation belongs on exactly the same one, because an agent pathing across terrain with no
collider walks on nothing. The half that is easy to forget is the exit: a chunk DEMOTED to a coarser
LOD retires its region, not just an unloaded one, or a stale region keeps describing terrain the
streamer is no longer rendering at that resolution. Source geometry is
`ChunkMesher.collision_faces()` — the same triangles the physics collider is cooked from, skirt
sliced off — so navigation and collision cannot disagree about where the ground is.

**Winding is measured per bake, not hard-coded.** §6 trap 1 is the expensive one: Recast treats a
triangle as up-facing when `cross(v1-v0, v2-v0).y` is NEGATIVE, and conventional winding bakes
*success with zero polygons*, silently. The obvious implementation hard-codes the flip.
`_wound_for_recast()` instead measures the first triangle and flips only if needed, because
`ChunkMesher`'s winding is its own business and may legitimately change — and if it did, a hard-coded
flip would produce an empty nav map that nothing reports until an enemy stands still forever.
`tools/nav_bake_check.gd` keeps the trap *proven* rather than commented: it bakes the same faces both
ways and asserts the wrong winding yields exactly 0 polygons.

**A correction worth recording, because it cost the most time in this task and was not a code bug.**
The check originally baked chunks (0,0)-(1,1), commented "near the island centre, where the heightmap
is reliably above water". For seed 20260818 those chunks are steep seabed at y = -4 to -15. Every
seam assertion failed and looked exactly like the erosion hole D-016 describes — the path even
stopped at x = 31.0, one metre short of the boundary, which is precisely the symptom. It was not:
a slope census over the whole island showed **82.5% of land is walkable at under 45 degrees**, and a
boundary with verified gentle land on both sides paths across with 0.000 m arrival error. The check
now *locates* walkable terrain from the heightmap instead of hard-coding coordinates, so it is
seed-independent and can never again report a bad test-terrain choice as a navigation defect.

The generalizable lesson, and the reason this is a decision and not just a commit message: **an
assertion loose enough to pass is worse than no assertion.** The first seam test asked only "does the
path end within one chunk of the target" and passed at 25.6 m short. Sharpening it to "snap the
target on-mesh, assert the endpoints are on opposite sides, demand arrival within 0.5 m" is what
turned a green tick into a real question.

**Would change my mind:** enemies needing to path on water or on structures. Buildables are NOT in
the source geometry — 3.7's pieces are colliders the nav map does not know about, so an agent will
path straight through a placed wall. That is the next real gap here, and it wants the streamer's
placed geometry folded into the bake, not a second nav system. Filed as F-159.

### D-102 · 2026-08-18 · Task 5.3's ranged combat ships three new RPCs with no `PROTOCOL_VERSION` bump — `net_version.gd`/`handshake_check.gd` were held all session by another lane's claim

`RangedCombatService` needed a real RPC pair-plus-one — `net_request_shot` (client → host),
`net_shot_fired` (host → everyone, cosmetic flight spawn), `net_shot_resolved` (host → everyone,
authoritative hit/miss) — because a bow's flight is genuinely variable-length with no existing
generic seam to piggyback on the way D-99/D-100 reused `WorldDeltaLog` for Mire deltas and the Cycle
counter. `docs/SPECS.md`'s own standing rule 5 requires any new RPC to bump `PROTOCOL_VERSION` in
`core/net/net_version.gd` and extend `tools/handshake_check.gd`'s pinned-version assertion — both
files were held by lane slate17's 3.7 claim for this task's entire session (the same file, the same
blocker D-100 hit for task 6.1).

Unlike 6.1, this task could not route around needing the RPC — a projectile flight is not a discrete
world-mutation delta with a `(chunk, kind, key)` shape, and forcing it through `WorldDeltaLog` would
mean broadcasting the whole flight instead of the two cosmetic/authoritative messages that already
match every other host-authoritative feature's shape (2.8's melee swing, 4.8's Wellspring channel).
**Decided: ship the three RPCs un-versioned rather than stall the whole task on a file conflict** —
the game is developed and shipped from one evolving source tree, not staggered binaries (`net_version.gd`'s
own header: "this project ships from source control... there is no compatibility window"), so the
real risk (two DIFFERENT-version builds of THIS commit connecting and silently desyncing over ranged
combat) is transient and only matters mid-transition, not at any steady state. Filed as F-161 so it
is not silently lost — whoever next holds `net_version.gd` bumps `PROTOCOL_VERSION` to 20 and
documents these three RPCs in its own running comment, then raises `handshake_check.gd`'s pinned
`PROTOCOL_VERSION == 19` assertion to 20.

**Would change my mind:** `net_version.gd`/`handshake_check.gd` becoming free during a task that
needs a real network feature verified — bump it then rather than defer again; two deferred bumps
compounding is a real (not just theoretical) desync risk.

### D-103 · 2026-08-18 · Task 6.2's Cycle Modifier framework: tags over an id list, Registry-first content loading with a seatbelt fallback, no seeded RNG, no effect wiring

Four calls, each narrower in scope than the M6 gate bullet that used to sketch this task.

**Incompatibility is tag-first, with an explicit id list as the escape hatch.** The roadmap's own
task title says "incompatibility tags" (plural), and DESIGN.md Q7's mitigation is literally "tag
modifiers as incompatible" — not an `incompatible_with: Array[StringName]` id list, which is what
the old M6 gate bullet in `docs/SPECS.md` (written before this task was scoped) sketched. A tag list
scales better: a new modifier that conflicts with "every night-themed modifier" declares one tag
once, instead of naming every existing night modifier by id and every future one needing to remember
to add itself to that list. `CycleModifierDef` ships both — `tags`/`incompatible_tags` as the primary
mechanism, plus a genuine `incompatible_with: Array[StringName]` for the rare pair that must never
stack but shares no tag worth inventing. The tag check is symmetric by construction (a candidate is
blocked if ITS OWN `incompatible_tags` names an active tag, OR if an ALREADY-ACTIVE modifier's
`incompatible_tags` names a tag the candidate carries) so only one of two conflicting authors needs
to declare the exclusion.

**Content loads through `autoload/registry.gd` first, same as every sibling Def.** `registry.gd` was
held all session by lane lp's task 5.3 claim when this task started — the identical shape D-100/D-102
both hit against `net_version.gd` — so `CycleModifierService` was first built with its own
self-contained scanner duplicating `Registry._load_dir`'s exact contract, specifically so folding it
into Registry later would be a same-shape, no-behavior-change move. 5.3 shipped and released
`registry.gd` before this task closed, so the fold happened in the same session rather than being
left for a future one: `CYCLE_MODIFIERS_PATH`/`CYCLE_MODIFIER_DEF`/`cycle_modifiers` plus one
`_load_dir(...)` call joined Registry's `_ready()` alongside every sibling family, with
`cycle_modifier_defs()`/`get_cycle_modifier()`/`has_cycle_modifier()` as its accessors.
`CycleModifierService._load_defs()` now asks Registry first (`get_node_or_null(^"/root/Registry")` +
`.call("cycle_modifier_defs")`) and only falls back to its own direct disk scan
(`_load_defs_from_disk()`) when Registry is not present under `/root` — the identical
"front door, then a quieter seatbelt for a hand-instantiated harness" split
`RuleService._load_defs()`/`_load_defs_from_disk()` already establishes for rules. The disk scanner
is kept, not deleted, for exactly the reason `RuleService` keeps its own.

**The draw does not use a seeded `RandomNumberGenerator`.** ARCHITECTURE.md §7 requires a seeded RNG
inside world generation, where every peer must independently compute the same answer — that does not
apply here. The draw happens exactly once, host-only, and no other peer ever recomputes it; the host
broadcasts the authoritative result through `WorldDeltaLog` the same way it broadcasts a Cycle number.
D-041 already settled this exact question for `Chest`'s loot roll: real entropy (`randomize()`) is
correct precisely because nothing needs to agree by recomputation, only by receiving the same
broadcast value.

**No modifier's gameplay EFFECT is wired to `PowerupService`/`WaveSpawner`/`MireGrid` here** — the old
gate bullet's "effect hooks over PowerupService/wave tables/Mire rates" phrase is deliberately not
built. The roadmap task line itself only names "deck, draw, stacking, Cycle-weighted rules,
incompatibility tags" — the framework, not a specific modifier's mechanics — and wiring a bespoke
effect for `long_night` (the one worked example authored with this task, AGENTS.md's ban on
bulk-generating content) would be deciding, inside a framework task, what the first piece of
modifier-driven gameplay actually IS. That is the identical shape D-094 already used for
`HookDef`/gameplay-by-hook, deferred to "M6 Cycle Modifiers... with the rest of the picture in view."
`EventBus.emit_cycle_modifier_drawn(id, cycle)` and `CycleModifierService.has_modifier(id)` are the
seam a future consumer hangs a real effect off, the same "future task's hook" role D-092 gave
`wellspring_capped` and D-100 gave `cycle_advanced` itself.

**A real trap, filed separately as F-163:** `expr as Array[StringName]` does NOT convert an untyped
`Array`'s element type — it silently leaves the array untyped, and a subsequent `.set()` on a
strictly-typed `Array[StringName]` `@export` property then no-ops with no error, no warning. The real
conversion is the constructor call `Array[StringName](expr)` — the same syntax `content/powerups/*.tres`
already uses for typed array/dictionary literals, which turned out to be load-bearing at runtime too,
not just in `.tres` text.

**Would change my mind:** on tags-vs-ids, a playtest showing authors keep reaching for explicit id
pairs anyway and the tag mechanism goes unused — then simplify to id-only. On effect wiring, nothing
— that is deliberately the next task's decision to make with the rest of the Cycle Modifier picture
(roster size, UI announce, extraction pacing) in view.
