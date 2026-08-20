extends SceneTree

## F-279 / F-298 — the two halves of `PlayerHealth._on_run_restarted()`, each proved where it
## actually lives.
##
## Phase 1 (solo, shipped map, in-process) is the F-279 body: a restart must put the local player
## back on the run spawn rather than leaving them wherever the ended run left them — aboard the
## shipwreck after an extraction, face down in the mud after a defeat. Restarted TWICE, because a
## reset that works once and then latches is the exact shape F-280 found elsewhere in this feature,
## and the two returns are compared to EACH OTHER as well as to the spawn: a teleport that drifts a
## little further every run is still a bug, it is just a slower one.
##
## Phase 2 (a real connected client, second process) is the part no single process can substitute
## for, and it is the authority claim rather than the arithmetic. Own player movement is CLIENT
## authority (`docs/ARCHITECTURE.md` §2.2 row 1), so the fix moves each peer's body ON THAT PEER off
## its own re-derived `run_restarted` — never by the host writing a remote transform. In one process
## the local player IS the host and both designs look identical; only a second peer can show that a
## client returns to its own spawn with the host having sent it nothing. The same probe carries
## F-298: stamina and the sprint lockout are client-simulated, appear in no snapshot, and so had no
## path back across a restart at all — the probe drains itself into the lockout before the host
## restarts and asserts both are clear afterwards.
##
##   .agent/bin/agent godot --script tools/run_restart_spawn_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const NET_CONFIG := preload("res://core/net/net_config.gd")

const PORT: int = 47451
const RESULT_PATH: String = "user://run_restart_spawn_client.json"
const SCENE_PATH: String = "res://levels/hollowmere.tscn"
const TIMEOUT_SEC: float = 15.0
## How far the player is dragged off the spawn before the restart, on both sides. Far enough that no
## settling, interpolation or gravity drift could account for the return.
const DISPLACEMENT_M: float = 12.0
## Accepted distance from the recorded run spawn afterwards. The same band
## `tools/run_restart_net_check.gd` uses, and 12x smaller than the displacement it has to undo.
const SPAWN_TOLERANCE_M: float = 1.0
## F-308: how many host-side inventory grants the client is given before the restart. Each one bumps
## that peer's snapshot revision by 1, so this is really "how far above zero the client's private
## `_local_revision` is carried" — the whole mechanism of that finding. Small enough to fit the
## authored stack sizes, large enough that the restarted run cannot climb back past it by accident.
const PRE_RESTART_GRANTS: int = 20
const GRANT_ITEM: StringName = &"log"

var failures: int = 0
var transport: Node
var player_health: Node
var cycle_service: Node
var defeat_service: Node
var inventory_service: Node
var child_pid: int = 0
var _client_restart_count: int = 0
## Everything the probe measures is sampled INSIDE its own `run_restarted` handler, not polled
## afterwards — see `_on_client_run_restarted()` for why polling cannot see this finding at all.
var _client_own_spawn: Vector3 = Vector3.ZERO
var _client_host_spawn: Vector3 = Vector3.ZERO
var _at_restart_spawn_distance: float = 999.0
var _at_restart_host_spawn_distance: float = 0.0
var _at_restart_stamina: float = -1.0
var _at_restart_can_sprint: bool = true


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_health = root.get_node_or_null(^"PlayerHealth")
	cycle_service = root.get_node_or_null(^"CycleService")
	defeat_service = root.get_node_or_null(^"DefeatService")
	inventory_service = root.get_node_or_null(^"InventoryService")
	if (transport == null or player_health == null or cycle_service == null
			or defeat_service == null or inventory_service == null):
		_fail("NetTransport, PlayerHealth, CycleService, DefeatService and InventoryService"
			+ " autoloads must exist")
		_finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "spawn-probe":
		_run_client()
	else:
		_run_driver()


# ── Phase 1 · solo, on the shipped map ────────────────────────────────────────────────────────────


func _run_driver() -> void:
	await _run_solo()
	await _run_networked()
	print("RUN_RESTART_SPAWN_CHECK failures=%d" % failures)
	_finish()


