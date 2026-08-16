# Journal

Append-only. Newest at the bottom. Written by `agent done` / `agent handoff`.

---

### DONE · 0.1 · sequoyah · 2026-08-15T21:24:40+00:00

**`git init`, first commit, verify `.gitignore` covers `.godot/`, `export/`, `*.import` cache**

Repo initialised on branch main, .gitignore covers .godot/, export/, .DS_Store and the local agent session file.

Commit at time of writing: `cbdc083`

---

### DONE · 0.2 · claude · 2026-08-15T21:29:21+00:00

**Create folder structure from `ARCHITECTURE.md` §3 (empty dirs + `.gdignore` where needed)**

Created the res:// layout from ARCHITECTURE.md §3: autoload, core/{net,save,util}, world/{gen,chunk,mire}, entities/{player,enemies,props,structures}, systems/{crafting,inventory,combat,powerups,waves,daynight}, content/{items,powerups,enemies,recipes,biomes}, ui/{hud,menus,lobby,inventory}. Each has a .gitkeep so git tracks it. Added .gdignore to docs/ and .agent/ so Godot stops scanning markdown and shell scripts on every editor focus.

Commit at time of writing: `9772f8d`

---

### DONE · 0.4 · claude · 2026-08-15T21:31:52+00:00

**First-person character controller: `CharacterBody3D`, mouse look, walk/sprint/jump, coyote time**

First-person controller in two files.

player_controller.gd (CharacterBody3D): walk/sprint, jump with coyote time (0.12s) + jump buffering (0.12s) + variable height on early release, separate ground/air acceleration, slope-stick bias, terminal velocity. Every feel-related number is @export'd with a range so 0.5 tuning happens in the inspector, not in code. Emits jumped and landed(impact_speed) as client-local signals for future audio/VFX.

player_camera.gd (Node3D pivot): pitch only, clamped to +/-89 deg; yaw is applied to the BODY, deliberately, so movement basis and view can never drift and so remote players' facing comes free with the replicated body transform. Sprint FOV kick, set boost to 0 to disable.

Authority: client-authoritative own movement (ARCHITECTURE.md 2.2 row 1). _ready() gates input, physics and camera.current on is_multiplayer_authority(), which returns true offline, so it works standalone now and needs no rewrite at 1.5.

NEEDS WIRING (Godot editor, my hands are off .tscn):
- Player (CharacterBody3D) with player_controller.gd
  - CollisionShape3D, CapsuleShape3D height 1.8 radius 0.4
  - CameraPivot (Node3D) at y 1.6, with player_camera.gd   <- name must be exactly CameraPivot
    - Camera3D (at origin)                                  <- name must be exactly Camera3D
- On the Player node set Floor Max Angle ~46 deg and Floor Snap Length ~0.3.
- Requires input actions from 0.3: move_forward/back/left/right, jump, sprint. Escape releases the mouse.
- I have not run Godot; report any parse error and I will fix it.

Files: `entities/player/player_controller.gd`, `entities/player/player_camera.gd`

Commit at time of writing: `9772f8d`

---

### DONE · 0.6 · claude · 2026-08-15T21:34:28+00:00

**Debug overlay autoload: FPS, position, entity counts, toggleable log channels, `~` console**

Debug overlay, log channels and console — three files, no scenes.

core/util/mire_log.gd — MireLog, all static, so any file can call MireLog.info(&'net', msg) with no reference and no autoload. Nine channels declared in CHANNELS; each toggles at runtime. Default on in debug builds, off in exported builds. WARN/ERROR always get through regardless of channel. Keeps a 400-line ring buffer so the console can show what happened before it was opened, and a sink list so the console mirrors live output.

autoload/debug_overlay.gd — CanvasLayer, builds its UI in code. F3 cycles hidden -> compact -> full. Shows FPS (colour-coded), process/physics ms, draw calls, node/object counts, static memory, camera position + yaw, and net role/peer id/peer count. Refreshes at 10Hz, not per frame. Two extension points so nothing ever needs to edit this file again: DebugOverlay.watch(key, callable) for a custom readout and DebugOverlay.track_group(group) for a live count. Position is read off get_viewport().get_camera_3d() rather than the player, so it works before a player exists and keeps zero coupling to gameplay.

autoload/debug_console.gd — CanvasLayer, top 45pct dropdown, backtick toggles, Esc closes, up/down recalls history. Built-ins: help, clear, channels, log <channel> on|off, overlay, quit. DebugConsole.register(&'name', callable, usage) from any system's _ready(). Pauses the tree while open (pause_while_open) — that is how typing WASD does not also walk the player, without the console knowing anything about the player; both autoloads are PROCESS_MODE_ALWAYS so they keep working while paused.

Authority: all three are client-local, never networked. Comment at the top of the console warns against commands that mutate host state directly.

NEEDS WIRING (Project > Project Settings > Autoload) — names matter, the console calls DebugOverlay by name:
  DebugOverlay   res://autoload/debug_overlay.gd
  DebugConsole   res://autoload/debug_console.gd
core/util/mire_log.gd is NOT an autoload — it is a class_name, do not add it.
Backtick and F3 are read as raw keycodes, so none of this depends on the 0.3 input map.
I have not run Godot; report any parse error and I will fix it.

Files: `autoload/debug_overlay.gd`, `autoload/debug_console.gd`, `core/util/mire_log.gd`

Commit at time of writing: `9772f8d`

---

### DONE · 0.3 · claude · 2026-08-15T21:46:15+00:00

**Set up input map (move, look, jump, sprint, attack, interact, inventory, build)**

Input map (10 actions, keyboard + gamepad), autoloads DebugOverlay/DebugConsole, player.tscn, and greybox_test.tscn — all generated via tools/setup_project.gd so Godot serialises its own formats. Verified with tools/verify_setup.gd: 35 checks incl. live physics (player lands and rests at ground level). Also covers 0.5's build; tuning is still open.

Notes along the way:
- Godot 4.7.1 found at /Applications/Godot.app — scripts compile-checked headless, all clean except the DebugOverlay autoload ref which resolves on wiring.

Files: `project.godot`, `entities/player/player.tscn`, `levels/greybox_test.tscn`, `tools/setup_project.gd`

Commit at time of writing: `b5c2f7d`

---

### DONE · 0.7 · terrain · 2026-08-15T22:02:39+00:00

**Spike R2 — generate 100 chunked terrain meshes from noise, measure frame times & hitches**

Spike R2 GREEN. 33x33 verts / 2048 tris per 32m chunk. ArrayMesh direct: 0.330 ms/chunk single-threaded (min 0.299, max 0.435) on M-series/15 cores, Godot 4.7.1 headless. SurfaceTool: 0.353 ms/chunk (7% slower, not worth a rewrite either way). WorkerThreadPool: 100 chunks in 11.2 ms wall = 0.112 ms/chunk amortized. Memory: 4.23 MB static delta for 100 live chunks (43 KB/chunk); raw vertex+index floor 58 KB/chunk. Determinism verified: same seed -> identical verts, different seed -> different. 50 chunks/frame on the main thread with no threading at all — 24x under the 8 ms GREEN threshold. CAVEAT: headless dummy renderer, so no GPU upload cost measured; no collision shape, no material, no LOD. Collision baking is the untested half — R3 should measure it.

Files: `world/chunk/chunk_mesher.gd`, `tools/bench_chunks.gd`

Commit at time of writing: `598523c`

---

### DONE · 0.8 · nav · 2026-08-16T00:30:42+00:00

**Spike R3 — bake a `NavigationRegion3D` on a runtime-generated chunk, measure the hitch**

GREEN. Runtime nav baking is viable; R3 is not the wall we feared.

