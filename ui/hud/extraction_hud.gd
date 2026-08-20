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
##
## F-238: a successful extraction had no run summary of its own — task 6.8 built one only for
## `ui/hud/defeat_hud.gd`'s death path (`EventBus.subscribe_salvage_banked`'s `extracted == true`
## branch was explicitly left unhandled by that file). This file now owns the success-path summary
## the same way `DefeatHud` owns the death one: a terminal, full-screen overlay shown on
## `EventBus.subscribe_run_extracted`, filled in with the Cycle reached, the modifiers drawn
## (`CycleModifierService.active_modifier_ids()`, task 6.2 — read-only, nothing to subscribe to,
## identical to `DefeatHud._modifiers_drawn_summary()`) and the Salvage banked
## (`EventBus.subscribe_salvage_banked`, only the `extracted == true` branch). Kept in THIS file
## rather than factored into a shared helper with `DefeatHud` (F-238's own suggestion) because this
## task's claim does not include `defeat_hud.gd` — the small formatting duplication is deliberate,
## not missed; a future task touching both files can still lift it into
## `ui/hud/run_summary_format.gd`.
##
## F-243: same un-terminal button `ui/hud/defeat_hud.gd` grew — see that file's own F-243 note for
## why only the local HOST peer's press does anything.
##
## F-307/D-185: and the same second input `DefeatHud` grew — `NetSession.session_ended`. F-243 read
## "am I the host" exactly once, when the overlay opened, so a client whose host quit sat on a
## disabled waiting label for a session that no longer existed while `blocks_gameplay_input` refused
## every menu over the top of it. On session end this screen's control becomes an enabled "Leave to
## Menu" and the overlay leaves the blocking group. Not "Start Next Run": an orphan's
## `_is_host_or_solo()` does flip true, but its world went with the session. Read `defeat_hud.gd`'s
## copy of this note with it — the pair must not drift.
##
## F-275: and the same keyboard/gamepad focus that button needs to be reachable at all — this summary
## is terminal, so it has no Esc/dismiss path and the restart button is the only way off it (the
## mandatory-panel trap F-216 fixed for `AttunementUI`). The enabled host button grabs focus as the
## overlay is shown and carries a visible focus ring; a non-host's disabled waiting label goes to
## `FOCUS_NONE` so it can never take focus a bare controller cannot act on. See `defeat_hud.gd`'s own
## F-275 note — the two screens are a deliberate pair and this half must not drift from it.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"
const SHIP_GROUP: StringName = &"extraction_ship"
const CYCLE_MODIFIER_SERVICE_PATH := ^"/root/CycleModifierService"
const POLL_SEC: float = 0.15
const NET_SESSION_PATH := ^"/root/NetSession"
const MAIN_MENU_PATH := ^"/root/MainMenu"
const RESTART_LABEL: String = "Start Next Run"
const WAITING_LABEL: String = "Waiting on the host to start the next run…"
const LEAVE_LABEL: String = "Leave to Menu"

const COLOUR_PANEL := Color(0.055, 0.086, 0.070, 0.92)
const COLOUR_BORDER := Color(0.345, 0.475, 0.390, 1.0)
const COLOUR_TEXT := Color(0.91, 0.94, 0.89, 1.0)
const COLOUR_PROGRESS := Color(0.894, 0.704, 0.286, 1.0)
const COLOUR_TRACK := Color(0.06, 0.08, 0.07, 0.85)

const BAR_SIZE := Vector2(320.0, 16.0)

## Summary screen palette — success-themed (green headline), distinct from `DefeatHud`'s red one,
## same background darkness and detail-text colour so the two terminal screens read as a pair.
const COLOUR_SUMMARY_BG := Color(0.02, 0.03, 0.02, 0.88)
const COLOUR_SUMMARY_HEADLINE := Color(0.36, 0.78, 0.42, 1.0)
const COLOUR_SUMMARY_DETAIL := Color(0.85, 0.85, 0.82, 1.0)
const SUMMARY_SUBTITLE: String = "EXTRACTED SAFELY"

var _panel: PanelContainer
var _label: Label
var _track: ColorRect
var _fill: ColorRect

var _nearby: Node3D
var _nearby_mode: StringName = &""
var _poll_elapsed: float = 0.0

var _summary_overlay: ColorRect
var _summary_headline: Label
var _summary_subtitle: Label
var _summary_modifiers_label: Label
var _summary_detail: Label
var _restart_button: Button
var _summary_shown: bool = false
## Tracked independently of `_summary_shown`, mirroring `DefeatHud._salvage_known` (F-235) — this
## screen's own `run_extracted`/`salvage_banked` pair has the same "either can legitimately land
## first" shape depending on autoload order, so neither guard may assume the other already ran.
var _salvage_known: bool = false
## F-243: same capture `DefeatHud` grew — this screen never needed one before, since it never closed.
var _restore_mouse_captured: bool = false
## F-307, mirroring `DefeatHud._session_over` exactly. Scoped to this overlay's lifetime, not the
## process: cleared on every showing and on the un-terminal path, set only by `session_ended`. A solo
## run never opens a session and so never sets it — which is the whole point, because a solo host and
## an orphaned client both answer `_is_host_or_solo()` with true and only one of them has a world.
var _session_over: bool = false


