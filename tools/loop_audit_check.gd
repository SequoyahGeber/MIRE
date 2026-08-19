extends SceneTree

## THE GAME-LOOP AUDIT (2026-08-19, hollow7). Boots the SHIPPED map — levels/hollowmere.tscn, the
## exact scene project.godot names as run/main_scene — and walks the whole player arc through the
## real front doors: spawn, harvest, craft, build, eat, night wave, chest, powerup, Wellspring
## downstream, Mire response, Cycle advance, modifier draw, extraction. Two runs, because the run
## has two endings and both are terminal:
##
##   .agent/bin/agent godot --script tools/loop_audit_check.gd                # arc + EXTRACT ending
##   .agent/bin/agent godot --script tools/loop_audit_check.gd -- defeat     # DEFEAT ending
##
## Verbs go through CommandService wherever a verb exists — auditing the loop through the console
## is also an audit OF the console. Direct service seams are used only where no verb exists, and
## each such use is a note in the report: a missing verb is itself a finding of the audit.
##
## Engine.time_scale is raised for the long holds (extraction departure is a 60 s channel) — the
## simulation is delta-accumulated everywhere (ARCHITECTURE.md §5a), which this deliberately leans
## on: if any system broke under time_scale it would be frame-coupled, which is its own bug.
const CommandServiceScript = preload("res://autoload/command_service.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

const SCENE_PATH: String = "res://levels/hollowmere.tscn"
const HOST_PEER: int = 1
const TIMEOUT_SEC: float = 20.0

var failures: int = 0
var notes: PackedStringArray = []
var command_service: CommandServiceScript
var level: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var defeat_mode: bool = OS.get_cmdline_user_args().has("defeat")

	await _phase_boot()
	if level == null:
		_finish()
		return

	if defeat_mode:
		await _phase_defeat_ending()
		_finish()
		return

	await _phase_day_verbs()
	await _phase_night_wave()
	await _phase_chests()
	await _phase_wellspring_downstream()
	await _phase_mire()
	await _phase_cycle()
	await _phase_extraction()
	_finish()


# ── 1 · boot & spawn ─────────────────────────────────────────────────────────────────────────────


func _phase_boot() -> void:
	print("\n== LOOP 1 · the shipped scene boots and a player stands in it ==")
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	check(packed != null, "the main scene loads")
	if packed == null:
		return
	level = packed.instantiate()
	root.add_child(level)
	current_scene = level  # autoloads watch current_scene; nothing sets it for a hand-added child
	for i: int in 30:
		await process_frame
		await physics_frame

	command_service = root.get_node_or_null(^"CommandService") as CommandServiceScript
	check(command_service != null, "CommandService is up")

	var body: Node3D = _player_body()
	check(body != null, "a player body exists in the shipped scene")
	if body != null:
		check(body.global_position.y > -5.0,
			"the player is not under the map (y=%.2f)" % body.global_position.y)

	# The placement services are marker-driven; the markers are the layout's. Count what actually
	# materialized — these numbers ARE the loop's fixtures.
	var wellsprings: int = get_nodes_in_group(&"wellspring").size()
	var chests: int = get_nodes_in_group(&"chest").size()
	var ships: int = get_nodes_in_group(&"extraction_ship").size()
	check(wellsprings >= 1, "WellspringService built %d Wellspring(s) from objective markers" % wellsprings)
	check(chests >= 5, "ChestPlacementService built %d chest(s) from loot markers" % chests)
	check(ships == 1, "ExtractionService built %d extraction ship(s) from the shipwreck marker" % ships)


# ── 2 · the day verbs ────────────────────────────────────────────────────────────────────────────


func _phase_day_verbs() -> void:
	print("\n== LOOP 2 · a day of verbs: harvest, craft, build, eat ==")
	var inventory: Node = root.get_node_or_null(^"InventoryService")

	# HARVEST — a real wired prop, hit through its own host seam until it yields.
	var harvestable: Node = _first_active_harvestable()
	check(harvestable != null, "a live harvestable exists to hit")
	if harvestable != null and inventory != null:
		var definition: Resource = harvestable.get(&"definition")
		var item_id := StringName(String(definition.get(&"yield_item_id"))) if definition != null \
			and definition.get(&"yield_item_id") != null else &""
		if item_id == &"":
			# Property name is the def's business — fall back to observing the depleted signal.
			var seen: Dictionary = {"item": &""}
			harvestable.connect(&"depleted", func(_peer: int, yielded: StringName, _n: int) -> void:
				seen["item"] = yielded)
			var swings: int = 0
			while bool(harvestable.get(&"active")) and swings < 32:
				swings += 1
				harvestable.call("host_apply_tool_damage", 1, 99, HOST_PEER)
				await physics_frame
			item_id = seen["item"]
			check(item_id != &"", "the prop depleted and named its yield (%s, %d swings)" % [item_id, swings])
			check(int(inventory.call("host_count", HOST_PEER, item_id)) > 0,
				"the yield landed in the inventory (%s x%d)"
					% [item_id, int(inventory.call("host_count", HOST_PEER, item_id))])
		else:
			var before: int = int(inventory.call("host_count", HOST_PEER, item_id))
			var swings: int = 0
			while bool(harvestable.get(&"active")) and swings < 32:
				swings += 1
				harvestable.call("host_apply_tool_damage", 1, 99, HOST_PEER)
				await physics_frame
			check(int(inventory.call("host_count", HOST_PEER, item_id)) > before,
				"harvesting yielded %s (%d swings)" % [item_id, swings])

	# CRAFT — stand at a real station marker, let the SERVICE say which station id that is, then
	# craft the first recipe registered for it. Everything read from live content — nothing named.
	var crafting: Node = root.get_node_or_null(^"CraftingService")
	var station: Node3D = _registered_station_marker()
	check(station != null, "a REGISTERED station stands in the scene (a marker whose asset matches "
		+ "a StationDef.world_scene — 8 station markers exist, only the registered ones craft)")
	if station != null and crafting != null:
		await _cmd("tp @s %f %f %f" % [station.global_position.x, station.global_position.y + 1.0,
			station.global_position.z], true)
		await physics_frame
		var station_id := StringName(String(crafting.call("nearby_station_id")))
		check(station_id != &"", "CraftingService sees the player at a station (%s)" % station_id)
		var recipe: Dictionary = _recipe_for_station(station_id)
		check(not recipe.is_empty(), "a recipe exists for station '%s' (%s)" % [station_id, recipe.get("id")])
		if not recipe.is_empty():
			for ingredient: Dictionary in recipe.get("inputs", []):
				await _cmd("give %s %d" % [ingredient["item"], ingredient["amount"]], true)
			var inventory_before: int = int(root.get_node_or_null(^"InventoryService").call(
				"host_count", HOST_PEER, recipe["output"]))
			var request: int = int(crafting.call("request_craft", recipe["id"]))
			check(request > 0, "request_craft accepted (#%d)" % request)
			var got: bool = await _until(func() -> bool:
				return int(root.get_node_or_null(^"InventoryService").call(
					"host_count", HOST_PEER, recipe["output"])) > inventory_before, TIMEOUT_SEC)
			check(got, "the crafted %s arrived in the inventory" % recipe["output"])

	# BUILD — the console verb, against EVERY authored piece until one stands on open ground. The
	# per-piece refusals are audit output in their own right: they exercise the validator's whole
	# vocabulary (support, overlap, water) with words a player will actually read.
	var build_service: Node = root.get_node_or_null(^"BuildService")
	var registry: Node = root.get_node_or_null(^"Registry")
	var verdict: Dictionary = {"seen": false, "ok": false, "reason": ""}
	build_service.connect(&"build_confirmed",
		func(_request: int, accepted: bool, reason: String) -> void:
			verdict["seen"] = true
			verdict["ok"] = accepted
			verdict["reason"] = reason)
	var body: Node3D = _player_body()
	var placed_id: StringName = &""
	var refusals: PackedStringArray = []
	for id: Variant in (registry.get(&"buildables") as Dictionary):
		# Pay the piece's authored cost first — build costs are the design, not an obstacle.
		var def: Resource = (registry.get(&"buildables") as Dictionary)[id]
		for cost_item: StringName in (def.get(&"cost") as Dictionary):
			await _cmd("give %s %d" % [cost_item,
				int((def.get(&"cost") as Dictionary)[cost_item])], true)
		var pieces_before: int = get_nodes_in_group(&"buildable_piece").size()
		var landed: bool = false
		for attempt: int in 3:
			verdict["seen"] = false
			var angle: float = float(attempt) * TAU / 3.0 + 0.4
			var spot: Vector3 = body.global_position \
				+ Vector3(cos(angle) * 5.0, 0.0, sin(angle) * 5.0)
			# Raycast the actual ground: the player's own y is their capsule origin, ~1 m above the
			# terrain, and the support validator probes beneath the piece's BASE. Whether raw
			# player-height coords place or refuse is itself an audit answer — attempt 0 uses the
			# raw y, attempts 1-2 use the grounded y, so the transcript shows both behaviours.
			if attempt > 0:
				var ground: Dictionary = root.world_3d.direct_space_state.intersect_ray(
					PhysicsRayQueryParameters3D.create(spot + Vector3.UP * 3.0,
						spot + Vector3.DOWN * 12.0))
				if not ground.is_empty():
					spot.y = (ground["position"] as Vector3).y
			await _cmd("build %s %f %f %f" % [id, spot.x, spot.y, spot.z], true)
			await _until(func() -> bool: return bool(verdict["seen"]), 5.0)
			if get_nodes_in_group(&"buildable_piece").size() > pieces_before:
				landed = true
				break
		if landed:
			placed_id = StringName(String(id))
			break
		refusals.append("%s: '%s'" % [id, verdict["reason"]])
	check(placed_id != &"",
		"the `build` verb placed a piece on open ground (%s)" % placed_id
			+ ("" if placed_id != &"" else " — every piece refused: %s" % "; ".join(refusals)))
	if not refusals.is_empty():
		note("build refusals on the way: %s" % "; ".join(refusals))

	# EAT — food through the real consume request.
	var food_id: StringName = _first_food_id()
	check(food_id != &"", "a food item exists (%s)" % food_id)
	if food_id != &"":
		var health: Node = root.get_node_or_null(^"PlayerHealth")
		await _cmd("give %s 3" % food_id, true)
		await _cmd("starve 1 10", true)
		var hunger_before: float = float(health.call("host_hunger", HOST_PEER))
		if health.has_method(&"request_consume_item"):
			health.call("request_consume_item", food_id)
			var fed: bool = await _until(func() -> bool:
				return float(health.call("host_hunger", HOST_PEER)) > hunger_before, 5.0)
			check(fed, "eating %s raised hunger %.1f -> %.1f" % [food_id, hunger_before,
				float(health.call("host_hunger", HOST_PEER))])
		else:
			note("PlayerHealth has no request_consume_item — eat is only reachable via UI/RPC")


# ── 3 · night falls and something attacks ────────────────────────────────────────────────────────


func _phase_night_wave() -> void:
	print("\n== LOOP 3 · dusk brings a wave, dawn clears it ==")
	var enemy_world: Node = root.get_node_or_null(^"EnemyWorld")
	var day_count: int = int(enemy_world.call("live_count"))
	await _cmd("time set dusk", true)
	var wave_up: bool = await _until(func() -> bool:
		return int(enemy_world.call("live_count")) > day_count, TIMEOUT_SEC)
	check(wave_up, "dusk spawned a wave (%d -> %d live)" % [day_count, int(enemy_world.call("live_count"))])

	await _cmd("time set dawn", true)
	var cleared: bool = await _until(func() -> bool:
		return int(enemy_world.call("live_count")) <= maxi(day_count, 4), TIMEOUT_SEC)
	check(cleared, "dawn cleared the wave (%d live)" % int(enemy_world.call("live_count")))


# ── 4 · a chest opens and pays out ───────────────────────────────────────────────────────────────


func _phase_chests() -> void:
	print("\n== LOOP 4 · chests: the loot loop pays coins and powerups ==")
	var chest: Node = _cheapest_chest()
	check(chest != null, "an affordable (or free) chest exists")
	if chest == null:
		return
	var cost: int = int(chest.get(&"cost_coins"))
	if cost > 0:
		await _cmd("give coins %d" % cost, true)
	var body: Node3D = _player_body()
	var chest_position: Vector3 = (chest as Node3D).global_position
	await _cmd("tp @s %f %f %f" % [chest_position.x, chest_position.y + 1.0, chest_position.z], true)

	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var powerups: Node = root.get_node_or_null(^"PowerupService")
	var coins_before: int = int(inventory.call("host_count", HOST_PEER, &"coins"))
	var stacks_before: int = (powerups.call("stacks_for", HOST_PEER) as Dictionary).size()

	var outcome: Dictionary = {"seen": false, "ok": false, "granted": {}, "detail": ""}
	chest.connect(&"open_confirmed",
		func(_request: int, accepted: bool, granted: Dictionary, detail: String) -> void:
			outcome["seen"] = true
			outcome["ok"] = accepted
			outcome["granted"] = granted
			outcome["detail"] = detail)
	chest.call("request_open")  # the real public wrapper — routes host-locally offline
	await _until(func() -> bool: return bool(outcome["seen"]), 5.0)
	check(bool(outcome["ok"]), "chest '%s' (cost %d) opened: %s" % [chest.name, cost,
		outcome["detail"] if not bool(outcome["ok"]) else str(outcome["granted"])])
	var coins_after: int = int(inventory.call("host_count", HOST_PEER, &"coins"))
	var stacks_after: int = (powerups.call("stacks_for", HOST_PEER) as Dictionary).size()
	check(coins_after != coins_before or stacks_after > stacks_before
		or not (outcome["granted"] as Dictionary).is_empty(),
		"and the roll paid out: coins %d->%d, powerup kinds %d->%d, granted=%s"
			% [coins_before, coins_after, stacks_before, stacks_after, outcome["granted"]])

	# F-239's regression guard, placed at the one moment the inventory is KNOWN non-empty: the
	# console's own `inv` must render the contents, not "carrying nothing".
	var inv_result: Dictionary = await _cmd("inv", true)
	check(String(inv_result.get("message", "")).contains("coins"),
		"`inv` renders the real contents (F-239): %s"
			% String(inv_result.get("message", "")).split("\n")[0])


# ── 5 · Wellspring: the downstream chain the cap triggers ────────────────────────────────────────


func _phase_wellspring_downstream() -> void:
	print("\n== LOOP 5 · Wellspring cap: rewards, salvage counter, HUD chain ==")
	var wellspring: Node3D = _first_node_in_group(&"wellspring") as Node3D
	if wellspring == null:
		check(false, "no Wellspring in the scene")
		return

	# The channel itself (60 s co-op / 150 s solo presence hold) belongs to 4.8's own checks; this
	# audit drives the DOWNSTREAM contract — what a cap is supposed to set in motion.
	var salvage: Node = root.get_node_or_null(^"SalvageService")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var capped_before: int = int(salvage.call("wellsprings_capped_this_run"))
	var items_before: int = _total_items(inventory)

	EVENT_BUS.emit_wellspring_capped(StringName(wellspring.name), wellspring.global_position)
	await physics_frame
	await physics_frame

	check(int(salvage.call("wellsprings_capped_this_run")) == capped_before + 1,
		"SalvageService counted the cap (%d)" % int(salvage.call("wellsprings_capped_this_run")))
	var items_after: int = _total_items(inventory)
	check(items_after > items_before,
		"RewardService granted the wellspring tier (total items %d -> %d)"
			% [items_before, items_after])
	note("channel presence-hold NOT driven here — 4.8's own checks own it; this drove the cap's downstream")


# ── 6 · the Mire notices ─────────────────────────────────────────────────────────────────────────


func _phase_mire() -> void:
	print("\n== LOOP 6 · the Mire: seeded, spreading, and pushed back by a cap ==")
	var mire: Node = root.get_node_or_null(^"MireGrid")
	if mire == null:
		check(false, "MireGrid autoload missing")
		return
	mire.call("ensure_ready")

	var hot: Vector3 = _most_corrupted_point(mire)
	check(float(mire.call("corruption_at", hot)) > 0.05,
		"the island has seeded corruption (%.3f at %s)" % [float(mire.call("corruption_at", hot)), hot])

	var before: float = float(mire.call("corruption_at", hot))
	EVENT_BUS.emit_wellspring_capped(&"audit_cap", hot)
	await physics_frame
	var after: float = float(mire.call("corruption_at", hot))
	check(after < before,
		"a Wellspring cap at a corrupted point clears it (%.3f -> %.3f)" % [before, after])


# ── 7 · the Cycle turns ──────────────────────────────────────────────────────────────────────────


func _phase_cycle() -> void:
	print("\n== LOOP 7 · Cycle advance: modifier drawn, escalation applied ==")
	var cycle_service: Node = root.get_node_or_null(^"CycleService")
	var modifier_service: Node = root.get_node_or_null(^"CycleModifierService")
	var mire: Node = root.get_node_or_null(^"MireGrid")

	var cycle_before: int = int(cycle_service.call("current_cycle"))
	var modifiers_before: int = (modifier_service.call("active_modifier_ids") as Array).size()
	var spread_before: float = float(cycle_service.call("spread_multiplier"))

	cycle_service.call("host_advance_cycle")
	await physics_frame

	check(int(cycle_service.call("current_cycle")) == cycle_before + 1,
		"the Cycle advanced (%d -> %d)" % [cycle_before, int(cycle_service.call("current_cycle"))])
	var modifiers_after: int = (modifier_service.call("active_modifier_ids") as Array).size()
	check(modifiers_after > modifiers_before,
		"a Cycle Modifier was drawn (%d active: %s)" % [modifiers_after,
			modifier_service.call("active_modifier_ids")])
	check(float(cycle_service.call("spread_multiplier")) > spread_before,
		"Mire spread escalated (%.3f -> %.3f)" % [spread_before,
			float(cycle_service.call("spread_multiplier"))])


# ── 8 · extraction: repair the wreck, board it, bank everything ──────────────────────────────────


func _phase_extraction() -> void:
	print("\n== LOOP 8 · extraction: repair from Cycle 3, board, bank full salvage ==")
	var ship: Node3D = _first_node_in_group(&"extraction_ship") as Node3D
	if ship == null:
		check(false, "no extraction ship")
		return
	var cycle_service: Node = root.get_node_or_null(^"CycleService")
	while int(cycle_service.call("current_cycle")) < int(ship.get(&"MIN_REPAIR_CYCLE")):
		cycle_service.call("host_advance_cycle")
		await physics_frame

	await _cmd("give repair_hammer 1", true)
	var ship_position: Vector3 = ship.global_position
	await _cmd("tp @s %f %f %f" % [ship_position.x, ship_position.y + 1.0, ship_position.z], true)
	await physics_frame

	var stages: int = int(ship.get(&"REPAIR_STAGE_COUNT"))
	for stage: int in stages:
		var cost: Dictionary = ship.call("current_repair_cost")
		for item_key: Variant in cost:
			await _cmd("give %s %d" % [item_key, int(cost[item_key])], true)
		ship.call("request_repair")  # the public wrapper — routes host-locally offline
		await physics_frame
		await physics_frame
	var repaired: bool = int(ship.get(&"repair_stage")) >= stages \
		if ship.get(&"repair_stage") != null else false
	check(repaired, "three staged repairs completed (stage %s/%d)" % [ship.get(&"repair_stage"), stages])

	var salvage: Node = root.get_node_or_null(^"SalvageService")
	var banked_before: int = int(salvage.call("total_salvage"))
	var extracted: Dictionary = {"fired": false}
	EVENT_BUS.subscribe_run_extracted(func(_cycle: int, _position: Vector3) -> void:
		extracted["fired"] = true)

	Engine.time_scale = 8.0  # the departure hold is 60 s of accumulated delta; §5a says this is safe
	ship.call("request_toggle_departure")
	var sailed: bool = await _until(func() -> bool: return bool(extracted["fired"]), 30.0)
	Engine.time_scale = 1.0
	check(sailed, "the departure hold completed and run_extracted fired")
	if sailed:
		var banked_after: int = int(salvage.call("total_salvage"))
		check(banked_after > banked_before,
			"extraction banked salvage (%d -> %d)" % [banked_before, banked_after])
		var save_path: String = "user://salvage.json"
		note("salvage persisted: %s" % ("yes" if FileAccess.file_exists(save_path)
			else "NO FILE at %s — extraction did not persist" % save_path))


# ── the other ending ─────────────────────────────────────────────────────────────────────────────


func _phase_defeat_ending() -> void:
	print("\n== LOOP 9 (separate run) · defeat: team wipe banks the fraction ==")
	var defeat: Node = root.get_node_or_null(^"DefeatService")
	var salvage: Node = root.get_node_or_null(^"SalvageService")
	# Earn something to lose: cap a Wellspring for its salvage bonus.
	var wellspring: Node3D = _first_node_in_group(&"wellspring") as Node3D
	if wellspring != null:
		EVENT_BUS.emit_wellspring_capped(StringName(wellspring.name), wellspring.global_position)
		await physics_frame
	var banked_before: int = int(salvage.call("total_salvage"))

	await _cmd("damage @s 1000000", true)
	await physics_frame
	var wiped: bool = await _until(func() -> bool: return bool(defeat.call("is_defeated")), 15.0)
	check(wiped, "a solo down is a team wipe — DefeatService triggered (6.7's contract)")
	if wiped:
		var banked_after: int = int(salvage.call("total_salvage"))
		check(banked_after >= banked_before,
			"defeat banked the death fraction (%d -> %d)" % [banked_before, banked_after])
		var hud: Node = root.get_node_or_null(^"DefeatHud")
		check(hud != null, "the defeat HUD exists to show the run summary")


# ── helpers ──────────────────────────────────────────────────────────────────────────────────────


func _cmd(line: String, expect_ok: bool) -> Dictionary:
	var result: Dictionary = await command_service.execute(
		line, command_service.build_local_ctx(&"runner"))
	if expect_ok and not bool(result.get("ok", false)):
		check(false, "command `%s` failed: %s" % [line, result.get("message", "")])
	return result


func _player_body() -> Node3D:
	for node: Node in get_nodes_in_group(&"players"):
		return node as Node3D
	return null


func _first_node_in_group(group: StringName) -> Node:
	for node: Node in get_nodes_in_group(group):
		if is_instance_valid(node):
			return node
	return null


func _first_active_harvestable() -> Node:
	for node: Node in get_nodes_in_group(&"harvestable"):
		if is_instance_valid(node) and bool(node.get(&"active")) \
				and node.has_method(&"host_apply_tool_damage"):
			return node
	return null


## The marker for a station that is REGISTERED (its asset is some StationDef's world_scene) — the
## 3.25 m crafting range means standing at the wrong prop of the station cluster reads as "no
## station", which is exactly what happened to this audit's first draft at the campfire.
func _registered_station_marker() -> Node3D:
	var registry: Node = root.get_node_or_null(^"Registry")
	var assets: Array[StringName] = []
	for id: Variant in (registry.get(&"stations") as Dictionary):
		var def: Resource = (registry.get(&"stations") as Dictionary)[id]
		assets.append(StringName(String(def.get(&"world_scene"))))
	for node: Node in get_nodes_in_group(&"authored_world_marker"):
		if String(node.get_meta(&"kind", "")) != "station":
			continue
		var marker_asset := StringName(String(node.name).trim_prefix("Station_"))
		if assets.has(marker_asset):
			return node as Node3D
	return null


## First recipe registered for [param station_id], read off the real RecipeDef schema
## (inputs: Array[RecipeIngredient]{item: ItemDef, count}, output_item: ItemDef).
func _recipe_for_station(station_id: StringName) -> Dictionary:
	var registry: Node = root.get_node_or_null(^"Registry")
	var recipes: Dictionary = registry.get(&"recipes")
	for id: Variant in recipes:
		var recipe: Resource = recipes[id]
		if StringName(String(recipe.get(&"station"))) != station_id:
			continue
		var output: Resource = recipe.get(&"output_item")
		if output == null:
			continue
		var inputs: Array = []
		for entry: Variant in (recipe.get(&"inputs") as Array):
			var ingredient: Resource = entry
			if ingredient == null or ingredient.get(&"item") == null:
				continue
			inputs.append({"item": StringName(String((ingredient.get(&"item") as Resource).get(&"id"))),
				"amount": int(ingredient.get(&"count"))})
		if inputs.is_empty():
			continue
		return {"id": StringName(String(id)), "inputs": inputs,
			"output": StringName(String(output.get(&"id")))}
	return {}


## A GROUND piece if one exists — the alphabetically-first buildable was `dock`, which legitimately
## wants water and made the placement test assert the wrong thing.
func _preferred_buildable_id() -> StringName:
	var registry: Node = root.get_node_or_null(^"Registry")
	var buildables: Dictionary = registry.get(&"buildables")
	var best: StringName = &""
	var best_volume: float = INF
	for id: Variant in buildables:
		var def: Resource = buildables[id]
		var size: Variant = def.get(&"size")
		var volume: float = (size.x * size.y * size.z) if size is Vector3 else INF
		if volume < best_volume:
			best_volume = volume
			best = StringName(String(id))
	return best


func _first_food_id() -> StringName:
	var registry: Node = root.get_node_or_null(^"Registry")
	var items: Dictionary = registry.get(&"items")
	for id: Variant in items:
		var item: Resource = items[id]
		var food: Variant = item.get(&"hunger_restore")
		if food != null and float(food) > 0.0:
			return StringName(String(id))
	return &""


func _cheapest_chest() -> Node:
	var best: Node = null
	var best_cost: int = 1 << 30
	for node: Node in get_nodes_in_group(&"chest"):
		if not is_instance_valid(node):
			continue
		var key: Variant = node.get(&"key_item_id")
		if key != null and StringName(String(key)) != &"":
			continue  # key-gated (D-122) — the coin path is the loop's common case
		var cost: int = int(node.get(&"cost_coins"))
		if cost < best_cost:
			best_cost = cost
			best = node
	return best


func _most_corrupted_point(mire: Node) -> Vector3:
	var best: Vector3 = Vector3.ZERO
	var best_value: float = -1.0
	for x: int in range(-480, 481, 32):
		for z: int in range(-480, 481, 32):
			var point := Vector3(float(x), 0.0, float(z))
			var value: float = float(mire.call("corruption_at", point))
			if value > best_value:
				best_value = value
				best = point
	return best


func _total_items(inventory: Node) -> int:
	var total: int = 0
	for slot: Dictionary in (inventory.call("host_slots", HOST_PEER) as Array):
		total += int(slot.get("amount", 0))  # the store's real key — F-239's lesson
	return total


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.1).timeout
	return bool(condition.call())


func note(text: String) -> void:
	notes.append(text)
	print("NOTE: %s" % text)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	if not notes.is_empty():
		print("\n-- audit notes --")
		for entry: String in notes:
			print("  · %s" % entry)
	print("\nLOOP_AUDIT failures=%d" % failures)
	quit(0 if failures == 0 else 1)
