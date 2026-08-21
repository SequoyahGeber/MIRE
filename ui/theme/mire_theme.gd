extends RefCounted

## MireTheme — MENU-1: the one design language every menu screen is built from (docs/MENU.md §3).
## Colour tokens, the type scale, the 8px spacing grid, and a component builder per widget the
## front end uses. This replaces the eight-file copy-paste of `COLOUR_*` constants plus a private
## `_button()`/`_panel_style()`/`_field_style()`/`_focus_style()` quartet that `main_menu.gd`,
## `lobby_menu.gd`, `settings_menu.gd`, `unlock_menu.gd` and the HUDs each grew their own copy of —
## same values, four maintenance sites, and no way to change the language in one place.
##
## USE IT BY PRELOAD, NEVER AS A BARE IDENTIFIER:
##     const MireTheme := preload("res://ui/theme/mire_theme.gd")
## SPECS.md's first standing rule — a bare global identifier is not guaranteed to resolve in a
## `--script` harness, which is how every check in this project runs. `core/dev/dev_launch.gd`'s
## `ProceduralWorldScript` const is the same pattern. Everything here is `static`, so there is
## nothing to instantiate: `MireTheme.button(...)`, `MireTheme.TEXT`, `MireTheme.wire_chain(...)`.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — pure presentation, the table's free last
## row. This file reads two settings (UI scale, reduce motion) and never writes any state at all.
##
## Accessibility contract this file exists to enforce mechanically (docs/MENU.md §9), so no screen
## has to remember it:
##   · every focusable control gets the visible AMBER focus ring (F-209/F-215), including sliders,
##     which need `FocusRingSlider` because Godot 4.7.1's `Slider` has no "focus" stylebox item
##   · nothing is smaller than CAPTION (13px @ 1080p) and everything scales by the UI-scale setting
##   · every interactive control is at least MIN_TOUCH_TARGET tall
##   · `motion_scale()` collapses to 0.0 under the reduce-motion setting, so an animation written as
##     `duration * MireTheme.motion_scale()` becomes an instant cut without a per-caller branch

const FocusRingSlider := preload("res://ui/menu/focus_ring_slider.gd")

# ── Colour tokens (docs/MENU.md §3.1) ─────────────────────────────────────────────────────────────
# The bog-green family is inherited verbatim from the shipped panels so the new front end is
# recognisably the same game; MIRE and MOSS are the two the design was missing.

## Full-screen dim behind any overlay.
const SHADE := Color(0.018, 0.035, 0.028, 0.78)
## Panel and screen backgrounds.
const PANEL := Color(0.055, 0.086, 0.070, 0.97)
## Buttons, inputs, cards — one step lighter than PANEL so a control reads as raised.
const FIELD := Color(0.085, 0.125, 0.102, 0.98)
## Resting borders and separators.
const BORDER := Color(0.345, 0.475, 0.390, 1.0)
## Primary text.
const TEXT := Color(0.91, 0.94, 0.89, 1.0)
## Secondary text, captions, hints.
const MUTED := Color(0.60, 0.69, 0.62, 1.0)
## The ONE highlight colour: focus ring, the single primary CTA per screen, headline numbers.
## Scarcity is the point — if everything is amber, focus is invisible.
const AMBER := Color(0.894, 0.704, 0.286, 1.0)
## Corruption, danger, destructive actions. The Mire's own purple-black.
const MIRE := Color(0.42, 0.26, 0.52, 1.0)
## Success, owned, banked.
const MOSS := Color(0.56, 0.80, 0.60, 1.0)
## Failures in status lines.
const ERROR := Color(0.96, 0.47, 0.39, 1.0)

# ── Type scale (docs/MENU.md §3.2), in px at the 1080p reference ─────────────────────────────────

## The Cycle number on the run summary. Nothing else earns this size.
const DISPLAY: int = 64
## Screen titles.
const HEADLINE: int = 32
## Section heads, card titles, primary buttons.
const TITLE: int = 20
## Default for everything.
const BODY: int = 16
## Hints and metadata. A FLOOR, not a suggestion — the shipped menus' 10px and 11px labels are
## unreadable on a Steam Deck's 7" 1280×800 panel, which is a first-class target (docs/MENU.md §9).
const CAPTION: int = 13

# ── Space and shape (docs/MENU.md §3.3) ──────────────────────────────────────────────────────────

## The 8px grid. Margins and gaps are multiples of this; 4 (GRID / 2) is allowed inside compact rows.
const GRID: int = 8
const RADIUS_FIELD: int = 6
const RADIUS_PANEL: int = 10
## Minimum height of anything clickable, at 100% scale.
const MIN_TOUCH_TARGET: int = 44

