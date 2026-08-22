extends SceneTree

## Short Forward+ smoke/performance run for the authored playtest hollow.
##
## @verify windowed — this check measures a frame rate, which is meaningless under the dummy
## rendering driver `--headless` installs, so `agent verify` must launch it with a framebuffer
## (F-556/F-562).
##
## CAVEAT worth reading before trusting the number this asserts. `agent godot --windowed` parks a
## 64x64 window offscreen (F-077), and a frame rate measured at 64x64 is not the frame rate a player
## gets — it is a regression tripwire, not a performance gate. `docs/PERFORMANCE.md`'s method is
## fullscreen on a real display reporting 1%% lows, and this check does not meet it and does not
## claim to. It catches "something made this catastrophically slower"; it cannot tell you the game
## is fast enough (F-547 makes the same distinction for `tools/traversal_profile.gd`).
##

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
	# `failures=N` — F-562, same reason as `tools/hollowmere_render_check.gd`: this asserts a
	# frame-rate floor, so it is a real check and owes the suite a verdict it can read.
	var failures: int = 1 if fps < MINIMUM_FPS else 0
	print("PLAYTEST_HOLLOW_RENDER_CHECK failures=%d" % failures)
	if failures > 0:
		push_error("RENDER_CHECK %.1f FPS is below %.1f FPS" % [fps, MINIMUM_FPS])
		quit(1)
		return
	quit(0)
