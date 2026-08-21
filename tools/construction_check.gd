extends SceneTree

## Verify the A-010 construction kit in the real engine — and, more to the
## point, verify that its pieces fit each other.
##
## Run with:  .agent/bin/agent godot --script tools/construction_check.gd
##
## Every other asset batch could be judged one export at a time. This one cannot:
## a bridge module is only correct in relation to the module beside it, and a
## door leaf is only correct in relation to the frame it hangs in. So this script
## imports the GLBs, checks each against the catalog, and then ASSEMBLES them —
## a five-module walkway with a ramp onto it, a boardwalk turning a corner, a
## fence turning a corner, and every hinged leaf swung through its documented
## arc against the frame it belongs to. Those assemblies are the contract; the
## per-asset numbers are just what makes them meaningful.
##
## Blender axes map as X -> X, Y -> -Z, Z -> Y. The kit's run axis is Blender x,
## so it is Godot x here, and the deck height is Godot y.
##
## It also ties the gameplay side to the art side (F-137): `content/buildables/*.tres` declares its
## own footprint independently of the catalog this script already loads, and nothing used to check
## the two agree.

const EXPORT_DIR: String = "res://assets/construction/exports"
const CATALOG_PATH: String = "res://assets/construction/catalog.json"
const BUILDABLES_DIR: String = "res://content/buildables"
const MODULE: float = 2.0
const DECK_Y: float = 1.0
const WALL_H: float = 3.0
## F-137: buildable id -> the catalog frame it should tile with. Only run pitch (size.x) and stand
## height (size.y) are compared, never depth — a footprint is allowed to be thinner than its art on
## purpose (buildable_def.gd's own doc comment on `size`).
const BUILDABLE_FRAME: Dictionary = {
	"door": "door_wood_frame",
	"gate": "gate_double_frame",
	"palisade": "palisade_straight",
	"palisade_gate": "palisade_gate_frame",
	"dock": "dock_straight",
	"floor": "floor_wood",
	"bridge": "bridge_straight",
	"ladder": "ladder",
}
## From entities/player/player.tscn. The ramp is the one piece the player's legs
## can veto, so its slope is checked against the engine's own number.
const FLOOR_MAX_ANGLE_DEG: float = 46.0
const TOLERANCE: float = 0.001

var failures: Array[String] = []
var boxes: Dictionary = {}
var parts: Dictionary = {}
var catalog: Dictionary = {}


func _init() -> void:
	var entries: Array = _load_catalog()
	if entries.is_empty():
		_finish()
		return
	for entry_value: Variant in entries:
		var entry := entry_value as Dictionary
		catalog[String(entry.get("name", ""))] = entry

	var on_disk: Array[String] = []
	var dir := DirAccess.open(EXPORT_DIR)
	if dir == null:
		failures.append("cannot open %s" % EXPORT_DIR)
		_finish()
		return
	for file_name in dir.get_files():
		if file_name.ends_with(".glb"):
			on_disk.append(file_name.get_basename())
	on_disk.sort()

	for name: Variant in catalog.keys():
		if not on_disk.has(String(name)):
			failures.append("%s: in catalog, no GLB on disk" % name)
	for name in on_disk:
		if not catalog.has(name):
			failures.append("%s: GLB on disk, not in catalog" % name)

	var triangles: int = 0
	for name in on_disk:
		if catalog.has(name):
			triangles += _check_asset(name, catalog[name] as Dictionary)
	print("CONSTRUCTION_IMPORT checked=%d triangles=%d" % [boxes.size(), triangles])

	_check_walkway()
	_check_dock_corner()
	_check_palisade_corner()
	_check_ramp()
	_check_doors()
	_check_state_drift()
	_check_buildable_defs()
	_finish()


func _load_catalog() -> Array:
	var text := FileAccess.get_file_as_string(CATALOG_PATH)
	if text.is_empty():
		failures.append("cannot read %s" % CATALOG_PATH)
		return []
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Array:
		failures.append("%s is not a JSON array" % CATALOG_PATH)
		return []
	return parsed as Array


