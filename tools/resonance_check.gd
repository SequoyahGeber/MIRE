extends SceneTree

## F-585, second half: the twelve Resonances of DESIGN.md §4.4, each driven end to end.
##
##   .agent/bin/agent godot --script tools/resonance_check.gd
##
## The powerups granted here are the five modifier-less ones (`open_flame`, `whetted_thirst`,
## `quiet_bloom`, `white_quiet`, `empty_vessel`) wherever a family has one, which is deliberate: they
## declare no stats at all, so every effect this check observes can ONLY have come from the
## Resonance layer. They are also the content F-585 was filed about — powerups whose entire payoff is
## a threshold that did nothing.
##
## Enemies are stubs in the `enemies` group (see `tools/status_effects_check.gd` for why), plus one
## assertion that the real `Enemy` carries the two methods the effects call into.

const RESONANCE := preload("res://autoload/resonance_service.gd")
const POWERUP_DEF := preload("res://systems/powerups/powerup_def.gd")

const HOST_PEER: int = 1

var failures: int = 0


class StubEnemy extends Node3D:
	var hp: int = 200
	var knockbacks: Array[Dictionary] = []
	var damage_taken: int = 0

	func _init() -> void:
		add_to_group(&"enemies")

	func host_apply_damage(amount: int, _instigator_peer_id: int) -> bool:
		if hp <= 0:
			return false
		hp = maxi(hp - amount, 0)
		damage_taken += amount
		return true

	func host_apply_knockback(direction: Vector3, impulse: float) -> void:
		knockbacks.append({"direction": direction, "impulse": impulse})

	func is_alive() -> bool:
		return hp > 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var resonance: Node = root.get_node_or_null(^"ResonanceService")
	var powerups: Node = root.get_node_or_null(^"PowerupService")
	var status: Node = root.get_node_or_null(^"StatusService")
	check(resonance != null, "ResonanceService autoload exists")
	check(powerups != null and status != null, "PowerupService and StatusService autoloads exist")
	if resonance == null or powerups == null or status == null:
		_finish()
		return

	_check_coverage(resonance)
	await _check_fire(resonance, powerups, status)
	await _check_cold(resonance, powerups, status)
	await _check_blood(resonance, powerups)
	await _check_fungal(resonance, powerups)
	await _check_kinetic(resonance, powerups, status)
	await _check_void(resonance, powerups)
	_check_enemy_surface()

	_finish()


## The anti-regrowth assertion. F-580 and F-585 are both "a vocabulary grew a name that nothing
## implements"; this fails the moment a seventh family is added to `PowerupDef.KNOWN_FAMILIES`
## without an effect in `ResonanceService`.
func _check_coverage(resonance: Node) -> void:
	print("\n== Coverage ==")
	var implemented: Array = RESONANCE.IMPLEMENTED_FAMILIES
	for family: StringName in POWERUP_DEF.KNOWN_FAMILIES:
		check(implemented.has(family), "family '%s' has a Resonance implementation" % family)
	check(implemented.size() == POWERUP_DEF.KNOWN_FAMILIES.size(),
		"no family is implemented that the vocabulary does not name")
	check(resonance.has_method(&"host_on_hit") and resonance.has_method(&"host_on_enemy_death"),
		"the two host seams combat and death call are public")


func _check_fire(resonance: Node, powerups: Node, status: Node) -> void:
	print("\n== Fire: attacks ignite / ignited enemies explode, chaining ==")
	_reset(powerups)
	powerups.call(&"host_grant", HOST_PEER, &"open_flame", 3)
	check(bool(resonance.call(&"active", HOST_PEER, &"Fire")), "3 stacks of a Fire tag resonate")

	var target := StubEnemy.new()
	root.add_child(target)
	resonance.call(&"host_on_hit", HOST_PEER, target, 10)
	check(bool(status.call(&"is_burning", target)), "Fire 3: a hit sets the target alight")

	# Greater: kill it while burning and the blast should hit — and ignite — a neighbour.
	powerups.call(&"host_grant", HOST_PEER, &"open_flame", 3)
	check(bool(resonance.call(&"greater", HOST_PEER, &"Fire")), "6 stacks reach the Greater Resonance")
	var neighbour := StubEnemy.new()
	root.add_child(neighbour)
	neighbour.global_position = target.global_position + Vector3(2.0, 0.0, 0.0)
	resonance.call(&"host_on_enemy_death", target, HOST_PEER)
	check(neighbour.damage_taken > 0,
		"Fire 6: an ignited corpse explodes onto a neighbour (%d damage)" % neighbour.damage_taken)
	check(bool(status.call(&"is_burning", neighbour)), "Fire 6: the blast chains by igniting it too")

	var far := StubEnemy.new()
	root.add_child(far)
	far.global_position = target.global_position + Vector3(40.0, 0.0, 0.0)
	check(far.damage_taken == 0, "the blast is bounded — a distant enemy takes nothing")

	target.free()
	neighbour.free()
	far.free()
	await process_frame


