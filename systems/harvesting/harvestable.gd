class_name Harvestable
extends Node3D

## Hit -> damage -> yield -> logical despawn -> respawn for a static world prop.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md section 2.2, world mutation row): HOST.
## Clients may request one definition-authored hit, but send neither damage nor yield. The host
## checks the sender's player, range and cooldown, applies damage, emits the yield event exactly
## once, disables the prop, and runs the respawn clock. Health, visual state and active state are
## replicated on-change through a code-built MultiplayerSynchronizer (D-023). Offline play runs the
## same authority path locally.

## Preloaded, not referenced by `class_name`: a new global class is invisible to a headless
## `--script` run until the editor rescans the project.
const MeshMerge := preload("res://core/render/mesh_merge.gd")
const DrawPolicy := preload("res://world/environment/draw_policy.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")
const HARVESTABLE_DEFINITION := preload("res://systems/harvesting/harvestable_def.gd")
## F-391: which destruction material this prop is made of, decided from the asset exactly as every
## ambient effect already is. Preloaded by path for the usual reason — a `class_name` is invisible to
## a headless `--script` run until the editor rescans the project.
const ASSET_VFX := preload("res://world/environment/asset_vfx_library.gd")
## F-432: the stump a felled tree leaves, cut from that tree's own trunk. Preloaded by path for the
## usual reason — a `class_name` is invisible to a headless `--script` run until the editor rescans.
const STUMP_BUILDER := preload("res://systems/harvesting/stump_builder.gd")
## The tool axis, for the same preload-not-`class_name` reason.
const HARVEST_LIB := preload("res://systems/harvesting/harvest_library.gd")
const SYNC_NODE_NAME: StringName = &"HarvestSync"
const VISUAL_NODE_NAME: StringName = &"HarvestVisual"
const HARVESTABLE_GROUP: StringName = &"harvestable"
## F-391: how long after this node enters the tree its impact VFX stays muted. A client builds the
## prop at full health locally and only then receives the host's real state — up to one
## `NetConfig.PROP_SYNC_INTERVAL_SEC` later — so a stump felled an hour ago arrives as a max -> 0
## health drop and would otherwise burst chips as if someone had just hit it. Comfortably longer
## than that interval, and shorter than the walk from anywhere a chunk streams in (LOD0 range) to
## anywhere you can swing at it, so no real first swing is ever muted.
const IMPACT_ARM_DELAY_MSEC: int = 1500
## What the depleting hit is worth relative to an ordinary one. Scales the burst, not the damage.
const IMPACT_DEPLETION_INTENSITY: float = 2.4
## Where on the prop the chips come off, as a fraction of its measured height, and the ceiling that
## keeps a tall tree's fragments at the height a player actually swings.
const IMPACT_ANCHOR_HEIGHT_FRACTION: float = 0.32
const IMPACT_ANCHOR_MAX_HEIGHT_M: float = 1.6
## Fallback anchor for a BATCHED prop — a bush or a nettle is one slot in a chunk's MultiMesh and
## has no mesh node of its own to measure (`autoload/harvest_world.gd`'s `_batch_visual_hook` is the
## whole of its presentation). Chest height off the ground is the honest guess for something you
## are standing over and swinging at.
const IMPACT_ANCHOR_FALLBACK_M: float = 0.55
## Bounds the one-time mesh walk `_measure_anchor_offset()` does on a prop's first landed hit.
const IMPACT_MESH_PART_CAP: int = 48
## F-432 — what a chop LOOKS like while it is happening.
##
## Reported from play as "harvest states of trees are not working", and the report was right: every
## `tree_*` asset resolves to `wild_tree.tres`, which ships no `active_state_scenes`, so a tree went
## from whole to gone with nothing in between. Authoring damage art per species is not available to
## a procedurally generated world (see `systems/harvesting/stump_builder.gd`), so the states are
## POSE rather than geometry, and they cost one node transform each:
##
##  · **Every landed hit shakes the tree**, hardest at the top of the swing and gone in
##    [constant SHAKE_DURATION_SEC]. This is the feedback that says the axe connected.
##  · **A damaged tree leans**, further the closer it is to coming down, so a half-chopped trunk
##    reads as one you should finish rather than one you have not started.
##
## Both run off `health`, which is a replicated on-change property every peer already has, so a
## client watching a teammate chop sees the same tree shake — no new RPC, no `PROTOCOL_VERSION`
## bump. Presentation only: the host still owns whether the prop broke.
const SHAKE_DURATION_SEC: float = 0.42
## Peak shake angle, in degrees, for a hit that does not fell the prop. Small on purpose — a tree is
## a heavy thing and a visible wobble of a couple of degrees at the base is metres of movement at the
## crown.
const SHAKE_PEAK_DEG: float = 2.6
## Oscillations across the whole shake. Two and a bit reads as a thud rather than a wobble.
const SHAKE_CYCLES: float = 2.4
## How far a prop leans once it is one hit from depleted. Reached progressively: a prop at half
## health leans half of it.
const MAX_LEAN_DEG: float = 5.0

