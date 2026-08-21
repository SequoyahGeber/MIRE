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
**AMBER as of 2026-08-20 (ivy1bcae0, F-347) — the 0.034 ms figure above no longer reproduces.**
`tools/bench_navbake.gd` on the settled 4.7.1 tree records the streaming episode's worst main-thread
block at **22-49 ms across five runs**, against the same 2 ms budget — three orders of magnitude off
the number this decision rests on. Everything else here still holds and is re-measured green: a
single async submission is 0.000-0.063 ms, attaching a region to a live map is 0.019 ms median, 16
bakes fired at once cost 5.2 ms, and seams connect via radius 0.50 / margin 1.10.

Profiled and isolated: it is **RETIREMENT**, not baking or attaching. Taking one region out of
service on a live map costs ~25-35 ms, and it is not about `free_rid` — `region_set_map(RID())`,
an empty navmesh, and `region_set_enabled(false)` all cost the same 25-26 ms, which points at the
map's edge-connection rebuild rather than at RID lifetime. `world/chunk/nav_baker.gd._retire()`
does exactly this per chunk as the world streams, so this is a shipped hitch, not a bench artifact.
Filed as its own finding with the measurements; the benchmark now exits nonzero on a missed budget,
so this cannot silently read green again.

What does NOT change: async-only baking, one bake in flight, `cell_size` 0.25, per-chunk regions,
the 1.10 m edge margin, and the grid-A* fallback staying unneeded. The risk R3 was about — can we
bake at runtime at all — is still answered yes. What is open is the cost of giving a region back.

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
*Reviewed 2026-08-19 — trigger fired as written: `GameState.run_seed` shipped in task 4.6. F-210
did the switch this entry itself names, deriving `Chest`'s roll from `(run_seed, a stable per-chest
id)` via the existing `Chest.host_seed_rng()` seam. No new decision needed; this one's provisional
period is over and its "would change my mind" is spent.*

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

### D-179 · 2026-08-18 · The powerup stat vocabulary is a governed catalog, and conditions, triggers and capabilities are stat names consumed at the owning system — not schema fields
*Renumbered from a duplicated `D-050` by F-283 — this entry and the `D-050` above were allocated the same number before the `agent decision` allocator existed (D-182). A pre-2026-08-20 citation of `D-050` that is about the subject below means this entry.*

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

### D-144 · 2026-08-19 · Task 4.13: the continent decides where biomes are, the biome decides how rough its ground is — and the terrain look costs 1.9x the chunk build

**The circularity, and the split that resolves it.** 4.13 gives every `BiomeDef` two terrain
amplitudes, so the surface now depends on which biome a point is in. But `BiomeMap` decides the
biome from height — so deciding it from the *final* height would mean the biome was chosen from a
surface the biome itself shaped. `IslandHeightmap` is therefore split:

* `continent(x, z, seed)` — warped fBm through the island mask, and nothing else. Biome-independent
  by construction. This is what `BiomeMap.biome_at()` samples, and what a `BiomeDef`'s
  `height_min`/`height_max` now mean.
* `height(x, z, seed, detail_amplitude, ridge_amplitude)` — the continent plus the two rough layers,
  scaled by the amplitudes the point's own biome authors. Defaults of 1.0 give the biome-blind
  surface, so every existing caller keeps working.

The one-line form: **the landmass decides where the biomes are; each biome decides how rough its own
ground is.** A shore is flat because its multipliers are near zero, not because the island is lower
there. `BiomeMap.terrain_amplitudes()` is the seam that hands a point's pair to the heightmap.

**Three shape decisions the top-down render forced, none of which are visible from ground level.**
`tools/terrain_map_render.gd` (new, headless, writes a PNG) is how these were found:

1. **A continental lift (`LAND_BIAS`).** Simplex is centred on zero, so `noise * mask` puts half the
   interior below sea level — the first render was an archipelago of ponds, not an island.
2. **A jittered coastline (`COAST_JITTER`).** The falloff is a circle, so without it the island is
   a coin with a sand rim. The mask reads a noise-displaced radius instead of the true one.
3. **A much tighter falloff** (0.55 → 0.78 of the radius). The original taper left a ~230 m annulus
   sitting within a metre or two of sea level, which handed `shore` most of the island's edge.

**The cost, measured rather than assumed** (`tools/bench_chunks.gd`, same machine, same run):
chunk build went **1.99 ms → 3.85 ms** single-threaded and **3.92 → 8.35 ms/chunk** amortized on the
WorkerThreadPool — 1.9x, for domain warp plus a ridged layer plus the coast field. Naive assembly was
2.4x; removing a duplicate noise construction per sample (the first cut built the base and coast
fields twice) recovered a fifth of it, with `check_determinism`'s hashes unchanged across the
refactor, which is what proves it was behaviour-neutral. **Against the worst-computers target this is
the largest single cost M4 has added**, and F-235 names the remaining win: the mesher rebuilds three
`FastNoiseLite` objects for every one of a chunk's 1,089 samples.

**Both new operations are in the determinism probe in the same task that added them**, per D-142:
`continent` and `ridge_mask` hash separately from `terrain_hash`, so a cross-platform mismatch says
which one drifted rather than just that the surface did.

**Sequoyah's direction, same day, after seeing the first render: the island was far too big, and the
brief is one main island plus one or two mini islands really close to it, with big ocean otherwise.**
Four consequences, all of them in this task:

* **`ISLAND_RADIUS` 512 → 118 m** — an island ~236 m across, the class the hand-authored Hollowmere
  is in (192 m, D-045) and what one evening can cover. The Mire grid still covers 1024 m; that is
  the right way round, terrain sized to the run rather than to the simulation's bookkeeping.
* **`HEIGHT_SCALE` 60 → 26 m.** Sixty metres of relief across 236 m is a cone whose every slope
  beats the player's 46° floor limit.
* **Shape scales with the island, texture does not.** Continental noise, its warp and the coast
  jitter are authored against a 512 m island and scaled by `FREQUENCY_SCALE`, so a smaller island
  has the same number of bays rather than cropping most of them out. Detail and ridges keep their
  absolute frequency, because a ridge is tens of metres and a bump underfoot is a few metres whatever
  size the island is — scaling those put crests 11 m apart and turned the interior into a sponge.
* **Islets are placed, not grown.** One or two, at 1.22× the radius, from a fixed table of unit
  vectors indexed by seed — a table rather than an angle because this file may not use `sin`/`cos`
  (they resolve differently across platforms, and D-017/D-028 rest on this function being
  bit-identical). Noise that produces satellites at all produces them out to the horizon, which is
  the archipelago the first render showed.

**A ridge only ever adds.** Re-centring the ridged fractal to −1..1 made it cut as deep as it lifted:
22 m pits on a 26 m island, and an interior riddled with lakes. It is thresholded now, so troughs sit
on the floor and only crests exist.

**Sequoyah, same day: "the islands are quite round, they shouldn't be standard shapes."** A radial
falloff makes a coin, and displacing its edge with noise makes a coin with a wobbly rim — the
silhouette is still a circle because the thing being displaced is a circle. Two changes, and the
second mattered more than the first:

* **The island is a union of overlapping lobes**, three or four of them, at seeded offsets and radii,
  with the centred body lobe deliberately *not* the largest (0.60 against lobes up to 0.72). At 0.84
  the body was the island and every other lobe was a bump on it, which still rendered as a circle.
  Connectivity is enforced by clamping each lobe's offset so it must overlap the body, rather than by
  picking numbers that happen to work.
* **Lobe directions are independent, not evenly spaced.** Stepping a fixed stride round the direction
  table spreads lobes evenly, and evenly-spread lobes union straight back into a rounded polygon —
  every seed came out the same shape. Independent directions let some seeds cluster their lobes into
  a long island with a waist and others spread them into a broad one. Variety is the point; one
  irregular shape repeated is still a standard shape.

Every mask is measured in **warped space** — a vector displacement applied to the point before any
distance is taken — so arcs become inlets and spits rather than staying arcs with noise on them.

**`world_radius()` is a function, not a constant, and that is deliberate.** GDScript will not
evaluate `maxf()` in a const expression, and the alternative — a hand-computed literal — is exactly
what went wrong: the first bound covered islets and was silently wrong the moment lobes could reach
further. `terrain_check` caught it as 11 mm of land sitting on the boundary.

**Two constants exist because of this, and callers must prefer them to the obvious ones:**
`WORLD_RADIUS` (islets sit past `ISLAND_RADIUS`, so *that* is no longer where the land ends —
anything culling or bounding the world wants this) and `MAX_HEIGHT` (`HEIGHT_SCALE` is the noise
amplitude, not the peak: `LAND_BIAS` lifts the continent and ridges add on top). `tools/terrain_check.gd`
asserted both of the old meanings and had to be brought forward with the model.

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

### D-104 · 2026-08-18 · Task 6.4's Wellspring re-corruption: a real-time clock gated by Cycle turnover, paused (not reset) under a Ward, and no hand-seeded local re-corruption

**The clock only starts at the next Cycle turnover, not the instant a Wellspring caps.**
DESIGN.md §5.1 lists "Capped Wellsprings begin re-corrupting" as one of three things that happen "at
the end of each Cycle," alongside the spread-rate escalation and enemy-roster expansion 6.1 already
built off the identical `EventBus.cycle_advanced` seam. Reading `capped` at the moment of a
`cycle_advanced` event, rather than starting a timer the instant `_finish_cap()` runs, means a
Wellspring capped seconds before a Cycle ends is not punished with almost no grace period, and a
Wellspring capped seconds after one is not left immune for an entire extra Cycle by accident — both
read the same clock at the same shared moment, exactly the "read once at the threshold" rule
`Wellspring._session_player_total()` already uses for the ritual's own player-count snapshot.

**`RECORRUPTION_DURATION_SEC` (900s) and `RECORRUPTING_VISUAL_FRACTION` (0.5) are placeholder-tuned,
same status as `MireGrid.BASE_SPREAD_RATE` and `CycleService.SPREAD_ESCALATION_PER_CYCLE`.** No
number is written down anywhere in DESIGN.md beyond "slowly re-corrupt." 900s matches
`DayNight.day_length_seconds`'s own default (also 900s) so a capped Wellspring left completely
unattended survives roughly one in-game day of its clock before it needs attention — long enough not
to feel instant, short enough to force a real choice before too many Cycles pass. Nothing here has
been through a real playtest.

**The clock PAUSES, not resets, while a placed Ward covers the Wellspring** — ROADMAP.md's own 6.4
line names this explicitly ("decay on a host timer unless Warded"), a real written mandate this task
found waiting for it, not something invented from scratch. `Wellspring._is_warded()` reuses
`BuildService.ward_radii()`, the exact same source `MireGrid`'s own `_ward_circles_provider` already
consumes for spread resistance (task 4.11) — one extra autoload hop instead of threading a second
seam through `MireGrid`. Pausing rather than resetting matches D-092's existing precedent for the
ritual's own under-presence case: a Ward is protection, not a fresh punishment for stepping away and
coming back.

**No SIM-level re-seed of the cleared radius on full re-corruption.** `MireGrid._on_wellspring_capped()`
zeroes a 48m radius; the symmetric `_on_wellspring_recorrupted()` only decrements
`_capped_wellsprings` (undoing the spread-rate reduction the cap granted) and does NOT hand-seed
corruption back into that circle. `MireGridSim.tick()`'s own flood-fill only spreads outward from a
cell that already has a nonzero value, so a fully-zeroed circle regrows from its still-corrupted edge
inward on its own, over subsequent ticks, once the multiplier lifts — the identical mechanic every
other cleared cell on the map already uses. Writing a second "reseed a radius" SIM function would
duplicate that regrowth by hand for no visible difference, and risks disagreeing with it (a
hand-picked reseed value the flood-fill would then fight or ignore).

**Would change my mind:** on the two placeholder constants, a real playtest (Q3, the wall) measuring
that Wellsprings decay before or long after the pressure curve wants them to. On the no-reseed call,
if a playtest shows the flood-fill regrowth is imperceptibly slow at the map's edges (few corrupted
neighbours to spread from) — then a small, capped reseed pulse at the moment of `_finish_recorruption()`
would be the fix, not a redesign.

---

### D-105 · 2026-08-19 · Extraction's "group confirm flow" is a presence-gated hold, not a per-peer ready-vote — task 6.5

DESIGN.md §5.2 says boarding "ends the run successfully" for the whole crew and names no UI shape for
the group's decision to leave. Two designs were live: (a) each player presses a personal "ready"
toggle, tracked as a replicated per-peer set, and departure fires once everyone's flag is up; or (b)
reuse Wellspring's own ritual FSM verbatim — an interact press starts a hold, it only advances while
enough players are physically present, a second press cancels it outright — with "enough" set to the
whole connected session rather than Wellspring's 1-2.

**Took (b).** Three reasons. First, it needs no new replicated shape: `repair_stage`,
`departure_channeling`, `departure_progress_sec`, `departure_required_players` and `departed` are all
primitives, exactly Wellspring's own property list, so `ExtractionShip`'s `SceneReplicationConfig` is
a copy-paste, not a novel Array/Dictionary-over-the-wire design nobody has proven works yet in this
codebase. Second, it is the more thematic reading of "board-to-leave, group confirm": the whole crew
has to physically gather at the wreck and hold there together, not tap a button from wherever they
happen to be standing — the climax scene DESIGN.md's "one more Cycle" framing is written for. Third,
it inherits D-092's already-settled cancel-forfeits/absence-pauses split for free, rather than
re-deriving a third version of that rule.

**Consequence:** a player who is downed, dead, or simply off exploring blocks departure until they
either rejoin the group at the ship or someone accepts leaving without them — there is no "vote to
leave without the straggler" path. That is read as correct for now: DESIGN.md's own frame is that
extraction is a decision the whole crew makes together, and the game has no partial-run-continues
state to strand a straggler in anyway (D-010 — a run is one sitting).

**Would change my mind:** a playtest where a downed or disconnected-but-not-expired teammate
repeatedly strands an otherwise-ready crew at the wreck long enough to feel bad, at which point the
fix is most likely excluding downed players from `departure_required_players` (mirroring
Wellspring's own presence count, which already only counts live players), not a redesign into the
per-peer vote shape.

---

### D-106 · 2026-08-19 · Ship repair does NOT go through `CraftingService`/`RecipeDef`, despite `docs/SPECS.md`'s 6.4 look-ahead note saying "staged repair via recipes (3.1's timed crafts)" — task 6.5

Checked `autoload/crafting_service.gd` before deciding this, rather than assuming. Its whole model is
built around a STATIC, content-authored station: `Registry.stations` holds fixed `StationDef`
entries, `nearby_station_id()` walks that registry (not a runtime scene tree) to find which one the
player is next to, and every recipe's `output_item` is a real `ItemDef` granted straight into the
requester's inventory via `InventoryService.host_transaction()`. None of that fits the ship: it is
one runtime-built node per marker (`autoload/extraction_service.gd`, not a `Registry`-listed
station), and a repair attempt has no item to grant — what it mutates is the ship's OWN replicated
`repair_stage`, a shape `CraftingService` has no seam for at all.

Retrofitting `CraftingService` to support a station that is a live node rather than a registry entry,
and a recipe that mutates external state instead of granting an item, would be a real redesign of a
system three other lanes build against, for one consumer — clearly outside a T2/est-3 task, and it
risks regressing crafting for no player-visible gain (the two paths would look identical in the HUD
either way).

**Took instead:** the harvest-request pattern every other host-authoritative interaction in this
codebase already uses (Wellspring's channel, Chest's open, BuildService's place/destroy) —
`net_request_repair` carries no data, the host re-derives everything (range, tool, Cycle gate,
inventory) and applies `InventoryService.host_transaction()` directly against `REPAIR_COSTS`, a
plain `Array[Dictionary]` of `item_id -> count` living as tuning data on `ExtractionShip` itself, the
same status as Wellspring's own `COOP_DURATION_SEC`/`RECORRUPTION_DURATION_SEC` constants. "Staged"
is still true — three discrete stages, matching the four A-009 hull states 1:1 — "via recipes" is not,
literally.

**Would change my mind:** a later task that wants ship repair to show up inside the crafting UI itself
(`ui/crafting/crafting_ui.gd`'s recipe rows), at which point `CraftingService` gaining a
"mutate-in-place" recipe kind is a real feature worth building for more than one consumer, not a
shim added just to satisfy this note.

---

### D-107 · 2026-08-19 · A persisting autoload must gate its own disk writes on "is this a real game boot", not trust every check that fires the event it listens for — task 6.6

`SalvageService` is the first system in this codebase that writes to `user://` in response to a
gameplay event, and it exposed a trap nothing before it could hit: `EventBus` is a per-process
static, so ANY `--script` harness that legitimately fires a real `run_extracted` or
`wellspring_capped` event to test ITS OWN system reaches every OTHER subscriber exactly as if it
were the shipped game. Confirmed, not hypothetical: running `tools/extraction_check.gd` once — its
departure-hold tests correctly complete two real extractions as part of proving that FSM — banked
116 Salvage into this developer's actual `user://salvage.json` before this guard existed. A prior
system reacting to the same events (`MireGrid` undoing a Wellspring's spread reduction on
`wellspring_capped`) never showed this failure mode because its state lives only in memory and dies
with the process; persistence is what turns a check's incidental side effect into permanent local
corruption that outlives the run that caused it.

**Took:** `SalvageService._persistence_enabled()` gates every write on
`save_path != SalvageSave.SAVE_PATH or get_tree().current_scene != null`. A `--script` harness never
loads `project.godot`'s `run/main_scene` (`current_scene` stays null for its whole run); the real
game, and a `--quit-after N` full-boot smoke check, always has one. `tools/salvage_check.gd` opts
back in by overriding `save_path` to a throwaway file before it ever banks anything, which both
isolates its own writes from a real save AND is the thing that lets it prove persistence actually
works. This puts the fix in exactly one place — the autoload that owns the disk write — rather than
requiring every existing and future check that might incidentally fire `run_extracted`/
`wellspring_capped`/`run_wiped` to know `SalvageService` exists and remember to disable it.

**Rejected:** teaching every check that can complete a Wellspring capture or an extraction to
explicitly silence `SalvageService` first. Fragile by construction — it is an opt-out an author has
to remember to add to code that has no reason to know a completely different system is listening,
and the failure mode (silent disk pollution) gives no signal that the opt-out was missed until
someone notices their save total drifted.

**Would change my mind:** a real dedicated-headless-server deployment that boots the actual game
without `run_main_scene` set (unlikely — see `DESIGN.md` §7's "no dedicated servers" cut), or a
future persistence system that legitimately needs to write from inside a `--script` harness without
an explicit path override, at which point the guard needs a second, deliberate opt-in rather than
the implicit one `current_scene` gives every real boot today.

---

### D-108 · 2026-08-19 · Salvage's reward curve, milestone scope, and the `run_wiped` seam — task 6.6

Three scope calls DESIGN.md leaves open, made together because each is a "decide it, write down why"
call under AGENTS.md rather than something worth stopping the task for.

**The curve.** `reward_for_cycle(cycle) = CYCLE_BASE * cycle^CYCLE_EXPONENT + milestone_bonus`,
`CYCLE_BASE = 10`, `CYCLE_EXPONENT = 1.6`. An exponent-based curve is superlinear by construction
(DESIGN.md §5.2: "Cycle 9 worth much more than 3x Cycle 3") without needing a hand-authored lookup
table that would need re-tuning every time a Cycle constant changes elsewhere. Measured: Cycle 3 =
58, Cycle 9 = 336 (~5.8x for 3x the Cycle). Placeholder, unplaytested — same status as every other
Cycle-facing constant in this codebase.

**Milestone scope.** DESIGN.md §4.6 names three secondary factors: "Wellsprings capped, bosses
killed, tiers reached." Only Wellsprings capped is real today — `EventBus.wellspring_capped` already
exists and fires once per cap; no boss enemy concept exists anywhere in the codebase, and nothing
announces a crafting tier as "reached" this run (`StationDef.tier` exists but is never broadcast).
Building detection for either from scratch would be two other systems' worth of work smuggled into a
T2/est-3 task. **Took:** ship the one real signal now (+20 Salvage/cap via `WELLSPRING_CAP_BONUS`),
shape the counter (`_wellsprings_capped_this_run`, reset on `GameState.seed_ready`) so a future task
adds a boss- or tier-reached bonus as one more `EventBus` subscription and one more counter, not a
reward-formula change. **Would change my mind:** a boss or tier-announcement system landing before
6.6's own numbers get a real playtest pass — at that point wire it in the same task that tunes the
curve, rather than leaving the milestone half permanently thinner than DESIGN's list.

**`run_wiped` ownership.** `EventBus.subscribe_run_wiped(cycle, world_position)` exists and
`SalvageService` consumes it (banking `DEATH_BANK_FRACTION = 0.5` of the full reward), but nothing
emits it — task 6.7 ("Lose condition") is the task that decides WHEN a run has actually ended in
defeat (team wipe with no bleed-out revive pending, or the island consumed), which 6.6 has no
business deciding. **6.7 must call this exact signal, not invent a second one** — `SalvageService`
is already wired to only this name — **and must fire it the way 6.6 fixed `run_extracted`: from a
replicated property's setter reaching every peer's own local `EventBus`, never from a host-only
guard.** `Wellspring._finish_cap()` had the old host-only shape for `wellspring_capped` at the time
this was written — that was the wrong shape to copy, not precedent to follow, and F-168 has since
fixed it to the setter shape this note requires.

**Would change my mind (on the split itself):** a playtest showing `DEATH_BANK_FRACTION = 0.5` makes
extracting feel mandatory rather than a real bet either way (Q6) — DESIGN.md only specifies the
direction ("a fraction"), not the number.

---

### D-109 · 2026-08-19 · Task 6.7's lose condition: a dedicated `DefeatService`, not `game_state.gd`; a broadcast RPC, not a `MultiplayerSynchronizer`; "down" alone is a wipe; a fraction, not "every cell", for island-consumed

Four calls, made together because each is a "decide it, write down why" call under AGENTS.md.

**Why `autoload/defeat_service.gd`, not `core/game_state.gd`.** `docs/SPECS.md`'s old 6.7 look-ahead
line said "defeat flow through GameState", and `ARCHITECTURE.md` §3 does reserve `game_state.gd`'s
slot for "act, day, seed, run status." Task 6.1 already answered this exact question for the Cycle
state machine and reversed it: `game_state.gd`'s header comment reserves the *file path*, not a
mandate to grow that specific file, and `game_state.gd` stays scoped to run-seed authority so mixing
an unrelated state machine into it does not blur that scope for no benefit. The identical reasoning
applies here — a dedicated `systems`/`autoload` file per system is the pattern every other
Cycle-adjacent autoload in this codebase already follows (`CycleService`, `MireGrid`, `WaveSpawner`,
`DayNight`), and `DefeatService` is one more.

**Why a broadcast RPC (`net_run_defeated`), not `MultiplayerSynchronizer` + `SceneReplicationConfig`
(D-023's usual mechanism for `Wellspring`/`ExtractionShip`/`Chest`/`Harvestable`).** That mechanism
exists to bring a LATE JOINER up to date with ongoing state — a synchronizer replays its property's
current value to a peer that connects after the fact. A run that has just ended in defeat has no
"late" left to join: the whole point is that play stops. A single reliable broadcast, sent once from
the same setter every peer's own `_apply_defeat()` runs through (host directly, client via the RPC
handler), is the whole mechanism this needs, and it avoids standing up `NetInterest`/`NetConfig`
machinery built for spatial, continuously-relevant props. **Would change my mind:** if a future task
needs a mid-defeat late joiner to see the same defeat screen (e.g. a spectator flow) — that is a real
"bring a joiner up to date" need this shape does not cover.

**"Down" alone is a wipe — no separate "and no revive available" check.** DESIGN.md §5.3: "all
players down simultaneously with no revive available." A revive requires a reviving player to be
ALIVE (`PlayerHealth._validate_revive`); the instant every present peer reads `host_is_alive() ==
false`, there is by construction nobody left who could revive anybody, so "no revive available" is
already true and does not need its own timer or flag.

**Island-consumed is a fraction (`ISLAND_CONSUMED_FRACTION = 0.97` of the grid at/above
`ISLAND_CONSUMED_CORRUPTION = 0.95`), not "every single cell."** `IslandHeightmap.
FALLOFF_START_FRACTION`'s outer taper means the grid's edge cells never fully saturate the way its
interior does, so a "wait for 100%" rule would never actually fire. Both numbers are
placeholder-tuned, the same unplaytested status as every other Mire constant in this codebase
(`MireGrid.BASE_SPREAD_RATE`, `CycleService.SPREAD_ESCALATION_PER_CYCLE`). **Would change my mind:**
a playtest showing the island reads as "consumed" while large playable pockets remain, or the
opposite — players reaching the DESIGN-intended "soft wall" (Cycle 8–12) well before the fraction
trips.

---

### D-110 · 2026-08-19 · Task 6.10: `MainMenu` never auto-opens and never binds Esc; settings ships as a shell, not 7.5's content

Three calls, made together because each is a "decide it, write down why" call under AGENTS.md, for
the "main menu shell, settings, and seed entry" the lobby-UI slice (D-030) left open.

**Why `MainMenu` (F1, not Esc) never auto-opens at boot.** The obvious reading of "main menu" is a
title screen the game boots INTO, gating play behind it. Two things rule that out here. First,
`entities/player/player_controller.gd`'s `ui_cancel` handler already has a one-line comment
reserving Esc for exactly this: "Temporary mouse release. Replaced by the pause menu in M7." Binding
Esc to a menu now — even a different one — relitigates a reservation four milestones early, for a
key the pause menu will want back. Second, and more load-bearing: `run/main_scene` boots straight
into `levels/hollowmere.tscn`, and this project's whole verification method (D-023) leans on
two-process checks and `--quit-after N` full-boot smoke runs that expect to act on a live world
immediately — every panel already shipped (`LobbyMenu`/`InventoryUI`/`CraftingUI`/`DebugConsole`)
opens on an explicit keypress and NONE auto-open, for exactly this reason. An auto-shown blocking
overlay at boot would be the first panel to break that invariant, silently, for every lane's checks,
not just this task's own. **Would change my mind:** a real "gate world-gen behind a start screen"
task, scoped and reviewed on its own, that explicitly updates the two-process/full-boot check
convention to dismiss the gate first — not a decision this task should make as a side effect of
"main menu" sounding like a title screen.

**Why seed entry stages through `GameState`, not a new field on `MainMenu` itself.** `GameState`
already owns `run_seed` and already decides when a fresh one is drawn (`host_generate_seed`,
`ensure_seed` — task 4.6, D-089). Adding `set_pending_seed()`/`has_pending_seed()`/`pending_seed()` to
that same file keeps exactly one place deciding what a session's seed is, with the UI only ever
staging a request. F-172 records the one gap this leaves: solo/offline play draws its seed
(`MireGrid._ready()` → `GameState.ensure_seed()`) before the player can ever open the menu that
would stage one, so seed entry today only reaches the HOST path, not solo play. **Would change my
mind:** if solo seed entry becomes a real ask — see F-172's own note on what actually closes that
(a boot-gate task, not a `MainMenu` change).

**Why `ui/menu/settings_menu.gd` ships as an empty shell instead of real graphics/audio/sensitivity
controls.** `autoload/graphics_quality.gd`'s own header comment already reserves "Task 7.5's settings
menu gets three buttons now," and `docs/SPECS.md`'s M7 look-ahead names task 7.5 as the one that
ships `user://settings.cfg` persistence and a `SettingsService` autoload for
graphics/audio/sensitivity/keybinds/FOV/accessibility — `docs/ROADMAP.md`'s own 6.10/7.5 split says
the same thing ("T0 shell + T1 wiring" for 6.10, the full knob list for 7.5). Building any of that
content here would be 6.10 designing 6.10's own content ahead of 7.5's own task, the exact trap D-089
named for `game_state.gd` (task 6.1 vs 4.6) and D-109 named again for `defeat_service.gd` (task 6.7
vs an old look-ahead line). `SettingsMenu` ships only the D-032 exclusivity, open/close and visual
frame; 7.5 adds rows to its `stack` node and nothing else about this file needs to change. **Would
change my mind:** nothing short of 7.5 itself — this is a scheduling call the roadmap already made,
not a technical constraint this task discovered.

### D-111 · 2026-08-19 · Task 6.9's unlock tree ships the full purchase/persistence/UI framework, but wires no live gameplay gate — F-173 explains why that is not a small follow-up

**"Never power" is enforced by `UnlockDef`'s schema, not a runtime check.** The def has `id`,
`category` (a closed §4.6 vocabulary), `display_name`, `description`, `cost`, `gates_id` — no
numeric stat/bonus field exists anywhere on it, the same structural move D-044 already used to make
a stray stat impossible to author onto `PowerupDef`. A future author cannot accidentally ship
"+5% damage" through this system even by mistake; there is nowhere on the resource to put it.

**Why the worked example (`unlock_deep_pocket.tres`, gating the real `deep_pocket` PowerupDef
already rolled by `content/loot/bog.tres`) does not actually change what a chest can roll.** This
was the natural first real gate — DESIGN.md §4.6 leads its unlockable list with "new powerups in
the pool," and a live consumer would have been the strongest possible proof the framework works.
It was cut for a real reason, not a scope shortcut: `LootTableDef.roll()` runs once, host-side, for
whichever peer opened the chest, but `UnlockService.is_content_unlocked()` only ever answers for
the CALLING peer's own local `user://unlocks.json` (§2.2's new "Unlocks" row is explicitly **None**
— per-player, unreplicated, the same shape Salvage already has). Wiring the check into the host's
roll would have to pick one of: gate the whole party's odds off the HOST's own unlock set
regardless of who opened the chest (wrong — a client who bought the unlock would never see it
drop), or somehow ask the opening PEER's own save (no seam exists to ask a peer for its own local
state — Salvage/Unlocks were deliberately built with no RPC of their own). Either shipped choice
would be a real bug wearing a "worked example" label. POI placement and enemy-roster expansion have
the identical conflict one level worse: §2.2 already requires those to be byte-identical across
every peer by construction (derived from the shared world seed), and a per-peer unlock set cannot
satisfy that without either replicating purchases or making unlocks a session-wide (not per-player)
setting — a real design call, not a missing line of glue code.

**What shipped instead is a complete, independently-testable vertical slice with no consumer:** the
def, the worked-example content file, `UnlockService.purchase()`/`is_content_unlocked()`,
`SalvageService.spend_salvage()`, `EventBus.unlock_purchased`, and `UnlockMenu`'s buy flow all work
and are covered by `tools/unlock_check.gd` end to end — buying the worked example really deducts
Salvage, really persists, and really flips `is_content_unlocked(&"deep_pocket")` from false to true.
Nothing in the shipped game calls `is_content_unlocked()` yet, so today that flip has no visible
effect — exactly the same "framework, not effect wiring" cut D-103 already made for Cycle Modifiers
(`has_modifier()` exists, nothing reads it into a gameplay system).

**Would change my mind:** a task that resolves the cross-peer question first — either (a) purchases
start replicating (a new reliable RPC, `UnlockService` gains an authority row closer to Salvage's
`salvage_banked` counterpart but broadcast), or (b) the design settles for "the HOST's own unlock
tree gates the run for everyone," which needs no RPC at all and matches how a single-player-rooted
roguelike's meta-progression usually reads anyway. Either answer, once picked, makes wiring the
first real gate (loot table, then POI/enemy roster) a small, mechanical follow-up — this decision is
about not shipping the WRONG answer by default, not about the gate being hard to wire technically.

**2026-08-19 (lp, F-236) — `is_content_unlocked()` still has exactly one consumer.** Six more
`content/unlocks/*.tres` rows shipped (all `category = "powerup"`, gating existing PowerupDefs that
already roll in a real loot table — `docs/SPECS.md`'s F-236 block), but the only live gate remains
`LootTableDef.roll()`'s POWERUP-kind check this decision already describes. An author who writes an
`attunement`/`poi`/`enemy`/`cycle_modifier`/`island_modifier`/`cosmetic`/`loadout` row today ships a
menu entry that spends real Salvage and marks itself purchased, but gates nothing — none of those
seven categories has a callsite that asks `is_content_unlocked()` yet. Recording it here rather than
letting the next author discover it by watching a purchased row change nothing.

### D-112 · 2026-08-19 · Task 7.8 adds no new §2.2 authority row; "packet loss / high latency" resolves to auditing what already exists, not simulating a wire

Every prior task with an open `## §2.2` instruction to "declare a row" was shipping new simulated
state — a replicated property, a new RPC, something two peers could disagree about. Task 7.8 ships
neither: it fixed five unguarded `rpc_id()` sends (see `SPECS.md` §7.8) and added one verification
script. Giving that a table row would misrepresent the table — every existing "none of its own" entry
(`net_version.gd`, `NetTransport` itself) is infrastructure for the same reason, and neither has a row.
The right read of "every system declares its authority" is that a task which adds no state to disagree
over has nothing to declare, not that it must invent a row to satisfy the letter of the rule.

**The other half of this decision: packet loss and high latency are not simulable on this dev setup,
and the task's scope reads as "hold the line on what already handles them," not "build a fault
injector."** Checked directly — `ClassDB.class_get_method_list()` against `ENetConnection`,
`ENetPacketPeer`, `ENetMultiplayerPeer` at the pinned Godot 4.7 build has no loss- or latency-injection
method anywhere in the three (`ENetPacketPeer.throttle_configure` is ENet's own outgoing bandwidth
throttle, not a fault injector), and there is no cross-platform, no-sudo way to fake WAN conditions on
a raw loopback socket from a headless macOS box either. So this task verified the two things that
already stand in for "packet loss doesn't desync state" (every mutating RPC is reliable; the two
`"unreliable"` RPCs in the whole repo are both self-healing by construction) and "high latency doesn't
evict a live peer" (`NetTransport`'s 2.5–8 s dead-peer window already treats slow as different from
gone), rather than building simulation infrastructure nothing else in the project has a use for.

