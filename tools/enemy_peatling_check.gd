extends SceneTree

## Headless verification for the enemy ladder's tier 1, the Peatling (docs/ENEMIES.md §3, task 5.11).
##
## Run with:
##   .agent/bin/agent godot --headless --script tools/enemy_peatling_check.gd
##
## Three things, in the order they can go wrong:
##
## 1. THE IMPORT. Same contract `tools/enemy_crawler_check.gd` holds A-006 to — skeleton, skinned
##    mesh, all six clips under their ENGINE-side names, exactly two of them looping — because the
##    "-loop" suffix trap is a property of Godot's importer, not of either generator.
##
## 2. WHICH WAY IT FACES. F-039's bug, asserted rather than remembered. Blender's exporter maps
##    Blender -Y (the direction both generators call "forward") onto glTF +Z, and Godot's forward is
##    -Z — so an authored-forward model arrives facing BACKWARD and its `EnemyDef` has to carry a
##    180 degree `model_yaw_offset_degrees` to correct it. That is a fact nobody can see in a diff
##    and everybody has to re-derive; so this measures where the fan actually is in the imported
##    mesh and asserts the `.tres` agrees with the answer.
##
## 3. THE STAIN, end to end. Spawn a real Peatling, kill it through the real damage seam, and prove
##    the Mire grid gained corruption where it died and did not gain any far away. This is the
##    tier's whole identity (docs/ENEMIES.md §3.5) and it crosses three systems — `Enemy`,
##    `EnemyDef` and `MireGrid` — so nothing short of end to end actually covers it.

const EXPORTS := "res://assets/enemies/exports/"
const EXPECTED_BONES := 8
const EXPECTED_STATIC := [
	"enemy_peatling_fragment_gel",
	"enemy_peatling_fragment_husk",
]
const EXPECTED_CLIPS := {
	"idle": true,
	"locomotion": true,
	"attack_tell": false,
	"attack": false,
	"hit": false,
	"death": false,
}

## Somewhere the island's initial corruption cluster cannot have reached, so a rise in corruption at
## the kill site is unambiguously the kill's doing. Well inside the 256-cell grid either way.
const KILL_SITE := Vector3(60.0, 0.0, -60.0)
const CONTROL_SITE := Vector3(-60.0, 0.0, 60.0)

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	_check_import()
	_check_facing()
	await _check_stain()
	finish()


# ── 1. the import ─────────────────────────────────────────────────────────────────────────────────


func _check_import() -> void:
	print("== the Peatling imports as a rigged, animated scene ==")
	var scene := load(EXPORTS + "enemy_peatling.glb") as PackedScene
	check(scene != null, "enemy_peatling.glb imported as a PackedScene")
	if scene == null:
		return
	var peatling: Node = scene.instantiate()

	var skeleton := _find_node(peatling, "Skeleton3D") as Skeleton3D
	check(skeleton != null, "the Peatling imported rigged")
	if skeleton != null:
		check(skeleton.get_bone_count() == EXPECTED_BONES,
			"skeleton has %d bones (expected %d)" % [skeleton.get_bone_count(), EXPECTED_BONES])

	var mesh_instance := _find_node(peatling, "MeshInstance3D") as MeshInstance3D
	check(mesh_instance != null and mesh_instance.skin != null, "the mesh is skinned to the skeleton")

	var player := _find_node(peatling, "AnimationPlayer") as AnimationPlayer
	check(player != null, "the clips survived import")
	if player != null:
		var names := player.get_animation_list()
		for clip_name: String in EXPECTED_CLIPS:
			if not names.has(clip_name):
				check(false, "missing clip '%s'" % clip_name)
				continue
			var animation := player.get_animation(clip_name)
			var loops: bool = animation.loop_mode != Animation.LOOP_NONE
			check(loops == bool(EXPECTED_CLIPS[clip_name]) and animation.length > 0.0,
				"clip '%s' is %.3f s, loop=%s" % [clip_name, animation.length, loops])
		for extra: String in names:
			check(EXPECTED_CLIPS.has(extra), "no unexpected extra clip (saw '%s')" % extra)

	peatling.free()

	for static_name: String in EXPECTED_STATIC:
		var fragment := load(EXPORTS + static_name + ".glb") as PackedScene
		check(fragment != null, "%s.glb imported" % static_name)
		if fragment == null:
			continue
		var instance: Node = fragment.instantiate()
		check(_find_node(instance, "MeshInstance3D") != null
				and _find_node(instance, "Skeleton3D") == null
				and _find_node(instance, "AnimationPlayer") == null,
			"%s is a plain static mesh" % static_name)
		instance.free()


