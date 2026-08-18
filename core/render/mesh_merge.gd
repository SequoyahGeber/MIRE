extends RefCounted

## Collapse a kit asset to ONE mesh with one surface per material, indexed, with a LOD ladder.
##
## The environment and harvestable kits are built from dozens of separate Blender objects — a
## pine is fifty-six — and each arrives from the .glb as its own MeshInstance3D. Drawn as
## authored, one tree is fifty-six draw calls. This was written inside `world/gen/authored_world.gd`
## because the authored map could not run without it; F-144 lifted it here on finding that the map
## paid the un-merged price anyway, everywhere the world builder was not the thing doing the
## instantiating. Forty-four wired trees were 2,464 of the map's 8,354 opaque draws — twenty-nine
## percent of the frame, from one asset, because `Harvestable` instantiates its state scenes
## straight from the .glb.
##
## Anything that stamps kit geometry into the world should come through here, including the
## procedural generator that replaces the authored map: the merge is a property of the ASSET, not
## of any scene or level, which is why it caches per source file and not per placement.

## Bump when the merge changes what it produces — the disk cache key carries it, so a stale entry
## from an older shape can never be read back.
const CACHE_VERSION: int = 5
const CACHE_DIR: String = "user://mesh_cache"
## The engine's own .glb import defaults, so a runtime merge simplifies the way the import
## pipeline would have.
const LOD_NORMAL_MERGE_ANGLE: float = 60.0
const LOD_NORMAL_SPLIT_ANGLE: float = 25.0

## Merged meshes for this process, keyed by source path. The disk cache below survives restarts;
## this one keeps a second visit from touching the filesystem at all.
static var _memo: Dictionary = {}


## The merged mesh for a .glb, built once per source file and reused by every placement.
## Returns null if the path does not load.
static func merged(path: String) -> ArrayMesh:
	if _memo.has(path):
		return _memo[path] as ArrayMesh
	var built := _build(path)
	_memo[path] = built
	return built


## Replace the mesh parts of an instantiated kit scene with one merged MeshInstance3D.
##
## Structure-preserving on purpose: a part that has children keeps its node and loses only its
## mesh, so anything the .glb hangs off a mesh node — an attachment point, a collider — survives.
## Returns the merged instance, or null if there was nothing to merge.
static func collapse(instantiated: Node3D, source_path: String) -> MeshInstance3D:
	var mesh := merged(source_path)
	if mesh == null:
		return null
	var parts: Array[MeshInstance3D] = []
	_collect(instantiated, parts)
	if parts.is_empty():
		return null
	for part: MeshInstance3D in parts:
		if part.get_child_count() > 0:
			part.mesh = null
		else:
			part.get_parent().remove_child(part)
			part.queue_free()
	var visual := MeshInstance3D.new()
	visual.name = &"MergedVisual"
	visual.mesh = mesh
	instantiated.add_child(visual)
	return visual


