class_name Wellspring
extends Node3D

## Host-authoritative capture ritual for one Wellspring objective (DESIGN.md §4.2).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Wellspring ritual" row): HOST. A request to
## start/cancel the channel carries no timer, no player count and no roll — the host alone decides
## whether it is accepted, exactly the "harvest pattern" Chest and Harvestable already established.
## `capped`/`channeling`/`progress_sec`/`duration_sec`/`required_players` are the only state that
## crosses the wire, through a code-built MultiplayerSynchronizer (D-023), same as Chest's `opened`.
## Offline play runs the identical authority path locally.
##
## Built and positioned identically on every peer by `autoload/wellspring_service.gd` from the
## map's own `objective` marker — this node holds no map-specific knowledge of its own, same split
## `autoload/harvest_world.gd` uses for harvestable holders.
##
## D-092: capping does NOT require the defense wave to be cleared, and does not grant a chest, Mire
## corruption-clear, or Attunement selection. See docs/DECISIONS.md for why — the short version is
## that Mire (4.9-4.11) does not exist yet and Attunement already fires at run start, not at cap
## (D-071). `EventBus.emit_wellspring_capped()` is the seam those future systems hook into.
##
## Task 6.4 (DESIGN.md §5.1 item 1, "Capped Wellsprings begin re-corrupting"; ROADMAP.md's own 6.4
## line: "decay on a host timer unless Warded"): once `capped`, the NEXT `EventBus.cycle_advanced`
## starts a real-time degradation clock (`recorruption_sec`) that only accrues while no placed Ward
## (`autoload/build_service.gd`'s `ward_radii()`, the same provider `MireGrid` already consumes for
## its own tick — task 4.11) covers this Wellspring's position — the identical pause-not-reset rule
## D-092 already gives the ritual's own presence requirement. It rides the same `host_tick()` this
## file already exposes for the ritual, so a check can cross the whole clock in one call exactly like
## it already does for a 60-150s ritual. Finishing flips `capped` back to `false` — the exact
## pre-ritual state, so `request_toggle_channel()` recaptures it with no special-casing — and fires
## `EventBus.emit_wellspring_recorrupted()`, `MireGrid`'s seam to undo the spread-rate reduction this
## cap granted (D-104).

const EVENT_BUS := preload("res://core/events/event_bus.gd")

const UNCAPPED_MESH_PATH: String = "res://assets/wellsprings/exports/wellspring_uncapped.glb"
const CAPPED_MESH_PATH: String = "res://assets/wellsprings/exports/wellspring_capped.glb"
const RECORRUPTING_MESH_PATH: String = "res://assets/wellsprings/exports/wellspring_recorrupting.glb"
const CORRUPTED_MESH_PATH: String = "res://assets/wellsprings/exports/wellspring_corrupted.glb"
## Shared across all four A-008 condition states (assets/wellsprings/README.md's state-swap
## contract): same 4.6 m foundation, centred at the shared origin, regardless of which state is
## showing. Collision is therefore built once and never swapped.
const FOUNDATION_RADIUS_M: float = 2.4
const FOUNDATION_HEIGHT_M: float = 0.6

## A player counts as "present" within this radius — comfortably past the 7.1 m boundary-stones
## ring (assets/wellsprings/catalog.json), so standing inside the ring always counts.
const PRESENCE_RANGE_M: float = 4.5
const COOP_DURATION_SEC: float = 60.0
## D-092: 2.5× the co-op duration. DESIGN.md §4.5 says only "longer", not a number.
const SOLO_DURATION_SEC: float = 150.0
const DEFENSE_WAVE_BASE_COUNT: int = 3
const DEFENSE_WAVE_PER_PLAYER: int = 1
const DEFENSE_WAVE_ENEMY_ID: StringName = &"crawler"
const DEFENSE_WAVE_SCATTER_M: float = 5.0

## Placeholder-tuned, same status as `MireGrid.BASE_SPREAD_RATE` and `CycleService`'s own escalation
## constant — nothing here has been through a real playtest yet. Chosen so a capped Wellspring left
## unattended survives a good chunk of the Cycle that started its clock (`DayNight.day_length_seconds`
## defaults to 900s) without the timer feeling instant, but still forces a real choice before too
## many Cycles pass.
const RECORRUPTION_DURATION_SEC: float = 900.0
## Below this fraction of `RECORRUPTION_DURATION_SEC` the capped mesh keeps showing — a Wellspring
## that just started degrading should not look different yet. At and above it, the mesh swaps to the
## visibly-decaying `wellspring_recorrupting.glb` state (assets/wellsprings/README.md's state-swap
## contract) so players get a read on borrowed time before it flips back to needing a fresh ritual.
const RECORRUPTING_VISUAL_FRACTION: float = 0.5

