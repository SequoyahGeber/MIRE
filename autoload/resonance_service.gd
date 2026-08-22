extends Node

## ResonanceService — autoload. The twelve effects `DESIGN.md` §4.4 promises and the project never
## had (F-585). Holding 3+ powerups of a family triggers a **Resonance**; 6+ upgrades it to a
## **Greater Resonance**. `PowerupService` has always counted the thresholds correctly and fired
## `resonance_changed`; until this file, the only thing listening was a sound.
##
##     | Family  | Resonance (3+)                   | Greater (6+)                                  |
##     | Blood   | kills heal you                   | kills heal the team, you take double damage   |
##     | Fungal  | corpses sprout spore clouds      | spores spread; you can walk in Mire safely    |
##     | Kinetic | sprinting builds a damage charge | the charge releases as a knock-back shockwave |
##     | Fire    | attacks ignite                   | ignited enemies explode, chaining             |
##     | Cold    | attacks slow                     | frozen enemies shatter for area damage        |
##     | Void    | dodge blinks                     | blinking leaves a damaging rift               |
##
## ## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2)
##
## **Mostly HOST.** Everything that damages, heals, ignites, spawns a field or moves an enemy runs in
## the host process, reached from seams that are already host-only: `CombatService._resolve_hit()`,
## `Enemy._enter_death()`, `EventBus.enemy_killed`. Two things are necessarily client-local, both on
## the "own movement is client-authoritative" row:
##
##   · **Kinetic's charge** builds from sprinting, and only the owning peer knows it is sprinting.
##     The client reports a FULL charge to the host (`net_report_charge`), which the host rate-limits
##     to no faster than the charge could honestly be earned — a client that lies gets one charge per
##     `CHARGE_SECONDS` and nothing more, which is what it would have got anyway.
##   · **Void's blink** extends a dodge, and the dodge itself is client-authoritative movement. The
##     displacement is applied locally; the rift it leaves is REQUESTED of the host, which checks the
##     requester actually holds the Greater Resonance before spawning anything.
##
## Nothing here is a stat. That is the whole point of §4.4: a Resonance is qualitative, so it cannot
## be expressed as `(base + add·N)·(1 + mult·N)` and does not belong in `PowerupService.stat()`. This
## service ASKS PowerupService for the tier and implements the behaviour itself, which is the same
## direction of dependency every other consumer of the powerup layer uses.

const HAZARD_FIELD := preload("res://systems/combat/hazard_field.gd")

const LOG_CHANNEL: StringName = &"powerup"

const FAMILY_BLOOD: StringName = &"Blood"
const FAMILY_FUNGAL: StringName = &"Fungal"
const FAMILY_KINETIC: StringName = &"Kinetic"
const FAMILY_FIRE: StringName = &"Fire"
const FAMILY_COLD: StringName = &"Cold"
const FAMILY_VOID: StringName = &"Void"

## Every family that has an implementation here. `tools/resonance_check.gd` asserts this covers
## `PowerupDef.KNOWN_FAMILIES` exactly — a seventh family added to the vocabulary without an effect
## in this file is the exact regrowth of F-580/F-585 that check exists to prevent.
const IMPLEMENTED_FAMILIES: Array[StringName] = [
	FAMILY_BLOOD, FAMILY_FUNGAL, FAMILY_KINETIC, FAMILY_FIRE, FAMILY_COLD, FAMILY_VOID,
]

# ── Tuning. Every number a designer would want to move, in one block. ─────────────────────────────

## Fire. The burn is deliberately weaker than a swing: it is pressure and a tag for the Greater
## Resonance to chain from, not a replacement for hitting things.
const FIRE_BURN_SECONDS: float = 4.0
const FIRE_BURN_DAMAGE_PER_TICK: float = 2.0
const FIRE_GREATER_BLAST_RADIUS_M: float = 4.0
const FIRE_GREATER_BLAST_DAMAGE: int = 14
## The chain re-ignites what the blast touched, which is what makes a burning pack cascade. The
## chained burn is SHORTER than the original: an infinite chain through a dense spawn is the failure
## mode, and a decaying one still reads as a cascade.
const FIRE_CHAIN_BURN_SECONDS: float = 2.0

