extends Node

## Turns deterministic world markers into ordinary collectible items lying around the island.
## NETWORK AUTHORITY: HOST. Placement is derived from the run seed and marker NodePath, but only the
## host spawns; ItemDropService's MultiplayerSpawner replicates each body and ItemDrop revalidates
## pickup range and inventory capacity. A consumed drop is absent from the spawner for late joiners.

const MARKER_GROUP: StringName = &"authored_world_marker"
const BUILT_META: StringName = &"mire_loose_loot_placed"
const ITEM_POOL: Array[StringName] = [
	&"berry", &"mushroom", &"wild_onion", &"fibre_bundle", &"flint", &"stone",
	&"branch", &"resin", &"arrow", &"bolt", &"iron_ore", &"coal",
]
const SEED_SALT: int = 0x1005E1007

var _refresh_scheduled: bool = false


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	_schedule_refresh()


func refresh_current_scene() -> void:
	_refresh_scheduled = false
	if not _owns_mutation():
		return
	for node: Node in get_tree().get_nodes_in_group(MARKER_GROUP):
		_maybe_place(node as Node3D)


func _on_node_added(node: Node) -> void:
	if node.is_in_group(MARKER_GROUP):
		_schedule_refresh()


func _schedule_refresh() -> void:
	if _refresh_scheduled:
		return
	_refresh_scheduled = true
	call_deferred(&"refresh_current_scene")


func _maybe_place(marker: Node3D) -> void:
	if marker == null or marker.has_meta(BUILT_META):
		return
	if String(marker.get_meta(&"kind", "")) != "loot":
		return
	marker.set_meta(BUILT_META, true)
	var key: String = String(marker.get_path())
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_for_marker(_run_seed(), key)
	# Roughly half of chest sites also advertise loose loot, keeping the world readable while still
	# producing 20-30 collectible piles on the 50-chest procedural island.
	if rng.randi_range(0, 1) == 0:
		return
	var item_id: StringName = ITEM_POOL[rng.randi_range(0, ITEM_POOL.size() - 1)]
	var amount: int = rng.randi_range(1, 3)
	var angle: float = rng.randf_range(0.0, TAU)
	var distance: float = rng.randf_range(2.0, 4.5)
	var position: Vector3 = marker.global_position + Vector3(cos(angle), 0.0, sin(angle)) * distance
	var drops: Node = get_node_or_null(^"/root/ItemDropService")
	if drops != null:
		drops.call(&"host_spawn_placed_drop", item_id, amount, position)


func _seed_for_marker(run_seed: int, marker_key: String) -> int:
	const PRIME: int = 1000003
	var id_hash: int = 0x1000193
	for byte: int in marker_key.to_utf8_buffer():
		id_hash = (id_hash ^ byte) * 16777619
	return (run_seed ^ SEED_SALT) * PRIME + id_hash


func _run_seed() -> int:
	var game_state: Node = get_node_or_null(^"/root/GameState")
	return 0 if game_state == null else int(game_state.call(&"ensure_seed"))


func _owns_mutation() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null or bool(transport.call(&"is_host")):
		return true
	return not bool(transport.call(&"is_active")) and not bool(transport.call(&"is_connecting"))
