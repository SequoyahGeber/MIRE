extends Node

## Run seed authority — docs/ARCHITECTURE.md §4: "The host picks a seed; the seed is replicated to
## clients." `ARCHITECTURE.md` §3 already reserves this file's path for "act, day, seed, run status
## (host-authoritative)"; task 6.1 (Cycle state machine) is where the rest of that slot gets built.
## This task (4.6) only needs the seed half, so it claims the reserved name/location now rather than
## inventing a second `core/net/run_seed.gd` that 6.1 would later have to merge with this one.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): HOST picks `run_seed` from real entropy — the same
## reasoning D-041 gives for `Chest.host_seed_rng()`: nothing today needs this run to be reproducible
## across restarts, only that every peer IN the run agrees, which replication (not a fixed constant)
## already provides. `autoload/world_delta_log.gd` is what actually gets the value to a client — this
## file only holds it and decides when a fresh one is drawn.
##
## F-258/D-161 lifted the "once" that used to be in that sentence: a seed is drawn once per RUN, not
## once per process. [method host_redraw_seed] draws the next run's, and `WorldDeltaLog.host_reseed()`
## carries it to every already-connected peer over the delta channel that was already there.
##
## Task 6.10 adds a UI-facing override: [method set_pending_seed] stages a specific value so a typed
## seed beats real entropy on the very next draw, without touching HOW a seed reaches a client (still
## entirely `WorldDeltaLog`'s job) or its authority (still host-only — a client staging a value only
## ever affects seeds that peer itself later hosts).

signal seed_ready(value: int)

var run_seed: int = 0
var _seed_ready: bool = false

## Task 6.10's seed-entry field stages a value here before hosting starts; whichever of
## [method host_generate_seed]/[method ensure_seed] draws next consumes it once, then clears it, so
## a later reconnect without a fresh entry falls back to real entropy same as always. 0 means
## "no override" — `ui/menu/main_menu.gd` never stages a real 0, mapping the one-in-four-billion
## String.hash() collision away from it too.
var _pending_seed: int = 0
var _has_pending_seed: bool = false


## UI-facing. `value == 0` clears a previously staged override.
func set_pending_seed(value: int) -> void:
	_pending_seed = value
	_has_pending_seed = value != 0


func has_pending_seed() -> bool:
	return _has_pending_seed


func pending_seed() -> int:
	return _pending_seed


## Host-only. Called once per hosted session (`NetTransport.server_started`) and lazily by
## [method ensure_seed] for offline/host-of-one play, which never fires that signal at all.
func host_generate_seed() -> int:
	if _has_pending_seed:
		run_seed = _pending_seed
		_has_pending_seed = false
	else:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		run_seed = rng.randi()
	_seed_ready = true
	seed_ready.emit(run_seed)
	return run_seed


## F-258. Host-only, MID-RUN: draws a brand-new seed for the next run, so a restart lands on a fresh
## island/POI layout/loot stream instead of replaying the one that just ended. Delegates rather than
## duplicating [method host_generate_seed] — the draw is the same draw — but exists under its own
## name because the two callers mean genuinely different things: `host_generate_seed()` is "this
## session has no seed yet" (`NetTransport.server_started`, `ensure_seed()`'s lazy boot path), and
## this is "the session has one, replace it while everyone is connected". Whoever calls this owns
## getting the new value to the other peers; `autoload/world_delta_log.gd`'s `host_reseed()` is the
## only caller that does, and `CycleService.host_restart_run()` goes through it.
##
## A staged `--seed=`/menu override is NOT re-consumed here: `host_generate_seed()` clears
## `_has_pending_seed` on the first draw, so a deliberate seed repro governs the run it was typed
## for and a restart moves on to real entropy — the same "a seed does not outlive its run" stance
## [method reset] already takes for a session.
func host_redraw_seed() -> int:
	return host_generate_seed()


## Client-side: adopt the value the host sent. Also safe to call host-side with its own value —
## idempotent, so callers never need to branch on who they are.
func set_replicated_seed(value: int) -> void:
	run_seed = value
	_seed_ready = true
	seed_ready.emit(run_seed)


func is_seed_ready() -> bool:
	return _seed_ready


## Anything that wants a seed right now — a headless harness, offline play that never opens a
## session — and does not want to reason about whether one has been drawn yet.
func ensure_seed() -> int:
	if not _seed_ready:
		host_generate_seed()
	return run_seed


## Mirrors `RunIdentity.clear()`'s reasoning: a run's seed does not outlive its session. The next
## hosted session draws a fresh one rather than reusing the last run's island.
func reset() -> void:
	run_seed = 0
	_seed_ready = false


func _ready() -> void:
	_apply_launch_seed_arg()
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null:
		return
	transport.get("server_started").connect(_on_hosting)
	transport.get("disconnected").connect(_on_disconnected)
	if bool(transport.call("is_active")) and bool(transport.call("is_host")):
		_on_hosting.call_deferred()


func _on_hosting() -> void:
	host_generate_seed()


func _on_disconnected() -> void:
	reset()


## F-172: solo/offline play draws its seed in `MireGrid._ready()` before any menu can open to stage
## one via [method set_pending_seed] — task 6.10's UI path only ever reaches a hosted session
## (D-110). `GameState` is last-but-one in `[autoload]` order, immediately before `MireGrid`, so a
## `--seed=<value>` launch argument staged here is guaranteed in place before anything downstream
## can draw. Parsing mirrors `ui/menu/main_menu.gd`'s own `request_set_seed()`: a pure integer is
## used as-is, any other text is hashed with `String.hash()` (same fixed algorithm on every
## platform) so a shared word-seed behaves identically whether typed in the menu or passed on the
## command line, and a value that lands on exactly 0 is bumped to 1 — 0 means "no override" in
## `set_pending_seed`'s own contract. Same two-step args lookup `core/dev/dev_launch.gd` already
## uses, but — unlike that file — not debug-only: seed entry is a real player-facing feature
## (`MainMenu`'s own field), and `autoload/steam_lobby.gd`'s `STEAM_CONNECT_LOBBY_ARG` already
## establishes that a retail-build cmdline arg reaching an autoload is a normal shape here, the same
## way a Steam "Launch Options" field already reaches any other Steam title.
func _apply_launch_seed_arg() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()
	for arg: String in args:
		if not arg.begins_with("--seed="):
			continue
		var text: String = arg.trim_prefix("--seed=").strip_edges()
		if text.is_empty():
			return
		var value: int = int(text.to_int()) if text.is_valid_int() else text.hash()
		if value == 0:
			value = 1
		set_pending_seed(value)
		return
