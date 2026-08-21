extends SceneTree

## F-464 — what the river's cut through a hill actually looks like now.
##
##   .agent/bin/agent godot --windowed --script tools/cliff_render.gd
##
## `tools/cliff_check.gd` proves the number; this is the half a number cannot settle. It finds the
## steepest CARVED ground on each seed's island — the same way the check does, off
## `IslandHeightmap.Shape.channel`, so both are looking at the same place — stands a camera in the
## valley at eye height and photographs the face from below, which is where a player meets one.
##
## Windowed, because it needs a real renderer (F-077: the wrapper parks a 64x64 window offscreen and
## the shot is taken through a SubViewport of its own size, so the window's size is irrelevant).
##
## Shots land in `assets/audit/cliffs/`, beside the terrain audit renders, because the question they
## answer — "does this read as rock or as a wall" — is one somebody will want to ask again after the
## next retune, against these.

const IslandHeightmap := preload("res://world/gen/island_heightmap.gd")

const WORLD_SCENE: String = "res://levels/procedural_island.tscn"
const OUT_DIR: String = "res://assets/audit/cliffs"
const WIDTH: int = 960
const HEIGHT: int = 540
const EYE_HEIGHT_M: float = 1.7
## Lifted off the eye line for the wide frame: from a valley floor at 1.7 m a 30 m face fills the
## frame with its own bottom five metres, which is a texture swatch and not a landform.
const LIFT_M: float = 6.0
## How far back from the foot of the face the camera stands, and how far up the face it looks. A
## cliff photographed from its own base is a texture swatch; from here it is a landform.
const STAND_OFF_M: float = 52.0
const AIM_HEIGHT_M: float = 13.0
## The search, matching `cliff_check.gd`'s coarse pass. Coarser than the check's, because a shot
## only needs the neighbourhood and this runs with a renderer attached.
const SCAN_STEP_M: float = 5.0
const CONVERGE_FRAMES: int = 24
const SETTLE_FRAME_CAP: int = 900

const SEEDS: Array[int] = [8102602, 4242, 20260818]

var _world: Node3D = null
var _streamer: Node = null


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("cliff_render needs a renderer — run it with --windowed")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for world_seed: int in SEEDS:
		await _shoot(world_seed)
	print("CLIFF_RENDER dir=%s" % ProjectSettings.globalize_path(OUT_DIR))
	quit()


## The steepest carved sample on this seed's island, and the downhill direction out of it.
func _worst_cliff(world_seed: int) -> Dictionary:
	var set: IslandHeightmap.NoiseSet = IslandHeightmap.make_noise_set(world_seed)
	var shape := IslandHeightmap.Shape.new()
	var radius: float = IslandHeightmap.world_radius()
	var best: float = -1.0
	var best_at := Vector2.ZERO
	var best_fall := Vector2(1.0, 0.0)
	var x: float = -radius
	while x <= radius:
		var z: float = -radius
		while z <= radius:
			var here := Vector2(x, z)
			z += SCAN_STEP_M
			IslandHeightmap.shape_into(here.x, here.y, set, world_seed, shape)
			if shape.channel.y <= 0.0:
				continue
			var h: float = IslandHeightmap.height_from_shape(here.x, here.y, shape, set)
			if h < 0.5:
				continue
			var east: float = IslandHeightmap.height_from_set(
				here.x + SCAN_STEP_M, here.y, set, world_seed)
			var north: float = IslandHeightmap.height_from_set(
				here.x, here.y + SCAN_STEP_M, set, world_seed)
			var gradient := Vector2(east - h, north - h)
			if gradient.length() <= best:
				continue
			best = gradient.length()
			best_at = here
			# Downhill, in XZ: the camera wants to stand at the bottom of what it is photographing.
			best_fall = -gradient.normalized() if gradient.length() > 0.0 else best_fall
		x += SCAN_STEP_M
	return {"at": best_at, "fall": best_fall, "rise": best}


