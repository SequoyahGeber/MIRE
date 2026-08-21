extends CanvasLayer

## Client-local build-mode presentation (F-086 — 3.6 shipped BuildService/BuildGhost/PlacementValidator
## with no way for a player to reach any of it). Built directly by
## entities/player/player_controller.gd for the local player only, the same way it builds its
## Viewmodel and debug avatar — NOT an autoload like ui/crafting/crafting_ui.gd or
## ui/inventory/inventory_ui.gd. Nobody needs to see another player's piece picker (client-local
## presentation, §2.2 last row, same as the ghost it sits beside), so this is built per-player.
## Piece rotate/destroy (task 7.6: real InputMap actions "build_rotate"/"build_destroy", each
## keyboard/mouse plus gamepad) are handled in player_controller.gd itself, not here — this bar is
## selection and status display only. Toggling
## build mode (the existing "build" InputMap action) is also read in player_controller.gd, so this
## bar and the player's build-mode state can never disagree about whether the mode is on; the player
## pushes state into this bar (`set_active`, `set_selected_piece`, `set_ghost_status`) rather than
## this bar polling for it.
##
## NETWORK AUTHORITY: none (§2.2 last row). A slot click only emits `piece_selected` — the player
## decides whether/how to act on it, and BuildService remains the only thing that ever actually
## places or destroys anything.
##
## F-217: `PieceSlot` now also selects via `ui_accept` while focused, and every slot chains to its
## row neighbours (`focus_neighbor_left`/`_right`, wrapping) so a bare controller can actually change
## which piece is selected — before this, toggle/rotate/confirm/destroy were gamepad-bound (task 7.6)
## but selection itself was mouse-only.

const COLOUR_PANEL := Color(0.055, 0.086, 0.070, 0.97)
const COLOUR_ROW := Color(0.085, 0.125, 0.102, 0.98)
const COLOUR_BORDER := Color(0.345, 0.475, 0.390, 1.0)
const COLOUR_READY := Color(0.894, 0.704, 0.286, 1.0)
const COLOUR_TEXT := Color(0.91, 0.94, 0.89, 1.0)
const COLOUR_MUTED := Color(0.60, 0.69, 0.62, 1.0)
const COLOUR_ERROR := Color(0.96, 0.47, 0.39, 1.0)
## F-217: keyboard/gamepad focus ring, same hue `InventoryUI` picked (F-209) for the identical
## "focused but not necessarily the active one" state — distinct from COLOUR_READY, which marks the
## piece build mode is actually placing.
const COLOUR_FOCUS := Color(0.55, 0.85, 0.95, 1.0)
## Snapping ON. Deliberately the same amber as COLOUR_READY: snapping on is the normal, expected
## state of build mode, so it reads as "armed" rather than as a warning.
const COLOUR_SNAP_ON := COLOUR_READY
## Snapping OFF — muted, because free placement is the quieter mode, not an error.
const COLOUR_SNAP_OFF := Color(0.60, 0.69, 0.62, 1.0)


