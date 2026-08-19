extends Node

## DefeatService — autoload. Task 6.7 (docs/DESIGN.md §5.3): "Losing = all players down
## simultaneously with no revive available, or the Mire consumes the island."
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, new "Lose condition" row): HOST decides WHEN a run
## has actually ended in defeat — the same host-tick-driven verdict `CycleService`/`WaveSpawner`
## already make for their own state machines. Firing that verdict is deliberately NOT a host-only
## guard around `EventBus.emit_run_wiped()` — that shape is `Wellspring._finish_cap()`'s still-open
## bug (F-168) and the exact trap D-108 named for this task. `defeated`'s setter fires the emit, and
## it runs identically whether this process just decided `defeated = true` itself (the host) or
## received the verdict over the wire (`net_run_defeated`, a client) — the same fix task 6.6 applied
## to `ExtractionShip.departed`'s setter. `SalvageService` is the seam's one existing consumer
## (`EventBus.subscribe_run_wiped`, task 6.6); this file is what finally calls it.
##
## Not `MultiplayerSynchronizer` (D-023's usual mechanism, `ExtractionShip`/`Wellspring`): those
## exist to keep a LATE JOINER in sync with ongoing state, and a run that just ended has no "late"
## left to join. A single reliable broadcast RPC, driven by the same setter every peer's own
## `_apply_defeat()` runs through, is the whole mechanism this needs — see docs/DECISIONS.md D-109.
##
## Two independent triggers, checked every host physics tick (`_owns_decision()` gates both, same
## split `MireGrid._owns_simulation()` uses):
##   1. Team wipe — every currently PRESENT peer (`NetTransport.peer_ids()`, or the solo player when
##      no session is open) reads `PlayerHealth.host_is_alive() == false`. The instant nobody is
##      ALIVE, nobody can revive anybody else either, so DESIGN's "no revive available" is already
##      true — there is no separate timer to wait out.
##   2. Island consumed — `MireGrid.consumed_fraction()` crosses `ISLAND_CONSUMED_FRACTION` of the
##      grid at or above `ISLAND_CONSUMED_CORRUPTION`. Checked on a slow accumulator
##      (`CHECK_INTERVAL_SEC`), the only one of the two worth throttling — it walks all 65536 cells.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

enum Cause { NONE, TEAM_WIPE, ISLAND_CONSUMED }

## Indexed by Cause — StringName is what crosses the wire and what EventBus/UI consumers read.
const CAUSE_NAMES: Dictionary = {
	Cause.TEAM_WIPE: &"team_wipe",
	Cause.ISLAND_CONSUMED: &"island_consumed",
}

## DESIGN.md §5.3 names the condition ("the Mire consumes the island") but gives no number —
## decided here (docs/DECISIONS.md D-109): the run ends once this fraction of the whole grid sits
## at or above this corruption level. Placeholder-tuned, same unplaytested status as every other
## Mire constant (`MireGrid.BASE_SPREAD_RATE`, `CycleService.SPREAD_ESCALATION_PER_CYCLE`) — a
## lower bar than "every single cell" on purpose, since the outer taper never fully saturates
## (`IslandHeightmap.FALLOFF_START_FRACTION`) and a wait-for-100% rule would never actually fire.
const ISLAND_CONSUMED_CORRUPTION: float = 0.95
const ISLAND_CONSUMED_FRACTION: float = 0.97
const CHECK_INTERVAL_SEC: float = 5.0

## Terminal for the run — never reset except by a fresh session (see `_reset()`). Setter fires
## `EventBus.emit_run_wiped()`; see the class doc for why this must never be skipped by a host-only
## guard.
var defeated: bool = false:
	set(value):
		if defeated == value:
			return
		defeated = value
		if defeated:
			EVENT_BUS.emit_run_wiped(_defeat_cycle, _defeat_position)

## What tripped `defeated` — &"team_wipe" or &"island_consumed". Set before `defeated` itself so a
## `run_wiped` subscriber reading this back (`ui/hud/defeat_hud.gd`) never sees the old value.
var cause: StringName = &""

var _defeat_cycle: int = 1
var _defeat_position: Vector3 = Vector3.ZERO
var _elapsed: float = 0.0
var _transport_node: Node


func _ready() -> void:
	set_physics_process(true)
	var transport: Node = _transport()
	transport.get("server_started").connect(_reset)
	transport.get("connected_to_host").connect(_reset)
	transport.get("disconnected").connect(_reset)
	_register_commands()


func _physics_process(delta: float) -> void:
	if not _owns_decision() or defeated:
		return
	if _check_team_wipe():
		_trigger_defeat(Cause.TEAM_WIPE)
		return
	_elapsed += delta
	if _elapsed < CHECK_INTERVAL_SEC:
		return
	_elapsed = 0.0
	if _check_island_consumed():
		_trigger_defeat(Cause.ISLAND_CONSUMED)


func is_defeated() -> bool:
	return defeated


