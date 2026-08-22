extends Node

## Melee combat v1: wind-up → commit → recovery, host-resolved hitbox, client-local hitstop, shake
## and impact sound.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2). Two rows, deliberately split:
##
## · The SWING ANIMATION is the owning player's own action — client-local, predicted the frame the
##   button goes down, so a swing never waits on a round trip. It decides nothing.
## · The HIT is HOST. A client sends only "I attacked with hotbar slot N". The host derives the
##   sender, reads its OWN authoritative inventory for that slot, looks up the weapon, runs its own
##   swing clock, and resolves the hitbox against its own copy of the world. Damage, target choice
##   and cooldown are never taken from a client.
## · Hitstop, screenshake and impact audio are client-local cosmetics and are never networked beyond
##   the one broadcast that says a hit happened (D-033).
##
## Damageable targets join `&"damageable"` and implement
## `host_apply_damage(amount: int, instigator_peer_id: int) -> bool`. Harvestables implement it
## today; task 2.10's enemies join the same group and need no change here.
##
## Ranged weapons (task 5.3, `systems/combat/ranged_weapon_def.gd` + `autoload/ranged_combat_service.gd`)
## are a SEPARATE content family and host state machine, not a mode of this one — a bow fires an ammo
## item through a variable-length flight, which does not fit WeaponDef's fixed-duration swing shape.
## `request_attack()` below checks `Registry.has_ranged_weapon()` on the selected slot first and hands
## the whole action to `RangedCombatService` when it does, before any melee state is touched, so the
## two systems' local lockouts stay mutually exclusive regardless of which hotbar slot is selected.

const DAMAGEABLE_GROUP: StringName = &"damageable"
const EYE_HEIGHT_M: float = 1.5
## Slack added to the host's range test, absorbing the difference between the attacker's predicted
## position and the last one replicated to the host. Cheating this buys a few centimetres.
const HOST_RANGE_TOLERANCE_M: float = 0.75
const HOTBAR_START_INDEX: int = 24
const HOTBAR_SLOT_COUNT: int = 8

enum Phase { IDLE, WIND_UP, COMMIT, RECOVERY }

## Local presentation only — the frame the owner pressed attack, not the frame the host agreed.
signal swing_started(weapon_id: StringName)
## A host-resolved connect, broadcast to every peer. Cosmetic consumers only.
signal attack_landed(peer_id: int, position: Vector3, damage: int, target_name: StringName)
## UNCONSUMED, and kept for that reason (F-576). Nothing in the shipped tree connects it, but
## it is the SOLE publisher of this fact — there is no other path by which a whiff reaches any
## presentation layer.
## That makes it an unfinished feature rather than dead code, the same shape as
## `systems/loot/item_drop.gd`'s `collected`, which F-576 nearly deleted a week before
## F-581 turned it into the pickup feed. Delete it only along with the feature.
signal attack_missed(peer_id: int)
## Host-side rejection reaching the peer that asked. Feeds a UI line, nothing else.
## UNCONSUMED, and kept for that reason (F-576). Nothing in the shipped tree connects it, but
## it is the SOLE publisher of this fact — there is no other path by which the host's refusal reason reaches the player
## who asked — the docstring above says it "feeds a UI line", and that UI line does not exist yet.
## That makes it an unfinished feature rather than dead code, the same shape as
## `systems/loot/item_drop.gd`'s `collected`, which F-576 nearly deleted a week before
## F-581 turned it into the pickup feed. Delete it only along with the feature.
signal attack_rejected(request_id: int, detail: String)

var unarmed: WeaponDef

var _local_phase: Phase = Phase.IDLE
var _local_elapsed: float = 0.0

## F-580: `attack_seconds` — how much longer or shorter this peer's whole swing takes
## (docs/POWERUPS.md §2: "swing phase durations (wind-up/commit/recovery scaled together), negative
## mult = faster"). Applied by scaling the swing CLOCK rather than the three authored durations, so
## every phase boundary, `swing_seconds()` and `local_phase_progress()` keep reading the WeaponDef
## unchanged and stay in step with each other for free.
##
## Floored well above zero: a stacked speed-up that reached zero would resolve a hit on the same tick
## it was requested and make the wind-up unreadable, which is the tell the whole melee design rests
## on. Cached per swing rather than per tick — a grant mid-swing applies to the next one.
var _local_attack_scale: float = 1.0

