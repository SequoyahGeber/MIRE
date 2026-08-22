extends Control

## ExpeditionScreen — MENU-4: the dock (docs/MENU.md §5). One screen for solo and co-op; solo is
## just an empty dock. This is the heart of the front end, because zero-friction co-op is the actual
## product (DESIGN.md D5) and every screen between "I want to play with you" and "we are playing" is
## friction that kills it.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI, the table's free last row.
## Every button is a request into `SteamLobby` / `NetTransport` / `NetSession`, which already own the
## real decisions, exactly as `ui/lobby/lobby_menu.gd` established. Member rows render
## `SteamLobby.members()`, which is LOBBY membership, not session membership — right for a dock,
## never authoritative. The seed goes to `GameState.set_pending_seed()`, which only this process's
## own `host_generate_seed()` ever consumes, so typing a seed on a client that never hosts does
## nothing at all.
##
## ## What this replaces
##
## The shipped front end splits this across two panels on two different hotkeys: seed entry lives in
## `main_menu.gd` (F1) and hosting lives in `lobby_menu.gd` (M), joined by a handshake the player has
## to know about — "Seed staged: 424242 — HOST in MULTIPLAYER to use it." That is precisely the
## friction D5 forbids: two screens, two keys, and a sentence explaining how they relate. Here the
## island and the party are the same screen, because they are the same decision.
##
## ## Scope note: ready flags and colour chips are NOT here
##
## docs/MENU.md §5 describes a ready toggle and a per-player colour chip riding on Steam lobby member
## metadata. `autoload/steam_lobby.gd` has no member-metadata API today (no `set_member_data`), and
## adding one means Steam calls that cannot be exercised without a running Steam client — so it would
## ship unverified, which is worse than shipping without it. SET SAIL therefore has no ready gate,
## which §5 already allows below two players, and the metadata work is filed as its own finding.
## Nothing here has to change to add it later: the rows are rebuilt from `_member_rows()`.

const MireTheme := preload("res://ui/theme/mire_theme.gd")
const IslandMinimap := preload("res://ui/frontend/island_minimap.gd")

## Player cap (DESIGN.md Q5 — collapses to 4 by changing this one number if six turns out to be
## unreadable in playtests).
const PARTY_SLOTS: int = 6

## Seconds of no typing before the island preview re-renders. Every keystroke would otherwise cost a
## full heightmap sweep, and holding backspace would queue a dozen of them.
const SEED_PREVIEW_DEBOUNCE: float = 0.30

const MINIMAP_SIDE: float = 268.0

## The dock's measure. Wide enough for six party rows and the island card side by side, narrow
## enough that a row stays a row rather than becoming a ribbon on a wide monitor.
const PAGE_WIDTH: float = 1120.0

signal sail_requested()

var _party_box: VBoxContainer
var _status_label: Label
var _seed_field: LineEdit
var _reroll_button: Button
var _paste_button: Button
var _minimap_holder: PanelContainer
var _minimap: TextureRect
var _join_row: HBoxContainer
var _join_field: LineEdit
var _join_button: Button
var _code_row: HBoxContainer
var _code_field: LineEdit
var _copy_button: Button
var _invite_button: Button
var _sail_button: Button
var _sail_hint: Label
var _back_button: Button

var _preview_timer: SceneTreeTimer
var _previewed_seed: int = 0
## F-520: INVITE was pressed with no lobby open. The lobby is being created; invite as soon as it is.
var _invite_when_open: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_connect_services()
	refresh()


func menu_default_focus() -> Control:
	# The host's eye goes to the island; a joining player's to the field they must paste into.
	if _is_host_or_solo():
		return _seed_field
	return _join_field if _join_row.visible else _sail_button


func _exit_tree() -> void:
	_disconnect_services()


# ── Public API (the check drives these; buttons call the same paths) ──────────────────────────────


func request_host_and_sail() -> void:
	# Solo needs no lobby at all: a run is a scene load, and opening a Steam lobby for one person is
	# latency and a failure mode bought for nothing. Hosting happens when someone actually invites.
	sail_requested.emit()
	var frontend: Node = _frontend()
	if frontend != null and frontend.has_method("enter_world"):
		frontend.call("enter_world")