# ── Detection (host-only) ─────────────────────────────────────────────────────────────────────────


## Every currently present peer is DOWNED or DEAD — see the class doc for why that already means
## "no revive available" with no separate window to wait out. A run with zero present peers (a
## harness that never spawned anyone) is never a wipe.
func _check_team_wipe() -> bool:
	var health: Node = _player_health()
	if health == null:
		return false
	var peers: PackedInt32Array = _present_peers()
	if peers.is_empty():
		return false
	for peer_id: int in peers:
		if bool(health.call(&"host_is_alive", peer_id)):
			return false
	return true


func _check_island_consumed() -> bool:
	var mire_grid: Node = get_node_or_null(^"/root/MireGrid")
	if mire_grid == null:
		return false
	var fraction: float = float(mire_grid.call(&"consumed_fraction", ISLAND_CONSUMED_CORRUPTION))
	return fraction >= ISLAND_CONSUMED_FRACTION


## The distinct multiplayer authorities among the `&"players"` group, the same "who is actually
## here right now" signal `ExtractionShip._present_count()`/`_session_player_total()` already use
## instead of `NetTransport.peer_ids()` — a departed peer's body despawns with it, so this needs no
## separate departure/grace-window logic (D-035's retained `PlayerHealth._states` entry for a
## disconnected-but-not-yet-expired peer must NOT count as present for a wipe verdict, and reading
## live bodies instead of the peer roster gets that for free). Works offline too: even solo, the
## local player is its own multiplayer authority in this group.
func _present_peers() -> PackedInt32Array:
	var peers: PackedInt32Array = PackedInt32Array()
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player == null:
			continue
		var peer_id: int = player.get_multiplayer_authority()
		if peer_id > 0 and not peers.has(peer_id):
			peers.append(peer_id)
	return peers


# ── Firing the verdict — see the class doc for why this is a broadcast RPC, not a synchronizer ────


func _trigger_defeat(cause_enum: int) -> void:
	if defeated or not _owns_decision():
		return
	var cause_name: StringName = CAUSE_NAMES[cause_enum]
	var cycle: int = _current_cycle()
	var position: Vector3 = _average_player_position()
	MireLog.info(&"world", "DefeatService: run ended in defeat (%s)" % cause_name)
	_apply_defeat(cause_name, cycle, position)
	if _transport_is_active():
		net_run_defeated.rpc(String(cause_name), cycle, position)


## PROTOCOL_VERSION is NOT bumped for this new RPC — same gap F-161/F-165 already recorded for
## tasks 5.3/6.5: `core/net/net_version.gd` and `tools/handshake_check.gd` were both held by lane
## slate17's 3.7 claim for this task's entire session. See docs/FINDINGS.md.
@rpc("authority", "call_remote", "reliable")
func net_run_defeated(cause_name: String, cycle: int, world_position: Vector3) -> void:
	_apply_defeat(StringName(cause_name), cycle, world_position)


## Runs on every peer — the host calls it directly, a client reaches it through `net_run_defeated`.
## Setting `defeated = true` last is what makes its setter's `emit_run_wiped()` fire with the right
## `cause`/cycle/position already in place.
func _apply_defeat(cause_name: StringName, cycle: int, world_position: Vector3) -> void:
	if defeated:
		return
	cause = cause_name
	_defeat_cycle = cycle
	_defeat_position = world_position
	defeated = true


func _current_cycle() -> int:
	var cycle_service: Node = get_node_or_null(^"/root/CycleService")
	return int(cycle_service.call(&"current_cycle")) if cycle_service != null else 1


## Best-effort flavour for `run_wiped`'s `world_position` arg — no consumer reads it today
## (`SalvageService._on_run_wiped` ignores it), but a future death marker or minimap ping might.
func _average_player_position() -> Vector3:
	var total := Vector3.ZERO
	var count: int = 0
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null:
			total += player.global_position
			count += 1
	return total / float(count) if count > 0 else Vector3.ZERO


func _reset() -> void:
	defeated = false
	cause = &""
	_defeat_cycle = 1
	_defeat_position = Vector3.ZERO
	_elapsed = 0.0


func _owns_decision() -> bool:
	var transport: Node = _transport()
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _player_health() -> Node:
	return get_node_or_null(^"/root/PlayerHealth")


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node(^"/root/NetTransport")
	return _transport_node


func _transport_is_active() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_active"))


# ── Commands (docs/COMMANDS.md §7 — task 3.16's convention) ─────────────────────────────────────


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"defeat", {
		"scope": &"local",
		"args": [],
		"handler": _cmd_defeat,
		"help": "defeat — read whether this run has ended in defeat, and why",
	})


func _cmd_defeat(_ctx: Dictionary, _args: Dictionary) -> Dictionary:
	if not defeated:
		return {"ok": true, "message": "run in progress", "data": {"defeated": false}}
	return {"ok": true, "message": "defeated (%s)" % cause,
		"data": {"defeated": true, "cause": String(cause)}}