func _run_solo() -> void:
	print("\n== F-279 phase 1 · a restart returns the solo player to the run spawn ==")
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	_check(packed != null, "the shipped map loads")
	if packed == null:
		return
	var level: Node = packed.instantiate()
	root.add_child(level)
	current_scene = level
	# Long enough for PlayerHealth's first physics tick to latch the offline spawn capture (F-063)
	# and for the body to settle onto the authored ground.
	for _index: int in 30:
		await process_frame
		await physics_frame

	var player: Node3D = _local_player_body()
	_check(player != null, "the local player exists before the first restart")
	if player == null:
		_teardown_level(level)
		return
	var run_spawn: Vector3 = player.global_position

	var returns: Array[Vector3] = []
	for attempt: int in 2:
		player.global_position = run_spawn + Vector3(DISPLACEMENT_M, 0.0, 0.0)
		await physics_frame
		_check(player.global_position.distance_to(run_spawn) > SPAWN_TOLERANCE_M,
			"restart %d: the player is off the run spawn before the restart" % (attempt + 1))
		defeat_service.set(&"defeated", true)
		await process_frame
		cycle_service.call("host_restart_run")
		await process_frame
		await physics_frame
		var moved_back: float = player.global_position.distance_to(run_spawn)
		_check(moved_back < SPAWN_TOLERANCE_M,
			"restart %d: the player is back on the run spawn (%.3f m away)"
				% [attempt + 1, moved_back])
		returns.append(player.global_position)

	# Not implied by the two assertions above: both could pass while each restart lands a little
	# further out, which is a drift bug rather than a reset. Compared to each other, not to a
	# constant, so retuning the authored spawn cannot make this fail.
	#
	# HORIZONTAL only, and that is not slack. `_apply_respawn_transform()` zeroes velocity and then
	# the body falls again for however many physics ticks separate the teleport from the sample, so
	# the Y components legitimately differ by a fraction of a tick of gravity (~0.01 m, measured)
	# while X and Z are written from the same stored spawn both times and must be bit-identical.
	# Drift, if it existed, would be in the displacement axis — X — where the band is 0.01 m against
	# a 12 m displacement.
	var horizontal_drift: float = (
		Vector2(returns[0].x, returns[0].z).distance_to(Vector2(returns[1].x, returns[1].z))
		if returns.size() == 2 else 999.0
	)
	_check(horizontal_drift < 0.01,
		"the second restart lands on the same point as the first, not a drifting one (%.5f m)"
			% horizontal_drift)

	# F-298's solo half. Offline the local peer IS the host, so this only proves the reset runs at
	# all — that it runs on a peer that is NOT the host is phase 2's whole job.
	_drain_local_stamina_to_lockout()
	_check(not bool(player_health.call("local_can_sprint")),
		"the solo player is sprint-locked out before the restart")
	defeat_service.set(&"defeated", true)
	await process_frame
	cycle_service.call("host_restart_run")
	await process_frame
	_check(is_equal_approx(
			float(player_health.call("local_stamina")),
			float(player_health.call("local_max_stamina"))),
		"restart returns the solo player's stamina to full")
	_check(bool(player_health.call("local_can_sprint")),
		"restart clears the solo player's sprint lockout")

	_teardown_level(level)


func _teardown_level(level: Node) -> void:
	current_scene = null
	root.remove_child(level)
	level.free()
	await process_frame


# ── Phase 2 · a real connected client, second process ─────────────────────────────────────────────