## The cross-system melee target seam (task 2.8). Anything in this group must implement
## `host_apply_damage(amount, instigator_peer_id) -> bool` and expect host-only callers; 2.10's
## enemies join it too and CombatService needs no change when they do.
const DAMAGEABLE_GROUP: StringName = &"damageable"

signal depleted(peer_id: int, item_id: StringName, amount: int)
signal respawned

@export var definition: HARVESTABLE_DEFINITION
@export_node_path("CollisionObject3D") var collision_body_path: NodePath
## The world builder's own mesh for this prop, used when the definition ships no state scenes of its
## own (`HarvestableDef.active_state_scenes` empty). Left unset by every caller that instead installs
## a hook through `set_visual_hook()` — see that method for why a hook and not just a node.
@export_node_path("Node3D") var authored_visual_path: NodePath

## Replicated state. Setters keep presentation correct when a network delta arrives on a client.
##
## F-391 hangs the destruction feedback here, and deliberately NOT on a damage signal: there was a
## host-only `hit_accepted` alongside this, so a client watching a teammate fell a tree got nothing
## at all — F-576 deleted it once F-391 had made it redundant and nothing else had picked it up.
## `health`
## is a replicated on-change property, which means this setter runs on every peer — the host's copy
## from `host_apply_damage()`, a client's from the MultiplayerSynchronizer delta — off a value
## everyone already has. Presentation only: the host still owns whether the node broke, and no new
## RPC means no `NetVersion.PROTOCOL_VERSION` bump.
var health: int = 0:
	set(value):
		var previous: int = health
		health = value
		if value < previous:
			_play_impact_vfx(value == 0)
			_start_shake()
		_apply_pose()

var visual_state: int = 0:
	set(value):
		if visual_state == value:
			return
		visual_state = value
		_schedule_visual_refresh()

var active: bool = true:
	set(value):
		if active == value:
			return
		active = value
		_refresh_collision()
		_schedule_visual_refresh()
		# The physics tick exists only to run the respawn clock, which only moves while depleted —
		# so hundreds of standing props tick zero times instead of 60/s each (F-099).
		set_physics_process(not active and _owns_world_mutation() and _configuration_valid)

var _configuration_valid: bool = false
## Shows or hides whatever already draws this prop, when the definition has no state scenes.
## A Callable rather than a Node3D because a generated world may not draw the prop as a node at
## all: `world/gen/authored_world.gd` keeps dense flora inside a chunk's MultiMesh batch, and one
## instance of a MultiMesh has no `visible` to set — it is hidden by zeroing its transform. One
## seam covers both representations, so neither this file nor HarvestableDef knows which is in use.
var _visual_hook: Callable = Callable()
var _collision_body: CollisionObject3D
var _collision_layer: int = 0
var _collision_mask: int = 0
var _visual: Node3D
var _sync: MultiplayerSynchronizer
var _visual_refresh_scheduled: bool = false
## F-391. `_impact_muted` covers the one health DROP that is bookkeeping rather than a swing;
## `_spawn_msec` covers the replication catch-up; `_impact_anchor_offset` caches the measured swing
## height (negative = not measured yet).
var _impact_muted: bool = false
var _spawn_msec: int = 0
var _impact_anchor_offset: float = -1.0
## F-432 presentation. `_presentation` is the node that DRAWS this prop when the definition ships no
## state scenes of its own — the world builder's own `Visual`, handed over by
## `autoload/harvest_world.gd` — and `_presentation_rest` is the transform it was built with, which
## every pose is applied on top of. `_shake_remaining` runs the hit reaction; `_shake_axis` is the
## horizontal axis it swings about, fixed per prop so one tree does not shake a different way each
## time it is struck.
var _presentation: Node3D = null
var _presentation_rest: Transform3D = Transform3D.IDENTITY
var _shake_remaining: float = 0.0
var _shake_axis: Vector3 = Vector3.RIGHT
var _respawn_remaining: float = 0.0
var _last_request_msec: Dictionary[int, int] = {}