## One registered buildable. Selecting never places anything — it only tells the player which piece
## the ghost should preview.
class PieceSlot extends PanelContainer:
	var piece_id: StringName = &""
	var select_requested: Callable

	var _label: Label
	var _icon: TextureRect
	var _base_style: StyleBoxFlat
	var _selected_style: StyleBoxFlat
	var _focus_style: StyleBoxFlat
	var _selected: bool = false
	var _has_focus: bool = false


	func setup(def: Resource, select_callback: Callable) -> void:
		piece_id = StringName(String(def.get(&"id")))
		select_requested = select_callback
		name = "BuildSlot_%s" % String(piece_id)
		custom_minimum_size = Vector2(88.0, 56.0)
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		focus_mode = Control.FOCUS_ALL
		_build_contents(def)
		_build_styles()
		focus_entered.connect(func() -> void: _has_focus = true; _update_style())
		focus_exited.connect(func() -> void: _has_focus = false; _update_style())


	func present(selected: bool) -> void:
		_selected = selected
		_update_style()


	## F-217: `PanelContainer` has no native `"focus"` theme item (the same gap F-215 hit on
	## `Slider`), so keyboard/gamepad focus is a `"panel"` stylebox swap here — the identical
	## technique `InventoryUI.InventorySlot` already uses for the same control type. Priority: focus
	## beats selected, so navigating away from the currently-building piece is never mistaken for
	## still standing on it.
	func _update_style() -> void:
		var style: StyleBoxFlat = _base_style
		if _selected:
			style = _selected_style
		if _has_focus:
			style = _focus_style
		add_theme_stylebox_override("panel", style)


	func _build_contents(def: Resource) -> void:
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 6)
		margin.add_theme_constant_override("margin_top", 4)
		margin.add_theme_constant_override("margin_right", 6)
		margin.add_theme_constant_override("margin_bottom", 4)
		add_child(margin)

		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", 2)
		margin.add_child(stack)

		_icon = TextureRect.new()
		_icon.custom_minimum_size = Vector2(0.0, 22.0)
		_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.texture = def.get(&"icon")
		_icon.visible = _icon.texture != null
		stack.add_child(_icon)

		var display_name: String = String(def.get(&"display_name"))
		if display_name.is_empty():
			display_name = String(piece_id)

		_label = Label.new()
		_label.text = display_name
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_label.add_theme_font_size_override("font_size", 12)
		_label.add_theme_color_override("font_color", COLOUR_TEXT)
		stack.add_child(_label)

		var cost_label := Label.new()
		cost_label.text = _cost_text(def.get(&"cost"))
		cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cost_label.add_theme_font_size_override("font_size", 10)
		cost_label.add_theme_color_override("font_color", COLOUR_MUTED)
		stack.add_child(cost_label)

		var description: String = String(def.get(&"description"))
		tooltip_text = "%s\n%s" % [display_name, description] if not description.is_empty() \
			else display_name
		accessibility_name = "%s build slot" % display_name


	func _cost_text(cost: Dictionary) -> String:
		if cost.is_empty():
			return "free"
		var parts: PackedStringArray = PackedStringArray()
		for item_id: StringName in cost:
			parts.append("%d %s" % [int(cost[item_id]), String(item_id)])
		return "  ·  ".join(parts)


	func _build_styles() -> void:
		_base_style = _slot_style(COLOUR_BORDER, 1)
		_selected_style = _slot_style(COLOUR_READY, 3)
		_focus_style = _slot_style(COLOUR_FOCUS, 3)
		add_theme_stylebox_override("panel", _base_style)


	func _slot_style(border: Color, border_width: int) -> StyleBoxFlat:
		var style := StyleBoxFlat.new()
		style.bg_color = COLOUR_ROW
		style.border_color = border
		style.set_border_width_all(border_width)
		style.set_corner_radius_all(6)
		return style


	func _gui_input(event: InputEvent) -> void:
		if (
			event is InputEventMouseButton
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
			and (event as InputEventMouseButton).pressed
		):
			select_requested.call(piece_id)
			return
		# F-217: the gamepad/keyboard equivalent of the mouse click above — same
		# ui_accept-in-_gui_input shape F-209 gave InventorySlot, but a single select_requested call
		# is the whole action here (no carry state to track, unlike a slot move).
		if event.is_action_pressed(&"ui_accept"):
			select_requested.call(piece_id)
			accept_event()


## Emitted on a slot click. The player decides what to do with it (player_controller.gd's
## set_selected_build_piece()) — this file never touches BuildGhost or BuildService directly.
signal piece_selected(piece_id: StringName)

var _root: Control
var _bar_center: CenterContainer
var _panel: PanelContainer
var _row: HBoxContainer
var _hint_label: Label
var _status_label: Label
var _slots: Array[PieceSlot] = []
## Mirrors BuildGhost's own `_snapping`, pushed in through set_snapping(). Same default, because the
## bar is built before the player ever presses the toggle and must not open showing the wrong mode.
var _snapping: bool = true
var _snap_label: Label
var _selected_piece_id: StringName = &""


func _ready() -> void:
	layer = 41
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_present_snapping()
	_populate_slots()
	var service: Node = get_node_or_null(^"/root/BuildService")
	if service != null:
		service.connect(&"build_confirmed", _on_build_confirmed)


func _exit_tree() -> void:
	var service: Node = get_node_or_null(^"/root/BuildService")
	if service != null and service.is_connected(&"build_confirmed", _on_build_confirmed):
		service.disconnect(&"build_confirmed", _on_build_confirmed)


## The player calls this on entering/leaving build mode. Never decided here.
func set_active(active: bool) -> void:
	_bar_center.visible = active
	if active:
		_show_status("R rotate  ·  V snapping  ·  click place  ·  right-click destroy", false)


func set_selected_piece(piece_id: StringName) -> void:
	_selected_piece_id = piece_id
	for slot: PieceSlot in _slots:
		slot.present(slot.piece_id == piece_id)
	_grab_focus_for_selected()


## F-217: player_controller.gd's set_selected_build_piece() calls set_active(true) and
## set_selected_piece() together on every entry into build mode (there is no "activate with nothing
## selected" path — see its own doc comment), so this single method doubles as the initial-focus grab
## AttunementUI's _grab_initial_focus() needed a separate open hook for (F-216). A slot click routes
## back through here too (piece_selected -> player_controller.gd -> set_selected_build_piece()), so a
## mouse click also leaves focus on the clicked slot — harmless, since Control already does that on
## its own for a FOCUS_ALL control.
func _grab_focus_for_selected() -> void:
	for slot: PieceSlot in _slots:
		if slot.piece_id == _selected_piece_id:
			slot.grab_focus()
			return