func request_open_lobby() -> void:
	_show_status("Opening a Steam lobby…", false)
	var lobby: Node = _lobby()
	if lobby == null:
		_show_status("Steam isn't available in this build.", true)
		return
	var err: int = int(lobby.call("host_session"))
	if err == ERR_UNAVAILABLE:
		_show_status("Steam isn't running — start it, then we sail.", true)


func request_join() -> void:
	var code: String = _join_field.text.strip_edges()
	if code.is_empty():
		_show_status("Paste a join code first — your friend gets it from the dock.", true)
		return
	var lobby: Node = _lobby()
	if lobby == null:
		_show_status("Steam isn't available in this build.", true)
		return
	_show_status("Joining %s…" % code, false)
	var err: int = int(lobby.call("join_by_id", code))
	if err == ERR_UNAVAILABLE:
		_show_status("Steam isn't running — start it, then we sail.", true)


func request_copy_code() -> void:
	var lobby: Node = _lobby()
	var lobby_id: int = int(lobby.call("current_lobby_id")) if lobby != null else 0
	if lobby_id == 0:
		_show_status("No code yet — open a lobby first.", true)
		return
	DisplayServer.clipboard_set(str(lobby_id))
	_toast("Join code copied — send it to a friend.")


## F-520: this used to hand the press straight to Steam's overlay and assume it worked. It has three
## honest outcomes instead, because two of them are common: there is no lobby yet (open one, and
## invite the moment it exists — pressing INVITE plainly means "I want someone in here"), the overlay
## is unavailable on this launch (fall back to the join code, which works everywhere), or the overlay
## is there and opens. What it must never do again is nothing.
func request_invite() -> void:
	var lobby: Node = _lobby()
	if lobby == null:
		_show_status("Steam isn't available in this build.", true)
		return

	if int(lobby.call("current_lobby_id")) == 0:
		_invite_when_open = true
		request_open_lobby()
		return

	if bool(lobby.call("open_invite_overlay")):
		_show_status("Steam's invite window is open — pick a friend.", false)
		return

	# No overlay: the join code is the invite. Put it where they can paste it and say so.
	DisplayServer.clipboard_set(str(int(lobby.call("current_lobby_id"))))
	_show_status(
		"Steam's overlay isn't available on this launch, so the invite window can't open. "
		+ "Your join code is copied — send it to a friend and they can paste it here.", true)
	_toast("Join code copied.")


## Stages the typed seed. A pure integer is used as-is; anything else is hashed, so a friend can
## share a memorable word the same way a number gets shared (`String.hash()` is fixed across every
## platform we ship to). Empty clears the override and the next run draws fresh.
func request_set_seed() -> void:
	var state: Node = _game_state()
	if state == null:
		return
	var text: String = _seed_field.text.strip_edges()
	if text.is_empty():
		state.call("set_pending_seed", 0)
		_show_status("No seed — we'll find an island when we get there.", false)
		_refresh_preview()
		return
	state.call("set_pending_seed", staged_seed_for(text))
	_refresh_preview()


func request_reroll() -> void:
	_seed_field.text = str(randi_range(1, 999999999))
	request_set_seed()


## The seed a given piece of text stages. Pulled out so the check can assert the rule without
## driving the widget, and so the preview and the staged value can never disagree.
static func staged_seed_for(text: String) -> int:
	var trimmed: String = text.strip_edges()
	if trimmed.is_empty():
		return 0
	var value: int = trimmed.to_int() if trimmed.is_valid_int() else trimmed.hash()
	return value if value != 0 else 1


func status_text() -> String:
	return _status_label.text


func party_row_count() -> int:
	return _party_box.get_child_count()


func previewed_seed() -> int:
	return _previewed_seed


func sail_enabled() -> bool:
	return not _sail_button.disabled


# ── State ─────────────────────────────────────────────────────────────────────────────────────────