func _ready() -> void:
	# Stamped before anything can move `health`, because the arm delay below is measured from it.
	_spawn_msec = Time.get_ticks_msec()
	set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	add_to_group(HARVESTABLE_GROUP)
	add_to_group(DAMAGEABLE_GROUP)
	_resolve_collision_body()
	_resolve_authored_visual()
	_configuration_valid = _validate_configuration()

	if definition != null:
		health = definition.max_health
		visual_state = 0
		active = true

	_build_synchronizer()
	_refresh_collision()
	_refresh_visual()
	# Off until depleted — the `active` setter turns the respawn clock on and off (F-099). Set here
	# explicitly too, because `active = true` above matches the default and skips its setter.
	set_physics_process(false)


## Convenience path for an interact/raycast hit. A client sends no parameters, so it cannot choose
## damage or yield. The host validates the sender and reads damage_per_hit from HarvestableDef.
func request_hit() -> void:
	if not _configuration_valid or not active:
		return
	if not _transport_is_active() or _transport_is_host():
		_accept_hit_request(_local_peer_id())
	else:
		net_request_hit.rpc_id(NetConfig.HOST_PEER_ID)


## Installed by whoever built this prop, BEFORE `add_child()`. See `_visual_hook`.
func set_visual_hook(hook: Callable) -> void:
	_visual_hook = hook
	if is_inside_tree():
		_schedule_visual_refresh()


## The node that draws this prop, for props that keep the world builder's own geometry (F-432).
##
## `set_visual_hook()` answers "show or hide it" and deliberately says nothing about WHAT it is,
## because a batched prop is a MultiMesh slot rather than a node. This says "and here is the node,
## when there is one" — which is what the hit shake, the damage lean and the stump cut from this
## tree's own trunk all need. Optional: a batched prop never gets one and simply has no pose.
func set_presentation(node: Node3D) -> void:
	_presentation = node
	_presentation_rest = node.transform if node != null else Transform3D.IDENTITY
	# A fixed axis per prop, derived from where it stands, so a given tree always shakes the same
	# way — a tree that picked a new direction per hit reads as jelly rather than as timber.
	var angle: float = float(hash(name)) * 0.001
	_shake_axis = Vector3(cos(angle), 0.0, sin(angle))
	_apply_pose()


## The tool-aware host seam (F-113). `CombatService` calls this in preference to `host_apply_damage`
## so the weapon that swung decides how much of a bite it takes: an axe fells a tree in three, a
## pickaxe barely scratches it, bare hands never will. Returns true when the swing CONNECTED, which
## deliberately includes a connect that did zero damage — the thunk of a pickaxe bouncing off a pine
## is the feedback that tells you to switch tools, and reporting it as a miss would delete that.
## What one swing of this tool WOULD take off, without taking it. Combat reports this number to
## every peer as the damage that landed, so a pickaxe bouncing off a pine reads as the 0 it is.
## F-543: `instigator_peer_id` defaults to 0 so the "what would this weapon do" preview keeps its old
## two-argument shape for anything that only wants the unmodified number; passing a real peer routes
## it through the same `harvest_damage` modifier `host_apply_tool_damage()` applies, so the number
## CombatService reports to the damage-number HUD is the number that actually landed.
func harvest_damage_for(tool_class: int, harvest_power: int, instigator_peer_id: int = 0) -> int:
	if definition == null:
		return 0
	var base: int = definition.damage_from_tool(tool_class, harvest_power)
	if instigator_peer_id <= 0:
		return base
	return _harvest_damage_for_peer(base, instigator_peer_id)


func host_apply_tool_damage(tool_class: int, harvest_power: int, instigator_peer_id: int) -> bool:
	if not _owns_world_mutation() or not _configuration_valid or not active:
		return false
	var amount: int = _harvest_damage_for_peer(
		definition.damage_from_tool(tool_class, harvest_power), instigator_peer_id
	)
	if amount <= 0:
		return true
	return host_apply_damage(amount, instigator_peer_id)


