extends SceneTree

## F-115: the shipped map's fog must be ground-hugging, patchy and local — not one uniform number
## applied to the whole froxel volume.
##
## The original bug was pure wiring and that is what this mostly guards: `playtest_atmosphere.gd`
## drove three `FogVolume` siblings BY NAME (`MireGroundFog`, `ForestMist`, `RuinsMist`) and the
## shipped level contained none of them, so the controller's entire fog path was dead and the only
## fog left was `Environment.volumetric_fog_density` — which, being one constant, can only ever be a
## flat full-screen haze. A check keyed on "does the level have a node called X" would have shipped
## the same bug on the next map, so this asserts the RELATIONSHIPS instead: mist exists for any
## level with an Atmosphere, it sits low against that level's own terrain, it follows the viewer
## horizontally and not vertically, and it thickens at dawn and dusk.
##
## Runs headless: everything here is node state and shader parameters, not rendered pixels. Use
## `tools/atmosphere_look_shot.gd --windowed` to actually look at it.
##
## Run with: .agent/bin/agent godot --script tools/ground_fog_check.gd

const TERRAIN_GROUP: StringName = &"authored_world_terrain"

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene_path := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	var packed := load(scene_path) as PackedScene
	check(packed != null, "main scene %s loads" % scene_path)
	if packed == null:
		_finish()
		return
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for _frame: int in 20:
		await process_frame
	await physics_frame

	var atmosphere: Node = scene.get_node_or_null(^"Atmosphere")
	check(atmosphere != null, "the level has an Atmosphere controller")
	if atmosphere == null:
		_finish()
		return

	# Nobody placed this in the level, and that is the point: a generated world has no level author
	# to remember it.
	var fog := atmosphere.get_node_or_null(^"GroundFog") as FogVolume
	check(fog != null, "Atmosphere built a GroundFog nobody had to place in the scene")
	if fog == null:
		_finish()
		return
	check(fog.shape == RenderingServer.FOG_VOLUME_SHAPE_BOX, "the mist volume is a box")

	# A FogMaterial is one constant density — the flat haze this finding is about. Only a fog
	# ShaderMaterial can vary density with world position.
	var shader_material := fog.material as ShaderMaterial
	check(shader_material != null and not (fog.material is FogMaterial),
		"the mist runs a fog SHADER, not a constant-density FogMaterial")
	if shader_material == null:
		_finish()
		return
	check(shader_material.shader != null and shader_material.shader.code.contains("shader_type fog"),
		"that shader really is a fog shader")

	# Low against THIS level's terrain, measured rather than authored.
	var terrain := AABB()
	var found := false
	for node: Node in get_nodes_in_group(TERRAIN_GROUP):
		var visual := node as VisualInstance3D
		if visual == null:
			continue
		var box: AABB = visual.global_transform * visual.get_aabb()
		terrain = box if not found else terrain.merge(box)
		found = true
	check(found, "the level publishes terrain to measure against")
	var base_height := float(fog.get("base_height"))
	check(not is_nan(base_height), "the mist measured a base height instead of guessing one")
	if found and not is_nan(base_height):
		# The low band is measured from the terrain's DRY floor. Streamed islands carry seabed
		# geometry tens of metres under the waterline, so "the low half of the terrain" would be
		# underwater — the same blind spot ground_fog.gd's own water clamp exists for. A map that
		# cannot answer where its water is keeps the raw AABB floor, same as before.
		var floor_y: float = terrain.position.y
		var centre: Vector3 = terrain.get_center()
		for node: Node in get_nodes_in_group(TERRAIN_GROUP):
			if not node.has_method(&"water_surface_at"):
				continue
			var water := float(node.call(&"water_surface_at", centre.x, centre.z))
			if is_finite(water):
				floor_y = maxf(floor_y, water)
			break
		var ceiling_y: float = terrain.position.y + terrain.size.y
		check(base_height > floor_y - 0.001,
			"the mist sits at or above the terrain's dry floor (%.2f >= %.2f)"
			% [base_height, floor_y])
		check(base_height < floor_y + (ceiling_y - floor_y) * 0.5,
			"the mist sits in the LOW half of the dry terrain, so high ground stands clear of it "
			+ "(%.2f < %.2f)" % [base_height, floor_y + (ceiling_y - floor_y) * 0.5])
		check(shader_material.get_shader_parameter(&"base_height") != null,
			"the measured height reached the shader")

	# Horizontal follow only. Following in Y is what would make a plateau as foggy as the mere,
	# which is the "covers everything" complaint in a different costume.
	var camera := Camera3D.new()
	camera.name = "GroundFogCheckCamera"
	scene.add_child(camera)
	camera.make_current()
	camera.global_position = Vector3(40.0, 30.0, -25.0)
	await process_frame
	await process_frame
	var first := fog.global_position
	check(is_equal_approx(first.x, 40.0) and is_equal_approx(first.z, -25.0),
		"the mist window follows the viewer horizontally")
	camera.global_position = Vector3(40.0, 90.0, -25.0)
	await process_frame
	await process_frame
	check(is_equal_approx(fog.global_position.y, first.y),
		"the mist does NOT follow the viewer upward — its height belongs to the world")

	# Thick at dawn and dusk, thin at noon. This is the "specific areas / not everywhere" half that
	# a player actually notices.
	var day_night: Node = root.get_node_or_null(^"DayNight")
	check(day_night != null, "DayNight autoload exists to pose the clock")
	if day_night != null:
		var noon := await _density_at(day_night, fog, 12.0)
		var dawn := await _density_at(day_night, fog, 6.25)
		var night := await _density_at(day_night, fog, 0.0)
		check(dawn > noon * 1.5,
			"dawn mist is well thicker than noon (%.2f vs %.2f)" % [dawn, noon])
		check(night > noon,
			"night mist is thicker than noon (%.2f vs %.2f)" % [night, noon])
		check(noon > 0.0, "noon still has some mist rather than none (%.2f)" % noon)

	# And the blanket that used to be the whole look must now be a rounding error next to it.
	var world_environment := scene.get_node_or_null(^"WorldEnvironment") as WorldEnvironment
	check(world_environment != null and world_environment.environment != null,
		"the level has an Environment")
	if world_environment != null and world_environment.environment != null:
		var uniform: float = world_environment.environment.volumetric_fog_density
		check(uniform < 0.0002,
			"the uniform full-screen haze is gone (volumetric_fog_density=%.5f)" % uniform)
		check(world_environment.environment.volumetric_fog_enabled,
			"volumetric fog is still enabled, so FogVolumes and light shafts render at all")

	print("GROUND_FOG_CHECK base_height=%.2f failures=%d" % [base_height, failures])
	_finish()


func _density_at(day_night: Node, fog: FogVolume, hour: float) -> float:
	day_night.set("time_of_day", hour / 24.0)
	await physics_frame
	await process_frame
	return float(fog.get("density_scale"))


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	quit(1 if failures > 0 else 0)
