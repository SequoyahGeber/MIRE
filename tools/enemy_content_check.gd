extends SceneTree

## Focused offline proof for task 5.2 — the three new `content/enemies/*.tres` kinds (`strider`,
## `tusker`, `broodcaller`) each read as a genuinely different fight, not just different numbers on
## the same fight. Every claim is proven BEHAVIOURALLY against the real, loaded `.tres` (fetched
## through `EnemyWorld.get_def()`, same as `enemy_check.gd`'s crawler) side by side with the shipped
## `crawler` baseline under an IDENTICAL test, never by reading the stat block alone:
##
## - `strider` — `move_speed` above the player's own `sprint_speed` (4.0). A continuously retreating
##   player still gets caught; the baseline crawler (below sprint speed) falls further behind under
##   the same retreat.
## - `tusker` — `attack_range_m` big enough that a distance which leaves the baseline crawler still
##   chasing is already inside the tusker's own telegraph.
## - `broodcaller` — `alert_radius_m`/`max_concurrent_attackers` both raised well past the baseline's
##   defaults, so a packmate too far to be woken by a crawler wakes instantly next to a broodcaller,
##   and a target that caps a crawler pack at 2 simultaneous attackers does not cap a brood at 5.
##
## What this task's own SPECS.md `## 5.2` block found NOT provable from any field: the hit always
## resolves at the END of the tell against the target's THEN-current position, and the enemy is fully
## stationary for the whole TELL/ATTACK/RECOVER span (`Enemy._tick_attack()`), so any nonzero player
## movement during a tell beats it regardless of `attack_range_m` — filed as F-235, not tested here
## because there is nothing here that would pass.
##
## Scenarios build `Enemy` nodes directly against the REAL loaded defs (no model, no EnemyWorld spawn
## path — `enemy_check.gd` already proves that path end to end), spaced 500 m apart on X so no
## scenario's aggro/alert/attack-slot math can see another's. Timings are driven by stepping
## `_physics_process` directly, never by sleeping — see `enemy_check.gd`'s header for why.

const ENEMY_SCRIPT := preload("res://systems/enemies/enemy.gd")

## `entities/player/player_controller.gd`'s own `sprint_speed` default, copied rather than shared —
## this is a test harness, not a gameplay consumer, and the two must not drift silently against each
## other; if the real default ever moves, this constant needs a deliberate look, not an automatic one.
const PLAYER_SPRINT_SPEED_MPS: float = 6.0

## Driving `_physics_process(delta)` directly (see `enemy_check.gd`'s header) makes `delta` itself a
## no-op for movement: `CharacterBody3D.move_and_slide()` reads the ENGINE's own physics delta, not
## the value passed to the function it's called from, so an `Enemy` stepped this way moves by
## `move_speed * (a fixed, engine-chosen delta)` every call regardless of what `delta` this script
## hands it. That fixed delta is consistent across every `Enemy` (confirmed empirically: two kinds'
## measured per-call displacement divided by their own `move_speed` agree to four decimal places), so
## comparing two ENEMIES' speeds by stepping both this way is still valid — but a bare `Node3D` player
## moved by hand at a literal `speed * delta` is on a different clock and the comparison is not
## apples to apples. `_measure_effective_step_seconds()` below calibrates a player's retreat against
## that same fixed delta instead of assuming one.

