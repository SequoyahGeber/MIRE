extends Node

## StatusService — autoload. Combat statuses that live on a target for a while: **Burning** (damage
## over time) and **Chilled** (slowed), plus **Staggered** (briefly unable to act), which Kinetic's
## Greater Resonance needs.
##
## Why this exists at all (F-580, F-585): `PowerupDef.KNOWN_STATS` has named `ignite_chance`,
## `slow_chance` and `slow_potency` since the vocabulary was settled, and `DESIGN.md` §4.4 promises
## "attacks ignite" and "attacks slow" as the Fire and Cold Resonances. None of it could be wired,
## because **burning and chilled did not exist**. This file is the missing mechanism, and it is
## deliberately one system rather than two: a status is a status, and Fire and Cold differing only in
## what their potency MEANS is what keeps a third status (poison, bleed) a data question later.
##
## ## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Enemy AI, spawns, damage" row): HOST.
##
## Only the host applies, ticks and expires a status, and only the host turns a burn tick into
## damage — through the target's own `host_apply_damage()`, so armour, death, kill bounty and the
## instigator's own lifesteal all behave exactly as they do for a sword. Clients hold a **mirror**
## for two purposes and no others: the VFX on the burning creature, and `speed_scale()`, which the
## enemy reads on the host anyway but which a client may legitimately ask when it is smoothing.
## The mirror arrives through one broadcast (`net_status_changed`), which carries the target's
## NodePath — enemies are spawned through a `MultiplayerSpawner`, so their paths are identical on
## every peer by construction, the same assumption `NetInterp.attach_to()` already makes.
##
## Nothing here decides WHO gets a status. That is `ResonanceService` (the qualitative layer) and the
## `ignite_chance`/`slow_chance` stats (the quantitative one), both of which call `host_apply()`.

const LOG_CHANNEL: StringName = &"combat"

## The three kinds. A status a target does not have costs nothing to ask about, so consumers query
## freely rather than caching.
const BURNING: StringName = &"burning"
const CHILLED: StringName = &"chilled"
const STAGGERED: StringName = &"staggered"

const KINDS: Array[StringName] = [BURNING, CHILLED, STAGGERED]

## Burn damage lands on a tick rather than per-frame. Half a second is slow enough that the number
## reads as a series of hits (and each one flinches the creature, which is the feedback), and fast
## enough that a three-second burn is six of them rather than a lump at the end.
const BURN_TICK_SEC: float = 0.5
## A chill can never stop a creature dead — an enemy at zero speed is a stunlock, and DESIGN.md's
## fights are about position, not about denial. Cold's Greater Resonance kills a frozen enemy by
## shattering it, not by freezing it forever.
const MAX_SLOW_FRACTION: float = 0.75

## Defaults every caller may override. These are the "one stack of the cheapest Fire powerup" values;
## Resonance passes its own.
const DEFAULT_BURN_SECONDS: float = 4.0
const DEFAULT_BURN_DAMAGE_PER_TICK: float = 2.0
const DEFAULT_CHILL_SECONDS: float = 3.0
const DEFAULT_CHILL_FRACTION: float = 0.35
const DEFAULT_STAGGER_SECONDS: float = 1.0

## Host-side and mirrored: instance id -> { kind -> { "expires_at", "potency", "source", "accum" } }.
## Keyed by instance id rather than by node so a freed target cannot keep a reference alive; the node
## itself is stored beside it and validated before every use.
var _statuses: Dictionary[int, Dictionary] = {}
var _nodes: Dictionary[int, Node] = {}
## instance id -> { kind -> Node3D }, the VFX this service attached. Attached as CHILDREN of the
## target on purpose: it means burning needs no cooperation from `enemy.gd` to be visible, and a
## target that dies and frees takes its own fire with it.
var _vfx: Dictionary[int, Dictionary] = {}

var _transport_node: Node
var _elapsed: float = 0.0

## Fires on every peer when a status starts or ends on a target. Presentation and gameplay hooks
## (ResonanceService's shatter and explode) both hang off it rather than polling.
signal status_changed(target: Node, kind: StringName, active: bool)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	set_physics_process(true)


# ── Host mutation ────────────────────────────────────────────────────────────────────────────────


