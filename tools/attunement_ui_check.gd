extends SceneTree

## Offline proof for task 3.9's selection UI: it stays closed until a local player body exists, opens
## exactly once, shows all four roles, and a CHOOSE click closes it on acceptance.
##
##   .agent/bin/agent godot --script tools/attunement_ui_check.gd
##
## Drives the REGISTERED /root/AttunementUI, not a private instance (F-068/F-069 precedent). A
## PlayerController is heavier than this check needs (viewmodel, camera, synchronizer) — the trigger
## only reads `is_in_group(&"players") and is_multiplayer_authority()` (see
## ui/attunement/attunement_ui.gd's `_poll_for_local_player`), so a bare Node3D standing in for one is
## enough to prove the polling contract without pulling in player_controller.gd, which this task does
## not claim and which is mid-edit-broken under lp's 3.8b claim at the time of writing (see 3.9's
## journal note).

const PLAYERS_GROUP: StringName = &"players"

var failures: int = 0
var ui: Node
var service: Node
var powerups: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	ui = root.get_node_or_null(^"AttunementUI")
	service = root.get_node_or_null(^"AttunementService")
	powerups = root.get_node_or_null(^"PowerupService")
	check(ui != null, "AttunementUI is registered as an autoload")
	check(service != null, "AttunementService is registered as an autoload")
	if ui == null or service == null or powerups == null:
		finish()
		return

	print("\n== stays closed with no local player body ==")
	ui.call(&"poll_now")
	check(not bool(ui.call(&"is_open")), "no players in the group yet — nothing to open for")

	print("\n== opens once a local-authority player body appears ==")
	var stand_in := Node3D.new()
	stand_in.name = "StandInPlayer"
	stand_in.add_to_group(PLAYERS_GROUP)
	root.add_child(stand_in)
	await process_frame
	ui.call(&"poll_now")
	# Offline, is_multiplayer_authority() is true for every node (no peer -> unique id 1, default
	# authority 1 — the same fact player_controller.gd's own _ready() comment documents), so the
	# stand-in satisfies the trigger with no MultiplayerAPI setup needed.
	check(bool(ui.call(&"is_open")), "the picker opened for the local player's first body")
	check(int(ui.call(&"role_button_count")) == 4, "all four DESIGN §4.5 roles are shown (%d)" %
		int(ui.call(&"role_button_count")))

	print("\n== an open mandatory picker keeps cursor and focus ownership ==")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	root.gui_release_focus()
	ui.call(&"enforce_input_ownership_now")
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE,
		"a later gameplay capture cannot strand the open picker without a cursor")
	var focus_owner: Control = root.gui_get_focus_owner()
	check(focus_owner != null and ui.is_ancestor_of(focus_owner),
		"a later focus clear cannot leave the mandatory picker without an operable control")

	print("\n== choosing a role closes the picker on acceptance ==")
	powerups.call(&"host_clear", NetConfig.HOST_PEER_ID)
	ui.call(&"choose", &"tinker")
	await process_frame
	check(not bool(ui.call(&"is_open")), "the picker closes once the pick is accepted")
	check(String(service.call(&"selection_of", NetConfig.HOST_PEER_ID)) == "tinker",
		"and the real service recorded it")

	stand_in.queue_free()
	print("\nATTUNEMENT_UI_CHECK failures=%d" % failures)
	finish()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
