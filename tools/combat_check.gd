extends SceneTree

## Focused offline proof for task 2.8: the swing state machine is committed and non-cancellable, the
## host resolves the hitbox against its own world, arc and reach actually exclude, damage reaches the
## shared `damageable` seam that Harvestable already implements, and hitstop plus screenshake are
## client-local consequences of a host-confirmed connect.

const HARVESTABLE_SCRIPT := preload("res://systems/harvesting/harvestable.gd")
const PLAYER_CAMERA_SCRIPT := preload("res://entities/player/player_camera.gd")

var failures: int = 0
var landed: Array[Dictionary] = []
var missed: int = 0
var rejections: Array[Dictionary] = []


## Minimal implementor of the damage seam. Asserts the contract CombatService relies on without
## dragging a definition, a synchronizer and a respawn clock into a hitbox test.
class TestTarget extends Node3D:
	var damage_taken: int = 0
	var last_peer_id: int = -1
	var hit_count: int = 0
	var accept: bool = true

	func _ready() -> void:
		add_to_group(&"damageable")

	func host_apply_damage(amount: int, instigator_peer_id: int) -> bool:
		if not accept:
			return false
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
	var combat: Node = root.get_node_or_null(^"CombatService")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	check(registry != null, "Registry autoload exists")
	check(combat != null, "CombatService autoload exists")
	check(inventory != null, "InventoryService autoload exists")
	if registry == null or combat == null or inventory == null:
		finish()
		return
	combat.get("attack_landed").connect(_on_landed)
	combat.get("attack_missed").connect(_on_missed)
	combat.get("attack_rejected").connect(_on_rejected)

	# ── content ───────────────────────────────────────────────────────────────────────────────────
	check(bool(registry.call("has_weapon", &"stone_axe")), "stone axe weapon is registered")
	var axe: WeaponDef = registry.call("get_weapon", &"stone_axe") as WeaponDef
	check(axe != null and axe.validation_errors().is_empty(), "authored weapon validates")
	check(not bool(registry.call("has_weapon", &"log")), "a plain resource item has no weapon")
	var unarmed: WeaponDef = combat.get("unarmed") as WeaponDef
	check(unarmed != null and unarmed.item_id == &"unarmed", "unarmed fallback exists in code")
	check(is_equal_approx(
		axe.swing_seconds(), axe.wind_up_seconds + axe.commit_seconds + axe.recovery_seconds
	), "swing duration is its three phases")

	# ── the shared damage seam ────────────────────────────────────────────────────────────────────
	check(HARVESTABLE_SCRIPT.DAMAGEABLE_GROUP == &"damageable",
		"Harvestable declares the shared damageable group")
	var harvestable: Node3D = HARVESTABLE_SCRIPT.new()
	harvestable.name = "SeamHarvestable"
	harvestable.set("definition", load("res://content/harvestables/tree.tres"))
	root.add_child(harvestable)
	await process_frame
	check(harvestable.is_in_group(&"damageable"), "a real Harvestable joins the damageable group")
	check(harvestable.has_method("host_apply_damage"), "the seam method is the one combat calls")
	harvestable.queue_free()
	await process_frame

	# ── world ─────────────────────────────────────────────────────────────────────────────────────
	var player := Node3D.new()
	player.name = "CombatCheckPlayer"
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

	# Straight ahead is -Z. In arc, in reach.
	var target := TestTarget.new()
	target.name = "AheadTarget"
	target.position = Vector3(0.0, 0.0, -2.0)
	root.add_child(target)
	# Behind the player: in reach, outside a 100 degree arc.
	var behind := TestTarget.new()
	behind.name = "BehindTarget"
	behind.position = Vector3(0.0, 0.0, 2.0)
	root.add_child(behind)
	# Ahead but well past the axe's 2.6 m reach plus tolerance.
	var far := TestTarget.new()
	far.name = "FarTarget"
	far.position = Vector3(0.0, 0.0, -9.0)
	root.add_child(far)
	await process_frame

	# ── held weapon ───────────────────────────────────────────────────────────────────────────────
	check((combat.call("weapon_for_hotbar_index", 0) as WeaponDef).item_id == &"unarmed",
		"an empty hotbar slot swings unarmed")
	check(bool(inventory.call("host_add", 1, &"stone_axe", 1)), "host grants the axe")
	# A grant lands in the HOTBAR first and only spills into the backpack once the hotbar is full
	# (`InventoryStore._addition_order()`, F-382). This used to grant the axe and then
	# `host_move_stack(1, 0, 24, 1)` it out of backpack slot 0; since that change slot 0 has been
	# empty, the move has returned false, and this check has been red at HEAD ever since (F-551) —
	# invisibly, because the axe was already exactly where the move was trying to put it. Assert the
	# placement instead of a move that now has nothing to move.
	var hotbar_start: int = int(inventory.call("hotbar_start_index"))
	var granted: Array[Dictionary] = inventory.call("host_slots", 1) as Array[Dictionary]
	check(StringName(String(granted[hotbar_start].get("item_id", ""))) == &"stone_axe",
		"the granted axe lands in hotbar slot one")
	check(granted[0].is_empty(), "and nothing was put in the backpack while the hotbar had room")
	check((combat.call("weapon_for_hotbar_index", 0) as WeaponDef).item_id == &"stone_axe",
		"the selected hotbar slot decides the weapon")
	check((combat.call("weapon_for_hotbar_index", 3) as WeaponDef).item_id == &"unarmed",
		"an unheld slot still swings unarmed")
	check((combat.call("weapon_for_hotbar_index", 99) as WeaponDef).item_id == &"unarmed",
		"an out-of-range slot falls back rather than failing")

	# ── the swing ─────────────────────────────────────────────────────────────────────────────────
	check(int(combat.call("local_phase")) == 0, "swing starts idle")
	var request_id: int = int(combat.call("request_attack"))
	check(request_id > 0, "attack returns a request id")
	check(int(combat.call("local_phase")) == 1, "the swing predicts its own wind-up immediately")
	check(bool(combat.call("host_swing_active", 1)), "the host accepted the request and is clocking it")
	check(int(combat.call("request_attack")) == -1, "a swing in progress cannot be cancelled or recut")
	check(target.hit_count == 0, "nothing is damaged during the wind-up")

	var connected: bool = await _until(func() -> bool: return target.hit_count > 0, 2.0)
	check(connected, "the host resolves the hit when the wind-up elapses")
	check(target.damage_taken == axe.damage, "the host applies the authored weapon damage")
	check(target.last_peer_id == 1, "damage is attributed to the attacking peer")
	check(behind.hit_count == 0, "a target behind the swing is outside the arc")
	check(far.hit_count == 0, "a target past the reach is not hit")
	check(landed.size() == 1, "one connect is announced")
	check(StringName(String(landed[0].get("target_name", ""))) == &"AheadTarget",
		"the announcement names the target the host chose")

	check(float(combat.call("local_hitstop_remaining")) > 0.0,
		"a connect freezes the attacker's own swing clock")
	check(float(pivot.call("shake_remaining")) > 0.0, "a connect shakes the attacker's camera")
	var rest_position: Vector3 = camera.position
	await process_frame
	check(camera.position != rest_position or rest_position != Vector3.ZERO,
		"shake displaces the camera while it runs")

	var recovered: bool = await _until(func() -> bool: return int(combat.call("local_phase")) == 0, 3.0)
	check(recovered, "the swing returns to idle after its recovery")
	check(is_zero_approx(float(pivot.call("shake_remaining"))), "shake ends on its own")
	await process_frame
	check(camera.position.is_equal_approx(Vector3.ZERO), "shake returns the camera to rest exactly")

	# ── misses and rejections ─────────────────────────────────────────────────────────────────────
	target.position = Vector3(0.0, 0.0, 9.0)
	await process_frame
	var missed_before: int = missed
	combat.call("request_attack")
	var reported_miss: bool = await _until(func() -> bool: return missed > missed_before, 3.0)
	check(reported_miss, "a swing that reaches nothing reports a miss")
	check(landed.size() == 1, "a miss announces no connect")
	await _until(func() -> bool: return int(combat.call("local_phase")) == 0, 3.0)

	target.position = Vector3(0.0, 0.0, -2.0)
	target.accept = false
	await process_frame
	missed_before = missed
	combat.call("request_attack")
	reported_miss = await _until(func() -> bool: return missed > missed_before, 3.0)
	check(reported_miss, "a target that refuses damage is a miss, not a phantom hit")
	check(target.damage_taken == axe.damage, "a refused hit adds no damage")
	await _until(func() -> bool: return int(combat.call("local_phase")) == 0, 3.0)

	var rejections_before: int = rejections.size()
	combat.call("_begin_host_swing", 1, 99, 4242)
	check(rejections.size() > rejections_before, "an out-of-range hotbar slot is rejected by the host")
	check(String(rejections[rejections.size() - 1].get("detail", "")).contains("hotbar slot"),
		"the host rejection says why")

	print("COMBAT_CHECK landed=%d missed=%d rejected=%d failures=%d" % [
		landed.size(), missed, rejections.size(), failures
	])
	finish()


func _on_landed(peer_id: int, position: Vector3, damage: int, target_name: StringName) -> void:
	landed.append({
		"peer_id": peer_id, "position": position, "damage": damage, "target_name": target_name
	})


func _on_missed(_peer_id: int) -> void:
	missed += 1


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
