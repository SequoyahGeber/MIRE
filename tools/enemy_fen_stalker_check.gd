extends SceneTree

## Headless verification for the enemy ladder's tier 2, the Fen Stalker (docs/ENEMIES.md §4).
##
## Run with:
##   .agent/bin/agent godot --headless --script tools/enemy_fen_stalker_check.gd
##
## Same three-part shape as `tools/enemy_peatling_check.gd` — import, facing, mechanic — with the
## mechanic half doing considerably more work, because tier 2's identity is behaviour rather than a
## world mutation:
##
## 1. THE IMPORT. Skeleton, skinned mesh, all six clips under their engine-side names, exactly two
##    looping, fragments static.
##
## 2. WHICH WAY IT FACES (F-039), measured off the mesh rather than remembered — here the
##    discriminator is the BILL, which reaches nearly half a metre past everything else.
##
## 3. THE AMBUSH, end to end, driven through the real state machine: the first committed strike is
##    multiplied, the second is not, a strike DODGED still spends it, and losing the target re-arms
##    it. Plus the stat identity the tier depends on and would silently lose in a balance pass —
##    faster than a walk and slower than a sprint, a real blind side, and a nonzero lunge.

const EXPORTS := "res://assets/enemies/exports/"
const EXPECTED_BONES := 19
const EXPECTED_STATIC := [
	"enemy_fen_stalker_fragment_plume",
	"enemy_fen_stalker_fragment_bill",
]
const EXPECTED_CLIPS := {
	"idle": true,
	"locomotion": true,
	"attack_tell": false,
	"attack": false,
	"hit": false,
	"death": false,
}

## `entities/player/player_controller.gd`'s own numbers, restated so the assertions below say what
## they mean. If these ever move, this check should be the thing that notices the tier's identity
## moved with them.
const PLAYER_WALK_SPEED: float = 4.0
const PLAYER_SPRINT_SPEED: float = 6.0

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
	await _check_ambush()
	finish()


# ── 1. the import ─────────────────────────────────────────────────────────────────────────────────


func _check_import() -> void:
	print("== the Fen Stalker imports as a rigged, animated scene ==")
	var scene := load(EXPORTS + "enemy_fen_stalker.glb") as PackedScene
	check(scene != null, "enemy_fen_stalker.glb imported as a PackedScene")
	if scene == null:
		return
	var stalker: Node = scene.instantiate()

	var skeleton := _find_node(stalker, "Skeleton3D") as Skeleton3D
	check(skeleton != null, "it imported rigged")
	if skeleton != null:
		check(skeleton.get_bone_count() == EXPECTED_BONES,
			"skeleton has %d bones (expected %d)" % [skeleton.get_bone_count(), EXPECTED_BONES])
		# The neck is three bones plus a head and a bill, and that is not decoration: two bones can
		# only make a V, and a V reads as a broken neck. The S is the creature.
		var neck_bones: int = 0
		for index: int in skeleton.get_bone_count():
			if skeleton.get_bone_name(index).begins_with("neck_"):
				neck_bones += 1
		check(neck_bones >= 3, "the neck is %d bones, enough to form an S" % neck_bones)

	var mesh_instance := _find_node(stalker, "MeshInstance3D") as MeshInstance3D
	check(mesh_instance != null and mesh_instance.skin != null, "the mesh is skinned to the skeleton")

	var player := _find_node(stalker, "AnimationPlayer") as AnimationPlayer
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

		# The contract every clip in this family is authored to: never longer than the EnemyDef
		# window it plays under, or `Enemy` cuts it mid-motion and the next clip starts from a pose
		# this one never reached. Asserted against the authored `.tres`, not against a constant.
		var def: Resource = load("res://content/enemies/fen_stalker.tres")
		if def != null:
			check(player.get_animation("attack_tell").length <= float(def.get(&"attack_tell_seconds")) + 0.001,
				"the tell clip fits inside attack_tell_seconds")
			check(player.get_animation("attack").length <= float(def.get(&"attack_seconds")) + 0.001,
				"the strike clip fits inside attack_seconds")

	stalker.free()

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
	var scene := load(EXPORTS + "enemy_fen_stalker.glb") as PackedScene
	if scene == null:
		return
	var stalker: Node = scene.instantiate()
	var mesh_instance := _find_node(stalker, "MeshInstance3D") as MeshInstance3D
	if mesh_instance == null or mesh_instance.mesh == null:
		check(false, "no mesh to measure")
		stalker.free()
		return

	# The bill. It reaches further from the body's centre line than anything else on the creature by
	# a wide margin, which makes "where is the bill?" the cleanest possible answer to "which way does
	# this face?". Every surface, because a multi-material mesh has one surface per material.
	var reach_positive: float = 0.0
	var reach_negative: float = 0.0
	for surface: int in mesh_instance.mesh.get_surface_count():
		for vertex: Vector3 in mesh_instance.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
			reach_positive = maxf(reach_positive, vertex.z)
			reach_negative = maxf(reach_negative, -vertex.z)
	stalker.free()

	var bill_on_positive_z: bool = reach_positive > reach_negative
	check(bill_on_positive_z,
		"the bill reaches further along +Z (%.3f m) than anything does along -Z (%.3f m)"
			% [reach_positive, reach_negative])

	var def: Resource = load("res://content/enemies/fen_stalker.tres")
	check(def != null, "fen_stalker.tres loads")
	if def == null:
		return
	var yaw: float = float(def.get(&"model_yaw_offset_degrees"))
	check(is_equal_approx(absf(yaw), 180.0) == bill_on_positive_z,
		"model_yaw_offset_degrees is %.0f, which points the bill down Godot's -Z" % yaw)


