extends SceneTree

## F-273 — THE `GameState.seed_ready` CONTRACT CHECK. F-258/D-161 turned this signal from a
## session boundary into a RUN boundary, and nothing anywhere states what it now promises: the two
## subscribers that existed carried doc comments describing the old once-per-session shape, and the
## signal declaration itself said nothing at all. F-273 fixed the prose; this file is the executable
## half, so the next subscriber's author cannot regress the contract by accident.
##
## The contract, exactly as `core/game_state.gd`'s `seed_ready` declaration now states it:
##
##   1. It fires on every peer, host and client alike, at every RUN boundary — not once per session
##      and not only on the host.
##   2. It fires at least once per boundary and **may fire more than once**: on the host a single
##      `CycleService.host_restart_run()` emits twice with the same value, because it calls
##      `GameState.host_redraw_seed()` and then `WorldDeltaLog.host_reseed()`, whose `_reseed_local()`
##      calls `set_replicated_seed()` on the sending side too. A handler must therefore be
##      IDEMPOTENT — "reset this run's tally", never "increment" or "toggle".
##   3. `GameState.reset()` (session end, `NetTransport.disconnected`) does NOT fire it. Session end
##      and run boundary are different events and only one of them is on this signal.
##
## Phases:
##   1. Subscriber census — the shipped subscribers are exactly SalvageService, RewardService and
##      MainMenu. A fourth trips this check on purpose: whoever adds it should have read the
##      contract line first, and this is the only place that can make them.
##   2. Every emitter fires it, carrying the new value — `ensure_seed()`, `host_generate_seed()`,
##      `host_redraw_seed()`, `set_replicated_seed()`.
##   3. The run boundary itself, driven through the REAL producers in the REAL order
##      `host_restart_run()` uses (`host_redraw_seed()` then `WorldDeltaLog.host_reseed()`), with
##      both subscribers' per-run state accumulated first by firing the REAL `wellspring_capped`
##      producer rather than poking either `_on_seed_ready()` by hand — F-310's rule, and the whole
##      point here is the fan-out across three independent subscribers. Asserts the double emit of
##      point 2 above, and that all three subscribers re-derived.
##   4. A client adopting the host's reseed (`set_replicated_seed()`, what `net_world_snapshot` and
##      `_on_world_delta_applied()` both call) is a run boundary too, and resets the same state.
##   5. Idempotence — the same value adopted twice still resets, so a repeated delta cannot leave a
##      subscriber holding the ended run's tally.
##   6. `reset()` is silent, and `is_seed_ready()` goes false.
##
## Solo/offline, one process. The full restart with a real defeat, a real island rebuild and the
## delta-log wipe is `tools/run_reseed_check.gd`'s job and is not duplicated here; this file is about
## what the SIGNAL promises its subscribers, which is a different contract from what a reseed does to
## the world.
##
##   .agent/bin/agent godot --script tools/seed_ready_contract_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")

## D-107: never let a check write a developer's real `user://salvage.json`.
const TEST_SAVE_PATH: String = "user://seed_ready_contract_check_salvage.json"

const BOOT_SEED: int = 20260820
const RESTART_SEED: int = 8675309
const ADOPT_SEED: int = 424242

## The shipped `seed_ready` subscribers, as owner node names, sorted. Deliberately an exact set and
## not a "contains" test — see phase 1.
const EXPECTED_SUBSCRIBERS: Array[String] = ["MainMenu", "RewardService", "SalvageService"]

var failures: int = 0
var emissions: Array[int] = []
var _player: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var game_state: Node = root.get_node_or_null(^"GameState")
	var salvage: Node = root.get_node_or_null(^"SalvageService")
	var reward: Node = root.get_node_or_null(^"RewardService")
	var main_menu: Node = root.get_node_or_null(^"MainMenu")
	var world_delta_log: Node = root.get_node_or_null(^"WorldDeltaLog")
	check(game_state != null, "GameState autoload exists")
	check(salvage != null, "SalvageService autoload exists")
	check(reward != null, "RewardService autoload exists")
	check(main_menu != null, "MainMenu autoload exists")
	check(world_delta_log != null, "WorldDeltaLog autoload exists")
	if game_state == null or salvage == null or reward == null or main_menu == null \
			or world_delta_log == null:
		_finish()
		return

	salvage.set(&"save_path", TEST_SAVE_PATH)

	# A present player, so `RewardService._grant_tier_to_party()` gets past its `_present_peers()`
	# early return and actually advances the per-run counter this check is watching. Same setup
	# `tools/reward_service_seed_check.gd` uses for the same reason.
	_player = Node3D.new()
	_player.name = "SeedReadyContractCheckPlayer"
	_player.add_to_group(&"players")
	_player.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	root.add_child(_player)
	await process_frame

	_phase_census(game_state)
	_phase_emitters(game_state)
	await _phase_run_boundary(game_state, salvage, reward, main_menu, world_delta_log)
	await _phase_client_adoption(game_state, salvage, reward)
	await _phase_idempotent(game_state, salvage, reward)
	_phase_reset_is_silent(game_state)

	_player.queue_free()
	await process_frame
	_finish()


