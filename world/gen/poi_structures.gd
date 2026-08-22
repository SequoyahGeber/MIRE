extends RefCounted

## Builds a POI's STRUCTURE — an arrangement of kit pieces, laid out by code from the world seed
## (F-493).
##
## ## Why a structure is not a scene and not scatter
##
## `PoiDef.scene_path` covers the case where a site is one authored `.tscn`, and scatter covers the
## case where props are independent points. A ruin is neither: it is several pieces whose positions
## only mean anything relative to each other, and it has to differ from seed to seed or every island
## ships the same building. So the layout is a function, this file turns its output into nodes, and
## `PoiDef.structure_id` names which function.
##
## ## Adding a structure
##
## Write a script with `static func pieces_for_site(site_seed: int) -> Array[Dictionary]`, list it
## in [constant BUILDERS], and set `structure_id` on a `content/poi/*.tres`. That is the whole
## contract — deliberately, because the structures worth having are the ones somebody designs, and
## a designer should not have to touch `procedural_world.gd` to try one.
##
## Each piece is `{asset, kit, offset: Vector3, yaw: float, tilt: Vector2, scale: float,
## sink: float, lying_radius: float}`; `offset` is local to the site, `sink` is how far the piece
## settles into the ground, and `lying_radius` lifts a piece that has been rotated onto its side so
## it rests ON the ground instead of halfway through it.
##
## ## AUTHORITY: none
##
## `docs/ARCHITECTURE.md` §2.2. Derived from the shared seed, identical on every peer, never sent —
## same standing as every other generation pass. Collision built here is static world collision.

const PropCollider := preload("res://world/gen/prop_collider.gd")
const DrawPolicy := preload("res://world/environment/draw_policy.gd")

const BUILDERS: Dictionary = {
	&"ruins": preload("res://world/gen/ruin_site.gd"),
	&"stone_circle": preload("res://world/gen/stone_circle_site.gd"),
}

## A structure's pieces stand on the real surface, so a hall on a gentle slope steps down it. Beyond
## this the pieces would visibly tear apart from one another, so the site levels to its own centre
## instead and the last few centimetres are absorbed by `sink`.
const MAX_FOLLOW_DROP_M: float = 1.6


static func has_structure(structure_id: StringName) -> bool:
	return BUILDERS.has(structure_id)


