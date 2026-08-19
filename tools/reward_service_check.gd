extends SceneTree

## F-183: nothing ever rolled the `wellspring`/`boss` loot tiers `docs/ITEMS.md` §5 authors —
## `Wellspring._finish_cap()` only ever flipped `capped`, `Boss._play_state_animation()` only ever
## flipped `state`. Proves `autoload/reward_service.gd`, the missing caller, against the REAL
## `content/loot/wellspring.tres`/`boss.tres` content — no synthetic table needed, the same choice
## `tools/chest_placement_check.gd` made for the real Hollowmere chest tiers.
##
##   1. Wiring — RewardService is registered and actually subscribed to both EventBus hooks.
##   2. A REAL Wellspring's `capped` transitioning to true (a bare property write, the exact shape a
##      client's MultiplayerSynchronizer delta takes — same F-168 shape `wellspring_check.gd` already
##      proved fires the event) grants the present player wellspring.tres's own coin range plus at
##      least one of its (all-POWERUP) rolls, landed for real in InventoryService/PowerupService.
##   3. `EventBus.emit_boss_defeated()` does the identical thing against boss.tres, a mixed
##      item/powerup table — asserted as "coins in range, plus at least one of iron_ingot/iron_ore/
##      any powerup stack increased" rather than "a powerup landed", since boss.tres's 3 independent
##      draws are not guaranteed to include a powerup entry (a synthetic table could force it, but
##      this file deliberately proves the REAL content instead — see the class doc above).
##   4. `_present_peers()` (the "whole party" fan-out) returns every distinct multiplayer authority
##      in the `players` group, not just the first one. A live multi-peer INVENTORY grant needs a
##      real connected transport (`chest_net_check.gd`'s own two-process pattern) — already-proven
##      plumbing this file does not re-test; this section proves the peer SET is computed correctly.
##
##   .agent/bin/agent godot --script tools/reward_service_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const WELLSPRING_SCRIPT := preload("res://systems/wellspring/wellspring.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var reward_service: Node = root.get_node_or_null(^"RewardService")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var powerups: Node = root.get_node_or_null(^"PowerupService")
	check(reward_service != null, "RewardService is registered as an autoload")
	check(inventory != null, "InventoryService autoload exists")
	check(powerups != null, "PowerupService autoload exists")
	if reward_service == null or inventory == null or powerups == null:
		finish()
		return

	check(EVENT_BUS.wellspring_capped_subscriber_count() >= 1,
		"RewardService is subscribed to wellspring_capped")
	check(EVENT_BUS.boss_defeated_subscriber_count() >= 1,
		"RewardService is subscribed to boss_defeated")

	await _check_present_peers(reward_service)
	await _check_wellspring_paycheck(inventory, powerups)
	await _check_boss_paycheck(inventory, powerups)

	print("\nREWARD_SERVICE_CHECK failures=%d" % failures)
	finish()


func _check_present_peers(reward_service: Node) -> void:
	print("\n== _present_peers(): every distinct multiplayer authority in the players group ==")
	var player_one := Node3D.new()
	player_one.name = "CheckRewardPlayerOne"
	player_one.add_to_group(&"players")
	player_one.set_multiplayer_authority(1)
	root.add_child(player_one)

	var player_two := Node3D.new()
	player_two.name = "CheckRewardPlayerTwo"
	player_two.add_to_group(&"players")
	player_two.set_multiplayer_authority(2)
	root.add_child(player_two)

	# A second body under the SAME authority (a co-owned puppet, or just a test artifact) must not
	# double-count — the party is distinct AUTHORITIES, not distinct nodes.
	var duplicate := Node3D.new()
	duplicate.name = "CheckRewardPlayerOneDuplicateBody"
	duplicate.add_to_group(&"players")
	duplicate.set_multiplayer_authority(1)
	root.add_child(duplicate)

	var peers: PackedInt32Array = reward_service.call("_present_peers")
	check(peers.size() == 2, "two distinct authorities among three player-group nodes (got %s)" % [peers])
	check(peers.has(1) and peers.has(2), "both distinct peer ids are present (got %s)" % [peers])

	player_one.queue_free()
	player_two.queue_free()
	duplicate.queue_free()
	await process_frame


func _check_wellspring_paycheck(inventory: Node, powerups: Node) -> void:
	print("\n== a capped Wellspring grants the present player wellspring.tres's own paycheck ==")
	var player := Node3D.new()
	player.name = "CheckRewardWellspringPlayer"
	player.add_to_group(&"players")
	player.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	root.add_child(player)

	var coins_before: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"coins"))
	var stacks_before: int = _total_powerup_stacks(powerups, NetConfig.HOST_PEER_ID)

	var wellspring := WELLSPRING_SCRIPT.new() as Node3D
	wellspring.name = "CheckRewardWellspring"
	root.add_child(wellspring)
	await process_frame
	wellspring.set("capped", true)

	var coins_granted: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"coins")) - coins_before
	var stacks_after: int = _total_powerup_stacks(powerups, NetConfig.HOST_PEER_ID)

	check(coins_granted >= 40 and coins_granted <= 80,
		"wellspring.tres's own coin_min/coin_max range (40-80) landed in InventoryService (+%d)" % coins_granted)
	check(stacks_after > stacks_before,
		"wellspring.tres is all-POWERUP entries, so at least one of its 3 rolls landed a stack (%d -> %d)"
			% [stacks_before, stacks_after])

	wellspring.queue_free()
	player.queue_free()
	await process_frame


func _check_boss_paycheck(inventory: Node, powerups: Node) -> void:
	print("\n== EventBus.emit_boss_defeated grants the present player boss.tres's own paycheck ==")
	var player := Node3D.new()
	player.name = "CheckRewardBossPlayer"
	player.add_to_group(&"players")
	player.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	root.add_child(player)

	var coins_before: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"coins"))
	var iron_ingot_before: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"iron_ingot"))
	var iron_ore_before: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"iron_ore"))
	var stacks_before: int = _total_powerup_stacks(powerups, NetConfig.HOST_PEER_ID)

	EVENT_BUS.emit_boss_defeated(&"check_guardian", Vector3(10.0, 0.0, 10.0))

	var coins_granted: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"coins")) - coins_before
	var iron_ingot_granted: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"iron_ingot")) - iron_ingot_before
	var iron_ore_granted: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"iron_ore")) - iron_ore_before
	var stacks_after: int = _total_powerup_stacks(powerups, NetConfig.HOST_PEER_ID)

	check(coins_granted >= 100 and coins_granted <= 220,
		"boss.tres's own coin_min/coin_max range (100-220) landed in InventoryService (+%d)" % coins_granted)
	check(iron_ingot_granted > 0 or iron_ore_granted > 0 or stacks_after > stacks_before,
		"boss.tres's 3 rolls landed at least one item or powerup (iron_ingot +%d, iron_ore +%d, powerup stacks %d -> %d)"
			% [iron_ingot_granted, iron_ore_granted, stacks_before, stacks_after])

	player.queue_free()
	await process_frame


func _total_powerup_stacks(powerups: Node, peer_id: int) -> int:
	var held: Dictionary = powerups.call("stacks_for", peer_id)
	var total: int = 0
	for count: int in held.values():
		total += count
	return total


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
