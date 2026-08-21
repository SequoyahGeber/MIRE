extends Node

## Runtime bridge between the authored playtest map and task 2.3's Harvestable component.
##
## The map's deterministic layout builder creates one holder per prop, with collision and `asset`
## metadata. This autoload discovers those holders after scene construction, replaces only intact
## A-001 resource props with live Harvestable nodes, hides the matching authored-map visual, and
## lets Harvestable instantiate the definition's damage/depleted states in the same transform.
## No map scene or generated layout file needs gameplay-specific edits.
##
## NETWORK AUTHORITY (ARCHITECTURE.md section 2.2): world mutation remains HOST-owned inside
## Harvestable. This bridge runs identically on every peer so RPC and synchronizer node paths match.
## The attack ray is client-local input; it only calls Harvestable.request_hit(), whose host validates
## range/cooldown and supplies damage/yield.

const HARVESTABLE_SCRIPT := preload("res://systems/harvesting/harvestable.gd")
## Preloaded, never named as the bare `EventBus` autoload identifier — a `--script` harness boots
## without autoloads resolved and would take the bare name as an unresolved constant.
const EVENT_BUS := preload("res://core/events/event_bus.gd")
## What each asset harvests as, keyed by the asset alone (F-114). Replaces the three-entry table
## this file used to carry, which is why 62 trees, 198 rocks and 794 bushes were painted scenery.
const HarvestLib := preload("res://systems/harvesting/harvest_library.gd")
## Both maps' harvestable holders. Playtest Hollow groups every authored prop and this file
## filters by the `asset` meta; Hollowmere instances its props through MultiMesh and so gives only
## its harvestable props a node of their own, in a group of their own. Until this was a list,
## Hollowmere — the main scene — had 77 trees and ore nodes that could not be harvested, because
## the group this looked for was one no node on that map was ever in.
const HOLDER_GROUPS: Array[StringName] = [
	&"playtest_hollow_asset", &"authored_world_harvestable",
]
const HARVESTABLE_GROUP: StringName = &"harvestable"
const WIRED_META: StringName = &"mire_harvestable_wired"
const ORIGINAL_VISUAL_META: StringName = &"mire_harvestable_original_visual"
const MAX_RAY_DISTANCE_M: float = 4.0
## Set by `world/gen/authored_world.gd` on a harvestable that stays inside a chunk's MultiMesh
## batch: the batch's meshes, and this prop's instance index within every one of them.
const BATCH_MESHES_META: StringName = &"batch_meshes"
const BATCH_INDEX_META: StringName = &"batch_index"
const BATCH_TRANSFORMS_META: StringName = &"batch_transforms"

## Definition path -> loaded resource. Keyed by path rather than by asset because one definition
## covers a whole family — every `tree_*` is one `wild_tree.tres`.
var _definitions: Dictionary[String, Resource] = {}
var _refresh_scheduled: bool = false
var _last_reported_count: int = -1
var _observed_scene_id: int = 0
## F-461. Holders that entered the tree since the last drain, waiting to be wired. Every entry here
## is wired EXACTLY ONCE — see `_on_node_added()` for why the whole-scene sweep this replaced was
## the wrong shape for a streamed world.
var _pending_holders: Array[Node] = []
var _drain_scheduled: bool = false


func _ready() -> void:
	_load_definitions()
	get_tree().node_added.connect(_on_node_added)
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)
	_schedule_refresh()
	_register_commands()


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)


## F-276. A new run starts on an UNTOUCHED island. Nothing else in the restart path reaches
## these props: an authored map's Harvestables are persistent live nodes carrying per-run mutable
## state (`health`, `visual_state`, `active`, and a 90-300 second respawn clock), not run-scoped
## objects a service can free (D-164) and not points re-derived from the seed the way
## `ResourceScatterField`'s are. F-258 wipes `WorldDeltaLog` and F-268 frees the buildables; neither
## touches Hollowmere's 1,156 authored props, so without this a tree felled in the last minutes of a
## run is still a stump for the first minutes of the next one.
##
## Unconditional on authority, like every other `run_restarted` subscriber in this codebase:
## `Harvestable.host_respawn()` self-guards on `_owns_world_mutation()`, so every peer's copy may
## call it and only the host's actually restores anything. Clients adopt the restored state through
## each prop's existing MultiplayerSynchronizer (`health`/`visual_state`/`active`, on-change, spawn
## properties) — no new RPC and no `PROTOCOL_VERSION` bump.
func _on_run_restarted() -> void:
	var respawned: int = host_respawn_all()
	if respawned > 0:
		MireLog.info(&"harvest", "run restart respawned %d depleted harvestable(s)" % respawned)



