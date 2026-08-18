extends CanvasLayer

## AttunementUI — the run-start role picker (DESIGN.md §4.5, task 3.9). Register as autoload
## `AttunementUI` → res://ui/attunement/attunement_ui.gd.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local presentation over
## AttunementService's real seam. Every CHOOSE button is `AttunementService.request_select(id)`;
## nothing here is trusted, the host answers via `selection_confirmed`.
##
## D-071: opens the moment the LOCAL player's own body exists — polled off the `&"players"` group's
## `is_multiplayer_authority()` flag (set identically offline and online by player_controller.gd)
## rather than a new signal, so this file needs no claim on player_controller.gd. That is "run
## start": a run is one sitting (D-010), so a player's first body is their run start, whether that is
## the offline hand-placed Player or a PlayerNet spawn. Joins the D-032 group while open. There is no
## Escape/dismiss path — task 3.9's spec locks the pick after selection and respec is out of scope,
## so once open there is nothing to dismiss TO.

const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"
const PLAYERS_GROUP: StringName = &"players"
const POLL_INTERVAL_SEC: float = 0.5
const ROLE_ORDER: Array[StringName] = [&"warden", &"forager", &"tinker", &"reaver"]

const COLOUR_SCREEN_SHADE := Color(0.018, 0.035, 0.028, 0.85)
const COLOUR_PANEL := Color(0.055, 0.086, 0.070, 0.97)
const COLOUR_ROW := Color(0.085, 0.125, 0.102, 0.98)
const COLOUR_BORDER := Color(0.345, 0.475, 0.390, 1.0)
const COLOUR_ACCENT := Color(0.894, 0.704, 0.286, 1.0)
const COLOUR_TEXT := Color(0.91, 0.94, 0.89, 1.0)
const COLOUR_MUTED := Color(0.60, 0.69, 0.62, 1.0)
const COLOUR_ERROR := Color(0.96, 0.47, 0.39, 1.0)

var _root: Control
var _shade: ColorRect
var _center: CenterContainer
var _status_label: Label
var _roles_box: VBoxContainer
var _party_label: Label
var _poll_timer: Timer

var _open: bool = false
var _picking: bool = false
var _restore_mouse_captured: bool = false
var _role_buttons: Dictionary[StringName, Button] = {}


func _ready() -> void:
	layer = 56
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()

	AttunementService.selection_changed.connect(_on_selection_changed)
	AttunementService.selection_confirmed.connect(_on_selection_confirmed)

	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_INTERVAL_SEC
	_poll_timer.autostart = true
	_poll_timer.timeout.connect(_poll_for_local_player)
	add_child(_poll_timer)


# ── Public API (the check drives these) ─────────────────────────────────────────────────────────


func is_open() -> bool:
	return _open


func choose(attunement_id: StringName) -> void:
	if not _open or _picking:
		return
	_picking = true
	_set_buttons_disabled(true)
	_show_status("Requesting %s…" % attunement_id, false)
	AttunementService.request_select(attunement_id)


func role_button_count() -> int:
	return _role_buttons.size()


func status_text() -> String:
	return _status_label.text


## Test/debug seam: force-checks for the local player right now instead of waiting for the poll
## interval, so a check does not need to sleep POLL_INTERVAL_SEC to prove the trigger works.
func poll_now() -> void:
	_poll_for_local_player()


# ── Trigger ──────────────────────────────────────────────────────────────────────────────────────


func _poll_for_local_player() -> void:
	if _open or AttunementService.local_selection() != &"":
		_poll_timer.stop()
		return
	for node: Node in get_tree().get_nodes_in_group(PLAYERS_GROUP):
		if node is Node3D and node.is_multiplayer_authority():
			_open_picker()
			_poll_timer.stop()
			return


func _open_picker() -> void:
	if _open:
		return
	_open = true
	_picking = false
	add_to_group(BLOCKING_UI_GROUP)
	_restore_mouse_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_shade.visible = true
	_center.visible = true
	_rebuild_role_rows()
	_refresh_party()
	_show_status("Pick one — it is locked for the run.", false)


func _close_picker() -> void:
	if not _open:
		return
	_open = false
	remove_from_group(BLOCKING_UI_GROUP)
	_shade.visible = false
	_center.visible = false
	if _restore_mouse_captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ── AttunementService signals ───────────────────────────────────────────────────────────────────


func _on_selection_confirmed(accepted: bool, attunement_id: StringName, detail: String) -> void:
	if not _open:
		return
	_picking = false
	if accepted:
		_close_picker()
		return
	_set_buttons_disabled(false)
	_show_status(detail, true)


