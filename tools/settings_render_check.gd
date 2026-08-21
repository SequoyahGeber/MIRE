extends SceneTree

## F-416's guard: every settings control has to DRAW, not merely exist.
##
## The God mode toggle (F-411) was reported missing from the Settings screen when it was in fact
## present, focusable, correctly wired and successfully driven by `tools/god_mode_check.gd`. What no
## check asserted was that it put any pixels on screen — `MireTheme.toggle()` overrode only the font
## and the focus ring, so the `checked`/`unchecked` items fell back to Godot's default dark grey
## outline, which against `MireTheme.PANEL` is invisible. Four shipped toggles were affected.
##
## Existence assertions cannot catch that class of defect, so this check renders each tab and reads
## the framebuffer back: for every toggle it measures the pixels inside the control's own rect and
## demands real contrast against the page background, in BOTH states. A toggle that renders as
## nothing fails here no matter how correct its wiring is.
##
## Needs a real framebuffer (F-077 parks the window offscreen):
##   .agent/bin/agent godot --windowed --script tools/settings_render_check.gd

const SettingsScreen := preload("res://ui/frontend/settings_screen.gd")
const MireTheme := preload("res://ui/theme/mire_theme.gd")
const Frontend := preload("res://ui/frontend/frontend.gd")

const SETTLE_FRAMES: int = 12

## Minimum perceived-luminance gap between a control's brightest pixel and the page background it
## sits on. 0.06 is well under what the drawn switch achieves and well over the ~0.005 the old
## default-theme outline managed, so it separates "faint" from "invisible" without being a
## pixel-exact golden-image test that any restyle would break.
const MIN_CONTRAST: float = 0.06

## Minimum share of the control's rect that must differ from the page at all — a single stray bright
## pixel is not a visible control. Deliberately low: `_row()` expands a toggle to the full value
## column, so the drawn switch is only a few percent of the rect it is measured in. The state this
## rejects is zero, which is what the unstyled default reported.
const MIN_COVERAGE: float = 0.01

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		_failures += 1
		print("FAIL: %s" % message)


func _run() -> void:
	Frontend.suspend_gameplay_overlays()
	var stack: Node = root.get_node_or_null(^"MenuStack")
	if stack != null:
		stack.call("pop_all")

	var size := Vector2i(1920, 1080)
	DisplayServer.window_set_size(size)
	root.content_scale_size = size
	await process_frame

	var screen: Control = SettingsScreen.new()
	if stack != null:
		stack.call("push", screen, false)
	else:
		root.add_child(screen)
	for _i: int in SETTLE_FRAMES:
		await process_frame

	if root.get_texture() == null:
		print("SETTINGS_RENDER_CHECK skipped — no framebuffer; run through `agent godot --windowed`")
		quit()
		return

	var total: int = 0
	for index: int in SettingsScreen.TABS.size():
		screen.call(&"show_tab", index)
		for _i: int in SETTLE_FRAMES:
			await process_frame

		var toggles: Array[CheckBox] = []
		_collect_toggles(screen, toggles)
		if toggles.is_empty():
			continue

		print("\n== %s ==" % SettingsScreen.TABS[index])
		for toggle: CheckBox in toggles:
			total += 1
			var label: String = "%s / %s" % [SettingsScreen.TABS[index], _describe(toggle)]
			var was: bool = toggle.button_pressed
			for state: bool in [false, true]:
				toggle.set_block_signals(true)
				toggle.button_pressed = state
				toggle.set_block_signals(false)
				for _i: int in SETTLE_FRAMES:
					await process_frame
				var image: Image = root.get_texture().get_image()
				var measured: Dictionary = _measure(image, toggle.get_global_rect())
				var state_name: String = "ON" if state else "OFF"
				check(float(measured["contrast"]) >= MIN_CONTRAST,
					"%s draws when %s — contrast %.3f vs the page (floor %.2f)" % [
						label, state_name, float(measured["contrast"]), MIN_CONTRAST])
				check(float(measured["coverage"]) >= MIN_COVERAGE,
					"%s covers real area when %s — %.1f%% of its rect (floor %.1f%%)" % [
						label, state_name, float(measured["coverage"]) * 100.0, MIN_COVERAGE * 100.0])
			toggle.set_block_signals(true)
			toggle.button_pressed = was
			toggle.set_block_signals(false)

		# ON and OFF must not merely both draw — they must be TELLABLE APART. A switch whose two
		# states look the same is a control the player cannot read the value of.
		for toggle: CheckBox in toggles:
			var on_icon: Texture2D = toggle.get_theme_icon(&"checked")
			var off_icon: Texture2D = toggle.get_theme_icon(&"unchecked")
			check(on_icon != null and off_icon != null and on_icon != off_icon,
				"%s / %s has distinct ON and OFF art" % [SettingsScreen.TABS[index], _describe(toggle)])

	check(total >= 4, "the screen still has every toggle this guard was written for (found %d)" % total)

	print("\nSETTINGS_RENDER_CHECK failures=%d" % _failures)
	quit(1 if _failures > 0 else 0)


