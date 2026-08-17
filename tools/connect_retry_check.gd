extends SceneTree

## Connect budget, timeout classification and first-join retry check (F-023). Real ENet, real
## processes, no editor:
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/connect_retry_check.gd
##
## EXPECTED ENGINE ERRORS (F-052 triage): this check deliberately provokes a connect timeout and an
## out-of-range port, and production code correctly reports both via `MireLog.error` → `push_error`.
## Declared by PATTERN in the verdict line; rule 4's grader ignores matching `ERROR:` lines and
## fails on anything else:
##   grep 'ERROR:' | grep -vE 'connect to .* timed out|is outside 1024..65535' | wc -l   → must be 0
##
## Exits non-zero on failure. Takes about 15 seconds — most of it one real 3 s LOCAL timeout, which is
## the point: the classification it checks is produced by the watchdog actually firing, not asserted.
##
## WHAT THIS PROVES, AND WHAT IT CANNOT. F-023 happens on Windows, over Steam, against a live lobby.
## None of those exist in a headless macOS probe, so this covers the whole mechanism around the
## Steam-specific branch and is deliberately explicit about the hole:
##
##   proved here   the per-mode budget table · that an expired deadline is classified CONNECT_TIMEOUT
##                 and not CONNECT_FAILED · that a synchronous failure does not inherit the previous
##                 attempt's ending · that a successful connect records its own duration · that
##                 NetSession declines to retry a mode whose retry it does not own
##
##   NOT proved    that the Steam retry recovers a real rendezvous, or that 20 s is the right budget.
##                 Both need task 1.12's physical run. The "connected … in N.NNs" line this adds to
##                 every join is what turns that run into the measurement nobody has taken yet.

const HOST_PORT: int = 47421

## Nothing is ever bound here. A closed loopback port is silent to ENet rather than refused — ENet
## does not act on ICMP — so the attempt runs to our own deadline, which is exactly the path a player
## takes when they forget to start the host first.
const DEAD_PORT: int = 47422

## Well under ENet's own connect timeout, so the deadline that expires is unambiguously ours.
const TIMEOUT_WAIT_SEC: float = 6.0

const CHILD_UP_TIMEOUT_SEC: float = 20.0
const CONNECT_WAIT_SEC: float = 10.0

## A stranded host child must not outlive the run that spawned it.
const CHILD_LIFETIME_SEC: float = 45.0

var _failures: int = 0
var _transport: Node
var _session: Node
var _host_pid: int = 0

## EndKind is an enum on the NetTransport script, and a --script main loop cannot name the autoload as
## a compile-time identifier to reach it (F-011). Read it off the script resource instead: same
## values, resolves here and in the running game alike, and it cannot drift from the enum the way a
## hand-mirrored copy of the ordinals would.
var _end_kind: Dictionary = {}

# Observed from NetTransport, so the checks read what the game would have heard rather than internals.
var _failure_reasons: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	# NOTHING may touch the autoloads from _initialize: they are children of root already but have not
	# ENTERED the tree, so node.multiplayer is still null and a join() here sets a peer on nothing,
	# prints one error and returns OK anyway (F-011, and the trap DELEGATION records). One deferred
	# frame is the fix.
	_start.call_deferred()


func _start() -> void:
	await process_frame
	if not _autoloads():
		print("autoloads missing — NetTransport / NetSession")
		quit(1)
		return

	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() >= 1 and args[0] == "host-probe":
		_run_host_probe()
		return
	_run_driver()


## Autoloads are not compile-time identifiers in a --script main loop (F-011) — the entry script is
## compiled before [autoload] is bootstrapped. Look them up off root.
func _autoloads() -> bool:
	_transport = root.get_node_or_null(^"NetTransport")
	_session = root.get_node_or_null(^"NetSession")
	if _transport != null:
		var script: GDScript = _transport.get_script() as GDScript
		if script != null:
			_end_kind = script.get_script_constant_map().get("EndKind", {})
	return _transport != null and _session != null and not _end_kind.is_empty()