## Cold. Slow enough to change how a pack closes on you, never enough to stop it (`StatusService`
## clamps this again at MAX_SLOW_FRACTION).
const COLD_CHILL_SECONDS: float = 3.0
const COLD_CHILL_FRACTION: float = 0.35
const COLD_GREATER_SHATTER_RADIUS_M: float = 4.5
const COLD_GREATER_SHATTER_DAMAGE: int = 20

## Blood. Small per kill and reliable, rather than a burst — DESIGN.md's Blood is sustain.
const BLOOD_KILL_HEAL_HP: int = 4
const BLOOD_GREATER_TEAM_HEAL_HP: int = 3
## "You take double damage" — the cost that makes the Greater Resonance a decision.
const BLOOD_GREATER_DAMAGE_MULTIPLIER: float = 2.0

## Fungal. A corpse becomes ground you own for a few seconds.
const FUNGAL_SPORE_RADIUS_M: float = 3.0
const FUNGAL_SPORE_SECONDS: float = 6.0
const FUNGAL_SPORE_DAMAGE_PER_TICK: int = 3
## Spread is capped by depth, not by count: one cloud can seed another, and that one cannot seed a
## third. Without a bound, a dense fight turns the whole island into spores.
const FUNGAL_SPREAD_RADIUS_M: float = 2.2
const FUNGAL_SPREAD_SECONDS: float = 3.0

## Kinetic. `CHARGE_SECONDS` of sprinting buys one charged hit.
const KINETIC_CHARGE_SECONDS: float = 3.0
const KINETIC_CHARGE_BONUS_DAMAGE: int = 12
const KINETIC_GREATER_SHOCKWAVE_RADIUS_M: float = 5.0
const KINETIC_GREATER_SHOCKWAVE_IMPULSE: float = 9.0
const KINETIC_GREATER_STAGGER_SECONDS: float = 1.2

## Void. The blink is the dash, again — far enough to cross a creature, not a teleport across a room.
const VOID_BLINK_EXTRA_METRES: float = 4.5
const VOID_RIFT_RADIUS_M: float = 2.5
const VOID_RIFT_SECONDS: float = 4.0
const VOID_RIFT_DAMAGE_PER_TICK: int = 5

## Field presets, so the wire carries a name rather than six floats and every peer builds the same
## thing from its own copy of these constants.
const PRESET_SPORE: StringName = &"spore"
const PRESET_RIFT: StringName = &"rift"
const PRESET_SHATTER: StringName = &"shatter"
const PRESET_BLAST: StringName = &"blast"

var _transport_node: Node
var _powerup_node: Node
var _status_node: Node

## Client-local, owning peer only: how much sprint time is banked toward the next charge.
var _local_charge_progress: float = 0.0
var _local_charge_ready: bool = false
## Host-side: peer id -> whether a charged hit is waiting to be spent, and when it was granted. The
## timestamp is the anti-spam clamp described in the header.
var _charged_peers: Dictionary[int, float] = {}
var _elapsed: float = 0.0
## Presentation-adjacent randomness for the per-hit `ignite_chance`/`slow_chance` rolls. Its own
## generator, never the global `randi()` (AGENTS.md): these rolls happen on the host inside combat
## resolution and must not perturb any seeded world stream sharing the global sequence.
var _rng := RandomNumberGenerator.new()

## Fires on the peer that owns the charge when it fills or is spent — the HUD hangs off this.
signal local_charge_changed(ready: bool, progress: float)
## Fires wherever an effect resolves, for audio and for checks. `family` is the family that did it.
signal resonance_fired(family: StringName, greater: bool, world_position: Vector3)


func _ready() -> void:
	_rng.randomize()
	process_mode = Node.PROCESS_MODE_PAUSABLE
	set_physics_process(true)
	var bus := preload("res://core/events/event_bus.gd")
	bus.subscribe_enemy_killed(_on_enemy_killed)
	bus.subscribe_run_restarted(_on_run_restarted)


func _exit_tree() -> void:
	var bus := preload("res://core/events/event_bus.gd")
	bus.unsubscribe_enemy_killed(_on_enemy_killed)
	bus.unsubscribe_run_restarted(_on_run_restarted)


func _physics_process(delta: float) -> void:
	_elapsed += delta


func _on_run_restarted() -> void:
	_charged_peers.clear()
	_local_charge_progress = 0.0
	_set_local_charge_ready(false)


