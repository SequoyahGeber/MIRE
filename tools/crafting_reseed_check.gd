extends SceneTree

## F-286 — THE CRAFTING RESEED CHECK. Proves that a procedural island rebuilt IN PLACE cannot leave
## `CraftingService` validating station range against the island that just ended.
##
## The bug's mechanism is a cache key that is not a generation identity. `_station_positions_for()`
## rescans the two station groups only when `current_scene`'s instance id or the TOTAL marker census
## changes; `ProceduralWorld.rebuild_for_seed()` moves neither, because it re-derives everything
## under the SAME scene and two seeds routinely publish the same number of markers. So the host can
## reject a craft at the station the player is standing beside, and accept one at a coordinate the
## previous island had — an authoritative gameplay failure, not a presentation one.
##
## Four phases:
##   1. A real procedural island on seed A, with a station marker planted under `PoiSites` (the
##      subtree the rebuild frees) and the cache populated the only way that counts — by a HOST-side
##      `request_craft` that is ACCEPTED there.
##   2. `rebuild_for_seed(B)` — the shipped in-place path, driven directly rather than through a
##      handler (F-310: drive the real call, never the consumer's callback).
##   3. **The census collision, constructed rather than hoped for.** The finding was found on a seed
##      pair that happened to publish 11 markers each. Waiting for that pair to recur would make this
##      check a coin flip, so phase 1 plants a fixed pad of kind-less markers inside `PoiSites` and
##      phase 3 replants exactly enough of them on the new island to bring the census back to the
##      recorded number. Same scene id, same census, different island: the precise state the old key
##      could not see, reproduced deterministically on any seed.
##   4. The assertions, both directions, through the authoritative path: a craft at the NEW station
##      is accepted, and a craft at the OLD station's now-vacant coordinate is rejected
##      out-of-range. Plus the seam itself — `EventBus.world_generation()` advanced by exactly one
##      and the push half dispatched once.
##
## Probe stations are planted at y = 500 so they cannot collide with whatever real station markers a
## seed's POI layout does or does not produce (F-301: some seeds publish none at all, which is why
## nothing here may depend on finding one). Every real marker sits on the terrain, hundreds of
## metres below, so it is out of the 3.25 m range of both probe points on every seed.
##
##   .agent/bin/agent godot --script tools/crafting_reseed_check.gd

