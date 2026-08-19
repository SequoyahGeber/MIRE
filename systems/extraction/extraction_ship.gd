class_name ExtractionShip
extends Node3D

## Host-authoritative extraction objective (DESIGN.md §5.2, task 6.5): the shipwreck a run cashes out
## on. "Not how you win. It is how you cash out" — repairing it is a real bet against pushing one more
## Cycle, and once it is seaworthy the whole crew has to choose, together, to leave.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Extraction" row): HOST. A repair request carries no
## item counts and no stage number — the host alone decides whether the requester is in range, holds
## a repair hammer, and can afford the current stage's cost, exactly the "harvest pattern" Wellspring
## and Chest already established. `repair_stage`, `departure_channeling`, `departure_progress_sec` and
## `departed` are the only state that crosses the wire, through a code-built MultiplayerSynchronizer
## (D-023), same shape as Wellspring's own.
##
## Built and positioned identically on every peer by `autoload/extraction_service.gd` from the map's
## own `shipwreck` marker — this node holds no map-specific knowledge of its own, the same split
## `autoload/wellspring_service.gd` uses for the Wellspring ritual.
##
## Assembly follows `assets/ships/README.md`'s ship-frame contract exactly: every part below is added
## as a sibling at `Transform3D.IDENTITY` and the README's own state->rig pairing decides which hull,
## mast and sail show for the current `repair_stage` (0 wrecked .. 3 repaired).
##
## PROTOCOL_VERSION is NOT bumped for `net_request_repair`/`net_request_toggle_departure` — same gap
## F-161 already recorded for task 5.3: `core/net/net_version.gd` and `tools/handshake_check.gd` were
## both held by lane slate17's 3.7 claim for this task's entire session. See docs/FINDINGS.md.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

const EXPORT_DIR: String = "res://assets/ships/exports"
const HULL_STATE_PATHS: PackedStringArray = [
	EXPORT_DIR + "/ship_hull_wrecked.glb",
	EXPORT_DIR + "/ship_hull_repair_1.glb",
	EXPORT_DIR + "/ship_hull_repair_2.glb",
	EXPORT_DIR + "/ship_hull_repaired.glb",
]
## README's own rig pairing: mast_broken rides the wrecked and first-repair hulls (no sail); the
## second repair stage steps the standing mast with the sail still furled; only the fully repaired
## hull raises it. "" means that part is not shown at this stage.
const MAST_STATE_PATHS: PackedStringArray = [
	EXPORT_DIR + "/ship_mast_broken.glb",
	EXPORT_DIR + "/ship_mast_broken.glb",
	EXPORT_DIR + "/ship_mast.glb",
	EXPORT_DIR + "/ship_mast.glb",
]
const SAIL_STATE_PATHS: PackedStringArray = [
	"",
	"",
	EXPORT_DIR + "/ship_sail_furled.glb",
	EXPORT_DIR + "/ship_sail_raised.glb",
]
## Present at every stage — the crew needs a ramp up and a rudder to read as a whole ship even
## half-wrecked. Ground-truthed against `assets/ships/README.md`'s "always ship-framed" set.
const STATIC_RIG_PATHS: PackedStringArray = [
	EXPORT_DIR + "/ship_rudder.glb",
	EXPORT_DIR + "/ship_boarding_ramp.glb",
	EXPORT_DIR + "/ship_cargo_hatch.glb",
]

## `assets/ships/README.md`'s repaired-hull footprint (10.905 x 4.143 x 3.818) — state drift across
## all four hull states is 0.0000 mm, so one approximate box covers every stage. Ship-frame parts sit
## with their vertical origin AT the ground plane (z=0 in Blender, y=0 here), not centred on it, so
## the collider is offset up by half its own height rather than straddling the origin.
const HULL_HALF_EXTENTS: Vector3 = Vector3(5.6, 1.9, 2.2)

