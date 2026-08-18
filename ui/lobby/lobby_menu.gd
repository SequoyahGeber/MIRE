extends CanvasLayer

## LobbyMenu — the in-game multiplayer panel: host a Steam lobby, join one by pasted ID, invite
## friends through the overlay, see who is in, leave. Task 6.10's lobby-UI slice, pulled forward of
## the rest of 6.10 (main menu / settings / seed entry) because it is what makes cross-play testing
## cheap (D-030): the ID travels over any chat instead of between terminals.
## Register as autoload `LobbyMenu` → res://ui/lobby/lobby_menu.gd
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI, the table's free last row.
## Every button is a request into SteamLobby / NetTransport, which already own the real decisions;
## nothing here is replicated and nothing here is trusted. Member rows render SteamLobby.members(),
## which is lobby membership, NOT session membership — fine for a lobby screen, never authoritative.
##
## Toggled with M (raw keycode, like DebugConsole's backtick — the action map is not touched), closed
## with Esc. Esc is consumed here in _input, so the player controller's temporary mouse-release
## toggle (_unhandled_input) never sees the same press. Joins the blocks_gameplay_input group while
## open and refuses to stack on any other cursor UI (D-032).

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
var _idle_box: VBoxContainer
var _host_button: Button
var _join_field: LineEdit
var _paste_button: Button
var _join_button: Button
var _lobby_box: VBoxContainer
var _lobby_id_field: LineEdit
var _copy_button: Button
var _invite_button: Button
var _members_box: VBoxContainer
var _leave_button: Button

var _open: bool = false
var _restore_mouse_captured: bool = false


func _ready() -> void:
	layer = 55
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()

	SteamLobby.lobby_created.connect(_on_lobby_created)
	SteamLobby.lobby_joined.connect(_on_lobby_joined)
	SteamLobby.lobby_failed.connect(_on_lobby_failed)
	SteamLobby.lobby_left.connect(_on_lobby_left)
	SteamLobby.members_changed.connect(_on_members_changed)
	SteamLobby.invite_accepted.connect(_on_invite_accepted)

	NetSession.session_opened.connect(_on_session_opened)
	NetSession.session_ended.connect(_on_session_ended)
	NetSession.connect_retry_attempted.connect(_on_connect_retry)
	NetSession.connect_failed.connect(_on_connect_failed)
	NetSession.rejoin_attempted.connect(_on_rejoin_attempted)
	NetSession.rejoined.connect(_on_rejoined)


func _input(event: InputEvent) -> void:
	if get_viewport().is_input_handled():
		return
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event
	if not key.pressed or key.is_echo():
		return

	if key.keycode == KEY_M:
		# Typing an 'm' into the join field must not toggle the menu shut.
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
		# One cursor-owning UI at a time (D-032). The other panel keeps the screen.
		return
	_open = open
	_shade.visible = open
	_center.visible = open
	if open:
		add_to_group(BLOCKING_UI_GROUP)
		_restore_mouse_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_refresh()
		if _idle_box.visible:
			_join_field.grab_focus()
	else:
		remove_from_group(BLOCKING_UI_GROUP)
		_root.release_focus()
		if _restore_mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func is_open() -> bool:
	return _open


func request_host() -> void:
	_show_status("Creating a Steam lobby…", false)
	var err: Error = SteamLobby.host_session()
	if err == ERR_UNAVAILABLE:
		_show_status("Steam is not available — is the Steam client running?", true)
	elif err != OK:
		# SteamLobby already emitted lobby_failed with the human-readable reason; nothing to add.
		pass


func request_join() -> void:
	var lobby_id_text: String = _join_field.text.strip_edges()
	if lobby_id_text.is_empty():
		_show_status("Paste a lobby ID first — your friend gets it from HOST, then COPY.", true)
		return
	_show_status("Joining lobby %s…" % lobby_id_text, false)
	var err: Error = SteamLobby.join_by_id(lobby_id_text)
	if err == ERR_UNAVAILABLE:
		_show_status("Steam is not available — is the Steam client running?", true)


func request_leave() -> void:
	if SteamLobby.in_lobby():
		SteamLobby.leave()
	else:
		NetTransport.leave()
	_show_status("Left the session.", false)
	_refresh()


func request_copy_lobby_id() -> void:
	var lobby_id: int = SteamLobby.current_lobby_id()
	if lobby_id == 0:
		_show_status("No lobby to copy — host one first.", true)
		return
	DisplayServer.clipboard_set(str(lobby_id))
	_show_status("Lobby ID copied — send it to a friend, they paste it under JOIN.", false)


