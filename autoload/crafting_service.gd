extends Node

## Host-authoritative crafting for every station. Clients submit only a recipe id; the host derives
## the requesting peer, resolves the recipe's station to a registered StationDef (task 3.1's
## "station-tier check" — a recipe whose station id does not resolve is rejected before the range
## check ever runs), validates its authoritative player against a real mapped station instance, and
## commits ingredients plus output through InventoryService's atomic transaction seam. A recipe with
## craft_time_sec > 0 (the furnace's worked example) delays that commit behind a host-side timer
## instead of applying it inline — see _start_timed_craft/_process.
##
## Wire shape is unchanged from task 2.6: a request still carries only a recipe id and a local
## request id, and completion still arrives solely through craft_confirmed. Per-station and timed
## crafting are both provable with that same pair, so this task does not bump the protocol.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

## Legacy Playtest Hollow prop group: a station is a StaticBody3D/Node3D holding meta `asset`.
const LEGACY_STATION_GROUP: StringName = &"playtest_hollow_asset"
## Hollowmere marker group (world/gen/authored_world.gd): a station is a Marker3D with meta
## `kind == "station"`, named "Station_<asset>" (tools/mapgen/hollowmere_layout.py). Hollowmere's
## station props are baked into MultiMeshInstance3D batches with no per-instance node of their own,
## so the marker is the only per-instance position this map exposes (F-057-shaped trap: matching only
## LEGACY_STATION_GROUP would leave every Hollowmere station inert, the same bug HarvestWorld had
## before it learned to read authored_world_prop/marker groups).
const MARKER_GROUP: StringName = &"authored_world_marker"
const MARKER_NAME_PREFIX: String = "Station_"
const MAX_STATION_DISTANCE_M: float = 3.25

signal craft_confirmed(request_id: int, accepted: bool, detail: String)

var _next_request_id: int = 1

## Requester-side (host-as-requester or a remote client) progress estimate for a timed craft this
## peer itself asked for, keyed by request_id: {"duration_sec": float, "started_msec": int}. Purely a
## presentation seam — every peer already has the identical RecipeDef from Registry, so a client
## computes its own countdown the moment it sends the request rather than waiting on a round trip.
## Cleared the moment craft_confirmed fires. Never consulted for authority; the host's own pending
## queue below is what actually delays the transaction.
var _local_pending_crafts: Dictionary[int, Dictionary] = {}

## HOST-only authoritative queue for in-progress timed crafts: peer_id -> (request_id -> {"data":
## Dictionary, "remaining_sec": float}). Keyed two levels deep because request ids are chosen locally
## by each requester (including the host's own local player), so two different peers can legitimately
## both be mid-flight on "request 1" at once.
var _host_pending_crafts: Dictionary[int, Dictionary] = {}

## Station instances never move once a map is built, so their positions are cached per asset and the
## two group scans run once per scene instead of on every range query (F-099). The census (a cheap
## O(1) count per group) re-triggers the scan if a harness or a later system adds or removes one.
##
## F-286: the census and the scene id are both counts of the CURRENT tree, and neither is a
## generation identity. `ProceduralWorld.rebuild_for_seed()` re-derives a whole island under the
## SAME current scene, so the scene id never moves; and two seeds routinely publish the same number
## of markers (measured: seed 908245843 and seed 424242 both give 11), so the census does not move
## either. A cache populated on the ended run then survives into the new one holding the PREVIOUS
## island's coordinates — the host rejecting a craft at the station the player is standing beside,
## and authorising one at a coordinate that now has nothing on it. `EventBus.world_generation()` is
## the third key component and the only one that is an identity: it counts in-place world rebuilds,
## so it changes even when the other two cannot.
var _station_positions: Dictionary[StringName, Array] = {}
var _station_scene_id: int = 0
var _station_census: int = -1
var _station_generation: int = -1


