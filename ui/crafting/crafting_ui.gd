extends CanvasLayer

## Client-local crafting presentation. The host remains the only crafting authority: this UI renders
## CraftingService's presentation helpers over immutable InventoryService snapshots, and every craft
## leaves as a `request_craft()` that carries nothing but a recipe id. Nothing here predicts an
## inventory change, and a row that looks craftable is a hint — the host repeats every check.
##
## Task 3.1: no station is hardcoded any more. `CraftingService.nearby_station_id()` says which
## registered station the player is next to (derived host-independently on this client, exactly as
## `local_station_in_range()` already was — the host repeats it), rows rebuild for whichever station
## that is, and a timed recipe (the furnace worked example) shows a live percentage instead of a bare
## "Waiting for the host…" — CraftingService.craft_progress() is a client-side estimate from the
## identical RecipeDef every peer already has, not something the host pushed.

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


## One registered recipe. Rebuilt in place from the authoritative snapshot; never mutated locally.
class RecipeRow extends PanelContainer:
	var recipe_id: StringName = &""
	var craft_requested: Callable
	var craftable: bool = false
	var requirement_text: String = ""

	var _output_label: Label
	var _requirement_label: Label
	var _detail_label: Label
	var _craft_button: Button
	var _content_margin: MarginContainer
	var _base_style: StyleBoxFlat
	var _ready_style: StyleBoxFlat


	func setup(recipe: RecipeDef, craft_callback: Callable) -> void:
		recipe_id = recipe.id
		craft_requested = craft_callback
		name = "RecipeRow_%s" % String(recipe_id)
		_build_contents(recipe)
		_build_styles()


	func present(status: Dictionary, requirements: String) -> void:
		requirement_text = requirements
		craftable = bool(status.get("can_request", false))
		_requirement_label.text = requirements
		_craft_button.disabled = not craftable

		var at_station: bool = bool(status.get("at_station", false))
		var has_ingredients: bool = bool(status.get("has_ingredients", false))
		if craftable:
			_detail_label.text = "READY"
			_detail_label.add_theme_color_override("font_color", COLOUR_READY)
		elif not at_station:
			_detail_label.text = "OUT OF RANGE"
			_detail_label.add_theme_color_override("font_color", COLOUR_MUTED)
		elif not has_ingredients:
			_detail_label.text = "MISSING MATERIALS"
			_detail_label.add_theme_color_override("font_color", COLOUR_ERROR)
		else:
			_detail_label.text = String(status.get("detail", ""))
			_detail_label.add_theme_color_override("font_color", COLOUR_MUTED)

		add_theme_stylebox_override("panel", _ready_style if craftable else _base_style)
		accessibility_name = "%s. %s. %s" % [
			_output_label.text, requirements, _detail_label.text
		]


	func set_compact(compact: bool) -> void:
		var padding: int = 8 if compact else 14
		_content_margin.add_theme_constant_override("margin_left", padding)
		_content_margin.add_theme_constant_override("margin_right", padding)
		_output_label.add_theme_font_size_override("font_size", 14 if compact else 17)
		_requirement_label.add_theme_font_size_override("font_size", 11 if compact else 13)
		_detail_label.add_theme_font_size_override("font_size", 10 if compact else 11)
		_craft_button.custom_minimum_size = Vector2(74.0 if compact else 104.0, 30.0 if compact else 36.0)


	func craft_button() -> Button:
		return _craft_button


	func _build_contents(recipe: RecipeDef) -> void:
		_content_margin = MarginContainer.new()
		_content_margin.add_theme_constant_override("margin_left", 14)
		_content_margin.add_theme_constant_override("margin_top", 9)
		_content_margin.add_theme_constant_override("margin_right", 14)
		_content_margin.add_theme_constant_override("margin_bottom", 9)
		add_child(_content_margin)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		_content_margin.add_child(row)

		var text_stack := VBoxContainer.new()
		text_stack.add_theme_constant_override("separation", 2)
		text_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(text_stack)

		var output_name: String = recipe.display_name
		if output_name.is_empty():
			output_name = recipe.output_item.display_name if recipe.output_item != null else String(recipe.id)
		_output_label = Label.new()
		_output_label.text = output_name if recipe.output_count <= 1 else "%s  ×%d" % [
			output_name, recipe.output_count
		]
		_output_label.add_theme_font_size_override("font_size", 17)
		_output_label.add_theme_color_override("font_color", COLOUR_TEXT)
		text_stack.add_child(_output_label)

		_requirement_label = Label.new()
		_requirement_label.add_theme_font_size_override("font_size", 13)
		_requirement_label.add_theme_color_override("font_color", COLOUR_MUTED)
		text_stack.add_child(_requirement_label)

		_detail_label = Label.new()
		_detail_label.add_theme_font_size_override("font_size", 11)
		_detail_label.add_theme_color_override("font_color", COLOUR_MUTED)
		text_stack.add_child(_detail_label)

		var button_center := CenterContainer.new()
		row.add_child(button_center)

		_craft_button = Button.new()
		_craft_button.name = "CraftButton"
		_craft_button.text = "CRAFT"
		_craft_button.custom_minimum_size = Vector2(104.0, 36.0)
		_craft_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_craft_button.pressed.connect(_on_pressed)
		button_center.add_child(_craft_button)

		if recipe.output_item != null and not recipe.output_item.description.is_empty():
			tooltip_text = "%s\n%s" % [output_name, recipe.output_item.description]
		else:
			tooltip_text = output_name


	func _build_styles() -> void:
		_base_style = _row_style(COLOUR_BORDER, 1)
		_ready_style = _row_style(COLOUR_READY, 2)
		add_theme_stylebox_override("panel", _base_style)


	func _row_style(border: Color, border_width: int) -> StyleBoxFlat:
		var style := StyleBoxFlat.new()
		style.bg_color = COLOUR_ROW
		style.border_color = border
		style.set_border_width_all(border_width)
		style.set_corner_radius_all(6)
		return style


	func _on_pressed() -> void:
		craft_requested.call(recipe_id)


