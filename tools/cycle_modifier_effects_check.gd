extends SceneTree

## F-245: proof that each of the seven authored Cycle Modifiers actually changes something, not just
## that the deck draws them (tools/cycle_modifier_check.gd already covers that half). Every subtest
## forces its one modifier active by writing `CycleModifierService._active_ids` directly — the same
## private-state-injection convention cycle_modifier_check.gd's own incompatibility tests already use
## — rather than waiting on a real weighted draw to land on it.
##
##   .agent/bin/agent godot --script tools/cycle_modifier_effects_check.gd

const SIM := preload("res://world/mire/mire_grid_sim.gd")

var failures: int = 0
var cycle_modifier_service: Node
var mire_grid: Node
var day_night: Node
var wave_spawner: Node
var enemy_world: Node
var powerup_service: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await physics_frame

	cycle_modifier_service = root.get_node_or_null(^"CycleModifierService")
	mire_grid = root.get_node_or_null(^"MireGrid")
	day_night = root.get_node_or_null(^"DayNight")
	wave_spawner = root.get_node_or_null(^"WaveSpawner")
	enemy_world = root.get_node_or_null(^"EnemyWorld")
	powerup_service = root.get_node_or_null(^"PowerupService")
	check(cycle_modifier_service != null, "CycleModifierService autoload exists")
	check(mire_grid != null, "MireGrid autoload exists")
	check(day_night != null, "DayNight autoload exists")
	check(wave_spawner != null, "WaveSpawner autoload exists")
	check(enemy_world != null, "EnemyWorld autoload exists")
	check(powerup_service != null, "PowerupService autoload exists")
	if cycle_modifier_service == null or mire_grid == null or day_night == null \
			or wave_spawner == null or enemy_world == null or powerup_service == null:
		finish()
		return

	await _check_drought()
	await _check_long_night()
	await _check_tithe()
	await _check_static()
	await _check_rooted()
	await _check_bloom()
	await _check_the_hunt()

	# Standing rule 4 (docs/SPECS.md): declare the dummy renderer's own provoked noise by pattern
	# rather than silencing it — the_hunt's elite is a tinted `tusker` (EnemyDef.visual_tint), and
	# building a tinted enemy's visual triggers the identical harmless
	# `material_get_instance_shader_parameters` spam tools/bog_crawler_check.gd's own header already
	# documents under a plain `--headless` run.
	print(
		"\nCYCLE_MODIFIER_EFFECTS_CHECK failures=%d · EXPECTED_ERROR_PATTERNS=\"Parameter \\\"material\\\" is null\""
		% failures
	)
	finish()


func _force_modifier(id: StringName) -> void:
	var active: Array[StringName] = [id]
	cycle_modifier_service.set(&"_active_ids", active)


func _clear_modifiers() -> void:
	var active: Array[StringName] = []
	cycle_modifier_service.set(&"_active_ids", active)
	cycle_modifier_service.set(&"_drought_cleared", false)


# ── drought: Harvestable yield halves until the next Wellspring cap ──────────────────────────────


