extends Node3D

## Client-local undergrowth scatter for the authored maps.
##
## ## Network authority (ARCHITECTURE.md §2.2)
##
## **None. This system is presentation only and every peer runs it independently.**
## It is deterministic — the seed comes from the layout file, so every peer draws
## the identical field of plants without a byte crossing the wire — and it creates
## no collision, no interaction, and no state any other system reads. Nothing here
## may ever gate gameplay: if undergrowth later needs to hide a player or be
## trampled, that is a host-authoritative system and it does not live in this file.
##
## ## Why this exists
##
## `assets/maps/playtest_hollow.glb` is an authored map: 751 props placed by hand
## in `tools/mapgen/hollow_layout.py` and frozen. Hand-placing the tens of
## thousands of plants it takes to make ground look alive is not work a person
## should do, and freezing them into the map GLB would bloat it for no gain. So
## the authored layout keeps owning the things whose position *matters* — trees
## you navigate by, rocks you take cover behind, everything with collision — and
## this fills the gaps between them with things whose position does not.
##
## ## How it places
##
## By raycast, not by reading the heightfield. The ground under a given point may
## be the heightfield, a terrain slab, a ridge terrace or a camp deck, and those
## live in different parts of the layout; a ray hits whichever is actually there.
## It also lands on the *collision* the player walks on rather than on a parallel
## reconstruction of it, so undergrowth cannot drift from the ground the way two
## copies of a layout always eventually do.
##
## Zones come from the layout's own props: each carries a zone name, so their
## centroids define where each zone is without this file hard-coding a single
## coordinate of the Hollow.

const FLORA_DIR: String = "res://assets/flora/exports"
const RAY_START_HEIGHT: float = 24.0
const RAY_END_HEIGHT: float = -12.0
const MAX_GROUND_SLOPE_DEG: float = 34.0

## Total plants attempted across the whole map. Roughly a third are rejected for
## landing on a prop, a slope or outside the ring, so the visible count is lower.
@export var density: int = 4200
## Turn the whole system off without touching the scene.
@export var enabled: bool = true
## Which authored layout to dress. Any map that carries `zones`, `props`, `roads`
## and `bound` works; nothing here is specific to one map.
@export_file("*.json") var layout_path: String = "res://world/gen/layouts/playtest_hollow.json"
## Group whose members count as "a prop is already here, do not grow on it".
@export var prop_group: StringName = &"playtest_hollow_asset"

## Which flora each zone draws from, and how much of its budget goes to each.
## Ordinary ground cover dominates every list: a scatter reads as a *place* when
## one or two things repeat and the rest are occasional, and reads as a garden
## centre when everything is equally likely.
const ZONE_PALETTES: Dictionary = {
	"SpawnCamp": {
		"grass_short": 30, "clover_patch": 18, "flowers_creeping": 10, "grass_dry": 8,
		"flowers_meadow": 8, "plant_creeper": 6, "moss_patch": 4, "nettle": 3,
	},
	"WestForest": {
		"leaf_litter": 22, "bracken": 16, "moss_patch": 14, "grass_short": 10,
		"plant_broadleaf": 8, "nettle": 6, "bush_round": 5, "sapling": 4,
		"plant_creeper": 4, "bush_broadleaf": 3, "tree_snag": 1,
	},
	"NorthRuins": {
		"grass_dry": 22, "moss_patch": 18, "grass_short": 14, "nettle": 8,
		"clover_patch": 8, "bush_thorn": 6, "bush_dead": 4, "plant_dock": 4,
	},
	"EastMire": {
		"sedge": 22, "marsh_grass": 20, "lily_pad": 12, "flowers_bog": 10,
		"moss_patch": 8, "grass_dry": 8, "bush_dead": 5, "tree_snag": 2,
	},
	"SouthRidge": {
		"grass_dry": 26, "grass_tussock": 18, "grass_short": 12, "flowers_meadow": 8,
		"plant_dock": 6, "bush_thorn": 5, "bush_round": 4, "sapling": 3,
	},
	"RoutesAndBoundary": {
		"grass_short": 26, "grass_dry": 16, "flowers_meadow": 10, "grass_tussock": 8,
		"clover_patch": 8, "leaf_litter": 6, "bush_round": 4, "sapling": 2,
	},
	# -- Hollowmere ---------------------------------------------------------
	"SpawnHold": {
		"grass_short": 30, "clover_patch": 16, "flowers_meadow": 12, "flowers_creeping": 8,
		"grass_tussock": 8, "plant_creeper": 6, "moss_patch": 4, "bush_round": 4,
	},
	"WestWood": {
		"leaf_litter": 22, "bracken": 18, "moss_patch": 12, "grass_short": 12,
		"plant_broadleaf": 8, "nettle": 6, "bush_round": 5, "sapling": 5, "plant_creeper": 4,
	},
	"DeepForest": {
		"leaf_litter": 26, "bracken": 20, "moss_patch": 14, "grass_short": 10,
		"plant_broadleaf": 8, "nettle": 6, "plant_creeper": 6, "bush_round": 4, "sapling": 3,
	},
	"Plateau": {
		"grass_dry": 30, "grass_tussock": 20, "moss_patch": 14, "grass_short": 12,
		"bush_thorn": 8, "plant_dock": 6, "clover_patch": 5, "flowers_meadow": 5,
	},
	"Quarry": {
		"grass_dry": 30, "moss_patch": 22, "grass_short": 16, "nettle": 10,
		"bush_thorn": 8, "plant_dock": 8, "leaf_litter": 6,
	},
	"Gorge": {
		"moss_patch": 30, "sedge": 18, "bracken": 14, "grass_short": 12,
		"leaf_litter": 10, "nettle": 8, "plant_creeper": 8,
	},
	"BoneFields": {
		"grass_dry": 34, "leaf_litter": 18, "bush_dead": 12, "grass_tussock": 10,
		"plant_dock": 8, "moss_patch": 8, "bush_thorn": 6, "nettle": 4,
	},
	"StoneMoor": {
		"grass_tussock": 26, "grass_dry": 24, "grass_short": 14, "moss_patch": 12,
		"flowers_meadow": 10, "bush_thorn": 8, "clover_patch": 6,
	},
	"EastReach": {
		"grass_short": 24, "nettle": 16, "flowers_tall": 12, "clover_patch": 12,
		"plant_creeper": 10, "moss_patch": 10, "grass_dry": 8, "bush_round": 4,
	},
	"MereShore": {
		"marsh_grass": 24, "sedge": 20, "lily_pad": 12, "flowers_bog": 12,
		"moss_patch": 10, "grass_short": 10, "leaf_litter": 6, "bush_dead": 4,
	},
	"SouthMarsh": {
		"sedge": 26, "marsh_grass": 22, "flowers_bog": 14, "moss_patch": 12,
		"lily_pad": 10, "grass_dry": 8, "bush_dead": 4, "nettle": 4,
	},
	"LumberEdge": {
		"leaf_litter": 26, "bracken": 18, "grass_short": 14, "sapling": 12,
		"moss_patch": 12, "nettle": 8, "plant_broadleaf": 6, "bush_round": 4,
	},
}