var _root: Control
var _shade: ColorRect
var _panel_center: CenterContainer
var _panel: PanelContainer
var _title_label: Label
var _row_box: VBoxContainer
var _empty_label: Label
var _status_label: Label
var _prompt_center: CenterContainer
var _prompt_label: Label
var _rows: Array[RecipeRow] = []
var _open: bool = false
var _in_range: bool = false
var _current_station_id: StringName = &""
var _poll_accumulator: float = 0.0
var _pending_request_id: int = -1
var _request_in_flight: bool = false
var _restore_mouse_captured: bool = false


func _ready() -> void:
	layer = 51
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	InventoryService.local_inventory_changed.connect(_on_inventory_changed)
	CraftingService.craft_confirmed.connect(_on_craft_confirmed)
	_refresh_station()
	get_viewport().size_changed.connect(_apply_responsive_layout)
	_apply_responsive_layout()


func _exit_tree() -> void:
	if InventoryService.local_inventory_changed.is_connected(_on_inventory_changed):
		InventoryService.local_inventory_changed.disconnect(_on_inventory_changed)
	if CraftingService.craft_confirmed.is_connected(_on_craft_confirmed):
		CraftingService.craft_confirmed.disconnect(_on_craft_confirmed)


func _process(delta: float) -> void:
	if _request_in_flight:
		_update_progress_status()
	_poll_accumulator += delta
	if _poll_accumulator < RANGE_POLL_SEC:
		return
	_poll_accumulator = 0.0
	poll_station()


## Re-derives station proximity and closes a panel the player has walked away from. The host would
## reject that craft anyway; leaving the window open would present a lie.
func poll_station() -> void:
	var was_in_range: bool = _in_range
	var previous_station_name: String = _station_display_name(_current_station_id)
	var station_changed: bool = _refresh_station()
	if _open and not _in_range:
		set_open(false)
		_show_status("You stepped away from the %s." % previous_station_name, true)
		return
	if _open or was_in_range != _in_range or station_changed:
		_refresh_rows()


