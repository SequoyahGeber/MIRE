extends SceneTree

## F-605 — the wipe state machine, across two real processes.
##
##   .agent/bin/agent godot --script tools/defeat_net_check.gd
##
## ## Why this file exists
##
## `player_health_net_check.gd` is green and covers the REVIVE half properly: the downed flag
## reaching a peer who did not go down, self-revive refused, out-of-range revive refused, in-range
## revive accepted. `defeat_check.gd` is green and covers the wipe VERDICT: both alive, one down,
## everyone down. Between them they stop exactly where a co-op session actually breaks — at the
## point a player stops being revivable.
##
## The question that matters most, and the reason this is ordered the way it is: **can a client that
## DIES get back into the run at all?** A client stuck as a corpse while its teammate plays on reads
## to that player as a broken game rather than as a netcode fault, and it ends the session. Every
## other question here is quality; that one is a hard lock. It is subtest 1 so that a run cut short
## still answers it.
##
## ## What is asserted, in order of how badly it ends a playtest
##
##   1. A client bleeds out to DEAD with the host alive, and comes back — respawned, at full hp,
##      inside `respawn_seconds`, and ALIVE on its own screen as well as on the host's ledger. Host
##      and client agreeing is the whole point: alive on the host and a corpse locally is the same
##      broken game from the player's chair.
##   2. It comes back AT THE SPAWN POINT, not where it fell. `_teleport_to_spawn()` warns and returns
##      without moving anybody when `_spawn_transforms` has no entry for that peer (F-063), so a
##      client that died in the Mire would respawn inside the thing that killed it. The client is
##      walked a long way off before it is killed, so "did not move" and "moved home" cannot be
##      confused — the failure this catches is silent otherwise.
##   3. One dead, one alive is NOT a defeat. If a single death ended the run, co-op would be over the
##      first time either player made a mistake.
##   4. Both down at once IS a defeat, across two processes rather than one with simulated peers.
##
## ## Network authority
##
## Reads only. The driver is the host and owns every mutation it makes; the probe process is a real
## client and only ever asks. Deaths are applied through `host_apply_damage`, which is the same seam
## an enemy uses, rather than by writing state — a check that sets the state it then asserts is the
## vacuous shape this repo has found four of today.
const NetConfig := preload("res://core/net/net_config.gd")

const PORT: int = 47433
const RESULT_PATH: String = "user://defeat_net_client.json"
const DRIVER_SIGNAL_PATH: String = "user://defeat_net_driver.json"
const TIMEOUT_SEC: float = 25.0

## Where the client is sent to die. Far enough from any spawn offset (the widest is 1.6 m) that
## "respawned at the spawn point" and "never moved" are metres apart rather than centimetres — the
## 0.21 m margin that nearly made `item_drop_net_check` vacuous is the lesson being applied here.
const DEATH_SITE := Vector3(45.0, 0.0, 45.0)
## How close to its captured spawn a respawned body has to land to count as "came home".
const HOME_TOLERANCE_M: float = 3.0

var failures: int = 0
var transport: Node
var player_net: Node
var health: Node
var defeat: Node
var child_pid: int = 0
var max_hp: int = 100


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	health = root.get_node_or_null(^"PlayerHealth")
	defeat = root.get_node_or_null(^"DefeatService")
	if transport == null or player_net == null or health == null or defeat == null:
		fail("NetTransport, PlayerNet, PlayerHealth and DefeatService autoloads must exist")
		finish()
		return
	max_hp = int(health.get("max_hp"))
	# The shipped bleed-out is 30 s and the shipped respawn 5 s, which is right for a run and absurd
	# for a check — 30 s of waiting per process, twice over. Compressed on BOTH processes so the
	# host's timers and the client's own view of them agree. This changes the clock, never the state
	# machine: every transition below is still driven by `DownedState.tick()` reaching its own
	# threshold, not by anything here writing a state.
	health.set("bleed_out_seconds", 2.0)
	health.set("respawn_seconds", 1.5)
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "defeat-probe":
		_run_client()
	else:
		_run_driver()


# ── host ──────────────────────────────────────────────────────────────────────────────────────────