func _check_drought() -> void:
	print("\n== drought: Harvestable yield ==")
	const HARVESTABLE_SCRIPT := preload("res://systems/harvesting/harvestable.gd")
	const HARVESTABLE_DEF_SCRIPT := preload("res://systems/harvesting/harvestable_def.gd")
	const ITEM_DEF_SCRIPT := preload("res://systems/inventory/item_def.gd")
	const EVENT_BUS := preload("res://core/events/event_bus.gd")

	var registry: Node = root.get_node_or_null(^"Registry")
	var item: Resource = ITEM_DEF_SCRIPT.new()
	item.set("id", &"check_drought_log")
	var items: Dictionary = registry.get("items")
	items[&"check_drought_log"] = item
	registry.set("items", items)

	var definition: Resource = HARVESTABLE_DEF_SCRIPT.new()
	definition.set("id", &"check_drought_tree")
	definition.set("max_health", 1)
	definition.set("damage_per_hit", 1)
	definition.set("yield_item_id", &"check_drought_log")
	definition.set("yield_amount", 10)
	definition.set("respawn_seconds", 999.0)
	definition.set("request_cooldown_seconds", 0.0)

	var yields: Array[int] = []
	# A lambda held in EVENT_BUS's static subscriber array past this script's own teardown crashes
	# the process at exit (a GDScript closure outliving the script instance that created it) — stored
	# so it can be unsubscribed by the exact same Callable before this function returns.
	var yield_listener: Callable = func(_kind, _peer, _item, amount, _pos): yields.append(amount)
	EVENT_BUS.subscribe_harvest_yielded(yield_listener)

	_clear_modifiers()
	var normal_prop: Node3D = HARVESTABLE_SCRIPT.new() as Node3D
	normal_prop.name = "CheckDroughtNormal"
	normal_prop.set("definition", definition)
	root.add_child(normal_prop)
	await process_frame
	normal_prop.call("host_apply_damage", 1, 1)
	check(yields.size() == 1 and yields[0] == 10, "no drought: full yield (%s)" % str(yields))
	normal_prop.queue_free()

	yields.clear()
	_force_modifier(&"drought")
	var drought_prop: Node3D = HARVESTABLE_SCRIPT.new() as Node3D
	drought_prop.name = "CheckDroughtActive"
	drought_prop.set("definition", definition)
	root.add_child(drought_prop)
	await process_frame
	drought_prop.call("host_apply_damage", 1, 1)
	check(yields.size() == 1 and yields[0] == 5, "drought active: yield halved (%s)" % str(yields))
	drought_prop.queue_free()

	yields.clear()
	EVENT_BUS.emit_wellspring_capped(&"CheckDroughtWellspring", Vector3.ZERO)
	check(not bool(cycle_modifier_service.call("drought_active")),
		"a Wellspring cap clears drought's effect (has_modifier still true, drought_active false)")
	check(bool(cycle_modifier_service.call("has_modifier", &"drought")),
		"drought stays on the permanent draw stack — only its effect cleared")

	var cleared_prop: Node3D = HARVESTABLE_SCRIPT.new() as Node3D
	cleared_prop.name = "CheckDroughtCleared"
	cleared_prop.set("definition", definition)
	root.add_child(cleared_prop)
	await process_frame
	cleared_prop.call("host_apply_damage", 1, 1)
	check(yields.size() == 1 and yields[0] == 10,
		"after the cap: yield back to full (%s)" % str(yields))
	cleared_prop.queue_free()

	EVENT_BUS.unsubscribe_harvest_yielded(yield_listener)
	_clear_modifiers()


# ── long_night: DayNight advances at half rate while in the night phase ──────────────────────────


func _check_long_night() -> void:
	print("\n== long_night: DayNight rate ==")
	day_night.call("host_set_time", 0.4)  # daytime
	var day_before: float = float(day_night.get("time_of_day"))
	day_night.call("host_advance", 10.0)
	var day_delta_normal: float = float(day_night.get("time_of_day")) - day_before

	day_night.call("host_set_time", 0.8)  # night
	var night_before: float = float(day_night.get("time_of_day"))
	day_night.call("host_advance", 10.0)
	var night_delta_normal: float = float(day_night.get("time_of_day")) - night_before
	check(is_equal_approx(day_delta_normal, night_delta_normal),
		"no long_night: day and night advance at the same rate (%.5f vs %.5f)"
		% [day_delta_normal, night_delta_normal])

	_force_modifier(&"long_night")
	day_night.call("host_set_time", 0.4)
	var day_before_ln: float = float(day_night.get("time_of_day"))
	day_night.call("host_advance", 10.0)
	var day_delta_ln: float = float(day_night.get("time_of_day")) - day_before_ln
	check(is_equal_approx(day_delta_ln, day_delta_normal),
		"long_night active: daytime rate is untouched (%.5f)" % day_delta_ln)

	day_night.call("host_set_time", 0.8)
	var night_before_ln: float = float(day_night.get("time_of_day"))
	day_night.call("host_advance", 10.0)
	var night_delta_ln: float = float(day_night.get("time_of_day")) - night_before_ln
	check(is_equal_approx(night_delta_ln, night_delta_normal * 0.5),
		"long_night active: night advances at half rate (%.5f vs half of %.5f)"
		% [night_delta_ln, night_delta_normal])

	_clear_modifiers()


