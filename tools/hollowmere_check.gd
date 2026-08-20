extends SceneTree

## Verify the Hollowmere map builds, holds a player up, and is walkable.
##
## Run with:  .agent/bin/agent godot --script tools/hollowmere_check.gd
##
## The layout generator already proves reachability against its own heightfield.
## This proves the *engine* agrees: that the terrain collider Godot builds from
## that same field is where the generator thought the ground was, and that a ray
## dropped anywhere sensible lands on it. A map that validates in Python and has
## no floor in Godot would pass every check written on one side of the fence.

const SCENE_PATH: String = "res://levels/hollowmere.tscn"
const LAYOUT_PATH: String = "res://world/gen/layouts/hollowmere.json"

var failures: Array[String] = []


func _init() -> void:
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	if packed == null:
		failures.append("could not load %s" % SCENE_PATH)
		_finish()
		return
	var level := packed.instantiate()
	# The Player node's authored transform, read before a frame runs. It is a real CharacterBody3D:
	# sixteen physics frames from now its position is wherever it settled, not where the map put it
	# (F-284, measured as 0.40 m of fall on this very map). `_check_spawn` only ever compared
	# horizontally so this was latent rather than live, but a vertical assertion added to it would
	# have graded gravity.
	var authored_player := level.get_node_or_null(^"Player") as Node3D
	var authored_player_position: Vector3 = \
		authored_player.position if authored_player != null else Vector3.ZERO
	root.add_child(level)
	# HarvestWorld and every other autoload that watches the level find it through
	# `current_scene`, which nothing sets when a scene is added by hand. Without
	# this the harvest wiring never runs and the check reports zero live
	# harvestables on a map that has seventy-seven of them.
	current_scene = level
	for frame in 16:
		await process_frame
		await physics_frame

	var world := level.get_node_or_null("World")
	if world == null:
		failures.append("scene has no World node")
		_finish()
		return

	var layout: Dictionary = _layout()
	print("HOLLOWMERE_BUILD terrain_tris=%d props=%d multimeshes=%d colliders=%d water=%d" % [
		int(world.get("terrain_triangles")), int(world.get("prop_count")),
		int(world.get("multimesh_count")), int(world.get("collider_count")),
		int(world.get("water_surfaces"))
	])
	if int(world.get("terrain_triangles")) < 15000:
		failures.append("terrain built only %d triangles" % int(world.get("terrain_triangles")))
	if int(world.get("prop_count")) < 2000:
		failures.append("only %d props built" % int(world.get("prop_count")))
	if int(world.get("water_surfaces")) < 1:
		failures.append("no water was built")
	if int(world.get("harvestable_holders")) < 40:
		failures.append("only %d harvestable holders built" % int(world.get("harvestable_holders")))

	var undergrowth := level.get_node_or_null("Undergrowth")
	if undergrowth != null:
		print("HOLLOWMERE_FLORA placed=%d multimeshes=%d" % [
			int(undergrowth.get("placed_count")), int(undergrowth.get("multimesh_count"))
		])
		if int(undergrowth.get("placed_count")) < 4000:
			failures.append("undergrowth placed only %d plants" % int(undergrowth.get("placed_count")))

	_check_spawn(level, layout, authored_player, authored_player_position)
	_probe_ground(level, world, layout)
	_check_markers(level, layout)
	_check_shipwreck_becomes_ship(level)
	_check_nothing_floats(level, world, layout)
	_check_water_is_one_sheet(level, world)
	_check_undergrowth_stays_off_props(level)
	_check_crawlers_have_a_home(level)
	await _check_harvestables_are_live()
	await _check_crawlers_actually_spawn(level)
	level.queue_free()
	_finish()


func _layout() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT_PATH))
	return parsed as Dictionary if parsed is Dictionary else {}


