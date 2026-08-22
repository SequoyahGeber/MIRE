extends SceneTree

## F-146: nothing in the game placed a chest, so the gilded tier's 1-2/island budget had no owner.
## Verifies `autoload/chest_placement_service.gd` end to end against the REAL shipped Hollowmere
## map (`project.godot`'s own `main_scene`, same boot `tools/environment_vfx_hollowmere_check.gd`
## uses) rather than a synthetic stand-in — the gilded markers this task added to
## `tools/mapgen/hollowmere_layout.py` are exercised for real, not proven-but-unreachable
## (contrast F-166's shipwreck marker, blocked from the live map by a held claim; this task held
## `world/gen/layouts/hollowmere.json` itself, so there was no such gap to leave behind).
##
## Three things a name-keyed or synthetic-only check could not catch:
##   1. the 8 pre-existing `Cache_<n>` waymark markers (shipped before this bridge existed) get a
##      live, OPENABLE `small`-tier Chest, free — proving this bridge is the first real consumer of
##      content that has been sitting inert in the map since task 4.7-era authoring;
##   2. the gilded markers this task's `build_gilded_chests()` added land as real, LOCKED chests —
##      proving the economy table, not just the marker-to-tier name parse;
##   3. the budget itself: 1-2 gilded chests, no more, no fewer, in the actual generated layout.
## A fourth section builds synthetic markers to cover the negative cases a live map's fixed content
## cannot exercise on its own (wrong kind, unrecognised tier, idempotent rescan).

const MARKER_GROUP: StringName = &"authored_world_marker"

var failures: int = 0
var _open_results: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# 4.19: pinned to the authored fixture — the Cache_<n> waymarks and gilded budget this grades
	# are Hollowmere's authored layout; the procedural map's chest contract is asserted per-map by
	# tools/world_contract_check.gd.
	var scene_path := "res://levels/hollowmere.tscn"
	print("fixture scene = %s" % scene_path)
	var packed := load(scene_path) as PackedScene
	check(packed != null, "main scene loads")
	if packed == null:
		finish()
		return
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene

	var service: Node = root.get_node_or_null(^"ChestPlacementService")
	check(service != null, "ChestPlacementService is registered as an autoload")
	if service == null:
		finish()
		return

	# AuthoredWorld's build is synchronous inside _ready(), but the bridge's own refresh is
	# call_deferred (F-099's filter) — give both room, same margin
	# environment_vfx_hollowmere_check.gd uses for AuthoredWorld's own deferred phases.
	for _frame: int in 30:
		await process_frame

	_check_live_hollowmere(service)
	await _check_synthetic(service)

	finish()


func _check_live_hollowmere(service: Node) -> void:
	var markers: Array[Node] = []
	for node: Node in get_nodes_in_group(MARKER_GROUP):
		markers.append(node)
	check(not markers.is_empty(), "Hollowmere published authored_world_marker nodes")

	var cache_chests: Array[Node] = []
	var gilded_chests: Array[Node] = []
	for marker: Node in markers:
		var name_str: String = String(marker.name)
		if name_str.begins_with("Cache_"):
			var chest: Node = marker.get_node_or_null(NodePath("Chest_%s" % name_str))
			if chest != null:
				cache_chests.append(chest)
		elif name_str.begins_with("Chest_gilded_"):
			var gilded: Node = marker.get_node_or_null(NodePath("Chest_%s" % name_str))
			if gilded != null:
				gilded_chests.append(gilded)

	check(cache_chests.size() == 8, "all 8 shipped Cache_ markers got a live Chest",
		str(cache_chests.size()))
	check(gilded_chests.size() >= 1 and gilded_chests.size() <= 2,
		"gilded chest count is within the 1-2/island budget (ITEMS.md §6.4)",
		str(gilded_chests.size()))

	for chest: Node in cache_chests:
		check(StringName(chest.get("tier")) == &"small", "Cache_ chest resolved to tier 'small'")
		check(int(chest.get("cost_coins")) == 0, "Reed Cache is free")
		check(StringName(chest.get("locked_by")) == &"", "Reed Cache is unlocked")
		check(chest.get_node_or_null(^"ChestVisual") != null,
			"Reed Cache has a visible closed-state model")
	for chest: Node in gilded_chests:
		check(StringName(chest.get("tier")) == &"gilded", "gilded marker resolved to tier 'gilded'")
		check(int(chest.get("cost_coins")) == 0, "gilded chest has no coin price")
		check(StringName(chest.get("locked_by")) == &"gilded_key",
			"gilded chest is locked by a Gilded Key (ITEMS.md line 243)")
		check(chest.get_node_or_null(^"ChestVisual") != null,
			"gilded chest has a visible closed-state model")

	if not cache_chests.is_empty():
		var result: Dictionary = await _request_and_await(cache_chests[0])
		check(bool(result.get("accepted", false)), "a live, free Cache_ chest actually opens",
			String(result.get("detail", "")))

	if not gilded_chests.is_empty():
		var result: Dictionary = await _request_and_await(gilded_chests[0])
		check(not bool(result.get("accepted", false)),
			"a gilded chest refuses to open without a Gilded Key",
			String(result.get("detail", "")))
		check(String(result.get("detail", "")).contains("locked"),
			"the refusal names the lock, not a generic failure", String(result.get("detail", "")))