## Applies (or refreshes) a status. Returns whether the target now carries it.
##
## **Refresh, never stack.** A second application takes the LONGER remaining time and the STRONGER
## potency, rather than adding either. Stacking duration is how a mob ends up burning for ninety
## seconds after one fight; stacking potency is how a six-player party one-shots everything by all
## igniting the same target. Taking the max of each keeps a second Fire source meaningful (it can
## upgrade a weak burn) without either failure.
func host_apply(target: Node, kind: StringName, seconds: float, potency: float,
		source_peer_id: int = 0) -> bool:
	if not _owns_simulation():
		return false
	if target == null or not is_instance_valid(target) or seconds <= 0.0:
		return false
	if not KINDS.has(kind):
		push_warning("StatusService: unknown status kind '%s'" % kind)
		return false
	# A status on something that cannot take damage or cannot move is meaningless, and a corpse
	# catching fire is worse than meaningless — Fire's Greater Resonance chains off burning enemies,
	# so a corpse that can be re-ignited is an infinite chain.
	if not _is_valid_target(target):
		return false
	if kind == CHILLED:
		potency = clampf(potency, 0.0, MAX_SLOW_FRACTION)
	elif potency < 0.0:
		potency = 0.0

	var id: int = target.get_instance_id()
	var held: Dictionary = _statuses.get(id, {})
	var existing: Dictionary = held.get(kind, {})
	var now: float = _elapsed
	var expires_at: float = maxf(float(existing.get("expires_at", now)), now + seconds)
	var strongest: float = maxf(float(existing.get("potency", 0.0)), potency)
	var fresh: bool = existing.is_empty()

	held[kind] = {
		"expires_at": expires_at,
		"potency": strongest,
		# The peer credited with the damage a burn deals. Kept from the FIRST application: whoever
		# set it alight owns the kill, and letting a later re-ignite steal the bounty would make
		# tagging a burning enemy the optimal play in a six-player run.
		"source": int(existing.get("source", source_peer_id)),
		"accum": float(existing.get("accum", 0.0)),
	}
	_statuses[id] = held
	_nodes[id] = target
	if fresh:
		_announce(target, kind, true)
	return true


## Clears one kind, or every kind when `kind` is empty. Called by a target that is about to die or
## despawn, and by the run reset.
func host_clear(target: Node, kind: StringName = &"") -> void:
	if target == null:
		return
	_clear_local(target.get_instance_id(), kind)
	if _transport_is_host() and _transport_is_active():
		var path: NodePath = target.get_path() if target.is_inside_tree() else NodePath()
		if not path.is_empty():
			net_status_cleared.rpc(path, kind)


func host_clear_all() -> void:
	for id: int in _statuses.keys():
		_clear_local(id, &"")


# ── Queries (any peer) ───────────────────────────────────────────────────────────────────────────


## What `Enemy._tick_pursuit()` multiplies its authored `move_speed` by. 1.0 when nothing is chilling
## it, so the read is safe to add unconditionally.
func speed_scale(target: Node) -> float:
	return 1.0 - potency_of(target, CHILLED)


func has_status(target: Node, kind: StringName) -> bool:
	if target == null:
		return false
	return _statuses.get(target.get_instance_id(), {}).has(kind)


func is_burning(target: Node) -> bool:
	return has_status(target, BURNING)


func is_chilled(target: Node) -> bool:
	return has_status(target, CHILLED)


func is_staggered(target: Node) -> bool:
	return has_status(target, STAGGERED)


## The live potency of one status: damage-per-tick for BURNING, slow fraction for CHILLED, unused for
## STAGGERED. Zero when absent.
func potency_of(target: Node, kind: StringName) -> float:
	if target == null:
		return 0.0
	var held: Dictionary = _statuses.get(target.get_instance_id(), {})
	var entry: Dictionary = held.get(kind, {})
	return float(entry.get("potency", 0.0))


## Who applied it, so a consumer can credit the right peer for a death it causes.
func source_of(target: Node, kind: StringName) -> int:
	if target == null:
		return 0
	var held: Dictionary = _statuses.get(target.get_instance_id(), {})
	return int(held.get(kind, {}).get("source", 0))


## Every target currently carrying `kind`, host-side. Used by nothing in the hot path — it exists for
## checks and for a future "how many are burning" HUD read.
func targets_with(kind: StringName) -> Array[Node]:
	var out: Array[Node] = []
	for id: int in _statuses:
		if not _statuses[id].has(kind):
			continue
		var node: Node = _node_for(id)
		if node != null:
			out.append(node)
	return out


func tracked_count() -> int:
	return _statuses.size()


# ── The tick ─────────────────────────────────────────────────────────────────────────────────────