NUMBERS (Godot 4.7.1, macOS arm64, 15 cores, 32 m chunk, cell 0.25, agent_radius 0.5):
- Blocking bake: 9.2 ms median (55% of a frame) -> never call the sync bake on the main thread.
- Async bake (NavigationServer3D.bake_from_source_geometry_data_async): 9.6 ms wall, submit costs
  0.004 ms, MAIN-THREAD BLOCK 0.011 ms. Effectively free.
- Realistic streaming episode (24 chunks baked + attached + retired, 3x3 window live):
  WORST main-thread block 0.034 ms. This is the number that matters. Budget was 2 ms.
- Attaching a baked region to a live map: 0.003 ms median with async_iterations on (0.289 ms off).
- 16 bakes fired in one frame: 6.8 ms block. Cap in-flight bakes at 2-4; one at a time is free.
- cell_size scaling is steeply superlinear: 1.0 m 0.26 ms | 0.5 m 2.1 ms | 0.25 m 9.2 ms |
  0.15 m 28.7 ms | 0.1 m 80.7 ms. 0.25 m is the right pick; 0.5 m if we ever need headroom.
- Bigger regions do not amortize: 4x4 chunks in one bake = 116.9 ms (7.3 ms/chunk) vs 9.6 ms for
  one chunk. Per-chunk bakes win.

SEAMS CONNECT, and the fix is not the obvious one:
- Chunks baked independently leave a hole exactly 2*agent_radius wide (measured 1.00 m at r=0.5),
  because Recast erodes the mesh inward from the geometry edge. Default edge_connection_margin
  0.25 < 1.00, so the default config SPLITS and an agent cannot path across a chunk boundary.
- FIX: NavigationServer3D.map_set_edge_connection_margin(map, 1.10) (i.e. > 2*agent_radius).
  8 edge connections form, path crosses the seam. Negative control: two chunks 32 m apart with
  the same margin stay SPLIT, so the margin is not inventing phantom links.
- What does NOT work, both measured: filter_baking_aabb (it filters SOURCE GEOMETRY before the
  bake, so overlap+clip still erodes to 0.5..31.5) and border_size (it shrinks the result further
  — 4 m border gave an 8 m hole). Overlapping bakes without clipping leave regions overlapping by
  7 m and still SPLIT. Do not reach for these.
- Alternative if a wide margin ever bites: agent_radius 0.0 gives a 0.00 m gap and connects on the
  default 0.25 margin, at the cost of the navmesh hugging cliff edges.

THREE TRAPS, all silent, all cost real time — documented in the code:
1. Triangle winding. Godot's Recast bridge wants cross(v1-v0, v2-v0).y NEGATIVE for an up-facing
   face, the opposite of the usual convention. Wrong winding bakes ZERO polygons and reports
   success with no error. This is what our first run hit.
2. A nav map is not queryable until the server syncs it on a physics frame. map_force_update()
   does not force it, and map_get_iteration_id() reaches 1 while the polygon graph is still empty.
   Both give a false 'ready'; poll a real query instead.
3. NavigationMesh.cell_size must equal the map's cell size or Godot warns and edges rasterize onto
   different grids.

NEEDS WIRING: nothing. Both files are throwaway spike code, no scene changes.
FOLLOW-UP FOR M4: bake off the main thread, one chunk in flight at a time, set the map's
edge_connection_margin above 2*agent_radius at startup, leave map async_iterations on.

Notes along the way:
- Seam fix is edge_connection_margin > 2*agent_radius, NOT filter_baking_aabb or border_size (both shrink the mesh, measured). Negative control confirms a 1.10 m margin does not link chunks 32 m apart.

Files: `world/chunk/nav_bake_probe.gd`, `tools/bench_navbake.gd`

Commit at time of writing: `9a1bc19`

---

### DONE · 0.9 · nav · 2026-08-16T00:41:31+00:00

**Record spike results in `DECISIONS.md`. If R3 failed, decide the fallback now.**

Filed both spike verdicts in docs/DECISIONS.md.

D-015 (R2, GREEN): chunked terrain meshing stays in GDScript. 0.330 ms/chunk single-threaded,
0.112 ms amortized threaded, 43 KB/chunk. No GDExtension, no C#, no threading until proven necessary.
Flagged the gap the R2 journal entry itself raised: COLLISION SHAPE GENERATION IS STILL UNMEASURED.
R3 spiked navigation baking, not physics cooking — those are different things and the untested half
of R2 stayed untested. Worth its own spike before M4 commits to a chunk streaming budget.

D-016 (R3, GREEN): runtime NavMesh baking stays; enemy AI keeps NavigationServer3D and the
grid-A*-on-heightmap fallback in ARCHITECTURE.md 6 R3 is dropped. 0.034 ms worst main-thread block
across a 24-chunk streaming episode. Operative rule recorded: map_set_edge_connection_margin must
exceed 2*agent_radius (1.10 m at r=0.5) or agents cannot path across a chunk boundary at all.

The three silent traps (triangle winding, false map-ready signals, cell_size mismatch) are NOT in
DECISIONS.md — they are findings, not decisions. They live in the code comments in
world/chunk/nav_bake_probe.gd and tools/bench_navbake.gd, and in the 0.8 journal entry. If they
should be in docs/FINDINGS.md, that file was unclaimed and another agent was active in the docs, so
I left it alone.

PROTOCOL NOTE: committing BEFORE 'agent done' avoids the 'edited without a claim' hook warning that
0.8 produced by following CLAUDE.md's stated order. Also: the pre-commit hook reported 'session:
claude' rather than 'nav' — it runs in a fresh shell that does not inherit MIRE_AGENT, so agent
identity is not resolved correctly from inside the hook. Check passed anyway, but with agents in
parallel that is the exact case the claim system exists to catch.

Files: `docs/DECISIONS.md`

Commit at time of writing: `9ebe47b`


---

### DONE · 0.10 · claude · 2026-08-16T02:20:14+00:00

**Spike R6 — run `tools/check_determinism.gd` on Windows and Linux, compare against the macOS baseline in `ARCHITECTURE.md` §6a**

Completed.

Files: `docs/DECISIONS.md`, `docs/ARCHITECTURE.md`, `docs/FINDINGS.md`, `docs/NEXT.md`, `tools/check_determinism_ops.gd`

Commit at time of writing: `cf62593`

---

### DONE · 0.5 · claude · 2026-08-16T02:46:31+00:00

**Grey-box test level — ramps, stairs, gaps. Tune the controller until movement *feels good*.**

Completed.

Files: `entities/player/player_controller.gd`, `docs/DECISIONS.md`, `tools/verify_setup.gd`, `docs/FINDINGS.md`, `docs/NEXT.md`

Commit at time of writing: `52f5b31`

---

### DONE · 2.2 · claude · 2026-08-16T02:59:39+00:00

**`Resource` scripts for `ItemDef`, `RecipeDef` + `registry.gd` boot loader**

ItemDef, RecipeDef/RecipeIngredient Resource scripts + registry.gd boot loader. registry.gd scans content/items and content/recipes for .tres, indexes by id, logs to MireLog 'content' channel.

Notes along the way:
- ItemDef (systems/inventory/), RecipeDef+RecipeIngredient (systems/crafting/), registry.gd autoload loading content/items+recipes .tres by id. Smoke-tested headless: loads clean with empty content dirs (0 items, 0 recipes, no errors). Not yet wired as autoload in project.godot -- needs Sequoyah.

Files: `systems/inventory/item_def.gd`, `systems/crafting/recipe_ingredient.gd`, `systems/crafting/recipe_def.gd`, `autoload/registry.gd`, `core/util/mire_log.gd`

Commit at time of writing: `1bc4650`

---

### DONE · 1.2 · net · 2026-08-16T03:10:07+00:00

**`NetTransport` autoload — swap between `ENetMultiplayerPeer` and `SteamMultiplayerPeer` behind one interface**