func _ready() -> void:
	# _process only drains the host's timed-craft queue; it idles off while that is empty (F-099).
	set_process(false)
	_register_commands()



func recipes_for_station(station: StringName) -> Array[RecipeDef]:
	var ids: Array[StringName] = []
	for id: StringName in Registry.recipes:
		ids.append(id)
	# StringName's `<` compares interned identity, not string content, so Array.sort() on a
	# StringName array does NOT give alphabetical order (confirmed: sorting the same values as
	# String gives "arrow, cleaver, iron_sword..."; as StringName it gives an unrelated order).
	# That silently broke the CraftingUI row order once the workbench had more than one recipe.
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	var result: Array[RecipeDef] = []
	for id: StringName in ids:
		var recipe: RecipeDef = Registry.get_recipe(id)
		if recipe != null and station_satisfies(station, recipe.station):
			result.append(recipe)
	return result


## Does standing at `station` let you craft a recipe that asks for `required`?
##
## F-575: this used to be `recipe.station == required`, a bare id comparison, and `StationDef` was
## the only content family in the repo whose fields nothing read — `family` and `tier` were authored,
## validated by `tools/station_tier_check.gd`, and then ignored by the game. The visible cost was the
## Reinforced Workbench: `workbench_upgraded` is the upgrade of `workbench` and satisfied NONE of the
## seven workbench recipes, so a player who paid for the upgrade got strictly less than the bench it
## replaces, which reads as a broken game rather than as content nobody has authored yet.
##
## Substitution comes from `StationDef.upgrades_from`, DECLARED per station, and deliberately not
## inferred from `family` + `tier`. The first attempt at this fix did infer it — "same family, equal
## or higher tier" — and it was wrong: `forge` runs furnace (1) then anvil (2), so the rule quietly
## moved `iron_ingot` and `bogsilver_ingot` onto the anvil and `tools/recipe_station_check.gd` (F-484,
## "smelting at the furnace, smithed goods at the anvil") caught it. A family is a themed progression,
## not a ladder of substitutes; an anvil comes after a furnace without being able to do its job.
##
## Chains resolve transitively, so a tier-3 bench need only name the tier-2 one. The walk is bounded
## by the registry size rather than trusting the data to be acyclic — a mis-authored `a -> b -> a`
## must not hang the host inside a craft request.
static func station_satisfies(station: StringName, required: StringName) -> bool:
	if station == required:
		return true
	if station == &"" or required == &"":
		return false
	var seen: Dictionary[StringName, bool] = {}
	var current: StringName = station
	while current != &"" and not seen.has(current):
		seen[current] = true
		var def: Resource = Registry.get_station(current)
		if def == null:
			return false
		var next := StringName(String(def.get("upgrades_from")))
		if next == required:
			return true
		current = next
	return false


## The registered station id the local player is currently in range of, or &"" if none. Ties break by
## registry iteration order (deterministic — Dictionary preserves insertion order — but not
## meaningfully orderable beyond that); two stations placed within range of each other is not a
## shape the vertical slice needs to disambiguate further. Presentation-only, same caveat as every
## other local_*/nearby_* helper here: the host repeats this check independently.
func nearby_station_id() -> StringName:
	var player: Node3D = _local_player()
	if player == null:
		return &""
	for station_id: StringName in Registry.stations:
		# The raw probe, not the F-575 satisfy rule: this answers "which bench am I standing at",
		# so standing at the Reinforced Workbench must report `workbench_upgraded` and not
		# `workbench`. `recipes_for_station()` is what widens that answer into a recipe list.
		if _station_instance_in_range(player, station_id):
			return station_id
	return &""


