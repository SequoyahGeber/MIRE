extends SceneTree

## F-492 — the pinecone is gathered under pines and thrown at things.
##
## Two halves, because the pinecone is two features sharing one item id:
##
## · CONTENT. It classifies as a harvestable through `HarvestLibrary`, resolves to a definition that
##   yields itself, and is actually placed by a procedural world in the biomes pines grow in.
## · THE THROW. It is its own ammo — `RangedWeaponDef.item_id == ammo_item_id` — which is a case no
##   other ranged weapon in the game exercises and which nothing in `RangedCombatService` was written
##   for. The interesting edge is the LAST pinecone: throwing it empties the very slot the host reads
##   the weapon out of, so the next request must be refused rather than throwing a phantom.
##
##   .agent/bin/agent godot --script tools/f492_pinecone_check.gd

const ResourceScatterLib := preload("res://world/gen/resource_scatter.gd")
const HarvestLib := preload("res://systems/harvesting/harvest_library.gd")
const PLAYER_CAMERA_SCRIPT := preload("res://entities/player/player_camera.gd")

const SEEDS: Array[int] = [20260821, 4242]
const CONES: Array[StringName] = [&"pinecone_open", &"pinecone_closed", &"pinecone_small"]

var failures: int = 0
var landed: Array[Dictionary] = []
var rejections: Array[Dictionary] = []


