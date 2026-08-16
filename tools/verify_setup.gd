extends SceneTree

## Smoke test for the M0 wiring. Proves the input map actually responds to keys, the autoloads are
## registered, and both scenes instantiate with the node names the scripts expect.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/verify_setup.gd
##
## Exits non-zero on failure, so it can be wired into a pre-commit or CI check later.

var _failures: int = 0
var _live_level: Node = null
var _live_player: CharacterBody3D = null
var _frames: int = 0


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _initialize() -> void:
	print("\n-- input map --")
	_verify_input()
	print("\n-- autoloads --")
	_verify_autoloads()
	print("\n-- scenes --")
	_verify_scenes()
	print("\n-- project.godot pinned settings (F-003) --")
	_verify_pinned_settings()

	# Static checks done. Now actually run the level so physics gets exercised — this is what
	# catches a mis-centred capsule (player sinks or hovers) that every static check would pass.
	print("\n-- live physics --")
	_live_level = load("res://levels/greybox_test.tscn").instantiate()
	root.add_child(_live_level)
	_live_player = _live_level.get_node_or_null("Player")
	if _live_player == null:
		_check("player present in running level", false)
		_finish()


func _process(_delta: float) -> bool:
	if _live_player == null:
		return false
	_frames += 1
	# ~1.5s at 60Hz: long enough to fall the 0.2m spawn gap and settle.
	if _frames < 90:
		return false

	var y: float = _live_player.global_position.y
	_check("player is on the floor", _live_player.is_on_floor(), "is_on_floor() false after 90 frames")
	# Feet at origin means a settled player rests at y ~= 0 on ground whose top face is y = 0.
	_check("player rests at ground level", absf(y) < 0.05, "y = %.3f" % y)
	_check("player is not still falling", absf(_live_player.velocity.y) < 1.0,
		"velocity.y = %.3f" % _live_player.velocity.y)
	_finish()
	return true


func _finish() -> void:
	print("")
	if _failures == 0:
		print("all checks passed")
	else:
		print("%d check(s) failed" % _failures)
	quit(1 if _failures > 0 else 0)


## Checks the *effective* runtime value via ProjectSettings.get_setting(), not the raw file text.
## Godot's editor prunes any setting matching the engine default on every save it performs — not just
## a Project Settings edit, any action that resaves project.godot — regardless of whether that value
## was set through the UI or hand-written into the file (ARCHITECTURE.md §5a, F-003, twice now). Chasing
## file presence is unwinnable for a value that equals the default. get_setting() is correct either
## way: it returns the override when one exists and the engine default otherwise, so this check can
## only fail on the thing that actually matters — someone changing a value away from the target, which
## (because it then differs from default) persists on save and would show up here.
func _verify_pinned_settings() -> void:
	var expected: Array = [
		["physics/common/physics_ticks_per_second", 60],
		["physics/common/max_physics_steps_per_frame", 8],
		["physics/common/physics_interpolation", true],
		["physics/common/physics_jitter_fix", 0.0],
		["display/window/vsync/vsync_mode", 1],
		["application/run/max_fps", 0],
	]
	for pair in expected:
		var key: String = pair[0]
		var want = pair[1]
		var got = ProjectSettings.get_setting(key, null)
		_check("%s == %s" % [key, str(want)], got == want, "got %s" % str(got))


func _verify_input() -> void:
	var expected: Array[String] = [
		"move_forward", "move_back", "move_left", "move_right",
		"jump", "sprint", "attack", "interact", "inventory", "build",
	]
	for action in expected:
		_check("action '%s' exists" % action, InputMap.has_action(action))

	# The real question: does a physical key press actually resolve to the action? A malformed
	# device field or a keycode/physical_keycode mix-up would pass "has_action" and still be dead.
	var probes: Array = [
		[KEY_W, "move_forward"], [KEY_S, "move_back"],
		[KEY_A, "move_left"], [KEY_D, "move_right"],
		[KEY_SPACE, "jump"], [KEY_SHIFT, "sprint"],
		[KEY_E, "interact"], [KEY_TAB, "inventory"], [KEY_B, "build"],
	]
	for probe in probes:
		var key: Key = probe[0]
		var action: String = probe[1]
		_check("key press drives '%s'" % action, _press_resolves(key, action),
			"keycode %d did not trigger the action" % key)


func _press_resolves(key: Key, action: String) -> bool:
	var down := InputEventKey.new()
	down.physical_keycode = key
	down.pressed = true
	Input.parse_input_event(down)
	Input.flush_buffered_events()

	var pressed: bool = Input.is_action_pressed(action)

	var up := InputEventKey.new()
	up.physical_keycode = key
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()

	return pressed


func _verify_autoloads() -> void:
	for name in ["DebugOverlay", "DebugConsole"]:
		var path: String = str(ProjectSettings.get_setting("autoload/" + name, ""))
		_check("%s registered" % name, path.begins_with("*res://"), "got '%s'" % path)


func _verify_scenes() -> void:
	var player_packed: PackedScene = load("res://entities/player/player.tscn")
	_check("player.tscn loads", player_packed != null)
	if player_packed == null:
		return

	var player: Node = player_packed.instantiate()
	_check("root is CharacterBody3D", player is CharacterBody3D, player.get_class())
	_check("script is PlayerController", player is PlayerController)
	_check("has CameraPivot", player.has_node("CameraPivot"))
	_check("has CollisionShape3D", player.has_node("CollisionShape3D"))

	if player.has_node("CameraPivot"):
		var pivot: Node = player.get_node("CameraPivot")
		_check("CameraPivot is PlayerCamera", pivot is PlayerCamera)
		_check("CameraPivot eye height 1.6", is_equal_approx(pivot.position.y, 1.6),
			str(pivot.position.y))
		_check("CameraPivot has Camera3D", pivot.has_node("Camera3D"))

	if player.has_node("CollisionShape3D"):
		var col: CollisionShape3D = player.get_node("CollisionShape3D")
		var shape := col.shape as CapsuleShape3D
		_check("capsule 1.8 x 0.4", shape != null
			and is_equal_approx(shape.height, 1.8) and is_equal_approx(shape.radius, 0.4))
		# Feet at origin: capsule centre must sit at half its height.
		_check("capsule centred at 0.9 (feet at origin)", is_equal_approx(col.position.y, 0.9),
			str(col.position.y))

	_check("floor_max_angle ~46deg", is_equal_approx(rad_to_deg(player.floor_max_angle), 46.0),
		"%.1f" % rad_to_deg(player.floor_max_angle))
	player.free()

	var level_packed: PackedScene = load("res://levels/greybox_test.tscn")
	_check("greybox_test.tscn loads", level_packed != null)
	if level_packed == null:
		return
	var level: Node = level_packed.instantiate()
	_check("level contains Player", level.has_node("Player"))
	_check("level has WorldEnvironment", level.has_node("WorldEnvironment"))
	_check("level has Ground", level.has_node("Ground"))
	_check("main_scene points at the level",
		str(ProjectSettings.get_setting("application/run/main_scene", "")) == "res://levels/greybox_test.tscn")
	level.free()
