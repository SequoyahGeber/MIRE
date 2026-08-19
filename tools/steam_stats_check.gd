extends SceneTree

## Direct proof for task 8.3 (achievements, stats, rich presence — the display half; F-123/F-127
## already proved the join-plumbing half via tools/rich_presence_check.gd and tools/steam_lobby_check.gd,
## which this task's work order also names but which do not exercise anything this task built — see
## docs/DELEGATION.md's own note on that mismatch):
##
##   1. The shipped project registers SteamStats and RichPresenceService as autoloads, and SteamLobby
##      exposes the new set_status() method they both depend on.
##   2. SteamStats's local trigger logic: EventBus events increment the right stat, unlock the right
##      achievement exactly once (not on a repeat event), and both survive a round trip through
##      user:// — with no Steam client required, matching every other per-player-local service's own
##      check (tools/salvage_check.gd, tools/unlock_check.gd).
##   3. Cycle- and Salvage-threshold achievements unlock exactly at their named milestone, not before.
##   4. The F-249 sibling fix: ExtractionShip.repair_stage's own setter now fires
##      EventBus.emit_ship_repaired() the instant it crosses into fully-repaired — proven directly
##      (no host-only call path needed) and proven end-to-end into SteamStats's own counter.
##   5. RichPresenceService.compute_status_text() is pure and needs no Steam session to assert.
##
##   .agent/bin/agent godot --script tools/steam_stats_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const STEAM_STATS_SAVE := preload("res://core/save/steam_stats_save.gd")
const EXTRACTION_SHIP := preload("res://systems/extraction/extraction_ship.gd")
## Consts read straight from the source script rather than hand-copied string literals, the same
## "can't drift apart" reasoning F-226's own fix gives for its preloaded CYCLE_SERVICE_SCRIPT const.
const STEAM_STATS_SCRIPT := preload("res://autoload/steam_stats.gd")

## Never a real player's save — deleted at the start and end of this run.
const TEST_SAVE_PATH: String = "user://steam_stats_check.json"

var failures: int = 0
var steam_stats: Node
var rich_presence: Node
var steam_lobby: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_cleanup()

	if not _check_wiring():
		_cleanup()
		finish()
		return

	steam_stats.set(&"save_path", TEST_SAVE_PATH)
	# Wipe whatever _ready() already loaded from a stale prior run's file into memory, so every test
	# below starts from a known-empty tally.
	steam_stats.set(&"_data", STEAM_STATS_SAVE.load_data(TEST_SAVE_PATH))

	_check_lifetime_counters()
	_check_cycle_achievements()
	_check_salvage_achievements()
	_check_ship_repaired_sibling_fix()
	_check_presence_text()
	_check_persistence()

	_cleanup()
	# EVENT_BUS.emit_boss_defeated() above reaches BossMusicDirector (task 5.5) exactly like the
	# shipped game would — the same "a --script harness's synthetic event fires every real
	# subscriber, not just this check's own" trap tools/salvage_check.gd's own header already
	# documents. BossMusicDirector starts loading/playing boss_stinger.ogg; this script quits shortly
	# after without waiting for that audio to finish, which the engine reports as a resource still in
	# use at exit. Pre-existing in BossMusicDirector, orthogonal to task 8.3 — not something this
	# check's own code leaves dangling, so declared by pattern (SPECS.md standing rule 4) rather than
	# either silenced or (worse) worked around by skipping the boss_defeated integration test.
	print("\nSTEAM_STATS_CHECK failures=%d · EXPECTED_ERROR_PATTERNS=\"resources still in use\"" % failures)
	finish()


func _check_wiring() -> bool:
	print("== autoloads ==")
	steam_stats = root.get_node_or_null(^"SteamStats")
	rich_presence = root.get_node_or_null(^"RichPresenceService")
	steam_lobby = root.get_node_or_null(^"SteamLobby")
	check(steam_stats != null, "SteamStats is registered as an autoload")
	check(rich_presence != null, "RichPresenceService is registered as an autoload")
	check(steam_lobby != null, "SteamLobby is registered as an autoload")
	if steam_lobby != null:
		check(steam_lobby.has_method(&"set_status"),
			"SteamLobby exposes set_status() — RichPresenceService's one call site")
	if rich_presence != null:
		check(rich_presence.has_method(&"compute_status_text"), "RichPresenceService is pure-testable")
	return steam_stats != null and rich_presence != null and steam_lobby != null


