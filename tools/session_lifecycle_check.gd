extends SceneTree

## Connection lifecycle check (task 1.7). Real processes, real ENet, no editor:
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/session_lifecycle_check.gd
##
## Exits non-zero on failure. Takes about 40 seconds — most of it is waiting for real timeouts, which
## is the point: the numbers this prints are measurements, not assertions about what should happen.
##
## WHY THIS ONE IS NOT IN-PROCESS like the other three harnesses. Every claim here is about what the
## OTHER SIDE ends up believing — that a refused joiner is told why, that a dropped client reconnects
## by itself, that a late joiner sees the players who were already there. A second raw
## ENetMultiplayerPeer in this process would prove none of that: it has no NetSession to receive the
## refusal, no PlayerNet to spawn into. So this script is both halves. Run with no arguments it is the
## host and the driver; it relaunches ITSELF with `-- client-probe <label>` for each client, and reads
## back what each one believed:
##
##     driver (host, capacity 2)          c1                c2                 c3
##       ├── c1 joins ──────────────────► admitted
##       ├── c2 joins ─────────────────────────────────────► REFUSED "session is full (2/2 players)"
##       ├── capacity 4, c3 joins late ──────────────────────────────────────► sees 3 players
##       ├── c4 joins claiming another protocol version ──────────────────────► REFUSED "protocol mismatch"
##       ├── kick c1 (an unclean drop) ─► rejoins by itself
##       ├── SIGKILL c3 ────────────────────────────────────────────────────► host times it out
##       └── end_session() ─────────────► HOST_CLOSED, no rejoin
##
## A child writes its running result to user://net_lifecycle/<label>.json after every event, not at
## exit — c3 is killed on purpose and still has to be able to testify.

const PORT: int = 47411
const RESULT_DIR: String = "user://net_lifecycle"
const NET_VERSION: GDScript = preload("res://core/net/net_version.gd")

## Generous on purpose: these are process launches on a machine that is also running two other agents'
## test suites. Every one of them is an upper bound that a pass never gets near, and each failure
## prints what it actually waited for.
const CHILD_READY_TIMEOUT_SEC: float = 20.0
const EVENT_TIMEOUT_SEC: float = 20.0

## What "the host noticed a peer died" must beat. ENet's untuned ceiling is 30 s; NetTransport lowers
## it to 8 s (_PEER_TIMEOUT_MAX_MSEC), and this is that plus room for a loaded machine.
const DEAD_PEER_DETECT_LIMIT_SEC: float = 12.0

var _failures: int = 0
var _sections_completed: int = 0
var _drive_finished: bool = false
var _transport: Node
var _session: Node
var _player_net: Node
## F-032's consumer: peer-keyed gameplay state that has to survive a reconnect.
var _inventory: Node

# Driver-side observations, filled from NetTransport/NetSession signals.
var _session_was_registered: bool = false
var _bad_version: bool = false
var _dead: Dictionary[int, bool] = {}
var _refused: Array[Dictionary] = []
var _joined: Array[int] = []
var _left: Array[int] = []


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() >= 2 and args[0] == "client-probe":
		_label = args[1]
		_bad_version = args.size() >= 3 and args[2] == "bad-version"
	# NOTHING may touch the autoloads from _initialize. They are already children of root by now — a
	# get_node finds them — but they have not ENTERED the tree: _ready has not run and node.multiplayer
	# is still null, so NetTransport.join() sets a peer on a null MultiplayerAPI, prints one error, and
	# returns OK anyway. One deferred frame is the fix; this trap is recorded in DELEGATION Current state.
	_start.call_deferred()


func _start() -> void:
	await process_frame
	if not _autoloads():
		print("autoloads missing — NetTransport / NetSession / PlayerNet")
		quit(1)
		return
	if _label.is_empty():
		_run_driver()
	else:
		_run_client()


# ── Shared ────────────────────────────────────────────────────────────────────────────────────────