func request_invite_overlay() -> void:
	if not SteamLobby.open_invite_overlay():
		_show_status("No lobby to invite anyone to — host one first.", true)


func set_join_field_text(text: String) -> void:
	_join_field.text = text


func join_field_text() -> String:
	return _join_field.text


func status_text() -> String:
	return _status_label.text


func lobby_id_text() -> String:
	return _lobby_id_field.text


func member_row_count() -> int:
	return _members_box.get_child_count()


# ── SteamLobby / NetSession signals ────────────────────────────────────────────────────────────────


func _on_lobby_created(lobby_id: int) -> void:
	_show_status("Lobby %d created — COPY the ID for friends, or INVITE via the overlay." % lobby_id, false)
	_refresh()


func _on_lobby_joined(lobby_id: int) -> void:
	_show_status("In lobby %d — connecting to the host…" % lobby_id, false)
	_refresh()


func _on_lobby_failed(reason: String) -> void:
	_show_status(reason, true)
	_refresh()


func _on_lobby_left(lobby_id: int) -> void:
	_show_status("Left lobby %d." % lobby_id, false)
	_refresh()


func _on_members_changed(_members: Array[Dictionary]) -> void:
	_rebuild_member_rows()


func _on_invite_accepted(lobby_id: int, auto_joining: bool) -> void:
	# A friend's invite is an explicit click on our session — surfacing the panel is the answer to
	# it, whichever branch we are on.
	set_open(true)
	if auto_joining:
		_show_status("Invite accepted — joining lobby %d…" % lobby_id, false)
	else:
		_join_field.text = str(lobby_id)
		_show_status("Invited to lobby %d — LEAVE your current session, then JOIN." % lobby_id, true)


func _on_session_opened(is_host: bool) -> void:
	if is_host:
		_show_status("Session live — you are the host. Friends can join with the lobby ID.", false)
	else:
		_show_status("Connected — you are in the host's game.", false)
	_refresh()


func _on_session_ended(_reason: int, detail: String) -> void:
	_show_status(detail, true)
	_refresh()


func _on_connect_retry(attempt: int, of: int) -> void:
	_show_status("Connection timed out — retrying (%d/%d)…" % [attempt, of], true)


func _on_connect_failed(detail: String) -> void:
	_show_status(detail, true)
	_refresh()


func _on_rejoin_attempted(attempt: int, of: int) -> void:
	_show_status("Connection lost — rejoining (%d/%d)…" % [attempt, of], true)


func _on_rejoined() -> void:
	_show_status("Rejoined the session.", false)
	_refresh()


# ── Internals ─────────────────────────────────────────────────────────────────────────────────────


func _other_blocking_ui_open() -> bool:
	for node: Node in get_tree().get_nodes_in_group(BLOCKING_UI_GROUP):
		if node != self:
			return true
	return false


## Idle (host/join controls) vs in-a-session (ID, invite, members, leave). NetTransport.is_active()
## is checked as well as the lobby so a LOCAL/LAN dev session shows as "in a session" instead of
## offering a second, conflicting Steam join.
func _refresh() -> void:
	var in_session: bool = SteamLobby.in_lobby() or NetTransport.is_active()
	_idle_box.visible = not in_session
	_lobby_box.visible = in_session

	var lobby_id: int = SteamLobby.current_lobby_id()
	if lobby_id != 0:
		_lobby_id_field.text = str(lobby_id)
		_copy_button.disabled = false
		_invite_button.disabled = false
	else:
		_lobby_id_field.text = "no Steam lobby (LOCAL/LAN session)" if in_session else ""
		_copy_button.disabled = true
		_invite_button.disabled = true
	_rebuild_member_rows()


func _rebuild_member_rows() -> void:
	for child: Node in _members_box.get_children():
		_members_box.remove_child(child)
		child.free()
	for member: Dictionary in SteamLobby.members():
		var row := Label.new()
		var tags: String = ""
		if bool(member.get("is_owner", false)):
			tags += "  · HOST"
		if bool(member.get("is_local", false)):
			tags += "  · YOU"
		row.text = "%s%s" % [str(member.get("name", "?")), tags]
		row.add_theme_font_size_override("font_size", 13)
		row.add_theme_color_override("font_color", COLOUR_TEXT)
		_members_box.add_child(row)