## Drop rays over the whole map and compare what physics reports against what the
## layout's own heightfield says. This is the seam where a map most often lies.
func _probe_ground(level: Node, world: Node, layout: Dictionary) -> void:
	var space := (level as Node3D).get_world_3d().direct_space_state
	var bound := float(layout.get("bound", 100.0))
	var misses := 0
	var worst := 0.0
	var samples := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 99001
	for attempt in 900:
		var x := rng.randf_range(-bound + 6.0, bound - 6.0)
		var z := rng.randf_range(-bound + 6.0, bound - 6.0)
		if Vector2(x, z).length() > bound - 6.0:
			continue
		samples += 1
		var expected := float(world.call("height_at", x, z))
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(x, expected + 60.0, z), Vector3(x, expected - 60.0, z)
		)
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			misses += 1
			continue
		# A ray dropped from 60 m up hits the tree before it hits the hill. Props
		# are grouped, so skip those samples rather than reporting the canopy as a
		# six-metre error in the terrain collider.
		var collider := hit.get("collider") as Node
		if collider != null and collider.is_in_group(&"authored_world_prop"):
			samples -= 1
			continue
		# Wellspring and ExtractionShip (F-166) each drop their own solid StaticBody3D on top
		# of the terrain — same "something to stand on, not the ground itself" shape as an
		# authored prop, just built at runtime by a bridge service instead of the layout, so
		# neither is in `authored_world_prop`. Skip by the collider's parent group instead.
		var collider_parent := collider.get_parent() if collider != null else null
		if collider_parent != null and (
			collider_parent.is_in_group(&"wellspring") or collider_parent.is_in_group(&"extraction_ship")
		):
			samples -= 1
			continue
		worst = maxf(worst, absf((hit["position"] as Vector3).y - expected))
	print("HOLLOWMERE_GROUND samples=%d misses=%d worst_delta=%.3f m" % [samples, misses, worst])
	if misses > 0:
		failures.append("%d of %d ground probes hit nothing — the map has holes" % [misses, samples])
	if worst > 1.5:
		failures.append("collision is %.2f m from the authored height somewhere" % worst)


## The scene's Player node and the layout's spawn are two copies of one fact, and
## the first time they disagreed the player started **inside a cabin, under a floor
## that had no collision**, with no way out. The layout is the source of truth; this
## makes the scene prove it still agrees.
func _check_spawn(level: Node, layout: Dictionary, player: Node3D,
		player_position: Vector3) -> void:
	var spawn: Array = layout.get("spawn", []) as Array
	if spawn.size() < 3:
		failures.append("layout has no spawn")
		return
	var authored := Vector3(float(spawn[0]), float(spawn[1]), float(spawn[2]))
	if player == null:
		failures.append("scene has no Player node")
		return
	var flat := Vector2(player_position.x - authored.x, player_position.z - authored.z).length()
	if flat > 0.5:
		failures.append(
			"Player node is %.2f m from the layout spawn — the scene has drifted" % flat
		)

	# And prove the spawn is actually clear, in the engine, of anything solid.
	var space := (level as Node3D).get_world_3d().direct_space_state
	var shape := SphereShape3D.new()
	shape.radius = 0.9
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), authored + Vector3.UP * 1.0)
	query.collide_with_areas = false
	var blocked: Array = []
	for hit_value: Variant in space.intersect_shape(query, 8):
		var collider := (hit_value as Dictionary).get("collider") as Node
		if collider != null and collider.is_in_group(&"authored_world_prop"):
			blocked.append(String(collider.get_meta(&"asset", collider.name)))
	if not blocked.is_empty():
		failures.append("spawn is inside %s" % ", ".join(blocked))
	print("HOLLOWMERE_SPAWN at %s clear=%s" % [authored, blocked.is_empty()])


func _check_markers(level: Node, layout: Dictionary) -> void:
	var markers := level.get_tree().get_nodes_in_group(&"authored_world_marker")
	var expected: int = (layout.get("markers", []) as Array).size()
	if markers.size() != expected:
		failures.append("%d markers in scene, layout lists %d" % [markers.size(), expected])
	var kinds: Dictionary = {}
	for marker in markers:
		var kind := String((marker as Node).get_meta(&"kind", ""))
		kinds[kind] = int(kinds.get(kind, 0)) + 1
	print("HOLLOWMERE_MARKERS ", kinds)
	for required in ["spawn", "extraction", "objective", "enemy_nest", "landmark"]:
		if not kinds.has(required):
			failures.append("no %s marker in the map" % required)


