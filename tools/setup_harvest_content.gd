extends SceneTree

## One-time, deterministic authoring helper for F-029. Resources are serialized by Godot rather
## than hand-written, preserving script/resource UIDs and external PackedScene references.

const ITEM_DEF_SCRIPT := preload("res://systems/inventory/item_def.gd")
const HARVESTABLE_DEF_SCRIPT := preload("res://systems/harvesting/harvestable_def.gd")
const SCRIPT_UID_PATHS: PackedStringArray = [
	"res://autoload/harvest_world.gd.uid",
	"res://tools/setup_harvest_content.gd.uid",
	"res://tools/harvest_world_check.gd.uid",
	"res://tools/harvest_world_net_check.gd.uid",
]

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/items"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/harvestables"))

	_save_item(&"log", "Log", "Sturdy timber harvested from Mire pines.",
		"res://assets/pickups/exports/pickup_log.glb")
	_save_item(&"stone", "Stone", "Rough stone used for tools and structures.",
		"res://assets/pickups/exports/pickup_stone.glb")
	_save_item(&"iron_ore", "Iron Ore", "Dense ore ready for smelting.",
		"res://assets/pickups/exports/pickup_iron_ore.glb")

	_save_harvestable(
		&"tree", 3, &"log", 3, 120.0,
		[
			"res://assets/harvestables/exports/harvest_tree_intact.glb",
			"res://assets/harvestables/exports/harvest_tree_damaged_a.glb",
			"res://assets/harvestables/exports/harvest_tree_damaged_b.glb",
		],
		"res://assets/harvestables/exports/harvest_tree_depleted_stump.glb"
	)
	_save_harvestable(
		&"stone_node", 3, &"stone", 3, 90.0,
		[
			"res://assets/harvestables/exports/stone_node_intact.glb",
			"res://assets/harvestables/exports/stone_node_cracked.glb",
		],
		"res://assets/harvestables/exports/stone_node_depleted.glb"
	)
	_save_harvestable(
		&"iron_node", 4, &"iron_ore", 2, 180.0,
		[
			"res://assets/harvestables/exports/iron_node_intact.glb",
			"res://assets/harvestables/exports/iron_node_cracked.glb",
		],
		"res://assets/harvestables/exports/iron_node_depleted.glb"
	)
	_ensure_script_uids()

	print("HARVEST_CONTENT_SETUP resources=6 failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _save_item(id: StringName, display_name: String, description: String, model_path: String) -> void:
	var item: Resource = ITEM_DEF_SCRIPT.new()
	item.set("id", id)
	item.set("display_name", display_name)
	item.set("description", description)
	item.set("category", 0)
	item.set("stack_size", 99)
	item.set("world_model", load(model_path) as PackedScene)
	_save(item, "res://content/items/%s.tres" % id)


func _save_harvestable(
	id: StringName,
	max_health: int,
	yield_item_id: StringName,
	yield_amount: int,
	respawn_seconds: float,
	active_paths: Array,
	depleted_path: String
) -> void:
	var definition: Resource = HARVESTABLE_DEF_SCRIPT.new()
	definition.set("id", id)
	definition.set("max_health", max_health)
	definition.set("damage_per_hit", 1)
	definition.set("yield_item_id", yield_item_id)
	definition.set("yield_amount", yield_amount)
	definition.set("respawn_seconds", respawn_seconds)
	definition.set("request_range_m", 4.0)
	definition.set("request_cooldown_seconds", 0.25)
	var active_scenes: Array[PackedScene] = []
	for path: String in active_paths:
		active_scenes.append(load(path) as PackedScene)
	definition.set("active_state_scenes", active_scenes)
	definition.set("depleted_scene", load(depleted_path) as PackedScene)
	_save(definition, "res://content/harvestables/%s.tres" % id)


func _save(resource: Resource, path: String) -> void:
	var error: Error = ResourceSaver.save(resource, path)
	if error == OK:
		print("SAVED: %s" % path)
		return
	failures += 1
	push_error("FAILED: %s (%s)" % [path, error_string(error)])


func _ensure_script_uids() -> void:
	for path: String in SCRIPT_UID_PATHS:
		if FileAccess.file_exists(path):
			continue
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			failures += 1
			push_error("FAILED: cannot create %s" % path)
			continue
		file.store_string(ResourceUID.id_to_text(ResourceUID.create_id()))
		file.close()
		print("SAVED: %s" % path)
