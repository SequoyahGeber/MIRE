extends SceneTree

## Verifies F-586 — every SOLID scattered world asset collides, and nothing soft does.
##
## The bug this exists to keep fixed was reported from a run as "theres some rocks and stuff that i
## could walk through". `world/gen/resource_scatter_field.gd` builds a scattered group two ways, and
## only the NODE-harvestable branch ever built a `StaticBody3D`. Everything else — all decorative
## scatter, which is the entire rock population of the island, plus every BATCH harvestable — went
## down the MultiMesh branch, which drew the prop and gave it no collision at all.
##
## Two halves, because "every world asset has a collision box" is two separate claims:
##
##  1. CLASSIFICATION. `world/gen/prop_collider.gd` is asked directly about the shipped `.glb`s
##     named by the shipped `content/scatter/*.tres` tables. A boulder must fit; grass, ferns and
##     moss must NOT (a blanket collider on ground flora would be a real performance regression at
##     scatter's densities, and would also be wrong — you walk through a fern). A tree must fit and
##     its collider must stop at the trunk band, never reaching its canopy: that is the standing art
##     directive F-348/F-390 encode, and "give everything a box" must not quietly undo it.
##
##  2. CONSTRUCTION. A real `ResourceScatterField` is driven against the same `FakeStreamer` double
##     `tools/resource_scatter_check.gd` uses, and every batched group it builds is inspected: a
##     group whose asset fits must carry one collision shape per MultiMesh instance, positioned
##     where that instance is drawn. This is the half that actually fails on the pre-F-586 file.
##
## Fully headless — the fitter is pure geometry and the field's state machine is driven by hand, so
## no renderer and no real collision cook is involved.
##
##   .agent/bin/agent godot --script tools/scatter_collision_check.gd

const PropCollider := preload("res://world/gen/prop_collider.gd")
const ResourceScatterLib := preload("res://world/gen/resource_scatter.gd")
const ResourceScatterFieldScript := preload("res://world/gen/resource_scatter_field.gd")

const SEED_A: int = 20260818

## Solid props sampled straight out of the shipped rock tables — the exact assets the player
## reported walking through.
const MUST_COLLIDE: Array[Array] = [
	["environment", "boulder_e"],
	["environment", "boulder_f"],
	["environment", "boulder_g"],
	["environment", "rock_cluster_d"],
	["environment", "rock_cluster_e"],
	["environment_additions", "mire_mossy_boulder"],
]

var failures: int = 0
var registry: Node
var _mesh_cache: Dictionary = {}
var _fit_cache: Dictionary = {}