NetTransport autoload + NetConfig. LOCAL and LAN fully working over ENet: host, join, leave, host-quit, client-timeout, and leave-and-rejoin in the same process without restarting. Full public API as specced (6 signals, 7 methods) plus is_active()/is_connecting()/mode_name()/steam_available(). STEAM is stubbed: the whole code path exists but goes through ClassDB/Engine by name so the project parses with GodotSteam absent, and every STEAM call returns ERR_UNAVAILABLE with a 'not installed yet (task 1.1)' reason. Task 1.4 replaces two function bodies (_create_steam_host/_create_steam_client) and touches nothing else. Verified headless: 51/51 checks across a solo state-machine probe and a real two-process host+client handshake, exit 0 on all three. NOT WIRED — Sequoyah must register the autoload NetTransport -> res://autoload/net_transport.gd before any of this runs.

Notes along the way:
- Two-process probe caught a real one: _teardown() filtered 'don't announce yourself' using multiplayer.get_unique_id(), but on the host-quit path ENet has already dropped the connection and that no longer returns our id — so every client emitted peer_left for ITSELF. Local id is now cached in _local_id (set on host/join, re-read on connected_to_server). Do not go back to reading get_unique_id() at teardown time.
- LOCAL binds 127.0.0.1 only (LAN binds *). Keeps dev traffic off the network and stops the macOS firewall prompt firing on every launch — that prompt is most of what makes the two-window loop feel slow.

Files: `autoload/net_transport.gd`, `core/net/net_config.gd`

Commit at time of writing: `cf7d09f`

---

### DONE · 1.0 · claude · 2026-08-16T03:12:01+00:00

**Register the `Registry` autoload in `project.godot` — 2.2 shipped the script but nothing loads it**

Registered Registry="*res://autoload/registry.gd" in project.godot [autoload], appended after DebugConsole. Godot editor confirmed not running first (pgrep). NOT VERIFIED AT RUNTIME — I was blocked from executing Godot, so the project has not been booted with this autoload. Someone must run tools/verify_setup.gd or press Play to confirm it loads and that content/ scanning reports 0/0 cleanly.

Files: `project.godot`

Commit at time of writing: `8291086`

---

### DONE · 1.0b · claude · 2026-08-16T03:13:21+00:00

**Register the `NetTransport` autoload in `project.godot` — 1.2 follow-up, shipped under the pre-D-021 prompt**

Registered NetTransport="*res://autoload/net_transport.gd" in project.godot [autoload], appended after Registry. Godot editor confirmed closed via pgrep first. NOT RUNTIME-VERIFIED — I am blocked from executing Godot in this session, so the project has not been booted with either new autoload. Reviewed the 1.3 interface snippet statically and it is sound: _resolve_address() maps LOCAL+"" to loopback, _resolve_port(-1) gives DEFAULT_PORT 27515, MireLog.info/error are statics taking (StringName, String), and all six signal signatures match the spec.

Files: `project.godot`

Commit at time of writing: `c8f272e`

---

### DONE · 1.3 · local · 2026-08-16T03:30:06+00:00

**`LOCAL` mode: launch 2 instances, auto-host/auto-join, no menus. Make this one keypress.**

DevLaunch autoload: --host / --client (also '-- host'/'-- client') auto-hosts or auto-joins a LOCAL session at startup. No args = does nothing; also gated on OS.is_debug_build(). Bounded retry (6 attempts, 0.4s apart) covers a client started before its host. Registered in project.godot. Verified by running two headless instances against the real 4.7.1 binary: both connect, peers [1, <client>]; client-first case connects on attempt 2; no-host case gives up after 6 and stops.

Files: `core/dev/dev_launch.gd`, `project.godot`

Commit at time of writing: `c97fe5a`

---

### DONE · 1.1 · steam · 2026-08-16T06:52:27+00:00

**Install GodotSteam GDExtension (4.4+ branch), confirm it loads in stock Godot 4.7, pin the engine version**

GodotSteam GDExtension 4.21 (Steamworks 1.65) installed to addons/godotsteam from Codeberg commit 50cc0b5 — the same commit the Asset Store serves. Loads in stock Godot 4.7.1: Steam + SteamMultiplayerPeer classes registered, 736 methods; steamInitEx() succeeds against App ID 480 with the Steam client running (SteamID resolved, getAppID()==480). Engine pinned at 4.7.1.stable.official.a13da4feb and asserted by tools/steam_check.gd. Binaries gitignored (95 MB) with the reinstall recipe in D-022. Filed F-009: the extension does not load until .godot/extension_list.cfg lists it, and that path is gitignored — a live risk for 1.12 on the Linux VM.

Files: `.gitignore`, `docs/DECISIONS.md`, `tools/steam_check.gd`, `steam_appid.txt`, `docs/FINDINGS.md`

Commit at time of writing: `1a9bbd3`

---

### DONE · 1.4 · lobby · 2026-08-16T07:53:23+00:00

**Steam lobby: create, invite via overlay, join by ID, leave, member list**

SteamLobby autoload (registered): create friends-only lobby, invite via overlay, join by lobby id, leave, live member list, plus overlay and cold-start (+connect_lobby) invite acceptance. NetTransport's STEAM seam filled in with no signature changes — host_with_lobby/connect_to_lobby, and is_lobby_id() distinguishes a lobby id from a player id by Steam's account-type bits. Verified end-to-end against the live Steam client on App ID 480 via tools/steam_lobby_check.gd: real lobby created (109775242295168604), ownership + member list correct, STEAM session hosting with peer id 1, leave tears both down, idempotent. NOT verified: the joining half — needs a second Steam account on a second machine, so join_by_id/overlay invite are two-human tests.

Files: `autoload/steam_lobby.gd`, `autoload/net_transport.gd`, `project.godot`, `tools/steam_api_probe.gd`, `core/net/net_config.gd`, `tools/steam_lobby_check.gd`

Commit at time of writing: `3902911`

---

### DONE · 1.10 · netui · 2026-08-16T08:14:40+00:00

**Network debug panel: ping, bandwidth up/down, entity count, authority display**

Live net readout via DebugOverlay.watch() extension point (F3 FULL mode only): session line (mode/host-or-client/local id/peer list), per-peer RTT, host in/out bandwidth in KB/s, rolling 5-event connection log, plus DebugOverlay.track_group(&"synced") for entity count. RTT from ENetPacketPeer.get_statistic(PEER_ROUND_TRIP_TIME); bandwidth from ENetConnection.pop_statistic — verified against the pinned 4.7.1 engine source that pop_statistic resets on read, so no manual delta-tracking needed. Both read 'n/a' with a stated reason in STEAM mode: SteamMultiplayerPeer exposes neither stat in this build, not invented. Verified headless: 19/19 checks incl. a real ENet host+client session (tools/net_debug_panel_check.gd) — genuine RTT (69ms) and bandwidth readings, not just offline degrade paths. NOT WIRED: nothing instantiates NetDebugPanel yet. It is not an autoload (none claimed, per the brief) — needs either a one-line project.godot autoload entry, or add_child(preload('res://ui/debug/net_debug_panel.gd').new()) from an existing autoload's _ready(). Also needs task 1.5 (or whatever spawns MultiplayerSynchronizer nodes) to add them to group &'synced' for the entity-count line to read anything but 0 — documented in the file's header comment.

Notes along the way:
- RTT via ENetPacketPeer.get_statistic(PEER_ROUND_TRIP_TIME), bandwidth via ENetConnection.pop_statistic (confirmed it resets on read against 4.7 engine source) — both n/a in STEAM mode since SteamMultiplayerPeer exposes neither. Verified against a real headless host+client ENet session, not just offline stubs.

Files: `ui/debug/net_debug_panel.gd`, `tools/net_debug_panel_check.gd`

Commit at time of writing: `06621eb`

---

### DONE · 1.5 · spawn · 2026-08-16T08:15:22+00:00

**Networked player: `MultiplayerSpawner` + `MultiplayerSynchronizer`, client-auth movement**