## Trusted host seam for task 2.8's hitbox. Combat owns attack validation and damage calculation;
## this method still rejects non-authority callers, non-positive damage and depleted props.
func host_apply_damage(amount: int, instigator_peer_id: int) -> bool:
	if not _owns_world_mutation() or not _configuration_valid or not active or amount <= 0:
		return false

	health = maxi(health - amount, 0)
	visual_state = _state_for_health(health)

	if health == 0:
		_deplete(instigator_peer_id)
	# Host calls retain immediate presentation semantics for signals/checks. Network replication may
	# assign visual_state and active back-to-back, so their setters coalesce into one deferred rebuild.
	_flush_visual_refresh()
	return true


## Host-only state restore for a point remembered as already depleted from a PRIOR real harvest
## (`world/gen/resource_scatter_field.gd`'s depletion memory, F-231) — reaches the exact same final
## state `host_apply_damage()` reaching 0 health does (`health` zeroed, `active` off, the respawn
## clock armed at `respawn_seconds`), but never emits `depleted`/`EVENT_BUS.emit_harvest_yielded()`.
## Those signals mean "a harvest just happened right now" to every listener downstream
## (`InventoryService` grants their real item/amount unconditionally) — correct for an actual hit,
## wrong for replaying a memory of one that already paid out once. Callers that only need to
## RE-ESTABLISH depleted state, not report a new harvest, must use this instead of
## `host_apply_damage()`.
func host_restore_depleted() -> bool:
	if not _owns_world_mutation() or not _configuration_valid or not active:
		return false
	# F-391: this is a replay of a harvest that already happened and already paid out, so it must
	# not throw chips either — same reasoning as the `depleted`/`harvest_yielded` suppression this
	# function exists for, applied to the presentation half.
	_impact_muted = true
	health = 0
	_impact_muted = false
	active = false
	visual_state = definition.active_state_scenes.size()
	_respawn_remaining = definition.respawn_seconds
	_flush_visual_refresh()
	return true


## Host-only explicit reset for admin commands and deterministic checks. Normal gameplay uses the
## physics-tick respawn clock.
func host_respawn() -> bool:
	if not _owns_world_mutation() or not _configuration_valid or active:
		return false
	_respawn_remaining = 0.0
	health = definition.max_health
	visual_state = 0
	active = true
	_last_request_msec.clear()
	_flush_visual_refresh()
	respawned.emit()
	return true


func respawn_remaining() -> float:
	return _respawn_remaining


## Which destruction material this prop is made of (F-391), asset first.
##
## The asset id is the durable identity — `AssetVfxLibrary` classifies from it exactly as it does
## for ambient effects, so any world containing a boulder gets stone chips off it with no map edit.
## The definition's `required_tool` is the fallback for an asset no rule names yet: a CHOP target is
## wood and a MINE target is stone, which is the same statement `HarvestLibrary`'s tool axis already
## makes. Public because the checks read it and because a future interact prompt wants the same
## answer.
func impact_class() -> int:
	var asset_id := _asset_id()
	if not asset_id.is_empty():
		var from_asset: int = ASSET_VFX.impact_for(asset_id)
		if from_asset != ASSET_VFX.Impact.NONE:
			return from_asset
	if definition == null:
		return ASSET_VFX.Impact.NONE
	return ASSET_VFX.impact_for_tool(definition.required_tool)


## Client-local destruction feedback for one landed hit (F-391). No authority and no wire traffic:
## it runs off `health`, which every peer already has.
##
## Muted in the two situations that are a health drop and not a swing:
##
## 1. `host_restore_depleted()` replaying a depletion this island already paid out (F-231's
##    depletion memory) — `_impact_muted` covers that one directly.
## 2. The first `IMPACT_ARM_DELAY_MSEC` of this node's life, which is the replication catch-up
##    described on that constant. `EnvironmentVfx.play_impact()` carries the other half of that
##    guard — a 40 m distance gate, which is what covers the same catch-up arriving late because
##    interest management only admitted the prop at 120 m.
func _play_impact_vfx(depleting: bool) -> void:
	if _impact_muted or not is_inside_tree():
		return
	if Time.get_ticks_msec() - _spawn_msec < IMPACT_ARM_DELAY_MSEC:
		return
	var impact: int = impact_class()
	if impact == ASSET_VFX.Impact.NONE:
		return
	var vfx: Node = get_node_or_null(^"/root/EnvironmentVfx")
	if vfx == null or not vfx.has_method(&"play_impact"):
		return
	vfx.call(
		&"play_impact",
		impact,
		_impact_anchor(),
		IMPACT_DEPLETION_INTENSITY if depleting else 1.0
	)