# ── 3. the ambush, and the stats the tier is made of ──────────────────────────────────────────────


func _check_ambush() -> void:
	print("\n== tier 2's identity: the stats it is made of ==")
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	check(world != null, "EnemyWorld autoload exists")
	if world == null:
		return
	check(bool(world.call("has_def", &"fen_stalker")), "the Fen Stalker definition is registered")
	var def: Resource = world.call("get_def", &"fen_stalker")
	if def == null:
		return
	check((def.call("validation_errors") as PackedStringArray).is_empty(),
		"the authored definition validates")

	# The one number the whole tier turns on. Above a walk, so you cannot stroll away from it; below
	# a sprint, so running is still an answer that costs you something. A balance pass that moves it
	# out of that band has not tuned this enemy, it has replaced it.
	var speed: float = float(def.get(&"move_speed"))
	check(speed > PLAYER_WALK_SPEED and speed < PLAYER_SPRINT_SPEED,
		"move_speed %.1f is between player walk (%.1f) and sprint (%.1f)"
			% [speed, PLAYER_WALK_SPEED, PLAYER_SPRINT_SPEED])
	# The first kind in the project to use F-240's lunge, which is the only thing that can make a
	# telegraph un-backpedal-able (docs/SPECS.md §5.2 is explicit that a bigger attack_range_m
	# cannot).
	check(float(def.get(&"lunge_speed_m_s")) > 0.0,
		"it closes ground during its own tell (lunge_speed_m_s = %.1f)" % float(def.get(&"lunge_speed_m_s")))
	check(float(def.get(&"vision_angle_deg")) < 360.0,
		"it has a real blind side (%.0f degree cone)" % float(def.get(&"vision_angle_deg")))
	check(float(def.get(&"ambush_damage_multiplier")) > 1.0, "and an ambush opener")
	var crawler: Resource = world.call("get_def", &"crawler")
	if crawler != null:
		check(float(def.get(&"turn_speed_rad")) < float(crawler.get(&"turn_speed_rad")),
			"it turns slower than the crawler, so circling it is real counterplay")

	print("\n== the ambush: the first committed strike, and only the first ==")
	EVENT_BUS.subscribe_enemy_attack_landed(_on_attack_landed)

	var player := Node3D.new()
	player.name = "1"
	player.add_to_group(&"players")
	root.add_child(player)
	player.global_position = Vector3.ZERO

	var enemy: Node3D = world.call("host_spawn", &"fen_stalker", Vector3(0.0, 0.0, -2.0))
	check(enemy != null, "the host spawns a Fen Stalker")
	if enemy == null:
		return
	await process_frame

	var base_damage: int = int(def.get(&"attack_damage"))
	var expected_opener: int = roundi(float(base_damage) * float(def.get(&"ambush_damage_multiplier")))

	check(_swing(enemy, player), "it winds up and strikes")
	check(attacks.size() == 1 and int(attacks[0].get("damage", 0)) == expected_opener,
		"the opening strike out of the freeze deals %d, not %d" % [expected_opener, base_damage])

	check(_swing(enemy, player), "it winds up again")
	check(attacks.size() == 1 and int(attacks[0].get("damage", 0)) == base_damage,
		"every strike after the opener deals the plain %d" % base_damage)

	# Losing the target puts it back to being scenery, and the next person to walk into it is being
	# surprised for the first time exactly as much as the last one was.
	player.global_position = enemy.global_position + Vector3(0.0, 0.0, 900.0)
	# Stepped until it lets go rather than for a fixed count: the enemy is in RECOVER when the player
	# leaves, and recovery does not re-resolve the target — so a handful of steps runs out before the
	# recovery does, and the drop that was going to happen anyway has not happened yet.
	var released: bool = false
	for _index: int in 200:
		_step(enemy, 0.1)
		if int(enemy.call("target_peer")) == 0:
			released = true
			break
	check(released, "a target far outside deaggro is dropped")
	check(_swing(enemy, player), "it acquires and strikes a third time")
	check(attacks.size() == 1 and int(attacks[0].get("damage", 0)) == expected_opener,
		"losing the target re-armed the ambush")

	# And the reward for reading the tell: a dodged opener is a SPENT opener.
	print("\n== a dodged opener is a spent opener ==")
	var fresh: Node3D = world.call("host_spawn", &"fen_stalker", Vector3(200.0, 0.0, 200.0))
	if fresh != null:
		await process_frame
		player.global_position = fresh.global_position - fresh.global_transform.basis.z * 1.2
		check(_step_until_state(fresh, 2, 0.05, 400), "the fresh one telegraphs")
		attacks.clear()
		# Out of reach before the tell ends — the whole point of a half-second telegraph.
		player.global_position = fresh.global_position - fresh.global_transform.basis.z * 30.0
		_step(fresh, 0.1, 12)
		check(attacks.is_empty(), "leaving during the tell beats the strike")
		check(_swing(fresh, player), "it commits again")
		check(attacks.size() == 1 and int(attacks[0].get("damage", 0)) == base_damage,
			"and the strike that was dodged still spent the ambush — the next one is plain %d"
				% base_damage)

	EVENT_BUS.unsubscribe_enemy_attack_landed(_on_attack_landed)
	world.call("host_despawn_all")


## Puts the player in reach, steps until the enemy commits, and lets the strike resolve. Clears
## `attacks` at the moment of the wind-up, so whatever is in it afterwards is this swing's.
func _swing(enemy: Node3D, player: Node3D) -> bool:
	# IN FRONT of it, not merely near it. This kind has a 120-degree vision cone
	# (`vision_angle_deg`), so a player standing behind a freshly spawned one is
	# genuinely invisible to it and it will never acquire — which is the blind
	# side working, not the check failing. A body's forward is -Z.
	player.global_position = enemy.global_position - enemy.global_transform.basis.z * 1.2
	# Step until it telegraphs rather than counting frames: the swing and recovery lengths are
	# tunable numbers and a fixed count would break the moment somebody tunes them (F-111).
	if not _step_until_state(enemy, 2, 0.05, 400):
		return false
	attacks.clear()
	# Comfortably past the tell, and the player is standing still inside reach, so the hit lands.
	_step(enemy, 0.1, 10)
	return true


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
	print("\nENEMY_FEN_STALKER_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)
