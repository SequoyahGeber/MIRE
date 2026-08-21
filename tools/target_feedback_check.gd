extends SceneTree

## Offline proof for F-433 — the two client-local combat readouts:
##
##   * `ui/hud/target_health_hud.gd` — the overhead enemy health bar, and the selection rules that
##     stop a screen of idle husks from each carrying one;
##   * `ui/hud/damage_numbers.gd` — the floating "-5", including the deliberate "0" a wrong-tool
##     bounce reports and the local-peer filter that keeps five teammates' numbers off your screen.
##
## Both are pure presentation, so there is nothing to assert about state — the checks read the
## computed LAYOUT (`tracked_bars()`, `active_indicators()`) rather than pixels, which is the same
## thing `tools/focus_prompt_check.gd` does with its `Kind` enum: assert the decision, not the paint.
##
## Enemies are frozen (`set_physics_process(false)`) the moment they spawn. Nothing here tests AI, and
## an enemy falling under gravity between the refresh and the assertion would make every projected
## position a moving target.

const ENEMY_WORLD_PATH := ^"/root/EnemyWorld"
const HUD_PATH := ^"/root/TargetHealthHud"
const NUMBERS_PATH := ^"/root/DamageNumbers"
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"

var failures: int = 0
var _camera: Camera3D
var _hud: Node
var _numbers: Node
var _world: Node
var _spawned: Array[Node3D] = []
var _next_x: float = 0.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	_world = root.get_node_or_null(ENEMY_WORLD_PATH)
	_hud = root.get_node_or_null(HUD_PATH)
	_numbers = root.get_node_or_null(NUMBERS_PATH)
	check(_world != null, "EnemyWorld autoload exists")
	check(_hud != null, "TargetHealthHud is registered as an autoload")
	check(_numbers != null, "DamageNumbers is registered as an autoload")
	if _world == null or _hud == null or _numbers == null:
		finish()
		return

	_camera = Camera3D.new()
	_camera.name = "CheckCamera"
	root.add_child(_camera)
	_camera.global_position = Vector3.ZERO
	_camera.make_current()
	await process_frame
	check(root.get_viewport().get_camera_3d() == _camera, "the check owns the active camera")

	await _check_selection_rules()
	await _check_bar_geometry()
	await _check_blocking_ui()
	await _check_bar_cap()
	await _check_damage_numbers()

	print("TARGET_FEEDBACK_CHECK failures=%d" % failures)
	finish()


# ── Which enemies get a bar ──────────────────────────────────────────────────────────────────────


func _check_selection_rules() -> void:
	_clear_enemies()

	# Each scenario gets its own lane on X so no two enemies overlap on screen and every bar can be
	# attributed to exactly one node.
	var near_idle: Node3D = _spawn(6.0)
	var far_idle: Node3D = _spawn(26.0)
	var far_damaged: Node3D = _spawn(26.0)
	var far_chasing: Node3D = _spawn(26.0)
	var out_of_range: Node3D = _spawn(60.0)
	var dead: Node3D = _spawn(8.0)
	var boss_like: Node3D = _spawn(8.0)

	far_damaged.set(&"health", maxi(int(far_damaged.get(&"health")) / 2, 1))
	far_chasing.set(&"state", 1)
	dead.set(&"state", 5)
	boss_like.add_to_group(&"bosses")

	await process_frame
	_hud.call(&"refresh_now")
	var shown: Array = _bar_nodes()

	check(shown.has(near_idle),
		"an untouched idle enemy inside ALWAYS_RANGE_M shows a bar — you are about to swing at it")
	check(not shown.has(far_idle),
		"an untouched idle enemy far away shows none, so a wood full of husks is not a wall of bars")
	check(shown.has(far_damaged), "a damaged enemy shows a bar at any range inside MAX_RANGE_M")
	check(shown.has(far_chasing), "an enemy that has noticed you shows a bar even at full health")
	check(not shown.has(out_of_range), "nothing past MAX_RANGE_M shows a bar")
	check(not shown.has(dead), "a corpse shows no bar")
	check(not shown.has(boss_like),
		"a boss is skipped — task 5.5's top-centre bar already reads its health")

	var fraction: float = _fraction_for(far_damaged)
	var expected: float = float(int(far_damaged.get(&"health"))) / float(
		int((far_damaged.get(&"definition") as Resource).get(&"max_health"))
	)
	check(is_equal_approx(fraction, expected),
		"the fill is health/max_health (%.2f)" % fraction)


