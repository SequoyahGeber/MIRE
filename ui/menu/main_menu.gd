extends CanvasLayer

## MainMenu — the game's persistent menu shell: seed entry, a way into the multiplayer lobby panel
## and the settings shell, and quit. Task 6.10's remaining "main menu + seed entry" slice, after the
## lobby-UI half shipped ahead of it (D-030, `ui/lobby/lobby_menu.gd`).
## Register as autoload `MainMenu` → res://ui/menu/main_menu.gd, AFTER `LobbyMenu` and
## `SettingsMenu` in `project.godot` (this file calls into both by node path at request time, so load
## order does not matter for correctness — kept after them anyway so the ordering reads the same way
## the panels nest).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI, the table's free last row.
## Seed entry does not grant a client any new power: it only calls `GameState.set_pending_seed()`,
## which a real client build already lets any peer call on its own `GameState` instance harmlessly —
## the value is only ever consumed by THAT process's own [method GameState.host_generate_seed] /
## [method GameState.ensure_seed], so typing a seed on a client that never hosts does nothing.
##
## Toggled with F1 (raw keycode, same convention as LobbyMenu's M and DebugConsole's backtick — the
## action map is not touched). Closed with Esc, consumed here in _input so the player controller's
## temporary mouse-release toggle (see its own comment: "Replaced by the pause menu in M7") never
## also reacts to the same press. Joins `blocks_gameplay_input` while open and refuses to stack on
## any other cursor UI (D-032) — opening the lobby, settings or unlocks panel from here first closes
## this one, the same "hand off, don't stack" shape D-032's own note asks a "future build menu, ward
## panel or map" to follow.
##
## Deliberately does NOT auto-open at boot. `world/mire/mire_grid.gd` already draws the run seed the
## instant the main scene loads (`GameState.ensure_seed()` in its own `_ready()`), so there is no
## "before the game starts" moment left to gate — see docs/FINDINGS.md for the follow-up this leaves
## open for solo play. What seed entry DOES reach: the window between opening this panel and pressing
## HOST in the lobby panel, which is the real moment `GameState.host_generate_seed()` draws for a
## hosted session. Auto-opening was also rejected on its own merits — every other panel in this game
## opens on a keypress, never automatically, and an auto-shown blocking overlay risks eating input
## from any check or two-process test that boots the main scene expecting to act immediately.

const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"

const COLOUR_SCREEN_SHADE := Color(0.018, 0.035, 0.028, 0.78)
const COLOUR_PANEL := Color(0.055, 0.086, 0.070, 0.97)
const COLOUR_FIELD := Color(0.085, 0.125, 0.102, 0.98)
const COLOUR_BORDER := Color(0.345, 0.475, 0.390, 1.0)
const COLOUR_ACCENT := Color(0.894, 0.704, 0.286, 1.0)
const COLOUR_TEXT := Color(0.91, 0.94, 0.89, 1.0)
const COLOUR_MUTED := Color(0.60, 0.69, 0.62, 1.0)
const COLOUR_ERROR := Color(0.96, 0.47, 0.39, 1.0)

var _root: Control
var _shade: ColorRect
var _center: CenterContainer
var _status_label: Label
var _seed_field: LineEdit
var _set_seed_button: Button
var _random_seed_button: Button
var _multiplayer_button: Button
var _settings_button: Button
var _unlocks_button: Button
var _quit_button: Button

var _open: bool = false
var _restore_mouse_captured: bool = false


func _ready() -> void:
	layer = 57
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()

	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state != null:
		game_state.connect("seed_ready", Callable(self, "_on_seed_ready"))


func _input(event: InputEvent) -> void:
	if get_viewport().is_input_handled():
		return
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event
	if not key.pressed or key.is_echo():
		return

	if key.keycode == KEY_F1:
		var focus_owner: Control = get_viewport().gui_get_focus_owner()
		if focus_owner is LineEdit or focus_owner is TextEdit:
			return
		set_open(not _open)
		get_viewport().set_input_as_handled()
	elif _open and key.keycode == KEY_ESCAPE:
		set_open(false)
		get_viewport().set_input_as_handled()


# ── Public API (the check drives these; buttons call the same paths) ──────────────────────────────


