extends SceneTree

## Offline proof for task 2.11: host advances time_of_day on its own physics tick, night/day
## thresholds fire exactly once per crossing, the level's Atmosphere node receives the converted
## value every tick, and a harness tree with no Atmosphere node never errors.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/day_night_check.gd
##
## Runs against a manually-instantiated DAY_NIGHT_SCRIPT, the same way tools/wave_spawner_check.gd
## proves WaveSpawner before either is registered as an autoload — this check has to pass BEFORE
## `agent autoload DayNight ...` runs (docs/SPECS.md 2.11's own ordering), so it cannot depend on
## /root/DayNight existing yet.

const DAY_NIGHT_SCRIPT := preload("res://systems/environment/day_night.gd")

## Stand-in for world/environment/playtest_atmosphere.gd — this check only needs to prove DayNight
## calls set_time_of_day() with the right conversion, not that the sky itself looks right.
class FakeAtmosphere extends Node:
	var day_length_seconds: float = 900.0
	var last_value: float = -1.0
	var call_count: int = 0

	func set_time_of_day(value: float) -> void:
		last_value = value
		call_count += 1


var failures: int = 0
var _threshold_night_count: int = 0
var _threshold_day_count: int = 0


func _on_test_night_started() -> void:
	_threshold_night_count += 1


func _on_test_day_started() -> void:
	_threshold_day_count += 1


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_check_advances_and_thresholds()
	await process_frame
	_check_applies_to_atmosphere()
	await process_frame
	_check_no_atmosphere_is_silent()

	print("\nDAY_NIGHT_CHECK failures=%d" % failures)
	finish()


## Host-of-one (no NetTransport session in this harness) advances time_of_day forward and fires each
## threshold exactly once as it's crossed, in both directions across a full lap of the cycle.
func _check_advances_and_thresholds() -> void:
	print("\n== host advances and crosses thresholds ==")
	var day_night: Node = DAY_NIGHT_SCRIPT.new()
	day_night.name = "DayNightUnderTest"
	root.add_child(day_night)

	# Member counters, not locals captured by a lambda: GDScript lambdas capture locals BY VALUE, so
	# `func() -> void: night_count += 1` would silently increment a copy the outer scope never sees
	# (the same trap tools/crafting_ui_check.gd's notes warn about for _until()).
	_threshold_night_count = 0
	_threshold_day_count = 0
	day_night.connect(&"night_started", _on_test_night_started)
	day_night.connect(&"day_started", _on_test_day_started)

	day_night.set(&"day_length_seconds", 2.0)
	day_night.set(&"time_of_day", 0.0)

	var before: float = float(day_night.get(&"time_of_day"))
	day_night.call(&"host_advance", 0.1)
	var after: float = float(day_night.get(&"time_of_day"))
	check(after > before, "host_advance() moves time forward")
	var expected_step: float = 0.1 / 2.0
	check(is_equal_approx(after - before, expected_step),
		"step matches delta / day_length_seconds (%.5f vs %.5f)" % [after - before, expected_step])

	# Drive to just before night, then step across it in small pieces so exactly one crossing occurs.
	day_night.set(&"time_of_day", 0.74)
	for i: int in 20:
		day_night.call(&"host_advance", 0.01)
	check(_threshold_night_count == 1,
		"night_started fires exactly once crossing 0.75 (%d)" % _threshold_night_count)
	for i: int in 20:
		day_night.call(&"host_advance", 0.01)
	check(_threshold_night_count == 1,
		"sitting past the threshold does not re-fire it (%d)" % _threshold_night_count)

	# Drive to just before day, then across it, including the 1.0 -> 0.0 wrap on the way. A shorter
	# day_length here just means fewer iterations to cross the wrap AND 0.25 in one pass.
	day_night.set(&"time_of_day", 0.99)
	day_night.set(&"day_length_seconds", 1.0)
	for i: int in 40:
		day_night.call(&"host_advance", 0.01)
	check(_threshold_day_count == 1,
		"day_started fires exactly once crossing 0.25, wrap included (%d)" % _threshold_day_count)

	day_night.queue_free()


## Every peer applies its time via a sibling Atmosphere node looked up under current_scene, and the
## value handed over is hours (0..24), not DayNight's own 0..1 fraction.
func _check_applies_to_atmosphere() -> void:
	print("\n== applies to the level's Atmosphere node ==")
	var scene := Node.new()
	scene.name = "FakeLevel"
	var atmosphere := FakeAtmosphere.new()
	atmosphere.name = "Atmosphere"
	scene.add_child(atmosphere)
	root.add_child(scene)
	current_scene = scene

	var day_night: Node = DAY_NIGHT_SCRIPT.new()
	day_night.name = "DayNightUnderTest2"
	root.add_child(day_night)
	day_night.set(&"time_of_day", 0.5)
	day_night.call(&"host_advance", 0.0)

	check(atmosphere.call_count > 0, "Atmosphere.set_time_of_day() was called")
	check(is_equal_approx(atmosphere.last_value, 12.0),
		"0.5 of a day converts to noon, 12.0h (got %.3f)" % atmosphere.last_value)

	day_night.queue_free()
	scene.queue_free()
	current_scene = null


## A harness tree (or a level with no Atmosphere child) must never error — day_night_net_check and
## any future headless harness that drives DayNight rely on this being a silent no-op.
func _check_no_atmosphere_is_silent() -> void:
	print("\n== no Atmosphere node is a silent no-op ==")
	current_scene = null
	var day_night: Node = DAY_NIGHT_SCRIPT.new()
	day_night.name = "DayNightUnderTest3"
	root.add_child(day_night)
	day_night.call(&"host_advance", 0.5)
	check(true, "host_advance() with no current_scene did not error")

	var empty_scene := Node.new()
	empty_scene.name = "EmptyLevel"
	root.add_child(empty_scene)
	current_scene = empty_scene
	day_night.call(&"host_advance", 0.5)
	check(true, "host_advance() with a scene that has no Atmosphere child did not error")

	day_night.queue_free()
	empty_scene.queue_free()
	current_scene = null


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