## Build the merged mesh, reading the disk cache first.
static func _build(path: String) -> ArrayMesh:
	# Keyed by the source's modified time, so editing a kit asset orphans the old entry rather
	# than serving it. A torn or unreadable cache file loads as null and falls through to a
	# rebuild that overwrites it. A player's FIRST load still pays full price — the durable fix
	# is baking merged meshes at export time, which belongs to the art pipeline (F-095).
	var cache_path := "%s/%s_%d_v%d.res" % [
		CACHE_DIR, path.get_file().get_basename(),
		FileAccess.get_modified_time(path), CACHE_VERSION]
	if ResourceLoader.exists(cache_path):
		var cached := load(cache_path) as ArrayMesh
		if cached != null:
			return cached
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		push_error("MeshMerge could not load %s" % path)
		return null
	var sample := packed.instantiate()
	var found: Array[MeshInstance3D] = []
	_collect(sample, found)

	var buckets: Dictionary = {}
	var order: Array[String] = []
	for part: MeshInstance3D in found:
		var offset := _offset_to(part, sample)
		var basis := offset.basis
		var mesh: Mesh = part.mesh
		for surface in mesh.get_surface_count():
			var material := mesh.surface_get_material(surface)
			# Bucketed by what the material LOOKS LIKE, not by what it is called. The kit is
			# flat-shaded palette art — 218 prop assets carry 201 differently-named materials and
			# not one albedo texture between them, but only 85 distinct appearances. Keying on
			# `resource_name` split surfaces that render identically, so a prop averaged 3.99
			# surfaces where its own palette justifies far fewer, and every one of those splits
			# is a draw call per placement (F-144).
			var key := _fingerprint(material, surface)
			var arrays: Array = mesh.surface_get_arrays(surface)
			# Two surfaces can only share one merged surface if they carry the SAME vertex
			# attributes — a surface with UVs and one without cannot be concatenated, because the
			# result would need a UV for every vertex or none. So the attribute set is part of
			# the key, not just the material's appearance.
			var attributes := _attribute_mask(arrays)
			key = "%s#%d" % [key, attributes]
			if not buckets.has(key):
				# One Material instance per appearance, shared across every asset that wears it,
				# so the renderer sees one state rather than a fresh one per name.
				buckets[key] = {"material": _shared_material(key, material),
					"v": PackedVector3Array(),
					"n": PackedVector3Array(), "i": PackedInt32Array(),
					"attributes": attributes,
					"uv": PackedVector2Array(), "uv2": PackedVector2Array(),
					"color": PackedColorArray(), "tangent": PackedFloat32Array()}
				order.append(key)
			var source_v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var source_n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var bucket: Dictionary = buckets[key]
			var out_v: PackedVector3Array = bucket["v"]
			var out_n: PackedVector3Array = bucket["n"]
			var out_i: PackedInt32Array = bucket["i"]
			# Anything the artist put on the vertices travels with them. The prop kit is untextured
			# so this moves nothing there, but the merge is shared with the flora kit and with
			# whatever a generated world stamps later, and a merge that silently drops UVs is a
			# trap that only shows up as a mis-shaded asset months afterwards.
			# Read, append, write back — every Packed*Array is a value type, so appending to what
			# the Dictionary hands back mutates a copy and stores nothing. Getting this wrong
			# leaves the attribute arrays shorter than the vertex array, which surfaces as
			# "array.size() != p_vertex_array_len" from add_surface and no mesh at all.
			if attributes & ATTR_UV:
				var out_uv: PackedVector2Array = bucket["uv"]
				out_uv.append_array(arrays[Mesh.ARRAY_TEX_UV])
				bucket["uv"] = out_uv
			if attributes & ATTR_UV2:
				var out_uv2: PackedVector2Array = bucket["uv2"]
				out_uv2.append_array(arrays[Mesh.ARRAY_TEX_UV2])
				bucket["uv2"] = out_uv2
			if attributes & ATTR_COLOR:
				var out_color: PackedColorArray = bucket["color"]
				out_color.append_array(arrays[Mesh.ARRAY_COLOR])
				bucket["color"] = out_color
			if attributes & ATTR_TANGENT:
				# Four floats per vertex: xyz is a direction and rotates with the part, w is a
				# handedness sign and must not.
				var source_t: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
				var out_t: PackedFloat32Array = bucket["tangent"]
				for t in range(0, source_t.size(), 4):
					var rotated := (basis * Vector3(
						source_t[t], source_t[t + 1], source_t[t + 2])).normalized()
					out_t.append(rotated.x)
					out_t.append(rotated.y)
					out_t.append(rotated.z)
					out_t.append(source_t[t + 3])
				bucket["tangent"] = out_t
			# Append the vertices ONCE and rebase this surface's own indices onto them. Walking
			# the index list and pushing a fresh vertex per entry — which is what this did until
			# F-144 — throws away every bit of vertex reuse the artist's mesh had, and leaves the
			# result unindexed. `ImporterMesh.generate_lods` produces nothing at all from an
			# unindexed surface, so the merge that made the map shippable was also what denied
			# every merged prop any LOD.
			var base: int = out_v.size()
			for index in source_v.size():
				out_v.append(offset * source_v[index])
				out_n.append((basis * source_n[index]).normalized() \
					if index < source_n.size() else Vector3.UP)
			if indices.is_empty():
				for index in source_v.size():
					out_i.append(base + index)
			else:
				for index in indices:
					out_i.append(base + index)
			bucket["v"] = out_v
			bucket["n"] = out_n
			bucket["i"] = out_i
	sample.free()

	# Built through ImporterMesh rather than ArrayMesh directly for one reason: it is the only
	# class exposing `generate_lods`, the same meshoptimizer simplifier the .glb importer runs.
	# An imported mesh gets its LOD ladder for free; a mesh assembled at runtime gets one only if
	# someone asks, and until F-144 nobody did.
	var importer := ImporterMesh.new()
	for key: String in order:
		var bucket: Dictionary = buckets[key]
		var vertices: PackedVector3Array = bucket["v"]
		if vertices.is_empty():
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = bucket["n"]
		arrays[Mesh.ARRAY_INDEX] = bucket["i"]
		var attributes: int = bucket["attributes"]
		if attributes & ATTR_UV:
			arrays[Mesh.ARRAY_TEX_UV] = bucket["uv"]
		if attributes & ATTR_UV2:
			arrays[Mesh.ARRAY_TEX_UV2] = bucket["uv2"]
		if attributes & ATTR_COLOR:
			arrays[Mesh.ARRAY_COLOR] = bucket["color"]
		if attributes & ATTR_TANGENT:
			arrays[Mesh.ARRAY_TANGENT] = bucket["tangent"]
		importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
			bucket["material"] as Material, key, 0)
	if importer.get_surface_count() == 0:
		return null
	importer.generate_lods(LOD_NORMAL_MERGE_ANGLE, LOD_NORMAL_SPLIT_ANGLE, [])
	var combined := importer.get_mesh()
	if combined == null or combined.get_surface_count() == 0:
		return null
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var save_error := ResourceSaver.save(combined, cache_path,
		ResourceSaver.FLAG_BUNDLE_RESOURCES | ResourceSaver.FLAG_COMPRESS)
	if save_error != OK:
		push_warning("MeshMerge could not cache %s: %s" % [cache_path, error_string(save_error)])
	return combined