# ── tithe: Wellspring.required_players ────────────────────────────────────────────────────────────


func _check_tithe() -> void:
	print("\n== tithe: Wellspring.required_players ==")
	const WELLSPRING_SCRIPT := preload("res://systems/wellspring/wellspring.gd")

	var solo_player := Node3D.new()
	solo_player.name = "1"
	solo_player.add_to_group(&"players")
	root.add_child(solo_player)
	solo_player.global_position = Vector3(500.0, 0.0, 500.0)

	_force_modifier(&"tithe")
	var solo_wellspring := WELLSPRING_SCRIPT.new() as Node3D
	solo_wellspring.name = "CheckTitheSolo"
	root.add_child(solo_wellspring)
	solo_wellspring.global_position = solo_player.global_position
	solo_wellspring.call("request_toggle_channel")
	check(int(solo_wellspring.get("required_players")) == 1,
		"tithe active, solo: still 1 (tithe never bricks a solo cap) (%d)"
		% int(solo_wellspring.get("required_players")))
	solo_wellspring.queue_free()
	solo_player.queue_free()
	enemy_world.call("host_despawn_all")
	await process_frame

	var coop_a := Node3D.new()
	coop_a.name = "1"
	coop_a.add_to_group(&"players")
	root.add_child(coop_a)
	coop_a.global_position = Vector3(500.0, 0.0, 500.0)
	var coop_b := Node3D.new()
	coop_b.name = "2"
	coop_b.add_to_group(&"players")
	root.add_child(coop_b)
	coop_b.global_position = Vector3(500.0, 0.0, 500.0)

	var normal_wellspring := WELLSPRING_SCRIPT.new() as Node3D
	normal_wellspring.name = "CheckTitheCoopNormal"
	root.add_child(normal_wellspring)
	normal_wellspring.global_position = coop_a.global_position
	_clear_modifiers()
	normal_wellspring.call("request_toggle_channel")
	check(int(normal_wellspring.get("required_players")) == 2,
		"no tithe, co-op: 2 (%d)" % int(normal_wellspring.get("required_players")))
	normal_wellspring.queue_free()
	enemy_world.call("host_despawn_all")

	_force_modifier(&"tithe")
	var tithe_wellspring := WELLSPRING_SCRIPT.new() as Node3D
	tithe_wellspring.name = "CheckTitheCoop"
	root.add_child(tithe_wellspring)
	tithe_wellspring.global_position = coop_a.global_position
	tithe_wellspring.call("request_toggle_channel")
	check(int(tithe_wellspring.get("required_players")) == 3,
		"tithe active, co-op: raised to 3 (%d)" % int(tithe_wellspring.get("required_players")))
	tithe_wellspring.queue_free()
	coop_a.queue_free()
	coop_b.queue_free()
	enemy_world.call("host_despawn_all")
	await process_frame
	_clear_modifiers()


# ── static: Chest price halved, powerup entries never roll ───────────────────────────────────────