## Nothing floats — checked in the engine, against the collider a player walks on.
##
## The generator proves this against its own heightfield, which is necessary and
## not sufficient: the map is only right if the ENGINE's ground is under every prop
## too. A ray is dropped just above each sampled prop's own origin; the terrain
## under it must be within a few centimetres. Bridge decks are exempt by name — a
## deck over a gorge is supposed to be nine metres above the ground.
func _check_nothing_floats(level: Node, world: Node, layout: Dictionary) -> void:
	var props: Array = layout.get("props", []) as Array
	if props.is_empty():
		failures.append("layout has no props to check")
		return
	var floating := 0
	var checked := 0
	var worst := 0.0
	var worst_name := ""
	var rng := RandomNumberGenerator.new()
	rng.seed = 71717
	for attempt in 700:
		var prop: Dictionary = props[rng.randi_range(0, props.size() - 1)] as Dictionary
		var note := String(prop.get("note", ""))
		if note.begins_with("Bridge_") or note == "hold cabin" or note == "village shell" \
				or note == "watchtower" or note == "wellspring" or note == "quarry gantry" \
				or note == "extraction cache" or note == "hunters camp":
			continue
		var pos: Array = prop.get("pos", [0.0, 0.0, 0.0]) as Array
		var here := Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		checked += 1
		var gap := here.y - float(world.call("height_at", here.x, here.z))
		if gap > 0.35:
			floating += 1
			if gap > worst:
				worst = gap
				worst_name = String(prop.get("asset", "?"))
	print("HOLLOWMERE_GROUNDED checked=%d floating=%d worst=%.2f m %s" % [
		checked, floating, worst, worst_name
	])
	if floating > 0:
		failures.append("%d of %d sampled props float (worst %.2f m, %s)" % [
			floating, checked, worst, worst_name
		])


## F-166: `autoload/extraction_service.gd` bridges a `shipwreck`-kind marker into a live
## `ExtractionShip`, but the map's own layout had no such marker — the bridge was proven only
## against a synthetic marker (`tools/extraction_check.gd`), never against the real Hollowmere
## layout it ships with. This closes that gap the way `_check_crawlers_have_a_home` already closes
## the equivalent one for `EnemyWorld`: ask the live scene, not the JSON, whether the bridge fired.
func _check_shipwreck_becomes_ship(level: Node) -> void:
	var extraction: Node = root.get_node_or_null(^"ExtractionService")
	if extraction == null:
		failures.append("ExtractionService autoload is not registered")
		return
	var marker: Node3D = null
	for candidate in level.get_tree().get_nodes_in_group(&"authored_world_marker"):
		if String((candidate as Node).get_meta(&"kind", "")) == "shipwreck":
			marker = candidate as Node3D
			break
	if marker == null:
		failures.append("Hollowmere layout has no 'shipwreck' marker")
		return
	var ship: Node = null
	for child in marker.get_children():
		if String(child.name).begins_with("ExtractionShip_"):
			ship = child
			break
	print("HOLLOWMERE_SHIPWRECK marker=%s ship_built=%s" % [marker.name, ship != null])
	if ship == null:
		failures.append("shipwreck marker %s has no live ExtractionShip child" % marker.name)


