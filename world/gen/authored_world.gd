extends Node3D

## Builds an authored map — terrain, water, props, collision, lights, markers —
## from one layout file at load.
##
## ## Network authority (ARCHITECTURE.md §2.2)
##
## **None, and deliberately so.** The layout is a frozen file shipped in the build,
## so every peer constructs a byte-identical world from it without a byte crossing
## the wire. This node owns no gameplay state: the markers it drops are read by
## host-authoritative systems (spawning, objectives, enemy nests), and those
## systems keep their authority. If a future map needs runtime variation — a
## destroyed bridge, a flooded zone — that is host-authoritative state replicated
## to clients, and it does not live here.
##
## ## Why this map has one consumer where Playtest Hollow has two
##
## The Hollow bakes its visuals in Blender and rebuilds its collision in GDScript
## from the same JSON, which is the right call at 88 m across: what you see is
## authored art. Hollowmere is 356 m across, and a single baked mesh that size
## cannot be culled — the renderer would draw the far valley wall through a hill
## every frame. So this script builds both halves, which has a second benefit the
## Hollow has to work for: the visual and the collision cannot drift apart,
## because they are produced by the same loop over the same array.
##
## Props are grouped into `MultiMeshInstance3D` per chunk per asset, so a hillside
## culls in one test rather than five hundred, and a forest of 300 pines is a
## handful of draw calls.

const PROP_GROUP: StringName = &"authored_world_prop"
## Harvestable props get their own node instead of a MultiMesh slot, and their own
## group, because `autoload/harvest_world.gd` has to hide one tree's visual when it
## is felled — and one instance of a MultiMesh is not a thing you can hide.
const HARVESTABLE_HOLDER_GROUP: StringName = &"authored_world_harvestable"
const MARKER_GROUP: StringName = &"authored_world_marker"
const TERRAIN_GROUP: StringName = &"authored_world_terrain"

@export_file("*.json") var layout_path: String = "res://world/gen/layouts/hollowmere.json"
## Skip prop instancing. Useful when profiling terrain or collision on its own.
@export var build_props: bool = true

var terrain_triangles: int = 0
var prop_count: int = 0
var multimesh_count: int = 0
var collider_count: int = 0
var water_surfaces: int = 0
var harvestable_holders: int = 0
## Static per-chunk cross-asset merges built by F-187, counted separately from `multimesh_count`
## because they are not MultiMeshInstance3D nodes — one merged MeshInstance3D per chunk.
var merged_prop_mesh_count: int = 0
## F-208: how many individual prop placements were baked into a sway-class merge bucket, counted
## separately because a sway holder publishes no `EnvironmentVfx.PLACEMENTS_META` (nothing reads
## per-instance position for pure sway) — this is the only record of how many copies moved out of
## the per-asset `MultiMeshInstance3D` sway path and into a merged mesh instead. Checks that want
## "total swaying prop coverage" need this added to whatever they count from live MultiMesh nodes.
var merged_sway_instance_count: int = 0

var _layout: Dictionary = {}
var _origin := Vector2.ZERO
var _cell: float = 1.0
var _nx: int = 0
var _nz: int = 0
var _heights: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	var started := Time.get_ticks_msec()
	_layout = _read_layout()
	if _layout.is_empty():
		return
	_read_heightfield()
	# Per-phase wall time rides along in the summary line (F-095): the whole build measured
	# 8,899 ms on the M5 Pro, which a weak machine multiplies — whoever attacks it needs to know
	# which phase to attack without re-instrumenting.
	var timings := PackedStringArray()
	_timed(timings, "terrain", _build_terrain)
	_timed(timings, "water", _build_water)
	if build_props:
		_timed(timings, "props", _build_props)
	_timed(timings, "lights", _build_lights)
	_timed(timings, "markers", _build_markers)
	print(
		"AUTHORED_WORLD id=%s terrain_tris=%d props=%d multimeshes=%d merged_meshes=%d colliders=%d water=%d harvestable=%d ms=%d phase_ms=[%s]" % [
			String(_layout.get("id", "?")), terrain_triangles, prop_count, multimesh_count,
			merged_prop_mesh_count, collider_count, water_surfaces, harvestable_holders,
			Time.get_ticks_msec() - started, " ".join(timings)
		]
	)


func _timed(into: PackedStringArray, label: String, phase: Callable) -> void:
	var phase_started := Time.get_ticks_msec()
	phase.call()
	into.append("%s=%d" % [label, Time.get_ticks_msec() - phase_started])


func _read_layout() -> Dictionary:
	var text := FileAccess.get_file_as_string(layout_path)
	if text.is_empty():
		push_error("AuthoredWorld could not read %s" % layout_path)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		push_error("AuthoredWorld layout is not a JSON object: %s" % layout_path)
		return {}
	return parsed as Dictionary


func _read_heightfield() -> void:
	var field: Dictionary = _layout.get("heightfield", {}) as Dictionary
	var origin: Array = field.get("origin", [0.0, 0.0]) as Array
	_origin = Vector2(float(origin[0]), float(origin[1]))
	_cell = float(field.get("cell", 1.0))
	_nx = int(field.get("nx", 0))
	_nz = int(field.get("nz", 0))
	var raw: Array = field.get("heights", []) as Array
	_heights.resize(raw.size())
	for index in raw.size():
		_heights[index] = float(raw[index])
	if _heights.size() != _nx * _nz:
		push_error("AuthoredWorld heightfield is %d values for %dx%d" % [_heights.size(), _nx, _nz])