const ProceduralWorldScript := preload("res://world/gen/procedural_world.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

const SEED_A: int = 908245843
const SEED_B: int = 424242
const RECIPE_ID: StringName = &"stone_axe"
const STATION_ID: StringName = &"workbench"
const MARKER_GROUP: StringName = &"authored_world_marker"
const MARKER_NAME_PREFIX: String = "Station_"
const HOST_PEER_ID: int = 1

## Planted high above any terrain-level marker, and far enough apart that one probe point can never
## be in range of the other station (MAX_STATION_DISTANCE_M is 3.25).
const STATION_A: Vector3 = Vector3(120.0, 500.0, -40.0)
const STATION_B: Vector3 = Vector3(-260.0, 500.0, 310.0)

## Headroom for the census collision — see phase 3. Large enough that island B's own marker count
## can exceed island A's by any plausible margin (POI layouts run to roughly a dozen) and the pad
## still has slack to give back.
const CENSUS_PAD: int = 64

var failures: int = 0
var confirmations: Dictionary[int, Dictionary] = {}
var world_rebuilt_fires: int = 0
var world: Node3D
var player: Node3D
var crafting: Node
var inventory: Node
var registry: Node
var asset: StringName = &""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	var game_state: Node = root.get_node_or_null(^"GameState")
	registry = root.get_node_or_null(^"Registry")
	inventory = root.get_node_or_null(^"InventoryService")
	crafting = root.get_node_or_null(^"CraftingService")
	check(game_state != null, "GameState autoload exists")
	check(registry != null, "Registry autoload exists")
	check(inventory != null, "InventoryService autoload exists")
	check(crafting != null, "CraftingService autoload exists")
	if game_state == null or registry == null or inventory == null or crafting == null:
		_finish()
		return

	# The asset name comes from the registered StationDef, never re-typed here: the marker name IS
	# the contract between worldgen and this service, and a rename must red this check, not slip.
	var station_def: Resource = registry.call("get_station", STATION_ID)
	check(station_def != null, "the '%s' station is registered" % STATION_ID)
	if station_def == null:
		_finish()
		return
	asset = StringName(String(station_def.get("world_scene")))
	check(asset != &"", "the station resolves to a world_scene asset (%s)" % asset)

	crafting.get("craft_confirmed").connect(_on_craft_confirmed)
	EVENT_BUS.subscribe_world_rebuilt(_on_world_rebuilt)

	var census_before: int = await _phase_island_a(game_state)
	if world == null or census_before < 0:
		EVENT_BUS.unsubscribe_world_rebuilt(_on_world_rebuilt)
		_finish()
		return
	_phase_rebuild(census_before)
	await process_frame
	_phase_assert()

	EVENT_BUS.unsubscribe_world_rebuilt(_on_world_rebuilt)
	_finish()


# ── 1 · island A, with the cache populated by a craft that really happened ───────────────────────


func _phase_island_a(game_state: Node) -> int:
	print("\n== CRAFT RESEED 1 · a real island on seed %d, cache populated by an accepted craft ==" % SEED_A)
	var scene := Node3D.new()
	scene.name = "CraftingReseedCheckScene"
	root.add_child(scene)
	current_scene = scene

	game_state.call("set_replicated_seed", SEED_A)
	world = ProceduralWorldScript.new()
	world.set(&"build_player", false)
	scene.add_child(world)
	await process_frame

	check(int(world.get(&"world_seed")) == SEED_A, "the island booted on seed %d" % SEED_A)
	var poi_sites: Node = _poi_holder()
	check(poi_sites != null, "the island published a PoiSites holder to plant into")
	if poi_sites == null:
		return -1

	player = Node3D.new()
	player.name = "CraftingReseedCheckPlayer"
	player.add_to_group(&"players")
	scene.add_child(player)

	_plant_station(poi_sites, STATION_A)
	_plant_pad(poi_sites, CENSUS_PAD, "A")
	var census: int = _census()
	print("  island A census=%d (pad %d)" % [census, CENSUS_PAD])

	# Populated through the AUTHORITATIVE path, not a presentation helper: what the finding claims
	# goes stale is the host's own validation, so that is what has to have run at least once.
	player.global_position = STATION_A
	check(_craft_accepted(), "the host accepts a craft at island A's station — the cache is warm")
	check(_cached_positions().has(STATION_A),
		"...and the warm cache really holds island A's coordinate %s" % STATION_A)
	return census


# ── 2/3 · the in-place rebuild, and the census collision ────────────────────────────────────────


func _phase_rebuild(census_before: int) -> void:
	print("\n== CRAFT RESEED 2 · rebuild_for_seed(%d) in place, then force the census collision ==" % SEED_B)
	var scene_id_before: int = current_scene.get_instance_id()
	var generation_before: int = EVENT_BUS.world_generation()

	world.call("rebuild_for_seed", SEED_B)

	check(int(world.get(&"world_seed")) == SEED_B, "the rebuild adopted seed %d" % SEED_B)
	check(current_scene.get_instance_id() == scene_id_before,
		"the current scene is the SAME instance — the rebuild happened in place, as F-258 intends")
	check(EVENT_BUS.world_generation() == generation_before + 1,
		"EventBus.world_generation() advanced by exactly one (%d -> %d)"
			% [generation_before, EVENT_BUS.world_generation()])
	check(world_rebuilt_fires == 1,
		"...and the push half dispatched exactly once (got %d)" % world_rebuilt_fires)
	check(not _all_marker_positions().has(STATION_A),
		"island A's station marker was torn down with its PoiSites — it is not in the tree at all")

	var poi_sites: Node = _poi_holder()
	check(poi_sites != null, "the new island published its own PoiSites holder")
	if poi_sites == null:
		return
	_plant_station(poi_sites, STATION_B)

	# The collision, constructed. Everything above changed the marker count by whatever this seed's
	# POI layout happens to differ by; give exactly that difference back as kind-less pad markers
	# and the census reads identical to the one the cache recorded on island A.
	var pad_needed: int = census_before - _census()
	check(pad_needed >= 0,
		"the pad has slack to give back (island B needs %d more marker(s); CENSUS_PAD is %d)"
			% [pad_needed, CENSUS_PAD])
	if pad_needed > 0:
		_plant_pad(poi_sites, pad_needed, "B")
	check(_census() == census_before,
		"the two islands present the IDENTICAL census (%d) — the state the old cache key could not see"
			% census_before)


# ── 4 · what the host now believes ──────────────────────────────────────────────────────────────


func _phase_assert() -> void:
	print("\n== CRAFT RESEED 3 · the host validates against the NEW island, both directions ==")

	player.global_position = STATION_B
	check(bool((crafting.call("local_recipe_status", RECIPE_ID) as Dictionary).get("at_station", false)),
		"the new island's station reads as in range")
	check(_craft_accepted(),
		"the host ACCEPTS a craft at the new island's station — pre-fix it rejected one here")
	check(_cached_positions().has(STATION_B),
		"the cache re-derived onto island B's coordinate %s" % STATION_B)
	check(not _cached_positions().has(STATION_A),
		"...and dropped island A's %s entirely" % STATION_A)

	player.global_position = STATION_A
	check(not bool((crafting.call("local_recipe_status", RECIPE_ID) as Dictionary).get("at_station", true)),
		"the vacated coordinate no longer reads as a station")
	var detail: String = _craft_detail()
	check(detail.contains("out of range"),
		"the host REJECTS a craft at the vacated coordinate, out of range — got '%s'" % detail)
	check(int(inventory.call("local_count", RECIPE_ID)) == 2,
		"exactly two crafts were ever authorised across the reseed (got %d %s)"
			% [int(inventory.call("local_count", RECIPE_ID)), RECIPE_ID])


# ── planting and reading ────────────────────────────────────────────────────────────────────────


## The marker contract exactly as `ProceduralWorld._build_poi_sites()` publishes it: group and meta
## set BEFORE add_child, because the marker services discover on `node_added` (F-012's mechanism).
func _plant_station(parent: Node, position: Vector3) -> void:
	var marker := Marker3D.new()
	marker.name = "%s%s" % [MARKER_NAME_PREFIX, asset]
	marker.add_to_group(MARKER_GROUP)
	marker.set_meta(&"kind", "station")
	parent.add_child(marker)
	marker.global_position = position


## Census ballast, and nothing else. An EMPTY `kind` is what `ProceduralWorld` calls scenery, so
## these are invisible to every kind-keyed consumer — including the station filter itself — while
## still counting toward the one number `_station_positions_for()` keys on.
func _plant_pad(parent: Node, count: int, tag: String) -> void:
	for index: int in count:
		var marker := Marker3D.new()
		marker.name = "CensusPad%s_%d" % [tag, index]
		marker.add_to_group(MARKER_GROUP)
		marker.set_meta(&"kind", "")
		parent.add_child(marker)


func _poi_holder() -> Node:
	return world.get_node_or_null(^"PoiSites")


## The same total `_station_positions_for()` keys on: both station groups, counted in the live tree.
func _census() -> int:
	return (get_node_count_in_group(&"playtest_hollow_asset")
		+ get_node_count_in_group(MARKER_GROUP))


## What the service currently BELIEVES, read straight off its cache. `_station_positions` is private
## by convention only, and reading it is what separates "the range answer happens to be right" from
## "the cache re-derived" — a check that only asserted the former would pass on a service that had
## simply never cached anything at all.
func _cached_positions() -> Array:
	var by_asset: Dictionary = crafting.get(&"_station_positions")
	return (by_asset.get(asset, [] as Array) as Array) if by_asset != null else []


func _all_marker_positions() -> Array:
	var out: Array = []
	for node: Node in get_nodes_in_group(MARKER_GROUP):
		var marker := node as Node3D
		if marker != null:
			out.append(marker.global_position)
	return out


# ── driving a real craft ────────────────────────────────────────────────────────────────────────


## Tops the local inventory up to whatever the recipe is short of, so a rejection below can only
## ever mean the station check — never a missing log. Read from the live status rather than
## re-typed, so a content edit to the recipe cannot quietly turn this check into a no-op.
func _grant_ingredients() -> void:
	var status: Dictionary = crafting.call("local_recipe_status", RECIPE_ID)
	var missing: Dictionary = status.get("missing", {}) as Dictionary
	for item_id: StringName in missing:
		inventory.call("host_add", HOST_PEER_ID, item_id, int(missing[item_id]))


## The shipped request path end to end — solo host, so `request_craft()` runs `_process_craft()`
## itself, which is the same `_station_in_range()` a remote peer's `net_request_craft` reaches.
func _craft_detail() -> String:
	_grant_ingredients()
	var request_id: int = int(crafting.call("request_craft", RECIPE_ID))
	var confirmation: Dictionary = confirmations.get(request_id, {})
	if confirmation.is_empty():
		return "no confirmation for request %d" % request_id
	return String(confirmation.get("detail", ""))


func _craft_accepted() -> bool:
	_grant_ingredients()
	var request_id: int = int(crafting.call("request_craft", RECIPE_ID))
	return bool((confirmations.get(request_id, {}) as Dictionary).get("accepted", false))


func _on_craft_confirmed(request_id: int, accepted: bool, detail: String) -> void:
	confirmations[request_id] = {"accepted": accepted, "detail": detail}


func _on_world_rebuilt() -> void:
	world_rebuilt_fires += 1


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	print("\nCRAFTING_RESEED_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)