func _check_bar_geometry() -> void:
	_clear_enemies()
	var near_enemy: Node3D = _spawn(6.0)
	var far_enemy: Node3D = _spawn(30.0)
	# Damaged, so the far one qualifies on rule 1 rather than on proximity — this scenario is about
	# geometry, not about selection.
	far_enemy.set(&"health", maxi(int(far_enemy.get(&"health")) - 1, 1))
	await process_frame
	_hud.call(&"refresh_now")

	var near_bar: Object = _bar_for(near_enemy)
	var far_bar: Object = _bar_for(far_enemy)
	check(near_bar != null and far_bar != null, "both test enemies are tracked")
	if near_bar == null or far_bar == null:
		return

	check(bool(near_bar.get("on_screen")), "a bar in front of the camera is on screen")
	var body_top: Vector2 = _camera.unproject_position(near_enemy.global_position)
	var bar_at: Vector2 = near_bar.get("screen_position")
	# Screen Y grows downward, so "above the head" is a SMALLER y than the enemy's own origin.
	check(bar_at.y < body_top.y, "the bar hovers above the enemy rather than sitting on it")
	check(absf(bar_at.x - body_top.x) < 1.0, "and is centred over it")
	check(float(far_bar.get("width")) < float(near_bar.get("width")),
		"a distant bar is drawn narrower, so it reads as belonging to the thing under it")
	check(float(far_bar.get("alpha")) < float(near_bar.get("alpha")),
		"and fainter past FADE_START_M")

	# Behind the camera is the case that produces garbage coordinates if it is not caught.
	near_enemy.global_position = Vector3(near_enemy.global_position.x, 0.0, 6.0)
	_hud.call(&"refresh_now")
	var behind: Object = _bar_for(near_enemy)
	check(behind == null or not bool(behind.get("on_screen")),
		"an enemy behind the camera draws nothing")


func _check_blocking_ui() -> void:
	_clear_enemies()
	_spawn(6.0)
	await process_frame
	_hud.call(&"refresh_now")
	check(not (_hud.call(&"tracked_bars") as Array).is_empty(), "a bar is showing to begin with")

	var panel := Node.new()
	panel.add_to_group(BLOCKING_UI_GROUP)
	root.add_child(panel)
	_hud.call(&"refresh_now")
	check((_hud.call(&"tracked_bars") as Array).is_empty(),
		"every bar goes away while a cursor-owning panel is open (D-032's interlock in spirit)")
	panel.free()
	_hud.call(&"refresh_now")
	check(not (_hud.call(&"tracked_bars") as Array).is_empty(), "and comes back when it closes")


func _check_bar_cap() -> void:
	_clear_enemies()
	var cap: int = int(_hud.get(&"MAX_BARS"))
	for index: int in cap + 4:
		var enemy: Node3D = _spawn(6.0 + float(index) * 0.4)
		# All damaged: every one of them qualifies, so the only thing left deciding is the cap.
		enemy.set(&"health", maxi(int(enemy.get(&"health")) - 1, 1))
	await process_frame
	_hud.call(&"refresh_now")
	var bars: Array = _hud.call(&"tracked_bars")
	check(bars.size() == cap, "at most MAX_BARS (%d) bars are drawn, got %d" % [cap, bars.size()])

	var distances: Array[float] = []
	for bar: Object in bars:
		distances.append(float(bar.get("distance")))
	var nearest_kept: bool = true
	for index: int in distances.size() - 1:
		if distances[index] > distances[index + 1]:
			nearest_kept = false
	check(nearest_kept, "and they are the nearest ones, so the cap never hides what is on top of you")
	_clear_enemies()


# ── Damage numbers ───────────────────────────────────────────────────────────────────────────────


