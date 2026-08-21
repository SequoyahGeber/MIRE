extends SceneTree

## MENU-3 proof (docs/MENU.md §4, §11): the front end builds, routes, and — the acceptance gate —
## gets out of the way of every other way this project is launched.
##
## Replaces `tools/main_menu_check.gd`'s job for the new front end. That check still runs against
## the shipped F1 panel until `main_menu.gd` is retired; this one covers what replaces it.
##
## Covers: the launch bypass (a `--script` or `-- host` boot must never see a menu); the title
## screen's layout, focus target and Esc-refusal; the routing signals; the quit confirmation; the
## credits screen; the late-bound screen paths that light up as later tasks land; and the backdrop's
## island, camera drift and Mire creep.
##
## Run with: .agent/bin/agent godot --script tools/title_check.gd

const Frontend := preload("res://ui/frontend/frontend.gd")
const TitleScreen := preload("res://ui/frontend/title_screen.gd")
const TitleBackdrop := preload("res://ui/frontend/backdrop.gd")
const MireTheme := preload("res://ui/theme/mire_theme.gd")
## The persistence boundary the SHIPPED title actually reads (MENU-7). This check used to read
## `salvage_save.gd` and a `last_run` key, which is where the card lived before MENU-7 moved it —
## so it failed against correct product code and proved nothing about the screen (F-335).
const RunRecordSave := preload("res://core/save/run_record_save.gd")

## A path no real player save can collide with. `RunRecord.save_path` is a `var` precisely so a check
## can point the service somewhere disposable; the title reads through the service, so redirecting it
## redirects the screen too.
const TEST_RECORD_PATH: String = "user://title_check_last_run.json"

## The 1080p reference the type scale and every offset in the front end are authored against
## (docs/MENU.md §3.2). MENU-10 re-runs the same layout assertions at the Deck's 1280×800.
const REFERENCE_SIZE := Vector2i(1920, 1080)

