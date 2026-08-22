extends SceneTree

## Focused offline proof for task 2.10: the crawler acquires and holds a target with hysteresis,
## paths toward it, telegraphs before it commits, resolves the hit against where the target is at the
## END of the tell, takes damage through 2.8's shared seam, and dies into a corpse that stops being
## damageable.
##
## Timings are driven by stepping the enemy's own `_physics_process` rather than by waiting in real
## time: the state machine is deterministic in delta, and a check that sleeps for 0.4 s per phase is
## a check nobody runs.

const ENEMY_SCRIPT := preload("res://systems/enemies/enemy.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

var failures: int = 0
var attacks: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	check(world != null, "EnemyWorld autoload exists")
	if world == null:
		finish()
		return

	check(bool(world.call("has_def", &"crawler")), "the crawler definition is registered")
	var def: Resource = world.call("get_def", &"crawler")
	check(def != null and (def.call("validation_errors") as PackedStringArray).is_empty(),
		"the authored definition validates")
	check(float(def.get("deaggro_radius_m")) > float(def.get("aggro_radius_m")),
		"deaggro is wider than aggro, so a target on the boundary cannot flicker")
	check(float(def.get("stop_distance_m")) <= float(def.get("attack_range_m")),
		"the enemy stops inside its own reach")
	check(is_equal_approx(float(def.get("attack_tell_seconds")), 0.4),
		"the telegraph is DESIGN.md §6's 0.4 s, matching A-006's authored clip")

	EVENT_BUS.subscribe_enemy_attack_landed(_on_attack_landed)

	# ── a player to hunt ──────────────────────────────────────────────────────────────────────────
	var player := Node3D.new()
	player.name = "1"
	player.add_to_group(&"players")
	root.add_child(player)
	player.global_position = Vector3(0.0, 0.0, 0.0)

	var enemy: Node3D = world.call("host_spawn", &"crawler", Vector3(0.0, 0.0, -8.0))
	check(enemy != null, "the host spawns a crawler")
	if enemy == null:
		finish()
		return
	# This check drives the state machine through _step(). Keep the engine's physics loop from
	# advancing the same live node between assertions (F-354), especially across the await below.
	enemy.set_physics_process(false)
	await process_frame
	check(enemy.is_in_group(&"damageable"), "an enemy joins 2.8's damageable group")
	check(enemy.has_method("host_apply_damage"), "and implements the seam CombatService calls")
	check(enemy.is_in_group(&"enemies"), "and is findable as an enemy")
	check(int(enemy.get("health")) == int(def.get("max_health")), "it spawns at full health")
	check(enemy.get_node_or_null(NodePath(NetConfig.PLAYER_SYNC_NODE)) != null,
		"it carries a synchronizer NetInterp can smooth (F-004)")

	# ── aggro and chase ───────────────────────────────────────────────────────────────────────────
	check(int(enemy.get("state")) == 0, "it starts idle")
	_step(enemy, 0.1)
	check(int(enemy.get("state")) == 1, "a player inside aggro range makes it chase")
	check(int(enemy.call("target_peer")) == 1, "it targets the peer that owns that player")
	var start_distance: float = enemy.global_position.distance_to(player.global_position)
	_step(enemy, 0.1, 12)
	var closed: float = enemy.global_position.distance_to(player.global_position)
	check(closed < start_distance, "chasing closes the distance (%.2f m -> %.2f m)"
		% [start_distance, closed])

	# Hysteresis: outside aggro but inside deaggro, an acquired target is kept. Both positions are
	# pinned rather than inherited from the chase above, so the distance is not one rounding error
	# away from the boundary being tested.
	enemy.global_position = Vector3.ZERO
	player.global_position = Vector3(0.0, 0.0, 22.0)
	check(22.0 > float(def.get("aggro_radius_m")) and 22.0 < float(def.get("deaggro_radius_m")),
		"the test distance really is between the two radii")
	_step(enemy, 0.1)
	check(int(enemy.call("target_peer")) == 1,
		"a target between the two radii is held, not dropped")
	player.global_position = Vector3(0.0, 0.0, 400.0)
	_step(enemy, 0.1)
	check(int(enemy.call("target_peer")) == 0, "a target past deaggro range is dropped")
	check(int(enemy.get("state")) == 0, "and it returns to idle")

	# ── the telegraph, and what it is for ─────────────────────────────────────────────────────────
	player.global_position = enemy.global_position + Vector3(0.0, 0.0, 1.0)
	# The scan that just dropped the far-away target (line 87-88) reset _rescan_wait to
	# RESCAN_INTERVAL_SEC (F-099's throttle: an untargeted enemy rescans at most once per 0.2 s, by
	# design). A single 0.05 s step lands inside that cooldown and never looks at the player standing
	# right next to it, so step until the cooldown clears and the state actually changes — the same
	# pattern already used a few lines down for the second telegraph (F-111).
	check(_step_until_state(enemy, 2, 0.05, 20), "a player in reach makes it telegraph")
	attacks.clear()
	# Stepped to either side of the 0.4 s boundary, never onto it: _phase_remaining is a float
	# subtraction, so "exactly 0.4 s of steps" can land a rounding error above zero.
	_step(enemy, 0.15, 2)
	check(attacks.is_empty(), "nothing lands during the tell")
	_step(enemy, 0.15)
	check(attacks.size() == 1, "the hit resolves when the tell ends")
	check(not attacks.is_empty() and int(attacks[0].get("damage", 0)) == int(def.get("attack_damage")),
		"it deals the authored damage")
	check(not attacks.is_empty() and int(attacks[0].get("peer_id", 0)) == 1,
		"aimed at the peer it was hunting")
	check(int(enemy.get("state")) == 3, "and it commits to the swing")

	# The whole point of a 0.4 s telegraph: leaving beats it.
	player.global_position = enemy.global_position + Vector3(0.0, 0.0, 1.0)
	# Step until it telegraphs rather than guessing how many frames the swing and recovery take —
	# those are tunable numbers (2.9 owns them) and a fixed count would break the moment they move.
	check(_step_until_state(enemy, 2, 0.05, 200), "it winds up again")
	attacks.clear()
	player.global_position = enemy.global_position + Vector3(0.0, 0.0, 9.0)
	_step(enemy, 0.15, 5)
	check(attacks.is_empty(), "stepping out of range during the tell beats the swing")

	# ── damage in, through 2.8's seam ─────────────────────────────────────────────────────────────
	player.global_position = enemy.global_position + Vector3(0.0, 0.0, 3.0)
	var before: int = int(enemy.get("health"))
	check(bool(enemy.call("host_apply_damage", 3, 1)), "the melee seam damages it")
	check(int(enemy.get("health")) == before - 3, "health drops by exactly the damage dealt")
	check(not bool(enemy.call("host_apply_damage", 0, 1)), "zero damage is refused")
	check(not bool(enemy.call("host_apply_damage", -5, 1)), "negative damage is refused")

	# A committed swing is not interruptible — an enemy whose attack any chip cancels cannot threaten.
	player.global_position = enemy.global_position + Vector3(0.0, 0.0, 1.0)
	check(_step_until_state(enemy, 2, 0.05, 200), "it is telegraphing")
	enemy.call("host_apply_damage", 1, 1)
	check(int(enemy.get("state")) == 2, "damage does not cancel a committed telegraph")

	# ── death ─────────────────────────────────────────────────────────────────────────────────────
	check(bool(enemy.call("is_alive")), "it is alive until it is not")
	check(bool(enemy.call("host_apply_damage", 999, 1)), "a lethal blow is accepted")
	check(int(enemy.get("health")) == 0, "health floors at zero, never negative")
	check(int(enemy.get("state")) == 5, "it enters the dead state")
	check(not bool(enemy.call("is_alive")), "and reports itself dead")
	check(not enemy.is_in_group(&"damageable"), "a corpse leaves the damageable group")
	check(not bool(enemy.call("host_apply_damage", 5, 1)), "and cannot be hit again")
	check(int(world.call("live_count")) == 0, "the world counts no living enemies")

	# The corpse lingers, then goes.
	_step(enemy, 0.5, 2)
	check(is_instance_valid(enemy) and enemy.is_inside_tree(), "the corpse lingers while it plays out")
	_step(enemy, 1.0, 8)
	await process_frame
	check(not is_instance_valid(enemy) or not enemy.is_inside_tree(),
		"and the host eventually despawns it")

	print("ENEMY_CHECK attacks=%d failures=%d" % [attacks.size(), failures])
	finish()


## Drives the host state machine directly. `_physics_process` is host-only and deterministic in
## delta, so stepping it is both faster and more repeatable than sleeping.
func _step(enemy: Node3D, delta: float, times: int = 1) -> void:
	for _i: int in times:
		if not is_instance_valid(enemy) or not enemy.is_inside_tree():
			return
		enemy.call("_physics_process", delta)


## Steps the host state machine until it reaches [param wanted], or gives up. Returns whether it got
## there, so a caller can assert on the outcome rather than on a frame count.
func _step_until_state(enemy: Node3D, wanted: int, delta: float, max_steps: int) -> bool:
	for _i: int in max_steps:
		if not is_instance_valid(enemy) or not enemy.is_inside_tree():
			return false
		if int(enemy.get("state")) == wanted:
			return true
		enemy.call("_physics_process", delta)
	return int(enemy.get("state")) == wanted


func _on_attack_landed(enemy_id: StringName, peer_id: int, damage: int, position: Vector3) -> void:
	attacks.append({
		"enemy_id": enemy_id, "peer_id": peer_id, "damage": damage, "position": position
	})


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