const WELLSPRING_GROUP: StringName = &"wellspring"
const SYNC_NODE_NAME: StringName = &"WellspringSync"
const VISUAL_NODE_NAME: StringName = &"WellspringVisual"

## Replicated. Setter keeps the visual correct when a network delta arrives on a client, and fires
## `wellspring_capped`/`wellspring_recorrupted` on the false->true / true->false transitions rather
## than `_finish_cap()`/`_finish_recorruption()` doing it directly (F-168 fixed the former; F-181
## applied the identical fix to the latter, which had the same bug — `_finish_recorruption()` is only
## ever reached via `host_tick()`'s `_owns_mutation()` guard, so its direct emit call never ran on a
## client at all). `EventBus` is a per-process static, so a host-only emit call never reaches a
## client's own local bus, and `SalvageService`'s milestone bonus needs both events on EVERY peer.
## Driving the emit off the setter means it fires identically whether this process just set `capped`
## itself (the host) or received it over the wire (a client, via `_sync`) — `capped` is one of the
## replicated properties in `_build_synchronizer()`, so both paths run this same setter.
var capped: bool = false:
	set(value):
		if capped == value:
			return
		capped = value
		_maybe_refresh_visual()
		if capped:
			EVENT_BUS.emit_wellspring_capped(name, global_position)
		else:
			EVENT_BUS.emit_wellspring_recorrupted(name, global_position)

## Replicated. Presentation reads this to show/hide the progress prompt.
var channeling: bool = false
## Replicated. Seconds of channel time accumulated so far this attempt.
var progress_sec: float = 0.0
## Replicated. Snapshotted when the channel starts — the duration this attempt needs to finish.
var duration_sec: float = COOP_DURATION_SEC
## Replicated. Snapshotted when the channel starts — how many players must stay present.
var required_players: int = 2
## Replicated. Real-time seconds accumulated toward `RECORRUPTION_DURATION_SEC` since the last time
## a Cycle advanced while this Wellspring was capped. Zero whenever `capped` is false.
var recorruption_sec: float = 0.0:
	set(value):
		if is_equal_approx(recorruption_sec, value):
			return
		recorruption_sec = value
		_maybe_refresh_visual()
## Replicated. True once this Wellspring has fully re-corrupted at least once — the only way to tell
## "never capped" (`wellspring_uncapped.glb`) apart from "was capped, lost it"
## (`wellspring_corrupted.glb`) once `capped` is back to false. Never reset within a run; a recapture
## only clears `capped`/`recorruption_sec`. F-243 is the one cross-run exception —
## `host_reset_for_new_run()` clears it too, since a new run needs a Wellspring that reads as "never
## capped", not one still carrying the last run's degradation history.
var has_recorrupted: bool = false:
	set(value):
		if has_recorrupted == value:
			return
		has_recorrupted = value
		_maybe_refresh_visual()

## Host-only, not replicated: whether this run's degradation clock is currently ticking. Set by
## `_on_cycle_advanced()`, cleared by `_finish_recorruption()`. Clients never read this — they only
## ever see the replicated `recorruption_sec` it drives.
var _recorruption_active: bool = false

var _visual: Node3D
var _sync: MultiplayerSynchronizer
var _visual_refresh_scheduled: bool = false
var _last_visual_mesh_path: String = ""


func _ready() -> void:
	set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	add_to_group(WELLSPRING_GROUP)
	_build_collision()
	_build_synchronizer()
	_refresh_visual()
	_last_visual_mesh_path = _mesh_path_for_state()
	set_process(false)
	EVENT_BUS.subscribe_cycle_advanced(_on_cycle_advanced)
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_cycle_advanced(_on_cycle_advanced)
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)


## Client-facing: press interact while in range. Toggles start/cancel; a no-op once capped.
func request_toggle_channel() -> void:
	if _owns_mutation():
		_process_toggle(_local_peer_id())
	elif _transport_is_active():
		net_request_toggle_channel.rpc_id(NetConfig.HOST_PEER_ID)


## Local-only convenience for the HUD prompt: is the LOCAL player close enough to act on this
## Wellspring right now? Presentation-only, same caveat as every other `local_*`/`nearby_*` helper
## in this codebase — the host repeats this check independently before accepting a request.
func is_local_player_in_range() -> bool:
	var player: Node3D = _player_by_peer(_local_peer_id())
	return player != null and _in_range(player)


@rpc("any_peer", "call_remote", "reliable")
func net_request_toggle_channel() -> void:
	if not _transport_is_host():
		return
	_process_toggle(multiplayer.get_remote_sender_id())


func _process_toggle(peer_id: int) -> void:
	if not _owns_mutation() or capped:
		return
	var player: Node3D = _player_by_peer(peer_id)
	if player == null or not _in_range(player):
		return
	if channeling:
		_cancel_channel()
	else:
		_start_channel()


