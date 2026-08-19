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

var focus_ring_style: StyleBoxFlat


func _ready() -> void:
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)


func _draw() -> void:
	if has_focus() and focus_ring_style != null:
		focus_ring_style.draw(get_canvas_item(), Rect2(Vector2.ZERO, size))