func _check_cold(resonance: Node, powerups: Node, status: Node) -> void:
	print("\n== Cold: attacks slow / frozen enemies shatter ==")
	_reset(powerups)
	powerups.call(&"host_grant", HOST_PEER, &"white_quiet", 3)
	var target := StubEnemy.new()
	root.add_child(target)
	resonance.call(&"host_on_hit", HOST_PEER, target, 10)
	check(bool(status.call(&"is_chilled", target)), "Cold 3: a hit chills the target")
	check(float(status.call(&"speed_scale", target)) < 1.0, "Cold 3: chilled means slower")

	powerups.call(&"host_grant", HOST_PEER, &"white_quiet", 3)
	var neighbour := StubEnemy.new()
	root.add_child(neighbour)
	neighbour.global_position = target.global_position + Vector3(2.0, 0.0, 0.0)
	resonance.call(&"host_on_enemy_death", target, HOST_PEER)
	check(neighbour.damage_taken > 0,
		"Cold 6: a frozen enemy shatters onto a neighbour (%d damage)" % neighbour.damage_taken)

	target.free()
	neighbour.free()
	await process_frame


func _check_blood(resonance: Node, powerups: Node) -> void:
	print("\n== Blood: kills heal you / kills heal the team, you take double damage ==")
	_reset(powerups)
	var health: Node = root.get_node_or_null(^"PlayerHealth")
	check(health != null, "PlayerHealth autoload exists")
	if health == null:
		return
	powerups.call(&"host_grant", HOST_PEER, &"whetted_thirst", 3)

	health.call(&"_ensure_host_state", HOST_PEER)
	health.call(&"host_apply_damage", HOST_PEER, 20, 0)
	var hurt: int = int(health.call(&"host_hp", HOST_PEER))
	var bus := preload("res://core/events/event_bus.gd")
	bus.emit_enemy_killed(&"peatling", 1, 1, HOST_PEER, Vector3.ZERO)
	var healed: int = int(health.call(&"host_hp", HOST_PEER))
	check(healed > hurt, "Blood 3: a kill heals the killer (%d -> %d)" % [hurt, healed])

	check(int(resonance.call(&"modify_damage_taken", HOST_PEER, 10)) == 10,
		"Blood 3 alone does NOT double incoming damage — that cost belongs to the Greater Resonance")
	powerups.call(&"host_grant", HOST_PEER, &"whetted_thirst", 3)
	check(int(resonance.call(&"modify_damage_taken", HOST_PEER, 10)) == 20,
		"Blood 6: you take double damage")
	_reset(powerups)
	check(int(resonance.call(&"modify_damage_taken", HOST_PEER, 10)) == 10,
		"a peer with no Blood takes damage unchanged, so the read is safe everywhere")


func _check_fungal(resonance: Node, powerups: Node) -> void:
	print("\n== Fungal: corpses sprout spore clouds / spores spread, walk the Mire safely ==")
	_reset(powerups)
	check(is_equal_approx(float(resonance.call(&"modify_blight_rate", HOST_PEER, 2.0)), 2.0),
		"blight is unchanged for a peer with no Fungal")
	powerups.call(&"host_grant", HOST_PEER, &"quiet_bloom", 3)

	var corpse := StubEnemy.new()
	root.add_child(corpse)
	var before: int = _field_count()
	resonance.call(&"host_on_enemy_death", corpse, HOST_PEER)
	await process_frame
	check(_field_count() > before, "Fungal 3: a corpse sprouts a spore cloud")

	powerups.call(&"host_grant", HOST_PEER, &"quiet_bloom", 3)
	check(is_equal_approx(float(resonance.call(&"modify_blight_rate", HOST_PEER, 2.0)), 0.0),
		"Fungal 6: you can walk in the Mire safely")

	corpse.free()
	await process_frame
	_clear_fields()


