extends SceneTree

## Direct proof for task 5.9 (docs/SPECS.md §5.9): Cycle-aware pacing (`cycle_count_multiplier()`),
## composition weighting (`_roll_roster()`), on top of the player-count scaling and roster-unlock
## mechanics `tools/wave_spawner_check.gd` already covers — that check must stay untouched and green,
## it is this task's real regression bar (nothing before a Cycle ever advances should change).
##
##   .agent/bin/agent godot --script tools/wave_director_check.gd
##
## Drives the REGISTERED WaveSpawner/EnemyWorld autoloads (F-068's lesson — a private harness copy
## would test nothing real). `EventBus` is a static preload, not an autoload, so
## `EventBus.emit_cycle_advanced()` reaches every real subscriber directly, no signal wiring needed.

var failures: int = 0
var wave: Node
var world: Node
const EVENT_BUS := preload("res://core/events/event_bus.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return

	print("\n== cycle_count_multiplier() curve ==")
	check(is_equal_approx(float(wave.call(&"cycle_count_multiplier", 1)), 1.0),
		"Cycle 1 multiplier is exactly 1.0 (no pre-existing wave-size assertion may change)")
	check(is_equal_approx(float(wave.call(&"cycle_count_multiplier", 6)), 1.75),
		"Cycle 6 multiplier is 1.0 + 5 * 0.15 = 1.75")
	check(is_equal_approx(float(wave.call(&"cycle_count_multiplier", 11)), 2.5),
		"Cycle 11 multiplier reaches the cap (2.5)")
	check(is_equal_approx(float(wave.call(&"cycle_count_multiplier", 20)), 2.5),
		"Cycle 20 multiplier stays capped, does not keep compounding")

	print("\n== host_start_wave() at Cycle 1 matches the pre-5.9 formula exactly ==")
	wave.set("base_count", 3)
	wave.set("per_player", 2)
	wave.set("scatter_m", 1.0)
	world.set("ambient_enabled", true)
	world.set("ambient_population", 0)
	world.call("host_despawn_all")
	await process_frame
	var expected_cycle1: int = int(wave.get("base_count")) + int(wave.get("per_player"))
	var spawned_cycle1: int = int(wave.call(&"host_start_wave"))
	check(spawned_cycle1 == expected_cycle1,
		"Cycle 1 wave size is unchanged: base + per_player (%d)" % expected_cycle1)
	check(int(world.call("live_count")) == expected_cycle1,
		"Cycle 1 field actually holds that many live enemies")
	wave.call(&"host_stop_wave")
	world.call("host_despawn_all")
	await process_frame

	print("\n== EventBus.emit_cycle_advanced() reaches WaveSpawner.current_cycle() ==")
	EVENT_BUS.emit_cycle_advanced(6)
	await process_frame
	check(int(wave.call(&"current_cycle")) == 6,
		"current_cycle() reads the real broadcast, not a stale/private copy")

	print("\n== host_start_wave() at Cycle 6 scales by the Cycle multiplier ==")
	var expected_cycle6: int = roundi(
		float(int(wave.get("base_count")) + int(wave.get("per_player"))) * 1.75
	)
	var spawned_cycle6: int = int(wave.call(&"host_start_wave"))
	check(spawned_cycle6 == expected_cycle6,
		"Cycle 6 wave size is (base + per_player) * 1.75 = %d" % expected_cycle6)
	check(int(world.call("live_count")) == expected_cycle6,
		"Cycle 6 field actually holds that many live enemies")
	wave.call(&"host_stop_wave")
	world.call("host_despawn_all")
	await process_frame

	print("\n== an explicit override_count still bypasses the Cycle multiplier ==")
	var spawned_override: int = int(wave.call(&"host_start_wave", 5))
	check(spawned_override == 5, "an explicit count is never Cycle-scaled")
	wave.call(&"host_stop_wave")
	world.call("host_despawn_all")
	await process_frame

	print("\n== composition: _roll_roster() is weighted toward the most-recently-unlocked archetype ==")
	EVENT_BUS.emit_cycle_advanced(1)  # Reset so later assertions are not reading Cycle 6's state.
	await process_frame
	var unlocked: StringName = StringName(wave.call(&"host_unlock_next_enemy"))
	check(unlocked == &"bog_crawler", "one archetype unlocked for the roll test (bog_crawler)")
	var far_away := Vector3(5000.0, 0.0, 5000.0)  # No Mire corruption out here — an uncontaminated roll.
	var sample_size: int = 600
	var spawned_sample: int = int(wave.call(
		&"host_spawn_wave_at", far_away, sample_size, &"", 0.1
	))
	check(spawned_sample == sample_size, "the sample wave actually spawned %d bodies" % sample_size)
	var base_count_seen: int = 0
	var unlocked_count_seen: int = 0
	for enemy: Node in world.call("live_enemies"):
		var def: Resource = enemy.get("definition")
		if def == null:
			continue
		var id := StringName(def.get(&"id"))
		if id == &"crawler":
			base_count_seen += 1
		elif id == &"bog_crawler":
			unlocked_count_seen += 1
	var observed_total: int = base_count_seen + unlocked_count_seen
	check(observed_total == sample_size, "every sampled body resolved to one of the two known ids")
	# Weight is 1 (enemy_id) : 2 (first unlock) -> bog_crawler's expected share is 2/3 ~= 0.667.
	# Deterministic under DEFAULT_SEED (no live RNG re-seed in this file), so a wide +/-0.12 band
	# around the expected share never flakes without also catching "the weighting broke".
	var unlocked_share: float = float(unlocked_count_seen) / float(maxi(observed_total, 1))
	check(unlocked_share > 0.54, "bog_crawler's observed share (%.3f) beats even odds (0.5)"
		% unlocked_share)
	check(unlocked_share < 0.80, "bog_crawler's observed share (%.3f) is still within its 0.667 weight"
		% unlocked_share)
	world.call("host_despawn_all")
	await process_frame

	print("\nWAVE_DIRECTOR_CHECK failures=%d" % failures)
	finish()


## Same shape as `wave_spawner_check.gd`'s own `_check_wiring()` — the shipped project actually has
## these autoloads, not a harness-private stand-in.
func _check_wiring() -> bool:
	print("== the shipped project actually has a wave director ==")
	world = root.get_node_or_null(^"EnemyWorld")
	var player_net: Node = root.get_node_or_null(^"PlayerNet")
	wave = root.get_node_or_null(^"WaveSpawner")
	check(world != null and player_net != null, "EnemyWorld and PlayerNet autoloads exist")
	check(wave != null, "WaveSpawner is registered as an autoload")
	if world == null or player_net == null or wave == null:
		return false
	check(wave.has_method(&"cycle_count_multiplier"), "WaveSpawner exposes cycle_count_multiplier()")
	check(wave.has_method(&"current_cycle"), "WaveSpawner exposes current_cycle()")
	world.call("host_despawn_all")
	# ambient_spawn_points() (host_start_wave()'s own marker source) needs a real nest marker — same
	# minimal setup wave_spawner_check.gd uses, so a size-scaling test has somewhere to spawn into.
	var marker := Marker3D.new()
	marker.add_to_group(&"playtest_hollow_marker")
	marker.set_meta(&"kind", "enemy_spawn")
	root.add_child(marker)
	return true


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