func set_open(open: bool) -> void:
	if open == _open:
		return
	if open and _other_blocking_ui_open():
		return
	_open = open
	_shade.visible = open
	_center.visible = open
	if open:
		add_to_group(BLOCKING_UI_GROUP)
		_restore_mouse_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_refresh()
		_seed_field.grab_focus()
	else:
		remove_from_group(BLOCKING_UI_GROUP)
		_root.release_focus()
		if _restore_mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func is_open() -> bool:
	return _open


## Stages `_seed_field`'s text as the next drawn seed. A pure integer is used as-is; any other text
## is hashed (`String.hash()` — a fixed algorithm, same result on every platform for the same
## string) so a friend can share a memorable seed the same way a numeric one gets shared. Empty
## clears a previous override.
func request_set_seed() -> void:
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state == null:
		return
	var text: String = _seed_field.text.strip_edges()
	if text.is_empty():
		game_state.call("set_pending_seed", 0)
		_show_status("Seed cleared — HOST/PLAY draws a fresh one.", false)
		_refresh()
		return
	var value: int = int(text.to_int()) if text.is_valid_int() else text.hash()
	if value == 0:
		value = 1
	game_state.call("set_pending_seed", value)
	_show_status("Seed staged: %d — HOST in MULTIPLAYER to use it." % value, false)
	_refresh()


func request_random_seed() -> void:
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state != null:
		game_state.call("set_pending_seed", 0)
	_seed_field.text = ""
	_show_status("Seed cleared — HOST/PLAY draws a fresh one.", false)
	_refresh()


func request_open_multiplayer() -> void:
	set_open(false)
	var lobby: Node = get_node_or_null(^"/root/LobbyMenu")
	if lobby != null:
		lobby.call("set_open", true)


func request_open_settings() -> void:
	set_open(false)
	var settings: Node = get_node_or_null(^"/root/SettingsMenu")
	if settings != null:
		settings.call("set_open", true)


## Task 6.9: hands off to the Salvage-spending unlock tree the same "close first, then open" way
## every other sub-panel here does (D-032) — never stacks two blocking panels.
func request_open_unlocks() -> void:
	set_open(false)
	var unlocks: Node = get_node_or_null(^"/root/UnlockMenu")
	if unlocks != null:
		unlocks.call("set_open", true)


func request_quit() -> void:
	get_tree().quit()


func seed_field_text() -> String:
	return _seed_field.text


func set_seed_field_text(text: String) -> void:
	_seed_field.text = text


func status_text() -> String:
	return _status_label.text


func _on_seed_ready(_value: int) -> void:
	_refresh()


# ── Internals ─────────────────────────────────────────────────────────────────────────────────────


func _other_blocking_ui_open() -> bool:
	for node: Node in get_tree().get_nodes_in_group(BLOCKING_UI_GROUP):
		if node != self:
			return true
	return false


func _refresh() -> void:
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state == null:
		return
	# Staged takes priority even once this run already has its own seed (is_seed_ready() basically
	# always ends up true within a frame or two of boot — world/mire/mire_grid.gd draws one lazily
	# the instant it's asked) — a staged value is for the NEXT hosted session, not this one, and
	# burying that under "this run's seed" the moment it's typed would make SET look like a no-op.
	if bool(game_state.call("has_pending_seed")):
		var pending: int = int(game_state.call("pending_seed"))
		_status_label.text = "Seed staged: %d — HOST in MULTIPLAYER to use it." % pending
		_status_label.add_theme_color_override("font_color", COLOUR_ACCENT)
	elif bool(game_state.call("is_seed_ready")):
		var value: int = int(game_state.get("run_seed"))
		_status_label.text = "This run's seed: %d" % value
		_status_label.add_theme_color_override("font_color", COLOUR_MUTED)
	else:
		_status_label.text = "No seed drawn yet."
		_status_label.add_theme_color_override("font_color", COLOUR_MUTED)