## DESIGN.md §5.2: "From Cycle 3, the wreck can be repaired with mid-tier resources."
const MIN_REPAIR_CYCLE: int = 3
## One entry per repair attempt, index == `repair_stage` going into that attempt. Placeholder-tuned,
## same status as Wellspring's own ritual numbers (not yet through a real playtest) — escalating so
## the last stage costs the most, in the spirit of DESIGN.md §5.2's "superlinear" note on the reward
## curve, applied here to the cost curve instead.
const REPAIR_COSTS: Array[Dictionary] = [
	{&"log": 6, &"iron_ingot": 2},
	{&"log": 4, &"iron_ingot": 4, &"fibre_bundle": 3},
	{&"iron_ingot": 6, &"iron_ore": 4},
]
const REPAIR_STAGE_COUNT: int = 3
## Flavour text on the item itself: "For mending wards. Also for endings." — the repair hammer is the
## tool this task's "endings" half is built around.
const REPAIR_TOOL_ITEM: StringName = &"repair_hammer"
const REPAIR_RANGE_M: float = 5.0

## Everyone connected has to be standing on deck together for the whole hold, the same presence-gated
## ritual shape as Wellspring's capture (D-092) — "group confirm" here means the crew, not a dialog.
## 60s matches `docs/SPECS.md`'s 6.5 look-ahead note ("all-aboard-or-cancel flow, host-arbitrated,
## 60 s window") — long enough that a straggler ten seconds out can still make it, short enough the
## crew feels the held breath before the mesh swaps to a raised sail.
const BOARD_RANGE_M: float = 7.0
const DEPARTURE_HOLD_SEC: float = 60.0

const SHIP_GROUP: StringName = &"extraction_ship"
const SYNC_NODE_NAME: StringName = &"ExtractionShipSync"
const HULL_NODE_NAME: StringName = &"ShipHull"
const RIG_NODE_NAME: StringName = &"ShipRig"

## Replicated. 0 (wrecked) .. REPAIR_STAGE_COUNT (fully repaired).
##
## Fires `emit_ship_repaired` from the setter, not from `_process_repair()` directly (task 8.3,
## F-249) — `_process_repair()` only runs where `_owns_mutation()` is true (host-only), the exact
## host-only-emit-call trap F-168 first found on `Wellspring.capped` and fixed by moving the emit
## into the replicated property's own setter (D-107/D-108's pattern, `departed` below already
## applies it). `EventBus` is a per-process static, so a host-only emit never reached a client's own
## local bus — nothing had ever consumed `ship_repaired` client-side to notice until task 8.3's
## SteamStats needed it on every peer, not just the host's.
##
## `is_inside_tree()`-guarded, same as `_maybe_refresh_visual()` just below it — `global_position` on
## a Node3D outside the tree logs an engine error rather than a real position, and a real
## ExtractionShip is always a placed world node by the time anything sets its repair stage. The one
## caller that isn't is `tools/extraction_check.gd`'s own departure-FSM setup, which sets
## `repair_stage = REPAIR_STAGE_COUNT` BEFORE `add_child()` as a shortcut past the repair minigame —
## exactly like the old host-only `_process_repair()` call site, that path never emitted either.
var repair_stage: int = 0:
	set(value):
		if repair_stage == value:
			return
		var was_repaired: bool = repair_stage >= REPAIR_STAGE_COUNT
		repair_stage = value
		_maybe_refresh_visual()
		if not was_repaired and repair_stage >= REPAIR_STAGE_COUNT and is_inside_tree():
			EVENT_BUS.emit_ship_repaired(name, global_position)

## Replicated. Presentation reads this to show/hide the departure hold prompt.
var departure_channeling: bool = false
## Replicated. Seconds of the departure hold accumulated so far this attempt.
var departure_progress_sec: float = 0.0
## Replicated. Snapshotted when the hold starts — how many players must stay aboard.
var departure_required_players: int = 1
## Replicated. True once the crew has finished the departure hold. Terminal — never reset.
##
## Setter fires `run_extracted` rather than `_finish_departure()` doing it directly (task 6.6):
## `EventBus` is a per-process static, so a host-only emit call would never reach a client's own
## local bus, and `SalvageService` needs the event on EVERY peer to bank that peer's own Salvage
## save. Driving the emit off the setter means it fires identically whether this process just set
## `departed = true` itself (the host) or received it over the wire (a client, via `_sync`) — the
## same fix `repair_stage`'s own setter already applies to `_maybe_refresh_visual()`.
var departed: bool = false:
	set(value):
		if departed == value:
			return
		departed = value
		if departed:
			EVENT_BUS.emit_run_extracted(_current_cycle(), global_position)

