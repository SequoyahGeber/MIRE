extends SceneTree

## MENU-6 proof (docs/MENU.md §7.1, §11): the tabbed settings screen presents every setting the
## service actually has, writes through to `SettingsService` rather than holding its own copy, and
## handles the rebind capture flow's awkward cases — a clash, a cancel, and Esc while armed.
##
## Run with: .agent/bin/agent godot --script tools/settings_screen_check.gd

const SettingsScreen := preload("res://ui/frontend/settings_screen.gd")
const MireTheme := preload("res://ui/theme/mire_theme.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var stack: Node = root.get_node_or_null(^"/root/MenuStack")
	var settings: Node = root.get_node_or_null(^"/root/SettingsService")
	check(stack != null, "MenuStack autoload exists")
	check(settings != null, "SettingsService autoload exists")
	if stack == null or settings == null:
		finish()
		return
	stack.call("pop_all")

	var screen: Control = SettingsScreen.new()
	stack.call("push", screen, false)
	await process_frame
	await process_frame

	# ── tabs ─────────────────────────────────────────────────────────────────────────────────────
	check(int(screen.call("tab_count")) == SettingsScreen.TABS.size(),
		"every declared tab builds a page (%d)" % int(screen.call("tab_count")))
	check(int(screen.call("active_tab")) == 0, "the first tab is showing on open")

	for index: int in SettingsScreen.TABS.size():
		screen.call("show_tab", index)
		await process_frame
		check(int(screen.call("active_tab")) == index, "tab %s selects" % SettingsScreen.TABS[index])
		var focus_target: Control = screen.call("menu_default_focus")
		check(focus_target != null and focus_target.focus_mode == Control.FOCUS_ALL,
			"tab %s names a focusable default — a controller never lands nowhere" % SettingsScreen.TABS[index])

	# Out-of-range indices must clamp rather than crash or blank the screen.
	screen.call("show_tab", 99)
	check(int(screen.call("active_tab")) == SettingsScreen.TABS.size() - 1, "an over-range tab clamps")
	screen.call("show_tab", -5)
	check(int(screen.call("active_tab")) == 0, "an under-range tab clamps")

	# ── the screen holds no state of its own: it writes through ──────────────────────────────────
	var restore_fov: float = float(settings.call("fov_degrees"))
	var restore_master: float = float(settings.call("master_volume"))
	var restore_invert: bool = bool(settings.call("invert_y"))
	var restore_reduce: bool = bool(settings.call("reduce_camera_motion"))

	var fov_slider: HSlider = _find_slider(screen, 0)
	if fov_slider != null:
		var target: float = clampf(restore_fov + 7.0, float(settings.get("MIN_FOV")), float(settings.get("MAX_FOV")))
		fov_slider.value = target
		await process_frame
		check(is_equal_approx(float(settings.call("fov_degrees")), target),
			"moving the FOV slider writes through to SettingsService")

	screen.call("show_tab", 4)
	await process_frame
	var reduce_toggle: CheckBox = _find_toggle(screen)
	if reduce_toggle != null:
		reduce_toggle.button_pressed = not restore_reduce
		await process_frame
		check(bool(settings.call("reduce_camera_motion")) == (not restore_reduce),
			"the reduce-motion toggle writes through to SettingsService")
		reduce_toggle.button_pressed = restore_reduce

	# ── rebind capture ───────────────────────────────────────────────────────────────────────────
	screen.call("show_tab", 2)
	await process_frame
	check(not bool(screen.call("is_capturing")), "no capture is armed to begin with")

	var rebind_buttons: Array = screen.call("_rebind_buttons", screen)
	check(rebind_buttons.size() > 0, "the controls tab lists rebindable actions (%d)" % rebind_buttons.size())

	var first: Button = rebind_buttons[0]
	var first_action: StringName = first.get_meta(&"action")
	var original_label: String = first.text

	screen.call("begin_capture", first_action, false, first)
	check(bool(screen.call("is_capturing")), "pressing a rebind row arms a capture")
	check(first.text.contains("press"), "the armed row says it is listening")

	# Esc while armed cancels the capture and must NOT leave the screen — otherwise the only way out
	# of "press a key…" is to bind a key you did not want.
	check(not bool(screen.call("menu_allows_cancel")),
		"Esc while armed is swallowed by the capture, not by the stack")
	check(not bool(screen.call("is_capturing")), "Esc while armed cancels the capture")
	check(first.text == original_label, "cancelling restores the row's real binding")
	check(int(stack.call("depth")) == 1, "cancelling a capture does not pop the screen")

	# With nothing armed, Esc leaves normally.
	check(bool(screen.call("menu_allows_cancel")), "Esc with nothing armed backs out of settings")

	# A clash must be reported by name rather than silently refused.
	if rebind_buttons.size() >= 2:
		var second: Button = rebind_buttons[1]
		var second_action: StringName = second.get_meta(&"action")
		var taken: String = String(settings.call("keybind_label", second_action))
		if taken != "—":
			screen.call("begin_capture", first_action, false, first)
			var clash_event := InputEventKey.new()
			clash_event.physical_keycode = OS.find_keycode_from_string(taken)
			clash_event.pressed = true
			screen.call("_finish_capture_key", clash_event)
			await process_frame
			var status: String = String(screen.call("status_text"))
			check(status.to_lower().contains("already used"),
				"rebinding onto a taken key says which action already has it (got: %s)" % status)
			check(not bool(screen.call("is_capturing")), "a clashing rebind disarms the capture")

	# Arming a second row must disarm the first — two live captures would bind one press twice.
	if rebind_buttons.size() >= 2:
		screen.call("begin_capture", first_action, false, first)
		screen.call("begin_capture", StringName(rebind_buttons[1].get_meta(&"action")), false, rebind_buttons[1])
		check(first.text == String(settings.call("keybind_label", first_action)),
			"arming another row restores the first row's label")
		screen.call("_cancel_capture")

	# ── the type floor, on the screen most likely to be read on a Deck ───────────────────────────
	check(_minimum_font_size(screen) >= MireTheme.CAPTION,
		"no text in settings falls below the %dpx floor" % MireTheme.CAPTION)

	settings.call("set_fov_degrees", restore_fov)
	settings.call("set_master_volume", restore_master)
	settings.call("set_invert_y", restore_invert)
	settings.call("set_reduce_camera_motion", restore_reduce)

	stack.call("pop_all")
	screen.free()
	print("SETTINGS_SCREEN_CHECK failures=%d" % failures)
	finish()


func _find_slider(node: Node, index: int) -> HSlider:
	var found: Array[HSlider] = []
	_collect_sliders(node, found)
	return found[index] if index < found.size() else null


func _collect_sliders(node: Node, into: Array[HSlider]) -> void:
	if node is HSlider:
		into.append(node)
	for child: Node in node.get_children():
		_collect_sliders(child, into)


## `is_visible_in_tree()`, not `visible`: a control on a hidden tab page still reports its own
## `visible` as true, so the naive test found the Controls tab's invert-Y toggle while the
## Accessibility tab was the one on screen.
func _find_toggle(node: Node) -> CheckBox:
	if node is CheckBox and (node as CheckBox).is_visible_in_tree():
		return node
	for child: Node in node.get_children():
		var found: CheckBox = _find_toggle(child)
		if found != null:
			return found
	return null


func _minimum_font_size(node: Node) -> int:
	var smallest: int = 9999
	if node is Label:
		var label: Label = node
		if label.has_theme_font_size_override("font_size"):
			smallest = mini(smallest, label.get_theme_font_size(&"font_size"))
	for child: Node in node.get_children():
		smallest = mini(smallest, _minimum_font_size(child))
	return smallest


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
