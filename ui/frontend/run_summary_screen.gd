extends Control

## RunSummaryScreen — MENU-7: the ceremony (docs/MENU.md §6.2).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI over this peer's own
## `RunRecord`. Restarting is host-only, and it asks `CycleService.host_restart_run()`, which already
## owns that decision; a non-host sees a disabled button with a reason rather than a control that
## silently does nothing (F-243's shape, kept).
##
## ## One screen for all three endings
##
## `ui/hud/extraction_hud.gd` and `ui/hud/defeat_hud.gd` each grew their own terminal summary
## overlay, and both file headers already ask for the duplication to be lifted out —
## `extraction_hud.gd` names the destination (`ui/hud/run_summary_format.gd`) and says the copy is
## "deliberate, not missed" only because that task's claim did not include the other file. This is
## that lift: extracted, wiped and consumed differ by a cause line and a number, not by a layout.
##
## ## Why the number counts up
##
## DESIGN.md §1: the brag is a number you say out loud. A count-up is the cheapest possible way to
## make a number feel earned, and it costs one tween. It is skippable with any press, and
## reduce-motion shows the final value immediately (`MireTheme.motion_scale()` collapses the
## duration to zero, so no branch is needed here).
##
## ## Scope: per-player stat rows are NOT here
##
## docs/MENU.md §6.2 shows a row per player — kills, gathered, revives, deaths. Nothing in this
## project tallies any of that: it needs a host-authoritative `RunStatsService` accumulating from
## EventBus, replicated once at run end, which is a new networked system with a `PROTOCOL_VERSION`
## bump and two-process evidence. That is its own task, not a rider on the screen that would display
## it. Filed as a finding. The layout below has the slot for it.

const MireTheme := preload("res://ui/theme/mire_theme.gd")
const IslandMinimap := preload("res://ui/frontend/island_minimap.gd")
const RunRecordSave := preload("res://core/save/run_record_save.gd")

const HEADLINE_HOLD: float = 0.15

var _record: Dictionary = {}
var _cycle_label: Label
var _restart_button: Button
var _title_button: Button
var _counting: Tween


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if _record.is_empty():
		_record = _load_record()
	_build()
	_play_count_up()


## Fills the screen from an explicit record rather than from disk. Called before the screen enters
## the tree; the summary shown right after a run must be THAT run, not whatever the last write
## happened to leave on disk.
func present(record: Dictionary) -> void:
	_record = record.duplicate(true)


func menu_default_focus() -> Control:
	return _restart_button if not _restart_button.disabled else _title_button


## The summary is terminal for the run it describes: Esc must not dismiss it back into a world that
## has already ended. Both buttons are real ways out, so this is not the mandatory-panel trap F-275
## filed — that was a pinned screen with NO exit at all.
func menu_allows_cancel() -> bool:
	return false


## Any press finishes the count-up immediately. A player who has seen the number does not want to
## watch it arrive, and an animation you cannot skip is an animation that annoys on the second run.
func _input(event: InputEvent) -> void:
	if _counting == null or not _counting.is_valid():
		return
	if event is InputEventKey and (event as InputEventKey).pressed:
		_finish_count_up()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_finish_count_up()
	elif event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
		_finish_count_up()


# ── Public API (the check drives these) ───────────────────────────────────────────────────────────


func record() -> Dictionary:
	return _record


func cycle_text() -> String:
	return _cycle_label.text


func restart_enabled() -> bool:
	return not _restart_button.disabled


func request_restart() -> void:
	var cycle: Node = get_node_or_null(^"/root/CycleService")
	if cycle != null and cycle.has_method("host_restart_run"):
		cycle.call("host_restart_run")
	var stack: Node = get_node_or_null(^"/root/MenuStack")
	if stack != null:
		stack.call("pop_all")


func request_title() -> void:
	var stack: Node = get_node_or_null(^"/root/MenuStack")
	if stack != null:
		stack.call("pop_all")
	var frontend_scene: String = "res://levels/frontend.tscn"
	if ResourceLoader.exists(frontend_scene):
		get_tree().change_scene_to_file(frontend_scene)


# ── Internals ─────────────────────────────────────────────────────────────────────────────────────


func _load_record() -> Dictionary:
	var run_record: Node = get_node_or_null(^"/root/RunRecord")
	if run_record != null and run_record.has_method("last_run"):
		return run_record.call("last_run")
	return RunRecordSave.load_data()


