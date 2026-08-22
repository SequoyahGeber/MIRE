extends Node

## Ranged combat v1 (task 5.3): draw → release → flight → host-resolved impact, client-local
## hitstop/shake/impact sound, a purely cosmetic flying arrow on every peer.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Ranged weapons" row). Same three-way split
## `autoload/combat_service.gd` established for melee in task 2.8, extended with a fourth piece this
## weapon family needs and melee never did — an actual flight:
##
## · The DRAW is the owning player's own action — client-local, predicted the frame the button goes
##   down, so a shot never waits on a round trip to start feeling responsive. It decides nothing.
## · The SHOT is HOST. A client sends only "I fired with hotbar slot N" — no aim vector, no target.
##   The host derives the sender, reads its OWN authoritative inventory for that slot and for ammo,
##   looks up the weapon, derives aim from the shooter's own already-replicated transform + camera
##   pitch (`systems/combat/aim_util.gd`, the same formula melee's `_aim_direction()` uses), and
##   simulates the arrow's flight itself: one `PhysicsDirectSpaceState3D.intersect_ray()` per physics
##   tick between last and current position, exactly like `systems/enemies/enemy.gd`'s own
##   line-of-sight ray. Damage, target choice, ammo consumption and cooldown are never taken from a
##   client.
## · The FLIGHT VISUAL is cosmetic prediction, identical on every peer: one broadcast
##   (`net_shot_fired`) carries the origin/direction/speed/gravity the host is ABOUT to simulate with,
##   and every peer (including the shooter and the host itself) advances an unreplicated, client-local
##   mesh instance through the identical kinematic formula. No per-tick position sync — a moving
##   projectile is exactly the case ARCHITECTURE.md §2.5 asks to keep off the wire when both sides can
##   already extrapolate it identically from one message.
## · The IMPACT is HOST, broadcast once (`net_shot_resolved`) the instant the host's own simulation
##   decides the shot is over (a hit, a wall, or `max_range_m`), which is also what snaps/despawns
##   every peer's cosmetic visual and starts the shooter's local recovery lockout. Hitstop, screenshake
##   and impact audio are client-local cosmetics past that one broadcast (D-033).
##
## PvP is cut (DESIGN.md §7) — an arrow that reaches another player's own body deals no damage; see
## `_resolve_flight()`. Damage that DOES land goes through the exact same `&"damageable"` seam melee
## uses: `host_apply_damage(amount: int, instigator_peer_id: int) -> bool`.

const DAMAGEABLE_GROUP: StringName = &"damageable"
## Mirrors `systems/enemies/enemy.gd`'s own world-only ray mask (`1 | PlacementValidator.TERRAIN_LAYER`)
## — layer 1 is the shared solid layer (players, enemies, buildables all default onto it), TERRAIN_LAYER
## is the ground's own layer since F-075 split it off. An arrow that reaches a damageable target's
## collider is resolved as a hit before this matters; anything else on either layer stops it cold.
const WORLD_COLLISION_MASK: int = 1 | PlacementValidator.TERRAIN_LAYER
## Spawn the arrow slightly ahead of the eye so its own flight never immediately re-intersects the
## shooter — belt-and-braces alongside the RID exclusion in `_advance_flight()`, not a substitute for it.
const ARROW_SPAWN_OFFSET_M: float = 0.35

enum Phase { IDLE, WIND_UP, COMMIT, RECOVERY }

## Local presentation only — the frame the owner pressed attack, not the frame the host agreed.
signal shot_started(weapon_id: StringName)
signal shot_phase_changed(phase: Phase)
## A host-resolved connect, broadcast to every peer. Cosmetic consumers only.
signal shot_landed(peer_id: int, position: Vector3, damage: int, target_name: StringName)
signal shot_missed(peer_id: int, position: Vector3)
## Host-side rejection reaching the peer that asked. Feeds a UI line, nothing else.
signal shot_rejected(request_id: int, detail: String)

var _gravity: float = 9.8