# ── Motion (docs/MENU.md §3.4), seconds ──────────────────────────────────────────────────────────

const DURATION_FAST: float = 0.15
const DURATION_SCREEN: float = 0.30
const DURATION_COUNT_UP: float = 1.20

enum Variant {
	## Default: FIELD fill, BORDER edge.
	STANDARD,
	## The one amber call-to-action per screen (PLAY, SET SAIL, ONE MORE RUN).
	PRIMARY,
	## Costs something you cannot get back (ABANDON RUN, QUIT). MIRE-accented.
	DESTRUCTIVE,
}


# ── Settings-derived scale (read-only; SettingsService owns the state) ────────────────────────────


## Multiplies every font size and minimum height. 1.0 until MENU-6 adds the accessibility slider;
## resolved through `get_node_or_null` + `call` rather than a bare `SettingsService` identifier for
## the same harness-safety reason this whole file is preloaded (SPECS.md standing rule 1), and
## tolerant of the service being absent so a `--script` check that boots no autoloads still works.
static func ui_scale() -> float:
	var settings: Node = _settings()
	if settings == null or not settings.has_method("ui_scale"):
		return 1.0
	return clampf(float(settings.call("ui_scale")), 1.0, 1.5)


## 1.0 normally, 0.0 when the player has asked for reduced motion. Write animations as
## `DURATION_FAST * MireTheme.motion_scale()`; a zero-length tween in Godot applies its final value
## immediately, so honouring the setting costs no branch at the call site and cannot be forgotten
## halfway down a screen (docs/MENU.md §3.4 makes this an acceptance criterion on every MENU task).
static func motion_scale() -> float:
	var settings: Node = _settings()
	if settings == null or not settings.has_method("reduce_camera_motion"):
		return 1.0
	return 0.0 if bool(settings.call("reduce_camera_motion")) else 1.0


static func font_size(role: int) -> int:
	return int(round(float(role) * ui_scale()))


static func _settings() -> Node:
	var loop: MainLoop = Engine.get_main_loop()
	if not (loop is SceneTree):
		return null
	var tree: SceneTree = loop
	if tree.root == null:
		return null
	return tree.root.get_node_or_null(^"/root/SettingsService")


# ── Styles ────────────────────────────────────────────────────────────────────────────────────────


## The visible focus ring (F-209): a transparent-fill AMBER outline drawn as the "focus" stylebox
## layer on top of normal/hover/pressed. Every focusable control in the front end gets this one.
static func focus_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	style.draw_center = false
	style.border_color = AMBER
	style.set_border_width_all(2)
	style.set_corner_radius_all(RADIUS_FIELD)
	return style


static func panel_style(fill: Color = PANEL, border: Color = BORDER) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(RADIUS_PANEL)
	style.content_margin_left = float(GRID * 2)
	style.content_margin_right = float(GRID * 2)
	style.content_margin_top = float(GRID * 2)
	style.content_margin_bottom = float(GRID * 2)
	return style


static func field_style(fill: Color = FIELD, border: Color = BORDER) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(RADIUS_FIELD)
	style.content_margin_left = float(GRID + GRID / 2)
	style.content_margin_right = float(GRID + GRID / 2)
	style.content_margin_top = float(GRID)
	style.content_margin_bottom = float(GRID)
	return style


# ── Components ────────────────────────────────────────────────────────────────────────────────────


## The kit's button. `variant` picks the resting/hover accent (Variant above); every variant gets
## the same focus ring and the same minimum height, which is what makes gamepad traversal and
## Deck-sized touch targets uniform without each screen re-deciding.
static func button(text: String, on_pressed: Callable = Callable(), variant: int = Variant.STANDARD) -> Button:
	var control := Button.new()
	control.text = text
	control.focus_mode = Control.FOCUS_ALL
	control.custom_minimum_size = Vector2(0.0, float(MIN_TOUCH_TARGET) * ui_scale())
	control.add_theme_font_size_override("font_size", font_size(TITLE if variant == Variant.PRIMARY else BODY))

	var accent: Color = AMBER
	var resting: Color = BORDER
	var fill: Color = FIELD
	match variant:
		Variant.PRIMARY:
			resting = AMBER
			fill = Color(AMBER.r, AMBER.g, AMBER.b, 0.16).blend(FIELD)
		Variant.DESTRUCTIVE:
			accent = MIRE.lightened(0.25)
			resting = MIRE
			fill = Color(MIRE.r, MIRE.g, MIRE.b, 0.14).blend(FIELD)

	control.add_theme_color_override("font_color", TEXT)
	control.add_theme_color_override("font_hover_color", TEXT)
	control.add_theme_color_override("font_focus_color", TEXT)
	control.add_theme_color_override("font_disabled_color", MUTED)
	control.add_theme_stylebox_override("normal", field_style(fill, resting))
	control.add_theme_stylebox_override("hover", field_style(fill.lightened(0.04), accent))
	control.add_theme_stylebox_override("pressed", field_style(fill.darkened(0.06), accent))
	control.add_theme_stylebox_override("disabled", field_style(fill.darkened(0.10), BORDER.darkened(0.35)))
	control.add_theme_stylebox_override("focus", focus_style())
	if on_pressed.is_valid():
		control.pressed.connect(on_pressed)
	return control


