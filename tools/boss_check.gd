extends SceneTree

## Focused offline proof for task 5.5 — the boss framework layered on `Enemy`'s existing
## IDLE -> CHASE -> TELL -> ATTACK -> RECOVER machine (2.10/5.1): phases (`BossDef.phases`, health
## thresholds), the arena leash (`BossDef.arena_radius_m` / `BossPhaseDef.seals_arena`), per-phase
## telegraphed moves (`BossPhaseDef.moves`), the replicated `phase`/`move_index` seam a health bar
## reads, and the `EventBus.boss_engaged`/`boss_phase_changed`/`boss_defeated` stinger hooks.
##
## Every scenario builds its own `Boss` node directly against a synthetic `BossDef` (no model, no
## content .tres — task 5.5 ships no worked-example boss, see `boss_def.gd`'s own header) except
## `_check_spawn_polymorphism()`, which goes through the real `EnemyWorld` autoload to prove the
## spawn-time script choice this task added to `enemy_world.gd`. Scenarios are spaced 500 m apart on
## X, same convention `enemy_ai_check.gd` uses, so no scenario's aggro/arena math can see another's.
##
## Timings are driven by stepping `_physics_process` directly, never by sleeping (enemy_check.gd's
## own convention, repeated here).

const BOSS_SCRIPT := preload("res://systems/enemies/boss.gd")
const BOSS_DEF := preload("res://systems/enemies/boss_def.gd")
const BOSS_PHASE_DEF := preload("res://systems/enemies/boss_phase_def.gd")
const BOSS_MOVE_DEF := preload("res://systems/enemies/boss_move_def.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

var failures: int = 0
var _next_peer: int = 9000


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	_check_content_validation()
	await _check_engage_and_phases()
	await process_frame
	await _check_arena_leash()
	await process_frame
	await _check_telegraph_moves()
	await process_frame
	await _check_fallback_no_moves()
	await process_frame
	await _check_spawn_polymorphism()
	await process_frame
	await _check_music_director()

	print("BOSS_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


# ── Content: validation + the phase-selection rule ──────────────────────────────────────────────


func _check_content_validation() -> void:
	var bad_move: Resource = BOSS_MOVE_DEF.new()
	bad_move.set("id", &"")
	bad_move.set("damage", 0)
	bad_move.set("range_m", -1.0)
	check(bad_move.call("validation_errors").size() == 3, "a move with no id/damage/range fails all three")

	var good_move: Resource = _make_move(&"slam", 10, 3.0)
	check(good_move.call("validation_errors").is_empty(), "a fully-authored move validates clean")

	var def: Resource = _make_boss_def([
		_make_phase(1.0, [good_move]),
		_make_phase(1.2, []),  # out of order — higher threshold AFTER a lower one
	])
	var errors: PackedStringArray = def.call("validation_errors")
	check(not errors.is_empty(), "phases authored out of descending threshold order fail validation")

	var ordered: Resource = _make_boss_def([_make_phase(1.0, [good_move]), _make_phase(0.5, [])])
	check(ordered.call("validation_errors").is_empty(), "descending-order phases validate clean")

	check(int(ordered.call("phase_for_health_fraction", 1.0)) == 0, "full health resolves to phase 0")
	check(int(ordered.call("phase_for_health_fraction", 0.7)) == 0,
		"a fraction above the second threshold stays in phase 0")
	check(int(ordered.call("phase_for_health_fraction", 0.5)) == 1,
		"a fraction at the second threshold resolves to phase 1")
	check(int(ordered.call("phase_for_health_fraction", 0.1)) == 1,
		"a fraction below every threshold still resolves to the LOWEST phase, not past the array")


# ── Engagement, phase transitions, and the three EventBus stinger hooks ─────────────────────────


func _check_engage_and_phases() -> void:
	var origin := Vector3(0.0, 0.0, 0.0)
	var def: Resource = _make_boss_def([
		_make_phase(1.0, []), _make_phase(0.6, []), _make_phase(0.3, []),
	])
	def.set("max_health", 100)
	var boss: Node3D = _spawn_boss(def, origin)
	var player: Node3D = _spawn_player(origin + Vector3(0.0, 0.0, -8.0))

	var engaged: Array = []
	var phase_changes: Array = []
	var defeats: Array = []
	var on_engaged := func(boss_id: StringName, position: Vector3) -> void:
		engaged.append([boss_id, position])
	var on_phase := func(boss_id: StringName, previous: int, new_phase: int, position: Vector3) -> void:
		phase_changes.append([boss_id, previous, new_phase, position])
	var on_defeated := func(boss_id: StringName, position: Vector3) -> void:
		defeats.append([boss_id, position])
	EVENT_BUS.subscribe_boss_engaged(on_engaged)
	EVENT_BUS.subscribe_boss_phase_changed(on_phase)
	EVENT_BUS.subscribe_boss_defeated(on_defeated)

	check(int(boss.get("phase")) == -1, "a boss starts dormant (phase -1)")
	check(not bool(boss.call("is_engaged")), "and reports itself not engaged")

	_step(boss, 0.1)  # acquires the player
	check(int(boss.get("phase")) == 0, "acquiring a target engages phase 0")
	check(bool(boss.call("is_engaged")), "is_engaged() flips true the same tick")
	check(engaged.size() == 1, "boss_engaged fired exactly once")
	check(phase_changes.is_empty(), "the first transition is boss_engaged, never boss_phase_changed")
	check(is_equal_approx(float(boss.call("health_fraction")), 1.0), "health_fraction starts at 1.0")

	boss.call("host_apply_damage", 45, _peer_id(player))  # 55/100 -> below the 0.6 threshold
	check(int(boss.get("phase")) == 1, "dropping below the second threshold advances to phase 1")
	check(phase_changes.size() == 1, "boss_phase_changed fired once")
	check(int(phase_changes[0][1]) == 0 and int(phase_changes[0][2]) == 1,
		"carrying the correct previous/new phase")

	boss.call("host_apply_damage", 100, _peer_id(player))  # lethal
	check(bool(boss.call("is_alive")) == false, "a lethal hit kills the boss")
	check(defeats.size() == 1, "boss_defeated fired exactly once")
	check(not bool(boss.call("is_engaged")), "a dead boss no longer reports itself engaged")

	# A second lethal-shaped call must not double-fire anything — host_apply_damage already refuses
	# once state is DEAD (Enemy's own rule), so this is really proving that refusal still holds here.
	boss.call("host_apply_damage", 10, _peer_id(player))
	check(defeats.size() == 1, "no further damage after death re-fires boss_defeated")

	EVENT_BUS.unsubscribe_boss_engaged(on_engaged)
	EVENT_BUS.unsubscribe_boss_phase_changed(on_phase)
	EVENT_BUS.unsubscribe_boss_defeated(on_defeated)
	_cleanup([boss, player])


# ── Arena leash ───────────────────────────────────────────────────────────────────────────────────


func _check_arena_leash() -> void:
	var origin := Vector3(500.0, 0.0, 0.0)

	# Acquisition: a player inside aggro_radius_m but OUTSIDE arena_radius_m is never taken.
	var far_def: Resource = _make_boss_def([_make_phase(1.0, [])])
	far_def.set("arena_radius_m", 5.0)
	var far_boss: Node3D = _spawn_boss(far_def, origin)
	var far_player: Node3D = _spawn_player(origin + Vector3(0.0, 0.0, -12.0))  # 12 m: inside aggro, outside arena
	_step(far_boss, 0.1)
	check(int(far_boss.get("phase")) == -1, "a player outside the arena radius is never acquired")
	_cleanup([far_boss, far_player])

	# Retention: a target acquired inside the arena is dropped once it leaves — UNLESS the active
	# phase seals the arena, in which case it is held regardless of distance.
	var leash_def: Resource = _make_boss_def([_make_phase(1.0, [])])
	leash_def.set("arena_radius_m", 10.0)
	leash_def.set("deaggro_radius_m", 200.0)  # wide enough that only the ARENA check can drop this
	leash_def.set("aggro_radius_m", 200.0)
	var leash_boss: Node3D = _spawn_boss(leash_def, origin + Vector3(0.0, 0.0, 100.0))
	var mobile_player: Node3D = _spawn_player(leash_boss.global_position + Vector3(0.0, 0.0, -5.0))
	_step(leash_boss, 0.1)
	check(int(leash_boss.get("phase")) == 0, "a player inside the arena radius is acquired")

	mobile_player.global_position = leash_boss.global_position + Vector3(0.0, 0.0, -50.0)
	_step(leash_boss, 0.1)
	check(int(leash_boss.call("target_peer")) == 0,
		"a held target that leaves the arena radius is dropped, unsealed")
	_cleanup([leash_boss, mobile_player])

	var sealed_def: Resource = _make_boss_def([_make_sealed_phase(1.0, [])])
	sealed_def.set("arena_radius_m", 10.0)
	sealed_def.set("deaggro_radius_m", 200.0)
	sealed_def.set("aggro_radius_m", 200.0)
	var sealed_boss: Node3D = _spawn_boss(sealed_def, origin + Vector3(0.0, 0.0, 200.0))
	var sealed_player: Node3D = _spawn_player(sealed_boss.global_position + Vector3(0.0, 0.0, -5.0))
	_step(sealed_boss, 0.1)
	check(int(sealed_boss.get("phase")) == 0, "sealed setup: the player is acquired inside the arena")
	sealed_player.global_position = sealed_boss.global_position + Vector3(0.0, 0.0, -50.0)
	_step(sealed_boss, 0.1)
	check(int(sealed_boss.call("target_peer")) == _peer_id(sealed_player),
		"a sealed phase holds its target even once it leaves the arena radius")
	_cleanup([sealed_boss, sealed_player])


# ── Telegraphs: per-phase weighted moves, own timings, own damage/range ─────────────────────────


func _check_telegraph_moves() -> void:
	var origin := Vector3(1000.0, 0.0, 0.0)
	var heavy: Resource = _make_move(&"heavy_slam", 40, 6.0, 1.0, 0.3, 1.5, 1.0)
	var quick: Resource = _make_move(&"quick_jab", 5, 2.0, 0.1, 0.1, 0.1, 9.0)
	var def: Resource = _make_boss_def([_make_phase(1.0, [heavy, quick])])
	var boss: Node3D = _spawn_boss(def, origin)

	# Weighted selection: quick_jab (weight 9) should dominate heavy_slam (weight 1) over many rolls,
	# deterministically — Boss._move_rng is seeded once at _ready() (MOVE_RNG_SEED), same convention
	# wave_spawner.gd's own roster-roll test relies on, and `boss` here is freshly spawned with no
	# prior draws, so the sequence below is reproducible without touching the RNG by hand.
	var moves: Array[BOSS_MOVE_DEF] = [heavy, quick]
	var quick_count: int = 0
	const SAMPLES: int = 400
	for _i: int in SAMPLES:
		if int(boss.call("_pick_move_index", moves)) == 1:
			quick_count += 1
	var quick_share: float = float(quick_count) / float(SAMPLES)
	check(quick_share > 0.8, "the 9:1-weighted move is picked far more often (%.2f observed)" % quick_share)

	# A real TELL -> ATTACK -> RECOVER cycle actually uses the CHOSEN move's own timings and damage,
	# not EnemyDef's flat fields. Force the pick deterministically by shrinking the pool to one move.
	var landed: Array = []
	var on_landed := func(_id: StringName, _peer: int, damage: int, _pos: Vector3) -> void:
		landed.append(damage)
	EVENT_BUS.subscribe_enemy_attack_landed(on_landed)

	var solo_def: Resource = _make_boss_def([_make_phase(1.0, [heavy])])
	var solo_boss: Node3D = _spawn_boss(solo_def, origin + Vector3(50.0, 0.0, 0.0))
	var target: Node3D = _spawn_player(solo_boss.global_position + Vector3(0.0, 0.0, -1.5))
	_step(solo_boss, 0.1)  # acquire + enter TELL (in range immediately)
	check(int(solo_boss.get("state")) == 2, "in range, the boss enters TELL")  # State.TELL == 2
	check(int(solo_boss.get("move_index")) == 0, "move_index names the chosen move for presentation")

	_step(solo_boss, float(heavy.get("tell_seconds")) + 0.01)
	check(int(solo_boss.get("state")) == 3, "the tell's own duration (not EnemyDef's) ends it")  # ATTACK
	check(landed.size() == 1 and int(landed[0]) == int(heavy.get("damage")),
		"the resolved hit carries the CHOSEN move's damage, not EnemyDef's")

	_step(solo_boss, float(heavy.get("attack_seconds")) + 0.01)
	check(int(solo_boss.get("state")) == 4, "the attack's own duration ends it into RECOVER")

	_step(solo_boss, float(heavy.get("recovery_seconds")) + 0.01)
	check(int(solo_boss.get("move_index")) == -1, "recovery ending clears move_index for the next pick")

	EVENT_BUS.unsubscribe_enemy_attack_landed(on_landed)
	_cleanup([boss, solo_boss, target])


# ── Fallback: an empty-moves phase behaves exactly like a plain Enemy's one fixed attack ────────


func _check_fallback_no_moves() -> void:
	var origin := Vector3(1500.0, 0.0, 0.0)
	var def: Resource = _make_boss_def([_make_phase(1.0, [])])  # no moves authored anywhere
	def.set("attack_damage", 7)
	def.set("attack_range_m", 2.0)
	def.set("attack_tell_seconds", 0.1)
	def.set("attack_seconds", 0.1)
	def.set("attack_recovery_seconds", 0.1)
	var boss: Node3D = _spawn_boss(def, origin)
	var target: Node3D = _spawn_player(origin + Vector3(0.0, 0.0, -1.5))

	var landed: Array = []
	var on_landed := func(_id: StringName, _peer: int, damage: int, _pos: Vector3) -> void:
		landed.append(damage)
	EVENT_BUS.subscribe_enemy_attack_landed(on_landed)

	_step(boss, 0.1)
	check(int(boss.get("state")) == 2, "with no moves authored, the boss still enters TELL")
	check(int(boss.get("move_index")) == -1, "move_index stays -1 — this is EnemyDef's own fixed attack")
	_step(boss, 0.2)
	check(landed.size() == 1 and int(landed[0]) == 7,
		"the fallback attack carries EnemyDef's own fixed damage")

	EVENT_BUS.unsubscribe_enemy_attack_landed(on_landed)
	_cleanup([boss, target])


# ── EnemyWorld spawns Boss (not plain Enemy) for a BossDef ──────────────────────────────────────


func _check_spawn_polymorphism() -> void:
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	check(world != null, "EnemyWorld autoload exists")
	if world == null:
		return

	var def: Resource = _make_boss_def([_make_phase(1.0, [])])
	def.set("id", &"boss_check_synthetic")
	var defs: Dictionary = world.get("defs")
	defs[&"boss_check_synthetic"] = def

	var spawned: Node3D = world.call("host_spawn", &"boss_check_synthetic", Vector3(2000.0, 0.0, 0.0))
	check(spawned != null, "EnemyWorld.host_spawn() accepts a BossDef")
	if spawned != null:
		check(spawned.get_script() == BOSS_SCRIPT,
			"…and instantiates Boss, not the plain Enemy script, for it")
		check(spawned.is_inside_tree(), "the spawned Boss is actually in the tree (real _ready() ran)")

	defs.erase(&"boss_check_synthetic")
	_cleanup([spawned])


# ── BossMusicDirector plays a stinger on all three EventBus hooks ───────────────────────────────


func _check_music_director() -> void:
	var director: Node = root.get_node_or_null(^"BossMusicDirector")
	check(director != null, "BossMusicDirector autoload exists")
	if director == null:
		return

	var players: Array = director.get("_players")
	check(players.size() >= 1, "the director built at least one AudioStreamPlayer")
	if players.is_empty():
		return

	# Earlier scenarios in this same run already engaged real Boss nodes, and BossMusicDirector — a
	# permanent autoload subscriber — reacted to every one of them. Stop whatever is already playing
	# so each assertion below proves ITS OWN emit started playback, not a leftover from earlier.
	for player: AudioStreamPlayer in players:
		player.stop()

	EVENT_BUS.emit_boss_engaged(&"check_boss", Vector3.ZERO)
	await process_frame
	check(_any_playing(players), "boss_engaged starts a stinger playing")

	for player: AudioStreamPlayer in players:
		player.stop()
	EVENT_BUS.emit_boss_phase_changed(&"check_boss", 0, 1, Vector3.ZERO)
	await process_frame
	check(_any_playing(players), "boss_phase_changed starts a stinger playing")

	for player: AudioStreamPlayer in players:
		player.stop()
	EVENT_BUS.emit_boss_defeated(&"check_boss", Vector3.ZERO)
	await process_frame
	check(_any_playing(players), "boss_defeated starts a stinger playing")

	for player: AudioStreamPlayer in players:
		player.stop()


func _any_playing(players: Array) -> bool:
	for player: AudioStreamPlayer in players:
		if player.playing:
			return true
	return false


# ── Construction ──────────────────────────────────────────────────────────────────────────────────


func _make_move(
	id: StringName, damage: int, range_m: float,
	tell_seconds: float = 0.4, attack_seconds: float = 0.4, recovery_seconds: float = 0.5,
	weight: float = 1.0
) -> Resource:
	var move: Resource = BOSS_MOVE_DEF.new()
	move.set("id", id)
	move.set("damage", damage)
	move.set("range_m", range_m)
	move.set("tell_seconds", tell_seconds)
	move.set("attack_seconds", attack_seconds)
	move.set("recovery_seconds", recovery_seconds)
	move.set("weight", weight)
	return move


func _make_phase(hp_threshold_fraction: float, moves: Array[Resource]) -> Resource:
	var phase: Resource = BOSS_PHASE_DEF.new()
	phase.set("hp_threshold_fraction", hp_threshold_fraction)
	var typed: Array[BOSS_MOVE_DEF] = []
	for move: Resource in moves:
		typed.append(move)
	phase.set("moves", typed)
	return phase


func _make_sealed_phase(hp_threshold_fraction: float, moves: Array[Resource]) -> Resource:
	var phase: Resource = _make_phase(hp_threshold_fraction, moves)
	phase.set("seals_arena", true)
	return phase


func _make_boss_def(phases: Array[Resource]) -> Resource:
	var def: Resource = BOSS_DEF.new()
	def.set("id", &"boss_test")
	def.set("max_health", 999)
	def.set("radius_m", 0.6)
	def.set("height_m", 1.2)
	def.set("move_speed", 4.0)
	def.set("stop_distance_m", 1.0)
	def.set("turn_speed_rad", 6.0)
	def.set("aggro_radius_m", 40.0)
	def.set("deaggro_radius_m", 60.0)
	def.set("attack_range_m", 3.0)
	def.set("attack_damage", 5)
	def.set("attack_tell_seconds", 0.1)
	def.set("attack_seconds", 0.1)
	def.set("attack_recovery_seconds", 0.1)
	def.set("vision_angle_deg", 360.0)
	def.set("requires_line_of_sight", false)
	def.set("alert_radius_m", 0.0)
	def.set("max_concurrent_attackers", 4)
	def.set("arena_radius_m", 40.0)
	var typed: Array[BOSS_PHASE_DEF] = []
	for phase: Resource in phases:
		typed.append(phase)
	def.set("phases", typed)
	return def


func _spawn_boss(def: Resource, position: Vector3) -> Node3D:
	var boss: CharacterBody3D = BOSS_SCRIPT.new()
	boss.name = "BossCheck%d" % _next_peer
	boss.set("definition", def)
	boss.position = position
	root.add_child(boss)
	return boss


func _spawn_player(position: Vector3) -> Node3D:
	var player := Node3D.new()
	player.name = str(_next_peer)
	_next_peer += 1
	player.add_to_group(&"players")
	root.add_child(player)
	player.global_position = position
	return player


func _peer_id(player: Node3D) -> int:
	return String(player.name).to_int()


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
func _step(node: Node3D, delta: float, times: int = 1) -> void:
	for _i: int in times:
		if not is_instance_valid(node) or not node.is_inside_tree():
			return
		node.call("_physics_process", delta)