var _local_phase: Phase = Phase.IDLE
var _local_phase_elapsed: float = 0.0
var _local_weapon: RangedWeaponDef
## The weapon the local peer last fired. A remote host's resolution can arrive after the local clock
## has already moved on, and the hit still has to feel like the weapon that threw it.
var _last_local_weapon: RangedWeaponDef
var _local_hitstop_remaining: float = 0.0
var _next_request_id: int = 1
## peer_id -> {"weapon": RangedWeaponDef, "phase": Phase, "phase_elapsed": float, "request_id": int,
##             "position": Vector3, "velocity": Vector3, "traveled_m": float}. The last three keys
## only exist once phase >= COMMIT.
## F-580's `arrow_save_chance` stream. Host-side only, seeded from the OS rather than from the run
## seed on purpose: whether one arrow survives is a per-shot flourish, not part of the deterministic
## world a seed reproduces, and threading it into the run's stream would make every ammo save a
## divergence risk between peers for no gain.
var _rng := RandomNumberGenerator.new()

var _host_shots: Dictionary[int, Dictionary] = {}
## peer_id -> {"node": Node3D or null, "weapon": RangedWeaponDef, "origin": Vector3,
##             "direction": Vector3, "speed": float, "gravity_scale": float, "elapsed": float}.
## Client-local cosmetic state, kept on every peer (including the host) for every peer's shots.
var _flight_visuals: Dictionary[int, Dictionary] = {}


func _ready() -> void:
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_rng.randomize()
	set_process(true)
	set_physics_process(true)


func _process(delta: float) -> void:
	_advance_local_shot(delta)
	_advance_visual_projectiles(delta)


func _physics_process(delta: float) -> void:
	_advance_host_shots(delta)


# ── Client seam ───────────────────────────────────────────────────────────────────────────────────

## Called by CombatService.request_attack() when the selected hotbar slot resolves to a
## RangedWeaponDef — never called directly by PlayerController, so the two weapon families share one
## front door. Returns the request id, or -1 if either this or melee's own local clock is locked out.
func request_shot(hotbar_index: int) -> int:
	if _local_phase != Phase.IDLE:
		return -1
	var combat: Node = get_node_or_null(^"/root/CombatService")
	if combat != null and int(combat.call(&"local_phase")) != 0:
		return -1
	var weapon: RangedWeaponDef = ranged_weapon_for_hotbar_index(hotbar_index)
	if weapon == null:
		return -1
	_start_local_shot(weapon)

	var request_id: int = _take_request_id()
	if _owns_resolution():
		_begin_host_shot(_local_peer_id(), hotbar_index, request_id)
	elif NetTransport.is_active():
		net_request_shot.rpc_id(NetConfig.HOST_PEER_ID, hotbar_index, request_id)
	else:
		shot_rejected.emit(request_id, "shot rejected: no authoritative session")
	return request_id


## The weapon the local peer would fire right now, or null if the slot holds no ranged weapon.
## Presentation and prediction only — the host repeats this lookup against its own inventory.
func ranged_weapon_for_hotbar_index(hotbar_index: int) -> RangedWeaponDef:
	if hotbar_index < 0 or hotbar_index >= InventoryService.hotbar_slot_count():
		return null
	var item_id: StringName = InventoryService.local_item_id(
		InventoryService.hotbar_start_index() + hotbar_index
	)
	if item_id == &"":
		return null
	return Registry.get_ranged_weapon(item_id)


func local_phase() -> Phase:
	return _local_phase


func local_phase_progress() -> float:
	if _local_phase == Phase.IDLE or _local_weapon == null:
		return 0.0
	match _local_phase:
		Phase.WIND_UP:
			return clampf(_local_phase_elapsed / maxf(_local_weapon.draw_seconds, 0.001), 0.0, 1.0)
		Phase.RECOVERY:
			return clampf(_local_phase_elapsed / maxf(_local_weapon.recovery_seconds, 0.001), 0.0, 1.0)
	return 0.0


func local_hitstop_remaining() -> float:
	return _local_hitstop_remaining


func host_shot_active(peer_id: int) -> bool:
	return _host_shots.has(peer_id)