func _show_status(message: String, error: bool) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", COLOUR_ERROR if error else COLOUR_MUTED)


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "MainMenuRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_shade = ColorRect.new()
	_shade.name = "MainMenuShade"
	_shade.color = COLOUR_SCREEN_SHADE
	_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_shade.visible = false
	_root.add_child(_shade)

	_center = CenterContainer.new()
	_center.name = "MainMenuCenter"
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_STOP
	_center.visible = false
	_root.add_child(_center)

	var panel := PanelContainer.new()
	panel.name = "MainMenuPanel"
	panel.custom_minimum_size = Vector2(420.0, 0.0)
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
	title.text = "MIRE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", COLOUR_TEXT)
	stack.add_child(title)

	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.text = "No seed drawn yet."
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(_status_label)

	stack.add_child(HSeparator.new())

	var seed_label := Label.new()
	seed_label.text = "RUN SEED — leave blank for a random island"
	seed_label.add_theme_font_size_override("font_size", 11)
	seed_label.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(seed_label)

	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 6)
	stack.add_child(seed_row)

	_seed_field = LineEdit.new()
	_seed_field.name = "SeedField"
	_seed_field.placeholder_text = "a number or a word…"
	_seed_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seed_field.add_theme_color_override("font_color", COLOUR_TEXT)
	_seed_field.text_submitted.connect(func(_text: String) -> void: request_set_seed())
	seed_row.add_child(_seed_field)

	_set_seed_button = _button("SET", request_set_seed)
	seed_row.add_child(_set_seed_button)

	_random_seed_button = _button("RANDOM", request_random_seed)
	stack.add_child(_random_seed_button)

	stack.add_child(HSeparator.new())

	_multiplayer_button = _button("MULTIPLAYER", request_open_multiplayer)
	stack.add_child(_multiplayer_button)

	_settings_button = _button("SETTINGS", request_open_settings)
	stack.add_child(_settings_button)

	_unlocks_button = _button("UNLOCKS", request_open_unlocks)
	stack.add_child(_unlocks_button)

	_quit_button = _button("QUIT", request_quit)
	stack.add_child(_quit_button)

	var close_hint := Label.new()
	close_hint.text = "F1 / ESC  CLOSE"
	close_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close_hint.add_theme_font_size_override("font_size", 10)
	close_hint.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(close_hint)

	# F-209: gamepad/keyboard focus navigation. Opening grabs _seed_field (set_open() above); this
	# wires the D-pad/arrow chain down the visible order, wrapping top<->bottom, plus the seed
	# row's SET button as an off-chain left/right hop. Godot's Slider/OptionButton/Button already
	# answer ui_accept/ui_left/ui_right once focused — only the chain and a visible ring were missing.
	_seed_field.add_theme_stylebox_override("focus", _focus_style())
	_wire_vertical_chain([
		_seed_field, _random_seed_button, _multiplayer_button,
		_settings_button, _unlocks_button, _quit_button,
	])
	_seed_field.focus_neighbor_right = _seed_field.get_path_to(_set_seed_button)
	_set_seed_button.focus_neighbor_left = _set_seed_button.get_path_to(_seed_field)
	_set_seed_button.focus_neighbor_bottom = _set_seed_button.get_path_to(_random_seed_button)


func _wire_vertical_chain(controls: Array) -> void:
	var count: int = controls.size()
	for i: int in count:
		var current: Control = controls[i]
		var prev: Control = controls[(i - 1 + count) % count]
		var next: Control = controls[(i + 1) % count]
		current.focus_neighbor_top = current.get_path_to(prev)
		current.focus_neighbor_bottom = current.get_path_to(next)


func _button(text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_color_override("font_color", COLOUR_TEXT)
	button.add_theme_stylebox_override("normal", _field_style(COLOUR_FIELD, COLOUR_BORDER))
	button.add_theme_stylebox_override("hover", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
	button.add_theme_stylebox_override("pressed", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
	button.add_theme_stylebox_override("focus", _focus_style())
	button.pressed.connect(on_pressed)
	return button


## Visible focus ring (F-209) — a transparent-fill outline drawn as Button/LineEdit's "focus"
## stylebox layer on top of normal/hover/pressed, since none of these controls override the
## engine default focus style, which is easy to miss against a dark panel background.
func _focus_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	style.draw_center = false
	style.border_color = COLOUR_ACCENT
	style.set_border_width_all(2)
	style.set_corner_radius_all(5)
	return style


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOUR_PANEL
	style.border_color = COLOUR_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
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