## Anything taller than this stays out of a road corridor. The layout already says
## ground cover may sit on a road and solid props may not; a bush is neither, and
## a trail you cannot see is not a trail.
const ROAD_CLEAR_FAMILIES: PackedStringArray = [
	"bush_round", "bush_broadleaf", "bush_thorn", "bush_dead", "sapling", "tree_snag",
	"grass_tussock", "marsh_grass", "sedge",
]

var placed_count: int = 0
var multimesh_count: int = 0

var _rng := RandomNumberGenerator.new()
var _zone_centres: Dictionary = {}
var _roads: Array = []
var _bound: float = 40.0
var _variants: Dictionary = {}
var _placements: Dictionary = {}


func _ready() -> void:
	if not enabled:
		return
	var layout := _read_layout()
	if layout.is_empty():
		return
	# The colliders this scatters onto are built by a sibling node's `_ready`, and
	# a shape is not in the physics space until the frame after it is added.
	await get_tree().physics_frame
	await get_tree().physics_frame
	_scatter(layout)


func _read_layout() -> Dictionary:
	var text := FileAccess.get_file_as_string(layout_path)
	if text.is_empty():
		push_error("Undergrowth could not read %s" % layout_path)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		push_error("Undergrowth layout is not a JSON object: %s" % layout_path)
		return {}
	return parsed as Dictionary


func _scatter(layout: Dictionary) -> void:
	_rng.seed = int(layout.get("seed", 0)) ^ 0x5F10A
	_bound = float(layout.get("bound", 40.0))
	_roads = layout.get("roads", []) as Array
	_collect_zone_centres(layout)
	if _zone_centres.is_empty():
		push_error("Undergrowth found no zones in the layout; nothing to scatter")
		return
	_collect_variants()

	var space := get_world_3d().direct_space_state
	for attempt in density:
		var point := Vector2(
			_rng.randf_range(-_bound, _bound), _rng.randf_range(-_bound, _bound)
		)
		if point.length() > _bound:
			continue
		var zone := _zone_for(point)
		var family := _pick_family(zone)
		if family.is_empty():
			continue
		if _on_road(point) and ROAD_CLEAR_FAMILIES.has(family):
			continue
		var hit := _ground_at(space, point)
		if hit.is_empty():
			continue
		var asset := _pick_variant(family)
		if asset.is_empty():
			continue
		_placements.get_or_add(asset, [] as Array).append(
			Transform3D(Basis(Vector3.UP, _rng.randf_range(0.0, TAU)), hit["position"] as Vector3)
			.scaled_local(Vector3.ONE * _rng.randf_range(0.86, 1.18))
		)
		placed_count += 1

	for asset: String in _placements:
		_emit(asset, _placements[asset] as Array)
	print(
		"UNDERGROWTH placed=%d assets=%d multimeshes=%d" % [
			placed_count, _placements.size(), multimesh_count
		]
	)


