extends SceneTree

## F-258 — THE RUN RESEED CHECK. D-149 cut a fresh world seed out of F-243's restart because it would
## have needed a live re-broadcast to every ALREADY-connected peer and nothing did that; D-161 lifted
## the cut by making `WorldDeltaLog.host_reseed()` that broadcast, over the reliable delta channel
## that was already on the wire. This proves both halves, plus that everything downstream of the seed
## actually re-derives instead of quietly replaying the run that just ended.
##
## Five phases:
##   1. GameState.host_redraw_seed() draws a NEW value mid-process and fires seed_ready.
##   2. WorldDeltaLog.host_reseed() wipes the ended run's chunk records and lays the seed record
##      down as the log's first entry.
##   3. The RECEIVE half — `net_delta_applied` carrying the seed record, called directly, which is
##      byte-for-byte what a client's ENet callback invokes. Same reasoning `tools/
##      cycle_advanced_net_check.gd` uses for the sibling branch: the dispatch is the thing under
##      test, not ENet's ability to deliver a packet.
##   4. The real trigger: a full solo defeat -> `CycleService.host_restart_run()` on the SHIPPED map,
##      asserting the new seed reached GameState, the stale chunk records are gone, and the Cycle/
##      run-generation records written AFTER the wipe survived it (the ordering `host_restart_run()`
##      depends on). Plus `Chest`'s per-run loot stream re-seeding off the new value.
##   5. The fresh island: ProceduralWorld.rebuild_for_seed() re-derives terrain, POI layout and
##      spawn, and the result matches a world BUILT on that seed from scratch — a rebuild must be
##      indistinguishable from a boot, or two peers restarting would disagree.
##
## Solo/offline, one process — the same "host-of-one is host authority with no peer to disagree"
## configuration `tools/run_restart_check.gd` runs in, and the reason phase 3 exercises the receive
## path by hand.
##
##   .agent/bin/agent godot --script tools/run_reseed_check.gd