**Would change my mind:** a future Godot upgrade that exposes real loss/latency injection on
`ENetConnection` (worth revisiting then — a real WAN-conditions harness would be strictly better than
this audit), or a task that DOES add new simulated state to this system (a reconnect-quality metric
replicated to a HUD, say) — that task gets a real row, not this one retroactively.

### D-113 · 2026-08-19 · Task 5.9's Cycle-aware wave pacing is additive and capped, not compounding like `CycleService`'s own spread multiplier

`WaveSpawner.cycle_count_multiplier(cycle)` scales a wave's SIZE by
`min(1.0 + (cycle - 1) * 0.15, 2.5)` — additive per Cycle, capped at 2.5x, reached at Cycle 11. The
obvious alternative was reusing `CycleService`'s own `_spread_multiplier` shape
(`SPREAD_ESCALATION_PER_CYCLE = 1.15`, compounding, uncapped) — either literally reading
`CycleService.spread_multiplier()` as the count multiplier too, or giving waves their own
1.15^cycle curve. Rejected both, for two independent reasons:

1. **DESIGN.md §5.4 names the escalation mechanism explicitly**: "Escalation is generated by stacking
   modifiers... **not from content volume**." A wave's enemy COUNT is content volume; treating it as
   the run's primary escalation axis (the way Mire spread rate legitimately is — that one IS meant to
   compound forever, it's the literal lose condition) contradicts the design doc's own stated reason
   endless replayability works here.
2. **This is an endless game with no Cycle ceiling.** An uncapped multiplicative enemy count run
   forever — 1.15^30 ≈ 66x base — is not "hard," it is a guaranteed frame-rate collapse in exactly the
   class of problem F-144 already documents for static props at ~2,900 instances. A capped curve avoids
   ever needing to answer "what render budget does an arbitrarily-long run get," because the count
   itself stops growing.

The cap's landing Cycle (11) was chosen to fall inside DESIGN.md §5.3's own explicit "hits a wall
somewhere around Cycle 8–12" window, so wave SIZE saturates right where the design doc already says
the difficulty wall should be — composition (the roster weighting `_roll_roster()` also shipped this
task) and Cycle Modifiers (6.2) are what carry the escalation past that point, per DESIGN.md §5.4.

**Would change my mind:** 5.10's balance pass (T0, "combat balance across the Cycle curve" — the task
this decision is explicitly written for) measuring, from a real playtest, that the wall lands
somewhere other than Cycle 8–12, or that wave SIZE (not just composition/modifiers) needs to keep
growing past the cap to hold difficulty. Both constants
(`CYCLE_COUNT_STEP_PER_CYCLE`/`CYCLE_COUNT_CAP_MULTIPLIER`) are placeholder-tuned like every other
Cycle-facing constant in this codebase — nothing here is precious, only the additive-and-capped SHAPE
is the actual decision, not the two numbers.

---

### D-114 · 2026-08-19 · Task 7.5's settings: JSON persistence over `ConfigFile`, runtime-created audio buses over a `.tres` layout, keybinds scoped to keyboard-primary actions, "reduce camera motion" as the one accessibility control

Four scope calls, made together because each is a "decide it, write down why" call under AGENTS.md
for a task whose only spec was an M7 look-ahead bullet (`docs/SPECS.md`'s own preamble makes writing
the real block part of this task).

**Why `user://settings.json` via a new `SettingsSave`/`SettingsService` pair, not the
`user://settings.cfg`/`ConfigFile` the old look-ahead bullet named.** By the time 7.5 was picked up,
task 6.6 (`SalvageSave`/`SalvageService`) and task 6.9 (`UnlockSave`/`UnlockService`) had already
established the repo's one real pattern for per-player persisted state: a static, autoload-free
`core/save/<name>_save.gd` doing JSON load/save/migrate with a versioned schema, and a matching
autoload that owns *when* to load/save and applies the values to the engine, guarded by the same
`save_path` override + `current_scene == null` `_persistence_enabled()` check so a `--script` check
never touches a real save file (D-107). Following `ConfigFile` instead would give this project two
save formats for the same category of data — "per-player account/presentation state that survives a
session" — for no reason other than the old bullet predating 6.6/6.9. Settings persistence gained
nothing `ConfigFile` offers (typed sections, comments) that the JSON shape doesn't already handle via
`_default_data()`/`_migrate()`. **Would change my mind:** a real cross-tool interop need for the
settings file (an external launcher reading it, say) that specifically wants INI-shaped text —
nothing this task found asked for that.

**Why "Music"/"SFX" audio buses are created at runtime (`AudioServer.add_bus()`) rather than shipping
a `default_bus_layout.tres`.** A committed bus layout resource is a Godot-authored file under D-031's
exact-claim/closed-editor rule for two buses whose only property is "exists, sends to Master" — the
kind of thing AGENTS.md's own Godot-file section says to prefer generating from a tool script over
hand-authoring when the content is this small. `SettingsService._ensure_audio_buses()` checks
`AudioServer.get_bus_index()` and only adds a bus if it's missing, so this is idempotent across
restarts and adds nothing to this task's claim set. **Would change my mind:** a bus layout that needs
per-bus effects (compression, a limiter) authored in the inspector — that content doesn't have a
sane code-only representation the way "exists and routes to Master" does.

**Why keybind rebinding covers only the ten keyboard-primary actions
(`move_forward/back/left/right`, `jump`, `sprint`, `interact`, `inventory`, `build`, `dodge`), not
`attack`.** `attack`'s primary binding is a mouse button (`project.godot`'s own `[input]` section),
and a "press a key to rebind" flow that also has to handle "click a mouse button to rebind" is a
different capture UI, not a checkbox on the same one — `SettingsMenu._finish_rebind()` only ever
listens for `InputEventKey`. Scoping to keyboard-only keeps 7.5's keybind rows homogeneous (one
button, one key, one conflict check) rather than half the rows behaving differently from the other
half. **Would change my mind:** an explicit ask for mouse-button rebinding — `attack`'s joypad
binding (axis 5) is also untouched by the same reasoning, and gamepad rebinding is task 7.6's own
scope, not this one's.