# ── 2. which way it faces ─────────────────────────────────────────────────────────────────────────


func _check_facing() -> void:
	print("\n== the authored yaw offset matches which way the mesh actually points (F-039) ==")
	var scene := load(EXPORTS + "enemy_peatling.glb") as PackedScene
	if scene == null:
		return
	var peatling: Node = scene.instantiate()
	var mesh_instance := _find_node(peatling, "MeshInstance3D") as MeshInstance3D
	if mesh_instance == null or mesh_instance.mesh == null:
		check(false, "no mesh to measure")
		peatling.free()
		return

	# The fan is by far the widest part of this creature, so "where is the fan?" is answerable as
	# "which half of the model carries the wider silhouette". Measured off the vertex array rather
	# than the AABB, which is symmetric about the origin and cannot tell front from back.
	# EVERY surface, not `surface_get_arrays(0)`. The mesh carries one surface per material and this
	# creature has eight, so surface 0 is a fraction of it — the first pass measured a single
	# material's geometry, missed the fan's corner lobes entirely, and produced two numbers 17%
	# apart that happened to have the right sign. A discriminator that is accidentally right is
	# worse than no discriminator.
	var vertices: PackedVector3Array = PackedVector3Array()
	for surface: int in mesh_instance.mesh.get_surface_count():
		vertices.append_array(mesh_instance.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX])
	var front_width: float = 0.0
	var back_width: float = 0.0
	for vertex: Vector3 in vertices:
		# Measured only OUTSIDE the middle third. Near the origin both halves carry the same body,
		# so a threshold close to zero compares the dome against itself and the two numbers come out
		# within a couple of centimetres of each other — technically the right sign, but far too
		# thin a margin to be a real assertion. Out past 0.15 m it is the fan's corner lobes against
		# the tail, which is a decisive difference.
		if vertex.z > 0.15:
			front_width = maxf(front_width, absf(vertex.x))
		elif vertex.z < -0.15:
			back_width = maxf(back_width, absf(vertex.x))
	peatling.free()

	var fan_on_positive_z: bool = front_width > back_width * 1.25
	check(fan_on_positive_z,
		"the fan sits on the mesh's +Z (%.3f m wide) not its -Z (%.3f m) — Blender's -Y forward "
		% [front_width, back_width]
		+ "arrives as glTF +Z, which is BACKWARD to Godot")

	var def: Resource = load("res://content/enemies/peatling.tres")
	check(def != null, "peatling.tres loads")
	if def == null:
		return
	var yaw: float = float(def.get(&"model_yaw_offset_degrees"))
	# Whichever way the mesh points, the def has to turn it to face Godot's forward (-Z). This is
	# the assertion that would have caught F-039 on the day rather than in play.
	var needs_flip: bool = fan_on_positive_z
	check(is_equal_approx(absf(yaw), 180.0) == needs_flip,
		"model_yaw_offset_degrees is %.0f, which points the fan down -Z" % yaw)


# ── 3. the stain ──────────────────────────────────────────────────────────────────────────────────