## The asset id this prop was built from. `autoload/harvest_world.gd` stamps it on the Harvestable
## itself; the walk upward covers a holder that carries it and a construction site that does not
## stamp the child, mirroring `EnvironmentVfx._asset_id_for`'s own ancestor walk.
func _asset_id() -> String:
	var cursor: Node = self
	for _depth: int in 4:
		if cursor == null:
			break
		if cursor.has_meta(&"asset"):
			return String(cursor.get_meta(&"asset"))
		cursor = cursor.get_parent()
	return ""


## Where the chips come off. Measured from the prop's own geometry — a tree is struck at chest
## height, a boulder near its middle — and cached, because from here the geometry only shrinks and
## the depleted stump is not what the swing hit.
func _impact_anchor() -> Vector3:
	if _impact_anchor_offset < 0.0:
		_impact_anchor_offset = _measure_anchor_offset()
	return global_position + Vector3.UP * _impact_anchor_offset


## F-543: the same measured offset `_impact_anchor()` uses, exposed so presentation can anchor to a
## prop's real geometry instead of guessing. `ui/hud/forager_sense_hud.gd` floats the Forager's
## through-terrain marker here, which is why it lands on a tree's trunk rather than at its roots.
## Public and const-shaped: it measures once, caches, and never mutates anything else.
func anchor_offset() -> float:
	if _impact_anchor_offset < 0.0:
		_impact_anchor_offset = _measure_anchor_offset()
	return _impact_anchor_offset


func _measure_anchor_offset() -> float:
	var holder := get_parent() as Node3D
	var root: Node = holder if holder != null else self
	var bounds := AABB()
	var found: bool = false
	var seen: int = 0
	var queue: Array[Node] = [root]
	while not queue.is_empty() and seen < IMPACT_MESH_PART_CAP:
		var cursor: Node = queue.pop_back()
		var mesh_instance := cursor as MeshInstance3D
		if mesh_instance != null and mesh_instance.mesh != null and mesh_instance.is_inside_tree():
			seen += 1
			var part: AABB = mesh_instance.global_transform * mesh_instance.mesh.get_aabb()
			bounds = part if not found else bounds.merge(part)
			found = true
		for child: Node in cursor.get_children():
			queue.append(child)
	if not found:
		return IMPACT_ANCHOR_FALLBACK_M
	var top: float = bounds.position.y + bounds.size.y - global_position.y
	return clampf(top * IMPACT_ANCHOR_HEIGHT_FRACTION, 0.25, IMPACT_ANCHOR_MAX_HEIGHT_M)


@rpc("any_peer", "call_remote", "reliable")
func net_request_hit() -> void:
	if not _transport_is_host():
		return
	_accept_hit_request(multiplayer.get_remote_sender_id())


func _accept_hit_request(peer_id: int) -> void:
	if not _request_is_valid(peer_id):
		return
	_last_request_msec[peer_id] = Time.get_ticks_msec()
	host_apply_damage(definition.damage_per_hit, peer_id)


func _request_is_valid(peer_id: int) -> bool:
	if not _owns_world_mutation() or not active or peer_id <= 0:
		return false

	var cooldown_msec: int = ceili(definition.request_cooldown_seconds * 1000.0)
	var now_msec: int = Time.get_ticks_msec()
	if _last_request_msec.has(peer_id):
		var elapsed_msec: int = now_msec - _last_request_msec[peer_id]
		if elapsed_msec < cooldown_msec:
			return false

	# Offline mode has no PlayerNet spawn. The local raycast that owns this call is the validation
	# seam there; in a session the host must independently verify the remote player's position.
	if not _transport_is_active():
		return true

	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net == null or not player_net.has_method("player_for"):
		return false
	var player: Node3D = player_net.call("player_for", peer_id) as Node3D
	if player == null:
		return false
	var range_sq: float = definition.request_range_m * definition.request_range_m
	return global_position.distance_squared_to(player.global_position) <= range_sq