func _run_networked() -> void:
	print("\n== F-279/F-298 phase 2 · a CLIENT returns itself, with nothing sent from the host ==")
	for stale: String in [RESULT_PATH, RESULT_PATH + ".part"]:
		if FileAccess.file_exists(stale):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(stale))

	var error: Error = transport.call("host", NET_CONFIG.Mode.LOCAL, PORT)
	_check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		return
	await process_frame
	child_pid = _spawn_client()
	_check(child_pid > 0, "client process launches")

	var armed: bool = await _until(
		func() -> bool: return bool(_read_result().get("armed", false)), TIMEOUT_SEC)
	_check(armed, "client connects, gets a body, drains its stamina and walks off its spawn")
	if not armed:
		return
	var before: Dictionary = _read_result()
	_check(float(before.get("spawn_distance", 0.0)) > SPAWN_TOLERANCE_M,
		"client is off its own spawn before the restart (%.3f m)"
			% float(before.get("spawn_distance", 0.0)))
	_check(not bool(before.get("can_sprint", true)),
		"client is sprint-locked out before the restart")

	# F-308. Granted one at a time on purpose: `host_add()` publishes a snapshot per call, so this
	# walks the client's private `_local_revision` up to PRE_RESTART_GRANTS. A single grant of 20
	# would move the item count identically and leave the revision at 1, which is the number the
	# finding is actually about.
	var client_peer_id: int = _first_remote_peer_id()
	_check(client_peer_id > 0, "the host can see the connected client's peer id")
	for _index: int in PRE_RESTART_GRANTS:
		inventory_service.call("host_add", client_peer_id, GRANT_ITEM, 1)
	_check(int(inventory_service.call("host_count", client_peer_id, GRANT_ITEM))
			== PRE_RESTART_GRANTS,
		"the host granted the client %d %s before the restart" % [PRE_RESTART_GRANTS, GRANT_ITEM])
	var carried: bool = await _until(
		func() -> bool:
			return int(_read_result().get("item_count", -1)) == PRE_RESTART_GRANTS,
		TIMEOUT_SEC)
	_check(carried, "the client received all %d and its revision is above zero (%d, r%d)"
		% [PRE_RESTART_GRANTS, int(_read_result().get("item_count", -1)),
			int(_read_result().get("revision", -1))])

	defeat_service.set(&"defeated", true)
	_check(int(cycle_service.call("host_restart_run")) == 1, "host restarts the run")
	var relayed: bool = await _until(
		func() -> bool: return int(_read_result().get("restart_count", 0)) >= 1, TIMEOUT_SEC)
	_check(relayed, "the client's own run_restarted listener fires")

	# The probe records everything below inside its OWN `run_restarted` handler, on the first frame
	# of the restarted run — see `_on_client_run_restarted()`. The driver only has to wait for that
	# record to reach the result file, which is what the `restart_count` wait above already did; one
	# more `_until` covers the poll interval between the handler and the next write.
	var recorded: bool = await _until(
		func() -> bool: return float(_read_result().get("at_restart_stamina", -1.0)) >= 0.0,
		TIMEOUT_SEC)
	_check(recorded, "the client recorded its own state at the first frame of the restarted run")
	var after: Dictionary = _read_result()
	_check(float(after.get("at_restart_spawn_distance", 999.0)) < SPAWN_TOLERANCE_M,
		"the client put ITSELF back on its own spawn (%.3f m away)"
			% float(after.get("at_restart_spawn_distance", 999.0)))
	_check(float(after.get("at_restart_host_spawn_distance", 0.0)) > 10.0,
		"the client used ITS OWN spawn record, not the host's stale copy 40 m away (%.3f m from it)"
			% float(after.get("at_restart_host_spawn_distance", 0.0)))
	_check(is_equal_approx(
			float(after.get("at_restart_stamina", -1.0)), float(after.get("max_stamina", 0.0))),
		"the client's stamina is full at the first frame of the new run (%.2f)"
			% float(after.get("at_restart_stamina", -1.0)))
	_check(bool(after.get("at_restart_can_sprint", false)),
		"the client's sprint lockout is cleared at the first frame of the new run")

	# F-308. Two assertions, and the second is the one a stale-guard bug cannot fake. The first says
	# the client stopped showing last run's items; the fix's own `_reset_local_cache()` is enough for
	# that. The second says the client can still ACCEPT host state afterwards — a restarted run's
	# snapshots start again from revision 0, and a client that carried its old `_local_revision` drops
	# every one of them silently.
	var emptied: bool = await _until(
		func() -> bool: return int(_read_result().get("item_count", -1)) == 0, TIMEOUT_SEC)
	_check(emptied, "the client's inventory no longer holds the ended run's items (%d)"
		% int(_read_result().get("item_count", -1)))
	inventory_service.call("host_add", client_peer_id, GRANT_ITEM, 3)
	var accepted: bool = await _until(
		func() -> bool: return int(_read_result().get("item_count", -1)) == 3, TIMEOUT_SEC)
	_check(accepted,
		"the restarted run's low-revision snapshot is accepted, not dropped as stale (%d, r%d)"
			% [int(_read_result().get("item_count", -1)), int(_read_result().get("revision", -1))])

	_check(int(after.get("failures", -1)) == 0, "client self-checks report 0 failures")


## The one peer in the session that is not this process. `peer_ids()` includes the host itself.
func _first_remote_peer_id() -> int:
	for peer_id: int in transport.call("peer_ids"):
		if int(peer_id) != int(transport.call("local_peer_id")):
			return int(peer_id)
	return 0