## F-113/F-101: this file used to listen for `attack` itself. `PlayerController` handles the same
## press and calls `CombatService.request_attack()` without marking it handled, so ONE click applied
## `HarvestableDef.damage_per_hit` here AND `WeaponDef.damage` through combat — which is most of why
## a single axe swing felled a whole tree. Combat is the only damage source now: it is host-resolved,
## it knows which tool you are holding, and it already targets everything in `&"damageable"`.
## `try_harvest_from_camera()` below stays as an API for checks and for any future interact verb.


func _process(_delta: float) -> void:
	# The engine may assign the initial main scene after this autoload's first deferred refresh.
	# Observe that assignment directly; node_added still handles holders built later inside the scene.
	var scene: Node = get_tree().current_scene
	var scene_id: int = scene.get_instance_id() if is_instance_valid(scene) else 0
	if scene_id == _observed_scene_id:
		return
	_observed_scene_id = scene_id
	_schedule_refresh()


## Raycast from the active first-person camera and request a hit on the Harvestable owning the
## collider. Returns true when a live harvestable was targeted, whether or not the host accepts it.
func try_harvest_from_camera() -> bool:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null or camera.get_world_3d() == null:
		return false
	var origin: Vector3 = camera.global_position
	var destination: Vector3 = origin - camera.global_basis.z * MAX_RAY_DISTANCE_M
	var query := PhysicsRayQueryParameters3D.create(origin, destination)
	query.collide_with_areas = true
	var player_body: CollisionObject3D = _collision_ancestor(camera)
	if player_body != null:
		query.exclude = [player_body.get_rid()]
	var hit: Dictionary = camera.get_world_3d().direct_space_state.intersect_ray(query)
	var collider: Node = hit.get("collider") as Node
	return request_harvest_from_collider(collider)


## Public for combat adapters and checks: walk from a hit collider to its harvestable root.
func request_harvest_from_collider(collider: Node) -> bool:
	var cursor: Node = collider
	while cursor != null:
		if cursor.is_in_group(HARVESTABLE_GROUP) and cursor.has_method("request_hit"):
			cursor.call("request_hit")
			return true
		cursor = cursor.get_parent()
	return false


func refresh_current_scene() -> void:
	_refresh_scheduled = false
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	# F-461: this sweep visits every holder in the scene, which is a superset of anything queued.
	_pending_holders.clear()
	for group: StringName in HOLDER_GROUPS:
		for candidate: Node in get_tree().get_nodes_in_group(group):
			if candidate is Node3D and (scene == candidate or scene.is_ancestor_of(candidate)):
				_wire_holder(candidate as Node3D, scene)
	var count: int = wired_harvestables().size()
	if count != _last_reported_count:
		_last_reported_count = count
		MireLog.info(&"harvest", "wired %d live harvestable prop(s)" % count)


func wired_harvestables() -> Array[Node3D]:
	var result: Array[Node3D] = []
	var scene: Node = get_tree().current_scene
	if scene == null:
		return result
	for candidate: Node in get_tree().get_nodes_in_group(HARVESTABLE_GROUP):
		if candidate is Node3D and (scene == candidate or scene.is_ancestor_of(candidate)):
			result.append(candidate as Node3D)
	return result


## Host-only refill of every wired prop, shared by `run_restarted` above and the `harvest respawn`
## command below so both mass restores go through one seam — the counterpart to D-164's
## `host_clear_all()` for world objects that are restored rather than freed. Returns how many props
## actually went from depleted to standing; a run that harvested nothing answers 0 and costs one
## group walk. Deliberately covers the whole `&"harvestable"` group under the current scene, not
## just this file's authored-map wiring: `ResourceScatterField` builds its points' Harvestables
## through the same group, and clearing that file's depletion MEMORY on `run_restarted` (F-258) does
## not stand a live already-depleted node back up.
func host_respawn_all() -> int:
	return _respawn_nodes(wired_harvestables())


func _respawn_nodes(nodes: Array) -> int:
	var respawned: int = 0
	for node: Node in nodes:
		if node != null and node.has_method(&"host_respawn") and bool(node.call("host_respawn")):
			respawned += 1
	return respawned


