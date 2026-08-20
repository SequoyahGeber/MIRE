extends SceneTree

## MENU-1 proof (docs/MENU.md §3, §11): the shared design language builds, and the accessibility
## contract it exists to enforce mechanically actually holds for every component — focus ring
## present on everything focusable (including sliders, which need F-215's custom draw), nothing
## below the CAPTION type floor, every interactive control at least MIN_TOUCH_TARGET tall, focus
## chains that wrap, and reduce-motion collapsing animation to an instant cut.
##
## Also asserts the contrast of the token pairs the screens actually use, because "readable on a
## dark panel" is the one property a colour token can silently lose in a later tweak and nobody
## notices until a player on a bright screen says the caption is invisible.
##
## Run with: .agent/bin/agent godot --script tools/menu_kit_check.gd

const MireTheme := preload("res://ui/theme/mire_theme.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	# ── every component builds, and is what it claims to be ─────────────────────────────────────
	var button: Button = MireTheme.button("PLAY")
	var primary: Button = MireTheme.button("SET SAIL", Callable(), MireTheme.Variant.PRIMARY)
	var destructive: Button = MireTheme.button("ABANDON RUN", Callable(), MireTheme.Variant.DESTRUCTIVE)
	var link: Button = MireTheme.link("credits")
	var field: LineEdit = MireTheme.text_field("a number or a word…")
	var slider: HSlider = MireTheme.slider(0.0, 1.0)
	var toggle: CheckBox = MireTheme.toggle("Reduce motion")
	var dropdown: OptionButton = MireTheme.dropdown()
	var card: PanelContainer = MireTheme.card()
	var keycap: PanelContainer = MireTheme.keycap("E")
	var text: Label = MireTheme.label("Cycle 9", MireTheme.DISPLAY)

	check(button != null and primary != null and destructive != null, "all three button variants build")
	check(link != null and field != null and toggle != null and dropdown != null, "link/field/toggle/dropdown build")
	check(slider != null and card != null and keycap != null and text != null, "slider/card/keycap/label build")

	# ── the focus ring is on everything that can hold focus (F-209) ──────────────────────────────
	for entry: Array in [
		[button, "standard button"], [primary, "primary button"], [destructive, "destructive button"],
		[link, "link"], [field, "text field"], [toggle, "toggle"], [dropdown, "dropdown"],
	]:
		var control: Control = entry[0]
		check(control.has_theme_stylebox_override("focus"), "%s draws a focus ring" % entry[1])
		check(control.focus_mode == Control.FOCUS_ALL, "%s is focusable" % entry[1])

	# F-215: Slider has no "focus" stylebox item at all, so the ring is drawn by the subclass. The
	# override would be silently inert — assert the real mechanism instead of the absent one.
	check(slider.get("focus_ring_style") != null, "slider carries a focus ring style it draws itself (F-215)")
	check(slider.has_method("_draw"), "slider draws its own ring rather than relying on a stylebox")

	# A keycap is a picture of a key, not a control — landing on it with a D-pad would be a dead end.
	check(keycap.mouse_filter == Control.MOUSE_FILTER_IGNORE, "keycap is non-interactive")

	# ── the type floor and the touch-target floor (docs/MENU.md §9) ──────────────────────────────
	check(MireTheme.CAPTION >= 13, "CAPTION is at least 13px — the Steam Deck floor")
	for role: int in [MireTheme.DISPLAY, MireTheme.HEADLINE, MireTheme.TITLE, MireTheme.BODY, MireTheme.CAPTION]:
		check(MireTheme.font_size(role) >= MireTheme.CAPTION, "type role %d never resolves below the floor" % role)

	for entry: Array in [
		[button, "button"], [field, "text field"], [slider, "slider"],
		[toggle, "toggle"], [dropdown, "dropdown"],
	]:
		var control: Control = entry[0]
		check(control.custom_minimum_size.y >= float(MireTheme.MIN_TOUCH_TARGET),
			"%s is at least %dpx tall" % [entry[1], MireTheme.MIN_TOUCH_TARGET])

	# ── contrast: every text token against every surface it is ever drawn on ─────────────────────
	# WCAG AA for body text is 4.5:1. MUTED on FIELD is the tightest pair in the system and the one
	# a future palette tweak is most likely to break.
	for pair: Array in [
		[MireTheme.TEXT, MireTheme.PANEL, "TEXT on PANEL"],
		[MireTheme.TEXT, MireTheme.FIELD, "TEXT on FIELD"],
		[MireTheme.MUTED, MireTheme.PANEL, "MUTED on PANEL"],
		[MireTheme.MUTED, MireTheme.FIELD, "MUTED on FIELD"],
		[MireTheme.AMBER, MireTheme.PANEL, "AMBER on PANEL"],
		[MireTheme.MOSS, MireTheme.FIELD, "MOSS on FIELD"],
		[MireTheme.ERROR, MireTheme.PANEL, "ERROR on PANEL"],
	]:
		var ratio: float = _contrast_ratio(pair[0], pair[1])
		check(ratio >= 4.5, "%s holds 4.5:1 contrast (got %.2f:1)" % [pair[2], ratio])

	# The focus ring must be visible against the surfaces it outlines. 3:1 is the WCAG bar for a
	# non-text indicator.
	for pair: Array in [
		[MireTheme.AMBER, MireTheme.FIELD, "focus ring on FIELD"],
		[MireTheme.AMBER, MireTheme.PANEL, "focus ring on PANEL"],
	]:
		var ratio: float = _contrast_ratio(pair[0], pair[1])
		check(ratio >= 3.0, "%s holds 3:1 contrast (got %.2f:1)" % [pair[2], ratio])

	# ── focus chains wrap, and Tab agrees with the arrows ───────────────────────────────────────
	var host := Control.new()
	root.add_child(host)
	var a: Button = MireTheme.button("A")
	var b: Button = MireTheme.button("B")
	var c: Button = MireTheme.button("C")
	for control: Button in [a, b, c]:
		host.add_child(control)
	MireTheme.wire_chain([a, b, c])
	check(a.focus_neighbor_top == a.get_path_to(c), "chain wraps from the top back to the bottom")
	check(c.focus_neighbor_bottom == c.get_path_to(a), "chain wraps from the bottom back to the top")
	check(a.focus_next == a.get_path_to(b), "Tab order follows the chain, not scene-tree order")
	check(b.focus_previous == b.get_path_to(a), "Shift-Tab order follows the chain")

	# A non-focusable control in the list must be skipped, not chained into a dead end — screens
	# pass mixed arrays (labels between buttons) and must not have to filter first.
	var mixed_label: Label = MireTheme.label("not focusable")
	host.add_child(mixed_label)
	var d: Button = MireTheme.button("D")
	host.add_child(d)
	MireTheme.wire_chain([a, mixed_label, d])
	check(a.focus_neighbor_bottom == a.get_path_to(d), "wire_chain skips non-focusable entries")

	# A row does NOT wrap: running off the end should stop, not teleport across the screen.
	MireTheme.wire_row([a, b, c])
	check(a.focus_neighbor_left.is_empty(), "row does not wrap at the left edge")
	check(c.focus_neighbor_right.is_empty(), "row does not wrap at the right edge")
	check(b.focus_neighbor_left == b.get_path_to(a), "row chains left")
	check(b.focus_neighbor_right == b.get_path_to(c), "row chains right")

	# ── reduce motion collapses animation to an instant cut ──────────────────────────────────────
	var settings: Node = root.get_node_or_null(^"/root/SettingsService")
	if settings == null:
		check(is_equal_approx(MireTheme.motion_scale(), 1.0), "motion_scale defaults to 1.0 with no settings service")
	else:
		var restore: bool = bool(settings.call("reduce_camera_motion"))
		settings.call("set_reduce_camera_motion", false)
		check(is_equal_approx(MireTheme.motion_scale(), 1.0), "motion_scale is 1.0 with reduce-motion off")
		settings.call("set_reduce_camera_motion", true)
		check(is_equal_approx(MireTheme.motion_scale(), 0.0), "motion_scale is 0.0 with reduce-motion on")

		var faded := Control.new()
		host.add_child(faded)
		var tween: Tween = MireTheme.fade_in(faded)
		check(tween == null, "fade_in returns no tween under reduce-motion")
		check(is_equal_approx(faded.modulate.a, 1.0), "fade_in applies the end state instantly under reduce-motion")

		settings.call("set_reduce_camera_motion", false)
		var live_tween: Tween = MireTheme.fade_in(faded)
		check(live_tween != null, "fade_in animates when motion is allowed")
		check(is_equal_approx(faded.modulate.a, 0.0), "fade_in starts transparent when motion is allowed")
		settings.call("set_reduce_camera_motion", restore)

	# ── UI scale multiplies type and targets together ────────────────────────────────────────────
	check(MireTheme.ui_scale() >= 1.0, "ui_scale never shrinks the interface below 100%")
	check(MireTheme.font_size(MireTheme.BODY) >= MireTheme.BODY, "BODY never resolves smaller than its base size")

	# The components built above were never parented — free them explicitly rather than leaving the
	# engine to report them as leaked ObjectDB instances at exit, which is noise a future reader of
	# this check's output would have to learn to ignore.
	for orphan: Control in [button, primary, destructive, link, field, slider, toggle, dropdown, card, keycap, text]:
		orphan.free()
	host.free()
	print("MENU_KIT_CHECK failures=%d" % failures)
	finish()


## WCAG 2.1 relative-luminance contrast ratio. Tokens carry alpha, and a translucent PANEL over a
## dark 3D backdrop is lighter than its raw value suggests — so blend each colour onto black first,
## which is the worst case for these dark surfaces and therefore the honest one to assert.
func _contrast_ratio(foreground: Color, background: Color) -> float:
	var back: Color = Color.BLACK.blend(background)
	var front: Color = back.blend(foreground)
	var l1: float = _relative_luminance(front)
	var l2: float = _relative_luminance(back)
	var lighter: float = maxf(l1, l2)
	var darker: float = minf(l1, l2)
	return (lighter + 0.05) / (darker + 0.05)


func _relative_luminance(colour: Color) -> float:
	return 0.2126 * _linearise(colour.r) + 0.7152 * _linearise(colour.g) + 0.0722 * _linearise(colour.b)


func _linearise(channel: float) -> float:
	if channel <= 0.03928:
		return channel / 12.92
	return pow((channel + 0.055) / 1.055, 2.4)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