# ── Threshold queries ────────────────────────────────────────────────────────────────────────────


## Whether `peer_id` holds the Resonance for `family` (3+). Host-side truth; on a client this is only
## answerable for the local peer, which is exactly what the client-local effects ask about.
func active(peer_id: int, family: StringName) -> bool:
	var powerups: Node = _powerups()
	if powerups == null:
		return false
	return bool(powerups.call(&"resonance_active", peer_id, family))


func greater(peer_id: int, family: StringName) -> bool:
	var powerups: Node = _powerups()
	if powerups == null:
		return false
	return bool(powerups.call(&"greater_resonance_active", peer_id, family))


# ── Fire, Cold and Kinetic: the hit seam ─────────────────────────────────────────────────────────


## Called by `CombatService` and `RangedCombatService` the moment a hit has actually landed, on the
## host. Returns **bonus damage** to add — Kinetic's charge — and applies whatever statuses the
## attacker's Resonances call for.
##
## Returning the bonus rather than applying it separately keeps a charged hit ONE damage event: two
## events would flinch the creature twice, pay two kill bounties' worth of lifesteal, and let armour
## round the small half away.
func host_on_hit(peer_id: int, target: Node, damage: int) -> int:
	if not _owns_simulation() or peer_id <= 0 or target == null or not is_instance_valid(target):
		return 0
	var status: Node = _status()

	# ── The QUANTITATIVE half: F-580's last three unread stats. ──────────────────────────────────
	# `ignite_chance` and `slow_chance` are probabilities per hit, and `slow_potency` scales how hard
	# the resulting chill bites. They live here rather than in `CombatService` because they apply the
	# same two statuses the Fire and Cold Resonances do, and one place deciding "this hit ignites"
	# is what keeps a player holding both from getting two competing burns.
	var powerups: Node = _powerups()
	if powerups != null and status != null:
		var ignite_chance: float = float(powerups.call(&"stat", peer_id, &"ignite_chance", 0.0))
		if ignite_chance > 0.0 and _rng.randf() < ignite_chance:
			status.call(&"host_apply", target, &"burning", FIRE_BURN_SECONDS,
				FIRE_BURN_DAMAGE_PER_TICK, peer_id)
		var slow_chance: float = float(powerups.call(&"stat", peer_id, &"slow_chance", 0.0))
		if slow_chance > 0.0 and _rng.randf() < slow_chance:
			# A base of COLD_CHILL_FRACTION, not zero: `slow_potency` is authored as a multiplier on
			# "how slowing a slow is", and asking for it against zero returns zero however many
			# stacks you hold — the exact shape of bug F-140 was filed about.
			var potency: float = float(
				powerups.call(&"stat", peer_id, &"slow_potency", COLD_CHILL_FRACTION)
			)
			status.call(&"host_apply", target, &"chilled", COLD_CHILL_SECONDS, potency, peer_id)

	# ── The QUALITATIVE half: the Resonances themselves. ─────────────────────────────────────────
	# Fire — attacks ignite.
	if status != null and active(peer_id, FAMILY_FIRE):
		status.call(&"host_apply", target, &"burning", FIRE_BURN_SECONDS,
			FIRE_BURN_DAMAGE_PER_TICK, peer_id)

	# Cold — attacks slow.
	if status != null and active(peer_id, FAMILY_COLD):
		status.call(&"host_apply", target, &"chilled", COLD_CHILL_SECONDS,
			COLD_CHILL_FRACTION, peer_id)

	# Kinetic — spend the charge, if one is banked.
	var bonus: int = 0
	if _charged_peers.has(peer_id) and active(peer_id, FAMILY_KINETIC):
		_charged_peers.erase(peer_id)
		bonus = KINETIC_CHARGE_BONUS_DAMAGE
		_notify_charge_spent(peer_id)
		var origin: Vector3 = (target as Node3D).global_position if target is Node3D else Vector3.ZERO
		resonance_fired.emit(FAMILY_KINETIC, greater(peer_id, FAMILY_KINETIC), origin)
		if greater(peer_id, FAMILY_KINETIC):
			_shockwave(peer_id, origin)
	return bonus