## Presentation-only preview for task 2.7. The host repeats every check when a request arrives.
func local_recipe_status(recipe_id: StringName) -> Dictionary:
	var data: Dictionary = _definition_data(recipe_id)
	if not bool(data.get("valid", false)):
		return {
			"known": false,
			"at_station": false,
			"has_ingredients": false,
			"can_request": false,
			"missing": {},
			"detail": String(data.get("detail", "unknown recipe")),
		}

	var missing: Dictionary = {}
	var removals: Dictionary = data.get("removals", {}) as Dictionary
	for item_id: StringName in removals:
		var required: int = int(removals.get(item_id, 0))
		var available: int = InventoryService.local_count(item_id)
		if available < required:
			missing[item_id] = required - available
	var at_station: bool = local_station_in_range(StringName(data.get("station", &"")))
	return {
		"known": true,
		"at_station": at_station,
		"has_ingredients": missing.is_empty(),
		"can_request": at_station and missing.is_empty(),
		"missing": missing,
		"detail": "ready" if at_station and missing.is_empty() else "requirements not met",
	}


func local_station_in_range(station: StringName) -> bool:
	var player: Node3D = _local_player()
	return player != null and _station_in_range(player, station)


## Fraction complete (0..1) of a timed craft this peer itself requested, or -1.0 if request_id is not
## a pending timed craft (either it was never timed, or it has already resolved through
## craft_confirmed). Purely a client-side estimate — see _local_pending_crafts above.
func craft_progress(request_id: int) -> float:
	if not _local_pending_crafts.has(request_id):
		return -1.0
	var entry: Dictionary = _local_pending_crafts[request_id]
	var duration: float = float(entry.get("duration_sec", 0.0))
	if duration <= 0.0:
		return 1.0
	var elapsed_sec: float = float(Time.get_ticks_msec() - int(entry.get("started_msec", 0))) / 1000.0
	return clampf(elapsed_sec / duration, 0.0, 1.0)


func request_craft(recipe_id: StringName) -> int:
	var request_id: int = _take_request_id()
	var recipe: RecipeDef = Registry.get_recipe(recipe_id)
	if recipe != null and recipe.craft_time_sec > 0.0:
		_local_pending_crafts[request_id] = {
			# F-543: the same `craft_seconds` scaling the host will apply, so the local progress
			# estimate tracks the real craft instead of finishing early or hanging at 99%.
			"duration_sec": _modified_craft_seconds(_local_peer_id(), recipe.craft_time_sec),
			"started_msec": Time.get_ticks_msec(),
		}
	if _owns_mutation():
		_process_craft(_local_peer_id(), recipe_id, request_id)
	elif NetTransport.is_active():
		net_request_craft.rpc_id(NetConfig.HOST_PEER_ID, recipe_id, request_id)
	else:
		_emit_confirmation(request_id, false, "no authoritative session")
	return request_id


@rpc("any_peer", "call_remote", "reliable")
func net_request_craft(recipe_id: StringName, request_id: int) -> void:
	if not NetTransport.is_host():
		return
	_process_craft(multiplayer.get_remote_sender_id(), recipe_id, request_id)


@rpc("authority", "call_remote", "reliable")
func net_craft_confirmed(request_id: int, accepted: bool, detail: String) -> void:
	_emit_confirmation(request_id, accepted, detail)


func _process(delta: float) -> void:
	if _host_pending_crafts.is_empty():
		set_process(false)
		return
	# .keys() copies are load-bearing here — both levels erase inside their loop. The write-backs
	# the old code did after mutating `entry`/`by_request` were not: Dictionaries are references.
	for peer_id: int in _host_pending_crafts.keys():
		var by_request: Dictionary = _host_pending_crafts[peer_id] as Dictionary
		for request_id: int in by_request.keys():
			var entry: Dictionary = by_request[request_id] as Dictionary
			var remaining: float = float(entry.get("remaining_sec", 0.0)) - delta
			if remaining > 0.0:
				entry["remaining_sec"] = remaining
				continue
			by_request.erase(request_id)
			_finish_craft(peer_id, request_id, entry.get("data", {}) as Dictionary)
		if by_request.is_empty():
			_host_pending_crafts.erase(peer_id)


