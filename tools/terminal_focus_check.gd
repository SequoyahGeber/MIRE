extends SceneTree

## F-275 proof: F-243's two terminal run-summary overlays (`ui/hud/defeat_hud.gd`,
## `ui/hud/extraction_hud.gd`) are reachable with no mouse at all. Both are mandatory panels in the
## F-216 sense — no Esc, no dismiss, the "Start Next Run" button is the only way off the screen — so
## "the button exists" is not the property under test; "a bare controller can press it" is.
##
## Phase 1 runs solo (this process is host-or-solo, so both buttons are the enabled host control):
## each overlay must grab its own button on show, at FOCUS_ALL, with a visible focus ring, and a
## real gamepad `ui_accept` must actually start the next run. Events go through
## `Input.parse_input_event()`, never a direct call into a node's `_gui_input()` — the same reasoning
## `tools/menu_focus_check.gd` states at length: focus handling is Godot's own Viewport GUI code, not
## anything these scripts implement, so only a real event through the real pipeline proves it.
##
## Phase 2 is the other half of the finding, and it needs a second process to be honest about it: on
## a NON-host peer the button is a disabled "waiting on the host" label, and the finding requires
## that it must NOT take focus — a focused control whose `ui_accept` does nothing is worse than no
## focus, because the player has no way to tell the screen is not simply broken. `_is_host_or_solo()`
## reads real `NetTransport` state, so the only way to exercise that branch without poking private
## engine/transport state is to actually be a connected client. The child process joins this one and
## drives both overlays through their real EventBus triggers locally (both are client-local
## presentation — ARCHITECTURE.md §2.2 "VFX, audio, camera, UI" — so no host traffic is involved in
## showing them; the session exists purely to make `is_host()` false).
##
##   .agent/bin/agent godot --script tools/terminal_focus_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const NET_CONFIG := preload("res://core/net/net_config.gd")

const PORT: int = 47451
const RESULT_PATH: String = "user://terminal_focus_client.json"
## F-290: the client rewrites its result file repeatedly while the driver polls it, and a plain
## open-truncate-write is observable half-written. Every write lands here first and is renamed into
## place, so the driver either sees the previous complete document or the next one, never a torn
## parse it would report as a failure that never happened.
const RESULT_TMP_PATH: String = "user://terminal_focus_client.json.tmp"
const TEST_SAVE_PATH: String = "user://terminal_focus_salvage.json"
const TIMEOUT_SEC: float = 20.0
const RESTART_LABEL: String = "Start Next Run"
const WAITING_LABEL: String = "Waiting on the host to start the next run…"

var failures: int = 0
var transport: Node
var defeat_service: Node
var cycle_service: Node
var child_pid: int = 0


## `CycleService._run_has_ended()` accepts a defeat OR a departed `&"extraction_ship"` group member,
## and the shipped ship is a whole level scene. This is the smallest real thing that satisfies that
## contract — a node in the group with a `departed` property — so the extraction half of the check
## needs no level load.
class StandInShip extends Node:
	var departed: bool = false


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	defeat_service = root.get_node_or_null(^"DefeatService")
	cycle_service = root.get_node_or_null(^"CycleService")
	if transport == null or defeat_service == null or cycle_service == null:
		_fail("NetTransport, DefeatService and CycleService autoloads must exist")
		_finish()
		return
	var salvage_service: Node = root.get_node_or_null(^"SalvageService")
	if salvage_service != null:
		salvage_service.set(&"save_path", TEST_SAVE_PATH)
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "terminal-focus-probe":
		await _run_client()
	else:
		await _run_driver()


# ── phase 1 · host/solo ───────────────────────────────────────────────────────────────────────────


func _run_driver() -> void:
	await _check_host_overlays()
	await _check_client_overlays()
	print("\nTERMINAL_FOCUS_CHECK failures=%d" % failures)
	_finish()


func _check_host_overlays() -> void:
	print("\n== F-275 · host/solo: each terminal overlay is operable from a bare controller ==")
	var defeat_hud: Node = root.get_node_or_null(^"DefeatHud")
	var extraction_hud: Node = root.get_node_or_null(^"ExtractionHud")
	_check(defeat_hud != null and extraction_hud != null,
		"the DefeatHud and ExtractionHud autoloads exist")
	if defeat_hud == null or extraction_hud == null:
		return

	var restarts: Dictionary = {"count": 0}
	var on_restarted: Callable = func() -> void:
		restarts["count"] = int(restarts["count"]) + 1
	EVENT_BUS.subscribe_run_restarted(on_restarted)

	# The real defeat path, not a bare EventBus emit: `defeated`'s own setter is what fires
	# `run_wiped` on every peer (see defeat_service.gd), so this drives the same code a team wipe does.
	defeat_service.set(&"cause", &"team_wipe")
	defeat_service.set(&"defeated", true)
	await process_frame
	_assert_focused_restart_button("the defeat summary")
	await _tap(JOY_BUTTON_A)
	_check(int(restarts["count"]) == 1,
		"ui_accept on the focused button starts the next run — with no dismiss path this is the only way off the defeat screen, and it is the whole finding")
	_check(_focused() == null,
		"hiding the defeat overlay hands keyboard focus back, so gameplay ui_accept is not still aimed at a hidden button")

	var ship := StandInShip.new()
	ship.name = "TerminalFocusCheckShip"
	ship.add_to_group(&"extraction_ship")
	root.add_child(ship)
	ship.departed = true
	EVENT_BUS.emit_run_extracted(3, Vector3.ZERO)
	await process_frame
	_assert_focused_restart_button("the extraction summary")
	await _tap(JOY_BUTTON_A)
	_check(int(restarts["count"]) == 2,
		"ui_accept on the focused button starts the next run from the extraction summary too")
	_check(_focused() == null, "hiding the extraction overlay hands keyboard focus back")

	EVENT_BUS.unsubscribe_run_restarted(on_restarted)
	root.remove_child(ship)
	ship.free()
	await process_frame