const MIN_ATTACK_SCALE: float = 0.25

## docs/POWERUPS.md §2's `_low_hp` condition: health below a third.
const LOW_HP_FRACTION: float = 1.0 / 3.0

## Floor for `melee_range_m`. Short enough to be a real penalty, long enough that a swing can still
## reach something the player is standing next to.
const MIN_REACH_M: float = 0.5

## F-580: the fractional remainder of `on_hit_lifesteal`/`on_kill_heal_hp`, per peer, carried between
## swings — see `_apply_hit_rewards()` for why rounding per hit would silently zero the stat.
var _heal_accum: Dictionary[int, float] = {}

## PowerupService, path-resolved (F-011) and cached (F-099) — the melee resolve path asks it up to
## four times per landed swing.
var _powerup_node: Node
var _local_weapon: WeaponDef
## The weapon the local peer last swung. A remote host's answer can arrive after the local swing has
## already recovered, and the hit still has to feel like the weapon that threw it.
var _last_local_weapon: WeaponDef
var _local_hitstop_remaining: float = 0.0
var _next_request_id: int = 1
## peer_id -> {"weapon": WeaponDef, "elapsed": float, "resolved": bool}
var _host_swings: Dictionary[int, Dictionary] = {}
var _placeholder_impact: AudioStream


func _ready() -> void:
	unarmed = _build_unarmed()
	_placeholder_impact = _build_placeholder_impact()
	set_process(true)


func _process(delta: float) -> void:
	_advance_local_swing(delta)
	_advance_host_swings(delta)


# ── Client seam ───────────────────────────────────────────────────────────────────────────────────

## Called by the owning PlayerController on the attack action. Starts the local swing immediately and
## asks the host to resolve it. Returns the request id, or -1 if the local swing is still locked out.
##
## Ranged weapons dispatch whole to RangedCombatService before any melee state is touched — see this
## file's header and RangedCombatService.request_shot()'s own symmetric check back the other way.
func request_attack() -> int:
	if _local_phase != Phase.IDLE:
		return -1
	var ranged: Node = get_node_or_null(^"/root/RangedCombatService")
	if ranged != null and int(ranged.call(&"local_phase")) != 0:
		return -1
	var hotbar_index: int = _selected_hotbar_index()
	if _ranged_weapon_id_for(hotbar_index) != &"":
		return int(ranged.call(&"request_shot", hotbar_index)) if ranged != null else -1
	var weapon: WeaponDef = weapon_for_hotbar_index(hotbar_index)
	_start_local_swing(weapon)

	var request_id: int = _take_request_id()
	if _owns_resolution():
		_begin_host_swing(_local_peer_id(), hotbar_index, request_id)
	elif NetTransport.is_active():
		net_request_attack.rpc_id(NetConfig.HOST_PEER_ID, hotbar_index, request_id)
	else:
		attack_rejected.emit(request_id, "attack rejected: no authoritative session")
	return request_id


## The weapon the local peer would swing right now. Presentation and prediction only — the host
## repeats this lookup against its own inventory.
func weapon_for_hotbar_index(hotbar_index: int) -> WeaponDef:
	if hotbar_index < 0 or hotbar_index >= HOTBAR_SLOT_COUNT:
		return unarmed
	# One slot read, not a full snapshot copy — this sits on per-frame presentation paths (F-099).
	var item_id: StringName = InventoryService.local_item_id(HOTBAR_START_INDEX + hotbar_index)
	if item_id == &"":
		return unarmed
	var weapon: WeaponDef = Registry.get_weapon(item_id)
	return weapon if weapon != null else unarmed


## The item id in this hotbar slot IF Registry has a RangedWeaponDef for it, else &"" — the one
## question request_attack() needs answered before it decides which system owns the click.
func _ranged_weapon_id_for(hotbar_index: int) -> StringName:
	if hotbar_index < 0 or hotbar_index >= HOTBAR_SLOT_COUNT:
		return &""
	var item_id: StringName = InventoryService.local_item_id(HOTBAR_START_INDEX + hotbar_index)
	if item_id == &"" or not Registry.has_ranged_weapon(item_id):
		return &""
	return item_id