func _physics_process(delta: float) -> void:
	_elapsed += delta
	if _statuses.is_empty():
		return
	# Iterate a snapshot of the keys: a burn tick can kill its target, which clears the entry and
	# mutates this dictionary mid-walk.
	for id: int in _statuses.keys():
		var node: Node = _node_for(id)
		if node == null or not _is_valid_target(node):
			# The target died or despawned. Drop it silently — a corpse's fire going out is not an
			# event anyone needs, and the VFX went with the freed node.
			_forget(id)
			continue
		var held: Dictionary = _statuses.get(id, {})
		for kind: StringName in held.keys():
			var entry: Dictionary = held[kind]
			if _elapsed >= float(entry["expires_at"]):
				_clear_local(id, kind)
				continue
			if kind == BURNING and _owns_simulation():
				_tick_burn(node, id, kind, entry, delta)


## Damage over time, paid in whole points on a fixed tick. The accumulator carries the fraction, so
## a 1.5-damage-per-tick burn genuinely deals 1.5 per tick over its life rather than rounding to 1
## every time — the same fractional-remainder discipline `CombatService` uses for lifesteal.
func _tick_burn(node: Node, id: int, kind: StringName, entry: Dictionary, delta: float) -> void:
	var accum: float = float(entry["accum"]) + delta
	if accum < BURN_TICK_SEC:
		entry["accum"] = accum
		return
	entry["accum"] = accum - BURN_TICK_SEC
	var damage: int = maxi(int(roundf(float(entry["potency"]))), 1)
	if not node.has_method(&"host_apply_damage"):
		return
	# Through the target's own damage entry point, never by writing `health`: armour, the flinch
	# counter, the death transition, the kill bounty and the instigator's lifesteal all live behind
	# it. A burn that bypassed it would be the only damage source in the game that does not.
	node.call(&"host_apply_damage", damage, int(entry["source"]))
	if not _is_valid_target(node):
		# The burn killed it. Clearing here rather than waiting for the next frame means
		# `ResonanceService` sees a consistent picture when it reacts to the death.
		_clear_local(id, kind)


# ── Replication ──────────────────────────────────────────────────────────────────────────────────


func _announce(target: Node, kind: StringName, active: bool) -> void:
	_apply_presentation(target, kind, active)
	status_changed.emit(target, kind, active)
	if not _transport_is_host() or not _transport_is_active():
		return
	if not target.is_inside_tree():
		return
	# NodePath, not an id: enemies are spawned by a `MultiplayerSpawner`, so the path is identical on
	# every peer. `EntityDirectory`'s ids are host-local and would not resolve on a client.
	net_status_changed.rpc(target.get_path(), kind, active)


@rpc("authority", "call_remote", "reliable")
func net_status_changed(target_path: NodePath, kind: StringName, active: bool) -> void:
	var target: Node = get_node_or_null(target_path)
	if target == null:
		return
	var id: int = target.get_instance_id()
	if active:
		var held: Dictionary = _statuses.get(id, {})
		# The mirror carries no clock: a client never expires a status on its own, because the host's
		# `net_status_cleared` is what ends it. Storing a far-future expiry keeps the shared query
		# path (`potency_of`) working without giving a client a second, disagreeing timeline.
		held[kind] = {"expires_at": INF, "potency": 0.0, "source": 0, "accum": 0.0}
		_statuses[id] = held
		_nodes[id] = target
	else:
		_statuses.get(id, {}).erase(kind)
	_apply_presentation(target, kind, active)
	status_changed.emit(target, kind, active)


@rpc("authority", "call_remote", "reliable")
func net_status_cleared(target_path: NodePath, kind: StringName) -> void:
	var target: Node = get_node_or_null(target_path)
	if target == null:
		return
	var id: int = target.get_instance_id()
	if kind == &"":
		for held_kind: StringName in _statuses.get(id, {}).keys():
			_apply_presentation(target, held_kind, false)
			status_changed.emit(target, held_kind, false)
		_forget(id)
		return
	_statuses.get(id, {}).erase(kind)
	_apply_presentation(target, kind, false)
	status_changed.emit(target, kind, false)


# ── Presentation ─────────────────────────────────────────────────────────────────────────────────


## Burning and chilled have to be readable across a clearing — a player choosing whether to commit to
## Fire needs to SEE that their hits set things alight. The VFX is attached as a child of the target
## rather than driven from `enemy.gd`, which keeps this whole system independent of what it burns:
## anything with a `host_apply_damage()` can catch fire, including a future destructible.
func _apply_presentation(target: Node, kind: StringName, active: bool) -> void:
	if kind == STAGGERED:
		return
	var target_3d := target as Node3D
	if target_3d == null:
		return
	var id: int = target.get_instance_id()
	var attached: Dictionary = _vfx.get(id, {})
	if not active:
		var existing: Variant = attached.get(kind)
		if existing != null and is_instance_valid(existing):
			(existing as Node).queue_free()
		attached.erase(kind)
		if attached.is_empty():
			_vfx.erase(id)
		else:
			_vfx[id] = attached
		return
	if attached.has(kind):
		return
	var effect: Node3D = _build_effect(kind)
	target_3d.add_child(effect)
	attached[kind] = effect
	_vfx[id] = attached