PlayerNet autoload spawns one player per peer under /root/PlayerNet/Players, named for its owner; PlayerController builds its own MultiplayerSynchronizer + SceneReplicationConfig in code (position, body yaw, CameraPivot pitch, 30Hz). Verified with two headless processes: both show 2 players, each holds authority over exactly one, and driving the local one moves the remote copy on the far side in both directions. Host speed check warns on a sustained 40 m/s client (limit 10.8) and stays quiet at 3 m/s; it never corrects. Offline is unchanged — nothing spawns, the level's Player is left alone.

Notes along the way:
- Authority is derived from the node NAME (players are named for their peer id), not replicated: the spawner sets it before add_child and PlayerController._ready() re-derives it, so host and client agree with nothing extra on the wire.
- Trap for 1.6/1.8: a MultiplayerSynchronizer's authority MUST be set BEFORE add_child(). Setting it after (still inside _ready) makes the engine reject the pending spawn — 'no network ID' — on every client.
- Trap for 1.9: autoload singletons are NOT compile-time identifiers in a '--script' SceneTree main loop (the script compiles before autoloads register). Look them up with root.get_node(^"NetTransport") instead.

Files: `autoload/player_net.gd`, `entities/player/player_controller.gd`, `core/net/net_config.gd`, `project.godot`

Commit at time of writing: `4f17bcd`

---

### DONE · 1.9 · load · 2026-08-16T08:27:33+00:00

**Spike R1 — 6 peers, 200 synced dummy entities, measure bandwidth and CPU**

AMBER. 6 real ENet peers + 200 host-authoritative entities, one process, 60Hz paced. Unfiltered 30Hz = 918 KB/s host up on the wire, 7.3x the 125 KB/s ceiling. With §2.5 interest management: 105 KB/s at 30Hz, 57 KB/s at 15Hz (8.8-16x cheaper). CPU never above 1.18 ms/frame of a 16.67 ms budget on any peer, so replication is bandwidth-bound, not CPU-bound. Wire cost is 30.5 B per entity per update per client carrying 16 B of real state, so the §6 R1 hand-rolled-binary fallback could buy at most 1.9x where filtering buys 8.8x — fallback NOT needed, but 1.8 becomes mandatory rather than optional.

Notes along the way:
- Interest management measured cheaper with players CLUSTERED (100 KB/s) than SPREAD (180 KB/s) at an identical 11.6% visible fraction. The extra cost in SPREAD is reliable-channel traffic (host ACK volume is ~2x), which points at visibility churn: an entity crossing the 120m boundary forces a despawn+respawn per peer. Not isolated. Task 1.8 should budget for churn and consider hysteresis (larger leave-radius than enter-radius) so boundary-hugging entities do not flap.

Files: `core/net/dummy_replicant.gd`, `tools/bench_replication.gd`

Commit at time of writing: `fc05234`

---

### DONE · F-015 · claude · 2026-08-16T16:50:24+00:00

**A finding cannot be claimed, so fixing one always edits unclaimed files**

An F-number is a task id everywhere a task id is accepted: findings sync out of FINDINGS.md's open section, claim/brief/note/done/ship all take one, brief prints the finding as its spec, and done warns if the section was not moved to Resolved. Findings sit in their own milestone, excluded from the progress count and the current-milestone scan.

Notes along the way:
- Findings sync into tasks under a Findings milestone, excluded from roadmap counts and the current-milestone scan.

Files: `.agent/bin/agent`, `docs/FINDINGS.md`, `AGENTS.md`

Commit at time of writing: `3223c5e`

---

### DONE · F-007 · larch · 2026-08-16T16:55:25+00:00

**Forgetting `MIRE_AGENT` makes you silently impersonate the last agent to run `agent start`**

Identity derived from the chat's own session id instead of a shared mutable session file. agent start takes no argument, no MIRE_AGENT prefix anywhere, git commit resolves the same agent because the hook inherits the environment. Two chats cannot collide: different tokens, different auto-assigned names.

Notes along the way:
- Identity is derived from the chat's session id, not declared: whoami maps CLAUDE_CODE_SESSION_ID (or Codex/TERM equivalents) to a name in gitignored .agent/sessions.json, crc32-keyed so every process in one chat agrees, including the git hook.

Files: `.agent/bin/agent`, `AGENTS.md`, `docs/FINDINGS.md`, `.gitignore`

Commit at time of writing: `aa91a1a`

---

### DONE · 0.11 · onyx · 2026-08-16T17:02:10+00:00

**Populate the greybox test level with procedural test props (crates, cover, pillars, platforms) so playtesting isn't just an empty box**

Added TestMapProps autoload (world/gen/test_map_props.gd) that scatters 66 deterministic test props (30 crates, 16 stumps, 12 cover walls, 8 platforms) around the greybox test level's open field, outside the existing hand-built ramps/stairs/gaps area. Seeded RNG, client-local/no networking needed (same category as terrain gen). Only activates when current_scene.name == GreyboxTest, so it's a no-op once a real level exists. Registered in project.godot autoloads (D-021, editor was closed).

Notes along the way:
- Runtime spawner autoload instead of scene edits (per hard rule + user confirmed). Verified headless: 'world: TestMapProps scattered 66 test props into GreyboxTest', no errors, godot --headless --path . --quit-after 120.

Files: `world/gen/test_map_props.gd`, `project.godot`, `docs/ROADMAP.md`

Commit at time of writing: `14138a5`

---

### DONE · 1.11 · bram · 2026-08-16T17:14:58+00:00

**Protocol/build version handshake — refuse mismatched builds with a clear message, not a desync**

NetVersion.mismatch_reason() + PROTOCOL_VERSION written and verified via tools/handshake_check.gd (real ENet round-trip, matched and mismatched cases both green). Wiring into autoload/net_transport.gd left undone — that file was claimed by 1.7 (tine) when this task started, so integrating would have been two agents in one file. Exact drop-in (RPC methods, call sites, signal reuse) documented in docs/DELEGATION.md Current state. Filed F-016 (new class_name scripts need preload() in --script harnesses until an editor pass).

Notes along the way:
- Wrote NetVersion.mismatch_reason() (pure) and tools/handshake_check.gd (real ENet round-trip, all green). Could not wire the send/reject into autoload/net_transport.gd — tine holds it for 1.7. Drop-in documented in DELEGATION.md Current state. Filed F-016: new class_name scripts need preload(), not bare reference, in --script harnesses until an editor pass refreshes global_script_class_cache.cfg.

Files: `core/net/net_version.gd`, `tools/handshake_check.gd`

Commit at time of writing: `0a267f5`

---

### DONE · 1.8 · birch · 2026-08-16T17:16:32+00:00

**Interest management: visibility filters + per-class `replication_interval` (`ARCHITECTURE.md` §2.5)**

Interest management shipped. NetInterest.configure(sync, source, class) is the single seam for every replicated entity: per-class replication_interval/delta_interval from the §2.5 table (PLAYER 30Hz unfiltered, ENEMY 15Hz, PROP on-change 10Hz), SYNCED_GROUP membership (D-024), and a hysteretic distance filter (enter 120m / leave 144m) evaluated on the physics tick. Observers pushed host-side by PlayerNet every tick. D-025 records the two radii and PHYSICS-vs-IDLE. Verified by tools/interest_check.gd — 40 checks including a live 1-host/2-client ENet session where moving one observer makes the entity spawn and despawn on that client only, and the band is sticky in both directions. Not an autoload, so no project.godot claim was needed.

Notes along the way:
- NetInterest.configure(sync, source, class) is the single seam: it sets replication_interval + delta_interval from the §2.5 class table, joins NetConfig.SYNCED_GROUP (D-024), and installs the hysteretic distance filter. Called where authority is set, before add_child (F-012).
- Adding a new class_name breaks every headless --script run until 'Godot --headless --path . --import' rebuilds .godot/global_script_class_cache.cfg, which is gitignored. Cost 10 minutes to diagnose; the fix is one command.
- MultiplayerSynchronizer in 4.7.1 has no is_visible_to(); get_visibility_for() reads back only the MANUAL override, not the filter result. Whether the engine actually calls our filter can only be proven in a live session — hence part 3 of the harness.

