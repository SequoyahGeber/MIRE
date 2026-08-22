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
## Phase 3 is F-307, and it needs the second process for the same reason phase 2 does. F-243 made a
## terminal screen's only control host-gated and F-275 made the non-host half of it correctly inert —
## but neither re-reads that gate afterwards, so a client whose host quits under the overlay was left
## on a screen with zero operable controls and, because the overlay is still in
## `blocks_gameplay_input` (D-032), no route to a menu either. The host quitting once a run has ended
## is the ordinary case, not an exotic one. This phase drives it literally: the child joins, opens a
## terminal overlay as a client, the driver then calls `NetTransport.leave()`, and the child asserts
## the screen still has a real exit afterwards (D-185: "Leave to Menu", not a restart of a world the
## session already tore down). Once per overlay, one child each, because `session_ended` fires once.
##
##   .agent/bin/agent godot --script tools/terminal_focus_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const NET_CONFIG := preload("res://core/net/net_config.gd")

const PORT: int = 47451
## F-307's two children get their own ports and their own result files: a phase that hosts again
## after the previous one's socket has only just closed is the kind of thing that fails once in
## twenty runs on a loaded machine, and a stale result file from an earlier phase reads as a pass.
## F-321 adds "attunement". It is not a terminal run-summary overlay like the other two — it is the
## run-START picker — but it is the same CLASS of bug and the same phase-3 driver proves it: a
## mandatory panel in `blocks_gameplay_input` that reads "the host will answer" exactly once and has
## no way out when that stops being true.
const ORPHAN_PORTS: Dictionary = {"defeat": 47452, "extraction": 47453, "attunement": 47454}
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"
const RESULT_PATH: String = "user://terminal_focus_client.json"
## F-290: the client rewrites its result file repeatedly while the driver polls it, and a plain
## open-truncate-write is observable half-written. Every write lands here first and is renamed into
## place, so the driver either sees the previous complete document or the next one, never a torn
## parse it would report as a failure that never happened.
const RESULT_TMP_PATH: String = "user://terminal_focus_client.json.tmp"
const TEST_SAVE_PATH: String = "user://terminal_focus_salvage.json"
const TIMEOUT_SEC: float = 20.0
## The post-leave wait needs its own, much longer budget. The SHIPPED host-leave path sends no notice
## (see this file's phase-3 note), so an orphaned client burns NetSession's whole 4-attempt rejoin
## ladder — 0.5+1+2+4 s of backoff plus four 3 s connect timeouts — before `session_ended` fires at
## all. That lands around 19 s, i.e. right on TIMEOUT_SEC, which is a flake waiting to happen.
const ORPHAN_TIMEOUT_SEC: float = 60.0
const RESTART_LABEL: String = "Start Next Run"
const WAITING_LABEL: String = "Waiting on the host to start the next run…"
const LEAVE_LABEL: String = "Leave to Menu"

var failures: int = 0
## Which result file this process is talking through. Phase 2 and F-307's two phase-3 children each
## own one, so a driver polling for the next phase can never read the previous phase's document.
var result_path: String = RESULT_PATH
var result_tmp_path: String = RESULT_TMP_PATH
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
	elif args.size() >= 2 and args[0] == "terminal-orphan-probe":
		await _run_orphan_client(args[1])
	else:
		await _run_driver()


# ── phase 1 · host/solo ───────────────────────────────────────────────────────────────────────────


func _run_driver() -> void:
	await _check_host_overlays()
	await _check_client_overlays()
	await _check_orphaned_client("defeat")
	await _check_orphaned_client("extraction")
	await _check_orphaned_client("attunement")
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
	_clear_result()

	var error: Error = transport.call("host", NET_CONFIG.Mode.LOCAL, PORT)
	_check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		return
	child_pid = _spawn_probe(PackedStringArray(["terminal-focus-probe"]))
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
	_report_probe(result, "client")

	transport.call("leave")
	await process_frame
	_reap_child()


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


# ── phase 3 · F-307 · the host leaves while a client sits on a terminal overlay ────────────────────