## Zone extents come from the props the layout already places there, so this file
## never states where the West Forest is — it asks the map.
func _collect_zone_centres(layout: Dictionary) -> void:
	# A layout that states its own zones is believed; the Hollow does not, so its
	# zones are still inferred from where its props ended up.
	for zone_value: Variant in layout.get("zones", []):
		if zone_value is Dictionary:
			var zone := zone_value as Dictionary
			var name := String(zone.get("name", ""))
			var centre: Array = zone.get("centre", [0.0, 0.0]) as Array
			if ZONE_PALETTES.has(name):
				_zone_centres[name] = Vector2(float(centre[0]), float(centre[1]))
	if not _zone_centres.is_empty():
		return
	var sums: Dictionary = {}
	var counts: Dictionary = {}
	for prop_value: Variant in layout.get("props", []):
		var prop := prop_value as Dictionary
		var zone := String(prop.get("zone", ""))
		if not ZONE_PALETTES.has(zone):
			continue
		var pos: Array = prop.get("pos", [0.0, 0.0, 0.0]) as Array
		var flat := Vector2(float(pos[0]), float(pos[2]))
		sums[zone] = (sums.get(zone, Vector2.ZERO) as Vector2) + flat
		counts[zone] = int(counts.get(zone, 0)) + 1
	for zone: String in sums:
		_zone_centres[zone] = (sums[zone] as Vector2) / float(counts[zone])


func _collect_variants() -> void:
	var dir := DirAccess.open(FLORA_DIR)
	if dir == null:
		push_error("Undergrowth cannot open %s" % FLORA_DIR)
		return
	for file_name in dir.get_files():
		if not file_name.ends_with(".glb"):
			continue
		var asset := file_name.get_basename()
		var family := asset.substr(0, asset.rfind("_"))
		_variants.get_or_add(family, [] as Array).append(asset)
	for family: String in _variants:
		(_variants[family] as Array).sort()


func _zone_for(point: Vector2) -> String:
	var best := ""
	var best_distance := INF
	for zone: String in _zone_centres:
		var distance := point.distance_squared_to(_zone_centres[zone] as Vector2)
		if distance < best_distance:
			best_distance = distance
			best = zone
	return best


func _pick_family(zone: String) -> String:
	var palette: Dictionary = ZONE_PALETTES.get(zone, {}) as Dictionary
	var total := 0
	for family: String in palette:
		total += int(palette[family])
	if total <= 0:
		return ""
	var roll := _rng.randi_range(0, total - 1)
	for family: String in palette:
		roll -= int(palette[family])
		if roll < 0:
			return family if _variants.has(family) else ""
	return ""


func _pick_variant(family: String) -> String:
	var options: Array = _variants.get(family, [] as Array) as Array
	if options.is_empty():
		return ""
	return String(options[_rng.randi_range(0, options.size() - 1)])


func _on_road(point: Vector2) -> bool:
	for road_value: Variant in _roads:
		var road := road_value as Dictionary
		var x0 := float(road.get("x0", 0.0))
		var z0 := float(road.get("z0", 0.0))
		var x1 := float(road.get("x1", 0.0))
		var z1 := float(road.get("z1", 0.0))
		if point.x >= minf(x0, x1) and point.x <= maxf(x0, x1) \
				and point.y >= minf(z0, z1) and point.y <= maxf(z0, z1):
			return true
	return false


func _ground_at(space: PhysicsDirectSpaceState3D, point: Vector2) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(point.x, RAY_START_HEIGHT, point.y), Vector3(point.x, RAY_END_HEIGHT, point.y)
	)
	query.collide_with_areas = false
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return {}
	# Landing on a boulder or a roof would be worse than not placing at all: props
	# are grouped by the layout runtime, so the group is the test.
	var collider := hit.get("collider") as Node
	if collider != null:
		var holder := collider.get_parent()
		if holder != null and holder.is_in_group(prop_group):
			return {}
	if (hit["normal"] as Vector3).angle_to(Vector3.UP) > deg_to_rad(MAX_GROUND_SLOPE_DEG):
		return {}
	return hit


## One MultiMeshInstance3D per mesh part per asset. A flora GLB is two to four
## parts (one per material), so a family placed 300 times costs three draw calls,
## not 300 nodes.
func _emit(asset: String, transforms: Array) -> void:
	var packed: PackedScene = load("%s/%s.glb" % [FLORA_DIR, asset]) as PackedScene
	if packed == null:
		push_error("Undergrowth could not load flora asset %s" % asset)
		return
	var sample := packed.instantiate()
	var parts: Array[MeshInstance3D] = []
	_collect_meshes(sample, parts)
	var holder := Node3D.new()
	holder.name = asset
	add_child(holder)
	for part in parts:
		var local := _global_offset(part, sample)
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = part.mesh
		multimesh.instance_count = transforms.size()
		for index in transforms.size():
			multimesh.set_instance_transform(index, (transforms[index] as Transform3D) * local)
		var instance := MultiMeshInstance3D.new()
		instance.name = part.name
		instance.multimesh = multimesh
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		holder.add_child(instance)
		multimesh_count += 1
	sample.free()


func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_meshes(child, out)


func _global_offset(node: Node3D, root: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != root:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result
