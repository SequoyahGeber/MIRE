extends SceneTree

## One-shot project bootstrap for M0: input map, autoloads, player scene, greybox level.
##
## Run with:
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/setup_project.gd
##
## Written as a script rather than done by hand so that Godot serialises its own formats — hand-authored
## .tscn files and input-event literals are easy to get subtly wrong.
##
## RE-RUNNING IS DESTRUCTIVE once hand-tuning has begun (F-048): it overwrites player.tscn and
## greybox_test.tscn wholesale and rewrites the full input map. The moment 2.9 serialises tuned
## camera @exports into player.tscn, a re-run erases them. It exists to take a fresh clone from zero
## to "press play" — after that, the editor is the source of truth and this file is history. The one
## thing it deliberately does NOT touch any more: an existing main_scene (the playable level moved on
## from the greybox — F-028 — and a bootstrap must not silently move it back).

const PLAYER_SCENE := "res://entities/player/player.tscn"
const LEVEL_SCENE := "res://levels/greybox_test.tscn"

# Capsule is 1.8 tall with a 0.4 radius, so its centre sits at 0.9 for the body origin to be at the
# feet. Eye height 1.6 then reads correctly against world geometry.
const CAPSULE_HEIGHT := 1.8
const CAPSULE_RADIUS := 0.4
const EYE_HEIGHT := 1.6


func _initialize() -> void:
	_setup_input_map()
	_setup_autoloads()
	_build_player_scene()
	_build_greybox_level()

	# Claim the main scene only when the project has none: reverting playtest_hollow to the M0
	# greybox on a re-run is the F-048 trap, and verify_setup deliberately does not pin the main
	# scene (F-028), so nothing downstream would catch the swap.
	var current_main: String = str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if current_main.is_empty():
		ProjectSettings.set_setting("application/run/main_scene", LEVEL_SCENE)
	var err: int = ProjectSettings.save()
	if err != OK:
		push_error("Failed to save project.godot: %d" % err)
	else:
		print("✓ project.godot written")
	print("✓ setup complete — open the project and press Play")
	quit()


# ---------------------------------------------------------------- input

func _key(physical: Key) -> InputEventKey:
	var e := InputEventKey.new()
	# physical_keycode binds by position, so WASD still works on AZERTY/Dvorak layouts.
	e.physical_keycode = physical
	return e


func _mouse(button: MouseButton) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = button
	return e


func _pad(button: JoyButton) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	return e


func _axis(axis: JoyAxis, value: float) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = value
	return e


func _action(name: String, events: Array) -> void:
	ProjectSettings.set_setting("input/" + name, {
		"deadzone": 0.2,
		"events": events,
	})


func _setup_input_map() -> void:
	# Names are read by string in player_controller.gd — a typo here shows up as "why won't it move".
	_action("move_forward", [_key(KEY_W), _axis(JOY_AXIS_LEFT_Y, -1.0)])
	_action("move_back", [_key(KEY_S), _axis(JOY_AXIS_LEFT_Y, 1.0)])
	_action("move_left", [_key(KEY_A), _axis(JOY_AXIS_LEFT_X, -1.0)])
	_action("move_right", [_key(KEY_D), _axis(JOY_AXIS_LEFT_X, 1.0)])
	_action("jump", [_key(KEY_SPACE), _pad(JOY_BUTTON_A)])
	_action("sprint", [_key(KEY_SHIFT), _pad(JOY_BUTTON_LEFT_STICK)])

	# Bound now, unused until M2. Free to add here, annoying to come back for.
	_action("attack", [_mouse(MOUSE_BUTTON_LEFT), _axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)])
	_action("interact", [_key(KEY_E), _pad(JOY_BUTTON_X)])
	_action("inventory", [_key(KEY_TAB), _pad(JOY_BUTTON_Y)])
	_action("build", [_key(KEY_B)])

	print("✓ input map: 10 actions")


func _setup_autoloads() -> void:
	# The leading * enables the singleton. Names are called directly in code
	# (debug_console.gd references DebugOverlay), so they must match exactly.
	ProjectSettings.set_setting("autoload/DebugOverlay", "*res://autoload/debug_overlay.gd")
	ProjectSettings.set_setting("autoload/DebugConsole", "*res://autoload/debug_console.gd")
	print("✓ autoloads: DebugOverlay, DebugConsole")


# ---------------------------------------------------------------- scene helpers

## Every descendant needs its owner set to the scene root or PackedScene.pack() silently drops it.
func _adopt(root: Node, node: Node) -> void:
	node.owner = root


func _material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.9
	return m