## The height of the terrain SURFACE — the triangle, not a bilinear guess.
##
## `_build_terrain` meshes each quad as (a, b, c) and (a, c, d), so the ground a
## player stands on is two flat triangles per cell. A bilinear sample of the same
## four corners differs from that surface by up to a quarter of the cell's height
## range, and every one of those centimetres is water clipped at the wrong place or
## a prop hovering. `tools/mapgen/hollowmere_layout.py` samples it the same way, so
## the file and the engine agree on where the ground is by construction.
func height_at(x: float, z: float) -> float:
	var fx := (x - _origin.x) / _cell
	var fz := (z - _origin.y) / _cell
	var ix := clampi(int(floor(fx)), 0, _nx - 2)
	var iz := clampi(int(floor(fz)), 0, _nz - 2)
	var tx := clampf(fx - ix, 0.0, 1.0)
	var tz := clampf(fz - iz, 0.0, 1.0)
	var h00 := _heights[iz * _nx + ix]
	var h10 := _heights[iz * _nx + ix + 1]
	var h01 := _heights[(iz + 1) * _nx + ix]
	var h11 := _heights[(iz + 1) * _nx + ix + 1]
	if tz <= tx:
		return h00 + (h10 - h00) * tx + (h11 - h10) * tz
	return h00 + (h11 - h01) * tx + (h01 - h00) * tz


## F-095 briefly built a conservative terrain-under-shell occluder here for the engine's raster
## occlusion culling. Measured and reverted: Hollowmere is a bowl, so from inside it the ridge
## occludes only the world's outside — ~2 draws culled, while the per-frame occlusion raster
## cost real main-thread time. Re-attempt only for worlds with genuinely blocking sightlines
## (interiors, canyon systems), and re-measure with tools/perf_probe.gd when you do.
## Draw distance and shadow policy, decided from geometry so it survives into generated worlds.
const DrawPolicy := preload("res://world/environment/draw_policy.gd")
## The asset merge itself, shared with `systems/harvesting/harvestable.gd` — a wired tree has to
## collapse to the same geometry the world builder stamps, or it costs fifty-six draws (F-144).
const MeshMerge := preload("res://core/render/mesh_merge.gd")
## Preloaded, not referenced by `class_name`: a new global class is invisible to a headless
## `--script` run until the editor rescans the project.
const AssetVfx := preload("res://world/environment/asset_vfx_library.gd")
## What is worth hitting, keyed by asset rather than by this map's layout flags (F-114).
const HarvestLib := preload("res://systems/harvesting/harvest_library.gd")
## Same preload rule, for `TERRAIN_LAYER`: the ground body below carries it so
## `PlacementValidator`'s overlap query never mistakes the ground a piece is resting on for an
## obstruction (F-075). Every other collider this file emits — props, harvestable colliders — is
## left on the engine default (layer 1), which is the shared "solid" layer that query watches.
const PlacementValidator := preload("res://systems/building/placement_validator.gd")


## Terrain is emitted as one surface per ground material, so the valley floor
## reads as patches of mud, scree, sand and moss rather than as one flat green —
## and it still costs one MeshInstance3D and one collider for the whole map.
func _build_terrain() -> void:
	var field: Dictionary = _layout.get("heightfield", {}) as Dictionary
	var material_names: Array = field.get("material_names", []) as Array
	var indices: Array = field.get("material_index", []) as Array
	var palette: Dictionary = _layout.get("materials", {}) as Dictionary

	var vertices: Array[PackedVector3Array] = []
	var normals: Array[PackedVector3Array] = []
	for _index in material_names.size():
		vertices.append(PackedVector3Array())
		normals.append(PackedVector3Array())

	var collision := PackedVector3Array()
	for iz in _nz - 1:
		for ix in _nx - 1:
			var a := _corner(ix, iz)
			var b := _corner(ix + 1, iz)
			var c := _corner(ix + 1, iz + 1)
			var d := _corner(ix, iz + 1)
			var slot := 0
			if indices.size() == _heights.size():
				slot = clampi(int(indices[iz * _nx + ix]), 0, material_names.size() - 1)
			var target := vertices[slot]
			var target_normals := normals[slot]
			_emit_triangle(target, target_normals, a, b, c)
			_emit_triangle(target, target_normals, a, c, d)
			collision.append_array(PackedVector3Array([a, b, c, a, c, d]))

	var mesh := ArrayMesh.new()
	for slot in material_names.size():
		if vertices[slot].is_empty():
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices[slot]
		arrays[Mesh.ARRAY_NORMAL] = normals[slot]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(
			mesh.get_surface_count() - 1,
			_ground_material(palette.get(String(material_names[slot]), {}) as Dictionary)
		)
		terrain_triangles += vertices[slot].size() / 3

	var instance := MeshInstance3D.new()
	instance.name = "TerrainMesh"
	instance.mesh = mesh
	instance.add_to_group(TERRAIN_GROUP)
	add_child(instance)

	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	body.collision_layer = PlacementValidator.TERRAIN_LAYER
	body.add_to_group(TERRAIN_GROUP)
	add_child(body)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(collision)
	var collider := CollisionShape3D.new()
	collider.name = "TerrainShape"
	collider.shape = shape
	body.add_child(collider)
	collider_count += 1


func _corner(ix: int, iz: int) -> Vector3:
	return Vector3(_origin.x + ix * _cell, _heights[iz * _nx + ix], _origin.y + iz * _cell)


## Flat normals, computed per face. The whole art direction depends on faceted
## shading; a smoothed heightfield would read as a different game.
func _emit_triangle(into: PackedVector3Array, into_normals: PackedVector3Array,
		a: Vector3, b: Vector3, c: Vector3) -> void:
	into.append(a)
	into.append(b)
	into.append(c)
	var normal := (b - a).cross(c - a).normalized()
	if normal.y < 0.0:
		normal = -normal
	into_normals.append(normal)
	into_normals.append(normal)
	into_normals.append(normal)


