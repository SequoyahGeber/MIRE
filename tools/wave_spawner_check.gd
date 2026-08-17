extends SceneTree

## Direct signal proof for task 2.12: no fifteen-minute clock wait and no new network seam. The
## real EnemyWorld owns every body, so all population assertions go through live_count().

const WAVE_SPAWNER_SCRIPT := preload("res://systems/waves/wave_spawner.gd")

class FakeDayNight extends Node:
	signal night_started
	signal day_started


var failures: int = 0
var day_night: FakeDayNight
var wave: Node
var world: Node
var players: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	world = root.get_node_or_null(^"EnemyWorld")
	var player_net: Node = root.get_node_or_null(^"PlayerNet")
	check(world != null and player_net != null, "EnemyWorld and PlayerNet autoloads exist")
	if world == null or player_net == null:
		finish()
		return

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

	day_night = FakeDayNight.new()
	day_night.name = "DayNight"
	root.add_child(day_night)
	wave = WAVE_SPAWNER_SCRIPT.new()
	wave.name = "WaveSpawnerUnderTest"
	wave.set("base_count", 3)
	wave.set("per_player", 2)
	wave.set("scatter_m", 1.0)
	root.add_child(wave)
	players = player_net.call("players_root") as Node

	print("\n== offline host-of-one night ==")
	var expected_one: int = int(wave.get("base_count")) + int(wave.get("per_player"))
	day_night.night_started.emit()
	await process_frame
	check(int(world.call("live_count")) == expected_one,
		"one-player wave matches base + per_player (%d)" % expected_one)
	check(not bool(world.get("ambient_enabled")), "night disables ambient replacement")
	# Re-emitting the threshold is harmless: this is one population per night, not a refill seam.
	day_night.night_started.emit()
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
	day_night.night_started.emit()
	await process_frame
	check(int(world.call("live_count")) == expected_three,
		"three-player wave matches base + per_player x 3 (%d)" % expected_three)
	await _assert_dawn("three-player dawn")

	print("\n== ambient-disabled preservation ==")
	world.set("ambient_enabled", false)
	day_night.night_started.emit()
	await process_frame
	day_night.day_started.emit()
	await process_frame
	await process_frame
	check(int(world.call("live_count")) == 0,
		"dawn still clears the wave when ambient was already disabled")
	check(not bool(world.get("ambient_enabled")),
		"dawn preserves an intentionally disabled daytime field")

	print("\nWAVE_SPAWNER_CHECK failures=%d" % failures)
	finish()


func _assert_dawn(label: String) -> void:
	day_night.day_started.emit()
	await process_frame
	await process_frame
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