# ── 1 · who is listening ─────────────────────────────────────────────────────────────────────────


func _phase_census(game_state: Node) -> void:
	print("\n== SEED_READY 1 · the shipped subscriber census ==")
	var names: Array[String] = []
	for connection: Dictionary in game_state.get_signal_connection_list(&"seed_ready"):
		var callable: Callable = connection.get("callable", Callable())
		var owner: Object = callable.get_object()
		if owner == null:
			continue
		if owner == self:
			continue  # this check's own probe connection, when one is live
		names.append(String((owner as Node).name) if owner is Node else owner.get_class())
	names.sort()
	check(names == EXPECTED_SUBSCRIBERS,
		("the shipped `seed_ready` subscribers are exactly %s — if this failed, a subscriber was "
			+ "added or removed: read `core/game_state.gd`'s contract on the signal declaration, "
			+ "confirm the new handler is idempotent and run-scoped, then update EXPECTED_SUBSCRIBERS "
			+ "(got %s)") % [EXPECTED_SUBSCRIBERS, names])


# ── 2 · every emitter fires it ───────────────────────────────────────────────────────────────────


func _phase_emitters(game_state: Node) -> void:
	print("\n== SEED_READY 2 · every emitter fires the signal, carrying the new value ==")
	game_state.connect(&"seed_ready", _on_seed_ready)

	# `ensure_seed()` — the lazy boot draw (`MireGrid.ensure_ready()`). By the time this check runs
	# a seed already exists, so this asserts the OTHER half of its contract: idempotent, silent.
	emissions.clear()
	var boot: int = int(game_state.call("ensure_seed"))
	check(boot != 0, "a seed already exists at boot (%d)" % boot)
	check(emissions.is_empty(),
		"ensure_seed() on an already-seeded process is silent — it is not a boundary (got %s)"
			% [emissions])

	# `set_replicated_seed()` — the client adoption path, also used host-side by `_reseed_local()`.
	emissions.clear()
	game_state.call("set_replicated_seed", BOOT_SEED)
	check(_emitted([BOOT_SEED]),
		"set_replicated_seed() fires once, carrying the adopted value (got %s)" % [emissions])
	check(int(game_state.get(&"run_seed")) == BOOT_SEED, "GameState.run_seed holds the adopted value")

	# `host_generate_seed()` — the session-start draw (`NetTransport.server_started`).
	emissions.clear()
	var generated: int = int(game_state.call("host_generate_seed"))
	check(_emitted([generated]),
		"host_generate_seed() fires once, carrying the drawn value (got %s)" % [emissions])

	# `host_redraw_seed()` — the run-boundary draw (`CycleService.host_restart_run()`).
	emissions.clear()
	var redrawn: int = int(game_state.call("host_redraw_seed"))
	check(redrawn != generated,
		"host_redraw_seed() draws a DIFFERENT value (%d -> %d)" % [generated, redrawn])
	check(_emitted([redrawn]),
		"host_redraw_seed() fires once, carrying the new value (got %s)" % [emissions])

	game_state.disconnect(&"seed_ready", _on_seed_ready)


# ── 3 · the run boundary, driven through the real producers ─────────────────────────────────────


func _phase_run_boundary(
	game_state: Node, salvage: Node, reward: Node, main_menu: Node, world_delta_log: Node
) -> void:
	print("\n== SEED_READY 3 · a run boundary resets all three subscribers ==")
	game_state.call("set_replicated_seed", BOOT_SEED)
	await _accumulate_run_state()

	var capped: int = int(salvage.get(&"_wellsprings_capped_this_run"))
	var event_id: int = int(reward.get(&"_next_reward_event_id"))
	check(capped == 2,
		"SalvageService counted both Wellspring caps this run (got %d)" % capped)
	check(event_id > 1,
		"RewardService's per-run reward-event counter advanced past 1 (got %d)" % event_id)
	check(main_menu.call("status_text") == "This run's seed: %d" % BOOT_SEED,
		"MainMenu is showing the run's seed before the boundary (got '%s')"
			% main_menu.call("status_text"))

	# The real producers, in the real order `CycleService.host_restart_run()` calls them.
	game_state.connect(&"seed_ready", _on_seed_ready)
	emissions.clear()
	game_state.call("set_pending_seed", RESTART_SEED)
	var new_seed: int = int(game_state.call("host_redraw_seed"))
	world_delta_log.call("host_reseed", new_seed)
	game_state.disconnect(&"seed_ready", _on_seed_ready)
	await process_frame

	check(new_seed == RESTART_SEED,
		"the boundary landed on the staged seed, so the assertions below name a known value (%d)"
			% new_seed)
	check(_emitted([RESTART_SEED, RESTART_SEED]),
		("one run boundary fires seed_ready TWICE on the host with the same value — "
			+ "host_redraw_seed() then WorldDeltaLog.host_reseed()'s own set_replicated_seed(). "
			+ "A handler must be idempotent (got %s)") % [emissions])
	check(int(salvage.get(&"_wellsprings_capped_this_run")) == 0,
		"SalvageService's per-run Wellspring tally reset at the boundary (got %d)"
			% int(salvage.get(&"_wellsprings_capped_this_run")))
	check(int(reward.get(&"_next_reward_event_id")) == 1,
		"RewardService's per-run reward-event counter reset to 1 (got %d)"
			% int(reward.get(&"_next_reward_event_id")))
	check(main_menu.call("status_text") == "This run's seed: %d" % RESTART_SEED,
		"MainMenu re-derived its status label off the new seed (got '%s')"
			% main_menu.call("status_text"))