## F-076: ground truth for "does this map's layout actually have harvestable props" — read
## straight from the raw layout JSON's `props` array, never through `HOLDER_GROUPS`. Unlike
## EnemyWorld's nest kind, this needed no new convention: every generator already marks a prop
## `"harvestable": true` in its own layout regardless of what it names the prop's holder group.
## `wired_harvestables()` above is the other half — what this file actually wired — and keeping
## the two independent is what lets `tools/world_contract_check.gd` catch a future map whose
## holder group `HOLDER_GROUPS` does not yet list, the exact shape Hollowmere shipped in with 77
## dead trees before this task's group was added.
func expected_harvestable_count(layout: Dictionary) -> int:
	var count: int = 0
	for prop_value: Variant in (layout.get("props", []) as Array):
		var prop := prop_value as Dictionary
		if prop == null:
			continue
		# F-114 moved the decision from the placement to the asset, so ground truth moved with it.
		# The layout's own flag is still counted, for a layout authored before the table existed.
		var asset_id := StringName(String(prop.get("asset", "")))
		if bool(prop.get("harvestable", false)) or HarvestLib.is_harvestable(asset_id):
			count += 1
	return count


## Only a holder entering the tree warrants a rescan. Both map generators add a holder to its group
## BEFORE add_child (and packed scenes instantiate with their groups set), so membership is already
## visible here. Without this filter, every node the game ever adds — audio one-shots, enemies,
## build pieces — scheduled a full multi-group scene rescan, which under steady spawn churn meant
## one per frame for the life of the game (F-099).
## F-461. This used to call `_schedule_refresh()`, which sweeps EVERY holder in the world and then
## walks the whole `harvestable` group a second time just to produce a log line. That is the right
## shape for an authored map, which builds its props once: the sweep runs once, wires 1,156 holders,
## and is never heard from again.
##
## It is the wrong shape for a streamed one. `ResourceScatterField` drains its group queue against a
## 2 ms budget, so during traversal holders enter the tree on very nearly every frame — and each one
## re-ran an O(all holders in the world) sweep whose only new work was the single holder that
## triggered it. `tools/chunk_stream_check.gd` shows the sweep re-running hundreds of times in one
## walk, its reported count climbing 337 -> 773; the report that opened F-461 described it from the
## player's side as the already-loaded chunks' assets being "reloaded" whenever a new chunk lands.
##
## A holder needs wiring exactly once, and the node that needs it is the node we were just handed.
## So queue it and wire only it. The full sweep still exists for the cases that genuinely need one —
## a scene change, a run restart, a console command — where it runs once and costs nothing per frame.
func _on_node_added(node: Node) -> void:
	for group: StringName in HOLDER_GROUPS:
		if node.is_in_group(group):
			_pending_holders.append(node)
			if not _drain_scheduled:
				_drain_scheduled = true
				call_deferred("_drain_pending_holders")
			return


## Wires the holders queued by `_on_node_added()` and nothing else. Deferred rather than immediate
## because a holder is added BEFORE its `Visual`/`CollisionBody` children are (F-012's ordering
## rule), so wiring it in the `node_added` callback itself would find neither.
func _drain_pending_holders() -> void:
	_drain_scheduled = false
	var holders: Array[Node] = _pending_holders
	_pending_holders = []
	# A full sweep is already queued for this frame and covers every one of these — doing both would
	# wire each holder twice (harmless, `WIRED_META` guards it) and pay for the scan twice (not).
	if _refresh_scheduled:
		return
	var scene: Node = get_tree().current_scene
	# No current scene yet. These holders are not lost: the engine assigning the main scene is what
	# `_process()` watches for, and that schedules the full sweep which picks them all up.
	if scene == null:
		return
	for node: Node in holders:
		if not is_instance_valid(node) or not node is Node3D:
			continue
		if scene == node or scene.is_ancestor_of(node):
			_wire_holder(node as Node3D, scene)


## The whole-world sweep. Correct, and cheap enough, for the events that actually change the world
## wholesale; never on the streaming path (see `_on_node_added()`).
func _schedule_refresh() -> void:
	if _refresh_scheduled:
		return
	_refresh_scheduled = true
	call_deferred("refresh_current_scene")


func _load_definitions() -> void:
	for path: String in HarvestLib.definition_paths():
		var definition: Resource = load(path)
		if definition == null:
			MireLog.error(&"harvest", "cannot load harvestable definition %s" % path)
			continue
		_definitions[path] = definition