func _on_selection_changed(_peer_id: int, _attunement_id: StringName) -> void:
	if _open:
		_refresh_party()


# ── Internals ────────────────────────────────────────────────────────────────────────────────────


func _rebuild_role_rows() -> void:
	for child: Node in _roles_box.get_children():
		_roles_box.remove_child(child)
		child.free()
	_role_buttons.clear()

	for role_id: StringName in ROLE_ORDER:
		var definition: Resource = Registry.get_attunement(role_id)
		if definition == null:
			continue
		_roles_box.add_child(_build_role_row(definition))


func _build_role_row(definition: Resource) -> PanelContainer:
	var role_id: StringName = StringName(definition.get(&"id"))
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _row_style())

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)

	var text_col := VBoxContainer.new()
	text_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text_col)

	var name_label := Label.new()
	name_label.text = String(definition.get(&"display_name"))
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.add_theme_color_override("font_color", COLOUR_ACCENT)
	text_col.add_child(name_label)

	var better_label := Label.new()
	better_label.text = "Better: %s" % String(definition.get(&"better_at"))
	better_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	better_label.add_theme_font_size_override("font_size", 12)
	better_label.add_theme_color_override("font_color", COLOUR_TEXT)
	text_col.add_child(better_label)

	var worse_label := Label.new()
	worse_label.text = "Worse: %s" % String(definition.get(&"worse_at"))
	worse_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	worse_label.add_theme_font_size_override("font_size", 12)
	worse_label.add_theme_color_override("font_color", COLOUR_MUTED)
	text_col.add_child(worse_label)

	var pick_button := Button.new()
	pick_button.text = "CHOOSE"
	pick_button.custom_minimum_size = Vector2(90.0, 0.0)
	pick_button.add_theme_color_override("font_color", COLOUR_TEXT)
	pick_button.add_theme_stylebox_override("normal", _field_style(COLOUR_ROW, COLOUR_BORDER))
	pick_button.add_theme_stylebox_override("hover", _field_style(COLOUR_ROW, COLOUR_ACCENT))
	pick_button.pressed.connect(choose.bind(role_id))
	row.add_child(pick_button)
	_role_buttons[role_id] = pick_button

	return panel


func _refresh_party() -> void:
	var lines: PackedStringArray = []
	for peer_id: int in AttunementService.all_selections():
		var attunement_id: StringName = AttunementService.selection_of(peer_id)
		var definition: Resource = Registry.get_attunement(attunement_id)
		var role_name: String = String(definition.get(&"display_name")) if definition != null else String(attunement_id)
		lines.append("peer %d: %s" % [peer_id, role_name])
	_party_label.text = "PARTY — %s" % ", ".join(lines) if not lines.is_empty() else "PARTY — nobody has chosen yet"


func _set_buttons_disabled(disabled: bool) -> void:
	for button: Button in _role_buttons.values():
		button.disabled = disabled


func _show_status(text: String, is_error: bool) -> void:
	_status_label.text = text
	_status_label.add_theme_color_override("font_color", COLOUR_ERROR if is_error else COLOUR_MUTED)


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "AttunementUiRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_shade = ColorRect.new()
	_shade.name = "AttunementShade"
	_shade.color = COLOUR_SCREEN_SHADE
	_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_shade.visible = false
	_root.add_child(_shade)

	_center = CenterContainer.new()
	_center.name = "AttunementCenter"
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_STOP
	_center.visible = false
	_root.add_child(_center)

	var panel := PanelContainer.new()
	panel.name = "AttunementPanel"
	panel.custom_minimum_size = Vector2(560.0, 0.0)
	panel.add_theme_stylebox_override("panel", _panel_style())
	_center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 10)
	margin.add_child(stack)

	var title := Label.new()
	title.text = "CHOOSE YOUR ATTUNEMENT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", COLOUR_TEXT)
	stack.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "ONE ROLE, LOCKED FOR THE RUN — NOBODY IS LOCKED OUT OF ANYTHING ELSE"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 11)
	subtitle.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(subtitle)

	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(_status_label)

	stack.add_child(HSeparator.new())

	_roles_box = VBoxContainer.new()
	_roles_box.name = "RolesBox"
	_roles_box.add_theme_constant_override("separation", 8)
	stack.add_child(_roles_box)

	stack.add_child(HSeparator.new())

	_party_label = Label.new()
	_party_label.name = "Party"
	_party_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_party_label.add_theme_font_size_override("font_size", 11)
	_party_label.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(_party_label)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOUR_PANEL
	style.border_color = COLOUR_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	return style


func _row_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOUR_ROW
	style.border_color = COLOUR_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	return style


func _field_style(fill: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	return style