## Called by `Enemy._enter_death()` on the host, BEFORE the enemy's statuses are cleared — Fire's and
## Cold's Greater Resonances both key off what the creature was carrying when it died, so the order
## is load-bearing rather than incidental.
func host_on_enemy_death(enemy: Node, instigator_peer_id: int) -> void:
	if not _owns_simulation() or enemy == null or not is_instance_valid(enemy):
		return
	var position: Vector3 = (enemy as Node3D).global_position if enemy is Node3D else Vector3.ZERO
	var status: Node = _status()

	# Fire 6 — an ignited enemy explodes, and the blast re-ignites what it catches.
	var was_burning: bool = status != null and bool(status.call(&"is_burning", enemy))
	if was_burning and greater(instigator_peer_id, FAMILY_FIRE):
		_blast(instigator_peer_id, position, FIRE_GREATER_BLAST_RADIUS_M,
			FIRE_GREATER_BLAST_DAMAGE, enemy)
		_spawn_field(PRESET_BLAST, position, instigator_peer_id)
		resonance_fired.emit(FAMILY_FIRE, true, position)

	# Cold 6 — a frozen enemy shatters.
	var was_chilled: bool = status != null and bool(status.call(&"is_chilled", enemy))
	if was_chilled and greater(instigator_peer_id, FAMILY_COLD):
		_blast(instigator_peer_id, position, COLD_GREATER_SHATTER_RADIUS_M,
			COLD_GREATER_SHATTER_DAMAGE, enemy)
		_spawn_field(PRESET_SHATTER, position, instigator_peer_id)
		resonance_fired.emit(FAMILY_COLD, true, position)

	# Fungal 3 — the corpse sprouts.
	if active(instigator_peer_id, FAMILY_FUNGAL):
		_spawn_field(PRESET_SPORE, position, instigator_peer_id)
		resonance_fired.emit(FAMILY_FUNGAL, greater(instigator_peer_id, FAMILY_FUNGAL), position)

	if status != null:
		status.call(&"host_clear", enemy)


## Area damage that skips one node — the corpse that caused it. Applied through each enemy's own
## `host_apply_damage()` so armour and bounties behave, and credited to the player whose Resonance
## fired it.
func _blast(peer_id: int, origin: Vector3, radius_m: float, damage: int, exclude: Node) -> void:
	var radius_squared: float = radius_m * radius_m
	var status: Node = _status()
	var chain: bool = greater(peer_id, FAMILY_FIRE)
	for node: Node in get_tree().get_nodes_in_group(&"enemies"):
		var enemy := node as Node3D
		if enemy == null or enemy == exclude or not is_instance_valid(enemy):
			continue
		if enemy.has_method(&"is_alive") and not bool(enemy.call(&"is_alive")):
			continue
		var offset: Vector3 = enemy.global_position - origin
		offset.y = 0.0
		if offset.length_squared() > radius_squared:
			continue
		if enemy.has_method(&"host_apply_damage"):
			enemy.call(&"host_apply_damage", damage, peer_id)
		# The chain: whatever survived the blast is now on fire, and will explode in turn. The
		# shorter burn is what makes it decay rather than run forever.
		if chain and status != null and is_instance_valid(enemy):
			status.call(&"host_apply", enemy, &"burning", FIRE_CHAIN_BURN_SECONDS,
				FIRE_BURN_DAMAGE_PER_TICK, peer_id)


# ── Blood: the kill seam ─────────────────────────────────────────────────────────────────────────


## `EventBus.enemy_killed` fires on the host, once, from `Enemy._enter_death()`.
func _on_enemy_killed(_enemy_id: StringName, _coin_min: int, _coin_max: int,
		instigator_peer_id: int, world_position: Vector3) -> void:
	if not _owns_simulation() or instigator_peer_id <= 0:
		return
	if not active(instigator_peer_id, FAMILY_BLOOD):
		return
	var health: Node = get_node_or_null(^"/root/PlayerHealth")
	if health == null:
		return
	health.call(&"host_heal", instigator_peer_id, BLOOD_KILL_HEAL_HP)
	var is_greater: bool = greater(instigator_peer_id, FAMILY_BLOOD)
	if is_greater:
		# "Kills heal the whole team." Everyone present, including the killer, who therefore gets
		# both halves — the Greater Resonance is strictly better at healing and strictly worse at
		# surviving, which is the trade §4.4 describes.
		for peer_id: int in _present_peers():
			if peer_id != instigator_peer_id:
				health.call(&"host_heal", peer_id, BLOOD_GREATER_TEAM_HEAL_HP)
	resonance_fired.emit(FAMILY_BLOOD, is_greater, world_position)


