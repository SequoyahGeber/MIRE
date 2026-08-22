extends SceneTree

## Eyeball evidence for the ocean's crest glint (`world/environment/water_low_poly.gdshader`).
##
##   .agent/bin/agent godot --windowed --script tools/ocean_glint_shot.gd
##
## Boots the shipped island scene without a player and renders the sea from three places — a
## standing view off the shore, a low grazing view across the water, and a raised look down the
## coast — into `assets/audit/terrain/`. Renders through its own SubViewport for the same reason
## `tools/atmosphere_look_shot.gd` does: the wrapper's window is 64x64 (F-077) and is irrelevant.
##
## Each frame is taken a different number of seconds into the wave cycle, because the glint is
## gated on a slow drifting patch field — a single instant proves nothing about whether the whole
## sea lights up at once.

const WIDTH: int = 1280
const HEIGHT: int = 720
const OUT_DIR: String = "res://assets/audit/terrain"
const SETTLE_FRAMES: int = 8

var _shots: Array = [
	{"name": "ocean_glint_shore", "pos": Vector3(0.0, 3.2, 330.0), "look": Vector3(0.0, 1.6, 520.0), "warm": 30},
	{"name": "ocean_glint_grazing", "pos": Vector3(0.0, 1.1, 360.0), "look": Vector3(60.0, 1.0, 620.0), "warm": 140},
	{"name": "ocean_glint_high", "pos": Vector3(0.0, 34.0, 300.0), "look": Vector3(30.0, 0.0, 560.0), "warm": 260},
]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("ocean_glint_shot needs a renderer — run it with --windowed")
		quit(1)
		return
	var scene := (load("res://levels/procedural_island.tscn") as PackedScene).instantiate() as Node3D
	scene.set(&"build_player", false)
	root.add_child(scene)
	current_scene = scene

	var viewport := SubViewport.new()
	viewport.size = Vector2i(WIDTH, HEIGHT)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.world_3d = scene.get_viewport().world_3d
	root.add_child(viewport)
	var cam := Camera3D.new()
	cam.fov = 70.0
	cam.far = 2000.0
	viewport.add_child(cam)
	cam.current = true

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for shot: Dictionary in _shots:
		cam.global_position = shot["pos"]
		cam.look_at(shot["look"], Vector3.UP)
		# TIME advances with real frames, so "a different point in the wave cycle" means letting
		# frames run — there is no way to scrub a shader's TIME from script.
		for i in int(shot["warm"]) + SETTLE_FRAMES:
			await process_frame
		var image := viewport.get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, shot["name"]]
		image.save_png(ProjectSettings.globalize_path(path))
		print("wrote ", ProjectSettings.globalize_path(path))
	quit(0)
