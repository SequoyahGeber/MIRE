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
