extends SceneTree

## Headed GPU cost probe for the playtest level. Renders the real level with a deliberately large
## backing store so the frame is GPU-bound rather than vsync-bound — at the shipped 1152x648 every
## configuration lands on the 120 Hz cap and the ladder tells you nothing. Run WITH a window:
##
##   /Applications/Godot.app/Contents/MacOS/Godot --path . --script tools/perf_probe.gd
##
## The Player is dropped and replaced with a plain Camera3D at its spawn: this measures rendering,
## and the player scene needs gameplay autoloads that --script does not bring up.

const LEVEL := "res://levels/playtest_hollow.tscn"
const WARMUP_FRAMES: int = 40
const SAMPLE_FRAMES: int = 100
## Big enough that no configuration can hide under the display's refresh interval.
const PROBE_WINDOW := Vector2i(2400, 1350)

var _level: Node3D
var _env: Environment
var _sun: DirectionalLight3D
var _atmosphere: Node
var _sky_material: PhysicalSkyMaterial

var _configs: Array[Dictionary] = []
var _config_index: int = -1
var _frame: int = 0
var _accum_ms: float = 0.0
var _results: Array[Dictionary] = []
var _clock: float = 8.35
## 0 = full apply_atmosphere(), 1 = move the sun only, 2 = nothing moves.
var _churn_mode: int = 0


func _initialize() -> void:
	var packed: PackedScene = load(LEVEL)
	_level = packed.instantiate() as Node3D
	var player: Node = _level.get_node_or_null(^"Player")
	var spawn := Vector3(0.0, 1.8, 7.4)
	if player != null:
		spawn = (player as Node3D).position + Vector3(0.0, 1.6, 0.0)
		_level.remove_child(player)
		player.queue_free()
	root.add_child(_level)

	var camera := Camera3D.new()
	camera.position = spawn
	camera.rotation_degrees = Vector3(-6.0, 12.0, 0.0)
	camera.current = true
	_level.add_child(camera)

	_env = (_level.get_node(^"WorldEnvironment") as WorldEnvironment).environment
	_sun = _level.get_node(^"Sun") as DirectionalLight3D
	_atmosphere = _level.get_node_or_null(^"Atmosphere")
	if _env.sky != null:
		_sky_material = _env.sky.sky_material as PhysicalSkyMaterial

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	root.size = PROBE_WINDOW

	# Applied cumulatively: every row is "the row above, minus one more thing".
	_configs = [
		{"name": "as shipped (DayNight applies atmosphere @60Hz)", "apply": Callable()},
		{"name": "  sun still rotates, sky material left alone", "apply": func() -> void: _churn_mode = 1},
		{"name": "  nothing animated (static sky + sun)", "apply": func() -> void: _churn_mode = 2},
		{"name": "  - volumetric fog", "apply": func() -> void: _env.volumetric_fog_enabled = false},
		{"name": "  - fog volumes", "apply": _no_fog_volumes},
		{"name": "  - glow", "apply": func() -> void: _env.glow_enabled = false},
		{"name": "  - sun shadows", "apply": func() -> void: _sun.shadow_enabled = false},
		{"name": "  - cloud deck", "apply": _no_clouds},
	]
	_advance_config()

	print("adapter: %s | Metal %s" % [
		RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version()])
	print("probe window %s @ screen scale %.1f  (backing %s)" % [
		str(PROBE_WINDOW), DisplayServer.screen_get_scale(),
		str(PROBE_WINDOW * int(DisplayServer.screen_get_scale()))])
	print("")


func _no_fog_volumes() -> void:
	for fog_name: String in ["MireGroundFog", "ForestMist", "RuinsMist"]:
		var v: Node = _level.get_node_or_null(NodePath(fog_name))
		if v != null:
			(v as FogVolume).visible = false


func _no_clouds() -> void:
	var deck: Node = _level.get_node_or_null(^"CloudDeck")
	if deck != null:
		(deck as Node3D).visible = false
		deck.set_process(false)


func _advance_config() -> void:
	_config_index += 1
	if _config_index >= _configs.size():
		return
	var apply: Callable = _configs[_config_index].get("apply", Callable())
	if apply.is_valid():
		apply.call()
	_frame = 0
	_accum_ms = 0.0


## Faithful to the real game: DayNight drives the sky from _physics_process, i.e. 60 Hz, not once
## per rendered frame.
func _physics_process(delta: float) -> bool:
	if _config_index >= _configs.size():
		return false
	_clock = fmod(_clock + delta * 24.0 / 900.0, 24.0)
	if _churn_mode == 0 and _atmosphere != null:
		_atmosphere.call(&"set_time_of_day", _clock)
	elif _churn_mode == 1:
		# Only the part that genuinely has to move for a day/night cycle: the light direction.
		var solar_phase: float = (_clock - 6.0) / 24.0 * TAU
		_sun.rotation_degrees = Vector3(
			-sin(solar_phase) * 90.0, -118.0 + (_clock / 24.0) * 236.0, 0.0)
	return false


func _process(delta: float) -> bool:
	if _config_index >= _configs.size():
		_report()
		return true

	_frame += 1
	if _frame <= WARMUP_FRAMES:
		return false
	_accum_ms += delta * 1000.0
	if _frame < WARMUP_FRAMES + SAMPLE_FRAMES:
		return false

	var avg_ms: float = _accum_ms / float(SAMPLE_FRAMES)
	_results.append({"name": _configs[_config_index]["name"], "ms": avg_ms})
	print("%-48s %7.2f ms  %6.0f fps" % [
		_configs[_config_index]["name"], avg_ms, 1000.0 / avg_ms])
	_advance_config()
	return false


func _report() -> void:
	print("\n--- what each step gives back ---")
	for i: int in range(_results.size() - 1):
		var cost: float = float(_results[i]["ms"]) - float(_results[i + 1]["ms"])
		print("%-48s %+7.2f ms" % [String(_results[i + 1]["name"]).strip_edges(), cost])
	if _results.size() > 1:
		var total: float = float(_results[0]["ms"]) - float(_results[_results.size() - 1]["ms"])
		print("%-48s %+7.2f ms" % ["TOTAL removed", total])