Files: `core/net/net_interest.gd`, `core/net/net_config.gd`, `entities/player/player_controller.gd`, `autoload/player_net.gd`, `tools/interest_check.gd`

Commit at time of writing: `982c2ae`

---

### DONE · 1.6 · ash · 2026-08-16T17:19:51+00:00

**Remote-player interpolation so other players don't stutter**

Snapshot interpolation for remote players. NetInterp autoload (registered, last in [autoload]) watches PlayerNet's Players container and attaches a RemoteInterpolator to every player this peer does NOT own; RemoteInterpolator buffers arrivals stamped with LOCAL ARRIVAL TIME and renders ~2 send-intervals in the past, deriving the delay from the observed interval so 15Hz enemies work unchanged (rest of F-004). Zero change to player_controller.gd/player_net.gd/net_config.gd (all three held by 1.8) and ZERO added to the wire — it hooks MultiplayerSynchronizer.synchronized and samples the node after the engine writes it, so velocity stays deliberately absent per 1.5. F-004's mechanism question answered as D-026: engine physics_interpolation does NOT cover this (it smooths the 60Hz physics grid to render rate; replication is a 33ms staircase with jitter that no 16.7ms window can flatten and that the engine cannot jitter-buffer since it has no arrival times) AND the two fight, so physics_interpolation_mode is forced OFF on the driven subtree and restored in _exit_tree. Measured by tools/interp_check.gd with the control read through get_global_transform_interpolated() so engine smoothing counts for the control: 67% still frames / CV 1.64 -> 1.5% / CV 0.21 synthetic (30Hz + 8ms jitter + 6% loss), 70% / CV 1.86 -> 0.0% / CV 0.12 over real ENet, at 67-84ms of drawn latency. 100m teleport snaps in one frame instead of smearing. Verified additionally by a real two-process --host/--client run: each peer smooths exactly the other's player and neither smooths its own; offline boot unchanged. Filed F-018 (PlayerNet has no spawn/despawn signal, so NetInterp reaches for its container by child name; 1.7 is the natural owner).

Notes along the way:
- F-004 resolved: engine physics_interpolation (already ON project-wide, F-003) does NOT cover network interpolation. It smooths the 60Hz physics grid to render rate; replication arrives at 30Hz at arbitrary idle-frame times with jitter, so a 33ms staircase survives a 16.7ms smoothing window, and the engine has no notion of arrival time so it cannot jitter-buffer. Both are needed. They also FIGHT: engine interp would re-interpolate our per-frame output across physics ticks. RemoteInterpolator sets physics_interpolation_mode=OFF on the subtree it drives.

Files: `core/net/remote_interp.gd`, `autoload/net_interp.gd`, `tools/interp_check.gd`, `project.godot`

Commit at time of writing: `ff837c4`

---

### DONE · 2.1 · reed · 2026-08-16T17:40:04+00:00

**Import a CC0 low-poly pack (Quaternius/Kenney) — trees, rocks, props. Set up import presets & materials.**

Original eight-piece low-poly environment kit built in Blender 5.2: pine, dead tree, boulder, rock cluster, stump, fallen log, grass, and Mire mushrooms. Individual metre-scale GLBs have embedded flat-shaded materials and no collision; editable source is isolated under assets/source/.gdignore. Verified all GLBs re-import in Blender (72–172 polygons per compound asset), a fresh Godot 4.7.1 import produced all eight .scn artifacts, and the 1280x720 preview rendered successfully. No scene wiring is required; map placement and simple primitive collision remain editor work when the map is built.

Notes along the way:
- Replaced the generic-pack import with an original eight-piece MIRE environment kit: editable Blender source, individual ground-centred GLBs, embedded flat-shaded materials, and a rendered preview. Runtime meshes are presentation-only; future harvest/mutation remains host-authoritative.
- Godot tried to import the .blend and required a machine-local Blender path, so source art now lives under assets/source/.gdignore while runtime GLBs remain in assets/environment/exports. Fresh headless Godot import produced all eight .scn artifacts successfully.

Files: `tools/blender/build_mire_map_kit.py`, `assets/environment/mire_map_kit.blend`, `assets/environment/exports/tree_pine_a.glb`, `assets/environment/exports/tree_bare_a.glb`, `assets/environment/exports/boulder_a.glb`, `assets/environment/exports/rock_cluster_a.glb`, `assets/environment/exports/stump_a.glb`, `assets/environment/exports/fallen_log_a.glb`, `assets/environment/exports/grass_clump_a.glb`, `assets/environment/exports/mushroom_cluster_a.glb`, `assets/environment/preview/mire_map_kit_preview.png`, `assets/source/.gdignore`, `assets/source/mire_map_kit.blend`, `assets/environment/README.md`

Commit at time of writing: `18aa989`

---

### DONE · 2.1b · reed · 2026-08-16T18:01:56+00:00

**Expand the original Blender environment kit from 8 to 116 assets across trees, rocks, forest debris, ground cover, Mire growths, ruins, and modular wood/stone building pieces**

Expanded the original Blender kit from 8 to 116 original low-poly assets across seven families: 18 trees, 18 rocks, 12 forest-debris props, 16 ground-cover props, 16 Mire growths, 12 ruins, and 24 modular wood/stone/fence building pieces. Construction pieces use 4 m bays and 3 m walls/posts. Generated eight reviewed preview renders plus catalog.json and an editable 641 KB source blend. Verified Python syntax, 116 valid GLB v2 files, 11,380 polygons total (402 max per asset), positive dimensions for every catalog entry, and a fresh Godot 4.7.1 import with 0/116 missing imported scenes. Assets are presentation-only; future placement, damage, and destruction remain host-authoritative.

Notes along the way:
- Scope expanded by Sequoyah: later construction needs reusable pieces, not monolithic buildings. Adding a 24-piece grid-compatible wood/stone/fence family now; target is 112 total assets (104 new), with modular 4 m bays and 3 m wall height.
- Final catalog is 116 assets: trees 18, rocks 18, forest debris 12, ground cover 16, Mire growth 16, ruins 12, modular building pieces 24. Construction uses 4 m bays and 3 m walls/posts; small trim overlaps prevent seams. Assets are presentation-only; placement/damage/destruction remains host-authoritative.
- Godot treats CSV files as localization tables and generated .translation artifacts from the first catalog. Switched to catalog.json; fresh Godot 4.7.1 import created usable .scn artifacts for all 116 GLBs with zero missing imports and no Blender-path or translation errors.
- Geometry budget: 11,380 polygons across the whole library; heaviest individual asset is 402 polygons. Eight 1600px category/hero previews were rendered and visually checked; source blend contains the full organized catalog.