func _process_craft(peer_id: int, recipe_id: StringName, request_id: int) -> void:
	var data: Dictionary = _definition_data(recipe_id)
	if not bool(data.get("valid", false)):
		_confirm_peer(peer_id, request_id, false, String(data.get("detail", "invalid recipe")))
		return

	var player: Node3D = _host_player(peer_id)
	if player == null:
		_confirm_peer(peer_id, request_id, false, "craft rejected: player is not spawned")
		return
	var station := StringName(data.get("station", &""))
	if not _station_in_range(player, station):
		_confirm_peer(peer_id, request_id, false, "craft rejected: station out of range")
		return

	# F-543: `craft_seconds` scales a timed craft's duration for the peer who asked
	# (docs/POWERUPS.md §2; DESIGN §4.5's Tinker is "better at craft cost", -20%, and `forge_blood`
	# stacks on top). Applied on the HOST, which is the only clock that decides when the craft
	# finishes — the client's own `_local_pending_crafts` estimate is scaled the same way in
	# `request_craft()` so the progress bar and the confirmation agree. An instant recipe
	# (`craft_time_sec == 0`) stays instant: there is no duration to shorten, and a positive
	# modifier must not invent a wait on a recipe authored to have none.
	var craft_time_sec: float = _modified_craft_seconds(
		peer_id, float(data.get("craft_time_sec", 0.0))
	)
	if craft_time_sec <= 0.0:
		_finish_craft(peer_id, request_id, data)
		return
	_start_timed_craft(peer_id, request_id, data, craft_time_sec)


## Timed path (furnace worked example): reject fast if the ingredients are already missing, otherwise
## park the request for _process() to complete. Ingredients are NOT removed here — the atomic
## host_transaction at completion is what actually spends them, so a request that outlives its own
## ingredients (traded away mid-smelt) is rejected then, exactly like the instant path already was.
func _start_timed_craft(peer_id: int, request_id: int, data: Dictionary, craft_time_sec: float) -> void:
	var removals: Dictionary = data.get("removals", {}) as Dictionary
	for item_id: StringName in removals:
		if not InventoryService.host_can_remove(peer_id, item_id, int(removals[item_id])):
			_confirm_peer(peer_id, request_id, false, "craft rejected: missing ingredients or inventory full")
			return
	var by_request: Dictionary = _host_pending_crafts.get(peer_id, {}) as Dictionary
	by_request[request_id] = {"data": data, "remaining_sec": craft_time_sec}
	_host_pending_crafts[peer_id] = by_request
	set_process(true)


func _finish_craft(peer_id: int, request_id: int, data: Dictionary) -> void:
	var accepted: bool = InventoryService.host_transaction(
		peer_id,
		data.get("removals", {}) as Dictionary,
		data.get("additions", {}) as Dictionary
	)
	var detail: String
	if accepted:
		detail = "crafted %s" % String(data.get("output_name", ""))
		# 3.18: the single commit point both craft paths (instant and timed) pass through, so the
		# tool ladder's high-water mark is raised exactly where a tool actually enters the world —
		# not on the request, which may still be rejected. ProgressionService ignores everything
		# whose `ItemDef.tool_tier` is 0, which is almost everything.
		_note_progression(data.get("additions", {}) as Dictionary)
	else:
		detail = "craft rejected: missing ingredients or inventory full"
	_confirm_peer(peer_id, request_id, accepted, detail)


## Host-side only, and deliberately tolerant of the autoload being absent: a `--script` check that
## boots CraftingService without the whole autoload list must still be able to craft.
func _note_progression(additions: Dictionary) -> void:
	if additions.is_empty():
		return
	var progression: Node = get_node_or_null(^"/root/ProgressionService")
	if progression != null:
		progression.call("host_note_crafted", additions)