## Rebuilds every derived part of the screen. Idempotent by construction — it re-derives rather than
## mutating — so it is safe on every lobby signal, which is what makes the dock live.
func refresh() -> void:
	var in_lobby: bool = _in_lobby()
	var mid_run: bool = _run_in_progress()
	var host_or_solo: bool = _is_host_or_solo()

	_join_row.visible = not in_lobby
	_code_row.visible = in_lobby
	_invite_button.visible = in_lobby

	var lobby: Node = _lobby()
	var lobby_id: int = int(lobby.call("current_lobby_id")) if lobby != null else 0
	var private: bool = _streamer_mode()
	_seed_field.secret = private
	_code_field.text = "hidden by Streamer Mode" if private and lobby_id != 0 \
		else (str(lobby_id) if lobby_id != 0 else "local game — no code to share")
	_copy_button.disabled = lobby_id == 0

	# The host picks the island; everyone else is cargo. Making that visible (rather than letting a
	# client type into a field whose value will be ignored) is the honest version of the rule.
	_seed_field.editable = host_or_solo
	_reroll_button.disabled = not host_or_solo

	if mid_run:
		_sail_button.text = "JUMP IN"
		_sail_button.disabled = false
		_sail_hint.text = "Cycle %d and sinking — hurry." % _current_cycle()
	elif host_or_solo:
		_sail_button.text = "SET SAIL"
		_sail_button.disabled = false
		_sail_hint.text = "everyone aboard? the island won't wait"
	else:
		_sail_button.text = "WAITING FOR THE HOST"
		_sail_button.disabled = true
		_sail_hint.text = "the host picks the island. stretch your legs."

	_rebuild_party()
	_refresh_preview()


func _rebuild_party() -> void:
	for child: Node in _party_box.get_children():
		_party_box.remove_child(child)
		child.queue_free()

	var members: Array = _members()
	for member: Dictionary in members:
		_party_box.add_child(_member_row(member))

	# Solo, with no lobby at all, still shows YOU on the dock — an empty party list would read as a
	# broken screen rather than as "nobody else is here yet".
	if members.is_empty():
		_party_box.add_child(_member_row({
			"name": _persona_name(), "is_owner": true, "is_local": true,
		}))

	var filled: int = _party_box.get_child_count()
	for index: int in range(filled, PARTY_SLOTS):
		_party_box.add_child(_empty_slot(index == filled))


func _member_row(member: Dictionary) -> Control:
	var card: PanelContainer = MireTheme.card(
		MireTheme.AMBER if bool(member.get("is_local", false)) else MireTheme.BORDER
	)
	var row: HBoxContainer = MireTheme.row()
	card.add_child(row)

	row.add_child(MireTheme.label("⛵", MireTheme.BODY, MireTheme.MOSS))
	var member_name: String = "Player" if _streamer_mode() else String(member.get("name", "?"))
	row.add_child(MireTheme.label(member_name, MireTheme.BODY, MireTheme.TEXT))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	# Tags are words, not colours — state is never carried by colour alone (docs/MENU.md §9).
	if bool(member.get("is_owner", false)):
		row.add_child(MireTheme.label("HOST", MireTheme.CAPTION, MireTheme.AMBER))
	if bool(member.get("is_local", false)):
		row.add_child(MireTheme.label("YOU", MireTheme.CAPTION, MireTheme.MUTED))
	return card


## An empty berth. The first one is the invite affordance — focusing it and pressing accept opens
## the Steam overlay, so "there is room for someone" and "add someone" are the same control rather
## than a separate button the player has to find.
func _empty_slot(is_invite: bool) -> Control:
	if not is_invite:
		var card: PanelContainer = MireTheme.card(MireTheme.BORDER.darkened(0.35))
		card.add_child(MireTheme.label("empty berth", MireTheme.CAPTION, MireTheme.MUTED))
		return card

	var button: Button = MireTheme.button("＋  INVITE A FRIEND", request_invite)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	return button


func _refresh_preview() -> void:
	# Debounced: a heightmap sweep per keystroke would make the field feel like treacle, and holding
	# backspace would queue one sweep per character.
	if _preview_timer != null and is_instance_valid(_preview_timer):
		_preview_timer.timeout.disconnect(_render_preview)
	_preview_timer = get_tree().create_timer(SEED_PREVIEW_DEBOUNCE, true, false, true)
	_preview_timer.timeout.connect(_render_preview)


