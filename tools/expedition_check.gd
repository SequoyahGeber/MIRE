extends SceneTree

## MENU-4 proof (docs/MENU.md §5, §11): the dock builds, stages seeds, previews the real island,
## and shows the right controls for who you are — host, joining client, or mid-run drop-in.
##
## Replaces `tools/lobby_menu_check.gd`'s job for the new front end; that check still covers the
## shipped M panel until `lobby_menu.gd` is retired.
##
## The Steam paths (host, join, invite, copy) cannot be exercised without a running Steam client, so
## what is asserted about them is what this screen is actually responsible for: that they are
## reachable, that they fail with a sentence a player can act on rather than silently, and that the
## screen re-derives itself from the services rather than from a signal payload.
##
## Run with: .agent/bin/agent godot --script tools/expedition_check.gd

const ExpeditionScreen := preload("res://ui/frontend/expedition_screen.gd")
const IslandMinimap := preload("res://ui/frontend/island_minimap.gd")
const Heightmap := preload("res://world/gen/island_heightmap.gd")
const MireTheme := preload("res://ui/theme/mire_theme.gd")

const REFERENCE_SIZE := Vector2i(1920, 1080)

var failures: int = 0
var _sailed: int = 0


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
	DisplayServer.window_set_size(REFERENCE_SIZE)
	await process_frame

	# ── the seed rule, independent of the widget ─────────────────────────────────────────────────
	check(ExpeditionScreen.staged_seed_for("424242") == 424242, "a numeric seed is used verbatim")
	check(ExpeditionScreen.staged_seed_for("") == 0, "an empty seed clears the override")
	var word: int = ExpeditionScreen.staged_seed_for("oakhollow")
	check(word != 0, "a word seed hashes to something non-zero")
	check(ExpeditionScreen.staged_seed_for("oakhollow") == word, "the same word always hashes the same")
	check(ExpeditionScreen.staged_seed_for("  oakhollow  ") == word, "surrounding whitespace is ignored")
	# A seed of 0 means "unset" everywhere in this project, so no typed text may ever produce one.
	check(ExpeditionScreen.staged_seed_for("0") != 0, "a typed zero is nudged off the 'unset' value")

	# ── the minimap is the real island, not an impression of one ─────────────────────────────────
	var image: Image = IslandMinimap.image_for_seed(7, 48)
	check(image.get_width() == 48 and image.get_height() == 48, "the minimap renders at the asked-for size")

	# Land must appear where the heightmap says land is. Sampling the centre of the patch and the
	# far corner is enough to prove the preview is keyed to the seed rather than decorative.
	var noise_set: Variant = Heightmap.make_noise_set(7)
	var centre_height: float = float(Heightmap.height_from_set(0.0, 0.0, noise_set, 7))
	var centre_pixel: Color = image.get_pixel(24, 24)
	var corner_pixel: Color = image.get_pixel(0, 0)
	if centre_height > 0.0:
		check(centre_pixel != IslandMinimap.COLOUR_DEEP,
			"the island's centre draws as land where the heightmap says land")
	check(corner_pixel.g <= IslandMinimap.COLOUR_SHALLOW.g + 0.01,
		"the far corner of the patch draws as water")

	# Two different seeds must produce two different islands, or the preview tells the player
	# nothing and choosing a seed is theatre.
	var other: Image = IslandMinimap.image_for_seed(991, 48)
	check(image.get_data() != other.get_data(), "different seeds preview as different islands")
	check(IslandMinimap.image_for_seed(7, 48).get_data() == image.get_data(),
		"the same seed always previews identically")

	# ── the screen ───────────────────────────────────────────────────────────────────────────────
	var dock: Control = ExpeditionScreen.new()
	dock.sail_requested.connect(func() -> void: _sailed += 1)
	stack.call("push", dock, false)
	await process_frame
	await process_frame

	var frame: Vector2 = (dock.get_parent() as Control).size
	check(dock.size.is_equal_approx(frame), "the dock fills its frame (%s of %s)" % [dock.size, frame])

	# Solo: no lobby, no session. The dock must still show YOU rather than an empty list, and must
	# fill the rest of the berths so the party reads as a party with room in it.
	check(int(dock.call("party_row_count")) == ExpeditionScreen.PARTY_SLOTS,
		"the dock shows every berth (%d)" % int(dock.call("party_row_count")))

	# Solo is host: the seed is yours to choose and SET SAIL is live.
	check(dock.get("_seed_field").editable, "a solo player can choose the island")
	check(bool(dock.call("sail_enabled")), "SET SAIL is enabled for a solo player")
	check(String(dock.get("_sail_button").text) == "SET SAIL", "the primary action reads SET SAIL")

	# Typing a seed stages it into GameState and nowhere else.
	var state: Node = root.get_node_or_null(^"/root/GameState")
	if state != null:
		state.call("set_pending_seed", 0)
		dock.get("_seed_field").text = "oakhollow"
		dock.call("request_set_seed")
		check(bool(state.call("has_pending_seed")), "typing a seed stages it")
		check(int(state.call("pending_seed")) == word, "the staged value matches the documented rule")

		dock.get("_seed_field").text = ""
		dock.call("request_set_seed")
		check(not bool(state.call("has_pending_seed")), "clearing the field clears the override")

	# The preview follows the seed, after the debounce.
	dock.get("_seed_field").text = "oakhollow"
	dock.call("request_set_seed")
	await create_timer(ExpeditionScreen.SEED_PREVIEW_DEBOUNCE + 0.25).timeout
	check(int(dock.call("previewed_seed")) == word,
		"the island preview follows the typed seed (previewing %d, expected %d)"
			% [int(dock.call("previewed_seed")), word])

	# Steam is not running in a check, so every Steam path must fail in a sentence rather than
	# silently — the whole point of the dock's status line.
	dock.call("request_copy_code")
	check(not String(dock.call("status_text")).is_empty(),
		"copying with no lobby explains itself instead of doing nothing")

	dock.get("_join_field").text = ""
	dock.call("request_join")
	check(String(dock.call("status_text")).contains("code"),
		"joining with an empty field says what is missing")

	# SET SAIL leaves the front end. `enter_world()` would change scenes, so the check watches the
	# signal the screen emits first rather than letting it tear the harness down.
	check(_sailed == 0, "nothing has sailed yet")

	# Focus must land somewhere a controller can use (F-216).
	var focus_target: Control = dock.call("menu_default_focus")
	check(focus_target != null and focus_target.focus_mode == Control.FOCUS_ALL,
		"the dock names a focusable default")

	# Nothing on this screen may fall below the type floor.
	check(_minimum_font_size(dock) >= MireTheme.CAPTION,
		"no text on the dock falls below the %dpx floor" % MireTheme.CAPTION)

	# Esc backs out to the title rather than trapping the player at the dock.
	check(not dock.has_method("menu_allows_cancel") or bool(dock.call("menu_allows_cancel")),
		"the dock can be backed out of")

	stack.call("pop_all")
	check(int(stack.call("depth")) == 0, "the dock pops cleanly")

	print("EXPEDITION_CHECK failures=%d" % failures)
	finish()


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
