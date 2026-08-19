extends SceneTree

## Focused offline proof for task 5.3: the draw/flight/recovery state machine is committed and
## non-cancellable, the host simulates the arrow's own flight and resolves it against its own world,
## ammo is consumed on the host only when the arrow actually leaves the bow, a target out of range or
## behind a wall is a miss, PvP never lands, and hitstop/screenshake/impact sound are client-local
## consequences of a host-confirmed connect — same shape as tools/combat_check.gd (task 2.8).

const PLAYER_CAMERA_SCRIPT := preload("res://entities/player/player_camera.gd")

var failures: int = 0
var landed: Array[Dictionary] = []
var missed: Array[Dictionary] = []
var rejections: Array[Dictionary] = []


## Minimal implementor of the damage seam. Asserts the contract RangedCombatService relies on without
## dragging a definition or a respawn clock into a flight test.
class TestTarget extends Node3D:
	var damage_taken: int = 0
	var last_peer_id: int = -1
	var hit_count: int = 0

	func _ready() -> void:
		add_to_group(&"damageable")
		# A real collider: the host resolves ranged hits with a physics raycast, unlike melee's
		# distance/arc test, so a damageable target needs a real body to be reachable at all. Centred
		# at roughly eye height (CombatAim.EYE_HEIGHT_M) with a generous radius, matching where a
		# level shot actually flies — the node's own origin (ground level) is not in the flight path.
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = 1.0
		shape.shape = sphere
		shape.position.y = 1.0
		body.add_child(shape)
		add_child(body)

	func host_apply_damage(amount: int, instigator_peer_id: int) -> bool:
		damage_taken += amount
		last_peer_id = instigator_peer_id
		hit_count += 1
		return true


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	var ranged: Node = root.get_node_or_null(^"RangedCombatService")
	var combat: Node = root.get_node_or_null(^"CombatService")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	check(registry != null, "Registry autoload exists")
	check(ranged != null, "RangedCombatService autoload exists")
	check(combat != null, "CombatService autoload exists")
	check(inventory != null, "InventoryService autoload exists")
	if registry == null or ranged == null or combat == null or inventory == null:
		finish()
		return
	ranged.get("shot_landed").connect(_on_landed)
	ranged.get("shot_missed").connect(_on_missed)
	ranged.get("shot_rejected").connect(_on_rejected)

	# ── content ───────────────────────────────────────────────────────────────────────────────────
	check(bool(registry.call("has_ranged_weapon", &"short_bow")), "short bow is registered")
	var bow: RangedWeaponDef = registry.call("get_ranged_weapon", &"short_bow") as RangedWeaponDef
	check(bow != null and bow.validation_errors().is_empty(), "the authored bow validates")
	check(not bool(registry.call("has_ranged_weapon", &"log")), "a plain resource item has no bow")
	check(bow.ammo_item_id == &"arrow", "the short bow fires arrows")

	# ── world ─────────────────────────────────────────────────────────────────────────────────────
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	var ground_shape := CollisionShape3D.new()
	var ground_box := BoxShape3D.new()
	ground_box.size = Vector3(200.0, 1.0, 200.0)
	ground_shape.shape = ground_box
	ground_shape.position = Vector3(0.0, -50.5, 0.0)
	ground.add_child(ground_shape)
	root.add_child(ground)

	var player := Node3D.new()
	player.name = "RangedCheckPlayer"
	player.add_to_group(&"players")
	root.add_child(player)
	var pivot: Node3D = PLAYER_CAMERA_SCRIPT.new()
	pivot.name = "CameraPivot"
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	pivot.add_child(camera)
	player.add_child(pivot)
	await process_frame
	pivot.call("set_active", true)

	# Straight ahead is -Z, well inside the bow's 60 m range and the raycast's mask.
	var target := TestTarget.new()
	target.name = "AheadTarget"
	target.position = Vector3(0.0, 0.0, -6.0)
	root.add_child(target)
	# A wall placed between shooter and a second target — the arrow should stop there, not pass
	# through, proving the raycast (not a distance test) actually blocks flight.
	var wall := StaticBody3D.new()
	wall.name = "Wall"
	wall.collision_layer = 1
	var wall_shape := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3(6.0, 4.0, 0.3)
	wall_shape.shape = wall_box
	wall.add_child(wall_shape)
	wall.position = Vector3(0.0, 1.0, -20.0)
	root.add_child(wall)
	var behind_wall := TestTarget.new()
	behind_wall.name = "BehindWallTarget"
	behind_wall.position = Vector3(0.0, 0.0, -40.0)
	root.add_child(behind_wall)
	await process_frame

	# ── held weapon ───────────────────────────────────────────────────────────────────────────────
	check(ranged.call("ranged_weapon_for_hotbar_index", 0) == null, "an empty hotbar slot has no bow")
	check(bool(inventory.call("host_add", 1, &"short_bow", 1)), "host grants the bow")
	check(bool(inventory.call("host_move_stack", 1, 0, 24, 1)), "bow moves into hotbar slot one")
	check(bool(inventory.call("host_add", 1, &"arrow", 3)), "host grants three arrows")
	check((combat.call("weapon_for_hotbar_index", 0) as WeaponDef).item_id == &"unarmed",
		"CombatService's own melee lookup sees no WeaponDef for the bow's slot")
	check((ranged.call("ranged_weapon_for_hotbar_index", 0) as RangedWeaponDef).item_id == &"short_bow",
		"the selected hotbar slot decides the bow")

	# ── dispatch: CombatService.request_attack() hands a ranged slot whole to RangedCombatService ──
	check(int(combat.call("local_phase")) == 0, "melee starts idle")
	check(int(ranged.call("local_phase")) == 0, "ranged starts idle")
	var request_id: int = int(combat.call("request_attack"))
	check(request_id > 0, "the shared attack input returns a shot request id")
	check(int(ranged.call("local_phase")) == 1, "the draw predicts itself immediately (ranged WIND_UP)")
	check(int(combat.call("local_phase")) == 0, "melee's own local phase is untouched by a bow draw")
	check(bool(ranged.call("host_shot_active", 1)), "the host accepted the request and is clocking it")
	check(int(ranged.call("request_shot", 0)) == -1, "a draw in progress cannot be cancelled or recut")
	check(int(combat.call("request_attack")) == -1,
		"melee's own request_attack refuses while a draw is in progress (mutual exclusion)")
	check(int(inventory.call("host_count", 1, &"arrow")) == 3, "nothing is consumed during the draw")
	check(target.hit_count == 0, "nothing is damaged during the draw")

	var connected: bool = await _until(func() -> bool: return target.hit_count > 0, 3.0)
	check(connected, "the host resolves the hit once the arrow's flight reaches the target")
	check(target.damage_taken == bow.damage, "the host applies the authored bow damage")
	check(target.last_peer_id == 1, "damage is attributed to the shooting peer")
	check(int(inventory.call("host_count", 1, &"arrow")) == 2,
		"exactly one arrow is consumed for the shot that fired")
	check(landed.size() == 1, "one connect is announced")
	check(StringName(String(landed[0].get("target_name", ""))) == &"AheadTarget",
		"the announcement names the target the host's raycast actually hit")

	check(float(ranged.call("local_hitstop_remaining")) > 0.0,
		"a connect freezes the shooter's own draw/recovery clock")
	check(float(pivot.call("shake_remaining")) > 0.0, "a connect shakes the shooter's camera")

	var recovered: bool = await _until(func() -> bool: return int(ranged.call("local_phase")) == 0, 3.0)
	check(recovered, "the shot returns to idle after its recovery")

	# ── a wall blocks the flight (raycast, not a distance test) ─────────────────────────────────────
	target.position = Vector3(999.0, 999.0, 999.0)
	await process_frame
	var missed_before: int = missed.size()
	ranged.call("request_shot", 0)
	var wall_stopped: bool = await _until(func() -> bool: return missed.size() > missed_before, 3.0)
	check(wall_stopped, "an arrow that reaches only a wall reports a miss")
	check(behind_wall.hit_count == 0, "a target behind the wall is never reached")
	check(int(inventory.call("host_count", 1, &"arrow")) == 1,
		"the ammo still leaves the quiver even though the shot missed")
	await _until(func() -> bool: return int(ranged.call("local_phase")) == 0, 3.0)

	# ── PvP is cut (DESIGN.md §7): a player-shaped target in the path blocks the arrow like any solid
	# but is never damaged, even though it joins &"damageable" too (so enemy hits still land on it) ──
	wall.queue_free()
	await process_frame
	var other_player := TestTarget.new()
	other_player.name = "OtherPlayer"
	other_player.add_to_group(&"players")
	other_player.position = Vector3(0.0, 0.0, -10.0)
	root.add_child(other_player)
	await process_frame
	check(bool(inventory.call("host_add", 1, &"arrow", 1)), "one more arrow for the PvP case")
	missed_before = missed.size()
	ranged.call("request_shot", 0)
	var pvp_case_done: bool = await _until(func() -> bool: return missed.size() > missed_before, 3.0)
	check(pvp_case_done, "an arrow that reaches only another player still reports a miss")
	check(other_player.hit_count == 0, "the other player's own damage seam is never called")
	check(behind_wall.hit_count == 0,
		"the arrow stops on contact with the other player, same as any solid — it does not pass through")
	await _until(func() -> bool: return int(ranged.call("local_phase")) == 0, 3.0)

	# ── out of ammo is rejected at the draw, before it locks anything ──────────────────────────────
	check(bool(inventory.call("host_remove", 1, &"arrow", 1)), "draining the last arrow for the next case")
	check(int(inventory.call("host_count", 1, &"arrow")) == 0, "peer is now out of ammo")
	var rejections_before: int = rejections.size()
	var out_of_ammo_id: int = int(ranged.call("request_shot", 0))
	check(out_of_ammo_id > 0, "the local draw still predicts (the client does not know ammo state)")
	var out_of_ammo_rejected: bool = await _until(
		func() -> bool: return rejections.size() > rejections_before, 3.0
	)
	check(out_of_ammo_rejected, "the host rejects a draw it cannot fulfil")
	check(String(rejections[rejections.size() - 1].get("detail", "")).contains("ammo"),
		"the rejection says why")
	check(not bool(ranged.call("host_shot_active", 1)), "a rejected draw leaves no host state behind")

	print("RANGED_COMBAT_CHECK landed=%d missed=%d rejected=%d failures=%d" % [
		landed.size(), missed.size(), rejections.size(), failures
	])
	finish()


func _on_landed(peer_id: int, position: Vector3, damage: int, target_name: StringName) -> void:
	landed.append({
		"peer_id": peer_id, "position": position, "damage": damage, "target_name": target_name
	})


func _on_missed(peer_id: int, position: Vector3) -> void:
	missed.append({"peer_id": peer_id, "position": position})


func _on_rejected(request_id: int, detail: String) -> void:
	rejections.append({"request_id": request_id, "detail": detail})


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await process_frame
	return bool(condition.call())


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