func _check_static() -> void:
	print("\n== static: Chest price + powerup gate ==")
	const CHEST_SCRIPT := preload("res://systems/loot/chest.gd")

	var chest := CHEST_SCRIPT.new() as Node3D
	chest.name = "CheckStaticChest"
	chest.set("tier", &"basic")  # a real registered tier (content/loot/basic.tres) — avoids the
	# "has no tier" configuration error; irrelevant to _price_for/_unlock_check, which read no
	# configuration-validated state of their own.
	chest.set("cost_coins", 100)
	root.add_child(chest)
	await process_frame

	_clear_modifiers()
	check(int(chest.call("_price_for", 1)) == 100, "no static: full price (%d)"
		% int(chest.call("_price_for", 1)))

	_force_modifier(&"static")
	check(int(chest.call("_price_for", 1)) == 50, "static active: price halved (%d)"
		% int(chest.call("_price_for", 1)))
	var static_gate: Callable = chest.call("_unlock_check")
	check(static_gate.is_valid() and not bool(static_gate.call(&"anything")),
		"static active: the powerup gate refuses every entry, unconditionally")

	chest.queue_free()
	_clear_modifiers()


# ── rooted: a Ward's spread-resistance stops applying ────────────────────────────────────────────


func _check_rooted() -> void:
	print("\n== rooted: MireGrid ward resistance ==")
	mire_grid.call("ensure_ready")
	var saved_provider: Callable = mire_grid.get(&"_ward_circles_provider")

	var origin_cell := Vector2i(200, 200)
	var neighbor_cell := Vector2i(201, 200)
	var origin_pos: Vector2 = SIM.cell_to_world_center(origin_cell.x, origin_cell.y)
	var neighbor_pos: Vector2 = SIM.cell_to_world_center(neighbor_cell.x, neighbor_cell.y)
	var origin_world := Vector3(origin_pos.x, 0.0, origin_pos.y)
	var neighbor_world := Vector3(neighbor_pos.x, 0.0, neighbor_pos.y)

	mire_grid.call(&"set_ward_circles_provider", func() -> Array:
		return [{"position": neighbor_pos, "radius": SIM.CELL_SIZE_M * 0.5}]
	)

	_clear_modifiers()
	mire_grid.call("host_set_corruption_at", origin_world, 1.0)
	mire_grid.call("host_set_corruption_at", neighbor_world, 0.0)
	mire_grid.call("_tick")
	check(is_equal_approx(float(mire_grid.call("corruption_at", neighbor_world)), 0.0),
		"no rooted: the Ward still resists spread into its radius")

	_force_modifier(&"rooted")
	mire_grid.call("host_set_corruption_at", origin_world, 1.0)
	mire_grid.call("host_set_corruption_at", neighbor_world, 0.0)
	mire_grid.call("_tick")
	check(float(mire_grid.call("corruption_at", neighbor_world)) > 0.0,
		"rooted active: the same Ward no longer resists — corruption reached it (%.4f)"
		% float(mire_grid.call("corruption_at", neighbor_world)))

	mire_grid.set(&"_ward_circles_provider", saved_provider)
	mire_grid.call("host_set_corruption_at", origin_world, 0.0)
	mire_grid.call("host_set_corruption_at", neighbor_world, 0.0)
	mire_grid.call("flush_deltas")
	_clear_modifiers()


# ── bloom: a death while active spawns two reduced-health children ───────────────────────────────


func _check_bloom() -> void:
	print("\n== bloom: Enemy death split ==")
	check(bool(enemy_world.call("has_def", &"crawler")), "the crawler definition is registered")
	if not bool(enemy_world.call("has_def", &"crawler")):
		return
	var def: Resource = enemy_world.call("get_def", &"crawler")
	var max_health: int = int(def.get("max_health"))
	var spawn_position := Vector3(900.0, 0.0, 900.0)

	_clear_modifiers()
	var normal_count_before: int = int(enemy_world.call("live_count"))
	var normal_enemy: Node3D = enemy_world.call("host_spawn", &"crawler", spawn_position)
	await process_frame
	normal_enemy.call("host_apply_damage", max_health, 1)
	await process_frame
	check(int(enemy_world.call("live_count")) == normal_count_before,
		"no bloom: a kill leaves the population where it started (no split)")
	enemy_world.call("host_despawn_all")
	await process_frame

	_force_modifier(&"bloom")
	var bloom_count_before: int = int(enemy_world.call("live_count"))
	var bloom_enemy: Node3D = enemy_world.call("host_spawn", &"crawler", spawn_position)
	await process_frame
	bloom_enemy.call("host_apply_damage", max_health, 1)
	await process_frame
	check(int(enemy_world.call("live_count")) == bloom_count_before + 2,
		"bloom active: a kill nets +2 live children (%d -> %d)"
		% [bloom_count_before, int(enemy_world.call("live_count"))])

	var found_reduced: bool = false
	for node: Node in enemy_world.call("live_enemies"):
		if is_instance_valid(node) and int(node.get("health")) == maxi(max_health / 2, 1):
			found_reduced = true
	check(found_reduced, "at least one child spawned at the reduced (half) health")

	enemy_world.call("host_despawn_all")
	await process_frame
	_clear_modifiers()