func _run_driver() -> void:
	print("\n== defeat / respawn across two processes (F-605) ==")
	for path: String in [RESULT_PATH, DRIVER_SIGNAL_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_write_driver_signal({"go_die": false, "host_close": false})

	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return
	await process_frame
	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	var connected: bool = await _until(
		func() -> bool: return bool(_read_result().get("connected", false))
	)
	check(connected, "client connects")
	if not connected:
		_teardown()
		return
	var client_peer: int = int(_read_result().get("peer_id", 0))
	check(client_peer > NetConfig.HOST_PEER_ID, "client reports a real peer id")

	var host_body: Node3D = await _wait_for_body(NetConfig.HOST_PEER_ID)
	var client_body: Node3D = await _wait_for_body(client_peer)
	check(host_body != null and client_body != null, "both bodies exist on the host")
	if host_body == null or client_body == null:
		_teardown()
		return

	# The spawn the host captured for this client when it spawned. `_on_player_spawned` writes it for
	# every peer including remote ones — reading it back here is what makes subtest 2 an assertion
	# about coming HOME rather than about landing on some arbitrary coordinate.
	var spawn_home: Vector3 = client_body.global_position
	print("  client spawn recorded at %s" % spawn_home)

	# ── 1 · THE HARD LOCK: a client dies and has to get back into the run ────────────────────────
	print("\n-- 1 · a client that dies comes back --")
	_write_driver_signal({"go_die": true, "host_close": false})
	var moved: bool = await _until(
		func() -> bool: return bool(_read_result().get("at_death_site", false))
	)
	check(moved, "client walks out to the death site %s" % DEATH_SITE)

	# Killed through the same seam an enemy uses, twice: once to put it down, once more to finish it
	# while downed. Writing DEAD directly would assert the state this check just set.
	check(bool(health.call(&"host_apply_damage", client_peer, max_hp, 0)),
		"host applies lethal damage to the client")
	var downed: bool = await _until(func() -> bool: return bool(health.call(&"host_is_downed", client_peer)))
	check(downed, "the client is DOWNED on the host")

	var died: bool = await _until(func() -> bool: return bool(health.call(&"host_is_dead", client_peer)))
	check(died, "the client bleeds out to DEAD (no revive came)")
	if not died:
		_teardown()
		return

	# THE assertion. Everything above is setup for this line.
	var respawned: bool = await _until(
		func() -> bool:
			return (
				not bool(health.call(&"host_is_dead", client_peer))
				and not bool(health.call(&"host_is_downed", client_peer))
			)
	)
	check(respawned,
		"THE HARD LOCK: a dead client returns to the run rather than staying a corpse")
	check(int(health.call(&"host_hp", client_peer)) == max_hp,
		"and returns at full hp (%d/%d)" % [int(health.call(&"host_hp", client_peer)), max_hp])

	# The client's own screen has to agree. Alive on the host and dead locally is the same broken
	# game from the player's chair, and it is a state these two processes can genuinely disagree on.
	var client_agrees: bool = await _until(
		func() -> bool: return bool(_read_result().get("locally_alive_again", false))
	)
	check(client_agrees, "and the CLIENT'S OWN state agrees it is alive — it can play again")

	# ── 2 · placement: home, not where it fell ───────────────────────────────────────────────────
	print("\n-- 2 · it comes back to the spawn point, not to where it died --")
	# F-605 diagnostics. "the RPC never went" and "the RPC went and the client ignored it" are
	# different bugs with the same red line — the same conflation that made F-521 look like a broken
	# client when it was a stale check.
	var transforms: Dictionary = health.get("_spawn_transforms")
	var host_has_entry: bool = transforms.has(client_peer)
	print("  host holds a spawn transform for the client: %s%s" % [
		host_has_entry,
		("  -> %s" % transforms.get(client_peer, {})) if host_has_entry else "",
	])
	print("  client body class on the host: %s (respawn needs CharacterBody3D)"
		% client_body.get_class())
	# BOUNDED WAIT, not a single read and not a delay. The respawn teleport is applied by the CLIENT
	# on its own body (own movement is client authority, §2.2 row 1) and travels back to the host as
	# an ordinary position update, so the host's copy is stale for a few frames after the state flips
	# to alive. The first cut read it once, caught it stale, and reported a defect that does not
	# exist; adding two diagnostic prints then "fixed" it by accident, which is the clearest possible
	# demonstration that a delay is not a fix. This waits for the arrival with a real deadline and
	# fails if it never comes.
	var came_home: bool = await _until(
		func() -> bool:
			var now: Vector3 = client_body.global_position
			return Vector2(now.x - spawn_home.x, now.z - spawn_home.z).length() <= HOME_TOLERANCE_M,
		10.0
	)
	var landed: Vector3 = client_body.global_position
	var from_home: float = Vector2(landed.x - spawn_home.x, landed.z - spawn_home.z).length()
	var from_death: float = Vector2(landed.x - DEATH_SITE.x, landed.z - DEATH_SITE.z).length()
	print("  landed at %s — %.1f m from spawn, %.1f m from where it died" %
		[landed, from_home, from_death])
	check(came_home,
		"respawn reaches the captured spawn on the host within 10 s (%.1f m from it, tolerance %.1f)"
			% [from_home, HOME_TOLERANCE_M])
	# Stated separately and deliberately: this is the F-063 failure — `_teleport_to_spawn()` warning
	# and returning leaves the body exactly where it fell, which for a death in the Mire or the water
	# means respawning inside whatever killed you.
	check(from_death > HOME_TOLERANCE_M,
		"and NOT where it fell (%.1f m away) — F-063's respawn-in-place path did not fire"
			% from_death)

	# ── 3 · one dead, one alive is not a defeat ──────────────────────────────────────────────────
	print("\n-- 3 · one player down does not end the run --")
	check(not bool(defeat.call(&"is_defeated")),
		"a client death with the host alive left the run running")

	# ── 4 · both down at once IS a defeat ────────────────────────────────────────────────────────
	print("\n-- 4 · both players down ends it --")
	check(bool(health.call(&"host_apply_damage", client_peer, max_hp, 0)),
		"the client goes down again")
	check(bool(health.call(&"host_apply_damage", NetConfig.HOST_PEER_ID, max_hp, 0)),
		"and the host goes down too")
	var wiped: bool = await _until(func() -> bool: return bool(defeat.call(&"is_defeated")))
	check(wiped, "both peers down across two processes fires the team wipe")

	_teardown()


func _teardown() -> void:
	_write_driver_signal({"go_die": false, "host_close": true})
	await _until(func() -> bool: return bool(_read_result().get("final", false)), 6.0)
	print("\nDEFEAT_NET_CHECK failures=%d result=%s" % [failures, JSON.stringify(_read_result())])
	finish()


# ── client ────────────────────────────────────────────────────────────────────────────────────────


func _run_client() -> void:
	_write_result({"connected": false})
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"final": true, "error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	var connected: bool = await _until(func() -> bool: return bool(transport.call("is_active")))
	if not connected:
		_write_result({"final": true, "error": "connect timeout"})
		finish()
		return
	var peer_id: int = int(transport.call("local_peer_id"))
	# F-107: re-fetch in the outer scope — a lambda captures outer locals by value.
	var spawned: bool = await _until(func() -> bool: return player_net.call("player_for", peer_id) != null)
	var body: Node3D = player_net.call("player_for", peer_id) as Node3D
	if not spawned or body == null:
		_write_result({"final": true, "error": "player spawn timeout"})
		finish()
		return
	_write_result({"connected": true, "peer_id": peer_id, "at_death_site": false,
		"locally_alive_again": false})

	# Wait for the host's go-ahead rather than a delay. larchcc2572's F-581 harness raced itself the
	# other way round today and fixing it with a sleep would have left the order undefined — which
	# matters more here than usual, because the friend this is all for plays on an M1 Air.
	await _until(func() -> bool: return bool(_read_driver_signal().get("go_die", false)))
	# Own movement is client authority (ARCHITECTURE.md §2.2 row 1), so the client places itself.
	body.global_position = DEATH_SITE
	await _until(func() -> bool: return false, 0.5)
	_write_result({"connected": true, "peer_id": peer_id, "at_death_site": true,
		"locally_alive_again": false})

	# The client's own view of itself. `local_health_changed` carries the DownedState int, and ALIVE
	# is 0 — this is what the player's own HUD reads, which is why it is the thing asserted rather
	# than the host's ledger a second time.
	var alive_again: Array[bool] = [false]
	var seen_dead: Array[bool] = [false]
	health.connect(&"local_health_changed",
		func(hp: int, _max_hp: int, state: int, _bleed: float) -> void:
			# DownedState.State is ALIVE 0, DOWNED 1, DEAD 2. Only DEAD counts: the first cut treated
			# any non-zero state as dead, so being merely DOWNED armed the latch and the client
			# reported itself back from the dead without ever having died.
			if state == 2:
				seen_dead[0] = true
			elif state == 0 and seen_dead[0] and hp > 0:
				alive_again[0] = true
				_write_result({"connected": true, "peer_id": peer_id, "at_death_site": true,
					"locally_alive_again": true})
	)

	await _until(func() -> bool: return bool(_read_driver_signal().get("host_close", false)), 40.0)
	_write_result({"connected": true, "peer_id": peer_id, "at_death_site": true,
		"locally_alive_again": alive_again[0], "saw_dead_locally": seen_dead[0], "final": true})
	finish()


# ── plumbing ──────────────────────────────────────────────────────────────────────────────────────


func _wait_for_body(peer_id: int) -> Node3D:
	await _until(func() -> bool: return player_net.call("player_for", peer_id) != null)
	return player_net.call("player_for", peer_id) as Node3D


func _spawn_client() -> int:
	return OS.create_process(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", "tools/defeat_net_check.gd", "--", "defeat-probe",
	]))


