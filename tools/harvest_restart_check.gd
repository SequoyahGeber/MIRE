extends SceneTree

## F-276 · a restarted run inherits no depleted world resources.
##
## Phase 1 (solo, shipped `levels/hollowmere.tscn`): deplete real authored Harvestables of BOTH
## representations the map ships — a prop drawn as its own node, and one that lives as a single slot
## inside a chunk's MultiMesh batch — then drive the real terminal-to-restart path
## (`DefeatService.defeated` -> `CycleService.host_restart_run()`) and assert every one of them is
## fully standing again: `active`, `health == max_health`, `visual_state == 0`, and a respawn clock
## back at zero rather than still counting down the definition's 90-300 seconds. Idempotence and the
## no-op case are asserted too, because `host_respawn_all()` runs on every restart forever.
##
## Phase 2 (two processes): the finding's fix is host-authoritative with "normal synchronizer
## replication to clients", and that half is exactly what a single-process check cannot see. A real
## joined client reports the `active` flag of a named prop chosen to sit inside its OWN player's
## interest radius (`NetInterest.Class.PROP` is distance-filtered), before and after the host's
## restart. Without the client half, a fix that reset only the host's copy would pass.
##
##   .agent/bin/agent godot --script tools/harvest_restart_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const NET_CONFIG := preload("res://core/net/net_config.gd")

const PORT: int = 47451
const RESULT_PATH: String = "user://harvest_restart_client.json"
const SCENE_PATH: String = "res://levels/hollowmere.tscn"
const TIMEOUT_SEC: float = 20.0
## How many separate props phase 1 fells. More than one because the two visual representations take
## different code paths through `Harvestable._refresh_visual()`, and a fix that only reached the
## node-drawn ones would still leave most of Hollowmere's props down.
const FELL_COUNT: int = 6

var failures: int = 0
var transport: Node
var harvest_world: Node
var cycle_service: Node
var defeat_service: Node
var child_pid: int = 0
var _client_watch_path: String = ""


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	harvest_world = root.get_node_or_null(^"HarvestWorld")
	cycle_service = root.get_node_or_null(^"CycleService")
	defeat_service = root.get_node_or_null(^"DefeatService")
	if transport == null or harvest_world == null or cycle_service == null or defeat_service == null:
		_fail("NetTransport, HarvestWorld, CycleService and DefeatService autoloads must exist")
		_finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "harvest-restart-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	await _run_solo()
	await _run_networked()
	print("HARVEST_RESTART_CHECK failures=%d" % failures)
	_finish()


# ── Phase 1 · solo ───────────────────────────────────────────────────────────────────────────────


func _run_solo() -> void:
	print("\n== F-276 PHASE 1 · a restart stands every felled prop back up ==")
	var level: Node = await _load_level()
	if level == null:
		return

	_check(EVENT_BUS.run_restarted_subscriber_count() > 0,
		"run_restarted has subscribers once the map is wired")
	_check(harvest_world.has_method(&"host_respawn_all"),
		"HarvestWorld exposes the host_respawn_all() mass-restore seam")

	var wired: Array = harvest_world.call("wired_harvestables")
	_check(wired.size() > 0, "the shipped map wires live harvestable props (%d)" % wired.size())

	# F-295's regression guard, and the reason phase 2 below can watch a prop at all: a holder whose
	# name collided with a sibling gets an engine-assigned `@Node3D@<id>`, and that id is a
	# per-process counter — so the host and the client disagree about the node path and the prop's
	# `MultiplayerSynchronizer` resolves on neither side. Every path here must come from the layout.
	var auto_named: int = 0
	for candidate: Variant in wired:
		if String((candidate as Node).get_path()).contains("@"):
			auto_named += 1
	_check(auto_named == 0,
		"every wired prop has a layout-derived node path, identical on every peer (%d auto-named)"
			% auto_named)

	# Nothing has been harvested yet, so the seam must be a no-op — a mass restore that "succeeds"
	# on an untouched island would hide a fix that respawns props it never depleted.
	_check(int(harvest_world.call("host_respawn_all")) == 0,
		"host_respawn_all() restores nothing on an untouched island")

	var felled: Array[Node] = _fell_props(wired)
	_check(felled.size() == FELL_COUNT,
		"%d authored props are depleted before the restart (%d)" % [FELL_COUNT, felled.size()])
	if felled.is_empty():
		await _teardown_level(level)
		return
	_check(_kinds_of(felled).size() >= 2,
		"the felled props cover both a node-drawn and a batched representation (%s)"
			% ", ".join(_kinds_of(felled)))
	for prop: Node in felled:
		if bool(prop.get(&"active")):
			_fail("%s should read depleted before the restart" % prop.get_path())
	_check(_max_respawn_remaining(felled) > 0.0,
		"each felled prop is counting down its own respawn clock before the restart")

	# The real ending -> restart path, not a bare EVENT_BUS.emit_run_restarted() shortcut: a check
	# that fires the event itself proves the subscriber, not that the shipped restart reaches it
	# (F-291).
	defeat_service.set(&"defeated", true)
	await process_frame
	var cycle: int = int(cycle_service.call("host_restart_run"))
	_check(cycle == 1, "the restart returns the run to Cycle 1")
	await process_frame
	await physics_frame

	var still_down: int = 0
	var wrong_health: int = 0
	var wrong_visual: int = 0
	var still_clocked: int = 0
	for prop: Node in felled:
		if not bool(prop.get(&"active")):
			still_down += 1
		var definition: Resource = prop.get(&"definition") as Resource
		if definition != null and int(prop.get(&"health")) != int(definition.get(&"max_health")):
			wrong_health += 1
		if int(prop.get(&"visual_state")) != 0:
			wrong_visual += 1
		if float(prop.call("respawn_remaining")) > 0.0:
			still_clocked += 1
	_check(still_down == 0,
		"every felled prop is active again immediately after the restart (%d still down)" % still_down)
	_check(wrong_health == 0,
		"every restored prop is back to full health (%d wrong)" % wrong_health)
	_check(wrong_visual == 0,
		"every restored prop is back to its intact visual state (%d wrong)" % wrong_visual)
	_check(still_clocked == 0,
		"no restored prop carries the previous run's respawn clock (%d still counting)" % still_clocked)

	# A second restart with nothing harvested in between must not claim work it did not do — this is
	# the assertion that would catch a handler that respawns unconditionally.
	defeat_service.set(&"defeated", true)
	await process_frame
	cycle_service.call("host_restart_run")
	await process_frame
	_check(int(harvest_world.call("host_respawn_all")) == 0,
		"a second restart with nothing harvested restores nothing")

	await _teardown_level(level)


