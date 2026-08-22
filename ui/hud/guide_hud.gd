extends CanvasLayer

## Client-local presentation for `GuideService` (task 3.19, `docs/PROGRESSION.md` §5). Three
## surfaces and nothing else: the objective line bottom-left, a tip card top-centre, and the tier
## fanfare above it. Built in code for the same reason `vitals_hud.gd` and `wellspring_hud.gd` are —
## an always-on HUD has nowhere safe to live in a hand-authored scene without an exact claim on it
## (D-031), and an autoload needs none.
##
## ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row: client-local only. This node reads
## `GuideService`'s signals and draws them. It never polls gameplay state, never sends anything, and
## — the rule the whole guidance layer lives under — **never takes input, never takes the cursor,
## and never blocks.** Nothing here is in `blocks_gameplay_input`, deliberately: a tutorial that can
## stop the game is how a co-op session ends up waiting on the one player who is reading.

const MIRE_THEME := preload("res://ui/theme/mire_theme.gd")

## Below the menu layers and above the world, beside the other gameplay HUDs.
const LAYER: int = 5

const FADE_SEC: float = 0.25
## Bottom-left, clear of the hotbar. Measured against `vitals_hud.gd`'s own bottom-left block.
const OBJECTIVE_MARGIN := Vector2(24.0, -132.0)
const OBJECTIVE_WIDTH_PX: float = 360.0
const TIP_TOP_OFFSET: float = 96.0
const FANFARE_TOP_OFFSET: float = 180.0

var _objective_panel: PanelContainer
var _objective_label: Label
var _tip_panel: PanelContainer
var _tip_label: Label
var _fanfare_panel: PanelContainer
var _fanfare_title: Label
var _fanfare_label: Label

var _tip_remaining: float = 0.0
var _fanfare_remaining: float = 0.0


func _ready() -> void:
	_build_ui()
	var guide: Node = get_node_or_null(^"/root/GuideService")
	if guide != null:
		guide.connect(&"objective_changed", _on_objective_changed)
		guide.connect(&"tip_shown", _on_tip_shown)
		guide.connect(&"tip_cleared", _on_tip_cleared)
		guide.connect(&"fanfare_shown", _on_fanfare_shown)
	set_process(true)


func _process(delta: float) -> void:
	if _tip_remaining > 0.0:
		_tip_remaining -= delta
		if _tip_remaining <= 0.0:
			_fade_out(_tip_panel)
	if _fanfare_remaining > 0.0:
		_fanfare_remaining -= delta
		if _fanfare_remaining <= 0.0:
			_fade_out(_fanfare_panel)


func _on_objective_changed(_step_id: StringName, text: String) -> void:
	if text.strip_edges().is_empty():
		_fade_out(_objective_panel)
		return
	_objective_label.text = text
	_fade_in(_objective_panel)


func _on_tip_shown(_step_id: StringName, text: String, seconds: float) -> void:
	_tip_label.text = text
	_tip_remaining = seconds
	_fade_in(_tip_panel)


func _on_tip_cleared() -> void:
	_tip_remaining = 0.0
	_fade_out(_tip_panel)


func _on_fanfare_shown(_tier: int, title: String, text: String, seconds: float) -> void:
	_fanfare_title.text = title
	_fanfare_label.text = text
	_fanfare_label.visible = not text.strip_edges().is_empty()
	_fanfare_remaining = seconds
	_fade_in(_fanfare_panel)


