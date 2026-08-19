extends CanvasLayer

## Client-local presentation for task 6.5's ExtractionShip — a bottom-centre prompt covering both the
## repair interaction and the board/departure hold, built in code (same reasoning as
## `ui/hud/vitals_hud.gd`: an always-on HUD has nowhere safe to live in a hand-authored scene without
## an exact claim on it, and this autoload needs none).
##
## Registered directly in `project.godot` — `ui/hud/wellspring_hud.gd` shipped the identical pattern
## but was never added to `[autoload]` (see docs/FINDINGS.md); this file does not repeat that gap.
##
## ARCHITECTURE.md §2.2 "VFX, audio, camera, UI" row: client-local only. Every number shown here is
## either the LOCAL player's own inventory (already client-known) or a replicated ExtractionShip
## property; the only mutations sent are `request_repair()`/`request_toggle_departure()`, both of
## which the host re-validates before acting on them.

const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"
const SHIP_GROUP: StringName = &"extraction_ship"
const POLL_SEC: float = 0.15

const COLOUR_PANEL := Color(0.055, 0.086, 0.070, 0.92)
const COLOUR_BORDER := Color(0.345, 0.475, 0.390, 1.0)
const COLOUR_TEXT := Color(0.91, 0.94, 0.89, 1.0)
const COLOUR_PROGRESS := Color(0.894, 0.704, 0.286, 1.0)
const COLOUR_TRACK := Color(0.06, 0.08, 0.07, 0.85)

const BAR_SIZE := Vector2(320.0, 16.0)

var _panel: PanelContainer
var _label: Label
var _track: ColorRect
var _fill: ColorRect

var _nearby: Node3D
var _nearby_mode: StringName = &""
var _poll_elapsed: float = 0.0


func _ready() -> void:
	_build_ui()
	set_process(true)


func _process(delta: float) -> void:
	_poll_elapsed += delta
	if _poll_elapsed < POLL_SEC:
		return
	_poll_elapsed = 0.0
	_refresh_nearby()
	_refresh_panel()


func _input(event: InputEvent) -> void:
	if _nearby == null or not event.is_action_pressed(&"interact"):
		return
	if not get_tree().get_nodes_in_group(BLOCKING_UI_GROUP).is_empty():
		return
	if get_viewport().is_input_handled():
		return
	if _nearby_mode == &"repair":
		_nearby.call(&"request_repair")
	elif _nearby_mode == &"board":
		_nearby.call(&"request_toggle_departure")
	get_viewport().set_input_as_handled()


## Repair takes priority while any stage is left; once fully repaired, only boarding remains
## reachable — the two prompts never compete for the same interact press.
func _refresh_nearby() -> void:
	var best: Node3D = null
	var best_mode: StringName = &""
	var best_distance_sq: float = INF
	var origin: Vector3 = _local_camera_position()
	for node: Node in get_tree().get_nodes_in_group(SHIP_GROUP):
		var ship := node as Node3D
		if ship == null or bool(ship.get("departed")):
			continue
		var mode: StringName = &""
		if int(ship.get("repair_stage")) < 3 and bool(ship.call(&"is_local_player_in_repair_range")):
			mode = &"repair"
		elif int(ship.get("repair_stage")) >= 3 and bool(ship.call(&"is_local_player_in_board_range")):
			mode = &"board"
		if mode == &"":
			continue
		var distance_sq: float = origin.distance_squared_to(ship.global_position)
		if distance_sq < best_distance_sq:
			best = ship
			best_mode = mode
			best_distance_sq = distance_sq
	_nearby = best
	_nearby_mode = best_mode


func _local_camera_position() -> Vector3:
	var camera: Camera3D = get_viewport().get_camera_3d()
	return camera.global_position if camera != null else Vector3.ZERO


func _refresh_panel() -> void:
	if _nearby == null:
		_panel.visible = false
		return
	_panel.visible = true
	if _nearby_mode == &"repair":
		_refresh_repair_panel()
	else:
		_refresh_board_panel()


func _refresh_repair_panel() -> void:
	var cost: Dictionary = _nearby.call(&"current_repair_cost") as Dictionary
	_label.text = "Hold %s to repair the wreck — needs %s" % [
		_interact_key_label(), _format_cost(cost)
	]
	_track.visible = false
	_fill.visible = false


func _refresh_board_panel() -> void:
	var channeling: bool = bool(_nearby.get("departure_channeling"))
	var progress: float = float(_nearby.get("departure_progress_sec"))
	var duration: float = ExtractionShip.DEPARTURE_HOLD_SEC
	var required: int = int(_nearby.get("departure_required_players"))
	if channeling:
		_label.text = "Departing — the whole crew (%d) must stay aboard" % required
		_track.visible = true
		_fill.visible = true
		_fill.size.x = BAR_SIZE.x * clampf(progress / duration, 0.0, 1.0)
	else:
		_label.text = "Press %s to board and leave the Mire" % _interact_key_label()
		_track.visible = false
		_fill.visible = false


func _format_cost(cost: Dictionary) -> String:
	var registry: Node = get_node_or_null(^"/root/Registry")
	var parts: PackedStringArray = []
	for item_id: Variant in cost.keys():
		var display_name: String = String(item_id)
		if registry != null:
			var item_def: Resource = registry.call(&"get_item", item_id) as Resource
			if item_def != null:
				display_name = String(item_def.get("display_name"))
		parts.append("%s x%d" % [display_name, int(cost[item_id])])
	return ", ".join(parts) if not parts.is_empty() else "nothing"


func _interact_key_label() -> String:
	for event: InputEvent in InputMap.action_get_events(&"interact"):
		var key := event as InputEventKey
		if key != null:
			return key.as_text_physical_keycode().to_upper()
	return "INTERACT"


func _build_ui() -> void:
	layer = 5

	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = COLOUR_PANEL
	style.border_color = COLOUR_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10.0)
	_panel.add_theme_stylebox_override("panel", style)
	_panel.visible = false
	add_child(_panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	_panel.add_child(column)

	_label = Label.new()
	_label.add_theme_color_override("font_color", COLOUR_TEXT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_label)

	_track = ColorRect.new()
	_track.color = COLOUR_TRACK
	_track.custom_minimum_size = BAR_SIZE
	_track.visible = false
	column.add_child(_track)

	_fill = ColorRect.new()
	_fill.color = COLOUR_PROGRESS
	_fill.size = Vector2(0.0, BAR_SIZE.y)
	_fill.visible = false
	_track.add_child(_fill)

	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_KEEP_SIZE)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.offset_top = -220.0
	_panel.offset_bottom = -160.0