func _write_result(data: Dictionary) -> void:
	var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data))
		file.close()


func _read_result() -> Dictionary:
	if not FileAccess.file_exists(RESULT_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RESULT_PATH))
	return parsed if parsed is Dictionary else {}


func _write_driver_signal(data: Dictionary) -> void:
	var file := FileAccess.open(DRIVER_SIGNAL_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data))
		file.close()


func _read_driver_signal() -> Dictionary:
	if not FileAccess.file_exists(DRIVER_SIGNAL_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DRIVER_SIGNAL_PATH))
	return parsed if parsed is Dictionary else {}


func _until(condition: Callable, seconds: float = TIMEOUT_SEC) -> bool:
	var waited: float = 0.0
	while waited < seconds:
		if bool(condition.call()):
			return true
		await process_frame
		waited += 1.0 / 60.0
	return bool(condition.call())


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func fail(description: String) -> void:
	check(false, description)


## Same shape as `player_health_net_check.gd`'s: kill the child, drop the transport, exit with the
## verdict. Both processes call it, and on the probe side `child_pid` is 0 so the kill is skipped.
func finish() -> void:
	if child_pid > 0 and OS.is_process_running(child_pid):
		OS.kill(child_pid)
	if transport != null and bool(transport.call("is_active")):
		transport.call("leave")
	quit(0 if failures == 0 else 1)