func _render_preview() -> void:
	var seed_value: int = staged_seed_for(_seed_field.text)
	if seed_value == 0:
		# No seed staged: show the island THIS process would draw if you sailed now, so the preview
		# is never blank and never a lie.
		var state: Node = _game_state()
		if state != null and bool(state.call("is_seed_ready")):
			seed_value = int(state.get("run_seed"))
	if seed_value == 0:
		seed_value = 1
	if seed_value == _previewed_seed:
		return
	_previewed_seed = seed_value
	_minimap.texture = IslandMinimap.texture_for_seed(seed_value)


# ── Service wiring ────────────────────────────────────────────────────────────────────────────────


func _connect_services() -> void:
	var lobby: Node = _lobby()
	if lobby != null:
		for signal_name: String in [
			"lobby_created", "lobby_joined", "lobby_left", "members_changed",
		]:
			if lobby.has_signal(signal_name):
				lobby.connect(signal_name, _on_lobby_changed)
		if lobby.has_signal("lobby_failed"):
			lobby.connect("lobby_failed", _on_lobby_failed)
	var settings: Node = get_node_or_null(^"/root/SettingsService")
	if settings != null and settings.has_signal(&"settings_changed"):
		settings.connect(&"settings_changed", refresh)


	# F-520: these four lines sat under `_streamer_mode()`'s `return` as unreachable code, so the
	# dock never heard the session open or end and kept showing pre-session state until some other
	# signal happened to land. They belong here, at the end of the wiring they were written for.
	var session: Node = _session()
	if session != null:
		for signal_name: String in ["session_opened", "session_ended"]:
			if session.has_signal(signal_name):
				session.connect(signal_name, _on_lobby_changed)


func _streamer_mode() -> bool:
	var settings: Node = get_node_or_null(^"/root/SettingsService")
	return settings != null and settings.has_method(&"streamer_mode") \
		and bool(settings.call(&"streamer_mode"))


func _disconnect_services() -> void:
	var lobby: Node = _lobby()
	if lobby != null:
		for signal_name: String in [
			"lobby_created", "lobby_joined", "lobby_left", "members_changed",
		]:
			if lobby.has_signal(signal_name) and lobby.is_connected(signal_name, _on_lobby_changed):
				lobby.disconnect(signal_name, _on_lobby_changed)
		if lobby.has_signal("lobby_failed") and lobby.is_connected("lobby_failed", _on_lobby_failed):
			lobby.disconnect("lobby_failed", _on_lobby_failed)

	var session: Node = _session()
	if session != null:
		for signal_name: String in ["session_opened", "session_ended"]:
			if session.has_signal(signal_name) and session.is_connected(signal_name, _on_lobby_changed):
				session.disconnect(signal_name, _on_lobby_changed)
	var settings: Node = get_node_or_null(^"/root/SettingsService")
	if settings != null and settings.has_signal(&"settings_changed") \
			and settings.is_connected(&"settings_changed", refresh):
		settings.disconnect(&"settings_changed", refresh)


## One handler for every lobby/session signal, with the arguments deliberately ignored: the screen
## re-derives its whole state from the services rather than trusting a payload, which is what keeps
## it correct no matter which signal arrived or how many times (D-177's idempotence rule, applied to
## a screen instead of a service).
func _on_lobby_changed(_a: Variant = null, _b: Variant = null) -> void:
	refresh()
	# F-520: an invite asked for before there was a lobby, taken now that there is one.
	if _invite_when_open and _in_lobby():
		_invite_when_open = false
		request_invite()


func _on_lobby_failed(reason: String) -> void:
	_invite_when_open = false
	_show_status(reason, true)
	refresh()


func _lobby() -> Node:
	return get_node_or_null(^"/root/SteamLobby")


func _session() -> Node:
	return get_node_or_null(^"/root/NetSession")


func _transport() -> Node:
	return get_node_or_null(^"/root/NetTransport")


