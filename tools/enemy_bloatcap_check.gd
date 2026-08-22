extends SceneTree

## Headless verification for the enemy ladder's tier 4, the Bloatcap (docs/ENEMIES.md §6).
##
## Run with:
##   .agent/bin/agent godot --headless --script tools/enemy_bloatcap_check.gd
##
## Import and facing as for tiers 1-3, then the burst — which is the first attack in the project that
## hits somebody who was never the target, so it is checked from the outside in:
##
##   · everybody inside the radius takes it, including a player the enemy never acquired
##   · everybody outside it takes nothing, and the boundary falls where the `.tres` says
##   · height does not save you — the burst is measured horizontally on purpose
##   · dying bursts again for the authored fraction, which is why killing one in melee is a mistake
##   · a kind with no burst authored still resolves exactly one single-target hit

const EXPORTS := "res://assets/enemies/exports/"
const EXPECTED_BONES := 12
const EXPECTED_STATIC := [
	"enemy_bloatcap_fragment_husk",
	"enemy_bloatcap_fragment_gleba",
]
const EXPECTED_CLIPS := {
	"idle": true,
	"locomotion": true,
	"attack_tell": false,
	"attack": false,
	"hit": false,
	"death": false,
}

const EVENT_BUS := preload("res://core/events/event_bus.gd")

var failures: int = 0
var attacks: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	_check_import()
	_check_facing()
	await _check_burst()
	finish()


# ── 1. the import ─────────────────────────────────────────────────────────────────────────────────


func _check_import() -> void:
	print("== the Bloatcap imports as a rigged, animated scene ==")
	var scene := load(EXPORTS + "enemy_bloatcap.glb") as PackedScene
	check(scene != null, "enemy_bloatcap.glb imported as a PackedScene")
	if scene == null:
		return
	var bloatcap: Node = scene.instantiate()

	var skeleton := _find_node(bloatcap, "Skeleton3D") as Skeleton3D
	check(skeleton != null, "it imported rigged")
	if skeleton != null:
		check(skeleton.get_bone_count() == EXPECTED_BONES,
			"skeleton has %d bones (expected %d)" % [skeleton.get_bone_count(), EXPECTED_BONES])
		var has_ostiole: bool = false
		for index: int in skeleton.get_bone_count():
			if skeleton.get_bone_name(index) == "ostiole":
				has_ostiole = true
		# The ostiole is a bone rather than geometry welded to the sac because the whole telegraph is
		# it dilating. If it ever stops being its own bone, the tell stops existing.
		check(has_ostiole, "the ostiole is its own bone, so it can dilate")

	var mesh_instance := _find_node(bloatcap, "MeshInstance3D") as MeshInstance3D
	check(mesh_instance != null and mesh_instance.skin != null, "the mesh is skinned to the skeleton")

	var player := _find_node(bloatcap, "AnimationPlayer") as AnimationPlayer
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

		var def: Resource = load("res://content/enemies/bloatcap.tres")
		if def != null:
			check(player.get_animation("attack_tell").length <= float(def.get(&"attack_tell_seconds")) + 0.001,
				"the tell clip (%.3f s) fits inside attack_tell_seconds"
					% player.get_animation("attack_tell").length)
			check(player.get_animation("attack").length <= float(def.get(&"attack_seconds")) + 0.001,
				"the strike clip (%.3f s) fits inside attack_seconds"
					% player.get_animation("attack").length)

	bloatcap.free()

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
	print("\n== a creature with no front still has to agree with its own .tres ==")
	# This one is radially symmetric on purpose — it has no face, no limbs to lead with, and a ring
	# of eyes instead of a pair. So there is nothing to measure a facing against, and the honest
	# assertion is the opposite of tiers 1-3's: that the model really IS symmetric, which is what
	# makes `vision_angle_deg = 360` an accurate description of it rather than a shortcut.
	var scene := load(EXPORTS + "enemy_bloatcap.glb") as PackedScene
	if scene == null:
		return
	var bloatcap: Node = scene.instantiate()
	var mesh_instance := _find_node(bloatcap, "MeshInstance3D") as MeshInstance3D
	if mesh_instance == null or mesh_instance.mesh == null:
		check(false, "no mesh to measure")
		bloatcap.free()
		return
	var reach_front: float = 0.0
	var reach_back: float = 0.0
	for surface: int in mesh_instance.mesh.get_surface_count():
		for vertex: Vector3 in mesh_instance.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
			reach_front = maxf(reach_front, vertex.z)
			reach_back = maxf(reach_back, -vertex.z)
	bloatcap.free()
	check(absf(reach_front - reach_back) < 0.05,
		"front and back reach match within 5 cm (%.3f vs %.3f) — it genuinely has no front"
			% [reach_front, reach_back])

	var def: Resource = load("res://content/enemies/bloatcap.tres")
	check(def != null and is_equal_approx(float(def.get(&"vision_angle_deg")), 360.0),
		"and its vision is authored as 360 degrees to match")