# ── Host resolution ───────────────────────────────────────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable")
func net_request_shot(hotbar_index: int, request_id: int) -> void:
	if not NetTransport.is_host():
		return
	_begin_host_shot(multiplayer.get_remote_sender_id(), hotbar_index, request_id)


@rpc("authority", "call_remote", "reliable")
func net_shot_fired(
	peer_id: int, request_id: int, origin: Vector3, direction: Vector3, speed: float,
	gravity_scale: float, weapon_item_id: StringName, ammo_item_id: StringName
) -> void:
	_apply_fired(peer_id, request_id, origin, direction, speed, gravity_scale, weapon_item_id, ammo_item_id)


@rpc("authority", "call_remote", "reliable")
func net_shot_resolved(
	peer_id: int, request_id: int, hit: bool, position: Vector3, damage: int, target_name: StringName
) -> void:
	_apply_resolved(peer_id, request_id, hit, position, damage, target_name)


@rpc("authority", "call_remote", "reliable")
func net_shot_rejected(request_id: int, detail: String) -> void:
	shot_rejected.emit(request_id, detail)


func _begin_host_shot(peer_id: int, hotbar_index: int, request_id: int) -> void:
	if peer_id <= 0:
		return
	if hotbar_index < 0 or hotbar_index >= InventoryService.hotbar_slot_count():
		_reject(peer_id, request_id, "shot rejected: hotbar slot out of range")
		return
	if _host_shots.has(peer_id):
		_reject(peer_id, request_id, "shot rejected: previous shot has not recovered")
		return
	if _host_player(peer_id) == null:
		_reject(peer_id, request_id, "shot rejected: player is not spawned")
		return
	var weapon: RangedWeaponDef = _host_weapon_for(peer_id, hotbar_index)
	if weapon == null:
		_reject(peer_id, request_id, "shot rejected: no ranged weapon in that slot")
		return
	if InventoryService.host_count(peer_id, weapon.ammo_item_id) < 1:
		_reject(peer_id, request_id, "shot rejected: out of ammo")
		return
	_host_shots[peer_id] = {
		"weapon": weapon, "phase": Phase.WIND_UP, "phase_elapsed": 0.0, "request_id": request_id,
	}


## The host reads its own inventory for the slot the client named, so the worst a lying client can do
## is fire one of the eight items it genuinely holds (same guarantee as CombatService's melee path).
func _host_weapon_for(peer_id: int, hotbar_index: int) -> RangedWeaponDef:
	var slots: Array[Dictionary] = InventoryService.host_slots(peer_id)
	var slot_index: int = InventoryService.hotbar_start_index() + hotbar_index
	if slot_index < 0 or slot_index >= slots.size():
		return null
	var item_id := StringName(String(slots[slot_index].get("item_id", "")))
	if item_id == &"" or int(slots[slot_index].get("amount", 0)) <= 0:
		return null
	return Registry.get_ranged_weapon(item_id)


func _advance_host_shots(delta: float) -> void:
	if _host_shots.is_empty():
		return
	var finished: Array[int] = []
	for peer_id: int in _host_shots:
		var shot: Dictionary = _host_shots[peer_id]
		var weapon: RangedWeaponDef = shot.get("weapon") as RangedWeaponDef
		if weapon == null:
			finished.append(peer_id)
			continue
		shot["phase_elapsed"] = float(shot.get("phase_elapsed", 0.0)) + delta
		match int(shot.get("phase", Phase.IDLE)):
			Phase.WIND_UP:
				if float(shot["phase_elapsed"]) >= weapon.draw_seconds:
					_fire(peer_id, shot)
			Phase.COMMIT:
				_advance_flight(peer_id, shot, delta)
			Phase.RECOVERY:
				if float(shot["phase_elapsed"]) >= weapon.recovery_seconds:
					finished.append(peer_id)
	for peer_id: int in finished:
		_host_shots.erase(peer_id)