## A borderless text button for footer links (CREDITS). Still focusable, still ringed.
static func link(text: String, on_pressed: Callable = Callable()) -> Button:
	var control := Button.new()
	control.text = text
	control.flat = true
	control.focus_mode = Control.FOCUS_ALL
	control.add_theme_font_size_override("font_size", font_size(CAPTION))
	control.add_theme_color_override("font_color", MUTED)
	control.add_theme_color_override("font_hover_color", AMBER)
	control.add_theme_color_override("font_focus_color", AMBER)
	control.add_theme_stylebox_override("focus", focus_style())
	if on_pressed.is_valid():
		control.pressed.connect(on_pressed)
	return control


static func label(text: String, role: int = BODY, colour: Color = TEXT) -> Label:
	var control := Label.new()
	control.text = text
	control.add_theme_font_size_override("font_size", font_size(role))
	control.add_theme_color_override("font_color", colour)
	return control


## A label that wraps and centres — status lines, hints, flavour copy.
static func paragraph(text: String, role: int = CAPTION, colour: Color = MUTED) -> Label:
	var control: Label = label(text, role, colour)
	control.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	control.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return control


static func panel(fill: Color = PANEL, border: Color = BORDER) -> PanelContainer:
	var control := PanelContainer.new()
	control.add_theme_stylebox_override("panel", panel_style(fill, border))
	return control


## A card is a panel with a tighter inner margin — party rows, unlock entries, the last-expedition
## block. `accent` recolours only the border, which is how "affordable"/"owned"/"ready" read without
## relying on colour alone (each caller also sets a glyph or label — docs/MENU.md §9).
static func card(accent: Color = BORDER) -> PanelContainer:
	var control := PanelContainer.new()
	var style: StyleBoxFlat = panel_style(FIELD, accent)
	style.content_margin_left = float(GRID + GRID / 2)
	style.content_margin_right = float(GRID + GRID / 2)
	style.content_margin_top = float(GRID + GRID / 2)
	style.content_margin_bottom = float(GRID + GRID / 2)
	control.add_theme_stylebox_override("panel", style)
	return control


static func text_field(placeholder: String = "") -> LineEdit:
	var control := LineEdit.new()
	control.placeholder_text = placeholder
	control.focus_mode = Control.FOCUS_ALL
	control.custom_minimum_size = Vector2(0.0, float(MIN_TOUCH_TARGET) * ui_scale())
	control.add_theme_font_size_override("font_size", font_size(BODY))
	control.add_theme_color_override("font_color", TEXT)
	control.add_theme_color_override("font_placeholder_color", MUTED)
	control.add_theme_stylebox_override("normal", field_style())
	control.add_theme_stylebox_override("focus", focus_style())
	return control


## A slider that can actually be seen to have focus — `FocusRingSlider` draws the ring itself
## because `Slider` has no "focus" stylebox item to override (F-215). Always use this, never a bare
## `HSlider`, or the control silently drops out of the gamepad-visible focus chain.
static func slider(minimum: float, maximum: float, step: float = 0.01) -> HSlider:
	var control := FocusRingSlider.new()
	control.min_value = minimum
	control.max_value = maximum
	control.step = step
	control.focus_mode = Control.FOCUS_ALL
	control.custom_minimum_size = Vector2(220.0, float(MIN_TOUCH_TARGET) * ui_scale())
	control.focus_ring_style = focus_style()
	return control