## Autoloads are not compile-time identifiers in a --script main loop (F-011) — the entry script is
## compiled before [autoload] is bootstrapped. Look them up off root, relative, which is also the only
## form accepted this early.
func _autoloads() -> bool:
	_transport = root.get_node_or_null(^"NetTransport")
	_player_net = root.get_node_or_null(^"PlayerNet")
	_inventory = root.get_node_or_null(^"InventoryService")
	_session = root.get_node_or_null(^"NetSession")
	_session_was_registered = _session != null
	if _session == null:
		# Registration is checked separately, and the rest of the run is still worth having: every
		# process here runs THIS script, so building the node by hand puts it at /root/NetSession in
		# all of them — the same path the RPCs resolve against. load() at runtime, not preload at
		# class scope, because the entry script compiles before autoloads exist (F-011).
		_session = (load("res://core/net/net_session.gd") as GDScript).new()
		_session.name = "NetSession"
		root.add_child(_session)
	return _transport != null and _session != null and _player_net != null


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s%s" % [label, ("  — " + detail) if detail != "" else ""])
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


## Poll a condition rather than await a signal: every wait here has a real deadline, and a signal that
## never fires has to fail the check instead of hanging the harness.
func _until(condition: Callable, timeout_sec: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await create_timer(0.1).timeout
	return bool(condition.call())


# ── Driver: the host, and the checks ──────────────────────────────────────────────────────────────


func _run_driver() -> void:
	print("\n== session lifecycle (task 1.7) ==")
	_check("NetSession is registered as an autoload", _session_was_registered)

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RESULT_DIR))
	_clear_results()

	# connect(&"name", ...) rather than signal-property access: these autoloads are typed Node here
	# (F-011 — they cannot be preloaded in a --script main loop), and reaching for a signal that Node
	# does not declare is the one form of that which the parser will not let through.
	_transport.connect(&"peer_joined", func(id: int) -> void: _joined.append(id))
	_transport.connect(&"peer_left", func(id: int) -> void: _left.append(id))
	_session.connect(&"peer_refused", func(id: int, detail: String) -> void:
		_refused.append({"peer": id, "detail": detail}))

	_driver_watchdog()
	_drive()


func _driver_watchdog() -> void:
	await create_timer(90.0).timeout
	if _drive_finished:
		return
	_failures += 1
	print("  FAIL  driver coroutine did not finish — a script error may have killed it")
	quit(1)