## Every property the finding names, in one place, for whichever overlay just opened.
func _assert_focused_restart_button(label: String) -> void:
	var focused: Control = _focused()
	var button: Button = focused as Button
	_check(button != null and button.text == RESTART_LABEL,
		"%s focuses its Start Next Run button for keyboard/gamepad activation" % label)
	if button == null:
		return
	_check(not button.disabled, "%s focuses the enabled host control, not a dead one" % label)
	_check(button.focus_mode == Control.FOCUS_ALL,
		"%s's button is in the focus graph at FOCUS_ALL" % label)
	_check(button.has_theme_stylebox_override(&"focus"),
		"%s's button carries a visible focus ring, so the player can see what ui_accept will hit" % label)


# ── phase 2 · a real non-host peer ────────────────────────────────────────────────────────────────


func _check_client_overlays() -> void:
	print("\n== F-275 · a real connected client: the disabled waiting label never takes focus ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))

	var error: Error = transport.call("host", NET_CONFIG.Mode.LOCAL, PORT)
	_check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		return
	child_pid = _spawn_client()
	_check(child_pid > 0, "the client probe process starts")
	if child_pid <= 0:
		return

	var done: bool = await _until(func() -> bool:
		return bool(_read_result().get("done", false)), TIMEOUT_SEC)
	var result: Dictionary = _read_result()
	_check(done, "the client probe reports back within %.0fs" % TIMEOUT_SEC)
	if not done:
		print("  last client result: %s" % JSON.stringify(result))
		return
	if result.has("error"):
		_fail("client probe: %s" % String(result["error"]))
		return
	for entry: Variant in result.get("checks", []):
		var row: Dictionary = entry as Dictionary
		_check(bool(row.get("ok", false)), "client: %s" % String(row.get("what", "")))

	transport.call("leave")
	await process_frame


func _run_client() -> void:
	var checks: Array = []
	var error: Error = transport.call(
		"join", NET_CONFIG.Mode.LOCAL, NET_CONFIG.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"done": true, "error": error_string(error)})
		_finish()
		return
	var joined: bool = await _until(
		func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	if not joined or bool(transport.call("is_host")):
		_write_result({"done": true, "error": "probe never connected as a non-host peer"})
		_finish()
		return

	defeat_service.set(&"cause", &"team_wipe")
	defeat_service.set(&"defeated", true)
	await process_frame
	_collect_client_checks(checks, root.get_node_or_null(^"DefeatHud"), "the defeat summary")

	EVENT_BUS.emit_run_restarted()
	await process_frame
	EVENT_BUS.emit_run_extracted(3, Vector3.ZERO)
	await process_frame
	_collect_client_checks(checks, root.get_node_or_null(^"ExtractionHud"), "the extraction summary")

	_write_result({"done": true, "checks": checks})
	_finish()


## The non-host half of the finding: the waiting label must be visibly present but completely inert.
func _collect_client_checks(checks: Array, hud: Node, label: String) -> void:
	if hud == null:
		checks.append({"ok": false, "what": "%s autoload exists" % label})
		return
	var button: Button = _find_button(hud)
	checks.append({"ok": button != null, "what": "%s built its restart control" % label})
	if button == null:
		return
	checks.append({
		"ok": button.text == WAITING_LABEL and button.disabled,
		"what": "%s shows the disabled waiting-on-the-host label" % label,
	})
	checks.append({
		"ok": button.focus_mode == Control.FOCUS_NONE,
		"what": "%s takes the waiting label out of the focus graph entirely" % label,
	})
	checks.append({
		"ok": _focused() != button,
		"what": "%s never focuses a control this peer's ui_accept cannot act on" % label,
	})


func _find_button(node: Node) -> Button:
	if node is Button:
		return node as Button
	for child: Node in node.get_children():
		var found: Button = _find_button(child)
		if found != null:
			return found
	return null


# ── helpers ───────────────────────────────────────────────────────────────────────────────────────


func _tap(button_index: int) -> void:
	var press := InputEventJoypadButton.new()
	press.button_index = button_index
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	await process_frame
	var release := InputEventJoypadButton.new()
	release.button_index = button_index
	release.pressed = false
	Input.parse_input_event(release)
	await process_frame


func _focused() -> Control:
	return root.get_viewport().gui_get_focus_owner()


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/terminal_focus_check.gd",
		"--", "terminal-focus-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _write_result(result: Dictionary) -> void:
	var file := FileAccess.open(RESULT_TMP_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(RESULT_TMP_PATH), ProjectSettings.globalize_path(RESULT_PATH))


func _read_result() -> Dictionary:
	if not FileAccess.file_exists(RESULT_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RESULT_PATH))
	return parsed if parsed is Dictionary else {}


func _check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	_fail(description)


func _fail(description: String) -> void:
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	if child_pid > 0 and OS.is_process_running(child_pid):
		OS.kill(child_pid)
	if transport != null and bool(transport.call("is_active")):
		transport.call("leave")
	quit(0 if failures == 0 else 1)