## The kit's on/off switch (F-416). Still a `CheckBox`, so `button_pressed`, `toggled` and every
## existing call site are untouched — but it now DRAWS.
##
## It used to override only the font and the focus ring, which left the `checked`/`unchecked` items
## resolving to Godot's default theme: a dark grey outline. Against `PANEL` that outline is
## invisible, so an OFF toggle rendered as a label with empty space beside it and an ON toggle as a
## smudge. Four shipped settings were affected — VSync, Dynamic resolution, Invert vertical look,
## Reduce motion — and it is why the God mode toggle (F-411) was reported missing when it was in
## fact present, focusable and correctly wired the whole time.
##
## The replacement is a pill switch rather than a tick box, because the state has to be readable
## without a legend: the knob is left and the track is `FIELD` when off, the knob is right and the
## track is `MOSS` when on. `MOSS` and not `AMBER` on purpose — amber is this kit's scarce focus
## colour (§3.1), and a screen of amber switches is a screen with no visible focus ring. Godot swaps
## the icon straight off `button_pressed` with no signal involved, so the drawn state cannot fall out
## of sync with the value the way a text label set from `toggled` would.
static func toggle(text: String = "") -> CheckBox:
	var control := CheckBox.new()
	control.text = text
	control.focus_mode = Control.FOCUS_ALL
	control.custom_minimum_size = Vector2(0.0, float(MIN_TOUCH_TARGET) * ui_scale())
	control.add_theme_font_size_override("font_size", font_size(BODY))
	control.add_theme_color_override("font_color", TEXT)
	control.add_theme_color_override("font_hover_color", TEXT)
	control.add_theme_color_override("font_focus_color", TEXT)
	control.add_theme_stylebox_override("focus", focus_style())
	control.add_theme_icon_override("checked", switch_icon(true))
	control.add_theme_icon_override("unchecked", switch_icon(false))
	control.add_theme_icon_override("checked_disabled", switch_icon(true, true))
	control.add_theme_icon_override("unchecked_disabled", switch_icon(false, true))
	# CheckBox draws `radio_*` for the same two states when it is put in a button group; a screen
	# that groups two toggles must not silently fall back to the invisible defaults again.
	control.add_theme_icon_override("radio_checked", switch_icon(true))
	control.add_theme_icon_override("radio_unchecked", switch_icon(false))
	control.add_theme_icon_override("radio_checked_disabled", switch_icon(true, true))
	control.add_theme_icon_override("radio_unchecked_disabled", switch_icon(false, true))
	return control


# ── The switch icon (F-416) ───────────────────────────────────────────────────────────────────────

## Pill size at the 1080p reference, before UI scale. Wider than it is tall because the travel of
## the knob from one end to the other is what reads as "off" versus "on" at a glance.
const SWITCH_WIDTH: int = 40
const SWITCH_HEIGHT: int = 22

## Supersample factor. The pill and its knob are circles, and a 40x22 icon drawn with hard pixel
## tests has visibly stepped edges next to this kit's anti-aliased text; drawing at 4x and resizing
## down is cheaper than a signed-distance shader for something generated four times per screen.
const SWITCH_SUPERSAMPLE: int = 4

## Generated icons are identical for every toggle on screen, and the UI-scale setting is the only
## thing that changes their size, so four textures serve the entire front end.
static var _switch_cache: Dictionary = {}


## One state of the pill switch, as a texture ready for `add_theme_icon_override()`.
static func switch_icon(on: bool, disabled: bool = false) -> ImageTexture:
	var scale: float = ui_scale()
	var key: String = "%d_%d_%.2f" % [int(on), int(disabled), scale]
	if _switch_cache.has(key):
		return _switch_cache[key] as ImageTexture

	var width: int = maxi(int(round(float(SWITCH_WIDTH) * scale)), SWITCH_WIDTH)
	var height: int = maxi(int(round(float(SWITCH_HEIGHT) * scale)), SWITCH_HEIGHT)
	var big_w: int = width * SWITCH_SUPERSAMPLE
	var big_h: int = height * SWITCH_SUPERSAMPLE

	var track: Color = MOSS if on else FIELD
	var edge: Color = MOSS.lightened(0.25) if on else BORDER
	var knob: Color = PANEL.darkened(0.35) if on else MUTED
	if disabled:
		# Same shape, drained — a disabled control still has to show WHICH state it is stuck in.
		track = track.lerp(PANEL, 0.55)
		edge = edge.lerp(PANEL, 0.55)
		knob = knob.lerp(PANEL, 0.45)

	var image := Image.create(big_w, big_h, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))

	var radius: float = float(big_h) * 0.5
	var border: float = 1.5 * float(SWITCH_SUPERSAMPLE)
	var knob_radius: float = radius - border - 2.0 * float(SWITCH_SUPERSAMPLE)
	var knob_x: float = (float(big_w) - radius) if on else radius
	var knob_centre := Vector2(knob_x, radius)

	for y: int in big_h:
		for x: int in big_w:
			var point := Vector2(float(x) + 0.5, float(y) + 0.5)
			# Distance to the pill: the capsule's spine runs between the two end centres.
			var spine: float = clampf(point.x, radius, float(big_w) - radius)
			var to_track: float = point.distance_to(Vector2(spine, radius))
			if to_track > radius:
				continue
			var colour: Color = edge if to_track > radius - border else track
			if knob_radius > 0.0 and point.distance_to(knob_centre) <= knob_radius:
				colour = knob
			image.set_pixel(x, y, colour)

	image.resize(width, height, Image.INTERPOLATE_BILINEAR)
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	_switch_cache[key] = texture
	return texture