**Why "Reduce Camera Motion" is the one accessibility control this task ships, not a longer list.**
`PlayerCamera` already had exactly two things that move the camera without the player's own input —
impact shake (`add_shake()`) and the sprint FOV pulse (`_process()`'s `lerpf` toward a boosted FOV) —
both named triggers for motion sensitivity/vestibular discomfort in the accessibility literature this
genre gets compared against. A single toggle that suppresses both is content this task could build
against an existing, well-understood seam and verify headlessly (`tools/settings_check.gd` calls
`add_shake()` under the toggle and asserts `shake_remaining() == 0.0`). Colorblind palettes, subtitle
systems, or a UI-scale slider would each need a system that does not exist yet (there is no subtitle
system, no colorblind-aware palette definition anywhere in the repo) — inventing one as a side effect
of "accessibility basics" is exactly the scope-creep AGENTS.md warns against ("a bug fix doesn't need
surrounding cleanup"). **Would change my mind:** a specific accessibility ask from Sequoyah's own
playtesting, or a future task that already owns the relevant system (a dialogue/audio-cue task owning
subtitles, a UI task owning palette).

---

### D-115 · 2026-08-18 · Task 7.7 ("Performance pass … LOD tuning, draw calls") ships enemy-visual LOD, not props/draw-call batching — that surface belongs to F-144

`agent brief 7.7` showed F-144 ("Props have no LOD and no cross-asset batching") already 6h in flight
under a different lane, holding `autoload/graphics_quality.gd`, `core/render/mesh_merge.gd`,
`systems/harvesting/harvestable.gd`, `world/environment/draw_policy.gd`,
`world/gen/authored_world.gd`, and `world/gen/undergrowth.gd` — every file the "LOD tuning, draw
calls" half of 7.7's title would otherwise touch, and F-144's own finding text is close to verbatim
the same headline ("no mesh LOD anywhere", "cross-asset batching"). AGENTS.md is explicit that two
agents in one file is the exact failure this project's claim system exists to prevent, and this work
order's own header forbids ending a turn to wait on another lane's claim. So rather than block on
F-144 or duplicate its scope in parallel (guaranteed merge pain on the same handful of files, decided
by whoever ships second), 7.7 was narrowed to the one performance surface F-144's fix cannot reach at
all: **enemies**, which are independently-animated per-instance meshes, not static geometry that can
be merged into F-144's batched-mesh approach. `Enemy._build_visual()` now sets a visibility-range
self-fade (90 m, 8 m margin) on every enemy mesh — see `docs/SPECS.md` §7.7 and F-174 for the full
writeup and the profiling numbers behind the 90 m choice.

**Would change my mind:** nothing about this split needs revisiting once F-144 ships — the two tasks
were always disjoint (mergeable static geometry vs. per-instance animated meshes), this decision just
records that they were worked as two separate claims rather than one lane blocking on the other. A
future perf pass that wants a SINGLE combined write-up of "everything with a visibility range now"
should read both F-144's resolution and `docs/SPECS.md` §7.7 rather than re-deriving either.

---

### D-116 · 2026-08-18 · Task 5.5's boss framework: `Boss extends Enemy` through ordinary overriding rather than editing `enemy.gd`; "arena" ships as a data flag + leash, not geometry; no new §2.2 authority row

Three calls, all made the same session, all downstream of the same fact: `agent claim 5.5` failed on
`systems/enemies/enemy.gd` mid-brief — lane lm had just picked it up for 7.7 (perf/LOD tuning). The
work order is explicit that a failed claim means "stop and drop", but the file wasn't load-bearing for
this task's DESIGN, only for one implementation path — so the actual call was redesigning around it,
not dropping.

**1. `Boss` touches zero lines of `enemy.gd`.** Every hook this task needed — reacting to a health
change, choosing what a TELL/ATTACK/RECOVER cycle's timings are, deciding whether a target is still
held, picking which clip a state plays — was already a plain overridable method (`host_apply_damage()`,
`_enter_tell()`, `_tick_attack()`, `_resolve_attack()`, `_play_state_animation()`,
`_build_synchronizer()`, `_can_perceive()`, `_acquire_target()`) or an inherited member var
(`_target_peer`/`_target_node`/`_sync`/`_anim`). GDScript resolves these virtually regardless of which
class's code calls them, so `Boss` extends every one of them with `super()` and reaches into the
inherited vars directly. **The general lesson, worth recording because it will recur:** a subclass
that needs to change ONE decision inside an existing host-owned state machine rarely needs the base
file touched at all — try overriding before claiming the file every other lane is also reaching for.
The one place this needed a genuine (if small) new mechanism was presentation: `_play_state_animation()`
is where `boss_defeated` is fired from, specifically because that method is already called from
`Enemy.state`'s own replicated setter — see point 3.

**2. "Arena" ships as `BossDef.arena_radius_m` + `BossPhaseDef.seals_arena` — a data flag and a leash
on the boss's OWN acquisition/retention, not a physical wall.** `docs/ASSET_TRACKER.md` A-027 already
lists "arena pylons" as boss-specific visual content for task 5.6, which settles which side of the
framework/content line the geometry sits on — but even setting that aside, procedural collision built
in code (the codebase's usual answer per D-023) was considered and rejected here: it would need
coordinating with `EnemyWorld.bake_navigation()`'s bake-before-spawn ordering for a mechanic nothing
yet needs (no boss encounter exists to actually seal). `seals_arena` exists now so a future boss author
can decide "hold the target regardless of distance this phase" today and wire the visible wall later
without touching `boss.gd` again — the framework's job was the DECISION, not the geometry.

**3. No new §2.2 authority row — same reasoning D-112 gave task 7.8.** `Boss IS an Enemy`; it adds no
state two peers could disagree about that isn't already covered by the existing "Enemies (spawn, AI,
damage): Host" row. `phase`/`move_index` are two more `REPLICATION_MODE_ALWAYS` properties on the same
synchronizer `Enemy._build_synchronizer()` already builds — extended, not replaced, via
`super()` then reading `_sync.replication_config` back out. The one thing worth a second sentence:
`EventBus.boss_engaged`/`boss_phase_changed` fire from `Boss.phase`'s own setter, and `boss_defeated`
fires from `_play_state_animation()` — itself already invoked from `Enemy.state`'s replicated setter —
rather than from a host-only `if _owns_simulation()` guard. `docs/FINDINGS.md` F-168 was the standing
example of getting this wrong (`Wellspring._finish_cap()` emitting `wellspring_capped` from a
host-only guard, undercounting on non-host peers, since fixed) when this was written; this task
applied the D-107/D-108 fix pattern from the start rather than needing a second pass later.

**Would change my mind:** on (1), a THIRD boss-adjacent system needing yet another `enemy.gd` hook
that cannot be reached by overriding would be a real signal to stop and actually claim/edit the base
file rather than keep layering workarounds — one clean subclass is a design, three is a smell. On (2),
the moment a real boss task (5.6+) needs players physically contained (not just the boss itself
leashed), that task owns deciding the mechanism (procedural walls, a POI-authored collision volume,
something else) and should read this decision rather than re-litigate whether arena geometry belongs
in the framework — it was a deliberate cut, not an oversight.

---

### D-117 · 2026-08-18 · F-162's three food viewmodels reuse the shipped pickup GLB instead of commissioning a dedicated first-person export

Every other holdable `ItemDef` (ten A-004 tools/weapons plus A-021S's iron sword) ships a paired
`*_viewmodel.glb` alongside its `*_world.glb` — a second export, posed and framed for first-person
by the Blender pipeline in `docs/ASSET_TRACKER.md`'s 2.1d contract. `mushroom`, `berry` and
`raw_meat` never got that treatment, and `tools/viewmodel_check.gd` requires every non-`RESOURCE`
`ItemDef` to carry a `view_model` (F-162). Two ways to close it: commission a new asset batch through
2.1d (a build script, GLB 2.0 validation, orbit inspection, catalog entry — the same weight as A-004
or A-021S), or reuse the `PackedScene` already set as `world_model`.

**Reuse won.** A-002's 2.1j pass already built these three at true, honest scale for a 1.8 m player
("Legibility by quantity, not inflation" — a handful of berries, a pair of mushroom caps, a cut of
meat, not inflated blobs), so the geometry is exactly what a hand would actually be holding — this
isn't placeholder content, it's the correct content, just never wired into the `view_model` slot. A
dedicated 2.1d batch for three low-severity food items would cost a full Blender build/verify cycle
for a visual delta a reused, already-shipped mesh mostly closes: `grip_offset`/`grip_rotation_degrees`/
`grip_scale` were computed per item from a measured AABB (`tools/_probe_food_grip.gd`, in the shape of
`tools/_probe_lods.gd`), not guessed, and `attack_style = NONE` — same as `short_bow`/`arrow`, the two
existing items with "no meaningful swing arc" — keeps them out of `viewmodel_check.gd`'s bladed-tool
tables. `AGENTS.md`/`CLAUDE.md` bar *bulk-generating* new content; wiring an existing, hand-authored
asset into a second slot with a computed transform is not that.

**Would change my mind:** the moment food items need to visibly change model between raw/cooked/rotten
states, or a boss/enemy needs to see what a player is holding at a distance and the pickup-scale mesh
reads badly there, a dedicated FP-framed export earns its 2.1d batch — this decision only says the
*first* viewmodel for these three doesn't need one. Re-litigate per item if art review (still pending
across A-002, per `ASSET_TRACKER.md`'s review column) flags the reused geometry as reading wrong.

---

### D-118 · 2026-08-19 · F-159's fix lands in `NavBaker` (task 4.5), not `EnemyWorld.bake_navigation()` (the live baker) — a claim conflict, not a preference

F-159 ("placed buildables are invisible to the nav map") is fixable in exactly one of two places: the
per-chunk `NavBaker` task 4.5 shipped, or `EnemyWorld.bake_navigation()`, the single-region full-scene
bake `EnemyWorld` actually runs at session bootstrap and `BuildService._request_nav_rebake()` re-
triggers on every placement/destroy. Only the second one is what a live LOCAL/LAN/Steam session paths
against today — `NavBaker` has no `ChunkStreamer` caller yet (F-139) and is exercised only by its own
check script. Compositing a fix across BOTH files was considered and rejected: Recast carves a hole
around solid geometry by seeing it in the SAME source data as whatever it's carving, so two
independently-baked regions — one from each file — cannot produce that result no matter how they're
layered or which one is "authoritative." The fix has to live entirely inside whichever file owns the
one `parse_source_geometry_data` + `bake_from_source_geometry_data` call for a given piece of ground.

`autoload/enemy_world.gd` was held by another lane (`lp`, task 5.5, boss framework) for this task's
entire session — not stale, actively in flight. **This landed in `NavBaker` instead**, because F-159's
own wording already scopes the fix there ("`world/chunk/nav_baker.gd` bakes navigation from
`ChunkMesher.collision_faces()`... the finding sketches the fix") and names `tools/nav_bake_check.gd`
as the verification path — a scope that does not depend on which system is live yet. The alternative
this decision explicitly rejects: reparenting `BuildService`'s placed-piece container from the
`BuildService` autoload into `get_tree().current_scene` so `EnemyWorld.bake_navigation()`'s existing
`scene_root` walk would pick it up "for free," with no `enemy_world.gd` edit at all. Looks clever, but
`EnemyWorld` itself keeps its OWN spawned content (`_container`/`_spawner`) as a child of the autoload
for the same reason `BuildService` does — an autoload survives a scene reload and its own children do
not need re-parenting after one, while anything hung off `current_scene` gets torn down with it. Moving
only `BuildService`'s container would have coupled its lifecycle to the scene in a way nothing else in
the codebase does, for a session-startup-order gain that saves editing one file this task could not
claim anyway.

**Consequence, tracked as F-177, not silently absorbed:** the live game still has F-159's original bug
until F-139 wires a real `ChunkStreamer`, at which point `EnemyWorld.bake_navigation()` is expected to
retire in `NavBaker`'s favor and F-177 closes for free — the fix is already sitting in `NavBaker`
waiting for a caller.

**Would change my mind:** if F-139 turns out to be scheduled much later than "after 4.7, possibly not
until M4" (its own words), a live-game gap this concrete (agents visibly walking through walls in
actual play) might be worth porting the same signal-based approach into `EnemyWorld.bake_navigation()`
directly rather than waiting on the ChunkStreamer cutover — that is F-177's own "what closes this"
already, not a re-litigation of this call, just a possible reprioritization of it.

### D-119 · 2026-08-19 · F-172's solo seed entry ships as a `--seed=<value>` launch argument, not a boot-gate, and it is not debug-only

Two calls, made together closing F-172 (solo/offline play draws its seed before any menu can open to
stage one — task 6.10's `MainMenu` only ever reaches a hosted session).

**Why a launch argument, not the boot-gate D-110 already reserved.** F-172's own "why not fixed here"
and D-110's own "would change my mind" both point at the same thing: gating world-gen's first
`ensure_seed()` call behind an actual title screen is a task scoped and reviewed on its own, one that
explicitly updates the two-process/`--quit-after N` full-boot check convention to dismiss the gate
first. Treating F-172 as license to build that gate anyway — because it is the "real" fix and F-172
is the finding that named it — would be exactly the mistake D-110 rejected for task 6.10 itself:
relitigating a bigger decision as a side effect of a smaller task. F-172's actual complaint, stripped
of the boot-gate framing, is narrower and already fully addressable: solo players had **no way at
all** to choose a seed. `GameState.set_pending_seed()`/`host_generate_seed()`/`ensure_seed()` (4.6,
6.10) already solve staging and consumption; the only gap was that nothing could call
`set_pending_seed()` before `MireGrid._ready()` on the solo path. A launch argument closes that exact
gap with zero boot-order change: `GameState._apply_launch_seed_arg()`, first line of `_ready()`,
stages it before `MireGrid` (last-but-one vs. last in `[autoload]` order) ever asks.

**Why not debug-only, unlike `core/dev/dev_launch.gd`'s `--host`/`--lan-join=` family.** Those exist
to make a dev's own two-instance testing loop fast and would open an unwanted socket if they ever
shipped live — `dev_launch.gd`'s own header says so explicitly. A seed override carries none of that
risk: it only ever affects world-gen determinism for the process that passed it, the same
`set_pending_seed()` a live client can already call harmlessly from `MainMenu` (its own header notes
a client staging a value affects nothing but that peer's own future host). `autoload/steam_lobby.gd`'s
`STEAM_CONNECT_LOBBY_ARG` already establishes that a retail-build cmdline arg reaching a real autoload
is a normal shape in this project, not something reserved for dev tooling — and Steam's own
"Launch Options" field (Properties → General, on any Steam title, retail included) is the one channel
a solo player can actually use to set this before world-gen ever runs.

**Would change my mind:** a real "gate world-gen behind a start screen" task landing — that task
should route solo seed entry through its own gate (an in-game field, same UX as `MainMenu`'s host
path) and can retire this launch argument or keep it alongside as a power-user shortcut; either is
that task's call, not a reason to hold this one back until it exists.

### D-120 · 2026-08-19 · F-157's display-name registry: sanitize on the host only, allow duplicate names and refuse an ambiguous `peer` resolution rather than guess, ship without a `PROTOCOL_VERSION` bump

D-098 already named the owner (`NetTransport`) and the shape (host-authoritative map, threaded from
`SteamLobby._persona()` in STEAM mode, a new client→host RPC for LOCAL/LAN) — this records the three
calls D-098 left open plus the recurring one it flagged as a precondition.

**1. Sanitize once, on the host, never on the sender.** `_sanitize_display_name()` strips control
characters, trims edges, and caps at 24 characters, and it runs ONLY inside
`NetTransport._host_apply_display_name()`. A client's own submission is never trusted raw — same
stance `_parse_args`'s "the host re-parses the raw line from scratch" already takes for commands
(D-078) and `BuildService` takes for a placement transform (D-034's neighbor). The 24-char cap is a
UI-fit number (a roster line, a kill-feed entry), not a security boundary; there was nothing in
`ARCHITECTURE.md`/`DESIGN.md` to derive a "correct" number from, so this is a judgment call, not a
measurement — easy to raise later if a real name-entry UI wants more room.

**2. Duplicate names are allowed, not deduplicated, and an ambiguous `peer` lookup refuses rather than
picking one.** Rejecting a second player's chosen name because someone else already has it would need
its own UX (a rename prompt, a forced suffix) that nothing asked for and this task has no mandate to
invent. Instead `CommandService._resolve_peer_by_name()` treats two connected peers sharing a name as
a genuine ambiguity and refuses with both candidate ids listed — the same "never guess" stance the
selector grammar's own `@r` (random pick) is the sole deliberate exception to (`docs/COMMANDS.md`
§3.2). A refusal that names the exact peer ids is one keystroke away from working (`op 4821771` instead
of `op Rowan`); a silent wrong pick is not recoverable at all.

**3. Ships without a `PROTOCOL_VERSION` bump — `core/net/net_version.gd` was held by another lane's
claim (`slate17`, task 3.7) for this task's entire session,** the same contention D-102 (task 5.3) and
its two repeats (F-165/F-169) already hit and accepted as a transient risk given this project ships
from one evolving source tree, not staggered binaries. Filed as F-178 to carry the bump forward,
continuing that same chain rather than inventing a fourth differently-worded finding for an
identical root cause.

**Would change my mind:** a real name-entry UI landing and wanting names longer than 24 characters —
raising the cap is a one-constant change, not a design reversal. A future task that wants collision-
proof identifiers (an achievement system, a save file keyed by name) should key on the peer id or a
persistent account id, never on display name — this decision does not make display names unique and
nothing should assume they are.

### D-121 · 2026-08-19 · F-177's fix lands directly in `EnemyWorld.bake_navigation()` as a second parse-and-merge, not a port of `NavBaker`'s per-piece box-tracking approach

D-118 recorded why F-159's fix landed in `NavBaker` instead of the live baker (a claim conflict, not a
preference) and left F-177 as the tracked consequence. With `autoload/enemy_world.gd` free this
session, F-177's own text sketches the port explicitly: "the same signal-based approach
(`piece_placed`/`piece_destroyed` from `BuildService`, folded into
`NavigationMeshSourceGeometryData3D` before the ONE bake call, box faces via the same convention
`NavBaker._box_faces()` establishes) should be ported there directly." This decision is choosing NOT
to do that, and shipping a smaller fix instead.

**Why not the port.** `NavBaker`'s box-tracking exists to solve a problem `EnemyWorld.bake_navigation()`
does not have: `NavBaker` bakes ONE CHUNK at a time, incrementally, as chunks stream in and out, so it
needs to remember every placed piece's `{coord, position, yaw, size}` between bakes to fold the right
subset into each chunk's source geometry — and it needs a `BuildableDef.size`-derived synthetic box
(`_box_faces()`) because it has no scene tree to walk; its terrain source is raw `ChunkMesher` triangle
data, not a `StaticBody3D`. `EnemyWorld.bake_navigation()` does neither of those things: it re-parses
`get_tree().current_scene` from scratch on every single call (session bootstrap, and every debounced
`BuildService._request_nav_rebake()`), full-scene, synchronous, with no per-piece state carried between
calls. Porting the tracking dictionary and the synthetic-box geometry into a baker that already
re-derives everything from the live scene tree on every call would be solving the same problem twice
with two different mechanisms in the same codebase, for no accuracy gain — worse, actually: a
synthetic box reconstructed from `size` describes the same idealized footprint every unauthored piece
gets, where re-parsing the piece's REAL `StaticBody3D`/`CollisionShape3D` (whatever `BuildService.
_generated_piece()` built, or whatever an authored `.tscn` like `ward.tscn` actually contains) is
already sitting right there in the tree, exactly the same way the terrain half of the bake already
reads it.

**What shipped instead.** `bake_navigation()` walks `scene_root` exactly as before (terrain, and
anything else the level itself contains), then makes a SECOND `parse_source_geometry_data()` call
rooted at `/root/BuildService/Buildings` — the placed-piece container, which is a *sibling* of the
level under `/root`, not a descendant of `scene_root`, and was therefore invisible to the walk before
this fix (F-177's actual bug, not a Recast limitation) — into a second
`NavigationMeshSourceGeometryData3D`, then `.merge()`s that into the first before the single
`bake_from_source_geometry_data()` call. Still ONE combined bake pass, same "Recast carves a hole by
seeing everything together" requirement D-118 already established; just two parses feeding it instead
of a tree walk plus a manually-authored triangle buffer.

**Would change my mind:** if `EnemyWorld.bake_navigation()` ever moves off a full-scene reparse
(e.g. picks up its own per-region incremental bake rather than re-baking the whole level on every
placement), the per-piece bookkeeping `NavBaker` already has becomes the right shape again and this
decision should be revisited. Until then, F-139 wiring a live `ChunkStreamer`/`NavBaker` pair is still
what D-118 expected to retire this file outright — this decision does not change that trajectory, it
just makes the interim state (however long F-139 takes) correct rather than merely documented as a
known gap.

### D-122 · 2026-08-19 · A placed chest picks ONE gate (coins or a key), never both — gilded is key-only, bog/strongbox are coin-gated, sunken is neither

F-146 (chest world placement) needed a per-tier `cost_coins`/`locked_by` for every marker
`autoload/chest_placement_service.gd` instances, and `docs/ITEMS.md` §5's "Getting in" column reads
looser than `Chest` can actually express: Strongbox is "~60 coins **or** a Rusted Key", Gilded is
"rare spawn (≈1-2/island) **or** a Gilded Key". `Chest._accept_open_request()` charges
`cost_coins` AND `locked_by` together in ONE transaction (`removals[COIN_ITEM_ID] = price;
removals[locked_by] = 1`) — there is no either/or mode, by design (a single atomic grant-or-nothing
transaction, not a menu of payment options). A placement-time decision has to pick one gate per
instance, and this decision records which:

- **Gilded is key-only** (`cost_coins = 0`, `locked_by = &"gilded_key"`). The item catalog itself is
  unambiguous — `docs/ITEMS.md` line 243: "Gilded Key ... opens the Gilded Chest" — with no mention
  of a coin alternative anywhere outside the chest table's own looser phrasing. Read the "≈1-2/island"
  half of that cell as the RARITY clause and "or a Gilded Key" as the only real gate; there is no coin
  price to fall back to.
- **Bog and strongbox are coin-gated** (25 and 60 respectively, `locked_by = &""`) — the coin half of
  their own "or a key" economy, picked because it needs no key item to already exist in a run before
  the first one can ever open, and because no map content places either tier yet (this task only
  budgeted gilded), so there is no existing instance whose behavior this could contradict. A Rusted
  Key-gated strongbox is a legitimate SECOND instance for whoever places bog/strongbox chests for
  real, not a mode this one instance needs to also support.
- **Sunken is neither** (`cost_coins = 0`, `locked_by = &""`) — `docs/ITEMS.md` §5 calls it
  "risk-priced rather than coin-priced": the hazard of reaching it (Mire border, deep fen, drowned
  cellar) is the price, and `Chest` has no way to charge that. This bridge does not place sunken
  chests at all yet (no hazard-placement pass exists to pick real coordinates), so the table entry is
  a placeholder for whoever adds one.

**Would change my mind:** if `Chest` ever grows a genuine either/or gate (accept EITHER the coins OR
the key, whichever the opener has), a placed instance could offer both again and this table would
collapse to whatever ITEMS.md's column literally says. Nothing today asks for that — the two-gate
column reads as flavor text describing a tier's overall economy, not a mechanic spec, and every
tier this task actually placed (gilded) has an unambiguous single answer once the item catalog's own
key-description line is read as authoritative over the looser table cell.

### D-123 · 2026-08-19 · A Wellspring cap / boss kill grants its loot tier directly into every present player's own inventory — no spawned `Chest`, and one independent roll per player, not one shared roll

F-183 found `wellspring`/`boss` (`docs/ITEMS.md` §5) authored, id-resolvable, and never rolled — a
Wellspring cap and a boss kill are events, not positions, so F-146's marker-bridge placement pattern
(`ChestPlacementService`) does not apply, and the finding itself left two design calls open. Both are
settled here, by `autoload/reward_service.gd`:

- **Direct grant, never a spawned `Chest`.** The finding's own alternative — instance a real `Chest`
  at the trigger's position — needs that node to land at the SAME `NodePath` on every peer, since
  Godot's high-level multiplayer API routes an RPC to a node by matching its path in the scene tree,
  not by creation order or a spawn id. This codebase has exactly two patterns that guarantee that
  today: `MultiplayerSpawner` (enemies/players — the engine's own mechanism) and
  `ChestPlacementService`'s bridge, which works only because every peer builds it from identical
  BOOT-TIME content (the map layout) in the same deterministic pass, so WHEN each peer's own
  `node_added` signal happens to fire never changes WHAT gets built or where. A Wellspring
  cap/boss-kill trigger has neither property — it fires at a real-time moment that depends on
  gameplay and network latency, so two peers building a `Chest` "at the same moment" have no
  guarantee of matching paths without inventing a THIRD synchronization mechanism (e.g. a spawn RPC
  carrying an explicit id) this task has no budget to build and prove. `InventoryService.host_add()`/
  `PowerupService.host_grant()` are already fully networked (each reaches a remote peer through its
  own existing snapshot RPC) and need no new node at all — the same "harvest pattern" seam
  `Chest._accept_open_request()` itself already grants through.
- **One independent roll per present player, not one shared roll split among them.** A world-placed
  chest already means "whoever gets there first loots it; a teammate who arrives after it's open
  gets nothing from that instance." Granting every player present at the trigger their OWN
  independent roll is the closer analogue — an event has no "who got there first," so treating it as
  N simultaneous personal chest-opens (one per player) is more generous and avoids inventing a
  "who deserves the boss loot" arbitration this task was never asked to design. `docs/ITEMS.md`
  §5's "the objective's paycheck" phrasing reads as "what the objective pays," not "one prize split
  N ways."

**Would change my mind:** a future task that builds a general "spawn a networked object outside
`MultiplayerSpawner`/boot-time content" primitive (an explicit host-assigned spawn id broadcast to
every peer, the same idea `MultiplayerSpawner` already automates for scene-tree children) would
remove the NodePath objection above and make a visible reward `Chest` straightforward — worth
revisiting then, especially given `docs/DESIGN.md` §4.4's "a teammate needs to know what you got"
social framing this decision's direct-grant version only serves indirectly (through
`PowerupService`'s existing `net_powerup_counts` broadcast telling every teammate a stack count
changed, not through anything visible in the world). A playtest showing the shared-roll split
matters more than "everyone loots" would also revisit the second call.

### D-124 · 2026-08-19 · Any Blender art family whose contract includes a byte-identical rebuild must not use `mire_art.box()`'s bevel modifier

F-057 left this as "an art-owner call" between two options: drop bevels (byte-stable, but squares off
deliberate chamfers and changes polygon counts) or accept the drift and weaken the contract for that
one family. By the time F-057 actually got fixed, four generators had already independently made the
same call the same way — `build_ward_set.py` first, then `build_flora_set.py`,
`build_construction_set.py` and `build_extraction_ship_set.py`, all four citing F-057 in their own
comments — while `build_crafting_stations.py`, the family that *found* the bug, was the one that had
never applied its own fix. Four independent agents reaching the identical answer without being told
to is what "art-owner call" looks like once it stops being ambiguous; recording it here is so the
fifth, sixth and seventh generator don't have to re-derive it, and so a future PR review has one
place to point at instead of five scattered code comments.

The rule: **a family whose `docs/ASSET_TRACKER.md` row claims (or will claim) a byte-identical
rebuild never passes `bevel=` through to `mire_art.box()`'s live modifier.** Either override `box()`
locally with a bevel-free version (`build_ward_set.py`'s shape — keep the `bevel` parameter so call
sites read unchanged, just ignore it), or don't call `box(..., bevel=...)` at all. `mire_art.box()`
itself keeps the bevel-capable version and its warning docstring, because not every family carries a
byte-identical contract (a hero asset that's hand-tuned once and never proven to rebuild identically
has no reason to give up the chamfer) — this decision governs the ones that do.

F-198 found three `DONE` batches (A-004, A-005, A-006 — `build_tool_weapon_set.py`,
`build_loot_set.py`, `build_enemy_crawler.py`) that still call the live bevel modifier with no
override, despite their own tracker rows already claiming a byte-identical rebuild passed. Not fixed
under this decision — each needs its own rebuild-and-reverify task — but this is the rule that task
should apply, and the reason it's a known, not a newly-discovered, shape of fix.

**Would change my mind:** a future Blender version that makes the bevel modifier itself deterministic
in background mode — this is pinned tooling (D-038), so that would have to be verified on the exact
pinned build, not assumed from a changelog. Until then, the modifier costs a family byte-identical
evidence it can't get back except by not using it.

### D-125 · 2026-08-19 · Tuning gates do not block the roadmap — 2.9's combat gate is dissolved as a blocker

Sequoyah, verbatim: **"Ignore combat gate, tuning can be done at any time don't let it hold things
up."** Said in response to the 2026-08-19 audit ranking 2.9 as "the oldest open debt on the board"
and the first thing to do next.

What changes:

- **2.9 stays on the roadmap as work** — combat feel still gets tuned, and it is still on the
  never-cut list. What it loses is its *gate function*: no task, milestone, or dispatch waits for a
  2.9 verdict. M5's header ("GATE: 2.9 passed ... no second weapon before one feels great") is
  rewritten in `SPECS.md`; enemy types, movesets, bosses and balance proceed on their own schedule.
- **Tuning is continuous parallel work, not a checkpoint.** An agent or director must never present
  a feel-tuning gate as the reason work is deferred, and must not rank one first merely because it
  is old. When Sequoyah plays and has verdicts, they are folded in as ordinary findings/tuning
  passes — whenever that happens.
- **F-036 resolves with this decision.** Its ordering half was fixed long ago (2.9/2.10 swapped);
  its surviving function was "the human gate is still open", and the gate no longer exists as a
  blocker.

What this deliberately does NOT dissolve: the question-answering playtests (2.14's fun check,
3.11's Attunement roles, 4.12's Mire go/no-go, 6.11's long runs). Those exist to answer design
questions, not to tune feel, and only Sequoyah can close them — but note the spirit of this call
reaches them too: work that can proceed without their answers should proceed.

**Would change my mind:** nothing an agent can observe — this is his call about his own process.
If a tuning debt ever demonstrably blocks something technical (e.g. a moveset framework that cannot
be designed without knowing base swing timing), say so in the task, don't resurrect the gate.

### D-126 · 2026-08-19 · Every asset-writer script holds `agent godot`'s own lock for its whole export window — `tools/blender/godot_import_lock.import_cache_guard`, not a narrower per-file fix

F-196: a crafting-station GLB rebuild raced the audit battery's `agent godot` runs, which each force
an import pre-pass (F-093) under `.agent/locks/godot.lock` (F-044). The writer never touched that
lock, so one import pass caught a torn read mid-write, stamped the cache against it, and every later
pass — including the writer's own trailing checks — kept reading "already imported" and skipped: 16
ERROR lines per run for 40 minutes, until a human ran `agent godot --import` by hand.

Two fixes were on the table (F-196's own text): a hash-verify failure ledger inside `agent godot`
itself, or making the *writer* take the same lock. Took the second — it needs no change to
`.agent/bin/agent`, no new ledger state, and it closes the race at its actual source (a writer that
never coordinated at all) rather than making the reader smarter about tolerating torn data it should
never have seen.

**The rule: any script that writes a file under `assets/` Godot imports through `EditorFileSystem`
(a `.glb`, `.png`, `.ogg`, `.wav` — anything with a `.import` sidecar) must wrap its whole write
window in `tools/blender/godot_import_lock.import_cache_guard()`, not just its final write call.**
Holding the lock for the *entire* export — not only a trailing `--import` — is what makes the race
structurally impossible rather than merely less likely: no `agent godot` run can even start a Godot
process while the writer is inside the guard, so nothing can stamp the cache against partial
content in the first place. On release the guard also forces one definitive `agent godot --import`
against the now-finished files, so a check run immediately after a rebuild sees correct assets
rather than depending on some other lane's next check to notice and re-import.

Landed in all 19 existing writers: the 16 `tools/blender/build_*.py` GLB exporters,
`render_item_icons.py` (PNG), and `tools/audio/render_music.py`/`render_sfx.py` (OGG/WAV). A JSON
writer (`tools/mapgen/hollow_layout.py`, `hollowmere_layout.py`) does NOT need this — Godot reads
JSON directly at runtime, never through the import pipeline, so there is no cache to poison.

**Would change my mind:** if `agent godot`'s import pre-pass (F-093) ever moves off `.agent/locks/godot.lock`
onto a different serialization mechanism, every writer needs to follow — `godot_import_lock.py` is
the one place that would need updating, by design (its `GODOT_LOCK`/`GODOT_HOLDER` paths are the only
coupling point). A future writer that forgets to import the guard is a review-time bug, not a design
question — `tools/import_cache_guard_check.py` proves the guard itself works; it cannot prove a new
script remembered to call it.

### D-127 · 2026-08-19 · A check that needs a generator's per-instance placements reads the generator's own already-computed transforms, never `MultiMesh.get_instance_transform()`

F-112: generalizing `tools/hollowmere_check.gd::_check_undergrowth_stays_off_props` for
`tools/world_contract_check.gd` found it reading live `MultiMeshInstance3D`s back with
`get_instance_transform()`, with no `to_global()` and no renderer guard. Two bugs, compounding: the
returned origin is CELL-LOCAL (rebased around each MultiMesh's own centre in
`undergrowth.gd::_emit()`), so `height_at(origin.x, origin.z)` was sampling terrain near world (0,0)
for every plant regardless of where it actually stood; and `MultiMesh` instance transforms live on
the RenderingServer, so the `--headless` dummy renderer this check has always run under
(`agent godot --script`, never `--windowed`) answers every read with identity, no error (F-103,
already documented for production code in `tools/multimesh_readback_check.gd`). The two bugs hid each
other: `worst=0.00 m` every run wasn't the check passing, it was `get_instance_transform()` returning
the same near-origin coordinate for every sample. This check has asserted nothing since it shipped.

**The fix that generalizes, not just patches:** `world/gen/undergrowth.gd`'s new
`sample_ground_gaps()` reads `_placements` — the world-space `Transform3D`s `_scatter()` already
computed before `_emit()` ever rebases them onto a MultiMesh — instead of reading a live
`MultiMeshInstance3D` back at all. This sidesteps F-103 rather than routing around it with
`--windowed` + a `DisplayServer.get_name() == "headless"` skip guard (the pattern
`tools/harvest_batch_check.gd` uses, and what an earlier draft of this fix did): no renderer
dependency, correct under a plain headless run, and one implementation instead of two to keep in
sync — `hollowmere_check.gd`'s function now calls `sample_ground_gaps()` too rather than
re-deriving the same raycast.

**The rule: when a generator already holds the per-instance transforms it placed (a member variable,
a published `meta`), a check reads THAT, never `MultiMesh.get_instance_transform()`.** The MultiMesh
is a render target, not a data store, under this engine's headless mode — F-103 said so for
production code (`EnvironmentVfx`); this extends it to check code, where the failure mode is worse:
production code that reads a MultiMesh back breaks visibly (props at the world origin), but a CHECK
that does the same thing passes green while proving nothing, silently, for as long as nobody thinks
to question a `worst=0.00 m` that never moves.

**Would change my mind:** a generator that has no separate placement record and truly only has the
MultiMesh (nothing here does yet) — then `--windowed` + the `DisplayServer` skip guard is the
fallback, not a violation of this rule.

### D-128 · 2026-08-19 · A Blender preview generator never repositions an object after its process's first render — a second, third… placement gets its own object, placed once, then only ever hidden or shown

F-204 diagnosed the mechanism (`object.location` assigned after `bpy.ops.render.render()` has run
once, in the same `--background` process, never takes effect — only camera moves and `hide_render`
toggles do) and fixed the two generators known to hit it. F-207's sweep then found the identical bug
live in eight more generators, so this is now a recurring authoring trap, not a one-off, and needs a
standing rule rather than a fresh diagnosis every time someone writes a multi-render preview.

**The rule:** if a generator's preview section needs an asset (or a scale-reference cube) to appear
at more than one position across its renders, build **one object per position it will ever occupy**,
all of them before the first `bpy.ops.render.render()` call, and toggle each with `hide_render` —
never write to `object.location`/`.rotation_euler` a second time for an object that has already
appeared in a render.

Two shapes, both landed in `build_gatherable_plants.py`/`build_flora_set.py` as the worked examples:

- **A reference cube (or any fixed prop) needed at N distinct spots across N sheets:** a
  `make_reference(tag, location)` helper, called once per sheet before the render loop, returns a
  hidden cube already sitting where that sheet needs it; the render loop only flips `hide_render`.
- **Specific already-built assets pulled into a tighter "showcase"/"hero" composition, possibly from
  grid positions tens of metres apart:** a `hero_duplicate(record, location)` helper makes a
  linked-mesh-data copy of the asset's single joined export mesh (`record["root"].children[0]`),
  positioned via `dup.matrix_world = Matrix.Translation(delta) @ source.matrix_world` (never `.location`
  alone, since it must survive whatever the source's own local-vs-parent split happens to be) — built
  once, before any render, then hidden until its one shot and hidden again after.

Before reaching for `hero_duplicate`, check whether the composition can be had for free: F-204's
gatherables fix reordered `SPECS` so three states that needed to read left-to-right in a decision shot
were already adjacent on the grid, and the decision shot then only ever moved the CAMERA to frame
their real positions — no duplicate needed. Duplication is for compositions the grid genuinely cannot
produce (assets from different family/category rows, spaced many metres apart).

**Would change my mind:** a Blender version where `bpy.ops.render.render()` re-evaluates the full
depsgraph including moved-object transforms before every call — nothing currently pinned
(`D-038`, Blender 5.2.0 LTS) does this, and F-204's own probe table (camera vs. object vs.
newly-created object) found no in-process workaround. If that ever changes, this rule can relax back
to "just move it," but re-verify with `tools/blender/asset_repro_check.py` plus an actual look at the
rendered PNG before trusting it, the way F-086-shaped "looks done, never checked" failures keep
costing this project.

---

### D-129 · 2026-08-19 · A pre-commit hook that needs "what THIS commit would leave behind" reads git's INDEX, not a synthesized diff-over-HEAD — and it fails OPEN on its own breakage, never closed

F-205 needed `cmd_check` to judge whether an autoload target would resolve after a commit that has no
sha yet. Two calls worth pinning down so a future editor of `cmd_check`/`tools/autoload_tracked_check.py`
doesn't relitigate either:

1. **The revision to check is git's INDEX (`:path`), not a hand-rolled overlay of `git diff --cached`
   onto `HEAD`.** For any tracked path, the index already **is** "staged content if there is any,
   HEAD's otherwise" — that's what an index is. `tools/autoload_tracked_check.py` already builds its
   git paths as `"%s:%s" % (rev, path)`; passing `rev=""` collapses that to `:path` for free, with no
   new diffing logic and no edit to the file's actual checking code. Reach for this same trick before
   writing bespoke "staged-plus-HEAD" logic anywhere else in the harness that needs the same overlay.
2. **A check gate added defensively (catches more than the ownership/claim checks already catch) must
   fail OPEN on its own internal errors, not closed.** `_autoload_tracked_missing()` returns `[]` — no
   missing targets found — if importing or running `autoload_tracked_check` throws. This inverts the
   rest of `cmd_check`'s posture (elsewhere, "never fail open" means an unreadable diff falls back to
   *demanding* a claim, D-031's own comment) on purpose: the claim system is the only thing standing
   between two agents' concurrent edits, so it must refuse when uncertain. The autoload gate is pure
   upside layered on top of F-200's already-shipped after-the-fact check (`--self-test`-verified
   separately) — it is never the sole guard against a bad commit, so a bug in the gate itself must
   never be able to block an unrelated commit. Any future gate added to `cmd_check` should ask which
   category it's in before choosing a failure direction, not copy whichever one is nearest in the
   source.

### D-130 · 2026-08-19 · A cross-asset merge bucket that needs to preserve per-instance runtime behavior declares that behavior's CLASS directly on the holder, never reconstructs it from asset identity — and an emitter class that needs no runtime bookkeeping at all does not get a dedicated bucket

F-203 widened `AuthoredWorld`'s F-187 chunk merge to include emitter-bearing props. Two calls worth
pinning down so a future widening of this merge (the sway case F-208 spun out, or a third prop class
down the line) does not relitigate either:

1. **When several different source assets must merge into one holder but something downstream still
   needs to know a per-instance CLASS (not identity), group the merge itself by that class and
   declare it directly on the holder — never try to recover it from asset identity after the fact.**
   `EnvironmentVfx._register_emitter` infers ONE `AssetVfxLibrary.Emitter` from ONE asset id; a merge
   spanning several different emitter-bearing assets destroys the asset id the moment it bakes their
   geometry together, so there is nothing left to infer from. Bucketing by `(chunk, emitter class)`
   instead of `(chunk)` alone sidesteps the whole problem: every instance feeding one merged mesh
   already agrees on the class, so the holder can just say so (`EnvironmentVfx.EMITTER_META`). This
   generalizes past emitters — any future per-instance behavior a merge needs to preserve should ask
   "can every instance in one bucket already agree on this?" before reaching for a more expensive
   per-vertex or per-sub-range encoding.
2. **Before giving a class the new bucket's metadata machinery, check whether it needs ANY of it.**
   `AssetVfxLibrary.Emitter.GLOW` is documented "emissive material only — no light, no particles, no
   per-instance node," and checked directly, nothing in `EnvironmentVfx` reads a class or a position
   for it. It was excluded from F-187's merge purely because `emitter_for() != NONE`, with no
   distinction for what the class actually costs at runtime — folding it into the existing
   metadata-free bucket instead of the new emitter-class one cost nothing and needed no new code path.
   A future emitter class (or any other per-instance-tagged prop type) should get this same check
   before being assumed to need the expensive treatment its siblings do.

### D-131 · 2026-08-19 · Task 7.6's gamepad rebind covers only JoypadButton-bound actions, never axis/trigger-bound ones — and menu UI focus navigation stays out of scope, resolved to Steam Input's own cursor emulation instead

Two scope calls for gamepad support, made together because D-114 already named both boundaries this
task would have to draw and "decide it, write down why" (AGENTS.md) applies to each.

**Why `JOYPAD_REBINDABLE_ACTIONS` (`SettingsService.rebind_action_joypad()`) excludes every
axis/trigger-bound action** — `move_forward/back/left/right`, `look_left/right/up/down`, `attack`,
`build_destroy` — even though each already carries a gamepad binding. D-114 drew the equivalent line
for KEYBOARD rebind around `attack`'s mouse binding: "a 'press a key to rebind' flow that also has to
handle a different capture UI is a different capture UI, not a checkbox on the same one." The gamepad
capture flow this task ships (`SettingsMenu._finish_rebind_joypad()`) is built the same way —
"wait for the next `InputEventJoypadButton` press" — and that shape has no answer for "which stick"
or "how far to pull a trigger before it counts." A stick pair is also two axes moving together
(`move_forward` shares `JOY_AXIS_LEFT_Y` with `move_back`'s opposite sign), so even a single-axis
capture flow would still need to ask which of two actions the player meant. **Would change my mind:**
an explicit ask for full-stick rebinding (swap which stick drives movement vs. look, useful for players
who prefer left-stick look) — that is a materially different, bigger capture UI (hold a direction,
choose a stick, not just "press a button"), not a quick extension of this one.

**Why menu UI focus navigation (Tab/D-pad moving a highlight between `Button`s, `ui_accept`
"clicking" whatever has it) is explicitly out of this task**, even though `MainMenu`/`SettingsMenu`/
`LobbyMenu`/`InventoryUI`/`CraftingUI`/`ChestUI`/`UnlockMenu` all still require a real mouse click to
open, select, or close. Godot's default `ui_up`/`ui_down`/`ui_accept`/`ui_cancel` actions already
carry joypad D-pad/A-button bindings out of the box, so the wiring for gamepad-driven `Control` focus
exists — what is genuinely missing is every one of those seven menus setting an initial focus,
wiring `focus_neighbor_*`/`focus_next`/`focus_previous` across a mix of `Button`/`OptionButton`/
`HSlider`/drag-and-drop `InventorySlot`s (`ui/inventory/inventory_ui.gd`'s own drag-and-drop
interaction has no keyboard/gamepad equivalent at all today), and giving each a visible focus outline
— a UI-system-wide pass across seven files this task did not open for any other reason, not an
extension of the InputMap work above. On a real Steam Deck this gap is normally invisible: Steam
Input's Desktop/Gamepad-with-mouse-emulation configuration maps a trackpad to a virtual cursor
system-wide, the same mechanism D-013 called "nearly free" Deck support — so a mouse click still
works, it just arrives from a trackpad. Filed as F-209 rather than solved here because it is
genuinely a bare-controller gap (a desktop Xbox controller with no Steam Input translation, or this
project's own `--windowed` dev builds, cannot open these menus at all), not a Deck-specific one, and
fixing it is a UI task, not an input-binding one. **Would change my mind:** a real Steam Deck in
Sequoyah's hands surfacing this as an actual blocker in Desktop mode (not just Gamepad mode, which
Steam Input's own cursor emulation already covers) — that would mean the emulation assumption above
was wrong, not just incomplete.

**Would change my mind:** a class whose "no per-instance node" claim turns out to be aspirational
rather than implemented (checked here for GLOW: `mushroom_cluster`'s Blender material has no
`emission_hex` set, so the effect is currently a no-op end to end — merging it changes nothing
observable either way, today). If GLOW's emissive material is ever actually implemented as a
runtime-applied, per-instance-varying effect rather than a baked asset material, this decision's
premise for it no longer holds and it would need the same class-bucketing treatment CRYSTAL/CAMPFIRE
already get.

### D-132 · 2026-08-19 · Task 8.4 built the Steam build/upload pipeline against placeholder App ID and depot IDs, hard-refusing to run until real ones land; 8.4 owns the tooling, 8.11 owns wiring the real IDs in

Task 8.1 (Steamworks account/tax/banking/$100 fee) and 8.2 (App ID swap) had not run when 8.4 started
— `.agent/state.json` still showed both `todo` — so there was no real App ID or Steamworks depot set
to build against. Two ways to handle that: stub the task out and hand it to Sequoyah once 8.1/8.2
land, or build the pipeline now against named placeholders and make it refuse to run for real until
they're replaced. Chose the second: `tools/steam/steam_build_config.sh` holds `STEAM_APP_ID=480`
(D-008's own dev placeholder) and `STEAM_DEPOT_WINDOWS/MACOS/LINUX=0`, and `steam_upload.sh` checks
for exactly those placeholder values before doing anything else, refusing with a message naming which
task fills them in. This means the whole pipeline — export presets, template rendering, steamcmd
invocation shape — is built, tested (with a fake `steamcmd` stub standing in for the real one, which
no machine in this project has installed yet) and ready the moment 8.2/8.11 supply real values,
instead of being 8.11's problem to build from scratch under a tighter T1 estimate.

**8.4 vs 8.11 split, made explicit because the two task titles overlap ("depots" appears in both):**
8.4 is the pipeline and tooling — release export presets, the `steamcmd` upload script, `.vdf`
templates, the never-publish-to-`default`-without-`STEAM_ALLOW_PUBLIC=1` guard. 8.11 ("three depots
wired to one app, per-platform launch options") is creating the real depots in the Steamworks web
dashboard once the App ID exists, filling their IDs into `steam_build_config.sh`, and setting each
depot's launch options in that same dashboard — neither of which can happen before 8.2, and neither
of which this task fabricated placeholder values for beyond the guard-clause sentinels above.

**The password half of "password-protected beta branch" (STEAM.md S4) has no steamcmd/VDF surface at
all** — it's set once in the Steamworks web dashboard (App Admin → Builds → Steam Pipeline →
Branches) and stays there; `steam_upload.sh` only controls which branch's `SetLive` a given upload
targets, never a password. Documented in the 8.4 SPECS.md block so nobody goes looking for a VDF
field that doesn't exist.

**Would change my mind:** nothing about the placeholder mechanism itself — a real App ID landing is
supposed to make the refusal go away by construction (fill in the config, the guard clause stops
firing). Would reconsider the 8.4/8.11 split if 8.11 turns out to need pipeline changes beyond
config values (e.g. a fourth depot, or a build layout steampipe can't express with this task's
`FileMapping`/`ContentRoot` shape) — that would mean the split drew the line in the wrong place.

**2026-08-19 addendum (task 8.11):** confirmed — 8.1/8.2 still `todo` when 8.11 ran, so the real
depot creation and dashboard launch options this decision assigned to 8.11 stayed genuinely
unreachable, exactly as predicted. 8.11 shipped everything short of that: `tools/steam/DEPOT_SETUP.md`
(the exact dashboard runbook + per-platform launch option values, cross-checked against what
`export_release.sh` builds) and `tools/steam/apply_ids.sh` (writes real IDs into
`steam_build_config.sh` in one command instead of a hand-edit, once they exist). **Whoever resumes
8.11 after 8.2 lands should not redesign this** — follow `DEPOT_SETUP.md` step by step, run
`apply_ids.sh`, then `tools/steam/depot_wiring_check.sh` to confirm the wiring, then a real
`steam_upload.sh`. Full spec: `docs/SPECS.md`'s `## 8.11 ·` block.

**Second 2026-08-19 addendum (8.11 re-dispatched same day):** still blocked, 8.1/8.2 still `todo` —
re-verified `depot_wiring_check.sh`, `tools/roadmap_dependency_check.gd`, and a full headless boot
all clean, no drift since the first pass. One new thing found on the wider sweep: `apply_ids.sh`
only ever writes `steam_build_config.sh`'s copy of the App ID; `core/net/net_config.gd:79` holds an
entirely separate `STEAM_APP_ID` constant (the one `steam_lobby.gd` actually uses at runtime,
`ARCHITECTURE.md` §2.4) that nothing in 8.11's tooling touches. Filed as F-257 and added as
`DEPOT_SETUP.md` step 6 rather than fixed here, since the edit is `core/net/` and belongs to 8.2 by
scope, not 8.11.

### D-133 · 2026-08-19 · F-161/F-165/F-169/F-178's four un-bumped RPCs get ONE retroactive `PROTOCOL_VERSION` bump, not four — and the rule that was missed four times gets a mechanical check, not a fifth reminder

Four tasks (5.3, 6.5, 6.7, F-157) each shipped real new RPCs while `core/net/net_version.gd` and
`tools/handshake_check.gd` sat behind lane slate17's task 3.7 claim for the whole session, so each
filed a finding (F-161, F-165, F-169, F-178) instead of bumping the version — D-100/D-102/D-120
already ratified shipping un-versioned as acceptable transient risk for a project with no
compatibility window (source control, not staggered binaries). By the time a lane finally held
`net_version.gd` free (hollow7, F-161), all four were outstanding at once.

**One bump, not four.** The obvious-looking alternative — number them retroactively, 20/21/22/23 in
task order — would be fiction: versions 20–22 never existed as a build anyone ran, connected to, or
shipped. A version number's only job is telling two real builds apart; minting three that no build
ever carried adds nothing a single "N+1, four RPC sets at once" bump doesn't already say, and invites
a future reader to go looking for what changed *between* 20 and 21 when nothing did. `net_version.gd`'s
own history comments (`## 21 (F-161/F-165/F-169/F-178, one bump for four omissions)`) name all four
RPC sets under the one entry instead.

**The rule itself needed a mechanism, not a fifth writeup.** Four different agents, four different
tasks, hit the identical omission — at that point it stops being a discipline gap and becomes a
missing check. `core/net/rpc_manifest.gd` scans every `@rpc` in game code (excluding `tools/`, whose
own harness RPCs like `handshake_check.gd`'s would otherwise force a version bump for adding a test)
into one canonical `<path>::<func>(<types>)|<config>` signature per RPC, hashes the sorted set
(FNV-1a), and records it alongside the `PROTOCOL_VERSION` it was taken at. `tools/rpc_manifest_check.gd`
fails whenever the scanned signature no longer matches `RECORDED_SIGNATURE`, printing the exact RPC
that changed and a paste-ready re-record block — so a fifth un-bumped RPC is a red check the moment it
ships, not something that waits for someone to notice and file a finding. Proven both directions
empirically before trusting it: adding a probe RPC failed the check and named it; removing it went
green again.

**Would change my mind:** a case where two builds genuinely need to interoperate across a version gap
(e.g. a public beta branch running behind main) — that would mean "N and N+1 interoperate" stops being
a guarantee nobody needs, and retroactive/incremental numbering would start mattering for real. Not
expected before Steam release, and STEAM.md's branch model doesn't describe one today.

### D-134 · 2026-08-19 · `ui_accept`/`ui_cancel` now carry a `JOY_BUTTON_A`/`JOY_BUTTON_B` gamepad binding project-wide — corrects a factual assumption D-131 and F-209 both made

D-131 (task 7.6) and F-209 (filed by that same task) both asserted "Godot's default `ui_up`/`ui_down`/
`ui_accept`/`ui_cancel` actions already carry joypad D-pad/A-button bindings out of the box." Verified
live while fixing F-209 via `InputMap.action_get_events()`: true for the four direction actions (D-pad
buttons 11–14 plus the left stick ship as engine defaults with no `project.godot` entry needed at
all) — **false** for `ui_accept`/`ui_cancel` in Godot 4.7.1, which ship with only Enter/Kp Enter/Space
and Escape respectively, no joypad event at all. Every `focus_neighbor_*` chain F-209 wired would have
been reachable by D-pad but nothing on it activatable or cancelable by a bare controller without this.

Fixed by adding one `JOY_BUTTON_A` event to `ui_accept` and one `JOY_BUTTON_B` event to `ui_cancel` in
`project.godot`'s `[input]` section (via `tools/bind_ui_gamepad_actions.gd`, a one-shot idempotent
script — reads each action's current event list through `InputMap.action_get_events()`, appends the
joypad event, writes back through `ProjectSettings.set_setting()` + `.save()`), preserving every
existing keyboard event rather than replacing them. **The call others must not relitigate:** treat
`ui_accept`/`ui_cancel` as already gamepad-bound project-wide from here on — do not re-add a joypad
event to either (the script is idempotent and no-ops if one is already present, but a hand-edit that
skips checking `InputMap.action_get_events()` first could silently duplicate it), and do not assume,
the way D-131/F-209 did, that any other built-in `ui_*` action already carries a joypad binding
without checking live — the four direction actions do, these two did not, and that split was not
something either agent verified before writing it down.

`JOY_BUTTON_A` is already bound to this project's own `jump` action (task 7.6). That overlap is inert:
a blocking UI panel owns GUI focus, so the Viewport's focused-`Control` `gui_input` consumes the event
before it ever reaches `_unhandled_input`, the same reason clicking a menu button has never also fired
`jump`. Not a new interaction this decision introduces.

**Would change my mind:** a future Godot upgrade changing the engine's own `ui_accept`/`ui_cancel`
defaults to include a joypad binding — at that point `project.godot`'s override becomes redundant
(harmless, since it would specify the same event) rather than load-bearing, and could be pruned.

### D-135 · 2026-08-19 · A reversal trigger that fired but is still the right call gets silenced with `*Reviewed <date> — <why>.*`, not by editing the reasoning
F-218: every decision here ends with a **Would change my mind:** clause, and nothing ever re-checked
whether one had fired — D-011's and D-041's both had, unnoticed, before agents tripped over the
consequences by accident. `tools/decision_trigger_check.py` (F-218) now checks mechanically for the
subset of triggers that name a concrete file or symbol, but a check that runs repeatedly needs a way
to mark a fired trigger as reviewed, or it re-flags the same decision on every future run forever.
This file's own preamble permits exactly one retro-edit — a one-line `*Superseded by D-0NN.*` pointer
— for a decision whose call actually changed. That doesn't fit a trigger that fired and the call is
*still right*: nothing was superseded, so writing a new entry would be a decision about nothing. The
one-line marker convention already in practical use for that shape (`*Amended by D-031.*`, D-012)
extends naturally: `*Reviewed <date> — <why the fired trigger doesn't change the call>.*`, right under
the heading, same place the other markers live. It never touches the reasoning body — append-only
stays append-only — it only records that someone looked. `tools/decision_trigger_check.py` treats it
identically to `Superseded by`/`Amended by`: present, skip; absent, keep flagging.
**Would change my mind:** this convention getting used to paper over a trigger that actually *should*
supersede the decision — a `*Reviewed*` note that doesn't explain why the fired evidence still leaves
the original call standing is worth challenging on sight, the same as a `*Superseded by*` pointer with
no real successor entry would be.

### D-136 · 2026-08-19 · An event-triggered loot roll with no placement id seeds from a monotonic per-run trigger counter, combined with the receiving peer's id — reset on `GameState.seed_ready`

F-219: `RewardService._grant_tier_to_party()` needed D-041/F-210's `(run_seed, stable id)` seeding
fix, but `Chest`'s stable id (its own node `name`, authored by `ChestPlacementService` before
`add_child()`) has no equivalent here — a Wellspring cap or boss kill is a moment in time, not a
placed object with a name. Two candidates existed: hash something about the trigger itself (a
`Wellspring`'s node name, an enemy's instance id) or mint a counter. The trigger-identity route was
rejected — a `Wellspring` and a `Boss` are two different classes with no shared identity scheme today,
and a boss respawns/re-instantiates in a way a placed `Chest` marker never does, so "the boss's own
id" is not actually stable across a run the way "the chest's own name" is. **Decided: a monotonic
`_next_reward_event_id`, incremented once per trigger (never per peer — two caps in one run must not
roll the same), reset to 1 on `GameState.seed_ready`.** That signal is the closest thing this codebase
has to "a run has begun" on every peer, host and client alike (`autoload/salvage_service.gd` already
resets its own per-run milestone tally there) — without the reset, a deliberate same-seed replay
(F-172's seed entry, a bug-repro `--seed=` launch) started fresh would still diverge from an earlier
run that happened to fire a different NUMBER of reward events before the point being compared.

The receiving peer's id is mixed into the same seed alongside the counter and the tier
(`_seed_for_run(run_seed, "%s:%d:%d" % [tier, event_id, peer_id])`) so that the party's `N`
independent-but-simultaneous rolls from one trigger never collide with each other, and the tier keeps
a wellspring-tier and boss-tier roll from colliding if their counters ever line up. This is the
general shape any future event-triggered (not placement-triggered) host roll should copy: a per-run
counter reset on `seed_ready`, salted per file same as `Chest`/`RewardService` already are, is the
answer whenever there is a trigger but no marker.

**Would change my mind:** a future system where the SAME trigger can legitimately fire more than once
per frame/tick in a way that needs sub-tick ordering the counter alone can't express — none does today
(`_grant_tier_to_party` runs synchronously to completion before the next `EventBus` emission is even
possible), but a batched/queued trigger path would need a tie-breaker beyond call order.

### D-137 · 2026-08-19 · `rpc_manifest_check.gd`'s own rule — a signature that moves without `PROTOCOL_VERSION` moving is the mistake it exists to catch — has exactly one legitimate exception: correcting a signature that was never validly produced in the first place

F-213: `RpcManifest.signature()`'s FNV-1a offset-basis literal overflowed GDScript's signed int64
parser (`0xCBF29CE484222325` is 14695981039346656037 unsigned, past the 9223372036854775807 signed
max), so `hex_to_int` failed on every single run since the manifest was created in the same commit
that introduced `PROTOCOL_VERSION` 21 — there is no earlier commit where this file's `scan()` ever
successfully executed. `RECORDED_SIGNATURE` was therefore never actually produced by running the
tool; it was pasted in by hand or from an external re-implementation at recording time, and it is not
a value the check's own documented process (re-run, paste the printed block) could ever have
generated.

Fixing the overflow (rewriting the literal as its signed two's-complement equivalent,
`-3750763034362895579`) changed `signature()`'s computed output, because the seed itself was wrong
before. Entry count stayed at 55 and every known RPC was still found — the wire surface did not move,
only the correctness of the hash of it did. **Decided: re-record `RECORDED_SIGNATURE` alone, leave
`RECORDED_PROTOCOL_VERSION` at 21.** Bumping `PROTOCOL_VERSION` here would be the actual lie — it
would tell every future build that the wire changed on 2026-08-19 when nothing about any RPC did.

This is not a loophole for casual re-recording: `rpc_manifest_check.gd`'s assertion that a moved
signature demands a version bump stays the default and correct read for every other case. It gives
way only when the recorded value provably could not have come from a real run of the tool — provable
here because the file's entire git history is one commit, and that commit is the one this same
overflow bug has poisoned since day one.

**Would change my mind:** discovering a commit where `rpc_manifest_check.gd` genuinely ran clean and
produced `"621c8ba008c3520f"` under a since-reverted version of the seed constant — that would make
the old value a legitimate prior recording superseded by a real (if inadvertent) wire-adjacent change,
not a correction, and the normal version-bump rule would apply instead.

### D-138 · 2026-08-19 · D-128's "never take effect" was too broad — an existing object CAN be safely repositioned between a Blender preview generator's renders, but only when something else between the two calls forces Blender to re-evaluate the depsgraph, and nothing in the pipeline guarantees that on purpose

*Narrows D-128, does not repeal it.* F-207 was filed as a mechanical `grep` sweep — the same
`record["root"].location = ` pattern F-204 diagnosed as broken, found live in eight more generators —
and D-128 generalized F-204's diagnosis into a standing rule: never write an already-rendered object's
`.location`/`.rotation_euler` a second time in one process. Closing F-207 required actually rebuilding
all eight generators and inspecting the previously-flagged PNGs (`tools/blender/asset_repro_check.py`
only checks geometry, never pixels — the same gap F-204 named). None of the nine flagged renders were
actually broken. Confirmed by disabling each reposition line in a throwaway copy and diffing the
rendered output against the real script: every one produced a materially different (correctly
scattered/off-frame) image, proving the real script's reposition **did** take effect.

**What actually determines whether a reposition takes effect, empirically (Blender 5.2.0 LTS,
`--background`, this repo's exact generators):**

1. **An object that has never yet appeared in any render this process has made** (`hide_render=True`
   through every prior `bpy.ops.render.render()` call) picks up a location/rotation assigned right
   before its first appearance correctly, no matter how late in the process that assignment happens.
   `build_tool_weapon_set.py`'s viewmodel render is this case: those records sit hidden through the
   world-preview render, then get shown, repositioned and rotated for the very next render — and it
   renders exactly as authored.
2. **Repositioning an object that HAS already appeared in a render is unreliable BY DEFAULT** — this
   is F-204's real, still-correct finding, reproduced verbatim by rebuilding the pre-fix
   `build_gatherable_plants.py` from `2330435^` under today's Blender: the reference cube froze at
   its first sheet's transform on the second sheet, exactly as originally diagnosed.
3. **...UNLESS something else runs between the reposition and the render that forces Blender to
   re-evaluate the scene.** Every one of the eight generators F-207 flagged does exactly this by
   accident: `build_crafting_stations.py`, `build_harvestable_resources.py`,
   `build_wellspring_set.py` (via `add_scale_reference`), `build_loot_set.py`, `build_ward_set.py`
   (via `add_scale_reference`), `build_enemy_crawler.py`, and `build_tool_weapon_set.py`'s showcase
   render all create brand-new mesh objects (`ico()`/`cone()`/`box()`/`cylinder_between()`, all
   `bpy.ops.mesh.primitive_*_add` underneath) for a scale reference AFTER the reposition and BEFORE
   the render — and that object creation is enough to un-stale every OTHER object's pending transform
   too, not just the new one's. `build_mire_map_kit.py`'s hero shot creates no new geometry but does
   change `camera.data.type` from `ORTHO` to `PERSP` right before its render, which empirically has
   the same unsticking effect. Confirmed for both mechanisms by re-running each generator with its
   reposition line replaced with `pass` and diffing against the real output.

**Why this stays a narrowing, not a reversal of D-128's rule:** nothing above is a documented Blender
guarantee — it is an accidental side effect of unrelated code (a scale prop's construction, a camera
mode flip) that happens to force a full depsgraph refresh in this Blender build. Reordering or
deleting that incidental code — e.g. "simplifying" a showcase render by dropping its scale reference,
or reusing one `camera.data` block across two different-typed cameras — would silently reintroduce
F-204's exact bug with no check to catch it (geometry checks don't look at pixels, and none of these
eight files even have one). **D-128's authoring rule remains the correct one to follow when WRITING a
new multi-render generator:** build one object per position before the first render, hide/show it,
never reposition an existing rendered object on purpose. This decision only means an agent auditing an
*existing* generator for this bug must rebuild and look at the actual pixels — matching the
composition the code clearly intends — before assuming a `.location =` between two `render()` calls is
broken. Filed as F-222 for the follow-up: harden the eight now-accidentally-correct renders with
`make_reference`/`hero_duplicate` so correctness stops depending on an unrelated object happening to
get created nearby.

**Would change my mind:** discovering Blender's actual trigger for the depsgraph refresh (still
unknown — candidate is any `bpy.ops` call that internally touches `view_layer.update()` or rebuilds
the operator's undo state, but `view_layer.update()` called directly was already ruled out by F-204's
own probe table) — that would turn this from "an accident we've verified nine instances of" into a
documented mechanism a generator could rely on rather than merely observing after the fact.

---

### D-139 · 2026-08-19 · Corrects D-083: a `Harvestable` depletion-memory restore is a full state
seam of its own, `host_restore_depleted()`, not a replayed `host_apply_damage()` hit

*Narrows D-083, does not repeal it.* D-083 was right that a direct poke at `Harvestable.active` is
wrong — `active` alone skips arming the respawn clock (`_respawn_remaining`), so a freshly-restored
point immediately auto-respawned on the next physics tick, and that failure mode is real and stays
fixed. Where D-083 went wrong was the specific mechanism it picked to fix it: replaying a full
`host_apply_damage()` hit reaches the right `active`/`_respawn_remaining` state, but `damage`-to-zero
is not a silent state setter — it is the exact seam a real player swing uses, so reaching 0 health
through it also runs `Harvestable._deplete()`'s `depleted.emit()` and
`EVENT_BUS.emit_harvest_yielded()` in full. `InventoryService` subscribes to that event and
unconditionally grants the yield, so every rebuild of an already-harvested `ResourceScatterField`
point (leaving and re-entering the LOD0/collision ring — an ordinary, trivially repeatable player
action, not an edge case) paid the host a second, unearned copy of the item. Filed and reproduced as
F-231; `tools/resource_scatter_check.gd`'s own lifecycle section had exercised this exact path since
4.4 and never noticed, because it only asserted `active == false` after rebuild, never that no new
yield fired.

**The fix keeps D-083's actual insight — restore the WHOLE state, not just `active` — while dropping
the part that was never a requirement:** `systems/harvesting/harvestable.gd` gained
`host_restore_depleted()`, a host-only method that reaches the identical final state
`host_apply_damage()` reaching 0 health does (`health` zeroed, `active` off, `_respawn_remaining`
armed at `respawn_seconds`) without emitting `depleted` or `EVENT_BUS.emit_harvest_yielded()`. It
keeps the one property of the damage seam actually worth keeping — the method family's own
host/offline-only gate, so a real client's call still quietly no-ops — without the yield side effect
a memory replay never earned. `world/gen/resource_scatter_field.gd`'s `_wire_point_state()` now calls
this instead of `host_apply_damage()`.

**The general rule this leaves for the next "restore remembered state" seam:** never replay a
mutation-with-side-effects method (anything that also fires an event another system reacts to) purely
to reach that method's STATE outcome. Either factor the state change into its own method first, or —
if state and side effect are inseparable in the existing seam — that is itself a sign the seam needs
splitting before a second caller with different intent (remembering vs. reporting) reuses it.

**Would change my mind:** a future host-authoritative replay case where the side effect genuinely
SHOULD refire (e.g. a session-resume path that intentionally wants clients to re-see a "this point was
just harvested" event) — that caller should still not reach for `host_apply_damage()` directly, but it
would be a real vote for a THIRD explicit method (`host_replay_depletion_event()` or similar) rather
than evidence this decision was wrong.

---

### D-140 · 2026-08-19 · A HOST-scope command handler with an IMPLICIT actor (no `peer`/`selector`
arg) must read `ctx.peer_id`, never a local-actor entry point like `_local_peer_id()`

F-228: `_cmd_craft`/`_cmd_build`/`_cmd_demolish` all called `request_craft()`/`request_place()`/
`request_destroy()` — the exact entry points the crafting UI, the placement ghost, and the demolish
tool call on their OWN local process, where resolving the actor via `_local_peer_id()` is correct
because those callers only ever run as the actor's own local call. A `CommandService` HOST-scope
handler is not that: `execute()`/`_execute_locally()` (`autoload/command_service.gd`) only ever call a
HOST-scope handler ON THE HOST process — the host's own console typing it directly, or a non-host
op's line re-entering via `net_submit_command`, re-parsed and re-executed on the host too
(COMMANDS.md's "host re-parses the raw line from scratch" design). So `_local_peer_id()` read inside
such a handler is ALWAYS the host's own id, never the actual issuer, and a non-host op's `craft`/
`build`/`demolish` silently mutated the host's own inventory/build ledger — worse, the confirmation
never even reached the real issuer, because `_confirm_peer()`/`_answer()` also gate the RPC-back on
`peer_id == _local_peer_id()`, which was already the wrong value by the time it got there.

**The rule for the next implicit-actor HOST-scope command:** read the actor off `ctx.peer_id` (which
`command_service.gd`'s `_build_ctx()` populates correctly for both the local and the re-executed-RPC
case — `multiplayer.get_remote_sender_id()` for the latter) and call the owning service's
`_process_*`/host-side seam DIRECTLY with that id, never through an entry point whose OTHER caller is
the actor's own local UI/tool. `give`/`loadout` (`core/dev/dev_loadout.gd`) and `inv`/`loot`
(`autoload/inventory_service.gd`, via `_resolve_peer(ctx, args)`) already get this right — they were
written against `ctx.peer_id` from the start, never against a local-actor helper, so they are the
worked reference for what a new implicit-actor command should copy. A command that instead takes an
explicit `peer`/`selector` argument (`kill`, `tp`, `heal`, `powerup give <peer>`, ...) never has this
failure mode — the actor is already a parsed argument, not something the handler has to infer.

**Would change my mind:** nothing found so far contradicts this — every HOST-scope handler in the
repo was swept (F-228's own close-out) and the two shapes (explicit target arg vs. `ctx.peer_id`) are
exhaustive for "who does this command act on." A future command type that legitimately needs a THIRD
shape (e.g. "the target is neither the issuer nor a parsed argument, but derived from world state")
would be the first real counter-example, and should get its own decision rather than stretching this
one.

### D-141 · 2026-08-19 · Host RPC rate limiting: a flat per-peer min-interval gate, applied only where the audit proved real per-request cost — not a token bucket, not blanket-applied everywhere

F-232's hostile-client audit found exactly two `@rpc("any_peer")` handlers doing unbounded real work
per call with no existing throttle (`BuildService.net_request_place`'s physics overlap query,
`CommandService.net_submit_command`'s entity-tree scan on `entities`/`tp`/`kill`/`tag`). Fixed both
with `core/net/rpc_rate_limiter.gd` — `RpcRateLimiter.allow(peer_id, min_interval_msec) -> bool`, a
per-peer "reject if less than N ms since your last allowed call" gate, `Time.get_ticks_msec()`-keyed,
no burst allowance and no decay curve.

**Why a flat min-interval, not a token bucket:** every handler already re-derives and re-validates
everything about a request from host-side state (F-232's own audit result) — the limiter's only job is
capping HOW OFTEN a peer may ask, not deciding whether an individual ask is valid. A token bucket would
let a peer save up idle time and spend it as a burst, which buys nothing here: nothing about this
project's request shapes benefits from bursting (a player does not queue up ten builds to fire at
once), and a flat gate is one field and one comparison instead of a refill-rate/capacity pair to tune.

**Why only the two proven handlers, not every `@rpc("any_peer")` in the project:** the audit read every
one (docs/SPECS.md's F-232 block lists them) and found the rest already do O(1) work per call — a
`Dictionary.has()`, a squared-distance check, a bounds-checked array write — or are already self-
limited by an in-flight guard (`CombatService`/`RangedCombatService`'s one-swing/one-shot-at-a-time
lock). Wiring a limiter onto a handler with no proven cost is hardening against a threat the audit
never found, and F-232's own filed history (F-228, F-230, F-231 — each a real, demonstrated bug, not a
defensive pass) is the house style this project has been running: fix what an audit proves, name what
it did not, and let the next real finding pick the next target — F-233 names the swept-but-unfixed
handlers explicitly so a future task does not have to re-derive the list.

**Would change my mind:** a future finding demonstrating a genuine exploit against one of the handlers
F-233 lists (their current O(1) cost turning out to compound in a way this audit missed), or a
gameplay pattern that legitimately needs to burst requests (making a flat gate the wrong shape, not
just an untuned one).

### D-142 · 2026-08-19 · The procedural terrain method: keep the fBm+falloff base, add domain warp + a masked ridged layer + per-biome amplitude tables + one carved river; erosion enters only through a determinism-gated spike

Chosen after surveying the procedural-terrain education canon (Lague's landmass/erosion series,
Kniberg's Minecraft density/spline material, Patel's polygonal maps, terrain-erosion-3-ways, the
academic survey, Valheim's derive-everything-from-one-seed architecture) against MIRE's five hard
constraints — cross-platform determinism (D-017/D-028), the worst-computers target, a bounded
~200 m island, Mire-grid compatibility, and POI-first pacing. Full survey with per-technique
verdicts and sources: `docs/WORLDGEN.md` §1.

The one-line form: **the smallest diff from the measured, shipped 4.1–4.7 stack that reproduces
Hollowmere's hand-authored virtues as procedural guarantees.** Domain warp and ridged layers are
FastNoiseLite-native (same trusted library, integer-seeded); the river is steepest-descent tracing
plus arithmetic carving; POI ground-flattening keeps 4.7 in charge of pacing. Rejected outright:
Voronoi re-architecture (discards a measured stack for the same output class), 3D density/caves
(2D Mire grid, low-end target, cut list), WFC (solves a variety problem we don't have).

**Erosion is the one seduction, and it is gated, not adopted.** A bounded island makes a one-time
seeded droplet pass affordable, but iterative float accumulation is exactly where platforms drift.
4.17's spike extends `tools/check_determinism.gd` and compares hashes on the D-028 Windows machine:
hash-equal adopts it, anything else rejects it permanently.

**Every new generator operation lands in the determinism probe in the same task that adds it.**

**Would change my mind:** the island-feel walk (4.18) reading warped-noise islands as *less*
legible than Hollowmere; or the erosion spike coming back hash-equal AND cheap, which upgrades it
from rejected-by-default to the standard pass.

### D-143 · 2026-08-19 · The cutover composes, it does not rewrite: one ProceduralWorld node emits the marker contract; flag first, parity second, default last

The 2026-08-19 audit established that **the map contract is the marker-group protocol** — every
world service (Wellspring, Extraction, ChestPlacement, Crafting, EnemyWorld) discovers its sites by
scanning `authored_world_marker` for a `kind` meta, plus the `authored_world_terrain`/
`_harvestable` groups. So procedural cutover = one composer node (`world/gen/procedural_world.gd`,
task 4.15) that instantiates the shipped pieces (ChunkStreamer, ResourceScatterField, NavBaker,
PoiMap) and **publishes the same markers**; services light up unchanged. `PoiDef` gains
`marker_kind` so content stays in charge of what a POI *is* to the services.

Rollout in that order: behind `DevLaunch --procedural` (nothing a player runs changes), then
map-contract parity (`world_contract_check` runs BOTH maps; F-112 folds in), then Sequoyah's
three-seed feel walk (schedules tuning, gates nothing — D-125), then the default main-scene swap
with Hollowmere retiring to fixture/reference — the same retirement Playtest Hollow went through.

**Would change my mind:** a service whose site discovery genuinely cannot express itself as a
marker kind (none known — even stations fit); that would argue for a real WorldContract interface,
a much bigger change than any current need justifies.

### D-180 · 2026-08-19 · Keep file claims; fix claim STALENESS instead of moving to per-agent worktrees
*Renumbered from a duplicated `D-144` by F-283 — this entry and the `D-144` above were allocated the same number before the `agent decision` allocator existed (D-182). A pre-2026-08-20 citation of `D-144` that is about the subject below means this entry.*
F-189 correctly reported that D-011's own reversal trigger — *"agents working concurrently often
enough that file claims become a bottleneck"* — has fired repeatedly: one hold on
`core/net/net_version.gd` spanned four sessions and cost four tasks their `PROTOCOL_VERSION` bump
(F-161/F-165/F-169/F-178), and a twelve-file hold blocked three queued items for six hours. Reading
that as "claims were the wrong choice" is the wrong inference. In every measured case the blockage
was a claim that **outlived the session holding it**, not two agents genuinely needing one file at
once; when those sessions ended, the claims cleared in bulk and the backlog drained in minutes.

Moving to per-agent git worktrees would trade a transient, visible bottleneck for a permanent,
expensive one: every agent needs its own `.godot/` import cache — the 42 MB artifact whose sharing
F-196 has just made structurally safe (D-126) and whose full rebuild costs minutes per agent. It
would also reintroduce merge conflicts in place of claim refusals, and the git-side hazards that made
sharing painful (F-081, F-117, F-149, F-191, F-197) are now all closed and regression-tested.

So: claims stay. What changes is that a refusal now reports how long the claim has been held and
whether its file has been written to since, so a director can distinguish "someone is mid-edit" from
"someone left four hours ago" — the judgement that was impossible before, when both rendered as the
same `claimed by X` line. It deliberately frees nothing: another agent's uncommitted work sits in the
shared tree, and the rule against working around a claim is what keeps two agents out of one file.

**Would change my mind:** a measured case of two agents needing the same file *simultaneously* rather
than sequentially, or claim contention persisting after the staleness signal exists — either would
mean the bottleneck is real concurrency rather than abandoned sessions, and worktrees become worth
their import-cache cost.

### D-145 · 2026-08-19 · Lane routing is a single seat: only the director may `order`, `dispatch` or `saturate`
Every session on this repo can reach `.agent/bin/agent`, and for a while every session used it. Over
one long day six work orders arrived in lane queues that the director had not written (F-132, F-057,
F-158, 6.8, 6.3, F-236). None of them were wrong as work, and nothing was corrupted — the cost was
subtler. The director's picture of what a lane would do next stopped being reliable, which produced a
duplicate dispatch when a task was reassigned between lanes while another chain still held it queued,
and an order aimed at a finding a peer chat had already started, which would have burned a dispatch
discovering the collision.

Routing is now one seat, enforced rather than requested: `agent order`/`dispatch`/`saturate` refuse
any agent that is not the director and name who is. `agent director` shows the seat, `--take` claims
it, `--clear` releases it. Nothing else changes — peer sessions claim files, work, and close out
exactly as before.

The reasoning is the same one behind file claims. A coordination surface with shared write access
makes every read of it a guess, and the director's entire output is judgement about what came back.
A task agent that spots work worth doing files a finding; the director picks it up from there. That is
the whole interface.

**Would change my mind:** a second orchestrator with a genuinely separate lane pool and no shared
queue — at which point the seat should be per-pool rather than global, not abolished.

### D-146 · 2026-08-19 · Task 6.3 ships six Cycle Modifiers, not the roadmap's 20–30, and none of the six are tagged incompatible with each other
The roadmap line for 6.3 reads "Author 20–30 Cycle Modifier `.tres` files," but AGENTS.md's
never-bulk-generate rule (and this task's own work order, more bluntly) overrides a roadmap number
whenever the two conflict: content is authored one asset at a time with a real design decision behind
each, not spun out to hit a count. Six modifiers that each change what a run's priorities are
(`drought`, `tithe`, `static`, `rooted`, `bloom`, `the_hunt` — see `docs/SPECS.md` §6.3 for what each
does and why) are worth more than twenty that vary a number, and the roadmap's remaining 14–24 are
left for a later task rather than padded out here.

`min_cycle` staggering is the other call worth recording so nobody re-derives it: all six sit at
`min_cycle >= 3`, which leaves Cycle 2 drawing `long_night` alone exactly as 6.2 authored it — that
was deliberate, not incidental, so this task's `tools/cycle_modifier_check.gd` rewrite could keep
6.2's own `_check_real_draw_via_cycle_advance()` assertion unmodified rather than making every future
modifier's `min_cycle` a decision that also has to dodge Cycle 2. `the_hunt` (an elite that tracks
whoever has the most powerups) sits latest at `min_cycle = 6` because the modifier needs a run where
someone has actually pulled ahead to have a real target — DESIGN.md Q7's "unfair before Cycle 7" risk
this task's own work order named.

No `incompatible_tags`/`incompatible_with` pairs were authored among the six. Q7's stacking worry is
about modifiers compounding the *same* axis into "unfair nonsense" — these six were deliberately
picked to each land on a different system (harvesting yield, Wellspring presence, chest loot, mire
recession, enemy death, enemy targeting), so none of them share an axis close enough to need an
exclusion. Each still carries a `tags` entry (`scarcity`/`wellspring`/`loot`/`mire`/`enemies`×2) so a
future modifier that DOES compound with one of these can declare the exclusion unilaterally, the same
"either author declares it once" symmetry D-103 already established — this task simply had nothing on
either side of a real conflict yet.

**Would change my mind:** a playtest surfacing a specific pair from this six (or a future one against
it) that is fun alone but breaks together — at which point the fix is one `incompatible_tags` entry
on whichever modifier is added later, not a retroactive redesign of these six.

### D-147 · 2026-08-19 · F-240's fix is a lunge during the TELL, not a position sampled at tell START

F-240 named two candidate fixes for "a telegraphed attack's reach and tell length cannot deny 'just
take one step back'": either the enemy closes ground during its own TELL/ATTACK span, or the hit
samples the target's position at tell **START** rather than tell **END**. This task built the first
and rejected the second, deliberately.

Sampling at tell start would make the hit connect against wherever the target stood when the
telegraph began, regardless of anything the enemy's own model does between then and the swing. 2.9's
whole hit-reaction and telegraph system stands on `state`/position being the truth the client renders
— an enemy standing fully still (per its replicated `state`/`position`) that still lands a hit on a
player who visibly created distance would read as a phantom hit, not a dodge that failed. That is
the opposite of DESIGN.md §6's "readable telegraph": the player would have done everything right and
lost anyway, with the game giving no visual reason why.

A lunge keeps the causality honest: the enemy's own replicated position visibly closes the gap, so a
player who gets hit was actually caught, not penalized for a decision the game made before they even
started moving. `Enemy._resolve_attack()` is untouched — the hit still resolves at the tell's END
against the target's THEN-current position, exactly as 2.10/5.1 built it; only whether the enemy
itself moved during the tell is new. `EnemyDef.lunge_speed_m_s` defaults to `0.0`, so every shipped
`EnemyDef` keeps the fully-stationary tell bit-for-bit — this is a framework tool for a future kind
to opt into, not a change to any authored content (`tools/enemy_lunge_check.gd`'s last scenario
confirms `crawler`/`tusker`/`strider`/`broodcaller` all still default to it).

**Would change my mind:** a playtest establishing that a start-sampled "always lands, however you
dodge" attack reads as fair for some specific enemy identity (e.g. an unavoidable ground-slam whose
tell is itself the dodge window, not the swing) — at which point that is a second, additively-named
field (e.g. `commits_to_start_position: bool`), not a replacement for this one.

### D-148 · 2026-08-19 · Task 8.3's achievements/stats/rich presence: ten hand-picked achievements not ~20, Steam is never eagerly initialised by these new autoloads, and presence has no "in the menu" state

Three calls, made together, the same "decide it, write down why" shape D-110 already used for a set
of small calls in one task.

**Why ten achievements, not the ~20 `docs/STEAM.md` §S4 names as an aim.** D-146 already set this
precedent for content in this exact shape ("Task 6.3 ships six Cycle Modifiers, not the roadmap's
20-30, and none of the six are tagged incompatible with each other") — a bulk sweep produces a whole
family of uniformly mediocre entries, which is worse than fewer that are each tied to a milestone
that genuinely fires in the shipped game today. `autoload/steam_stats.gd`'s `ALL_ACHIEVEMENTS` is the
ten: first extraction, first Wellspring capped, first boss defeated, the ship repaired, Cycle 5/10/15
reached, 500/2000 lifetime Salvage banked, first unlock purchased. **Would change my mind:** a real
playtest surfacing specific moments worth celebrating that these ten miss — add those individually,
the same "one asset at a time" rule D-073 already states for hand-authored content.

**Why `RichPresenceService`/`SteamStats` never call `SteamLobby.initialise()` themselves.** The first
version of this task had both new autoloads call `initialise()` unconditionally from their own
`_ready()`, so a solo player who never hosts or joins a lobby would still get live Steam
achievements/presence — Steam is otherwise only brought up when the player actually asks for a
session (`SteamLobby`'s own header). Reverted the same session: on any machine with a real Steam
client running — this dev machine included — that turned EVERY headless `agent godot` run
project-wide into a real `SteamAPI_Init()` call, confirmed by running `tools/salvage_check.gd` before
and after and diffing the log (Steam client startup lines and ObjectDB-leak warnings at exit appear
only in the "after" run). A presence-only task is not the place to widen how eagerly the whole
project's tooling talks to a live third-party client. Both files now only read/push Steam state that
something else — a real hosted/joined session, an accepted invite — already brought up
(`SteamLobby.is_ready()`); LOCAL tracking (the counters `SteamStats` persists to
`user://steam_stats.json`, and every assertion in `tools/steam_stats_check.gd`) needs no Steam
session at all and is unaffected either way. **Would change my mind:** a real product decision that
solo/offline achievement tracking against the live Steam API matters enough to pay this cost — at
which point the right fix is probably `NetConfig`/`DevLaunch` gaining a flag that keeps `agent godot`
itself Steam-free regardless of what autoloads want, not reverting this call.

### D-149 · 2026-08-19 · F-243's run restart resets services IN PLACE — no level reload, no fresh world seed, host-only trigger with no new RPC
*Middle third superseded by D-161 (a restart draws a fresh seed). Its run-scoped reset enumeration is amended by D-178 — the live list is `tools/run_scope_audit_check.gd`, and the sentence below has been short since F-259.*

Three scope calls, made together, closing F-243 ("the run loop is a line, not a circle").

**Why services reset in place rather than reloading `levels/hollowmere.tscn`.** The finding's own
"suggested shape (not prescribed)" was "host reloads the level scene and broadcasts, services reset
on a `run_started` signal" — investigated and rejected. Nothing in this codebase has ever reloaded a
scene at runtime (`grep`'d for `change_scene_to_file`/`change_scene_to_packed`/
`reload_current_scene`across every `.gd` file: zero hits), and the players/enemies/buildables that
would need to survive the reload live OUTSIDE the level tree anyway (`PlayerNet.Players`,
`EnemyWorld`'s own container, `BuildService`'s own container — all children of their owning autoload,
never of `Hollowmere`), so a reload buys nothing for those three and adds real risk (re-triggering
`World`/`Undergrowth`'s generation cost live, mid-session, on every peer, for systems never built or
tested to run twice in one process). The three systems a reload WOULD have reset for free — Chest,
Wellspring, ExtractionShip, all children of level-tree marker nodes — instead grew their own small
`host_reset_for_new_run()` (`systems/loot/chest.gd`, `systems/wellspring/wellspring.gd`,
`systems/extraction/extraction_ship.gd`), the same size cost as writing the reload path safely would
have been, without the new risk. **Would change my mind:** a future task that already needs a live
scene-reload path for an unrelated reason (a level-select feature, say) — at that point resetting
those three the "for free" way becomes worth revisiting.

**Why a restart keeps the same `GameState.run_seed` — same island, same POI/Wellspring/Chest/
ExtractionShip positions.** Regenerating the world seed live would need a NEW broadcast reaching
every already-connected peer (`WorldDeltaLog.net_world_snapshot` only ever targets a peer that just
joined — `NetSession.peer_admitted`, not a running session) plus every terrain/POI/streaming system
proving it behaves correctly reseeded mid-process, none of which exists today and none of which F-243
asked for ("no path to a next run", not "no path to a new island"). Only RUN-scoped state resets:
Cycle, Mire corruption, Cycle Modifiers, inventory, health, enemies, buildables, chest/wellspring/ship
progress. Filed as its own gap, F-258, so it reads as a real scope cut and not a missed case.

**Why restart is HOST-only with no new RPC, not a per-player request routed through
`CommandService`.** `CommandService`'s HOST-scope commands (`build`, `craft`, `give`, ...) all require
the issuing peer to be "op" (`CommandService._is_op()` — the host is always op, nobody else is by
default), which is right for that file's actual role: a debug/admin console layer, not the path real
gameplay verbs use (`BuildService.request_place()` and its siblings call their own dedicated RPC
directly, no op check, exactly why F-244 could even exist as a *separate* "the console `build` verb
doesn't ground-snap" bug — the console command and the real placement flow are already two different
code paths). A UI button any player can press therefore cannot go through `CommandService` without
either op-ing every peer by default (unrelated scope creep) or adding a THIRD `request_*`/`net_*` RPC
pair, which would need a `PROTOCOL_VERSION` bump (`core/net/net_version.gd`), a
`tools/handshake_check.gd` assertion update, and re-recording `core/net/rpc_manifest.gd`'s scanned
signature — real, mechanical work, but for a request that has a simpler answer: restart is a
session-level decision, the same category `NetTransport` mode and `GameState.host_generate_seed()`
already put entirely in the host's hands with no RPC of their own. `ui/hud/defeat_hud.gd`/
`ui/hud/extraction_hud.gd`'s "Start Next Run" button only enables for the local peer that IS the host
(`_is_host_or_solo()`); every other peer sees it disabled, reading "Waiting on the host to start the
next run…". `CycleService.host_restart_run()` is still registered as a `restart` console command too
(host-only, since the host is always op) — free, and matches the finding's own "through the existing
command front door" framing for the one peer it actually works for. **Would change my mind:** a
playtest where the host is reliably the first to alt-tab away or disconnect after a wipe, stranding
the rest of the party — at that point the fix is probably "any present peer may restart", which
genuinely does need the new RPC pair this decision avoids for now.

**Why rich presence has no separate "in the menu" state.** The obvious first design was a
menu-vs-in-run state machine ("In the menu" vs "In a run — Cycle N", `docs/STEAM.md` §S4's own
suggested wording) — dropped once `ui/menu/main_menu.gd` and D-110 made it clear no such phase exists
in the shipped game: `run/main_scene` boots straight into a live `levels/hollowmere.tscn` with a
Cycle already ticking (`MireGrid._ready()` draws the seed immediately), and `MainMenu` never gates
play. Inventing a "menu" presence state would describe a boot phase that does not exist rather than
the game that does, so `RichPresenceService.compute_status_text()` is just "Cycle N", with the
connected party size appended once there is one to report. **Would change my mind:** D-110's own
trigger — a real "gate world-gen behind a start screen" task, scoped and reviewed on its own.

### D-150 · 2026-08-19 · `chunk_stream_check.gd`'s union-of-interest separation is sized against the LOD0 ring, not the full load radius

F-251's fix for the check's 5th pre-existing failure. `_check_union_of_interest()`'s `min_separation`
was `LOAD_RADIUS_CHUNKS + HYSTERESIS_CHUNKS + 1` (10 chunks / 320 m) — big enough that NEITHER
anchor's full outer streaming ring (LOD0 through LOD2, out to `LOAD_RADIUS_CHUNKS`) could reach the
other's chunk. That doesn't fit the shipped island any more: `IslandHeightmap.ISLAND_RADIUS` shrank
512→118 m in the same terrain retuning pass this finding's other 4 failures trace to (D-142/D-143
era), and harvestable placements never occur past Chebyshev radius 6 from origin — open water beyond
the island has none. No two harvestable-bearing chunks are ever 10 apart, so the search this
constant feeds always returned `NOT_FOUND`, unrelated to any real `ChunkStreamer` bug.

**Rebased to `LOD0_RADIUS_CHUNKS + HYSTERESIS_CHUNKS + 1` (4 chunks / 128 m) instead of shrinking the
same LOAD_RADIUS-based formula.** The assertions this separation feeds only claim two things: both
anchors' chunks load at LOD0 with a collider, and specifically that anchor B's collider comes from
anchor B's OWN presence, not merely from sitting inside anchor A's radius somewhere. Proving that
second claim only requires B to sit outside A's LOD0 ring (`LOD0_RADIUS_CHUNKS + HYSTERESIS_CHUNKS`)
— A's LOD1/LOD2 rings extend further but never carry a collider, so a chunk inside them but outside
A's LOD0 ring still could not have gotten its collider from A alone, which is the one thing the test
needs to rule out. The stronger LOAD_RADIUS-based bound proved something true but unnecessary, and no
longer fits inside the island's own harvestable footprint. 4 chunks does, with margin (real content
reaches to radius 6, and the search still explores out to `ISLAND_CHUNK_RADIUS` — 10 chunks — before
giving up).

**Would change my mind:** the island growing back toward its original ~512 m scale (a future D-143
reversal) — at that point the LOAD_RADIUS-based bound becomes achievable again and is the strictly
stronger claim, worth reverting to.

### D-181 · 2026-08-19 · The LM lane runs Opus at high effort and second-passes its own work: every completed task is auto-queued as a review-and-fix
*Renumbered from a duplicated `D-150` by F-283 — this entry and the `D-150` above were allocated the same number before the `agent decision` allocator existed (D-182). A pre-2026-08-20 citation of `D-150` that is about the subject below means this entry.*
Two changes to the Max lane, both from measurements taken 2026-08-18/19.

**Opus, not Sonnet.** The five-hour windows kept rolling over only part-used, which reads as spare
capacity; the weekly underneath was at 90%. The weekly is the real budget and it expires unspent at
its reset, so the question was never affordability but what the most capable thing to spend it on is
before it evaporates. Effort rises to `high` for the same reason. (Claude Code has no `--effort`
flag — it is a thinking budget expressed in the order text, so the ledger records what was asked
for rather than implying a flag that was dropped.)

**Second pass.** 26 independent reviews found 8 real defects that the implementing lane's own green
checks had missed — a non-host op charging the host's inventory, an item duplicating on every chunk
rebuild, a console that printed nothing. That is roughly a third of reviews finding something real,
which makes review the highest-yield activity available. But each finding then needed its own order,
brief, claim and verify cycle, rebuilding context the reviewer already had. So a completed task on a
`second_pass` lane now auto-queues `--review --fix` against the commit it just made: the reviewer may
repair what it finds, under a claim, verified, closed out normally.

The `--fix` prompt draws two lines the review-only mode did not need. Do not rewrite work that is
merely not how you would have done it — the bar is a nameable, provable defect, not a preference. And
if a fix is larger than the change under review, file it instead and say why; a second pass that
becomes a rewrite has stopped being a review. Guards against a self-feeding queue: a review is never
itself reviewed, each task is second-passed once per chain, and nothing queues without a commit.

A separate documentation stage was considered and rejected. Documentation was not a failure mode —
the lanes wrote their own SPECS blocks, D-numbers and DELEGATION entries throughout — and a third
agent would collide with the coder on exactly the docs files it needs, making it a relay rather than
parallelism, starting cold to rebuild context the coder had warm.

**Would change my mind:** second passes that mostly find nothing (the ~30% hit rate collapsing once
the easy defects are gone), or a weekly window that stops being the binding constraint — either
turns this from leverage into overhead.

### D-151 · 2026-08-19 · Both Claude lanes run Opus; the second-pass reviewer runs at max effort and owns the bookkeeping
Extends D-181. LP joins LM on Opus at high effort, for the same reason: a subscription weekly is a
budget that expires unspent, so the only question is what the most capable thing to spend it on is.

The review pass runs one tier above the work it reviews — `max`, where the implementing pass runs
`high`. The asymmetry is deliberate. Writing a change is bounded by its spec; catching what a green
check missed is open-ended search, and the second pass is the last look anyone gives that work. Today
26 reviews found 8 defects that had already passed their own tests, which is where the leverage is.

The reviewer also inherits the **bookkeeping**, because it is the last agent to see the task and the
board is what every future agent routes off. A wrong entry there is read as truth and never
re-examined, which makes it more expensive than a wrong line of code. It must check four things that
have each gone wrong here: that the task is genuinely done and the board agrees (F-086 was marked
`done` with its work unverified, and `agent claim` then refused anyone trying to pick it up); that a
fixed finding actually moved to `## Resolved` (seven dispatches went to already-fixed findings in one
day); that `docs/NEXT.md` still describes reality, since it is the plan a human reads first; and that
SPECS, the `ARCHITECTURE.md` §2.2 row and DELEGATION's *Current state* describe what shipped rather
than what was intended (§5 described a replication mechanism that was never built — F-212).

**Would change my mind:** max-effort reviews finding no more than high-effort ones did, which would
make the extra spend pure cost; or bookkeeping drift stopping on its own, which would mean the
close-out protocol is now sufficient without a second reader.

### D-152 · 2026-08-19 · The marker CONTRACT is kind AND name — PoiDef carries both, and the parity matrix asserts fixtures, not markers

Task 4.16. Three calls:

**1 · `PoiDef.marker_name` exists because two services' contract is the NAME.** The composer
(4.15/D-143) published kind-tagged markers, which satisfies WellspringService and ExtractionService
— but ChestPlacementService reads the TIER from a `Cache_*`/`Chest_<tier>_*` name prefix, and
CraftingService resolves the station asset from an exact `Station_<asset>` name. A procedural map
with kind-only markers therefore built zero chests and zero registered stations: two loop links
silently missing, on the map that is supposed to become the default (4.19). `marker_name` on the
def (empty = composer default) closes it as content, not code — and collisions are impossible
because each marker is the sole child of its own site root. Worked examples authored one at a time:
`loot_cache` (8 sites, `Cache_poi`), `enemy_nest` (5 sites, kind-only), `station_camp` (1 site,
`Station_station_workbench_primitive`, the workbench GLB as its scene).

**2 · The matrix asserts FIXTURES, not markers.** `tools/world_contract_check.gd` now boots both
maps in one process — the shipped scene, then a code-built `ProceduralWorld` — and asks the same
question of each: does every fixture the run arc needs actually stand? Wellspring ≥1, exactly one
extraction ship, chests with resolvable tiers, at least one REGISTERED station (a marker whose
asset matches a `StationDef.world_scene` — six of Hollowmere's eight station props are scenery, so
"a station marker exists" proves nothing; the loop audit's own lesson), nest spawn points, a
standable spawn, wired harvest proxies around it, and a MireGrid that seeded inside the island and
recedes from a cap. Layout-shaped phases (F-076) still run only where a layout exists; F-112's
Undergrowth phase is REQUIRED on the authored map and asserted ABSENT on the procedural one —
flora there is ResourceScatterField's, and a second scatterer would mean two systems fighting
over the same ground.

**3 · One shipwreck, placed with objective priority.** The first matrix run failed with **two
extraction ships**: 4.7 had authored `shipwreck` as scenery (`target_count = 3`) before extraction
existed, and 4.15's `marker_kind` quietly turned every site into an exit. The run needs exactly
one (D-095's priority lesson applies to the exit exactly as it did to the Wellspring — the door
out of the run must not lose the good ground to landmarks): `target_count = 1`,
`placement_priority = 5`.

**MireGrid binding needed no code** — `MireGridSim` derives its bounds from
`IslandHeightmap.ISLAND_RADIUS`, so 4.13's 118 m island rescaled the grid automatically
(cell ≈ 0.92 m); the matrix asserts the seeded-and-recedes behaviour on both maps rather than
trusting the derivation.

**Would change my mind:** a second name-keyed service. If a third contract dimension appears
(name, kind, and something else), the marker convention should become a typed meta dictionary
instead of accreting fields on PoiDef.

---

### D-153 · 2026-08-19 · F-253: `MireGrid`'s pre-join throwaway local seed is not a bug — do not gate `_owns_simulation()` on connection intent

F-253 (`tools/seed_sync_check.gd`'s 3 failures) traced to `GameState.is_seed_ready()` flipping true on
a not-yet-joined client well before the host's real `net_world_snapshot` RPC lands — confirmed by
timestamped print-debugging (client draws its own seed at msec≈663; the host's RPC doesn't arrive
until msec≈858). The draw comes from `MireGrid.ensure_ready()` → `GameState.ensure_seed()`, gated by
`_owns_simulation()`, which reads true for ANY peer whose transport is neither active nor connecting —
correct for genuine solo/offline play, but also true for "about to join, hasn't called `join()` yet."

**Call: leave `_owns_simulation()` alone.** This is D-110/D-119's own F-172 resolution working exactly
as designed — solo/offline play must seed instantly at boot, and those decisions explicitly rejected
gating world-gen's first tick behind any connection-state check, precisely to avoid relitigating that
as a side effect of a smaller task (D-110's own words). `MireGrid`'s local draw is real-entropy waste,
not corruption: `_owns_simulation()` flips false the instant the peer actually becomes a connected
client, so the throwaway `_grid` is never read again (every consumer re-checks `_owns_simulation()` at
call time), and `GameState.set_replicated_seed()` unconditionally overwrites `run_seed` once the real
snapshot arrives, re-firing `seed_ready` so any subscriber (`ui/menu/main_menu.gd`'s "This run's seed"
label included) self-corrects. Confirmed no consumer of `is_seed_ready()`/`run_seed` anywhere in the
repo treats the pre-join value as durable.

**What this means for future checks:** `GameState.is_seed_ready()` is not proof a *replicated* value
has arrived — only that *some* value has been drawn, host-generated or not. A check that needs to
prove replication specifically must gate on a fact only the replication path itself can produce (F-253
used `WorldDeltaLog`'s `before_delta` flag, set only inside `net_world_snapshot()`'s own RPC body).

**Would change my mind:** a future system that reads `run_seed` synchronously in that pre-join window
for something durable (not just UI display) — today nothing does.

### D-154 · 2026-08-19 · Claim files late and release them all at close-out
A claim locks a file for every other agent until the claiming task closes out. The old protocol had
agents claim their whole file list up front, so a file was locked for the entire task — up to the
2-hour timeout with LM on Opus — even when it was edited for only minutes near the end. Sequoyah
identified this as the primary cause of agents stalling on each other (F-262), and the session bore it
out: net_version.gd held across four sessions, graphics_quality.gd blocking F-130 for hours, twelve
files held six hours with no writes.

The fix has two halves and only the first was adopted. **Claim late**: claim each file the moment
before its first edit, not up front. `agent claim` is additive, so this needs no new mechanism —
only the instruction, now in the order template and AGENTS.md rule 1. It shrinks a file's lock from
the whole task to the minutes it is actually worked.

**Release stays all-at-once at close-out** — the early-release half was considered and rejected. A
task's files are one change that is not final until its own verification passes; releasing a file
mid-task lets a sibling edit it, and if the task's check then sends it back into that file the result
is the exact two-agents-one-file race claims exist to prevent. Holding claims through the short
docs-writing close-out is a small price for that safety.

**Would change my mind:** measured evidence that close-out itself (the docs-writing tail, after the
last source edit) is where the remaining contention lives — which would justify releasing source
claims at green-check time while keeping only the docs files, the rejected half revisited with data.

### D-155 · 2026-08-19 · `apply_ids.sh` writes every home of the Steam App ID, including the two outside `tools/steam/`
The real Steam App ID lives in three independent places, and nothing derives any of them from
another: `tools/steam/steam_build_config.sh` (the offline `steamcmd` depot upload, task 8.4/D-132),
`core/net/net_config.gd`'s `const STEAM_APP_ID` (the runtime value `steam_lobby.gd` passes to
`steamInitEx()`, ARCHITECTURE.md §2.4/D-008), and `steam_appid.txt` at the repo root (what the Steam
SDK reads on any dev run that calls `steamInitEx()` with app_id 0 — `tools/steam_check.gd` does).
Task 8.11's `apply_ids.sh` reached only the first, so task 8.2 could apply the real ID, watch
`depot_wiring_check.sh` go green, and ship a build that uploads to the correct depot while every
client still initialises against Spacewar's 480 — unjoinable, and indistinguishable from a fully
wired release (F-257).

F-257 offered two fixes: document the companion edits in 8.2's spec block, or make one command do
all of them. **Chose the second.** A documented second step is only as good as the reader; the whole
point of a single `apply_ids.sh <app_id> <depot_win> <depot_mac> <depot_linux>` is that a partial
swap becomes structurally impossible rather than merely discouraged. The script now pre-flights all
three targets before writing to any of them, refuses if a target line is missing, renamed or
duplicated, and rolls all three back if any value fails to read back — a rolled-back trio is
recoverable, a half-applied one ships.

**The claim-boundary question F-257 raised, answered:** yes, a `tools/` script may write into
`core/` and the repo root. The alternative — a script that deliberately reaches only its own
directory and leaves a note asking someone to finish the job — is exactly the failure being fixed,
and the directory a file happens to live in is not a reason to let a release ship broken. The
protocol obligation lands on the *agent running the script*, not on the script: `apply_ids.sh`'s
header states that whoever runs it must hold claims on `core/net/net_config.gd` and
`steam_appid.txt` as well as `steam_build_config.sh`, and task 8.2's spec block repeats it.

**Belt and braces, because a hand-edit can still drift them:** `steam_upload.sh` — the last gate
before a live, hard-to-reverse Steam publish — now reads `net_config.gd`'s constant itself and
refuses to upload if it disagrees with the config's, and `depot_wiring_check.sh` asserts all three
agree in the repo as it stands. `tools/steam_check.gd` was changed from asserting a hardcoded
`app_id == 480` to asserting `app_id == NetConfig.STEAM_APP_ID`: the literal would have had to be
edited again at 8.2 and would have failed loudly and uselessly until someone did, whereas the
agreement assertion stays a true and useful claim on both sides of the swap.

**Would change my mind:** a fourth home appearing that `apply_ids.sh` genuinely must not write —
a vendored third-party file, or a per-developer local override. Then the script's job becomes
"write every home it owns and *verify* the rest", and the verification in `depot_wiring_check.sh`
§4 becomes the primary mechanism rather than the backstop.

### D-156 · 2026-08-19 · F-245's Cycle Modifier consumers: `tithe` exempts solo, `the_hunt` reuses `tusker` rather than authoring an elite

Two scoping calls made while wiring the seven Cycle Modifiers' real effects (F-245), each affecting
how a future modifier or content task should read these two files.

**`tithe` (`Wellspring._start_channel()`) raises `required_players` by one only when the session is
already co-op, never for a lone player.** The `.tres` description says "a duo... has to physically
regroup" — read literally as "always +1," a solo run (`required_players` starts at 1) would need 2
players that do not exist, making every Wellspring permanently uncappable for the rest of that run.
`tools/wellspring_recorruption_check.gd`'s own solo recapture test caught this: `agent baseline`
showed 0 failures at HEAD and 3 once `tithe`'s naive (unconditional) version could be drawn mid-run
by that check's own Cycle advances. Solo is common in this project (`SOLO_DURATION_SEC` exists
specifically for it) and DESIGN.md never floats "some modifiers make solo unwinnable" as intended
chaos the way it does for, say, `the_hunt`'s late `min_cycle`. **Would change my mind:** a DESIGN.md
update that explicitly wants a modifier able to hard-block solo progress — today none does, and
`tithe`'s own prose is about raising an EXISTING co-op requirement, not inventing one from zero.

**`the_hunt`'s "roaming elite" is `tusker` (this project's single toughest `EnemyDef`: 45 max_health
against 7–9 for `strider`/`broodcaller`, the only two-digit `content/enemies/*.tres`), not a new
hand-authored enemy.** AGENTS.md's "never bulk-generate content data" rule and F-245's own "framework,
not content" scope both argue against inventing an 8.6.4 wave in `content/enemies/` just to give one
Cycle Modifier a bespoke elite — the def only needs to be tougher than the ambient population and
already exists. Tracking ("beelines for whoever holds the most powerups") comes from
`WaveSpawner`'s own retarget ticker calling the new `Enemy.host_force_target()`, not from any new
`EnemyDef` field — `tusker`'s stats are otherwise untouched. **Would change my mind:** a future task
that wants the elite to visually read as distinct from a normal Tusker encounter (a tint, a VFX, a
name) — that is presentation, not a reason to relitigate which `EnemyDef` backs it.

### D-157 · 2026-08-19 · The delegation harness self-heals: chains re-exec on harness change, survive single task failures, register dispatch intent, and re-reviews reset
One hardening pass over five failure classes, each observed live on 2026-08-19 (F-263). Chains check
the harness files' mtimes between tasks and re-exec themselves when the code changed underneath them,
so a fix reaches running fleets instead of only future ones. A single task failure no longer stops
the queue behind it — the order stays on disk and the chain continues, stopping only on two
consecutive failures or a lane-level stop, because F-243's timeout starved eight queued orders three
times over. A chain registers a lightweight in_flight marker at dispatch under its slot's identity,
closing the duplicate-grab window that claim-late (D-154) widened; the marker is inherited by the
agent's first real claim and dropped if the run dies before one. Re-ordering a done review resets it
to todo with the new sha, since reviewing new commits is new work. And `agent decision` now allocates
D-numbers under a lock — this entry is its first successful output, after its claim-guard correctly
refused the first attempt while another lane held the file.

**Would change my mind:** re-exec proving unsafe mid-queue (a chain resuming with incompatible state
would argue for restart-at-drain instead), or the dispatch marker stranding tasks in_flight after
crashes despite the no-files cleanup — either means the self-healing is causing more incidents than
it prevents.

---

### D-158 · 2026-08-19 · F-254: a Cycle Modifier draw replicates as an ADDITIVE per-slot `:cycle` key, and the client announces off `COUNT_KEY`, not off the touched key

F-254 named two acceptable fixes and left the choice to whoever took it. Taking **option (a)**: the
Cycle a modifier was drawn on is recorded under its own `WorldDeltaLog` key (`"0:cycle"`, `"1:cycle"`,
…) beside that slot's existing `def_id` key, and `CycleModifierService._on_world_delta_applied()`
re-derives `EventBus.emit_cycle_modifier_drawn(def_id, cycle)` on a client from the pair.

**Rejected (b) — "mark `cycle_modifier_drawn` host-only until a real consumer forces the decision."**
That option was written when the modifiers were inert. F-245 has since wired all seven to real
gameplay consumers, so the first client-visible reaction to a draw (a toast, a HUD banner) is now
ordinary next work rather than hypothetical, and leaving a documented-as-broken signal in front of it
just relocates the trap. It also would have left `EventBus`'s own doc comment asserting "emitted by
the HOST only" for a signal whose whole purpose is a cross-peer reaction.

**Rejected: widening the `str(slot)` value to `"%s:%d" % [def_id, cycle]`.** F-254 called this out
and it holds — `_replicated_active_ids()` reads that value as a bare id, so widening it changes the
parsing contract for every existing reader to buy nothing an additive key does not. A new key is
invisible to a loop that only asks for `str(index)` and `COUNT_KEY`.

**The part that is not obvious, and that a future edit must not "simplify":** the client handler does
NOT react to the key that was touched. Any landing under this `kind` re-scans every slot below the
recorded `COUNT_KEY` and emits for whichever slot's `(def_id, cycle)` pair changed since it last
announced. Two properties fall out of that, and both are load-bearing:

1. **Order-independence.** One draw writes three records, which cross the wire as three separate
   `net_delta_applied` RPCs. The scan is idempotent, so those three landings produce exactly one emit
   between them in any arrival order — the race F-254 raised as an objection to the naive fix,
   answered rather than assumed away.
2. **Restart safety.** `WorldDeltaLog` is latest-value-wins and never deletes. After a restart writes
   `COUNT_KEY = 0`, slot 0 still holds the PREVIOUS run's `def_id`. A per-key handler that emitted the
   moment the new run's `"0:cycle"` record landed would pair the new Cycle with a stale modifier id.
   Gating on `slot < count` means nothing is announced until the draw's own `COUNT_KEY` write — which
   `_announce()` deliberately issues LAST, after both halves — brings the slot back into range.

Consequently `_announce()`'s write order (`slot:cycle`, `slot`, then `COUNT_KEY`) is part of the
contract, not incidental formatting. `COUNT_KEY` is what publishes a draw.

**Also settled: the client's `_announced_draws` dedupe is cleared on `run_restarted`, above the
host-ownership gate.** A restart keeps the same run seed (`CycleService`'s own scope cut, F-258), so
each restarted run redraws the *same* modifier on the *same* Cycle — a byte-identical stamp the
dedupe would otherwise swallow forever. The clear sits above `_owns_modifiers()` because a client
reaches `_on_run_restarted()` only through `CycleService._on_world_delta_applied()`'s re-derived
emit, and that is exactly the peer whose stamps need resetting.

**Would change my mind:** a consumer that genuinely needs the full historical draw list replayed as
signals on join. Today a late joiner deliberately gets no backlog (`net_world_snapshot` bypasses
`delta_applied`) and reads the caught-up stack from `active_modifier_ids()` instead — same contract
`CycleService` has. That would need real design, not a widening of this handler.

### D-159 · 2026-08-19 · An asset may show a void it CONTAINS, never one the terrain would have to own — and every named-but-cut interior must cite its finding on the same line

D-142 put 3D density and caves on the cut list, so the shipped world is a 2D heightfield with
nothing below grade. The consequence for art is narrower than "no caves" and keeps being
rediscovered: **the mesh may have a hole in it; the ground may not.** `giant hollow tree` is fine —
its void is inside its own trunk, and the asset carries it wherever it is placed. `cliff overhang`
is fine because it is honest about being a rock ledge PLACED on a slope, never a claim the terrain
overhangs. `corrupted crater` and the re-scoped `sinkhole` are fine because a depression IN the
heightfield is the one below-grade shape the heightfield can express. What is not fine is a mouth
that reads as *go in here*: a player walks up, tries to enter, and finds solid ground.

This has now been caught three times, each by a human re-reading a table after the list was already
written — F-237 (`cave entrance`, A-016), F-255 (`flooded cellar entrance`, A-020) and F-255's own
sweep (`burrow entrance`, A-016b, which was `NEXT` and about to be built). Three for three by eye is
not a process, so the rule is asserted by `tools/asset_scope_check.gd` instead.

**The enforced form:** in any file where an asset gets NAMED before it gets a mesh —
`docs/ASSET_TRACKER.md`, every `assets/*/README.md`, every `tools/blender/build_*.py` — a line may
name a below-grade interior (`cave`, `cellar`, `tunnel`, `catacomb`, `crypt`, `basement`, `dungeon`,
`undercroft`, `mine shaft`) or an `entrance` only if that same line cites an `F-NNN` or `D-NNN`. No
exported GLB may be named for one at all.

**The citation requirement is the whole mechanism, not paperwork.** Prose recording a cut and prose
proposing an asset are textually identical — "cave entrance" appears in both — and the citation is
the only thing that distinguishes them. A row that names a cave and says why is a record; a row that
names a cave and says nothing is the row somebody opens Blender for.

**Re-scope rather than cut, where the landmark survives it.** F-237 cut `cave entrance` because
nothing was left once the cave went. F-255 kept `flooded cellar ruin` and `burrow mound`, because a
ruined flooded structure and a mound of turned earth are both good props once the implied room is
gone. Cutting is the fallback, not the default.

**Would change my mind:** D-142's erosion spike coming back hash-equal does NOT reopen this — it
changes how the surface is shaped, not whether there is anything under it. Only adopting 3D density
would, and D-142 rejects that outright rather than gating it.

### D-160 · 2026-08-20 · F-261: a noise set NESTS the layer below it rather than folding into it, and every worldgen refactor proves itself against captured pre-fix hashes
F-261 closed the third and last of the per-sample noise-rebuild sites F-241 named, and it had to
settle two things the earlier two instalments never faced.

**The set nests, it does not fold.** F-261 offered both: give `BiomeMap` its own small
`NoiseSet`-alike, or fold the moisture field into `IslandHeightmap.NoiseSet` "since both are keyed by
the same `world_seed`". Nesting won. `BiomeMap.NoiseSet` holds `island: IslandHeightmap.NoiseSet`
plus `moisture_noise`, and `make_noise_set(world_seed, island_set := null)` ADOPTS a caller's
existing island set instead of building a second one.

The reason is the dependency direction. `biome_map.gd` preloads `island_heightmap.gd`; nothing goes
the other way, and D-144 is explicitly about keeping the terrain layer ignorant of the biome layer
above it — the continent is the biome-INDEPENDENT half of the surface, which is the only thing that
stops biome selection being circular. A moisture field living inside the heightmap's own set would
put a field in the terrain layer that only the layer above it reads, which is exactly the inversion
D-144 exists to prevent, for a saving of one object. Nesting also buys something folding could not:
`ResourceScatter.placements_for_chunk()` already built an island set for its heights, and adoption
lets it resolve moisture through the same chunk-scoped set rather than paying twice.

**A `*_from_set` path never gets its own copy of the formula.** `continent()`/`continent_from_set()`
funnel through one private `_continent_with()`, `moisture()`/`moisture_from_set()` through
`_moisture_with()`, exactly as `height()` already delegates to `height_from_set()`. Two bodies that
must agree forever will not; the only durable version of "bit-identical" is one body. Where
delegation would have COST something — `continent()` routed through a full `make_noise_set()` would
construct the detail and ridge fields it never reads — the shared body takes the four fields as
parameters instead, so the bare path stays exactly as cheap as it was.

**A worldgen refactor proves itself against captured pre-fix hashes, not against itself.** The
danger in this class of change is not that the new path disagrees with the old API — both live in
the same file and a self-consistency check passes trivially. It is that the whole file now generates
a DIFFERENT island, silently, and nothing downstream can tell: a POI layout is never replicated
(ARCHITECTURE.md §4), so a moved Wellspring reads as a new seed, not as a bug.

`agent baseline` cannot cover this, and the reason generalises: a check written as part of a fix does
not exist at the revision you want to compare against, and neither do the APIs it drives. So the
procedure is to capture the hashes FIRST, from a throwaway probe run against the untouched tree,
before the first edit — and then paste them into the new check as constants.
`tools/worldgen_noise_reuse_check.gd`'s `GOLDEN_POI`/`GOLDEN_BIOME`/`GOLDEN_AMPLITUDES` are that
capture, taken at 17bacba across five seeds. They are a tripwire, not a specification: a later task
that deliberately changes worldgen output re-captures them and says so in its own close-out.

**Would change my mind:** a caller appearing that needs moisture WITHOUT any island sample would
argue for splitting the moisture field back out of `BiomeMap.NoiseSet` into a set of its own — today
every caller wants both, so one object is right. On the golden hashes: if a worldgen tuning pass
ever has to re-capture them more than about twice, they are being used as a specification rather
than a tripwire and should be narrowed to POI placement alone, which is the part that actually
cannot self-detect drift.

### D-161 · 2026-08-20 · F-258: a restart draws a FRESH world seed, re-broadcast over the existing delta channel — no new RPC, no protocol bump, and the ended run's chunk log is wiped with it

Reverses the middle third of D-149. That entry cut a fresh seed out of F-243's restart on two
grounds: it "would need a live re-broadcast reaching every ALREADY-connected peer, and nothing in
this codebase does that today", plus "every terrain/POI/streaming system proving it behaves
correctly when re-derived from a NEW seed mid-process". Both were true statements about the code at
the time. Neither turned out to cost what the scope cut assumed, and the finding it was filed as
(F-258) is closed by the four calls below.

**Why no new RPC — the re-broadcast is one already on the wire.** D-149 (and F-258's own "would
take" list) budgeted a protocol bump: `core/net/net_version.gd` + `tools/handshake_check.gd` +
re-recording `core/net/rpc_manifest.gd`'s scanned signature. None of it was needed. `WorldDeltaLog`'s
`net_delta_applied` is *already* a host → everyone reliable broadcast of a `(chunk, kind, key,
value)` tuple, and a seed is a value. `host_reseed()` sends it under a `kind` of `&"world"`, key
`"seed"`, at the same `Vector2i.ZERO` pseudo-chunk `CycleService` already keys its Cycle and
run-generation records to — the third use of D-099/D-100's no-new-RPC reuse of this log, and the
same reason it is safe each time: the log keys by `(chunk, kind, key)`, so a kind nothing spatial
uses cannot collide. The wire SHAPE never moves, which is precisely the condition
`tools/rpc_manifest_check.gd` scans for; it stays green at PROTOCOL_VERSION 21, 55 RPCs, unchanged.
What D-149 called "the thing nothing in this codebase does" was one method on a file whose own
header already said getting the seed to a client was its job — it had simply only ever done it for a
peer that was *joining* (`net_world_snapshot`, `NetSession.peer_admitted`), never one already here.
**Would change my mind:** a future reseed that has to carry more than an int (a whole world
descriptor, a content-set id) — at that point it is a real payload and deserves a real RPC rather
than a pseudo-chunk record.

**Why the reseed WIPES `WorldDeltaLog`, and why that forces an ordering.** Every record in the log
is keyed by a chunk of the island that just ended: harvest depletion at a point, a Mire cell.
Carried into a world derived from a different seed they describe coordinates that mean something
else — a depleted tree where the new island has open ground. So `host_reseed()` clears `_state` and
lays the seed record down as the log's first entry, on the host and identically on every receiving
peer (one `_reseed_local()`, so send and receive cannot drift in what a reseed MEANS).

That makes ORDER load-bearing inside `CycleService.host_restart_run()`, which is why it is now
commented there rather than left to be rediscovered: the reseed runs FIRST, before that file's own
`RUN_KIND`/`KIND` records (written after the wipe, or they go with it) and before
`EVENT_BUS.emit_run_restarted()` (so every subscriber that re-derives from the seed reads the new
value, not the ended run's). On a client the same order arrives for free — both records ride the one
reliable ordered `net_delta_applied` channel, seed then run, so `_on_world_delta_applied()`'s
re-derived `run_restarted` cannot outrun the reseed that must precede it.

**Why "every system proves it re-derives" was cheaper than D-149 estimated.** Because almost all of
them already did, by construction. `IslandHeightmap`/`BiomeMap`/`PoiMap`/`ResourceScatter` are pure
static functions taking `world_seed` as a parameter — nothing to re-derive, only a new argument.
`CycleModifierService`, `RewardService` and `MireGrid` read the seed through `GameState.ensure_seed()`
at *call* time, so they picked up the new value with no edit at all. Only two things actually cached
it: `ProceduralWorld` (which owns the `ChunkStreamer`/`NavBaker`/`ResourceScatterField` trio and now
tears them down and rebuilds on `run_restarted` — a rebuilt island is asserted byte-identical to one
BOOTED on that seed, since two peers restarting must not derive different worlds), and `Chest`,
whose `_rng` was deliberately "left running rather than reseeded" *because* D-149 kept the seed —
now re-seeded from `(new run_seed, chest name)`, restoring F-210's real contract.

**Why `ProceduralWorld` repositions only the local player, and rebinds the respawn point with it.**
Own-player movement is client-authoritative (`ARCHITECTURE.md` §2.2 row 1), so a peer writing another
peer's transform would be overwritten on the next synchronizer tick — and does not need to, since
`run_restarted` reaches every peer and each moves its own. Moving the body alone was the trap: F-063's
captured `PlayerHealth._spawn_transforms` entry still described the PREVIOUS island's shore, so the
next death would have respawned the player into open ocean — F-063's own bug arriving by a different
route. `PlayerHealth.rebind_local_spawn()` does both halves in one call for that reason, and is
client-local rather than routed through `host_place_player()`, which would make an authority claim
this path does not need. **Would change my mind:** a restart that keeps players where they stood
(a "same island, new run" mode) — then the rebind is wrong and the spawn capture should be left alone.

**Scope kept out, deliberately.** The shipped map is `levels/hollowmere.tscn`, which is AUTHORED —
its terrain, POI, Wellspring, Chest and ship markers are hand-placed and no seed moves them. So
today's player-visible win from this is the loot/modifier/Mire streams genuinely differing run to
run; the fresh *island* half lands on `ProceduralWorld`, still dev-only behind `DevLaunch
--procedural` until 4.19's cutover (F-139). That is the right order — the mechanism is proven and
exercised before the map that needs it ships, not after.

### D-162 · 2026-08-20 · A finding resolves when the defect its own text asserts is false at HEAD — spin-outs found while fixing it live as their own findings, cited in the resolution note
F-269 had to decide whether F-243 ("the run loop is a line, not a circle — after defeat or
extraction there is no path to a next run short of relaunching the process") is resolvable while its
review verdict reads *changes required* and nine findings spun out of it are open (F-268, F-275
through F-281), one of which still fails `tools/run_restart_check.gd` at HEAD.

**The rule: a finding is resolved when the specific defect its own text asserts is no longer true at
HEAD.** Not when the area it touched is perfect. F-243's assertion is a negative existence claim —
no restart path exists — and that claim is false now: `EventBus.run_restarted` has twenty-one
subscribers, both HUDs submit the restart, and two dedicated checks drive it. Leaving it under
`## Open` does not communicate "there is residue"; it communicates the false headline, and `brief`
offers that headline to the next lane as buildable work. That is the expensive failure — a lane
re-deriving a shipped feature — and it is strictly worse than a resolved entry whose note names nine
open follow-ups by number.

The residue is not lost by resolving, because the residue already has F-numbers. That is what
spinning a gap out into its own finding is *for*: it is the record. A resolution note that lists
them keeps the trail readable in both directions — the parent points forward at what is left, each
child already points back.

Corollaries, both of which F-269 exercised:

- **A finding whose text says part of it is unfixed does not resolve.** F-236 names three content
  rows and `content/ranged_weapons/` is still one file; it was reopened, not moved.
- **A finding whose fix was deliberately deferred to design does not resolve either.** F-267's
  mechanism was never built; the incident was cleaned up and the mechanism filed. `agent reopen`
  is the correct exit for both, and it clears the drift by correcting the status rather than by
  moving the section (F-131).

**Would change my mind:** a resolved parent whose spin-outs get triaged as low-priority and rot,
where leaving the parent open would have kept the pressure on. If that happens, the fix is a
"blocked-by" field on a finding rather than reverting to headline-as-status — but if it happens
twice, this rule is wrong and the parent should stay open until its children close.

### D-163 · 2026-08-20 · F-271: a biome is decided from the CONTINENT everywhere, including scatter — and `PoiDef`'s height bounds deliberately mean the opposite surface

D-144 already said a biome is chosen from `IslandHeightmap.continent()`, never `height()`, because a
`BiomeDef` carries terrain amplitudes and so the full surface height depends on which biome a point
is in. What D-144 did not say is that the rule binds every *consumer* of biome classification, not
just `BiomeMap.biome_at()` itself. `ResourceScatter._placement_at()` called `BiomeMap.assign()`
directly with the surface height for two years' worth of commits, and nothing noticed, because
scatter placement is never replicated (ARCHITECTURE.md §2.2) — a peer that classified a point
differently would have nothing to disagree with.

**The rule, stated so it cannot be read narrowly:** `assign()` is a primitive with one correct
argument, and outside `biome_map.gd` and `tools/biome_check.gd`'s unit tests nothing should be
calling it. A caller that wants a point's biome calls `biome_at()` / `biome_at_from_set()`. Having
the surface height already in a local is not a reason to reuse it — that reuse is precisely how the
bug arose, and the fix leaves both samples in the function side by side to make the distinction
visible at the call site.

**`PoiDef` is the deliberate exception, and it is not one.** `PoiDef.height_min`/`height_max` are
tested against `height()` and stay that way. The two fields answer different questions: a biome
cannot be chosen from a surface it shaped itself, whereas a landmark's height constraint is a
statement about the ground its feet land on — a Wellspring above the waterline, a shipwreck at it,
both visible-surface facts. What was actually broken there was the documentation: both fields read
"Metres, in IslandHeightmap.height()'s units" while meaning different surfaces. Both doc comments now
name their own surface and point at the other. The mixed units inside a single `PoiDef` — biome
resolved continentally, height tested on the surface — are intended.

**What it costs, measured.** Over an 81x81 grid at 8 m spacing, on the three biomes shipped today,
0.08%–0.14% of world points classify differently under the two rules (5–9 points in 6561, across
five seeds). The scatter layout hash moved for all five seeds, with the placement count changing by
at most 2 per seed — so the churn is real but small. It is small because biome content is thin
(F-236): three defs with wide, barely-overlapping height bands, so a few metres of ridge rarely
crosses a boundary. Every biome authored with a tighter band widens this, which is the argument for
fixing it now rather than after the content exists.

**One correction to F-274's reading of this, for whoever fixes that one.** F-274 says wiring the
amplitude seam is "exactly what turns F-271 from a doc-conformance problem into a live one," and that
F-271 "has not visibly diverged" while amplitudes are inert. The first half is right about severity;
the second half is not right about the facts. The divergence is live at HEAD and always was, because
it does not come from amplitudes at all — `height()` is `continent()` PLUS the detail and ridge
layers, and those layers are applied with the 1.0/1.0 defaults today, so the two functions return
different numbers on all high ground regardless of what any BiomeDef authors. That is the 0.08%-0.14%
measured above, on the shipped content, before F-274 changes anything. What wiring amplitudes adds is
circularity — `height()` starting to depend on the biome it is being used to select — which makes the
old code incoherent rather than merely wrong. F-271 was therefore worth fixing on its own schedule
and was, so F-274 no longer has to carry it.

**What would change my mind:** a task that gives the chunk mesher real per-biome terrain amplitudes
(F-274 — `terrain_amplitudes()` currently has no shipped caller, so `height()` is biome-blind in
practice today). Once the surface genuinely varies by biome, `PoiDef`'s bounds start meaning
something seed- and biome-dependent in a way an author cannot predict from the number alone, and the
POI half of this decision is worth revisiting. The biome half is not: it gets *more* correct as
amplitudes get real, since that is when `height()`-based classification becomes properly circular
rather than merely inconsistent.

---

### D-164 · 2026-08-20 · F-268: run-scoped world objects are FREED on `run_restarted`, never merely forgotten — and the method that does it is called `host_clear_all()`

A service that owns spawned nodes for the duration of a run must, on `EventBus.run_restarted`, free
the nodes. Clearing its own bookkeeping dictionary is not the fix and does not become the fix by
making the test pass.

**Why this is a decision and not a code comment.** The nodes in question are `MultiplayerSpawner`
children, and a spawner replays every LIVE spawn to a newly connected peer
(`core/net/net_session.gd`). So a host that empties `_placed` while the piece nodes still exist has
built the worst version of the bug rather than fixed it: the host believes the map is clear, its own
`placed_count()` agrees, the check passes — and the next player to join receives the previous run's
walls from the spawner's own replay, with no host-side record to destroy them by. The freed node is
what makes the despawn replicate. Nothing else does.

Two corollaries, both learned from the finding that produced this:

- **Announce each removal on the way out.** `BuildService.host_clear_all()` emits `piece_destroyed`
  per piece rather than clearing silently, because `NavBaker` tracks placed geometry off that signal
  (F-159) and has no `run_restarted` subscription of its own. A consumer that learns about
  destruction from a signal must learn about *this* destruction from the same signal, or the mass
  clear is the one code path that silently desyncs it.
- **Assert the container, not the bookkeeping.** `placed_count() == 0` cannot distinguish a freed
  piece from a forgotten one, which is exactly why F-268's assertion could have been "fixed" wrongly.
  `tools/run_restart_check.gd` now also asserts the replicated container's own child count and that
  no piece node survives anywhere in the tree.

**The name is part of the decision.** `host_clear_all()`, on `BuildService` and `HaulService` today.
A third spawner-backed service should be findable with one `grep -rn 'host_clear_all'`, not by
reading three files for three spellings of one idea. Host-guarded internally on the file's own
`_owns_mutation()`, and called unconditionally from `_on_run_restarted()` — every peer's copy may
call it and only the host's frees anything, matching every other `run_restarted` subscriber.

**No refund on a restart clear.** `InventoryService` empties every peer's inventory off the same
signal, so materials paid back would land in a bucket emptying in the same frame. This matches
`host_piece_destroyed_by_damage()`, which also refunds nothing, and differs deliberately from
`_process_destroy()`, which does.

**What would change my mind:** a run-scoped object that must genuinely outlive its run — a
meta-progression structure a player keeps between runs, say. That is a different lifetime, not an
exception to this: it should not be in a run-scoped container in the first place, the way
`UnlockService._purchased` is not.


### D-165 · 2026-08-20 · F-274: a point's terrain amplitudes are BLENDED across biome boundaries, not picked — and `build_mesh()` requires the biome table rather than defaulting it

**The seam.** D-144 named `BiomeMap.terrain_amplitudes()` as the seam that hands a point's
`(detail_amplitude, ridge_amplitude)` pair to `IslandHeightmap.height()`. F-274 found the seam built
and uncrossed: everything that shipped took the 1.0/1.0 defaults, so every biome got the same
biome-blind ground and the authored numbers in `content/biomes/*.tres` moved only the audit PNG.
This decision settles the two calls the wiring forced, both of which someone will otherwise
relitigate as "surely the simpler thing".

**1. The pair is a weighted BLEND of every nearby biome, not the winning biome's own.**

The obvious implementation — resolve the point's biome, look up its pair, sample — ships cliffs. The
amplitudes are a step function of the biome id, and the biome id is a step function of two
continuous fields, so the surface inherits a discontinuity along every biome boundary.
`forest.tres` authors `ridge_amplitude = 0.9` and `grassland.tres` authors 0.25; they meet along
the `moisture = 0.5` contour, which crosses the island's high ground where the ridge mask is at full
strength. The step there is `(0.9 - 0.25) x ridged_crest x RIDGE_WEIGHT` — about **7.7 metres of
vertical wall**, unclimbable under F-136's 46 degree floor limit, running across the interior along a
noise contour, with chunk seams straight through it.

So `BiomeMap.blend_amplitudes()` weights every def by how far inside its own (height, moisture) band
the point sits — 1.0 in the interior, falling to 0 over `AMPLITUDE_BLEND_HEIGHT_M` (1.5 m of
continental height) and `AMPLITUDE_BLEND_MOISTURE` (0.06) outside it — and returns the weighted mean.
The field is continuous, converges to the authored pair well inside a band, and costs one extra
polynomial per def. Measured: biome shaping adds at most **0.53 m** to the surface's own local step
over a 0.25 m walk across four seeds, against the terrain's own pre-existing 3.6 m steps at the river
corridor edge.

Three consequences worth stating so nobody rediscovers them:

- **The blend is priority-BLIND**, unlike `assign()`. Priority resolves a point's *identity* — which
  scatter table, which ground material, which biome the HUD names — and identity has to be a single
  answer. Roughness does not. Where two authored bands overlap, the ground is genuinely between the
  two, and averaging is truer than winner-takes-all. Authoring consequence: laying a flat biome over
  a rough one flattens the overlap even where the rough one wins the id.
- **A GAP in authored coverage puts the cliff back.** With no def within a margin, the blend falls
  back to (1.0, 1.0), and that fallback is the one discontinuity in an otherwise continuous field.
  The shipped content has no gap (`shore` covers every moisture below 4 m, `grassland`/`forest`
  every moisture above it). A new biome must not open one.
- **`amplitudes_for(id, defs)` still returns the AUTHORED pair** and is not what the ground uses.
  It is the reader for "what did this biome author", which is what a check compares the blend
  against in a biome's interior.

**2. `ChunkMesher.build_mesh()` REQUIRES `biome_defs`, ahead of the optional `lod`.**

An optional `biome_defs: Array = []` would have kept every call site compiling and every bench
running unchanged. It is also exactly the mechanism that produced F-274: a default that silently
yields a real-looking but wrong surface, which then ships because nothing about the call looks
incomplete. GDScript cannot place a required parameter after an optional one, so the argument ORDER
gave way instead of the requirement — `build_mesh(chunk_x, chunk_z, world_seed, biome_defs, lod = 0)`.
`tools/biome_terrain_check.gd` asserts on the method's own signature that the argument stayed
mandatory, because that is the property, not a behaviour.

The table itself is read ONCE per world build, in `ProceduralWorld._load_biome_defs()`, and handed
down: `ChunkStreamer.biome_defs` (which the worker task carries into the mesher), `NavBaker` adopting
the streamer's in `bind()`, `PoiMap`, `ResourceScatter`, and `height_at()`. Three separate reads of
the same autoload would be three chances for one consumer to be on an empty table, and a consumer on
an empty table is a landmark floating over a ridge — which is the failure this whole seam exists to
prevent.

**What it costs, measured.** `tools/bench_chunks.gd` single-threaded mean, seed 20260818, 100 chunks
on this machine: **5.956 ms/chunk before, 8.077 ms after** — 1.36x. A vertex now also pays one
moisture sample, a scan of the flattened table and six `smoothstep`s, which is the irreducible price
of resolving a biome per vertex. It was 10.697 ms (1.80x) in the first cut, before the river
channel was cached on `Shape`: the carve is applied twice per biome-shaped sample and
`_river_channel()` rebuilds and walks the polyline each time, so caching it collapsed two walks into
one and gave back more than half the regression, bit-identically. What is left of the per-sample
allocation underneath — `lobes()`, `islet_centres()` and `river_polyline()` are still rebuilt per
point — is F-294. This is a `WorkerThreadPool` cost, not a frame cost: `chunk_stream_check
--windowed` still reports the streamer's own per-frame cost at 0.2007 ms mean / 3.8 ms worst over a
500 m sprint, 0 hitches attributable to this node.

**What moved.** Every seed's terrain, POI site heights and scatter placement heights. `GOLDEN_POI`,
`GOLDEN_AMPLITUDES` and `GOLDEN_SCATTER` in `tools/worldgen_noise_reuse_check.gd` were re-captured
under D-160's rule; `GOLDEN_BIOME` and `check_determinism`'s `terrain_hash` (`c20eed19b44270a1`) were
deliberately left alone and still pass, which is what proves classification and the underlying
heightmap layer were not touched.

---

### D-166 · 2026-08-20 · F-278: a run restart SETS the clock, it does not CROSS to it — and a client snaps to any host jump rather than interpolating toward it

Two calls, both about `systems/environment/day_night.gd`, both easy to get backwards on a second
pass. Neither is worth relitigating.

**1 · The reset writes `time_of_day` directly and fires no threshold signal.** The obvious
implementation is `host_set_time(_run_start_time_of_day)` — that method exists precisely to jump the
clock, and its own header says the reason it is a seam at all is that it crosses thresholds on the
way so a `time set dusk` really starts the night. That is exactly what makes it the wrong call here.
A run ends at night (0.75+); the run-start morning is 0.348; `day_started_at` is 0.25 and therefore
sits *between* them. Routing the reset through `host_set_time()` fires `day_started`, and
`CycleService._on_day_started()` banks it as a full elapsed day — against `_days_elapsed`, which
`host_restart_run()` zeroed three lines earlier. The clock/count disagreement F-278 exists to remove
would come straight back, merely inverted. **A run BEGINS at morning; nothing crossed into it.** The
new run's first `night_started` is produced the ordinary way, by the clock advancing forward over
0.75 — which is the whole point of putting that crossing back in front of the clock, and is what
WaveSpawner (F-259) needs, since clearing a latch cannot re-fire a signal that already fired during
the previous run.

`tools/day_night_restart_check.gd` asserts the *absence* of both signals across two restarts, so a
later "simplification" to `host_set_time()` fails rather than silently costing a day.

**2 · `net_push_time` snaps when the value jumped, and infers that from the value itself.** A client
never runs its own clock — it lerps between the last two host snapshots through `_lerp_wrapped_unit()`,
which takes the SHORTEST way round the wrap. The shortest way from 0.80 back to 0.348 is backwards
through dusk and afternoon, so the one host motion interpolation renders *wrong* is a jump, and a
restart is a jump. `CLIENT_SNAP_THRESHOLD = 0.1` splits the two cases with room to spare: the largest
step a normally-advancing host can produce in one replication interval is
`REPLICATE_INTERVAL_SEC / day_length` — 0.017 even at the 60-second minimum day, 0.001 at the shipped
900 — while the jumps that need snapping (a restart, a `time set midnight` from noon) are 0.2 to 0.5.
Nothing legitimate lands in between. This is the same shape `core/net/remote_interp.gd` already had
for player transforms as `TELEPORT_DISTANCE_M`; DayNight was the outlier, not the innovator.

**Why the inference and not a flag on the wire.** `core/net/rpc_manifest.gd` scans RPC *shape*, so a
second parameter saying "this one is a jump" would be a `PROTOCOL_VERSION` bump — and it would not
even work reliably, because the ordering is the actual problem. `net_push_time` is **unreliable**;
`run_restarted` reaches a client over `WorldDeltaLog`'s **reliable ordered** channel. Reliable
delivery is head-of-line blocked behind whatever else is in that channel, so the reset push routinely
overtakes the event that explains it and lands while `_client_target_time` still holds the ended run's
night. Measured, not theorised: `tools/day_night_restart_check.gd`'s client sampled 5 frames inside a
band it can only reach by smearing, with the `run_restarted` snap already in place. The client-side
`run_restarted` handler stays anyway — it is what makes the adoption immediate rather than up to a
replication interval late — but the interpolator is what makes it correct.

**The general form, for anyone pairing an unreliable state push with a reliable event:** the push can
arrive first. Do not make the receiver's correctness depend on the event landing first.


### D-167 · 2026-08-20 · F-277: an Attunement selection is RUN-scoped — the lock dies with the run that set it, and each peer re-arms its OWN picker

**The call.** A pick made under D-071's "run start" trigger lasts exactly one run. On
`EventBus.run_restarted` the host clears every peer's selection (`AttunementService.host_clear_all()`,
D-164's naming) and broadcasts the clear; every peer's `AttunementUI` then reopens its own picker for
the new run. D-071's one-pick-per-run lock and "respec is out of scope" both stand — they are
statements about a *run*, and F-243 made "run" stop meaning "process".

**Why it is a decision and not just a bug fix.** The alternative reading was defensible: DESIGN §4.5
calls the pick identity-flavoured, and the file's own header says "locked for the run" while D-071's
trigger is worded "this session". F-243 turned that ambiguity into a soft-lock, because the *effect*
was already run-scoped — `PowerupService.host_clear_all()` clears the granted stack on the same
event — while the *record* was not. Half-scoped state is the worst of both: the player loses the
Attunement and keeps the ban on choosing one. Whichever way it was settled, the two halves had to
agree, and run-scoped is the half F-243 had already shipped.

**The pattern this generalises, and the one thing that is easy to get wrong.** A UI that re-arms
itself on a run boundary must not key that re-arm on the run event alone. `AttunementUI` re-arms from
**both** `run_restarted` and `AttunementService.selection_changed`, because on a client the host's
clearing broadcast and the client-side re-derived `run_restarted` travel different channels and can
land in either order; whichever arrives second is a harmless no-op, because the re-arm is guarded on
the local selection actually being empty rather than on the event that woke it. Keying only on
`run_restarted` looks correct in a single-process check and loses the race roughly half the time on
a real client.

**Re-arm on the NEXT frame, not inside the emit.** `run_restarted` subscribers run synchronously in
autoload registration order, and `AttunementUI` sits ahead of `DefeatHud`/`ExtractionHud` in
`project.godot` — both of which restore `Input.mouse_mode` to `CAPTURED` inside their own handler.
A panel that opens during that emit samples the terminal overlay's VISIBLE cursor as "what to restore
afterwards" and then has the mouse captured out from under it. Any run-boundary UI that touches the
mouse mode has to open deferred, after every peer subscriber has finished with it.

**A mandatory panel's in-flight request is a bounded wait, never a latch (F-297).** A panel with no
Esc and no dismiss path that disables its controls while waiting for a host answer must re-enable
them on a timeout, because "the answer never came" is a reachable state (the host drops between the
send and the reply) and its consequence is a player with no operable control and no route back to
gameplay. `AttunementUI` gives that wait 8 seconds and puts the failure in its existing error status
line. Panels with a dismiss path — `chest_ui.gd`, `crafting_ui.gd` — do not need this; the dismiss
path already is the bound.

**What would change my mind:** DESIGN §4.5 growing an explicit meta-progression Attunement that a
player keeps between runs. That would be a different lifetime, not an exception — like
`UnlockService._purchased`, it would live outside the run-scoped map rather than inside it with a
carve-out.

**D-number provenance (F-260).** Taken by reading the highest `### D-` heading in this file and
adding one, with no atomic allocator. D-165 was already held by F-274 at the time this was written.

---

### D-168 · 2026-08-20 · F-280: `run_started` is a PER-RUN public event, and `EventBus.run_restarted` is not a substitute for it — two seams, two meanings, neither interchangeable

**`run_started` means every run, restarts included.** F-154 shipped it latched once per PROCESS,
correctly for its own time — a run's lifetime *was* the process lifetime — and said in as many words
that a play-again flow would have to revisit the guard. F-243 was that flow and did not, so every
enabled user-authored `run_started` HookDef fired on boot and then silently skipped every later run
in the lobby. `CycleService._run_started_emitted` is now run-scoped: `host_restart_run()` clears it
and re-emits, and nothing else clears it.

**Why un-latch the public event rather than add a public `run_restarted` word.** The finding offered
both exits. The name is a promise a scenario author reads at face value, and F-154 itself framed the
process/run identity as a temporary equivalence rather than a design. A second public event would
force anyone who wants "a run began" to bind two hooks and would make the first run the odd one out
— the opposite of what §5.2's vocabulary is for.

**And why the private sibling still exists.** `EventBus.run_restarted` is NOT the same event under a
different name. It means "throw the ENDED run's state away", which is exactly the thing with no
first-run counterpart: a service subscribing it at boot would try to clear state that does not exist
yet, and a hook author subscribing it would miss the first run entirely. So:

- **`CycleService.run_started`** — PUBLIC, in `CommandService._HOOK_EVENTS`, host/solo only, fires at
  the START of every run. For scenario authors. Not for services.
- **`EventBus.run_restarted`** — PRIVATE service-to-service, fires only on a RESTART. For the ~15
  run-scoped services that reset. Not vocabulary; nothing in `_HOOK_EVENTS` binds it and nothing
  should.

**Ordering is part of the contract, not an implementation detail.** Inside `host_restart_run()`,
`run_restarted` fires FIRST and `run_started` fires LAST — after `_announce()` and after every reset.
A hook body is arbitrary user command script, so it has to observe the run it is named after (Cycle 1
recorded, modifiers cleared, inventories empty, the new seed live), while a `run_restarted`
subscriber exists to tear the ended run down. `tools/run_started_hook_check.gd` pins this as a
property — the listener snapshots `current_cycle()`, `host_count()` and `defeated` at emit time — so
a later refactor that reorders those calls fails a check instead of quietly changing what hooks see.

**Un-latching means clearing the guard, never emitting directly.** `_emit_run_started()` stays the
single emit site so its `_owns_cycle()` host/solo gate keeps deciding who may fire, in one place. The
guard also stays *within* a run: `host_advance_cycle()` does not touch it (Cycle 2 is the same run)
and neither does the mid-run early return (a refused restart never began a run).

**What would change my mind:** a real authored scenario that genuinely wants boot-once semantics.
That is what autoexec is for (`COMMANDS.md` §5.3) — and F-300 is the note that autoexec's own
documented purpose has the mirror-image version of this problem.

**D-number provenance (F-260).** Taken by reading the highest `### D-` heading in this file and
adding one, twice — once when drafting and once immediately before writing — with no atomic
allocator. D-165 was already held by F-274 when this task's first draft cited it; that reference was
corrected to D-168 in `cycle_service.gd` before anything shipped.

---

### D-169 · A map's spawn is graded against the layout's authored record, read before physics runs — never off the settled body

*2026-08-20, F-284.*

Every check that asks "is this map's spawn standable" reads the spawn from the level's `Player`
node **captured off `packed.instantiate()`, before `add_child()` and before a single frame**, and
cross-checks it against the layout JSON's own `spawn` record. It never reads `player.position`
after the warm-up frames.

**Why:** the level's `Player` is a real `CharacterBody3D`. It falls. Hollowmere's authored spawn is
y = 2.423 and the ground under it is y = 2.023; sixteen warm-up frames later the node reports
2.023, because it landed. A vertical assertion written against that number grades *the terrain's
ability to catch a falling body* and passes for a spawn authored ten metres in the air or a metre
inside the terrain alike — which is exactly the class of bug F-284 exists to catch, surviving the
check meant to catch it. The three checks that read this node all did so post-warm-up; two escaped
only because their assertion happened to be horizontal-only, which is luck, not design.

**The pairing that makes it map-agnostic:** both world scripts answer two public calls,
`height_at(x, z)` and `water_surface_at(x, z)`, and "standable" is defined from that pair alone —
ground above water by a clearance, spawn on the ground within a band. `AuthoredWorld` derives the
surface from the layout's water bodies (the same `_water_level` geometry `_build_water` meshes),
`ProceduralWorld` answers `SEA_LEVEL`. So the shared phase cannot tell which map it is holding, and
a future map gets the assertion for free — F-076's founding rule, honoured rather than restated.

**Do not "simplify" this** by letting the check reach into `AuthoredWorld._water_level` directly, or
by asserting the water test only where a layout exists. A map that cannot answer where its water is
must FAIL rather than skip: a silent skip is indistinguishable from a dry map, which is F-076's
blind spot arriving through the door marked "generic".

**What would change my mind:** a spawn source that is no longer a node in the scene — if PlayerNet
ever takes the spawn from the layout record directly, the record becomes the only truth and the
node cross-check retires with it.

---

### D-170 · 2026-08-20 · F-287: scene-derived VFX state is pruned by the node it came from, never cleared wholesale on `run_restarted`

**The decision.** `EnvironmentVfx` records, for every emitter site, the instance id of the prop it
was registered from, and retires a site when that prop is freed or leaves the tree. It does **not**
clear its site arrays when a run restarts. The clearing version of this fix is not a cheaper
variant of the same thing — it is a different, wrong behaviour.

**Why the obvious fix is wrong.** `EventBus.run_restarted` fires on *both* maps. On the procedural
map it accompanies `ProceduralWorld.rebuild_for_seed()`, which frees the island and builds a new one,
so a blanket clear happens to be right there. On the authored map nothing is torn down at all:
Hollowmere's props stand through the restart, every one of them already carries `VFX_META` from its
first registration, and `_apply_node()` early-returns on that meta — so the re-walk that is supposed
to repopulate the arrays skips all of them and the map goes dark for the rest of the process. Five
fires, 101 crystals, 161 spore sites, no error, no log line. `tools/environment_vfx_reseed_check.gd`
plants a survivor prop outside the rebuilt subtree and asserts it keeps its site; that assertion
exists to fail if someone later "simplifies" this into a clear.

Stripping `VFX_META` from the surviving nodes to force re-registration is the other exit, and it was
rejected: it re-dresses shared mesh resources to solve a bookkeeping problem, and it makes the cost
of a restart proportional to the whole scene rather than to what actually changed.

**The membership test is `not is_instance_valid() or not is_inside_tree()`, in that order.**
`remove_child()` is synchronous and `queue_free()` is not, and the teardown that matters here does
both in that sequence — so during the frame a run restarts, every node of the ended island is still
a perfectly valid instance and only the tree test can tell it is gone. Any future prune written
against validity alone will silently do nothing at the one moment it is needed.

**Where it runs, and why two places.** A deferred prune-and-re-walk on `run_restarted`, and a prune
on the existing quarter-second budget tick. The signal is the shipped boundary but not the only one:
`rebuild_for_seed()` is public and announces nothing, so a console reroll or a check driving it
directly is invisible to any subscriber. The periodic prune is what makes the invariant true rather
than merely usually true — and it is strictly cheaper than the nearest-first sort that tick already
pays, so "prune only on the signal to save time" is a false economy.

**Scope.** This is `EnvironmentVfx` state — no authority, nothing on the wire, `ARCHITECTURE.md`
§2.2 "VFX, audio, camera, UI". The same reasoning applies to any autoload that discovers nodes via
`node_added` and caches something derived from them; today that cache is the only one that
accumulated (`F-286` is the same class in `CraftingService`, filed separately).

**What would change my mind:** a generator that reuses prop nodes across a rebuild instead of
freeing them. Then "still in the tree" stops meaning "still the current island", and the source
record would need a generation counter rather than a liveness test.

**D-number hazard (F-283).** Taken by reading the file's tail; D-169 was the highest at the time.
Still no atomic allocator, so a concurrent lane could take D-170 too.

### D-171 · 2026-08-20 · F-288: a parity assertion compares the FULL ordered contract with exact deep equality, and proves its own comparator before the parity is trusted
Two rules for every check that asserts "these two derivations agree" — same seed twice, a rebuild
versus a boot, host versus client:

**1. Compare the whole ordered record, exactly.** A `size()` compare is not a parity assertion, and
neither is a spot-check of two convenient fields. `run_reseed_check` phase 5 claimed a rebuilt island
was "byte-identical" to a booted one on the strength of four terrain samples and an equal POI *count*
— a rebuild that kept the ended run's transforms passed it (F-288). `procedural_world_check` compared
position and `def_id` and let rotation and scene path through. Flatten the record to an `Array` of
per-item `Array`s, read fields by explicit key, and compare with `==`: deep `Array` equality walks it
element by element with exact float comparison. Prefer that to a formatted fingerprint string —
`poi_check.gd`'s rounds position to 3dp, which is right for the question it asks and wrong for
anything guarding cross-peer derivation, where the drift you are hunting is smaller than the
rounding.

**2. The comparator asserts itself first.** The failure mode here is not a wrong answer, it is an
assertion that proves nothing while printing PASS — so a replacement that also proves nothing closes
the finding and changes no facts. Before trusting a match, perturb a duplicate of one side by the
smallest change that must matter (F-288 adds `0.001` to one site's `rotation_y`) and assert the
comparator sees it. A comparator that flattened everything away then fails at the top of the phase
instead of passing quietly at the bottom. This is also the standing substitute for pre-fix sabotage
when the file you would have to break is held by another lane: sabotage proves the assertion once, in
a commit nobody keeps; the self-test proves it on every run forever.

**Would change my mind:** an exact deep compare that turns out to be flaky across platforms for a
value we genuinely do not control bit-for-bit (a physics-settled transform, say). The answer there is
a documented `is_equal_approx` walk with a stated tolerance and the same self-test — not a return to
counting.

### D-172 · 2026-08-20 · F-290: a `user://` file two processes share is written by RENAME, and a check that counts malformed input parses SILENTLY

Two rules, both about the check harness rather than the game.

**1. Any file one process writes while another polls it is written to a `.part` sibling and
`DirAccess.rename_absolute()`d into place.** `FileAccess.open(path, FileAccess.WRITE)` is
truncate-then-refill: for the width of one `store_string()` the file on disk is empty or half a
document, and a reader that lands there gets a torn payload. In this repo that reader is always
`JSON.parse_string()`, which `ERR_PRINT`s — so the cost is an undeclared `ERROR:` line inside a run
that retries, recovers, prints `failures=0` and exits 0. Standing rule 4's exact failure mode, and
invisible precisely because the check still passes. `rename(2)` swaps a directory entry in one step,
so the reader sees the previous whole document or the next one, never a partial one. Pair it with an
`if raw.is_empty(): return {}` guard on the read and a startup cleanup that removes the `.part`
sibling alongside the target. `tools/json_result_race_check.gd` measures both forms head to head and
gates on the renamed one being torn zero times.

**Do not instead declare `Parse JSON failed` as an `EXPECTED_ERROR_PATTERNS` entry.** Malformed
transport is not an intentional test case in any of these files, and declaring the pattern blinds
the whole family to a probe that really did write garbage. Fix the writer.

**2. A check that deliberately reads possibly-malformed input uses `JSON.new().parse()`, never the
static `JSON.parse_string()`.** The instance method returns an `Error` and sets `error_line`
silently; the static one prints. A check whose job is to *count* torn or corrupt reads must not emit
an engine ERROR per one it finds — it would fail its own standing-rule-4 grep at the moment it
succeeds at its measurement. Same applies to any check exercising a corrupt-save or bad-payload path
where the count, not the log line, is the assertion.

**Scope note.** Rule 1 is a property of the *pair* — writer and concurrent reader — not of the write
call alone. A one-shot generator writing files nothing is polling (`setup_harvest_content.gd`) is
fine as it stands; adding staging there is noise.

**Windows caveat, recorded not fixed.** Godot's `DirAccessWindows::rename` removes an existing target
before moving, so the swap is not atomic there the way it is on macOS/Linux. Every file governed by
this rule is a dev-machine `tools/` check that never ships, so the caveat costs nothing today. It
would matter the moment this pattern is used for a real save path — and `core/save/*` uses
`FileAccess` directly, so it is not.

**What would change my mind:** a platform where `rename` over an open file fails rather than
succeeding. Then the reader needs a retry-on-parse-failure loop with a silent parser, which is
strictly worse — it reintroduces the torn read and merely stops logging it.

**D-number hazard (F-283).** Taken by reading the file's tail; D-171 was the highest at the time.
No atomic allocator, so a concurrent lane could take D-172 too.

---

### D-173 · 2026-08-20 · F-279/F-298/F-308: a `run_restarted` handler may gate on authority only for the parts that are replicated, and a restart teleport is CLIENT-local

Two rules, one file's worth of bugs apart, both about `EventBus.run_restarted`.

**1. `run_restarted` reaches every peer — so a handler that opens with an authority gate must first
reset everything behind that gate the peer owns privately.** The event is not host-only: a client
re-derives it from the `WorldDeltaLog` record through `CycleService._on_world_delta_applied()`. That
makes `if _owns_mutation(): host_reset_for_new_run()` a *correct* line only when every field the
reset touches is replicated back down to the client afterwards. Where it is not, the client is simply
never reset, and the failure is quiet because the host and every solo player look fine.

Three shipped instances, all now fixed, all the same silhouette:

- **`PlayerHealth` (F-298)** — `_local_stamina` / `_sprint_locked_out` are client-simulated by design
  (§2.2 row 1; the host's copy is explicitly advisory and rides in no snapshot). A client that
  sprinted into the lockout as the run ended started the next run still locked out.
- **`InventoryService` (F-308)** — `_local_revision`, the peer's private staleness guard. The restart
  re-seeds the host's `_revisions` to 0, so every snapshot of the new run arrives *below* the value
  the client carried and `net_inventory_snapshot()` discards all of them. The client keeps the ended
  run's items and swallows the new run's transactions until the counter climbs back past the old
  value. Nothing republishes on a timer here, so unlike `PlayerHealth` it never self-heals.
- **`CycleModifierService` (F-254)** — `_announced_draws`, already split above the gate, with a
  comment saying why. That one was found first and is the shape the other two now copy.

The fix is always the same two lines: the unreplicated reset first, unconditional; the host's world
rebuild behind the gate. Resetting the local cache first is safe rather than merely tolerable — it
resets *to* the values the incoming host snapshot carries, and clearing the revision is what lets
that snapshot apply at all.

**A grep, not a memory:** `grep -rn --include='*.gd' subscribe_run_restarted .` and read each
handler's first line. 22 subscribing files outside `tools/` as of this decision; exactly the three above
gate at the top and the other 19 are unconditional. **Anything new that gates must say in a comment
which replicated field justifies it.**

**2. Moving a player body on a run restart is CLIENT-local, never a host `rpc_id`.** Own player
movement is §2.2 row 1, and a restart is the one teleport the client already knows about — the event
reaches it. So each peer calls its own `PlayerHealth._teleport_local_to_spawn()`, exactly as
`ProceduralWorld._replace_players()` has done since F-258.

The host-driven alternative — looping `_teleport_to_spawn(peer_id)` over `_states`, which sends
`net_force_respawn.rpc_id()` — is right for a **bleed-out respawn** and wrong for a **restart**, and
the difference is worth stating because the two calls sit six lines apart in the same file:

- A respawn is host-timed. No client can predict it, so the host must tell it. Keep that path.
- A restart is an event the client already receives. Pushing a transform on top of it races: the RPC
  and the `run_restarted` delta travel on different reliable streams with no ordering between them
  (F-278 measured that head-of-line asymmetry at 5 smeared frames on the clock).
- On the procedural map the host's `_spawn_transforms` entry for a *remote* peer describes the
  **previous** island — D-161 draws a fresh seed per run — so the host would be teleporting somebody
  onto a shore this seed may have put underwater. F-063's bug by another route.

Client-local makes the ordering intra-process and therefore deterministic: the `PlayerHealth`
autoload's handler runs first (it subscribes in `_ready()`, before any level node does) and
`ProceduralWorld` then overwrites body *and* spawn record with the new island's shore inside the same
synchronous emit.

**Proving it needs two processes and one deliberate disagreement.** With a single peer the local
player IS the host and both designs are indistinguishable. `tools/run_restart_spawn_check.gd` has its
probe move its **own** spawn record 40 m via the client-local `rebind_local_spawn()` before the
restart, so the host's copy is knowingly stale; a host-driven fix lands the client on the host's
version and fails. Any future change to this path is verified the same way or it is not verified.

### D-174 · 2026-08-20 · A consumer of state another subscriber produces reacts to the SECOND event and is idempotent — it never relies on autoload/subscribe order
**Context.** `EventBus` invokes listeners in append order, and autoloads append in `project.godot`
order. That makes autoload registration order a load-bearing gameplay input the moment two
subscribers of the same event stand in a producer/consumer relationship — and nothing about
`project.godot` says so, so any later reorder silently changes behaviour. F-282 is the incident:
WaveSpawner (line 44) asked `CycleModifierService.has_modifier(&"the_hunt")` from its own
`cycle_advanced` listener, and CycleModifierService (line 61) had not drawn yet. The Hunt's elite
entered one whole Cycle late for the life of the feature.

**The decision.** When one subscriber of event E produces state a second subscriber of E consumes,
the consumer does **not** read that state from its own E handler. It reacts to the **second event**
the producer emits when the state is actually ready, and its reaction is made **idempotent** so both
seams may drive it. Concretely, in this repo:

- Subscribe to the completed-action event (`cycle_modifier_drawn`, `salvage_banked`), not only to the
  trigger event (`cycle_advanced`, `run_wiped`).
- Keep a per-occurrence stamp or latch so the action happens exactly once regardless of which event
  arrives first — `WaveSpawner._hunt_spawned_cycle` (per Cycle),
  `DefeatHud`/`ExtractionHud._salvage_known` (per run).
- Use the id the event **carries** for that stamp, never a cached copy of it, so the stamp is right
  even when the two handlers run in the unexpected order.

The test of a correct implementation is that **reversing the two autoloads in `project.godot` changes
nothing**. If it would, the consumer is still order-dependent and the decision is not satisfied.

**Why not the two obvious alternatives.**

*Reorder the autoloads.* It fixes one pair and encodes the dependency somewhere nobody reads. The
next autoload inserted between them re-breaks it with no failing check, and `project.godot` is
explicitly never claimed (F-051), so the constraint has no owner.

*Move the trigger to the second event only.* This is where F-282 nearly went wrong. The Hunt spawns
one elite **per Cycle** for the rest of the run (`content/cycle_modifiers/the_hunt.tres`), but a
modifier is drawn **once**. Driving purely off the draw would have replaced "one Cycle late" with
"exactly one elite, ever" — a quieter bug in a feature nobody had been able to see working. Both
seams, plus idempotence, is what keeps the cadence and fixes the ordering at once.

**Precedent, arrived at twice independently.** `DefeatHud`/`ExtractionHud` already do exactly this
for the run summary: neither reads the banked total from its `run_wiped`/`run_extracted` handler
(`SalvageService` subscribes the same events and may not have banked yet). They render a "Tallying
Salvage…" placeholder and fill it from `salvage_banked` behind `_salvage_known`. F-282 reached the
same shape from the other end. Two independent arrivals is what makes this a rule rather than a
comment in one file.

**Scope.** Shipped code only, and it is currently satisfied everywhere: F-282's sweep read every
`EVENT_BUS.subscribe_*` handler outside `tools/` and found `WaveSpawner` the only violator. The other
six modifier consumers (`Chest`, `Harvestable`, `MireGrid`, `Wellspring`, `DayNight`, `Enemy`) are
immune by a different route this decision also blesses: they read `has_modifier()` **on demand, at
the moment the effect matters**, never from an event handler at all. That remains the preferred shape
where the effect is a query rather than a one-shot action — it cannot be early, and it needs no
stamp. This decision governs the cases where the consumer must *act* rather than *answer*.

Verification of the class belongs to the checks, and those cannot currently see it: see **F-310**.

**Would change my mind:** an explicit, enforced listener-priority mechanism on `EventBus` —
`subscribe_*(listener, priority)` with a check that fails when two subscribers of one event declare
the same priority and one reads the other's state. That would make ordering a *declared* contract
instead of an emergent one, at which point a consumer could legitimately read from its own handler
and the second-event dance becomes ceremony. It is not worth building for the one pair that exists
today; a third independent occurrence of this shape is the signal that it is. Equally: if an event
ever needs a consumer to act on the trigger *itself* — where reacting to the completed action is
observably too late for the player — this rule loses to that, and the ordering must instead be made
explicit at the producer (a direct call, not a subscription).

### D-175 · 2026-08-20 · F-286: a cache derived from the world is keyed by a generation counter it PULLS, not cleared by an event it subscribes to

**The decision.** `EventBus` now carries `world_rebuilt` — "a world composer just re-derived its
contract nodes in place" — emitted at the END of `ProceduralWorld.rebuild_for_seed()`, plus
`EventBus.world_generation()`, a monotonic count of those emits bumped **before** the dispatch. A
consumer that holds *state to reset* subscribes. A consumer that holds only a *cache derived from
the scene* folds `world_generation()` into its cache key and subscribes to nothing.
`CraftingService._station_positions_for()` is the worked example and the reason the rule exists.

**Why the pull half, when subscribe-and-clear is the obvious fix.** Three reasons, and the second is
the one that would have bitten:

1. **There is nothing to reset.** A handler that exists solely to clear a cache is a subscription
   kept alive, unsubscribed on exit, and ordered against every other subscriber, to do what one
   integer comparison in the key does for free. `CraftingService` deliberately idles with
   `set_process(false)` (F-099); this keeps it that way.

2. **A handler races dispatch order; a key cannot.** `ProceduralWorld` subscribes to `run_restarted`
   from `_ready()`, and every autoload subscribed earlier — so an autoload's handler runs *while the
   ended island is still standing*. Clear the cache there and the next query, still inside the same
   frame, re-caches the dead coordinates and the bug survives its own fix. D-170 hit this from the
   other side and had to `call_deferred` its whole rediscovery to get around it. A counter read at
   the query itself has no ordering to lose: whenever the query lands, it sees the generation that
   is current at that instant.

3. **`rebuild_for_seed()` is public and `run_restarted` is not the only way in.** A console reroll
   or a `--script` check calling it directly fires no restart at all. D-170 covered that gap with a
   quarter-second periodic sweep because nothing announced the call; `world_rebuilt` now does, and
   the pull key covers it with no sweep at all.

**The emit goes LAST, and the counter goes UP FIRST.** Last, because every contract node —
`PoiSites`, `SpawnMarker`, the marker groups — must already be published when a handler re-reads the
tree, or the handler sees the island it is being told is gone. First, because a subscriber that
consults a generation-keyed cache from inside its own handler has to see the new value, not the one
it is being notified about.

**Boot does not emit.** A first build changes `current_scene`, which every scene-keyed consumer
already watches. `world_rebuilt` means "rebuilt in place" specifically, and widening it to mean
"a world exists now" would make it useless for the one thing it is for.

**This does not overturn D-170, and the two are not in tension.** "Prune by source, do not clear" is
about `EnvironmentVfx`, whose re-walk is blocked by `VFX_META` early-returns, so a clear on the
authored map leaves it permanently dark. `_station_positions_for()` re-derives unconditionally from
the live groups; dropping it is always recoverable. Same class of bug, opposite fixes, and the
difference is in the mechanism rather than in preference: **before choosing clear-or-prune, ask
whether the re-derivation is unconditional.** If anything can make the re-walk skip what it is
supposed to find, clearing is a silent regression waiting to happen.

**Scope.** `ARCHITECTURE.md` §2.2 unchanged. Crafting stays host-authoritative — this was a defect
*in* that row, not a move of it — and `EventBus` still sends nothing. `world_rebuilt` has exactly
one producer today (`rebuild_for_seed()` is the only in-place world rebuild in the repo) and a
second producer would be a new map generator, not a new caller.

**What would change my mind:** a consumer that must act on the rebuild *before* the new island is
published — the D-174 case, where reacting to the completed action is observably too late. Nothing
has that need yet, and a consumer that grows one wants a direct call from the producer, not a second
event fired earlier.

**D-number hazard (F-283).** Taken by reading the file's tail; D-174 was the highest at the time.
Still no atomic allocator, so a concurrent lane could take D-175 too.

### D-176 · 2026-08-20 · state.json mutations go through state_txn, and the transaction never spans a subprocess
**Context: F-266.** Every mutating `agent` command was `load()` -> check -> mutate -> `save()` with
no lock, so two lanes could both read a state where a task and its files were free, both pass the
conflict check, both print `✓ claimed`, and the later `save()` erase the earlier one silently. The
fix adds `state_txn()` — `flock` on `.agent/locks/state.lock`, re-entrant, held across the whole
window — plus atomic writes for `state.json` and `BOARD.md` and a `rev` compare-and-swap in
`save()`.

**The rule this decision fixes is the scope of that lock, not its existence.** The obvious
"improvement" is to wrap every command in `COMMANDS` uniformly, or to widen `_saturate_locked()`'s
two brackets into one. **Do not.** `state_txn()` is taken by every single `agent` invocation across
five or six concurrent agents, so anything it is held across, every other lane waits behind.

- **Wrap in `COMMANDS` (`in_state_txn`) only commands whose whole body is local and short**:
  `claim`, `note`, `done`, `handoff`, `drop`, `reopen`, `sync`, `reap`. These are milliseconds.
- **Bracket the window inside the body** when the command does anything else worth not blocking on:
  `start` and `board` print a `git status`/`git log` summary afterwards; `order` writes order files
  and renders a brief; `saturate` runs a whole lane dispatch.
- **Never hold it across a subprocess.** `_saturate_locked()` keeps its two writes — the pre-dispatch
  intent marker and the post-run marker cleanup — in *separate* transactions because an entire lane
  run, capped at eight hours, happens between them. One transaction spanning both would freeze every
  other agent's board for the length of that run, which is a worse outage than the race it closes.
- **Lock order is always outer-resource -> state.** `ship` holds `file_lock("git")` and reaches the
  state lock only through `save()`; `_saturate_locked()` holds its lane lock and takes short state
  transactions inside it; `godot`/`findings`/`decisions`/`project` never take the state lock at all.
  Nothing goes the other way, so there is no cycle. A future command that takes the state lock and
  then a `file_lock` would introduce one — take the `file_lock` first instead.

**`save()` self-locks when it is not already inside a transaction**, so a write can never be
unserialised even if a future command forgets to bracket. That is a safety net, not the mechanism:
it makes the *write* atomic but does nothing for the read-check that preceded it, which is where
F-266 actually lived. Bracket the window.

**The `rev` counter is an alarm, not the lock.** Under the transaction it can never disagree. If
`save()` ever refuses with "it changed under this command", the correct response is to find the code
path that reached `save()` with a stale state — not to raise the threshold or drop the check.

**Would change my mind:** a measured case where the millisecond-scale lock is itself the contention
bottleneck — i.e. `agent` commands visibly queueing on `.agent/locks/state.lock` under normal lane
load. The answer then is a finer-grained state file (splitting `claims` from `tasks`), not a wider
or absent lock. `tools/agent_state_lock_check.py` is where the evidence for that would be built.

**D-number hazard (F-283):** allocated by `agent decision` under `file_lock("decisions")`, which is
F-260's atomic allocator — not by reading the file's tail.

### D-177 · 2026-08-20 · F-273: `GameState.seed_ready` is the RUN-boundary hook, and every subscriber's handler must be idempotent — the signal can fire twice for one boundary
Settles what F-258/D-161 changed but never wrote down, so nobody has to re-derive it from three
files the way F-273 did. The signal's declaration in `core/game_state.gd` now carries this verbatim
and `tools/seed_ready_contract_check.gd` holds the code to it.

**`seed_ready` is a RUN boundary on every peer — not a session boundary, not host-only.** It fires
from `host_generate_seed()` (session start via `NetTransport.server_started`, plus `MireGrid`'s lazy
`ensure_seed()` at boot), from `host_redraw_seed()` (`CycleService.host_restart_run()`), and from
`set_replicated_seed()` on a client (`WorldDeltaLog.net_world_snapshot()` for a mid-run joiner,
`_on_world_delta_applied()` for a reseed reaching a peer already here). Before D-161 the first of
those was the only one that mattered, which is why two subscribers' comments said "once per hosted
session" for a week after it stopped being true.

**A subscriber's handler must be IDEMPOTENT, because one boundary can emit more than once.** A
single `host_restart_run()` fires it TWICE on the host with the same value: once for
`_host_redraw_world_seed()`, once again for `WorldDeltaLog.host_reseed()` → `_reseed_local()` →
`set_replicated_seed()`, which deliberately runs on the sending side too so the host and a receiving
client cannot drift in what a reseed MEANS (D-161). So a handler may zero, assign or re-derive; it
may never increment, toggle, advance a phase, or count boundaries. Both shipped service subscribers
are zeroing resets and `MainMenu`'s re-derives a whole label, so the rule costs nothing today — the
point is that it is now stated before a fourth subscriber assumes otherwise.

**Deduplicating the double emit was considered and rejected.** A `run_seed == value` early-out in
`set_replicated_seed()` would collapse it, but that method's contract is explicitly "safe to call
host-side with its own value — idempotent, so callers never need to branch on who they are", and a
client re-adopting an unchanged seed after a reconnect must still get the reset. Guarding the emit
would turn a loud, harmless duplicate into a silent missed boundary in exactly the case (a repeated
or replayed delta) where a subscriber most needs the reset. Idempotent handlers are the cheaper
invariant, and the census phase of the check is what keeps them idempotent.

**`GameState.reset()` is a session END and does not fire this signal.** Session end and run boundary
are different events; only the second one is on `seed_ready`. Anything that needs the first listens
to `NetSession.session_ended`. Anything that must re-derive its WORLD rather than a per-run tally
hangs off `EventBus.run_restarted` instead, which arrives immediately after the reseed on the same
reliable channel.

**Would change my mind:** a subscriber appears whose per-run work is genuinely not idempotent —
something that must run exactly once per boundary (a one-shot telemetry event, a save write, a UI
animation). At that point the right fix is not to loosen this rule but to give `CycleService` a
distinct once-per-boundary emit, because the duplicate is structural in `host_restart_run()` and
will not go away by being ignored.

### D-178 · 2026-08-20 · F-281: the run-scoped reset enumeration lives in `tools/run_scope_audit_check.gd`, not in D-149's prose — every autoload is classified, and the classification must be TOTAL

D-149 wrote the enumeration as a sentence: "Only RUN-scoped state resets: Cycle, Mire corruption,
Cycle Modifiers, inventory, health, enemies, buildables, chest/wellspring/ship progress." That
sentence was accurate the day it was written and has been short ever since. It went short four times
in five days — F-259 (`WaveSpawner`), F-268 (`BuildService`, and `HaulService` in its own sweep),
F-277 (`AttunementService`), F-278 (`DayNight`) — and **three of those four were found twice, by two
different lanes, independently**, because each lane redid the same `grep -l subscribe_run_restarted`
by hand and each got a slightly different answer about what the remainder meant. F-281 exists only
because one of those sweeps wrote its leftovers down.

**Why a check and not a better-maintained list.** Prose cannot fail. The failure mode is never "the
list was wrong when written"; it is "somebody added an autoload and nobody re-read the list", and no
amount of care in the writing addresses that. `tools/run_scope_audit_check.gd` classifies every
autoload in `project.godot` as either `RESETS` (it subscribes `EventBus.run_restarted`, asserted) or
a one-line reason why it does not (asserted to still not subscribe). **The load-bearing property is
totality, not the contents**: an autoload nobody classified fails the check, which is the one moment
somebody is forced to actually decide whether the thing they just wrote is run-scoped. That moment is
precisely what the four rediscoveries above were each missing.

**Why the reasons are asserted in both directions.** A reason that has quietly become false is how
F-259 and F-277 were both missed on a first pass — the sweep saw a name it recognised, remembered a
justification, and moved on. So a file carrying a "not run-scoped" reason that starts subscribing
fails the check too: the reason is now stale and the row must be reclassified. The reasons are also
the answer to "was this considered?", which is the question every one of these rediscoveries
re-asked from scratch.

**Why the non-autoload half is listed separately.** D-149 chose per-node `host_reset_for_new_run()`
over a scene reload for Chest, Wellspring and ExtractionShip, so a third of its own enumeration lives
in the level tree where an autoload sweep structurally cannot see it — as do `ProceduralWorld`
(D-161) and `ResourceScatterField`. `SCENE_SCOPE` names those five explicitly so the autoload-sweep
habit stays honest about what it does not cover.

**What this does NOT assert.** Only that the subscription exists — not that the handler resets the
right things. That half stays with the behavioural checks (`run_restart_check`,
`day_night_restart_check`, `attunement_restart_check`, `harvest_restart_check`,
`run_restart_spawn_check`, `run_restart_net_check`), and it is a real gap: F-303 is a subscriber
whose handler resets the wrong quantity, and this check would pass it. The split is deliberate —
subscription is a source fact one cheap check can pin for all 65 files, behaviour needs a booted
world per system.

**Would change my mind:** `EventBus` gaining a runtime-enumerable subscriber registry. The
source-text scan exists because the static `Callable` registry cannot be listed at runtime and a
booted probe would only see nodes that happen to be in that tree; given the list, this check becomes
a runtime assertion and stops being a grep.

**Amendment · 2026-08-20 (ivy1bcae0, F-328): the first three autoloads this caught, and what it
caught.** MENU-2/5/7 registered `ui/menu_stack.gd`, `ui/menu/pause_menu.gd` and
`autoload/run_record.gd` without classifying them, taking `project.godot` to 63 autoloads against a
map of 60 — so the check went red exactly as designed, on its first real test. The three
classifications, and the reasoning this amendment exists to record:

- **`MenuStack` — session-scoped.** Its state is the stack of screens the *player* opened. A run
  boundary does not make an open Settings screen wrong, and a screen that does care about the run
  pops itself; the stack is navigation, not run state.
- **`PauseMenu` — session-scoped.** Its only state is `_screen`, and that is cleared by the screen's
  own `tree_exited`, so it structurally cannot outlive the thing it points at.
- **`RunRecord` — RUN-scoped, and it was not resetting.** This is the one the tripwire was built for.
  `_pending` accumulates half a record — `run_extracted`/`run_wiped` supplies the ending and Cycle,
  `salvage_banked` supplies the figure — and `_flush_if_ready()` clears it only when *both* halves
  arrive. An ending that banks nothing (a Cycle 1 wipe whose fractional Salvage rounds to zero, so
  `salvage_banked` never fires) leaves `{ending, cycle}` behind. The next run's `salvage_banked` then
  completes *that* stale record, and the title card shows the previous expedition's Cycle and ending
  against this run's Salvage: one run's brag attributed to another. `RunRecord` now subscribes
  `run_restarted` and clears `_pending`.

The general point, restated because it is the return on the check: nobody was careless here. Three
autoloads shipped in one menu milestone and the question "is any of this run-scoped?" was never put
to anyone. Totality is what put it.

**Amendment · 2026-08-21 (flinta92725, F-413): `GodModeService` is session-scoped.** God mode is an
operator playtesting knob, like a live gamerule: restarting the current run must not silently undo
the tester's chosen environment. It clears when the network session/process ends and deliberately
does not persist to disk. `tools/run_scope_audit_check.gd` records that classification; the retired
`SettingsMenu` autoload was removed from the enumeration entirely.

### D-182 · 2026-08-20 · A duplicated D-number is repaired by renumbering the LATER entry, and the citations move with it
F-260 gave `agent decision` an allocator, so a new collision is now impossible; F-283 had to decide
what to do about the three already in the file (`D-050`, `D-144`, `D-150`, each heading two
unrelated decisions). Two outcomes were open — renumber, or keep the pairs as historical record and
document them — and the rule below is the one to reuse, because the choice recurs every time a
hand-written heading slips past the allocator.

**Renumber, and renumber the LATER member.** The earlier entry keeps the number it was correctly
allocated; the later write is the one that created the collision, so the later write is the one
that yields. This is mechanical rather than a judgement about which decision matters more or which
has fewer citations — and mechanical is the point, because "renumber whichever is cheaper to
rewrite" makes the outcome depend on who is holding the file that day. D-050's second entry became
D-179, D-144's became D-180, D-150's became D-181.

**Every citation moves in the same commit, classified by reading its prose — not by `sed`.** The
numbers are ambiguous by construction, so a blind rewrite is guaranteed to break the half that
meant the entry that kept its number. F-283 read all 34 in-repo citations: three `D-050` sites that
look like the powerup entry are actually the attack-style entry (`tools/build_check.gd`, two in
`docs/DELEGATION.md`, one in `docs/FINDINGS.md`), and every `D-144` outside `docs/NEXT.md` is the
terrain split, not the file-claims decision.

**Two things are deliberately NOT rewritten.** `.agent/JOURNAL.md` is an append-only record of what
was true when it was written, and a renumbered citation there would be a false record of a past
session; git history is the same. The renumbered entry instead carries a one-line breadcrumb naming
its old number, so a `grep D-050 docs/DECISIONS.md` from an old journal line or an old commit lands
on the pointer rather than silently on the wrong page — the same job `*Superseded by D-0NN.*` does
for a dead rule, and the reason a renumbering pass is not a `git mv` of the text.

**`python3 tools/decision_ref_check.py` fails on a duplicate heading** as of F-283, so this rule is
only ever needed for a heading written by hand around the allocator.

**Would change my mind:** a collision where the later entry is the one every citation in the repo
and every queued work order means, and the earlier is a one-line stub nothing references — then the
mechanical rule costs more than it saves and the pair should be renumbered the other way, with the
exception recorded here rather than left as a silent precedent.

### D-183 · 2026-08-20 · A loop-critical POI is guaranteed by marking its content `required`, not by a fallback in the composer
F-301 shipped islands with no crafting station on 17 of 132 seeds. Two fixes were open and the
finding named both: add a mandatory-POI pass to `world/gen/`, or stamp a fallback station near the
spawn when placement drops one. Neither was needed, and the reason is worth stating because the same
choice arrives every time a new fixture becomes load-bearing.

**The mechanism already exists and it is content-driven: `PoiDef.required` plus D-152's relax
ladder.** `poi_map.gd._place_kind()` already re-runs its dart loop at two documented relax rungs
when a `required` def places nothing, on the same continuing RNG stream so every peer still derives
the identical island. It was already doing this for the wellspring and the shipwreck on the exact
seeds that lost the station. The station was missing one boolean in `content/poi/station_camp.tres`.
So the fix is one content field, and `world/gen/` is untouched.

**A spawn-adjacent fallback would have been worse, not merely redundant.** It is a second placement
path with its own determinism surface, and it puts the station somewhere no POI rule chose — the
failure F-063 is about, arriving by a different route. A rung of an existing ladder is a placement
the layout still owns.

**The corollary, and it is the part to reuse: the loop's fixture list and the `required` flag are
two different questions, so they get two different enforcement mechanisms.** `required` is a
CONTENT declaration — "this def is worth relaxing terrain fit for". Whether the island ends up with
a chest to open or somewhere for the night wave to spawn is a CONTRACT demand, made by
`tools/world_contract_check.gd`, and `loot_cache`/`enemy_nest` satisfy it today with several sites
each and no relax ladder at all. Flagging those `required` to be safe would be cargo cult: it
changes nothing while they place (the ladder only fires at zero), and it quietly asserts a design
intent — "one of these is worth a tilted, out-of-biome placement" — that nobody made. They are
covered by a seed sweep in `tools/poi_required_station_check.gd` instead, which fails at the content
change that first loses one and names the seed.

**Would change my mind:** a fixture whose def genuinely cannot be satisfied by any relaxation the
ladder permits — spacing is never relaxed by design, so a def whose target count exceeds what its
own `min_spacing_m` allows on the island cannot be rescued by `required` at any rung. That case
needs the spacing content fixed (F-319) or a real fallback, and this decision does not cover it.

### D-184 · 2026-08-20 · MIRE island terrain targets Muck: mostly flat, gentle rolling hills, no mountains — supersedes the 4.13 ridged-silhouette goal
Sequoyah's island-feel verdict (2026-08-20, 4.18's tuning input, given off the first shipped
procedural island renders): "the map should be mostly flat, some gentle rolling hills is nice but
no mountains, look at muck for reference." This supersedes D-142/D-144's Hollowmere-derived
"plateau/ridge silhouette" as the AMPLITUDE target — the ridged layer machinery stays (D-144's
only-add rule, the mask, the biome amplitude tables all hold), but it is tuned as rolling texture
(RIDGE_WEIGHT 2.0), not a skyline, and HEIGHT_SCALE/LAND_BIAS sit at 11/0.75 so the interior is
sprintable end to end. Valheim remains the lighting/atmosphere reference; Muck is the terrain-shape
reference. Applied in world/gen/island_heightmap.gd by quill5fa5c7.

**Would change my mind:** Sequoyah walking a retuned island (a real 4.18 walk, not renders) and
asking for more verticality back — the tune is three constants, so reversal is cheap and needs no
structural change.

**2026-08-20 second pass (same day, his next verdict):** "still wayyy too steep on the hills, im
thinking like 3-5 hills on the whole island." Countable hills is a structure, not an amplitude, so
the rolling-fBm interior is gone: the continent is now a near-flat plateau (`BASE_NOISE_WEIGHT
0.25` damps the noise to ~±1 m of undulation) plus **3–5 PLACED seeded hills**
(`IslandHeightmap.hills()` — smooth radial mounds, 26–52 m radius, 5–8 m lift, `maxf`-merged,
placed by the same integer-mixing recipe as the lobes). The ridge window moved above the plateau
(RIDGE_MASK 0.95–1.30) so cresting only touches hill tops. The reversal is still cheap: raise
`BASE_NOISE_WEIGHT` back toward 1.0 and the rolling interior returns.

**Third refinement (same day):** he linked the exact look — r/Unity3D post rvr9ca, "procedurally
generated low poly terrain… without mountains and coloring based on height", a flat-shaded
low-poly ground. The terrain shape above already matched; the missing half was **flat shading**,
shipped as `world/chunk/terrain_flat.gdshader` — per-facet normals from screen-space derivatives
(`cross(dFdy(VERTEX), dFdx(VERTEX))`) on the streamer's shared material. Chosen over non-indexed
per-face-normal meshes deliberately: that alternative triples every resident chunk's vertex count,
and MIRE targets the worst machines. The mesh, its smooth normals, collision and LOD are all
untouched — the shader only changes lighting. No height-based coloring either, matching the post.

**Fourth refinement (same day, call delegated — "you do whatever you think is best"):** the thread's
Delaunay link names why the reference's facets look organic where a grid's do not — irregular
triangulation. Shipped the equivalent without retriangulating: deterministic integer-hash XZ jitter
on INTERIOR chunk vertices (`ChunkMesher.VERTEX_JITTER_FRACTION` 0.35 of the LOD step, strictly
under the 0.5 that would fold a quad). Border vertices stay exactly on-grid — chunk tiling, LOD
seam divergence, skirt and perimeter indexing all key on the border and are untouched. Every
jittered vertex re-samples the analytic surface at its (float32-narrowed) actual position, so the
"every vertex sits on the ground" agreement contracts in `biome_terrain_check`/`noise_reuse_check`
hold exactly; those checks and `chunk_stream_check`'s layout assertion now read the vertex's own
stored XZ instead of assuming grid placement — same strength, no grid assumption.

---

### D-185 · 2026-08-20 · F-307: a terminal run-summary overlay whose session ends offers the way OUT, not a restart — and it leaves `blocks_gameplay_input` to make that reachable

F-307 named two candidate remedies and said the choice was a product call rather than a reviewer's.
This is that call, made for both terminal overlays (`ui/hud/defeat_hud.gd`,
`ui/hud/extraction_hud.gd`) together, because they are a deliberate pair and must not drift.

**When `NetSession.session_ended` fires under a shown terminal overlay, the overlay's single control
becomes an enabled "Leave to Menu" that opens `MainMenu`, and the overlay leaves
`blocks_gameplay_input`. It does not become "Start Next Run".**

Three parts, each of which was a real fork:

**1. Leave, not restart.** The rejected option was re-deriving the button so the orphan gets a working
`host_restart_run()`. Its own predicate invites this — `_is_host_or_solo()` genuinely flips true once
the transport is neither active nor connecting — but the predicate is answering "may I act as host",
not "is there a run here to restart". The peer's world went with the session: `PlayerNet` clears on
disconnect, and D-149's restart resets services *in place* on a world that is assumed to still exist.
Lighting the button up would be the finding's own phrasing, "the button lights up ≠ the next run is
playable", and F-279/F-281 already show that path is leaky even solo. A restart-for-orphans is a
feature (a peer promoting itself to host of a fresh solo run) and would need its own spec, its own
world rebuild and its own proof. Getting the player to a menu needs none of that and is what every
co-op game does when the host quits.

**2. The blocking group is part of the fix, not garnish.** Re-deriving the button alone leaves D-032's
interlock (`_other_blocking_ui_open()`) refusing every `set_open(true)` from `MainMenu`,
`SettingsMenu`, `LobbyMenu` and `UnlockMenu` — a screen with a working control and still no route to
a menu. So `_on_session_ended()` calls `remove_from_group(BLOCKING_UI_GROUP)`. **This is legal at
exactly this moment and nowhere else.** D-032's group means "a cursor UI owns the screen, suppress
gameplay input"; handing gameplay input back normally requires the panel to close. Here the session is
dead and the local player has already been despawned, so there is no world to be handed input to — the
group is protecting nothing. Any future member of this class gets the same permission on the same
grounds and no others: **the session is over**, not merely "the panel wants a menu".

**3. The flag is scoped to the showing, not to the process.** `_session_over` is cleared in
`_on_run_wiped()` / `_on_run_extracted()` and in `_on_run_restarted()`, and set only by
`session_ended`. This is the part that is easy to get wrong and expensive to debug: **transport state
alone cannot tell a solo host from an orphaned client** — both answer `_is_host_or_solo()` with true,
and a solo run never opens a session at all, so "is there a session right now" is false for both. Only
"the session *this showing* opened under has ended" separates them. A process-scoped flag would leave
every solo run after an orphaned one wearing the "Leave to Menu" label with no way to start a Cycle.

The overlay deliberately stays visible behind the menu — it is still that run's summary, and
`MainMenu` is a higher `CanvasLayer` (57 vs 20), so it draws and takes input over the top.

Proven by phase 3 of `tools/terminal_focus_check.gd`, against both `EndReason`s (see
`docs/SPECS.md` §F-307 for why the two children leave by different paths). The two siblings this
turned up are F-321 (`AttunementUI`, the third mandatory panel, same bug) and F-322 (nothing shipped
calls `end_session()`, which is why the ungraceful path costs 19 s).

---

### D-186 · 2026-08-20 · F-353: the daytime varnish is a `daylight`-driven grade, and every knob it moves is a DAY end whose night end is the value the scene author already set

Sequoyah's verdict on the shipped procedural island: *"im not happy with the lighting of the game
during the day, it looks super washed out and looks like it needs a coat of varnish to make
everything clear and saturated."* Measured on `assets/audit/terrain/island_spawn_view.png`, the
whole frame lived between luminance 0.477 and 0.710 with a saturation median of 0.238 — no blacks,
no whites, no chroma — and two ground samples 150 px apart differed by one 1/255 step.

**Four causes, each a single number, none of them the fog volumes everyone reaches for first:**

1. **`fog_height_density = 0.06` in the level scenes.** Godot computes the exponential fog's height
   term INDEPENDENTLY of `fog_density` and `max`es the two together, so F-115 setting
   `fog_density = 0` to "keep the open routes clear" never disabled it. Everything below `fog_height`
   (6 m — the ground, the props, the player's feet) was blended toward `fog_light_color` **at every
   distance including zero**. Isolated by render: with the height term off, the blue channel two
   metres from the camera moves 121 → 103 and ground saturation rises 0.072, while the far shore
   does not move at all. A distance-independent blend is a coat of paint, not fog.
2. **`glow_bloom = 0.14`.** This applies glow to the whole frame *below* the HDR threshold — a milk
   pass over every pixel regardless of brightness. Dropping it took the darkest pixel in the frame
   from 0.164 to 0.070. That is where the blacks had gone.
3. **`tonemap_white = 3.0` under ACES.** Godot normalises by the tonemapped white, so a white point
   of 3 maps the scene's real 0..1 range into the toe of the curve: blacks lift, highlights never
   arrive, contrast dies everywhere at once.
4. **`ambient_light_energy` running to 0.62.** D-184's terrain is flat-shaded with no texture and no
   normal map, so facet-to-facet radiance difference is the ONLY thing giving the ground form. A
   fill that strong makes a facet turned 30° off the sun read the same as one facing it.

**The decision is the shape, not the numbers.** Every value moves in
`world/environment/playtest_atmosphere.gd`'s existing `daylight`-driven block as the DAY end of a
lerp whose NIGHT end is what the scene author set — so at `daylight` 0 the grade is byte-identical
to what shipped. Three reasons this is the right shape and not just the cautious one:

- **He asked about the day.** A change that also retunes night is a bigger change than the one
  requested, judged against renders nobody looked at.
- **It quarantines F-356.** Night renders essentially black *on the shipped grade* — verified by
  rendering hour 22.0 as its own control before touching anything. Had the varnish been applied flat,
  that pre-existing failure would have looked like this change's regression and been debugged as one.
- **The file already worked this way.** `ambient_light_energy`, `tonemap_exposure`, sun energy and the
  sky colours were all `daylight` lerps already; the four new knobs are the same idiom, in the same
  driver-gated block, so they cost nothing per tick (the block early-outs whenever the drivers hold).

Terrain albedo moved with the grade — `Color(0.35, 0.45, 0.3)` → `Color(0.26, 0.40, 0.19)` in both
`chunk_streamer.gd` and the shader's own default. The old value was a greyed olive (sRGB saturation
~0.20) chosen while the grade was washing everything out anyway; with the veils gone it rendered as
a pale chartreuse sheet.

**Result, same camera and same hour, shipped vs now:** luminance p05/p95 spread 0.281 → 0.626, frame
minimum 0.164 → 0.020, saturation median 0.238 → 0.383, ground rgb(149,175,123) sat 0.24 →
rgb(98,160,62) sat 0.44. Night measures identical to shipped at hour 22.0, which is the property that
made this safe to ship.

Guarded by `tools/grade_check.gd` (headless — it asserts the veil stays off, that noon carries the
day grade, and that midnight returns to the authored values on BOTH shipped levels). Looked at with
`tools/grade_probe.gd --windowed`, which poses any hour and renders variants for A/B.

**Would change my mind:** Sequoyah walking a lit island and calling the greens too electric or the
shadows too heavy. Both are one constant each (`DAY_ADJUSTMENT_SATURATION`, `DAY_AMBIENT_ENERGY`),
and the golden-hour render at 17.2 is the frame to judge them on — it is the darkest daytime hour
and the one where a further ambient cut would start crushing.

**Two method traps this cost real time to learn, recorded for whoever tunes the look next:**
`procedural_world` builds a DIFFERENT island per probe run, so shots from two runs are two different
maps and cannot be compared — only variants within one run are comparable. And the first shot after
the settle has not converged; it reads several units darker than the identical config rendered later
in the same run, so lead with a throwaway variant or discard shot one.

### D-187 · 2026-08-21 · The three authored themes are bound to three moments, and the pairing is chosen on fatigue and shape rather than on which track is "best"

Sequoyah picked three of task 7.2's five theme candidates and said "lets use all 3". Three tracks and
three moments is not automatic — the assignment is the decision, and shipping three `.ogg`s that
nothing references is precisely F-373's failure (an asset rendered, imported, loudness-checked,
documented, and played by no code, in a game that reports no error when it goes silent). So each one
got a cue in `autoload/theme_music_director.gd`:

| Cue | Asset | Candidate | Fires on | Ends |
|---|---|---|---|---|
| `menu` | `menu_theme.ogg` | Hollowmere Hymn (folk lament) | the `mire_frontend` group being on screen | when it leaves |
| `landfall` | `theme_landfall.ogg` | Wake the Deep (heroic) | the front end going away, or booting with none | one pass, then an 8 s fade |
| `cycle` | `theme_cycle.ogg` | Mire Rites (percussive 6/8) | `cycle_advanced` at Cycle 2+ | one pass, then an 8 s fade |

**Why not the obvious pairing.** "Wake the Deep" is the biggest arrangement and the only candidate
with a real A-B-A tune, which makes it the intuitive menu theme — and the wrong one. A title screen
is the single place in this game where a track may be left running for twenty minutes, so the
binding constraint there is *fatigue*, not impact, and the calm one wins. Impact belongs where it is
heard once and then gets out of the way: landfall. "Mire Rites" builds across four stages and ends on
a hard stop, which is the shape of an escalation cue and is why it is bound to the cycle turning
rather than to a timer or to combat.

**Cycle 1 deliberately does not fire the cycle cue.** Every run already starts in Cycle 1, so a cue
there would land on top of landfall and mean nothing. `FIRST_CUE_CYCLE = 2`.

**The two bounded cues still loop.** All five candidates are rendered circularly (`render_theme.py`'s
`finish()` folds reverb and instrument decay back onto the head, same as the ambient beds), so a
non-looping playback would stop dead at the fold rather than arrive anywhere. They loop like
everything else and are retired by a timed fade over their final 8 s, so the fold is only ever heard
as the wash it was written to be.

**The bed ducks to 0.10, not to zero and not to the boss stinger's 0.28.** A stinger is a 7 s event
the bed should be heard *under*; a theme is two minutes of full arrangement in its own key that owns
the mix. But taking the bed to actual zero would cross `AUDIBLE_EPSILON` and *stop* its channel, and
a stopped `AudioStreamPlayer` resumes at the head of a 3:44 loop — so a cycle cue ending mid-run
would silently rewind the ambience. Ducking to a whisper keeps its playhead.

**What is not yet audible, and why that is not a bug here.** `project.godot`'s `run/main_scene` still
boots straight into the world while task 4.19's cutover is in flight, so nothing puts the front end
on screen in the shipped path and the `menu` cue has no moment yet. `ThemeMusicDirector` handles that
explicitly rather than sitting silent: no front end at `_ready()` means landfall has already
happened, and the cue fires immediately. When 4.19 flips the boot scene the menu cue starts working
with no change here.

Proven headless by `tools/theme_music_check.gd` (registration, all three streams looping at their
composed lengths, landfall-at-boot, the bounded fade and hand-back, Cycle 1 vs Cycle 2, the duck
depth and its floor, and a run restart dropping a live cycle cue). `tools/audio_import_check.gd`
knows the three lengths; `tools/ambient_music_check.gd` still passes unchanged.

## D-196 — the dawn cue is a JIG SET, and the escalation keeps every third morning

**Sequoyah:** *"im thinking it would be fun to have a happy jig typa theme song play when morning
starts to kinda celebrate surviving another day"* — then, on hearing the first 32-second pass,
*"thats really good, we should make it longer though like maybe 2 mintues"*.

**It is the only cue in the game that is not about the mire.** Every other piece of music here scores
a place: the beds are the standing water, the Cycle theme is the escalation, the stinger is the thing
that found you. A morning cue scores the *players* — six people who were alive at dusk and still are.
So it gets the whistle, the fiddle, the bodhrán and the dulcimer, and the Cycle theme keeps the frame
drums and the chant. Nothing else in the palette reads as people rather than as weather.

**It is written to the form, not to a vibe.** A double jig is 6/8, eight-bar parts played AABB, the
accent on quavers 1 and 4, and each group of three lilted long-short-short. That last one is not
decoration — a flat 6/8 with notes in it is a march, and the LILT table in `render_theme.py`'s
`jig_bars()` is the entire difference. The reference work went in before a note was written; the tune
itself is ours.

**Two minutes is a SET, not a longer tune.** Four repeats of one 32-bar jig is a minute of music
heard twice, and the second minute is where a daily cue starts to grate. A set is how this music is
actually played — tune one twice, change of tune, tune two twice — so that is the form: T1 T1 / T2 T2
/ the head of T1 to finish, 138 bars. The second tune is **G Mixolydian, the same seven notes as the
D Dorian everything else in MIRE is written in**, tonic moved to G. That is what makes the change of
tune a lift rather than a departure: the drone can follow it D→G→D and the cue never stops sounding
like Hollowmere. And every change of intensity is a change of *who is playing* — the sixteen bars
where the fiddle has the tune and the whistle is out, the four bars near the end where everything
drops — because a session has no other kind.

**The third morning belongs to the escalation.** `CycleService.DAYS_PER_CYCLE` is 3, so two mornings
in three are ordinary and get the jig; on the third the Cycle theme fires and the jig is disarmed
outright rather than interrupted by it (`ThemeMusicDirector._poll_dawn()`). Celebrating survival on
the morning the mire just got worse is the wrong reading of the same event, and playing both is worse
than either.

**The trigger is a poll, not `DayNight.day_started`.** That signal is HOST-only and the code means it
— `_advance_client()` never calls `_check_thresholds()` — so a cue wired to it would pass a
single-process check and be silent for four players out of five. Same trap, same fix as
`AmbientMusicDirector`. And the cue is gated on having actually *seen* a night: a run that opens in
daylight has survived nothing yet.

**Would change my mind:** hearing it land often enough to grate. The dial is the arrangement, not the
length — dropping the second tune's repeat takes it to ~1:40 without breaking the form, and moving it
to every *second* Cycle is one condition in `_poll_dawn()`. If two minutes turns out to be too much
music for a daily event, shorten the set before shortening the tune.

## D-190 — high ground is a flat top plus a ramp, and the two are sized independently

**F-450.** Sequoyah: *"taller hills please the map is wayy too flat, i do like big flat areas but i
also like higher areas, i dont like narrow hills that make the map always go up and down."*

A dome cannot satisfy that at any amplitude. Its crown is a single point, so every metre of its
footprint is sloping ground; making it taller only makes it steeper, and adding more of them turns
the whole island into slope. What the sentence describes is an UPLAND — level ground at a raised
elevation, reached over a bounded amount of slope.

So a placed hill is now a flat top of radius `top_radius`, plus a ramp of `height * run` metres
outside it. The top decides how much high level ground there is; the run decides how you get onto
it; neither number constrains the other. The first cut made the top a FRACTION of the footprint and
that coupling immediately bit — a big top meant a narrow ramp, so the most useful tablelands were
ringed by 38-degree rims on every bearing.

**The ramp blend is cubed toward the steep side, and that is a land-budget decision.** With a linear
blend, half of every upland's perimeter carries a long gentle ramp; three to five uplands then spent
so much of the island on their own flanks that level ground fell from 62% to 32% — the same "always
going up and down" complaint arriving by a different road. There is only so much island, and a metre
of it is either flat or it is a way up. Cubing concentrates the gentle ramp into the sector opposite
the steep face, so an upland is a table with a defined edge and one walkable approach.

**Height is derived from the top's radius, not drawn independently of it**, because independent
draws make a quarter of all hills the tall-and-narrow combination — the exact landform he ruled out.

**And "flat" is not the gate.** When the check gated on the strict `< 4 degrees` share he said *"it
doesnt need to be perfectly flat"*. The gate is EASY GOING — 10 degrees or less — which is what the
original sentence was about. Uplands cost sloping ground; the question is whether what is left is
comfortable to walk, not whether it is a table.


## D-191 — terrain height is upstream of the biome bands, the skirt, and every probe in the tools

**F-450.** Tripling the island's relief (peak ~21 m to ~50 m) broke four things that had no obvious
connection to the heightmap, and each was a constant authored against the terrain's old size:

  · **`content/biomes/*.tres` height bands.** `highland` started at 6.9 m, which was the top of the
    old plateau and is now the bottom of it; highland took 27-40% of the island and `forest` was
    left a 1.4 m-wide window. Bands are elevations, and elevations are only meaningful relative to
    how tall the terrain is.
  · **`ChunkMesher.SKIRT_DEPTH`**, which was a fraction of `HEIGHT_SCALE`. That is the amplitude of
    the continental NOISE alone — placed hills add their crown lift on top of it and are not in it,
    so the relief tripled while the skirt stayed put and the LOD-seam margin fell from 3.4x to
    1.38x. It is a fraction of `MAX_HEIGHT` now, which is the number that actually means "how tall
    can this terrain be".
  · **`tools/biome_terrain_check.gd`'s probe coordinates**, which are downstream of the bands.
  · **`tools/terrain_map_render.gd`'s height shading**, which clipped at a hard-coded 8 m and so
    rendered 45 m of relief as one flat white.

**The rule: a constant in metres against the terrain is a constant against the terrain's SIZE.**
When the heightmap's amplitude moves, grep for the numbers that were calibrated to it rather than
waiting for the checks to find them — and prefer deriving from `MAX_HEIGHT` over restating a metre
count, so the next pass does not have to.


## D-188 — an island's silhouette comes from its lobes' SHAPE, not from trim on their edges

**F-447.** Sequoyah has asked three separate times for islands that are not round (2026-08-19 "the
islands are quite round, they shouldn't be standard shapes"; 2026-08-21 "id like the shape to be a
bit more random rather than usually mostly round"). Each earlier pass added trim: coastline jitter,
a domain warp, then a union of several offset lobes instead of one disc. Each helped and none of
them fixed it, because **a union of discs is a rounded blob however the discs are arranged** —
every piece of its outline is an arc of a circle, and "round" is what arcs of circles look like.

The fix had to change what the pieces ARE. Lobes are ellipses now: each carries a stretch factor,
and its mask is measured in a frame scaled along its own outward bearing, so it reaches further out
to sea and stays narrow across. That produces peninsulas, waists and bays as STRUCTURE rather than
as displacement, and four seeds render as four recognisably different islands instead of four
arrangements of the same blob.

The transform is **area-preserving** — the along component divided by the stretch, the across
component multiplied by it — which is what stops a shape control from also being a size control.

**The general rule: when a form reads wrong, check whether you are adding noise to the right thing.
Displacing a circle's edge cannot stop the silhouette being a circle.**


## D-189 — a landform's steepness is specified as an ANGLE, and its variety includes the ordinary case

**F-447.** Two rules from the same pass, both learned by measuring rather than looking.

**Specify the gradient, not a fraction of the footprint.** The first cut gave each hill a
`cliff_bias` that squeezed its radius on one bearing. That ties the face's steepness to a radius and
a height the seed drew independently, so a tall hill that happened to draw a broad radius came out
gentle however large the bias was; the steepest face across three seeds measured 20.3 degrees.
Replacing it with `scarp_run` — metres of run per metre of rise, which IS the gradient — makes the
seed pick the steepness directly, and lets a broad 90 m swell end in a bluff on one side, which is
the combination the direction was asking for and which a bias fraction cannot express.

**A spread must reach its ordinary end.** Having measured that many hills came out near-symmetric,
the first instinct was to put a floor under the spread so every hill had a steep side. Sequoyah
corrected it the same day: *"i dont want every single hill to have a cliff, some hills can be very
gentle and rolling and others can have a steeper side or whatever, just variety."* The plain
instances are what the dramatic ones are read against; a cliff on every hill is a terrain style, not
a landmark. `scarp_run` now runs past the point where the scarp stops existing at all, and
`tools/hill_slope_check.gd` asserts **both ends of the distribution** — that some hills are
near-symmetric and some are cliffs — because a fleet average alone cannot tell a spread apart from a
floor.


## D-187 — one look-at prompt owns every interaction prompt; the systems keep the input

**F-431.** Two prompts existed in the shipped game and they were both proximity driven:
`ui/building/door_prompt.gd` drew its own panel 168 px above the bottom edge, and `ui/loot/chest_ui.gd`
drew a second one 152 px above it. Standing between a door and a chest drew both. Everything else a
player is meant to act on — every tree, every ore vein, every crate — drew nothing, and there was no
crosshair anywhere in the game to say what was under the aim point.

The call: **`ui/hud/focus_prompt.gd` is the only thing that draws an interaction prompt.** Each
system keeps what is genuinely its own — Chest owns the request, the in-flight state and the reward
rows; BuildableDoor owns the toggle — and gives up the panel. A new interactable kind adds a
`_describe_*()` case and a `Kind` enum entry; it does not add a CanvasLayer.

Two consequences worth stating, because both are load-bearing:

- **Prompts are aim-driven, not proximity-driven.** A chest two metres behind you no longer prompts.
  That is the point: the prompt names the thing under the crosshair, so it can say "Needs an axe"
  about *this* tree rather than about whatever is nearest.
- **The prompt calls the host's own function.** `HarvestableDef.damage_from_tool()` decides both what
  the panel says and what the swing does, so the prompt can never promise a hit the host refuses.

Targeting is one ray (the same one `autoload/harvest_world.gd` casts) with an aim-cone fallback when
it misses. The fallback is not a nicety: a live probe of `levels/procedural_island.tscn` found 208 of
313 harvestables with no collider at all, because `HarvestLibrary.Represent.BATCH` keeps dense flora
inside a chunk's MultiMesh. Ray-only targeting would have left two thirds of the harvestable world
silent.

## D-186 — a leading underscore does not make a method private; the engine owns some of those names

**F-421.** `ui/frontend/frontend.gd` had a helper called `_enter_world()`, meaning "leave the menu
and go into the game world". `Node3D` has an engine virtual of exactly that name, fired on
`NOTIFICATION_ENTER_WORLD` — **before `_enter_tree()`, long before `_ready()`**. So the method was
never private: Godot called it the instant the node entered the 3D world.

QUIT TO TITLE is the only path that enters `levels/frontend.tscn`. Taking it put the incoming
Frontend into the world inside `SceneTree::_flush_scene_change()`, the engine called
`_enter_world()`, and the body asked for **another scene change from inside the one already
running**. The process died with SIGSEGV every single time, before `_ready()` ever ran — which is
also why nobody in this project had ever seen the title screen.

It cost a long investigation because every signal pointed away from our code: the crash carried
**no GDScript frames at all**, the shipped Godot binary is stripped so the `.ips` symbolicated to
nonsense, and it never reproduced from `--quit-after` (a different path entirely — `SceneTree::quit()`,
not a scene change).

**The rule: never name a method after an engine virtual, and do not trust reflection to tell you
which names those are.** `ClassDB.class_has_method("Node3D", "_enter_world")` returns **false** and
the name is absent from `class_get_method_list`, so neither the editor's autocomplete nor a
ClassDB-based lint can see the collision. The only reliable test is to ask the engine: declare the
name on the base class, put it in a tree, and see whether it fires on its own.

`tools/virtual_shadow_check.gd` does exactly that for every `extends <EngineClass>` script in the
project, and carries a self-test so it cannot silently degrade into a check that passes for the
wrong reason. Run it when adding lifecycle-shaped methods.

### D-188 · 2026-08-21 · Sound effects are synthesized as *objects* — a material and a geometry — not as layered waveforms, and the level column is loudness rather than peak

Sequoyah's verdict on the v1 SFX, after listening: **"there not great, a couple of them are ok but
most are wildly innacurate."** He also said what to do about it: **"do some research online, find
some examples and use them for referenace."** Both halves matter, and the second is the reason the
first was fixable.

**What v1 did wrong.** Every recipe layered a click, a sine drop and a noise bed, with each partial's
resonance and decay time picked by ear. That sounds like a reasonable way to build an impact and it
is not, because it destroys the one cue that carries material identity. Klatzky, Pai & Krotkov
(*Presence* 9(4), 2000) established that a **shape-invariant, frequency-dependent decay parameter**
determines perceived material far more strongly than frequency content does, and that it correlates
with the substance's physical damping. Choosing decay per-partial by ear guarantees no two partials
agree about what the object is made of, so the ear names it nothing.

**What v2 does instead.** A recipe names a material and a geometry; `tools/audio/mire_material.py`
derives the rest:

- Decay is never authored. A material is a loss factor η, and every mode decays at `τ = 1/(π·f·η)`.
  High modes die faster than low ones at a rate set by the substance alone, which is why wood sounds
  like wood at any pitch and any size.
- Boundary damping is added on top of the published η, because published figures are for a specimen
  ringing freely and nothing in a game is: a trunk is rooted, a plank is nailed in, a blade is
  gripped. Without it a struck dry plank rings for 0.7 s — a xylophone bar on a stand.
- Excitation is a **contact time**, not a click. A collision force is a half-sine of duration `T_c`
  and its spectrum rolls off above `1/(2·T_c)`, so a padded mallet physically cannot make a bright
  sound however hard it is swung. `hardness` therefore changes timbre, not volume.
- Mode ratios come from real geometry; irregular solids get quasi-random incommensurate ratios,
  which is the honest model for a rock and is why one clacks instead of ringing.
- Water is the Minnaert model throughout: a bubble rings at `3.26/r` and its pitch **rises** as it
  collapses. A swamp game that gets this wrong sounds synthetic no matter what else it does.

Measured separation, one struck object per material: iron 2.1 s, mire crystal 266 ms, dry wood 83 ms,
granite 33 ms, bone 19 ms, mud 39 ms. v1 had no mechanism that could produce that spread at all.

**The mix is loudness, not peak.** v1 peak-normalised everything into a −2.5..−8 dBFS band, which put
a footstep within 6 dB of a falling tree — the loudest thing a player did all day was walk. Peak
normalisation is also simply the wrong measure for sparse material: three cricket chirps across two
seconds hit the ceiling on one sample and are inaudible. The catalogue's level column is now the
**loudest 100 ms as RMS**, with a soft limiter before a −1.2 dBFS true-peak ceiling, and levels are
assigned by how often a sound fires and how much it matters. `audio_check.py` gates the band and
asserts the catalogue's spread stays under 30 dB.

**Why this is a decision and not just an implementation.** It fixes the *inputs* to sound design
rather than the outputs. Adding a new sound now means answering "what is it made of, how is it held,
and how hard was it hit" — three questions with physical answers — instead of guessing at
frequencies. Two sounds made of the same substance relate to each other without anything being copied
between them, which is what makes 131 effects feel like one game.

**Would change my mind:** Sequoyah listening and finding a specific material still wrong. The fix
would then be a number in `LOSS` or a mounting value in one recipe, not a rewrite — which is itself
the argument for the approach.

Recorded alongside: `tools/audio/render_sfx.py` (the catalogue), `autoload/sfx_director.gd` (the only
thing that plays any of it), `tools/sfx_check.gd` and `tools/sfx_runtime_probe.gd` (proof it fires).

### D-189 · 2026-08-21 · Per-target combat feedback is three separate readouts, and only one of them is new UI on the crosshair

F-433: Sequoyah asked for "healthbars for enemies and damage indicators ex -5hp, -3hp, same thing for
all harvestable resources that take more than one action to harvest ... enemy healthbars should hover
above their head, resources should have their progress bar just next to the players crosshair while
harvesting." Three requirements, and they are deliberately NOT one system:

1. **An enemy's health hovers over the enemy** (`ui/hud/target_health_hud.gd`). World-anchored,
   because the thing you need to know is *which* of the four husks is nearly dead, and a readout in
   the HUD plane cannot answer that.
2. **A harvestable's progress sits under the crosshair** (`ui/hud/focus_prompt.gd`, F-431 — already
   built, not duplicated here). World-anchored is wrong for a prop: you are standing a metre from a
   trunk that fills the screen, and the bar belongs with the name and the tool hint that are already
   there. A second panel drawing the same number at a second offset is precisely the defect F-431 was
   filed to fix, so this task added nothing to the crosshair.
3. **The number that just landed floats off the impact** (`ui/hud/damage_numbers.gd`), for both kinds
   of target, because it answers a third question — is this weapon doing anything — that neither bar
   answers.

**Three supporting calls inside that.**

*Not every enemy gets a bar.* Damaged, non-IDLE, or inside 12 m — any one is enough, within 38 m and
unoccluded, capped at the twelve nearest. A generated island carries a lot of enemies and a screen of
bars over distant idle husks hides the one that matters. The rules are all read off already-replicated
fields (`Enemy.health`, `Enemy.state`), so a client applies them without asking the host anything.

*Only your own damage numbers.* Both combat services broadcast every resolution to every peer, so
drawing all of them was free — and wrong: six players' numbers over one husk is confetti, and the
number you actually need is whether *your* swing is landing.

*A zero is shown, not swallowed.* `Harvestable.host_apply_tool_damage()` already reports a pickaxe
bouncing off a pine as a hit that connected for 0, on purpose. That comes through as a muted "0". The
alternative — suppressing it — deletes the clearest possible "wrong tool" signal at exactly the moment
the player is asking the question.

**Why this is a decision.** It settles *where* a given fact about a target belongs on screen, which is
the thing that gets re-litigated every time someone adds a readout. World-anchored for anything you
must disambiguate between; crosshair-anchored for the single thing you are aimed at; ephemeral and
in-world for the event that just happened.

**Would change my mind:** playtest showing the selection rules withhold a bar someone wanted (the fix
is a constant, not the design), or bars proving unreadable against dense foliage, which would argue
for an outline or a backing plate rather than for moving them.

**NETWORK AUTHORITY: none.** All three are ARCHITECTURE.md §2.2's "VFX, audio, camera, UI" row —
client-local presentation over already-replicated state. No new RPC, no protocol bump.

---

### D-190 · 2026-08-21 · F-435: a simulation a player is standing in has to be published to the GPU as a field, and the cue for it is a colour on the ground first and a fog second

Sequoyah, from play: **"the tainted ground that starts damaging you has no indication that it's
different, i feel like there should be low yellowy green fog and a purple hue to the ground."**

**The structural half.** `MireGrid` was a live 256x256 corruption grid with exactly one reader shape:
`corruption_at(world_position)`, a GDScript call answering one position at a time. That is the right
API for `PlayerHealth._tick_blight()` — one player, one physics tick — and it is useless for a look,
which needs the value at every fragment of ground in frame. The gap was not a missing VFX task; it
was that the simulation had no path to a shader at all, which is why the Mire had gone eight tasks
without any world-space representation while accumulating a HUD vignette, a defeat condition and a
Wellspring interaction.

So the rule this settles, for any simulation of this kind: **a per-cell world simulation that a
player physically occupies publishes a texture alongside its per-position getter.**
`MireGrid.corruption_field_texture()` is that texture — R8, one texel per cell, mapped over the
island in world XZ, re-uploaded at most four times a second and only when the grid moved. Consumers
bind it once and sample it; they never call back into the simulation per frame. The host writes it
from `_grid`; a client keeps a mirror fed by `WorldDeltaLog.delta_applied` and rebuilt on the new
`snapshot_applied` signal, because a late-join snapshot replaces that log wholesale without replaying
a single delta.

**The look half, and the order it is in.** The purple ground is the PRIMARY cue and the fog is
reinforcement, not the other way around, for three reasons that all point the same way: the ground is
the thing you are standing on and the thing that hurts you; a colour on a surface survives every
graphics preset, while the `low` preset disables volumetric fog and makes every FogVolume a no-op;
and the ground shader can put a hard-edged, ragged boundary exactly where the damage threshold is,
which a diffuse medium cannot.

**Both cues are ramped in two stages around `PlayerHealth.BLIGHT_CORRUPTION_THRESHOLD` rather than
smoothly across the range.** A single smoothstep across 0..1 marks nothing in particular at the value
that actually starts draining health, and a player cannot learn a line that is not drawn. 45% of the
effect lands between "barely there" and the threshold, the remaining 55% across the deep field. The
constants are duplicated in both shaders and both name the GDScript constant they must track.

**What the fog needed that was not obvious.** Two things, and both are recorded in
`world/environment/ground_fog.gdshader`'s header because both were discovered by photographing the
wrong answer:

* **A blight layer hangs off the TERRAIN, not off `base_height`.** The mist's single measured datum
  is pinned just above the waterline on a streamed island (the seabed is in the terrain's AABB), so a
  layer built on it sits under the sea while the corruption it marks is thirty metres up. `GroundFog`
  now builds a coarse 64x64 height map of the level from whatever node answers `height_at()`, and the
  layer hugs that. The ordinary mist still hangs off `base_height` and is a candidate to move onto
  the same map later.
* **Emission carries more of a fog cue than albedo does.** The level runs
  `volumetric_fog_anisotropy` at 0.92 — very strongly forward-scattering — so a purely scattering
  medium is close to invisible on any heading except toward the sun, and invisible at night. A
  sickly self-glow reads from every angle, which is also the half of "yellowy green" that albedo
  alone cannot say.

**Gated on pixels, not on source.** `tools/blight_ground_check.gd` renders the same ground four ways
from one camera — both halves off, ground only, fog only, both — and asserts the colour moves the
right way over corrupted ground at two distances, that clean ground 150 m away is bit-comparable to
the pre-F-435 frame, and that the texel the shader samples carries the simulation's own value. The
last one is what catches a flipped V, which every other assertion would pass while the purple sat
metres from the ground that hurts you.

### D-191 · 2026-08-21 · The Mire starts as exactly one corruption area, and its own art grows only there
Two calls from one session, and they hold each other up.

**One seed, not four.** Sequoyah, on seeing four clusters generated: *"there should only be one
corruption area on the map since it will start spreading, having more than one is too much."*
`MireGridSim.SEED_CLUSTER_COUNT` is 1. The Mire is a spreading threat, so its initial footprint is a
starting position and not a coverage target: one front is a thing a player can point at, navigate
relative to, and watch advance, and four fronts merge within minutes into "the ground is going bad
everywhere" — which is weather, not an enemy with a location. If the Mire ever needs to threaten
more of the island, raise the spread rate, the cluster radius or the Cycle multiplier. Never the
number of fronts.

**Mire growth is scattered by corruption, not by biome.** `mushroom_cluster_*`, `mire_crystal_*` and
`mire_tendril_*` are the `mire_growth` category — purple corruption, not woodland decor — and they
were entries in three ordinary biome tables, so corruption grew out of clean birch woodland (F-445).
The Mire is not a biome and never will be, so `ScatterDef` grew a second, orthogonal gate:
`min_corruption`/`max_corruption`, plus `biome_id = "*"` for a table that opts out of the biome gate
entirely. It reads `MireGridSim.initial_corruption_at()` — the field the world STARTS with, not the
live spreading one — because a chunk's placements are generated once, cached, and must be identical
on every peer forever, which a field that moves every two seconds could never be. The spreading half
of the Mire is already shown by F-435's ground shader; the scatter is the permanent growth at the
heart it spread from, which is exactly why there needs to be only one heart.

**Would change my mind:** a second corruption origin that is a deliberate, authored event rather
than a generation parameter (a Cycle escalation seeding a new front, say) — that is a different
mechanic and would want its own decision, not a bigger `SEED_CLUSTER_COUNT`.

### D-192 · 2026-08-21 · The benchmark runs in its own pinned world, never inside a player's run
The in-game benchmark (F-453, `core/bench/`) always generates its own island on a fixed seed and is
offered from the front end only. It is never available from the pause menu, and it never measures
the run a player is in the middle of.

Two of its nine scenes change the world permanently: the night scene crosses into darkness and fires
`night_started`, and the combat scene spawns a wave whose enemies stay in the world afterwards. Run
inside a live session, the benchmark would hand a player a night and six enemies they did not ask
for, in the middle of a run they care about. The obvious alternative — a "safe mode" that drops
those two scenes — is worse, because night and a live wave are most of where MIRE's frame budget
actually goes, and a benchmark that skips them would recommend settings for a game nobody plays.

The seed is pinned to `BenchmarkRunner.BENCH_SEED`, deliberately the same value
`tools/probe_scene.gd` pins, for the reason docs/PERFORMANCE.md §1 rule 5 gives: `host_generate_seed()`
draws real entropy, so an unpinned benchmark measures a different island every launch and two runs
cannot be compared — not across a driver update, not across a settings change, and not between two
players comparing numbers.

The cost is that a benchmark takes a world generation before it takes a measurement, which is why
the screen says so before the player commits to it.

**Would change my mind:** a scene set that is genuinely non-mutating and still representative — if
night and waves could be staged and fully reverted, an in-run "why is this hitching?" benchmark
would be worth having, and it is the obvious thing to want while actually playing.

### D-193 · 2026-08-21 · A settings recommendation is only ever made from numbers measured on that machine
`core/bench/settings_advisor.gd` never predicts. It compares measurements taken minutes apart on the
machine in front of the player, and the runner pays for that by re-sampling the worst scene at each
candidate preset before the advisor is asked anything.

The tempting alternative was arithmetic: docs/PERFORMANCE.md has a table of what every graphics lever
costs, so measure once and subtract. Do not do this. Every row of that table came from the fastest
machine in the project, the file says so in bold (F-174), and its own paired-versus-serial columns
disagree about MEDIUM by roughly 4 ms depending on which reference you read them against. A
prediction built on it would be a confident claim about hardware nobody has ever run this on — the
exact failure F-342 filed, dressed up as a player-facing feature.

Two rules follow and both are enforced in code. The pass condition is the **worst scene's 1% low**,
not an average across scenes and not the median: averaging the shore into the night wave hides the
one scene the player would have complained about. And ties go downward, the same way
`core/render/hardware_tier.gd` breaks its ties — landing one preset too low costs a player five
seconds in the settings menu, landing one too high costs them their opinion of the game.

**Would change my mind:** enough real-hardware benchmark reports to fit a cost model that is
validated against low-end machines rather than extrapolated from one fast one. That is a data
problem, not a design one, and F-174 is the finding that has to close first.

### D-194 · 2026-08-21 · A graphics preset is chosen against the hardest scene a preset can change
`core/bench/settings_advisor.gd`'s `preset_basis()` excludes every scene flagged `travel` from the
comparison that picks a preset. The verdict is made against the worst *stationary* scene; the worst
scene overall is still reported, and its hitch is described on its own terms.

This was not the first design, and the first one was wrong in two separate ways at once — both of
which the benchmark's own output exposed, which is the argument for having built it.

**It recommended a preset for a cost no preset touches.** `Running inland` is reliably the worst
scene in the suite (F-457: a 17 fps 1% low against a 109 fps median), and what it measures is the
chunk streamer, mesher and nav baker doing main-thread work as the player moves. Calibrating on it
produced a report that contradicted itself inside three lines: *"MEDIUM holds 73 fps where HIGH
managed 17"* printed directly above *"that gap is hitching, and a lower preset will not remove it."*
docs/PERFORMANCE.md §2 had already established the general form of this — the draw-call knobs buy
draw calls and not milliseconds — so a scene whose cost is not fill is the wrong instrument for
choosing a fill lever.

**And the comparison was not measuring presets at all.** Every calibration pass restarts the
traversal from the same point and walks the same spiral, so the FIRST pass streams that ground in
and every later pass runs across chunks that are already resident. Whichever preset was measured
second won, by a factor of four. That is not sampling noise a longer window fixes; the two samples
were measuring different worlds. Any repeated measurement of a streaming traversal has this
property, so the rule is not "sample traversal for longer" — it is "do not compare presets on a
traversal at all."

The cost is that the recommendation is silent about the one scene a player is most likely to notice.
That is paid for explicitly: the hitch gets its own reason line saying no preset will fix it, which
is more useful than a preset change that appears to and does not.

**Would change my mind:** a traversal that is repeatable — a fixed route through ground evicted from
the streamer between passes, so each preset genuinely meets the same unbuilt world. Then travelling
scenes could calibrate too, and would be the better basis, because traversal is where the game
actually lives.

### D-195 · 2026-08-21 · The benchmark pairs every location across day and night, and warms up first
Two changes to the benchmark suite (F-458), and the second exists because of the first.

**Every situation is measured twice, once by day and once by night.** The shipped suite ran seven
day scenes against two night ones. Night is not a minor variant of MIRE — it is when the waves come,
when every point light refreshes its shadow, when the ground fog and stars are up — so a suite
weighted seven-to-two toward daylight drew its recommendation from the easy half of the game.
`BenchmarkSuite.scenes()` is now generated from `situations()` × {day, night}, so the split is equal
by construction rather than by somebody counting rows, and `benchmark_check` asserts it. The whole
day block runs, then the whole night block: crossing into darkness fires `night_started` and is
one-way, so it happens exactly once.

**And the runner warms up every destination before sampling any of them.** Pairing exposed something
the old suite could not have seen: a location's FIRST visit hitches and its second does not.
`Deep forest` measured a 22 fps 1% low by day and 74 by night — same trees, same place, minutes
apart — and Marshland did the same (39 / 73). Filed as F-459, because it is a real cost players pay
on every run of a game that generates a fresh island every run.

Waiting on the chunk streamer does not cover it: `settle_world()` was satisfied before those samples
started. So without a warm-up pass, the day half systematically eats every location's first-visit
cost and the night half never does — the pairing would measure visit order rather than lighting,
which is the one thing it exists to control for.

The uncomfortable part, stated plainly: **the warm-up deliberately hides a defect that players
experience.** That is the right trade for an instrument whose output is a settings recommendation —
a number that changes depending on which scene ran first is not a measurement — but it must not
become the reason nobody fixes F-459. The way to check that finding is to disable `_prewarm()` and
confirm the first visit and the second agree.

**Would change my mind:** F-459 being fixed at the source. If first sight of a material costs
nothing, the warm-up is dead weight and should go, and the suite gets its most player-relevant
measurement back.
