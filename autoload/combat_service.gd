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
signal swing_phase_changed(phase: Phase)
## A host-resolved connect, broadcast to every peer. Cosmetic consumers only.
signal attack_landed(peer_id: int, position: Vector3, damage: int, target_name: StringName)
signal attack_missed(peer_id: int)
## Host-side rejection reaching the peer that asked. Feeds a UI line, nothing else.
signal attack_rejected(request_id: int, detail: String)

var unarmed: WeaponDef

var _local_phase: Phase = Phase.IDLE
var _local_elapsed: float = 0.0
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
func request_attack() -> int:
	if _local_phase != Phase.IDLE:
		return -1
	var hotbar_index: int = _selected_hotbar_index()
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
	_host_swings[peer_id] = {"weapon": weapon, "elapsed": 0.0, "resolved": false}


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
		var elapsed: float = float(swing.get("elapsed", 0.0)) + delta
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

	var target: Node = _best_target(player, weapon)
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
		applied = int(target.call("harvest_damage_for", weapon.tool_class, weapon.harvest_power))
		connected = bool(
			target.call("host_apply_tool_damage", weapon.tool_class, weapon.harvest_power, peer_id)
		)
	else:
		connected = bool(target.call("host_apply_damage", weapon.damage, peer_id))
	if not connected:
		_broadcast(peer_id, false, Vector3.ZERO, 0, &"")
		return
	_broadcast(peer_id, true, target_position, applied, StringName(String(target.name)))


## Nearest damageable inside the swing's reach and horizontal arc. The arc is measured on the
## horizontal plane with a separate vertical band, so a prop whose origin sits on the ground is hit
## by a level swing rather than requiring the player to aim at its feet.
func _best_target(player: Node3D, weapon: WeaponDef) -> Node:
	var eye: Vector3 = player.global_position + Vector3.UP * EYE_HEIGHT_M
	var aim: Vector3 = _aim_direction(player)
	var aim_flat: Vector3 = Vector3(aim.x, 0.0, aim.z)
	if aim_flat.length_squared() < 0.000001:
		aim_flat = Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, player.rotation.y)
	aim_flat = aim_flat.normalized()

	var reach: float = weapon.range_m + HOST_RANGE_TOLERANCE_M
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
	elif NetTransport.is_active():
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

	_local_elapsed += delta
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
	swing_phase_changed.emit(phase)


func _play_impact(position: Vector3) -> void:
	var weapon: WeaponDef = _feel_weapon()
	var stream: AudioStream = weapon.impact_sound if weapon.impact_sound != null else _placeholder_impact
	if stream == null or not is_inside_tree():
		return
	var player := AudioStreamPlayer3D.new()
	player.name = "MeleeImpact"
	player.stream = stream
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
	weapon.range_m = 1.8
	weapon.arc_degrees = 80.0
	weapon.vertical_reach_m = 2.0
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