# ── the_hunt: one tracking elite per Cycle, retargeted off the powerup leaderboard ────────────────


func _check_the_hunt() -> void:
	print("\n== the_hunt: WaveSpawner tracking elite ==")
	var marker := Node3D.new()
	marker.name = "CheckHuntNestMarker"
	marker.add_to_group(&"authored_world_marker")
	marker.set_meta(&"kind", "enemy_nest")
	root.add_child(marker)
	marker.global_position = Vector3(950.0, 0.0, 950.0)
	await process_frame

	var player_a := Node3D.new()
	player_a.name = "1"
	player_a.add_to_group(&"players")
	root.add_child(player_a)
	var player_b := Node3D.new()
	player_b.name = "2"
	player_b.add_to_group(&"players")
	root.add_child(player_b)
	powerup_service.call("host_clear", 1)
	powerup_service.call("host_clear", 2)

	_clear_modifiers()
	var before_no_hunt: int = int(enemy_world.call("live_count"))
	wave_spawner.call(&"_maybe_spawn_hunt_elite")
	check(int(enemy_world.call("live_count")) == before_no_hunt,
		"no the_hunt: no elite spawned on a Cycle check")

	_force_modifier(&"the_hunt")
	wave_spawner.call(&"_maybe_spawn_hunt_elite")
	var elite: Node3D = wave_spawner.get(&"_hunt_elite")
	check(elite != null and is_instance_valid(elite) and String(elite.get("definition").get("id")) == "tusker",
		"the_hunt active: one tusker elite spawned and tracked")

	# host_grant() refuses an unregistered id, so the stack is forced directly instead — the same
	# synthetic-injection convention every other check here already uses for its own throwaway
	# content, avoiding a real content/powerups/*.tres just to exercise the leaderboard math.
	var stacks: Dictionary = powerup_service.get(&"_stacks")
	stacks[2] = {&"check_hunt_powerup": 5}
	powerup_service.set(&"_stacks", stacks)
	check(int(powerup_service.call("total_stacks", 2)) == 5, "peer 2 now leads the leaderboard (5 stacks)")

	wave_spawner.call(&"_retarget_hunt_elite")
	check(elite.call("target_peer") == 2,
		"the elite retargeted to whoever leads the leaderboard (peer 2, got %d)"
		% int(elite.call("target_peer")))

	# Deliberately never despawns `elite` (a tinted tusker, EnemyDef.visual_tint): freeing a
	# duplicated-material mesh mid-run trips the dummy renderer's harmless
	# `material_get_instance_shader_parameters` teardown noise into a hard crash instead of the
	# inert ERROR spam bog_crawler_check.gd's own header documents — same root cause, so this
	# leaves the elite parented and lets process exit clean it up, exactly that check's convention.
	powerup_service.call("host_clear", 2)
	_clear_modifiers()

	await _check_the_hunt_on_the_drawn_cycle()


# ── F-282: the_hunt on the Cycle it is DRAWN, through a real advance ─────────────────────────────