func local_phase() -> Phase:
	return _local_phase


## 0..1 through the whole swing, for a viewmodel or a debug readout.
func local_swing_progress() -> float:
	if _local_phase == Phase.IDLE or _local_weapon == null:
		return 0.0
	return clampf(_local_elapsed / _local_weapon.swing_seconds(), 0.0, 1.0)


## 0..1 through the CURRENT phase, which is what an animation wants — `local_swing_progress()` runs
## across the whole swing and cannot tell a wind-up from a recovery. Returns 0 while idle.
func local_phase_progress() -> float:
	if _local_phase == Phase.IDLE or _local_weapon == null:
		return 0.0
	var wind_up: float = _local_weapon.wind_up_seconds
	var commit_end: float = wind_up + _local_weapon.commit_seconds
	match _local_phase:
		Phase.WIND_UP:
			return clampf(_local_elapsed / maxf(wind_up, 0.001), 0.0, 1.0)
		Phase.COMMIT:
			return clampf((_local_elapsed - wind_up) / maxf(_local_weapon.commit_seconds, 0.001), 0.0, 1.0)
		Phase.RECOVERY:
			return clampf(
				(_local_elapsed - commit_end) / maxf(_local_weapon.recovery_seconds, 0.001), 0.0, 1.0
			)
	return 0.0


## The item id currently being swung, or &"" while idle. The viewmodel uses it to keep showing the
## weapon that threw the swing even if the selection changes mid-arc.
func local_swing_item() -> StringName:
	return _local_weapon.item_id if _local_weapon != null else &""


func local_hitstop_remaining() -> float:
	return _local_hitstop_remaining


func host_swing_active(peer_id: int) -> bool:
	return _host_swings.has(peer_id)


## Shared with RangedCombatService (task 5.3) — a bow with no authored `impact_sound` plays the exact
## same placeholder thud melee falls back to, rather than a second copy of the procedural synth below.
func placeholder_impact_sound() -> AudioStream:
	return _placeholder_impact


# ── Host resolution ───────────────────────────────────────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable")
func net_request_attack(hotbar_index: int, request_id: int) -> void:
	if not NetTransport.is_host():
		return
	_begin_host_swing(multiplayer.get_remote_sender_id(), hotbar_index, request_id)


@rpc("authority", "call_remote", "reliable")
func net_attack_resolved(
	peer_id: int, hit: bool, position: Vector3, damage: int, target_name: StringName
) -> void:
	_apply_resolution(peer_id, hit, position, damage, target_name)


@rpc("authority", "call_remote", "reliable")
func net_attack_rejected(request_id: int, detail: String) -> void:
	attack_rejected.emit(request_id, detail)


func _begin_host_swing(peer_id: int, hotbar_index: int, request_id: int) -> void:
	if peer_id <= 0:
		return
	if hotbar_index < 0 or hotbar_index >= HOTBAR_SLOT_COUNT:
		_reject(peer_id, request_id, "attack rejected: hotbar slot out of range")
		return
	if _host_swings.has(peer_id):
		_reject(peer_id, request_id, "attack rejected: previous swing has not recovered")
		return
	if _host_player(peer_id) == null:
		_reject(peer_id, request_id, "attack rejected: player is not spawned")
		return

	var weapon: WeaponDef = _host_weapon_for(peer_id, hotbar_index)
	_host_swings[peer_id] = {
		"weapon": weapon, "elapsed": 0.0, "resolved": false,
		"attack_scale": _attack_scale(peer_id),
	}


## The host reads its own inventory for the slot the client named, so the worst a lying client can do
## is swing one of the eight items it genuinely holds.
func _host_weapon_for(peer_id: int, hotbar_index: int) -> WeaponDef:
	var slots: Array[Dictionary] = InventoryService.host_slots(peer_id)
	return _weapon_from_slots(slots, hotbar_index)


