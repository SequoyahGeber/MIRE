extends SceneTree

## MENU-6 proof (docs/MENU.md §7.1, §11): the tabbed settings screen presents every setting the
## service actually has, writes through to `SettingsService` rather than holding its own copy, and
## handles the rebind capture flow's awkward cases — a clash, a cancel, and Esc while armed.
##
## Run with: .agent/bin/agent godot --script tools/settings_screen_check.gd

const SettingsScreen := preload("res://ui/frontend/settings_screen.gd")
const MireTheme := preload("res://ui/theme/mire_theme.gd")
const SETTINGS_SAVE := preload("res://core/save/settings_save.gd")
const FOCUS_RING_SLIDER := preload("res://ui/menu/focus_ring_slider.gd")

## F-386 made this check able to observe persistence, which means it now WRITES — so it points
## `SettingsService` at its own file first, exactly as `tools/settings_check.gd` does, and a run can
## never touch a real player's `user://settings.json`.
const TEST_PATH: String = "user://settings_screen_check.json"

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var stack: Node = root.get_node_or_null(^"/root/MenuStack")
	var settings: Node = root.get_node_or_null(^"/root/SettingsService")
	var god_mode: Node = root.get_node_or_null(^"/root/GodModeService")
	check(stack != null, "MenuStack autoload exists")
	check(settings != null, "SettingsService autoload exists")
	check(god_mode != null, "GodModeService autoload exists")
	if stack == null or settings == null or god_mode == null:
		finish()
		return
	stack.call("pop_all")
	settings.set(&"save_path", TEST_PATH)
	_cleanup()

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
	var playtesting_index: int = SettingsScreen.TABS.find("PLAYTESTING")
	check(playtesting_index >= 0, "the live Settings screen declares a PLAYTESTING tab")
	if playtesting_index >= 0:
		screen.call("show_tab", playtesting_index)
		var god_toggle: CheckBox = screen.find_child("GodModeToggle", true, false) as CheckBox
		check(god_toggle != null, "PLAYTESTING exposes the runtime God Mode toggle")

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

	# ── F-385: every slider says what it is set to ───────────────────────────────────────────────
	print("\n== numeric readouts (F-385) ==")
	screen.call("show_tab", 0)
	await process_frame
	var display_page: Control = (screen.get(&"_pages") as Array)[0] as Control
	var resolution_dropdown: OptionButton = display_page.get(&"_resolution_dropdown") as OptionButton
	check(resolution_dropdown != null, "the live DISPLAY page exposes the resolution control")
	if resolution_dropdown != null:
		settings.call("set_window_mode", 1)
		check(resolution_dropdown.disabled,
			"resolution is disabled in borderless mode, where the monitor's native size wins")
		settings.call("set_window_mode", 2)
		check(resolution_dropdown.disabled,
			"resolution is disabled in fullscreen mode, where the monitor's native size wins")
		settings.call("set_window_mode", 0)
		check(not resolution_dropdown.disabled, "resolution is enabled again in windowed mode")
	for entry: Array in [
		[0, 90.0, "90°", "field of view"],
		[1, 1.25, "125%", "brightness"],
		[2, 0.5, "50%", "master volume"],
		[5, 0.35, "0.35", "mouse sensitivity"],
		[6, 245.0, "245°/s", "gamepad look sensitivity"],
	]:
		var slider: HSlider = _find_slider(screen, int(entry[0]))
		check(slider is FOCUS_RING_SLIDER, "the %s row is a FocusRingSlider" % entry[3])
		if not (slider is FOCUS_RING_SLIDER):
			continue
		var ring: FocusRingSlider = slider
		ring.value = float(entry[1])
		check(ring.readout_text() == String(entry[2]),
			"the %s row reads %s (got: %s)" % [entry[3], entry[2], ring.readout_text()])
		check(ring.readout_min_width() > 0.0,
			"the %s readout has a fixed width, so the row cannot reflow mid-drag" % entry[3])

	# ── F-387: the rows below the fold are reachable ─────────────────────────────────────────────
	print("\n== scrolling and the mouse wheel (F-387) ==")
	var host: Control = screen.get(&"_page_host") as Control
	check(host is VBoxContainer,
		"the page host is a BoxContainer — a bare Control reports no minimum size, so the scroll " +
		"container had nothing taller than itself to scroll and simply clipped the overflow")
	var scroll: ScrollContainer = host.get_parent() as ScrollContainer
	check(scroll != null, "the pages sit inside a ScrollContainer")
	if scroll != null:
		check(scroll.follow_focus, "the viewport follows focus, so a gamepad reaches the rows below")

		# CONTROLS is the tallest tab: a slider, a toggle and twelve rebind rows. The bug was that
		# the host reported NO minimum size at all, so the scroll range was always zero and the
		# overflow was clipped rather than scrolled — which is why this asserts the range against the
		# page's own content height rather than against the window. Whether that content happens to
		# overflow depends on the resolution (this harness runs a 1280-tall window and it does not);
		# whether the ScrollContainer can SEE it does not, and that is the defect.
		screen.call("show_tab", 2)
		await process_frame
		await process_frame
		var pages: Array = screen.get(&"_pages")
		var controls_height: float = (pages[2] as Control).get_combined_minimum_size().y
		check(controls_height > 0.0 and is_equal_approx(host.get_combined_minimum_size().y, controls_height),
			"the scroll host measures the showing tab's real height (%.0f px)" % controls_height)
		var bar: VScrollBar = scroll.get_v_scroll_bar()
		check(bar.max_value >= controls_height,
			"the scroll range covers all of it (%.0f of %.0f)" % [bar.max_value, controls_height])

		# A hidden tab must not inflate the range either, or every tab would scroll as if it were
		# the longest one. `BoxContainer` skips invisible children, which is the other half of why
		# the host is one.
		screen.call("show_tab", 4)
		await process_frame
		await process_frame
		var accessibility_height: float = (pages[4] as Control).get_combined_minimum_size().y
		check(is_equal_approx(host.get_combined_minimum_size().y, accessibility_height),
			"switching to a short tab shrinks the range to that tab (%.0f px)" % accessibility_height)

	var all_sliders: Array[HSlider] = []
	_collect_sliders(screen, all_sliders)
	var wheel_safe: int = 0
	for slider: HSlider in all_sliders:
		if not slider.scrollable and slider.mouse_force_pass_scroll_events:
			wheel_safe += 1
	check(wheel_safe == all_sliders.size() and all_sliders.size() == 7,
		"every slider declines the wheel and lets it climb to the scroll container (%d/%d)"
			% [wheel_safe, all_sliders.size()])

	# ── F-386: preview, save, cancel, restore defaults ───────────────────────────────────────────
	print("\n== preview, save, cancel, restore defaults (F-386) ==")
	check(bool(screen.call("is_previewing")), "showing the screen starts a preview")
	var save_button: Button = screen.get(&"_save_button") as Button
	var restore_button: Button = screen.get(&"_restore_button") as Button
	check(save_button != null and restore_button != null, "the screen has SAVE and RESTORE DEFAULTS")
	check(save_button != null and save_button.focus_mode == Control.FOCUS_ALL
			and restore_button != null and restore_button.focus_mode == Control.FOCUS_ALL,
		"both footer buttons are focusable — a commit step a controller cannot land on is no step")

	screen.call("show_tab", 0)
	await process_frame
	var staged_fov: HSlider = _find_slider(screen, 0)
	if save_button != null and restore_button != null and staged_fov != null:
		staged_fov.value = 80.0
		save_button.pressed.emit()
		check(is_equal_approx(_fov_on_disk(), 80.0), "SAVE writes the staged value to disk")
		check(not bool(screen.call("has_unsaved_changes")), "SAVE clears the unsaved marker")
		check(bool(screen.call("is_previewing")), "SAVE keeps previewing, so the next edit stages")

		staged_fov.value = 100.0
		check(is_equal_approx(float(settings.call("fov_degrees")), 100.0),
			"dragging FOV applies live — the preview is why this is not deferred")
		check(is_equal_approx(_fov_on_disk(), 80.0), "dragging FOV does NOT reach disk")
		check(bool(screen.call("has_unsaved_changes")), "the screen says it has unsaved changes")

		# Popping is the road Esc and the back link both take, so this is the real cancel path.
		stack.call("pop")
		await process_frame
		check(is_equal_approx(float(settings.call("fov_degrees")), 80.0),
			"backing out hands back the FOV the player arrived with — the drag is recoverable")
		check(not bool(settings.call("is_persistence_held")), "backing out releases the preview")
		check(is_equal_approx(_fov_on_disk(), 80.0), "the cancelled drag never touched disk")

		var default_fov: float = float(
			(settings.call("default_state") as Dictionary)[&"fov_degrees"])
		stack.call("push", screen, false)
		await process_frame
		restore_button.pressed.emit()
		check(is_equal_approx(float(settings.call("fov_degrees")), default_fov),
			"RESTORE DEFAULTS loads the default FOV into the live state")
		check(is_equal_approx(staged_fov.value, default_fov), "and the slider follows it")
		check(is_equal_approx(_fov_on_disk(), 80.0), "RESTORE DEFAULTS does not persist on its own")
		stack.call("pop")
		await process_frame
		check(is_equal_approx(float(settings.call("fov_degrees")), 80.0),
			"backing out undoes RESTORE DEFAULTS, same as any other unsaved change")

	check(not bool(settings.call("is_persistence_held")), "no preview is left holding the service")

	settings.call("set_fov_degrees", restore_fov)
	settings.call("set_master_volume", restore_master)
	settings.call("set_invert_y", restore_invert)
	settings.call("set_reduce_camera_motion", restore_reduce)

	stack.call("pop_all")
	screen.free()
	_cleanup()
	print("SETTINGS_SCREEN_CHECK failures=%d" % failures)
	finish()


func _fov_on_disk() -> float:
	return float(SETTINGS_SAVE.load_data(TEST_PATH).get(&"fov_degrees", -1.0))


func _cleanup() -> void:
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(TEST_PATH)


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
