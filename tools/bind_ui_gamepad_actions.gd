extends SceneTree

## One-shot F-209 fix: Godot 4.7's built-in `ui_up`/`ui_down`/`ui_left`/`ui_right` actions ship with
## a D-pad joypad binding out of the box (confirmed live via InputMap.action_get_events()), but
## `ui_accept`/`ui_cancel` do NOT — only Enter/Space/Kp Enter and Escape. D-131/F-209 both assumed
## otherwise ("Godot's default ui_up/ui_down/ui_accept/ui_cancel actions already carry joypad D-pad/
## A-button bindings out of the box"); that assumption was wrong for exactly these two, which is why
## the rest of F-209's focus_neighbor_*/grab_focus() wiring alone was not enough — you could navigate
## a menu with a bare controller but never activate or back out of anything. This is a one-shot
## project.godot write, not a recurring check (setup_project.gd's own doc comment explains why a
## script rather than a hand-edit: "hand-authored ... input-event literals are easy to get subtly
## wrong" — same reasoning applies to amending an existing built-in action's event list, which is not
## a trivial append). Idempotent: re-running detects an existing joypad binding and no-ops.
##
## Run with: .agent/bin/agent godot --script tools/bind_ui_gamepad_actions.gd

const BINDINGS: Dictionary = {
	&"ui_accept": JOY_BUTTON_A,
	&"ui_cancel": JOY_BUTTON_B,
}


func _initialize() -> void:
	var changed: bool = false
	for action: StringName in BINDINGS:
		if _add_joypad_binding(action, BINDINGS[action]):
			changed = true

	if not changed:
		print("✓ ui_accept/ui_cancel already carry their joypad bindings — nothing to do")
		quit(0)
		return

	var err: int = ProjectSettings.save()
	if err != OK:
		push_error("Failed to save project.godot: %d" % err)
		quit(1)
		return
	print("✓ project.godot written — ui_accept now carries JOY_BUTTON_A, ui_cancel JOY_BUTTON_B")
	quit(0)


## Returns whether it actually added an event (false if `action` already had a JoypadButton bound).
func _add_joypad_binding(action: StringName, button_index: int) -> bool:
	var events: Array = InputMap.action_get_events(action)
	for event: InputEvent in events:
		if event is InputEventJoypadButton:
			return false

	var pad_event := InputEventJoypadButton.new()
	pad_event.button_index = button_index
	var new_events: Array = events.duplicate()
	new_events.append(pad_event)

	ProjectSettings.set_setting("input/" + String(action), {
		"deadzone": InputMap.action_get_deadzone(action),
		"events": new_events,
	})
	return true