func _ground_material(spec: Dictionary) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	var color: Array = spec.get("color", [0.3, 0.3, 0.3, 1.0]) as Array
	material.albedo_color = Color(float(color[0]), float(color[1]), float(color[2]),
		float(color[3]) if color.size() > 3 else 1.0)
	material.roughness = float(spec.get("roughness", 0.95))
	material.metallic = float(spec.get("metallic", 0.0))
	return material


## Water: every body unioned into ONE surface per material, clipped to the ground.
##
## The rule is **highest level wins, per grid vertex**. Two bodies whose areas
## overlap therefore produce one sheet, not two — the mere and the fen used to
## overlap across the whole lake at levels 1.8 m apart and were both drawn, so the
## lake had a second transparent sheet hanging in the air above it. A union cannot
## do that even if a future layout overlaps its bodies again.
##
## A quad is emitted when ANY of its corners is under water, with every corner at
## the water level. Requiring all four submerged is the obvious rule and it is what
## made the shoreline a 2 m staircase with a gap between the water and the beach:
## the quads that straddle the shore are exactly the ones that draw the edge. The
## overhang past the true waterline is at most one cell and is under the bank,
## because the bank is above the water — that is what made the corner dry.
func _build_water() -> void:
	var bodies: Array = _layout.get("water", []) as Array
	if bodies.is_empty() or _nx < 2 or _nz < 2:
		return
	var palette: Dictionary = _layout.get("water_materials", {}) as Dictionary
	var count: int = _nx * _nz
	var levels := PackedFloat32Array()
	levels.resize(count)
	var owners := PackedInt32Array()
	owners.resize(count)
	for iz in _nz:
		for ix in _nx:
			var index: int = iz * _nx + ix
			var point := Vector2(_origin.x + ix * _cell, _origin.y + iz * _cell)
			var best: float = 0.0
			var best_body: int = -1
			for body_index in bodies.size():
				var level := _water_level(bodies[body_index] as Dictionary, point)
				if is_nan(level):
					continue
				if best_body < 0 or level > best:
					best = level
					best_body = body_index
			levels[index] = best
			owners[index] = best_body

	var surfaces: Dictionary = {}
	for iz in _nz - 1:
		for ix in _nx - 1:
			var corners: Array[int] = [
				iz * _nx + ix, iz * _nx + ix + 1, (iz + 1) * _nx + ix + 1, (iz + 1) * _nx + ix
			]
			var submerged: int = -1
			var top: float = 0.0
			for slot in 4:
				var index: int = corners[slot]
				if owners[index] < 0 or _heights[index] >= levels[index]:
					continue
				if submerged < 0 or levels[index] > top:
					submerged = slot
					top = levels[index]
			if submerged < 0:
				continue
			var material_name := String((bodies[owners[corners[submerged]]] as Dictionary)
				.get("material", "lake"))
			var points: Array[Vector3] = []
			for slot in 4:
				var index: int = corners[slot]
				# A dry corner takes the quad's own level: this quad exists because
				# its neighbour is under water, and the sheet has to reach it.
				var level: float = top if owners[index] < 0 else maxf(levels[index], top)
				points.append(Vector3(
					_origin.x + (ix + (1 if slot == 1 or slot == 2 else 0)) * _cell,
					level,
					_origin.y + (iz + (1 if slot >= 2 else 0)) * _cell
				))
			var vertices: PackedVector3Array = surfaces.get_or_add(
				material_name, PackedVector3Array()
			)
			for triangle: Array in [[0, 1, 2], [0, 2, 3]]:
				for slot: int in triangle:
					vertices.append(points[slot])
			surfaces[material_name] = vertices

	var root := Node3D.new()
	root.name = "Water"
	add_child(root)
	for material_name: String in surfaces:
		var vertices: PackedVector3Array = surfaces[material_name]
		if vertices.is_empty():
			continue
		var normals := PackedVector3Array()
		normals.resize(vertices.size())
		normals.fill(Vector3.UP)
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material := _ground_material(palette.get(material_name, {}) as Dictionary)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		mesh.surface_set_material(0, material)
		var instance := MeshInstance3D.new()
		instance.name = material_name.capitalize()
		instance.mesh = mesh
		root.add_child(instance)
		water_surfaces += 1


## The surface level of one body at a point, or NAN where that body does not cover it.
func _water_level(body: Dictionary, point: Vector2) -> float:
	match String(body.get("kind", "")):
		"circle":
			var centre: Array = body.get("centre", [0.0, 0.0]) as Array
			if point.distance_to(Vector2(float(centre[0]), float(centre[1]))) > float(body.get("radius", 0.0)):
				return NAN
			return float(body.get("level", 0.0))
		"rect":
			var lo: Array = body.get("min", [0.0, 0.0]) as Array
			var hi: Array = body.get("max", [0.0, 0.0]) as Array
			if point.x < float(lo[0]) or point.x > float(hi[0]) \
					or point.y < float(lo[1]) or point.y > float(hi[1]):
				return NAN
			return float(body.get("level", 0.0))
		"polyline":
			# One body for the whole river. It used to be one "strip" per segment,
			# and consecutive strips overlap at every bend — two quads a few
			# centimetres apart, z-fighting the length of the valley.
			var points: Array = body.get("points", []) as Array
			if points.size() < 2:
				return NAN
			var half := float(body.get("half_width", 1.0))
			var best := INF
			var best_level := 0.0
			for index in points.size() - 1:
				var a: Array = points[index] as Array
				var b: Array = points[index + 1] as Array
				var start := Vector2(float(a[0]), float(a[1]))
				var end := Vector2(float(b[0]), float(b[1]))
				var span := end - start
				var length_sq := span.length_squared()
				var t := 0.0 if length_sq < 0.0001 else clampf((point - start).dot(span) / length_sq, 0.0, 1.0)
				var distance := start.lerp(end, t).distance_to(point)
				if distance < best:
					best = distance
					best_level = lerpf(float(a[2]), float(b[2]), t)
			if best > half:
				return NAN
			return best_level
	return NAN


