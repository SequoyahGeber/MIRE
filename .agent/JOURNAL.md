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

---

### HANDOFF · 1.12 · hollow · 2026-08-16T22:41:46+00:00

**Cross-platform join test — Mac ↔ Windows ↔ Linux in one lobby, over Steam**

All three preflights passed on Godot 4.7.1/GodotSteam 4.21/App 480 using mutual-friend accounts TheQuoy (Mac), quoygeber (Windows), sequoyahgeber (Linux). A Mac lobby reached Windows+Linux and F3 showed three peers/players; code-built remote debug capsules plus players-group registration made both remotes visible, and Linux movement replicated. Windows first join twice timed out at the hard 10.0s then immediate retry connected, including once with firewall already off; filed F-023. Windows Steam IPC is unavailable from the OpenSSH service session, so run checks/game interactively. Windows Firewall is STILL DISABLED from diagnosis; restore it and add a narrow allow rule for C:\Tools\Godot\Godot_v4.7.1-stable_win64.exe before final testing. Formal PASS is not achieved: no complete 60s all-player movement observation, no retained screenshot per platform, and final evidence run ended host-first so clients logged CONNECTION_LOST. Evidence logs are /Users/sequoyahgeber/Desktop/MIRETestLogs. Temporary Mac/Linux/Windows test processes/tasks were stopped. Next: firewall-on rerun from shipped revision, preserve first failure if any, capture all three F3 screenshots/logs and 60s movement, clients exit first then host. Validation: import OK; lifecycle 8/8 0 failures; interp PASS; debug panel 0 failures with known F-021 engine errors.

Files: `entities/player/player_controller.gd`, `docs/FINDINGS.md`, `docs/DELEGATION.md`, `docs/NEXT.md`, `docs/STEAM_CROSS_PLATFORM_TEST.md`

Commit at time of writing: `6c3b721`

---

### HANDOFF · F-023 · vane · 2026-08-16T22:59:02+00:00

**Windows Steam first join intermittently exceeds the hard 10-second connection timeout**

Mechanism fixed, measurement still owed — F-023 stays open on purpose.

Root cause was bigger than the 10s number: NOTHING retried a Steam first join. dev_launch.gd:183 excluded STEAM from its retry by hand, NetSession never listened to connection_failed, SteamLobby doesn't either. Every 'immediate retry' in the 1.12 report was a human relaunching.