var failures: int = 0
var _next_peer: int = 400


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

	var crawler_def: Resource = world.call("get_def", &"crawler")
	check(crawler_def != null, "the crawler baseline is registered")

	var new_ids: Array[StringName] = [&"strider", &"tusker", &"broodcaller"]
	var defs: Dictionary = {}
	for id: StringName in new_ids:
		check(bool(world.call("has_def", id)), "%s is registered" % id)
		var def: Resource = world.call("get_def", id)
		defs[id] = def
		check(def != null and (def.call("validation_errors") as PackedStringArray).is_empty(),
			"%s's authored definition validates" % id)

	if crawler_def == null or defs.size() < new_ids.size():
		finish()
		return

	await _check_speed_denies_kiting(crawler_def, defs[&"strider"])
	await process_frame
	await _check_reach_changes_safe_distance(crawler_def, defs[&"tusker"])
	await process_frame
	await _check_pack_pressure(crawler_def, defs[&"broodcaller"])

	print("ENEMY_CONTENT_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


# ── strider: closes distance a below-sprint kind cannot ────────────────────────────────────────────


func _check_speed_denies_kiting(crawler_def: Resource, strider_def: Resource) -> void:
	check(float(strider_def.get("move_speed")) > PLAYER_SPRINT_SPEED_MPS,
		"sanity: the strider's move_speed really does exceed player sprint speed")
	check(float(crawler_def.get("move_speed")) < PLAYER_SPRINT_SPEED_MPS,
		"sanity: the baseline crawler's move_speed really is below player sprint speed")

	var origin_crawler := Vector3(0.0, 0.0, 0.0)
	var origin_strider := Vector3(500.0, 0.0, 0.0)
	var start_distance := 8.0

	# Calibrate the player's per-call retreat distance against the SAME fixed engine delta the
	# enemies themselves move on (see the header comment on `PLAYER_SPRINT_SPEED_MPS`), using the
	# crawler def as the reference — any def would do, since the delta is the same for all of them.
	var effective_step_seconds: float = _measure_effective_step_seconds(crawler_def)
	var retreat_step_m: float = PLAYER_SPRINT_SPEED_MPS * effective_step_seconds

	var crawler: Node3D = _spawn_enemy(crawler_def, origin_crawler)
	var crawler_player: Node3D = _spawn_player(origin_crawler + Vector3(0.0, 0.0, -start_distance))
	var strider: Node3D = _spawn_enemy(strider_def, origin_strider)
	var strider_player: Node3D = _spawn_player(origin_strider + Vector3(0.0, 0.0, -start_distance))

	_step(crawler, 0.1)
	_step(strider, 0.1)
	check(int(crawler.get("state")) == 1 and int(strider.get("state")) == 1,
		"both kinds acquire their own player and give chase")

	# A continuously retreating player, same script against both kinds, one call per enemy per loop —
	# 60 calls so the (deliberately small, per-call) speed difference accumulates to a clear margin.
	for _i: int in 60:
		_retreat_by(crawler_player, crawler, retreat_step_m)
		_step(crawler, 0.1)
		_retreat_by(strider_player, strider, retreat_step_m)
		_step(strider, 0.1)

	check(int(crawler.get("state")) == 1 and int(strider.get("state")) == 1,
		"neither ever closed to its own attack range — this measured pursuit, not a frozen telegraph")
	var crawler_final: float = _flat_distance(crawler, crawler_player)
	var strider_final: float = _flat_distance(strider, strider_player)
	check(crawler_final > start_distance,
		"the baseline crawler falls further behind a continuously retreating player (%.2f m -> %.2f m)"
			% [start_distance, crawler_final])
	check(strider_final < start_distance,
		"the strider closes the gap on the SAME retreating player despite it (%.2f m -> %.2f m)"
			% [start_distance, strider_final])

	_cleanup([crawler, crawler_player, strider, strider_player])


# ── tusker: a distance safe against the baseline is already inside its own reach ───────────────────


func _check_reach_changes_safe_distance(crawler_def: Resource, tusker_def: Resource) -> void:
	var test_distance := 2.5
	check(test_distance > float(crawler_def.get("attack_range_m")),
		"sanity: the test distance is outside the baseline crawler's own reach")
	check(test_distance < float(tusker_def.get("attack_range_m")),
		"sanity: the same test distance is inside the tusker's own reach")

	var origin_crawler := Vector3(1000.0, 0.0, 0.0)
	var origin_tusker := Vector3(1500.0, 0.0, 0.0)

	var crawler: Node3D = _spawn_enemy(crawler_def, origin_crawler)
	var crawler_player: Node3D = _spawn_player(origin_crawler + Vector3(0.0, 0.0, -test_distance))
	var tusker: Node3D = _spawn_enemy(tusker_def, origin_tusker)
	var tusker_player: Node3D = _spawn_player(origin_tusker + Vector3(0.0, 0.0, -test_distance))

	_step(crawler, 0.1)
	_step(tusker, 0.1)
	check(int(crawler.get("state")) == 1,
		"at 2.5 m the baseline crawler is still chasing, outside its own reach")
	check(int(tusker.get("state")) == 2,
		"the identical 2.5 m distance is already inside the tusker's telegraph")

	check(float(tusker_def.get("attack_recovery_seconds"))
			>= float(crawler_def.get("attack_recovery_seconds")) * 2.0,
		"the tusker's punish window after a swing is at least double the baseline's")

	_cleanup([crawler, crawler_player, tusker, tusker_player])


# ── broodcaller: pack pressure past the baseline's own defaults ────────────────────────────────────


func _check_pack_pressure(crawler_def: Resource, broodcaller_def: Resource) -> void:
	await _check_alert_range(crawler_def, broodcaller_def)
	await process_frame
	await _check_attacker_cap(crawler_def, broodcaller_def)


func _check_alert_range(crawler_def: Resource, broodcaller_def: Resource) -> void:
	var packmate_distance := 15.0
	check(packmate_distance > float(crawler_def.get("alert_radius_m")),
		"sanity: 15 m is beyond the baseline crawler's own alert_radius_m")
	check(packmate_distance < float(broodcaller_def.get("alert_radius_m")),
		"sanity: the same 15 m is inside the broodcaller's alert_radius_m")

	var origin_crawler := Vector3(2000.0, 0.0, 0.0)
	var origin_brood := Vector3(2500.0, 0.0, 0.0)

	var crawler_spotter: Node3D = _spawn_enemy(crawler_def, origin_crawler)
	var crawler_packmate: Node3D = _spawn_enemy(
		crawler_def, origin_crawler + Vector3(packmate_distance, 0.0, 0.0)
	)
	var crawler_player: Node3D = _spawn_player(origin_crawler + Vector3(0.0, 0.0, -8.0))

	var brood_spotter: Node3D = _spawn_enemy(broodcaller_def, origin_brood)
	var brood_packmate: Node3D = _spawn_enemy(
		broodcaller_def, origin_brood + Vector3(packmate_distance, 0.0, 0.0)
	)
	var brood_player: Node3D = _spawn_player(origin_brood + Vector3(0.0, 0.0, -8.0))

	check(int(crawler_packmate.call("target_peer")) == 0
			and int(brood_packmate.call("target_peer")) == 0,
		"both packmates start with no target")

	_step(crawler_spotter, 0.1)
	_step(brood_spotter, 0.1)
	check(int(crawler_spotter.get("state")) == 1 and int(brood_spotter.get("state")) == 1,
		"both spotters acquire their own player on the same tick")

	check(int(crawler_packmate.call("target_peer")) == 0,
		"15 m is beyond the baseline crawler's alert_radius_m — its packmate is never woken")
	check(int(brood_packmate.call("target_peer")) == _peer_id(brood_player),
		"the identical 15 m distance is inside the broodcaller's own alert_radius_m — woken same tick")

	_cleanup([crawler_spotter, crawler_packmate, crawler_player,
		brood_spotter, brood_packmate, brood_player])


func _check_attacker_cap(crawler_def: Resource, broodcaller_def: Resource) -> void:
	# Six points on a ring at ~1.7 m, comfortably inside both defs' default 2.0 m attack_range_m —
	# enough attackers to exceed even the broodcaller's raised cap by one, so the holdout is proven
	# too, not just the commit count.
	var ring: Array[Vector3] = [
		Vector3(0.0, 0.0, -1.7), Vector3(1.5, 0.0, -0.8), Vector3(-1.5, 0.0, -0.8),
		Vector3(1.5, 0.0, 0.8), Vector3(-1.5, 0.0, 0.8), Vector3(0.0, 0.0, 1.7),
	]

	var origin_crawler := Vector3(3000.0, 0.0, 0.0)
	var crawler_player: Node3D = _spawn_player(origin_crawler)
	var crawler_attackers: Array[Node3D] = []
	for offset: Vector3 in ring:
		crawler_attackers.append(_spawn_enemy(crawler_def, origin_crawler + offset))
	for enemy: Node3D in crawler_attackers:
		_step(enemy, 0.1)
	var crawler_telling: int = 0
	for enemy: Node3D in crawler_attackers:
		if int(enemy.get("state")) in [2, 3]:
			crawler_telling += 1
	check(crawler_telling == int(crawler_def.get("max_concurrent_attackers")),
		"the baseline crawler pack commits exactly its own max_concurrent_attackers (%d of 6)"
			% int(crawler_def.get("max_concurrent_attackers")))

	var origin_brood := Vector3(3500.0, 0.0, 0.0)
	var brood_player: Node3D = _spawn_player(origin_brood)
	var brood_attackers: Array[Node3D] = []
	for offset: Vector3 in ring:
		brood_attackers.append(_spawn_enemy(broodcaller_def, origin_brood + offset))
	for enemy: Node3D in brood_attackers:
		_step(enemy, 0.1)
	var brood_telling: int = 0
	for enemy: Node3D in brood_attackers:
		if int(enemy.get("state")) in [2, 3]:
			brood_telling += 1
	check(brood_telling == int(broodcaller_def.get("max_concurrent_attackers")),
		"the same 6-strong brood commits its own, higher max_concurrent_attackers (%d of 6)"
			% int(broodcaller_def.get("max_concurrent_attackers")))
	check(brood_telling > crawler_telling,
		"planting and fighting one broodcaller draws more simultaneous attackers than one crawler")

	_cleanup(crawler_attackers + [crawler_player] + brood_attackers + [brood_player])


# ── Construction ──────────────────────────────────────────────────────────────────────────────────


func _spawn_enemy(def: Resource, position: Vector3) -> Node3D:
	var enemy: CharacterBody3D = ENEMY_SCRIPT.new()
	enemy.name = "ContentTestEnemy%d" % _next_peer  # unique; not read as a peer id
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


## Moves `player` directly away from `enemy`'s current position by a fixed `distance_m`, flat on the
## XZ plane — simulates a player holding sprint straight backward, the simplest possible kiting
## attempt. Takes a distance, not a speed, because this harness's own `delta` does not drive movement
## (see the header comment on `PLAYER_SPRINT_SPEED_MPS`) — callers derive the distance from
## `_measure_effective_step_seconds()` instead of assuming one.
func _retreat_by(player: Node3D, enemy: Node3D, distance_m: float) -> void:
	var away: Vector3 = player.global_position - enemy.global_position
	away.y = 0.0
	if away.length_squared() < 0.0001:
		return
	player.global_position += away.normalized() * distance_m


## How far one `_physics_process()` call actually moves an `Enemy` per unit of its own `move_speed` —
## the engine's own fixed physics delta, invisible to and unaffected by the `delta` this script passes
## in (see the header comment on `PLAYER_SPRINT_SPEED_MPS`). Spawns a throwaway probe of
## `reference_def`, lets its first call handle acquisition (which also moves it, so that call is not
## measured), then measures the SECOND call's pure-movement displacement against a stationary target
## far enough away that it never reaches attack range.
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


## Drives the host state machine directly — see `enemy_check.gd`'s header for why.
func _step(enemy: Node3D, delta: float, times: int = 1) -> void:
	for _i: int in times:
		if not is_instance_valid(enemy) or not enemy.is_inside_tree():
			return
		enemy.call("_physics_process", delta)


func finish() -> void:
	quit(0 if failures == 0 else 1)