func _drive() -> void:
	print("\n-- host --")
	_session.capacity = 2  # host + one client. The game never does this; the test does (see NetSession).
	var err: Error = _transport.host(NetConfig.Mode.LOCAL, PORT)
	_check("host() started on port %d" % PORT, err == OK, error_string(err))
	await create_timer(0.4).timeout
	_check("hosting", bool(_transport.is_host()))
	_check("free_slots() reports the empty seat", int(_session.free_slots()) == 1,
		"got %d" % int(_session.free_slots()))
	_sections_completed += 1

	print("\n-- a client joins --")
	var c1: int = _spawn_probe("c1")
	_check("c1 process launched", c1 > 0, "pid %d" % c1)
	var c1_joined: bool = await _until(func() -> bool: return _joined.size() >= 1, CHILD_READY_TIMEOUT_SEC)
	_check("host saw c1 join", c1_joined, "peers now %s" % str(_transport.peer_ids()))
	var c1_id: int = _joined[0] if c1_joined else 0
	var spawned: bool = await _until(
		func() -> bool: return _player_net.spawned_peers().size() == 2, EVENT_TIMEOUT_SEC)
	_check("host spawned both players", spawned, "roster %s" % str(_player_net.spawned_peers()))
	_check("session is full at capacity 2", int(_session.free_slots()) == 0)
	_sections_completed += 1

	print("\n-- an over-capacity client is refused, and told why --")
	var c2: int = _spawn_probe("c2")
	var refused: bool = await _until(func() -> bool: return _refused.size() >= 1, CHILD_READY_TIMEOUT_SEC)
	_check("host refused c2", refused)
	if refused:
		_check("refusal names the reason", String(_refused[0]["detail"]).begins_with("session is full"),
			String(_refused[0]["detail"]))
	# The whole point of gating before peer_joined: a refused peer is invisible to everything else.
	_check("refused peer was never announced", _joined.size() == 1,
		"peer_joined fired %d time(s)" % _joined.size())
	_check("refused peer got no player node", _player_net.spawned_peers().size() == 2,
		"roster %s" % str(_player_net.spawned_peers()))
	var c2_done: bool = await _until(func() -> bool: return not _alive(c2), EVENT_TIMEOUT_SEC)
	_check("c2 exited on its own", c2_done)
	var c2_result: Dictionary = _read_result("c2")
	_check("c2 believes it was REFUSED", String(c2_result.get("end_reason", "")) == "REFUSED",
		str(c2_result))
	_check("c2 can quote the reason", String(c2_result.get("end_detail", "")).begins_with("session is full"),
		String(c2_result.get("end_detail", "")))
	_sections_completed += 1

	print("\n-- a late client joins a session already in progress --")
	_session.capacity = 4
	var c3: int = _spawn_probe("c3")
	var c3_joined: bool = await _until(func() -> bool: return _joined.size() >= 2, CHILD_READY_TIMEOUT_SEC)
	_check("host saw c3 join mid-session", c3_joined, "peers now %s" % str(_transport.peer_ids()))
	var c3_id: int = _joined[1] if c3_joined else 0
	var three: bool = await _until(
		func() -> bool: return _player_net.spawned_peers().size() == 3, EVENT_TIMEOUT_SEC)
	_check("host roster is three players", three, "roster %s" % str(_player_net.spawned_peers()))
	var c3_seen: bool = await _until(func() -> bool:
		var seen: Array = _read_result("c3").get("roster", [])
		return seen.size() >= 3, EVENT_TIMEOUT_SEC)
	var c3_result: Dictionary = _read_result("c3")
	_check("the late joiner sees the players who were already there", c3_seen,
		"c3 roster %s" % str(c3_result.get("roster", [])))
	_sections_completed += 1

	print("\n-- a client running a different build is refused by version, not by capacity --")
	_refused.clear()
	var c4: int = _spawn_probe("c4", "bad-version")
	var version_refused: bool = await _until(func() -> bool: return _refused.size() >= 1, CHILD_READY_TIMEOUT_SEC)
	_check("host refused the mismatched build", version_refused)
	if version_refused:
		_check("refusal is the version reason, not the capacity one",
			String(_refused[0]["detail"]).begins_with("protocol mismatch"), String(_refused[0]["detail"]))
	var c4_done: bool = await _until(func() -> bool: return not _alive(c4), EVENT_TIMEOUT_SEC)
	_check("c4 exited on its own", c4_done)
	var c4_result: Dictionary = _read_result("c4")
	_check("c4 was told which build to blame",
		String(c4_result.get("end_detail", "")).begins_with("protocol mismatch"),
		String(c4_result.get("end_detail", "")))
	var back_to_three_after_c4: bool = await _until(
		func() -> bool: return _player_net.spawned_peers().size() == 3, EVENT_TIMEOUT_SEC)
	_check("the mismatched peer left no player behind", back_to_three_after_c4,
		"roster %s" % str(_player_net.spawned_peers()))
	_sections_completed += 1

	print("\n-- an unclean drop: the client reconnects by itself --")
	_joined.clear()
	# F-032: give the peer about to be dropped something to lose. A rejoining client returns under a
	# NEW peer id, and before the run-player token existed this inventory was released the moment the
	# drop was noticed — so every reconnect was a silent wipe.
	var had_inventory: bool = _inventory != null and bool(
		_inventory.call("host_add", c1_id, &"log", 7)
	)
	_check("c1 holds an inventory before it drops", had_inventory
		and int(_inventory.call("host_count", c1_id, &"log")) == 7)
	_transport.kick_peer(c1_id)
	var c1_gone: bool = await _until(func() -> bool: return _left.has(c1_id), EVENT_TIMEOUT_SEC)
	_check("host saw c1 drop", c1_gone)
	var c1_back: bool = await _until(func() -> bool: return _joined.size() >= 1, EVENT_TIMEOUT_SEC)
	_check("c1 came back on its own", c1_back, "peers now %s" % str(_transport.peer_ids()))
	var back_to_three: bool = await _until(
		func() -> bool: return _player_net.spawned_peers().size() == 3, EVENT_TIMEOUT_SEC)
	_check("the rejoiner got a player again", back_to_three,
		"roster %s" % str(_player_net.spawned_peers()))
	var c1_result: Dictionary = _read_result("c1")
	_check("c1 reports a rejoin, not an ending", int(c1_result.get("rejoins", 0)) >= 1,
		str(c1_result.get("events", [])))

	# The peer id genuinely changed — that is the whole premise of F-032, so assert it rather than
	# assuming it, or this section could pass on a transport that happened to reuse ids.
	var rejoined_id: int = int(_joined[0]) if not _joined.is_empty() else 0
	_check("the rejoiner came back under a different peer id", rejoined_id > 0
		and rejoined_id != c1_id, "was %d, now %d" % [c1_id, rejoined_id])
	if _inventory != null and rejoined_id > 0:
		var carried: bool = await _until(
			func() -> bool: return int(_inventory.call("host_count", rejoined_id, &"log")) == 7,
			EVENT_TIMEOUT_SEC)
		_check("the inventory followed the player across the new peer id", carried,
			"peer %d holds %d log(s)" % [rejoined_id, int(_inventory.call("host_count", rejoined_id, &"log"))])
		_check("nothing was left behind under the old peer id",
			(_inventory.call("host_slots", c1_id) as Array).is_empty())
	_sections_completed += 1

	print("\n-- a client's process dies: how long until the host notices --")
	_left.clear()
	var killed_at: int = Time.get_ticks_msec()
	OS.kill(c3)
	_dead[c3] = true
	var noticed: bool = await _until(func() -> bool: return _left.has(c3_id), DEAD_PEER_DETECT_LIMIT_SEC)
	var elapsed: float = float(Time.get_ticks_msec() - killed_at) / 1000.0
	_check("host timed the dead peer out within %.0fs" % DEAD_PEER_DETECT_LIMIT_SEC, noticed,
		"took %.1fs" % elapsed)
	print("  ↳ dead-peer detection: %.1fs (ENet default ceiling is 30s; NetTransport caps it at 8s)" % elapsed)
	var despawned: bool = await _until(
		func() -> bool: return _player_net.spawned_peers().size() == 2, EVENT_TIMEOUT_SEC)
	_check("the dead peer's player was despawned", despawned,
		"roster %s" % str(_player_net.spawned_peers()))
	_sections_completed += 1

	print("\n-- the host quits, and says so --")
	await _session.end_session()
	_check("host is offline", not bool(_transport.is_active()))
	var c1_done: bool = await _until(func() -> bool: return not _alive(c1), EVENT_TIMEOUT_SEC)
	_check("c1 exited after the host closed", c1_done)
	c1_result = _read_result("c1")
	_check("c1 believes the HOST CLOSED it, not that the link died",
		String(c1_result.get("end_reason", "")) == "HOST_CLOSED", str(c1_result))
	_check("c1 did not try to reconnect to a host that quit",
		int(c1_result.get("rejoin_attempts_after_close", 0)) == 0, str(c1_result))
	_sections_completed += 1
	_check("all lifecycle sections completed", _sections_completed == 8,
		"completed %d/8" % _sections_completed)

	_cleanup([c1, c2, c3, c4])
	print("\n%d failure(s)\n" % _failures)
	_drive_finished = true
	quit(1 if _failures > 0 else 0)