## What a material looks like, as a string. Two surfaces sharing one of these render the same,
## so they can share a surface — and a draw call.
##
## Deliberately broad: every property that changes the pixel is in the key, including the ones
## this kit never uses. A fingerprint that omitted, say, emission would quietly merge a glowing
## crystal facet into the dull rock beside it, and the failure would be a look, not an error.
const ATTR_UV: int = 1
const ATTR_UV2: int = 2
const ATTR_COLOR: int = 4
const ATTR_TANGENT: int = 8


## Which optional vertex attributes a surface actually carries. An absent array reads back as
## null rather than as an empty typed array, so this tests for the value, not for emptiness.
static func _attribute_mask(arrays: Array) -> int:
	var mask: int = 0
	if _present(arrays, Mesh.ARRAY_TEX_UV):
		mask |= ATTR_UV
	if _present(arrays, Mesh.ARRAY_TEX_UV2):
		mask |= ATTR_UV2
	if _present(arrays, Mesh.ARRAY_COLOR):
		mask |= ATTR_COLOR
	if _present(arrays, Mesh.ARRAY_TANGENT):
		mask |= ATTR_TANGENT
	return mask


static func _present(arrays: Array, slot: int) -> bool:
	var value: Variant = arrays[slot]
	return value != null and (value as Array).size() > 0 if value is Array \
		else value != null and not _is_empty_packed(value)


static func _is_empty_packed(value: Variant) -> bool:
	match typeof(value):
		TYPE_PACKED_VECTOR2_ARRAY: return (value as PackedVector2Array).is_empty()
		TYPE_PACKED_VECTOR3_ARRAY: return (value as PackedVector3Array).is_empty()
		TYPE_PACKED_COLOR_ARRAY: return (value as PackedColorArray).is_empty()
		TYPE_PACKED_FLOAT32_ARRAY: return (value as PackedFloat32Array).is_empty()
		TYPE_PACKED_INT32_ARRAY: return (value as PackedInt32Array).is_empty()
	return true


static func _fingerprint(material: Material, surface: int) -> String:
	if material == null:
		return "none_%d" % surface
	var standard := material as StandardMaterial3D
	if standard == null:
		# Shader materials and anything else exotic keep their own identity — there is no safe
		# general way to tell two shader setups apart.
		return "obj_%d" % material.get_instance_id()
	return "std|%s|%.4f|%.4f|%d|%d|%s|%.4f|%d|%d|%d|%s|%s" % [
		standard.albedo_color, standard.roughness, standard.metallic,
		standard.shading_mode, standard.transparency,
		standard.emission, standard.emission_energy_multiplier,
		1 if standard.emission_enabled else 0,
		standard.cull_mode, standard.diffuse_mode,
		standard.albedo_texture.resource_path if standard.albedo_texture != null else "-",
		standard.normal_texture.resource_path if standard.normal_texture != null else "-",
	]


## The one Material instance every surface with this appearance shares, process-wide.
static var _shared_materials: Dictionary = {}


static func _shared_material(key: String, material: Material) -> Material:
	if material == null:
		return null
	if not _shared_materials.has(key):
		_shared_materials[key] = material
	return _shared_materials[key] as Material


static func _collect(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect(child, out)


static func _offset_to(node: Node3D, root: Node) -> Transform3D:
	var out := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != root:
		var spatial := current as Node3D
		if spatial != null:
			out = spatial.transform * out
		current = current.get_parent()
	return out