## One MultiMeshInstance3D per (chunk, asset, mesh part). Chunking is what makes a
## map this size affordable: the renderer discards a whole hillside of trees with
## one frustum test.
func _build_props() -> void:
	var grouped: Dictionary = {}
	# F-187: rigid, non-batch, never-shadow-casting props merge across assets into one static
	# mesh per chunk instead of one MultiMesh per (chunk, asset) — see the eligibility comment
	# below for why sway-bearing and shadow-tall props are still excluded. F-203 widened this to
	# emitter-bearing props too: they merge into `emitter_mergeable`, a second bucket keyed by
	# (chunk, emitter class) rather than folded into the asset-agnostic `mergeable` set — see the
	# comment at the classification site below for why the class has to be the merge key.
	var mergeable: Dictionary = {}
	var emitter_mergeable: Dictionary = {}
	# F-208: a third bucket, keyed by (chunk, sway type) the same way `emitter_mergeable` is keyed
	# by (chunk, emitter class) — see the classification comment at the bucketing site below for
	# why the type has to be the merge key.
	var sway_mergeable: Dictionary = {}
	var harvestable: Array[Dictionary] = []
	# Filled here rather than after classification: deciding whether a prop is short enough to
	# merge needs its mesh's own AABB, and `_mesh_parts` memoizes per (kit, asset) regardless of
	# when it is first called, so calling it during classification costs nothing extra later.
	var cache: Dictionary = {}
	for prop_value: Variant in _layout.get("props", []):
		var prop := prop_value as Dictionary
		# Harvestability is a property of the ASSET, not of this placement (F-114). The layout's own
		# `harvestable` flag is still honoured so an older layout keeps working, but nothing new
		# needs it — a generated world gets a choppable pine by stamping `tree_pine_c`, exactly the
		# way it gets the pine's canopy sway.
		var asset_id := StringName(String(prop.get("asset", "")))
		if bool(prop.get("harvestable", false)) or HarvestLib.is_harvestable(asset_id):
			# BATCH props stay in the MultiMesh below and pick up a logic-only holder once their
			# instance index is known; only NODE props are promoted to a mesh of their own.
			if HarvestLib.representation_for(asset_id) == HarvestLib.Represent.NODE:
				harvestable.append(prop)
				continue
		var chunk: Array = prop.get("chunk", [0, 0]) as Array
		var kit_name := String(prop.get("kit", ""))
		var asset_name := String(prop.get("asset", ""))
		# Anything reaching this line that IS harvestable is BATCH representation (NODE already
		# `continue`d above) — depletion hides ONE instance by zeroing its transform inside that
		# asset's own MultiMesh (`_build_batch_harvestables`), which only works if the batch is
		# still keyed one-asset-per-node.
		var mesh_key := "%s|%s" % [kit_name, asset_name]
		if not cache.has(mesh_key):
			cache[mesh_key] = _mesh_parts(kit_name, asset_name)
		var object_meshes: Array = cache[mesh_key] as Array
		var object_height := 0.0
		if not object_meshes.is_empty():
			var object_mesh: Mesh = (object_meshes[0] as Dictionary)["mesh"]
			object_height = object_mesh.get_aabb().size.y * float(prop.get("scale", 1.0))
		var sway := AssetVfx.sway_for(asset_name)
		var emitter := AssetVfx.emitter_for(asset_name)
		# A merged chunk mesh tall or wide enough to cast a shadow routinely spans more than one
		# of the four PSSM cascade splits — measured directly, this is what cost the first version
		# of this merge its whole win: draw calls fell as expected, but shadow-pass primitives
		# ROSE 16% (`frame_cost_check.gd` against `agent baseline`), because Godot re-renders a
		# caster into every cascade its AABB touches and a whole chunk's worth of merged geometry
		# touches more of them than one small prop ever did. Excluded from every merge bucket
		# below, solved by construction — merge only what will never cast a shadow.
		if HarvestLib.is_harvestable(asset_id) or object_height >= DrawPolicy.SHADOW_MIN_HEIGHT:
			var key := "%d_%d|%s|%s" % [int(chunk[0]), int(chunk[1]), kit_name, asset_name]
			grouped.get_or_add(key, [] as Array).append(prop)
		elif sway != AssetVfx.Sway.NONE:
			if emitter != AssetVfx.Emitter.NONE:
				# F-208 scope: an asset carrying BOTH sway and an emitter (mire_tendril: TENDRIL +
				# SPORE is the one on Hollowmere) stays on the original per-asset MultiMesh path
				# rather than joining either new bucket — merging it into the sway bucket would
				# need EMITTER_META and a baked height mask on the same holder at once, and into
				# the emitter bucket would silently drop its sway. Neither is attempted here; not
				# a regression, since F-187 excluded every sway-bearing asset from any merge
				# bucket in the first place.
				var key := "%d_%d|%s|%s" % [int(chunk[0]), int(chunk[1]), kit_name, asset_name]
				grouped.get_or_add(key, [] as Array).append(prop)
			else:
				# F-208: `_apply_sway`'s wind shader reads `VERTEX.y` in MODEL space against that
				# ONE asset's own AABB (`wind_root_y`/`wind_inv_height`, set from `mesh.get_aabb()`
				# in `EnvironmentVfx._apply_sway`) — correct for a single asset's own local frame,
				# wrong the instant several placements' chunk-relative heights are baked into one
				# static mesh, because the mask would then read terrain elevation within the chunk
				# instead of height within each individual plant. Splitting the merge by (chunk,
				# sway type) — the same shape F-203 used for emitters — sidesteps this a
				# different way: `MeshMerge.merge_instances(..., bake_height_mask=true)` bakes a
				# correct per-vertex mask into UV2.x from each source asset's OWN local AABB
				# before the merge, and every instance feeding one merged mesh this way already
				# agrees on which `AssetVfxLibrary.Sway` profile to dress it with, so — like the
				# emitter class — the holder can declare that profile directly
				# (`EnvironmentVfx.SWAY_META`) instead of needing one surviving per-mesh AABB.
				var skey := "%d_%d|s%d" % [int(chunk[0]), int(chunk[1]), int(sway)]
				sway_mergeable.get_or_add(skey, [] as Array).append(prop)
		elif emitter != AssetVfx.Emitter.NONE and emitter != AssetVfx.Emitter.GLOW:
			# F-203: `EnvironmentVfx._register_emitter` keys the `PLACEMENTS_META` contract off
			# ONE asset id per holder and infers ONE emitter class from it — a node merging
			# several different emitter-bearing assets would misattribute their sites to the
			# wrong class, or drop them. Splitting the merge itself by (chunk, emitter class)
			# instead of by nothing sidesteps that: every instance feeding one merged mesh
			# already agrees on which class to register as, so the holder can declare that class
			# directly (`EnvironmentVfx.EMITTER_META`) instead of relying on asset identity
			# surviving the bake — no per-asset sub-range bookkeeping needed, because nothing
			# downstream of the merge ever needs to know which of the group's several assets a
			# given baked vertex came from, only which class the whole holder belongs to.
			#
			# GLOW is deliberately excluded from this branch — it falls through to the plain
			# `mergeable` set below instead, because `AssetVfxLibrary.Emitter.GLOW` is "emissive
			# material only — no light, no particles, no per-instance node": nothing at runtime
			# ever reads a class or a position for it, so it needs none of this bookkeeping and
			# merges exactly like any other inert rigid prop.
			var ekey := "%d_%d|e%d" % [int(chunk[0]), int(chunk[1]), int(emitter)]
			emitter_mergeable.get_or_add(ekey, [] as Array).append(prop)
		else:
			var mkey := "%d_%d" % [int(chunk[0]), int(chunk[1])]
			mergeable.get_or_add(mkey, [] as Array).append(prop)

	var visuals := Node3D.new()
	visuals.name = "PropVisuals"
	add_child(visuals)
	var bodies := Node3D.new()
	bodies.name = "PropCollision"
	add_child(bodies)

	var harvest_root := Node3D.new()
	harvest_root.name = "Harvestables"
	add_child(harvest_root)
	_build_harvestables(harvestable, cache, harvest_root)
	for key: String in grouped:
		var props: Array = grouped[key] as Array
		var parts := key.split("|")
		var kit := parts[1]
		var asset := parts[2]
		# get_or_add evaluates its default argument EAGERLY, so written that way _mesh_parts ran
		# once per (chunk, asset) GROUP — 1,028 merges instead of ~40, which was 96% of the whole
		# world build (F-095: phase_ms props=9,055 of 9,145).
		var mesh_key := key.substr(key.find("|") + 1)
		if not cache.has(mesh_key):
			cache[mesh_key] = _mesh_parts(kit, asset)
		var meshes: Array = cache[mesh_key] as Array
		if meshes.is_empty():
			continue
		var transforms: Array[Transform3D] = []
		var centroid := Vector3.ZERO
		var max_scale: float = 0.0
		for prop_value: Variant in props:
			var prop := prop_value as Dictionary
			var pos: Array = prop.get("pos", [0.0, 0.0, 0.0]) as Array
			var prop_scale := float(prop.get("scale", 1.0))
			var placement := Transform3D(
				Basis(Vector3.UP, float(prop.get("yaw", 0.0))),
				Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
			).scaled_local(Vector3.ONE * prop_scale)
			transforms.append(placement)
			centroid += placement.origin
			max_scale = maxf(max_scale, prop_scale)
			_add_prop_collision(bodies, prop, placement)
			prop_count += 1
		centroid /= float(transforms.size())
		# Rebase every copy onto the group's centre before it goes into the MultiMesh, and stand
		# the holder there. `visibility_range` measures the camera's distance to the node's
		# ORIGIN, and a holder left at the world origin makes that distance meaningless — the
		# whole batch would cull together on the far side of the map, or never cull at all
		# (F-144). `world/gen/undergrowth.gd` rebases onto cell centres for exactly this reason.
		# These groups are already per-chunk, so the centroid is a tight stand-in for the batch.
		var local_transforms: Array[Transform3D] = []
		for placement: Transform3D in transforms:
			local_transforms.append(Transform3D(placement.basis, placement.origin - centroid))
		var holder := Node3D.new()
		holder.position = centroid
		holder.name = key.replace("|", "_")
		# The asset id travels with the geometry so presentation can bind to it without knowing
		# anything about this map (F-097). Same `asset` meta the harvestable holders already
		# carry, so there is one contract rather than two: EnvironmentVfx reads exactly this and
		# nothing else about the scene, and the world generator that replaces this file inherits
		# every effect by stamping it too.
		holder.set_meta(&"asset", asset)
		# Where each copy stands, in the HOLDER's space. Only assets whose presentation is
		# per-copy get this, so the other 2,800-odd props cost nothing. It exists because
		# instance transforms inside a MultiMesh are unreadable outside the GPU — see
		# EnvironmentVfx.PLACEMENTS_META.
		#
		# Local, not world: `EnvironmentVfx._register_emitter` multiplies each entry by the
		# node's `global_transform`. That was always the contract, but until F-144 stood this
		# holder at its group's centroid the holder sat at the origin, so world positions
		# happened to satisfy it. They no longer do — publishing world positions here would put
		# every firefly and every ember one full centroid away from the prop it belongs to.
		if AssetVfx.emitter_for(asset) != AssetVfx.Emitter.NONE:
			var origins := PackedVector3Array()
			for placement: Transform3D in local_transforms:
				origins.append(placement.origin)
			holder.set_meta(&"placements", origins)
		visuals.add_child(holder)
		for entry_value: Variant in meshes:
			var entry := entry_value as Dictionary
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.mesh = entry["mesh"]
			multimesh.instance_count = local_transforms.size()
			for index in local_transforms.size():
				multimesh.set_instance_transform(
					index, local_transforms[index] * (entry["offset"] as Transform3D))
			var instance := MultiMeshInstance3D.new()
			instance.name = String(entry["name"])
			instance.multimesh = multimesh
			instance.set_meta(&"asset", asset)
			DrawPolicy.apply(instance, (entry["mesh"] as Mesh).get_aabb(), max_scale)
			holder.add_child(instance)
			multimesh_count += 1
		# World transforms place the logic holders; local ones are what actually sit in the
		# MultiMesh, and are therefore what a restore has to write back.
		_build_batch_harvestables(
			props, asset, holder, harvest_root, transforms, local_transforms, meshes)


	# F-203/F-208: folded into one dictionary and one loop so all three buckets share every line
	# of the actual merge/bake/DrawPolicy logic — a trailing "|e<N>" or "|s<N>" on the key is the
	# only thing that distinguishes an emitter- or sway-class bucket from a plain one below.
	for ekey: String in emitter_mergeable:
		mergeable[ekey] = emitter_mergeable[ekey]
	for skey: String in sway_mergeable:
		mergeable[skey] = sway_mergeable[skey]

	for key: String in mergeable:
		var props: Array = mergeable[key] as Array
		# Keys look like "<chunk>" for the plain rigid bucket, "<chunk>|e<N>" for an emitter-class
		# bucket, or "<chunk>|s<N>" for a sway-class bucket (see the classification comment above)
		# — parsed back out here rather than carried alongside the dictionaries, so all three
		# buckets can share one loop. Mutually exclusive: F-208 keeps a sway+emitter combo asset
		# out of every merge bucket, so one key never carries both tags.
		var emitter := AssetVfx.Emitter.NONE
		var sway := AssetVfx.Sway.NONE
		var pipe := key.find("|")
		if pipe != -1:
			var tag_value := int(key.substr(pipe + 2))
			if key.substr(pipe + 1, 1) == "e":
				emitter = tag_value as AssetVfx.Emitter
			else:
				sway = tag_value as AssetVfx.Sway
		var entries: Array = []
		# Raw placement origins, parallel to `entries` — only the emitter-class bucket needs
		# these (as local, holder-relative positions once the centroid is known), but collecting
		# them costs nothing for the plain bucket, which simply never reads them.
		var origins: Array[Vector3] = []
		var centroid := Vector3.ZERO
		# The tallest single OBJECT going into this merge, not the merged mesh's own AABB — the
		# merged mesh's vertices are baked at their absolute world height relative to the holder,
		# so its AABB spans the chunk's terrain relief as well as every object's own height, and
		# terrain relief alone is routinely several metres on Hollowmere. Feeding that span to
		# `DrawPolicy` would classify nearly every merge as TALL and draw it to 260 m regardless of
		# what is actually in it — measured: this exact bug cost the merge its whole win, taking
		# `frame_cost_check.gd`'s primitive count UP 18% instead of down (F-187's baseline compare).
		var max_object_height: float = 0.0
		for prop_value: Variant in props:
			var prop := prop_value as Dictionary
			var kit := String(prop.get("kit", ""))
			var asset := String(prop.get("asset", ""))
			# Same cache the grouped path above fills -- keyed identically (kit|asset), so an asset
			# placed both as scenery and, elsewhere, densely enough to earn its own MultiMesh group
			# still costs one `_mesh_parts` call.
			var mesh_key := "%s|%s" % [kit, asset]
			if not cache.has(mesh_key):
				cache[mesh_key] = _mesh_parts(kit, asset)
			var meshes: Array = cache[mesh_key] as Array
			if meshes.is_empty():
				continue
			var pos: Array = prop.get("pos", [0.0, 0.0, 0.0]) as Array
			var prop_scale := float(prop.get("scale", 1.0))
			var placement := Transform3D(
				Basis(Vector3.UP, float(prop.get("yaw", 0.0))),
				Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
			).scaled_local(Vector3.ONE * prop_scale)
			var mesh_entry: Dictionary = meshes[0] as Dictionary
			var object_mesh: Mesh = mesh_entry["mesh"]
			entries.append({"mesh": object_mesh,
				"transform": placement * (mesh_entry["offset"] as Transform3D)})
			origins.append(placement.origin)
			centroid += placement.origin
			max_object_height = maxf(max_object_height, object_mesh.get_aabb().size.y * prop_scale)
			_add_prop_collision(bodies, prop, placement)
			prop_count += 1
		if entries.is_empty():
			continue
		centroid /= float(entries.size())
		var local_entries: Array = []
		for entry_value: Variant in entries:
			var entry := entry_value as Dictionary
			var transform: Transform3D = entry["transform"]
			local_entries.append({"mesh": entry["mesh"],
				"transform": Transform3D(transform.basis, transform.origin - centroid)})
		var combined := MeshMerge.merge_instances(local_entries, sway != AssetVfx.Sway.NONE)
		if combined == null:
			continue
		var holder := Node3D.new()
		# Same centroid-rebasing reasoning as the grouped path above: `visibility_range` measures
		# from the node's own origin, and an ArrayMesh's AABB is exact once its vertices are baked
		# relative to that origin rather than the world's.
		holder.position = centroid
		holder.name = ("merged_%s" % key).replace("|", "_")
		visuals.add_child(holder)
		var instance := MeshInstance3D.new()
		instance.name = "MergedProps"
		instance.mesh = combined
		# No `asset` meta either way: this node deliberately spans many assets, so there is no one
		# id to publish. The plain bucket also gets no `EnvironmentVfx.EMITTER_META`/`SWAY_META` —
		# it is exactly the props AssetVfxLibrary has nothing to say about, so `EnvironmentVfx`'s
		# meta-then-name walk correctly finds nothing and skips it. An emitter-class bucket DOES
		# get `EMITTER_META` (F-203) plus the same `placements` meta a per-asset holder publishes,
		# rebased onto this holder's own centroid exactly like `local_transforms` is above. A
		# sway-class bucket (F-208) gets `SWAY_META` instead — no `placements`, since nothing
		# downstream reads a per-instance position for pure sway, only the profile to dress with.
		if emitter != AssetVfx.Emitter.NONE:
			var placements := PackedVector3Array()
			for origin: Vector3 in origins:
				placements.append(origin - centroid)
			holder.set_meta(&"placements", placements)
			holder.set_meta(&"vfx_emitter", int(emitter))
		elif sway != AssetVfx.Sway.NONE:
			holder.set_meta(&"vfx_sway", int(sway))
			merged_sway_instance_count += entries.size()
		DrawPolicy.apply(instance, AABB(Vector3.ZERO, Vector3(0.0, max_object_height, 0.0)), 1.0)
		holder.add_child(instance)
		merged_prop_mesh_count += 1


