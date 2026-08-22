extends SceneTree

## F-277 · a restarted run gives every player their Attunement pick back.
## F-297 · the mandatory picker's in-flight request is a bounded wait, not a latch.
##
## Phase 1 (solo, shipped `levels/hollowmere.tscn`): open the real run-start picker, pick a role,
## prove the pick locked, then drive the real terminal-to-restart path
## (`DefeatService.defeated` -> `CycleService.host_restart_run()`) and assert the next run is
## genuinely pickable again — the selection cleared, the PowerupService stack it granted gone with
## it, the picker reopened with all four CHOOSE buttons operable and one of them focused (F-216's
## no-mouse guarantee has to survive into run two as well), and a DIFFERENT role acceptable. The
## no-op case is asserted too, because `host_clear_all()` runs on every restart forever.
##
## Phase 2 (two processes): the fix is host-authoritative — the host clears and broadcasts, each peer
## re-arms its own picker — and that half is exactly what one process cannot see. A really joined
## client picks over the wire, the host restarts, and the client reports whether ITS selection
## cleared and ITS picker reopened; then it picks a second, different role over the wire, which is
## what proves the host's "already selected" lock actually lifted for a remote peer rather than just
## locally. The client also owns the F-297 sub-phase, because the only honest way to produce an
## unanswered `request_select()` is the finding's own scenario: send it, then lose the host.
##
##   .agent/bin/agent godot --script tools/attunement_restart_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const NET_CONFIG := preload("res://core/net/net_config.gd")

const PORT: int = 47457
const RESULT_PATH: String = "user://attunement_restart_client.json"
const STEP_PATH: String = "user://attunement_restart_step.json"
const SCENE_PATH: String = "res://levels/hollowmere.tscn"
const TIMEOUT_SEC: float = 25.0

## The two roles phase 1 picks, in order. Deliberately different: picking the SAME id twice would
## pass against a fix that cleared the lock but left the old id in place.
const FIRST_ROLE: StringName = &"forager"
const SECOND_ROLE: StringName = &"reaver"
const FIRST_POWERUP: StringName = &"attunement_forager"
const SECOND_POWERUP: StringName = &"attunement_reaver"

## Phase 2's handshake. The driver writes the step; the client acts on the transition and reports it
## back in `step_done`, so neither side has to guess at timing.
const STEP_PICK_FIRST: int = 1
const STEP_PICK_SECOND: int = 2
const STEP_EXPIRE: int = 3

var failures: int = 0
var transport: Node
var attunement: Node
var attunement_ui: Node
var powerups: Node
var cycle_service: Node
var defeat_service: Node
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	attunement = root.get_node_or_null(^"AttunementService")
	attunement_ui = root.get_node_or_null(^"AttunementUI")
	powerups = root.get_node_or_null(^"PowerupService")
	cycle_service = root.get_node_or_null(^"CycleService")
	defeat_service = root.get_node_or_null(^"DefeatService")
	if (transport == null or attunement == null or attunement_ui == null or powerups == null
			or cycle_service == null or defeat_service == null):
		_fail("NetTransport, AttunementService, AttunementUI, PowerupService, CycleService and"
			+ " DefeatService autoloads must exist")
		_finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "attunement-restart-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	await _run_solo()
	await _run_networked()
	print("ATTUNEMENT_RESTART_CHECK failures=%d" % failures)
	_finish()


# ── Phase 1 · solo ───────────────────────────────────────────────────────────────────────────────


