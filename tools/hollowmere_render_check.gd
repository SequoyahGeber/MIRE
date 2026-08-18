extends SceneTree

## Render Hollowmere from several vantage points and measure the frame rate.
##
## Run with:  .agent/bin/agent godot --script tools/hollowmere_render_check.gd
##
## Two jobs. It captures viewport images so the map can be *looked at* without
## anybody opening the editor, and it times a sample so a 356 m map with 18,000
## plants on it cannot quietly become unplayable while every other check stays
## green. Both matter: the numeric checks prove the map is correct, and correct is
## not the same as good.

const SCENE_PATH: String = "res://levels/hollowmere.tscn"
const OUT_DIR: String = "res://assets/maps/preview"
const WARMUP_FRAMES: int = 40
const SAMPLE_FRAMES: int = 120
const MINIMUM_FPS: float = 30.0

## Named viewpoints, chosen to show a different part of the valley each.
const SHOTS: Array = [
	{"name": "hold", "from": Vector3(-58.0, 22.0, 52.0), "at": Vector3(-34.0, 2.0, 18.0)},
	{"name": "mere", "from": Vector3(4.0, 34.0, 132.0), "at": Vector3(52.0, -2.0, 78.0)},
	{"name": "gorge", "from": Vector3(-62.0, 30.0, -34.0), "at": Vector3(-16.0, 4.0, -74.0)},
	{"name": "plateau", "from": Vector3(-24.0, 44.0, -18.0), "at": Vector3(-96.0, 16.0, -84.0)},
	{"name": "valley", "from": Vector3(-120.0, 96.0, 150.0), "at": Vector3(10.0, 0.0, -10.0)},
]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		push_error("HOLLOWMERE_RENDER could not load %s" % SCENE_PATH)
		quit(1)
		return
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene

	var camera := Camera3D.new()
	camera.name = "ShotCamera"
	camera.fov = 62.0
	camera.far = 520.0
	scene.add_child(camera)
	camera.current = true

	for _frame: int in WARMUP_FRAMES:
		await process_frame

	# `agent godot` always passes --headless (it exists to serialise the shared
	# import cache, F-044), and headless uses the dummy rendering driver: nothing
	# is ever drawn, so `RenderingServer.frame_post_draw` never emits and awaiting
	# it hangs the run forever rather than failing. Capture therefore only happens
	# when there is a real display; through `agent godot` this script still does
	# its other job of timing the frame rate.
	var can_capture := DisplayServer.get_name() != "headless"
	if not can_capture:
		print("HOLLOWMERE_RENDER capture skipped — headless has no framebuffer")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for shot_value: Variant in (SHOTS if can_capture else []):
		var shot := shot_value as Dictionary
		camera.global_position = shot["from"] as Vector3
		camera.look_at(shot["at"] as Vector3, Vector3.UP)
		camera.current = true
		for _frame: int in 8:
			await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		var path := "%s/hollowmere_%s.png" % [OUT_DIR, String(shot["name"])]
		image.save_png(ProjectSettings.globalize_path(path))
		print("HOLLOWMERE_SHOT %s -> %s" % [String(shot["name"]), path])

	var started := Time.get_ticks_usec()
	for _frame: int in SAMPLE_FRAMES:
		await process_frame
	var seconds := float(Time.get_ticks_usec() - started) / 1_000_000.0
	var fps := float(SAMPLE_FRAMES) / seconds
	var props := get_nodes_in_group(&"authored_world_prop").size()
	print("HOLLOWMERE_RENDER display=%s fps=%.1f prop_bodies=%d" % [DisplayServer.get_name(), fps, props])
	if fps < MINIMUM_FPS:
		push_error("HOLLOWMERE_RENDER %.1f FPS is below %.1f" % [fps, MINIMUM_FPS])
		quit(1)
		return
	quit(0)