## Blood's Greater Resonance costs you double. Called by `PlayerHealth` where it already computes
## `damage_taken`; returns `amount` unchanged for everyone else, so the read is safe unconditionally.
func modify_damage_taken(peer_id: int, amount: int) -> int:
	if amount <= 0 or not greater(peer_id, FAMILY_BLOOD):
		return amount
	return int(roundf(float(amount) * BLOOD_GREATER_DAMAGE_MULTIPLIER))


## Fungal's Greater Resonance is "you can walk in Mire safely". Called by `PlayerHealth._tick_blight()`
## where it applies `blight_rate`; returns zero for a peer six-deep in Fungal, and `rate` for anyone
## else. Zero rather than a reduction on purpose — §4.4 says *safely*, and a player who has committed
## six powerup slots to a family should get the sentence they were promised.
func modify_blight_rate(peer_id: int, rate: float) -> float:
	if rate <= 0.0 or not greater(peer_id, FAMILY_FUNGAL):
		return rate
	return 0.0


# ── Kinetic: the charge ──────────────────────────────────────────────────────────────────────────


## Client-local, once per physics frame on the owning peer, while sprinting. `PlayerController` calls
## it where it already knows it is sprinting and on the ground.
func local_sprint_tick(delta: float) -> void:
	var peer_id: int = _local_peer_id()
	if delta <= 0.0 or not active(peer_id, FAMILY_KINETIC):
		return
	if _local_charge_ready:
		return
	_local_charge_progress += delta
	local_charge_changed.emit(false, clampf(_local_charge_progress / KINETIC_CHARGE_SECONDS, 0.0, 1.0))
	if _local_charge_progress < KINETIC_CHARGE_SECONDS:
		return
	_local_charge_progress = 0.0
	_set_local_charge_ready(true)
	if _transport_is_active() and not _transport_is_host():
		net_report_charge.rpc_id(NetConfig.HOST_PEER_ID)
	else:
		_host_grant_charge(_local_peer_id())


func local_charge_ready() -> bool:
	return _local_charge_ready


func local_charge_progress() -> float:
	return clampf(_local_charge_progress / KINETIC_CHARGE_SECONDS, 0.0, 1.0)


@rpc("any_peer", "call_remote", "reliable")
func net_report_charge() -> void:
	if not _transport_is_host():
		return
	_host_grant_charge(multiplayer.get_remote_sender_id())


## Rate-limited on the host. A client cannot earn a charge faster than sprinting for
## `KINETIC_CHARGE_SECONDS` would earn it, so the worst a lying client achieves is the charge rate it
## already had. This is the honest shape for a client-authoritative input feeding a host-side effect:
## trust the report, bound the rate.
func _host_grant_charge(peer_id: int) -> void:
	if peer_id <= 0 or not active(peer_id, FAMILY_KINETIC):
		return
	var last: float = float(_charged_peers.get(peer_id, -INF))
	if _elapsed - last < KINETIC_CHARGE_SECONDS:
		return
	_charged_peers[peer_id] = _elapsed


func host_has_charge(peer_id: int) -> bool:
	return _charged_peers.has(peer_id)


func _notify_charge_spent(peer_id: int) -> void:
	if peer_id == _local_peer_id():
		_set_local_charge_ready(false)
		return
	if _transport_is_active() and _peer_connected(peer_id):
		net_charge_spent.rpc_id(peer_id)


@rpc("authority", "call_remote", "reliable")
func net_charge_spent() -> void:
	_set_local_charge_ready(false)


func _set_local_charge_ready(ready: bool) -> void:
	if _local_charge_ready == ready:
		return
	_local_charge_ready = ready
	if not ready:
		_local_charge_progress = 0.0
	local_charge_changed.emit(ready, 1.0 if ready else 0.0)


