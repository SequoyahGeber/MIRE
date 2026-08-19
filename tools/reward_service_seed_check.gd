extends SceneTree

## F-219 proof: `RewardService._grant_tier_to_party()` now derives each peer's roll from
## `(GameState.run_seed, tier, a monotonic per-run reward-event id, peer_id)` instead of boot-time
## `randomize()` — see `autoload/reward_service.gd`'s `_seed_for_run()`/`_run_seed()`/
## `_next_reward_event_id`, reset on `GameState.seed_ready`. Same shape `tools/chest_seed_check.gd`
## proves for `Chest`, adapted for a trigger with no placement id of its own: a Wellspring cap has a
## monotonic per-run counter standing in for `Chest`'s stable node name instead.
##
## Against the REAL `content/loot/wellspring.tres` (18 entries, coin range 40-80, 3 rolls per
## trigger) — same "prove the real content, not a synthetic table" choice
## `tools/reward_service_check.gd` already made, wide enough that a coincidental match between two
## DIFFERENT trigger positions is not a realistic false pass (same confidence `chest_seed_check.gd`
## states for its own 1..999 range).
##
##   1. Same run_seed, same reward-event position (a `GameState.seed_ready` reset between them,
##      exactly a same-seed replay looks like) -> identical roll.
##   2. Same run_seed, a SECOND trigger with no reset in between -> the per-run counter must keep it
##      from repeating the first roll.
##   3. A different run_seed at the same reward-event position -> different roll.
##
##   .agent/bin/agent godot --script tools/reward_service_seed_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("\n== F-219 RewardService seed determinism check ==")
	var game_state: Node = root.get_node_or_null(^"GameState")
	var reward_service: Node = root.get_node_or_null(^"RewardService")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var powerups: Node = root.get_node_or_null(^"PowerupService")
	check(game_state != null, "GameState autoload exists")
	check(reward_service != null, "RewardService autoload exists")
	check(inventory != null, "InventoryService autoload exists")
	check(powerups != null, "PowerupService autoload exists")
	if game_state == null or reward_service == null or inventory == null or powerups == null:
		finish()
		return

	var player := Node3D.new()
	player.name = "RewardSeedCheckPlayer"
	player.add_to_group(&"players")
	player.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	root.add_child(player)
	await process_frame

	# ── Case 1: same run_seed, replayed reward-event position (seed_ready resets the counter,
	# same shape a same-seed replay takes) -> identical roll. ──────────────────────────────────
	game_state.call("set_replicated_seed", 20260819)
	var roll_a: Dictionary = await _capped_roll(inventory, powerups)
	game_state.call("set_replicated_seed", 20260819)
	var roll_b: Dictionary = await _capped_roll(inventory, powerups)
	check(not (roll_a["coins"] == 0 and roll_a["powerups"].is_empty()) and roll_a == roll_b,
		"same run_seed + replayed trigger position rolls identically (%s vs %s)" % [roll_a, roll_b])

	# ── Case 2: same run_seed, a SECOND trigger with no reset in between -> the per-run event
	# counter must keep it from repeating the first roll. ──────────────────────────────────────
	var roll_c: Dictionary = await _capped_roll(inventory, powerups)
	check(roll_b != roll_c,
		"a second trigger in the same run does not repeat the first roll (%s vs %s)" % [roll_b, roll_c])

	# ── Case 3: different run_seed, same trigger position (fresh reset) -> different roll. ─────
	game_state.call("set_replicated_seed", 424242)
	var roll_d: Dictionary = await _capped_roll(inventory, powerups)
	check(roll_a != roll_d,
		"different run_seed, same trigger position rolls differently (%s vs %s)" % [roll_a, roll_d])

	player.queue_free()
	await process_frame

	print("REWARD_SERVICE_SEED_CHECK failures=%d" % failures)
	finish()


## Fires a real Wellspring cap and returns what it granted the check player, as a
## `{coins: delta, powerups: {id: delta}}` fingerprint — comparable across calls because it is a
## DELTA from the snapshot taken immediately before, not an absolute total, so accumulation across
## calls in the same run never pollutes the comparison.
func _capped_roll(inventory: Node, powerups: Node) -> Dictionary:
	var before: Dictionary = _snapshot(inventory, powerups)
	EVENT_BUS.emit_wellspring_capped(&"reward_seed_check", Vector3.ZERO)
	await process_frame
	return _diff(before, _snapshot(inventory, powerups))


func _snapshot(inventory: Node, powerups: Node) -> Dictionary:
	return {
		"coins": int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"coins")),
		"powerups": (powerups.call("stacks_for", NetConfig.HOST_PEER_ID) as Dictionary).duplicate(),
	}


func _diff(before: Dictionary, after: Dictionary) -> Dictionary:
	var powerup_delta: Dictionary = {}
	var after_powerups: Dictionary = after["powerups"]
	var before_powerups: Dictionary = before["powerups"]
	for powerup_id: Variant in after_powerups:
		var delta: int = int(after_powerups[powerup_id]) - int(before_powerups.get(powerup_id, 0))
		if delta != 0:
			powerup_delta[powerup_id] = delta
	return {"coins": int(after["coins"]) - int(before["coins"]), "powerups": powerup_delta}


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