func _run_solo() -> void:
	print("\n== F-277 PHASE 1 · a restart hands the Attunement pick back ==")
	var level: Node = await _load_level()
	if level == null:
		return

	_check(EVENT_BUS.run_restarted_subscriber_count() > 0,
		"run_restarted has subscribers once the map is wired")
	_check(attunement.has_method(&"host_clear_all"),
		"AttunementService exposes the host_clear_all() run-boundary seam")

	# Nothing has been picked, so the seam must be a no-op — a clear that "succeeds" on a fresh
	# session would hide a fix that reports work it never did.
	_check(_seam_int(attunement, &"host_clear_all", -1) == 0,
		"host_clear_all() clears nothing before anybody has picked")

	attunement_ui.call("poll_now")
	await process_frame
	_check(bool(attunement_ui.call("is_open")), "the run-start picker opens for run one")
	_check(int(attunement_ui.call("role_button_count")) == 4,
		"all four roles are offered (%d)" % int(attunement_ui.call("role_button_count")))

	await _pick(FIRST_ROLE)
	_check(StringName(attunement.call("local_selection")) == FIRST_ROLE,
		"run one's pick is recorded (%s)" % attunement.call("local_selection"))
	_check(not bool(attunement_ui.call("is_open")), "the picker closes once the pick is accepted")
	_check(_local_stacks(FIRST_POWERUP) == 1,
		"the pick granted its backing powerup stack (%d)" % _local_stacks(FIRST_POWERUP))

	# The lock itself still has to work WITHIN a run — F-277 is about it outliving the run, not about
	# removing it. D-071's one-pick-per-run rule is what this asserts.
	attunement.call("request_select", SECOND_ROLE)
	await process_frame
	_check(StringName(attunement.call("local_selection")) == FIRST_ROLE,
		"a second pick inside the same run is still refused")

	# The real ending -> restart path, not a bare EVENT_BUS.emit_run_restarted() shortcut: a check
	# that fires the event itself proves the subscriber, not that the shipped restart reaches it
	# (F-291).
	await _restart_run()

	_check(StringName(attunement.call("local_selection")) == &"",
		"the restart cleared the selection (%s)" % attunement.call("local_selection"))
	_check((attunement.call("all_selections") as Dictionary).is_empty(),
		"the restart cleared EVERY peer's selection, not just the local one")
	_check(_local_stacks(FIRST_POWERUP) == 0,
		"the Attunement's powerup stack went with it (%d)" % _local_stacks(FIRST_POWERUP))
	_check(bool(attunement_ui.call("is_open")), "the picker reopens for run two")
	_check(int(attunement_ui.call("role_button_count")) == 4,
		"run two offers all four roles again (%d)" % int(attunement_ui.call("role_button_count")))
	var operable: int = _seam_int(attunement_ui, &"operable_button_count", -1)
	_check(operable == 4, "every CHOOSE button is operable in run two (%d)" % operable)
	# F-216: this panel has no dismiss path, so a focused button is what makes run two reachable at
	# all for a player with no mouse. A reopen that forgets the grab is the F-275 failure again.
	_check(_focused_is_role_button(),
		"a CHOOSE button holds focus in run two, so a bare controller can answer (%s)"
			% _focused_name())
	_check(not _seam_bool(attunement_ui, &"is_picking", true),
		"no stale in-flight request survives into run two")

	await _pick(SECOND_ROLE)
	_check(StringName(attunement.call("local_selection")) == SECOND_ROLE,
		"run two accepts a DIFFERENT role (%s)" % attunement.call("local_selection"))
	_check(_local_stacks(SECOND_POWERUP) == 1,
		"run two's pick granted its own backing powerup (%d)" % _local_stacks(SECOND_POWERUP))
	_check(_local_stacks(FIRST_POWERUP) == 0, "run one's powerup did not come back with it")

	# A second restart, then an immediate re-clear: the handler runs on every restart forever, so it
	# must report honestly rather than claiming work it did not do.
	await _restart_run()
	_check(_seam_int(attunement, &"host_clear_all", -1) == 0,
		"a restart leaves nothing for a second host_clear_all() to clear")

	await _teardown_level(level)


func _pick(role_id: StringName) -> void:
	attunement_ui.call("choose", role_id)
	await process_frame
	await process_frame


## Drives the shipped ending, then the shipped restart, then lets the deferred re-arm land — the
## picker reopens on a deferred call so it cannot sample the terminal overlay's cursor mode (see
## `attunement_ui.gd::_rearm_for_new_run`).
func _restart_run() -> void:
	defeat_service.set(&"defeated", true)
	await process_frame
	var cycle: int = int(cycle_service.call("host_restart_run"))
	_check(cycle == 1, "the restart returns the run to Cycle 1")
	for _index: int in 4:
		await process_frame
	await physics_frame


## Offline, `local_peer_id()` is 0 and AttunementService falls back to HOST_PEER_ID — mirror that
## fallback here or phase 1 would ask PowerupService about a peer nobody ever granted anything to.
func _local_peer_id() -> int:
	var peer_id: int = int(transport.call("local_peer_id"))
	return peer_id if peer_id > 0 else NET_CONFIG.HOST_PEER_ID


func _local_stacks(powerup_id: StringName) -> int:
	return int(powerups.call("stacks_of", _local_peer_id(), powerup_id))