func _advance_host_swings(delta: float) -> void:
	if _host_swings.is_empty():
		return
	var finished: Array[int] = []
	for peer_id: int in _host_swings:
		var swing: Dictionary = _host_swings[peer_id]
		var weapon: WeaponDef = swing.get("weapon") as WeaponDef
		if weapon == null:
			finished.append(peer_id)
			continue
		# F-580: the same scaled clock the local swing uses, so the host's resolve tick and the
		# owner's viewmodel stay on the same schedule for a peer holding `attack_seconds`.
		var elapsed: float = (
			float(swing.get("elapsed", 0.0)) + delta / float(swing.get("attack_scale", 1.0))
		)
		swing["elapsed"] = elapsed
		if not bool(swing.get("resolved", false)) and elapsed >= weapon.wind_up_seconds:
			swing["resolved"] = true
			_resolve_hit(peer_id, weapon)
		if elapsed >= weapon.swing_seconds():
			finished.append(peer_id)
	for peer_id: int in finished:
		_host_swings.erase(peer_id)


func _resolve_hit(peer_id: int, weapon: WeaponDef) -> void:
	var player: Node3D = _host_player(peer_id)
	if player == null:
		_broadcast(peer_id, false, Vector3.ZERO, 0, &"")
		return

	var target: Node = _best_target(player, weapon, peer_id)
	if target == null:
		_broadcast(peer_id, false, Vector3.ZERO, 0, &"")
		return

	var target_position: Vector3 = (target as Node3D).global_position
	# Two seams, chosen by the target (F-113). An enemy takes the weapon's combat `damage`; a
	# harvestable takes the tool's `harvest_power` scaled by whether the tool class matches, which
	# is what makes an axe fell a tree in three swings and a pickaxe bounce off it. Preferring the
	# tool seam by feature test rather than by type keeps `&"damageable"` the single contract:
	# a target that has never heard of tools is unaffected, exactly as before.
	var applied: int = weapon.damage
	var connected: bool
	if target.has_method("host_apply_tool_damage"):
		applied = int(target.call(
			"harvest_damage_for", weapon.tool_class, weapon.harvest_power, peer_id
		))
		connected = bool(
			target.call("host_apply_tool_damage", weapon.tool_class, weapon.harvest_power, peer_id)
		)
	else:
		# F-543: `melee_damage` scales the weapon's combat damage for the peer who swung
		# (docs/POWERUPS.md §2; DESIGN §4.5 is Reaver +15% / Forager -15%). Host-side, so `stat()`
		# with the real peer id, not `local_stat()` — CombatService resolves every peer's swing.
		# `applied` is reassigned as well as passed, so the damage number the HUD shows is the
		# damage the enemy took. `maxi(..., 1)` keeps a connected swing from reading as a whiff.
		applied = maxi(_modified_melee_damage(peer_id, weapon.damage), 1)
		connected = bool(target.call("host_apply_damage", applied, peer_id))
		if connected:
			host_apply_hit_rewards(peer_id, applied, target)
	if not connected:
		_broadcast(peer_id, false, Vector3.ZERO, 0, &"")
		return
	_broadcast(peer_id, true, target_position, applied, StringName(String(target.name)))