func _fire(peer_id: int, shot: Dictionary) -> void:
	var weapon: RangedWeaponDef = shot["weapon"]
	var request_id: int = int(shot.get("request_id", 0))
	var player: Node3D = _host_player(peer_id)
	# Re-checked, not just trusted from _begin_host_shot: the draw took real time, and another
	# consumer of the same ammo stack could have emptied it in between. A dry fire ends the action
	# cleanly instead of firing a phantom arrow.
	if player == null or InventoryService.host_count(peer_id, weapon.ammo_item_id) < 1:
		_broadcast_resolved(peer_id, request_id, false, Vector3.ZERO, 0, &"")
		shot["phase"] = Phase.RECOVERY
		shot["phase_elapsed"] = 0.0
		return
	# F-580: `arrow_save_chance` — the chance this shot does not consume its arrow
	# (docs/POWERUPS.md §2). Asked on a base of 0.0, so a peer holding neither `bottomless_quiver`
	# nor `fletchers_debt` rolls nothing and the arrow is always spent, exactly as before. Rolled on
	# the HOST's own stream: ammo is host-authoritative inventory state, and a client-rolled save
	# would be a client deciding whether it paid for its own shot.
	if not _saves_arrow(peer_id):
		InventoryService.host_remove(peer_id, weapon.ammo_item_id, 1)
	var direction: Vector3 = CombatAim.direction(player)
	var origin: Vector3 = CombatAim.eye_position(player) + direction * ARROW_SPAWN_OFFSET_M
	shot["position"] = origin
	shot["velocity"] = direction * weapon.projectile_speed_m_s
	shot["traveled_m"] = 0.0
	shot["phase"] = Phase.COMMIT
	shot["phase_elapsed"] = 0.0
	_broadcast_fired(
		peer_id, request_id, origin, direction, weapon.projectile_speed_m_s, weapon.gravity_scale,
		weapon.item_id, weapon.ammo_item_id
	)


## One raycast per physics tick between last and current position — the same shape as
## systems/enemies/enemy.gd's own line-of-sight ray, swept across the tick instead of a single point
## so a fast arrow cannot skip through a thin collider between two frames.
func _advance_flight(peer_id: int, shot: Dictionary, delta: float) -> void:
	var weapon: RangedWeaponDef = shot["weapon"]
	var prev_position: Vector3 = shot["position"]
	var velocity: Vector3 = shot["velocity"]
	velocity.y -= _gravity * weapon.gravity_scale * delta
	var new_position: Vector3 = prev_position + velocity * delta
	shot["velocity"] = velocity
	shot["position"] = new_position
	shot["traveled_m"] = float(shot.get("traveled_m", 0.0)) + (new_position - prev_position).length()

	var hit_node: Node = null
	var hit_position: Vector3 = new_position
	# A plain Node has no get_world_3d() of its own (that's Node3D/Viewport) — the main viewport's
	# world is reached through the tree instead, same physics space every Node3D in the game queries.
	var world: World3D = get_tree().root.get_world_3d() if is_inside_tree() else null
	if world != null and not prev_position.is_equal_approx(new_position):
		var exclude: Array[RID] = []
		var player: Node3D = _host_player(peer_id)
		# get_rid() is CollisionObject3D's, not Node3D's — true for the real PlayerController
		# (CharacterBody3D) but not guaranteed for a bare Node3D standing in for one in a test harness.
		# ARROW_SPAWN_OFFSET_M already moves the origin off the shooter's own body, so this exclusion
		# is belt-and-braces, not load-bearing — skip it rather than fail the whole tick.
		if player != null and player.has_method(&"get_rid"):
			exclude.append(player.get_rid())
		var query := PhysicsRayQueryParameters3D.create(
			prev_position, new_position, WORLD_COLLISION_MASK, exclude
		)
		var result: Dictionary = world.direct_space_state.intersect_ray(query)
		if not result.is_empty():
			hit_node = result.get("collider") as Node
			hit_position = result.get("position", new_position)

	if hit_node != null:
		_resolve_flight(peer_id, shot, hit_node, hit_position)
		return
	if float(shot["traveled_m"]) >= weapon.max_range_m:
		_broadcast_resolved(peer_id, int(shot.get("request_id", 0)), false, new_position, 0, &"")
		shot["phase"] = Phase.RECOVERY
		shot["phase_elapsed"] = 0.0