var failures: int = 0
var _routed: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var stack: Node = root.get_node_or_null(^"/root/MenuStack")
	check(stack != null, "MenuStack autoload exists")
	if stack == null:
		finish()
		return
	stack.call("pop_all")

	# A headless root viewport is 64×64. Every layout assertion below is about where controls land
	# inside a real frame, so give it one — otherwise "the menu is on screen" is measured against a
	# 64px screen and passes or fails for reasons that have nothing to do with the layout.
	DisplayServer.window_set_size(REFERENCE_SIZE)
	root.size = REFERENCE_SIZE
	await process_frame

	# ── the acceptance gate: this check is itself a --script launch, so the bypass must be on ────
	check(Frontend._launch_bypasses_frontend(),
		"a --script launch bypasses the front end — every existing check keeps working")

	# ── the title screen ─────────────────────────────────────────────────────────────────────────
	var title: Control = TitleScreen.new()
	stack.call("push", title, false)
	await process_frame
	await process_frame

	# Layout, asserted rather than assumed. A screen whose rect collapses to zero height still
	# builds every control and passes every behavioural test above while drawing NOTHING that is
	# anchored to its bottom edge — which is exactly what the first renders of this screen showed:
	# the wordmark (top-anchored) visible, the entire menu, footer and scrim silently absent.
	# Measured against the stack's own screen host rather than the window: the window size a headless
	# run reports and the size the viewport actually lays out at are not the same number, and the
	# property that matters is "the screen fills the frame it was given".
	var viewport_size: Vector2 = (title.get_parent() as Control).size
	check(viewport_size.x > 64.0 and viewport_size.y > 64.0,
		"the check is running against a real frame, not a 64px headless stub (%s)" % viewport_size)
	check(title.size.is_equal_approx(viewport_size),
		"a pushed screen fills its frame (screen %s, frame %s)" % [title.size, viewport_size])

	var choices: Control = title.get_node_or_null(^"MainChoices")
	check(choices != null, "the choice column exists")
	check(choices.size.x > 0.0 and choices.size.y > 0.0,
		"the choice column has a real rect (%s) — a negative or zero width draws nothing" % choices.size)
	check(choices.global_position.y > 0.0 and choices.global_position.y < viewport_size.y,
		"the choice column sits on screen (y=%.0f of %.0f)" % [choices.global_position.y, viewport_size.y])

	var footer: Control = title.get_node_or_null(^"Footer")
	check(footer != null and footer.global_position.y < viewport_size.y,
		"the footer sits on screen")

	check(title.get("_play_button") != null, "the title builds its menu")
	check(title.call("menu_default_focus") == title.get("_play_button"),
		"a controller lands on PLAY when the title is shown")
	check(not bool(title.call("menu_allows_cancel")),
		"Esc does not pop the title — it is the floor of the stack, and QUIT is the way out")

	# Every choice routes by signal; the screen itself decides nothing.
	_routed.clear()
	title.play_requested.connect(func() -> void: _routed.append("play"))
	title.unlocks_requested.connect(func() -> void: _routed.append("unlocks"))
	title.settings_requested.connect(func() -> void: _routed.append("settings"))
	title.credits_requested.connect(func() -> void: _routed.append("credits"))
	title.quit_requested.connect(func() -> void: _routed.append("quit"))

	(title.get("_play_button") as Button).pressed.emit()
	(title.get("_unlocks_button") as Button).pressed.emit()
	(title.get("_settings_button") as Button).pressed.emit()
	(title.get("_quit_button") as Button).pressed.emit()
	check(",".join(_routed) == "play,unlocks,settings,quit",
		"every title choice emits its own routing signal, in order")

	# The footer's live numbers must survive a missing service rather than blanking the screen.
	title.call("refresh")
	var salvage_label: Label = title.get("_salvage_label")
	check(salvage_label != null and salvage_label.text.begins_with("SALVAGE"),
		"the footer shows a salvage balance")
	var persona_label: Label = title.get("_persona_label")
	check(persona_label != null and not persona_label.text.is_empty(),
		"the footer shows a persona, or 'offline' when Steam is not signed in")

	# First boot has no run to report; an empty card would tell a new player they had already failed.
	var card: Control = title.get("_expedition_card")
	check(card != null, "the last-expedition card exists")
	await _check_expedition_card_states()

	# Everything on the title must clear the type floor — it is the screen most likely to be read
	# from a couch on a Deck.
	check(_minimum_font_size(title) >= MireTheme.CAPTION,
		"no text on the title screen falls below the %dpx floor" % MireTheme.CAPTION)

	stack.call("pop_all")
	title.free()

	# ── routing: quit confirms, credits pushes, unbuilt screens say so ───────────────────────────
	var frontend: Node3D = Frontend.new()
	# Add it under a parent so _ready() runs, but the bypass is active in this process, so it goes
	# straight for the world scene — which is exactly what must NOT happen inside a check. Drive the
	# public routing calls directly instead of letting _ready() run.
	check(Frontend._launch_bypasses_frontend(), "the frontend would bypass in this process")

	frontend.request_credits()
	await process_frame
	check(int(stack.call("depth")) == 1, "CREDITS pushes a screen")
	check(stack.call("top") is Control, "the credits screen is a Control")
	stack.call("pop_all")

	frontend.request_settings()
	await process_frame
	if ResourceLoader.exists(Frontend.SETTINGS_SCREEN_PATH):
		check(int(stack.call("depth")) == 1, "SETTINGS pushes the settings screen once it exists")
		stack.call("pop_all")
	else:
		# The late-binding contract: an unbuilt screen must SAY so, never silently do nothing —
		# that silent no-op is the D-032 dead end this front end exists to remove.
		check(int(stack.call("depth")) == 0, "an unbuilt screen pushes nothing")
		check(int(stack.call("toast_count")) > 0, "an unbuilt screen tells the player instead of doing nothing")

	frontend.free()

	# ── the backdrop: a real island, drifting, being eaten ───────────────────────────────────────
	var backdrop: Node3D = TitleBackdrop.new()
	root.add_child(backdrop)
	# Read the opening state BEFORE yielding: `_ready()` has run by now, but the first `_process`
	# has not, and a single awaited frame is enough to move the creep off its starting radius.
	var opening_radius: float = float(backdrop.call("mire_radius"))
	await process_frame

	check(backdrop.get_node_or_null(^"BackdropIsland") != null, "the backdrop builds an island")
	check(backdrop.get_node_or_null(^"BackdropWater") != null, "the backdrop builds water")
	check(backdrop.get_node_or_null(^"BackdropSun") != null, "the backdrop lights the island")
	check(backdrop.get_node_or_null(^"BackdropEnvironment") != null, "the backdrop sets its own environment")

	var island: MeshInstance3D = backdrop.get_node(^"BackdropIsland")
	var mesh: ArrayMesh = island.mesh
	check(mesh != null and mesh.get_surface_count() == 1, "the island is one mesh surface")
	var vertex_count: int = mesh.surface_get_array_len(0)
	check(vertex_count > 0, "the island mesh has geometry (%d vertices)" % vertex_count)
	# Flat shading means unshared vertices: three per triangle, so the count is divisible by three
	# and no vertex is reused between faces.
	check(vertex_count % 3 == 0, "the island is built from unshared vertices — flat-shaded, per DESIGN §6")

	var camera: Camera3D = backdrop.call("camera")
	check(camera != null and camera.current, "the backdrop owns the active camera")
	check(camera.position.y > 0.0, "the camera sits above the waterline")

	# The island is a real MIRE island for a date-derived seed, not a random one — everyone launching
	# today sees the same one.
	check(int(backdrop.call("seed_value")) == int(TitleBackdrop.daily_seed()),
		"the backdrop draws the daily island")
	check(int(TitleBackdrop.daily_seed()) == int(TitleBackdrop.daily_seed()),
		"the daily seed is stable within a day")
	check(int(TitleBackdrop.daily_seed()) != 0, "the daily seed is never zero")

	# The Mire creeps outward over time, and reduce-motion freezes it rather than jumping it to the
	# end state — a fully-corrupted island would say something different from a corrupting one.
	var settings: Node = root.get_node_or_null(^"/root/SettingsService")
	check(is_equal_approx(opening_radius, TitleBackdrop.MIRE_RADIUS_START),
		"the corruption starts at its opening radius")

	if settings != null:
		var restore: bool = bool(settings.call("reduce_camera_motion"))
		settings.call("set_reduce_camera_motion", true)
		# The property that matters is that reduce-motion STOPS the clock — not that the clock reads
		# zero, which it cannot once a frame has ticked. Freeze, then prove nothing moved.
		var frozen_radius: float = float(backdrop.call("mire_radius"))
		var frozen_fraction: float = float(backdrop.call("creep_fraction"))
		backdrop._process(4.0)
		check(is_equal_approx(float(backdrop.call("mire_radius")), frozen_radius),
			"reduce motion freezes the creep instead of snapping it to fully consumed")
		check(is_equal_approx(float(backdrop.call("creep_fraction")), frozen_fraction),
			"reduce motion stops the backdrop's clock rather than advancing it")

		settings.call("set_reduce_camera_motion", false)
		var before_position: Vector3 = camera.position
		backdrop._process(6.0)
		check(float(backdrop.call("mire_radius")) > opening_radius, "the corruption creeps outward over time")
		check(camera.position != before_position, "the camera drifts")
		check(float(backdrop.call("creep_fraction")) > 0.0, "creep_fraction advances")
		settings.call("set_reduce_camera_motion", restore)

	backdrop.free()
	stack.call("pop_all")
	print("TITLE_CHECK failures=%d" % failures)
	finish()