## Nearest damageable inside the swing's reach and horizontal arc. The arc is measured on the
## horizontal plane with a separate vertical band, so a prop whose origin sits on the ground is hit
## by a level swing rather than requiring the player to aim at its feet.
func _best_target(player: Node3D, weapon: WeaponDef, peer_id: int) -> Node:
	var eye: Vector3 = player.global_position + Vector3.UP * EYE_HEIGHT_M
	var aim: Vector3 = _aim_direction(player)
	var aim_flat: Vector3 = Vector3(aim.x, 0.0, aim.z)
	if aim_flat.length_squared() < 0.000001:
		aim_flat = Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, player.rotation.y)
	aim_flat = aim_flat.normalized()

	# F-580: `melee_range_m` — the swing's reach for the peer who threw it (docs/POWERUPS.md §2,
	# base `WeaponDef.range_m`). The host's own tolerance is added AFTER the stat, so a reach powerup
	# does not also scale the latency allowance it has nothing to do with.
	var reach: float = _modified_reach(peer_id, weapon.range_m) + HOST_RANGE_TOLERANCE_M
	var half_arc_cosine: float = cos(deg_to_rad(weapon.arc_degrees * 0.5))
	var best: Node = null
	var best_distance: float = INF

	for node: Node in get_tree().get_nodes_in_group(DAMAGEABLE_GROUP):
		# F-062: the attacker is itself damageable (task 2.13 put the player body in this group so
		# crawler hits could land), and it wins this contest outright unless excluded — it sits
		# EYE_HEIGHT_M below the eye, which is inside every weapon's vertical band and reach, at zero
		# horizontal offset, so it takes the "directly on the axis" branch below and skips the arc
		# test entirely. Left in, every swing chops the swinger and nothing past 1.5 m is ever
		# reachable. Excluded by identity rather than by a minimum distance, because an enemy pressed
		# right up against you must still be hittable.
		if node == player:
			continue
		var target := node as Node3D
		if target == null or not target.has_method("host_apply_damage"):
			continue
		var to_target: Vector3 = target.global_position - eye
		if absf(to_target.y) > weapon.vertical_reach_m:
			continue
		var distance: float = to_target.length()
		if distance > reach or distance >= best_distance:
			continue
		var to_flat: Vector3 = Vector3(to_target.x, 0.0, to_target.z)
		if to_flat.length_squared() < 0.000001:
			best = node
			best_distance = distance
			continue
		if aim_flat.dot(to_flat.normalized()) < half_arc_cosine:
			continue
		best = node
		best_distance = distance
	return best


## Body yaw plus replicated camera pitch. Both arrive on the host through the player's own
## synchronizer, so the host never has to trust an aim vector sent with the attack.
func _aim_direction(player: Node3D) -> Vector3:
	var pitch: float = 0.0
	var pivot := player.get_node_or_null(^"CameraPivot") as Node3D
	if pivot != null:
		pitch = pivot.rotation.x
	return Vector3(0.0, 0.0, -1.0).rotated(Vector3.RIGHT, pitch).rotated(Vector3.UP, player.rotation.y)


func _broadcast(
	peer_id: int, hit: bool, position: Vector3, damage: int, target_name: StringName
) -> void:
	if NetTransport.is_active():
		net_attack_resolved.rpc(peer_id, hit, position, damage, target_name)
	_apply_resolution(peer_id, hit, position, damage, target_name)


func _reject(peer_id: int, request_id: int, detail: String) -> void:
	if peer_id == _local_peer_id():
		attack_rejected.emit(request_id, detail)
	elif NetTransport.is_active() and NetTransport.has_peer(peer_id):
		# F-059's shape: an attacker that disconnects between net_request_attack and this rejection
		# would otherwise take an rpc_id() to a peer id nothing is listening on any more.
		net_attack_rejected.rpc_id(peer_id, request_id, detail)


# ── Client-local feel ─────────────────────────────────────────────────────────────────────────────

func _apply_resolution(
	peer_id: int, hit: bool, position: Vector3, damage: int, target_name: StringName
) -> void:
	if not hit:
		attack_missed.emit(peer_id)
		return
	attack_landed.emit(peer_id, position, damage, target_name)
	_play_impact(position)
	if peer_id != _local_peer_id():
		return
	var weapon: WeaponDef = _feel_weapon()
	_local_hitstop_remaining = weapon.hitstop_seconds
	var camera: Node = _local_camera()
	if camera != null and camera.has_method("add_shake"):
		camera.call("add_shake", weapon.shake_magnitude, weapon.shake_duration)


func _feel_weapon() -> WeaponDef:
	if _local_weapon != null:
		return _local_weapon
	return _last_local_weapon if _last_local_weapon != null else unarmed


func _start_local_swing(weapon: WeaponDef) -> void:
	_local_weapon = weapon
	_last_local_weapon = weapon
	_local_elapsed = 0.0
	_local_attack_scale = _attack_scale(_local_peer_id())
	_local_hitstop_remaining = 0.0
	_set_local_phase(Phase.WIND_UP)
	swing_started.emit(weapon.item_id)


