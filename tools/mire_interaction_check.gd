extends SceneTree

## Task 4.11 (docs/SPECS.md): the four small Mire consumers 4.9's MireGrid unblocked — rotted
## resource yields, the Blight debuff, corrupted spawn tables, and Ward resistance. Single-process,
## offline (host-of-one): every owning system's OWN host-authority is already proven by its own net
## check (inventory_net_check.gd, player_health_net_check.gd, wave_spawner_check.gd,
## build_net_check.gd) — this file only proves the new corruption-driven behaviour layered on top of
## each.
##
##   .agent/bin/agent godot --script tools/mire_interaction_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")

var failures: int = 0
var mire_grid: Node
var inventory: Node
var player_health: Node
var build_service: Node
var wave_spawner: Node
var enemy_world: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return

	# The harness owns time from here — see wave_spawner_check.gd's own note on why.
	mire_grid.call("ensure_ready")
	mire_grid.set_physics_process(false)
	player_health.set_physics_process(false)

	_check_rotted_yield()
	await _check_blight_debuff()
	await _check_corrupted_spawns()
	_check_ward_resistance()

	# `_check_corrupted_spawns()` above spawns real bog_crawler bodies at full corruption, so F-158's
	# visual_tint (systems/enemies/enemy.gd `_apply_visual_tint()`) runs for real and can provoke the
	# dummy renderer's own harmless `material_get_instance_shader_parameters` noise on every surface
	# override it sets — see tools/bog_crawler_check.gd's header for why. Whether it fires this run
	# depends on the corrupted-spawn roll actually landing on bog_crawler at least once, so declare it
	# unconditionally rather than relying on the roll. Standing rule 4 (docs/SPECS.md): declare by
	# pattern rather than silencing it.
	print(
		"\nMIRE_INTERACTION_CHECK failures=%d · EXPECTED_ERROR_PATTERNS=\"Parameter \\\"material\\\" is null\""
		% failures
	)
	finish()


func _check_wiring() -> bool:
	print("== the shipped project actually wires every 4.11 consumer ==")
	mire_grid = root.get_node_or_null(^"MireGrid")
	inventory = root.get_node_or_null(^"InventoryService")
	player_health = root.get_node_or_null(^"PlayerHealth")
	build_service = root.get_node_or_null(^"BuildService")
	wave_spawner = root.get_node_or_null(^"WaveSpawner")
	enemy_world = root.get_node_or_null(^"EnemyWorld")
	var all_present: bool = mire_grid != null and inventory != null and player_health != null \
		and build_service != null and wave_spawner != null and enemy_world != null
	check(all_present, "MireGrid, InventoryService, PlayerHealth, BuildService, WaveSpawner and EnemyWorld are all registered")
	return all_present


# ── Rotted resource yields ───────────────────────────────────────────────────────────────────────


func _check_rotted_yield() -> void:
	print("\n== rotted resource yields ==")
	var clean_position := Vector3(300.0, 0.0, 300.0)
	var corrupted_position := Vector3(-300.0, 0.0, -300.0)
	mire_grid.call("host_set_corruption_at", clean_position, 0.0)
	mire_grid.call("host_set_corruption_at", corrupted_position, 1.0)

	# F-535: a yield now lands on the ground first, so the rot is measured on the DROP's stack
	# rather than on the pack — the rot itself still happens in InventoryService, unchanged.
	var peer_id: int = NetConfig.HOST_PEER_ID
	EVENT_BUS.emit_harvest_yielded(&"test_tree", peer_id, &"log", 10, clean_position)
	var clean_granted: int = _dropped_amount()
	check(clean_granted == 10, "clean ground yields the full amount (%d/10)" % clean_granted)

	EVENT_BUS.emit_harvest_yielded(&"test_tree", peer_id, &"log", 10, corrupted_position)
	var corrupted_granted: int = _dropped_amount()
	check(corrupted_granted >= 1 and corrupted_granted < 10,
		"fully corrupted ground rots part of the yield away, never all of it (%d/10)" % corrupted_granted)


## The stack on the single drop the last yield produced, then clears the ground again so the next
## yield is measured on its own. Zero when no drop service is registered at all.
func _dropped_amount() -> int:
	var drops: Node = root.get_node_or_null(^"ItemDropService")
	if drops == null:
		return 0
	var amount: int = 0
	for drop: Node in (drops.call("live_drops") as Array):
		amount += int(drop.get(&"amount"))
	drops.call("host_clear_all")
	return amount


# ── Blight debuff ─────────────────────────────────────────────────────────────────────────────────