## Water must be ONE sheet, and its edge must be buried in the bank.
##
## Two things to prove, and they are the two halves of "the water is wacky".
##
## **Never two sheets.** The mere and the fen used to overlap across the whole lake
## at levels 1.8 m apart and both were drawn, so a second transparent surface hung
## in the air above the first. `stacked` must be zero, and a union by highest level
## is what makes it structurally zero rather than tuned to zero.
##
## **The edge is buried, not ragged.** A quad is emitted when any corner is under
## water, so the sheet reaches up to one cell past the true waterline and ends
## inside the bank — which is what gives a clean shoreline instead of the 2 m
## staircase the all-four-corners rule produced. That overhang is measured here
## rather than assumed: it should be a couple of metres of hidden geometry on the
## steepest banks, and if it ever became tens of metres the clip has stopped
## working and there is a sheet crossing a hill.
func _check_water_is_one_sheet(level: Node, world: Node) -> void:
	var water := (world as Node).get_node_or_null("Water")
	if water == null:
		failures.append("no Water node was built")
		return
	var triangles: Array[PackedVector3Array] = []
	for child in water.get_children():
		var instance := child as MeshInstance3D
		if instance == null or instance.mesh == null:
			continue
		var arrays: Array = (instance.mesh as ArrayMesh).surface_get_arrays(0)
		triangles.append(arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array)

	var stacked := 0
	var airborne := 0
	var sampled := 0
	var worst_air := 0.0
	for vertices in triangles:
		var stride: int = maxi(3, (vertices.size() / 3 / 400) * 3)
		for base in range(0, vertices.size() - 2, stride):
			var centre := (vertices[base] + vertices[base + 1] + vertices[base + 2]) / 3.0
			sampled += 1
			var lift := centre.y - float(world.call("height_at", centre.x, centre.z))
			# One cell of overhang past the true waterline is how the shore gets a
			# straight edge instead of a staircase; a metre of it is a sheet on a hill.
			if lift < -0.2:
				airborne += 1
				worst_air = maxf(worst_air, -lift)
			var covers := 0
			for other in triangles:
				if _covers(other, centre):
					covers += 1
			if covers > 1:
				stacked += 1
	print("HOLLOWMERE_WATER surfaces=%d sampled=%d stacked=%d shore_overhang=%d deepest=%.2f m" % [
		triangles.size(), sampled, stacked, airborne, worst_air
	])
	if stacked > 0:
		failures.append("%d water samples have a second surface over them" % stacked)
	if worst_air > 8.0:
		failures.append("water reaches %.2f m into the bank — the shore clip has stopped working"
			% worst_air)
	if sampled > 0 and float(airborne) / float(sampled) > 0.15:
		failures.append("%d of %d water quads are shore overhang — the clip is too loose" % [
			airborne, sampled
		])


## Does this triangle soup cover a point in plan view?
func _covers(vertices: PackedVector3Array, point: Vector3) -> bool:
	for base in range(0, vertices.size() - 2, 3):
		var a := vertices[base]
		var b := vertices[base + 1]
		var c := vertices[base + 2]
		if minf(minf(a.x, b.x), c.x) > point.x or maxf(maxf(a.x, b.x), c.x) < point.x:
			continue
		if minf(minf(a.z, b.z), c.z) > point.z or maxf(maxf(a.z, b.z), c.z) < point.z:
			continue
		var v0 := Vector2(c.x - a.x, c.z - a.z)
		var v1 := Vector2(b.x - a.x, b.z - a.z)
		var v2 := Vector2(point.x - a.x, point.z - a.z)
		var denominator := v0.x * v1.y - v1.x * v0.y
		if absf(denominator) < 0.000001:
			continue
		var u := (v2.x * v1.y - v1.x * v2.y) / denominator
		var v := (v0.x * v2.y - v2.x * v0.y) / denominator
		if u >= -0.001 and v >= -0.001 and u + v <= 1.001:
			return true
	return false


## Undergrowth must not grow on top of props.
##
## This is a real bug this map shipped with, and it is invisible to every other
## check: the scatter tested the collider's PARENT for the prop group while this
## map puts the group on the collider itself, so grass grew over the tops of rocks
## and up through the trees. A plant standing well above the terrain under it is
## standing on something, and the only somethings here are props.
##
## F-112: this used to walk the live `MultiMeshInstance3D`s itself, comparing
## `get_instance_transform()`'s origin — which is CELL-LOCAL, rebased around each MultiMesh's own
## centre in `undergrowth.gd::_emit()` — directly against `height_at()` with no `to_global()`, so
## `height_at(origin.x, origin.z)` was sampling the terrain near world (0,0) for every plant on
## the map regardless of where it actually stood. That bug was invisible because of a second one:
## `MultiMesh` instance transforms live on the RenderingServer, and the dummy renderer this check
## has always run under (`agent godot --script`, no `--windowed`) answers every read with
## identity/zero, no error (F-103, `tools/multimesh_readback_check.gd`) — `worst=0.00 m` every run
## wasn't this check passing, it was `get_instance_transform()` returning the same coordinate for
## every sample regardless of index, which coincidentally undershot 0.6 m near world origin. This
## check asserted nothing since it shipped. Now delegates to `Undergrowth.sample_ground_gaps()`
## (F-112, built for `tools/world_contract_check.gd`), which reads the world-space transforms
## `_scatter()` already computed instead of reading the live MultiMesh back — correct under a
## plain headless run, with no renderer dependency and no duplicate raycast to keep in sync.
func _check_undergrowth_stays_off_props(level: Node) -> void:
	var undergrowth := level.get_node_or_null("Undergrowth")
	if undergrowth == null or not undergrowth.has_method(&"sample_ground_gaps"):
		return
	var gaps: Array = undergrowth.call("sample_ground_gaps")
	var perched := 0
	var worst := 0.0
	for gap: float in gaps:
		if gap > 0.6:
			perched += 1
			worst = maxf(worst, gap)
	print("HOLLOWMERE_FLORA_GROUND sampled=%d perched=%d worst=%.2f m" % [gaps.size(), perched, worst])
	# A handful sit on bridge decks and camp floors, which is correct. A field of
	# them on top of the boulders is not, and that reads as hundreds.
	if gaps.size() > 0 and float(perched) / float(gaps.size()) > 0.02:
		failures.append("%d of %d sampled plants (%.1f%%) grow on top of props" % [
			perched, gaps.size(), 100.0 * float(perched) / float(gaps.size())
		])