func _build_effect(kind: StringName) -> Node3D:
	var burning: bool = kind == BURNING
	var tint: Color = Color(1.0, 0.45, 0.12) if burning else Color(0.48, 0.80, 1.0)

	var root := Node3D.new()
	root.name = "Status_%s" % kind

	var material := ParticleProcessMaterial.new()
	material.direction = Vector3(0.0, 1.0, 0.0)
	# Fire climbs and cold falls. It is the cheapest possible way to tell the two apart at a glance,
	# and it survives being seen for a third of a second out of the corner of an eye.
	material.spread = 25.0 if burning else 55.0
	material.initial_velocity_min = 0.6 if burning else 0.1
	material.initial_velocity_max = 1.6 if burning else 0.4
	material.gravity = Vector3(0.0, 1.1 if burning else -0.6, 0.0)
	material.scale_min = 0.4
	material.scale_max = 1.0
	material.color = tint

	var quad := QuadMesh.new()
	quad.size = Vector2(0.16, 0.16)
	var mote := StandardMaterial3D.new()
	mote.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mote.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mote.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mote.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mote.vertex_color_use_as_albedo = true
	quad.material = mote

	var particles := GPUParticles3D.new()
	particles.name = "Motes"
	particles.amount = 18 if burning else 12
	particles.lifetime = 0.9
	particles.process_material = material
	particles.draw_pass_1 = quad
	particles.position.y = 0.6
	root.add_child(particles)

	# Fire lights the ground around it; cold does not. A shadowless omni is cheap, and it is what
	# makes a burning creature legible at night, which is when most of a run is fought.
	if burning:
		var light := OmniLight3D.new()
		light.name = "Glow"
		light.light_color = tint
		light.light_energy = 2.2
		light.omni_range = 3.5
		light.shadow_enabled = false
		light.position.y = 0.7
		root.add_child(light)
	return root


# ── Internals ────────────────────────────────────────────────────────────────────────────────────


func _clear_local(id: int, kind: StringName) -> void:
	var held: Dictionary = _statuses.get(id, {})
	if held.is_empty():
		_forget(id)
		return
	var node: Node = _node_for(id)
	var kinds: Array = held.keys() if kind == &"" else [kind]
	for held_kind: StringName in kinds:
		if not held.has(held_kind):
			continue
		held.erase(held_kind)
		if node != null and is_instance_valid(node):
			_apply_presentation(node, held_kind, false)
			status_changed.emit(node, held_kind, false)
			if _transport_is_host() and _transport_is_active() and node.is_inside_tree():
				net_status_changed.rpc(node.get_path(), held_kind, false)
	if held.is_empty():
		_forget(id)
	else:
		_statuses[id] = held


## The one safe way to read `_nodes`. A freed Object is still a value in the dictionary, and
## assigning it straight to a typed `Node` variable throws "Trying to assign invalid previously freed
## instance" — a target that dies and frees between two ticks is the normal case here, not an
## exceptional one, so every read goes through this rather than through `_nodes.get()`.
func _node_for(id: int) -> Node:
	var raw: Variant = _nodes.get(id)
	if raw == null or not is_instance_valid(raw):
		return null
	return raw as Node


func _forget(id: int) -> void:
	_statuses.erase(id)
	_nodes.erase(id)
	var attached: Dictionary = _vfx.get(id, {})
	for kind: StringName in attached:
		# Same freed-instance hazard as `_node_for()`: the VFX are CHILDREN of the target, so a
		# target that frees takes them with it and what is left in this dictionary is a dead handle.
		var effect: Variant = attached[kind]
		if effect != null and is_instance_valid(effect):
			(effect as Node).queue_free()
	_vfx.erase(id)


## A target worth tracking: still in the tree, still alive if it has an opinion about that. `Enemy`
## answers `is_alive()`; anything else is taken at face value.
func _is_valid_target(target: Node) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if target.has_method(&"is_alive") and not bool(target.call(&"is_alive")):
		return false
	return true


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


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node_or_null(^"/root/NetTransport")
	return _transport_node