# ── 4 · the client half — adopting the host's reseed ────────────────────────────────────────────


func _phase_client_adoption(game_state: Node, salvage: Node, reward: Node) -> void:
	print("\n== SEED_READY 4 · a client adopting the host's seed is a run boundary too ==")
	await _accumulate_run_state()
	check(int(salvage.get(&"_wellsprings_capped_this_run")) == 2,
		"the tally accumulated again before the client-side boundary")

	# Byte-for-byte what `WorldDeltaLog._on_world_delta_applied()` / `net_world_snapshot()` call on
	# a receiving peer.
	game_state.call("set_replicated_seed", ADOPT_SEED)
	await process_frame

	check(int(game_state.get(&"run_seed")) == ADOPT_SEED, "the adopted seed landed")
	check(int(salvage.get(&"_wellsprings_capped_this_run")) == 0,
		"SalvageService reset on the adopted seed, not only on the host's own draw (got %d)"
			% int(salvage.get(&"_wellsprings_capped_this_run")))
	check(int(reward.get(&"_next_reward_event_id")) == 1,
		"RewardService reset on the adopted seed (got %d)"
			% int(reward.get(&"_next_reward_event_id")))


# ── 5 · idempotence — the same value twice ──────────────────────────────────────────────────────


func _phase_idempotent(game_state: Node, salvage: Node, reward: Node) -> void:
	print("\n== SEED_READY 5 · re-adopting the SAME value is still a reset, not a no-op ==")
	await _accumulate_run_state()
	game_state.connect(&"seed_ready", _on_seed_ready)
	emissions.clear()
	game_state.call("set_replicated_seed", ADOPT_SEED)
	game_state.disconnect(&"seed_ready", _on_seed_ready)
	await process_frame

	check(_emitted([ADOPT_SEED]),
		"set_replicated_seed() fires even when the value has not changed (got %s)" % [emissions])
	check(int(salvage.get(&"_wellsprings_capped_this_run")) == 0
			and int(reward.get(&"_next_reward_event_id")) == 1,
		"both subscribers reset again — the handlers are idempotent, so a repeated delta cannot "
			+ "leave one holding the ended run's tally")


# ── 6 · a session end is not a run boundary ─────────────────────────────────────────────────────


func _phase_reset_is_silent(game_state: Node) -> void:
	print("\n== SEED_READY 6 · GameState.reset() is a session end and does NOT fire ==")
	game_state.connect(&"seed_ready", _on_seed_ready)
	emissions.clear()
	game_state.call("reset")
	game_state.disconnect(&"seed_ready", _on_seed_ready)

	check(emissions.is_empty(),
		"reset() (NetTransport.disconnected) does not fire seed_ready (got %s)" % [emissions])
	check(not bool(game_state.call("is_seed_ready")), "reset() clears is_seed_ready()")
	check(int(game_state.get(&"run_seed")) == 0, "reset() clears run_seed")


# ── helpers ──────────────────────────────────────────────────────────────────────────────────────


## Puts real per-run state into BOTH subscribers by firing the real `wellspring_capped` producer
## twice — never by calling either service's `_on_wellspring_capped()` directly (F-310: a check that
## pokes one subscriber's handler proves nothing about a fan-out, which is the only thing this file
## is here to prove).
func _accumulate_run_state() -> void:
	EVENT_BUS.emit_wellspring_capped(&"SeedReadyContractCheckSpring", Vector3.ZERO)
	await process_frame
	EVENT_BUS.emit_wellspring_capped(&"SeedReadyContractCheckSpring2", Vector3(10.0, 0.0, 10.0))
	await process_frame


## `emissions == [x] as Array[int]` does not parse — `as` binds looser than `==`, so the comparison
## is attempted first and the cast lands on the resulting bool (Godot 4.7). One helper beats
## parenthesising every call site.
func _emitted(expected: Array) -> bool:
	if emissions.size() != expected.size():
		return false
	for i: int in range(expected.size()):
		if emissions[i] != int(expected[i]):
			return false
	return true


func _on_seed_ready(value: int) -> void:
	emissions.append(value)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	print("\nSEED_READY_CONTRACT_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