func _check_lifetime_counters() -> void:
	print("\n== lifetime counters (increment-forever stats + their first-time achievement) ==")

	check(int(steam_stats.call(&"stat_value", STEAM_STATS_SCRIPT.STAT_RUNS_EXTRACTED)) == 0, "sanity: no extractions banked yet")
	check(not bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_FIRST_EXTRACTION)), "sanity: not yet unlocked")
	EVENT_BUS.emit_run_extracted(1, Vector3.ZERO)
	check(int(steam_stats.call(&"stat_value", STEAM_STATS_SCRIPT.STAT_RUNS_EXTRACTED)) == 1, "one run_extracted -> RUNS_EXTRACTED == 1")
	check(bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_FIRST_EXTRACTION)), "run_extracted unlocks ACH_FIRST_EXTRACTION")
	EVENT_BUS.emit_run_extracted(2, Vector3.ZERO)
	check(int(steam_stats.call(&"stat_value", STEAM_STATS_SCRIPT.STAT_RUNS_EXTRACTED)) == 2, "a second run_extracted -> RUNS_EXTRACTED == 2 (keeps counting)")

	EVENT_BUS.emit_run_wiped(1, Vector3.ZERO)
	check(int(steam_stats.call(&"stat_value", STEAM_STATS_SCRIPT.STAT_RUNS_WIPED)) == 1, "one run_wiped -> RUNS_WIPED == 1")

	EVENT_BUS.emit_wellspring_capped(&"CheckWellspring", Vector3.ZERO)
	check(int(steam_stats.call(&"stat_value", STEAM_STATS_SCRIPT.STAT_WELLSPRINGS_CAPPED)) == 1, "one wellspring_capped -> WELLSPRINGS_CAPPED == 1")
	check(bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_FIRST_WELLSPRING)), "wellspring_capped unlocks ACH_FIRST_WELLSPRING")

	EVENT_BUS.emit_boss_defeated(&"CheckBoss", Vector3.ZERO)
	check(int(steam_stats.call(&"stat_value", STEAM_STATS_SCRIPT.STAT_BOSSES_DEFEATED)) == 1, "one boss_defeated -> BOSSES_DEFEATED == 1")
	check(bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_FIRST_BOSS)), "boss_defeated unlocks ACH_FIRST_BOSS")

	EVENT_BUS.emit_unlock_purchased(&"CheckUnlock", 10, 90)
	check(bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_FIRST_UNLOCK)), "unlock_purchased unlocks ACH_FIRST_UNLOCK")


func _check_cycle_achievements() -> void:
	print("\n== Cycle-threshold achievements (exact milestone, not before) ==")
	EVENT_BUS.emit_run_extracted(4, Vector3.ZERO)
	check(int(steam_stats.call(&"stat_value", STEAM_STATS_SCRIPT.STAT_CYCLES_REACHED)) == 4, "Cycle 4 reached -> CYCLES_REACHED == 4")
	check(not bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_CYCLE_5)), "Cycle 4 does NOT unlock the Cycle 5 achievement")

	EVENT_BUS.emit_run_extracted(5, Vector3.ZERO)
	check(bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_CYCLE_5)), "Cycle 5 unlocks ACH_CYCLE_5")
	check(not bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_CYCLE_10)), "Cycle 5 does NOT unlock the Cycle 10 achievement")

	EVENT_BUS.emit_run_extracted(3, Vector3.ZERO)
	check(int(steam_stats.call(&"stat_value", STEAM_STATS_SCRIPT.STAT_CYCLES_REACHED)) == 5,
		"a LOWER Cycle afterwards does not lower CYCLES_REACHED (running max, not last-seen)")

	EVENT_BUS.emit_run_extracted(15, Vector3.ZERO)
	check(bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_CYCLE_10)), "jumping straight to Cycle 15 still unlocks Cycle 10 on the way")
	check(bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_CYCLE_15)), "...and Cycle 15 itself")