## The soft-lock, driven literally. The driver hosts, the child joins and opens one terminal overlay
## as a non-host peer, and only then does the driver call `NetTransport.leave()` — the single most
## likely thing a host does once a run has ended. Everything the finding asserts is on the child's
## side, because `_is_host_or_solo()` and `NetSession.session_ended` both read live transport state
## and there is no honest way to fake either from inside one process.
##
## One child per overlay: `session_ended` fires once per session, so a single child cannot exercise
## both `DefeatHud` and `ExtractionHud`. Their two `_refresh_restart_button()` bodies are deliberate
## duplicates (see either file's header), which is exactly why both need proving separately.
func _check_orphaned_client(which: String) -> void:
	# Not "%s summary": F-321's case is the run-START picker, not a run summary. The phase is about
	# the mandatory-panel CLASS, so the label has to name the panel rather than assume its kind.
	print("\n== F-307/F-321 · the host leaves under the %s panel: the screen still has a way out ==" % which)
	result_path = "user://terminal_orphan_%s.json" % which
	result_tmp_path = "%s.tmp" % result_path
	_clear_result()

	var port: int = int(ORPHAN_PORTS[which])
	var error: Error = transport.call("host", NET_CONFIG.Mode.LOCAL, port)
	_check(error == OK, "host starts on port %d" % port)
	if error != OK:
		return
	child_pid = _spawn_probe(PackedStringArray(["terminal-orphan-probe", which]))
	_check(child_pid > 0, "the orphan probe process starts")
	if child_pid <= 0:
		return

	# The child says "ready" only once it is a connected non-host peer sitting on the overlay. Leaving
	# before that would test a peer that never had a host, which is not the finding.
	var ready: bool = await _until(func() -> bool:
		return bool(_read_result().get("ready", false)), TIMEOUT_SEC)
	_check(ready, "the orphan probe reaches the %s summary as a client within %.0fs" % [which, TIMEOUT_SEC])
	if not ready:
		print("  last orphan result: %s" % JSON.stringify(_read_result()))
		_reap_child()
		return

	# The two overlays leave by DIFFERENT paths on purpose, because the fix must hook `session_ended`
	# whatever EndReason produced it. "defeat" uses the path the game actually ships —
	# `NetTransport.leave()`, what `lobby_menu.request_leave()` calls — which tells the client nothing
	# and ends as CONNECTION_LOST once the rejoin ladder gives up. "extraction" uses
	# `NetSession.end_session()`, the documented graceful close, which ends as HOST_CLOSED almost
	# immediately. Fire-and-forget on the coroutine is safe and documented: `net_host_closing.rpc()`
	# goes out before its first await.
	# "extraction" is the only one that takes the graceful close; "defeat" and "attunement" both take
	# `NetTransport.leave()`, the harsher CONNECTION_LOST path that only ends after the rejoin ladder
	# gives up. F-321's new subscriber has to survive that one specifically — it is the shape a host
	# alt-F4 produces, and it is the longest a client can sit believing an answer is still coming.
	if which != "extraction":
		transport.call("leave")
	else:
		var session: Node = root.get_node_or_null(^"NetSession")
		if session == null:
			_fail("the NetSession autoload exists")
			_reap_child()
			return
		session.call(&"end_session")

	var done: bool = await _until(func() -> bool:
		return bool(_read_result().get("done", false)), ORPHAN_TIMEOUT_SEC)
	var result: Dictionary = _read_result()
	_check(done, "the orphan probe reports back within %.0fs of the host leaving" % ORPHAN_TIMEOUT_SEC)
	if not done:
		print("  last orphan result: %s" % JSON.stringify(result))
	else:
		_report_probe(result, "orphaned %s" % which)
	_reap_child()
	await process_frame


