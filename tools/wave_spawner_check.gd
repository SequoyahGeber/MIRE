extends SceneTree

## Direct proof for task 2.12: dusk fills the field, dawn clears it, and the count scales with the
## number of live players. No fifteen-minute clock wait and no new network seam — the real
## EnemyWorld owns every body, so all population assertions go through live_count().
##
##   .agent/bin/agent godot --script tools/wave_spawner_check.gd
##
## This harness drives the REGISTERED autoloads (F-068, F-069). The first version built its own
## FakeDayNight named "DayNight" and its own WaveSpawner instance; once 2.11 registered the real
## DayNight autoload, `/root/DayNight` resolved to the autoload while the check emitted on its fake,
## so every population assertion was reading a signal nobody had subscribed to. Worse, the same
## shape would silently pass with WaveSpawner unregistered — which is exactly the state 2.12 shipped
## in, for a day, with no night waves in the game at all. Hence _check_wiring() below: if the
## autoload is missing, this check fails on line one instead of testing a private copy.
##
## Thresholds are crossed by advancing the real clock rather than by emitting the signal, because
## "the host's own clock reaches 0.75 and something happens" is the actual claim under test.

var failures: int = 0
var day_night: Node
var wave: Node
var world: Node
var players: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return

	# The harness owns time from here. DayNight advances on its own physics tick otherwise, and a
	# stray crossing mid-assertion would spawn a wave nothing in this file asked for.
	day_night.set_physics_process(false)
	wave.set("base_count", 3)
	wave.set("per_player", 2)
	wave.set("scatter_m", 1.0)

	# A marker is all EnemyWorld's public seam needs. Keeping ambient_population at zero lets dawn
	# prove both "all wave bodies are gone" and "ambient was restored" without an immediate daytime
	# crawler making those assertions mutually exclusive.
	var marker := Marker3D.new()
	marker.add_to_group(&"playtest_hollow_marker")
	marker.set_meta(&"kind", "enemy_spawn")
	root.add_child(marker)
	world.set("ambient_enabled", true)
	world.set("ambient_population", 0)
	world.call("host_despawn_all")
	await process_frame
	check(int(world.call("live_count")) == 0, "the field starts empty")

	print("\n== offline host-of-one night ==")
	var expected_one: int = int(wave.get("base_count")) + int(wave.get("per_player"))
	await _cross_into_night()
	check(int(world.call("live_count")) == expected_one,
		"one-player wave matches base + per_player (%d)" % expected_one)
	check(not bool(world.get("ambient_enabled")), "night disables ambient replacement")
	# Re-firing the threshold is harmless: this is one population per night, not a refill seam.
	day_night.emit_signal(&"night_started")
	await process_frame
	check(int(world.call("live_count")) == expected_one,
		"a repeated night signal does not add or replace enemies")
	await _assert_dawn("one-player dawn")

	print("\n== three-player night ==")
	for peer_id: int in range(1, 4):
		var body := Node3D.new()
		body.name = str(peer_id)
		players.add_child(body)
	var expected_three: int = int(wave.get("base_count")) + int(wave.get("per_player")) * 3
	await _cross_into_night()
	check(int(world.call("live_count")) == expected_three,
		"three-player wave matches base + per_player x 3 (%d)" % expected_three)
	await _assert_dawn("three-player dawn")

	print("\n== ambient-disabled preservation ==")
	world.set("ambient_enabled", false)
	await _cross_into_night()
	await _cross_into_day()
	check(int(world.call("live_count")) == 0,
		"dawn still clears the wave when ambient was already disabled")
	check(not bool(world.get("ambient_enabled")),
		"dawn preserves an intentionally disabled daytime field")

	print("\n== position-override wave (task 4.8's Wellspring seam) ==")
	world.call("host_despawn_all")
	await process_frame
	var ambient_before: bool = bool(world.get("ambient_enabled"))
	var override_position := Vector3(50.0, 0.0, -30.0)
	var spawned: int = int(wave.call(&"host_spawn_wave_at", override_position, 4, &"crawler", 0.5))
	check(spawned == 4, "host_spawn_wave_at reports the count it spawned")
	check(int(world.call("live_count")) == 4, "host_spawn_wave_at actually populates EnemyWorld")
	check(bool(world.get("ambient_enabled")) == ambient_before,
		"host_spawn_wave_at leaves ambient_enabled untouched")
	world.call("host_despawn_all")
	await process_frame

	print("\nWAVE_SPAWNER_CHECK failures=%d" % failures)
	finish()


## F-068's regression anchor. 2.12's code was complete and correct and simply never ran, because
## nothing registered it — so "the script exists and its logic is right" is not what this check is
## allowed to assert. It asserts that the shipped project boots with a wave director attached to a
## clock.
func _check_wiring() -> bool:
	print("== the shipped project actually has a wave director ==")
	world = root.get_node_or_null(^"EnemyWorld")
	var player_net: Node = root.get_node_or_null(^"PlayerNet")
	day_night = root.get_node_or_null(^"DayNight")
	wave = root.get_node_or_null(^"WaveSpawner")
	check(world != null and player_net != null, "EnemyWorld and PlayerNet autoloads exist")
	check(day_night != null, "DayNight is registered as an autoload")
	check(wave != null,
		"WaveSpawner is registered as an autoload — without this the game has no night waves")
	if world == null or player_net == null or day_night == null or wave == null:
		return false
	check(day_night.is_connected(&"night_started", Callable(wave, "_on_night_started")),
		"WaveSpawner is subscribed to the real DayNight's dusk")
	check(day_night.is_connected(&"day_started", Callable(wave, "_on_day_started")),
		"WaveSpawner is subscribed to the real DayNight's dawn")
	players = player_net.call("players_root") as Node
	return true


## Advances the host's own clock over night_started_at (0.75) in small steps, the way a real dusk
## arrives. A short day_length just means fewer iterations, not a different code path — this is the
## same host_advance() the production _physics_process calls.
func _cross_into_night() -> void:
	day_night.set(&"day_length_seconds", 1.0)
	day_night.set(&"time_of_day", 0.74)
	for _step: int in 20:
		day_night.call(&"host_advance", 0.01)
	await process_frame


## Crosses day_started_at (0.25), wrap included, the same way.
func _cross_into_day() -> void:
	day_night.set(&"day_length_seconds", 1.0)
	day_night.set(&"time_of_day", 0.99)
	for _step: int in 40:
		day_night.call(&"host_advance", 0.01)
	await process_frame
	# _refill_daytime is call_deferred so queued enemy frees have left the tree first.
	await process_frame


func _assert_dawn(label: String) -> void:
	await _cross_into_day()
	check(int(world.call("live_count")) == 0, "%s clears the field" % label)
	check(bool(world.get("ambient_enabled")), "%s restores the prior ambient setting" % label)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
