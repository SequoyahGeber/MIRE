extends CanvasLayer

## Client-local presentation for task 4.8's Wellspring ritual — a bottom-centre prompt/progress bar,
## built in code (same reasoning as ui/hud/vitals_hud.gd: an always-on HUD has nowhere safe to live
## in a hand-authored scene without an exact claim on it, and this autoload needs none).
##
## ARCHITECTURE.md §2.2 "VFX, audio, camera, UI" row: client-local only. Every number shown here is
## either the LOCAL player's own position (client-known already) or a replicated Wellspring
## property; nothing here mutates state except sending `request_toggle_channel()`, which the host
## re-validates before acting on it.
##
## F-164: a second, top-centre panel warns ambiently once ANY capped Wellspring crosses
## `Wellspring.RECORRUPTING_VISUAL_FRACTION` of its clock — independent of `_nearby`/`_refresh_panel`
## above, which only ever track an UNCAPPED Wellspring the local player stands next to (that pair
## exists to drive the capping PROMPT, not to report status). DESIGN.md's "visible on the horizon"
## framing is why this does not gate on proximity or on which player did the capping: every peer
## polls the same replicated `recorruption_sec` field this HUD already reads for the in-range case,
## so a player anywhere on the map — not just one who happens to walk past the decaying mesh — gets
## the warning before it flips back to needing a fresh ritual.

const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"
const WELLSPRING_GROUP: StringName = &"wellspring"
const POLL_SEC: float = 0.15

const COLOUR_PANEL := Color(0.055, 0.086, 0.070, 0.92)
const COLOUR_BORDER := Color(0.345, 0.475, 0.390, 1.0)
const COLOUR_TEXT := Color(0.91, 0.94, 0.89, 1.0)
const COLOUR_PROGRESS := Color(0.894, 0.704, 0.286, 1.0)
const COLOUR_TRACK := Color(0.06, 0.08, 0.07, 0.85)
const COLOUR_WARNING := Color(0.87, 0.44, 0.20, 1.0)

const BAR_SIZE := Vector2(280.0, 16.0)

var _panel: PanelContainer
var _label: Label
var _track: ColorRect
var _fill: ColorRect

var _warning_panel: PanelContainer
var _warning_label: Label

var _nearby: Node3D
var _poll_elapsed: float = 0.0


func _ready() -> void:
	_build_ui()
	set_process(true)


func _process(delta: float) -> void:
	_poll_elapsed += delta
	if _poll_elapsed < POLL_SEC:
		return
	_poll_elapsed = 0.0
	_refresh_nearby()
	_refresh_panel()
	_refresh_recorruption_warning()


func _input(event: InputEvent) -> void:
	if _nearby == null or not event.is_action_pressed(&"interact"):
		return
	if not get_tree().get_nodes_in_group(BLOCKING_UI_GROUP).is_empty():
		return
	if get_viewport().is_input_handled():
		return
	if not bool(_nearby.call(&"is_local_player_in_range")):
		return
	_nearby.call(&"request_toggle_channel")
	get_viewport().set_input_as_handled()


func _refresh_nearby() -> void:
	var best: Node3D = null
	var best_distance_sq: float = INF
	var origin: Vector3 = _local_camera_position()
	for node: Node in get_tree().get_nodes_in_group(WELLSPRING_GROUP):
		var wellspring := node as Node3D
		if wellspring == null or bool(wellspring.get("capped")):
			continue
		if not bool(wellspring.call(&"is_local_player_in_range")):
			continue
		var distance_sq: float = origin.distance_squared_to(wellspring.global_position)
		if distance_sq < best_distance_sq:
			best = wellspring
			best_distance_sq = distance_sq
	_nearby = best


func _local_camera_position() -> Vector3:
	var camera: Camera3D = get_viewport().get_camera_3d()
	return camera.global_position if camera != null else Vector3.ZERO


func _refresh_panel() -> void:
	if _nearby == null:
		_panel.visible = false
		return
	_panel.visible = true
	var channeling: bool = bool(_nearby.get("channeling"))
	var progress: float = float(_nearby.get("progress_sec"))
	var duration: float = maxf(float(_nearby.get("duration_sec")), 0.01)
	var required: int = int(_nearby.get("required_players"))
	if channeling:
		_label.text = "Capping the Wellspring — needs %d player(s) present" % required
		_track.visible = true
		_fill.visible = true
		_fill.size.x = BAR_SIZE.x * clampf(progress / duration, 0.0, 1.0)
	else:
		_label.text = "Hold %s to begin capping the Wellspring (needs %d player(s))" % [
			_interact_key_label(), required
		]
		_track.visible = false
		_fill.visible = false


## F-164: every capped Wellspring in the group, not just `_nearby` — a recorrupting one is never
## `_nearby` in the first place (`_refresh_nearby()` skips `capped == true` on purpose, that pair is
## for the capping prompt only). Reads `Wellspring`'s own tuning constants directly (global class
## via `class_name`, same as any other consumer of them — see `wellspring_recorruption_check.gd`)
## rather than hard-coding the threshold, per DELEGATION.md's own guidance to a future consumer.
func _refresh_recorruption_warning() -> void:
	var recorrupting_count: int = 0
	var soonest_remaining: float = INF
	var threshold: float = Wellspring.RECORRUPTION_DURATION_SEC * Wellspring.RECORRUPTING_VISUAL_FRACTION
	for node: Node in get_tree().get_nodes_in_group(WELLSPRING_GROUP):
		var wellspring := node as Node3D
		if wellspring == null or not bool(wellspring.get("capped")):
			continue
		var recorruption_sec: float = float(wellspring.get("recorruption_sec"))
		if recorruption_sec < threshold:
			continue
		recorrupting_count += 1
		var remaining: float = maxf(Wellspring.RECORRUPTION_DURATION_SEC - recorruption_sec, 0.0)
		soonest_remaining = minf(soonest_remaining, remaining)

	if recorrupting_count == 0:
		_warning_panel.visible = false
		return
	_warning_panel.visible = true
	var remaining_label: String = _format_remaining(soonest_remaining)
	if recorrupting_count == 1:
		_warning_label.text = "A Wellspring is losing its cap — recorrupts in %s" % remaining_label
	else:
		_warning_label.text = "%d Wellsprings are losing their cap — nearest in %s" % [
			recorrupting_count, remaining_label
		]


func _format_remaining(seconds: float) -> String:
	var total: int = int(ceil(seconds))
	return "%d:%02d" % [total / 60, total % 60]


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

	# Anchor-based, not a manual position computed from _panel.size — that size is not yet valid
	# the frame this node is built, and this way stays correct across any later viewport resize too.
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_KEEP_SIZE)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.offset_top = -220.0
	_panel.offset_bottom = -160.0

	_build_warning_panel()


## F-164's ambient panel — top-centre, clear of both the capping prompt above (bottom-centre) and
## `vitals_hud.gd`'s own state banner (`BANNER_HEIGHT_FRACTION` 0.32 down from the top, and on a
## higher `layer` besides, so the two can never overlap-and-fight for the same pixels).
func _build_warning_panel() -> void:
	_warning_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = COLOUR_PANEL
	style.border_color = COLOUR_WARNING
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8.0)
	_warning_panel.add_theme_stylebox_override("panel", style)
	_warning_panel.visible = false
	add_child(_warning_panel)

	_warning_label = Label.new()
	_warning_label.add_theme_color_override("font_color", COLOUR_WARNING)
	_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_warning_panel.add_child(_warning_label)

	_warning_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_KEEP_SIZE)
	_warning_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_warning_panel.offset_top = 16.0