## Fells props by the trusted host seam rather than `request_hit()`, so the check does not depend on
## a player standing in range. Deliberately takes HALF from each representation instead of the first
## N of the wired list: that list is node-drawn props first, so "the first six" was six trees and ore
## nodes, and the 794 batched bushes — the majority of the map, and the only ones whose restore also
## has to write a MultiMesh slot back — went untested.
func _fell_props(wired: Array) -> Array[Node]:
	var per_kind: int = maxi(FELL_COUNT / 2, 1)
	var taken: Dictionary[String, int] = {"node": 0, "batched": 0}
	var felled: Array[Node] = []
	for candidate: Variant in wired:
		if felled.size() >= FELL_COUNT:
			break
		var prop := candidate as Node
		if prop == null or not bool(prop.get(&"active")):
			continue
		var kind: String = _kind_of(prop)
		if int(taken[kind]) >= per_kind:
			continue
		var guard: int = 0
		while bool(prop.get(&"active")) and guard < 64:
			prop.call("host_apply_damage", 1000000, 1)
			guard += 1
		if not bool(prop.get(&"active")):
			taken[kind] = int(taken[kind]) + 1
			felled.append(prop)
	return felled


## "batched" or "node", read from the holder meta `world/gen/authored_world.gd` stamps.
func _kind_of(prop: Node) -> String:
	var holder: Node = prop.get_parent()
	return "batched" if holder != null and holder.has_meta(&"batch_meshes") else "node"


func _kinds_of(props: Array[Node]) -> PackedStringArray:
	var kinds: Dictionary[String, bool] = {}
	for prop: Node in props:
		kinds[_kind_of(prop)] = true
	var names: PackedStringArray = PackedStringArray()
	for key: String in kinds.keys():
		names.append(key)
	names.sort()
	return names


func _max_respawn_remaining(props: Array[Node]) -> float:
	var longest: float = 0.0
	for prop: Node in props:
		longest = maxf(longest, float(prop.call("respawn_remaining")))
	return longest


# ── Phase 2 · a real connected client adopts the restored state ──────────────────────────────────


