extends CanvasLayer

## Client-local chest-opening presentation. Chest remains the only authority: this UI finds the
## nearest chest, turns [E] into exactly one `request_open()`, and renders whatever
## `open_confirmed` reports — it never predicts a roll or a grant. Joins the D-032 interlock
## (`blocks_gameplay_input`) like InventoryUI/CraftingUI, so at most one cursor-owning panel is ever
## open at a time.

const CHEST_GROUP: StringName = &"chest"
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"
const RANGE_POLL_SEC: float = 0.15
const NARROW_BREAKPOINT_PX: float = 700.0

const COLOUR_SCREEN_SHADE := Color(0.018, 0.035, 0.028, 0.78)
const COLOUR_PANEL := Color(0.055, 0.086, 0.070, 0.97)
const COLOUR_ROW := Color(0.085, 0.125, 0.102, 0.98)
const COLOUR_BORDER := Color(0.345, 0.475, 0.390, 1.0)
const COLOUR_READY := Color(0.894, 0.704, 0.286, 1.0)
const COLOUR_TEXT := Color(0.91, 0.94, 0.89, 1.0)
const COLOUR_MUTED := Color(0.60, 0.69, 0.62, 1.0)
const COLOUR_ERROR := Color(0.96, 0.47, 0.39, 1.0)


## One granted item or coin amount. Built fresh per open, never mutated in place.
class RewardRow extends PanelContainer:
	func setup(display_name: String, amount: int) -> void:
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 12)
		margin.add_theme_constant_override("margin_top", 6)
		margin.add_theme_constant_override("margin_right", 12)
		margin.add_theme_constant_override("margin_bottom", 6)
		add_child(margin)

		var row := HBoxContainer.new()
		margin.add_child(row)

		var name_label := Label.new()
		name_label.text = display_name
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.add_theme_font_size_override("font_size", 14)
		name_label.add_theme_color_override("font_color", COLOUR_TEXT)
		row.add_child(name_label)

		var amount_label := Label.new()
		amount_label.text = "×%d" % amount
		amount_label.add_theme_font_size_override("font_size", 14)
		amount_label.add_theme_color_override("font_color", COLOUR_READY)
		row.add_child(amount_label)

		var style := StyleBoxFlat.new()
		style.bg_color = COLOUR_ROW
		style.border_color = COLOUR_BORDER
		style.set_border_width_all(1)
		style.set_corner_radius_all(6)
		add_theme_stylebox_override("panel", style)


var _root: Control
var _shade: ColorRect
var _panel_center: CenterContainer
var _panel: PanelContainer
var _reward_box: VBoxContainer
var _status_label: Label
var _prompt_center: CenterContainer
var _prompt_label: Label
var _open: bool = false
var _poll_accumulator: float = 0.0
var _nearest_chest: Node3D
var _pending_chest: Node3D
var _pending_request_id: int = -1
var _request_in_flight: bool = false
var _restore_mouse_captured: bool = false


func _ready() -> void:
	layer = 52
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_refresh_nearest()


func _process(delta: float) -> void:
	_poll_accumulator += delta
	if _poll_accumulator < RANGE_POLL_SEC:
		return
	_poll_accumulator = 0.0
	_refresh_nearest()


func _input(event: InputEvent) -> void:
	if get_viewport().is_input_handled():
		return
	if event.is_action_pressed(&"interact"):
		var focus_owner: Control = get_viewport().gui_get_focus_owner()
		if focus_owner is LineEdit or focus_owner is TextEdit:
			return
		if _open:
			set_open(false)
			get_viewport().set_input_as_handled()
		elif try_open_nearest():
			get_viewport().set_input_as_handled()
		return
	if _open and event.is_action_pressed(&"ui_cancel"):
		set_open(false)
		get_viewport().set_input_as_handled()


## The interact path. Returns whether a request was actually sent, so the caller knows whether the
## input was consumed.
func try_open_nearest() -> bool:
	_refresh_nearest()
	if _nearest_chest == null or _other_blocking_ui():
		return false
	if bool(_nearest_chest.get("opened")):
		return false

	_pending_chest = _nearest_chest
	if not _pending_chest.is_connected(&"open_confirmed", _on_open_confirmed):
		_pending_chest.connect(&"open_confirmed", _on_open_confirmed)
	_request_in_flight = true
	set_open(true)
	_clear_rewards()
	_show_status("Opening the chest…", false)
	_pending_request_id = int(_pending_chest.call("request_open"))
	return true


func set_open(open: bool) -> void:
	if open == _open:
		return
	_open = open
	_shade.visible = open
	_panel_center.visible = open
	if open:
		add_to_group(BLOCKING_UI_GROUP)
		_restore_mouse_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		remove_from_group(BLOCKING_UI_GROUP)
		_root.release_focus()
		if _restore_mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_request_in_flight = false
	_refresh_prompt()


func is_open() -> bool:
	return _open


func nearest_chest() -> Node3D:
	return _nearest_chest


func is_prompt_visible() -> bool:
	return _prompt_center.visible


func status_text() -> String:
	return _status_label.text