func _run_orphan_client(which: String) -> void:
	result_path = "user://terminal_orphan_%s.json" % which
	result_tmp_path = "%s.tmp" % result_path
	if not ORPHAN_PORTS.has(which):
		_write_result({"done": true, "error": "unknown orphan overlay %s" % which})
		_finish()
		return

	var checks: Array = []
	var error: Error = transport.call(
		"join", NET_CONFIG.Mode.LOCAL, NET_CONFIG.LOOPBACK_ADDRESS, int(ORPHAN_PORTS[which]))
	if error != OK:
		_write_result({"done": true, "error": error_string(error)})
		_finish()
		return
	var joined: bool = await _until(
		func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	if not joined or bool(transport.call("is_host")):
		_write_result({"done": true, "error": "orphan probe never connected as a non-host peer"})
		_finish()
		return

	if which == "attunement":
		await _run_orphan_attunement_client(checks)
		return

	var session: Node = root.get_node_or_null(^"NetSession")
	var main_menu: Node = root.get_node_or_null(^"MainMenu")
	var hud_name: String = "DefeatHud" if which == "defeat" else "ExtractionHud"
	var hud: Node = root.get_node_or_null(NodePath(hud_name))
	if session == null or main_menu == null or hud == null:
		_write_result({"done": true, "error": "NetSession, MainMenu and the overlay autoload must exist"})
		_finish()
		return

	# Connected here rather than polling `is_active`, because `session_ended` is the signal the fix is
	# required to hook and it fires only AFTER the rejoin ladder is exhausted (see net_session.gd) —
	# a transport-state poll would fire mid-rejoin, while getting back in is still possible.
	var ended: Dictionary = {"yes": false}
	session.connect(&"session_ended", func(_reason: int, _detail: String) -> void:
		ended["yes"] = true)

	_open_terminal_overlay(which)
	await process_frame

	var button: Button = _find_button(hud)
	checks.append({"ok": button != null, "what": "the summary built its restart control"})
	if button == null:
		_write_result({"done": true, "checks": checks})
		_finish()
		return

	# The "before" half is the state F-243/F-275 shipped and this task must not regress.
	checks.append({
		"ok": button.disabled and button.text == WAITING_LABEL,
		"what": "before the host leaves, the client sees the disabled waiting-on-the-host label",
	})
	checks.append({
		"ok": hud.is_in_group(BLOCKING_UI_GROUP),
		"what": "before the host leaves, the overlay blocks gameplay input (D-032), as F-243 shipped it",
	})
	main_menu.call(&"set_open", true)
	checks.append({
		"ok": not bool(main_menu.call(&"is_open")),
		"what": "before the host leaves, D-032's interlock correctly refuses to open a menu over a live run's overlay",
	})

	_write_result({"ready": true})

	var over: bool = await _until(func() -> bool: return bool(ended["yes"]), ORPHAN_TIMEOUT_SEC)
	checks.append({"ok": over, "what": "NetSession.session_ended fires on the orphaned peer"})
	if not over:
		_write_result({"done": true, "checks": checks})
		_finish()
		return
	await process_frame

	checks.append({
		"ok": _is_host_or_solo(),
		"what": "the orphaned peer's own host predicate now says it may act",
	})
	checks.append({
		"ok": not button.disabled and button.focus_mode == Control.FOCUS_ALL,
		"what": "F-307: the overlay re-reads its host check when the session ends, so the control is operable again",
	})
	checks.append({
		"ok": button.text == LEAVE_LABEL,
		"what": "D-185: the control becomes Leave to Menu, not a restart of a world the dead session already tore down",
	})
	checks.append({
		"ok": not hud.is_in_group(BLOCKING_UI_GROUP),
		"what": "F-307: the overlay leaves blocks_gameplay_input once the session is dead, so a menu can open over it",
	})
	checks.append({
		"ok": _focused() == button,
		"what": "F-307: focus moves to the now-operable control, so F-275's bare-controller rule still holds after the flip",
	})
	# The whole soft-lock in one assertion: a real gamepad ui_accept, through the real input pipeline,
	# gets this peer off the terminal screen and into a menu.
	await _tap(JOY_BUTTON_A)
	checks.append({
		"ok": bool(main_menu.call(&"is_open")),
		"what": "F-307: ui_accept on that control opens the main menu — the terminal screen has a real exit",
	})

	_write_result({"done": true, "checks": checks})
	_finish()


## F-321's half of phase 3. Same driver, same host-leaves seam, different panel and therefore a
## different set of assertions — `AttunementUI` has no restart button to re-enable, so what has to be
## true afterwards is that the panel is GONE and the interlock it held is released.
##
## The picker is opened through its real trigger, not by calling `_open_picker()`: D-071 opens it off
## the first `&"players"` group member this peer has authority over, so a stand-in Node3D in that
## group is the whole prerequisite, and `poll_now()` is the file's own seam for running that poll
## immediately instead of waiting out POLL_INTERVAL_SEC.
##
## The `choose()` in the middle matters and is not padding. It puts the panel in exactly the state
## the finding describes — `_picking` latched, every button disabled, an 8 s timer running against a
## host that is about to vanish — so what this proves is not "a freshly-opened panel closes" but "the
## panel closes out of the latched state that used to loop forever".
func _run_orphan_attunement_client(checks: Array) -> void:
	var session: Node = root.get_node_or_null(^"NetSession")
	var main_menu: Node = root.get_node_or_null(^"MainMenu")
	var picker: Node = root.get_node_or_null(^"AttunementUI")
	if session == null or main_menu == null or picker == null:
		_write_result({"done": true, "error": "NetSession, MainMenu and AttunementUI must all exist"})
		_finish()
		return

	var ended: Dictionary = {"yes": false}
	session.connect(&"session_ended", func(_reason: int, _detail: String) -> void:
		ended["yes"] = true)

	# D-071's real open condition: a body in the players group that THIS peer has authority over.
	var body := Node3D.new()
	body.name = "OrphanProbePlayer"
	body.add_to_group(&"players")
	body.set_multiplayer_authority(get_multiplayer().get_unique_id())
	root.add_child(body)
	picker.call(&"poll_now")
	await process_frame

	checks.append({
		"ok": bool(picker.get("_open")),
		"what": "the picker opens for the joined client, so this is the real panel and not a stand-in",
	})
	checks.append({
		"ok": picker.is_in_group(BLOCKING_UI_GROUP),
		"what": "before the host leaves, the picker blocks gameplay input (D-032), as task 3.9 shipped it",
	})
	main_menu.call(&"set_open", true)
	checks.append({
		"ok": not bool(main_menu.call(&"is_open")),
		"what": "before the host leaves, D-032's interlock correctly refuses a menu over the live picker",
	})

	# Latch it, exactly as a player pressing CHOOSE the instant before the host quits would.
	picker.call(&"choose", &"warden")
	checks.append({
		"ok": bool(picker.get("_picking")),
		"what": "the request latches _picking and disables the buttons — F-297's bounded wait, armed",
	})

	_write_result({"ready": true})

	var over: bool = await _until(func() -> bool: return bool(ended["yes"]), ORPHAN_TIMEOUT_SEC)
	checks.append({"ok": over, "what": "NetSession.session_ended fires on the orphaned peer"})
	if not over:
		_write_result({"done": true, "checks": checks})
		_finish()
		return
	await process_frame

	checks.append({
		"ok": not bool(picker.get("_open")),
		"what": "F-321: the picker closes when the session ends — there is no run left to pick for (D-185)",
	})
	checks.append({
		"ok": not bool(picker.get("_picking")),
		"what": "F-321: the pending request is cleared, so the 8 s timer cannot re-arm the loop it used to",
	})
	checks.append({
		"ok": not picker.is_in_group(BLOCKING_UI_GROUP),
		"what": "F-321: the picker leaves blocks_gameplay_input, which is what actually frees the player",
	})
	checks.append({
		"ok": Input.mouse_mode == Input.MOUSE_MODE_VISIBLE,
		"what": "F-321: the cursor stays visible — gameplay is gone, so re-capturing it would hide the pointer the player needs",
	})
	# The soft-lock in one assertion: the thing that was impossible for the whole run is now possible.
	main_menu.call(&"set_open", true)
	checks.append({
		"ok": bool(main_menu.call(&"is_open")),
		"what": "F-321: the main menu opens over the dead session — the orphaned client has a way out",
	})

	_write_result({"done": true, "checks": checks})
	_finish()


## Both overlays are client-local presentation (ARCHITECTURE.md §2.2 "VFX, audio, camera, UI"), so
## each opens through its own real trigger with no host traffic involved — same as phase 2.
func _open_terminal_overlay(which: String) -> void:
	if which == "defeat":
		defeat_service.set(&"cause", &"team_wipe")
		defeat_service.set(&"defeated", true)
		return
	EVENT_BUS.emit_run_extracted(3, Vector3.ZERO)


## The same predicate both HUDs run, so the check asserts the peer's own claim rather than a
## restatement of it.
func _is_host_or_solo() -> bool:
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


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


func _spawn_probe(probe_args: PackedStringArray) -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/terminal_focus_check.gd", "--",
	])
	args.append_array(probe_args)
	return OS.create_process(OS.get_executable_path(), args)


## Every phase hosts on its own port, but they all share one process's transport, so a child that
## outlives its phase would still be holding a connection when the next phase starts hosting.
func _reap_child() -> void:
	if child_pid > 0 and OS.is_process_running(child_pid):
		OS.kill(child_pid)
	child_pid = 0


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _write_result(result: Dictionary) -> void:
	var file := FileAccess.open(result_tmp_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(result_tmp_path), ProjectSettings.globalize_path(result_path))


func _read_result() -> Dictionary:
	if not FileAccess.file_exists(result_path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(result_path))
	return parsed if parsed is Dictionary else {}


func _clear_result() -> void:
	if FileAccess.file_exists(result_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(result_path))


## Reports one probe's collected rows, whichever phase produced them.
func _report_probe(result: Dictionary, prefix: String) -> void:
	if result.has("error"):
		_fail("%s: %s" % [prefix, String(result["error"])])
	for entry: Variant in result.get("checks", []):
		var row: Dictionary = entry as Dictionary
		_check(bool(row.get("ok", false)), "%s: %s" % [prefix, String(row.get("what", ""))])


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