## Hitstop stalls the attacker's own swing clock and nothing else. `Engine.time_scale` would stall
## this peer's whole frame loop, and with it the network pump every transport is polled from (D-033).
func _advance_local_swing(delta: float) -> void:
	if _local_phase == Phase.IDLE or _local_weapon == null:
		return
	if _local_hitstop_remaining > 0.0:
		_local_hitstop_remaining = maxf(_local_hitstop_remaining - delta, 0.0)
		return

	# F-580: the scaled clock. `/ scale` and not `* scale` — a scale of 0.9 means the swing TAKES 90%
	# as long, so its clock has to run faster to reach the same authored boundaries sooner.
	_local_elapsed += delta / _local_attack_scale
	var wind_up: float = _local_weapon.wind_up_seconds
	var commit_end: float = wind_up + _local_weapon.commit_seconds
	if _local_elapsed >= _local_weapon.swing_seconds():
		_local_elapsed = 0.0
		_local_weapon = null
		_set_local_phase(Phase.IDLE)
	elif _local_elapsed >= commit_end:
		_set_local_phase(Phase.RECOVERY)
	elif _local_elapsed >= wind_up:
		_set_local_phase(Phase.COMMIT)


func _set_local_phase(phase: Phase) -> void:
	if _local_phase == phase:
		return
	_local_phase = phase


func _play_impact(position: Vector3) -> void:
	var weapon: WeaponDef = _feel_weapon()
	var stream: AudioStream = weapon.impact_sound if weapon.impact_sound != null else _placeholder_impact
	if stream == null or not is_inside_tree():
		return
	var player := AudioStreamPlayer3D.new()
	player.name = "MeleeImpact"
	player.stream = stream
	# Task 7.5: routed through the SFX bus so the settings menu's SFX slider covers it. The bus is
	# created by SettingsService at boot; a nonexistent bus name just falls back to Master, so this
	# is harmless if that autoload is ever absent (e.g. an isolated scene test).
	player.bus = &"SFX"
	player.max_distance = weapon.impact_audible_range_m
	player.unit_size = 6.0
	get_tree().root.add_child(player)
	player.global_position = position
	player.finished.connect(player.queue_free)
	player.play()


func _local_camera() -> Node:
	var player: Node3D = _local_player()
	return player.get_node_or_null(^"CameraPivot") if player != null else null


# ── Shared lookups ────────────────────────────────────────────────────────────────────────────────

func _weapon_from_slots(slots: Array[Dictionary], hotbar_index: int) -> WeaponDef:
	var slot_index: int = HOTBAR_START_INDEX + hotbar_index
	if slot_index < 0 or slot_index >= slots.size():
		return unarmed
	var item_id := StringName(String(slots[slot_index].get("item_id", "")))
	if item_id == &"" or int(slots[slot_index].get("amount", 0)) <= 0:
		return unarmed
	var weapon: WeaponDef = Registry.get_weapon(item_id)
	return weapon if weapon != null else unarmed


func _selected_hotbar_index() -> int:
	var ui: Node = get_node_or_null(^"/root/InventoryUI")
	if ui == null or not ui.has_method("selected_hotbar_slot"):
		return 0
	return int(ui.call("selected_hotbar_slot"))


func _host_player(peer_id: int) -> Node3D:
	if NetTransport.is_active():
		return PlayerNet.player_for(peer_id)
	if peer_id != NetConfig.HOST_PEER_ID:
		return null
	return _local_player()


func _local_player() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null


func _local_peer_id() -> int:
	var peer_id: int = NetTransport.local_peer_id()
	return peer_id if peer_id > 0 else NetConfig.HOST_PEER_ID


func _owns_resolution() -> bool:
	return (
		NetTransport.is_host()
		or (not NetTransport.is_active() and not NetTransport.is_connecting())
	)


func _take_request_id() -> int:
	var result: int = _next_request_id
	_next_request_id += 1
	if _next_request_id <= 0:
		_next_request_id = 1
	return result