func _ready() -> void:
	_build_ui()
	set_process(true)
	EVENT_BUS.subscribe_run_extracted(_on_run_extracted)
	EVENT_BUS.subscribe_salvage_banked(_on_salvage_banked)
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)
	# Standing rule 1 (F-011/F-046): by path, never a bare `NetSession` — this file is an autoload
	# every `--script` harness loads at compile time.
	var session: Node = get_node_or_null(NET_SESSION_PATH)
	if session != null:
		session.connect(&"session_ended", Callable(self, "_on_session_ended"))


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_extracted(_on_run_extracted)
	EVENT_BUS.unsubscribe_salvage_banked(_on_salvage_banked)
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)
	var session: Node = get_node_or_null(NET_SESSION_PATH)
	if session != null and session.is_connected(&"session_ended", Callable(self, "_on_session_ended")):
		session.disconnect(&"session_ended", Callable(self, "_on_session_ended"))


func _process(delta: float) -> void:
	if _summary_shown:
		return
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


## Terminal for the run it ends, like `DefeatHud`'s own screen and `ExtractionShip.departed` — once
## shown, stays up until the run itself resets. Joins `blocks_gameplay_input` (D-032) the moment it
## shows, so `player_controller.gd`'s `gameplay_input_allowed()` stops local movement/interact
## without pausing the tree (a paused multiplayer client stalls networking — see that function's own
## note). F-243's un-terminal path is `_on_run_restarted()` just below.
func _on_run_extracted(cycle: int, _world_position: Vector3) -> void:
	if _summary_shown:
		return
	_summary_shown = true
	# F-307: this screen only opens while its session is alive, so every showing starts the flag
	# false — otherwise a later solo run would inherit an earlier orphaned run's LEAVE_LABEL.
	_session_over = false
	_summary_headline.text = "CYCLE %d" % cycle
	_summary_subtitle.text = SUMMARY_SUBTITLE
	_summary_modifiers_label.text = _modifiers_drawn_summary()
	if not _salvage_known:
		_summary_detail.text = "Tallying Salvage…"
	_refresh_restart_button()
	_panel.visible = false
	_summary_overlay.visible = true
	add_to_group(BLOCKING_UI_GROUP)
	_restore_mouse_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# F-275: after `visible = true`, never before — Godot force-releases focus from a Control that is
	# not visible in the tree, so a grab taken while the overlay is still hidden is thrown away.
	_grab_restart_focus()


## F-243: every peer's own `EVENT_BUS.run_restarted` (see `CycleService`'s own F-243 note for the
## host-emits/client-re-derives split) hides this screen and clears the one-shot guards so a SECOND
## extraction this session shows fresh numbers instead of no-op-ping on `_summary_shown` still true.
func _on_run_restarted() -> void:
	if not _summary_shown:
		return
	_summary_shown = false
	_salvage_known = false
	_session_over = false
	_summary_overlay.visible = false
	remove_from_group(BLOCKING_UI_GROUP)
	if _restore_mouse_captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## F-307, the same handler `DefeatHud` carries. `session_ended` fires once per session on every peer,
## and only after `NetSession`'s rejoin ladder is exhausted, so a peer that got back in never reaches
## here and one that does has nothing left to reconnect to.
func _on_session_ended(_reason: int, _detail: String) -> void:
	_session_over = true
	if not _summary_shown:
		return
	_refresh_restart_button()
	# Re-deriving the button alone would not fix the screen: while this overlay is in
	# `blocks_gameplay_input`, D-032's interlock turns every menu's `set_open(true)` into a no-op, so
	# there is still no route to a menu. Safe to leave the group at exactly this moment because the
	# session is dead — `PlayerNet` cleared the local player on disconnect, so no live world is being
	# handed input back.
	remove_from_group(BLOCKING_UI_GROUP)
	_grab_restart_focus()


func _refresh_restart_button() -> void:
	# F-307/D-185: an orphaned peer gets the way out, not a restart of a world the session tore down.
	# Checked before the host predicate because an orphan satisfies both.
	if _session_over:
		_restart_button.text = LEAVE_LABEL
		_restart_button.disabled = false
		_restart_button.focus_mode = Control.FOCUS_ALL
		return
	var is_local_host: bool = _is_host_or_solo()
	_restart_button.text = RESTART_LABEL if is_local_host else WAITING_LABEL
	_restart_button.disabled = not is_local_host
	# F-275: `disabled` does not take a Button out of the focus graph — it still answers grab_focus()
	# and still draws a focus ring, so without this a non-host peer gets a focused control whose
	# ui_accept does nothing. FOCUS_NONE is what makes the waiting label inert.
	_restart_button.focus_mode = Control.FOCUS_ALL if is_local_host else Control.FOCUS_NONE


## F-275: only ever grabs the enabled host button — `_refresh_restart_button()` has already put a
## non-host's waiting label at FOCUS_NONE, and grab_focus() on such a control is a no-op that only
## prints an engine warning.
func _grab_restart_focus() -> void:
	if _restart_button.focus_mode == Control.FOCUS_NONE:
		return
	_restart_button.grab_focus()