func _check_salvage_achievements() -> void:
	print("\n== lifetime-Salvage-threshold achievements ==")
	EVENT_BUS.emit_salvage_banked(50, 200, 3, true)
	check(int(steam_stats.call(&"stat_value", STEAM_STATS_SCRIPT.STAT_LIFETIME_SALVAGE)) == 200, "salvage_banked -> LIFETIME_SALVAGE == total_salvage")
	check(not bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_SALVAGE_500)), "200 lifetime Salvage does NOT unlock the 500 achievement")

	EVENT_BUS.emit_salvage_banked(400, 600, 4, true)
	check(bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_SALVAGE_500)), "600 lifetime Salvage unlocks ACH_SALVAGE_500")
	check(not bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_SALVAGE_2000)), "600 does NOT unlock the 2000 achievement")

	EVENT_BUS.emit_salvage_banked(1500, 2100, 6, true)
	check(bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_SALVAGE_2000)), "2100 lifetime Salvage unlocks ACH_SALVAGE_2000")


## F-249: the sibling of F-168's host-only-emit-call trap, in ExtractionShip.repair_stage. Proven
## two ways — the setter fires with no host-only call path involved at all, and the real event reaches
## SteamStats's own counter/achievement the same way any other peer's local EventBus would.
func _check_ship_repaired_sibling_fix() -> void:
	print("\n== F-249: ExtractionShip.repair_stage fires ship_repaired from its own setter ==")
	var ship: Node3D = EXTRACTION_SHIP.new()
	# In the tree, not just .new() — the setter reads global_position, which logs an engine error on
	# a Node3D that was never added anywhere (harmless, but avoidable, so avoid it).
	root.add_child(ship)
	var fired: Array = []
	var handler := func(ship_name: StringName, _pos: Vector3) -> void: fired.append(ship_name)
	EVENT_BUS.subscribe_ship_repaired(handler)

	ship.set(&"repair_stage", 2)
	check(fired.is_empty(), "repair_stage 0 -> 2 (below REPAIR_STAGE_COUNT) does not fire ship_repaired")

	var ships_repaired_before: int = int(steam_stats.call(&"stat_value", STEAM_STATS_SCRIPT.STAT_SHIPS_REPAIRED))
	ship.set(&"repair_stage", 3)
	check(fired.size() == 1, "repair_stage crossing into REPAIR_STAGE_COUNT fires ship_repaired exactly once")
	check(int(steam_stats.call(&"stat_value", STEAM_STATS_SCRIPT.STAT_SHIPS_REPAIRED)) == ships_repaired_before + 1,
		"...and SteamStats's own SHIPS_REPAIRED counter sees it, with no host-only gate in the way")
	check(bool(steam_stats.call(&"is_unlocked", STEAM_STATS_SCRIPT.ACH_SHIPWRIGHT)), "...and ACH_SHIPWRIGHT unlocks")

	ship.set(&"repair_stage", 3)
	check(fired.size() == 1, "re-setting the SAME value fires nothing a second time")

	EVENT_BUS.unsubscribe_ship_repaired(handler)
	root.remove_child(ship)
	ship.free()


func _check_presence_text() -> void:
	print("\n== RichPresenceService.compute_status_text() (pure, no Steam needed) ==")
	var text: String = String(rich_presence.call(&"compute_status_text"))
	check(text.begins_with("Cycle "), "presence text names the Cycle: got '%s'" % text)
	check(not text.contains("players"),
		"a --script harness has no connected peers, so no party-size suffix: got '%s'" % text)


func _check_persistence() -> void:
	print("\n== round trip through user:// ==")
	var on_disk: Dictionary = STEAM_STATS_SAVE.load_data(TEST_SAVE_PATH)
	check(int((on_disk.get("stats", {}) as Dictionary).get(STEAM_STATS_SCRIPT.STAT_RUNS_EXTRACTED, -1)) ==
		int(steam_stats.call(&"stat_value", STEAM_STATS_SCRIPT.STAT_RUNS_EXTRACTED)),
		"the file on disk agrees with SteamStats's own in-memory value")
	check(bool((on_disk.get("achievements", {}) as Dictionary).get(STEAM_STATS_SCRIPT.ACH_FIRST_EXTRACTION, false)),
		"an unlocked achievement is really on disk, not just in memory")


func _cleanup() -> void:
	if FileAccess.file_exists(TEST_SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_PATH))


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
