extends SceneTree

## Headless verification for the enemy ladder's tier 3, the Bog Bulwark (docs/ENEMIES.md §5).
##
## Run with:
##   .agent/bin/agent godot --headless --script tools/enemy_bog_bulwark_check.gd
##
## Same three-part shape as tiers 1 and 2 — import, facing, mechanic:
##
## 1. THE IMPORT. Skeleton, skinned mesh, six clips under their engine-side names, exactly two
##    looping, both timed clips inside their authored `EnemyDef` windows, fragments static.
##
## 2. WHICH WAY IT FACES (F-039), measured off the mesh. The discriminator here is the beak.
##
## 3. THE ARMOUR, from every side that matters: a hit from the front is reduced, the same hit from
##    behind is not, the boundary of the arc falls where the `.tres` says it does, a hit with no
##    locatable instigator is never reduced (armour must fail OPEN), and a deflected hit does not
##    bump `hit_counter` — which is the whole feedback channel for "you are hitting the wrong end".

const EXPORTS := "res://assets/enemies/exports/"
const EXPECTED_BONES := 20
const EXPECTED_STATIC := [
	"enemy_bog_bulwark_fragment_scute",
	"enemy_bog_bulwark_fragment_beak",
]
const EXPECTED_CLIPS := {
	"idle": true,
	"locomotion": true,
	"attack_tell": false,
	"attack": false,
	"hit": false,
	"death": false,
}

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	_check_import()
	_check_facing()
	await _check_armour()
	finish()


# ── 1. the import ─────────────────────────────────────────────────────────────────────────────────


func _check_import() -> void:
	print("== the Bog Bulwark imports as a rigged, animated scene ==")
	var scene := load(EXPORTS + "enemy_bog_bulwark.glb") as PackedScene
	check(scene != null, "enemy_bog_bulwark.glb imported as a PackedScene")
	if scene == null:
		return
	var bulwark: Node = scene.instantiate()

	var skeleton := _find_node(bulwark, "Skeleton3D") as Skeleton3D
	check(skeleton != null, "it imported rigged")
	if skeleton != null:
		check(skeleton.get_bone_count() == EXPECTED_BONES,
			"skeleton has %d bones (expected %d)" % [skeleton.get_bone_count(), EXPECTED_BONES])
		# A turtle's vertebrae are fused to its carapace: the shell IS the spine. So there is exactly
		# one body bone and no spine chain, and that is why this creature cannot be staggered.
		var spine_bones: int = 0
		for index: int in skeleton.get_bone_count():
			if skeleton.get_bone_name(index).begins_with("spine"):
				spine_bones += 1
		check(spine_bones == 0, "there is no spine chain — the shell is the skeleton")

	var mesh_instance := _find_node(bulwark, "MeshInstance3D") as MeshInstance3D
	check(mesh_instance != null and mesh_instance.skin != null, "the mesh is skinned to the skeleton")

	var player := _find_node(bulwark, "AnimationPlayer") as AnimationPlayer
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

		var def: Resource = load("res://content/enemies/bog_bulwark.tres")
		if def != null:
			check(player.get_animation("attack_tell").length <= float(def.get(&"attack_tell_seconds")) + 0.001,
				"the tell clip (%.3f s) fits inside attack_tell_seconds"
					% player.get_animation("attack_tell").length)
			check(player.get_animation("attack").length <= float(def.get(&"attack_seconds")) + 0.001,
				"the strike clip (%.3f s) fits inside attack_seconds"
					% player.get_animation("attack").length)

	bulwark.free()

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
	var scene := load(EXPORTS + "enemy_bog_bulwark.glb") as PackedScene
	if scene == null:
		return
	var bulwark: Node = scene.instantiate()
	var mesh_instance := _find_node(bulwark, "MeshInstance3D") as MeshInstance3D
	if mesh_instance == null or mesh_instance.mesh == null:
		check(false, "no mesh to measure")
		bulwark.free()
		return

	# Head end against tail end. Both stick out past the shell, so the discriminator is not reach but
	# BULK: the head end carries a skull, a jaw and two beaks, and the tail end tapers to a point.
	# Counted over every surface, because a multi-material mesh has one surface per material.
	var front_bulk: int = 0
	var back_bulk: int = 0
	for surface: int in mesh_instance.mesh.get_surface_count():
		for vertex: Vector3 in mesh_instance.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
			if vertex.z > 1.0:
				front_bulk += 1
			elif vertex.z < -1.0:
				back_bulk += 1
	bulwark.free()

	var head_on_positive_z: bool = front_bulk > back_bulk
	check(head_on_positive_z,
		"the head end carries more geometry past +1 m (%d verts) than the tail end past -1 m (%d)"
			% [front_bulk, back_bulk])

	var def: Resource = load("res://content/enemies/bog_bulwark.tres")
	check(def != null, "bog_bulwark.tres loads")
	if def == null:
		return
	var yaw: float = float(def.get(&"model_yaw_offset_degrees"))
	check(is_equal_approx(absf(yaw), 180.0) == head_on_positive_z,
		"model_yaw_offset_degrees is %.0f, which points the head down Godot's -Z" % yaw)


# ── 3. the armour ─────────────────────────────────────────────────────────────────────────────────