## Collapse an asset to ONE mesh with one surface per material.
##
## This is not an optimisation, it is the difference between the map running and
## not. The environment kit's assets are built from dozens of separate Blender
## objects — a pine is around forty — and each one arrives as its own
## MeshInstance3D. Instanced per chunk that produced **4,749 MultiMeshInstance3D
## nodes for 1,408 props**: more draw calls than props, which is the exact
## opposite of what instancing is for. Merging first takes it to one node per
## (chunk, asset) and a handful of surfaces each.
##
## The flora kit already joins at export time, which is the better place to do it;
## doing it here as well means the older kits get the same benefit without a
## rebuild that would collide with another agent's claim.
func _mesh_parts(kit: String, asset: String) -> Array:
	var mesh := MeshMerge.merged("res://assets/%s/exports/%s.glb" % [kit, asset])
	if mesh == null:
		return []
	return [{"mesh": mesh, "offset": Transform3D.IDENTITY, "name": asset}]


## One node per harvestable prop: a holder in `HARVESTABLE_HOLDER_GROUP` carrying
## the asset name, with a `Visual` and a `CollisionBody` under it. That shape is
## exactly what `HarvestWorld._wire_holder` needs to swap the tree for a live
## Harvestable, and it is why a hollowmere tree can now actually be chopped down —
## before this the map's trees and ore were inert scenery, because HarvestWorld
## only ever looked for `playtest_hollow_asset` holders that this map never built.
func _build_harvestables(props: Array[Dictionary], cache: Dictionary, root: Node3D) -> void:
	if props.is_empty():
		return
	for index in props.size():
		var prop: Dictionary = props[index]
		var kit := String(prop.get("kit", ""))
		var asset := String(prop.get("asset", ""))
		# Same eager-default trap as _build_props: never pass _mesh_parts() into get_or_add.
		var mesh_key := "%s|%s" % [kit, asset]
		if not cache.has(mesh_key):
			cache[mesh_key] = _mesh_parts(kit, asset)
		var meshes: Array = cache[mesh_key] as Array
		if meshes.is_empty():
			continue
		var pos: Array = prop.get("pos", [0.0, 0.0, 0.0]) as Array
		var placement := Transform3D(
			Basis(Vector3.UP, float(prop.get("yaw", 0.0))),
			Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		).scaled_local(Vector3.ONE * float(prop.get("scale", 1.0)))

		var holder := Node3D.new()
		holder.name = "Harvest_%03d" % index
		holder.transform = placement
		holder.set_meta(&"asset", asset)
		holder.set_meta(&"kit", kit)
		holder.add_to_group(HARVESTABLE_HOLDER_GROUP)
		root.add_child(holder)

		var entry: Dictionary = meshes[0] as Dictionary
		var visual := MeshInstance3D.new()
		visual.name = "Visual"
		visual.mesh = entry["mesh"]
		visual.transform = entry["offset"] as Transform3D
		# The map's single largest draw bucket: 3,008 individually placed harvestables were
		# 3,662 opaque draws and 14,648 more in the four shadow cascades, half of every draw
		# call the frame submitted, none of them bounded by distance (F-144).
		DrawPolicy.apply(visual, (entry["mesh"] as Mesh).get_aabb(),
			float(prop.get("scale", 1.0)))
		holder.add_child(visual)

		var body := StaticBody3D.new()
		body.name = "CollisionBody"
		body.set_meta(&"asset", asset)
		body.set_meta(&"kit", kit)
		body.add_to_group(PROP_GROUP)
		holder.add_child(body)
		_add_shapes(body, prop.get("cols", []) as Array)
		prop_count += 1
		harvestable_holders += 1