func _deplete(instigator_peer_id: int) -> void:
	active = false
	visual_state = definition.active_state_scenes.size()
	_respawn_remaining = definition.respawn_seconds
	var amount: int = _yield_amount(instigator_peer_id)
	depleted.emit(instigator_peer_id, definition.yield_item_id, amount)
	EVENT_BUS.emit_harvest_yielded(
		definition.id,
		instigator_peer_id,
		definition.yield_item_id,
		amount,
		global_position
	)


## Cycle Modifier `drought` (F-245, content/cycle_modifiers/drought.tres): halves the yield while its
## effect window is open — `CycleModifierService.drought_active()` is the one place that tracks when
## that window closes (the next Wellspring cap), not just whether `drought` was ever drawn.
func _yield_amount(instigator_peer_id: int) -> int:
	var amount: int = definition.yield_amount
	var modifiers: Node = get_node_or_null(^"/root/CycleModifierService")
	if modifiers != null and bool(modifiers.call(&"drought_active")):
		amount = amount / 2
	# F-543: `harvest_yield` scales what the depleting hit pays out, per the peer who landed it
	# (docs/POWERUPS.md §2; DESIGN §4.5 is Forager +25% / Warden -15%). Applied AFTER `drought` so
	# the Cycle Modifier's halving is the world's, and the powerup's is the player's — chaining them
	# the other way would let a Forager round the drought away entirely on a 1-yield node.
	# `maxi(..., 1)` so a stacked negative never turns a depleted node into nothing at all: a
	# harvest that consumed the prop and paid zero reads as a bug to the player, not as a penalty.
	var powerups: Node = get_node_or_null(^"/root/PowerupService")
	if powerups != null:
		amount = int(roundi(float(powerups.call(&"stat", instigator_peer_id, &"harvest_yield", float(amount)))))
	return maxi(amount, 1)


## F-543: `harvest_damage` — how big a bite one swing takes, i.e. DESIGN §4.5's gather SPEED half
## (Forager is better at it, Warden worse). Kept separate from `_yield_amount()` because it runs on
## every hit rather than only the depleting one, and because a zero here is legal and meaningful:
## `damage_from_tool()` already returns 0 for the wrong tool class, and that thunk is deliberate
## feedback (see `host_apply_tool_damage`'s note). So this only ever scales a bite that already
## exists — `base <= 0` returns unchanged rather than letting a positive modifier mint damage a bare
## hand should never do.
func _harvest_damage_for_peer(base: int, instigator_peer_id: int) -> int:
	if base <= 0:
		return base
	var powerups: Node = get_node_or_null(^"/root/PowerupService")
	if powerups == null:
		return base
	var scaled: float = float(powerups.call(&"stat", instigator_peer_id, &"harvest_damage", float(base)))
	return maxi(int(roundi(scaled)), 1)


## Starts the hit reaction. Client-local and free of authority for the same reason
## `_play_impact_vfx()` is: it runs off `health`, which every peer already has, and it moves nothing
## but one node's rotation. Muted in exactly the cases the impact VFX is — a depletion replayed from
## memory, and the replication catch-up right after this node enters the tree — because a stump felled
## an hour ago must not lurch when a client finally hears about it.
func _start_shake() -> void:
	if _impact_muted or not is_inside_tree():
		return
	if Time.get_ticks_msec() - _spawn_msec < IMPACT_ARM_DELAY_MSEC:
		return
	if _pose_target() == null:
		return
	_shake_remaining = SHAKE_DURATION_SEC
	set_process(true)


func _process(delta: float) -> void:
	_shake_remaining = maxf(_shake_remaining - delta, 0.0)
	_apply_pose()
	if _shake_remaining <= 0.0:
		set_process(false)


## The node a pose is applied to: the world builder's own visual when there is one, and otherwise
## the state scene this component instantiated. Null for a batched prop, which has no node at all.
func _pose_target() -> Node3D:
	if is_instance_valid(_presentation):
		return _presentation
	return _visual


## Lean plus shake, written onto the presentation node in one assignment.
##
## The lean is the persistent part — how far through being felled this prop is — and the shake decays
## into it, so a hit on a nearly-dead tree settles at its lean rather than snapping back upright.
func _apply_pose() -> void:
	var target: Node3D = _pose_target()
	if target == null:
		return
	var rest: Transform3D = _presentation_rest if target == _presentation else Transform3D.IDENTITY
	var angle: float = deg_to_rad(_lean_degrees() + _shake_degrees())
	target.transform = rest if is_zero_approx(angle) else rest.rotated_local(_shake_axis, angle)