func reward_row_count() -> int:
	return _reward_box.get_child_count()


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "ChestUIRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_shade = ColorRect.new()
	_shade.name = "ChestShade"
	_shade.color = COLOUR_SCREEN_SHADE
	_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_shade.visible = false
	_root.add_child(_shade)

	_panel_center = CenterContainer.new()
	_panel_center.name = "ChestCenter"
	_panel_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel_center.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel_center.visible = false
	_root.add_child(_panel_center)

	_panel = PanelContainer.new()
	_panel.name = "ChestPanel"
	_panel.custom_minimum_size = Vector2(320.0, 0.0)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_panel_center.add_child(_panel)

	var panel_margin := MarginContainer.new()
	panel_margin.add_theme_constant_override("margin_left", 18)
	panel_margin.add_theme_constant_override("margin_top", 16)
	panel_margin.add_theme_constant_override("margin_right", 18)
	panel_margin.add_theme_constant_override("margin_bottom", 16)
	_panel.add_child(panel_margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 10)
	panel_margin.add_child(stack)

	var title := Label.new()
	title.text = "CHEST"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", COLOUR_TEXT)
	stack.add_child(title)

	_reward_box = VBoxContainer.new()
	_reward_box.name = "Rewards"
	_reward_box.add_theme_constant_override("separation", 6)
	stack.add_child(_reward_box)

	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.text = "Open a chest to see what's inside."
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(_status_label)

	var close_hint := Label.new()
	close_hint.text = "E / ESC  CLOSE"
	close_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close_hint.add_theme_font_size_override("font_size", 10)
	close_hint.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(close_hint)

	_prompt_center = CenterContainer.new()
	_prompt_center.name = "ChestPrompt"
	_prompt_center.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_prompt_center.offset_top = -152.0
	_prompt_center.offset_bottom = -104.0
	_prompt_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt_center.visible = false
	_root.add_child(_prompt_center)

	var prompt_panel := PanelContainer.new()
	prompt_panel.name = "PromptPanel"
	prompt_panel.add_theme_stylebox_override("panel", _panel_style())
	prompt_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt_center.add_child(prompt_panel)

	var prompt_margin := MarginContainer.new()
	prompt_margin.add_theme_constant_override("margin_left", 12)
	prompt_margin.add_theme_constant_override("margin_top", 6)
	prompt_margin.add_theme_constant_override("margin_right", 12)
	prompt_margin.add_theme_constant_override("margin_bottom", 6)
	prompt_panel.add_child(prompt_margin)

	_prompt_label = Label.new()
	_prompt_label.text = "E   OPEN CHEST"
	_prompt_label.add_theme_font_size_override("font_size", 14)
	_prompt_label.add_theme_color_override("font_color", COLOUR_READY)
	prompt_margin.add_child(_prompt_label)

	get_viewport().size_changed.connect(_apply_responsive_layout)
	_apply_responsive_layout()


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOUR_PANEL
	style.border_color = COLOUR_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	return style


## Nearest unopened chest within ITS OWN request_range_m, read straight off the node so the prompt
## never disagrees with what request_open() will actually accept. No ChestWorld bridge exists (task
## 3.5 places no props); this scan is the whole discovery mechanism.
func _refresh_nearest() -> void:
	var player: Node3D = _local_player()
	var closest: Node3D = null
	var closest_distance_sq: float = INF
	if player != null:
		for node: Node in get_tree().get_nodes_in_group(CHEST_GROUP):
			var chest := node as Node3D
			if chest == null or not is_instance_valid(chest):
				continue
			var range_m: float = float(chest.get("request_range_m"))
			var distance_sq: float = player.global_position.distance_squared_to(chest.global_position)
			if distance_sq <= range_m * range_m and distance_sq < closest_distance_sq:
				closest = chest
				closest_distance_sq = distance_sq
	_nearest_chest = closest
	_refresh_prompt()


func _refresh_prompt() -> void:
	var showable: bool = (
		_nearest_chest != null
		and not bool(_nearest_chest.get("opened"))
		and not _open
		and not _other_blocking_ui()
	)
	_prompt_center.visible = showable


func _other_blocking_ui() -> bool:
	for node: Node in get_tree().get_nodes_in_group(BLOCKING_UI_GROUP):
		if node != self:
			return true
	return false


func _local_player() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null


func _on_open_confirmed(request_id: int, accepted: bool, granted: Dictionary, detail: String) -> void:
	if not _request_in_flight and request_id != _pending_request_id:
		return
	_request_in_flight = false
	if accepted:
		_populate_rewards(granted)
		_show_status("You found:" if not granted.is_empty() else "The chest was empty.", false)
	else:
		_clear_rewards()
		_show_status(detail, true)


func _populate_rewards(granted: Dictionary) -> void:
	_clear_rewards()
	var ids: Array[StringName] = []
	for item_id: StringName in granted:
		ids.append(item_id)
	ids.sort()
	for item_id: StringName in ids:
		var display_name: String = String(item_id)
		var item: ItemDef = Registry.get_item(item_id)
		if item != null and not item.display_name.is_empty():
			display_name = item.display_name
		var row := RewardRow.new()
		row.setup(display_name, int(granted[item_id]))
		_reward_box.add_child(row)


func _clear_rewards() -> void:
	for child: Node in _reward_box.get_children():
		_reward_box.remove_child(child)
		child.queue_free()


func _show_status(message: String, error: bool) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", COLOUR_ERROR if error else COLOUR_MUTED)


func _apply_responsive_layout() -> void:
	if _panel == null:
		return
	var viewport_width: float = get_viewport().get_visible_rect().size.x
	var narrow: bool = viewport_width < NARROW_BREAKPOINT_PX
	_panel.custom_minimum_size = Vector2(
		clampf(viewport_width - 32.0, 260.0, 420.0 if not narrow else 320.0), 0.0
	)
	_prompt_label.add_theme_font_size_override("font_size", 12 if narrow else 14)
