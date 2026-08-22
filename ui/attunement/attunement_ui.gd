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
##
## F-216: because there is no dismiss path, a bare controller MUST be able to reach a CHOOSE button
## with no mouse at all — unlike every other F-209 panel, this one is not optional. Opening grabs
## the first ROLE_ORDER button, the buttons chain top<->bottom (_wire_vertical_chain, rebuilt with
## the rows every open since Registry content is boot-time-static but the row set still gets torn
## down and rebuilt per open), and each carries a visible "focus" stylebox override. ui_accept
## already carries a gamepad binding project-wide (tools/bind_ui_gamepad_actions.gd, F-209) so no
## further wiring is needed for CHOOSE itself.
##
## F-277: "run start" is every run, not just the first. `EventBus.run_restarted` re-arms this panel —
## AttunementService clears the run-scoped selection on that same event, so the picker has to reopen
## for the new run or the player spends it with no Attunement and no way to pick one. The re-arm is
## driven from BOTH `run_restarted` and `selection_changed`, because on a client the host's clearing
## broadcast and the re-derived `run_restarted` can land in either order.
##
## F-321/D-185: the F-297 timeout below bounds ONE request; it does not bound the panel. A client
## whose host quits while the picker is up never gets `selection_confirmed`, so the timeout re-enables
## the buttons, the player presses one, `request_select()` goes to a peer that no longer exists,
## `_picking` latches, and eight seconds later it re-enables — forever. That is worse than F-307's
## stuck overlay, because it looks alive. The panel never leaves `blocks_gameplay_input`, so D-032's
## interlock refuses MainMenu/SettingsMenu/LobbyMenu/UnlockMenu the whole time and the player cannot
## even quit to the menu. `NetSession.session_ended` is this panel's second input for exactly the
## reason it is DefeatHUD's: "the host will answer" is a fact about a LIVE session, and this file read
## it once, at open. On session end there is no run left to pick an Attunement FOR, so the panel
## closes outright rather than degrading to a dismissable state — D-185's reasoning, transposed.
##
## F-297: `_picking` is a bounded wait, not a latch. A mandatory panel — no Esc, no dismiss path,
## `blocks_gameplay_input` while open — that disables every button until an answer that may never
## come is a soft-lock with no way back to gameplay, so an unanswered request expires after
## REQUEST_TIMEOUT_SEC and re-enables the buttons with the failure in the status line.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"
const PLAYERS_GROUP: StringName = &"players"
## Standing rule 1 (F-011/F-046): NetSession by PATH, never as a bare identifier — this file is an
## autoload that every `--script` harness loads at compile time, and most of them install no session
## at all. A missing node here means "no session to end", which is exactly right for solo.
const NET_SESSION_PATH := ^"/root/NetSession"
const POLL_INTERVAL_SEC: float = 0.5
## F-297: how long an unanswered `request_select()` may keep the buttons disabled. Generous enough
## that a normal host round-trip (one reliable RPC each way) never trips it, short enough that a
## player whose host vanished mid-request is not staring at a dead panel.
const REQUEST_TIMEOUT_SEC: float = 8.0
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
var _request_timer: Timer

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

	# F-297's bounded wait. One-shot, armed by `choose()` and disarmed by any answer.
	_request_timer = Timer.new()
	_request_timer.wait_time = REQUEST_TIMEOUT_SEC
	_request_timer.one_shot = true
	_request_timer.timeout.connect(_on_request_timeout)
	add_child(_request_timer)

	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)
	# F-321. Connected once here rather than per-open: the picker can be open across a session end in
	# either order, and a subscription that only exists while the panel is showing would miss the end
	# that arrives on the same frame the panel opens.
	var session: Node = get_node_or_null(NET_SESSION_PATH)
	if session != null:
		session.connect(&"session_ended", Callable(self, "_on_session_ended"))


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)
	var session: Node = get_node_or_null(NET_SESSION_PATH)
	if session != null and session.is_connected(&"session_ended", Callable(self, "_on_session_ended")):
		session.disconnect(&"session_ended", Callable(self, "_on_session_ended"))