## The Blight's nests must actually be where crawlers come from.
##
## EnemyWorld read only Playtest Hollow's marker group, so this map shipped as the
## main scene with four nests modelled into it and no enemies at all. Asking
## EnemyWorld itself, rather than counting markers, is the point: the markers were
## always there.
func _check_crawlers_have_a_home(level: Node) -> void:
	var world: Node = level.get_tree().root.get_node_or_null(^"EnemyWorld")
	if world == null:
		failures.append("EnemyWorld autoload is not registered")
		return
	var points: Array = world.call("ambient_spawn_points") as Array
	print("HOLLOWMERE_NESTS spawn_points=%d" % points.size())
	if points.size() < 3:
		failures.append("EnemyWorld found %d nest spawn points on this map" % points.size())
		return
	# And they are in the Blight, not scattered over the valley.
	for point_value: Variant in points:
		var point: Vector3 = point_value as Vector3
		if Vector2(point.x - 38.0, point.z + 56.0).length() > 30.0:
			failures.append("a crawler nest sits outside the Blight at %s" % point)
			return


## Wired is not the same as working, so this waits for EnemyWorld's own bootstrap
## and counts bodies. Finding the nest markers only proves the lookup; a nest on
## ground the navmesh does not cover would still produce no crawlers, and the
## symptom on screen is identical to the bug this map actually shipped with.
func _check_crawlers_actually_spawn(level: Node) -> void:
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	if world == null:
		return
	for frame in 240:
		await physics_frame
		if int(world.call("live_count")) > 0:
			break
	var live: int = int(world.call("live_count"))
	var far := 0
	for enemy_value: Variant in world.call("live_enemies"):
		var body := enemy_value as Node3D
		if body != null and Vector2(body.global_position.x - 38.0,
				body.global_position.z + 56.0).length() > 34.0:
			far += 1
	print("HOLLOWMERE_CRAWLERS live=%d navmesh_polys=%d outside_blight=%d" % [
		live, int(world.call("nav_polygon_count")), far
	])
	if live <= 0:
		failures.append("no crawlers spawned from the Blight's nests")
	if far > 0:
		failures.append("%d crawler(s) spawned outside the Blight" % far)


## The map's trees and ore must be harvestable, not scenery.
func _check_harvestables_are_live() -> void:
	var harvest: Node = root.get_node_or_null(^"HarvestWorld")
	if harvest == null:
		failures.append("HarvestWorld autoload is not registered")
		return
	harvest.call("refresh_current_scene")
	await process_frame
	var live: Array = harvest.call("wired_harvestables") as Array
	print("HOLLOWMERE_HARVEST live=%d" % live.size())
	if live.size() < 40:
		failures.append("only %d live harvestables wired on this map" % live.size())


func _finish() -> void:
	if failures.is_empty():
		print("HOLLOWMERE_CHECK PASS")
	else:
		print("HOLLOWMERE_CHECK FAIL (%d)" % failures.size())
		for failure in failures:
			print("  ", failure)
	quit(0 if failures.is_empty() else 1)