func _resolve_flight(peer_id: int, shot: Dictionary, hit_node: Node, hit_position: Vector3) -> void:
	var weapon: RangedWeaponDef = shot["weapon"]
	var request_id: int = int(shot.get("request_id", 0))
	# The raycast's own collider is not necessarily the &"damageable" node: Enemy/PlayerController are
	# CollisionObject3D themselves, but Harvestable is a plain Node3D that finds a CHILD
	# CollisionObject3D for its own collider (systems/harvesting/harvestable.gd's `_collision_body`) —
	# the exact inverse search, walking UP from the hit collider to whichever ancestor actually owns
	# the damage seam. A wall or any other collider with no damageable ancestor stays a plain miss.
	var damageable: Node = _damageable_owner(hit_node)
	# PvP is cut (DESIGN.md §7) — an arrow that reaches another player's own body never damages it,
	# even though `&"players"` members also carry `&"damageable"` for enemy hits to land on them.
	var valid_target: bool = (
		damageable != null
		and not damageable.is_in_group(&"players")
		and damageable.has_method(&"host_apply_damage")
	)
	# F-543: `bow_damage` scales ranged damage for the peer who fired (docs/POWERUPS.md §2; DESIGN
	# §4.5's Reaver is "better at melee/ranged damage", +15%). Host-side resolution, so `stat()` with
	# the shooter's real peer id. The SAME value is applied and reported, so the damage number the
	# HUD shows is the damage the target took.
	var applied: int = maxi(_modified_damage(peer_id, &"bow_damage", weapon.damage), 1)
	var connected: bool = valid_target and bool(damageable.call("host_apply_damage", applied, peer_id))
	if connected:
		# F-580: `on_hit_lifesteal`/`on_kill_heal_hp`, through CombatService's shared accumulator so
		# a bow hit and a melee hit feed one running remainder per peer rather than two that each
		# round their own fraction away.
		var melee: Node = get_node_or_null(^"/root/CombatService")
		if melee != null:
			melee.call(&"host_apply_hit_rewards", peer_id, applied, damageable)
		_broadcast_resolved(
			peer_id, request_id, true, hit_position, applied, StringName(String(damageable.name))
		)
	else:
		_broadcast_resolved(peer_id, request_id, false, hit_position, 0, &"")
	shot["phase"] = Phase.RECOVERY
	shot["phase_elapsed"] = 0.0


## Walks up from a raycast's own collider to the nearest ancestor (itself included) that joins
## &"damageable" — see the header comment above. Bounded depth: a runaway parent chain is a scene
## bug, not something this should hang trying to diagnose.
func _damageable_owner(node: Node) -> Node:
	var current: Node = node
	var depth: int = 0
	while current != null and depth < 8:
		if current.is_in_group(DAMAGEABLE_GROUP):
			return current
		current = current.get_parent()
		depth += 1
	return null


func _broadcast_fired(
	peer_id: int, request_id: int, origin: Vector3, direction: Vector3, speed: float,
	gravity_scale: float, weapon_item_id: StringName, ammo_item_id: StringName
) -> void:
	if NetTransport.is_active():
		net_shot_fired.rpc(peer_id, request_id, origin, direction, speed, gravity_scale, weapon_item_id, ammo_item_id)
	_apply_fired(peer_id, request_id, origin, direction, speed, gravity_scale, weapon_item_id, ammo_item_id)


func _broadcast_resolved(
	peer_id: int, request_id: int, hit: bool, position: Vector3, damage: int, target_name: StringName
) -> void:
	if NetTransport.is_active():
		net_shot_resolved.rpc(peer_id, request_id, hit, position, damage, target_name)
	_apply_resolved(peer_id, request_id, hit, position, damage, target_name)


func _reject(peer_id: int, request_id: int, detail: String) -> void:
	if peer_id == _local_peer_id():
		shot_rejected.emit(request_id, detail)
	elif NetTransport.is_active() and NetTransport.has_peer(peer_id):
		# Same F-059 shape as CombatService._reject: a shooter can drop mid-draw, between
		# net_request_shot and this rejection landing.
		net_shot_rejected.rpc_id(peer_id, request_id, detail)