## A blocking cursor panel owns the mouse for its entire showing, not only on the frame it opens.
## Player bodies and run-boundary HUDs can become ready after this autoload and legitimately try to
## restore captured gameplay input. Without this guard their later write wins and strands a
## mouse-driven mandatory picker behind a captured cursor (F-530). Reasserting VISIBLE is
## client-local presentation only; the blocking group continues to suppress gameplay input.
func _process(_delta: float) -> void:
	if not _open:
		return
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var focused: Control = get_viewport().gui_get_focus_owner()
	if focused == null or not is_ancestor_of(focused):
		_grab_initial_focus()


# ── Public API (the check drives these) ─────────────────────────────────────────────────────────


func is_open() -> bool:
	return _open


func choose(attunement_id: StringName) -> void:
	if not _open or _picking:
		return
	_picking = true
	_set_buttons_disabled(true)
	_show_status("Requesting %s…" % attunement_id, false)
	_request_timer.start()
	AttunementService.request_select(attunement_id)


func role_button_count() -> int:
	return _role_buttons.size()


func status_text() -> String:
	return _status_label.text


func is_picking() -> bool:
	return _picking


## F-297: seconds left on the bounded wait, 0.0 when nothing is pending. A check asserting only that
## the buttons come back could pass against a fix that re-enabled them immediately and dropped the
## request; this proves the wait is real and armed.
func pending_request_seconds_left() -> float:
	return _request_timer.time_left


## F-297: how many CHOOSE buttons a player could actually press right now. On a panel with no
## dismiss path this — not `_picking` — is what decides whether they are stuck, so it is what the
## check asserts.
func operable_button_count() -> int:
	var operable: int = 0
	for button: Button in _role_buttons.values():
		if not button.disabled:
			operable += 1
	return operable


## Test/debug seam: force-checks for the local player right now instead of waiting for the poll
## interval, so a check does not need to sleep POLL_INTERVAL_SEC to prove the trigger works.
func poll_now() -> void:
	_poll_for_local_player()


## Test/debug seam, same shape as `poll_now()`: run F-297's bounded-wait expiry immediately instead
## of sleeping REQUEST_TIMEOUT_SEC, so a check can prove the panel recovers without stalling for it.
func expire_pending_request_now() -> void:
	_on_request_timeout()


## Test seam for the same per-frame ownership guard `_process()` drives in play.
func enforce_input_ownership_now() -> void:
	_process(0.0)


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
	_grab_initial_focus()


func _close_picker() -> void:
	if not _open:
		return
	_open = false
	remove_from_group(BLOCKING_UI_GROUP)
	_shade.visible = false
	_center.visible = false
	if _restore_mouse_captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## F-321. The session this picker opened under is over: close it, unconditionally and without waiting
## for an answer that can no longer come.
##
## Closing outright rather than leaving it open-but-dismissable is D-185's call transposed. There is
## no world left to pick an Attunement for — `PlayerNet` clears on disconnect — so a picker that
## stayed up would be asking a question about a run that no longer exists. Leaving the blocking group
## is the part that actually matters: until this runs, D-032's interlock refuses every menu, so this
## is what gives an orphaned client its way back to the main menu.
##
## The mouse is deliberately left VISIBLE rather than restored to `_restore_mouse_captured`. That flag
## records what gameplay wanted at the instant the picker opened, and gameplay is what just went away;
## re-capturing the cursor here would hand a menu-bound player a hidden pointer at the exact moment
## they need to click their way out.
func _on_session_ended(_reason: int, _detail: String) -> void:
	_request_timer.stop()
	_picking = false
	if not _open:
		return
	_restore_mouse_captured = false
	_close_picker()


# ── AttunementService signals ───────────────────────────────────────────────────────────────────


