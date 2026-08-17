extends SceneTree

## Proves the two things that were missing when Sequoyah pressed Play: you start holding something,
## and there are crawlers in the world.
##
## Deliberately loads the REAL main scene rather than an empty root. Both failures were failures of
## wiring, not of logic — `EnemyWorld.host_spawn()` worked fine and nothing called it, and the nest
## marker existed and nothing read it. A check against a bare tree would have passed throughout.

var failures: int = 0
var level: Node


func _initialize() -> void:
	# This check is ABOUT the loadout — opt in to grants, which F-052 gates out of every other
	# --script harness so net checks start from genuinely empty inventories.
	OS.set_environment("MIRE_DEV_LOADOUT", "1")
	_run.call_deferred()


func _run() -> void:
	var main_scene_path: String = str(ProjectSettings.get_setting("application/run/main_scene", ""))
	check(not main_scene_path.is_empty(), "the project has a main scene")
	var packed: PackedScene = load(main_scene_path) as PackedScene
	check(packed != null, "it loads: %s" % main_scene_path)
	if packed == null:
		finish()
		return
	level = packed.instantiate()
	root.add_child(level)
	# current_scene is what EnemyWorld bakes from; instantiating alone does not set it.
	root.get_tree().current_scene = level
	await process_frame
	await process_frame

	var registry: Node = root.get_node_or_null(^"Registry")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	var dev: Node = root.get_node_or_null(^"DevLoadout")
	check(registry != null and inventory != null and world != null and dev != null,
		"Registry, InventoryService, EnemyWorld and DevLoadout are all registered")
	if registry == null or inventory == null or world == null or dev == null:
		finish()
		return

	# ── you start with something ──────────────────────────────────────────────────────────────────
	print("\n-- starting loadout --")
	var missing: PackedStringArray = PackedStringArray()
	for entry: Dictionary in (dev.get("loadout") as Array):
		var item_id := StringName(entry.get("item", &""))
		if not bool(registry.call("has_item", item_id)):
			missing.append(String(item_id))
	check(missing.is_empty(), "every item in the loadout actually exists (%s)" % ", ".join(missing))

	var held: int = 0
	for entry: Dictionary in (dev.get("loadout") as Array):
		var item_id := StringName(entry.get("item", &""))
		if int(inventory.call("host_count", NetConfig.HOST_PEER_ID, item_id)) > 0:
			held += 1
	check(held == (dev.get("loadout") as Array).size(),
		"the local player was granted all %d stacks (%d held)"
			% [(dev.get("loadout") as Array).size(), held])
	check(int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"stone_axe")) >= 1,
		"including something to swing")
	check(int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"log")) >= 2
		and int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"stone")) >= 3,
		"and enough log and stone to craft the one workbench recipe")

	# The part that decides whether any of this is usable: 2.4 fills the backpack first, so without
	# an explicit move you start holding nothing and have to open Tab and drag before you can swing.
	var slots: Array = inventory.call("host_slots", NetConfig.HOST_PEER_ID)
	var on_bar: int = 0
	for index: int in range(24, slots.size()):
		if not (slots[index] as Dictionary).is_empty():
			on_bar += 1
	check(on_bar >= 6, "the hotbar is stocked, so you can swing without opening a menu (%d/8)" % on_bar)
	check(StringName(String((slots[24] as Dictionary).get("item_id", ""))) == &"stone_axe",
		"and slot 1 is the axe")

	# Granting twice must not double the loadout — a rebind or a late signal would otherwise stack.
	check(not bool(dev.call("grant", NetConfig.HOST_PEER_ID)), "a second grant is refused")

	# ── and there are crawlers ────────────────────────────────────────────────────────────────────
	print("\n-- ambient crawlers --")
	check(bool(world.call("has_def", &"crawler")), "the crawler is registered")
	var points: Array = world.call("ambient_spawn_points")
	check(points.size() >= 1, "the level publishes at least one enemy_spawn marker (%d)" % points.size())

	var populated: bool = await _until(
		func() -> bool: return int(world.call("live_count")) >= int(world.get("ambient_population")),
		12.0
	)
	check(populated, "ambient spawning fills the field to %d without a session (%d alive)"
		% [int(world.get("ambient_population")), int(world.call("live_count"))])
	check(int(world.call("nav_polygon_count")) > 0,
		"the level's navmesh baked (%d polygons) — crawlers path rather than steer blindly"
			% int(world.call("nav_polygon_count")))

	# The whole population is replaceable: kill the field and it refills on its own.
	world.call("host_despawn_all")
	await process_frame
	await process_frame
	check(int(world.call("live_count")) == 0, "killall empties the field")
	var refilled: bool = await _until(
		func() -> bool: return int(world.call("live_count")) >= 1, 20.0
	)
	check(refilled, "and it refills on its own (%d alive)" % int(world.call("live_count")))

	print("\nDEV_LOADOUT_CHECK alive=%d nav=%d failures=%d"
		% [int(world.call("live_count")), int(world.call("nav_polygon_count")), failures])
	finish()


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.1).timeout
	return bool(condition.call())


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