## F-335: the card's contract, driven from both sides instead of read off whatever this machine
## happens to have on disk.
##
## The old assertion compared the card's visibility to a record it read itself — which passes whether
## the card is right or wrong, as long as both agree. Worse, it read the PRE-MENU-7 boundary
## (`salvage_save.gd`, key `last_run`) while the shipped title reads `RunRecord`/`run_record_save.gd`,
## so it went red against correct code and its redness said nothing about the screen.
##
## Here the record is written, the title rebuilt, and the card asserted VISIBLE; then the record is
## removed, the title rebuilt, and the card asserted HIDDEN. Both directions, so a card stuck on or
## stuck off fails.
func _check_expedition_card_states() -> void:
	var service: Node = root.get_node_or_null(^"RunRecord")
	if service == null:
		check(false, "RunRecord autoload is present — it is what the title reads through")
		return
	var real_path: String = String(service.get("save_path"))
	service.set("save_path", TEST_RECORD_PATH)
	_remove_test_record()

	# No record: a first-ever boot.
	var empty: Dictionary = await _rebuilt_card_state()
	check(bool(empty.get("exists", false)), "a rebuilt title still builds an expedition card")
	check(not bool(empty.get("visible", true)),
		"with no recorded run the last-expedition card is hidden, not shown empty")

	# A recorded run, written through the shipped writer so the fixture is the real format.
	service.call("record", &"extracted", 7, 420)
	check(bool(RunRecordSave.load_data(TEST_RECORD_PATH).get("has_run", false)),
		"the fixture wrote a real record through the shipped boundary")
	var filled: Dictionary = await _rebuilt_card_state()
	check(bool(filled.get("visible", false)),
		"with a recorded run the last-expedition card appears")

	_remove_test_record()
	service.set("save_path", real_path)


## `{exists, visible}` for a freshly built title's expedition card.
##
## Built and freed here rather than reusing the screen under test, because visibility is decided
## during `_build()`: poking the save afterwards would not move an already-built card, and a check
## that flipped the flag itself would be asserting its own poke. Returns plain values because the
## screen is gone by the time the caller reads them.
func _rebuilt_card_state() -> Dictionary:
	var screen: Control = TitleScreen.new()
	root.add_child(screen)
	await process_frame
	var card: Control = screen.get("_expedition_card") as Control
	var state := {"exists": card != null, "visible": card != null and card.visible}
	screen.queue_free()
	await process_frame
	return state


func _remove_test_record() -> void:
	if FileAccess.file_exists(TEST_RECORD_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_RECORD_PATH))


## Walks a screen for Label font sizes so the type floor is asserted against what was actually
## built, not against the constants — a screen that hardcodes a size instead of using the kit is
## exactly what this catches.
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
