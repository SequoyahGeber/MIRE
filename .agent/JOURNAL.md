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