Files: `tools/blender/build_mire_map_kit.py`, `assets/source/mire_map_kit.blend`, `assets/environment/README.md`, `assets/environment/exports/tree_pine_a.glb`, `assets/environment/exports/tree_pine_b.glb`, `assets/environment/exports/tree_pine_c.glb`, `assets/environment/exports/tree_pine_d.glb`, `assets/environment/exports/tree_pine_e.glb`, `assets/environment/exports/tree_pine_f.glb`, `assets/environment/exports/tree_bare_a.glb`, `assets/environment/exports/tree_bare_b.glb`, `assets/environment/exports/tree_bare_c.glb`, `assets/environment/exports/tree_bare_d.glb`, `assets/environment/exports/tree_birch_a.glb`, `assets/environment/exports/tree_birch_b.glb`, `assets/environment/exports/tree_birch_c.glb`, `assets/environment/exports/tree_birch_d.glb`, `assets/environment/exports/tree_crooked_a.glb`, `assets/environment/exports/tree_crooked_b.glb`, `assets/environment/exports/tree_crooked_c.glb`, `assets/environment/exports/tree_crooked_d.glb`, `assets/environment/exports/boulder_a.glb`, `assets/environment/exports/boulder_b.glb`, `assets/environment/exports/boulder_c.glb`, `assets/environment/exports/boulder_d.glb`, `assets/environment/exports/boulder_e.glb`, `assets/environment/exports/boulder_f.glb`, `assets/environment/exports/boulder_g.glb`, `assets/environment/exports/boulder_h.glb`, `assets/environment/exports/rock_cluster_a.glb`, `assets/environment/exports/rock_cluster_b.glb`, `assets/environment/exports/rock_cluster_c.glb`, `assets/environment/exports/rock_cluster_d.glb`, `assets/environment/exports/rock_cluster_e.glb`, `assets/environment/exports/rock_cluster_f.glb`, `assets/environment/exports/standing_stone_a.glb`, `assets/environment/exports/standing_stone_b.glb`, `assets/environment/exports/standing_stone_c.glb`, `assets/environment/exports/standing_stone_d.glb`, `assets/environment/exports/stump_a.glb`, `assets/environment/exports/stump_b.glb`, `assets/environment/exports/stump_c.glb`, `assets/environment/exports/stump_d.glb`, `assets/environment/exports/fallen_log_a.glb`, `assets/environment/exports/fallen_log_b.glb`, `assets/environment/exports/fallen_log_c.glb`, `assets/environment/exports/fallen_log_d.glb`, `assets/environment/exports/root_cluster_a.glb`, `assets/environment/exports/root_cluster_b.glb`, `assets/environment/exports/root_cluster_c.glb`, `assets/environment/exports/root_cluster_d.glb`, `assets/environment/exports/grass_clump_a.glb`, `assets/environment/exports/grass_clump_b.glb`, `assets/environment/exports/grass_clump_c.glb`, `assets/environment/exports/grass_clump_d.glb`, `assets/environment/exports/grass_clump_e.glb`, `assets/environment/exports/grass_clump_f.glb`, `assets/environment/exports/fern_a.glb`, `assets/environment/exports/fern_b.glb`, `assets/environment/exports/fern_c.glb`, `assets/environment/exports/fern_d.glb`, `assets/environment/exports/fern_e.glb`, `assets/environment/exports/fern_f.glb`, `assets/environment/exports/reeds_a.glb`, `assets/environment/exports/reeds_b.glb`, `assets/environment/exports/reeds_c.glb`, `assets/environment/exports/reeds_d.glb`, `assets/environment/exports/mushroom_cluster_a.glb`, `assets/environment/exports/mushroom_cluster_b.glb`, `assets/environment/exports/mushroom_cluster_c.glb`, `assets/environment/exports/mushroom_cluster_d.glb`, `assets/environment/exports/mushroom_cluster_e.glb`, `assets/environment/exports/mushroom_cluster_f.glb`, `assets/environment/exports/mire_crystal_a.glb`, `assets/environment/exports/mire_crystal_b.glb`, `assets/environment/exports/mire_crystal_c.glb`, `assets/environment/exports/mire_crystal_d.glb`, `assets/environment/exports/mire_crystal_e.glb`, `assets/environment/exports/mire_crystal_f.glb`, `assets/environment/exports/mire_tendril_a.glb`, `assets/environment/exports/mire_tendril_b.glb`, `assets/environment/exports/mire_tendril_c.glb`, `assets/environment/exports/mire_tendril_d.glb`, `assets/environment/exports/ruin_wall_a.glb`, `assets/environment/exports/ruin_wall_b.glb`, `assets/environment/exports/ruin_wall_c.glb`, `assets/environment/exports/ruin_wall_d.glb`, `assets/environment/exports/ruin_column_a.glb`, `assets/environment/exports/ruin_column_b.glb`, `assets/environment/exports/ruin_column_c.glb`, `assets/environment/exports/ruin_column_d.glb`, `assets/environment/exports/ruin_arch_a.glb`, `assets/environment/exports/ruin_arch_b.glb`, `assets/environment/exports/stone_marker_a.glb`, `assets/environment/exports/stone_marker_b.glb`, `assets/environment/preview/mire_map_kit_preview.png`, `assets/environment/preview/trees_preview.png`, `assets/environment/preview/rocks_preview.png`, `assets/environment/preview/forest_debris_preview.png`, `assets/environment/preview/ground_cover_preview.png`, `assets/environment/preview/mire_growth_preview.png`, `assets/environment/preview/ruins_preview.png`, `assets/environment/exports/wood_foundation.glb`, `assets/environment/exports/wood_floor.glb`, `assets/environment/exports/wood_wall_solid.glb`, `assets/environment/exports/wood_wall_window.glb`, `assets/environment/exports/wood_wall_door.glb`, `assets/environment/exports/wood_half_wall.glb`, `assets/environment/exports/wood_roof_slope.glb`, `assets/environment/exports/wood_roof_corner.glb`, `assets/environment/exports/wood_stairs.glb`, `assets/environment/exports/wood_beam.glb`, `assets/environment/exports/wood_post.glb`, `assets/environment/exports/wood_railing.glb`, `assets/environment/exports/stone_foundation.glb`, `assets/environment/exports/stone_floor.glb`, `assets/environment/exports/stone_wall_solid.glb`, `assets/environment/exports/stone_wall_window.glb`, `assets/environment/exports/stone_wall_door.glb`, `assets/environment/exports/stone_half_wall.glb`, `assets/environment/exports/stone_stairs.glb`, `assets/environment/exports/stone_pillar.glb`, `assets/environment/exports/fence_straight.glb`, `assets/environment/exports/fence_corner.glb`, `assets/environment/exports/fence_gate.glb`, `assets/environment/exports/fence_post.glb`, `assets/environment/preview/building_pieces_preview.png`, `assets/environment/catalog.csv`, `docs/ROADMAP.md`, `assets/environment/catalog.json`

Commit at time of writing: `bd1387c`

---

### DONE · 2.1c · reed · 2026-08-16T18:15:43+00:00

**Build a compact runtime-generated playtest map from the environment kit: camp, forest, ruins, Mire grove, ridge, routes, and collision**

Compact deterministic map complete: 6 themed zones, 171 visible GLB asset instances, 113 simplified collision shapes, routes, camp buildings/fences, forest, ruins, Mire grove, and ridge lookout. Direct GLTFDocument loading avoids generated .import dependencies. Verified with playtest_map_check (0 failures, all 171 holders have visuals) and a normal Metal Forward+ launch at 60 FPS. No scene resources edited; TestMapProps was already registered. Safe to move on.

Notes along the way:
- Runtime GLB load is deliberate: GLTFDocument + PackedScene cache keeps the map runnable from committed sources without forbidden/generated .import sidecars. Final map: 6 zones, 171 visuals, 113 simplified collision shapes. Static layout is deterministic client-local; future mutable gameplay remains host-authoritative.

Files: `docs/ROADMAP.md`, `world/gen/test_map_props.gd`, `world/gen/test_map_props.gd.uid`, `tools/playtest_map_check.gd`, `tools/playtest_map_check.gd.uid`, `docs/DELEGATION.md`

Commit at time of writing: `04bdedc`

---

### HANDOFF · 2.1d · ember · 2026-08-16T18:32:13+00:00

**Produce the single `NEXT` batch in `docs/ASSET_TRACKER.md`; verify, advance the queue, hand off rather than close**

A-001 complete: 12 portable harvestable-state GLBs, dedicated deterministic Blender generator/source, exact catalog, family README, full-set preview, and scale preview. Verified syntax, clean deterministic rebuild (byte-identical GLBs/catalog; pixel-identical renders), GLB 2.0 structure/catalog/scale/bounds/materials at 2,116 triangles, visual quality, and isolated fresh Godot 4.7.1 import with 12/12 scenes and no errors. Tracker marks A-001 DONE and A-002 NEXT. Next run: build only A-002 in a separate pickup-family generator, preserving host authority for pickup state/collection.

