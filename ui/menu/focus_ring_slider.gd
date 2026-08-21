class_name FocusRingSlider
extends HSlider

## F-215: `Slider` (`scene/gui/slider.cpp`, `HSlider`'s base) has no `"focus"` theme stylebox item
## in Godot 4.7.1, so the `add_theme_stylebox_override("focus", ...)` every Button/OptionButton/
## CheckBox/LineEdit in this project gets is silently inert on a slider. Draw the ring ourselves
## instead: the caller sets `focus_ring_style` to the same StyleBoxFlat it already uses for every
## other control in the menu, and this repaints it on top of the engine's own slider drawing
## whenever `has_focus()` is true — the same "no built-in focus stylebox" gap
## `InventoryUI.InventorySlot` solves for `PanelContainer`, just via `_draw()` instead of a stylebox
## swap, because `Slider` has no `"panel"`-equivalent item to swap either.
##
## ## F-385: the numeric readout lives here, not in each screen
##
## Both settings surfaces — `ui/menu/settings_menu.gd` (in-game) and `ui/frontend/settings_screen.gd`
## (title) — shipped six sliders between them with no number anywhere on the row. FOV spans 60-110 in
## steps of 1, so once you moved the handle the value you had before was simply gone. The two screens
## build their rows differently (one stacks label-over-slider in its own palette, the other lays out
## label-left/control-right through `MireTheme`), so the *row* cannot be shared — but the part that
## was actually missing can be, and is: `bind_readout()` below owns the formatting, the fixed width
## and the signal wiring, and each screen only supplies a `Label` it styled itself. One place to fix
## a format, one place that can forget to update on `set_block_signals()` refreshes.
##
## ## F-387: the wheel must scroll the panel, not nudge the setting
##
## `Slider` ships `scrollable = true`, which makes it consume `WHEEL_UP`/`WHEEL_DOWN`, step its own
## value and `accept_event()` — and an accepted event stops climbing, so the `ScrollContainer` above
## never sees it. Six sliders are spread down a settings list far taller than its viewport, so the
## wheel over most of the panel silently changed a setting instead of scrolling, which the player
## reported (2026-08-20) as "the settings menu has no scrolling so some settings are hidden". Both
## halves of that sentence are the same bug.
##
## `scrollable = false` is the fix: the slider stops changing its own value AND stops accepting, so
## the event climbs to the scroll container and the engine's own wheel handling scrolls the panel.
## `mouse_force_pass_scroll_events` is what lets it climb past this control's `MOUSE_FILTER_STOP`;
## it is already Godot's default, but it is set explicitly here for the reason
## `ui/crafting/crafting_ui.gd` states for its own rows under F-380 — a control that silently ate the
## wheel would read as "the menu doesn't scroll", so the property that stops it doing so is worth
## stating rather than inheriting. Nothing else changes: `Slider` still accepts its own left-button
## drag, and `ui_left`/`ui_right` keyboard and gamepad stepping never went through the wheel branch.

## How `bind_readout()` renders a value. One per unit this project actually has a slider for; the
## widest string any of them produces ("720°/s") is what `READOUT_MIN_WIDTH` is sized against.
enum Readout {
	## No readout. The default, so an unbound slider behaves exactly as it did before F-385.
	NONE,
	## Bare whole number.
	INTEGER,
	## Whole degrees — field of view.
	DEGREES,
	## Whole degrees per second — gamepad look sensitivity, which is an angular rate, not a factor.
	DEGREES_PER_SECOND,
	## A 0-1 linear value shown as whole percent — the three volume buses.
	PERCENT,
	## Two decimals — mouse sensitivity, whose useful range (0.01-1.00) has no meaningful integer.
	DECIMAL2,
}

## Default fixed width of a readout label, in pixels at the 11-13px font the settings rows use. The
## point of a fixed width is that the row does not reflow as the number gains or loses a digit while
## you drag — a slider that shoves its own label sideways is worse than no label (F-385).
const READOUT_MIN_WIDTH: float = 72.0

var focus_ring_style: StyleBoxFlat

## How `_readout_label` is formatted. Set through `bind_readout()`, never directly.
var readout_format: int = Readout.NONE
var _readout_label: Label


func _init() -> void:
	# F-387. Set in `_init()` rather than `_ready()` so a caller that reparents or queries the slider
	# before it enters the tree still sees the corrected values, and so every construction site gets
	# the fix without having to remember it.
	scrollable = false
	mouse_force_pass_scroll_events = true


func _ready() -> void:
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	refresh_readout()


func _draw() -> void:
	if has_focus() and focus_ring_style != null:
		focus_ring_style.draw(get_canvas_item(), Rect2(Vector2.ZERO, size))


## Attaches `label` as this slider's numeric readout (F-385). The caller owns the label's font,
## colour and placement — this owns the text, the alignment and the minimum width, because those
## three are what the bug was. Wired to `value_changed`, the same signal the row's setter already
## listens to, so the number and the applied setting can never disagree.
func bind_readout(label: Label, format: int, min_width: float = READOUT_MIN_WIDTH) -> void:
	_readout_label = label
	readout_format = format
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.custom_minimum_size.x = maxf(label.custom_minimum_size.x, min_width)
	if not value_changed.is_connected(_on_value_changed):
		value_changed.connect(_on_value_changed)
	refresh_readout()


## Re-derives the readout from the slider's current value. Public because both screens refresh their
## sliders with `set_block_signals(true)` around the write (so re-showing a panel does not fire every
## setter again) — which also swallows `value_changed`, so without this call the number would keep
## showing whatever the player last dragged it to rather than what the panel just loaded.
func refresh_readout() -> void:
	if _readout_label != null:
		_readout_label.text = format_value(value, readout_format)


## What the bound readout currently reads, or "" if this slider has none. The proxy a check uses for
## "the player can see this number" without having to know how the screen laid the row out.
func readout_text() -> String:
	return _readout_label.text if _readout_label != null else ""


## The fixed width the readout label was pinned to, or 0.0 if unbound. Exposed so a check can prove
## the row cannot reflow as digits come and go — the half of F-385 a screenshot would not show.
func readout_min_width() -> float:
	return _readout_label.custom_minimum_size.x if _readout_label != null else 0.0


## The one formatting table. Static so a check can assert the strings without building a slider.
static func format_value(v: float, format: int) -> String:
	match format:
		Readout.INTEGER:
			return "%d" % int(round(v))
		Readout.DEGREES:
			return "%d°" % int(round(v))
		Readout.DEGREES_PER_SECOND:
			return "%d°/s" % int(round(v))
		Readout.PERCENT:
			return "%d%%" % int(round(v * 100.0))
		Readout.DECIMAL2:
			return "%.2f" % v
	return ""


func _on_value_changed(v: float) -> void:
	if _readout_label != null:
		_readout_label.text = format_value(v, readout_format)