func _game_state() -> Node:
	return get_node_or_null(^"/root/GameState")


func _frontend() -> Node:
	var tree: SceneTree = get_tree()
	return tree.current_scene if tree != null else null


func _members() -> Array:
	var lobby: Node = _lobby()
	if lobby == null or not lobby.has_method("members"):
		return []
	return lobby.call("members")


func _persona_name() -> String:
	var lobby: Node = _lobby()
	if lobby != null and lobby.has_method("local_persona_name"):
		var name_text: String = String(lobby.call("local_persona_name")).strip_edges()
		if not name_text.is_empty():
			return name_text
	return "you"


func _in_lobby() -> bool:
	var lobby: Node = _lobby()
	return lobby != null and lobby.has_method("in_lobby") and bool(lobby.call("in_lobby"))


## Host, or nobody but you — both mean "your choices count". A solo player with no session at all is
## the host of a party of one.
func _is_host_or_solo() -> bool:
	var transport: Node = _transport()
	if transport == null or not transport.has_method("is_active") or not bool(transport.call("is_active")):
		return true
	var lobby: Node = _lobby()
	if lobby == null or not lobby.has_method("lobby_owner_id"):
		return true
	return int(lobby.call("lobby_owner_id")) == int(lobby.call("local_steam_id"))


## A session that is already live means the party is mid-run and this is a drop-in, not a departure.
func _run_in_progress() -> bool:
	var transport: Node = _transport()
	if transport == null or not transport.has_method("is_active"):
		return false
	if not bool(transport.call("is_active")):
		return false
	return _current_cycle() > 0


func _current_cycle() -> int:
	var cycle: Node = get_node_or_null(^"/root/CycleService")
	if cycle != null and cycle.has_method("current_cycle"):
		return int(cycle.call("current_cycle"))
	return 0


func _show_status(message: String, is_error: bool) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", MireTheme.ERROR if is_error else MireTheme.MUTED)


func _toast(message: String) -> void:
	var stack: Node = get_node_or_null(^"/root/MenuStack")
	if stack != null:
		stack.call("toast", message, false)


# ── Layout ────────────────────────────────────────────────────────────────────────────────────────