func _definition_data(recipe_id: StringName) -> Dictionary:
	if recipe_id == &"" or not Registry.has_recipe(recipe_id):
		return {"valid": false, "detail": "craft rejected: unknown recipe"}
	var recipe: RecipeDef = Registry.get_recipe(recipe_id)
	if recipe == null:
		return {"valid": false, "detail": "craft rejected: unknown recipe"}
	if not Registry.has_station(recipe.station):
		return {"valid": false, "detail": "craft rejected: unsupported station"}
	if recipe.output_item == null or recipe.output_count <= 0:
		return {"valid": false, "detail": "craft rejected: invalid output"}
	var output_id: StringName = recipe.output_item.id
	if output_id == &"" or not Registry.has_item(output_id):
		return {"valid": false, "detail": "craft rejected: unknown output"}

	var removals: Dictionary = {}
	for ingredient: RecipeIngredient in recipe.inputs:
		if ingredient == null or ingredient.item == null or ingredient.count <= 0:
			return {"valid": false, "detail": "craft rejected: invalid ingredient"}
		var item_id: StringName = ingredient.item.id
		if item_id == &"" or not Registry.has_item(item_id):
			return {"valid": false, "detail": "craft rejected: unknown ingredient"}
		removals[item_id] = int(removals.get(item_id, 0)) + ingredient.count
	if removals.is_empty():
		return {"valid": false, "detail": "craft rejected: recipe has no ingredients"}

	return {
		"valid": true,
		"station": recipe.station,
		"removals": removals,
		"additions": {output_id: recipe.output_count},
		"output_name": recipe.output_item.display_name,
		"craft_time_sec": maxf(recipe.craft_time_sec, 0.0),
	}


## Nearest live instance of `station` within range, checked against both a legacy Playtest Hollow
## prop (individually queryable node, meta `asset`) and a Hollowmere marker (meta kind == "station",
## named "Station_<asset>" — see MARKER_GROUP above). `station` not resolving to a registered
## StationDef means no world_scene to match against, so it is always out of range.
func _station_in_range(player: Node3D, required: StringName) -> bool:
	if Registry.get_station(required) == null:
		return false
	# F-575: any registered station that satisfies the requirement counts, not just the one whose id
	# the recipe names. Both the client preview (`local_station_in_range`) and the host's own
	# revalidation in `_process_craft()` come through here, so the two cannot disagree about whether
	# the Reinforced Workbench is a workbench.
	for station_id: StringName in Registry.stations:
		if not station_satisfies(station_id, required):
			continue
		if _station_instance_in_range(player, station_id):
			return true
	return false


## Is a physical instance of exactly this station within reach — no family or tier reasoning.
## `nearby_station_id()` and `_station_in_range()` both need this, and they need it to mean different
## things: "which bench am I standing at" is a question about the world, "can I craft this here" is a
## question about the rules.
func _station_instance_in_range(player: Node3D, station: StringName) -> bool:
	var station_def: Resource = Registry.get_station(station)
	if station_def == null:
		return false
	var asset := StringName(String(station_def.get("world_scene")))
	if asset == &"":
		return false
	var max_distance_squared: float = MAX_STATION_DISTANCE_M * MAX_STATION_DISTANCE_M
	for position: Vector3 in _station_positions_for(asset):
		if player.global_position.distance_squared_to(position) <= max_distance_squared:
			return true
	return false


## How many stations of this kind exist ANYWHERE in the world, whoever placed them and however far
## away they are — a party fact, unlike `local_station_in_range()` right above, which is a fact about
## where you are standing. `GuideService` (3.19) is the caller: "place a workbench" has to clear when
## your teammate places one on the other side of the island.
##
## Rides the same `_station_positions_for()` cache every craft query already warms, so asking this
## four times a second costs a dictionary lookup.
func station_count(required: StringName) -> int:
	if Registry.get_station(required) == null:
		return 0
	# F-575, same rule as `_station_in_range()`: a guide step that says "place a workbench" must
	# clear when the party places the Reinforced Workbench instead, or the tutorial deadlocks behind
	# a bench the player has already outgrown.
	var total: int = 0
	for station_id: StringName in Registry.stations:
		if not station_satisfies(station_id, required):
			continue
		var station_def: Resource = Registry.get_station(station_id)
		var asset := StringName(String(station_def.get("world_scene")))
		if asset == &"":
			continue
		total += _station_positions_for(asset).size()
	return total