func _check_blight_debuff() -> void:
	print("\n== Blight debuff ==")
	var clean_peer: int = NetConfig.HOST_PEER_ID
	var corrupted_peer: int = 2
	player_health.call("_ensure_host_state", corrupted_peer)

	var clean_body := Node3D.new()
	clean_body.name = str(clean_peer)
	clean_body.set_multiplayer_authority(clean_peer)
	clean_body.add_to_group(&"players")
	clean_body.position = Vector3(500.0, 0.0, 500.0)
	root.add_child(clean_body)

	var corrupted_body := Node3D.new()
	corrupted_body.name = str(corrupted_peer)
	corrupted_body.set_multiplayer_authority(corrupted_peer)
	corrupted_body.add_to_group(&"players")
	corrupted_body.position = Vector3(-500.0, 0.0, -500.0)
	root.add_child(corrupted_body)
	await process_frame

	mire_grid.call("host_set_corruption_at", clean_body.position, 0.0)
	mire_grid.call("host_set_corruption_at", corrupted_body.position, 1.0)

	var clean_hp_before: int = int(player_health.call("host_hp", clean_peer))
	var corrupted_hp_before: int = int(player_health.call("host_hp", corrupted_peer))

	for _tick_index: int in 10:
		player_health.call("_physics_process", 1.0)

	var clean_hp_after: int = int(player_health.call("host_hp", clean_peer))
	var corrupted_hp_after: int = int(player_health.call("host_hp", corrupted_peer))
	check(clean_hp_after == clean_hp_before,
		"clean ground never applies Blight (%d -> %d)" % [clean_hp_before, clean_hp_after])
	check(corrupted_hp_after < corrupted_hp_before,
		"full corruption drains hp over time, same transition path as starvation (%d -> %d)" % [
			corrupted_hp_before, corrupted_hp_after
		])

	clean_body.queue_free()
	corrupted_body.queue_free()
	await process_frame


# ── Corrupted spawn tables ───────────────────────────────────────────────────────────────────────


func _check_corrupted_spawns() -> void:
	print("\n== corrupted spawn tables ==")
	enemy_world.call("host_despawn_all")
	await process_frame

	var clean_position := Vector3(600.0, 0.0, 600.0)
	var corrupted_position := Vector3(-600.0, 0.0, -600.0)
	mire_grid.call("host_set_corruption_at", clean_position, 0.0)
	mire_grid.call("host_set_corruption_at", corrupted_position, 1.0)

	wave_spawner.call("host_spawn_wave_at", clean_position, 30, &"crawler", 0.5)
	await process_frame
	var clean_bog_count: int = _count_kind(&"bog_crawler")
	check(clean_bog_count == 0,
		"clean ground never substitutes the corrupted variant (%d/30 bog_crawler)" % clean_bog_count)

	enemy_world.call("host_despawn_all")
	await process_frame

	wave_spawner.call("host_spawn_wave_at", corrupted_position, 30, &"crawler", 0.5)
	await process_frame
	var corrupted_bog_count: int = _count_kind(&"bog_crawler")
	check(corrupted_bog_count > 0,
		"fully corrupted ground substitutes bog_crawler some of the time (%d/30)" % corrupted_bog_count)

	enemy_world.call("host_despawn_all")
	await process_frame


func _count_kind(kind: StringName) -> int:
	var total: int = 0
	for enemy: Node in enemy_world.call("live_enemies"):
		if not is_instance_valid(enemy):
			continue
		var def: Resource = enemy.get(&"definition")
		if def != null and StringName(String(def.get(&"id"))) == kind:
			total += 1
	return total


# ── Ward resistance ───────────────────────────────────────────────────────────────────────────────


## The real placement pipeline (PlacementValidator, cost, range) is already covered by
## build_check.gd/build_net_check.gd — this only proves 4.11's own addition: that a placed Ward's
## live position/radius reaches BuildService.ward_radii(), and that MireGrid's own tick was actually
## wired to call it. A piece is planted directly into BuildService's own _placed/_container rather
## than going through request_place(), the same "test the seam, not the whole pipeline again" call
## seed_sync_check.gd's own header note makes about WorldDeltaLog.
func _check_ward_resistance() -> void:
	print("\n== Ward resistance wiring ==")
	var container: Node3D = build_service.get(&"_container")
	var placed: Dictionary = build_service.get(&"_placed")
	var ward_piece := Node3D.new()
	ward_piece.name = "TestWardPiece"
	ward_piece.position = Vector3(50.0, 0.0, 50.0)
	container.add_child(ward_piece)
	placed[StringName("TestWardPiece")] = {"def": &"ward_post", "owner": NetConfig.HOST_PEER_ID}

	var circles: Array = build_service.call("ward_radii")
	var found: Dictionary = {}
	for circle: Dictionary in circles:
		var position: Vector2 = circle.get("position", Vector2.ZERO)
		if position.distance_to(Vector2(50.0, 50.0)) < 0.01:
			found = circle
			break
	check(not found.is_empty(), "ward_radii() reports the placed Ward's live position")
	check(is_equal_approx(float(found.get("radius", 0.0)), 12.0),
		"ward_radii() reports ward_post's real ward_radius_m (12.0), not a placeholder")

	var provider: Callable = mire_grid.get(&"_ward_circles_provider")
	check(provider.is_valid(),
		"BuildService wired itself into MireGrid.set_ward_circles_provider() on boot")
	if provider.is_valid():
		var wired_circles: Array = provider.call()
		var wired_found: bool = false
		for circle: Dictionary in wired_circles:
			var position: Vector2 = circle.get("position", Vector2.ZERO)
			if position.distance_to(Vector2(50.0, 50.0)) < 0.01:
				wired_found = true
				break
		check(wired_found,
			"the wired provider (called from MireGrid's own tick) returns this exact Ward")

	placed.erase(StringName("TestWardPiece"))
	ward_piece.queue_free()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