## Shows a live percentage for an in-flight timed craft (the furnace worked example). Recipes with no
## craft_time_sec resolve fast enough that "Waiting for the host…" (set when the request was sent)
## rarely has a chance to be seen, let alone need a progress readout.
func _update_progress_status() -> void:
	var progress: float = CraftingService.craft_progress(_pending_request_id)
	if progress < 0.0:
		return
	_show_status("Crafting… %d%%" % int(round(progress * 100.0)), false)


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
		elif try_open_station():
			get_viewport().set_input_as_handled()
		return
	if _open and event.is_action_pressed(&"ui_cancel"):
		set_open(false)
		get_viewport().set_input_as_handled()


## The interact path. Returns whether the workbench panel actually opened, so the caller knows
## whether the input was consumed.
func try_open_station() -> bool:
	_refresh_station()
	if not _in_range or _other_blocking_ui():
		return false
	set_open(true)
	return true


## The registered station id the panel is currently built for, or &"" if none is in range.
func current_station_id() -> StringName:
	return _current_station_id


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
		_show_status("Craft from the workbench. The host confirms every craft.", false)
		_refresh_rows()
	else:
		remove_from_group(BLOCKING_UI_GROUP)
		_root.release_focus()
		if _restore_mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_refresh_prompt()


func is_open() -> bool:
	return _open


func is_station_in_range() -> bool:
	return _in_range


func is_prompt_visible() -> bool:
	return _prompt_center.visible


func recipe_row_count() -> int:
	return _rows.size()


func displayed_recipe_id(index: int) -> StringName:
	return _rows[index].recipe_id if index >= 0 and index < _rows.size() else &""


func is_recipe_craftable(index: int) -> bool:
	return _rows[index].craftable if index >= 0 and index < _rows.size() else false


func recipe_requirement_text(index: int) -> String:
	return _rows[index].requirement_text if index >= 0 and index < _rows.size() else ""


func craft_button_disabled(index: int) -> bool:
	return _rows[index].craft_button().disabled if index >= 0 and index < _rows.size() else true


## Presses the row's craft button exactly as a click would, so the harness exercises the real seam.
func request_craft_at(index: int) -> int:
	if index < 0 or index >= _rows.size():
		_show_status("That recipe is not on the workbench.", true)
		return -1
	_rows[index].craft_button().emit_signal("pressed")
	return _pending_request_id


func status_text() -> String:
	return _status_label.text


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "CraftingUIRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_shade = ColorRect.new()
	_shade.name = "CraftingShade"
	_shade.color = COLOUR_SCREEN_SHADE
	_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_shade.visible = false
	_root.add_child(_shade)

	_panel_center = CenterContainer.new()
	_panel_center.name = "CraftingCenter"
	_panel_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel_center.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel_center.visible = false
	_root.add_child(_panel_center)

	_panel = PanelContainer.new()
	_panel.name = "CraftingPanel"
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

	_title_label = Label.new()
	_title_label.name = "StationTitle"
	_title_label.text = "CRAFTING"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 22)
	_title_label.add_theme_color_override("font_color", COLOUR_TEXT)
	stack.add_child(_title_label)

	var subtitle := Label.new()
	subtitle.text = "THE HOST VALIDATES AND GRANTS EVERY CRAFT"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 11)
	subtitle.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(subtitle)

	_row_box = VBoxContainer.new()
	_row_box.name = "RecipeRows"
	_row_box.add_theme_constant_override("separation", 6)
	stack.add_child(_row_box)

	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.text = "Craft from the station. The host confirms every craft."
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
	_prompt_center.name = "CraftingPrompt"
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
	_prompt_label.text = "E   USE STATION"
	_prompt_label.add_theme_font_size_override("font_size", 14)
	_prompt_label.add_theme_color_override("font_color", COLOUR_READY)
	prompt_margin.add_child(_prompt_label)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOUR_PANEL
	style.border_color = COLOUR_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	return style


## Re-derives which registered station (if any) the player is next to and rebuilds the row list when
## that identity changes. Returns whether it changed, so poll_station() knows to re-present rows even
## when _in_range itself didn't flip (walking from one station straight into another's range).
func _refresh_station() -> bool:
	var station_id: StringName = CraftingService.nearby_station_id()
	_in_range = station_id != &""
	var changed: bool = station_id != _current_station_id
	if changed:
		_current_station_id = station_id
		_rebuild_rows(station_id)
	_refresh_prompt()
	return changed


