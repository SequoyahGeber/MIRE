extends SceneTree

## F-585, first half: the status mechanism Burning and Chilled are made of, which the project did not
## have and which F-580's `ignite_chance`/`slow_chance`/`slow_potency` had no hope of reading.
##
##   .agent/bin/agent godot --script tools/status_effects_check.gd
##
## Targets here are STUBS, not real enemies, and that is the point rather than a shortcut:
## `StatusService` is written against "anything with `host_apply_damage()` and an opinion about
## `is_alive()`", so a stub is the honest test of its contract and keeps this check independent of
## navmesh, spawner and `EnemyDef` content. `tools/resonance_check.gd` drives a real `Enemy` for the
## parts that genuinely need one.

const BURNING: StringName = &"burning"
const CHILLED: StringName = &"chilled"
const STAGGERED: StringName = &"staggered"

var failures: int = 0


## The smallest thing a status can live on: it takes damage, it can die, and it remembers what it was
## hit for so the check can assert the burn actually paid out.
class StubTarget extends Node3D:
	var hp: int = 100
	var damage_events: Array[Dictionary] = []

	func host_apply_damage(amount: int, instigator_peer_id: int) -> bool:
		if hp <= 0:
			return false
		hp = maxi(hp - amount, 0)
		damage_events.append({"amount": amount, "peer": instigator_peer_id})
		return true

	func is_alive() -> bool:
		return hp > 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	var status: Node = root.get_node_or_null(^"StatusService")
	check(status != null, "StatusService autoload exists")
	if status == null:
		_finish()
		return

	await _check_burn(status)
	await _check_chill(status)
	await _check_stagger(status)
	await _check_refresh(status)
	await _check_lifecycle(status)

	_finish()


func _check_burn(status: Node) -> void:
	print("\n== Burning ==")
	var target := StubTarget.new()
	root.add_child(target)

	check(bool(status.call(&"host_apply", target, BURNING, 4.0, 3.0, 7)),
		"a burn applies to a living target")
	check(bool(status.call(&"is_burning", target)), "the target reads as burning")
	check(int(status.call(&"source_of", target, BURNING)) == 7,
		"the burn remembers who lit it, so the kill pays the right player")

	# One full tick's worth of time, driven directly rather than waited out.
	status.call(&"_physics_process", 0.5)
	check(target.damage_events.size() == 1,
		"a burn deals damage on its tick (%d events)" % target.damage_events.size())
	if target.damage_events.size() > 0:
		check(int(target.damage_events[0]["amount"]) == 3, "the tick deals the applied potency")
		check(int(target.damage_events[0]["peer"]) == 7,
			"burn damage is credited to the peer who applied it, not to nobody")

	# Half a tick pays nothing; the remainder carries.
	status.call(&"_physics_process", 0.25)
	check(target.damage_events.size() == 1, "a partial tick does not pay early")
	status.call(&"_physics_process", 0.25)
	check(target.damage_events.size() == 2, "the fractional remainder carries into the next tick")

	target.free()
	await process_frame


func _check_chill(status: Node) -> void:
	print("\n== Chilled ==")
	var target := StubTarget.new()
	root.add_child(target)

	check(is_equal_approx(float(status.call(&"speed_scale", target)), 1.0),
		"an unchilled target moves at its authored speed")
	status.call(&"host_apply", target, CHILLED, 3.0, 0.4, 1)
	check(is_equal_approx(float(status.call(&"speed_scale", target)), 0.6),
		"a 0.4 chill scales speed to 0.6 (got %f)" % float(status.call(&"speed_scale", target)))
	check(target.damage_events.is_empty(), "a chill deals no damage")

	# The clamp is what stops Cold becoming a stunlock.
	status.call(&"host_apply", target, CHILLED, 3.0, 5.0, 1)
	var scale: float = float(status.call(&"speed_scale", target))
	check(scale >= 0.24, "an absurd chill is clamped to MAX_SLOW_FRACTION, never to a standstill (%f)" % scale)

	target.free()
	await process_frame


func _check_stagger(status: Node) -> void:
	print("\n== Staggered ==")
	var target := StubTarget.new()
	root.add_child(target)
	status.call(&"host_apply", target, STAGGERED, 1.0, 1.0, 1)
	check(bool(status.call(&"is_staggered", target)), "a stagger applies")
	check(is_equal_approx(float(status.call(&"speed_scale", target)), 1.0),
		"a stagger is not a slow — the enemy skips its whole tick instead")
	target.free()
	await process_frame


func _check_refresh(status: Node) -> void:
	print("\n== Refresh, never stack ==")
	var target := StubTarget.new()
	root.add_child(target)

	status.call(&"host_apply", target, BURNING, 4.0, 2.0, 5)
	status.call(&"host_apply", target, BURNING, 1.0, 6.0, 9)
	check(is_equal_approx(float(status.call(&"potency_of", target, BURNING)), 6.0),
		"a stronger application upgrades the potency")
	check(int(status.call(&"source_of", target, BURNING)) == 5,
		"the ORIGINAL igniter keeps the credit — re-tagging a burning enemy must not steal the kill")

	status.call(&"host_apply", target, BURNING, 4.0, 1.0, 9)
	check(is_equal_approx(float(status.call(&"potency_of", target, BURNING)), 6.0),
		"a weaker application never downgrades a live burn")

	target.free()
	await process_frame


func _check_lifecycle(status: Node) -> void:
	print("\n== Expiry, death and cleanup ==")
	var target := StubTarget.new()
	root.add_child(target)

	status.call(&"host_apply", target, BURNING, 1.0, 1.0, 1)
	status.call(&"host_apply", target, CHILLED, 1.0, 0.3, 1)
	check(int(status.call(&"tracked_count")) >= 1, "the service tracks a target with statuses")
	check(target.get_node_or_null(^"Status_burning") != null,
		"burning attaches its own VFX to the target, so nothing has to cooperate to be visible")
	check(target.get_node_or_null(^"Status_chilled") != null, "chilled attaches its own VFX")

	# Past the expiry.
	status.call(&"_physics_process", 1.2)
	check(not bool(status.call(&"is_burning", target)), "a burn expires on its own clock")
	check(not bool(status.call(&"is_chilled", target)), "a chill expires on its own clock")
	check(is_equal_approx(float(status.call(&"speed_scale", target)), 1.0),
		"speed returns to normal once the chill is gone")

	# A dead target is dropped rather than kept burning — Fire's Greater Resonance chains off burning
	# enemies, so a corpse that can hold a burn is an infinite chain.
	status.call(&"host_apply", target, BURNING, 5.0, 1.0, 1)
	target.hp = 0
	check(not bool(status.call(&"host_apply", target, BURNING, 5.0, 1.0, 1)),
		"a dead target refuses a new status")
	status.call(&"_physics_process", 0.1)
	check(not bool(status.call(&"is_burning", target)), "a dead target stops burning")

	status.call(&"host_clear_all")
	check(int(status.call(&"tracked_count")) == 0, "host_clear_all() empties the service")

	target.free()
	await process_frame


func _finish() -> void:
	print("\nSTATUS_EFFECTS_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