func _check_armour() -> void:
	print("\n== tier 3's identity: the stats it is made of ==")
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	check(world != null, "EnemyWorld autoload exists")
	if world == null:
		return
	check(bool(world.call("has_def", &"bog_bulwark")), "the Bog Bulwark definition is registered")
	var def: Resource = world.call("get_def", &"bog_bulwark")
	if def == null:
		return
	check((def.call("validation_errors") as PackedStringArray).is_empty(),
		"the authored definition validates")
	check(float(def.get(&"armor_arc_degrees")) > 0.0 and float(def.get(&"armor_damage_multiplier")) < 1.0,
		"it is authored with directional armour")
	# It never lets go. Slow is only fair if leaving does not solve it — a Bulwark that gave up would
	# be a Bulwark you walk away from once and never fight.
	check(float(def.get(&"deaggro_radius_m")) >= 100.0,
		"its deaggro radius (%.0f m) is effectively the whole island" % float(def.get(&"deaggro_radius_m")))
	check(float(def.get(&"turn_speed_rad")) <= 1.6,
		"it turns slowly enough that getting behind it is achievable")
	check(int(def.get(&"max_concurrent_attackers")) == 1, "only ever one of them commits at a time")
	check(float(def.get(&"armor_damage_multiplier")) > 0.0,
		"armour never reduces a hit to nothing — that reads as a bug, not as armour")

	print("\n== the armour: which end of it you are standing at ==")
	var player := Node3D.new()
	player.name = "1"
	player.add_to_group(&"players")
	root.add_child(player)

	var enemy: Node3D = world.call("host_spawn", &"bog_bulwark", Vector3(300.0, 0.0, 300.0))
	check(enemy != null, "the host spawns a Bog Bulwark")
	if enemy == null:
		return
	await process_frame
	# Pinned rather than inherited: every assertion below is about an ANGLE, and an enemy that has
	# turned to face its target between two of them would quietly answer a different question.
	enemy.global_rotation = Vector3.ZERO
	var forward: Vector3 = -enemy.global_transform.basis.z
	var multiplier: float = float(def.get(&"armor_damage_multiplier"))
	var arc: float = float(def.get(&"armor_arc_degrees"))
	var blow: int = 40
	var reduced: int = maxi(roundi(float(blow) * multiplier), 1)

	# Dead ahead.
	player.global_position = enemy.global_position + forward * 3.0
	var before: int = int(enemy.get("health"))
	var hits_before: int = int(enemy.get("hit_counter"))
	enemy.call(&"host_apply_damage", blow, 1)
	check(before - int(enemy.get("health")) == reduced,
		"a hit from dead ahead lands for %d of %d" % [reduced, blow])
	check(int(enemy.get("hit_counter")) == hits_before,
		"and does not bump hit_counter — no flash, no flinch, which IS the feedback")

	# Dead behind.
	player.global_position = enemy.global_position - forward * 3.0
	before = int(enemy.get("health"))
	hits_before = int(enemy.get("hit_counter"))
	enemy.call(&"host_apply_damage", blow, 1)
	check(before - int(enemy.get("health")) == blow,
		"the same hit from behind lands for all %d" % blow)
	check(int(enemy.get("hit_counter")) == hits_before + 1,
		"and reacts normally")

	# Just outside the arc, and just inside it. The boundary is the mechanic: a player who has
	# learnt "get round the side" has to be right about where the side starts.
	var outside := Vector3(forward).rotated(Vector3.UP, deg_to_rad(arc * 0.5 + 8.0))
	player.global_position = enemy.global_position + outside * 3.0
	before = int(enemy.get("health"))
	enemy.call(&"host_apply_damage", blow, 1)
	check(before - int(enemy.get("health")) == blow,
		"a hit from just outside the %.0f degree arc is unreduced" % arc)

	var inside := Vector3(forward).rotated(Vector3.UP, deg_to_rad(arc * 0.5 - 8.0))
	player.global_position = enemy.global_position + inside * 3.0
	before = int(enemy.get("health"))
	enemy.call(&"host_apply_damage", blow, 1)
	check(before - int(enemy.get("health")) == reduced,
		"and from just inside it, it is reduced")

	# Armour must fail OPEN. A damage source with no locatable instigator is not standing anywhere,
	# and silently nullifying it would be the worst kind of bug: invisible, and only on one enemy.
	player.global_position = enemy.global_position + forward * 3.0
	# Topped back up first. Four measured blows have already taken it to within one hit of dead, and
	# a health pool that floors at zero would report a delta of "whatever was left" — which is a true
	# number about the wrong thing, and would have this assertion fail for a reason that has nothing
	# to do with armour.
	enemy.set("health", int(def.get(&"max_health")))
	before = int(enemy.get("health"))
	enemy.call(&"host_apply_damage", blow, 0)
	check(before - int(enemy.get("health")) == blow,
		"damage with no instigator is never reduced — armour fails open")

	# And nothing about any of this touched the kinds that have no armour authored.
	var crawler: Node3D = world.call("host_spawn", &"crawler", Vector3(320.0, 0.0, 300.0))
	if crawler != null:
		await process_frame
		crawler.global_rotation = Vector3.ZERO
		player.global_position = crawler.global_position - crawler.global_transform.basis.z * 1.0
		before = int(crawler.get("health"))
		hits_before = int(crawler.get("hit_counter"))
		crawler.call(&"host_apply_damage", 5, 1)
		check(before - int(crawler.get("health")) == 5,
			"a kind with no armour authored takes a frontal hit in full")
		check(int(crawler.get("hit_counter")) == hits_before + 1, "and still flinches")

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
	print("\nENEMY_BOG_BULWARK_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)
