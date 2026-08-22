extends SceneTree

## Direct proof for task 4.8:
##   1. The shipped project actually wires WellspringService, and it builds a live Wellspring from
##      an `objective` marker (F-068's lesson — a script that is merely correct but never registered
##      is exactly the failure this class of check exists to catch).
##   2. The ritual state machine itself: toggle start/cancel, an out-of-range requester is rejected,
##      a solo attempt gets a longer timer and still completes, and a co-op attempt's progress
##      PAUSES (not resets) while under the 2-player presence requirement, then finishes once both
##      are present. `host_tick()` crosses whole ritual durations in one call, the same reason
##      `DayNight.host_advance()` exists — no need to wait 80 real seconds for a headless check.
##   3. F-168: `wellspring_capped` fires off `capped`'s setter, not `_finish_cap()`'s host-only body —
##      so setting `capped` the way a client's MultiplayerSynchronizer would (a bare property write,
##      never through `_finish_cap()`) still fires the event. Before the fix this branch caught
##      nothing, because the emit lived only in the host-only ritual path.
##   4. F-181: the identical bug existed on the true->false transition — `wellspring_recorrupted` fired
##      from `_finish_recorruption()`'s host-only body, so a bare `capped = false` write (the shape a
##      client's synchronizer delta takes) fired nothing. Same fix, same setter, symmetric proof.
##   5. F-374: the solo timer is the retuned 80 s, not the 150 s that read in play as "an absurdly
##      long time to cap", and a lapse in presence shorter than `PRESENCE_GRACE_SEC` no longer
##      stalls the bar — a crawler's knockback out of a 4.5 m circle used to freeze it for the whole
##      round trip. Past the grace it pauses, and it still never decays (D-092).
##
##   .agent/bin/agent godot --script tools/wellspring_check.gd