func _start_channel() -> void:
	channeling = true
	progress_sec = 0.0
	var solo: bool = _session_player_total() <= 1
	# Cycle Modifier `tithe` (F-245, content/cycle_modifiers/tithe.tres): one more player must be
	# physically present than usual. Read once here, same "snapshotted at channel start" rule every
	# other field on this line already follows — a draw mid-ritual does not retroactively change an
	# attempt already running. Solo is exempt: the def's own text ("a DUO ... has to physically
	# regroup") is about raising an existing co-op requirement, not about making a Wellspring
	# uncappable alone — tools/wellspring_recorruption_check.gd's solo recapture caught exactly that
	# reading (`required_players` 1 -> 2 with only one player ever in the scene) before this guard.
	required_players = (1 if solo else 2) + (1 if (_has_modifier(&"tithe") and not solo) else 0)
	duration_sec = SOLO_DURATION_SEC if solo else COOP_DURATION_SEC
	set_process(true)
	_spawn_defense_wave()


## D-092: cancelling forfeits progress rather than merely pausing it — a deliberate, simple rule
## distinct from "everyone stepped away", which pauses (see _process below) without resetting.
func _cancel_channel() -> void:
	channeling = false
	progress_sec = 0.0
	set_process(false)


## F-243: resets this Wellspring to its never-capped state for a new run — same island, same node
## (docs/DECISIONS.md's F-243 entry). Host-only; a client's own copy no-ops and picks up the reset
## through the normal replicated-property sync every other mutation here already uses. Going through
## `capped`'s own setter (rather than a private backing field) means a Wellspring capped when the run
## ended also fires `wellspring_recorrupted` here — accepted, not a bug: `MireGrid._on_wellspring_
## recorrupted()` only ever decrements `_capped_wellsprings` (clamped at 0), and `MireGrid.host_reset()`
## (also subscribed to `run_restarted`) sets that count to 0 directly regardless of which order the
## two subscribers run in.
func host_reset_for_new_run() -> void:
	if not _owns_mutation():
		return
	channeling = false
	progress_sec = 0.0
	_recorruption_active = false
	recorruption_sec = 0.0
	has_recorrupted = false
	capped = false
	set_process(false)


func _on_run_restarted() -> void:
	host_reset_for_new_run()


func _process(delta: float) -> void:
	host_tick(delta)


## Advances the ritual AND the re-corruption clock by `delta` seconds, host-only. Split out of
## `_process()` so a check can cross a whole 60-150 s ritual, or the much longer
## `RECORRUPTION_DURATION_SEC` clock, in a handful of calls instead of thousands of real engine
## frames — the same reason `DayNight.host_advance()` is public rather than something only
## `_physics_process` calls.
func host_tick(delta: float) -> void:
	if not _owns_mutation():
		set_process(false)
		return
	if channeling:
		if _present_count() >= required_players:
			progress_sec = minf(progress_sec + delta, duration_sec)
		if progress_sec >= duration_sec:
			_finish_cap()
	if capped and _recorruption_active and not _is_warded():
		recorruption_sec = minf(recorruption_sec + delta, RECORRUPTION_DURATION_SEC)
		if recorruption_sec >= RECORRUPTION_DURATION_SEC:
			_finish_recorruption()
	if not channeling and not (capped and _recorruption_active):
		set_process(false)


func _finish_cap() -> void:
	channeling = false
	progress_sec = 0.0
	capped = true
	recorruption_sec = 0.0
	set_process(false)


## Host-only. The seam DESIGN.md §5.1 item 1 names directly: "Capped Wellsprings begin
## re-corrupting" is one of the three things that happen at a Cycle turnover. A Wellspring capped
## mid-Cycle gets its first free ride to the NEXT turnover before the clock starts — same "read once
## at the threshold moment" rule `_session_player_total()` already follows for the ritual itself.
func _on_cycle_advanced(_cycle: int) -> void:
	if not _owns_mutation() or not capped or _recorruption_active:
		return
	_recorruption_active = true
	set_process(true)


## ROADMAP.md's 6.4 line names this explicitly ("unless Warded"). Reuses `BuildService.ward_radii()`
## rather than `MireGrid`'s own `_ward_circles_provider` (private to that file) — same source, same
## shape, one extra hop through the autoload instead of threading a second seam through MireGrid.
##
## Called from `host_tick()`, so once per rendered frame for as long as a re-corruption clock runs.
## That was the expensive half of F-337: `ward_radii()` used to rebuild itself from every placed
## piece on every call, having been written for a consumer that asks twice a second. It is cached
## now, so this reads a small list of circles and nothing else. No throttle was added here on
## purpose — a ward raised mid-re-corruption should stop the clock on the frame it goes up, not up to
## a tick later, and the cache removes the reason to trade that away.
func _is_warded() -> bool:
	var build_service: Node = get_node_or_null(^"/root/BuildService")
	if build_service == null:
		return false
	var position: Vector2 = Vector2(global_position.x, global_position.z)
	for circle: Dictionary in build_service.call(&"ward_radii"):
		var radius: float = float(circle.get("radius", 0.0))
		if radius <= 0.0:
			continue
		var center: Vector2 = circle.get("position", Vector2.ZERO)
		if position.distance_to(center) <= radius:
			return true
	return false