func _lean_degrees() -> float:
	if definition == null or not active or definition.max_health <= 0:
		return 0.0
	var damage: float = 1.0 - float(health) / float(definition.max_health)
	return clampf(damage, 0.0, 1.0) * MAX_LEAN_DEG


func _shake_degrees() -> float:
	if _shake_remaining <= 0.0:
		return 0.0
	var progress: float = 1.0 - _shake_remaining / SHAKE_DURATION_SEC
	# Amplitude decays as (1 - t)^2 so the first swing carries the hit and the tail settles quietly.
	var decay: float = (1.0 - progress) * (1.0 - progress)
	return SHAKE_PEAK_DEG * decay * sin(progress * TAU * SHAKE_CYCLES)


func _physics_process(delta: float) -> void:
	if active or not _owns_world_mutation():
		return
	_respawn_remaining = maxf(_respawn_remaining - delta, 0.0)
	if _respawn_remaining <= 0.0:
		host_respawn()


## Which authored presentation matches this health. A definition with no state scenes has exactly
## one presentation — the world builder's own mesh — so it stays at 0 and `active` alone decides
## whether it is drawn; without this guard the fraction below divides by an empty array.
func _state_for_health(value: int) -> int:
	var state_count: int = definition.active_state_scenes.size()
	if state_count == 0:
		return 0
	if value <= 0:
		return state_count
	var damage_fraction: float = 1.0 - float(value) / float(definition.max_health)
	return clampi(floori(damage_fraction * float(state_count)), 0, state_count - 1)


func _build_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	for property_name: StringName in [&"health", &"visual_state", &"active"]:
		var property_path := NodePath(".:%s" % property_name)
		config.add_property(property_path)
		config.property_set_spawn(property_path, true)
		config.property_set_replication_mode(
			property_path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE
		)

	_sync = MultiplayerSynchronizer.new()
	_sync.name = SYNC_NODE_NAME
	_sync.root_path = NodePath("..")
	_sync.replication_config = config
	_sync.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	NetInterest.configure(_sync, self, NetInterest.Class.PROP)
	add_child(_sync)


func _resolve_collision_body() -> void:
	if not collision_body_path.is_empty():
		_collision_body = get_node_or_null(collision_body_path) as CollisionObject3D
	else:
		var bodies: Array[Node] = find_children("*", "CollisionObject3D", true, false)
		if not bodies.is_empty():
			_collision_body = bodies[0] as CollisionObject3D
	if _collision_body != null:
		_collision_layer = _collision_body.collision_layer
		_collision_mask = _collision_body.collision_mask


## An authored scene may point at its own mesh by path instead of installing a hook. Wrapping it in
## the same Callable keeps `_refresh_visual` with exactly one way to show or hide a prop.
func _resolve_authored_visual() -> void:
	if _visual_hook.is_valid() or authored_visual_path.is_empty():
		return
	var node := get_node_or_null(authored_visual_path) as Node3D
	if node == null:
		return
	_visual_hook = func(shown: bool) -> void:
		if is_instance_valid(node):
			node.visible = shown


func _refresh_collision() -> void:
	if _collision_body == null:
		return
	_collision_body.set_deferred("collision_layer", _collision_layer if active else 0)
	_collision_body.set_deferred("collision_mask", _collision_mask if active else 0)
	for child: Node in _collision_body.find_children("*", "CollisionShape3D", true, false):
		(child as CollisionShape3D).set_deferred("disabled", not active)