Landed (D-029): NetConfig.STEAM_CONNECT_TIMEOUT_SEC (provisionally 20s, separate from ENet's 10s because a rendezvous is a different mechanism); EndKind.CONNECT_TIMEOUT split from CONNECT_FAILED so only a no-verdict attempt is retried; NetSession retries a timed-out first join STEAM-only, twice at 0.5s/2.0s, and hands the lobby back on give-up; NetTransport.last_connect_msec() plus a 'connected ... in N.NNs' log line on every join.

Retry is STEAM-only for a real reason, not caution: a timed-out attempt tears down WITHOUT announcing, so SteamLobby never leaves the lobby and we are still a member — which is connect_to_lobby()'s one precondition. That is what makes it not F-020 (rejoin-after-drop, where the lobby WAS left).

Two bugs fixed in passing. (1) host()/join() now clear _last_end_kind up front — a synchronous failure used to inherit the previous attempt's ending, which would have made the new retry guard fire for a call that never opened a socket. (2) NetSession._await_connect_result derived its backstop from CONNECT_TIMEOUT_SEC + 2 = 12s, which after the Steam budget went to 20s would have cancelled live attempts; it is now mode-derived via NetTransport.connect_timeout_sec().

Verified headless macOS: tools/connect_retry_check.gd PASS 0 failures (real 13ms LOCAL connect measured, CONNECT_TIMEOUT classified, sync failure clears to NONE). Regressions all 0 failures: lifecycle 8/8, handshake, interp, interest, synced group, debug panel. verify_setup all checks passed.

WHAT IS LEFT, and it is the finding's original ask: nobody has ever measured a Windows Steam first join. 20s is an allowance, not evidence, and the retry has never met a real rendezvous. 1.12's rerun closes both — collect the 'connected ... in N.NNs' line from all three platforms, set STEAM_CONNECT_TIMEOUT_SEC from the tail, then move F-023 to Resolved. A Windows timeout the retry rescues is the fix working and still NOT a clean PASS for 1.12. Filed F-024: shipped LAN joins have no retry, only DevLaunch does; close it with M6's join screen.

Files: `autoload/net_transport.gd`, `autoload/steam_lobby.gd`, `core/net/net_config.gd`, `core/net/net_session.gd`, `core/dev/dev_launch.gd`, `tools/connect_retry_check.gd`

Commit at time of writing: `10331c4`

---

### HANDOFF · 1.12 · ivy · 2026-08-16T23:19:13+00:00

**Cross-platform join test — Mac ↔ Windows ↔ Linux in one lobby, over Steam**

Two-platform rerun wrapped cleanly. Mac host lobby 109775242382594016 admitted fresh origin/main Windows peer 579922246; Windows F3 showed STEAM client, peers [1,579922246], players 2. Firewall enabled on all profiles. Windows exited first (scheduled-task termination was required because noVNC/WM_CLOSE did not reach Godot); host logged peer leave/despawn, then its window closed with exit 0. Temporary MIRELobbyJoin task deleted. Current Windows test tree is C:\MIRE-main; stale C:\MIRE still has the old 10s timeout. Not a 1.12 PASS: Linux absent, successful Windows latency log did not flush, and three-platform 60s movement/screenshots remain. Docs updated with this exact state.

Files: `docs/STEAM_CROSS_PLATFORM_TEST.md`, `docs/DELEGATION.md`, `docs/NEXT.md`, `docs/FINDINGS.md`

Commit at time of writing: `cc62ad9`

---

### DONE · F-026 · vane · 2026-08-16T23:24:50+00:00

**A deferred task pins the board's active milestone forever, hiding all remaining work**

Excluded 'blocked' from the active-milestone scan in _print_ready. A deferred task no longer pins its milestone active with nothing pickable. Verified: board now heads M2 with 2.3, M1 still honestly 13/14, 1.12 still 🚧 blocked.

Files: `.agent/bin/agent`

Commit at time of writing: `6c4cf24`

---

### HANDOFF · 2.1d · vane · 2026-08-16T23:46:09+00:00

**Produce the single `NEXT` batch in `docs/ASSET_TRACKER.md`; verify, advance the queue, hand off rather than close**

A-005 (loot set) is DONE and shipped: 10 GLBs in assets/loot/, 2542 polys, generator tools/blender/build_loot_set.py, source assets/source/loot_set.blend, catalog + README + 2 previews.

Verified: two clean rebuilds byte-identical; GLB 2.0 validation 10/10 with catalog exact and no orphans; closed/open base-footprint drift 0.00mm on all three chest pairs; both previews visually inspected; fresh Godot 4.7.1 --import 10/10 zero errors.

Three bugs found and fixed while verifying, all worth knowing before the next batch. (1) Lid rotation sign: the lid extends -Y from a rear hinge, so a positive X-rotation drove its front corner to z=-0.046 and the ground-normalization then lifted every open chest off the floor. (2) Per-state centring: normalizing each state on its own bounds shifted the chest body when the lid swung, which would desync a runtime mesh swap from collision — create_asset now takes anchor_parts and the pair measures 0.00mm. (3) Solid bodies: a chest built as one box reveals nothing when opened and seals its contents inside; chest_shell() builds a real cavity and contents fill to the rim, because anything on the floor of a chest is hidden by its front wall at standing eye height. Traps (2) and (3) are now in the tracker's Art and export contract, and (2) will bite A-007's Ward set directly.

Queue advanced: A-006 marked BLOCKED (its stated dependency is combat task 2.9 confirming the feel target, and 2.9 has not started) — Sequoyah has since authorised gale to work it anyway, so whoever holds it should flip the row and record that authorisation. A-007 (Basic Ward set, after A-003 which is done) is now NEXT. A-006 is also the first rig/animation batch, so it must satisfy the extra verification requirements: deform check, animation-name check, looping check, contact sheet.

Note this task collided: gale adopted A-005 mid-session believing this one had stalled. Resolved by direct agent-to-agent handover. 2.1d is a single repeating task id, so two batches cannot be in flight at once — coordinate before adopting.

Files: `docs/ASSET_TRACKER.md`, `tools/blender/build_loot_set.py`, `assets/source/loot_set.blend`, `assets/loot/README.md`, `assets/loot/catalog.json`, `assets/loot/exports/loot_chest_reinforced_closed.glb`, `assets/loot/exports/loot_chest_reinforced_open.glb`, `assets/loot/exports/loot_chest_small_closed.glb`, `assets/loot/exports/loot_chest_small_open.glb`, `assets/loot/exports/loot_chest_wellspring_closed.glb`, `assets/loot/exports/loot_chest_wellspring_open.glb`, `assets/loot/exports/loot_coin_pouch.glb`, `assets/loot/exports/loot_item_bag.glb`, `assets/loot/exports/loot_player_backpack.glb`, `assets/loot/exports/loot_powerup_orb.glb`, `assets/loot/preview/loot_preview.png`, `assets/loot/preview/loot_scale_preview.png`

Commit at time of writing: `4b7c6cb`

---

### HANDOFF · 2.1d · gale · 2026-08-16T23:59:35+00:00

**Produce the single `NEXT` batch in `docs/ASSET_TRACKER.md`; verify, advance the queue, hand off rather than close**

A-006 complete: four portable enemy GLBs in assets/enemies/ — a six-legged Mire crawler (skinned mesh, 17-bone rig, 6 clips), its spawn nest, and shell/leg death fragments. Deterministic generator at tools/blender/build_enemy_crawler.py, editable source at assets/source/enemy_crawler.blend, plus tools/enemy_crawler_check.gd for the Godot-side rig verification.

Verification: two clean rebuilds gave byte-identical GLBs and catalog and pixel-identical previews; GLB 2.0 validation 4/4 with catalog exact and no orphans; deform check confirms all 16 deform bones own geometry (root is deliberately non-deforming); clip durations match the authored timing exactly; three previews inspected including a rendered eight-pose contact sheet; fresh Godot 4.7.1 import 4/4 clean and enemy_crawler_check.gd passes on skeleton, skin, six clip names and loop modes.

Two traps this batch paid for, both now written into the tracker's verification contract. First, glTF stores animation in SECONDS, so the exporter divides frames by scene.render.fps and Blender defaults to 24 — every clip shipped 25 percent slow until the frame rate was set before the first export, and nothing in the .blend looked wrong because the frame numbers were right. Second, a multi-material mesh exports as one primitive per material, so a deform check that reads meshes[0].primitives[0] samples a sixth of the model and falsely reports most bones as carrying no geometry; union the joints over all primitives.

Also worth knowing for anything that plays these: Godot consumes the -loop name suffix, so the GLB's idle-loop and locomotion-loop arrive in engine as idle and locomotion. Asking for the exported name fails at runtime. Recorded in docs/DELEGATION.md Current state.

A-006's gate was waived by Sequoyah rather than met — combat task 2.9 has not started, so the 0.4 s tell and the rest of the timing come from DESIGN.md section 6 and not from playtest. The tracker row and the review column both say so; 2.9 should re-time the clips if it disagrees.

Next: A-007 (Ward set) is the single NEXT row and is a state set, so it needs A-005's anchor_parts treatment — centre every state on the shared foundation, not on its own bounds.

Files: `docs/ASSET_TRACKER.md`, `tools/blender/build_enemy_crawler.py`, `assets/enemies`, `assets/source/enemy_crawler.blend`, `tools/enemy_crawler_check.gd`, `assets/enemies/README.md`, `assets/enemies/catalog.json`, `assets/enemies/exports`, `assets/enemies/preview`, `assets/enemies/exports/enemy_crawler.glb`, `assets/enemies/exports/enemy_crawler_fragment_leg.glb`, `assets/enemies/exports/enemy_crawler_fragment_shell.glb`, `assets/enemies/exports/enemy_crawler_nest.glb`, `assets/enemies/preview/crawler_pose_sheet.png`, `assets/enemies/preview/enemies_preview.png`, `assets/enemies/preview/enemies_scale_preview.png`

Commit at time of writing: `f77d528`

---

### DONE · 2.1f · ember · 2026-08-17T00:24:32+00:00

**Author `playtest_hollow` — one shared layout file driving both the Blender visuals and the Godot collision, with elevation, a closed boundary, road clearance, and the loot/pickup/enemy kits placed**

Built playtest_hollow from one deterministic JSON layout: 463 props, 26 terrain records, 20 terrain bodies, 254 prop collision shapes, 4102 visual meshes, exact visual/collision origin parity, fresh Godot import, and repeatable Blender/GLB/preview validation.

Files: `world/gen/playtest_hollow.gd`, `world/gen/layouts/playtest_hollow.json`, `levels/playtest_hollow.tscn`, `tools/mapgen/hollow_layout.py`, `tools/blender/build_playtest_hollow.py`, `tools/playtest_hollow_check.gd`, `assets/maps/playtest_hollow.glb`, `assets/maps/README.md`

Commit at time of writing: `c358300`

---

### DONE · 2.1g · wick · 2026-08-17T00:47:21+00:00

**Animate environmental presentation: client-local foliage wind and campfire flame, spark, smoke, and light VFX; scalable and scene-safe**

Client-local environmental animation is live in Playtest Hollow: height-masked shared wind animates grass/fern/reed/sedge meshes; procedural billboard flames, sparks, smoke, and flickering lights replace static fire placeholders. Dedicated check: 1,772 foliage mesh parts, 4 fire sources, 0 failures. Full playtest_hollow_check: 4,102 visual meshes, 463 props, 274 colliders, 0 failures. Forward+ rendered inspection passed at the 120 FPS cap with corrected soft particle shapes; no scene wiring required.

Notes along the way:
- Environmental animation is client-local per ARCHITECTURE 2.2. Runtime discovery animates authored GLB placements automatically: shared vertex-wind materials plus code-built fire particles/lights; no scene/resource edits required.
- Rendered Forward+ inspection caught and fixed solid rectangular particle quads. Procedural billboard shader now shapes flame tongues, round sparks, and soft smoke; rendered run held the 120 FPS cap with no shader/runtime errors.

Files: `autoload/environment_vfx.gd`, `world/environment/foliage_wind.gdshader`, `tools/environment_vfx_check.gd`, `project.godot`, `docs/ROADMAP.md`, `docs/DELEGATION.md`, `docs/DECISIONS.md`, `world/environment/particle_billboard.gdshader`, `docs/NEXT.md`, `world/gen/playtest_hollow.gd`, `autoload/environment_vfx.gd.uid`, `tools/environment_vfx_check.gd.uid`, `world/environment/foliage_wind.gdshader.uid`, `world/environment/particle_billboard.gdshader.uid`

Commit at time of writing: `9121a9e`

---

### DONE · 2.3 · nettle · 2026-08-17T01:11:22+00:00

**Harvestable prop: hit → damage → yield → despawn → respawn. Host-authoritative (`ARCHITECTURE.md` §2.2).**

Built data-authored HarvestableDef, host-authoritative Harvestable hit/damage/deplete/respawn with parameterless client RPC, range/cooldown validation, on-change PROP replication, collision/visual state changes, and one host-only EventBus yield seam for 2.4. Protocol is v2. Fixed filtered-host addressability and F-027 filter lifetime in NetInterest. Verified: harvestable_check 39 PASS/0; real two-process ENet request/depletion/respawn PASS; interest_check all 3 sections PASS; handshake 0 failures; playtest_hollow default boot 463 props/274 shapes. Needs wiring: author ItemDef and HarvestableDef .tres resources and attach/instantiate Harvestable wrappers for A-001 map props; until then harvesting does not work in the playable map. Safe to start 2.4 against the EventBus callback signature recorded in docs/NEXT.md. verify_setup's one stale greybox-main assertion is F-028; pre-existing project.godot and other agents' files were untouched.

Notes along the way:
- Authority: host owns health, damage acceptance, yield emission, logical despawn and respawn. Client hit RPC carries no damage; host validates sender range and per-peer cooldown. Static definitions stay data-authored, and yield crosses into task 2.4 through EventBus rather than a direct inventory reference. Protocol version bumps because this adds an RPC and replicated property schema.
- Harness reproduced F-027: MultiplayerSynchronizer's visibility Callable does not strongly retain NetInterest.RadiusFilter on Godot 4.7.1. Harvestable stores the returned filter beside HarvestSync; shared NetInterest still needs a follow-up fix.
- Real ENet exposed that a client-side prop filter answers false for peer 1 (clients publish no NetInterest observers), so Godot rejects client-to-host RPCs as targeting a peer that cannot see the node. Host authority must always be visible/addressable for filtered world entities; encode that invariant in RadiusFilter and its check.
- Regression checks: harvestable_check 39 PASS/0 failures; harvestable_net_check real two-process ENet PASS; interest_check all 3 sections PASS; handshake_check 0 failures; default playtest_hollow boot exits 0 with 463 props/274 shapes. verify_setup has one unrelated stale main-scene assertion, filed F-028; project.godot was already user-modified and remains untouched.

Files: `systems/harvesting/harvestable_def.gd`, `systems/harvesting/harvestable_def.gd.uid`, `systems/harvesting/harvestable.gd`, `systems/harvesting/harvestable.gd.uid`, `core/events/event_bus.gd`, `core/events/event_bus.gd.uid`, `core/net/net_version.gd`, `tools/harvestable_check.gd`, `tools/harvestable_check.gd.uid`, `tools/harvestable_net_check.gd`, `tools/harvestable_net_check.gd.uid`, `core/net/net_interest.gd`, `tools/interest_check.gd`, `docs/FINDINGS.md`, `docs/NEXT.md`

Commit at time of writing: `32d853e`

---

### HANDOFF · 2.1d · ember · 2026-08-17T01:15:30+00:00

**Produce the single `NEXT` batch in `docs/ASSET_TRACKER.md`; verify, advance the queue, hand off rather than close**

A-007 DONE and queue advanced to A-008 NEXT. Eight Ward GLBs in assets/wards (2,182 polygons) with healthy/damaged/critical/destroyed silhouettes sharing exact foundation bounds at 0.00 mm centre/size drift; repair scaffold, boundary post and activation crystal included. Two clean Blender 5.2 rebuilds produced byte-identical GLBs/catalog; GLB 2.0, applied scale, exact catalog/no-orphan, 1600x1000 preview and visual checks passed. Fresh isolated Godot 4.7.1 import with pinned GodotSteam: 8/8 imported scenes, zero errors. Sequoyah's supplied rock/tree are separately tracked as S-001 in assets/environment_additions: source reference GLBs preserved under assets/source/reference_imports, diorama/render baggage removed, assembly scaling fixed, names/transforms/origins/palette normalized, boulder contact flattened; 2 GLBs/1,720 polygons, same deterministic/GLB/preview checks, Godot 2/2 zero-error import. Editable sources: assets/source/ward_set.blend and adapted_nature_set.blend. Next run starts A-008 only.

Files: `docs/ASSET_TRACKER.md`, `docs/DELEGATION.md`, `tools/blender/build_ward_set.py`, `assets/source/ward_set.blend`, `assets/wards`, `tools/blender/build_adapted_nature_set.py`, `assets/source/adapted_nature_set.blend`, `assets/source/reference_imports`, `assets/environment_additions`, `assets/environment_additions/README.md`, `assets/environment_additions/catalog.json`, `assets/environment_additions/exports/mire_broadleaf_tree.glb`, `assets/environment_additions/exports/mire_broadleaf_tree.glb.import`, `assets/environment_additions/exports/mire_mossy_boulder.glb`, `assets/environment_additions/exports/mire_mossy_boulder.glb.import`, `assets/environment_additions/preview/adapted_nature_preview.png`, `assets/environment_additions/preview/adapted_nature_preview.png.import`, `assets/environment_additions/preview/adapted_nature_scale_preview.png`, `assets/environment_additions/preview/adapted_nature_scale_preview.png.import`, `assets/wards/README.md`, `assets/wards/catalog.json`, `assets/wards/exports/ward_activation_crystal.glb`, `assets/wards/exports/ward_activation_crystal.glb.import`, `assets/wards/exports/ward_boundary_post.glb`, `assets/wards/exports/ward_boundary_post.glb.import`, `assets/wards/exports/ward_critical.glb`, `assets/wards/exports/ward_critical.glb.import`, `assets/wards/exports/ward_damaged.glb`, `assets/wards/exports/ward_damaged.glb.import`, `assets/wards/exports/ward_destroyed.glb`, `assets/wards/exports/ward_destroyed.glb.import`, `assets/wards/exports/ward_foundation.glb`, `assets/wards/exports/ward_foundation.glb.import`, `assets/wards/exports/ward_healthy.glb`, `assets/wards/exports/ward_healthy.glb.import`, `assets/wards/exports/ward_repair_scaffolding.glb`, `assets/wards/exports/ward_repair_scaffolding.glb.import`, `assets/wards/preview/ward_preview.png`, `assets/wards/preview/ward_preview.png.import`, `assets/wards/preview/ward_scale_preview.png`, `assets/wards/preview/ward_scale_preview.png.import`, `assets/source/reference_imports/low_poly_rock_asset.glb`, `assets/source/reference_imports/low_poly_tree_asset.glb`

Commit at time of writing: `4d7dbfd`

---

### DONE · 2.1h · pike · 2026-08-17T01:22:00+00:00

**Polish `playtest_hollow`: open the spawn-camp gates, enlarge and better connect the zones, improve grass, and add complementary ground-cover variants**

Expanded playtest_hollow from 68x68m to 88x88m with connected trail/transition terrain, rebalanced zone dressing, and 783 deterministic prop placements. Replaced the closed fence-gate visual with two swung-open leaves and changed gate collision to two post boxes, leaving four verified 1.8m-clear camp exits. Rebuilt grass as bent low-poly blade meshes, added meadow/tuft/seedhead families, raised the kit from 116 to 128 assets, and placed 319 grass props using all 18 variants. Updated dynamic scene checks and added a short Forward+ render check. Verified hollow_layout.py; playtest_hollow_check.gd (0 failures, all four physical egress rays clear, 783/783 visual alignment, 6256 meshes, 359 colliders); environment_vfx_check.gd (3477 foliage surfaces, 4 fires, 0 failures); and visible Forward+ Metal (120.0 FPS over 360 frames). Python compilation and git diff --check pass. No .tscn/.tres/.import edits were needed; the existing scene already consumes the shared GLB/layout sources.

Notes along the way:
- Authority: static visuals/collision and foliage VFX are client-local. Fence trap is in shared asset/layout data, not playtest_hollow.tscn: fence_gate has a full-width collider and closed-leaf mesh. Keep the scene untouched so visual and collision consumers stay aligned.
- Rebuilt the 128-asset map kit and the 88x88m hollow. Verified layout generation: 783 props, 339 prop shapes, 33 terrain records, 319 grass placements across 18 variants. Godot scene check: 0 failures, 359 total colliders, 6256 authored visual meshes, all four spawn-camp gate egress rays clear, 783/783 visual origins aligned. VFX check: 3477 wind-shaded foliage surfaces, 4 fires, 0 failures. Forward+ Metal render: 360 frames in 3.000s = 120.0 FPS on Apple M5 Pro. No .tscn/.tres/.import files changed.

Files: `docs/ROADMAP.md`, `tools/mapgen/hollow_layout.py`, `world/gen/layouts/playtest_hollow.json`, `tools/blender/build_playtest_hollow.py`, `assets/source/playtest_hollow.blend`, `assets/maps/playtest_hollow.glb`, `assets/maps/preview/playtest_hollow_preview.png`, `tools/playtest_hollow_check.gd`, `tools/blender/build_mire_map_kit.py`, `assets/source/mire_map_kit.blend`, `assets/environment`, `assets/environment/README.md`, `assets/environment/catalog.json`, `assets/environment/exports/grass_clump_a.glb`, `assets/environment/exports/grass_clump_b.glb`, `assets/environment/exports/grass_clump_c.glb`, `assets/environment/exports/grass_clump_d.glb`, `assets/environment/exports/grass_clump_e.glb`, `assets/environment/exports/grass_clump_f.glb`, `assets/environment/exports/grass_meadow_a.glb`, `assets/environment/exports/grass_meadow_b.glb`, `assets/environment/exports/grass_meadow_c.glb`, `assets/environment/exports/grass_meadow_d.glb`, `assets/environment/exports/grass_tuft_a.glb`, `assets/environment/exports/grass_tuft_b.glb`, `assets/environment/exports/grass_tuft_c.glb`, `assets/environment/exports/grass_tuft_d.glb`, `assets/environment/exports/grass_seedhead_a.glb`, `assets/environment/exports/grass_seedhead_b.glb`, `assets/environment/exports/grass_seedhead_c.glb`, `assets/environment/exports/grass_seedhead_d.glb`, `assets/environment/exports/fence_gate.glb`, `assets/environment/preview/ground_cover_preview.png`, `assets/environment/preview/mire_map_kit_preview.png`, `tools/playtest_hollow_render_check.gd`, `tools/playtest_hollow_render_check.gd.uid`, `assets/environment/exports/fence_post.glb`, `assets/environment/exports/fern_a.glb`, `assets/environment/exports/fern_b.glb`, `assets/environment/exports/fern_c.glb`, `assets/environment/exports/fern_d.glb`, `assets/environment/exports/fern_e.glb`, `assets/environment/exports/fern_f.glb`, `assets/environment/exports/mire_crystal_a.glb`, `assets/environment/exports/mire_crystal_b.glb`, `assets/environment/exports/mire_crystal_c.glb`, `assets/environment/exports/mire_crystal_d.glb`, `assets/environment/exports/mire_crystal_e.glb`, `assets/environment/exports/mire_crystal_f.glb`, `assets/environment/exports/mire_tendril_a.glb`, `assets/environment/exports/mire_tendril_b.glb`, `assets/environment/exports/mire_tendril_c.glb`, `assets/environment/exports/mire_tendril_d.glb`, `assets/environment/exports/mushroom_cluster_a.glb`, `assets/environment/exports/mushroom_cluster_b.glb`, `assets/environment/exports/mushroom_cluster_c.glb`, `assets/environment/exports/mushroom_cluster_d.glb`, `assets/environment/exports/mushroom_cluster_e.glb`, `assets/environment/exports/mushroom_cluster_f.glb`, `assets/environment/exports/reeds_a.glb`, `assets/environment/exports/reeds_b.glb`, `assets/environment/exports/reeds_c.glb`, `assets/environment/exports/reeds_d.glb`, `assets/environment/exports/wood_stairs.glb`, `assets/environment/preview/building_pieces_preview.png`, `assets/environment/preview/forest_debris_preview.png`, `assets/environment/preview/mire_growth_preview.png`, `assets/environment/preview/rocks_preview.png`, `assets/environment/preview/ruins_preview.png`, `assets/environment/preview/trees_preview.png`

Commit at time of writing: `37d8490`

---

### DONE · F-029 · nettle · 2026-08-17T01:24:51+00:00

**Task 2.3's harvest lifecycle is not wired into the playable map**

Playtest Hollow now wires 11 intact A-001 props to host-authoritative Harvestables with serialized log/stone/iron content and a 4 m attack ray. Verified normal main-scene boot (wired 11), real-map lifecycle/raycast (failures=0), real-map two-process ENet replication (host yields=1, client yields=0, failures=0), 39-assertion component regression, parameterless-request ENet regression, interest and handshake checks. Replicated visuals now coalesce cleanly with EnvironmentVFX. No editor or scene wiring remains.

Notes along the way:
- Authority remains host-owned. HarvestWorld deterministically wires only intact A-001 holders (5 trees, 4 stone, 2 iron), leaving damaged/stump set dressing decorative; attack is a 4 m client-local ray that submits parameterless request_hit. Replicated visual setters are coalesced to avoid transient VFX targets.

Files: `autoload/harvest_world.gd`, `autoload/harvest_world.gd.uid`, `project.godot`, `content/items/log.tres`, `content/items/stone.tres`, `content/items/iron_ore.tres`, `content/harvestables/tree.tres`, `content/harvestables/stone_node.tres`, `content/harvestables/iron_node.tres`, `tools/setup_harvest_content.gd`, `tools/setup_harvest_content.gd.uid`, `tools/harvest_world_check.gd`, `tools/harvest_world_check.gd.uid`, `docs/FINDINGS.md`, `docs/NEXT.md`, `tools/harvest_world_net_check.gd`, `core/util/mire_log.gd`, `systems/harvesting/harvestable.gd`

Commit at time of writing: `2382da8`

---

### HANDOFF · 2.1d · ember · 2026-08-17T01:27:46+00:00

**Produce the single `NEXT` batch in `docs/ASSET_TRACKER.md`; verify, advance the queue, hand off rather than close**

A-008 Wellspring batch finished and verified; A-009 extraction ship is the sole NEXT batch.

Files: `docs/ASSET_TRACKER.md`, `docs/DELEGATION.md`, `tools/blender/build_wellspring_set.py`, `assets/source/wellspring_set.blend`, `assets/wellsprings/README.md`, `assets/wellsprings/catalog.json`, `assets/wellsprings/exports/wellspring_distant_monolith.glb`, `assets/wellsprings/exports/wellspring_base.glb`, `assets/wellsprings/exports/wellspring_crystal.glb`, `assets/wellsprings/exports/wellspring_basin.glb`, `assets/wellsprings/exports/wellspring_roots.glb`, `assets/wellsprings/exports/wellspring_uncapped.glb`, `assets/wellsprings/exports/wellspring_capped.glb`, `assets/wellsprings/exports/wellspring_recorrupting.glb`, `assets/wellsprings/exports/wellspring_corrupted.glb`, `assets/wellsprings/exports/wellspring_ritual_pedestal.glb`, `assets/wellsprings/exports/wellspring_boundary_stones.glb`, `assets/wellsprings/exports/wellspring_guardian_platform.glb`, `assets/wellsprings/preview/wellspring_preview.png`, `assets/wellsprings/preview/wellspring_scale_preview.png`

Commit at time of writing: `6ce71ab`

---

### DONE · 2.4 · nettle · 2026-08-17T01:48:54+00:00

**Inventory system: stacks, add/remove, host-validated. Data layer only.**

Host-owned 24-slot inventories now stack by ItemDef limits, consume harvest yields, support all-or-nothing add/remove and atomic crafting transactions, confirm owner-only remove/move requests, and publish revisioned snapshots; first 8 stable slots are the hotbar seam. Inventory offline check: local_changes=9, host_changes=9, confirmations=3, failures=0. Real two-process ENet: targeted grant, isolation, accepted/rejected operations, anti-grant and peer cleanup all pass with failures=0. Real Hollow tree grants 3 logs with failures=0; harvest component/net, interest, protocol-v3 handshake, default boot, and all 8 session-lifecycle sections pass. Filed F-031 stale map handoff and F-032 stable identity needed for reconnect state.

Notes along the way:
- Inventory/crafting authority is host-owned. InventoryService keeps 24 stable slots per peer (first 8 reserved for hotbar UI), grants only through trusted host_add/host_transaction, and exposes no client add RPC. Client remove/move requests carry no peer id; host derives sender, validates, publishes a revisioned owner-only snapshot, and explicitly confirms accept/reject.
- Lifecycle regression exposed F-032: LOCAL auto-rejoin changes the ENet peer id, and the project has no stable run-player identity. Inventory cleanup on peer_left is correct and unambiguous today; preserving an orphan by join order would misassign state when multiple clients reconnect. Filed the cross-system rebind requirement rather than hiding it in inventory.

Files: `systems/inventory/inventory_store.gd`, `systems/inventory/inventory_store.gd.uid`, `autoload/inventory_service.gd`, `autoload/inventory_service.gd.uid`, `project.godot`, `core/net/net_version.gd`, `tools/inventory_check.gd`, `tools/inventory_check.gd.uid`, `tools/inventory_net_check.gd`, `tools/inventory_net_check.gd.uid`, `tools/harvest_world_check.gd`, `docs/NEXT.md`, `docs/DELEGATION.md`, `docs/FINDINGS.md`, `tools/harvestable_check.gd`

Commit at time of writing: `e57a88f`

---

### DONE · 2.1i · pike14 · 2026-08-17T02:10:02+00:00

**Audit existing art and improve the highest-impact hero/environment assets without bypassing their gameplay-review gates**

Audited and rebuilt existing assets, prioritizing Hollow: all 18 ambient trees and six harvest tree states now use coherent trunks, roots, branches and faceted crowns; damage uses concave cuts, broken limbs and chips; felled/stump states were rebuilt. Improved Ward/Wellspring state silhouettes and S-001 grounding, fixed deterministic generated-object ordering, updated catalogs/previews/docs, and changed no map/layout files. Verified 162 GLB 2.0 files across five exact catalogs, byte-identical GLBs/catalogs across two clean Blender 5.2 builds, Ward/Wellspring drift 0.00 mm, visual previews, and successful Godot 4.7.1 asset import. Needs human in-editor review: Hollow fog/density, tree collision, damage readability from the chop angle, and felled orientation.

Notes along the way:
- Scoped to standalone assets only; maps/layouts are excluded. Audit keeps blockout families behind their named playtest gates and targets A-007 Ward, A-008 Wellspring, and S-001 adapted nature for high-impact silhouette, state-readability, and grounding polish. Static visuals remain client-local cosmetics; gameplay state/authority stays host-owned.
- Sequoyah clarified the priority: improve standalone assets used in Hollow, especially the ambient tree set and every mined/chopped tree state. No Hollow map or layout changes. Preserve the existing asset names and shared state footprint so current placements and harvest wiring keep working.
- Rebuilt all 18 A-000 trees and six A-001 tree/harvest states without touching map/layout files. Preserved export names and origins; damage is now concave geometry, not decals. Also strengthened Ward/Wellspring state silhouettes, grounded S-001 boulder, and fixed generator object ordering so GLBs/catalogs are byte-stable. Validation: 162 GLB 2.0 files across five exact catalogs passed; two Blender 5.2 rebuilds matched for all GLBs/catalogs; Ward/Wellspring anchor drift 0.00 mm; Godot 4.7.1 imported assets successfully (only unrelated external-editor setting warnings).

Files: `docs/ROADMAP.md`, `docs/ASSET_TRACKER.md`, `tools/blender/build_ward_set.py`, `tools/blender/build_wellspring_set.py`, `tools/blender/build_adapted_nature_set.py`, `assets/source/ward_set.blend`, `assets/source/wellspring_set.blend`, `assets/source/adapted_nature_set.blend`, `assets/wards/README.md`, `assets/wards/catalog.json`, `assets/wards/exports/ward_activation_crystal.glb`, `assets/wards/exports/ward_boundary_post.glb`, `assets/wards/exports/ward_critical.glb`, `assets/wards/exports/ward_damaged.glb`, `assets/wards/exports/ward_destroyed.glb`, `assets/wards/exports/ward_foundation.glb`, `assets/wards/exports/ward_healthy.glb`, `assets/wards/exports/ward_repair_scaffolding.glb`, `assets/wards/preview/ward_preview.png`, `assets/wards/preview/ward_scale_preview.png`, `assets/wellsprings/README.md`, `assets/wellsprings/catalog.json`, `assets/wellsprings/exports/wellspring_base.glb`, `assets/wellsprings/exports/wellspring_basin.glb`, `assets/wellsprings/exports/wellspring_boundary_stones.glb`, `assets/wellsprings/exports/wellspring_capped.glb`, `assets/wellsprings/exports/wellspring_corrupted.glb`, `assets/wellsprings/exports/wellspring_crystal.glb`, `assets/wellsprings/exports/wellspring_distant_monolith.glb`, `assets/wellsprings/exports/wellspring_guardian_platform.glb`, `assets/wellsprings/exports/wellspring_recorrupting.glb`, `assets/wellsprings/exports/wellspring_ritual_pedestal.glb`, `assets/wellsprings/exports/wellspring_roots.glb`, `assets/wellsprings/exports/wellspring_uncapped.glb`, `assets/wellsprings/preview/wellspring_preview.png`, `assets/wellsprings/preview/wellspring_scale_preview.png`, `assets/environment_additions/README.md`, `assets/environment_additions/catalog.json`, `assets/environment_additions/exports/mire_broadleaf_tree.glb`, `assets/environment_additions/exports/mire_mossy_boulder.glb`, `assets/environment_additions/preview/adapted_nature_preview.png`, `assets/environment_additions/preview/adapted_nature_scale_preview.png`, `tools/blender/build_harvestable_resources.py`, `assets/source/harvestable_resources.blend`, `assets/harvestables/README.md`, `assets/harvestables/catalog.json`, `assets/harvestables/exports/harvest_tree_damaged_a.glb`, `assets/harvestables/exports/harvest_tree_damaged_b.glb`, `assets/harvestables/exports/harvest_tree_depleted_stump.glb`, `assets/harvestables/exports/harvest_tree_felled_trunk.glb`, `assets/harvestables/exports/harvest_tree_fresh_stump.glb`, `assets/harvestables/exports/harvest_tree_intact.glb`, `assets/harvestables/exports/iron_node_cracked.glb`, `assets/harvestables/exports/iron_node_depleted.glb`, `assets/harvestables/exports/iron_node_intact.glb`, `assets/harvestables/exports/stone_node_cracked.glb`, `assets/harvestables/exports/stone_node_depleted.glb`, `assets/harvestables/exports/stone_node_intact.glb`, `assets/harvestables/preview/harvestables_preview.png`, `assets/harvestables/preview/harvestables_scale_preview.png`, `tools/blender/build_mire_map_kit.py`, `assets/source/mire_map_kit.blend`, `assets/environment/README.md`, `assets/environment/catalog.json`, `assets/environment/exports/tree_bare_a.glb`, `assets/environment/exports/tree_bare_b.glb`, `assets/environment/exports/tree_bare_c.glb`, `assets/environment/exports/tree_bare_d.glb`, `assets/environment/exports/tree_birch_a.glb`, `assets/environment/exports/tree_birch_b.glb`, `assets/environment/exports/tree_birch_c.glb`, `assets/environment/exports/tree_birch_d.glb`, `assets/environment/exports/tree_crooked_a.glb`, `assets/environment/exports/tree_crooked_b.glb`, `assets/environment/exports/tree_crooked_c.glb`, `assets/environment/exports/tree_crooked_d.glb`, `assets/environment/exports/tree_pine_a.glb`, `assets/environment/exports/tree_pine_b.glb`, `assets/environment/exports/tree_pine_c.glb`, `assets/environment/exports/tree_pine_d.glb`, `assets/environment/exports/tree_pine_e.glb`, `assets/environment/exports/tree_pine_f.glb`, `assets/environment/preview/trees_preview.png`, `assets/environment/preview/mire_map_kit_preview.png`, `assets/environment/exports/boulder_a.glb`, `assets/environment/exports/boulder_b.glb`, `assets/environment/exports/boulder_c.glb`, `assets/environment/exports/boulder_d.glb`, `assets/environment/exports/boulder_e.glb`, `assets/environment/exports/boulder_f.glb`, `assets/environment/exports/boulder_g.glb`, `assets/environment/exports/boulder_h.glb`, `assets/environment/exports/fallen_log_a.glb`, `assets/environment/exports/fallen_log_b.glb`, `assets/environment/exports/fallen_log_c.glb`, `assets/environment/exports/fallen_log_d.glb`, `assets/environment/exports/fence_corner.glb`, `assets/environment/exports/fence_gate.glb`, `assets/environment/exports/fence_post.glb`, `assets/environment/exports/fence_straight.glb`, `assets/environment/exports/fern_a.glb`, `assets/environment/exports/fern_b.glb`, `assets/environment/exports/fern_c.glb`, `assets/environment/exports/fern_d.glb`, `assets/environment/exports/fern_e.glb`, `assets/environment/exports/fern_f.glb`, `assets/environment/exports/grass_clump_a.glb`, `assets/environment/exports/grass_clump_b.glb`, `assets/environment/exports/grass_clump_c.glb`, `assets/environment/exports/grass_clump_d.glb`, `assets/environment/exports/grass_clump_e.glb`, `assets/environment/exports/grass_clump_f.glb`, `assets/environment/exports/grass_meadow_a.glb`, `assets/environment/exports/grass_meadow_b.glb`, `assets/environment/exports/grass_meadow_c.glb`, `assets/environment/exports/grass_meadow_d.glb`, `assets/environment/exports/grass_seedhead_a.glb`, `assets/environment/exports/grass_seedhead_b.glb`, `assets/environment/exports/grass_seedhead_c.glb`, `assets/environment/exports/grass_seedhead_d.glb`, `assets/environment/exports/grass_tuft_a.glb`, `assets/environment/exports/grass_tuft_b.glb`, `assets/environment/exports/grass_tuft_c.glb`, `assets/environment/exports/grass_tuft_d.glb`, `assets/environment/exports/mire_crystal_a.glb`, `assets/environment/exports/mire_crystal_b.glb`, `assets/environment/exports/mire_crystal_c.glb`, `assets/environment/exports/mire_crystal_d.glb`, `assets/environment/exports/mire_crystal_e.glb`, `assets/environment/exports/mire_crystal_f.glb`, `assets/environment/exports/mire_tendril_a.glb`, `assets/environment/exports/mire_tendril_b.glb`, `assets/environment/exports/mire_tendril_c.glb`, `assets/environment/exports/mire_tendril_d.glb`, `assets/environment/exports/mushroom_cluster_a.glb`, `assets/environment/exports/mushroom_cluster_b.glb`, `assets/environment/exports/mushroom_cluster_c.glb`, `assets/environment/exports/mushroom_cluster_d.glb`, `assets/environment/exports/mushroom_cluster_e.glb`, `assets/environment/exports/mushroom_cluster_f.glb`, `assets/environment/exports/reeds_a.glb`, `assets/environment/exports/reeds_b.glb`, `assets/environment/exports/reeds_c.glb`, `assets/environment/exports/reeds_d.glb`, `assets/environment/exports/rock_cluster_a.glb`, `assets/environment/exports/rock_cluster_b.glb`, `assets/environment/exports/rock_cluster_c.glb`, `assets/environment/exports/rock_cluster_d.glb`, `assets/environment/exports/rock_cluster_e.glb`, `assets/environment/exports/rock_cluster_f.glb`, `assets/environment/exports/root_cluster_a.glb`, `assets/environment/exports/root_cluster_b.glb`, `assets/environment/exports/root_cluster_c.glb`, `assets/environment/exports/root_cluster_d.glb`, `assets/environment/exports/ruin_arch_a.glb`, `assets/environment/exports/ruin_arch_b.glb`, `assets/environment/exports/ruin_column_a.glb`, `assets/environment/exports/ruin_column_b.glb`, `assets/environment/exports/ruin_column_c.glb`, `assets/environment/exports/ruin_column_d.glb`, `assets/environment/exports/ruin_wall_a.glb`, `assets/environment/exports/ruin_wall_b.glb`, `assets/environment/exports/ruin_wall_c.glb`, `assets/environment/exports/ruin_wall_d.glb`, `assets/environment/exports/standing_stone_a.glb`, `assets/environment/exports/standing_stone_b.glb`, `assets/environment/exports/standing_stone_c.glb`, `assets/environment/exports/standing_stone_d.glb`, `assets/environment/exports/stone_floor.glb`, `assets/environment/exports/stone_foundation.glb`, `assets/environment/exports/stone_half_wall.glb`, `assets/environment/exports/stone_marker_a.glb`, `assets/environment/exports/stone_marker_b.glb`, `assets/environment/exports/stone_pillar.glb`, `assets/environment/exports/stone_stairs.glb`, `assets/environment/exports/stone_wall_door.glb`, `assets/environment/exports/stone_wall_solid.glb`, `assets/environment/exports/stone_wall_window.glb`, `assets/environment/exports/stump_a.glb`, `assets/environment/exports/stump_b.glb`, `assets/environment/exports/stump_c.glb`, `assets/environment/exports/stump_d.glb`, `assets/environment/exports/wood_beam.glb`, `assets/environment/exports/wood_floor.glb`, `assets/environment/exports/wood_foundation.glb`, `assets/environment/exports/wood_half_wall.glb`, `assets/environment/exports/wood_post.glb`, `assets/environment/exports/wood_railing.glb`, `assets/environment/exports/wood_roof_corner.glb`, `assets/environment/exports/wood_roof_slope.glb`, `assets/environment/exports/wood_stairs.glb`, `assets/environment/exports/wood_wall_door.glb`, `assets/environment/exports/wood_wall_solid.glb`, `assets/environment/exports/wood_wall_window.glb`, `assets/environment/preview/building_pieces_preview.png`, `assets/environment/preview/forest_debris_preview.png`, `assets/environment/preview/ground_cover_preview.png`, `assets/environment/preview/mire_growth_preview.png`, `assets/environment/preview/rocks_preview.png`, `assets/environment/preview/ruins_preview.png`

Commit at time of writing: `15eed59`

---

### DONE · 2.5 · dusk3 · 2026-08-17T02:30:40+00:00

**Inventory UI — grid, drag/drop, hotbar**

Client-local InventoryUI is registered and working: persistent eight-slot hotbar, Tab/Escape 24-slot field pack, ItemDef icon/name presentation, 1-8 selection, and drag/drop moves that render only authoritative snapshots and show operation confirmations. Opening joins blocks_gameplay_input so PlayerController suppresses movement/jump without pausing network processing. Verified inventory_ui_check: 29 passes, 0 failures; inventory_check: failures=0; inventory_net_check: two-process failures=0; playtest_hollow_check: 6256 visuals, 359 colliders, failures=0; main scene ran 180 frames; Forward+ renders saved at 1280x720 and 374x666. verify_setup has only its pre-existing F-028 stale-main-scene assertion; every other section passed. No editor wiring remains. Safe to start 2.6.

Notes along the way:
- Authority: client-local UI reads immutable InventoryService snapshots; all drag/drop mutations submit full-stack request_move_stack calls and wait for host confirmation. Hotbar selection is presentation-only until held-item work exists. Inventory releases the cursor without pausing multiplayer, and movement gates on captured mouse state.
- Implemented InventoryUI autoload with 24-slot grid, persistent eight-slot hotbar, ItemDef icons/name fallback, Tab/Escape cursor lifecycle, 1-8 selection, and drag/drop routed through InventoryService. Opening joins blocks_gameplay_input so PlayerController suppresses movement/jump without pausing networking. Focused UI check: 29 passes, 0 failures; rendered 1280x720 and 374x666 frames; inherited inventory and two-process ENet checks both passed.

Files: `ui/inventory/inventory_ui.gd`, `ui/inventory/inventory_ui.gd.uid`, `tools/inventory_ui_check.gd`, `tools/inventory_ui_check.gd.uid`, `tools/inventory_ui_render_check.gd`, `tools/inventory_ui_render_check.gd.uid`, `entities/player/player_controller.gd`, `project.godot`, `docs/NEXT.md`, `docs/DELEGATION.md`

Commit at time of writing: `97024c6`

---

### DONE · F-033 · dusk3 · 2026-08-17T02:41:22+00:00

**Inventory hotbar aliases eight backpack slots instead of adding eight separate slots**

Corrected the inventory contract to 24 backpack slots plus eight separate hotbar slots. The host owns 32 stable dictionaries; grants and crafting removals prefer backpack slots, hotbar is 24-31, UI moves between regions without aliasing, and protocol is v4. Verified 51 inventory assertions, 32 UI assertions, two-process ENet inventory movement, version handshake, Playtest Hollow, 180-frame main scene, and desktop/narrow Forward+ renders with zero task failures. F-033 moved to Resolved. No editor work remains; safe to start 2.6.

Notes along the way:
- Corrected contract: 32 stable authoritative slots total. Backpack is 0-23 so grants fill it first; hotbar is separate 24-31. InventoryStore will prefer backpack for empty-slot grants and ingredient removal, using hotbar capacity only as overflow/last resort. Snapshot shape changes wire compatibility, so protocol bumps from 3 to 4.
- Fixed and verified: authoritative snapshots are 32 slots (backpack 0-23, hotbar 24-31); grants and removals prefer backpack; UI drag/drop maps to distinct ranges; protocol v4. inventory_check 51/0, inventory_ui_check 32/0, two-process inventory_net_check failures=0, handshake 0 failures, Playtest Hollow failures=0, main scene 180 frames, Forward+ renders show independent contents and full narrow hotbar.

Files: `autoload/inventory_service.gd`, `systems/inventory/inventory_store.gd`, `ui/inventory/inventory_ui.gd`, `tools/inventory_check.gd`, `tools/inventory_net_check.gd`, `tools/inventory_ui_check.gd`, `tools/inventory_ui_render_check.gd`, `core/net/net_version.gd`, `docs/FINDINGS.md`, `docs/NEXT.md`, `docs/DELEGATION.md`

Commit at time of writing: `ac0e0f7`

---

### DONE · 2.6 · dusk3 · 2026-08-17T02:52:00+00:00

**Crafting: recipe check, craft request → host validates → grants. One station (workbench).**

Host-authoritative workbench crafting is implemented and registered: one Stone Axe recipe spends 2 logs plus 3 stone atomically, client requests carry no peer identity, and host validates the authoritative player within 3.25 m of the mapped primitive workbench. Offline, UI/inventory regression, handshake, Playtest Hollow, main-scene smoke, and real two-process ENet checks all pass. Protocol is v5. No editor or scene wiring remains; task 2.7 can build directly on CraftingService's query/request/confirmation API.

Notes along the way:
- Authority: crafting is host-owned. Client requests carry recipe_id and request_id only; host derives sender, validates the registered RecipeDef, authoritative player proximity to the mapped primitive workbench, and commits inputs/output through InventoryService.host_transaction. One stone-axe vertical-slice recipe is authored; bulk content remains 3.2. New RPC bumps protocol v4 to v5.
- Godot rejected PackedStringArray(...) as a const expression in CraftingService; because 2.6 intentionally supports exactly one primitive workbench, replaced the collection with one StringName constant. The content authoring run still serialized both resources successfully, but does not count as a clean validation run.
- Verified on Godot 4.7.1: crafting_check 32/32, crafting_net_check 18/18 in two real ENet processes, inventory_check 49/49, inventory_ui_check 31/31, handshake_check 14/14, playtest_hollow_check 50/50, and a 180-frame main-scene smoke all pass. The authored hollow contains station_workbench_primitive. CraftingService is registered; no editor or scene wiring remains.

Files: `autoload/crafting_service.gd`, `autoload/crafting_service.gd.uid`, `tools/setup_crafting_content.gd`, `tools/setup_crafting_content.gd.uid`, `content/items/stone_axe.tres`, `content/recipes/stone_axe.tres`, `tools/crafting_check.gd`, `tools/crafting_check.gd.uid`, `tools/crafting_net_check.gd`, `tools/crafting_net_check.gd.uid`, `core/net/net_version.gd`, `project.godot`, `docs/NEXT.md`, `docs/DELEGATION.md`

Commit at time of writing: `6a4cb45`

---

### DONE · 2.7 · dusk3 · 2026-08-17T04:01:51+00:00

**Crafting UI**

CraftingUI autoload: interact-gated workbench panel, in-range prompt, per-ingredient have/need from the authoritative snapshot, and host-confirmed crafting with no prediction. One cursor UI at a time via blocks_gameplay_input (D-032); the panel closes itself when the player leaves station range. Verified on Godot 4.7.1: crafting_ui_check 46/46, crafting_ui_render_check at 1280x720 and 375x667, extended crafting_net_check 28/28 in two real ENet processes (client sees 'Waiting for the host...' then the host's verbatim accept/reject), and inherited crafting_check 32/32, inventory_ui_check 29/29, inventory_check all-pass.

Notes along the way:
- Authority: client-local presentation only. CraftingUI reads CraftingService's presentation helpers over immutable InventoryService snapshots and turns the craft button into request_craft(); the host revalidates recipe, station range and ingredients, and the panel renders craft_confirmed verbatim with no prediction.
- A local host confirms INSIDE request_craft(), before the id it returns exists to compare against — so the confirmation handler gates on an in-flight flag, not an id. Gating on the id made the 'Waiting for the host' status overwrite an answer that had already arrived.

Files: `ui/crafting/crafting_ui.gd`, `ui/crafting/crafting_ui.gd.uid`, `tools/crafting_ui_check.gd`, `tools/crafting_ui_check.gd.uid`, `tools/crafting_ui_render_check.gd`, `tools/crafting_ui_render_check.gd.uid`, `project.godot`, `tools/crafting_net_check.gd`

Commit at time of writing: `51d75be`

---

### DONE · 2.8 · dusk3 · 2026-08-17T04:31:24+00:00

**Melee combat v1: wind-up → commit → recovery, hitbox, hitstop, screenshake, impact SFX**

Melee v1: CombatService autoload with committed wind-up/commit/recovery, host-resolved hitbox over the new 'damageable' seam, WeaponDef content (content/weapons/stone_axe.tres) keyed by item id and loaded by Registry, code-built unarmed fallback, client-local hitstop, camera impact shake and a placeholder impact thud. Client predicts its own swing; the host derives the weapon from its own inventory and owns every hit (D-034). Verified on Godot 4.7.1: combat_check 42/42, combat_net_check 23/23 in two real ENet processes (host applied 3 damage for the held axe and 1 for an empty slot, proving host-side weapon derivation; spam rejected mid-recovery). Regression: harvest_world 70/70, harvestable 43/43, harvestable_net 12/12, inventory 51/51, crafting 32/32, crafting_ui 47/47. No authored impact sound exists yet - the thud is a code-built placeholder.

Notes along the way:
- Authority split (D-034): the swing is client-predicted on the press, the hit is host. A client sends only a hotbar slot index; the host reads its OWN host_slots(peer_id) for that slot to decide the weapon, and uses the yaw/pitch the player synchronizer already replicates for aim. Targets are the group 'damageable' + host_apply_damage(amount, peer) -> bool, which Harvestable already had; 2.10's enemies join the same group with no CombatService change.
- Hitstop is the attacker's own swing clock, never Engine.time_scale - time_scale slows the frame loop every transport pump is polled from (same mechanism as F-025). Filed F-033: task 2.9's gate ('one enemy with one weapon feels great') cannot be met before 2.10 builds the enemy; tuning against a tree would look like the gate passing.

Files: `systems/combat/weapon_def.gd`, `systems/combat/weapon_def.gd.uid`, `autoload/combat_service.gd`, `autoload/combat_service.gd.uid`, `entities/player/player_camera.gd`, `entities/player/player_controller.gd`, `systems/harvesting/harvestable.gd`, `autoload/registry.gd`, `content/weapons/stone_axe.tres`, `tools/setup_combat_content.gd`, `tools/setup_combat_content.gd.uid`, `tools/combat_check.gd`, `tools/combat_check.gd.uid`, `tools/combat_net_check.gd`, `tools/combat_net_check.gd.uid`, `project.godot`

Commit at time of writing: `95969ac`

---

### HANDOFF · 2.1d · kiln9 · 2026-08-17T04:31:26+00:00

**Produce the single `NEXT` batch in `docs/ASSET_TRACKER.md`; verify, advance the queue, hand off rather than close**

A-004R + A-042a done, both OUT OF QUEUE at Sequoyah's direct request ('better tool assets, and inventory icons'). A-009 is untouched and still the NEXT batch — start there. A-004R rebuilt all ten tool/weapon designs in place (same names, same 20 exports, dimensions within ~6 cm) using two new reusable builders in build_tool_weapon_set.py: ground_profile() takes per-point bevel DISTANCES in metres, not fractions, and swept_shaft() takes a radius per path point. Two traps paid for: a fractional inset rounds off exactly the corners that make a silhouette, and a bright edge laid over a head is invisible because it loses to the head's own silhouette at the rim — butt the two shapes along a seam instead. Judge heads on a six-azimuth orbit render, never head-on; both bugs were invisible from the front. A-042a added 24 inventory icons in assets/icons/, rendered from the shipped GLBs rather than drawn (D-033), with measured framing and Cycles + pinned seed because EEVEE would not reproduce anti-aliasing on thin silhouettes. Extend SOURCES in render_item_icons.py for new families; do not start a second icon pipeline. Verify with tools/item_icons_check.gd. Still open for Sequoyah: icons have not been seen at real inventory slot size.

Files: `docs/ASSET_TRACKER.md`, `docs/DELEGATION.md`, `tools/blender/build_tool_weapon_set.py`, `tools/blender/render_item_icons.py`, `assets/source/tool_weapon_set.blend`, `assets/tools_weapons`, `assets/icons`, `docs/DECISIONS.md`, `content/items/iron_ore.tres`, `content/items/log.tres`, `content/items/stone.tres`, `content/items/stone_axe.tres`, `tools/item_icons_check.gd`

Commit at time of writing: `95969ac`

---

### DONE · F-035 · kiln9 · 2026-08-17T04:39:09+00:00

**Inventory icons are capped at 26 px because a `CenterContainer` sizes children to their minimum**

Icon TextureRect moved out of the CenterContainer into its own full-slot MarginContainer, added as the PanelContainer's first child so it fills the slot and draws behind the key/amount labels; padding scales with slot size. Verified with inventory_ui_check.gd (3 confirmations, 0 failures) and Forward+ renders at 1280x720 and 374x666.

Files: `ui/inventory/inventory_ui.gd`, `docs/FINDINGS.md`

Commit at time of writing: `8564d5c`

---

### DONE · F-002 · dusk3 · 2026-08-17T04:46:46+00:00

**Sprint-FOV lerp uses the framerate-dependent smoothing form**

Switched the sprint-FOV lerp to the framerate-independent 1.0 - exp(-speed*delta) form with a comment naming the finding and ARCHITECTURE 5a rule 6. verify_setup 0 failures.

Files: `entities/player/player_camera.gd`

Commit at time of writing: `6f28dd9`

---

### DONE · F-011 · dusk3 · 2026-08-17T04:46:46+00:00

**Autoloads are not compile-time identifiers in a `--script` main loop**

Closed by fixing, not by documenting: a --script main loop compiles its DEPENDED scripts in the same pass, so the restriction reaches any script reachable through a class_name. 2.8's bare CombatService in player_controller.gd had silently broken verify_setup (4 failures) and interp_check (3). Now resolved by path. Both harnesses back to 0. Rule promoted to DELEGATION.

Files: `entities/player/player_controller.gd`

Commit at time of writing: `6f28dd9`

---

### DONE · F-012 · dusk3 · 2026-08-17T04:46:47+00:00

**A `MultiplayerSynchronizer`'s authority must be set BEFORE `add_child()`**

Fix landed in 1.5 and 1.6/1.8 both honoured it; promoted the permanent rule (authority before add_child) into DELEGATION rather than leaving a warning on the findings board.

Files: `docs/FINDINGS.md`

Commit at time of writing: `6f28dd9`

---

### DONE · F-016 · dusk3 · 2026-08-17T04:46:47+00:00

**A brand-new `class_name` is not resolvable by bare identifier in a `--script` main loop**

Promoted the preload-instead-of-bare-class_name convention into DELEGATION alongside F-011. Engine behaviour unchanged; only where it is written down.

Files: `docs/FINDINGS.md`

Commit at time of writing: `6f28dd9`

---

### DONE · F-018 · dusk3 · 2026-08-17T04:46:47+00:00

**`PlayerNet` has no way to be told when a player spawns, so observers reach into its children**

PlayerNet now emits player_spawned/player_despawned from its own container subscription (not from _spawn_for, which is host-only) and exposes players_root(). NetInterp no longer resolves the container by name. interp_check 0 failures plus all four two-process ENet checks.

Files: `autoload/player_net.gd`, `autoload/net_interp.gd`

Commit at time of writing: `6f28dd9`

---

### DONE · F-021 · dusk3 · 2026-08-17T04:46:47+00:00

**The net debug panel harness passes while Godot reports an uninitialized multiplayer root**

Gave the harness's second peer a root_path before attaching its peer; it must be /root, not a private node, or autoload-addressed RPCs answer 'Node not found' instead. Uninitialized-root errors 0 (was a stream); engine errors 11 -> 2. Residual 2 filed as F-037. GDScript has no hook to fail on engine errors; the grep convention is now in DELEGATION.

Files: `tools/net_debug_panel_check.gd`

Commit at time of writing: `6f28dd9`

---

### DONE · F-028 · dusk3 · 2026-08-17T04:46:47+00:00

**`verify_setup.gd` hard-codes the superseded greybox main scene**

verify_setup no longer pins a main scene path: greybox is now an explicit physics fixture and the configured main_scene is validated structurally. 0 failures against playtest_hollow.

Files: `tools/verify_setup.gd`

Commit at time of writing: `6f28dd9`

---

### DONE · F-031 · dusk3 · 2026-08-17T04:46:47+00:00

**`DELEGATION.md` still describes the pre-polish Playtest Hollow layout**

DELEGATION now carries playtest_hollow_check's own output (88x88m, 783 props, 33 terrain records, 6256 meshes, 359 shapes) and says to re-read them from the check rather than hand-editing.

Files: `docs/FINDINGS.md`

Commit at time of writing: `6f28dd9`

---

### HANDOFF · F-025 · dusk3 · 2026-08-17T04:46:47+00:00

**Steam's callback pump runs once per rendered frame, so a slow frame rate slows the handshake**

Item 1 fixed: SteamLobby's run_callbacks and NetTransport's connect watchdog moved from _process to _physics_process, so a frame-rate collapse no longer starves Steam by the same factor. Mitigation, not full decoupling - physics steps are still capped per frame. Item 2 is untouched and is what keeps this open: nobody has measured a real Windows Steam first join, and no macOS check can exercise this path. Measure on the physical Windows PC, record frame rate beside the latency, then set STEAM_CONNECT_TIMEOUT_SEC from evidence.

Files: `autoload/steam_lobby.gd`, `autoload/net_transport.gd`

Commit at time of writing: `6f28dd9`

---

### DONE · F-017 · dusk3 · 2026-08-17T04:51:38+00:00

**A brand-new script still ships without its `.uid`, because the sidecar does not exist yet**

ship now runs a Godot import when its staged set has a .gd with no sidecar, then stages what appeared. Skips with a warning if Godot is running (D-031), not found (GODOT= names it), or the import fails - ship must never fail for environmental reasons. Verified end-to-end with a throwaway probe script.

Files: `.agent/bin/agent`

Commit at time of writing: `cbd3357`

---

### DONE · F-034 · dusk3 · 2026-08-17T04:51:38+00:00

**`agent ship` silently drops directory claims and appends stray argv to the commit message**

All three parts fixed: directory claims expand to their changed files at ship time, path-shaped arguments are rejected before any state is loaded instead of being glued onto the commit subject, and the sign-off prints how many files were left alone and how many it truncated. The fourth observation (shipping a claimed doc that held another agent's edits) is working practice, not a ship bug - recorded as such.

Commit at time of writing: `cbd3357`

---

### DONE · F-032 · dusk3 · 2026-08-17T15:43:36+00:00

**Auto-rejoin assigns a new peer id, so peer-keyed gameplay state cannot follow it**

Host-issued opaque run-player token (core/net/run_identity.gd) minted on the client hello; NetSession emits run_player_rebound(old,new) and run_player_expired(peer). The fix that matters is a deletion: InventoryService no longer releases on peer_left, because peer_left cannot tell a reconnect from a departure. A live peer's token is never reassigned and a parked identity expires after 90s. Protocol 5 -> 6. Verified: run_identity_check 37/37 offline, and session_lifecycle_check over real multi-process ENet - peer 1545394978 came back as 175915464 with its 7 logs intact and nothing left behind. Recorded as D-035.

Files: `core/net/net_session.gd`, `core/net/net_version.gd`, `core/net/run_identity.gd`, `core/net/run_identity.gd.uid`, `autoload/inventory_service.gd`, `tools/session_lifecycle_check.gd`, `tools/run_identity_check.gd`, `tools/run_identity_check.gd.uid`

Commit at time of writing: `5483f2f`

---

### DONE · 2.10 · dusk3 · 2026-08-17T15:58:44+00:00

**Enemy v1: host-authoritative chase + attack, nav-driven, health, death, ragdoll or dissolve**

Enemy v1: EnemyWorld autoload (host-only spawning, per-session navmesh bake from the level's static collision, registry for 2.12) plus Enemy - IDLE/CHASE/TELL/ATTACK/RECOVER/DEAD, nav-driven with straight-line fallback, aggro hysteresis, 0.4s telegraph resolving at its END so backing out beats the swing, uncancellable committed attack, health, death and a corpse that leaves the damageable group. One authored crawler.tres over A-006. Verified on Godot 4.7.1: enemy_check 44/44 offline, enemy_net_check 15/15 in two real ENet processes (client copy runs no physics and is NetInterp-smoothed). Regression: combat, harvest_world, interp, verify_setup, run_identity, crafting_ui all 0 failures. Player damage is an EventBus event - 2.13 owns player health.

Notes along the way:
- Authority: host owns every enemy decision - target, path, turn, when the swing lands, health, death. Clients run no AI; position/yaw/state/health replicate through a code-built synchronizer named NetConfig.PLAYER_SYNC_NODE so NetInterp smooths enemies unchanged (closes F-004's enemy half). Enemies join 'damageable' so 2.8's CombatService needed no change.
- Two bugs the checks caught: the held-target lookup went through PlayerNet, which knows only players IT spawned, so aggro hysteresis silently never worked outside a session - now scans the players group first. And the enemy attack emits an EventBus event rather than inventing player health, because 2.13 owns what a hit costs.

Files: `systems/enemies/enemy_def.gd`, `systems/enemies/enemy_def.gd.uid`, `systems/enemies/enemy.gd`, `systems/enemies/enemy.gd.uid`, `autoload/enemy_world.gd`, `autoload/enemy_world.gd.uid`, `content/enemies/crawler.tres`, `tools/setup_enemy_content.gd`, `tools/setup_enemy_content.gd.uid`, `tools/enemy_check.gd`, `tools/enemy_check.gd.uid`, `tools/enemy_net_check.gd`, `tools/enemy_net_check.gd.uid`, `project.godot`, `core/events/event_bus.gd`

Commit at time of writing: `77d3f96`

---

### HANDOFF · 2.9 · dusk3 · 2026-08-17T16:04:25+00:00

**Tune combat feel until one enemy with one weapon feels great. Do not proceed otherwise.**

Mechanical work complete; the GATE IS NOT PASSED and only Sequoyah can pass it. Done: crawler move_speed 3.4 -> 4.4 (outruns a 4.0 walk, loses to a 6.0 sprint) so backpedaling is no longer free and the 0.4s telegraph matters; enemy hit reaction via a replicated hit_counter driving A-006's hit clip plus a 0.12s white overlay; corpse sinks and fades over corpse_seconds instead of blinking out; tools/combat_feel_check.gd prints the whole picture and asserts relationships between authored values (0 failures). Verified: enemy_check 44/44, enemy_net_check 15/15, combat_check 0 failures. NEXT: a real playtest. Judge the 0.4s tell in first person, whether the 100-degree arc feels generous or sloppy, whether 0.075s hitstop reads as impact or hitch, and whether 4 swings per crawler holds with three of them. Tune content/weapons/stone_axe.tres and content/enemies/crawler.tres in the inspector - do NOT re-run the setup_*_content tools afterwards, they overwrite. Still missing: an authored impact sound; the thud is a code-built placeholder.

Files: `systems/enemies/enemy.gd`, `content/enemies/crawler.tres`, `content/weapons/stone_axe.tres`, `tools/setup_enemy_content.gd`, `tools/setup_combat_content.gd`, `tools/combat_feel_check.gd`, `tools/combat_feel_check.gd.uid`

Commit at time of writing: `6b0d5a8`

---

### HANDOFF · 2.14 · dusk3 · 2026-08-17T16:22:54+00:00

**Playtest with friends. Write down what they said, not what you think they meant.**

PLAYABILITY ONLY - the actual playtest with friends is untouched and still the task. What landed: a starting loadout (10 tools + resources, 8 stacks moved onto the hotbar so you can swing immediately), 9 generated ItemDefs and 7 WeaponDefs from the A-004 catalog, and ambient crawler spawning (4, respawning, at the East Mire nest marker) with an offline bootstrap that bakes the level navmesh - 2529 polygons - because pressing Play opens no session and nothing called bake_navigation. Verified: dev_loadout_check 16/16 against the REAL main scene; enemy, combat, crafting, inventory, inventory_ui, crafting_ui, combat_feel, verify_setup all 0 failures. One trap worth knowing: DevLoadout must stay gated on get_tree().current_scene, or it grants inside every --script harness and four checks fail on a non-empty inventory. Weapon numbers are derived, not tuned - 2.9 owns them.

Files: `tools/setup_tool_content.gd`, `tools/setup_tool_content.gd.uid`, `core/dev/dev_loadout.gd`, `core/dev/dev_loadout.gd.uid`, `autoload/enemy_world.gd`, `project.godot`, `tools/dev_loadout_check.gd`, `tools/dev_loadout_check.gd.uid`, `content/items/wooden_axe.tres`, `content/items/wooden_pickaxe.tres`, `content/items/stone_pickaxe.tres`, `content/items/iron_pickaxe.tres`, `content/items/cleaver.tres`, `content/items/skewer.tres`, `content/items/short_bow.tres`, `content/items/arrow.tres`, `content/items/repair_hammer.tres`, `content/weapons/wooden_axe.tres`, `content/weapons/wooden_pickaxe.tres`, `content/weapons/stone_pickaxe.tres`, `content/weapons/iron_pickaxe.tres`, `content/weapons/cleaver.tres`, `content/weapons/skewer.tres`, `content/weapons/repair_hammer.tres`

Commit at time of writing: `01be471`

---

### DONE · F-039 · dusk3 · 2026-08-17T16:31:36+00:00

**A-006's crawler faces +Z, but its generator, catalog and docs all say -Z**

EnemyDef.model_yaw_offset_degrees rotates the visual only; crawler set to 180. A-006 exports facing +Z while its generator, catalog and DELEGATION all say -Z, so the correct _face() math pointed the model's tail at the player - that is both 'walks backwards' and 'attacks facing away'. Verified by rendering a real spawned crawler from the player's eye. The asset half is still owed and is recorded in the finding.

Files: `systems/enemies/enemy.gd`, `systems/enemies/enemy_def.gd`, `content/enemies/crawler.tres`, `tools/setup_enemy_content.gd`, `tools/enemy_facing_check.gd`, `tools/enemy_facing_check.gd.uid`

Commit at time of writing: `51aafe5`

---

### DONE · F-040 · dusk3 · 2026-08-17T16:31:36+00:00

**A dead enemy falls through the world**

Death zeroes collision_layer instead of disabling every CollisionShape3D. A corpse kept applying gravity with no shape, so it fell through the terrain for the whole corpse window. It now keeps its mask, lands where it died, and collides with nothing. enemy_check 44/44.

Commit at time of writing: `51aafe5`

---

### HANDOFF · 2.1d · dusk3 · 2026-08-17T16:35:34+00:00

**Produce the single `NEXT` batch in `docs/ASSET_TRACKER.md`; verify, advance the queue, hand off rather than close**

Only the queue was touched - no assets were produced. Promoted A-021S (iron sword, split out of A-021 at Sequoyah's direct request) to the single NEXT row and returned A-009 to QUEUED. The next asset agent takes 2.1d normally and reads the A-021S row for the full brief. Boundary: that agent owns tools/blender/, assets/tools_weapons/, assets/icons/, docs/ASSET_TRACKER.md and its own new content/items/iron_sword.tres + content/weapons/iron_sword.tres - it must NOT re-run tools/setup_tool_content.gd, which regenerates the nine existing tool items and is owned by the viewmodel work in flight.

Files: `docs/ASSET_TRACKER.md`

Commit at time of writing: `2dfcc4d`

---

### DONE · F-041 · dusk3 · 2026-08-17T16:52:06+00:00

**Held items are invisible in first person, so there is no swing to read**

Viewmodel system: entities/player/viewmodel.gd renders the selected hotbar item under the camera with a procedural swing driven by CombatService.local_phase_progress(). ItemDef gained view_model plus per-item grip offset/rotation/scale so a weapon that sits wrong is an inspector fix, not a code change. All ten A-004 viewmodel exports are wired. Key structural point: the swing lives on the viewmodel node in camera axes and the grip lives on the item child - applying both to one node makes 'swing down' come out as an upward flail. Verified by tools/viewmodel_check.gd against the real main scene, 10 assertions plus a render per swing phase. Also restored the stone_axe icon that regenerating its .tres had dropped.

Files: `systems/inventory/item_def.gd`, `entities/player/viewmodel.gd`, `entities/player/viewmodel.gd.uid`, `entities/player/player_controller.gd`, `autoload/combat_service.gd`, `tools/setup_tool_content.gd`, `tools/setup_crafting_content.gd`, `tools/viewmodel_check.gd`, `tools/viewmodel_check.gd.uid`, `content/items/stone_axe.tres`, `content/items/wooden_axe.tres`, `content/items/wooden_pickaxe.tres`, `content/items/stone_pickaxe.tres`, `content/items/iron_pickaxe.tres`, `content/items/cleaver.tres`, `content/items/skewer.tres`, `content/items/short_bow.tres`, `content/items/arrow.tres`, `content/items/repair_hammer.tres`

Commit at time of writing: `0010110`

---

### HANDOFF · 2.1d · reed16 · 2026-08-17T17:01:21+00:00

**Produce the single `NEXT` batch in `docs/ASSET_TRACKER.md`; verify, advance the queue, hand off rather than close**

A-021S (iron sword) is DONE and shipped; 2.1d stays open with A-009 (extraction ship set, 15 models) promoted to the single NEXT row.

WHAT LANDED. iron_sword_world.glb + iron_sword_viewmodel.glb (421 polys / 1,000 tris, 0.510 x 0.114 x 1.724 m), icon_iron_sword.png, content/items/iron_sword.tres and content/weapons/iron_sword.tres. Diamond-section blade with a fuller, bright ground edges butted onto the core, upswept crossguard with brass quillon caps, brass ecusson, leather grip with cord risers, faceted wheel pommel.

VERIFIED, WITH NUMBERS. Two clean rebuilds: 22/22 GLBs and catalog byte-identical. GLB 2.0 validation 22/22 — catalog exact, no orphans/duplicates/missing, ground origin, horizontally centred, embedded materials, TRIANGLES only, no skins/animations/cameras. Six-azimuth orbit render of the sword plus a blade-section close-up; three previews re-inspected. Fresh Godot 4.7.1 import clean. tools/item_icons_check.gd PASS (25 icons). And in the RUNNING GAME at 1280x720: granted, held in the selected hotbar slot, viewmodel mesh instantiated, swung through idle/wind-up/commit/recovery — 14/14 checks, zero failures.

FOUR TRAPS THIS BATCH PAID FOR.
1. ground_profile() is wrong for a blade. It insets walls toward the profile CENTROID, so on a metre-long blade the pull near the point is almost entirely downward and the section stays a square wall where the edge should be. Added lofted(name, rings, mat, apex) — explicit cross-sections, optional apex fan. Use it for anything much longer than it is wide.
2. Rendered PNGs can never be byte-identical (F-042). Blender stamps RenderTime/Date (EEVEE) and cycles.ViewLayer.total_time (Cycles) into tEXt chunks. Re-running the icon pipeline unchanged marked all 24 existing icons modified in git; decompressing IDAT showed 24/24 pixel-identical, 0 changed. Compare IDAT, never file hashes. Now in the verification contract.
3. Proportions have to be judged by looking. First pass had a 0.10 m half-width blade and read as a gladius; the quillon caps sat at a guard width I had already shrunk and rendered as two brass nubs floating in mid-air. Both were invisible in the grid preview and obvious in the orbit render. Render an orbit before believing a silhouette.
4. Directory claims do not work. 'agent check' reported every file under my claimed assets/tools_weapons and assets/icons as unclaimed until I re-claimed each exact path — F-034 covers this for 'agent ship' and it applies to check too. Claim exact paths for assets.

WHAT IS NOT DONE, AND IS NOT MINE.
- F-043: nothing puts the sword in a player's hand. core/dev/dev_loadout.gd lists the six A-004 tools and not the sword, so only 'give iron_sword' reaches it. One line, but that file is task 2.14's and what a run starts with is 2.9/3.x's design call.
- The WeaponDef numbers (0.19/0.11/0.26 s, 2.9 m, 95 deg, 6 damage) are placeholders I chose to sit between the cleaver and the axe. Task 2.9 owns them; its gate is still unpassed (F-036).
- grip_scale 0.32 / offset (0.27, -0.30, -0.48) was tuned by eye at 1280x720. Stills cannot show whether the blade clips the near plane at the commit, where the swing drives it down past the camera. That needs motion.
- tools/item_icons_check.gd had a hard-coded 24 that my 25th icon turned red. Fixed properly: it now derives the count from the exports directory and asserts catalog<->files agree both ways, so the next batch does not hit it.

FOR A-009. Read assets/tools_weapons/README.md for the lofted() rationale, and A-005's anchor_parts note in the tracker before building the ship's repair stages — a state set that shares a hull needs the shared geometry as its anchor, not each state's own bounds.

Files: `docs/ASSET_TRACKER.md`, `docs/DELEGATION.md`, `tools/blender/build_tool_weapon_set.py`, `tools/blender/render_item_icons.py`, `assets/source/tool_weapon_set.blend`, `assets/tools_weapons`, `assets/icons`, `content/items/iron_sword.tres`, `content/weapons/iron_sword.tres`, `tools/item_icons_check.gd`, `docs/FINDINGS.md`, `assets/tools_weapons/README.md`, `assets/icons/catalog.json`, `assets/icons/preview/item_icons_sheet.png`, `assets/icons/exports/icon_iron_sword.png`, `assets/tools_weapons/catalog.json`, `assets/tools_weapons/preview/tools_weapons_scale_preview.png`, `assets/tools_weapons/preview/tools_weapons_viewmodel_preview.png`, `assets/tools_weapons/preview/tools_weapons_world_preview.png`, `assets/tools_weapons/exports/iron_sword_world.glb`, `assets/tools_weapons/exports/iron_sword_viewmodel.glb`

Commit at time of writing: `423fb8f`