## Kinetic 6. Knocks every enemy in range away from the impact and staggers it. Enemies are
## host-simulated, so this is nothing like `PlayerController.local_apply_knockback()` — there is no
## client half and no `knockback_taken` stat, which is a player's stat.
func _shockwave(peer_id: int, origin: Vector3) -> void:
	var radius_squared: float = KINETIC_GREATER_SHOCKWAVE_RADIUS_M * KINETIC_GREATER_SHOCKWAVE_RADIUS_M
	var status: Node = _status()
	for node: Node in get_tree().get_nodes_in_group(&"enemies"):
		var enemy := node as Node3D
		if enemy == null or not is_instance_valid(enemy):
			continue
		if enemy.has_method(&"is_alive") and not bool(enemy.call(&"is_alive")):
			continue
		var offset: Vector3 = enemy.global_position - origin
		offset.y = 0.0
		if offset.length_squared() > radius_squared:
			continue
		if enemy.has_method(&"host_apply_knockback"):
			enemy.call(&"host_apply_knockback", offset, KINETIC_GREATER_SHOCKWAVE_IMPULSE)
		if status != null:
			status.call(&"host_apply", enemy, &"staggered", KINETIC_GREATER_STAGGER_SECONDS,
				1.0, peer_id)


# ── Void: the blink ──────────────────────────────────────────────────────────────────────────────


## Client-local, from `PlayerController._execute_dodge()` on the owning peer. Returns the extra
## distance the dash should cover — zero for a player without the Resonance, so the caller adds it
## unconditionally. The rift is requested of the host separately, because a damaging volume is world
## mutation and a client never spawns one.
func local_on_dodge(origin: Vector3) -> float:
	var peer_id: int = _local_peer_id()
	if not active(peer_id, FAMILY_VOID):
		return 0.0
	resonance_fired.emit(FAMILY_VOID, greater(peer_id, FAMILY_VOID), origin)
	if greater(peer_id, FAMILY_VOID):
		if _transport_is_active() and not _transport_is_host():
			net_request_rift.rpc_id(NetConfig.HOST_PEER_ID, origin)
		else:
			_host_open_rift(_local_peer_id(), origin)
	return VOID_BLINK_EXTRA_METRES


@rpc("any_peer", "call_remote", "reliable")
func net_request_rift(origin: Vector3) -> void:
	if not _transport_is_host():
		return
	_host_open_rift(multiplayer.get_remote_sender_id(), origin)


## Host-side validation of a client's request: it opens a rift only for a peer that genuinely holds
## the Greater Resonance. The position is taken as given — a client that lies about where it dodged
## from gets a rift somewhere useless, which is not worth a round trip to disprove.
func _host_open_rift(peer_id: int, origin: Vector3) -> void:
	if not _owns_simulation() or peer_id <= 0:
		return
	if not greater(peer_id, FAMILY_VOID):
		return
	_spawn_field(PRESET_RIFT, origin, peer_id)


# ── Fields ───────────────────────────────────────────────────────────────────────────────────────


## Builds the host's simulating field and tells every client to build a matching visual one. Both
## halves read the same preset table, so the wire carries a name and a place rather than a
## description of the effect.
func _spawn_field(preset: StringName, position: Vector3, source_peer_id: int) -> void:
	_build_field(preset, position, source_peer_id, true)
	if _transport_is_host() and _transport_is_active():
		net_spawn_field.rpc(preset, position)


@rpc("authority", "call_remote", "reliable")
func net_spawn_field(preset: StringName, position: Vector3) -> void:
	_build_field(preset, position, 0, false)