# ── 3. the burst ──────────────────────────────────────────────────────────────────────────────────


func _check_burst() -> void:
	print("\n== tier 4's identity: the stats it is made of ==")
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	check(world != null, "EnemyWorld autoload exists")
	if world == null:
		return
	check(bool(world.call("has_def", &"bloatcap")), "the Bloatcap definition is registered")
	var def: Resource = world.call("get_def", &"bloatcap")
	if def == null:
		return
	check((def.call("validation_errors") as PackedStringArray).is_empty(),
		"the authored definition validates")
	var radius: float = float(def.get(&"burst_radius_m"))
	check(radius > 0.0, "it is authored to burst")
	check(float(def.get(&"death_burst_fraction")) > 0.0, "and to burst again when it dies")
	# The tell has to be the longest in the roster: a burst does not care which way you dodge, only
	# how far you got, so the warning has to be long enough to actually cover the distance.
	check(float(def.get(&"attack_tell_seconds")) >= 0.6,
		"its telegraph (%.2f s) is long enough to outrun" % float(def.get(&"attack_tell_seconds")))
	check(float(def.get(&"attack_range_m")) <= radius,
		"it commits from inside its own burst radius, so a committed burst always reaches its target")

	print("\n== the burst: everyone in the radius, nobody outside it ==")
	EVENT_BUS.subscribe_enemy_attack_landed(_on_attack_landed)

	var origin := Vector3(500.0, 0.0, 500.0)
	var target := Node3D.new()
	target.name = "1"
	target.add_to_group(&"players")
	root.add_child(target)
	# A SECOND player, standing well inside the radius and never targeted by anything. This is the
	# assertion the whole mechanic exists for: an attack that hits somebody who was not the target.
	var bystander := Node3D.new()
	bystander.name = "2"
	bystander.add_to_group(&"players")
	root.add_child(bystander)
	# A THIRD, just outside it.
	var distant := Node3D.new()
	distant.name = "3"
	distant.add_to_group(&"players")
	root.add_child(distant)

	var enemy: Node3D = world.call("host_spawn", &"bloatcap", origin)
	check(enemy != null, "the host spawns a Bloatcap")
	if enemy == null:
		return
	await process_frame
	enemy.global_position = origin

	target.global_position = origin + Vector3(0.0, 0.0, -1.5)
	bystander.global_position = origin + Vector3(radius * 0.75, 0.0, 0.0)
	distant.global_position = origin + Vector3(radius + 4.0, 0.0, 0.0)

	attacks.clear()
	check(_step_until_state(enemy, 2, 0.05, 400), "it winds up")
	attacks.clear()
	_step(enemy, 0.1, 14)

	var damage: int = int(def.get(&"attack_damage"))
	check(attacks.size() == 2, "the burst produced %d hits (expected 2 — target and bystander)"
		% attacks.size())
	check(_hit_peer(1) == damage, "the target took the full %d" % damage)
	check(_hit_peer(2) == damage, "the bystander it never targeted took the same %d" % damage)
	check(_hit_peer(3) == 0, "the player outside the radius took nothing")

	# Height must not save you. Measured horizontally, like every other distance decision this class
	# makes — a burst you escape by standing on a rock is a burst nobody can reason about.
	bystander.global_position = origin + Vector3(radius * 0.75, 6.0, 0.0)
	attacks.clear()
	check(_step_until_state(enemy, 2, 0.05, 400), "it winds up again")
	attacks.clear()
	_step(enemy, 0.1, 14)
	check(_hit_peer(2) == damage, "standing six metres above it is not standing outside it")

	# Killing it in melee is the mistake the whole tier is built to teach.
	print("\n== and it bursts again when it dies ==")
	bystander.global_position = origin + Vector3(radius * 0.5, 0.0, 0.0)
	distant.global_position = origin + Vector3(radius + 4.0, 0.0, 0.0)
	attacks.clear()
	enemy.call(&"host_apply_damage", int(def.get(&"max_health")) * 4, 1)
	await process_frame
	var expected_death: int = maxi(roundi(float(damage) * float(def.get(&"death_burst_fraction"))), 1)
	check(not bool(enemy.call(&"is_alive")), "it dies")
	check(_hit_peer(1) == expected_death,
		"the killer standing next to it took %d — a fraction of %d, not nothing"
			% [expected_death, damage])
	check(_hit_peer(2) == expected_death, "so did the other player inside the radius")
	check(_hit_peer(3) == 0, "the one outside it still took nothing")

	# And nothing about any of this changed the kinds that do not burst.
	print("\n== a kind with no burst authored is untouched ==")
	var crawler: Node3D = world.call("host_spawn", &"crawler", Vector3(560.0, 0.0, 500.0))
	if crawler != null:
		await process_frame
		crawler.global_position = Vector3(560.0, 0.0, 500.0)
		target.global_position = crawler.global_position + Vector3(0.0, 0.0, -1.0)
		bystander.global_position = crawler.global_position + Vector3(1.5, 0.0, 0.0)
		attacks.clear()
		check(_step_until_state(crawler, 2, 0.05, 400), "the crawler winds up")
		attacks.clear()
		_step(crawler, 0.1, 12)
		check(attacks.size() == 1, "it resolved exactly one single-target hit, not an area one")
		check(_hit_peer(2) == 0, "the bystander standing right beside it took nothing")
		attacks.clear()
		crawler.call(&"host_apply_damage", 999, 1)
		await process_frame
		check(attacks.is_empty(), "and dying cost nobody anything")

	EVENT_BUS.unsubscribe_enemy_attack_landed(_on_attack_landed)
	world.call("host_despawn_all")


## Total damage recorded against `peer_id` since the last `attacks.clear()`.
func _hit_peer(peer_id: int) -> int:
	var total: int = 0
	for record: Dictionary in attacks:
		if int(record.get("peer_id", 0)) == peer_id:
			total += int(record.get("damage", 0))
	return total


# ── harness ───────────────────────────────────────────────────────────────────────────────────────


func _step(enemy: Node3D, delta: float, times: int = 1) -> void:
	for _index: int in times:
		if not is_instance_valid(enemy) or not enemy.is_inside_tree():
			return
		enemy.call("_physics_process", delta)


func _step_until_state(enemy: Node3D, wanted: int, delta: float, max_steps: int) -> bool:
	for _index: int in max_steps:
		if not is_instance_valid(enemy) or not enemy.is_inside_tree():
			return false
		if int(enemy.get("state")) == wanted:
			return true
		enemy.call("_physics_process", delta)
	return int(enemy.get("state")) == wanted


func _on_attack_landed(_enemy_id: StringName, peer_id: int, damage: int, position: Vector3) -> void:
	attacks.append({"peer_id": peer_id, "damage": damage, "position": position})


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
	print("\nENEMY_BLOATCAP_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)