Files: `docs/ASSET_TRACKER.md`, `docs/ROADMAP.md`, `tools/blender/build_harvestable_resources.py`, `assets/source/harvestable_resources.blend`, `assets/harvestables/README.md`, `assets/harvestables/catalog.json`, `assets/harvestables/preview/harvestables_preview.png`, `assets/harvestables/preview/harvestables_scale_preview.png`, `assets/harvestables/exports/harvest_tree_intact.glb`, `assets/harvestables/exports/harvest_tree_damaged_a.glb`, `assets/harvestables/exports/harvest_tree_damaged_b.glb`, `assets/harvestables/exports/harvest_tree_felled_trunk.glb`, `assets/harvestables/exports/harvest_tree_fresh_stump.glb`, `assets/harvestables/exports/harvest_tree_depleted_stump.glb`, `assets/harvestables/exports/stone_node_intact.glb`, `assets/harvestables/exports/stone_node_cracked.glb`, `assets/harvestables/exports/stone_node_depleted.glb`, `assets/harvestables/exports/iron_node_intact.glb`, `assets/harvestables/exports/iron_node_cracked.glb`, `assets/harvestables/exports/iron_node_depleted.glb`, `docs/DELEGATION.md`

Commit at time of writing: `e0f42e1`

---

### HANDOFF · 2.1d · ember · 2026-08-16T18:40:55+00:00

**Produce the single `NEXT` batch in `docs/ASSET_TRACKER.md`; verify, advance the queue, hand off rather than close**

A-002 complete: 14 portable pickup GLBs covering wood, minerals, ingot, fibre, food, currency, and salvage; dedicated deterministic Blender generator/source, exact catalog, family README, full-set preview, and scale preview. Verified syntax, clean deterministic rebuild (byte-identical GLBs/catalog; pixel-identical renders), GLB 2.0 structure/catalog/scale/bounds/materials at 2,364 triangles, visual quality, and isolated fresh Godot 4.7.1 import with 14/14 scenes and no errors. Tracker marks A-002 DONE and A-003 NEXT. Next run: build only A-003 in a separate crafting-station generator; keep station use/crafting authority host-owned.

Files: `docs/ASSET_TRACKER.md`, `docs/DELEGATION.md`, `tools/blender/build_pickup_kit.py`, `assets/source/pickup_kit.blend`, `assets/pickups/README.md`, `assets/pickups/catalog.json`, `assets/pickups/preview/pickups_preview.png`, `assets/pickups/preview/pickups_scale_preview.png`, `assets/pickups/exports/pickup_log.glb`, `assets/pickups/exports/pickup_branch.glb`, `assets/pickups/exports/pickup_stone.glb`, `assets/pickups/exports/pickup_flint.glb`, `assets/pickups/exports/pickup_iron_ore.glb`, `assets/pickups/exports/pickup_iron_ingot.glb`, `assets/pickups/exports/pickup_coal.glb`, `assets/pickups/exports/pickup_fibre_bundle.glb`, `assets/pickups/exports/pickup_berry.glb`, `assets/pickups/exports/pickup_mushroom.glb`, `assets/pickups/exports/pickup_raw_meat.glb`, `assets/pickups/exports/pickup_coin.glb`, `assets/pickups/exports/pickup_coin_stack.glb`, `assets/pickups/exports/pickup_salvage_fragment.glb`

Commit at time of writing: `f151625`

---

### HANDOFF · 2.1d · ember · 2026-08-16T18:50:26+00:00

**Produce the single `NEXT` batch in `docs/ASSET_TRACKER.md`; verify, advance the queue, hand off rather than close**

A-003 complete: eight portable station GLBs covering primitive/upgraded workbenches, campfire, cooking spit, stone furnace, anvil, repair bench, and woodcutting block; dedicated deterministic Blender generator/source, exact catalog, family README, full-set preview, and scale preview. Verified syntax, deterministic rebuild (byte-identical GLBs/catalog; pixel-identical renders), GLB 2.0 structure/catalog/scale/bounds/materials at 4,372 triangles total and 1,100 max, visual quality, and isolated fresh Godot 4.7.1 import with 8/8 scenes and no errors. Tracker marks A-003 DONE and A-004 NEXT. Next run: make only A-004 as ten shared designs with paired world/viewmodel exports; preserve host authority for tool use and combat.

Files: `docs/ASSET_TRACKER.md`, `docs/DELEGATION.md`, `tools/blender/build_crafting_stations.py`, `assets/source/crafting_stations.blend`, `assets/crafting_stations/README.md`, `assets/crafting_stations/catalog.json`, `assets/crafting_stations/preview/crafting_stations_preview.png`, `assets/crafting_stations/preview/crafting_stations_scale_preview.png`, `assets/crafting_stations/exports/station_workbench_primitive.glb`, `assets/crafting_stations/exports/station_workbench_upgraded.glb`, `assets/crafting_stations/exports/station_campfire.glb`, `assets/crafting_stations/exports/station_cooking_spit.glb`, `assets/crafting_stations/exports/station_stone_furnace.glb`, `assets/crafting_stations/exports/station_anvil.glb`, `assets/crafting_stations/exports/station_repair_bench.glb`, `assets/crafting_stations/exports/station_woodcutting_block.glb`

Commit at time of writing: `73cf552`

---

### DONE · 2.1e · reed · 2026-08-16T19:00:05+00:00

**Replace the runtime-scattered playtest visuals with an authored Blender map asset, incorporating harvestables and crafting stations**

Replaced runtime visual scatter with an authored Blender map. Editable source + fixed GLB + preview include six zones, paths/terrain, A-001 harvestables, and A-003 stations. GLB hash remained 8cb6c1c7e1e07d54c396ff5a2086c8375e740e25ae15a03c132a9be3ce78ab79 across clean rebuilds. Headless Godot check passed: 1,732 visible meshes, 178 collision markers, 120 shapes, 0 failures. Normal Metal Forward+ launch rendered at 120 FPS and was visually inspected from spawn. Runs now; no editor wiring or scene-resource edit needed. Safe to move on.

Notes along the way:
- Visible placement now lives in editable assets/source/playtest_map.blend and one 3.6 MB authored GLB. The GLB is byte-identical across clean Blender 5.2 rebuilds. Godot loads 1,732 mesh nodes at 120 FPS; TestMapProps now supplies collision only (178 markers / 120 shapes). Added A-001 harvest trees/ore and A-003 camp/forge stations. No .tscn/.tres/.import edits.

Files: `docs/ROADMAP.md`, `docs/DELEGATION.md`, `docs/ASSET_TRACKER.md`, `tools/blender/build_playtest_map.py`, `assets/source/playtest_map.blend`, `assets/maps/playtest_map.glb`, `assets/maps/README.md`, `assets/maps/preview/playtest_map_preview.png`, `world/gen/test_map_props.gd`, `tools/playtest_map_check.gd`

Commit at time of writing: `e23c5f4`

---

### DONE · F-019 · reed · 2026-08-16T19:12:29+00:00

**Generated asset import sidecars flood every clean-tree audit**

Ignored 166 editor-generated .import sidecars, committed six delayed script UIDs from completed tasks, and included Sequoyah's authored playtest_map.tscn after a clean headless boot. Active 1.7 networking work intentionally left uncommitted.

Notes along the way:
- Audit also recovered six delayed .uid sidecars from completed tasks and the human-authored levels/playtest_map.tscn. The scene booted headlessly without errors; no scene content was edited. Active 1.7 files remain untouched.

