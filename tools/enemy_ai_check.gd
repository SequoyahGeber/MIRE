extends SceneTree

## Focused offline proof for task 5.1 — the three capabilities it generalised on top of 2.10's
## `IDLE -> CHASE -> TELL -> ATTACK -> RECOVER` state machine: perception (a facing cone plus an
## optional line-of-sight ray, both acquisition-only), alerting (a fresh acquisition wakes untargeted
## packmates in range, one hop) and an attack-slot cap (at most `max_concurrent_attackers` may
## telegraph or swing at the same target at once).
##
## Every scenario builds its own `Enemy` nodes directly against a synthetic `EnemyDef` (no model, no
## EnemyWorld spawn path — 2.10's `enemy_check.gd` already proves that path end to end) so each test
## controls exactly the fields it is exercising. Scenarios are spaced 500 m apart on X and each
## player gets a unique peer id, so no scenario's aggro/alert/attack-slot math can see another's.
##
## Timings are driven by stepping `_physics_process` directly, never by sleeping — see enemy_check.gd's
## header for why.

const ENEMY_SCRIPT := preload("res://systems/enemies/enemy.gd")
const ENEMY_DEF := preload("res://systems/enemies/enemy_def.gd")

var failures: int = 0
var _next_peer: int = 200


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	await _check_cone()
	await process_frame  # let the previous scenario's queue_free() calls actually clear
	await _check_line_of_sight()
	await process_frame
	await _check_retention_ignores_perception()
	await process_frame
	await _check_alert()
	await process_frame
	await _check_attack_slot_cap()
	await process_frame
	await _check_attack_slot_cap_is_per_kind()
	await process_frame
	await _check_engagement_ledger_hygiene()

	print("ENEMY_AI_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


# ── Perception: the facing cone gates acquisition ───────────────────────────────────────────────────


func _check_cone() -> void:
	var origin := Vector3(0.0, 0.0, 0.0)
	var def: Resource = _make_def({"vision_angle_deg": 90.0, "requires_line_of_sight": false})
	var enemy: Node3D = _spawn_enemy(def, origin)
	var behind: Node3D = _spawn_player(origin + Vector3(0.0, 0.0, 8.0))  # enemy faces -Z at rest

	_step(enemy, 0.1)
	check(int(enemy.get("state")) == 0, "a player behind a 90 deg cone is not acquired")
	check(int(enemy.call("target_peer")) == 0, "and no target is held")

	var ahead: Node3D = _spawn_player(origin + Vector3(0.0, 0.0, -8.0))
	behind.queue_free()
	# The failed scan above already set the RESCAN_INTERVAL_SEC cooldown (F-099/F-111) — step past it
	# rather than guessing one step covers it.
	check(_step_until_state(enemy, 1, 0.05, 20), "the same enemy acquires a player inside the cone")
	check(int(enemy.call("target_peer")) == _peer_id(ahead), "targeting the one it can see")

	_cleanup([enemy, ahead])


# ── Perception: an unobstructed ray gates acquisition ───────────────────────────────────────────────


func _check_line_of_sight() -> void:
	var origin := Vector3(500.0, 0.0, 0.0)
	var def: Resource = _make_def({"vision_angle_deg": 360.0, "requires_line_of_sight": true})
	var enemy: Node3D = _spawn_enemy(def, origin)
	var player: Node3D = _spawn_player(origin + Vector3(0.0, 0.0, -8.0))

	var wall: StaticBody3D = _spawn_wall(origin + Vector3(0.0, 1.0, -4.0))
	await process_frame  # the physics server needs a frame to register the new body

	_step(enemy, 0.1)
	check(int(enemy.get("state")) == 0, "a wall between enemy and player blocks acquisition")
	check(int(enemy.call("target_peer")) == 0, "no target is held while the ray is blocked")

	wall.queue_free()
	await process_frame
	# Same F-099/F-111 cooldown as above — the blocked scan already armed it.
	check(_step_until_state(enemy, 1, 0.05, 20), "removing the wall lets the same enemy acquire")
	check(int(enemy.call("target_peer")) == _peer_id(player), "targeting the now-visible player")

	_cleanup([enemy, player])


# ── Perception gates acquisition only — a held target survives losing perception ───────────────────


func _check_retention_ignores_perception() -> void:
	var origin := Vector3(1000.0, 0.0, 0.0)
	var def: Resource = _make_def({"vision_angle_deg": 360.0, "requires_line_of_sight": true})
	var enemy: Node3D = _spawn_enemy(def, origin)
	var player: Node3D = _spawn_player(origin + Vector3(0.0, 0.0, -8.0))

	_step(enemy, 0.1)
	check(int(enemy.call("target_peer")) == _peer_id(player), "the target is acquired in the open")

	# A wall now stands between them. Acquisition would refuse this; retention must not.
	var wall: StaticBody3D = _spawn_wall(origin + Vector3(0.0, 1.0, -4.0))
	await process_frame
	_step(enemy, 0.1, 5)
	check(int(enemy.call("target_peer")) == _peer_id(player),
		"a target already held is kept once a wall blocks the ray — retention never re-checks perception")

	_cleanup([enemy, player, wall])


# ── Group behaviour: a fresh acquisition alerts untargeted packmates in range, one hop ──────────────


func _check_alert() -> void:
	var origin := Vector3(1500.0, 0.0, 0.0)
	var def: Resource = _make_def({"alert_radius_m": 10.0})
	var spotter: Node3D = _spawn_enemy(def, origin)
	var player: Node3D = _spawn_player(origin + Vector3(0.0, 0.0, -8.0))

	# In range of the spotter's alert (never sees the player itself — placed far from it).
	var packmate: Node3D = _spawn_enemy(_make_def({"alert_radius_m": 10.0}), origin + Vector3(6.0, 0.0, 0.0))
	# Out of the spotter's alert radius — the control.
	var stranger: Node3D = _spawn_enemy(_make_def({"alert_radius_m": 10.0}), origin + Vector3(15.0, 0.0, 0.0))
	# In range of the PACKMATE's own alert (7 m from it) but outside the SPOTTER's (13 m from it) —
	# never alerted directly by the spotter, so this only gets woken if alerting chains. It must not.
	var second_hop: Node3D = _spawn_enemy(
		_make_def({"alert_radius_m": 10.0}), origin + Vector3(13.0, 0.0, 0.0)
	)

	check(int(packmate.call("target_peer")) == 0, "the packmate starts with no target")
	_step(spotter, 0.1)
	check(int(spotter.get("state")) == 1, "the spotter acquires the player on its own")
	check(int(packmate.call("target_peer")) == _peer_id(player),
		"acquiring wakes the untargeted packmate within alert_radius_m, same tick")
	check(int(stranger.call("target_peer")) == 0,
		"an enemy outside alert_radius_m is not woken")
	check(int(second_hop.call("target_peer")) == 0,
		"alerting is one hop — the packmate's own alert radius does not chain")

	# The wake is live, not just a flag: the packmate actually pursues once it is stepped. Horizontal
	# distance only — this harness has no floor, so a stepped body also free-falls (F-099's gravity
	# term has nothing to stand on), and that vertical drift is not what this assertion is about.
	var start_distance: float = _flat_distance(packmate, player)
	_step(packmate, 0.1, 10)
	check(_flat_distance(packmate, player) < start_distance,
		"the woken packmate actually chases the alerted target")

	_cleanup([spotter, packmate, stranger, second_hop, player])


# ── Group behaviour: an attack-slot cap holds extra attackers back ──────────────────────────────────


func _check_attack_slot_cap() -> void:
	var origin := Vector3(2000.0, 0.0, 0.0)
	var def: Resource = _make_def({
		"alert_radius_m": 0.0, "max_concurrent_attackers": 2,
		"attack_range_m": 5.0, "attack_tell_seconds": 0.1, "attack_seconds": 0.1,
		"attack_recovery_seconds": 0.1,
	})
	var player: Node3D = _spawn_player(origin)
	var attackers: Array[Node3D] = [
		_spawn_enemy(def, origin + Vector3(0.0, 0.0, -1.5)),
		_spawn_enemy(def, origin + Vector3(1.3, 0.0, -1.0)),
		_spawn_enemy(def, origin + Vector3(-1.3, 0.0, -1.0)),
	]

	# One shared tick: all three resolve the same target and are already in range, in a fixed order —
	# the first two claim the cap's two slots, the third finds them taken.
	for enemy: Node3D in attackers:
		_step(enemy, 0.1)
	var telling: int = 0
	for enemy: Node3D in attackers:
		if int(enemy.get("state")) in [2, 3]:  # TELL, ATTACK
			telling += 1
	check(telling == int(def.get("max_concurrent_attackers")),
		"exactly max_concurrent_attackers enemies commit to an attack on the first opportunity")
	check(int(attackers[2].get("state")) == 1,
		"the one that found the cap full holds position (CHASE) instead of telegraphing")

	# Slots free up as the first two cycle through TELL -> ATTACK -> RECOVER -> CHASE; the held-back
	# enemy must eventually get a turn — proving the cap is rechecked every tick, not a one-time refusal.
	var third_got_a_turn: bool = false
	for _i: int in 60:
		for enemy: Node3D in attackers:
			_step(enemy, 0.05)
		if int(attackers[2].get("state")) in [2, 3]:
			third_got_a_turn = true
			break
	check(third_got_a_turn, "the held-back enemy attacks once a slot frees up")

	_cleanup(attackers + [player])


# ── Group behaviour: the cap is per KIND, and its ledger does not drift (F-331) ─────────────────────


## `Enemy`'s class comment has always said "at most `max_concurrent_attackers` of one kind", but
## `_engaged_attackers()` never compared `definition.id` — so crawlers, striders and bosses all drew
## on one shared budget against the same target. This is the assertion that behaviour finally matches
## the documented contract, and the one that would go red if the kind comparison were removed again.
func _check_attack_slot_cap_is_per_kind() -> void:
	var origin := Vector3(3000.0, 0.0, 0.0)
	var shared: Dictionary = {
		"alert_radius_m": 0.0, "max_concurrent_attackers": 1,
		"attack_range_m": 5.0, "attack_tell_seconds": 0.4, "attack_seconds": 0.4,
		"attack_recovery_seconds": 0.4,
	}
	var alpha: Resource = _make_def(shared.merged({"id": &"ai_test_alpha"}, true))
	var beta: Resource = _make_def(shared.merged({"id": &"ai_test_beta"}, true))

	var player: Node3D = _spawn_player(origin)
	var pack: Array[Node3D] = [
		_spawn_enemy(alpha, origin + Vector3(0.0, 0.0, -1.5)),
		_spawn_enemy(alpha, origin + Vector3(1.3, 0.0, -1.0)),
		_spawn_enemy(beta, origin + Vector3(-1.3, 0.0, -1.0)),
		_spawn_enemy(beta, origin + Vector3(0.0, 0.0, 1.5)),
	]
	for enemy: Node3D in pack:
		_step(enemy, 0.1)

	var alpha_engaged: int = _engaged_of_kind(pack, &"ai_test_alpha")
	var beta_engaged: int = _engaged_of_kind(pack, &"ai_test_beta")
	check(alpha_engaged == 1, "one alpha holds the alpha cap (got %d)" % alpha_engaged)
	# The regression assertion. Under the shared budget the single alpha filled the ONE slot and no
	# beta could ever telegraph, so this read 0.
	check(beta_engaged == 1,
		"a beta commits too — the cap is per kind, not one budget shared across kinds (got %d)"
			% beta_engaged)

	_cleanup(pack + [player])


## The ledger `_engaged_attackers()` now reads must hold exactly the engaged enemies, and must let
## go of them however they stop being engaged. A drifting count is the specific failure the original
## group scan was written to avoid, so it is the specific thing worth proving.
func _check_engagement_ledger_hygiene() -> void:
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	check(world != null, "EnemyWorld autoload is present to hold the engagement ledger")
	if world == null:
		return

	var origin := Vector3(4000.0, 0.0, 0.0)
	var def: Resource = _make_def({
		"id": &"ai_test_ledger", "alert_radius_m": 0.0, "max_concurrent_attackers": 1,
		"attack_range_m": 5.0, "attack_tell_seconds": 5.0, "attack_seconds": 0.2,
		"attack_recovery_seconds": 0.2,
	})
	var player: Node3D = _spawn_player(origin)
	var engaged: Node3D = _spawn_enemy(def, origin + Vector3(0.0, 0.0, -1.5))
	var waiting: Node3D = _spawn_enemy(def, origin + Vector3(1.3, 0.0, -1.0))

	var before: int = int(world.call(&"engagement_row_count"))
	_step(engaged, 0.1)
	_step(waiting, 0.1)
	check(int(world.call(&"engagement_row_count")) == before + 1,
		"exactly one row appears when one enemy commits")
	check(int(waiting.get("state")) == 1, "the second enemy of the same kind is held at CHASE")

	# Idle enemies far from anyone must not enter the ledger at all. This is what makes the lookup
	# O(engaged) rather than O(roster): if an idle enemy could hold a row, the "scan" would grow back
	# into the O(N^2) walk F-331 removed.
	var idle: Array[Node3D] = []
	for i: int in 12:
		idle.append(_spawn_enemy(def, origin + Vector3(500.0 + float(i) * 10.0, 0.0, 0.0)))
	for enemy: Node3D in idle:
		_step(enemy, 0.1)
	check(int(world.call(&"engagement_row_count")) == before + 1,
		"12 idle enemies add no rows — the ledger holds engagements, not the roster")

	# Death mid-telegraph: the exact case the original comment said a counter could not survive.
	engaged.set("state", 5)  # DEAD
	check(int(world.call(&"engagement_row_count")) == before,
		"dying mid-telegraph releases the slot immediately")
	var freed: bool = _step_until_state(waiting, 2, 0.1, 40)
	check(freed, "the held-back enemy takes the slot the dead one released")

	# Removal from the tree is the other way an engagement ends, and it goes through `_exit_tree()`.
	var rows_with_waiting: int = int(world.call(&"engagement_row_count"))
	check(rows_with_waiting == before + 1, "the new attacker holds exactly one row")
	waiting.queue_free()
	await process_frame
	check(int(world.call(&"engagement_row_count")) == before,
		"freeing an engaged enemy releases its row through _exit_tree()")

	_cleanup(idle + [engaged, player])


## Enemies of `kind` currently telegraphing or swinging (states TELL=2, ATTACK=3).
func _engaged_of_kind(pack: Array[Node3D], kind: StringName) -> int:
	var count: int = 0
	for enemy: Node3D in pack:
		var def: Resource = enemy.get("definition") as Resource
		if def != null and StringName(def.get("id")) == kind and int(enemy.get("state")) in [2, 3]:
			count += 1
	return count


# ── Construction ──────────────────────────────────────────────────────────────────────────────────


func _make_def(overrides: Dictionary = {}) -> Resource:
	var def: Resource = ENEMY_DEF.new()
	def.set("id", &"ai_test")
	def.set("max_health", 999)
	def.set("radius_m", 0.45)
	def.set("height_m", 0.6)
	def.set("move_speed", 4.0)
	def.set("stop_distance_m", 1.0)
	def.set("turn_speed_rad", 6.0)
	def.set("aggro_radius_m", 18.0)
	def.set("deaggro_radius_m", 26.0)
	def.set("attack_range_m", 2.0)
	def.set("attack_damage", 3)
	def.set("attack_tell_seconds", 0.1)
	def.set("attack_seconds", 0.1)
	def.set("attack_recovery_seconds", 0.1)
	def.set("vision_angle_deg", 360.0)
	def.set("requires_line_of_sight", true)
	def.set("alert_radius_m", 8.0)
	def.set("max_concurrent_attackers", 2)
	for key: String in overrides:
		def.set(key, overrides[key])
	return def


func _spawn_enemy(def: Resource, position: Vector3) -> Node3D:
	var enemy: CharacterBody3D = ENEMY_SCRIPT.new()
	enemy.name = "AiTestEnemy%d" % _next_peer  # unique; not read as a peer id
	enemy.set("definition", def)
	enemy.position = position
	root.add_child(enemy)
	return enemy


func _spawn_player(position: Vector3) -> Node3D:
	var player := Node3D.new()
	player.name = str(_next_peer)
	_next_peer += 1
	player.add_to_group(&"players")
	root.add_child(player)
	player.global_position = position
	return player


func _spawn_wall(position: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 3.0, 0.5)
	shape.shape = box
	body.add_child(shape)
	root.add_child(body)
	body.global_position = position
	return body


func _peer_id(player: Node3D) -> int:
	return String(player.name).to_int()


func _flat_distance(a: Node3D, b: Node3D) -> float:
	var delta: Vector3 = a.global_position - b.global_position
	return Vector2(delta.x, delta.z).length()


func _cleanup(nodes: Array) -> void:
	for node: Variant in nodes:
		if node is Node and is_instance_valid(node):
			(node as Node).queue_free()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


## Drives the host state machine directly — see enemy_check.gd's header for why.
func _step(enemy: Node3D, delta: float, times: int = 1) -> void:
	for _i: int in times:
		if not is_instance_valid(enemy) or not enemy.is_inside_tree():
			return
		enemy.call("_physics_process", delta)


## Steps until `wanted` is reached or `max_steps` is exhausted (enemy_check.gd's own helper, same
## shape) — needed wherever a scenario reuses one enemy for a second acquisition, since the first
## scan already armed RESCAN_INTERVAL_SEC's cooldown (F-099/F-111) and a single further step can land
## inside it.
func _step_until_state(enemy: Node3D, wanted: int, delta: float, max_steps: int) -> bool:
	for _i: int in max_steps:
		if not is_instance_valid(enemy) or not enemy.is_inside_tree():
			return false
		if int(enemy.get("state")) == wanted:
			return true
		enemy.call("_physics_process", delta)
	return int(enemy.get("state")) == wanted
