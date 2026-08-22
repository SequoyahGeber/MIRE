extends SceneTree

## Headless verification for the enemy ladder's tier 5, the Mire Herald (docs/ENEMIES.md §7).
##
## Run with:
##   .agent/bin/agent godot --headless --script tools/enemy_mire_herald_check.gd
##
## Import and facing as for the rungs below, then the aura — which is the only mechanic in the roster
## that runs while nothing is happening, so it is checked over TIME rather than at an instant:
##
##   · standing still corrupts the ground under it, and keeps corrupting it
##   · WALKING corrupts a trail, not a spot — which is what makes kiting one expensive
##   · a corpse stops. The aura is what the creature does, not what its body is.
##   · a kind with no aura authored never touches the grid at all
##
## Plus the tier's stat identity, and the one structural fact the whole rung rests on: this is the
## same `MireGrid.host_add_corruption()` seam the tier-1 Peatling's death stain uses. Tier 1 corrupts
## a patch by dying; tier 5 does not have to die. If those two ever stop sharing a seam, the ladder
## has stopped being a ladder.

const EXPORTS := "res://assets/enemies/exports/"
const EXPECTED_BONES := 20
const EXPECTED_STATIC := [
	"enemy_mire_herald_fragment_antler",
	"enemy_mire_herald_fragment_hide",
]
const EXPECTED_CLIPS := {
	"idle": true,
	"locomotion": true,
	"attack_tell": false,
	"attack": false,
	"hit": false,
	"death": false,
}

## Far from the island's own initial corruption cluster, so any rise here is unambiguously the
## Herald's doing.
const SITE := Vector3(-140.0, 0.0, 140.0)

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	_check_import()
	_check_facing()
	await _check_aura()
	finish()


# ── 1. the import ─────────────────────────────────────────────────────────────────────────────────


func _check_import() -> void:
	print("== the Mire Herald imports as a rigged, animated scene ==")
	var scene := load(EXPORTS + "enemy_mire_herald.glb") as PackedScene
	check(scene != null, "enemy_mire_herald.glb imported as a PackedScene")
	if scene == null:
		return
	var herald: Node = scene.instantiate()

	var skeleton := _find_node(herald, "Skeleton3D") as Skeleton3D
	check(skeleton != null, "it imported rigged")
	if skeleton != null:
		check(skeleton.get_bone_count() == EXPECTED_BONES,
			"skeleton has %d bones (expected %d)" % [skeleton.get_bone_count(), EXPECTED_BONES])
		# The antlers are their own bones so the rack can be driven by the head rather than welded to
		# it. Forty kilos of lever is the whole reason this creature moves the way it does.
		var antlers: int = 0
		for index: int in skeleton.get_bone_count():
			if skeleton.get_bone_name(index).begins_with("antler_"):
				antlers += 1
		check(antlers == 2, "both antlers are their own bones")

	var mesh_instance := _find_node(herald, "MeshInstance3D") as MeshInstance3D
	check(mesh_instance != null and mesh_instance.skin != null, "the mesh is skinned to the skeleton")

	var player := _find_node(herald, "AnimationPlayer") as AnimationPlayer
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

		var def: Resource = load("res://content/enemies/mire_herald.tres")
		if def != null:
			check(player.get_animation("attack_tell").length <= float(def.get(&"attack_tell_seconds")) + 0.001,
				"the tell clip (%.3f s) fits inside attack_tell_seconds"
					% player.get_animation("attack_tell").length)
			check(player.get_animation("attack").length <= float(def.get(&"attack_seconds")) + 0.001,
				"the strike clip (%.3f s) fits inside attack_seconds"
					% player.get_animation("attack").length)

	herald.free()

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


# ── 2. which way it faces, and how big it is ──────────────────────────────────────────────────────


func _check_facing() -> void:
	print("\n== the rack, the span, and the yaw offset (F-039) ==")
	var scene := load(EXPORTS + "enemy_mire_herald.glb") as PackedScene
	if scene == null:
		return
	var herald: Node = scene.instantiate()
	var mesh_instance := _find_node(herald, "MeshInstance3D") as MeshInstance3D
	if mesh_instance == null or mesh_instance.mesh == null:
		check(false, "no mesh to measure")
		herald.free()
		return

	var span: float = 0.0
	var head_bulk: int = 0
	var tail_bulk: int = 0
	for surface: int in mesh_instance.mesh.get_surface_count():
		for vertex: Vector3 in mesh_instance.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
			span = maxf(span, absf(vertex.x) * 2.0)
			if vertex.z > 1.4:
				head_bulk += 1
			elif vertex.z < -1.4:
				tail_bulk += 1
	herald.free()

	# Megaloceros' antlers reach about three and a half metres across, and that number is the
	# creature's entire silhouette. If a future tweak quietly costs it its span, it has stopped being
	# the thing this rung is for.
	check(span > 3.0, "the antler span is %.2f m — the real animal's order of magnitude" % span)

	var head_on_positive_z: bool = head_bulk > tail_bulk
	check(head_on_positive_z,
		"the head end carries more geometry past +1.4 m (%d verts) than the tail end past -1.4 m (%d)"
			% [head_bulk, tail_bulk])

	var def: Resource = load("res://content/enemies/mire_herald.tres")
	check(def != null, "mire_herald.tres loads")
	if def == null:
		return
	check(is_equal_approx(absf(float(def.get(&"model_yaw_offset_degrees"))), 180.0) == head_on_positive_z,
		"model_yaw_offset_degrees points the head down Godot's -Z")