## The definition this asset harvests as, or null when the asset is scenery.
func definition_for(asset_id: StringName) -> Resource:
	var path: String = HarvestLib.definition_path_for(asset_id)
	if path.is_empty():
		return null
	return _definitions.get(path, null)


func _wire_holder(holder: Node3D, scene: Node) -> void:
	if holder == null or holder.has_meta(WIRED_META):
		return
	var asset_id := StringName(String(holder.get_meta(&"asset", "")))
	var definition: Resource = definition_for(asset_id)
	if definition == null:
		return

	var harvestable: Node3D = HARVESTABLE_SCRIPT.new() as Node3D
	harvestable.name = "Harvestable"
	harvestable.set("definition", definition)
	harvestable.set_meta(&"layout_index", _layout_index(holder.name))
	harvestable.set_meta(&"asset", asset_id)

	if holder.has_meta(BATCH_MESHES_META):
		_wire_batch_holder(holder, harvestable)
		return
	_wire_node_holder(holder, scene, asset_id, definition, harvestable)


## The common case since F-114: hundreds of bushes and saplings whose geometry never leaves the
## chunk's MultiMesh. There is no visual node to hide and no collider to reparent — the whole prop
## is one slot in a batch — so the holder gets the Harvestable and a hook that zeroes that slot.
func _wire_batch_holder(holder: Node3D, harvestable: Node3D) -> void:
	harvestable.call("set_visual_hook", _batch_visual_hook(holder))
	holder.add_child(harvestable)
	holder.set_meta(WIRED_META, true)


## A harvestable drawn as its own node: a tree, an ore node, a boulder. Its authored mesh is either
## replaced by the definition's damage-state scenes (the three multi-state harvestables) or kept and
## merely hidden on depletion (every family added by F-114, which ships no per-species state art).
func _wire_node_holder(
	holder: Node3D, scene: Node, asset_id: StringName, definition: Resource, harvestable: Node3D
) -> void:
	# The visual, found two ways because the two maps store it two ways. A holder that carries its
	# own `Visual` child answers directly; the Hollow keeps its visuals in a parallel
	# `AuthoredVisuals` tree and is matched by index.
	var original_visual: Node3D = holder.get_node_or_null(^"Visual") as Node3D
	if original_visual == null:
		var layout_index: int = _layout_index(holder.name)
		if layout_index < 0:
			MireLog.error(&"harvest", "cannot derive layout index from %s" % holder.name)
			return
		var visual_name := "Placed_%03d_%s" % [layout_index, asset_id]
		var authored_root: Node = scene.get_node_or_null(^"AuthoredVisuals")
		original_visual = (
			authored_root.find_child(visual_name, true, false) as Node3D if authored_root != null else null
		)
	if original_visual == null:
		MireLog.error(&"harvest", "cannot find authored visual for %s" % holder.name)
		return

	var keeps_authored_visual: bool = bool(definition.call("uses_authored_visual"))

	# Collision is optional, and only since F-114. A prop that brings its own damage-state geometry
	# must hand its collider over — the states swap under it and something has to own the shape —
	# but a family that keeps the world builder's own mesh may legitimately have no collider at all
	# (soft flora is walked through). `CombatService` finds its target in the `&"damageable"` group
	# by distance and arc, not by raycast, so a collider-less harvestable is still swingable.
	var collision_body: CollisionObject3D = holder.get_node_or_null(^"CollisionBody") as CollisionObject3D
	if collision_body == null and not keeps_authored_visual:
		MireLog.error(&"harvest", "%s has no CollisionBody" % holder.name)
		return
	if keeps_authored_visual:
		harvestable.call("set_visual_hook", func(shown: bool) -> void:
			if is_instance_valid(original_visual):
				original_visual.visible = shown
		)
		# F-432: and the node itself, not just a way to hide it. A prop that keeps the world
		# builder's geometry has no state scenes to swap, so its damage states are POSE — the shake
		# on a landed hit and the lean as it goes down — and the stump it leaves is cut from this
		# very mesh. All three need the node, which only this file knows how to find.
		harvestable.call("set_presentation", original_visual)

	# Reparent while Harvestable is still outside the tree, so its _ready() discovers collision and
	# builds its synchronizer only after the complete, identical subtree exists on every peer.
	if collision_body != null:
		holder.remove_child(collision_body)
		harvestable.add_child(collision_body)
	holder.add_child(harvestable)

	# Only a definition that brings its own intact geometry hides the authored mesh, and only that
	# hidden mesh is marked. One that does not IS the authored mesh: hiding it here would delete the
	# tree the moment it was wired, and marking it would claim a duplicate that does not exist.
	if not keeps_authored_visual:
		original_visual.visible = false
		original_visual.set_meta(ORIGINAL_VISUAL_META, true)
	holder.set_meta(WIRED_META, true)