func _focused_is_role_button() -> bool:
	var focused: Control = _focused()
	return focused is Button and (focused as Button).text == "CHOOSE"


func _focused_name() -> String:
	var focused: Control = _focused()
	return "none" if focused == null else String(focused.get_path())


func _focused() -> Control:
	var viewport: Viewport = root.get_viewport()
	return null if viewport == null else viewport.gui_get_focus_owner()


# ── Phase 2 · a real connected client ────────────────────────────────────────────────────────────


func _run_networked() -> void:
	print("\n== F-277 PHASE 2 · a joined client gets its own pick back ==")
	_remove_files()
	_write_step(0)
	var level: Node = await _load_level()
	if level == null:
		return

	var error: Error = transport.call("host", NET_CONFIG.Mode.LOCAL, PORT)
	_check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		await _teardown_level(level)
		return
	await process_frame
	child_pid = _spawn_client()
	_check(child_pid > 0, "client process launches")

	var armed: bool = await _until(func() -> bool: return _client_bool("armed"), TIMEOUT_SEC)
	_check(armed, "client connects and reports its own peer id")
	if not armed:
		await _teardown_level(level)
		return
	var client_peer: int = int(_read_result().get("peer_id", 0))
	_check(client_peer > 1, "the client has a real remote peer id (%d)" % client_peer)

	_check(_client_bool("ui_open"), "the client's own run-start picker is open in run one")

	# ── Run one's pick, made over the wire ───────────────────────────────────────────────────────
	_write_step(STEP_PICK_FIRST)
	var picked: bool = await _until(
		func() -> bool: return StringName(attunement.call("selection_of", client_peer)) == FIRST_ROLE,
		TIMEOUT_SEC)
	_check(picked, "the host records the client's pick (%s)"
		% attunement.call("selection_of", client_peer))
	_check(await _until(func() -> bool: return not _client_bool("ui_open"), TIMEOUT_SEC),
		"the client's picker closes on the host's confirmation")
	_check(int(powerups.call("stacks_of", client_peer, FIRST_POWERUP)) == 1,
		"the host granted the client's backing powerup")

	# ── The restart, and the client half of the fix ──────────────────────────────────────────────
	await _restart_run()
	_check((attunement.call("all_selections") as Dictionary).is_empty(),
		"the host holds no selections after the restart")
	_check(await _until(
			func() -> bool: return String(_read_result().get("local_selection", "x")) == "",
			TIMEOUT_SEC),
		"the client's own mirror of its selection cleared over the wire")
	_check(await _until(func() -> bool: return _client_bool("ui_open"), TIMEOUT_SEC),
		"the client's picker REOPENS for run two — the half a solo check cannot see")

	# ── Run two's pick, also over the wire: proves the host's lock really lifted for a remote peer ─
	_write_step(STEP_PICK_SECOND)
	var repicked: bool = await _until(
		func() -> bool: return StringName(attunement.call("selection_of", client_peer)) == SECOND_ROLE,
		TIMEOUT_SEC)
	_check(repicked, "the host accepts the client's SECOND-run pick (%s)"
		% attunement.call("selection_of", client_peer))
	_check(int(powerups.call("stacks_of", client_peer, SECOND_POWERUP)) == 1,
		"run two's powerup reached the client's stacks on the host")
	_check(int(powerups.call("stacks_of", client_peer, FIRST_POWERUP)) == 0,
		"run one's powerup did not survive the restart on the host either")

	# ── F-297 · the bounded wait, in the finding's own scenario ──────────────────────────────────
	await _restart_run()
	_check(await _until(func() -> bool: return _client_bool("ui_open"), TIMEOUT_SEC),
		"the client's picker reopens a third time — the re-arm is not one-shot")
	_write_step(STEP_EXPIRE)
	var expired: bool = await _until(
		func() -> bool: return int(_read_result().get("step_done", 0)) == STEP_EXPIRE, TIMEOUT_SEC)
	_check(expired, "the client completed the F-297 lost-host sub-phase")
	if expired:
		var result: Dictionary = _read_result()
		_check(float(result.get("wait_armed_sec", 0.0)) > 0.0,
			"an unanswered request arms a real bounded wait (%.2fs)"
				% float(result.get("wait_armed_sec", 0.0)))
		_check(int(result.get("operable_after_expiry", -1)) == 4,
			"every CHOOSE button is operable again once the wait expires (%d)"
				% int(result.get("operable_after_expiry", -1)))
		_check(not bool(result.get("picking_after_expiry", true)),
			"the expired request no longer holds the panel")
		_check(bool(result.get("status_is_error", false)),
			"the panel says why, instead of silently re-enabling")
		# F-321, asserted here because this is the only two-process harness that has a client whose
		# session ends while a mandatory panel is up.
		_check(bool(result.get("closed_after_session_end", false)),
			"ending the session CLOSES the picker rather than leaving it up over a dead run")
		_check(not bool(result.get("blocking_after_session_end", true)),
			"and releases the blocking-UI interlock, so the orphan can reach the main menu")

	_check(int(_read_result().get("failures", -1)) == 0, "client self-checks report 0 failures")
	await _teardown_level(level)