## Relaunch this same script as a client, in its own process, with the full autoload stack.
func _spawn_probe(label: String, flavour: String = "") -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args: PackedStringArray = PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/session_lifecycle_check.gd",
		"--", "client-probe", label,
	])
	if not flavour.is_empty():
		args.append(flavour)
	var pid: int = OS.create_process(OS.get_executable_path(), args)
	print("  ↳ launched %s as pid %d" % [label, pid])
	return pid


func _clear_results() -> void:
	var dir: DirAccess = DirAccess.open(RESULT_DIR)
	if dir == null:
		return
	for file: String in dir.get_files():
		dir.remove(file)


func _read_result(label: String) -> Dictionary:
	var path: String = "%s/%s.json" % [RESULT_DIR, label]
	if not FileAccess.file_exists(path):
		return {}
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


## OS.is_process_running() reaps the child when it reports false, and asking a second time about a
## reaped pid is an engine error rather than another false. Remember instead of asking twice.
func _alive(pid: int) -> bool:
	if pid <= 0 or _dead.has(pid):
		return false
	if OS.is_process_running(pid):
		return true
	_dead[pid] = true
	return false


func _cleanup(pids: Array[int]) -> void:
	for pid: int in pids:
		if _alive(pid):
			OS.kill(pid)
			_dead[pid] = true


