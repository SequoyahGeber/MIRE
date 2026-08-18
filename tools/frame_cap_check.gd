extends SceneTree

## Headless proof for the F-066 frame cap. The point of DevFrameCap is that it caps editor and debug
## runs and leaves a release export alone, so this asserts both halves of that condition rather than
## just "the autoload loaded" — a cap that silently shipped to players would be the actual failure.

const EXPECTED_DEV_CAP: int = 60

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var cap_node: Node = root.get_node_or_null(^"DevFrameCap")
	check(cap_node != null, "DevFrameCap autoload is registered and loaded")
	if cap_node == null:
		finish()
		return

	# This check runs on the editor binary, so has_feature("editor") is true here exactly as it is
	# during Play. If that ever stops holding, every assertion below is meaningless, so assert it.
	check(OS.has_feature("editor"), "this run reports the 'editor' feature, as a Play run does")
	check(Engine.max_fps == EXPECTED_DEV_CAP,
		"an editor run is capped to %d fps (got %d)" % [EXPECTED_DEV_CAP, Engine.max_fps])

	# The cap must be adjustable at runtime, or the console command is decoration.
	cap_node.call("set_cap", 30)
	check(Engine.max_fps == 30, "set_cap(30) applies (got %d)" % Engine.max_fps)
	check(int(cap_node.call("cap")) == 30, "cap() reports the live value")
	cap_node.call("set_cap", 0)
	check(Engine.max_fps == 0, "set_cap(0) uncaps (got %d)" % Engine.max_fps)
	cap_node.call("set_cap", -5)
	check(Engine.max_fps == 0, "a negative cap clamps to uncapped rather than going negative")
	cap_node.call("set_cap", EXPECTED_DEV_CAP)

	# An explicit --max-fps (or a project setting) must win over the dev default, or the flag looks
	# broken to whoever reaches for it. Re-runs _ready with a value already in place.
	Engine.max_fps = 144
	cap_node.call("_ready")
	check(Engine.max_fps == 144, "an explicitly set cap is left alone (got %d)" % Engine.max_fps)
	Engine.max_fps = 0
	cap_node.call("_ready")
	check(Engine.max_fps == EXPECTED_DEV_CAP,
		"with nothing set, the dev default applies (got %d)" % Engine.max_fps)

	var console: Node = root.get_node_or_null(^"DebugConsole")
	check(console != null, "DebugConsole autoload exists for the fps_cap command to register against")

	# The whole reason this file exists: simulation must not move with the frame rate. Physics ticks
	# are what the day/night clock, the wave director and every net system advance on, and capping
	# frames must not touch them.
	check(Engine.physics_ticks_per_second == 60,
		"physics tick is untouched at 60 Hz (got %d)" % Engine.physics_ticks_per_second)

	finish()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
