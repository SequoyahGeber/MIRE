extends CanvasLayer

## Task 5.5's boss health bar — top-centre name/health/phase-pip readout, built in code (same
## reasoning as ui/hud/vitals_hud.gd and ui/hud/wellspring_hud.gd: an always-on HUD has nowhere safe
## to live in a hand-authored scene without an exact claim on it, and this autoload needs none).
##
## ARCHITECTURE.md §2.2 "VFX, audio, camera, UI": client-local only. Every number shown here is a
## `Boss` property that is either the host's own live value or a client's already-replicated copy
## (`health`/`state` from `Enemy`, `phase` from `Boss` itself) — nothing here mutates anything.
##
## Polls the `bosses` group (`Boss.BOSS_GROUP`) the same way `wellspring_hud.gd` polls `wellspring`,
## rather than subscribing to `EventBus.boss_engaged`/etc: those fire once per transition and are the
## right shape for a one-shot stinger, but a health bar needs the CONTINUOUS fraction between
## transitions too, and a poll of the already-replicated field is simpler than layering a second
## "health changed" signal over the top of `hit_counter`'s existing jump-detection role.

const BOSS_GROUP: StringName = &"bosses"
const POLL_SEC: float = 0.1

const COLOUR_PANEL := Color(0.086, 0.058, 0.058, 0.92)
const COLOUR_BORDER := Color(0.475, 0.310, 0.300, 1.0)
const COLOUR_TEXT := Color(0.94, 0.91, 0.89, 1.0)
const COLOUR_HEALTH := Color(0.82, 0.24, 0.22, 1.0)
const COLOUR_TRACK := Color(0.08, 0.06, 0.06, 0.85)
const COLOUR_PIP_ACTIVE := Color(0.894, 0.704, 0.286, 1.0)
const COLOUR_PIP_SPENT := Color(0.40, 0.30, 0.20, 0.9)

const BAR_SIZE := Vector2(420.0, 20.0)
const PIP_SIZE := Vector2(14.0, 6.0)
const PIP_GAP: float = 4.0

var _panel: PanelContainer
var _name_label: Label
var _track: ColorRect
var _fill: ColorRect
var _pip_row: HBoxContainer
var _pips: Array[ColorRect] = []

var _tracked: Node3D
var _poll_elapsed: float = 0.0


func _ready() -> void:
	layer = 6
	_build_ui()
	set_process(true)


func _process(delta: float) -> void:
	_poll_elapsed += delta
	if _poll_elapsed < POLL_SEC:
		return
	_poll_elapsed = 0.0
	_refresh_tracked()
	_refresh_panel()


## The nearest ENGAGED, living boss — "nearest" only matters once two are simultaneously live (not
## authored anywhere yet), so this is future-proofing rather than a scenario `tools/boss_check.gd`
## needs to exercise. A boss that has not yet been engaged (still dormant) or has already died shows
## no bar, same as `wellspring_hud.gd` hiding once a Wellspring caps.
func _refresh_tracked() -> void:
	var best: Node3D = null
	var best_distance_sq: float = INF
	var origin: Vector3 = _local_camera_position()
	for node: Node in get_tree().get_nodes_in_group(BOSS_GROUP):
		var boss := node as Node3D
		if boss == null or not is_instance_valid(boss):
			continue
		if not bool(boss.call(&"is_engaged")):
			continue
		var distance_sq: float = origin.distance_squared_to(boss.global_position)
		if distance_sq < best_distance_sq:
			best = boss
			best_distance_sq = distance_sq
	_tracked = best


func _local_camera_position() -> Vector3:
	var camera: Camera3D = get_viewport().get_camera_3d()
	return camera.global_position if camera != null else Vector3.ZERO


func _refresh_panel() -> void:
	if _tracked == null:
		_panel.visible = false
		return
	_panel.visible = true

	var definition: Resource = _tracked.get(&"definition")
	var display_name: String = ""
	if definition != null:
		display_name = String(definition.get("display_name"))
	if display_name.is_empty():
		display_name = "Boss"
	_name_label.text = display_name

	var fraction: float = float(_tracked.call(&"health_fraction"))
	_fill.size.x = BAR_SIZE.x * clampf(fraction, 0.0, 1.0)

	var phase_count: int = int(_tracked.call(&"phase_count"))
	var current_phase: int = int(_tracked.get(&"phase"))
	_refresh_pips(phase_count, current_phase)


## Rebuilds the pip row only when the phase COUNT changes (a different boss, or the same one first
## resolving its BossDef) — not every poll tick (F-099's usual "rebuild only when the underlying
## shape moves" rule). Recolouring the existing pips for a phase change is cheap and happens every
## refresh regardless.
func _refresh_pips(phase_count: int, current_phase: int) -> void:
	if _pips.size() != phase_count:
		for pip: ColorRect in _pips:
			pip.queue_free()
		_pips.clear()
		for i: int in phase_count:
			var pip := ColorRect.new()
			pip.custom_minimum_size = PIP_SIZE
			pip.color = COLOUR_PIP_SPENT
			_pip_row.add_child(pip)
			_pips.append(pip)
	for i: int in _pips.size():
		# A dormant boss (current_phase < 0) shows every pip unspent; otherwise phases at or before
		# the active one read as "passed" — the active phase itself included, since reaching it is
		# the thing worth showing, not just the ones fully behind it.
		var reached: bool = current_phase >= 0 and i <= current_phase
		_pips[i].color = COLOUR_PIP_ACTIVE if reached else COLOUR_PIP_SPENT


func _build_ui() -> void:
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
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 6)
	_panel.add_child(column)

	_name_label = Label.new()
	_name_label.add_theme_color_override("font_color", COLOUR_TEXT)
	_name_label.add_theme_font_size_override("font_size", 18)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_name_label)

	_track = ColorRect.new()
	_track.color = COLOUR_TRACK
	_track.custom_minimum_size = BAR_SIZE
	column.add_child(_track)

	_fill = ColorRect.new()
	_fill.color = COLOUR_HEALTH
	_fill.size = Vector2(0.0, BAR_SIZE.y)
	_track.add_child(_fill)

	_pip_row = HBoxContainer.new()
	_pip_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_pip_row.add_theme_constant_override("separation", int(PIP_GAP))
	column.add_child(_pip_row)

	# Anchor-based, not a manually computed position — same reasoning as wellspring_hud.gd's own
	# layout comment: _panel.size is not valid the frame this node is built, and an anchor preset
	# stays correct across any later viewport resize on its own.
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_KEEP_SIZE)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.offset_top = 24.0
	_panel.offset_bottom = 96.0