static func dropdown() -> OptionButton:
	var control := OptionButton.new()
	control.focus_mode = Control.FOCUS_ALL
	control.custom_minimum_size = Vector2(0.0, float(MIN_TOUCH_TARGET) * ui_scale())
	control.add_theme_font_size_override("font_size", font_size(BODY))
	control.add_theme_color_override("font_color", TEXT)
	control.add_theme_stylebox_override("normal", field_style())
	control.add_theme_stylebox_override("hover", field_style(FIELD.lightened(0.04), AMBER))
	control.add_theme_stylebox_override("pressed", field_style(FIELD, AMBER))
	control.add_theme_stylebox_override("focus", focus_style())
	return control


static func separator() -> HSeparator:
	var control := HSeparator.new()
	var style := StyleBoxLine.new()
	style.color = BORDER.darkened(0.15)
	style.thickness = 1
	control.add_theme_stylebox_override("separator", style)
	return control


## The `[E]`-style glyph used in prompts and hints. Non-focusable by design: it is a picture of a
## key, never a control you can land on.
static func keycap(text: String) -> PanelContainer:
	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style: StyleBoxFlat = field_style(FIELD.lightened(0.06), MUTED)
	style.content_margin_left = float(GRID / 2)
	style.content_margin_right = float(GRID / 2)
	style.content_margin_top = 2.0
	style.content_margin_bottom = 2.0
	frame.add_theme_stylebox_override("panel", style)
	var text_label: Label = label(text, CAPTION, TEXT)
	text_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	frame.add_child(text_label)
	return frame


## A vertical stack with the grid's standard gap — the spine of nearly every screen.
static func column(separation: int = GRID) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", separation)
	return box


static func row(separation: int = GRID) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", separation)
	return box


# ── Focus wiring ──────────────────────────────────────────────────────────────────────────────────


## Chains `focus_neighbor_top`/`_bottom` down a visible list and wraps the ends, which is what makes
## a D-pad or arrow key walk a screen (F-209). Also sets `focus_next`/`focus_previous` so Tab agrees
## with the arrows instead of following scene-tree order, which is the bug F-209's original fix left
## behind on every panel that mixed rows and columns.
static func wire_chain(controls: Array) -> void:
	var usable: Array[Control] = []
	for entry: Variant in controls:
		if entry is Control and (entry as Control).focus_mode != Control.FOCUS_NONE:
			usable.append(entry)
	var count: int = usable.size()
	if count == 0:
		return
	for i: int in count:
		var current: Control = usable[i]
		var previous: Control = usable[(i - 1 + count) % count]
		var following: Control = usable[(i + 1) % count]
		current.focus_neighbor_top = current.get_path_to(previous)
		current.focus_neighbor_bottom = current.get_path_to(following)
		current.focus_previous = current.get_path_to(previous)
		current.focus_next = current.get_path_to(following)


## Left/right neighbours for a horizontal group (a seed row, a tab bar). Does not wrap: running off
## the end of a row should stop, not teleport across the screen.
static func wire_row(controls: Array) -> void:
	var usable: Array[Control] = []
	for entry: Variant in controls:
		if entry is Control and (entry as Control).focus_mode != Control.FOCUS_NONE:
			usable.append(entry)
	for i: int in usable.size():
		var current: Control = usable[i]
		if i > 0:
			current.focus_neighbor_left = current.get_path_to(usable[i - 1])
		if i < usable.size() - 1:
			current.focus_neighbor_right = current.get_path_to(usable[i + 1])


# ── Motion helpers ────────────────────────────────────────────────────────────────────────────────


## Fades a control in over `duration`, or applies the end state instantly under reduce-motion.
## Returns the tween so a caller can await it; null when motion is off (nothing to await —
## `await` on null would error, so callers check, which the two screens that animate both do).
static func fade_in(control: Control, duration: float = DURATION_FAST) -> Tween:
	var scaled: float = duration * motion_scale()
	if scaled <= 0.0:
		control.modulate.a = 1.0
		return null
	control.modulate.a = 0.0
	var tween: Tween = control.create_tween()
	tween.tween_property(control, ^"modulate:a", 1.0, scaled).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	return tween