func _collect(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect(child, out)


func _transform_to_root(node: Node3D, root: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var walker: Node = node
	while walker != null and walker != root:
		if walker is Node3D:
			result = (walker as Node3D).transform * result
		walker = walker.get_parent()
	return result


## Vertices, never `transform * get_aabb()`. An AABB is axis-aligned in the
## mesh's own space, so pushing it through a rotation returns the box around the
## rotated box — strictly larger than the geometry inside it. Every diagonal
## brace and every round post in this kit is a rotated primitive, so the inflated
## ruler would report seams and floating decks that are not there (F-094 on this
## side of the fence).
func _measure(name: String) -> Array:
	var packed: PackedScene = load("%s/%s.glb" % [EXPORT_DIR, name]) as PackedScene
	if packed == null:
		failures.append("%s: did not import as a PackedScene" % name)
		return []
	var node: Node = packed.instantiate()
	var meshes: Array[MeshInstance3D] = []
	_collect(node, meshes)
	var measured: Array = []
	for instance in meshes:
		var mesh := instance.mesh
		if mesh == null:
			failures.append("%s: %s has no mesh" % [name, instance.name])
			continue
		var to_root := _transform_to_root(instance, node)
		var low := Vector3.INF
		var high := -Vector3.INF
		var count: int = 0
		var vertices := PackedVector3Array()
		for surface in mesh.get_surface_count():
			if mesh.surface_get_material(surface) == null:
				failures.append("%s: %s surface %d has no embedded material" % [name, instance.name, surface])
			var arrays: Array = mesh.surface_get_arrays(surface)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var source: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			count += indices.size() / 3
			# Expanded through the index buffer, so every three entries are one
			# real triangle. Bounds come out the same; what this buys is a swing
			# test that can use triangles instead of a box around a rotated box.
			for index in indices:
				var point := to_root * source[index]
				vertices.append(point)
				low = low.min(point)
				high = high.max(point)
		if instance.skin != null:
			failures.append("%s: %s carries a skin; this batch is static geometry" % [name, instance.name])
		measured.append({
			"name": String(instance.name),
			"aabb": AABB(low, high - low),
			"points": vertices,
			"triangles": count,
		})
	node.free()
	return measured


func _check_asset(name: String, entry: Dictionary) -> int:
	var measured: Array = _measure(name)
	if measured.is_empty():
		failures.append("%s: instantiated with no measurable mesh" % name)
		return 0
	parts[name] = measured

	var low := Vector3.INF
	var high := -Vector3.INF
	var triangles: int = 0
	for part_value: Variant in measured:
		var part := part_value as Dictionary
		var box := part["aabb"] as AABB
		low = low.min(box.position)
		high = high.max(box.end)
		triangles += int(part["triangles"])
	var aabb := AABB(low, high - low)
	boxes[name] = aabb

	var expected := Vector3(
		float(entry.get("width_m", 0.0)),
		float(entry.get("height_m", 0.0)),
		float(entry.get("depth_m", 0.0))
	)
	if (aabb.size - expected).length() > 0.02:
		failures.append("%s: engine measures %v, catalog says %v" % [name, aabb.size.snappedf(0.001), expected])
	if triangles != int(entry.get("triangles", 0)):
		failures.append("%s: %d triangles in engine, catalog says %d" % [name, triangles, int(entry.get("triangles", 0))])

	var origin := String(entry.get("origin", ""))
	if origin == "ground_centred":
		if absf(aabb.position.y) > 0.01:
			failures.append("%s: base sits %.1f mm off its origin" % [name, aabb.position.y * 1000.0])
		var centre := aabb.position + aabb.size * 0.5
		if absf(centre.x) > 0.01 or absf(centre.z) > 0.01:
			failures.append("%s: not horizontally centred (%v)" % [name, centre.snappedf(0.001)])
	elif aabb.position.y < -0.01:
		failures.append("%s: %.1f mm below the ground plane" % [name, aabb.position.y * 1000.0])

	# The module contract, re-measured by the engine rather than trusted.
	if entry.has("run_span_m"):
		var span := float(entry["run_span_m"])
		if absf(aabb.size.x - span) > TOLERANCE:
			failures.append("%s: runs %.4f m, module is %.2f m" % [name, aabb.size.x, span])
	if entry.has("deck_z_m"):
		var deck := _deck_box(name)
		if deck.size == Vector3.ZERO:
			failures.append("%s: no Deck geometry in the engine" % name)
		elif absf(deck.end.y - DECK_Y) > TOLERANCE:
			failures.append("%s: deck at %.4f m, the kit's deck is %.2f m" % [name, deck.end.y, DECK_Y])
	return triangles


func _deck_box(name: String, offset: Vector3 = Vector3.ZERO, turn: float = 0.0) -> AABB:
	var low := Vector3.INF
	var high := -Vector3.INF
	var basis := Basis(Vector3.UP, turn)
	for part_value: Variant in parts.get(name, []) as Array:
		var part := part_value as Dictionary
		if not String(part["name"]).begins_with("Deck"):
			continue
		var box := part["aabb"] as AABB
		for corner in 8:
			var point: Vector3 = basis * box.get_endpoint(corner) + offset
			low = low.min(point)
			high = high.max(point)
	if low == Vector3.INF:
		return AABB()
	return AABB(low, high - low)


## Five modules and a ramp, laid end to end the way the catalog says to lay
## them. Every walking surface has to land on the same plane and every joint has
## to close: a run of decks with a 6 mm lip in it is a run of decks you trip on.
func _check_walkway() -> void:
	var run: Array = [
		["ramp", -4.0], ["dock_straight", -2.0], ["dock_straight", 0.0],
		["bridge_straight", 2.0], ["bridge_broken", 4.0],
	]
	var decks: Array[AABB] = []
	for step_value: Variant in run:
		var step := step_value as Array
		var deck := _deck_box(String(step[0]), Vector3(float(step[1]), 0.0, 0.0))
		if deck.size == Vector3.ZERO:
			failures.append("walkway: %s contributed no deck" % step[0])
			continue
		if absf(deck.end.y - DECK_Y) > TOLERANCE:
			failures.append("walkway: %s deck lands at %.4f, not %.3f" % [step[0], deck.end.y, DECK_Y])
		decks.append(deck)
	var worst: float = 0.0
	for index in range(decks.size() - 1):
		var gap: float = decks[index + 1].position.x - decks[index].end.x
		worst = maxf(worst, absf(gap))
		if absf(gap) > TOLERANCE:
			failures.append("walkway: %.2f mm %s between module %d and %d" % [
				absf(gap) * 1000.0, "gap" if gap > 0.0 else "overlap", index, index + 1
			])
	print("CONSTRUCTION_WALKWAY modules=%d worst_joint=%.4f mm deck=%.3f m" % [decks.size(), worst * 1000.0, DECK_Y])


## The corner turns the boardwalk, so it has to close on two different edges at
## once — the failure a straight run cannot expose.
func _check_dock_corner() -> void:
	var corner := _deck_box("dock_corner")
	var west := _deck_box("dock_straight", Vector3(-MODULE, 0.0, 0.0))
	var north := _deck_box("dock_straight", Vector3(0.0, 0.0, -MODULE), PI * 0.5)
	if corner.size == Vector3.ZERO or west.size == Vector3.ZERO or north.size == Vector3.ZERO:
		failures.append("dock corner: a piece of the turn has no deck")
		return
	var west_gap: float = corner.position.x - west.end.x
	var north_gap: float = corner.position.z - north.end.z
	if absf(west_gap) > TOLERANCE:
		failures.append("dock corner: %.2f mm joint on the -x arm" % (west_gap * 1000.0))
	if absf(north_gap) > TOLERANCE:
		failures.append("dock corner: %.2f mm joint on the -z arm" % (north_gap * 1000.0))
	if absf(corner.end.y - west.end.y) > TOLERANCE or absf(corner.end.y - north.end.y) > TOLERANCE:
		failures.append("dock corner: the turn steps up or down")
	print("CONSTRUCTION_DOCK_CORNER arms=%.4f mm / %.4f mm" % [west_gap * 1000.0, north_gap * 1000.0])


## The palisade corner is the one piece with a JOINT origin: its own corner post,
## not its bounding box. That claim is worth nothing unless a straight section
## really does butt to it at the offsets the catalog names.
func _check_palisade_corner() -> void:
	var mates: Array = (catalog.get("palisade_corner", {}) as Dictionary).get("mates_m", [])
	if mates.size() != 2:
		failures.append("palisade_corner: catalog does not name two mates")
		return
	var arm_a := _rail_box("palisade_corner", "Arm_A_Rail")
	var arm_b := _rail_box("palisade_corner", "Arm_B_Rail")
	if arm_a.size == Vector3.ZERO or arm_b.size == Vector3.ZERO:
		failures.append("palisade_corner: arms have no rails to measure")
		return
	# Blender's +y arm is Godot's -z, so the catalog's [0, MODULE, 0] mate is a
	# straight section turned 90 degrees and set at -z.
	var straight_a := _rail_box("palisade_straight", "Rail", Vector3(-MODULE, 0.0, 0.0))
	var straight_b := _rail_box("palisade_straight", "Rail", Vector3(0.0, 0.0, -MODULE), PI * 0.5)
	var gap_a: float = arm_a.position.x - straight_a.end.x
	var gap_b: float = arm_b.position.z - straight_b.end.z
	if absf(gap_a) > TOLERANCE:
		failures.append("palisade_corner: %.2f mm joint on arm A" % (gap_a * 1000.0))
	if absf(gap_b) > TOLERANCE:
		failures.append("palisade_corner: %.2f mm joint on arm B" % (gap_b * 1000.0))
	var height: float = boxes.get("palisade_straight", AABB()).size.y
	if absf(height - WALL_H) > 0.01:
		failures.append("palisade_straight: %.3f m tall, the kit's wall is %.2f m" % [height, WALL_H])
	if absf(boxes.get("ladder", AABB()).size.y - WALL_H) > 0.01:
		failures.append("ladder: %.3f m, so it does not top out level with a wall" % boxes.get("ladder", AABB()).size.y)
	print("CONSTRUCTION_PALISADE_CORNER arms=%.4f mm / %.4f mm" % [gap_a * 1000.0, gap_b * 1000.0])


func _rail_box(name: String, prefix: String, offset: Vector3 = Vector3.ZERO, turn: float = 0.0) -> AABB:
	var low := Vector3.INF
	var high := -Vector3.INF
	var basis := Basis(Vector3.UP, turn)
	for part_value: Variant in parts.get(name, []) as Array:
		var part := part_value as Dictionary
		if not String(part["name"]).begins_with(prefix):
			continue
		var box := part["aabb"] as AABB
		for corner in 8:
			var point: Vector3 = basis * box.get_endpoint(corner) + offset
			low = low.min(point)
			high = high.max(point)
	if low == Vector3.INF:
		return AABB()
	return AABB(low, high - low)


## The player controller has no step-up, so a ramp that is too steep or that
## misses the deck by a centimetre is a ramp nobody can use.
func _check_ramp() -> void:
	var deck := _deck_box("ramp")
	var box: AABB = boxes.get("ramp", AABB())
	if deck.size == Vector3.ZERO:
		failures.append("ramp: no deck surface")
		return
	var rise: float = deck.size.y
	var run: float = deck.size.x
	var angle: float = rad_to_deg(atan2(rise, run))
	if angle > FLOOR_MAX_ANGLE_DEG:
		failures.append("ramp: %.1f degrees, past the player's %.0f degree floor limit" % [angle, FLOOR_MAX_ANGLE_DEG])
	if absf(deck.end.y - DECK_Y) > TOLERANCE:
		failures.append("ramp: head at %.4f m, the deck it feeds is %.2f m" % [deck.end.y, DECK_Y])
	if box.position.y > 0.02:
		failures.append("ramp: toe starts %.0f mm up, and nothing in the game can step that" % (box.position.y * 1000.0))
	if absf(run - MODULE) > TOLERANCE:
		failures.append("ramp: %.4f m of run, module is %.2f m" % [run, MODULE])
	print("CONSTRUCTION_RAMP slope=%.2f deg rise=%.3f m toe=%.1f mm" % [angle, rise, box.position.y * 1000.0])


## A per-triangle AABB shrunk inward by `margin` on every axis, clamped so a
## degenerate (near-planar) triangle collapses to zero width on its thin axis
## instead of `AABB.grow()` driving that axis negative (F-148). Plain `.abs()`
## would instead flip a negative axis positive around its grown center, which
## expands the box past the triangle's real bounds on that axis.
func _shrunk_solid(low: Vector3, high: Vector3, margin: float) -> AABB:
	var center := (low + high) * 0.5
	var half := (high - low) * 0.5
	half.x = maxf(half.x - margin, 0.0)
	half.y = maxf(half.y - margin, 0.0)
	half.z = maxf(half.z - margin, 0.0)
	return AABB(center - half, half * 2.0)


## Hang every leaf in the frame the catalog gives it, swing it through the arc
## the catalog documents, and fail if any part of the leaf is ever inside any
## part of the frame. This is the whole of "working wood door": without it the
## claim is a name in a filename.
func _check_doors() -> void:
	var swung: int = 0
	for name: Variant in catalog.keys():
		var entry := catalog[String(name)] as Dictionary
		if not entry.has("hinge"):
			continue
		var hinge := entry["hinge"] as Dictionary
		var frame_name := String(hinge["frame"])
		if not parts.has(frame_name) or not parts.has(String(name)):
			failures.append("%s: frame or leaf missing, so the swing cannot be checked" % name)
			continue
		# Blender (x, y, z) becomes Godot (x, z, -y).
		var offset_raw: Array = hinge["hinge_offset_m"] as Array
		var hinge_at := Vector3(float(offset_raw[0]), float(offset_raw[2]), -float(offset_raw[1]))
		var swing: float = 1.0 if String(hinge["opens_toward"]) == "+x" else -1.0
		var limit: float = float(hinge["swing_deg"])
		var opening := (catalog[frame_name] as Dictionary).get("opening_m", {}) as Dictionary
		var half_width: float = float(opening.get("width", 1.0)) * 0.5
		var top: float = float(opening.get("height", 2.0))

		# The frame as triangles. A jamb's knee brace is a rotated box, so the
		# box around it is far bigger than the wood; per-triangle bounds are
		# tight enough that a near miss stays a near miss.
		var solids: Array[AABB] = []
		for part_value: Variant in parts[frame_name] as Array:
			var part := part_value as Dictionary
			# A pintle and a knuckle are supposed to interlock; that is what a
			# hinge is. Everything else in the frame is a collision.
			if String(part["name"]).contains("Pintle"):
				continue
			var soup: PackedVector3Array = part["points"]
			var index: int = 0
			while index + 2 < soup.size():
				var low := soup[index].min(soup[index + 1]).min(soup[index + 2])
				var high := soup[index].max(soup[index + 1]).max(soup[index + 2])
				solids.append(_shrunk_solid(low, high, 0.004))
				index += 3

		var worst_bite: float = 0.0
		var step: float = 0.0
		while step <= limit + 0.01:
			var basis := Basis(Vector3.UP, deg_to_rad(step) * swing)
			for part_value: Variant in parts[String(name)] as Array:
				var part := part_value as Dictionary
				if String(part["name"]).contains("Knuckle"):
					continue
				for vertex: Vector3 in part["points"] as PackedVector3Array:
					var point: Vector3 = basis * vertex + hinge_at
					for solid in solids:
						if solid.has_point(point):
							failures.append("%s: %s is inside the frame at %.0f degrees" % [
								name, part["name"], step
							])
							step = limit + 100.0
							break
					if step > limit:
						break
				if step > limit:
					break
			step += 10.0

		# And the point of opening it: at full swing a player walks through.
		# The corridor is the middle of the opening, not its last 250 mm — an
		# open leaf's own thickness always eats the edge it is hinged on.
		var basis_open := Basis(Vector3.UP, deg_to_rad(limit) * swing)
		var corridor := AABB(
			Vector3(-half_width + 0.25, 0.10, -0.16),
			Vector3(maxf(0.1, (half_width - 0.25) * 2.0), minf(top, 1.90) - 0.10, 0.32)
		)
		for part_value: Variant in parts[String(name)] as Array:
			var part := part_value as Dictionary
			for vertex: Vector3 in part["points"] as PackedVector3Array:
				var point: Vector3 = basis_open * vertex + hinge_at
				if corridor.has_point(point):
					failures.append("%s: still blocking the doorway at %.0f degrees" % [name, limit])
					worst_bite = 1.0
					break
			if worst_bite > 0.0:
				break
		swung += 1
	print("CONSTRUCTION_DOORS swung=%d" % swung)


## The intact and broken bridge are swapped in place when a span gives way.
## Nothing re-centres them, so they cannot drift — this is the measurement.
func _check_state_drift() -> void:
	var intact := _rail_box("bridge_straight", "Anchor")
	var broken := _rail_box("bridge_broken", "Anchor")
	if intact.size == Vector3.ZERO or broken.size == Vector3.ZERO:
		failures.append("bridge state pair: no shared Anchor geometry to compare")
		return
	var drift: float = maxf(
		(intact.position - broken.position).length(),
		(intact.size - broken.size).length()
	)
	if drift > TOLERANCE:
		failures.append("bridge states drift %.3f mm at the shared trestle" % (drift * 1000.0))
	print("CONSTRUCTION_STATE_DRIFT %.4f mm" % (drift * 1000.0))


## F-137: `content/buildables/*.tres` states the module a second time, by hand, in a different
## resource than the one everything above measures. `wall.tres` has no exported GLB at all, so it
## is compared straight to this file's own MODULE/WALL_H constants (the same numbers
## `tools/blender/build_construction_set.py` hand-declares on its side, per its own header comment).
## Every other buildable with a catalog counterpart is compared to that entry's engine-measured
## `run_span_m`/`height_m` instead, so a `.tres` authored off-module fails here without needing its
## own hardcoded expectation.
func _check_buildable_defs() -> void:
	var wall := load("%s/wall.tres" % BUILDABLES_DIR) as BuildableDef
	if wall == null:
		failures.append("wall.tres: did not load as a BuildableDef")
	else:
		if absf(wall.size.x - MODULE) > TOLERANCE:
			failures.append("wall.tres: size.x is %.3f m, the kit's module is %.2f m" % [wall.size.x, MODULE])
		if absf(wall.size.y - WALL_H) > TOLERANCE:
			failures.append("wall.tres: size.y is %.3f m, the kit's wall height is %.2f m" % [wall.size.y, WALL_H])

	var checked := 1
	for buildable_name: String in BUILDABLE_FRAME:
		var frame_name: String = BUILDABLE_FRAME[buildable_name]
		var entry := catalog.get(frame_name, {}) as Dictionary
		if entry.is_empty():
			failures.append("%s.tres: no '%s' entry in the catalog to check against" % [buildable_name, frame_name])
			continue
		var def := load("%s/%s.tres" % [BUILDABLES_DIR, buildable_name]) as BuildableDef
		if def == null:
			failures.append("%s.tres: did not load as a BuildableDef" % buildable_name)
			continue
		if entry.has("run_span_m"):
			var run_span: float = float(entry["run_span_m"])
			if absf(def.size.x - run_span) > 0.01:
				failures.append("%s.tres: size.x is %.3f m, %s runs %.3f m" % [buildable_name, def.size.x, frame_name, run_span])
		if entry.has("height_m"):
			var height: float = float(entry["height_m"])
			if absf(def.size.y - height) > 0.01:
				failures.append("%s.tres: size.y is %.3f m, %s stands %.3f m" % [buildable_name, def.size.y, frame_name, height])
		checked += 1
	print("CONSTRUCTION_BUILDABLE_DEFS checked=%d" % checked)


func _finish() -> void:
	if failures.is_empty():
		print("CONSTRUCTION_CHECK PASS")
		quit(0)
		return
	for failure in failures:
		print("FAIL  %s" % failure)
	print("CONSTRUCTION_CHECK FAIL failures=%d" % failures.size())
	quit(1)