Files: `.gitignore`, `autoload/net_interp.gd.uid`, `core/net/net_version.gd.uid`, `core/net/remote_interp.gd.uid`, `tools/handshake_check.gd.uid`, `tools/interest_check.gd.uid`, `tools/interp_check.gd.uid`, `docs/FINDINGS.md`, `levels/playtest_map.tscn`

Commit at time of writing: `423b73a`

---

### DONE · 1.7 · reed · 2026-08-16T19:23:07+00:00

**Connection lifecycle: join mid-session, disconnect, host quits, timeout handling**

Connection lifecycle complete: NetSession is registered and owns host admission, readable end reasons, clean host close, LOCAL/LAN auto-rejoin, and the wired protocol handshake. Real multi-process ENet harness completed 8/8 sections with 0 failures; killed peer detected/despawned in 2.6s. Setup, boot, handshake, interest, interpolation and synced-group regressions pass. Steam lobby rejoin remains F-020; net debug harness false-green engine errors recorded separately as F-021. No scene or resource wiring is needed.

Notes along the way:
- Took over stale tine claim from quota-exhausted Claude handoff. Read AGENTS, NEXT, ARCHITECTURE 2.2, DELEGATION Current state, and DECISIONS. Registered NetSession after NetTransport and before DevLaunch with editor confirmed closed; harness now preloads NetVersion per F-016.
- Implemented and registered NetSession after NetTransport. Real multi-process lifecycle harness completed 8/8 sections with 0 failures: capacity/refusal, late roster, version mismatch cleanup, auto-rejoin, 2.6s dead-peer detection, clean host close. Regressions green: handshake 0 failures, interest PASS, interpolation PASS, synced group PASS, setup all checks passed, normal headless boot clean. net_debug_panel_check exits 0 but exposes pre-existing custom SceneMultiplayer root errors; filed F-021 instead of widening 1.7. Steam rejoin limitation filed F-020; admission policy recorded D-027.

Files: `core/net/net_session.gd`, `core/net/net_session.gd.uid`, `autoload/net_transport.gd`, `core/dev/dev_launch.gd`, `tools/session_lifecycle_check.gd`, `tools/session_lifecycle_check.gd.uid`, `project.godot`, `docs/DELEGATION.md`, `docs/DECISIONS.md`, `docs/NEXT.md`, `docs/FINDINGS.md`

Commit at time of writing: `af4ae9f`

---

### DONE · F-022 · kiln · 2026-08-16T19:27:42+00:00

**Project metadata retained the superseded "Muck but better" name**

Canonicalized the project name as MIRE locally, in Godot metadata, documentation, and GitHub; headless setup verification passed.

Notes along the way:
- Renamed the local workspace and GitHub repository to MIRE; updated Godot metadata and removed working-title wording. Headless setup verification passed.

Files: `project.godot`, `docs/DESIGN.md`, `docs/FINDINGS.md`

Commit at time of writing: `3acc3ae`

---

### DONE · F-009 · flint · 2026-08-16T19:34:30+00:00

**A GDExtension only loads if gitignored `.godot/extension_list.cfg` lists it**

Committed .godot/extension_list.cfg as the sole tracked .godot exception, documented it beside the pinned GodotSteam reinstall recipe, and removed F-009 from the 1.12 blocker list. Verified steam_check all passed on App ID 480, normal headless boot clean, agent check clean.

Notes along the way:
- Committing the single deterministic extension registry file. Keep the rest of .godot ignored; a fresh clone then loads the pinned addon headlessly without editor scanning.

Files: `.gitignore`, `.godot/extension_list.cfg`, `docs/FINDINGS.md`, `docs/DELEGATION.md`, `docs/DECISIONS.md`, `docs/NEXT.md`

Commit at time of writing: `cda7858`

---

### HANDOFF · F-006 · slate · 2026-08-16T19:34:55+00:00

**Three roadmap tasks assume a Windows or Linux machine we don't have**

New capability recorded: a friend's powerful physical Windows gaming PC is available, can clone the repo, and has Codex to execute precise test briefs and return evidence. This replaces the Windows VM as the preferred Windows target and removes the real-Windows-GPU gap for tasks 0.10, 1.12, and 7.12. Linux stays on the Unraid x86_64 VM; Steam Deck remains unresolved. I did not edit FINDINGS/DECISIONS/DELEGATION because flint/F-009 currently holds those files. Next agent: update F-006 and the standing cross-platform decision after F-009 releases them; create the exact Windows brief when the first test is ready, not prematurely.

Commit at time of writing: `d4a5cdf`

---

### HANDOFF · F-006 · slate · 2026-08-16T19:36:41+00:00

**Three roadmap tasks assume a Windows or Linux machine we don't have**

Windows Codex brief is complete in docs/WINDOWS_TEST_BRIEF.md and ready for Sequoyah's call. Run it on the friend's physical PC and return the full Codex report. Do not resolve F-006 yet: after evidence returns, record Windows hashes in ARCHITECTURE/DECISIONS, then prepare the separate simultaneous multiplayer brief for 1.12.

Files: `docs/WINDOWS_TEST_BRIEF.md`, `docs/FINDINGS.md`, `docs/DECISIONS.md`, `docs/DELEGATION.md`, `docs/NEXT.md`

Commit at time of writing: `d4a5cdf`

---

### HANDOFF · F-006 · slate · 2026-08-16T20:11:48+00:00

**Three roadmap tasks assume a Windows or Linux machine we don't have**

Windows hardware gap is now largely resolved: physical Ryzen 5 5600/RTX 3060 PC is the preferred Windows target; determinism passed and docs are updated. F-006 remains open only for actually scheduling/running 1.12 cross-platform Steam and later 7.12 export checks; Steam Deck remains separate. Future fresh clones must reinstall D-022 GodotSteam and run a headless editor scan before checks.

Files: `docs/FINDINGS.md`, `docs/DECISIONS.md`, `docs/ARCHITECTURE.md`, `docs/DELEGATION.md`, `docs/NEXT.md`, `docs/WINDOWS_TEST_BRIEF.md`

Commit at time of writing: `f958400`

---

### DONE · 4.0b · slate · 2026-08-16T20:11:49+00:00

**Finish Spike R6 — determinism probe on Windows x86_64, fill the third column in `ARCHITECTURE.md` §6a**

Windows x86_64 determinism completed on physical Ryzen 5 5600 with pinned Godot 4.7.1 a13da4feb. Two runs were identical; PRNG, both noise hashes, and all four safe-operation hashes matched macOS. Startup errors were separately reproduced as missing gitignored GodotSteam plus first-scan cache state, so this clears R6 but is not a clean Windows boot test.

Files: `docs/FINDINGS.md`, `docs/DECISIONS.md`, `docs/ARCHITECTURE.md`, `docs/DELEGATION.md`, `docs/NEXT.md`, `docs/WINDOWS_TEST_BRIEF.md`

Commit at time of writing: `f958400`

---

### HANDOFF · 1.12 · hollow · 2026-08-16T20:16:02+00:00

**Cross-platform join test — Mac ↔ Windows ↔ Linux in one lobby, over Steam**

Windows prerequisite is now complete (aa2efb2). Added debug-only DevLaunch --steam-host and --steam-join=<lobby_id> paths that call SteamLobby in the required asynchronous order, plus docs/STEAM_CROSS_PLATFORM_TEST.md with pinned-engine/addon/import preflight, commands, evidence capture, and pass criteria. Local verify_setup.gd and agent check pass. Final work is the simultaneous macOS host + Windows/Linux client Steam session; retain three steam_check logs, launch logs, and F3 screenshots, then resolve 1.12 from that evidence.

Files: `docs/STEAM_CROSS_PLATFORM_TEST.md`, `docs/DELEGATION.md`, `docs/NEXT.md`, `tools/steam_cross_platform_check.gd`, `tools/steam_cross_platform_check.gd.uid`, `core/dev/dev_launch.gd`

Commit at time of writing: `aa2efb2`