## Instances one structure under `site_root`. `height_at` is called per piece with world (x, z) and
## must answer the same surface the chunk mesher builds — pass `ProceduralWorld.height_at`.
##
## Returns the number of pieces built, for the checks and the world's own log line.
static func build(
	site_root: Node3D, structure_id: StringName, site_seed: int, height_at: Callable
) -> int:
	var builder: Script = BUILDERS.get(structure_id, null)
	if builder == null:
		return 0
	var pieces: Array = builder.call(&"pieces_for_site", site_seed)
	var mesh_cache: Dictionary = {}
	var collider_cache: Dictionary = {}
	var origin: Vector3 = site_root.global_position
	var site_yaw: float = site_root.rotation.y
	var built: int = 0

	for index: int in pieces.size():
		var piece: Dictionary = pieces[index]
		var kit: String = String(piece.get("kit", ""))
		var asset: String = String(piece.get("asset", ""))
		var parts: Array = _mesh_parts(mesh_cache, kit, asset)
		if parts.is_empty():
			continue

		# The site's own yaw turns the whole building, so a ruin is not axis-aligned with the world
		# grid on every island.
		var local: Vector3 = (piece.get("offset", Vector3.ZERO) as Vector3).rotated(Vector3.UP, site_yaw)
		var world_x: float = origin.x + local.x
		var world_z: float = origin.z + local.z
		var ground: float = float(height_at.call(world_x, world_z))
		# Follow the ground, but never further than a building can plausibly step.
		ground = clampf(ground, origin.y - MAX_FOLLOW_DROP_M, origin.y + MAX_FOLLOW_DROP_M)

		var holder := Node3D.new()
		holder.name = "%s_%02d" % [asset, index]
		holder.set_meta(&"asset", StringName(asset))
		holder.set_meta(&"kit", kit)

		var basis := Basis()
		var tilt: Vector2 = piece.get("tilt", Vector2.ZERO)
		basis = basis.rotated(Vector3.UP, site_yaw + float(piece.get("yaw", 0.0)))
		basis = basis.rotated(basis.x.normalized(), tilt.x)
		basis = basis.rotated(basis.z.normalized(), tilt.y)
		var scale: float = float(piece.get("scale", 1.0))
		# Composed in WORLD space and assigned after the holder is in the tree. The site root
		# carries the ruin's own position and yaw, so writing a world transform into `transform`
		# would apply both twice — which is exactly what the first cut of this did, and it put a
		# ruin at double its site's height.
		var world_transform := Transform3D(
			basis.scaled(Vector3(scale, scale, scale)),
			Vector3(
				world_x,
				ground - float(piece.get("sink", 0.0)) + float(piece.get("lying_radius", 0.0)),
				world_z,
			)
		)

		var visual := Node3D.new()
		visual.name = "Visual"
		for part: Dictionary in parts:
			var mesh_instance := MeshInstance3D.new()
			mesh_instance.mesh = part["mesh"]
			mesh_instance.transform = part["offset"] as Transform3D
			DrawPolicy.apply(mesh_instance, (part["mesh"] as Mesh).get_aabb(), scale)
			visual.add_child(mesh_instance)
		holder.add_child(visual)

		# Masonry is solid: unlike scatter's flora, a ruin piece with no collider is a wall you walk
		# through. `PropCollider` still decides the SHAPE — it is the one place that knows a fallen
		# wall wants a box along its length and a standing column wants a cylinder.
		var fit: Dictionary = PropCollider.fit_cached(collider_cache, "%s|%s" % [kit, asset], parts)
		if not fit.is_empty():
			var body := StaticBody3D.new()
			body.name = "CollisionBody"
			var shape_node := CollisionShape3D.new()
			if StringName(fit.get("shape", &"cylinder")) == &"box":
				var box := BoxShape3D.new()
				box.size = fit["size"] as Vector3
				shape_node.shape = box
				shape_node.position = fit["center"] as Vector3
			else:
				var cylinder := CylinderShape3D.new()
				cylinder.radius = float(fit["radius"])
				cylinder.height = float(fit["height"])
				shape_node.shape = cylinder
				shape_node.position.y = float(fit["center_y"])
			body.add_child(shape_node)
			holder.add_child(body)

		site_root.add_child(holder)
		holder.global_transform = world_transform
		built += 1
	return built


## Mesh parts of one export, cached per (kit, asset) for the same reason `ResourceScatterField`
## caches its own: the walk instantiates the GLB, and a ruin uses the same four wall meshes a dozen
## times.
static func _mesh_parts(cache: Dictionary, kit: String, asset: String) -> Array:
	var key := "%s|%s" % [kit, asset]
	if cache.has(key):
		return cache[key]
	var packed: PackedScene = load("res://assets/%s/exports/%s.glb" % [kit, asset]) as PackedScene
	if packed == null:
		push_error("PoiStructures could not load %s/%s" % [kit, asset])
		cache[key] = []
		return []
	var sample: Node = packed.instantiate()
	var found: Array[MeshInstance3D] = []
	_collect_meshes(sample, found)
	var parts: Array = []
	for part: MeshInstance3D in found:
		if part.mesh != null:
			parts.append({"mesh": part.mesh, "offset": _global_offset(part, sample)})
	sample.free()
	cache[key] = parts
	return parts


static func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		_collect_meshes(child, out)


static func _global_offset(node: Node3D, root: Node) -> Transform3D:
	var transform := Transform3D.IDENTITY
	var cursor: Node = node
	while cursor != null and cursor != root.get_parent():
		if cursor is Node3D:
			transform = (cursor as Node3D).transform * transform
		cursor = cursor.get_parent()
	return transform
