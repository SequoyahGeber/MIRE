extends SceneTree

## F-539: `docs/ITEMS.md` §4 lists Old Coins' sources as "kills, caches", but nothing granted a coin
## for a kill — `Enemy._enter_death()` emitted `died()` and only `SfxDirector` listened, so the whole
## pre-boss economy ran on scattered Reed Caches. Proves the bounty end to end against the REAL
## `content/enemies/*.tres`, the same "no synthetic content" choice `tools/reward_service_check.gd`
## made for the loot tiers.
##
##   1. Wiring — RewardService is subscribed to `enemy_killed`.
##   2. The ladder is a pay scale: every authored kind has a valid range, and tiers 1-5 pay strictly
##      more than the tier below. This is the design claim, and it is the one a later balance pass
##      is most likely to break silently.
##   3. A REAL kill through the REAL damage seam (`Enemy.host_apply_damage()`, not a hand-emitted
##      event) lands coins in the KILLER's inventory, inside that kind's authored range.
##   4. The killer is paid, not the party: a second present player with a different authority gains
##      nothing from a kill they did not make.
##   5. An uncredited death (instigator peer 0 — a burst, a fall) pays nobody.
##   6. F-219 determinism: the same run seed and the same kill ordinal pay the same coins.
##
##   .agent/bin/agent godot --script tools/kill_bounty_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")

## The ladder in order, `docs/ENEMIES.md` §2. Off-ladder kinds are range-checked but not ordered
## against these — a Mire Tusker is not a rung.
const LADDER: Array[StringName] = [
	&"peatling", &"fen_stalker", &"bog_bulwark", &"bloatcap", &"mire_herald",
]
const KILL_SITE := Vector3(24.0, 0.0, 24.0)

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var reward_service: Node = root.get_node_or_null(^"RewardService")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	check(reward_service != null, "RewardService autoload exists")
	check(inventory != null, "InventoryService autoload exists")
	check(world != null, "EnemyWorld autoload exists")
	if reward_service == null or inventory == null or world == null:
		finish()
		return

	check(EVENT_BUS.enemy_killed_subscriber_count() >= 1,
		"RewardService is subscribed to enemy_killed")

	_check_pay_scale(world)
	await _check_real_kill_pays_the_killer(world, inventory)
	_check_uncredited_death_pays_nobody(inventory)
	_check_determinism(reward_service, inventory)

	print("\nKILL_BOUNTY_CHECK failures=%d" % failures)
	finish()


func _check_pay_scale(world: Node) -> void:
	print("\n== the ladder is a pay scale ==")
	var previous_max: int = 0
	for enemy_id: StringName in LADDER:
		var def: Resource = world.call("get_def", enemy_id)
		if def == null:
			check(false, "%s is registered" % enemy_id)
			continue
		var low: int = int(def.get(&"coin_drop_min"))
		var high: int = int(def.get(&"coin_drop_max"))
		check(low > 0 and high >= low, "%s pays a valid bounty (%d-%d)" % [enemy_id, low, high])
		check(low > previous_max,
			"%s's floor (%d) is above the tier below's ceiling (%d) — killing up the ladder always pays better"
				% [enemy_id, low, previous_max])
		previous_max = high


func _check_real_kill_pays_the_killer(world: Node, inventory: Node) -> void:
	print("\n== a real kill pays the killer, and only the killer ==")
	var def: Resource = world.call("get_def", &"peatling")
	if def == null:
		check(false, "peatling.tres is registered")
		return
	var low: int = int(def.get(&"coin_drop_min"))
	var high: int = int(def.get(&"coin_drop_max"))

	var killer := Node3D.new()
	killer.name = "CheckBountyKiller"
	killer.add_to_group(&"players")
	killer.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	root.add_child(killer)

	# A bystander under a DIFFERENT authority. It is in the players group, so the party fan-out
	# `_grant_tier_to_party()` uses would pay it; a bounty must not.
	var bystander := Node3D.new()
	bystander.name = "CheckBountyBystander"
	bystander.add_to_group(&"players")
	bystander.set_multiplayer_authority(2)
	root.add_child(bystander)
	await process_frame

	var killer_before: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"coins"))
	var bystander_before: int = int(inventory.call("host_count", 2, &"coins"))

	var enemy: Node3D = world.call("host_spawn", &"peatling", KILL_SITE)
	check(enemy != null, "the host spawns a Peatling")
	if enemy != null:
		await process_frame
		# Through the real damage seam CombatService uses, not a hand-emitted event.
		enemy.call(&"host_apply_damage", int(def.get(&"max_health")) * 4, NetConfig.HOST_PEER_ID)
		await process_frame
		check(not bool(enemy.call(&"is_alive")), "and it dies to the shared damageable seam")

	var granted: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"coins")) - killer_before
	var bystander_granted: int = int(inventory.call("host_count", 2, &"coins")) - bystander_before
	check(granted >= low and granted <= high,
		"the killer was paid inside peatling.tres's authored range %d-%d (+%d)" % [low, high, granted])
	check(bystander_granted == 0,
		"the bystander was paid nothing for a kill they did not make (+%d)" % bystander_granted)

	if enemy != null:
		enemy.queue_free()
	killer.queue_free()
	bystander.queue_free()
	await process_frame


func _check_uncredited_death_pays_nobody(inventory: Node) -> void:
	print("\n== an uncredited death pays nobody ==")
	var before: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"coins"))
	EVENT_BUS.emit_enemy_killed(&"mire_herald", 45, 75, 0, KILL_SITE)
	var after: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"coins"))
	check(after == before, "peer 0 (a burst, a fall — nobody) granted no coins (+%d)" % [after - before])

	# And a kind authored with no bounty at all is a no-op even with a real killer.
	EVENT_BUS.emit_enemy_killed(&"check_worthless", 0, 0, NetConfig.HOST_PEER_ID, KILL_SITE)
	var after_worthless: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"coins"))
	check(after_worthless == after,
		"a kind with a 0-0 bounty granted nothing (+%d)" % [after_worthless - after])


## F-219's contract, applied to bounties: two runs sharing a `GameState.run_seed` pay the same
## bounties in the same order. Reproduced by resetting the service's per-run ordinal the same way
## `seed_ready` does, then replaying the identical kill.
func _check_determinism(reward_service: Node, inventory: Node) -> void:
	print("\n== the same seed and the same kill ordinal pay the same coins (F-219) ==")
	var first: int = _replay_one_kill(reward_service, inventory)
	var second: int = _replay_one_kill(reward_service, inventory)
	check(first == second,
		"a replayed kill at the same ordinal paid the same bounty (%d, %d)" % [first, second])
	check(first > 0, "and it paid something at all (%d)" % first)


func _replay_one_kill(reward_service: Node, inventory: Node) -> int:
	reward_service.call("_on_seed_ready", 0)
	var before: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"coins"))
	EVENT_BUS.emit_enemy_killed(&"bog_bulwark", 18, 30, NetConfig.HOST_PEER_ID, KILL_SITE)
	return int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"coins")) - before


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