func _on_selection_confirmed(accepted: bool, attunement_id: StringName, detail: String) -> void:
	_request_timer.stop()
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
		return
	# F-277: on a CLIENT this is the event that actually frees the next run's pick — the host's
	# `net_attunement_selected(peer, &"")` clear can land after the re-derived `run_restarted`, in
	# which case the re-arm below is the one that opens the picker. `_rearm_for_new_run()` is a no-op
	# unless the LOCAL selection is now empty, so a teammate's pick never reopens this panel.
	_rearm_for_new_run()


## F-297. Not "the request failed" — "the request has not been answered inside a bounded wait", which
## on a panel with no dismiss path has to be recoverable. Restores the buttons and says so; a late
## answer that arrives afterwards is still handled by `_on_selection_confirmed()` above.
func _on_request_timeout() -> void:
	if not _open or not _picking:
		return
	_picking = false
	_set_buttons_disabled(false)
	_show_status("No answer from the host — pick again.", true)


# ── Run boundary (F-277) ─────────────────────────────────────────────────────────────────────────


## Every peer's own `EventBus.run_restarted` (the host emits it directly, a client re-derives it from
## the WorldDeltaLog record — see `CycleService.host_restart_run()`). The selection it invalidates is
## AttunementService's to clear; all this does is put the panel back in its pre-pick state.
func _on_run_restarted() -> void:
	_picking = false
	_request_timer.stop()
	if _open:
		# Already open — the pick was never made, so keep the panel and just drop any stale request.
		_set_buttons_disabled(false)
		_show_status("Pick one — it is locked for the run.", false)
		_refresh_party()
		return
	_rearm_for_new_run()


## Re-arms the D-071 trigger for a new run: guarded so it only fires once the local selection really
## is clear, and polled straight away rather than waiting out POLL_INTERVAL_SEC — the player's body
## already exists on a restart, so there is nothing to wait for.
##
## The poll is DEFERRED, not immediate. `run_restarted` subscribers run synchronously in autoload
## order and this file is registered ahead of DefeatHud/ExtractionHud, each of which restores
## `Input.mouse_mode` to CAPTURED inside its own handler. Opening during that emit would sample the
## terminal overlay's VISIBLE cursor as "what to restore afterwards", and the HUD would then capture
## the mouse out from under a panel whose only mouse control is a CHOOSE button.
func _rearm_for_new_run() -> void:
	if _open or AttunementService.local_selection() != &"":
		return
	_poll_timer.start()
	_poll_for_local_player.call_deferred()


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

	# F-216: chain every CHOOSE button, in ROLE_ORDER, wrapping top<->bottom — same recipe F-209
	# gave UnlockMenu's BUY-button rows (unlock_menu.gd's _wire_vertical_chain).
	var chain: Array = []
	for role_id: StringName in ROLE_ORDER:
		if _role_buttons.has(role_id):
			chain.append(_role_buttons[role_id])
	_wire_vertical_chain(chain)


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
	pick_button.add_theme_stylebox_override("focus", _focus_style())
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


## F-216: this panel has no Esc/dismiss path (see file header) — a bare controller's only way past
## it is ui_accept on a focused CHOOSE button, so unlike every other F-209 panel, grabbing initial
## focus here is not a convenience, it is what makes the panel reachable at all.
func _grab_initial_focus() -> void:
	for role_id: StringName in ROLE_ORDER:
		if _role_buttons.has(role_id):
			_role_buttons[role_id].grab_focus()
			return


func _wire_vertical_chain(controls: Array) -> void:
	var count: int = controls.size()
	for i: int in count:
		var current: Control = controls[i]
		var prev: Control = controls[(i - 1 + count) % count]
		var next: Control = controls[(i + 1) % count]
		current.focus_neighbor_top = current.get_path_to(prev)
		current.focus_neighbor_bottom = current.get_path_to(next)


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


## Visible focus ring (F-209/F-216) — same transparent-fill outline shape as main_menu.gd/
## unlock_menu.gd's own copies of this helper.
func _focus_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	style.draw_center = false
	style.border_color = COLOUR_ACCENT
	style.set_border_width_all(2)
	style.set_corner_radius_all(5)
	return style