func _build_ui() -> void:
	layer = LAYER

	# ── objective line ───────────────────────────────────────────────────────────────────────────
	_objective_panel = PanelContainer.new()
	_objective_panel.add_theme_stylebox_override(
		"panel", MIRE_THEME.panel_style(MIRE_THEME.SHADE, MIRE_THEME.BORDER)
	)
	_objective_panel.modulate.a = 0.0
	_objective_panel.visible = false
	_objective_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_objective_panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", MIRE_THEME.GRID)
	_objective_panel.add_child(row)

	# A single amber pip rather than an icon: it reads as "this is the live one" at a glance and
	# costs no asset.
	var pip := ColorRect.new()
	pip.color = MIRE_THEME.AMBER
	pip.custom_minimum_size = Vector2(4.0, 0.0)
	row.add_child(pip)

	_objective_label = Label.new()
	_objective_label.add_theme_color_override("font_color", MIRE_THEME.TEXT)
	_objective_label.add_theme_font_size_override(
		"font_size", MIRE_THEME.font_size(MIRE_THEME.CAPTION)
	)
	_objective_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_objective_label.custom_minimum_size.x = OBJECTIVE_WIDTH_PX
	row.add_child(_objective_label)

	_objective_panel.set_anchors_and_offsets_preset(
		Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_KEEP_SIZE
	)
	_objective_panel.offset_left = OBJECTIVE_MARGIN.x
	_objective_panel.offset_right = OBJECTIVE_MARGIN.x + OBJECTIVE_WIDTH_PX + 28.0
	_objective_panel.offset_top = OBJECTIVE_MARGIN.y
	_objective_panel.offset_bottom = OBJECTIVE_MARGIN.y + 48.0

	# ── tip card ─────────────────────────────────────────────────────────────────────────────────
	_tip_panel = PanelContainer.new()
	_tip_panel.add_theme_stylebox_override(
		"panel", MIRE_THEME.panel_style(MIRE_THEME.PANEL, MIRE_THEME.AMBER)
	)
	_tip_panel.modulate.a = 0.0
	_tip_panel.visible = false
	_tip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_tip_panel)

	_tip_label = Label.new()
	_tip_label.add_theme_color_override("font_color", MIRE_THEME.TEXT)
	_tip_label.add_theme_font_size_override("font_size", MIRE_THEME.font_size(MIRE_THEME.BODY))
	_tip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip_label.custom_minimum_size = Vector2(460.0, 0.0)
	_tip_panel.add_child(_tip_label)

	_tip_panel.set_anchors_and_offsets_preset(
		Control.PRESET_CENTER_TOP, Control.PRESET_MODE_KEEP_SIZE
	)
	_tip_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_tip_panel.offset_top = TIP_TOP_OFFSET

	# ── tier fanfare ─────────────────────────────────────────────────────────────────────────────
	_fanfare_panel = PanelContainer.new()
	_fanfare_panel.add_theme_stylebox_override(
		"panel", MIRE_THEME.panel_style(MIRE_THEME.SHADE, MIRE_THEME.AMBER)
	)
	_fanfare_panel.modulate.a = 0.0
	_fanfare_panel.visible = false
	_fanfare_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fanfare_panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	_fanfare_panel.add_child(column)

	_fanfare_title = Label.new()
	_fanfare_title.add_theme_color_override("font_color", MIRE_THEME.AMBER)
	_fanfare_title.add_theme_font_size_override(
		"font_size", MIRE_THEME.font_size(MIRE_THEME.HEADLINE)
	)
	_fanfare_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_fanfare_title)

	_fanfare_label = Label.new()
	_fanfare_label.add_theme_color_override("font_color", MIRE_THEME.MUTED)
	_fanfare_label.add_theme_font_size_override(
		"font_size", MIRE_THEME.font_size(MIRE_THEME.CAPTION)
	)
	_fanfare_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_fanfare_label)

	_fanfare_panel.set_anchors_and_offsets_preset(
		Control.PRESET_CENTER_TOP, Control.PRESET_MODE_KEEP_SIZE
	)
	_fanfare_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_fanfare_panel.offset_top = FANFARE_TOP_OFFSET


## Fades are `modulate:a` only — no layout animation, so a headless check can drive this node and
## read `visible` without waiting on a rendering server. `MIRE_THEME.motion_scale()` is applied so a
## player who asked for reduced camera motion gets an instant cut instead of a slide.
func _fade_in(panel: PanelContainer) -> void:
	if panel == null:
		return
	panel.visible = true
	var tween: Tween = create_tween()
	tween.tween_property(panel, "modulate:a", 1.0, FADE_SEC * MIRE_THEME.motion_scale())


func _fade_out(panel: PanelContainer) -> void:
	if panel == null or not panel.visible:
		return
	var tween: Tween = create_tween()
	tween.tween_property(panel, "modulate:a", 0.0, FADE_SEC * MIRE_THEME.motion_scale())
	tween.tween_callback(func() -> void: panel.visible = false)