## The two signals and one method `ResourceScatterField.attach_to_streamer()` reads, with collision
## timing under this check's control rather than a physics cook's. Same double as
## `tools/resource_scatter_check.gd`.
class FakeStreamer:
	extends Node
	signal chunk_mesh_ready(coord: Vector2i, lod: int)
	signal chunk_unloaded(coord: Vector2i)
	var _collision: Dictionary[Vector2i, bool] = {}

	func chunk_has_collision(coord: Vector2i) -> bool:
		return _collision.get(coord, false)

	func set_collision(coord: Vector2i, value: bool) -> void:
		_collision[coord] = value


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	registry = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry is registered as an autoload")
	if registry == null:
		quit(1)
		return

	_check_classification()
	_check_foliage_stays_walkable()
	_check_trunk_band_respected()
	await _check_batched_groups_collide()

	print("\nSCATTER_COLLISION_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _check_classification() -> void:
	print("== the fitter calls the shipped rocks solid ==")
	for pair: Array in MUST_COLLIDE:
		var parts: Array = _mesh_parts(pair[0], pair[1])
		if parts.is_empty():
			check(false, "%s/%s has mesh geometry to measure" % [pair[0], pair[1]])
			continue
		var fit: Dictionary = _fit(pair[0], pair[1])
		check(not fit.is_empty(), "%s is a solid prop and gets a collider" % pair[1])


func _check_foliage_stays_walkable() -> void:
	print("\n== ground flora is still walk-through, at every asset the tables place ==")
	var soft_total: int = 0
	var soft_wrongly_solid: PackedStringArray = []
	for entry: Array in _scattered_assets():
		var parts: Array = _mesh_parts(entry[0], entry[1])
		if parts.is_empty():
			continue
		# The independent witness: a prop made ENTIRELY of foliage surfaces is soft by definition,
		# whatever the fitter says. Asking `has_foliage()` alone would let a tree in.
		if not _is_all_foliage(parts):
			continue
		soft_total += 1
		if not _fit(entry[0], entry[1]).is_empty():
			soft_wrongly_solid.append(entry[1])
	check(soft_total > 0, "the shipped tables place at least one all-foliage asset to test (%d)" % soft_total)
	check(soft_wrongly_solid.is_empty(),
		"no all-foliage asset was given a collider (%s)" % soft_wrongly_solid)


func _check_trunk_band_respected() -> void:
	print("\n== a tree collides as its trunk, never its canopy ==")
	var trees: int = 0
	var over_band: PackedStringArray = []
	for entry: Array in _scattered_assets():
		if not String(entry[1]).begins_with("tree_"):
			continue
		var parts: Array = _mesh_parts(entry[0], entry[1])
		if parts.is_empty():
			continue
		var fit: Dictionary = _fit(entry[0], entry[1])
		if fit.is_empty():
			continue
		trees += 1
		# The directive is about WIDTH, not height. A cylinder is allowed to be as tall as the trunk
		# is — a pine's bole really is solid for 18 m, and stopping the shape at the 1.8 m obstacle
		# height would let a player walk through the upper trunk. What must never happen is the
		# shape growing out to the CANOPY, which is the 1.25-1.37 m radius F-348/F-390 removed. So
		# the assertion is the fitted radius against the prop's full foliage-inclusive half-width:
		# a collider measured off leaves would be a large fraction of it, a trunk fit is a sliver.
		if StringName(fit.get("shape", &"cylinder")) == &"box":
			continue                                        # a fallen tree is a log, not a canopy
		var radius: float = float(fit["radius"])
		var canopy: float = _canopy_half_width(parts)
		if canopy > 0.0 and radius > canopy * 0.5:
			over_band.append("%s (%.2f m radius against a %.2f m canopy)" % [entry[1], radius, canopy])
	check(trees > 0, "the shipped tables place at least one tree to test (%d)" % trees)
	check(over_band.is_empty(),
		"no tree's collider is measured off its canopy rather than its trunk (%s)" % over_band)


func _check_batched_groups_collide() -> void:
	print("\n== a batched scatter group carries one shape per instance ==")
	var biome_defs: Array = registry.get(&"biomes").values()
	var scatter_defs: Array = registry.get(&"scatter_tables").values()

	var scene := Node3D.new()
	scene.name = "ScatterCollisionCheckScene"
	root.add_child(scene)
	current_scene = scene

	var field := ResourceScatterFieldScript.new()
	field.world_seed = SEED_A
	field.scatter_defs = scatter_defs
	field.biome_defs = biome_defs
	scene.add_child(field)

	var fake_streamer := FakeStreamer.new()
	scene.add_child(fake_streamer)
	field.attach_to_streamer(fake_streamer)

	# A spread of chunks rather than one, so the assertion covers whatever mix of tables the island
	# actually produces near the origin instead of one chunk's luck.
	var coords: Array[Vector2i] = []
	for cx in range(-3, 4):
		for cz in range(-3, 4):
			var placements: Array[Dictionary] = ResourceScatterLib.placements_for_chunk(
				cx, cz, SEED_A, scatter_defs, biome_defs
			)
			if not placements.is_empty():
				coords.append(Vector2i(cx, cz))
	check(not coords.is_empty(), "the island produces scatter near the origin to inspect (%d chunks)" % coords.size())

	for coord: Vector2i in coords:
		fake_streamer.set_collision(coord, true)
		fake_streamer.chunk_mesh_ready.emit(coord, 0)
	await _wait_real_seconds(1.5)

	var groups_seen: int = 0
	var solid_groups: int = 0
	var shapes_built: int = 0
	var missing: PackedStringArray = []
	var miscounted: PackedStringArray = []
	var misplaced: PackedStringArray = []
	var soft_with_body: PackedStringArray = []
	var unverifiable: PackedStringArray = []

	for instance: Node in scene.find_children("*", "MultiMeshInstance3D", true, false):
		var multimesh: MultiMesh = (instance as MultiMeshInstance3D).multimesh
		if multimesh == null or multimesh.instance_count == 0:
			continue
		# Part 0 only: a group with several mesh parts publishes one MultiMeshInstance3D per part
		# and one shared CollisionBody, so counting per part would demand N bodies for one group.
		if not String(instance.name).ends_with("_0"):
			continue
		var group_holder := instance.get_parent() as Node3D
		if group_holder == null:
			continue
		groups_seen += 1
		var asset := String(instance.get_meta(&"asset", ""))
		var kit: String = _kit_for(asset)
		var fit: Dictionary = _fit(kit, asset) if not kit.is_empty() else {}
		var body := group_holder.get_node_or_null(^"CollisionBody") as StaticBody3D

		if fit.is_empty():
			if body != null:
				soft_with_body.append(asset)
			continue

		solid_groups += 1
		if body == null:
			missing.append("%s x%d" % [asset, multimesh.instance_count])
			continue
		var shapes: Array[Node] = body.find_children("*", "CollisionShape3D", false, false)
		shapes_built += shapes.size()
		if shapes.size() != multimesh.instance_count:
			miscounted.append("%s (%d shapes for %d instances)"
				% [asset, shapes.size(), multimesh.instance_count])
			continue
		# Position, not just count: a body full of shapes stacked at the group origin would pass a
		# count assertion and still leave every rock but one walk-through. Each shape's origin must
		# sit within the drawn instance's own footprint.
		# F-103/F-547: `multimesh.get_instance_transform()` reads back as IDENTITY under
		# `--headless` — the transforms live in the RenderingServer and there is no server to hold
		# them. An earlier draft of this check used it and every group away from the origin
		# "failed" by exactly its own distance from the origin, which is the readback returning
		# nothing rather than a real defect. The `placements` meta part 0 publishes for
		# EnvironmentVfx carries the same origins CPU-side, and is what this asserts against.
		var drawn_origins: PackedVector3Array = instance.get_meta(&"placements", PackedVector3Array())
		if drawn_origins.is_empty():
			unverifiable.append(asset)
			continue
		var worst: float = 0.0
		for drawn: Vector3 in drawn_origins:
			var nearest: float = INF
			for shape_node: Node in shapes:
				var offset: Vector3 = (shape_node as CollisionShape3D).transform.origin - drawn
				# Y is deliberately excluded: the fit lifts a shape to its own centre height, which
				# is exactly the offset from the drawn instance's origin that it should have.
				nearest = minf(nearest, Vector2(offset.x, offset.z).length())
			worst = maxf(worst, nearest)
		if worst > 0.5:
			misplaced.append("%s (%.2f m from the nearest shape)" % [asset, worst])

	check(groups_seen > 0, "the field built batched scatter groups to inspect (%d)" % groups_seen)
	check(solid_groups > 0, "at least one of them is a solid prop that must collide (%d)" % solid_groups)
	check(missing.is_empty(), "every solid batched group has a CollisionBody (%s)" % missing)
	check(miscounted.is_empty(), "each one carries exactly one shape per drawn instance (%s)" % miscounted)
	check(misplaced.is_empty(), "each shape sits under the instance it collides for (%s)" % misplaced)
	check(unverifiable.is_empty(),
		"every solid group published the placements this check reads positions from (%s)" % unverifiable)
	check(soft_with_body.is_empty(),
		"no soft group was given a body it should not have (%s)" % soft_with_body)
	print("     %d shapes across %d solid groups" % [shapes_built, solid_groups])


## Every (kit, asset) any shipped scatter table can place.
func _scattered_assets() -> Array[Array]:
	var out: Array[Array] = []
	var seen: Dictionary = {}
	for def: Resource in registry.get(&"scatter_tables").values():
		for entry: Resource in def.get(&"entries"):
			var kit := String(entry.get(&"kit"))
			var asset := String(entry.get(&"asset"))
			var key := "%s|%s" % [kit, asset]
			if seen.has(key):
				continue
			seen[key] = true
			out.append([kit, asset])
	return out


func _kit_for(asset: String) -> String:
	for entry: Array in _scattered_assets():
		if String(entry[1]) == asset:
			return String(entry[0])
	return ""


## Loaded exactly the way `ResourceScatterField._load_mesh_parts()` loads them, so the fitter is
## asked about the same geometry the field feeds it.
func _mesh_parts(kit: String, asset: String) -> Array:
	var key := "%s|%s" % [kit, asset]
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var parts: Array = []
	var path := "res://assets/%s/exports/%s.glb" % [kit, asset]
	var packed: PackedScene = load(path) as PackedScene
	if packed != null:
		var sample := packed.instantiate()
		var found: Array[MeshInstance3D] = []
		_collect_meshes(sample, found)
		for part: MeshInstance3D in found:
			if part.mesh != null:
				parts.append({"mesh": part.mesh, "offset": _global_offset(part, sample)})
		sample.free()
	_mesh_cache[key] = parts
	return parts


func _fit(kit: String, asset: String) -> Dictionary:
	var parts: Array = _mesh_parts(kit, asset)
	if parts.is_empty():
		return {}
	return PropCollider.fit_cached(_fit_cache, "%s|%s" % [kit, asset], parts)


func _is_all_foliage(parts: Array) -> bool:
	var surfaces: int = 0
	for part: Dictionary in parts:
		var mesh: Mesh = part["mesh"] as Mesh
		for surface: int in mesh.get_surface_count():
			surfaces += 1
			var material: Material = mesh.surface_get_material(surface)
			var name := "" if material == null else String(material.resource_name)
			var foliage := false
			for prefix: String in PropCollider.FOLIAGE_MATERIAL_PREFIXES:
				if name.begins_with(prefix):
					foliage = true
					break
			if not foliage:
				return false
	return surfaces > 0


## The prop's widest horizontal half-extent counting EVERYTHING, leaves included — the number a
## canopy-derived collider would be a large fraction of.
func _canopy_half_width(parts: Array) -> float:
	var widest: float = 0.0
	for part: Dictionary in parts:
		var box: AABB = (part["offset"] as Transform3D) * ((part["mesh"] as Mesh).get_aabb())
		for corner: Vector3 in [box.position, box.end]:
			widest = maxf(widest, maxf(absf(corner.x), absf(corner.z)))
	return widest


func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		_collect_meshes(child, out)


func _global_offset(node: Node3D, source_root: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != source_root:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result


func _wait_real_seconds(seconds: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
