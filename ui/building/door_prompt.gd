extends CanvasLayer

## Client-local door interaction: find the nearest placed door, show what [E] would do, and turn one
## press into exactly one `request_toggle()`.
##
## `systems/building/buildable_door.gd` remains the only authority — this predicts nothing and
## renders nothing about the door's state that it did not learn from the door itself. It exists
## because a system nothing calls is not shipped (F-151, the same week `ui/loot/chest_ui.gd` was
## found orphaned), and because a door with no prompt is a door a player walks past.
##
## Joins nothing: it owns no cursor and blocks no input, so it is NOT part of the D-032
## `blocks_gameplay_input` interlock. It does respect it — while any cursor-owning panel is open,
## [E] belongs to that panel.

const DOOR_GROUP: StringName = &"door"
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"
const POLL_SEC: float = 0.12

const COLOUR_PANEL := Color(0.055, 0.086, 0.070, 0.88)
const COLOUR_BORDER := Color(0.345, 0.475, 0.390, 1.0)
const COLOUR_TEXT := Color(0.91, 0.94, 0.89, 1.0)
const COLOUR_KEY := Color(0.894, 0.704, 0.286, 1.0)

var _label: RichTextLabel
var _panel: PanelContainer
var _nearest: Node3D
var _poll_timer: float = 0.0


func _ready() -> void:
	layer = 5
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	set_process(true)


func _build_ui() -> void:
	var root_control := Control.new()
	root_control.name = "DoorPromptRoot"
	root_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root_control)

	_panel = PanelContainer.new()
	_panel.name = "Prompt"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -150.0
	_panel.offset_right = 150.0
	_panel.offset_top = -168.0
	_panel.offset_bottom = -128.0

	var style := StyleBoxFlat.new()
	style.bg_color = COLOUR_PANEL
	style.border_color = COLOUR_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	_panel.add_theme_stylebox_override("panel", style)

	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_color_override("default_color", COLOUR_TEXT)
	_label.add_theme_font_size_override("normal_font_size", 15)
	_panel.add_child(_label)
	root_control.add_child(_panel)
	_panel.visible = false


func _process(delta: float) -> void:
	_poll_timer -= delta
	if _poll_timer > 0.0:
		return
	_poll_timer = POLL_SEC
	_refresh_nearest()


func _input(event: InputEvent) -> void:
	if get_viewport().is_input_handled():
		return
	if not event.is_action_pressed(&"interact"):
		return
	var focus_owner: Control = get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit or focus_owner is TextEdit:
		return
	if _blocking_ui_open():
		return
	_refresh_nearest()
	if _nearest == null:
		return
	if bool(_nearest.call("request_toggle")):
		get_viewport().set_input_as_handled()


## Nearest door whose own `interact_range_m` the player is actually inside — the door decides its
## reach, so the prompt can never offer an interaction the host would refuse.
func _refresh_nearest() -> void:
	_nearest = null
	var player: Node3D = _local_player()
	if player == null:
		_hide()
		return
	var best: float = INF
	for node: Node in get_tree().get_nodes_in_group(DOOR_GROUP):
		var door: Node3D = node as Node3D
		if door == null or not door.is_inside_tree():
			continue
		var reach: float = float(door.get(&"interact_range_m"))
		var distance: float = door.global_position.distance_to(player.global_position)
		if distance <= reach and distance < best:
			best = distance
			_nearest = door
	if _nearest == null:
		_hide()
		return
	var verb: String = "Close" if bool(_nearest.get(&"open")) else "Open"
	_label.text = "[center][color=#%s]E[/color]  %s[/center]" % [COLOUR_KEY.to_html(false), verb]
	_panel.visible = true


func _hide() -> void:
	if _panel != null:
		_panel.visible = false


func _blocking_ui_open() -> bool:
	for node: Node in get_tree().get_nodes_in_group(BLOCKING_UI_GROUP):
		if node is CanvasItem and (node as CanvasItem).visible:
			return true
		if node.has_method(&"is_open") and bool(node.call(&"is_open")):
			return true
	return false


## The same lookup `ui/loot/chest_ui.gd` uses: the body in `&"players"` this peer has authority
## over. PlayerNet indexes by peer id and has no "which one is mine" accessor, and authority is the
## honest answer in both offline and session play.
func _local_player() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null
