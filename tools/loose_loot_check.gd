extends SceneTree

## Headless contract for F-570: deterministic loot markers create persistent, collectible ordinary
## item drops through the already host-authoritative ItemDropService path.

var failures: int = 0


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var service: Node = root.get_node_or_null(^"LooseLootService")
	var drops: Node = root.get_node_or_null(^"ItemDropService")
	check(service != null, "LooseLootService is registered as an autoload")
	check(drops != null, "ItemDropService exists")
	if service == null or drops == null:
		_finish()
		return
	drops.call(&"host_clear_all")
	var game_state: Node = root.get_node_or_null(^"GameState")
	if game_state != null:
		game_state.call(&"set_replicated_seed", 570570)

	var holder := Node3D.new()
	holder.name = "LooseLootFixture"
	root.add_child(holder)
	for index: int in 40:
		var site := Node3D.new()
		site.name = "Site%d" % index
		holder.add_child(site)
		var marker := Marker3D.new()
		marker.name = "Cache_%d" % index
		marker.add_to_group(&"authored_world_marker")
		marker.set_meta(&"kind", "loot")
		site.add_child(marker)
	await process_frame
	service.call(&"refresh_current_scene")
	await process_frame

	var live: Array[Node] = drops.call(&"live_drops") as Array[Node]
	check(live.size() >= 12 and live.size() <= 28,
		"40 loot markers produce a sparse but visible set of loose drops (%d)" % live.size())
	for drop: Node in live:
		check(bool(drop.get(&"persistent")), "placed loose loot persists until collected or run restart")
		check(StringName(drop.get(&"item_id")) != &"", "placed loose loot carries a real item id")
	var before: int = live.size()
	service.call(&"refresh_current_scene")
	await process_frame
	check(int(drops.call(&"live_count")) == before, "rescanning markers never duplicates loose loot")

	drops.call(&"host_clear_all")
	root.remove_child(holder)
	holder.free()
	_finish()


func check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: %s" % label)
	else:
		failures += 1
		print("FAIL: %s" % label)


func _finish() -> void:
	print("LOOSE_LOOT_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