## Bare hands. Deliberately code, not content: an empty hotbar slot must never depend on someone
## having authored a .tres for it.
func _build_unarmed() -> WeaponDef:
	var weapon := WeaponDef.new()
	weapon.item_id = &"unarmed"
	weapon.display_name = "Bare Hands"
	weapon.wind_up_seconds = 0.14
	weapon.commit_seconds = 0.08
	weapon.recovery_seconds = 0.22
	# F-519: the reach has to cover what the look-at prompt already promises. Every bare-hands plant
	# authors `request_range_m = 3.0`, and `ui/hud/focus_prompt.gd` offers a harvestable at exactly
	# that — so at 1.8 m (2.55 m with HOST_RANGE_TOLERANCE_M) the HUD read "Gather Bush with Bare
	# Hands" while the swing silently missed, which is the entry tier of the whole tool tree failing.
	# 2.3 + 0.75 = 3.05 clears it and is still the shortest reach in the game (the cleaver is 2.4).
	# The vertical band matches WeaponDef's own default for the same reason: a scattered plant's
	# origin sits at your feet, 1.5 m below the eye the reach is measured from.
	weapon.range_m = 2.3
	weapon.arc_degrees = 80.0
	weapon.vertical_reach_m = 2.4
	weapon.damage = 1
	# Bare hands are `Tool.NONE` with power 1: they pull sticks off a bush, which asks for no tool,
	# and floor to zero against anything that wants an axe or a pickaxe (F-113).
	weapon.tool_class = 0
	weapon.harvest_power = 1
	weapon.hitstop_seconds = 0.035
	weapon.shake_magnitude = 0.05
	weapon.shake_duration = 0.14
	return weapon


## Placeholder thud so 2.9 has something audible to tune against before any audio asset exists. A
## seeded generator, never `randi()` — two peers must produce the identical placeholder (AGENTS.md).
## An authored `WeaponDef.impact_sound` replaces it with no code change.
func _build_placeholder_impact() -> AudioStream:
	const SAMPLE_RATE: int = 22050
	const DURATION_SEC: float = 0.18
	var frame_count: int = int(SAMPLE_RATE * DURATION_SEC)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x4d495245  # "MIRE"

	var data := PackedByteArray()
	data.resize(frame_count * 2)
	for frame: int in frame_count:
		var t: float = float(frame) / float(SAMPLE_RATE)
		var envelope: float = pow(1.0 - t / DURATION_SEC, 3.0)
		var body: float = sin(TAU * 92.0 * t) * 0.65
		var crack: float = rng.randf_range(-1.0, 1.0) * 0.35 * pow(1.0 - t / DURATION_SEC, 12.0)
		var sample: int = int(clampf((body + crack) * envelope, -1.0, 1.0) * 32000.0)
		data.encode_s16(frame * 2, sample)

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream


## F-543: one place for "this peer's version of an authored damage number". Both damage stats
## (`melee_damage` here, `bow_damage` in RangedCombatService) are authored as multipliers on a base
## that comes from the weapon def, so the base is never zero on a path that reaches this.
## F-580: `melee_damage`, then the two condition-suffixed variants docs/POWERUPS.md §2 authorises,
## chained onto the unconditional pass exactly as that section's worked example does. D-179: the
## CONDITION is evaluated here, by the consumer that can see it — the service stays condition-blind.
func _modified_melee_damage(peer_id: int, base: int) -> int:
	var powerups: Node = _powerup_service()
	if powerups == null:
		return base
	var damage: float = float(powerups.call(&"stat", peer_id, &"melee_damage", float(base)))
	if _is_low_hp(peer_id):
		damage = float(powerups.call(&"stat", peer_id, &"melee_damage_low_hp", damage))
	if _is_night():
		damage = float(powerups.call(&"stat", peer_id, &"melee_damage_at_night", damage))
	return int(roundi(damage))


## docs/POWERUPS.md §2's `_low_hp` condition: health below a third, read off PlayerHealth's HOST
## state — CombatService resolves every peer's swing, so a client's own cache is the wrong source.
func _is_low_hp(peer_id: int) -> bool:
	var health: Node = get_node_or_null(^"/root/PlayerHealth")
	if health == null:
		return false
	var maximum: int = int(health.call(&"host_max_hp", peer_id))
	if maximum <= 0:
		return false
	return float(int(health.call(&"host_hp", peer_id))) / float(maximum) < LOW_HP_FRACTION