# ── Client-local feel ─────────────────────────────────────────────────────────────────────────────

func _apply_fired(
	peer_id: int, _request_id: int, origin: Vector3, direction: Vector3, speed: float,
	gravity_scale: float, weapon_item_id: StringName, ammo_item_id: StringName
) -> void:
	_spawn_visual_projectile(peer_id, origin, direction, speed, gravity_scale, weapon_item_id, ammo_item_id)


func _apply_resolved(
	peer_id: int, _request_id: int, hit: bool, position: Vector3, damage: int, target_name: StringName
) -> void:
	var weapon: RangedWeaponDef = null
	if _flight_visuals.has(peer_id):
		weapon = _flight_visuals[peer_id].get("weapon") as RangedWeaponDef
	_despawn_visual_projectile(peer_id)
	if weapon == null:
		weapon = _feel_weapon()

	# F-327: local feel state is committed BEFORE the outcome is announced. Godot signal callbacks
	# are synchronous, so a listener connected to `shot_landed` runs inside the emit — and with the
	# old order it observed a confirmed hit while `_local_phase` still read the firing phase and
	# `_local_hitstop_remaining` still read zero. Any consumer that reacts to a landed shot by asking
	# "how long is the hitstop" got the answer from before the shot resolved. Nothing in the shipped
	# tree listens yet, which is exactly why this is the moment to fix the order rather than the
	# moment to document the hazard.
	if peer_id == _local_peer_id():
		_enter_local_recovery()
		if hit:
			_local_hitstop_remaining = weapon.hitstop_seconds
			var camera: Node = _local_camera()
			if camera != null and camera.has_method("add_shake"):
				camera.call("add_shake", weapon.shake_magnitude, weapon.shake_duration)

	if hit:
		shot_landed.emit(peer_id, position, damage, target_name)
		_play_impact(position, weapon)
	else:
		shot_missed.emit(peer_id, position)


func _feel_weapon() -> RangedWeaponDef:
	if _local_weapon != null:
		return _local_weapon
	if _last_local_weapon != null:
		return _last_local_weapon
	# No authored weapon known at all (a rejected/never-armed shot) — a zero-length placeholder that
	# is never actually fired keeps every caller's field reads safe without a null check each.
	var fallback := RangedWeaponDef.new()
	fallback.item_id = &"unknown_bow"
	return fallback


func _start_local_shot(weapon: RangedWeaponDef) -> void:
	_local_weapon = weapon
	_last_local_weapon = weapon
	_local_hitstop_remaining = 0.0
	_set_local_phase(Phase.WIND_UP)
	shot_started.emit(weapon.item_id)


## Hitstop stalls the local draw/recovery clock only, never Engine.time_scale (D-033, same reasoning
## as combat_service.gd's melee clock).
func _advance_local_shot(delta: float) -> void:
	if _local_phase == Phase.IDLE or _local_weapon == null:
		return
	if _local_hitstop_remaining > 0.0:
		_local_hitstop_remaining = maxf(_local_hitstop_remaining - delta, 0.0)
		return

	_local_phase_elapsed += delta
	match _local_phase:
		Phase.WIND_UP:
			if _local_phase_elapsed >= _local_weapon.draw_seconds:
				_set_local_phase(Phase.COMMIT)
		Phase.COMMIT:
			# Flight time is not known locally — this waits for _enter_local_recovery(), called the
			# instant the host's net_shot_resolved arrives for this peer.
			pass
		Phase.RECOVERY:
			if _local_phase_elapsed >= _local_weapon.recovery_seconds:
				_local_weapon = null
				_set_local_phase(Phase.IDLE)


## Called on the local peer's own resolution, regardless of what local phase prediction currently
## reads — the host deciding the shot is over is authoritative over the client's own guess at when
## the arrow landed.
func _enter_local_recovery() -> void:
	_set_local_phase(Phase.RECOVERY)


func _set_local_phase(phase: Phase) -> void:
	_local_phase_elapsed = 0.0
	if _local_phase == phase:
		return
	_local_phase = phase
	shot_phase_changed.emit(phase)