## A logic-only holder for each harvestable that STAYS in the chunk's MultiMesh batch (F-114).
##
## The 794 bushes and saplings on this map are the reason this exists. Promoting each to its own
## `MeshInstance3D`, the way a tree or an ore node is promoted, would have turned a handful of
## batched draw calls into eight hundred — on a game whose target is the worst computer someone
## might play it on. So the geometry stays exactly where it was and the holder carries only the
## harvest logic, plus the coordinates of its own slot inside the batch: `autoload/harvest_world.gd`
## turns those into the hook `Harvestable` calls to hide one bush, which it does by zeroing that
## single instance's transform — the only way to hide one copy of a MultiMesh.
##
## No collider is synthesised, and that is deliberate: soft flora is walked through, and
## `CombatService` picks its target out of the `&"damageable"` group by distance and arc rather
## than by raycast, so a bush with no collision is still perfectly swingable.
func _build_batch_harvestables(
	props: Array, asset: String, batch_holder: Node3D, root: Node3D,
	transforms: Array[Transform3D], local_transforms: Array[Transform3D], meshes: Array
) -> void:
	var asset_id := StringName(asset)
	if not HarvestLib.is_harvestable(asset_id):
		return
	if HarvestLib.representation_for(asset_id) != HarvestLib.Represent.BATCH:
		return
	var slots: Array[MultiMesh] = []
	var offsets: Array[Transform3D] = []
	for child: Node in batch_holder.get_children():
		var instance := child as MultiMeshInstance3D
		if instance == null or instance.multimesh == null:
			continue
		slots.append(instance.multimesh)
		var part: int = offsets.size()
		var entry: Dictionary = (meshes[part] if part < meshes.size() else {}) as Dictionary
		offsets.append(entry.get("offset", Transform3D.IDENTITY) as Transform3D)
	if slots.is_empty():
		return

	for index in props.size():
		if index >= transforms.size():
			break
		var prop := props[index] as Dictionary
		var holder := Node3D.new()
		holder.name = "HarvestBatch_%s_%03d" % [asset, index]
		holder.transform = transforms[index]
		holder.set_meta(&"asset", asset)
		holder.set_meta(&"kit", String(prop.get("kit", "")))
		holder.set_meta(&"batch_meshes", slots)
		holder.set_meta(&"batch_index", index)
		# The exact transform each mesh part of this prop was written into the batch with, recorded
		# by the only code that knows it for certain. Reading it back with
		# `MultiMesh.get_instance_transform()` would be a RenderingServer round trip per prop at wire
		# time — 794 of them here — and returns identity under the dummy renderer every headless
		# check runs on, so a restore would quietly teleport every bush to the world origin.
		# In the MULTIMESH's space, not the world's — F-144 rebased each batch onto its holder,
		# and `HarvestWorld._batch_visual_hook` feeds these straight back into
		# `set_instance_transform`. World transforms here would restore a chopped bush at the
		# holder's offset from the origin, which is to say somewhere else entirely.
		var placements: Array[Transform3D] = []
		for part: int in slots.size():
			placements.append(local_transforms[index] * offsets[part])
		holder.set_meta(&"batch_transforms", placements)
		holder.add_to_group(HARVESTABLE_HOLDER_GROUP)
		root.add_child(holder)
		harvestable_holders += 1