## Same minimal damage seam tools/ranged_combat_check.gd uses — a real collider at eye height, so a
## level throw can actually reach it, and nothing else.
class TestTarget extends Node3D:
	var damage_taken: int = 0
	var hit_count: int = 0

	func _ready() -> void:
		add_to_group(&"damageable")
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = 1.0
		shape.shape = sphere
		shape.position.y = 1.0
		body.add_child(shape)
		add_child(body)

	func host_apply_damage(amount: int, _instigator_peer_id: int) -> bool:
		damage_taken += amount
		hit_count += 1
		return true


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	var ranged: Node = root.get_node_or_null(^"RangedCombatService")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var harvest: Node = root.get_node_or_null(^"HarvestWorld")
	check(registry != null and ranged != null and inventory != null and harvest != null,
		"Registry, RangedCombatService, InventoryService and HarvestWorld autoloads exist")
	if registry == null or ranged == null or inventory == null or harvest == null:
		_finish()
		return

	print("== the item, the harvestable and the throw are one id ==")
	var item: ItemDef = registry.call("get_item", &"pinecone") as ItemDef
	check(item != null, "pinecone is a registered item")
	if item != null:
		check(item.stack_size > 1, "pinecones stack (%d), or you could carry exactly one" % item.stack_size)
		check(item.world_model != null and item.view_model != null,
			"the pinecone has art in the world and in the hand")
	var throw_def: RangedWeaponDef = registry.call("get_ranged_weapon", &"pinecone") as RangedWeaponDef
	check(throw_def != null, "pinecone is a registered ranged weapon")
	if throw_def == null:
		_finish()
		return
	check(throw_def.validation_errors().is_empty(), "the authored throw validates")
	check(throw_def.ammo_item_id == throw_def.item_id,
		"the pinecone is its own ammo — the whole point of the feature")
	check(throw_def.gravity_scale > 0.4,
		"a thrown cone arcs (gravity_scale %.2f); a flat one would read as a bow"
			% throw_def.gravity_scale)
	var sling: RangedWeaponDef = registry.call("get_ranged_weapon", &"sling") as RangedWeaponDef
	if sling != null:
		check(throw_def.damage < sling.damage and throw_def.max_range_m < sling.max_range_m,
			"a bare hand throws worse than a sling (%d dmg / %.0f m against %d / %.0f)"
				% [throw_def.damage, throw_def.max_range_m, sling.damage, sling.max_range_m])

	print("\n== every cone on the ground is pickable, and yields a pinecone ==")
	for asset: StringName in CONES:
		check(HarvestLib.definition_path_for(asset) == "res://content/harvestables/pinecone.tres",
			"%s harvests as pinecone" % asset)
		check(HarvestLib.representation_for(asset) == HarvestLib.Represent.BATCH,
			"%s stays in its chunk's multimesh batch — there are hundreds of them" % asset)
		var definition: Resource = harvest.call("definition_for", asset)
		check(definition != null and definition.get(&"yield_item_id") == &"pinecone",
			"%s resolves to a definition yielding pinecone" % asset)
		if definition != null:
			check(int(definition.get(&"required_tool")) == 0,
				"%s comes up bare-handed — it is lying on the floor" % asset)

	var scatter_defs: Array = registry.get(&"scatter_tables").values()
	var biome_defs: Array = registry.get(&"biomes").values()
	for world_seed: int in SEEDS:
		print("\n== seed %d, chunks [-6,6) ==" % world_seed)
		var cones: int = 0
		var pines: int = 0
		var total: int = 0
		for cx in range(-6, 6):
			for cz in range(-6, 6):
				for placement: Dictionary in ResourceScatterLib.placements_for_chunk(
					cx, cz, world_seed, scatter_defs, biome_defs
				):
					total += 1
					var asset: String = String(placement["asset"])
					if CONES.has(StringName(asset)):
						cones += 1
					elif asset.begins_with("tree_pine"):
						pines += 1
		check(cones > 0, "%d cone(s) reach the ground" % cones)
		check(pines == 0 or cones >= pines * 0.5,
			"cones are not rarer than the trees that drop them (%d cones, %d pines)" % [cones, pines])
		check(float(cones) / float(maxi(total, 1)) < 0.10,
			"litter stays litter, not a carpet (%.2f%% of %d props)"
				% [100.0 * float(cones) / float(maxi(total, 1)), total])

	print("\n== throwing one empties the hand it was thrown from ==")
	ranged.get("shot_landed").connect(func(peer: int, position: Vector3, damage: int, target_name: StringName) -> void:
		landed.append({"peer": peer, "position": position, "damage": damage, "target": target_name}))
	ranged.get("shot_rejected").connect(func(request_id: int, detail: String) -> void:
		rejections.append({"request_id": request_id, "detail": detail}))

	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	var ground_shape := CollisionShape3D.new()
	var ground_box := BoxShape3D.new()
	ground_box.size = Vector3(200.0, 1.0, 200.0)
	ground_shape.shape = ground_box
	ground_shape.position = Vector3(0.0, -50.5, 0.0)
	ground.add_child(ground_shape)
	root.add_child(ground)

	var player := Node3D.new()
	player.name = "PineconeThrower"
	player.add_to_group(&"players")
	root.add_child(player)
	var pivot: Node3D = PLAYER_CAMERA_SCRIPT.new()
	pivot.name = "CameraPivot"
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	pivot.add_child(camera)
	player.add_child(pivot)
	await process_frame
	pivot.call("set_active", true)

	# Close enough that the arc still reaches it — a pinecone drops fast, and a target at the bow's
	# test distance would land under it rather than on it.
	var target := TestTarget.new()
	target.name = "AheadTarget"
	target.position = Vector3(0.0, 0.0, -4.0)
	root.add_child(target)
	await process_frame

	check(bool(inventory.call("host_add", 1, &"pinecone", 2)), "the host grants two pinecones")
	# `host_add` picks the slot itself, and where it lands is not this check's business — only that
	# the two cones end up in the hotbar slot the throw is requested from.
	var hotbar_zero: int = int(inventory.call("hotbar_start_index"))
	if StringName(String(inventory.call("local_item_id", hotbar_zero))) != &"pinecone":
		var slots: Array[Dictionary] = inventory.call("host_slots", 1)
		for index in slots.size():
			if StringName(String(slots[index].get("item_id", ""))) == &"pinecone":
				check(bool(inventory.call("host_move_stack", 1, index, hotbar_zero, 2)),
					"both cones move into hotbar slot one")
				break
	check(int(inventory.call("host_count", 1, &"pinecone")) == 2, "two cones are held")
	check((ranged.call("ranged_weapon_for_hotbar_index", 0) as RangedWeaponDef).item_id == &"pinecone",
		"the held stack IS the weapon")

	check(int(ranged.call("request_shot", 0)) > 0, "the first throw is accepted")
	var connected: bool = await _until(func() -> bool: return target.hit_count > 0, 3.0)
	check(connected, "the host resolves the throw against its own world")
	check(target.damage_taken == throw_def.damage, "the authored throw damage lands")
	check(int(inventory.call("host_count", 1, &"pinecone")) == 1,
		"exactly one pinecone leaves the stack it was thrown from")
	await _until(func() -> bool: return int(ranged.call("local_phase")) == 0, 3.0)

	check(int(ranged.call("request_shot", 0)) > 0, "the last pinecone can be thrown")
	var emptied: bool = await _until(
		func() -> bool: return int(inventory.call("host_count", 1, &"pinecone")) == 0, 3.0)
	check(emptied, "throwing the last one empties the slot")
	await _until(func() -> bool: return int(ranged.call("local_phase")) == 0, 3.0)

	# The self-ammo edge: the slot the host reads the weapon out of is the slot the ammo came from,
	# so an empty hand must resolve to no weapon at all rather than to a throw with nothing to throw.
	check(ranged.call("ranged_weapon_for_hotbar_index", 0) == null,
		"an emptied slot holds no weapon")
	check(int(ranged.call("request_shot", 0)) == -1, "throwing an empty hand is refused outright")

	_finish()


func check(condition: bool, label: String) -> void:
	if condition:
		print("  PASS  %s" % label)
	else:
		failures += 1
		print("  FAIL  %s" % label)


func _until(predicate: Callable, timeout_seconds: float) -> bool:
	var elapsed := 0.0
	while elapsed < timeout_seconds:
		if bool(predicate.call()):
			return true
		await process_frame
		elapsed += 1.0 / 60.0
	return bool(predicate.call())


func _finish() -> void:
	print("\n%s (%d failure(s))" % ["OK" if failures == 0 else "FAILED", failures])
	quit(0 if failures == 0 else 1)