## docs/POWERUPS.md §2's `_at_night` condition, off the shared day/night state. Read as the same
## `fraction >= night_started_at or fraction < day_started_at` comparison DayNight makes internally,
## from its own replicated `time_of_day` and its own two thresholds, rather than through a method of
## its own — the fraction and both thresholds are already public and this file has no business
## adding an API to a system it only reads. No DayNight (a bare combat harness) means "not night",
## which is the same answer as an unmodified swing.
func _is_night() -> bool:
	var day_night: Node = get_node_or_null(^"/root/DayNight")
	if day_night == null:
		return false
	var fraction: float = float(day_night.get(&"time_of_day"))
	return (
		fraction >= float(day_night.get(&"night_started_at"))
		or fraction < float(day_night.get(&"day_started_at"))
	)


## F-580: the swing's reach after `melee_range_m`. Floored above zero so a stacked negative cannot
## produce a weapon that can never connect with anything.
func _modified_reach(peer_id: int, base: float) -> float:
	var powerups: Node = _powerup_service()
	if powerups == null:
		return base
	return maxf(float(powerups.call(&"stat", peer_id, &"melee_range_m", base)), MIN_REACH_M)


## F-580: `on_hit_lifesteal` (a FRACTION of damage dealt, returned as HP) and `on_kill_heal_hp` (a
## flat heal when the swing killed). Both are asked on a base of 0.0, so a peer holding neither does
## no work and no heal is attempted. Host-side: healing is host-authoritative state.
##
## Public because RangedCombatService lands damage through its own resolve path and a bow user
## holding `red_quench` must not silently get nothing — the same shared-helper precedent as
## `placeholder_impact_sound()`, and the accumulator has to be one per peer, not one per weapon.
##
## The kill test is "the target was alive before this hit and is not now", asked of the target itself
## rather than of a kill event, because melee's resolve seam has no kill callback of its own and a
## dead node is freed on its own schedule.
func host_apply_hit_rewards(peer_id: int, damage: int, target: Node) -> void:
	var powerups: Node = _powerup_service()
	var health: Node = get_node_or_null(^"/root/PlayerHealth")
	if powerups == null or health == null or damage <= 0:
		return
	var heal: float = float(powerups.call(&"stat", peer_id, &"on_hit_lifesteal", 0.0)) * float(damage)
	if target.has_method(&"is_alive") and not bool(target.call(&"is_alive")):
		heal += float(powerups.call(&"stat", peer_id, &"on_kill_heal_hp", 0.0))
	# Accumulated across swings rather than rounded per hit: 8% lifesteal on a 6-damage swing is
	# 0.48 hp, and rounding that to zero every time would make the powerup do nothing at all while
	# reading as if it worked.
	if heal <= 0.0:
		return
	var carried: float = float(_heal_accum.get(peer_id, 0.0)) + heal
	var whole: int = int(carried)
	_heal_accum[peer_id] = carried - float(whole)
	if whole > 0:
		health.call(&"host_heal", peer_id, whole)


func _modified_damage(peer_id: int, stat_name: StringName, base: int) -> int:
	var powerups: Node = _powerup_service()
	if powerups == null:
		return base
	return int(roundi(float(powerups.call(&"stat", peer_id, stat_name, float(base)))))


func _powerup_service() -> Node:
	if _powerup_node == null or not is_instance_valid(_powerup_node):
		_powerup_node = get_node_or_null(^"/root/PowerupService")
	return _powerup_node


## F-580: the swing-duration scale for one peer, resolved once per swing. `attack_seconds` is asked
## on a base of 1.0 for the same reason `Chest._luck_for()` does (F-140): every authored modifier is
## multiplicative, and asking on 0.0 would return 0 however many stacks are held.
func _attack_scale(peer_id: int) -> float:
	var powerups: Node = _powerup_service()
	if powerups == null:
		return 1.0
	return maxf(float(powerups.call(&"stat", peer_id, &"attack_seconds", 1.0)), MIN_ATTACK_SCALE)