func _kind(name: StringName) -> int:
	return int(_end_kind.get(name, -1))


# ── The host child ────────────────────────────────────────────────────────────────────────────────


## Hosts and idles. It exists only so the driver has something real to connect to, because one process
## has one root MultiplayerAPI and cannot be both ends of its own ENet session.
func _run_host_probe() -> void:
	var err: Error = _transport.host(NetConfig.Mode.LOCAL, HOST_PORT)
	if err != OK:
		quit(1)
		return
	await create_timer(CHILD_LIFETIME_SEC).timeout
	quit(0)


# ── Driver ────────────────────────────────────────────────────────────────────────────────────────


func _run_driver() -> void:
	print("\n== connect budget and first-join retry (F-023) ==")
	_transport.connection_failed.connect(func(reason: String) -> void: _failure_reasons.append(reason))

	_check_budget_table()
	await _check_successful_connect_is_measured()
	await _check_timeout_is_classified_and_not_retried()
	await _check_synchronous_failure_does_not_inherit_a_timeout()

	if _host_pid != 0:
		OS.kill(_host_pid)

	print("\n%s — %d failure(s) · EXPECTED_ERROR_PATTERNS=\"connect to .* timed out|is outside 1024..65535\"\n"
		% ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(1 if _failures > 0 else 0)


## Section 1. Pure table, no I/O. The last check is the one that matters most: it is the reason
## NetSession's rejoin backstop had to stop hard-coding the ENet number.
func _check_budget_table() -> void:
	print("\n-- per-mode connect budget --")
	_check("LOCAL fails fast", is_equal_approx(
		_transport.connect_timeout_sec(NetConfig.Mode.LOCAL), NetConfig.LOCAL_CONNECT_TIMEOUT_SEC
	), "%.1fs" % NetConfig.LOCAL_CONNECT_TIMEOUT_SEC)
	_check("LAN keeps the ENet budget", is_equal_approx(
		_transport.connect_timeout_sec(NetConfig.Mode.LAN), NetConfig.CONNECT_TIMEOUT_SEC
	), "%.1fs" % NetConfig.CONNECT_TIMEOUT_SEC)
	_check("STEAM has a budget of its own", is_equal_approx(
		_transport.connect_timeout_sec(NetConfig.Mode.STEAM), NetConfig.STEAM_CONNECT_TIMEOUT_SEC
	), "%.1fs — a rendezvous, not a slower socket" % NetConfig.STEAM_CONNECT_TIMEOUT_SEC)

	# If this ever fails, the mode-derived backstop in NetSession._await_connect_result has stopped
	# being load-bearing and the flat constant would be safe again. It is not, today.
	_check("the STEAM budget outlasts the old flat backstop",
		NetConfig.STEAM_CONNECT_TIMEOUT_SEC > NetConfig.CONNECT_TIMEOUT_SEC + 2.0,
		"%.1fs > %.1fs, so a hard-coded backstop would cancel live attempts" % [
			NetConfig.STEAM_CONNECT_TIMEOUT_SEC, NetConfig.CONNECT_TIMEOUT_SEC + 2.0
		])


## Section 2. The instrumentation, against a real handshake. This is the number the whole finding
## turned out to be missing, so a harness that did not produce one would be missing the point.
func _check_successful_connect_is_measured() -> void:
	print("\n-- a successful connect records how long it took --")
	_check("no measurement before the first connect", int(_transport.last_connect_msec()) == -1)

	_host_pid = _spawn_host()
	if _host_pid == 0:
		_check("host child launched", false, "OS.create_process returned 0")
		return
	# The child has to be listening before we knock; LOCAL's budget is 3 s and would expire otherwise.
	await create_timer(3.0).timeout

	_transport.join(NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, HOST_PORT)
	var connected: bool = await _until(func() -> bool: return bool(_transport.is_active()), CONNECT_WAIT_SEC)
	_check("connected to the host child", connected)
	if not connected:
		return

	var elapsed: int = int(_transport.last_connect_msec())
	_check("the connect duration was recorded", elapsed >= 0, "%d ms" % elapsed)
	_check("and it is inside the budget it was measured against",
		elapsed < int(NetConfig.LOCAL_CONNECT_TIMEOUT_SEC * 1000.0),
		"%d ms < %d ms" % [elapsed, int(NetConfig.LOCAL_CONNECT_TIMEOUT_SEC * 1000.0)])

	_transport.leave()
	await process_frame


## Section 3. The classification split, produced by a deadline actually expiring — and the policy
## check that goes with it.
func _check_timeout_is_classified_and_not_retried() -> void:
	print("\n-- an expired deadline is a timeout, not a refusal --")
	_failure_reasons.clear()

	_transport.join(NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, DEAD_PORT)
	var resolved: bool = await _until(
		func() -> bool: return not bool(_transport.is_connecting()), TIMEOUT_WAIT_SEC
	)
	_check("the attempt resolved", resolved)

	var kind: int = int(_transport.last_end_kind())
	_check("classified CONNECT_TIMEOUT, not CONNECT_FAILED",
		kind == _kind(&"CONNECT_TIMEOUT"),
		"end kind %d — only a timeout is worth asking again" % kind)
	_check("the failure reached listeners", _failure_reasons.size() >= 1,
		_failure_reasons[0] if _failure_reasons.size() >= 1 else "nothing emitted")
	_check("a timeout does not fabricate a measurement", int(_transport.last_connect_msec()) == -1)

	# NetSession retries STEAM only, because only a timed-out STEAM attempt is still holding the lobby
	# membership its retry depends on. LOCAL and LAN first joins belong to DevLaunch — see F-024.
	await process_frame
	await process_frame
	_check("NetSession did not retry a LOCAL first join", not bool(_session.is_connect_retrying()),
		"LOCAL/LAN retry is DevLaunch's, and two loops would double every attempt")
	_check("the retry policy is on by default", bool(_session.auto_connect_retry))


## Section 4. The trap found while writing this file: before host()/join() cleared it up front, a
## synchronous failure kept the LAST attempt's ending, so the guard above would have retried a call
## that never opened a socket. Section 3 leaves a CONNECT_TIMEOUT standing, which is what makes this
## a real test rather than a tautology.
func _check_synchronous_failure_does_not_inherit_a_timeout() -> void:
	print("\n-- a synchronous failure is not a timeout --")
	_check("a CONNECT_TIMEOUT is standing going in",
		int(_transport.last_end_kind()) == _kind(&"CONNECT_TIMEOUT"))

	# Rejected on the port check, before any socket exists.
	var err: Error = _transport.join(NetConfig.Mode.LAN, "192.0.2.1", NetConfig.PORT_MAX + 1)
	_check("the call failed synchronously", err != OK, error_string(err))
	_check("and cleared the previous ending",
		int(_transport.last_end_kind()) == _kind(&"NONE"),
		"end kind %d" % int(_transport.last_end_kind()))

	await process_frame
	await process_frame
	_check("so nothing retried it", not bool(_session.is_connect_retrying()))


# ── Plumbing ──────────────────────────────────────────────────────────────────────────────────────


func _spawn_host() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args: PackedStringArray = PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/connect_retry_check.gd",
		"--", "host-probe",
	])
	var pid: int = OS.create_process(OS.get_executable_path(), args)
	print("  ↳ launched host child as pid %d" % pid)
	return pid


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s%s" % [label, ("  — " + detail) if detail != "" else ""])
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


## Poll rather than await a signal: every wait here has a real deadline, and a signal that never
## fires has to fail its check instead of hanging the harness.
func _until(condition: Callable, timeout_sec: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await create_timer(0.1).timeout
	return bool(condition.call())