func _spawn_visual_projectile(
	peer_id: int, origin: Vector3, direction: Vector3, speed: float, gravity_scale: float,
	weapon_item_id: StringName, ammo_item_id: StringName
) -> void:
	_despawn_visual_projectile(peer_id)
	var weapon: RangedWeaponDef = Registry.get_ranged_weapon(weapon_item_id)
	var node: Node3D = null
	# The flying visual reuses the ammo item's OWN authored world_model (arrow_world.glb) — no new
	# asset, no new content to author, just the pickup mesh already shipped for `arrow` in flight.
	var ammo_item: ItemDef = Registry.get_item(ammo_item_id)
	if ammo_item != null and ammo_item.world_model != null and is_inside_tree():
		node = ammo_item.world_model.instantiate() as Node3D
		if node != null:
			node.name = "RangedShotVisual%d" % peer_id
			get_tree().root.add_child(node)
			node.global_position = origin
			if direction.length_squared() > 0.000001:
				node.look_at(origin + direction, Vector3.UP if absf(direction.y) < 0.999 else Vector3.FORWARD)
	_flight_visuals[peer_id] = {
		"node": node, "weapon": weapon, "origin": origin, "direction": direction, "speed": speed,
		"gravity_scale": gravity_scale, "elapsed": 0.0,
	}


func _advance_visual_projectiles(delta: float) -> void:
	if _flight_visuals.is_empty():
		return
	for peer_id: int in _flight_visuals:
		var visual: Dictionary = _flight_visuals[peer_id]
		var elapsed: float = float(visual.get("elapsed", 0.0)) + delta
		visual["elapsed"] = elapsed
		var node: Node3D = visual.get("node") as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var gravity_scale: float = float(visual.get("gravity_scale", 0.0))
		var drop: float = 0.5 * _gravity * gravity_scale * elapsed * elapsed
		var origin: Vector3 = visual.get("origin", Vector3.ZERO)
		var direction: Vector3 = visual.get("direction", Vector3.FORWARD)
		var speed: float = float(visual.get("speed", 0.0))
		node.global_position = origin + direction * speed * elapsed - Vector3.UP * drop


func _despawn_visual_projectile(peer_id: int) -> void:
	if not _flight_visuals.has(peer_id):
		return
	var node: Node3D = _flight_visuals[peer_id].get("node") as Node3D
	if node != null and is_instance_valid(node):
		node.queue_free()
	_flight_visuals.erase(peer_id)


func _play_impact(position: Vector3, weapon: RangedWeaponDef) -> void:
	var stream: AudioStream = weapon.impact_sound
	if stream == null:
		var combat: Node = get_node_or_null(^"/root/CombatService")
		stream = combat.call(&"placeholder_impact_sound") if combat != null else null
	if stream == null or not is_inside_tree():
		return
	var player := AudioStreamPlayer3D.new()
	player.name = "RangedImpact"
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

func _take_request_id() -> int:
	var result: int = _next_request_id
	_next_request_id += 1
	if _next_request_id <= 0:
		_next_request_id = 1
	return result


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


## F-543: this peer's version of the authored ranged damage. Same shape as CombatService's melee
## twin — a separate copy rather than a shared helper because these two services already keep their
## own resolution paths deliberately independent (one is a swing timeline, one is a raycast).
## F-580: does this peer's `arrow_save_chance` spare this shot's arrow? Clamped into 0..1 — an
## authored stack above 1.0 would otherwise mean an infinite quiver, which is a different powerup
## from the one either description promises.
func _saves_arrow(peer_id: int) -> bool:
	var powerups: Node = get_node_or_null(^"/root/PowerupService")
	if powerups == null:
		return false
	var chance: float = clampf(
		float(powerups.call(&"stat", peer_id, &"arrow_save_chance", 0.0)), 0.0, 1.0
	)
	if chance <= 0.0:
		return false
	return _rng.randf() < chance


func _modified_damage(peer_id: int, stat_name: StringName, base: int) -> int:
	var powerups: Node = get_node_or_null(^"/root/PowerupService")
	if powerups == null:
		return base
	return int(roundi(float(powerups.call(&"stat", peer_id, stat_name, float(base)))))
