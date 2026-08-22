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
	check(_live_of_wave_kind(world, wave) == expected_cycle1,
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
	check(_live_of_wave_kind(world, wave) == expected_cycle6,
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
	# 5.11 gave the roster a stride (`roster_unlock_stride`, docs/ENEMIES.md §2), so an unlock now
	# costs more than one advance. Forced to 1 for the composition test below, which is about
	# `_roll_roster()`'s WEIGHTING and has no opinion about pacing; the stride itself is asserted on
	# its own further down.
	var authored_stride: int = int(wave.get(&"roster_unlock_stride"))
	wave.set(&"roster_unlock_stride", 1)
	# Read off the authored roster, not hard-coded: `roster_order` grows a rung every time a tier of
	# docs/ENEMIES.md's ladder is authored, and this test is about `_roll_roster()`'s weighting, which
	# has no opinion about which archetype it is weighting.
	var first_rung: StringName = StringName((wave.get(&"roster_order") as Array)[0])
	var unlocked: StringName = StringName(wave.call(&"host_unlock_next_enemy"))
	check(unlocked == first_rung, "one archetype unlocked for the roll test (%s)" % first_rung)
	wave.set(&"roster_unlock_stride", authored_stride)
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
		if id == wave.get(&"enemy_id"):
			base_count_seen += 1
		elif id == first_rung:
			unlocked_count_seen += 1
	var observed_total: int = base_count_seen + unlocked_count_seen
	check(observed_total == sample_size, "every sampled body resolved to one of the two known ids")
	# Weight is 1 (enemy_id) : 2 (first unlock) -> the unlocked rung's expected share is 2/3 ~= 0.667.
	# Deterministic under DEFAULT_SEED (no live RNG re-seed in this file), so a wide +/-0.12 band
	# around the expected share never flakes without also catching "the weighting broke".
	var unlocked_share: float = float(unlocked_count_seen) / float(maxi(observed_total, 1))
	check(unlocked_share > 0.54, "the unlocked rung's observed share (%.3f) beats even odds (0.5)"
		% unlocked_share)
	check(unlocked_share < 0.80, "the unlocked rung's observed share (%.3f) is still within its 0.667 weight"
		% unlocked_share)
	world.call("host_despawn_all")
	await process_frame

	print("\n== ladder cadence: roster_unlock_stride spends more than one Cycle per unlock (5.11) ==")
	# Two entries, because a one-entry roster cannot tell "skipped by the stride" apart from
	# "exhausted" — both return &"". The ids are stand-ins for ladder rungs; this test is about the
	# CADENCE, and it must not start failing the day tiers 2-5 are authored into roster_order.
	var real_roster: Array = wave.get(&"roster_order")
	var ladder: Array[StringName] = [&"bog_crawler", &"tusker"]
	wave.call(&"host_reset_for_new_run")
	wave.set(&"roster_order", ladder)
	wave.set(&"roster_unlock_stride", 2)
	check(StringName(wave.call(&"host_unlock_next_enemy")) == &"bog_crawler",
		"the FIRST advance unlocks, so tier 2 lands on Cycle 2 and not Cycle 3")
	check(StringName(wave.call(&"host_unlock_next_enemy")) == &"",
		"the second advance unlocks nothing — the stride is actually spent")
	check(StringName(wave.call(&"host_unlock_next_enemy")) == &"tusker",
		"the third advance unlocks the next rung")
	check(StringName(wave.call(&"host_unlock_next_enemy")) == &"",
		"and the fourth spends the stride again")
	check(int(wave.call(&"unlocked_enemy_pool").size()) == 2, "exactly two rungs came out of four advances")
	# A restarted run walks the same curve from the beginning — the stride counter is run state, and
	# leaving it behind would put the new run's first unlock on the wrong Cycle (F-259's shape).
	wave.call(&"host_reset_for_new_run")
	check(StringName(wave.call(&"host_unlock_next_enemy")) == &"bog_crawler",
		"a restarted run unlocks on ITS first advance, not on the ended run's parity")
	wave.call(&"host_reset_for_new_run")
	wave.set(&"roster_order", real_roster)
	wave.set(&"roster_unlock_stride", authored_stride)

	# Sampling above spawns real bog_crawler bodies, so F-158's visual_tint (systems/enemies/enemy.gd
	# `_apply_visual_tint()`) runs for real and provokes the dummy renderer's own harmless
	# `material_get_instance_shader_parameters` noise on every surface override it sets — see
	# tools/bog_crawler_check.gd's header for why. Standing rule 4 (docs/SPECS.md): declare it by
	# pattern rather than silencing it.
	print(
		"\nWAVE_DIRECTOR_CHECK failures=%d · EXPECTED_ERROR_PATTERNS=\"Parameter \\\"material\\\" is null\""
		% failures
	)
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


## How many live enemies are of the wave's own base kind — NOT `EnemyWorld.live_count()` (F-500).
##
## `live_count()` counts every body on the field, and the field is not only this wave's. Firing
## `cycle_advanced` also reaches `CycleModifierService`, which draws that Cycle's modifier; when the
## draw comes up `the_hunt`, `WaveSpawner._maybe_spawn_hunt_elite()` puts a `tusker` on the map in the
## same frame, and the count comes back one high. The draw is seeded per RUN, so this failed roughly
## one run in five and passed every time anybody re-ran it to look — which is the worst way for a
## check to be wrong. Diagnosed by exactly the failure it describes: `spawned=9 expected=9 live=10
## kinds={"tusker": 1, "peatling": 9}`.
##
## Counting the wave's own kind asserts the thing the test is actually about — the wave director put
## the right number of bodies on the field — and is indifferent to anything else legitimately
## spawning alongside it.
func _live_of_wave_kind(world: Node, wave: Node) -> int:
	var wanted := StringName(wave.get(&"enemy_id"))
	var total: int = 0
	for enemy: Node in world.call("live_enemies"):
		var def: Resource = enemy.get("definition")
		if def != null and StringName(def.get(&"id")) == wanted:
			total += 1
	return total


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