func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right"]:
		margin.add_theme_constant_override("margin_%s" % side, MireTheme.GRID * 9)
	margin.add_theme_constant_override("margin_top", MireTheme.GRID * 5)
	margin.add_theme_constant_override("margin_bottom", MireTheme.GRID * 5)
	add_child(margin)

	# Centre the page and cap its width. Left to fill a 1920-wide frame the party rows stretch into
	# 1500px ribbons with a name at one end and two tags at the other, which is unreadable at a
	# glance and looks nothing like a dock. A fixed measure with the frame falling away either side
	# is what keeps the same layout working from 1280 up to ultrawide.
	var centre: HBoxContainer = MireTheme.row(0)
	margin.add_child(centre)
	centre.add_child(_flexible_spacer())

	var page: VBoxContainer = MireTheme.column(MireTheme.GRID * 2)
	page.custom_minimum_size = Vector2(PAGE_WIDTH, 0.0)
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	centre.add_child(page)

	centre.add_child(_flexible_spacer())

	# Header
	var header: HBoxContainer = MireTheme.row()
	page.add_child(header)
	_back_button = MireTheme.link("◀  back", _go_back)
	header.add_child(_back_button)
	var title: Label = MireTheme.label("EXPEDITION", MireTheme.HEADLINE, MireTheme.TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_child(title)
	var balance := Control.new()
	balance.custom_minimum_size = Vector2(80.0, 0.0)
	header.add_child(balance)

	page.add_child(MireTheme.separator())

	# Two columns: who is coming, and where you are going.
	var columns: HBoxContainer = MireTheme.row(MireTheme.GRID * 3)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(columns)

	columns.add_child(_build_party_column())
	columns.add_child(_build_island_column())

	# Status, then the one primary action.
	_status_label = MireTheme.paragraph("", MireTheme.BODY, MireTheme.MUTED)
	page.add_child(_status_label)

	_sail_button = MireTheme.button("SET SAIL", request_host_and_sail, MireTheme.Variant.PRIMARY)
	page.add_child(_sail_button)

	_sail_hint = MireTheme.paragraph("everyone aboard? the island won't wait", MireTheme.CAPTION, MireTheme.MUTED)
	page.add_child(_sail_hint)

	MireTheme.wire_chain([
		_seed_field, _reroll_button, _join_field, _join_button,
		_copy_button, _invite_button, _sail_button, _back_button,
	])
	MireTheme.wire_row([_seed_field, _reroll_button])
	MireTheme.wire_row([_join_field, _paste_button, _join_button])
	MireTheme.wire_row([_code_field, _copy_button])


func _build_party_column() -> Control:
	var column: VBoxContainer = MireTheme.column()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(MireTheme.label("THE PARTY", MireTheme.CAPTION, MireTheme.MUTED))

	_party_box = MireTheme.column(MireTheme.GRID / 2)
	column.add_child(_party_box)

	# Join code (in a lobby) or join-a-friend (not in one). Only ever one of them is visible.
	_code_row = MireTheme.row(MireTheme.GRID / 2)
	column.add_child(_code_row)
	_code_field = MireTheme.text_field()
	_code_field.editable = false
	_code_field.focus_mode = Control.FOCUS_NONE
	_code_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code_field.add_theme_color_override("font_color", MireTheme.AMBER)
	_code_row.add_child(_code_field)
	_copy_button = MireTheme.button("COPY", request_copy_code)
	_code_row.add_child(_copy_button)

	_invite_button = MireTheme.button("INVITE FRIENDS (STEAM)", request_invite)
	column.add_child(_invite_button)

	_join_row = MireTheme.row(MireTheme.GRID / 2)
	column.add_child(_join_row)
	_join_field = MireTheme.text_field("paste a join code…")
	_join_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_field.text_submitted.connect(func(_text: String) -> void: request_join())
	_join_row.add_child(_join_field)
	_paste_button = MireTheme.button("PASTE", func() -> void:
		_join_field.text = DisplayServer.clipboard_get().strip_edges())
	_join_row.add_child(_paste_button)
	_join_button = MireTheme.button("JOIN", request_join)
	_join_row.add_child(_join_button)

	var host_button: Button = MireTheme.button("OPEN A LOBBY", request_open_lobby)
	column.add_child(host_button)

	return column


func _build_island_column() -> Control:
	var column: VBoxContainer = MireTheme.column()
	# Sized off the minimap plus the card's own padding, with room for the seed row beneath it —
	# at the first cut this column was narrow enough to truncate the seed field's placeholder.
	column.custom_minimum_size = Vector2(MINIMAP_SIDE + float(MireTheme.GRID * 8), 0.0)
	column.add_child(MireTheme.label("THE ISLAND", MireTheme.CAPTION, MireTheme.MUTED))

	_minimap_holder = MireTheme.card()
	column.add_child(_minimap_holder)
	_minimap = IslandMinimap.preview_rect(1, MINIMAP_SIDE)
	_minimap_holder.add_child(_minimap)

	var seed_row: HBoxContainer = MireTheme.row(MireTheme.GRID / 2)
	column.add_child(seed_row)
	_seed_field = MireTheme.text_field("a number or a word…")
	_seed_field.custom_minimum_size.x = 150.0
	_seed_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seed_field.text_submitted.connect(func(_text: String) -> void: request_set_seed())
	_seed_field.text_changed.connect(func(_text: String) -> void: request_set_seed())
	seed_row.add_child(_seed_field)
	_reroll_button = MireTheme.button("REROLL", request_reroll)
	seed_row.add_child(_reroll_button)

	column.add_child(MireTheme.paragraph(
		"leave it blank and we'll find one when we get there", MireTheme.CAPTION, MireTheme.MUTED
	))
	return column


## A zero-width control that eats leftover space. Used in pairs to centre a fixed-width page.
func _flexible_spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer


func _go_back() -> void:
	var stack: Node = get_node_or_null(^"/root/MenuStack")
	if stack != null:
		stack.call("pop")
