extends CanvasLayer

## Always-available performance and state readout. F3 cycles hidden -> compact -> full.
##
## Network authority: CLIENT-LOCAL (ARCHITECTURE.md §2.2, last row). Everything here reads local
## state only; the overlay never sends or receives anything.
##
## Autoload — builds its own UI in code so there is no scene to wire and no scene to merge-conflict.
## Other systems add their own readouts without touching this file:
##
##     DebugOverlay.watch(&"chunks", func() -> String: return str(loaded_chunks.size()))
##     DebugOverlay.track_group(&"enemies")

enum Mode { HIDDEN, COMPACT, FULL }

## Readouts refresh at this rate rather than every frame — the overlay should never be what costs
## you the frame you are trying to measure.
const REFRESH_HZ: float = 10.0

var mode: Mode = Mode.COMPACT

var _watches: Dictionary[StringName, Callable] = {}
var _tracked_groups: Array[StringName] = []
var _label: RichTextLabel
var _panel: PanelContainer
var _accumulator: float = 0.0


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	track_group(&"players")
	track_group(&"enemies")
	_apply_mode()


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.position = Vector2(8, 8)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var margin := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 6)
	_panel.add_child(margin)

	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.custom_minimum_size = Vector2(260, 0)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(_label)

	add_child(_panel)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		if (event as InputEventKey).keycode == KEY_F3:
			cycle_mode()
			get_viewport().set_input_as_handled()


func cycle_mode() -> void:
	match mode:
		Mode.HIDDEN:
			mode = Mode.COMPACT
		Mode.COMPACT:
			mode = Mode.FULL
		_:
			mode = Mode.HIDDEN
	_apply_mode()


func set_mode(new_mode: Mode) -> void:
	mode = new_mode
	_apply_mode()


func _apply_mode() -> void:
	_panel.visible = mode != Mode.HIDDEN
	set_process(mode != Mode.HIDDEN)
	if _panel.visible:
		_refresh()


## Add a named readout. The callable takes no arguments and returns anything printable.
func watch(key: StringName, provider: Callable) -> void:
	_watches[key] = provider


func unwatch(key: StringName) -> void:
	_watches.erase(key)


## Show a live count of the nodes in a group. Cheap at 10Hz; do not call this for a group with
## thousands of members.
func track_group(group: StringName) -> void:
	if not _tracked_groups.has(group):
		_tracked_groups.append(group)


func _process(delta: float) -> void:
	_accumulator += delta
	if _accumulator < 1.0 / REFRESH_HZ:
		return
	_accumulator = 0.0
	_refresh()


func _refresh() -> void:
	var fps: float = Engine.get_frames_per_second()
	var frame_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0

	var lines: Array[String] = []
	lines.append("[b]%s FPS[/b]  %.1f ms" % [_colour_fps(fps), frame_ms])

	if mode == Mode.COMPACT:
		_label.text = "\n".join(lines)
		return

	lines.append("physics %.2f ms   draw %d" % [
		physics_ms, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	])
	lines.append("nodes %d   objects %d   mem %.1f MB" % [
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
	])

	lines.append(_position_line())
	lines.append(_net_line())

	for group: StringName in _tracked_groups:
		lines.append("%s: %d" % [group, get_tree().get_node_count_in_group(group)])

	for key: StringName in _watches:
		var provider: Callable = _watches[key]
		if not provider.is_valid():
			continue
		lines.append("%s: %s" % [key, provider.call()])

	_label.text = "\n".join(lines)


## Reads the active camera rather than the player, so it works before there is a player and keeps
## the overlay decoupled from gameplay code.
func _position_line() -> String:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return "pos: —"
	var p: Vector3 = camera.global_position
	return "pos %.1f, %.1f, %.1f   yaw %.0f°" % [
		p.x, p.y, p.z, rad_to_deg(camera.global_rotation.y)
	]


func _net_line() -> String:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return "net: offline"
	var role: String = "host" if multiplayer.is_server() else "client"
	return "net: %s  id %d  peers %d" % [
		role, multiplayer.get_unique_id(), multiplayer.get_peers().size()
	]


func _colour_fps(fps: float) -> String:
	var colour: String = "9f9"
	if fps < 30.0:
		colour = "f77"
	elif fps < 55.0:
		colour = "fd7"
	return "[color=#%s]%d[/color]" % [colour, int(fps)]