## Hides or restores ONE instance of a MultiMesh by zeroing its transform, which is the only handle
## a batched copy has — it is not a node and has no `visible`. The intact transforms come from the
## world builder's own `batch_transforms` meta rather than from `get_instance_transform()`: that
## read is a RenderingServer round trip, and under the dummy renderer every headless check runs on
## it answers identity, which would restore the bush at the world origin.
func _batch_visual_hook(holder: Node3D) -> Callable:
	var meshes: Array = holder.get_meta(BATCH_MESHES_META, []) as Array
	var index: int = int(holder.get_meta(BATCH_INDEX_META, -1))
	var intact: Array = holder.get_meta(BATCH_TRANSFORMS_META, []) as Array
	if intact.size() != meshes.size():
		MireLog.error(&"harvest", "%s batch transforms do not match its meshes" % holder.name)
		return func(_shown: bool) -> void: pass

	return func(shown: bool) -> void:
		for slot: int in meshes.size():
			var multimesh := meshes[slot] as MultiMesh
			if multimesh == null or index < 0 or index >= multimesh.instance_count:
				continue
			var placement: Transform3D = intact[slot] as Transform3D
			multimesh.set_instance_transform(
				index,
				placement if shown else Transform3D(Basis().scaled(Vector3.ZERO), placement.origin)
			)


func _layout_index(holder_name: StringName) -> int:
	var value := String(holder_name)
	var separator: int = value.rfind("_")
	if separator < 0:
		return -1
	var suffix: String = value.substr(separator + 1)
	return suffix.to_int() if suffix.is_valid_int() else -1


func _collision_ancestor(node: Node) -> CollisionObject3D:
	var cursor: Node = node
	while cursor != null:
		if cursor is CollisionObject3D:
			return cursor as CollisionObject3D
		cursor = cursor.get_parent()
	return null


# ── Commands (docs/COMMANDS.md §7 — task 3.16) ───────────────────────────────────────────────────


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"harvest", {
		"scope": &"host",
		"args": [
			{"name": "op", "type": &"enum", "values": ["respawn", "status"]},
			{"name": "target", "type": &"selector", "optional": true, "default": null},
		],
		"handler": _cmd_harvest,
		"help": "harvest respawn [selector] | harvest status — refill depleted props",
	})


## No new seam needed: `Harvestable.host_respawn()` already exists, host-guarded, and clears the
## respawn clock properly. This verb only decides WHICH props to call it on — a selector when one is
## given, every wired harvestable otherwise.
func _cmd_harvest(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var nodes: Array = _harvest_targets(ctx, args.get("target"))
	if String(args.get("op", "status")) == "status":
		var depleted: int = 0
		for node: Node in nodes:
			if not bool(node.get(&"active")):
				depleted += 1
		return {"ok": true, "message": "%d harvestable(s), %d depleted" % [nodes.size(), depleted],
			"data": {"total": nodes.size(), "depleted": depleted}}

	var respawned: int = _respawn_nodes(nodes)
	return {"ok": true, "message": "respawned %d of %d harvestable(s)" % [respawned, nodes.size()],
		"data": {"respawned": respawned, "total": nodes.size()}}


## A null selector means "all of them" — `wired_harvestables()` is this service's own list and is
## already the answer to "what harvestables exist", so the selector path is the narrowing case, not
## the normal one.
func _harvest_targets(ctx: Dictionary, selector: Variant) -> Array:
	if selector == null or not (selector is Dictionary):
		return wired_harvestables()
	var directory: Node = get_node_or_null(^"/root/EntityDirectory")
	if directory == null:
		return wired_harvestables()
	var nodes: Array = []
	for entry: Dictionary in directory.call("resolve", selector as Dictionary, ctx):
		if String(entry["kind"]) == "harvestable":
			nodes.append(entry["node"])
	return nodes