func _finish_recorruption() -> void:
	_recorruption_active = false
	has_recorrupted = true
	capped = false
	recorruption_sec = 0.0
	set_process(false)


func _spawn_defense_wave() -> void:
	var waves: Node = get_node_or_null(^"/root/WaveSpawner")
	if waves == null:
		return
	var count: int = DEFENSE_WAVE_BASE_COUNT + DEFENSE_WAVE_PER_PLAYER * _session_player_total()
	waves.call(
		&"host_spawn_wave_at", global_position, count, DEFENSE_WAVE_ENEMY_ID, DEFENSE_WAVE_SCATTER_M
	)


## Every live player within PRESENCE_RANGE_M, host-side. Works offline too: even solo, the local
## player is in the `&"players"` group as its own multiplayer authority (same technique
## `entities/player/player_controller.gd`'s `_nearest_downed_teammate` uses on the client side).
func _present_count() -> int:
	var count: int = 0
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and _in_range(player):
			count += 1
	return count


## Total live players THIS SESSION (offline = 1) — snapshotted once at channel start, same
## read-once-at-the-threshold-moment rule `systems/waves/wave_spawner.gd`'s base_count/per_player
## already follow, so a player joining or leaving mid-ritual does not retroactively change what an
## already-running attempt needs.
func _session_player_total() -> int:
	var count: int = 0
	for _node: Node in get_tree().get_nodes_in_group(&"players"):
		count += 1
	return maxi(count, 1)


func _in_range(player: Node3D) -> bool:
	var range_sq: float = PRESENCE_RANGE_M * PRESENCE_RANGE_M
	return global_position.distance_squared_to(player.global_position) <= range_sq


func _player_by_peer(peer_id: int) -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.get_multiplayer_authority() == peer_id:
			return player
	return null


func _build_collision() -> void:
	var body := StaticBody3D.new()
	body.name = "WellspringCollision"
	add_child(body)
	var shape := CylinderShape3D.new()
	shape.radius = FOUNDATION_RADIUS_M
	shape.height = FOUNDATION_HEIGHT_M
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position.y = FOUNDATION_HEIGHT_M * 0.5
	body.add_child(collider)


func _build_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	for property_name: String in [
		"capped", "channeling", "progress_sec", "duration_sec", "required_players",
		"recorruption_sec", "has_recorrupted"
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


## The condition-state mesh for the current replicated fields — one of the four A-008 states
## (assets/wellsprings/README.md's state-swap contract). `capped` alone no longer decides this: a
## capped Wellspring past `RECORRUPTING_VISUAL_FRACTION` of its clock shows the decaying state, and
## an uncapped one that got there by fully re-corrupting (rather than never having been capped) shows
## the worse "corrupted" state, not the original "uncapped" one.
func _mesh_path_for_state() -> String:
	if capped:
		if recorruption_sec >= RECORRUPTION_DURATION_SEC * RECORRUPTING_VISUAL_FRACTION:
			return RECORRUPTING_MESH_PATH
		return CAPPED_MESH_PATH
	return CORRUPTED_MESH_PATH if has_recorrupted else UNCAPPED_MESH_PATH


func _refresh_visual() -> void:
	if not is_inside_tree():
		return
	if _visual != null:
		remove_child(_visual)
		_visual.queue_free()
		_visual = null
	var packed: PackedScene = load(_mesh_path_for_state()) as PackedScene
	if packed == null:
		return
	_visual = packed.instantiate() as Node3D
	if _visual == null:
		push_error("Wellspring %s: state mesh root must be Node3D" % name)
		return
	_visual.name = VISUAL_NODE_NAME
	add_child(_visual)


## Recomputes the target mesh path and only schedules an actual rebuild when it changed — called
## from every replicated field's setter, including `recorruption_sec`, which changes every tick
## while the clock runs. Cheap: a string compare, not a scene load, on every no-op call.
func _maybe_refresh_visual() -> void:
	var target: String = _mesh_path_for_state()
	if target == _last_visual_mesh_path:
		return
	_last_visual_mesh_path = target
	_schedule_visual_refresh()


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


func _has_modifier(id: StringName) -> bool:
	var modifiers: Node = get_node_or_null(^"/root/CycleModifierService")
	return modifiers != null and bool(modifiers.call(&"has_modifier", id))


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