# ── Client probe: one child process, reporting what it believed ───────────────────────────────────


var _label: String = ""
var _result: Dictionary = {}


func _run_client() -> void:
	_result = {
		"label": _label,
		"events": [],
		"roster": [],
		"rejoins": 0,
		"rejoin_attempts_after_close": 0,
		"end_reason": "",
		"end_detail": "",
	}

	_session.connect(&"session_opened", _probe_opened)
	_session.connect(&"session_ended", _probe_ended)
	_session.connect(&"connection_interrupted",
		func(detail: String) -> void: _probe_event("interrupted: " + detail))
	_session.connect(&"rejoin_attempted", _probe_rejoin_attempt)
	_session.connect(&"rejoined", _probe_rejoined)

	var err: Error = _transport.join(NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	_probe_event("join() -> %s" % error_string(err))
	if err != OK:
		_probe_finish(1)
		return

	# A probe that is never told anything must not sit here forever holding a pid the driver waits on.
	call_deferred(&"_probe_watchdog")


func _probe_watchdog() -> void:
	await create_timer(120.0).timeout
	if String(_result.get("end_reason", "")).is_empty():
		_probe_event("watchdog: nothing ended this session")
		_probe_finish(1)


func _probe_opened(is_host: bool) -> void:
	_probe_event("opened as peer %d (host=%s)" % [int(_transport.local_peer_id()), str(is_host)])
	if _bad_version:
		# A real RPC from a real client over a real connection — the only thing faked is the number,
		# which is the whole subject of the test. NetSession has already sent the correct hello; this
		# is what a stale build would have sent instead.
		var bogus: int = int(NET_VERSION.PROTOCOL_VERSION) + 1
		_probe_event("claiming protocol v%d" % bogus)
		_session.net_client_hello.rpc_id(NetConfig.HOST_PEER_ID, bogus)
	_probe_sample_roster()


## What this client can actually see, a moment after joining — the mid-session-join claim in one line.
func _probe_sample_roster() -> void:
	await create_timer(1.0).timeout
	var roster: Array[int] = []
	for peer_id: int in _player_net.spawned_peers():
		roster.append(peer_id)
	_result["roster"] = roster
	_probe_event("roster %s" % str(roster))


func _probe_rejoin_attempt(attempt: int, of: int) -> void:
	_probe_event("rejoin attempt %d/%d" % [attempt, of])
	if not String(_result.get("end_reason", "")).is_empty():
		_result["rejoin_attempts_after_close"] = int(_result["rejoin_attempts_after_close"]) + 1
	_probe_write()


func _probe_rejoined() -> void:
	_result["rejoins"] = int(_result["rejoins"]) + 1
	_probe_event("rejoined as peer %d" % int(_transport.local_peer_id()))


func _probe_ended(reason: int, detail: String) -> void:
	_result["end_reason"] = _session.reason_name(reason)
	_result["end_detail"] = detail
	_probe_event("ended: %s (%s)" % [_result["end_reason"], detail])
	# Stay alive a moment: a client that quits instantly could not report a rejoin it should not have
	# attempted, and that absence is one of the checks.
	await create_timer(1.5).timeout
	_probe_finish(0)


func _probe_event(text: String) -> void:
	var events: Array = _result["events"]
	events.append("%7.2fs  %s" % [float(Time.get_ticks_msec()) / 1000.0, text])
	print("[%s] %s" % [_label, text])
	_probe_write()


## Written after every event, never only at exit: c3 is killed mid-session on purpose and its file is
## still the evidence that a late joiner saw the whole roster.
func _probe_write() -> void:
	var file: FileAccess = FileAccess.open("%s/%s.json" % [RESULT_DIR, _label], FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(_result, "  "))
	file.close()


func _probe_finish(code: int) -> void:
	_probe_write()
	quit(code)