const WELLSPRING_SCRIPT := preload("res://systems/wellspring/wellspring.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

var failures: int = 0
var world: Node
var _capped_events: Array = []
var _recorrupted_events: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return

	await _check_marker_consumption()
	_check_ritual_fsm()
	_check_capped_event_via_replication()
	_check_recorrupted_event_via_replication()

	print("\nWELLSPRING_CHECK failures=%d" % failures)
	finish()


func _check_wiring() -> bool:
	print("== the shipped project actually has a Wellspring service ==")
	var service: Node = root.get_node_or_null(^"WellspringService")
	world = root.get_node_or_null(^"EnemyWorld")
	check(service != null, "WellspringService is registered as an autoload")
	check(world != null, "EnemyWorld autoload exists")
	return service != null and world != null


func _check_marker_consumption() -> void:
	print("\n== objective marker -> live Wellspring ==")
	var objective := Marker3D.new()
	objective.name = "CheckObjectiveMarker"
	objective.add_to_group(&"authored_world_marker")
	objective.set_meta(&"kind", "objective")
	objective.position = Vector3(900.0, 0.0, 900.0)
	root.add_child(objective)

	var decoy := Marker3D.new()
	decoy.name = "CheckDecoyMarker"
	decoy.add_to_group(&"authored_world_marker")
	decoy.set_meta(&"kind", "enemy_nest")
	root.add_child(decoy)

	await process_frame
	await process_frame

	var built: Node3D = null
	for child: Node in objective.get_children():
		if child.is_in_group(&"wellspring"):
			built = child as Node3D
	check(built != null, "an 'objective' marker gets a live Wellspring child")
	check(objective.get_children().size() == 1,
		"exactly one Wellspring is built per marker (no double-build)")

	var decoy_built := false
	for child: Node in decoy.get_children():
		if child.is_in_group(&"wellspring"):
			decoy_built = true
	check(not decoy_built, "a non-'objective' marker gets no Wellspring")


func _check_ritual_fsm() -> void:
	print("\n== ritual state machine ==")
	EVENT_BUS.subscribe_wellspring_capped(_on_wellspring_capped)
	world.call("host_despawn_all")

	var wellspring := WELLSPRING_SCRIPT.new() as Node3D
	wellspring.name = "CheckWellspringSolo"
	root.add_child(wellspring)
	wellspring.global_position = Vector3(-500.0, 0.0, -500.0)

	var player_one := Node3D.new()
	player_one.name = "CheckPlayerOne"
	player_one.add_to_group(&"players")
	player_one.set_multiplayer_authority(1)
	root.add_child(player_one)
	player_one.global_position = wellspring.global_position

	print("-- toggle start/cancel --")
	wellspring.call(&"request_toggle_channel")
	check(bool(wellspring.get("channeling")), "an in-range press starts the channel")
	check(int(wellspring.get("required_players")) == 1, "one live player -> solo requirement")
	# F-374 retuned this from 150.0. The assertion names the number rather than merely proving
	# "longer than co-op", because the SIZE of the solo premium was the bug — an inequality check
	# would have stayed green through the whole of it. Retuning again means editing this line on
	# purpose, which is the point (this is a tuning constant Sequoyah reviews at commit level).
	check(is_equal_approx(float(wellspring.get("duration_sec")), 80.0),
		"solo duration is the longer fallback, at F-374's retuned 80 s")
	check(float(wellspring.get("duration_sec")) > WELLSPRING_SCRIPT.COOP_DURATION_SEC,
		"solo is still longer than co-op, as DESIGN.md §4.5 asks")
	wellspring.call(&"request_toggle_channel")
	check(not bool(wellspring.get("channeling")), "a second press cancels the channel")
	check(is_equal_approx(float(wellspring.get("progress_sec")), 0.0),
		"cancelling forfeits progress rather than pausing it")
	var defenders_after_cancel: int = int(world.call("live_count"))

	print("-- out-of-range requester is rejected --")
	player_one.global_position = wellspring.global_position + Vector3(500.0, 0.0, 0.0)
	wellspring.call(&"request_toggle_channel")
	check(not bool(wellspring.get("channeling")),
		"a requester outside PRESENCE_RANGE_M cannot start the channel")

	print("-- solo completion spawns a defense wave and caps --")
	player_one.global_position = wellspring.global_position
	var live_before: int = int(world.call("live_count"))
	wellspring.call(&"request_toggle_channel")
	check(bool(wellspring.get("channeling")), "back in range, the channel starts")
	var wave_spawned: int = int(world.call("live_count")) - live_before
	check(defenders_after_cancel == 4,
		"the first solo start deploys base(3) + per_player(1) x 1 defenders (%d)" % defenders_after_cancel)
	check(wave_spawned == 0,
		"restarting a cancelled ritual does not stack another defense wave (%d added)" % wave_spawned)
	for _restart: int in 5:
		wellspring.call(&"request_toggle_channel")
		wellspring.call(&"request_toggle_channel")
	check(int(world.call("live_count")) == defenders_after_cancel,
		"five more cancel/restart cycles keep the encounter bounded at %d enemies" % defenders_after_cancel)
	wellspring.call(&"host_tick", 200.0)
	check(bool(wellspring.get("capped")), "a full-duration tick with the player present caps it")
	check(not bool(wellspring.get("channeling")), "capping ends the channel")
	check(_capped_events.size() == 1, "EventBus.emit_wellspring_capped fired exactly once")
	if not _capped_events.is_empty():
		var event: Dictionary = _capped_events[0]
		check(String(event.get("name", "")) == "CheckWellspringSolo",
			"the capped event names the right Wellspring")
	world.call("host_despawn_all")

	print("-- co-op requirement pauses progress until both players are present --")
	var wellspring_two := WELLSPRING_SCRIPT.new() as Node3D
	wellspring_two.name = "CheckWellspringCoop"
	root.add_child(wellspring_two)
	wellspring_two.global_position = Vector3(-800.0, 0.0, -800.0)
	player_one.global_position = wellspring_two.global_position

	var player_two := Node3D.new()
	player_two.name = "CheckPlayerTwo"
	player_two.add_to_group(&"players")
	player_two.set_multiplayer_authority(2)
	root.add_child(player_two)
	player_two.global_position = wellspring_two.global_position + Vector3(500.0, 0.0, 0.0)

	wellspring_two.call(&"request_toggle_channel")
	check(int(wellspring_two.get("required_players")) == 2,
		"two live players this session -> the co-op requirement")
	check(is_equal_approx(float(wellspring_two.get("duration_sec")), 60.0),
		"co-op duration is the short timer")
	wellspring_two.call(&"host_tick", 70.0)
	check(is_equal_approx(float(wellspring_two.get("progress_sec")), 0.0),
		"progress does not advance while only one of two required players is present")
	check(not bool(wellspring_two.get("capped")), "not capped while under-presence")

	player_two.global_position = wellspring_two.global_position
	wellspring_two.call(&"host_tick", 70.0)
	check(bool(wellspring_two.get("capped")),
		"progress resumes and finishes once both players are present")
	world.call("host_despawn_all")

	_check_presence_grace(player_one, player_two)


## F-374's second half. The finding's own words: a hard pause "is what makes an interrupted cap feel
## long rather than hard" — one crawler knockback out of a 4.5 m circle froze the bar for the entire
## walk back. `PRESENCE_GRACE_SEC` forgives exactly that round trip and nothing longer.
##
## Deltas here are small and exact, unlike the 70-200 s fast-forwards above, because the whole
## behaviour under test lives in a two-second window. That means real engine frames would corrupt it:
## `_start_channel()` turns `_process` on, so the wellspring would keep ticking itself between these
## assertions. Driving `host_tick()` by hand with `_process` off is the same trick
## `tools/player_vitals_check.gd` uses on PlayerHealth, and for the same reason.
func _check_presence_grace(player_one: Node3D, player_two: Node3D) -> void:
	print("\n== F-374: a knockback shorter than the presence grace does not stall the bar ==")
	# Back to a solo session — `_session_player_total()` counts the group, and a second body left in
	# it would make this a co-op attempt needing two present players. Restored at the end.
	player_two.remove_from_group(&"players")

	var wellspring := WELLSPRING_SCRIPT.new() as Node3D
	wellspring.name = "CheckWellspringGrace"
	root.add_child(wellspring)
	wellspring.global_position = Vector3(-1100.0, 0.0, -1100.0)
	player_one.global_position = wellspring.global_position
	var away: Vector3 = wellspring.global_position + Vector3(50.0, 0.0, 0.0)

	wellspring.call(&"request_toggle_channel")
	wellspring.set_process(false)
	check(bool(wellspring.get("channeling")), "the solo attempt starts")
	check(is_equal_approx(float(wellspring.get("duration_sec")),
		WELLSPRING_SCRIPT.SOLO_DURATION_SEC), "and it is running the solo duration")

	wellspring.call(&"host_tick", 5.0)
	check(is_equal_approx(float(wellspring.get("progress_sec")), 5.0),
		"progress accrues second for second while present")

	player_one.global_position = away
	wellspring.call(&"host_tick", 1.0)
	check(is_equal_approx(float(wellspring.get("progress_sec")), 6.0),
		"a 1 s lapse, inside PRESENCE_GRACE_SEC, keeps the bar moving (F-374)")
	wellspring.call(&"host_tick", 1.5)
	check(is_equal_approx(float(wellspring.get("progress_sec")), 6.0),
		"2.5 s of unbroken absence is past the grace, and the bar stops")
	wellspring.call(&"host_tick", 300.0)
	check(is_equal_approx(float(wellspring.get("progress_sec")), 6.0),
		"it stays stopped however long nobody is present — paused, never decayed (D-092)")

	player_one.global_position = wellspring.global_position
	wellspring.call(&"host_tick", 2.0)
	check(is_equal_approx(float(wellspring.get("progress_sec")), 8.0),
		"returning resumes from exactly where it paused")
	player_one.global_position = away
	wellspring.call(&"host_tick", 1.0)
	check(is_equal_approx(float(wellspring.get("progress_sec")), 9.0),
		"the grace re-arms on return, so the second knockback is forgiven too")

	player_one.global_position = wellspring.global_position
	wellspring.call(&"host_tick", WELLSPRING_SCRIPT.SOLO_DURATION_SEC)
	check(bool(wellspring.get("capped")), "and the attempt still finishes")

	player_two.add_to_group(&"players")
	world.call("host_despawn_all")


## F-168: a non-host peer never calls `_finish_cap()` — it only ever learns `capped` went true by a
## `MultiplayerSynchronizer` delta writing the property directly. Reproduce that shape exactly (bare
## assignment, no ritual, no host_tick) and prove the event still fires — before the fix it did not,
## because the emit lived in `_finish_cap()`'s host-only body instead of `capped`'s setter.
func _check_capped_event_via_replication() -> void:
	print("\n== F-168: capped fires wellspring_capped even set outside the host ritual path ==")
	EVENT_BUS.subscribe_wellspring_capped(_on_wellspring_capped)
	_capped_events.clear()

	var wellspring := WELLSPRING_SCRIPT.new() as Node3D
	wellspring.name = "CheckWellspringReplicated"
	root.add_child(wellspring)

	wellspring.set("capped", true)
	check(_capped_events.size() == 1,
		"a bare 'capped = true' write (the shape a client's synchronizer delta takes) fires the event")
	if not _capped_events.is_empty():
		check(String(_capped_events[0].get("name", "")) == "CheckWellspringReplicated",
			"the capped event names the right Wellspring")

	wellspring.set("capped", true)
	check(_capped_events.size() == 1, "re-setting capped to the same value does not re-fire the event")

	EVENT_BUS.unsubscribe_wellspring_capped(_on_wellspring_capped)
	wellspring.queue_free()


func _on_wellspring_capped(wellspring_name: StringName, world_position: Vector3) -> void:
	_capped_events.append({"name": String(wellspring_name), "position": world_position})


## F-181: a non-host peer never calls `_finish_recorruption()` — it only ever learns `capped` went
## false by a `MultiplayerSynchronizer` delta writing the property directly. Reproduce that shape
## exactly (bare assignment, no clock, no host_tick) and prove the event still fires — before the fix
## it did not, because the emit lived in `_finish_recorruption()`'s host-only body instead of
## `capped`'s setter.
func _check_recorrupted_event_via_replication() -> void:
	print("\n== F-181: capped=false fires wellspring_recorrupted even set outside the host clock path ==")
	EVENT_BUS.subscribe_wellspring_recorrupted(_on_wellspring_recorrupted)
	_recorrupted_events.clear()

	var wellspring := WELLSPRING_SCRIPT.new() as Node3D
	wellspring.name = "CheckWellspringRecorruptedReplicated"
	root.add_child(wellspring)

	wellspring.set("capped", true)
	wellspring.set("capped", false)
	check(_recorrupted_events.size() == 1,
		"a bare 'capped = false' write (the shape a client's synchronizer delta takes) fires the event")
	if not _recorrupted_events.is_empty():
		check(String(_recorrupted_events[0].get("name", "")) == "CheckWellspringRecorruptedReplicated",
			"the recorrupted event names the right Wellspring")

	wellspring.set("capped", false)
	check(_recorrupted_events.size() == 1, "re-setting capped to the same value does not re-fire the event")

	EVENT_BUS.unsubscribe_wellspring_recorrupted(_on_wellspring_recorrupted)
	wellspring.queue_free()


func _on_wellspring_recorrupted(wellspring_name: StringName, world_position: Vector3) -> void:
	_recorrupted_events.append({"name": String(wellspring_name), "position": world_position})


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	EVENT_BUS.unsubscribe_wellspring_capped(_on_wellspring_capped)
	quit(0 if failures == 0 else 1)