func _show_status(message: String, error: bool) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", COLOUR_ERROR if error else COLOUR_MUTED)


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "LobbyMenuRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_shade = ColorRect.new()
	_shade.name = "LobbyShade"
	_shade.color = COLOUR_SCREEN_SHADE
	_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_shade.visible = false
	_root.add_child(_shade)

	_center = CenterContainer.new()
	_center.name = "LobbyCenter"
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_STOP
	_center.visible = false
	_root.add_child(_center)

	var panel := PanelContainer.new()
	panel.name = "LobbyPanel"
	panel.custom_minimum_size = Vector2(480.0, 0.0)
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
	title.text = "MULTIPLAYER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", COLOUR_TEXT)
	stack.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "STEAM CO-OP  ·  HOST A LOBBY OR JOIN WITH AN ID"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 11)
	subtitle.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(subtitle)

	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.text = "Host a game and send the lobby ID to friends, or paste theirs and join."
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(_status_label)

	stack.add_child(HSeparator.new())

	# Idle: host, or paste-and-join.
	_idle_box = VBoxContainer.new()
	_idle_box.name = "IdleBox"
	_idle_box.add_theme_constant_override("separation", 8)
	stack.add_child(_idle_box)

	_host_button = _button("HOST A STEAM GAME", request_host)
	_idle_box.add_child(_host_button)

	var join_label := Label.new()
	join_label.text = "JOIN A FRIEND"
	join_label.add_theme_font_size_override("font_size", 11)
	join_label.add_theme_color_override("font_color", COLOUR_MUTED)
	_idle_box.add_child(join_label)

	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 6)
	_idle_box.add_child(join_row)

	_join_field = LineEdit.new()
	_join_field.name = "JoinField"
	_join_field.placeholder_text = "paste a lobby ID…"
	_join_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_field.add_theme_color_override("font_color", COLOUR_TEXT)
	_join_field.text_submitted.connect(func(_text: String) -> void: request_join())
	join_row.add_child(_join_field)

	_paste_button = _button("PASTE", func() -> void:
		_join_field.text = DisplayServer.clipboard_get().strip_edges())
	join_row.add_child(_paste_button)

	_join_button = _button("JOIN", request_join)
	join_row.add_child(_join_button)

	# In a session: the ID to share, the overlay, who is in, and the way out.
	_lobby_box = VBoxContainer.new()
	_lobby_box.name = "LobbyBox"
	_lobby_box.add_theme_constant_override("separation", 8)
	_lobby_box.visible = false
	stack.add_child(_lobby_box)

	var id_label := Label.new()
	id_label.text = "LOBBY ID — friends paste this to join"
	id_label.add_theme_font_size_override("font_size", 11)
	id_label.add_theme_color_override("font_color", COLOUR_MUTED)
	_lobby_box.add_child(id_label)

	var id_row := HBoxContainer.new()
	id_row.add_theme_constant_override("separation", 6)
	_lobby_box.add_child(id_row)

	_lobby_id_field = LineEdit.new()
	_lobby_id_field.name = "LobbyIdField"
	_lobby_id_field.editable = false
	_lobby_id_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lobby_id_field.add_theme_color_override("font_color", COLOUR_ACCENT)
	id_row.add_child(_lobby_id_field)

	_copy_button = _button("COPY", request_copy_lobby_id)
	id_row.add_child(_copy_button)

	_invite_button = _button("INVITE FRIENDS (STEAM OVERLAY)", request_invite_overlay)
	_lobby_box.add_child(_invite_button)

	var members_label := Label.new()
	members_label.text = "IN THE LOBBY"
	members_label.add_theme_font_size_override("font_size", 11)
	members_label.add_theme_color_override("font_color", COLOUR_MUTED)
	_lobby_box.add_child(members_label)

	_members_box = VBoxContainer.new()
	_members_box.name = "MembersBox"
	_members_box.add_theme_constant_override("separation", 2)
	_lobby_box.add_child(_members_box)

	_leave_button = _button("LEAVE SESSION", request_leave)
	_lobby_box.add_child(_leave_button)

	var close_hint := Label.new()
	close_hint.text = "M / ESC  CLOSE"
	close_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close_hint.add_theme_font_size_override("font_size", 10)
	close_hint.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(close_hint)


func _button(text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_color_override("font_color", COLOUR_TEXT)
	button.add_theme_stylebox_override("normal", _field_style(COLOUR_FIELD, COLOUR_BORDER))
	button.add_theme_stylebox_override("hover", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
	button.add_theme_stylebox_override("pressed", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
	button.pressed.connect(on_pressed)
	return button


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