## Cached station positions for one asset — see _station_positions' comment for the invalidation
## rule. Filtering matches the old per-query scans exactly: a legacy prop carries meta `asset`; a
## Hollowmere marker is kind == "station" named "Station_<asset>".
func _station_positions_for(asset: StringName) -> Array:
	var scene: Node = get_tree().current_scene
	var scene_id: int = scene.get_instance_id() if is_instance_valid(scene) else 0
	var census: int = (
		get_tree().get_node_count_in_group(LEGACY_STATION_GROUP)
		+ get_tree().get_node_count_in_group(MARKER_GROUP)
	)
	# Pulled, not subscribed (D-175). There is no state here to reset — only a cache derived from
	# the scene — and a `world_rebuilt`/`run_restarted` handler would be racing dispatch order for
	# the right to clear it, where reading the counter at the query itself cannot lose that race.
	var generation: int = EVENT_BUS.world_generation()
	if scene_id != _station_scene_id or census != _station_census \
			or generation != _station_generation:
		_station_scene_id = scene_id
		_station_census = census
		_station_generation = generation
		_station_positions.clear()
		for node: Node in get_tree().get_nodes_in_group(LEGACY_STATION_GROUP):
			var station_node := node as Node3D
			if station_node == null:
				continue
			var node_asset := StringName(String(station_node.get_meta(&"asset", "")))
			if node_asset == &"":
				continue
			(_station_positions.get_or_add(node_asset, [] as Array) as Array).append(
				station_node.global_position
			)
		for node: Node in get_tree().get_nodes_in_group(MARKER_GROUP):
			var marker := node as Node3D
			if marker == null or String(marker.get_meta(&"kind", "")) != "station":
				continue
			var marker_name := String(marker.name)
			if not marker_name.begins_with(MARKER_NAME_PREFIX):
				continue
			var marker_asset := StringName(marker_name.substr(MARKER_NAME_PREFIX.length()))
			(_station_positions.get_or_add(marker_asset, [] as Array) as Array).append(
				marker.global_position
			)
	return _station_positions.get(asset, [] as Array)


func _host_player(peer_id: int) -> Node3D:
	if NetTransport.is_active():
		return PlayerNet.player_for(peer_id)
	if peer_id != NetConfig.HOST_PEER_ID:
		return null
	return _local_player()


func _local_player() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null


func _confirm_peer(peer_id: int, request_id: int, accepted: bool, detail: String) -> void:
	if peer_id == _local_peer_id():
		_emit_confirmation(request_id, accepted, detail)
	elif NetTransport.is_active() and NetTransport.has_peer(peer_id):
		# F-059's shape: a crafter can disconnect while a timed craft is resolving, between
		# net_request_craft and this confirmation.
		net_craft_confirmed.rpc_id(peer_id, request_id, accepted, detail)


func _emit_confirmation(request_id: int, accepted: bool, detail: String) -> void:
	_local_pending_crafts.erase(request_id)
	craft_confirmed.emit(request_id, accepted, detail)


func _take_request_id() -> int:
	var result: int = _next_request_id
	_next_request_id += 1
	if _next_request_id <= 0:
		_next_request_id = 1
	return result


func _local_peer_id() -> int:
	var peer_id: int = NetTransport.local_peer_id()
	return peer_id if peer_id > 0 else NetConfig.HOST_PEER_ID