const ProceduralWorldScript := preload("res://world/gen/procedural_world.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

const SCENE_PATH: String = "res://levels/hollowmere.tscn"
const TEST_SAVE_PATH: String = "user://run_reseed_check_salvage.json"
const STALE_CHUNK: Vector2i = Vector2i(7, -3)
const STALE_KIND: StringName = &"harvest"
const STALE_KEY: String = "13:41"
const REBUILD_SEED: int = 424242
const PROBE_POINTS: Array[Vector2] = [
	Vector2(0.0, 0.0), Vector2(120.0, -40.0), Vector2(-260.0, 310.0), Vector2(80.0, 500.0),
]

var failures: int = 0
var level: Node
var seed_ready_values: Array[int] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	var game_state: Node = root.get_node_or_null(^"GameState")
	var world_delta_log: Node = root.get_node_or_null(^"WorldDeltaLog")
	check(game_state != null, "GameState autoload exists")
	check(world_delta_log != null, "WorldDeltaLog autoload exists")
	if game_state == null or world_delta_log == null:
		_finish()
		return

	_phase_redraw(game_state)
	_phase_host_reseed(game_state, world_delta_log)
	_phase_receive(game_state, world_delta_log)
	await _phase_restart(game_state, world_delta_log)
	await _phase_fresh_island(game_state)
	_finish()


# ── 1 · the draw ─────────────────────────────────────────────────────────────────────────────────


func _phase_redraw(game_state: Node) -> void:
	print("\n== RESEED 1 · GameState.host_redraw_seed() draws a new seed mid-process ==")
	var first: int = int(game_state.call("ensure_seed"))
	check(first != 0, "a seed exists to begin with (%d)" % first)

	game_state.connect(&"seed_ready", _on_seed_ready)
	var second: int = int(game_state.call("host_redraw_seed"))
	check(second != first, "the redraw produced a DIFFERENT seed (%d -> %d)" % [first, second])
	check(int(game_state.get(&"run_seed")) == second, "GameState.run_seed holds the new value")
	check(bool(game_state.call("is_seed_ready")), "the new seed reads as ready")
	check(seed_ready_values.size() == 1 and seed_ready_values[0] == second,
		"seed_ready fired exactly once, carrying the new value")
	game_state.disconnect(&"seed_ready", _on_seed_ready)


# ── 2 · the broadcast half ───────────────────────────────────────────────────────────────────────


func _phase_host_reseed(game_state: Node, world_delta_log: Node) -> void:
	print("\n== RESEED 2 · WorldDeltaLog.host_reseed() wipes the old world and records the new seed ==")
	world_delta_log.call("host_record", STALE_CHUNK, STALE_KIND, STALE_KEY, true)
	check(world_delta_log.call("latest", STALE_CHUNK, STALE_KIND, STALE_KEY, null) == true,
		"a chunk record from the ended run is in the log to begin with")

	var next_seed: int = int(game_state.get(&"run_seed")) + 5150
	world_delta_log.call("host_reseed", next_seed)

	check(world_delta_log.call("latest", STALE_CHUNK, STALE_KIND, STALE_KEY, null) == null,
		"the ended run's chunk record was wiped — it described the PREVIOUS island's coordinates")
	var recorded: Variant = world_delta_log.call(
		"latest", _seed_chunk(world_delta_log), _seed_kind(world_delta_log),
		_seed_key(world_delta_log), null)
	check(int(recorded) == next_seed, "the seed record is in the log (%s)" % recorded)
	check(int(world_delta_log.call("entry_count")) == 1,
		"the seed record is the log's ONLY entry after a reseed (got %d)"
			% int(world_delta_log.call("entry_count")))
	check(int(game_state.get(&"run_seed")) == next_seed,
		"host_reseed() adopted the value into GameState too")


# ── 3 · the receive half (what a client's ENet callback invokes) ────────────────────────────────


func _phase_receive(game_state: Node, world_delta_log: Node) -> void:
	print("\n== RESEED 3 · net_delta_applied carrying the seed record — the client's own path ==")
	world_delta_log.call("host_record", STALE_CHUNK, STALE_KIND, STALE_KEY, true)
	var received_seed: int = 918273645

	# Exactly the call ENet makes on a client. An ordinary delta must NOT be treated as a reseed;
	# assert the discrimination both ways, because a `kind`/`key` typo would silently turn every
	# harvest delta into a world wipe.
	world_delta_log.call("net_delta_applied", 4, 4, "harvest", "1:1", true)
	check(world_delta_log.call("latest", STALE_CHUNK, STALE_KIND, STALE_KEY, null) == true,
		"an ordinary delta is still an ordinary delta — it did not wipe the log")

	var seed_chunk: Vector2i = _seed_chunk(world_delta_log)
	world_delta_log.call("net_delta_applied", seed_chunk.x, seed_chunk.y,
		String(_seed_kind(world_delta_log)), _seed_key(world_delta_log), received_seed)
	check(int(game_state.get(&"run_seed")) == received_seed,
		"a peer receiving the seed record adopted it (run_seed == %d)" % received_seed)
	check(world_delta_log.call("latest", STALE_CHUNK, STALE_KIND, STALE_KEY, null) == null,
		"and wiped its copy of the ended run's records, same as the host did")
	check(int(world_delta_log.call("entry_count")) == 1,
		"receive and send leave the log in the identical shape")


# ── 4 · the real trigger, on the shipped map ────────────────────────────────────────────────────


func _phase_restart(game_state: Node, world_delta_log: Node) -> void:
	print("\n== RESEED 4 · a real defeat -> CycleService.host_restart_run() on the shipped map ==")
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	check(packed != null, "the shipped scene loads")
	if packed == null:
		return
	level = packed.instantiate()
	root.add_child(level)
	current_scene = level
	for i: int in 30:
		await process_frame
		await physics_frame

	# D-107's guard: never let a check write a developer's real user://salvage.json.
	var salvage: Node = root.get_node_or_null(^"SalvageService")
	if salvage != null:
		salvage.set(&"save_path", TEST_SAVE_PATH)

	var cycle_service: Node = _cycle_service()
	check(cycle_service != null, "CycleService is up")
	if cycle_service == null:
		return

	var chest: Node = _first_chest()
	check(chest != null, "the shipped map has a Chest to watch the loot stream on")
	var before_roll: float = _peek_chest_roll(chest)

	var seed_before: int = int(game_state.get(&"run_seed"))
	world_delta_log.call("host_record", STALE_CHUNK, STALE_KIND, STALE_KEY, true)

	# The run has to have ENDED — host_restart_run() refuses otherwise, by design (D-149).
	var defeat_service: Node = root.get_node_or_null(^"DefeatService")
	check(defeat_service != null, "DefeatService is up")
	if defeat_service != null:
		defeat_service.set(&"defeated", true)
	await process_frame

	var new_cycle: int = int(cycle_service.call("host_restart_run"))
	await process_frame
	check(new_cycle == 1, "the restart reports Cycle 1 (got %d)" % new_cycle)

	var seed_after: int = int(game_state.get(&"run_seed"))
	check(seed_after != seed_before,
		"the restart drew a FRESH world seed (%d -> %d) — F-258's whole point"
			% [seed_before, seed_after])
	check(world_delta_log.call("latest", STALE_CHUNK, STALE_KIND, STALE_KEY, null) == null,
		"the ended run's chunk records did not survive into the new run")

	# The ordering host_restart_run() depends on: the wipe runs BEFORE this file's own records, so
	# these two must still be readable afterwards. A reseed placed later would have eaten them.
	var global_chunk: Vector2i = _script_const(cycle_service, &"GLOBAL_CHUNK")
	check(int(world_delta_log.call("latest", global_chunk,
		_script_const(cycle_service, &"KIND"), _script_const(cycle_service, &"KEY"), -1)) == 1,
		"the Cycle record written after the wipe survived it")
	check(int(world_delta_log.call("latest", global_chunk,
		_script_const(cycle_service, &"RUN_KIND"), _script_const(cycle_service, &"RUN_KEY"), -1)) >= 1,
		"the run-generation record written after the wipe survived it")
	check(int(world_delta_log.call("latest", _seed_chunk(world_delta_log),
		_seed_kind(world_delta_log), _seed_key(world_delta_log), 0)) == seed_after,
		"and the seed record itself agrees with GameState")

	if chest != null:
		var after_roll: float = _peek_chest_roll(chest)
		check(not is_equal_approx(before_roll, after_roll),
			"the chest's loot stream re-seeded off the new run seed (%f -> %f)"
				% [before_roll, after_roll])
		# F-210's contract must still hold across the reseed: (run_seed, chest id) -> the same roll.
		chest.call("host_seed_rng", 12345)
		var pinned_a: float = _peek_chest_roll(chest)
		chest.call("host_seed_rng", 12345)
		check(is_equal_approx(pinned_a, _peek_chest_roll(chest)),
			"a pinned seed still reproduces exactly — reseeding did not make the stream unstable")

	# The restarted run must still be playable, not reset-and-frozen.
	check(int(cycle_service.call("host_advance_cycle")) == 2,
		"the reseeded run still advances its Cycle")


# ── 5 · the fresh island ────────────────────────────────────────────────────────────────────────


func _phase_fresh_island(game_state: Node) -> void:
	print("\n== RESEED 5 · ProceduralWorld re-derives terrain, POI and spawn from the new seed ==")
	if level != null:
		level.queue_free()
		level = null
		await process_frame

	var scene := Node3D.new()
	scene.name = "ReseedCheckScene"
	root.add_child(scene)
	current_scene = scene

	var boot_seed: int = int(game_state.get(&"run_seed"))
	var world: Node3D = ProceduralWorldScript.new()
	world.set(&"build_player", false)
	scene.add_child(world)
	await process_frame

	var before_heights: PackedFloat32Array = _height_profile(world)
	var before_sites: int = (world.get(&"poi_sites") as Array).size()
	var before_spawn: Vector3 = world.get(&"spawn_position")
	check(before_sites > 0, "the world booted with POI sites (%d)" % before_sites)

	world.call("rebuild_for_seed", REBUILD_SEED)
	await process_frame

	check(int(world.get(&"world_seed")) == REBUILD_SEED, "the rebuild adopted the new seed")
	check(world.get(&"streamer") != null and world.get(&"nav_baker") != null
			and world.get(&"scatter_field") != null,
		"streamer, nav baker and scatter field were all rebuilt, not left dangling")
	check(_height_profile(world) != before_heights,
		"the island itself changed — the height profile differs from seed %d's" % boot_seed)
	check(world.get(&"spawn_position") != before_spawn,
		"landfall moved with it (%s -> %s)" % [before_spawn, world.get(&"spawn_position")])
	check((world.get(&"poi_sites") as Array).size() > 0,
		"the new island still gets POI sites (%d)"
			% (world.get(&"poi_sites") as Array).size())
	check(_named_child_count(world, "PoiSites") == 1 and _named_child_count(world, "SpawnMarker") == 1,
		"the previous island's PoiSites/SpawnMarker were torn down, not duplicated")

	# A rebuild must be indistinguishable from a boot on the same seed, or two peers restarting from
	# the same broadcast would derive different islands — the exact desync this whole path exists to
	# avoid. Built fresh in a second scene and compared.
	var fresh_scene := Node3D.new()
	fresh_scene.name = "ReseedCheckFreshScene"
	root.add_child(fresh_scene)
	game_state.call("set_replicated_seed", REBUILD_SEED)
	var fresh: Node3D = ProceduralWorldScript.new()
	fresh.set(&"build_player", false)
	fresh_scene.add_child(fresh)
	await process_frame

	check(_height_profile(world) == _height_profile(fresh),
		"a rebuilt island is byte-identical to one BOOTED on the same seed")
	check(world.get(&"spawn_position") == fresh.get(&"spawn_position"),
		"...and picks the identical spawn")
	check((world.get(&"poi_sites") as Array).size() == (fresh.get(&"poi_sites") as Array).size(),
		"...and the identical POI count")


# ── helpers ─────────────────────────────────────────────────────────────────────────────────────


func _height_profile(world: Node3D) -> PackedFloat32Array:
	var out: PackedFloat32Array = []
	for point: Vector2 in PROBE_POINTS:
		out.append(float(world.call("height_at", point.x, point.y)))
	return out


func _named_child_count(parent: Node, child_name: String) -> int:
	var found: int = 0
	for child: Node in parent.get_children():
		if child.name == child_name:
			found += 1
	return found


## Constants are not properties — `Object.get()` returns null for one — so read them off the script
## itself. Going through the real constants rather than re-typing their values is what makes a rename
## on either side fail this check loudly instead of quietly asserting nothing.
func _script_const(node: Node, name: StringName) -> Variant:
	var script: Script = node.get_script() as Script
	if script == null:
		return null
	return script.get_script_constant_map().get(name, null)


func _seed_chunk(world_delta_log: Node) -> Vector2i:
	return _script_const(world_delta_log, &"SEED_CHUNK") as Vector2i


func _seed_kind(world_delta_log: Node) -> StringName:
	return StringName(_script_const(world_delta_log, &"SEED_KIND"))


func _seed_key(world_delta_log: Node) -> String:
	return String(_script_const(world_delta_log, &"SEED_KEY"))


func _cycle_service() -> Node:
	return root.get_node_or_null(^"CycleService")


func _first_chest() -> Node:
	for node: Node in get_nodes_in_group(&"chest"):
		return node
	return null


## Reads one number off the chest's own RNG stream without opening anything — enough to tell two
## streams apart, which is all this needs. `_rng` is private by convention, not by the language, and
## a check reaching into it is cheaper than a debug accessor nothing else wants.
func _peek_chest_roll(chest: Node) -> float:
	var rng: RandomNumberGenerator = chest.get(&"_rng")
	return 0.0 if rng == null else rng.randf()


func _on_seed_ready(value: int) -> void:
	seed_ready_values.append(value)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	print("\nRUN_RESEED_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)
