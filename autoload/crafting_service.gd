extends Node

## Host-authoritative crafting for the vertical slice. Clients submit only a recipe id; the host
## derives the requesting peer, validates its authoritative player against a real mapped station,
## and commits ingredients plus output through InventoryService's atomic transaction seam.

const STATION_GROUP: StringName = &"playtest_hollow_asset"
const WORKBENCH_STATION: StringName = &"workbench"
const WORKBENCH_ASSET: StringName = &"station_workbench_primitive"
const MAX_STATION_DISTANCE_M: float = 3.25

signal craft_confirmed(request_id: int, accepted: bool, detail: String)

var _next_request_id: int = 1


func recipes_for_station(station: StringName) -> Array[RecipeDef]:
	var ids: Array[StringName] = []
	for id: StringName in Registry.recipes:
		ids.append(id)
	ids.sort()
	var result: Array[RecipeDef] = []
	for id: StringName in ids:
		var recipe: RecipeDef = Registry.get_recipe(id)
		if recipe != null and recipe.station == station:
			result.append(recipe)
	return result


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
	for item_id: StringName in data.get("removals", {}):
		var required: int = int((data.get("removals", {}) as Dictionary).get(item_id, 0))
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


func request_craft(recipe_id: StringName) -> int:
	var request_id: int = _take_request_id()
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
		_confirm_peer(peer_id, request_id, false, "craft rejected: workbench out of range")
		return

	var accepted: bool = InventoryService.host_transaction(
		peer_id,
		data.get("removals", {}) as Dictionary,
		data.get("additions", {}) as Dictionary
	)
	var detail: String
	if accepted:
		detail = "crafted %s" % String(data.get("output_name", recipe_id))
	else:
		detail = "craft rejected: missing ingredients or inventory full"
	_confirm_peer(peer_id, request_id, accepted, detail)


func _definition_data(recipe_id: StringName) -> Dictionary:
	if recipe_id == &"" or not Registry.has_recipe(recipe_id):
		return {"valid": false, "detail": "craft rejected: unknown recipe"}
	var recipe: RecipeDef = Registry.get_recipe(recipe_id)
	if recipe == null or recipe.station != WORKBENCH_STATION:
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
	}


func _station_in_range(player: Node3D, station: StringName) -> bool:
	if station != WORKBENCH_STATION:
		return false
	var max_distance_squared: float = MAX_STATION_DISTANCE_M * MAX_STATION_DISTANCE_M
	for node: Node in get_tree().get_nodes_in_group(STATION_GROUP):
		var station_node := node as Node3D
		if station_node == null:
			continue
		var asset_name := StringName(String(station_node.get_meta(&"asset", "")))
		if asset_name != WORKBENCH_ASSET:
			continue
		if player.global_position.distance_squared_to(station_node.global_position) <= max_distance_squared:
			return true
	return false


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
	elif NetTransport.is_active():
		net_craft_confirmed.rpc_id(peer_id, request_id, accepted, detail)


func _emit_confirmation(request_id: int, accepted: bool, detail: String) -> void:
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