## Everything above forces `_active_ids` and calls `_maybe_spawn_hunt_elite()` by hand, which is what
## let F-282 ship: the elite spawned when poked, but never on the Cycle the draw actually happened,
## because `project.godot` registers WaveSpawner (line 44) before CycleModifierService (line 61) and
## `EventBus` invokes `cycle_advanced` listeners in registration order. This phase pokes nothing —
## it drives `CycleService.host_advance_cycle()` and asserts what the player would see.
##
## The deck is narrowed to `the_hunt` alone (`_defs`, the same private-state injection
## tools/cycle_modifier_seed_check.gd uses on this exact field) so the draw is forced rather than
## rolled, and `CycleService._current_cycle` is set to `min_cycle - 1` so the single advance lands on
## the first Cycle where `weight_at()` is positive — `the_hunt` is `min_cycle = 6`, so a check that
## advanced from 1 would draw nothing at all and pass vacuously.
func _check_the_hunt_on_the_drawn_cycle() -> void:
	print("\n== F-282: the_hunt's elite enters on the Cycle it is drawn, not the next one ==")
	var cycle_service: Node = root.get_node_or_null(^"CycleService")
	check(cycle_service != null, "CycleService autoload exists")
	if cycle_service == null:
		return

	var hunt_def: Resource = cycle_modifier_service.call("def_for", &"the_hunt")
	check(hunt_def != null, "the_hunt def is loaded")
	if hunt_def == null:
		return

	# `_defs` is a Dictionary — a reference — so `defs_before` keeps pointing at the real deck while
	# `_defs` is swapped for the one-card one, and restoring it is a plain re-`set()`.
	var defs_before: Dictionary = cycle_modifier_service.get(&"_defs")
	cycle_modifier_service.set(&"_defs", {&"the_hunt": hunt_def})
	_clear_modifiers()
	wave_spawner.set(&"_hunt_elite", null)
	wave_spawner.set(&"_hunt_spawned_cycle", 0)

	var target_cycle: int = int(hunt_def.get(&"min_cycle"))
	cycle_service.set(&"_current_cycle", target_cycle - 1)
	var live_before: int = int(enemy_world.call("live_count"))
	var advanced_to: int = int(cycle_service.call("host_advance_cycle"))
	await process_frame

	check(advanced_to == target_cycle,
		"a real advance reached Cycle %d (got %d)" % [target_cycle, advanced_to])
	check(bool(cycle_modifier_service.call("has_modifier", &"the_hunt")),
		"the_hunt was drawn by that advance")
	var elite: Node3D = wave_spawner.get(&"_hunt_elite")
	check(elite != null and is_instance_valid(elite),
		"F-282: the elite is on the ground on the SAME Cycle the_hunt was drawn")
	check(int(wave_spawner.get(&"_hunt_spawned_cycle")) == target_cycle,
		"the spawn is stamped against Cycle %d" % target_cycle)
	check(int(enemy_world.call("live_count")) == live_before + 1,
		"exactly ONE elite entered — both cycle_advanced and cycle_modifier_drawn drive the same "
		+ ("idempotent spawn (live %d -> %d)"
			% [live_before, int(enemy_world.call("live_count"))]))

	# The same Cycle firing again (a re-announced advance, a console `host_draw_modifier`) must not
	# add a second elite; the NEXT Cycle must. Both are the per-Cycle stamp, from opposite sides.
	wave_spawner.call(&"_maybe_spawn_hunt_elite", target_cycle)
	check(int(enemy_world.call("live_count")) == live_before + 1,
		"a repeat trigger on the same Cycle spawns nothing more")
	cycle_service.call("host_advance_cycle")
	await process_frame
	check(int(enemy_world.call("live_count")) == live_before + 2,
		"the next Cycle spawns the next elite, so the per-Cycle cadence the_hunt.tres describes "
		+ "is intact")

	# Elites left parented on purpose — see the teardown note in `_check_the_hunt()` above.
	cycle_modifier_service.set(&"_defs", defs_before)
	_clear_modifiers()
	wave_spawner.set(&"_hunt_elite", null)
	wave_spawner.set(&"_hunt_spawned_cycle", 0)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