func _refresh_visual() -> void:
	if not is_inside_tree() or definition == null:
		return
	# The prop draws itself: nothing to instantiate, and the only thing depletion changes is whether
	# the world builder's existing geometry is shown. An authored depleted_scene still works — a
	# stump under a felled wild tree — and is simply added on top of the hidden original.
	if definition.uses_authored_visual() and _visual_hook.is_valid():
		_visual_hook.call(active)

	var scene: PackedScene
	if active:
		if definition.uses_authored_visual():
			scene = null
		elif visual_state < 0 or visual_state >= definition.active_state_scenes.size():
			return
		else:
			scene = definition.active_state_scenes[visual_state]
	else:
		scene = definition.depleted_scene

	if _visual != null:
		remove_child(_visual)
		_visual.queue_free()
		_visual = null

	# F-432: a felled tree leaves a stump cut from its OWN trunk, in preference to the definition's
	# one authored stump. See `systems/harvesting/stump_builder.gd` for why this is generated rather
	# than authored per species; it answers null for anything that is not a standing tree, and the
	# definition's `depleted_scene` then applies as before.
	if not active:
		var stump: Mesh = _generated_stump()
		if stump != null:
			_show_stump(stump)
			return

	if scene == null:
		return

	_visual = scene.instantiate() as Node3D
	if _visual == null:
		push_error("Harvestable %s: state scene root must be Node3D" % name)
		return
	_visual.name = VISUAL_NODE_NAME
	add_child(_visual)
	# State scenes are the kit's .glb as authored: fifty-six separate MeshInstance3D nodes for a
	# tree, which is fifty-six draw calls per tree per frame. The world builder has always merged
	# them before stamping a prop; nothing merged them here, so wiring a tree as a live
	# harvestable multiplied its cost by fourteen the moment it became choppable. Forty-four
	# trees were 2,464 of Hollowmere's 8,354 opaque draws (F-144).
	#
	# The merge caches per source file, so this is one collapse per state scene for the whole
	# world, not one per tree — and DrawPolicy then bounds how far the result is drawn.
	var source: String = scene.resource_path
	if not source.is_empty():
		var merged := MeshMerge.collapse(_visual, source)
		if merged != null:
			DrawPolicy.apply(merged, merged.mesh.get_aabb(), maxf(global_basis.get_scale().y, 0.001))


## The stump this prop leaves when felled, or null when it should use whatever its definition
## authored. Only for props that draw the world builder's own geometry — a definition that ships its
## own damage-state art (`harvest_tree_intact`) already has a stump drawn to match it — and only for
## CHOP targets, because "cut it off at knee height" is a statement about wood.
func _generated_stump() -> Mesh:
	if definition == null or not definition.uses_authored_visual():
		return null
	if definition.required_tool != HARVEST_LIB.Tool.CHOP:
		return null
	var mesh: Mesh = _presentation_mesh()
	if mesh == null:
		return null
	return STUMP_BUILDER.stump_for(StringName(_asset_id()), mesh)


func _presentation_mesh() -> Mesh:
	if not is_instance_valid(_presentation):
		return null
	var instance := _presentation as MeshInstance3D
	if instance != null:
		return instance.mesh
	for child: Node in _presentation.find_children("*", "MeshInstance3D", true, false):
		var found := child as MeshInstance3D
		if found != null and found.mesh != null:
			return found.mesh
	return null


func _show_stump(stump: Mesh) -> void:
	var instance := MeshInstance3D.new()
	instance.name = VISUAL_NODE_NAME
	instance.mesh = stump
	_visual = instance
	add_child(instance)
	DrawPolicy.apply(instance, stump.get_aabb(), maxf(global_basis.get_scale().y, 0.001))


func _schedule_visual_refresh() -> void:
	if _visual_refresh_scheduled:
		return
	_visual_refresh_scheduled = true
	call_deferred("_flush_visual_refresh")


func _flush_visual_refresh() -> void:
	if not _visual_refresh_scheduled:
		return
	_visual_refresh_scheduled = false
	_refresh_visual()


func _validate_configuration() -> bool:
	if definition == null:
		push_error("Harvestable %s has no definition" % name)
		return false
	var errors: PackedStringArray = definition.validation_errors()
	if not errors.is_empty():
		push_error("Harvestable %s definition is invalid: %s" % [name, "; ".join(errors)])
		return false

	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method("has_item"):
		push_error("Harvestable %s cannot validate yield item without Registry" % name)
		return false
	if not bool(registry.call("has_item", definition.yield_item_id)):
		push_error(
			"Harvestable %s references unknown yield item '%s'"
			% [name, definition.yield_item_id]
		)
		return false
	return true


func _owns_world_mutation() -> bool:
	return not _transport_is_active() or _transport_is_host()


func _transport() -> Node:
	return get_node_or_null(^"/root/NetTransport")


func _transport_is_active() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_active"))


func _transport_is_host() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_host"))


func _local_peer_id() -> int:
	var transport: Node = _transport()
	if transport == null or not _transport_is_active():
		return NetConfig.HOST_PEER_ID
	return int(transport.call("local_peer_id"))