## Host-only, exactly as F-243 established: `CycleService.host_restart_run()` is host-only and there
## is no request RPC, so a client pressing it would do nothing. A disabled button WITH A REASON is
## the honest presentation of that; a working-looking button that silently fails is not.
func _is_host() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null or not transport.has_method("is_active") or not bool(transport.call("is_active")):
		return true
	var lobby: Node = get_node_or_null(^"/root/SteamLobby")
	if lobby == null or not lobby.has_method("lobby_owner_id"):
		return true
	return int(lobby.call("lobby_owner_id")) == int(lobby.call("local_steam_id"))


func _play_count_up() -> void:
	var target: int = int(_record.get("cycle", 0))
	var duration: float = MireTheme.DURATION_COUNT_UP * MireTheme.motion_scale()
	if duration <= 0.0 or target <= 0:
		_cycle_label.text = "CYCLE %d" % target
		return
	_cycle_label.text = "CYCLE 0"
	_counting = create_tween()
	_counting.tween_method(_set_cycle_display, 0.0, float(target), duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_counting.tween_interval(HEADLINE_HOLD)


func _set_cycle_display(value: float) -> void:
	_cycle_label.text = "CYCLE %d" % int(round(value))


func _finish_count_up() -> void:
	if _counting != null and _counting.is_valid():
		_counting.kill()
	_counting = null
	_cycle_label.text = "CYCLE %d" % int(_record.get("cycle", 0))


func _build() -> void:
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)

	var panel: PanelContainer = MireTheme.panel()
	panel.custom_minimum_size = Vector2(700.0, 0.0)
	centre.add_child(panel)

	var column: VBoxContainer = MireTheme.column(MireTheme.GRID)
	panel.add_child(column)

	# The headline. Tabular numerals matter here: without them the number jitters horizontally as it
	# counts, which turns the one moment of ceremony into a wobble.
	_cycle_label = MireTheme.label("CYCLE 0", MireTheme.DISPLAY, MireTheme.AMBER)
	_cycle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_cycle_label)

	var cause: String = String(_record.get("cause_line", ""))
	if not cause.is_empty():
		column.add_child(MireTheme.paragraph("\"%s\"" % cause, MireTheme.TITLE, MireTheme.TEXT))

	column.add_child(MireTheme.separator())

	var body: HBoxContainer = MireTheme.row(MireTheme.GRID * 2)
	column.add_child(body)

	# The island it happened on, when the record knows which one.
	var seed_value: int = int(_record.get("seed", 0))
	if seed_value != 0:
		var card: PanelContainer = MireTheme.card()
		card.add_child(IslandMinimap.preview_rect(seed_value, 150.0))
		body.add_child(card)

	var facts: VBoxContainer = MireTheme.column(MireTheme.GRID / 2)
	facts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(facts)

	facts.add_child(_fact("modifiers drawn", _modifiers_text()))
	facts.add_child(_fact("salvage banked", "+%d" % int(_record.get("salvage_banked", 0)), MireTheme.MOSS))
	facts.add_child(_fact("ending", _ending_text()))

	# MENU-7's remaining half lives here: a row per player, once something tallies them.

	column.add_child(MireTheme.separator())

	var host: bool = _is_host()
	_restart_button = MireTheme.button("ONE MORE RUN", request_restart, MireTheme.Variant.PRIMARY)
	_restart_button.disabled = not host
	column.add_child(_restart_button)
	if not host:
		column.add_child(MireTheme.paragraph(
			"waiting on the host to start the next one", MireTheme.CAPTION, MireTheme.MUTED
		))

	_title_button = MireTheme.button("BACK TO TITLE", request_title)
	column.add_child(_title_button)

	MireTheme.wire_chain([_restart_button, _title_button])


func _fact(label_text: String, value_text: String, colour: Color = MireTheme.TEXT) -> Control:
	var row: HBoxContainer = MireTheme.row()
	var key: Label = MireTheme.label(label_text, MireTheme.CAPTION, MireTheme.MUTED)
	key.custom_minimum_size = Vector2(160.0, 0.0)
	row.add_child(key)
	var value: Label = MireTheme.label(value_text, MireTheme.BODY, colour)
	value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(value)
	return row


func _modifiers_text() -> String:
	var modifiers: Variant = _record.get("modifiers", [])
	if not (modifiers is Array) or (modifiers as Array).is_empty():
		return "none — the island did it unaided"
	var names: Array = []
	for id: Variant in modifiers:
		names.append(String(id).replace("_", " ").capitalize())
	return ", ".join(names)


func _ending_text() -> String:
	match String(_record.get("ending", "")):
		"extracted":
			return "you left on your own terms"
		"wiped":
			return "the island took you"
		"consumed":
			return "the island ran out"
		_:
			return "unrecorded"