func _build_field(preset: StringName, position: Vector3, source_peer_id: int,
		simulate: bool) -> Node3D:
	var field := Node3D.new()
	field.set_script(HAZARD_FIELD)
	field.name = "Hazard_%s" % preset
	field.set(&"simulate", simulate)
	field.set(&"source_peer_id", source_peer_id)
	match preset:
		PRESET_SPORE:
			field.set(&"radius_m", FUNGAL_SPORE_RADIUS_M)
			field.set(&"seconds", FUNGAL_SPORE_SECONDS)
			field.set(&"damage_per_tick", FUNGAL_SPORE_DAMAGE_PER_TICK)
			field.set(&"tint", Color(0.55, 0.83, 0.42))
		PRESET_RIFT:
			field.set(&"radius_m", VOID_RIFT_RADIUS_M)
			field.set(&"seconds", VOID_RIFT_SECONDS)
			field.set(&"damage_per_tick", VOID_RIFT_DAMAGE_PER_TICK)
			field.set(&"tint", Color(0.66, 0.42, 0.95))
		PRESET_SHATTER:
			# The damage already landed as an instant blast; this is the ice hanging in the air
			# afterwards, and it chills whatever walks through it.
			field.set(&"radius_m", COLD_GREATER_SHATTER_RADIUS_M)
			field.set(&"seconds", 1.2)
			field.set(&"damage_per_tick", 0)
			field.set(&"status_kind", &"chilled")
			field.set(&"status_seconds", COLD_CHILL_SECONDS)
			field.set(&"status_potency", COLD_CHILL_FRACTION)
			field.set(&"tint", Color(0.48, 0.80, 1.0))
		PRESET_BLAST:
			field.set(&"radius_m", FIRE_GREATER_BLAST_RADIUS_M)
			field.set(&"seconds", 0.9)
			field.set(&"damage_per_tick", 0)
			field.set(&"tint", Color(1.0, 0.45, 0.12))
		_:
			push_warning("ResonanceService: unknown field preset '%s'" % preset)
			field.queue_free()
			return null
	_field_parent().add_child(field)
	field.global_position = position
	# Fungal's Greater Resonance: a cloud seeds another cloud on whatever it touches. Connected only
	# on the simulating copy, and only for a spore field, so a visual-only client copy can never
	# spawn anything and a rift can never sprout mushrooms.
	if simulate and preset == PRESET_SPORE and greater(source_peer_id, FAMILY_FUNGAL):
		field.connect(&"touched", _on_spores_touched.bind(source_peer_id))
	return field


## The spread, bounded by construction: this handler is only ever attached to a full-size spore
## field, and what it spawns is a SMALLER, shorter one with no `touched` connection of its own. One
## generation, then it stops.
func _on_spores_touched(target: Node, source_peer_id: int) -> void:
	if not _owns_simulation() or target == null or not is_instance_valid(target):
		return
	var target_3d := target as Node3D
	if target_3d == null:
		return
	var seeded := _build_field(PRESET_SPORE, target_3d.global_position, source_peer_id, true)
	if seeded == null:
		return
	seeded.set(&"radius_m", FUNGAL_SPREAD_RADIUS_M)
	seeded.set(&"seconds", FUNGAL_SPREAD_SECONDS)
	if _transport_is_host() and _transport_is_active():
		net_spawn_field.rpc(PRESET_SPORE, target_3d.global_position)


## Fields live under the current scene so a run restart, which rebuilds it, takes them with it. In a
## headless check there may be no current scene; the tree root is then the only parent available.
func _field_parent() -> Node:
	var scene: Node = get_tree().current_scene
	return scene if scene != null else get_tree().root


# ── Internals ────────────────────────────────────────────────────────────────────────────────────


func _present_peers() -> PackedInt32Array:
	var transport: Node = _transport()
	if transport == null or not _transport_is_active():
		return PackedInt32Array([NetConfig.HOST_PEER_ID])
	var peers: PackedInt32Array = transport.call("peer_ids")
	var out := PackedInt32Array([NetConfig.HOST_PEER_ID])
	for peer_id: int in peers:
		if peer_id != NetConfig.HOST_PEER_ID:
			out.append(peer_id)
	return out


func _powerups() -> Node:
	if _powerup_node == null or not is_instance_valid(_powerup_node):
		_powerup_node = get_node_or_null(^"/root/PowerupService")
	return _powerup_node


func _status() -> Node:
	if _status_node == null or not is_instance_valid(_status_node):
		_status_node = get_node_or_null(^"/root/StatusService")
	return _status_node


func _owns_simulation() -> bool:
	var transport: Node = _transport()
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _transport_is_host() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_host"))


func _transport_is_active() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_active"))


func _peer_connected(peer_id: int) -> bool:
	var transport: Node = _transport()
	return transport != null and (transport.call("peer_ids") as PackedInt32Array).has(peer_id)


func _local_peer_id() -> int:
	var transport: Node = _transport()
	if transport == null or not _transport_is_active():
		return NetConfig.HOST_PEER_ID
	return int(transport.call("local_peer_id"))


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node_or_null(^"/root/NetTransport")
	return _transport_node
