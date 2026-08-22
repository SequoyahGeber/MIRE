extends SceneTree

## F-527: the build bar is one row above the hotbar, categorized into mouse-clickable tabs and
## pieces, and releases/recaptures the first-person cursor with its lifetime.
##
##   .agent/bin/agent godot --script tools/build_picker_check.gd
##
## Proves the three things the playtest report needed. That every authored buildable declares a tab
## and the tabs are the ones we meant; that the bar only ever puts ONE row of slots on screen; and
## — the actual fault — that opening gives the pointer back, real tab/slot mouse handlers select the
## ghost, and closing recaptures first-person aim. Bound keyboard/gamepad selection remains covered.
##
## Runs against a real player from player.tscn rather than a bare BuildBar, because the seam that
## was broken is the round trip: bar emits `piece_selected` -> player_controller
## `set_selected_build_piece()` -> ghost. A BuildBar on its own would report a selection that never
## reached anything.

## The tab each piece is meant to land on. Written out rather than read back from the .tres so this
## check disagrees with a mis-authored category instead of agreeing with it.
const EXPECTED_CATEGORY: Dictionary[StringName, StringName] = {
	&"wall_wood": &"structure",
	&"floor_wood": &"structure",
	&"ramp": &"structure",
	&"ward_post": &"defence",
	&"workbench": &"station",
	&"campfire": &"station",
}

var failures: int = 0
var registry: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	registry = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if registry == null:
		finish()
		return

	_check_content_declares_categories()
	_check_actions_are_bound()
	await _check_bar_is_one_row_and_mouse_driven()

	print("\nBUILD_PICKER_CHECK failures=%d" % failures)
	finish()


## Every piece has a tab, the tabs are the three we authored, and no tab is wide enough to wrap.
func _check_content_declares_categories() -> void:
	print("\n== every buildable declares a tab ==")
	var buildables: Dictionary = registry.get(&"buildables")
	check(not buildables.is_empty(), "the registry indexed some buildables")

	var counts: Dictionary[StringName, int] = {}
	var uncategorized: PackedStringArray = []
	for id: StringName in buildables:
		var category: StringName = StringName(String(buildables[id].get(&"category")))
		if category == &"":
			uncategorized.append(String(id))
			continue
		counts[category] = int(counts.get(category, 0)) + 1
	check(uncategorized.is_empty(),
		"no piece is left without a tab (offenders: %s)" % ", ".join(uncategorized))

	for id: StringName in EXPECTED_CATEGORY:
		var def: Resource = registry.call(&"get_buildable", id)
		if def == null:
			check(false, "'%s' is indexed" % id)
			continue
		var got: StringName = StringName(String(def.get(&"category")))
		check(got == EXPECTED_CATEGORY[id],
			"'%s' is on the %s tab (got %s)" % [id, EXPECTED_CATEGORY[id], got])

	# The whole point of tabs: the row never has to wrap. Eight is what ROW_WIDTH_PX is sized for.
	for category: StringName in counts:
		check(int(counts[category]) <= 8,
			"the %s tab holds %d pieces, which still fits one row" % [category, counts[category]])

	check(BuildableDef.category_label(&"structure") == "STRUCTURE", "a listed tab has its label")
	check(BuildableDef.category_label(&"siege_engine") == "SIEGE ENGINE",
		"an unlisted tab is title-cased rather than shown as a raw key")
	check(BuildableDef.category_rank(&"structure") < BuildableDef.category_rank(&"station"),
		"structure sorts before station")
	check(BuildableDef.category_rank(&"siege_engine") >= BuildableDef.CATEGORY_ORDER.size(),
		"an unlisted tab sorts after every listed one rather than being dropped")

	var broken := BuildableDef.new()
	broken.category = &""
	check("category" in " ".join(broken.validation_errors()),
		"a def with no category fails validation by name")


## The picker is bound input or it is nothing — this is the fault F-483 filed.
func _check_actions_are_bound() -> void:
	print("\n== the picker's actions exist in the InputMap ==")
	for action: StringName in [
		&"build_piece_prev", &"build_piece_next",
		&"build_category_prev", &"build_category_next",
	]:
		check(InputMap.has_action(action), "'%s' is a real action" % action)
		if InputMap.has_action(action):
			check(not InputMap.action_get_events(action).is_empty(),
				"and '%s' is actually bound to something" % action)


