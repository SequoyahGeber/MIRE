extends SceneTree

## F-062 regression proof: a melee swing must never resolve against the attacker's own body.
##
## Why this is a SEPARATE check from tools/combat_check.gd rather than three more lines inside it:
## combat_check builds its attacker as a bare Node3D that joins only &"players" (see its "world"
## section). That attacker was never in &"damageable", so the whole class of bug this file exists for
## was structurally invisible to it — and stayed invisible when task 2.13 put the REAL player body
## into &"damageable" so crawler hits could land. This check uses entities/player/player.tscn, the
## actual thing that ships, precisely so that group membership is real.
##
## The geometry that made the bug bite, and that the assertions below pin down: CombatService
## measures from an eye EYE_HEIGHT_M (1.5) above the body origin, so the attacker's own origin sits
## 1.5 m from the eye at exactly zero horizontal offset — inside every weapon's vertical band and
## reach, and on the "directly on the axis" branch that skips the arc test. Left unexcluded it wins
## the nearest-target contest against anything further out than 1.5 m, which is most of the axe's
## 2.6 m reach. So the target here sits at 2.5 m: in reach, and in the band the self-hit stole.

const PLAYER_SCENE := preload("res://entities/player/player.tscn")

## Distance to the sacrificial target. Inside the stone axe's 2.6 m reach and outside EYE_HEIGHT_M,
## so a regressed CombatService would pick the attacker over it every time.
const TARGET_DISTANCE_M: float = 2.5

var failures: int = 0


## Minimal damage-seam implementor, same shape as combat_check.gd's — a hitbox test has no business
## dragging a definition and a respawn clock in with it.
class TestTarget extends Node3D:
	var damage_taken: int = 0
	var hit_count: int = 0

	func _ready() -> void:
		add_to_group(&"damageable")

	func host_apply_damage(amount: int, _instigator_peer_id: int) -> bool:
		damage_taken += amount
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
	var health: Node = root.get_node_or_null(^"PlayerHealth")
	check(registry != null, "Registry autoload exists")
	check(combat != null, "CombatService autoload exists")
	check(inventory != null, "InventoryService autoload exists")
	check(health != null, "PlayerHealth autoload exists")
	if registry == null or combat == null or inventory == null or health == null:
		finish()
		return

	var axe: WeaponDef = registry.call("get_weapon", &"stone_axe") as WeaponDef
	check(axe != null, "stone axe is registered")
	if axe == null:
		finish()
		return

	# ── the attacker: the real player body, in the real groups ────────────────────────────────────
	var player: Node3D = PLAYER_SCENE.instantiate() as Node3D
	player.name = "1"
	root.add_child(player)
	await process_frame
	await process_frame

	check(player.is_in_group(&"damageable"),
		"the player body is damageable — the precondition that made F-062 possible")
	check(player.is_in_group(&"players"), "and is the body CombatService swings from")
	check(TARGET_DISTANCE_M < axe.range_m,
		"the target sits inside the axe's authored reach (%.2f m < %.2f m)" % [
			TARGET_DISTANCE_M, axe.range_m
		])
	check(TARGET_DISTANCE_M > 1.5,
		"and outside EYE_HEIGHT_M, so a self-hit would out-compete it")

	var max_hp: int = int(health.call("host_hp", 1))
	check(max_hp > 0, "the attacker starts with hp on the host")

	# Straight ahead is -Z with no yaw applied.
	var ahead := TestTarget.new()
	ahead.name = "AheadTarget"
	ahead.position = Vector3(0.0, 0.0, -TARGET_DISTANCE_M)
	root.add_child(ahead)
	await process_frame

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
		"the swing will use the axe, not unarmed")

	# ── a swing with a legitimate target in reach ─────────────────────────────────────────────────
	check(int(combat.call("request_attack")) > 0, "the attack is accepted")
	var connected: bool = await _until(func() -> bool: return ahead.hit_count > 0, 2.0)
	check(connected, "the swing reaches a target 2.5 m ahead — the band the self-hit used to steal")
	check(ahead.damage_taken == axe.damage, "and pays it the authored weapon damage")
	check(int(health.call("host_hp", 1)) == max_hp,
		"the attacker takes NOTHING from its own swing (F-062)")
	check(not bool(health.call("host_is_downed", 1)), "and is nowhere near downed")

	# The LOCAL clock is what gates the next request, and hitstop deliberately stalls it past the
	# host's own resolution — so wait on local_phase, not on host_swing_active.
	var recovered: bool = await _until(
		func() -> bool: return int(combat.call("local_phase")) == 0, 3.0
	)
	check(recovered, "the swing returns to idle after its recovery")

	# ── a swing at empty air ──────────────────────────────────────────────────────────────────────
	# The regression's second face: with nothing else in range the attacker was the ONLY candidate,
	# so a whiff still cost hp. A miss must cost nothing at all.
	ahead.queue_free()
	await process_frame
	await process_frame

	var hp_before_whiff: int = int(health.call("host_hp", 1))
	check(int(combat.call("request_attack")) > 0, "a second attack is accepted")
	var idle: bool = await _until(
		func() -> bool: return int(combat.call("local_phase")) == 0, 3.0
	)
	check(idle, "the whiffed swing runs to completion")
	check(int(health.call("host_hp", 1)) == hp_before_whiff,
		"a swing at empty air costs the attacker nothing (F-062)")

	finish()


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


## The verdict line is not decoration: `agent verify` parses `failures=N` out of a check's own output
## and reports "missing failures verdict" when there is none, which reads as a failure whatever the
## assertions did. This check had no such line and so was red at HEAD however green it ran (F-551).
func finish() -> void:
	print("COMBAT_SELF_HIT_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