var _sync: MultiplayerSynchronizer
var _hull_root: Node3D
var _rig_root: Node3D
var _last_hull_stage: int = -1


func _ready() -> void:
	set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	add_to_group(SHIP_GROUP)
	_build_collision()
	_build_static_rig()
	_build_synchronizer()
	_refresh_visual()
	_last_hull_stage = repair_stage
	set_process(false)


## Client-facing: press interact while holding a repair hammer, in range, with the current stage's
## resources on hand. A no-op once fully repaired.
func request_repair() -> void:
	if _owns_mutation():
		_process_repair(_local_peer_id())
	elif _transport_is_active():
		net_request_repair.rpc_id(NetConfig.HOST_PEER_ID)


## Client-facing: press interact while aboard and repaired. Toggles start/cancel the departure hold,
## same shape as Wellspring's `request_toggle_channel()`. A no-op before the ship is seaworthy or
## after the crew has already departed.
func request_toggle_departure() -> void:
	if _owns_mutation():
		_process_toggle_departure(_local_peer_id())
	elif _transport_is_active():
		net_request_toggle_departure.rpc_id(NetConfig.HOST_PEER_ID)


## Local-only convenience for the HUD prompt.
func is_local_player_in_repair_range() -> bool:
	var player: Node3D = _player_by_peer(_local_peer_id())
	return player != null and _in_range(player, REPAIR_RANGE_M)


func is_local_player_in_board_range() -> bool:
	var player: Node3D = _player_by_peer(_local_peer_id())
	return player != null and _in_range(player, BOARD_RANGE_M)


## Ingredients the CURRENT repair stage needs, or an empty Dictionary once fully repaired. Presented
## as `item_id -> count`, resolved against `Registry` by the caller (same split every other HUD in
## this codebase uses — this file never reads item display names).
func current_repair_cost() -> Dictionary:
	if repair_stage >= REPAIR_STAGE_COUNT:
		return {}
	return REPAIR_COSTS[repair_stage]


@rpc("any_peer", "call_remote", "reliable")
func net_request_repair() -> void:
	if not _transport_is_host():
		return
	_process_repair(multiplayer.get_remote_sender_id())


@rpc("any_peer", "call_remote", "reliable")
func net_request_toggle_departure() -> void:
	if not _transport_is_host():
		return
	_process_toggle_departure(multiplayer.get_remote_sender_id())


func _process_repair(peer_id: int) -> void:
	if not _owns_mutation() or repair_stage >= REPAIR_STAGE_COUNT:
		return
	if _current_cycle() < MIN_REPAIR_CYCLE:
		return
	var player: Node3D = _player_by_peer(peer_id)
	if player == null or not _in_range(player, REPAIR_RANGE_M):
		return
	var inventory: Node = _inventory_service()
	if inventory == null or int(inventory.call(&"host_count", peer_id, REPAIR_TOOL_ITEM)) < 1:
		return
	var cost: Dictionary = REPAIR_COSTS[repair_stage]
	for item_id: StringName in cost.keys():
		if not bool(inventory.call(&"host_can_remove", peer_id, item_id, int(cost[item_id]))):
			return
	if not bool(inventory.call(&"host_transaction", peer_id, cost, {})):
		return
	repair_stage += 1


func _process_toggle_departure(peer_id: int) -> void:
	if not _owns_mutation() or departed or repair_stage < REPAIR_STAGE_COUNT:
		return
	var player: Node3D = _player_by_peer(peer_id)
	if player == null or not _in_range(player, BOARD_RANGE_M):
		return
	if departure_channeling:
		_cancel_departure()
	else:
		_start_departure()


func _start_departure() -> void:
	departure_channeling = true
	departure_progress_sec = 0.0
	departure_required_players = _session_player_total()
	set_process(true)


## Same D-092 rule Wellspring's own cancel already follows: cancelling forfeits progress outright,
## distinct from everyone stepping off deck, which only pauses it (see `host_tick`).
func _cancel_departure() -> void:
	departure_channeling = false
	departure_progress_sec = 0.0
	set_process(false)


func _process(delta: float) -> void:
	host_tick(delta)