func _client_bool(key: String) -> bool:
	return bool(_read_result().get(key, false))


# ── The client process ───────────────────────────────────────────────────────────────────────────


## Loads the SAME map before joining, for the same reason harvest_restart_check's client does: the
## picker's D-071 trigger is "the local player's own body exists", and without a level there is no
## body and the phase would prove nothing.
func _run_client() -> void:
	_write_result({"armed": false})
	var level: Node = await _load_level()
	if level == null:
		_write_result({"error": "client could not load the map"})
		_finish()
		return
	var error: Error = transport.call(
		"join", NET_CONFIG.Mode.LOCAL, NET_CONFIG.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		_finish()
		return
	_client_drive()


func _client_drive() -> void:
	var joined: bool = await _until(
		func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	if not joined:
		_write_result({"error": "client never connected"})
		_finish()
		return
	var client_failures: int = 0
	if bool(transport.call("is_host")):
		client_failures += 1

	var handled: int = 0
	var extra: Dictionary = {}
	var deadline_msec: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 3.0 * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		var step: int = _read_step()
		if step > handled:
			# A client must never write a selection itself. If this peer's own copy could clear or
			# record one locally the whole phase would pass for the wrong reason, so assert the
			# host-guard holds here before doing anything else.
			if _seam_int(attunement, &"host_clear_all", 0) != 0:
				client_failures += 1
			handled = step
			extra = await _client_step(step, extra)
		_write_result({
			"armed": true,
			"peer_id": int(transport.call("local_peer_id")),
			"local_selection": String(attunement.call("local_selection")),
			"ui_open": bool(attunement_ui.call("is_open")),
			"failures": client_failures,
			"step_done": handled,
			"wait_armed_sec": extra.get("wait_armed_sec", 0.0),
			"operable_after_expiry": extra.get("operable_after_expiry", -1),
			"picking_after_expiry": extra.get("picking_after_expiry", true),
			"status_is_error": extra.get("status_is_error", false),
			"closed_after_session_end": extra.get("closed_after_session_end", false),
			"blocking_after_session_end": extra.get("blocking_after_session_end", true),
		})
		if handled == STEP_EXPIRE:
			# The sub-phase ends with this peer deliberately disconnected; keep reporting the final
			# document but stop touching the session.
			await create_timer(0.05).timeout
			continue
		await create_timer(0.05).timeout
	_finish()


func _client_step(step: int, extra: Dictionary) -> Dictionary:
	match step:
		STEP_PICK_FIRST:
			attunement_ui.call("choose", FIRST_ROLE)
		STEP_PICK_SECOND:
			attunement_ui.call("choose", SECOND_ROLE)
		STEP_EXPIRE:
			# F-297: an unanswered request arms a BOUNDED wait, and the panel recovers when it runs
			# out — on a picker with no dismiss path that is the difference between a slow host and a
			# soft-lock.
			#
			# This sub-phase used to strand the request by calling `transport.leave()` and reading the
			# seams afterwards. That stopped proving anything the moment F-321 landed: `leave()` ends
			# the session, and `_on_session_ended()` now stops the request timer, clears `_picking`
			# and CLOSES the picker outright (D-185's call — there is no run left to pick for). So
			# every read came back from a shut panel — `wait_armed_sec` 0.0 because the timer was
			# stopped, `operable_button_count` 0 because the buttons were never re-enabled on the way
			# out — and three assertions have been red at HEAD ever since, describing a scenario the
			# code deliberately no longer has (F-551).
			#
			# Both behaviours are right; they are just different scenarios. F-297's is "the host is
			# still there and does not answer", so it is exercised in-session, with NO await between
			# the request and the expiry — the host's real reply is a network round trip away and
			# must not be allowed to race the seam. F-321's is asserted separately below, where the
			# session really does end.
			attunement_ui.call("choose", &"warden")
			extra = {
				"wait_armed_sec": _seam_float(attunement_ui, &"pending_request_seconds_left", 0.0),
				"operable_after_expiry": -1,
				"picking_after_expiry": true,
				"status_is_error": false,
				"closed_after_session_end": false,
				"blocking_after_session_end": true,
			}
			# The wait is real (asserted above); run it out now rather than stalling the check for
			# REQUEST_TIMEOUT_SEC, through the same debug seam poll_now() uses.
			if attunement_ui.has_method(&"expire_pending_request_now"):
				attunement_ui.call("expire_pending_request_now")
			extra["operable_after_expiry"] = _seam_int(attunement_ui, &"operable_button_count", -1)
			extra["picking_after_expiry"] = _seam_bool(attunement_ui, &"is_picking", true)
			extra["status_is_error"] = String(attunement_ui.call("status_text")).contains("No answer")

			# F-321, in the same breath: ending the session closes the picker and releases D-032's
			# blocking-UI interlock, which is what gives an orphaned client its way back to the menu.
			transport.call("leave")
			await process_frame
			extra["closed_after_session_end"] = not bool(attunement_ui.call("is_open"))
			extra["blocking_after_session_end"] = attunement_ui.is_in_group(&"blocks_gameplay_input")
	return extra


# ── Harness ──────────────────────────────────────────────────────────────────────────────────────


func _load_level() -> Node:
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	_check(packed != null, "the shipped map loads")
	if packed == null:
		return null
	var level: Node = packed.instantiate()
	root.add_child(level)
	current_scene = level
	for _index: int in 30:
		await process_frame
		await physics_frame
	return level


func _teardown_level(level: Node) -> void:
	if transport != null and bool(transport.call("is_active")):
		transport.call("leave")
	current_scene = null
	root.remove_child(level)
	level.free()
	await process_frame


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/attunement_restart_check.gd",
		"--", "attunement-restart-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


## F-290: written to a sibling path and RENAMED into place. The child rewrites this file every 50 ms
## while the parent polls it, and a plain truncate-then-write hands the reader a half document, which
## `JSON.parse_string` reports as an ERROR line. A rename is atomic.
func _write_json(path: String, value: Dictionary) -> void:
	var staging: String = path + ".part"
	var file := FileAccess.open(staging, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(value))
	file.close()
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(staging), ProjectSettings.globalize_path(path))


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var raw: String = FileAccess.get_file_as_string(path)
	if raw.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(raw)
	return parsed if parsed is Dictionary else {}


func _write_result(result: Dictionary) -> void:
	_write_json(RESULT_PATH, result)


func _read_result() -> Dictionary:
	return _read_json(RESULT_PATH)


func _write_step(step: int) -> void:
	_write_json(STEP_PATH, {"step": step})


func _read_step() -> int:
	return int(_read_json(STEP_PATH).get("step", 0))


func _remove_files() -> void:
	for path: String in [RESULT_PATH, RESULT_PATH + ".part", STEP_PATH, STEP_PATH + ".part"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## F-275's lesson, applied to the harness itself: a check that calls a seam the fix ADDS aborts its
## own coroutine when run against a build that lacks it, so the pre-fix proof shows three assertions
## and stops instead of showing the finding's symptoms. These wrappers degrade to a sentinel and let
## the run continue, so "does this check actually catch the bug" has an answer.
func _seam_int(node: Node, method: StringName, fallback: int) -> int:
	return int(node.call(method)) if node.has_method(method) else fallback


func _seam_float(node: Node, method: StringName, fallback: float) -> float:
	return float(node.call(method)) if node.has_method(method) else fallback


func _seam_bool(node: Node, method: StringName, fallback: bool) -> bool:
	return bool(node.call(method)) if node.has_method(method) else fallback


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  PASS  %s" % label)
	else:
		_fail(label)


func _fail(label: String) -> void:
	failures += 1
	print("  FAIL  %s" % label)


func _finish() -> void:
	if child_pid > 0 and OS.is_process_running(child_pid):
		OS.kill(child_pid)
	quit(1 if failures > 0 else 0)