## Connects BEFORE calling request_open(): with no transport active, `Chest._accept_open_request()`
## runs — and `open_confirmed` fires — synchronously inside the `request_open()` call itself, not
## on a later RPC round trip. Connecting after the call would miss a signal that already fired.
func _request_and_await(chest: Node) -> Dictionary:
	var callback := func(_rid: int, accepted: bool, granted: Dictionary, detail: String) -> void:
		_open_results.append({"accepted": accepted, "granted": granted, "detail": detail})
	chest.connect(&"open_confirmed", callback)
	chest.call("request_open")
	var waited: int = 0
	while _open_results.is_empty() and waited < 30:
		await process_frame
		waited += 1
	chest.disconnect(&"open_confirmed", callback)
	if _open_results.is_empty():
		return {}
	return _open_results.pop_front()


## Negative/edge cases a fixed live map cannot exercise on its own: wrong kind, an unrecognised
## marker name, and idempotency across a second rescan.
func _check_synthetic(service: Node) -> void:
	var holder := Node3D.new()
	holder.name = "ChestPlacementCheckHolder"
	root.add_child(holder)

	var not_loot := Marker3D.new()
	not_loot.name = "Chest_gilded_should_not_build"
	not_loot.set_meta(&"kind", "station")
	not_loot.add_to_group(MARKER_GROUP)
	holder.add_child(not_loot)

	var unrecognised := Marker3D.new()
	unrecognised.name = "Waymark_9"
	unrecognised.set_meta(&"kind", "loot")
	unrecognised.add_to_group(MARKER_GROUP)
	holder.add_child(unrecognised)

	var new_gilded := Marker3D.new()
	new_gilded.name = "Chest_gilded_synthetic"
	new_gilded.set_meta(&"kind", "loot")
	new_gilded.add_to_group(MARKER_GROUP)
	holder.add_child(new_gilded)

	for _frame: int in 5:
		await process_frame

	check(not_loot.get_node_or_null(^"Chest_Chest_gilded_should_not_build") == null,
		"a non-'loot' kind marker never gets a Chest, whatever its name")
	check(unrecognised.get_node_or_null(^"Chest_Waymark_9") == null,
		"a 'loot' marker with no recognised name prefix is left alone")
	var synthetic_chest: Node = new_gilded.get_node_or_null(^"Chest_Chest_gilded_synthetic")
	check(synthetic_chest != null, "a fresh 'Chest_gilded_<n>' marker gets built on the next rescan")
	if synthetic_chest != null:
		check(StringName(synthetic_chest.get("tier")) == &"gilded",
			"the synthetic marker's tier parsed from its own name")
		check(synthetic_chest.get_node_or_null(^"ChestVisual") != null,
			"a dynamically placed chest receives a real visual model")

	service.call("refresh_current_scene")
	for _frame: int in 3:
		await process_frame
	var rebuilt_count: int = 0
	for child: Node in new_gilded.get_children():
		if child.name == "Chest_Chest_gilded_synthetic":
			rebuilt_count += 1
	check(rebuilt_count == 1, "a second rescan does not double-build an already-placed chest",
		str(rebuilt_count))

	holder.queue_free()


func check(condition: bool, description: String, detail: String = "") -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s%s" % [description, ("" if detail.is_empty() else " (%s)" % detail)])


func finish() -> void:
	print("failures=%d" % failures)
	quit(0 if failures == 0 else 1)