## Contrast is measured INSIDE the control's own rect: brightest pixel minus darkest. The dark end
## is the page showing through the control's empty space and the bright end is whatever the control
## actually painted, so a control that paints nothing reports a uniform rect and a contrast of ~0.
## Sampling a neighbouring strip instead would read the tab bar on a tab's first row.
## `rect` arrives in the viewport's CONTENT coordinate space (1920x1080 here). The framebuffer read
## back is in physical pixels, which on a HiDPI display is a larger image entirely — measuring the
## content rect against it samples a different control, and the first version of this check silently
## passed an invisible toggle because of it. Scale before sampling.
func _measure(image: Image, rect: Rect2) -> Dictionary:
	var content: Vector2 = root.get_visible_rect().size
	var ratio := Vector2(
		float(image.get_width()) / maxf(content.x, 1.0),
		float(image.get_height()) / maxf(content.y, 1.0)
	)
	var scaled := Rect2(rect.position * ratio, rect.size * ratio)
	var bounds := Rect2i(
		Vector2i(maxi(int(scaled.position.x), 0), maxi(int(scaled.position.y), 0)),
		Vector2i(int(scaled.size.x), int(scaled.size.y))
	)
	bounds = bounds.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return {"contrast": 0.0, "coverage": 0.0}

	var brightest: float = -1.0
	var darkest: float = 2.0
	var lumas: PackedFloat32Array = PackedFloat32Array()
	for y: int in range(bounds.position.y, mini(bounds.end.y, image.get_height())):
		for x: int in range(bounds.position.x, mini(bounds.end.x, image.get_width())):
			var luma: float = _luma(image.get_pixel(x, y))
			brightest = maxf(brightest, luma)
			darkest = minf(darkest, luma)
			lumas.append(luma)
	if lumas.is_empty():
		return {"contrast": 0.0, "coverage": 0.0}

	var differing: int = 0
	for luma: float in lumas:
		if absf(luma - darkest) >= MIN_CONTRAST * 0.5:
			differing += 1
	return {
		"contrast": brightest - darkest,
		"coverage": float(differing) / float(lumas.size()),
	}


func _luma(colour: Color) -> float:
	return 0.2126 * colour.r + 0.7152 * colour.g + 0.0722 * colour.b


## The row label a toggle belongs to, so a failure names the setting rather than a node path.
func _describe(toggle: CheckBox) -> String:
	if not toggle.text.is_empty():
		return toggle.text
	var row: Node = toggle.get_parent()
	while row != null:
		for sibling: Node in row.get_children():
			if sibling is Label and not (sibling as Label).text.is_empty():
				return (sibling as Label).text
		row = row.get_parent()
	return toggle.name


func _collect_toggles(node: Node, out: Array[CheckBox]) -> void:
	if node == null:
		return
	if node is CheckBox and (node as CheckBox).is_visible_in_tree():
		out.append(node as CheckBox)
	for child: Node in node.get_children():
		_collect_toggles(child, out)