## A static box with matching mesh and collision. Size is full extents, position is its centre.
func _box(root: Node, parent: Node, name: String, size: Vector3, pos: Vector3,
		color: Color, rot_deg: Vector3 = Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = name
	body.position = pos
	body.rotation_degrees = rot_deg
	parent.add_child(body)
	_adopt(root, body)

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	box_mesh.material = _material(color)
	mesh.mesh = box_mesh
	body.add_child(mesh)
	_adopt(root, mesh)

	var col := CollisionShape3D.new()
	col.name = "Collision"
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	_adopt(root, col)

	return body


func _save(root: Node, path: String) -> void:
	var packed := PackedScene.new()
	var err: int = packed.pack(root)
	if err != OK:
		push_error("pack failed for %s: %d" % [path, err])
		return
	err = ResourceSaver.save(packed, path)
	if err != OK:
		push_error("save failed for %s: %d" % [path, err])
	else:
		print("✓ %s" % path)


# ---------------------------------------------------------------- player

func _build_player_scene() -> void:
	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(load("res://entities/player/player_controller.gd"))
	# 46° lets you walk the 45° ramp but not the 50° one — a deliberate, testable line.
	player.floor_max_angle = deg_to_rad(46.0)
	player.floor_snap_length = 0.3
	player.floor_stop_on_slope = true

	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var capsule := CapsuleShape3D.new()
	capsule.height = CAPSULE_HEIGHT
	capsule.radius = CAPSULE_RADIUS
	col.shape = capsule
	# Centre the capsule so the body origin sits at the feet, not the waist.
	col.position = Vector3(0.0, CAPSULE_HEIGHT * 0.5, 0.0)
	player.add_child(col)
	_adopt(player, col)

	# Name must be exactly CameraPivot — player_controller.gd resolves it with $CameraPivot.
	var pivot := Node3D.new()
	pivot.name = "CameraPivot"
	pivot.set_script(load("res://entities/player/player_camera.gd"))
	pivot.position = Vector3(0.0, EYE_HEIGHT, 0.0)
	player.add_child(pivot)
	_adopt(player, pivot)

	# Name must be exactly Camera3D — player_camera.gd resolves it with $Camera3D.
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.fov = 75.0
	cam.current = true
	pivot.add_child(cam)
	_adopt(player, cam)

	_save(player, PLAYER_SCENE)
	player.free()


# ---------------------------------------------------------------- greybox level

func _build_greybox_level() -> void:
	var root := Node3D.new()
	root.name = "GreyboxTest"

	_add_environment(root)

	var ground := _box(root, root, "Ground", Vector3(60, 1, 60), Vector3(0, -0.5, 0),
		Color(0.32, 0.34, 0.30))
	ground.name = "Ground"

	_add_ramps(root)
	_add_stairs(root)
	_add_gaps(root)
	_add_walls(root)

	# Player starts on flat ground facing the ramps.
	var player: Node = load(PLAYER_SCENE).instantiate()
	player.name = "Player"
	player.position = Vector3(0, 0.2, 8)
	root.add_child(player)
	# Only the instance root is adopted — its children stay owned by the packed scene.
	_adopt(root, player)

	_save(root, LEVEL_SCENE)
	root.free()


func _add_environment(root: Node) -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_horizon_color = Color(0.62, 0.65, 0.68)
	sky_mat.ground_horizon_color = Color(0.62, 0.65, 0.68)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	root.add_child(we)
	_adopt(root, we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-45, -130, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	root.add_child(sun)
	_adopt(root, sun)


## Ramps bracketing floor_max_angle (46°), so you can feel exactly where walkable stops.
func _add_ramps(root: Node) -> void:
	var group := Node3D.new()
	group.name = "Ramps"
	root.add_child(group)
	_adopt(root, group)

	var angles: Array[float] = [15.0, 30.0, 45.0, 50.0]
	var colors: Array[Color] = [
		Color(0.35, 0.50, 0.35), Color(0.40, 0.50, 0.32),
		Color(0.52, 0.48, 0.30), Color(0.55, 0.34, 0.32),
	]
	for i in angles.size():
		var a: float = angles[i]
		_box(root, group, "Ramp_%ddeg" % int(a), Vector3(4, 0.4, 8),
			Vector3(-18 + i * 5.0, 1.4, -6), colors[i], Vector3(-a, 0, 0))


## Step heights around the usual comfortable limit, to check the snap length works.
func _add_stairs(root: Node) -> void:
	var group := Node3D.new()
	group.name = "Stairs"
	root.add_child(group)
	_adopt(root, group)

	var heights: Array[float] = [0.2, 0.3, 0.4]
	for s in heights.size():
		var h: float = heights[s]
		var x: float = 4.0 + s * 5.0
		for step in 6:
			_box(root, group, "Stair_%d_%d" % [int(h * 100), step],
				Vector3(3, h, 1.2), Vector3(x, h * 0.5 + step * h, -4 - step * 1.2),
				Color(0.42, 0.44, 0.52))


## Gaps widen left to right — walk along the edge and find where the jump stops clearing.
func _add_gaps(root: Node) -> void:
	var group := Node3D.new()
	group.name = "Gaps"
	root.add_child(group)
	_adopt(root, group)

	var widths: Array[float] = [1.5, 2.5, 3.5, 4.5]
	var x: float = -20.0
	for i in widths.size():
		var w: float = widths[i]
		_box(root, group, "Platform_%d" % i, Vector3(4, 1, 6), Vector3(x, 0.5, 14),
			Color(0.45, 0.42, 0.50))
		x += 4.0 + w
	_box(root, group, "Platform_end", Vector3(4, 1, 6), Vector3(x, 0.5, 14),
		Color(0.45, 0.42, 0.50))


func _add_walls(root: Node) -> void:
	var group := Node3D.new()
	group.name = "Walls"
	root.add_child(group)
	_adopt(root, group)

	# A corridor for testing wall slide, and a low lip you should be able to step over.
	_box(root, group, "Wall_A", Vector3(0.5, 3, 12), Vector3(12, 1.5, 8), Color(0.50, 0.50, 0.54))
	_box(root, group, "Wall_B", Vector3(0.5, 3, 12), Vector3(15, 1.5, 8), Color(0.50, 0.50, 0.54))
	_box(root, group, "Lip", Vector3(6, 0.25, 0.5), Vector3(0, 0.125, 2), Color(0.58, 0.54, 0.40))