## Pushed by player_controller.gd when the player presses the snap toggle, and never decided here —
## `BuildGhost` owns that state and this only shows it, the same one-way contract `set_active()` and
## `set_selected_piece()` already follow. Called with the ghost's answer, not with a guess, so the
## bar cannot drift out of step with what the ghost is actually doing.
func set_snapping(enabled: bool) -> void:
	_snapping = enabled
	_present_snapping()


func is_snapping() -> bool:
	return _snapping


func _present_snapping() -> void:
	if _snap_label == null:
		return
	_snap_label.text = "SNAP ON — pieces mate to their neighbours" if _snapping \
		else "SNAP OFF — free placement"
	_snap_label.add_theme_color_override(
		"font_color", COLOUR_SNAP_ON if _snapping else COLOUR_SNAP_OFF)


## Fed every physics tick the player is in build mode, straight from BuildGhost's own
## is_valid()/last_reason_text() — this file never re-derives a verdict of its own.
func set_ghost_status(valid: bool, reason_text: String) -> void:
	if reason_text.is_empty():
		return
	_hint_label.text = reason_text
	_hint_label.add_theme_color_override("font_color", COLOUR_MUTED if valid else COLOUR_ERROR)


func is_active() -> bool:
	return _bar_center.visible


func slot_count() -> int:
	return _slots.size()


func slot_piece_id(index: int) -> StringName:
	return _slots[index].piece_id if index >= 0 and index < _slots.size() else &""


## Presses the slot exactly as a click would, so a check exercises the real seam.
func select_slot(index: int) -> void:
	if index < 0 or index >= _slots.size():
		return
	piece_selected.emit(_slots[index].piece_id)


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "BuildBarRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_bar_center = CenterContainer.new()
	_bar_center.name = "BuildBarCenter"
	_bar_center.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_bar_center.offset_top = -172.0
	_bar_center.offset_bottom = -96.0
	_bar_center.mouse_filter = Control.MOUSE_FILTER_STOP
	_bar_center.visible = false
	_root.add_child(_bar_center)

	_panel = PanelContainer.new()
	_panel.name = "BuildBarPanel"
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_bar_center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	_panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 4)
	margin.add_child(stack)

	_row = HBoxContainer.new()
	_row.name = "BuildSlots"
	_row.add_theme_constant_override("separation", 4)
	stack.add_child(_row)

	_hint_label = Label.new()
	_hint_label.name = "GhostHint"
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.add_theme_font_size_override("font_size", 12)
	_hint_label.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(_hint_label)

	# Its OWN label rather than a phrase inside the hint: set_ghost_status() rewrites the hint every
	# physics tick from the ghost's verdict, so a mode indicator living there would be erased within a
	# frame of being set. A player toggling snapping has to be able to see the state they toggled to.
	_snap_label = Label.new()
	_snap_label.name = "SnapState"
	_snap_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_snap_label.add_theme_font_size_override("font_size", 11)
	stack.add_child(_snap_label)

	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 10)
	_status_label.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(_status_label)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOUR_PANEL
	style.border_color = COLOUR_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	return style


## Registry.buildables loads once at boot and never changes at runtime (task 3.7 authors more .tres
## files, it does not hot-reload them), so slots are built once here rather than rebuilt on a poll —
## unlike CraftingUI's rows, which change with whichever station is nearby.
func _populate_slots() -> void:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return
	var buildables: Dictionary = registry.get(&"buildables")
	for id: StringName in buildables:
		var def: Resource = buildables[id]
		var slot := PieceSlot.new()
		slot.setup(def, _on_slot_pressed)
		_slots.append(slot)
		_row.add_child(slot)
	_wire_horizontal_chain(_slots)


## F-217: same recipe F-209/F-216 gave every other panel's control chain (UnlockMenu's
## _wire_vertical_chain, AttunementUI's copy of it) — but horizontal, since the slots sit in one
## HBoxContainer row rather than a stacked column, so ui_left/ui_right is the natural axis. Wraps
## first<->last like every other chain in this project. Built once here alongside the slots
## themselves (see this function's own doc comment on why slots are static).
func _wire_horizontal_chain(slots: Array[PieceSlot]) -> void:
	var count: int = slots.size()
	if count == 0:
		return
	for i: int in count:
		var current: PieceSlot = slots[i]
		var prev: PieceSlot = slots[(i - 1 + count) % count]
		var next: PieceSlot = slots[(i + 1) % count]
		current.focus_neighbor_left = current.get_path_to(prev)
		current.focus_neighbor_right = current.get_path_to(next)


func _on_slot_pressed(piece_id: StringName) -> void:
	piece_selected.emit(piece_id)


## Fires for both a place and a destroy request (BuildService.build_confirmed carries no "kind"), so
## the accepted message stays generic rather than claiming "placed" for what might be a destroy.
func _on_build_confirmed(_request_id: int, accepted: bool, reason: String) -> void:
	if accepted:
		_show_status("done" if reason.is_empty() else reason, false)
	else:
		_show_status(reason if not reason.is_empty() else "refused", true)


func _show_status(message: String, error: bool) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", COLOUR_ERROR if error else COLOUR_MUTED)