func _add_prop_collision(parent: Node3D, prop: Dictionary, placement: Transform3D) -> void:
	var shapes: Array = prop.get("cols", []) as Array
	if shapes.is_empty():
		return
	var body := StaticBody3D.new()
	body.name = "%s_%03d" % [String(prop.get("asset", "Prop")), collider_count]
	body.transform = placement
	body.set_meta(&"asset", String(prop.get("asset", "")))
	body.set_meta(&"kit", String(prop.get("kit", "")))
	body.add_to_group(PROP_GROUP)
	parent.add_child(body)
	_add_shapes(body, shapes)


func _add_shapes(body: StaticBody3D, shapes: Array) -> void:
	for shape_value: Variant in shapes:
		var data := shape_value as Dictionary
		var collider := CollisionShape3D.new()
		if String(data.get("t", "")) == "box":
			var size: Array = data.get("size", [1.0, 1.0, 1.0]) as Array
			var box := BoxShape3D.new()
			box.size = Vector3(float(size[0]), float(size[1]), float(size[2]))
			collider.shape = box
			var off: Array = data.get("off", [0.0, 0.0, 0.0]) as Array
			collider.position = Vector3(float(off[0]), float(off[1]), float(off[2]))
		else:
			var cylinder := CylinderShape3D.new()
			cylinder.radius = float(data.get("r", 0.5))
			cylinder.height = float(data.get("h", 1.0))
			collider.shape = cylinder
			collider.position.y = float(data.get("y", cylinder.height * 0.5))
		collider.name = "Shape_%03d" % collider_count
		body.add_child(collider)
		collider_count += 1