## Tears down the previous station's rows and builds fresh ones for `station_id` (&"" clears them).
## RecipeRow instances are never reused across stations — each is bound to one RecipeDef at setup().
func _rebuild_rows(station_id: StringName) -> void:
	for row: RecipeRow in _rows:
		row.queue_free()
	_rows.clear()
	if _empty_label != null:
		_empty_label.queue_free()
		_empty_label = null

	_title_label.text = _station_display_name(station_id).to_upper() if station_id != &"" else "CRAFTING"
	if station_id != &"":
		for recipe: RecipeDef in CraftingService.recipes_for_station(station_id):
			var row := RecipeRow.new()
			row.setup(recipe, _on_craft_requested)
			_rows.append(row)
			_row_box.add_child(row)

	if station_id != &"" and _rows.is_empty():
		_empty_label = Label.new()
		_empty_label.name = "NoRecipes"
		_empty_label.text = "No recipes are registered here."
		_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_empty_label.add_theme_color_override("font_color", COLOUR_MUTED)
		_row_box.add_child(_empty_label)

	_apply_responsive_layout()


func _station_display_name(station_id: StringName) -> String:
	if station_id == &"":
		return "station"
	var station: Resource = Registry.get_station(station_id)
	var display_name: String = String(station.get("display_name")) if station != null else ""
	return display_name if not display_name.is_empty() else String(station_id).capitalize()


func _refresh_prompt() -> void:
	_prompt_center.visible = _in_range and not _open and not _other_blocking_ui()
	if _in_range:
		_prompt_label.text = "E   USE %s" % _station_display_name(_current_station_id).to_upper()


func _refresh_rows() -> void:
	for row: RecipeRow in _rows:
		var status: Dictionary = CraftingService.local_recipe_status(row.recipe_id)
		row.present(status, _requirement_text(row.recipe_id))


## "2/2 Log · 1/3 Stone" — have over need, straight off the authoritative snapshot.
func _requirement_text(recipe_id: StringName) -> String:
	var recipe: RecipeDef = Registry.get_recipe(recipe_id)
	if recipe == null:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for ingredient: RecipeIngredient in recipe.inputs:
		if ingredient == null or ingredient.item == null:
			continue
		var item_id: StringName = ingredient.item.id
		var have: int = mini(InventoryService.local_count(item_id), ingredient.count)
		var display_name: String = ingredient.item.display_name
		if display_name.is_empty():
			display_name = String(item_id)
		parts.append("%d/%d %s" % [have, ingredient.count, display_name])
	return "  ·  ".join(parts)


func _other_blocking_ui() -> bool:
	for node: Node in get_tree().get_nodes_in_group(BLOCKING_UI_GROUP):
		if node != self:
			return true
	return false


func _on_inventory_changed(_slots: Array[Dictionary], _revision: int) -> void:
	_refresh_rows()


func _on_craft_requested(recipe_id: StringName) -> void:
	# A local host answers inside request_craft(), before it has returned the id to compare against —
	# so the in-flight flag, not the id, is what says whether an answer is still owed.
	_request_in_flight = true
	_pending_request_id = CraftingService.request_craft(recipe_id)
	if _request_in_flight:
		_show_status("Waiting for the host…", false)
	_refresh_rows()


func _on_craft_confirmed(request_id: int, accepted: bool, detail: String) -> void:
	if not _request_in_flight and request_id != _pending_request_id:
		return
	_request_in_flight = false
	_show_status(detail, not accepted)
	_refresh_rows()


func _show_status(message: String, error: bool) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", COLOUR_ERROR if error else COLOUR_MUTED)


func _apply_responsive_layout() -> void:
	if _panel == null:
		return
	_apply_layout_for_width(get_viewport().get_visible_rect().size.x)


func _apply_layout_for_width(viewport_width: float) -> void:
	var narrow: bool = viewport_width < NARROW_BREAKPOINT_PX
	_panel.custom_minimum_size = Vector2(
		clampf(viewport_width - 32.0, 280.0, 560.0 if not narrow else 360.0), 0.0
	)
	for row: RecipeRow in _rows:
		row.set_compact(narrow)
	_prompt_label.add_theme_font_size_override("font_size", 12 if narrow else 14)