func _shoot(world_seed: int) -> void:
	var game_state: Node = root.get_node_or_null(^"/root/GameState")
	if game_state == null:
		push_error("no GameState autoload")
		return
	# Before the world is instanced: `ProceduralWorld._ready()` calls `ensure_seed()`, and a seed
	# adopted afterwards would be the next island, not this one.
	game_state.call(&"set_replicated_seed", world_seed)

	var spot: Dictionary = _worst_cliff(world_seed)
	# The island level itself, not `application/run/main_scene` — that is the frontend, and a title
	# screen has no terrain to photograph.
	var scene := (load(WORLD_SCENE) as PackedScene).instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for _frame: int in 20:
		await process_frame
	await physics_frame
	_world = scene if scene.has_method(&"height_at") else _find_world(scene)
	if _world == null:
		push_error("no ProceduralWorld under %s" % WORLD_SCENE)
		return
	_streamer = _world.get(&"streamer") as Node

	var foot: Vector2 = spot["at"] as Vector2
	var fall: Vector2 = spot["fall"] as Vector2
	# WALKED downhill, not offset in a straight line. A cliff sits in a valley, and a fixed offset
	# along the local gradient climbs the far side of it: the first version of this stood 52 m out
	# and 46 m UP, on the opposite plateau, looking down into the gorge it was meant to photograph.
	# Re-reading the gradient each step follows the floor round instead.
	var stand: Vector2 = _walk_downhill(world_seed, foot, fall)
	var ground: float = 0.0
	if _world != null and _world.has_method(&"height_at"):
		ground = float(_world.call(&"height_at", stand.x, stand.y))
	var eye := Vector3(stand.x, maxf(ground, 0.0) + EYE_HEIGHT_M + LIFT_M, stand.y)

	var viewport := SubViewport.new()
	viewport.size = Vector2i(WIDTH, HEIGHT)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = false
	viewport.world_3d = scene.get_viewport().world_3d
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 70.0
	camera.far = 500.0
	viewport.add_child(camera)
	camera.make_current()
	camera.global_position = eye
	await _settle(eye)
	camera.look_at(Vector3(foot.x, maxf(ground, 0.0) + AIM_HEIGHT_M, foot.y), Vector3.UP)

	print("  DEBUG world=%s streamer=%s foot_h=%.2f stand_h=%.2f cam=%s children=%d" % [
		_world.name, str(_streamer != null),
		float(_world.call(&"height_at", foot.x, foot.y)),
		float(_world.call(&"height_at", stand.x, stand.y)),
		str(camera.global_position), _world.get_child_count()])
	for _frame: int in CONVERGE_FRAMES:
		await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = viewport.get_texture().get_image()
	var path := "%s/cliff_%d.png" % [OUT_DIR, world_seed]
	var error: int = image.save_png(path)
	print("SHOT seed=%d cliff_at=(%.0f, %.0f) rise=%.1f m per %.0f m eye=(%.0f, %.1f, %.0f) -> %s (%s)"
		% [world_seed, foot.x, foot.y, spot["rise"], SCAN_STEP_M, eye.x, eye.y, eye.z,
			path, error_string(error)])
	viewport.queue_free()
	scene.queue_free()
	current_scene = null
	await process_frame
	await process_frame


## Follows the ground downhill from [param foot] for up to [constant STAND_OFF_M], re-reading the
## gradient every step, and stops early where the floor levels out — which on a gorge is the bank of
## the river that cut it, and is exactly where a player stands when they look up at the face.
func _walk_downhill(world_seed: int, foot: Vector2, fall: Vector2) -> Vector2:
	const STEP_M: float = 4.0
	var set: IslandHeightmap.NoiseSet = IslandHeightmap.make_noise_set(world_seed)
	var here: Vector2 = foot
	var direction: Vector2 = fall
	var walked: float = 0.0
	while walked < STAND_OFF_M:
		var next: Vector2 = here + direction * STEP_M
		var h_here: float = IslandHeightmap.height_from_set(here.x, here.y, set, world_seed)
		var h_next: float = IslandHeightmap.height_from_set(next.x, next.y, set, world_seed)
		if h_next > h_here - 0.15:
			break
		here = next
		walked += STEP_M
		var east: float = IslandHeightmap.height_from_set(here.x + STEP_M, here.y, set, world_seed)
		var north: float = IslandHeightmap.height_from_set(here.x, here.y + STEP_M, set, world_seed)
		var gradient := Vector2(east - h_next, north - h_next)
		if gradient.length() > 0.001:
			# Blended, not replaced: a bare local gradient on a benched face turns the walk back on
			# itself at the first tread.
			direction = (direction * 0.55 - gradient.normalized() * 0.45).normalized()
	# Far enough back that the face is a landform rather than a swatch, even if the floor was short.
	return here + direction * maxf(0.0, 18.0 - walked)


## The `ProceduralWorld` under the level, wherever the level chose to put it.
func _find_world(node: Node) -> Node3D:
	for child: Node in node.get_children():
		if child.has_method(&"height_at"):
			return child as Node3D
		var found: Node3D = _find_world(child)
		if found != null:
			return found
	return null


## Waits for the ground around [param position] to exist — `prime()` is the streamer's blocking
## seam for exactly this (F-324).
##
## The PLAYER is moved there first, and that is not incidental. `ProceduralWorld._stream_anchors()`
## re-derives the streamer's anchor set from the `players` group every update (F-330), so anchors
## set from outside survive about one tick: the first version of this file called `set_anchors()`
## and photographed open water 200 m from a cliff, because every chunk it asked for had been evicted
## again before the frame was drawn. Standing the body where the camera stands is the supported way
## to say "stream here".
func _settle(position: Vector3) -> void:
	for node: Node in root.get_tree().get_nodes_in_group(&"players"):
		var body := node as Node3D
		if body != null:
			body.global_position = position
	if _streamer != null:
		var anchors: Array[Vector3] = [position]
		_streamer.call(&"set_anchors", anchors)
		if _streamer.has_method(&"prime"):
			_streamer.call(&"prime", anchors)
	for _frame: int in 40:
		await process_frame
