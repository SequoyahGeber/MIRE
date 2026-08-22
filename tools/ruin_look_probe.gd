extends SceneTree

## F-493 — look at a procedurally built ruin, from the ground, the way a player meets it.
##
## The layout check proves a ruin is a rectangle of the right pieces with collision on them; it
## cannot tell whether the thing READS as a building. This boots the shipped island, finds the POI
## sites the composer built ruins on, and saves an eye-height three-quarter view of each.
##
##   .agent/bin/agent godot --windowed --script tools/ruin_look_probe.gd

const OUT_DIR: String = "res://assets/audit/terrain"
const SETTLE_FRAMES: int = 240
const MAX_SHOTS: int = 3


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("ruin_look_probe needs a renderer — run it with --windowed")
		quit(1)
		return
	# The composer scene directly, not `run/main_scene` — that is the frontend menu, which has no
	# island in it at all.
	var scene_path := "res://levels/procedural_island.tscn"
	var scene := (load(scene_path) as PackedScene).instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene

	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = false
	viewport.world_3d = scene.get_viewport().world_3d
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 70.0
	camera.far = 3000.0
	viewport.add_child(camera)
	camera.make_current()

	for _frame: int in SETTLE_FRAMES:
		await process_frame

	var sites: Array[Node3D] = []
	var holder: Node = scene.get_node_or_null(^"PoiSites")
	if holder != null:
		for child: Node in holder.get_children():
			if String(child.name).begins_with("ruins") and child.get_child_count() > 0:
				sites.append(child as Node3D)
	print("RUIN_LOOK_PROBE %d ruin site(s)" % sites.size())

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var streamer: Node = scene.get_node_or_null(^"ChunkStreamer")
	for index: int in mini(sites.size(), MAX_SHOTS):
		var site: Node3D = sites[index]
		var centre: Vector3 = site.global_position
		# Stream the ground in AROUND THE RUIN. Without this the shot is a building floating over
		# open water: chunks follow the spawn anchor, and a POI 400 m inland has no terrain under it
		# in a probe with no player walking there.
		if streamer != null:
			var anchors: Array[Vector3] = [centre]
			streamer.call(&"set_anchors", anchors)
			streamer.call(&"prime", anchors, 5)
			for _frame: int in 300:
				await process_frame
		# Eye height, one hall-length back, off the corner — the three-quarter view that shows two
		# walls at once instead of flattening the building into one elevation.
		camera.global_position = centre + Vector3(11.0, 3.4, 10.0)
		camera.look_at(centre + Vector3.UP * 1.6, Vector3.UP)
		for _frame: int in 90:
			await process_frame
		await RenderingServer.frame_post_draw
		var image: Image = viewport.get_texture().get_image()
		var path := "%s/ruin_site_%d.png" % [OUT_DIR, index]
		print("SHOT %s pieces=%d -> %s (%s)" % [
			site.name, site.get_child_count(), ProjectSettings.globalize_path(path),
			error_string(image.save_png(path))])

	print("RUIN_LOOK_PROBE done seed=%s" % str(scene.get(&"world_seed")))
	quit(0)