func _owns_mutation() -> bool:
	return (
		NetTransport.is_host()
		or (not NetTransport.is_active() and not NetTransport.is_connecting())
	)


# ── Commands (docs/COMMANDS.md §7 — task 3.16) ───────────────────────────────────────────────────


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"craft", {
		"scope": &"host",
		"args": [{"name": "recipe", "type": &"recipe_id"}],
		"handler": _cmd_craft,
		"help": "craft <recipe_id> — craft through the normal request path, costs included",
	})
	command_service.call("register_spec", &"recipes", {
		"scope": &"local",
		"args": [{"name": "station", "type": &"string", "optional": true, "default": ""}],
		"handler": _cmd_recipes,
		"help": "recipes [station_id] — what can be crafted, optionally at one station",
	})


## Calls _process_craft() directly with the ISSUING peer (ctx.peer_id), rather than request_craft() —
## request_craft() resolves the actor via _local_peer_id(), which is correct for the crafting UI (it
## always runs as the actor's own local call) but wrong here: a HOST-scope command handler always
## executes on the host process (command_service.gd's execute()/_execute_locally() never reach a
## handler anywhere else), including when a non-host op is the one who typed it and the line reached
## here over net_submit_command. Going through request_craft() there would resolve _local_peer_id()
## to the HOST's own id and silently craft on the host's behalf instead of the op's (F-228). This
## still validates through the exact same _process_craft() the UI's own request goes through — same
## ingredient/station/range check, just with the right actor — so COMMANDS.md §7's "goes through the
## normal request path, not around it" still holds; only the actor resolution changes.
func _cmd_craft(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var recipe_id: StringName = args.get("recipe", &"")
	var peer_id: int = int(ctx.get("peer_id", _local_peer_id()))
	var request_id: int = _take_request_id()
	_process_craft(peer_id, recipe_id, request_id)
	# The confirmation is asynchronous (craft_confirmed/net_craft_confirmed), and a LOCAL-synchronous
	# handler cannot await it — see command_service.gd's header. Reporting the accepted REQUEST is
	# honest: _confirm_peer() delivers the real confirmation to the actual issuer when it lands,
	# exactly as it does for the UI path.
	return {"ok": true, "message": "craft %s requested (#%d)" % [recipe_id, request_id],
		"data": {"recipe": String(recipe_id), "request": request_id}}


func _cmd_recipes(_ctx: Dictionary, args: Dictionary) -> Dictionary:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return {"ok": false, "message": "Registry is not loaded", "data": {}}
	var station := StringName(String(args.get("station", "")).strip_edges())
	var listed: Array = recipes_for_station(station) if station != &"" \
		else (registry.get(&"recipes") as Dictionary).values()
	if listed.is_empty():
		return {"ok": true,
			"message": "no recipes%s" % (" at station '%s'" % station if station != &"" else ""),
			"data": {"recipes": []}}
	var ids: Array = []
	var lines: PackedStringArray = ["%d recipe(s)%s:" % [
		listed.size(), " at %s" % station if station != &"" else ""]]
	for recipe: Resource in listed:
		var id := StringName(String(recipe.get(&"id")))
		ids.append(String(id))
		lines.append("  %s" % id)
	return {"ok": true, "message": "\n".join(lines), "data": {"recipes": ids}}


## F-543: one peer's version of an authored craft duration. Returns `base` untouched for a
## non-timed recipe, and clamps at zero rather than letting a stacked negative multiplier produce a
## negative duration (which `_start_timed_craft` would treat as "already done" on the next tick, and
## which docs/POWERUPS.md §2 rules out at author time anyway via the zero-crossing check).
func _modified_craft_seconds(peer_id: int, base: float) -> float:
	if base <= 0.0:
		return base
	var powerups: Node = get_node_or_null(^"/root/PowerupService")
	if powerups == null:
		return base
	return maxf(float(powerups.call(&"stat", peer_id, &"craft_seconds", base)), 0.0)