func _check_damage_numbers() -> void:
	_numbers.call(&"active_indicators").clear()

	_numbers.call(&"show_damage", Vector3(0.0, 0.0, -6.0), 5)
	var active: Array = _numbers.call(&"active_indicators")
	check(active.size() == 1, "one landed hit spawns one indicator")
	if active.is_empty():
		return
	check(String(active[0].get("text")) == "-5", "it reads the damage the host applied, signed")
	check(bool(active[0].get("on_screen")), "and is projected in front of the camera")

	_numbers.call(&"show_damage", Vector3(0.0, 0.0, -6.0), 0)
	active = _numbers.call(&"active_indicators")
	check(String(active[1].get("text")) == "0",
		"a hit that applied nothing still reports — the wrong-tool thunk is the tool hint")
	check(
		Color(active[1].get("colour")) != Color(active[0].get("colour")),
		"and is drawn in its own muted colour rather than as damage"
	)
	check(
		not is_equal_approx(float(active[0].get("spread")), float(active[1].get("spread"))),
		"two fast hits on one target are spread apart rather than stacked"
	)

	# Lifetime. Advanced directly rather than slept out: the motion is a pure function of elapsed.
	var lifetime: float = float(_numbers.get(&"LIFETIME_SEC"))
	_numbers.call(&"_advance", lifetime * 0.8)
	active = _numbers.call(&"active_indicators")
	check(active.size() == 2, "an indicator is still alive four-fifths of the way through")
	check(float(active[0].get("alpha")) < 1.0, "and has begun fading")
	_numbers.call(&"_advance", lifetime)
	check((_numbers.call(&"active_indicators") as Array).is_empty(),
		"and is gone once its lifetime is spent")

	# The local-peer filter, driven through the real signal.
	var combat: Node = root.get_node_or_null(^"/root/CombatService")
	check(combat != null, "CombatService is available to emit through")
	if combat == null:
		return
	combat.emit_signal(&"attack_landed", 1, Vector3(0.0, 0.0, -6.0), 7, &"crawler")
	check((_numbers.call(&"active_indicators") as Array).size() == 1,
		"the local peer's own hit draws a number")
	combat.emit_signal(&"attack_landed", 4242, Vector3(0.0, 0.0, -6.0), 7, &"crawler")
	check((_numbers.call(&"active_indicators") as Array).size() == 1,
		"a teammate's hit on the same enemy does not, so a six-player fight is still readable")

	var ranged: Node = root.get_node_or_null(^"/root/RangedCombatService")
	check(ranged != null, "RangedCombatService is available to emit through")
	if ranged != null:
		ranged.emit_signal(&"shot_landed", 1, Vector3(0.0, 0.0, -6.0), 3, &"crawler")
		var numbers: Array = _numbers.call(&"active_indicators")
		check(String(numbers[numbers.size() - 1].get("text")) == "-3",
			"an arrow reports through the same path as a swing")

	var cap: int = int(_numbers.get(&"MAX_ACTIVE"))
	for index: int in cap + 6:
		_numbers.call(&"show_damage", Vector3(0.0, 0.0, -6.0), index + 1)
	check((_numbers.call(&"active_indicators") as Array).size() == cap,
		"the active set is capped at MAX_ACTIVE (%d)" % cap)


# ── Helpers ──────────────────────────────────────────────────────────────────────────────────────


## A frozen crawler `distance` metres down the camera's -Z, on its own lane in X.
func _spawn(distance: float) -> Node3D:
	var enemy: Node3D = _world.call("host_spawn", &"crawler", Vector3(_next_x, 0.0, -distance))
	_next_x += 1.2
	if enemy == null:
		return null
	enemy.set_physics_process(false)
	_spawned.append(enemy)
	return enemy


func _clear_enemies() -> void:
	for enemy: Node3D in _spawned:
		if is_instance_valid(enemy):
			enemy.get_parent().remove_child(enemy)
			enemy.queue_free()
	_spawned.clear()
	_next_x = 0.0
	if _hud != null:
		_hud.call(&"refresh_now")


func _bar_nodes() -> Array:
	var nodes: Array = []
	for bar: Object in _hud.call(&"tracked_bars"):
		nodes.append(bar.get("node"))
	return nodes


func _bar_for(enemy: Node3D) -> Object:
	for bar: Object in _hud.call(&"tracked_bars"):
		if bar.get("node") == enemy:
			return bar
	return null


func _fraction_for(enemy: Node3D) -> float:
	var bar: Object = _bar_for(enemy)
	return float(bar.get("fraction")) if bar != null else -1.0


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