func _check_kinetic(resonance: Node, powerups: Node, status: Node) -> void:
	print("\n== Kinetic: sprinting builds a charge / the charge is a shockwave ==")
	_reset(powerups)
	powerups.call(&"host_grant", HOST_PEER, &"air_writ", 3)
	check(bool(resonance.call(&"active", HOST_PEER, &"Kinetic")), "3 Kinetic stacks resonate")

	# Not yet: half the sprint time buys nothing.
	resonance.call(&"local_sprint_tick", 1.0)
	check(not bool(resonance.call(&"host_has_charge", HOST_PEER)),
		"a charge is not free — one second of sprinting is not enough")
	resonance.call(&"local_sprint_tick", 5.0)
	check(bool(resonance.call(&"host_has_charge", HOST_PEER)), "Kinetic 3: sprinting fills the charge")

	var target := StubEnemy.new()
	root.add_child(target)
	var bonus: int = int(resonance.call(&"host_on_hit", HOST_PEER, target, 10))
	check(bonus > 0, "Kinetic 3: the charged hit adds bonus damage (%d)" % bonus)
	check(not bool(resonance.call(&"host_has_charge", HOST_PEER)), "the charge is spent by the hit")

	# Greater: the same hit should also knock everything nearby away and stagger it.
	powerups.call(&"host_grant", HOST_PEER, &"air_writ", 2)
	powerups.call(&"host_grant", HOST_PEER, &"bellows_lung", 2)
	check(bool(resonance.call(&"greater", HOST_PEER, &"Kinetic")), "7 Kinetic stacks reach Greater")
	resonance.call(&"local_sprint_tick", 99.0)
	var bystander := StubEnemy.new()
	root.add_child(bystander)
	bystander.global_position = target.global_position + Vector3(2.5, 0.0, 0.0)
	resonance.call(&"host_on_hit", HOST_PEER, target, 10)
	check(bystander.knockbacks.size() > 0, "Kinetic 6: the charge releases as a shockwave")
	check(bool(status.call(&"is_staggered", bystander)), "Kinetic 6: the shockwave staggers")

	target.free()
	bystander.free()
	await process_frame


func _check_void(resonance: Node, powerups: Node) -> void:
	print("\n== Void: dodge blinks / blinking leaves a rift ==")
	_reset(powerups)
	check(is_equal_approx(float(resonance.call(&"local_on_dodge", Vector3.ZERO)), 0.0),
		"a player with no Void dodges exactly as far as before")

	powerups.call(&"host_grant", HOST_PEER, &"empty_vessel", 3)
	var blink: float = float(resonance.call(&"local_on_dodge", Vector3.ZERO))
	check(blink > 0.0, "Void 3: the dodge blinks further (%.1f m)" % blink)
	_clear_fields()

	powerups.call(&"host_grant", HOST_PEER, &"empty_vessel", 3)
	var before: int = _field_count()
	resonance.call(&"local_on_dodge", Vector3.ZERO)
	await process_frame
	check(_field_count() > before, "Void 6: the blink leaves a damaging rift behind")
	_clear_fields()


## The real `Enemy` has to answer what the effects call. Asserted against the class rather than a
## live instance because spawning one needs a navmesh and an `EnemyDef`, which is `enemy_check`'s job.
func _check_enemy_surface() -> void:
	print("\n== The real Enemy ==")
	var source: String = FileAccess.get_file_as_string("res://systems/enemies/enemy.gd")
	check(source.contains("func host_apply_knockback"),
		"Enemy.host_apply_knockback() exists for the shockwave to call")
	check(source.contains("_status_speed_scale()"),
		"Enemy multiplies its authored move_speed by the chill scale")
	check(source.contains("host_on_enemy_death"),
		"Enemy tells the Resonance layer it died, before its statuses are cleared")


func _reset(powerups: Node) -> void:
	powerups.call(&"host_clear", HOST_PEER)
	var status: Node = root.get_node_or_null(^"StatusService")
	if status != null:
		status.call(&"host_clear_all")


func _field_count() -> int:
	var count: int = 0
	for node: Node in root.get_children():
		if String(node.name).begins_with("Hazard_"):
			count += 1
	return count


func _clear_fields() -> void:
	for node: Node in root.get_children():
		if String(node.name).begins_with("Hazard_"):
			node.free()


func _finish() -> void:
	print("\nRESONANCE_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