func _check_bar_is_one_row_and_mouse_driven() -> void:
	print("\n== tabs and pieces can be picked with a free mouse cursor ==")
	var player_net: Node = root.get_node_or_null(^"PlayerNet")
	var players_root: Node = player_net.call(&"players_root") as Node if player_net != null else null
	check(players_root != null, "PlayerNet's players_root exists")
	if players_root == null:
		return

	var level := Node3D.new()
	level.name = "PickerTestLevel"
	root.add_child(level)
	current_scene = level

	var player: CharacterBody3D = \
		preload("res://entities/player/player.tscn").instantiate() as CharacterBody3D
	player.name = "1"
	players_root.add_child(player)
	await process_frame
	await process_frame

	var ghost: Node = player.get_node_or_null(^"BuildGhost")
	var bar: Node = player.get_node_or_null(^"BuildBar")
	check(ghost != null and bar != null, "the player built a ghost and a bar")
	if ghost == null or bar == null:
		player.queue_free()
		return

	root.push_input(_key_event(KEY_B, true))
	check(bool(bar.call(&"is_active")), "the 'build' action shows the bar")
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE,
		"opening build mode releases the cursor for pointing")

	# BuildBar deliberately stays outside blocks_gameplay_input: it needs the pointer, but clicking
	# bare world space must still reach PlayerController's existing placement branch.
	check(not bar.is_in_group(&"blocks_gameplay_input"),
		"the open bar does not disable world placement input")
	check(bool(player.call(&"gameplay_input_allowed")),
		"and build mode can still place the armed ghost")

	check(int(bar.call(&"category_count")) >= 2, "the bar built more than one tab")
	check(int(bar.call(&"visible_slot_count")) <= 8,
		"only one row of slots is on screen (%d)" % int(bar.call(&"visible_slot_count")))
	check(int(bar.call(&"visible_slot_count")) < int(bar.call(&"slot_count")),
		"and that is fewer than the whole set — the tabs are actually hiding something")

	# These seams construct a left mouse press and feed the actual Control._gui_input handlers.
	var mouse_first_tab: StringName = StringName(bar.call(&"open_category"))
	bar.call(&"select_category", 1)
	var mouse_second_tab: StringName = StringName(bar.call(&"open_category"))
	check(mouse_second_tab != mouse_first_tab,
		"clicking a category tab opens it (%s -> %s)" % [mouse_first_tab, mouse_second_tab])
	check(StringName(bar.call(&"_category_of", ghost.call(&"current_piece_id"))) == mouse_second_tab,
		"and a tab click arms that category's first piece")
	var clicked_piece: StringName = StringName(bar.call(&"slot_piece_id", 0))
	bar.call(&"select_slot", 0)
	check(StringName(ghost.call(&"current_piece_id")) == clicked_piece,
		"clicking a piece slot arms that exact piece (%s)" % clicked_piece)

	# Stepping the piece. Fed as the real action event into the real _input(), exactly as the engine
	# would deliver a wheel press, with nothing clicked and no slot method called directly.
	# Every press below goes in through `root.push_input()` — the engine's own delivery — rather
	# than by calling `_input()` on the bar directly. Two reasons, and the second is the one that
	# bites: it exercises the REAL propagation, so a press this bar is supposed to take from
	# `InventoryUI` is actually seen to reach this bar first; and `push_input` is what clears the
	# viewport's handled flag at the start of a dispatch. Calling `_input()` by hand leaves the flag
	# set by the previous consume forever, and every press after the first is skipped by the guard
	# at the top of `_input()` — a section that passes by doing nothing at all.
	var before: StringName = StringName(ghost.call(&"current_piece_id"))
	root.push_input(_wheel_event(MOUSE_BUTTON_WHEEL_DOWN))
	var after: StringName = StringName(ghost.call(&"current_piece_id"))
	check(after != &"" and after != before,
		"wheel-down still changes the armed piece (%s -> %s)" % [before, after])

	root.push_input(_wheel_event(MOUSE_BUTTON_WHEEL_UP))
	check(StringName(ghost.call(&"current_piece_id")) == before,
		"and wheel-up steps back to where it was")

	# Stepping the tab. The armed piece must follow, or the tab is a display with no effect.
	var first_tab: StringName = StringName(bar.call(&"open_category"))
	root.push_input(_key_event(KEY_C, true))
	var second_tab: StringName = StringName(bar.call(&"open_category"))
	check(second_tab != first_tab, "C opens the next tab (%s -> %s)" % [first_tab, second_tab])
	check(StringName(bar.call(&"_category_of", ghost.call(&"current_piece_id"))) == second_tab,
		"and the armed piece moved to that tab with it")

	root.push_input(_key_event(KEY_Z, true))
	check(StringName(bar.call(&"open_category")) == first_tab, "Z steps back to the previous tab")

	# The other direction of the same invariant: a piece selected directly must drag its tab open,
	# or the row would sit marking nothing while the ghost previewed something else.
	var elsewhere: StringName = &""
	for i: int in int(bar.call(&"slot_count")):
		var id: StringName = StringName(bar.call(&"slot_piece_id", i))
		if StringName(bar.call(&"_category_of", id)) != first_tab:
			elsewhere = id
			break
	check(elsewhere != &"", "there is a piece on some other tab to select")
	if elsewhere != &"":
		player.call(&"set_selected_build_piece", elsewhere)
		check(StringName(bar.call(&"open_category"))
				== StringName(bar.call(&"_category_of", elsewhere)),
			"selecting a piece opens the tab it lives on")

	# The picker must not double up on a binding something else in gameplay reads. The first cut of
	# F-483 put piece stepping on the shoulder buttons, which are `hotbar_prev`/`hotbar_next`, on
	# the theory that BuildBar would win `_input` and consume them; `InventoryUI` won instead and
	# one press both stepped the piece and swapped the held item. This is the regression guard.
	var inventory_ui: Node = root.get_node_or_null(^"InventoryUI")
	check(inventory_ui != null, "the InventoryUI autoload is there to be contended with")
	if inventory_ui != null:
		var hotbar_before: int = int(inventory_ui.call(&"selected_hotbar_slot"))
		var piece_before: StringName = StringName(ghost.call(&"current_piece_id"))
		root.push_input(_pad_event(JOY_BUTTON_RIGHT_SHOULDER))
		check(StringName(ghost.call(&"current_piece_id")) == piece_before
				and int(inventory_ui.call(&"selected_hotbar_slot")) != hotbar_before,
			"the shoulder buttons are the hotbar's alone, even in build mode")

		# The pad's own piece step, on a button nothing else wants.
		root.push_input(_pad_event(JOY_BUTTON_BACK))
		check(StringName(ghost.call(&"current_piece_id")) != piece_before,
			"BACK steps the piece on a pad")

	# Stepping past the end of a tab carries into the next one — the whole reason two pad buttons
	# are enough to reach all 22 pieces without a tab binding.
	var seen: Dictionary[StringName, bool] = {}
	for i: int in int(bar.call(&"slot_count")):
		seen[StringName(bar.call(&"open_category"))] = true
		root.push_input(_wheel_event(MOUSE_BUTTON_WHEEL_DOWN))
	check(seen.size() == int(bar.call(&"category_count")),
		"stepping the piece walks every tab (%d of %d)"
			% [seen.size(), int(bar.call(&"category_count"))])

	# Out of build mode the shared bindings go back to the hotbar untouched.
	check(bool(player.call(&"gameplay_input_allowed")),
		"no other cursor-owning panel is open when build mode closes")
	root.push_input(_key_event(KEY_B, true))
	check(not bool(bar.call(&"is_active")), "the 'build' action closes the bar again")
	var close_mode: Input.MouseMode = Input.mouse_mode
	check(DisplayServer.get_name() == "headless" or close_mode == Input.MOUSE_MODE_CAPTURED,
		"closing build mode recaptures the cursor for first-person aim (mode %d)" % close_mode)
	var armed_after_close: StringName = StringName(ghost.call(&"current_piece_id"))
	root.push_input(_wheel_event(MOUSE_BUTTON_WHEEL_DOWN))
	check(StringName(ghost.call(&"current_piece_id")) == armed_after_close,
		"and the wheel does nothing to the bar once build mode is off")
	if inventory_ui != null:
		var piece_closed: StringName = StringName(ghost.call(&"current_piece_id"))
		root.push_input(_pad_event(JOY_BUTTON_BACK))
		check(StringName(ghost.call(&"current_piece_id")) == piece_closed,
			"and BACK does nothing to the armed piece once build mode is off")

	player.queue_free()


func _key_event(keycode: Key, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.keycode = keycode
	event.pressed = pressed
	return event


func _pad_event(button_index: JoyButton) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.button_index = button_index
	event.pressed = true
	return event


func _wheel_event(button_index: int) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button_index
	event.pressed = true
	return event


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