# ── 3. the aura ───────────────────────────────────────────────────────────────────────────────────


func _check_aura() -> void:
	print("\n== tier 5's identity: the stats it is made of ==")
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	var mire_grid: Node = root.get_node_or_null(^"MireGrid")
	check(world != null and mire_grid != null, "EnemyWorld and MireGrid autoloads exist")
	if world == null or mire_grid == null:
		return
	check(bool(world.call("has_def", &"mire_herald")), "the Mire Herald definition is registered")
	var def: Resource = world.call("get_def", &"mire_herald")
	if def == null:
		return
	check((def.call("validation_errors") as PackedStringArray).is_empty(),
		"the authored definition validates")
	check(float(def.get(&"aura_corruption_per_second")) > 0.0
			and float(def.get(&"aura_corruption_radius_m")) > 0.0,
		"it is authored to corrupt the ground continuously")
	check(int(def.get(&"max_health")) > 200, "it has the deepest health pool in the roster")
	check(float(def.get(&"alert_radius_m")) >= 30.0,
		"and it wakes everything for %.0f m — a Herald arriving brings the night with it"
			% float(def.get(&"alert_radius_m")))

	# The structural fact the rung rests on. Tier 1 corrupts a patch by dying and tier 5 does not have
	# to die; if those two ever stop sharing a seam, the ladder has stopped being a ladder.
	var peatling: Resource = world.call("get_def", &"peatling")
	check(peatling != null and float(peatling.get(&"death_corruption_amount")) > 0.0,
		"tier 1 still corrupts by dying, which is the same mechanic this one does not have to die for")

	print("\n== the aura: it corrupts the ground it is standing on, and does not stop ==")
	mire_grid.call(&"ensure_ready")
	var before: float = float(mire_grid.call(&"corruption_at", SITE))
	var enemy: Node3D = world.call("host_spawn", &"mire_herald", SITE)
	check(enemy != null, "the host spawns a Mire Herald")
	if enemy == null:
		return
	await process_frame
	enemy.global_position = SITE

	# Two seconds of standing still, stepped rather than waited: the state machine is deterministic
	# in delta, and a check that sleeps is a check nobody runs.
	_step(enemy, 0.1, 20)
	var after_two: float = float(mire_grid.call(&"corruption_at", SITE))
	check(after_two > before,
		"two seconds of standing there raised corruption (%.3f -> %.3f)" % [before, after_two])

	_step(enemy, 0.1, 20)
	var after_four: float = float(mire_grid.call(&"corruption_at", SITE))
	check(after_four > after_two,
		"and it keeps going (%.3f -> %.3f) — it does not have to die to do this"
			% [after_two, after_four])

	# The part that breaks every habit the ladder taught: kiting one costs LAND. A Herald walked
	# across your territory corrupts a trail, not a spot.
	var down_range := SITE + Vector3(30.0, 0.0, 0.0)
	check(is_zero_approx(float(mire_grid.call(&"corruption_at", down_range))),
		"ground 30 m away is still clean")
	enemy.global_position = down_range
	_step(enemy, 0.1, 20)
	check(float(mire_grid.call(&"corruption_at", down_range)) > 0.0,
		"walking it somewhere else corrupts THERE too — a trail, not a spot")

	# A corpse stops. The aura is what the creature does, not what its body is.
	var grave := SITE + Vector3(0.0, 0.0, 60.0)
	enemy.global_position = grave
	enemy.call(&"host_apply_damage", int(def.get(&"max_health")) * 4, 1)
	await process_frame
	check(not bool(enemy.call(&"is_alive")), "it dies")
	var at_death: float = float(mire_grid.call(&"corruption_at", grave))
	_step(enemy, 0.1, 30)
	check(is_equal_approx(float(mire_grid.call(&"corruption_at", grave)), at_death),
		"three seconds of corpse added nothing more (%.3f)" % at_death)

	# And nothing about any of this touched the kinds with no aura authored.
	var clean := Vector3(-200.0, 0.0, -200.0)
	var crawler: Node3D = world.call("host_spawn", &"crawler", clean)
	if crawler != null:
		await process_frame
		crawler.global_position = clean
		var crawler_before: float = float(mire_grid.call(&"corruption_at", clean))
		_step(crawler, 0.1, 40)
		check(is_equal_approx(float(mire_grid.call(&"corruption_at", clean)), crawler_before),
			"a kind with no aura authored never touches the grid")

	world.call("host_despawn_all")


# ── harness ───────────────────────────────────────────────────────────────────────────────────────


func _step(enemy: Node3D, delta: float, times: int = 1) -> void:
	for _index: int in times:
		if not is_instance_valid(enemy) or not enemy.is_inside_tree():
			return
		enemy.call("_physics_process", delta)


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
	print("\nENEMY_MIRE_HERALD_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)