func _is_host_or_solo() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _on_restart_pressed() -> void:
	if _session_over:
		_leave_to_menu()
		return
	var cycle_service: Node = get_node_or_null(^"/root/CycleService")
	if cycle_service != null:
		cycle_service.call("host_restart_run")


## F-307. The summary stays up behind the menu — it is still this run's summary, and `MainMenu` is a
## higher CanvasLayer than either terminal overlay, so it draws and takes input over the top. An
## ordinary `set_open(true)`, which is precisely why the blocking-group removal above had to run first.
func _leave_to_menu() -> void:
	var main_menu: Node = get_node_or_null(MAIN_MENU_PATH)
	if main_menu != null:
		main_menu.call(&"set_open", true)


## Only the extraction half of this signal is ours — `extracted == false` is `DefeatHud`'s own death
## path. Gated on `_salvage_known`, not `_summary_shown` (same reasoning as `DefeatHud`'s F-235 fix)
## since this can legitimately fire before `_on_run_extracted` does, depending on autoload order.
func _on_salvage_banked(earned: int, total_salvage: int, _cycle: int, extracted: bool) -> void:
	if not extracted or _salvage_known:
		return
	_salvage_known = true
	_summary_detail.text = "Salvage earned: %d (%d total)" % [earned, total_salvage]


## "Modifiers drawn" stat: the run's whole stacked deck (task 6.2's `CycleModifierService`), in draw
## order, by display name — never a bare `CycleModifierDef` reference (F-016). Identical to
## `DefeatHud._modifiers_drawn_summary()`; see this file's header for why it is duplicated rather
## than shared.
func _modifiers_drawn_summary() -> String:
	var service: Node = get_node_or_null(CYCLE_MODIFIER_SERVICE_PATH)
	if service == null:
		return "Modifiers drawn: none"
	var ids: Array = service.call(&"active_modifier_ids")
	if ids.is_empty():
		return "Modifiers drawn: none"
	var names: PackedStringArray = []
	for id: Variant in ids:
		var def: Resource = service.call(&"def_for", id) as Resource
		var display_name: String = String(def.get(&"display_name")) if def != null else ""
		names.append(display_name if not display_name.is_empty() else String(id))
	return "Modifiers drawn: %s" % ", ".join(names)


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

	_build_summary_ui()


## Own `CanvasLayer` (layer 20, same as `DefeatHud`'s terminal screen) rather than this file's outer
## layer 5 — the bottom-centre prompt panel above deliberately sits BELOW other gameplay UI
## (inventory, chest, etc.), but a terminal run-ending screen must not.
func _build_summary_ui() -> void:
	var summary_layer := CanvasLayer.new()
	summary_layer.layer = 20
	add_child(summary_layer)

	_summary_overlay = ColorRect.new()
	_summary_overlay.color = COLOUR_SUMMARY_BG
	_summary_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_summary_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_summary_overlay.visible = false
	summary_layer.add_child(_summary_overlay)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	column.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_KEEP_SIZE)
	_summary_overlay.add_child(column)

	_summary_headline = Label.new()
	_summary_headline.add_theme_color_override("font_color", COLOUR_SUMMARY_DETAIL)
	_summary_headline.add_theme_font_size_override("font_size", 48)
	_summary_headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_summary_headline)

	_summary_subtitle = Label.new()
	_summary_subtitle.add_theme_color_override("font_color", COLOUR_SUMMARY_HEADLINE)
	_summary_subtitle.add_theme_font_size_override("font_size", 26)
	_summary_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_summary_subtitle)

	_summary_modifiers_label = Label.new()
	_summary_modifiers_label.add_theme_color_override("font_color", COLOUR_SUMMARY_DETAIL)
	_summary_modifiers_label.add_theme_font_size_override("font_size", 18)
	_summary_modifiers_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_summary_modifiers_label)

	_summary_detail = Label.new()
	_summary_detail.add_theme_color_override("font_color", COLOUR_SUMMARY_DETAIL)
	_summary_detail.add_theme_font_size_override("font_size", 18)
	_summary_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_summary_detail)

	_restart_button = Button.new()
	_restart_button.text = RESTART_LABEL
	_restart_button.custom_minimum_size = Vector2(240.0, 44.0)
	_restart_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# F-275: the visible focus ring every other panel in this codebase carries (F-209/F-216) — on a
	# full-screen overlay with one control, "which control has focus" is otherwise invisible.
	_restart_button.add_theme_stylebox_override("focus", _focus_style())
	_restart_button.pressed.connect(_on_restart_pressed)
	column.add_child(_restart_button)


## Visible focus ring (F-209/F-216/F-275) — same transparent-fill outline shape as
## `ui/hud/defeat_hud.gd`/`ui/lobby/lobby_menu.gd`'s own copies of this helper, in this screen's own
## success-green accent rather than the defeat screen's red.
func _focus_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	style.draw_center = false
	style.border_color = COLOUR_SUMMARY_HEADLINE
	style.set_border_width_all(2)
	style.set_corner_radius_all(5)
	return style
