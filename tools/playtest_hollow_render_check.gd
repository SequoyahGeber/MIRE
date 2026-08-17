extends SceneTree

## Short Forward+ smoke/performance run for the authored playtest hollow.

const SCENE_PATH: String = "res://levels/playtest_hollow.tscn"
const WARMUP_FRAMES: int = 180
const SAMPLE_FRAMES: int = 360
const MINIMUM_FPS: float = 50.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		push_error("RENDER_CHECK could not load %s" % SCENE_PATH)
		quit(1)
		return
	var scene := packed.instantiate() as Node3D
	if scene == null:
		push_error("RENDER_CHECK could not instantiate playtest hollow")
		quit(1)
		return
	root.add_child(scene)
	current_scene = scene
	for _frame: int in WARMUP_FRAMES:
		await process_frame
	var started_usec := Time.get_ticks_usec()
	for _frame: int in SAMPLE_FRAMES:
		await process_frame
	var elapsed_seconds := float(Time.get_ticks_usec() - started_usec) / 1_000_000.0
	var fps := float(SAMPLE_FRAMES) / elapsed_seconds
	var foliage_count := get_nodes_in_group(&"playtest_hollow_asset").size()
	print(
		"PLAYTEST_HOLLOW_RENDER display=%s frames=%d seconds=%.3f fps=%.1f props=%d"
		% [DisplayServer.get_name(), SAMPLE_FRAMES, elapsed_seconds, fps, foliage_count]
	)
	if fps < MINIMUM_FPS:
		push_error("RENDER_CHECK %.1f FPS is below %.1f FPS" % [fps, MINIMUM_FPS])
		quit(1)
		return
	quit(0)