func _run_networked() -> void:
	print("\n== F-276 PHASE 2 · a joined client sees the prop standing again ==")
	_remove_result()
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

	var armed: bool = await _until(
		func() -> bool: return bool(_read_result().get("armed", false)), TIMEOUT_SEC)
	_check(armed, "client connects and reports its own player position")
	if not armed:
		await _teardown_level(level)
		return

	var client_position: Vector3 = _vector_from(_read_result().get("player_position", []))
	var target: Node3D = _prop_near(client_position)
	_check(target != null,
		"an active prop sits inside the client's interest radius (%.1f m)"
			% NET_CONFIG.INTEREST_ENTER_RADIUS_M)
	if target == null:
		await _teardown_level(level)
		return

	_client_watch_path = String(target.get_path())
	_write_watch(_client_watch_path)
	var observed: bool = await _until(
		func() -> bool: return bool(_read_result().get("watch_found", false)), TIMEOUT_SEC)
	_check(observed, "the client resolved the same prop node path (%s)" % _client_watch_path)
	if not observed:
		await _teardown_level(level)
		return
	_check(bool(_read_result().get("watch_active", false)),
		"the client sees the prop standing before it is felled")

	while bool(target.get(&"active")):
		target.call("host_apply_damage", 1000000, 1)
	await physics_frame
	var client_saw_depletion: bool = await _until(
		func() -> bool: return not bool(_read_result().get("watch_active", true)), TIMEOUT_SEC)
	_check(client_saw_depletion, "the client replicates the depletion")

	defeat_service.set(&"defeated", true)
	await process_frame
	cycle_service.call("host_restart_run")
	await process_frame
	await physics_frame
	_check(bool(target.get(&"active")), "the host restored the prop on restart")
	var client_saw_restore: bool = await _until(
		func() -> bool: return bool(_read_result().get("watch_active", false)), TIMEOUT_SEC)
	_check(client_saw_restore,
		"the client replicates the restart's restore — the next run's island is whole on every peer")
	_check(int(_read_result().get("failures", -1)) == 0, "client self-checks report 0 failures")

	await _teardown_level(level)


## The nearest active prop to the client's own player, so `NetInterest`'s PROP distance filter
## cannot make this check flaky by culling the one node it watches.
func _prop_near(position: Vector3) -> Node3D:
	var best: Node3D = null
	var best_distance: float = NET_CONFIG.INTEREST_ENTER_RADIUS_M
	for candidate: Variant in harvest_world.call("wired_harvestables"):
		var prop := candidate as Node3D
		if prop == null or not bool(prop.get(&"active")):
			continue
		var distance: float = prop.global_position.distance_to(position)
		if distance < best_distance:
			best_distance = distance
			best = prop
	return best


## The client loads the SAME map before joining. `HarvestWorld` wires its props identically on every
## peer (that is the whole reason the bridge is an autoload rather than map script), so this is what
## gives the client a Harvestable at the same node path for the host's synchronizer to reach. A
## client that only joined would have no prop to observe and the phase would prove nothing.
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

	while true:
		var player: Node3D = _local_player()
		var watch_path: String = _read_watch()
		var watched: Node = root.get_node_or_null(NodePath(watch_path)) if not watch_path.is_empty() else null
		# A client must never own the restore. If this peer's own copy respawned anything locally the
		# phase would pass for the wrong reason, so the client asserts the host-guard holds here.
		if watched != null and bool(watched.call("host_respawn")):
			client_failures += 1
		_write_result({
			"armed": player != null,
			"player_position": [player.global_position.x, player.global_position.y,
				player.global_position.z] if player != null else [],
			"watch_found": watched != null,
			"watch_active": watched != null and bool(watched.get(&"active")),
			"failures": client_failures,
		})
		await create_timer(0.05).timeout


func _local_player() -> Node3D:
	for candidate: Node in get_nodes_in_group(&"players"):
		if candidate is Node3D and candidate.is_multiplayer_authority():
			return candidate as Node3D
	return null


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
		"--headless", "--path", project_dir, "--script", "tools/harvest_restart_check.gd",
		"--", "harvest-restart-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


## Written to a sibling path and RENAMED into place. F-290: the child rewrites this file every 50 ms
## while the parent polls it, and a plain truncate-then-write hands the reader an empty or half
## document, which `JSON.parse_string` reports as an ERROR line. A rename is atomic, so a reader
## always sees one whole document — the previous one or the next one, never a torn one.
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


func _remove_result() -> void:
	for path: String in [RESULT_PATH, RESULT_PATH + ".part", _watch_path(), _watch_path() + ".part"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## The driver's half of the same atomic handshake: which node the client should watch.
func _watch_path() -> String:
	return "user://harvest_restart_watch.json"


func _write_watch(node_path: String) -> void:
	var staging: String = _watch_path() + ".part"
	var file := FileAccess.open(staging, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"path": node_path}))
	file.close()
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(staging), ProjectSettings.globalize_path(_watch_path()))


func _read_watch() -> String:
	if not FileAccess.file_exists(_watch_path()):
		return ""
	var raw: String = FileAccess.get_file_as_string(_watch_path())
	if raw.is_empty():
		return ""
	var parsed: Variant = JSON.parse_string(raw)
	return String((parsed as Dictionary).get("path", "")) if parsed is Dictionary else ""


func _vector_from(value: Variant) -> Vector3:
	var values := value as Array
	if values == null or values.size() != 3:
		return Vector3.ZERO
	return Vector3(float(values[0]), float(values[1]), float(values[2]))


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