func _run_client() -> void:
	_write_result({"armed": false})
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
	var client_failures: int = 0
	if not joined:
		_write_result({"error": "client never connected"})
		_finish()
		return
	if bool(transport.call("is_host")):
		client_failures += 1

	# Re-fetched after the wait, not assigned from inside the lambda: GDScript lambdas capture
	# locals BY VALUE, so a `body = ...` in there would set the copy and leave this one null.
	var got_body: bool = await _until(
		func() -> bool: return _local_player_body() != null, TIMEOUT_SEC)
	var body: Node3D = _local_player_body()
	if not got_body or body == null:
		_write_result({"error": "client never received its own body"})
		_finish()
		return
	# The spawn PlayerNet gave this peer — and, importantly, the ONLY spawn the host knows for it.
	_client_host_spawn = body.global_position
	# Now move this peer's own spawn record somewhere the host has never heard of.
	# `rebind_local_spawn()` is client-local by construction (F-258 — it writes `_spawn_transforms`
	# for the LOCAL peer only and sends nothing), so after this the two processes disagree about
	# where this player belongs, on purpose. That disagreement is what makes the phase-2 assertion
	# discriminating rather than decorative: a fix that returned the client to its spawn by having
	# the host `rpc_id` a `net_force_respawn` would land it on the host's stale copy, 40 m away, and
	# the position assertion would fail — which is exactly the §2.2 row 1 violation being ruled out.
	# It is also the real procedural case in miniature: after a reseed the host's record for a remote
	# peer describes the PREVIOUS island's shore.
	_client_own_spawn = _client_host_spawn + Vector3(0.0, 0.0, 40.0)
	player_health.call("rebind_local_spawn", _client_own_spawn, NAN)

	EVENT_BUS.subscribe_run_restarted(_on_client_run_restarted)

	_drain_local_stamina_to_lockout()
	if bool(player_health.call("local_can_sprint")):
		client_failures += 1
	body.global_position = _client_own_spawn + Vector3(DISPLACEMENT_M, 0.0, 0.0)
	await physics_frame

	while true:
		# Re-drained every loop, and this is load-bearing. `PlayerController._physics_process()` ticks
		# `local_tick_stamina(delta, false)` on this same body every frame at 18/sec, so a probe that
		# drained once and then waited would be back above `sprint_resume_fraction` in under a second
		# and at full in five — and would report F-298 as fixed at a clean HEAD, because natural regen
		# is indistinguishable from a reset once you sample late enough. Pinning the drain models the
		# case the finding is actually about: a player still sprinting as the run ends.
		_drain_local_stamina_to_lockout()
		var live: Node3D = _local_player_body()
		var here: Vector3 = live.global_position if live != null else Vector3.ONE * 9999.0
		_write_result({
			"armed": true,
			"restart_count": _client_restart_count,
			"spawn_distance": here.distance_to(_client_own_spawn),
			"host_spawn_distance": here.distance_to(_client_host_spawn),
			"can_sprint": bool(player_health.call("local_can_sprint")),
			"at_restart_spawn_distance": _at_restart_spawn_distance,
			"at_restart_host_spawn_distance": _at_restart_host_spawn_distance,
			"at_restart_stamina": _at_restart_stamina,
			"at_restart_can_sprint": _at_restart_can_sprint,
			"max_stamina": float(player_health.call("local_max_stamina")),
			"item_count": int(inventory_service.call("local_count", GRANT_ITEM)),
			"revision": int(inventory_service.call("local_revision")),
			"failures": client_failures,
		})
		await create_timer(0.05).timeout


## Sampled here rather than polled from the driver, because every value below is only distinguishable
## from its unfixed self on the FIRST frame of the restarted run. Stamina regenerates on its own
## (see the drain loop's note) and the body keeps falling, so a poll 50 ms later reads a healthy
## player either way. This handler is subscribed after `PlayerHealth`'s — that autoload subscribes in
## `_ready()`, before any of this runs — so by the time it is called the reset under test has already
## happened, and what it records is the state the new run actually begins in.
func _on_client_run_restarted() -> void:
	_client_restart_count += 1
	var body: Node3D = _local_player_body()
	_at_restart_spawn_distance = (
		body.global_position.distance_to(_client_own_spawn) if body != null else 999.0)
	_at_restart_host_spawn_distance = (
		body.global_position.distance_to(_client_host_spawn) if body != null else 0.0)
	_at_restart_stamina = float(player_health.call("local_stamina"))
	_at_restart_can_sprint = bool(player_health.call("local_can_sprint"))


# ── Shared ────────────────────────────────────────────────────────────────────────────────────────


## Drives the real client-side stamina tick rather than poking the private field: the lockout is set
## inside `local_tick_stamina()`, so a check that set stamina directly would be asserting against a
## state the game cannot actually reach.
func _drain_local_stamina_to_lockout() -> void:
	for _index: int in 600:
		player_health.call("local_tick_stamina", 0.1, true)
		if not bool(player_health.call("local_can_sprint")):
			return


func _local_player_body() -> Node3D:
	for node: Node in get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/run_restart_spawn_check.gd",
		"--", "spawn-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


## F-290: staged to a sibling `.part` path and RENAMED into place, because the driver polls this file
## while the probe rewrites it in a loop and a plain `FileAccess.WRITE` truncates before it refills.
func _write_result(result: Dictionary) -> void:
	var staging: String = RESULT_PATH + ".part"
	var file := FileAccess.open(staging, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(staging), ProjectSettings.globalize_path(RESULT_PATH))


func _read_result() -> Dictionary:
	if not FileAccess.file_exists(RESULT_PATH):
		return {}
	var raw: String = FileAccess.get_file_as_string(RESULT_PATH)
	if raw.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(raw)
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