## Advances the departure hold by `delta` seconds, host-only. Split out of `_process()` so a check
## can cross the whole hold in a handful of calls, the same reason Wellspring's `host_tick()` is
## public rather than something only `_physics_process` calls.
func host_tick(delta: float) -> void:
	if not _owns_mutation():
		set_process(false)
		return
	if departure_channeling:
		if _present_count(BOARD_RANGE_M) >= departure_required_players:
			departure_progress_sec = minf(departure_progress_sec + delta, DEPARTURE_HOLD_SEC)
		if departure_progress_sec >= DEPARTURE_HOLD_SEC:
			_finish_departure()
	if not departure_channeling:
		set_process(false)


func _finish_departure() -> void:
	departure_channeling = false
	departed = true
	set_process(false)


func _current_cycle() -> int:
	var cycle_service: Node = get_node_or_null(^"/root/CycleService")
	if cycle_service == null:
		return MIN_REPAIR_CYCLE
	return int(cycle_service.call(&"current_cycle"))


func _inventory_service() -> Node:
	return get_node_or_null(^"/root/InventoryService")


## Every live player within `range_m`, host-side. Works offline too: even solo, the local player is
## in the `&"players"` group as its own multiplayer authority (Wellspring's `_present_count()` uses
## the identical technique).
func _present_count(range_m: float) -> int:
	var count: int = 0
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and _in_range(player, range_m):
			count += 1
	return count


## Total live players THIS SESSION (offline = 1) — snapshotted once at hold start, the same
## read-once-at-the-threshold-moment rule Wellspring's `_session_player_total()` already follows, so
## someone joining or leaving mid-hold does not retroactively change what an already-running attempt
## needs.
func _session_player_total() -> int:
	var count: int = 0
	for _node: Node in get_tree().get_nodes_in_group(&"players"):
		count += 1
	return maxi(count, 1)


func _in_range(player: Node3D, range_m: float) -> bool:
	var range_sq: float = range_m * range_m
	return global_position.distance_squared_to(player.global_position) <= range_sq


func _player_by_peer(peer_id: int) -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.get_multiplayer_authority() == peer_id:
			return player
	return null


func _build_collision() -> void:
	var body := StaticBody3D.new()
	body.name = "ExtractionShipCollision"
	add_child(body)
	var shape := BoxShape3D.new()
	shape.size = HULL_HALF_EXTENTS * 2.0
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position.y = HULL_HALF_EXTENTS.y
	body.add_child(collider)


func _build_static_rig() -> void:
	_rig_root = Node3D.new()
	_rig_root.name = RIG_NODE_NAME
	add_child(_rig_root)
	for part_path: String in STATIC_RIG_PATHS:
		_instance_part(_rig_root, part_path)


func _build_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	for property_name: String in [
		"repair_stage", "departure_channeling", "departure_progress_sec",
		"departure_required_players", "departed"
	]:
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


func _refresh_visual() -> void:
	if not is_inside_tree():
		return
	if _hull_root != null:
		remove_child(_hull_root)
		_hull_root.queue_free()
		_hull_root = null
	_hull_root = Node3D.new()
	_hull_root.name = HULL_NODE_NAME
	add_child(_hull_root)
	var stage: int = clampi(repair_stage, 0, HULL_STATE_PATHS.size() - 1)
	_instance_part(_hull_root, HULL_STATE_PATHS[stage])
	_instance_part(_hull_root, MAST_STATE_PATHS[stage])
	_instance_part(_hull_root, SAIL_STATE_PATHS[stage])


func _instance_part(parent: Node3D, glb_path: String) -> void:
	if glb_path.is_empty():
		return
	var packed: PackedScene = load(glb_path) as PackedScene
	if packed == null:
		push_error("ExtractionShip: could not load %s" % glb_path)
		return
	var part: Node3D = packed.instantiate() as Node3D
	if part == null:
		push_error("ExtractionShip: %s root must be Node3D" % glb_path)
		return
	part.name = glb_path.get_file().get_basename()
	parent.add_child(part)


func _maybe_refresh_visual() -> void:
	var stage: int = clampi(repair_stage, 0, HULL_STATE_PATHS.size() - 1)
	if stage == _last_hull_stage:
		return
	_last_hull_stage = stage
	if is_inside_tree():
		_refresh_visual()


func _owns_mutation() -> bool:
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