func _check_stain() -> void:
	print("\n== killing a Peatling stains the ground it died on (docs/ENEMIES.md §3.5) ==")
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	var mire_grid: Node = root.get_node_or_null(^"MireGrid")
	check(world != null and mire_grid != null, "EnemyWorld and MireGrid autoloads exist")
	if world == null or mire_grid == null:
		return

	check(bool(world.call("has_def", &"peatling")), "the Peatling definition is registered")
	var def: Resource = world.call("get_def", &"peatling")
	if def == null:
		check(false, "peatling.tres is not in the registry")
		return
	check((def.call("validation_errors") as PackedStringArray).is_empty(),
		"the authored definition validates")
	check(float(def.get(&"death_corruption_amount")) > 0.0
			and float(def.get(&"death_corruption_radius_m")) > 0.0,
		"it is authored to leave corruption behind")
	# The identity check, not a number check: tier 1 must be slower than a player's WALK, or "walk it
	# off your ground" — the counterplay the whole mechanic is built around — does not exist.
	check(float(def.get(&"move_speed")) < 4.0,
		"it is slower than player walk speed (4.0 m/s), so it can always be led away")
	check(is_zero_approx(float(def.get(&"alert_radius_m"))),
		"and it never calls a pack — tier 1's pressure is the ground, not the crowd")

	mire_grid.call(&"ensure_ready")
	var before_kill: float = float(mire_grid.call(&"corruption_at", KILL_SITE))
	var before_control: float = float(mire_grid.call(&"corruption_at", CONTROL_SITE))

	var enemy: Node3D = world.call("host_spawn", &"peatling", KILL_SITE)
	check(enemy != null, "the host spawns a Peatling")
	if enemy == null:
		return
	await process_frame
	# Straight through the real damage seam CombatService uses, not a private back door.
	var killed: bool = bool(enemy.call(&"host_apply_damage", int(def.get(&"max_health")) * 4, 1))
	check(killed, "it takes damage through the shared damageable seam")
	await process_frame
	check(not bool(enemy.call(&"is_alive")), "and dies")

	var after_kill: float = float(mire_grid.call(&"corruption_at", KILL_SITE))
	var after_control: float = float(mire_grid.call(&"corruption_at", CONTROL_SITE))
	check(after_kill > before_kill,
		"corruption at the kill site rose (%.3f -> %.3f)" % [before_kill, after_kill])
	check(is_equal_approx(after_control, before_control),
		"corruption on the other side of the island did not (%.3f -> %.3f)"
			% [before_control, after_control])

	# The falloff is what makes a stain read as a spill rather than a disc, and it is also what keeps
	# a single kill from saturating a whole cell radius.
	var radius: float = float(def.get(&"death_corruption_radius_m"))
	var edge: Vector3 = KILL_SITE + Vector3(radius * 0.92, 0.0, 0.0)
	var outside: Vector3 = KILL_SITE + Vector3(radius * 2.5, 0.0, 0.0)
	check(float(mire_grid.call(&"corruption_at", edge)) < after_kill,
		"the stain falls off toward its edge")
	check(is_zero_approx(float(mire_grid.call(&"corruption_at", outside))),
		"and stops entirely outside its radius")

	# Twice on one spot really does cost twice — `stain_radius()` adds rather than taking a max, so
	# "kill them all in one pile" is never the cheap option.
	var second: Node3D = world.call("host_spawn", &"peatling", KILL_SITE)
	if second != null:
		await process_frame
		second.call(&"host_apply_damage", int(def.get(&"max_health")) * 4, 1)
		await process_frame
		check(float(mire_grid.call(&"corruption_at", KILL_SITE)) > after_kill,
			"a second kill on the same ground stains it further, not equally")

	world.call("host_despawn_all")


# ── harness ───────────────────────────────────────────────────────────────────────────────────────


func _find_node(node: Node, type: String) -> Node:
	if node.get_class() == type:
		return node
	for child in node.get_children():
		var found := _find_node(child, type)
		if found != null:
			return found
	return null


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	printerr("FAIL: %s" % description)


func finish() -> void:
	print("\nENEMY_PEATLING_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)
