extends SceneTree

## F-477: every crafting station is buildable, and a BUILT one is a real station rather than a prop.
##
## Run with:  .agent/bin/agent godot --script tools/station_buildable_check.gd
##
## The assertion that matters is the second one. `content/buildables/*.tres` and
## `content/stations/*.tres` are two separate folders that agree only by convention: the piece scene
## carries `metadata/asset`, and `CraftingService._station_positions_for()` matches that string
## against `StationDef.world_scene`. Nothing else in the codebase compares them, so a station whose
## piece scene has a typo'd meta builds fine, stands there, and never opens a crafting panel — the
## exact failure mode F-137 records for footprints. So the piece is instantiated here and put through
## `station_count()`, the same call GuideService makes, rather than string-compared on disk.

const STATION_DIR: String = "res://content/stations"
const BUILDABLE_DIR: String = "res://content/buildables"

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var crafting: Node = root.get_node_or_null(^"/root/CraftingService")
	check(crafting != null, "CraftingService autoload exists")
	if crafting == null:
		_finish()
		return

	var holder := Node3D.new()
	root.add_child(holder)

	var station_ids: Array[String] = []
	var dir := DirAccess.open(STATION_DIR)
	if dir == null:
		check(false, "content/stations is readable")
		_finish()
		return
	for file_name in dir.get_files():
		if file_name.ends_with(".tres"):
			station_ids.append(file_name.trim_suffix(".tres"))
	station_ids.sort()

	for station_id in station_ids:
		var station: Resource = load("%s/%s.tres" % [STATION_DIR, station_id]) as Resource
		var id := StringName(String(station.get(&"id")))
		var buildable: Resource = load("%s/%s.tres" % [BUILDABLE_DIR, id]) as Resource
		check(buildable != null, "%s: the station can be built, not only found" % id)
		if buildable == null:
			continue
		var cost: Dictionary = buildable.get(&"cost")
		check(not cost.is_empty(), "%s: costs resources" % id)

		var before: int = int(crafting.call("station_count", id))
		var scene: PackedScene = buildable.get(&"scene")
		var piece: Node3D = scene.instantiate() as Node3D
		holder.add_child(piece)
		var after: int = int(crafting.call("station_count", id))
		check(
			after == before + 1,
			"%s: a placed piece registers as a station" % id,
			"count %d -> %d, meta asset '%s' vs world_scene '%s'" % [
				before, after, piece.get_meta(&"asset", ""), station.get(&"world_scene")
			]
		)
		piece.queue_free()
		await process_frame

	print("STATION_BUILDABLE stations=%d" % station_ids.size())
	_finish()


func check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		print("PASS: %s" % label)
		return
	failures += 1
	print("FAIL: %s%s" % [label, "" if detail.is_empty() else " — %s" % detail])


func _finish() -> void:
	print("STATION_BUILDABLE_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
