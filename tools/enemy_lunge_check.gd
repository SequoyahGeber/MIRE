extends SceneTree

## Focused offline proof for F-240 — `EnemyDef.lunge_speed_m_s` and `Enemy._tick_lunge()`, the
## framework fix for "a telegraphed attack's reach and tell length cannot deny 'just take one step
## back'". `enemy_content_check.gd`'s own header names the gap this closes: 2.10/5.1's `_tick_attack()`
## zeroed `velocity.x`/`velocity.z` for the WHOLE TELL/ATTACK/RECOVER span, so no `EnemyDef` field could
## make a continuously retreating player's backpedal fail — the enemy never closed the gap it opened,
## regardless of `attack_range_m`.
##
## Every scenario builds `Enemy` nodes directly against a synthetic `EnemyDef` (`enemy_ai_check.gd`'s
## own pattern) so each test controls exactly the fields it exercises, spaced 500 m apart on X so no
## scenario's aggro/attack math can see another's. Timings are driven by stepping `_physics_process`
## directly, never by sleeping (see `enemy_check.gd`'s header for why), and player retreat distance is
## calibrated against the ENGINE's own fixed physics delta, not the `delta` argument this script passes
## — see `enemy_content_check.gd`'s header on `_measure_effective_step_seconds()` for why a bare
## `speed * delta` retreat would not be an apples-to-apples comparison.

