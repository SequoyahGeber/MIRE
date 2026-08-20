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

## THE CONTRACT (F-273, and state it here because two subscribers spent a week describing the
## pre-F-258 one). `seed_ready` is a **RUN boundary, on every peer** — not a session boundary, not
## host-only, and not once per anything:
##
## - It fires on the host from [method host_generate_seed] (session start, `NetTransport.
##   server_started`, and `MireGrid`'s lazy [method ensure_seed] at boot) and from
##   [method host_redraw_seed] (`CycleService.host_restart_run()`, F-258/D-161).
## - It fires on a client from [method set_replicated_seed] — `WorldDeltaLog.net_world_snapshot()`
##   for a peer joining mid-run, and `_on_world_delta_applied()` for a reseed reaching a peer
##   already here.
## - **It can fire more than once for one boundary.** A single `host_restart_run()` emits TWICE on
##   the host with the same value: once for the redraw, once for `WorldDeltaLog.host_reseed()`'s own
##   `_reseed_local()` → [method set_replicated_seed]. So a handler must be IDEMPOTENT — "reset this
##   run's tally", never "increment", "toggle" or "advance a phase". Both shipped service
##   subscribers (`autoload/salvage_service.gd`, `autoload/reward_service.gd`) are zeroing resets for
##   exactly this reason, and `ui/menu/main_menu.gd` re-derives a label.
## - [method reset] (session end, `NetTransport.disconnected`) does **not** fire it. Session end and
##   run boundary are different events, and only the second one is on this signal.
##
## Anything that must re-derive its WORLD from the new seed hangs off `EventBus.run_restarted`
## instead, which arrives immediately after this on the same reliable channel — see
## `autoload/world_delta_log.gd`'s `_reseed_local()`. `tools/seed_ready_contract_check.gd` holds
## every sentence above to the code, including an exact census of the subscribers listed here.
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


## Host-only. Called on `NetTransport.server_started`, lazily by [method ensure_seed] for
## offline/host-of-one play (which never fires that signal at all), and — F-273, because this
## comment used to say "once per hosted session" and F-258/D-161 made that false — once more per
## RESTART, since [method host_redraw_seed] delegates the draw straight to this function rather
## than duplicating it. Emits `seed_ready` on every one of those, per that signal's contract above.
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
## hosted session draws a fresh one rather than reusing the last run's island. Deliberately silent —
## this is a session END, not a run boundary, so it does not emit `seed_ready`; a subscriber that
## needs to know a session is over listens to `NetSession.session_ended`, not to this.
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