func _build_lights() -> void:
	var root := Node3D.new()
	root.name = "LayoutLights"
	add_child(root)
	for light_value: Variant in _layout.get("lights", []):
		var data := light_value as Dictionary
		var light := OmniLight3D.new()
		light.name = String(data.get("name", "Light"))
		var pos: Array = data.get("pos", [0.0, 0.0, 0.0]) as Array
		light.position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		var color: Array = data.get("color", [1.0, 1.0, 1.0]) as Array
		light.light_color = Color(float(color[0]), float(color[1]), float(color[2]))
		light.light_energy = float(data.get("energy", 1.0))
		light.omni_range = float(data.get("range", 8.0))
		light.shadow_enabled = false
		root.add_child(light)


func _build_markers() -> void:
	var root := Node3D.new()
	root.name = "GameplayMarkers"
	add_child(root)
	for marker_value: Variant in _layout.get("markers", []):
		var data := marker_value as Dictionary
		var marker := Marker3D.new()
		marker.name = String(data.get("name", "Marker"))
		var pos: Array = data.get("pos", [0.0, 0.0, 0.0]) as Array
		marker.position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		marker.set_meta(&"kind", String(data.get("kind", "")))
		marker.set_meta(&"zone", String(data.get("zone", "")))
		marker.add_to_group(MARKER_GROUP)
		root.add_child(marker)