const ENEMY_SCRIPT := preload("res://systems/enemies/enemy.gd")
const ENEMY_DEF := preload("res://systems/enemies/enemy_def.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

## Enemy.State values, copied as literals rather than referencing the enum — same convention every
## other enemy check file in this project already uses (`enemy_check.gd`, `enemy_ai_check.gd`).
const STATE_TELL: int = 2
const STATE_ATTACK: int = 3

const PLAYER_SPRINT_SPEED_MPS: float = 6.0

var failures: int = 0
var attacks: Array[Dictionary] = []
var _next_peer: int = 600


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	EVENT_BUS.subscribe_enemy_attack_landed(_on_attack_landed)

	await _check_baseline_still_denies_backpedal()
	await process_frame
	await _check_lunge_catches_the_same_backpedal()
	await process_frame
	await _check_lunge_stops_at_stop_distance()
	await process_frame
	await _check_lunge_never_moves_outside_tell()
	await process_frame
	_check_shipped_content_defaults_to_stationary()

	print("ENEMY_LUNGE_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


# ── Baseline: lunge_speed_m_s == 0.0 (every existing EnemyDef) still loses to a plain backpedal ──────


func _check_baseline_still_denies_backpedal() -> void:
	var origin := Vector3(0.0, 0.0, 0.0)
	var def: Resource = _make_def({"lunge_speed_m_s": 0.0})
	var enemy: Node3D = _spawn_enemy(def, origin)
	var player: Node3D = _spawn_player(origin + Vector3(0.0, 0.0, -2.0))
	var effective_step_seconds: float = _measure_effective_step_seconds(def)
	var retreat_step_m: float = PLAYER_SPRINT_SPEED_MPS * effective_step_seconds

	_step(enemy, 0.1)
	check(int(enemy.get("state")) == STATE_TELL, "sanity: it enters the tell immediately at 2 m")
	attacks.clear()
	var start_distance: float = _flat_distance(enemy, player)

	var steps: int = _retreat_through_tell(enemy, player, retreat_step_m)
	check(steps > 0 and steps < 200, "the tell actually ended within the loop's own bound")
	check(int(enemy.get("state")) == STATE_ATTACK, "the tell resolved and committed to a swing")
	check(_flat_distance(enemy, player) > start_distance,
		"F-240's own bug, still true at lunge_speed_m_s = 0.0: the enemy never closed the gap (%.2f m -> %.2f m)"
			% [start_distance, _flat_distance(enemy, player)])
	check(attacks.is_empty(),
		"so a plain continuous backpedal still beats the swing with no lunge — unchanged default")

	_cleanup([enemy, player])


# ── Fix: the SAME backpedal, against a kind whose lunge_speed_m_s outpaces it ─────────────────────────


func _check_lunge_catches_the_same_backpedal() -> void:
	var origin := Vector3(500.0, 0.0, 0.0)
	var def: Resource = _make_def({"lunge_speed_m_s": 20.0})
	check(float(def.get("lunge_speed_m_s")) > PLAYER_SPRINT_SPEED_MPS,
		"sanity: this kind's lunge speed really does exceed player sprint speed")
	var enemy: Node3D = _spawn_enemy(def, origin)
	var player: Node3D = _spawn_player(origin + Vector3(0.0, 0.0, -2.0))
	var effective_step_seconds: float = _measure_effective_step_seconds(def)
	var retreat_step_m: float = PLAYER_SPRINT_SPEED_MPS * effective_step_seconds

	_step(enemy, 0.1)
	check(int(enemy.get("state")) == STATE_TELL, "sanity: it enters the tell immediately at 2 m")
	attacks.clear()
	var start_distance: float = _flat_distance(enemy, player)

	var steps: int = _retreat_through_tell(enemy, player, retreat_step_m)
	check(steps > 0 and steps < 200, "the tell actually ended within the loop's own bound")
	check(int(enemy.get("state")) == STATE_ATTACK, "the tell resolved and committed to a swing")
	check(_flat_distance(enemy, player) < start_distance,
		"unlike the baseline, it actually closed ground on the SAME retreating player (%.2f m -> %.2f m)"
			% [start_distance, _flat_distance(enemy, player)])
	check(not attacks.is_empty(),
		"and the same continuous backpedal that beat the baseline no longer beats this kind's swing")

	_cleanup([enemy, player])


# ── A lunge stops at stop_distance_m rather than carrying the enemy through its target ────────────────


func _check_lunge_stops_at_stop_distance() -> void:
	var origin := Vector3(1000.0, 0.0, 0.0)
	var def: Resource = _make_def({
		"lunge_speed_m_s": 20.0, "stop_distance_m": 1.0, "attack_range_m": 2.0,
	})
	var enemy: Node3D = _spawn_enemy(def, origin)
	# Already inside stop_distance_m when the tell begins, held motionless (a player standing
	# right on top of the enemy) — a lunge that ignored the stop distance would shove the enemy
	# straight through the player instead.
	var player: Node3D = _spawn_player(origin + Vector3(0.0, 0.0, -0.6))

	_step(enemy, 0.1)
	check(int(enemy.get("state")) == STATE_TELL, "sanity: it enters the tell immediately at 0.6 m")
	var before: Vector3 = enemy.global_position

	_step(enemy, 0.1, 5)
	check(int(enemy.get("state")) == STATE_TELL, "still telegraphing (attack_tell_seconds default)")
	var after: Vector3 = enemy.global_position
	check(Vector2(after.x - before.x, after.z - before.z).length() < 0.01,
		"already inside stop_distance_m — the lunge holds position instead of closing further")

	_cleanup([enemy, player])


# ── A lunge only ever applies during TELL — ATTACK/RECOVER stay fully stationary, unchanged ───────────


func _check_lunge_never_moves_outside_tell() -> void:
	var origin := Vector3(1500.0, 0.0, 0.0)
	var def: Resource = _make_def({
		"lunge_speed_m_s": 20.0, "attack_range_m": 5.0, "attack_tell_seconds": 0.1,
		"attack_seconds": 0.3, "attack_recovery_seconds": 0.3,
	})
	var enemy: Node3D = _spawn_enemy(def, origin)
	var player: Node3D = _spawn_player(origin + Vector3(0.0, 0.0, -4.0))

	_step(enemy, 0.05)
	check(int(enemy.get("state")) == STATE_TELL, "sanity: it enters the tell immediately at 4 m")
	# 0.15 s in one call safely clears the 0.1 s tell in a single step, rather than two 0.05 s calls
	# that could land exactly on the float boundary between them.
	_step(enemy, 0.15)
	check(int(enemy.get("state")) == STATE_ATTACK, "the short tell has resolved into the swing")

	var before: Vector3 = enemy.global_position
	# 3 x 0.05 s stays well inside the 0.3 s attack_seconds this scenario authored — no boundary risk.
	_step(enemy, 0.05, 3)
	check(int(enemy.get("state")) == STATE_ATTACK,
		"still mid-swing (state 3), not back to chase or a second tell")
	var after: Vector3 = enemy.global_position
	check(Vector2(after.x - before.x, after.z - before.z).length() < 0.01,
		"ATTACK/RECOVER stay fully stationary — the lunge is scoped to TELL alone, unchanged elsewhere")

	_cleanup([enemy, player])


# ── Every shipped EnemyDef still defaults to 0.0 — no content changed by this framework fix ───────────


func _check_shipped_content_defaults_to_stationary() -> void:
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	check(world != null, "EnemyWorld autoload exists")
	if world == null:
		return
	for id: StringName in [&"crawler", &"tusker", &"strider", &"broodcaller"]:
		if not bool(world.call("has_def", id)):
			continue
		var def: Resource = world.call("get_def", id)
		check(is_equal_approx(float(def.get("lunge_speed_m_s")), 0.0),
			"%s ships with lunge_speed_m_s at its 0.0 default — F-240's fix changes no shipped content"
				% id)


# ── Shared drive loop ─────────────────────────────────────────────────────────────────────────────────


## Retreats `player` directly away from `enemy` by `retreat_step_m` and steps the enemy once, repeated
## until it leaves TELL (or the loop's own generous bound is hit, which would itself be a failure the
## caller's `steps < 200` assertion catches). Small `delta` so the tell spans enough physics calls for
## the per-call movement (fixed by the engine, not by `delta` — see this file's header) to add up to a
## clear, non-borderline margin either way.
func _retreat_through_tell(enemy: Node3D, player: Node3D, retreat_step_m: float) -> int:
	var steps: int = 0
	while int(enemy.get("state")) == STATE_TELL and steps < 200:
		_retreat_by(player, enemy, retreat_step_m)
		_step(enemy, 0.02)
		steps += 1
	return steps


## Moves `player` directly away from `enemy`'s current position by a fixed `distance_m`, flat on the
## XZ plane — a player holding sprint straight backward, the simplest possible kiting attempt. Copied
## from `enemy_content_check.gd`'s own helper of the same name and contract.
func _retreat_by(player: Node3D, enemy: Node3D, distance_m: float) -> void:
	var away: Vector3 = player.global_position - enemy.global_position
	away.y = 0.0
	if away.length_squared() < 0.0001:
		return
	player.global_position += away.normalized() * distance_m


## How far one `_physics_process()` call actually moves an `Enemy` per unit of its own `move_speed` —
## the engine's own fixed physics delta, invisible to and unaffected by the `delta` this script passes
## in. Copied from `enemy_content_check.gd`'s own helper; see its header for the full reasoning.
func _measure_effective_step_seconds(reference_def: Resource) -> float:
	var probe: Node3D = _spawn_enemy(reference_def, Vector3(9000.0, 0.0, 0.0))
	var probe_player: Node3D = _spawn_player(Vector3(9000.0, 0.0, -12.0))
	_step(probe, 0.1)
	var before: Vector3 = probe.global_position
	_step(probe, 0.1)
	var after: Vector3 = probe.global_position
	var displaced: float = Vector2(after.x - before.x, after.z - before.z).length()
	_cleanup([probe, probe_player])
	return displaced / float(reference_def.get("move_speed"))


# ── Construction ──────────────────────────────────────────────────────────────────────────────────────


func _make_def(overrides: Dictionary = {}) -> Resource:
	var def: Resource = ENEMY_DEF.new()
	def.set("id", &"lunge_test")
	def.set("max_health", 999)
	def.set("radius_m", 0.45)
	def.set("height_m", 0.6)
	def.set("move_speed", 4.0)
	def.set("stop_distance_m", 1.0)
	def.set("turn_speed_rad", 6.0)
	def.set("aggro_radius_m", 18.0)
	def.set("deaggro_radius_m", 26.0)
	def.set("attack_range_m", 2.5)
	def.set("attack_damage", 3)
	def.set("attack_tell_seconds", 0.6)
	def.set("attack_seconds", 0.1)
	def.set("attack_recovery_seconds", 0.1)
	def.set("vision_angle_deg", 360.0)
	def.set("requires_line_of_sight", true)
	def.set("alert_radius_m", 0.0)
	def.set("max_concurrent_attackers", 2)
	def.set("lunge_speed_m_s", 0.0)
	for key: String in overrides:
		def.set(key, overrides[key])
	return def


func _spawn_enemy(def: Resource, position: Vector3) -> Node3D:
	var enemy: CharacterBody3D = ENEMY_SCRIPT.new()
	enemy.name = "LungeTestEnemy%d" % _next_peer  # unique; not read as a peer id
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


## Drives the host state machine directly. `_physics_process` is host-only and deterministic in
## delta, so stepping it is both faster and more repeatable than sleeping.
func _step(enemy: Node3D, delta: float, times: int = 1) -> void:
	for _i: int in times:
		if not is_instance_valid(enemy) or not enemy.is_inside_tree():
			return
		enemy.call("_physics_process", delta)


func _flat_distance(a: Node3D, b: Node3D) -> float:
	var delta: Vector3 = a.global_position - b.global_position
	return Vector2(delta.x, delta.z).length()


func _cleanup(nodes: Array) -> void:
	for node: Variant in nodes:
		if node is Node and is_instance_valid(node):
			(node as Node).queue_free()


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
