extends Node

## SteamStats — autoload. Task 8.3: Steam achievements + stats, and the local per-player tally that
## backs them. Register as autoload `SteamStats` → res://autoload/steam_stats.gd, after `SteamLobby`,
## `CycleService`, `SalvageService` and `UnlockService` in `project.godot` (F-051 — this file only
## ever reads those by node path, so load order matters only in the "already registered" sense).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Achievements, stats, rich presence" row): NONE.
## Same category as Salvage/Unlocks (tasks 6.6/6.9) — per-player account state on that player's own
## machine. Every peer runs this exact autoload and reacts only to events ITS OWN local `EventBus`
## (a per-process static) received, writing only to ITS OWN `user://steam_stats.json` and pushing
## only to ITS OWN Steam session. No two peers ever compare a stat or an achievement.
##
## WHY A REAL STEAM APP ID IS NOT NEEDED TO SHIP THIS CODE (F-248's prediction for this task,
## landing): `setStatInt()`/`setAchievement()` fail harmlessly against an id no Steamworks dashboard
## has registered yet — App ID 480 has none of ours defined, and won't until task 8.2 lands a real
## App ID and someone works through `tools/steam/ACHIEVEMENTS.md` in the dashboard. Unlike 8.4/8.11's
## depot IDs, there is no placeholder to swap here later: the `STAT_*`/`ACH_*` string consts below
## ARE the real, final API names, chosen by us rather than assigned by Steam, so this file needs no
## follow-up code change once the dashboard rows exist — see `docs/DECISIONS.md`.
##
## Ten achievements, not the ~20 `docs/STEAM.md` names as an aim — D-146 already set the "ship fewer
## real ones, not a bulk template fill" precedent for content in this exact shape (six Cycle
## Modifiers, not twenty). Each of the ten below is hand-picked against a milestone that already
## fires in the shipped game today, not a guess at one that might.
##
## Everything degrades to a clear local-only no-op when GodotSteam is absent or Steam is not
## running — same contract `SteamLobby`'s own header promises, and for the same reason: this is the
## normal state during LOCAL development. The local `user://steam_stats.json` counters still work
## and still gate the console `steamstats` command below, so a stat/achievement's TRIGGER logic is
## fully testable with no Steam client at all.
##
## DELIBERATELY NEVER CALLS `SteamLobby.initialise()` ITSELF — only pushes to Steam once it is
## ALREADY up (`SteamLobby.is_ready()`). Local tracking (the counters above, and every check in
## `tools/steam_stats_check.gd`) needs no Steam at all and is unaffected either way; only the real
## `setStatInt()`/`setAchievement()` push waits. An eager `initialise()` call here was tried and
## reverted the same session: on any machine with a real Steam client running, it turned EVERY
## headless `agent godot` run project-wide into a real `SteamAPI_Init()` call — confirmed by running
## `tools/salvage_check.gd` before and after and diffing the log for Steam startup lines and the
## ObjectDB-leak warnings that came with them. See `RichPresenceService`'s header and
## `docs/DECISIONS.md` for the same call made in the same place for the same reason.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const STEAM_STATS_SAVE := preload("res://core/save/steam_stats_save.gd")
const NET_CONFIG := preload("res://core/net/net_config.gd")

const STEAM_SINGLETON: StringName = &"Steam"

## Stat API names — exact strings a future Steamworks dashboard stat definition (task 8.2's
## follow-up, `tools/steam/ACHIEVEMENTS.md`) must match verbatim, case included. All lifetime,
## int-valued: the four `_STAT_COUNTERS` below are cumulative counts that only ever go up; the two
## "reached"/"lifetime" ones store the running maximum instead of incrementing.
const STAT_CYCLES_REACHED: String = "CYCLES_REACHED"
const STAT_LIFETIME_SALVAGE: String = "LIFETIME_SALVAGE"
const STAT_RUNS_EXTRACTED: String = "RUNS_EXTRACTED"
const STAT_RUNS_WIPED: String = "RUNS_WIPED"
const STAT_WELLSPRINGS_CAPPED: String = "WELLSPRINGS_CAPPED"
const STAT_BOSSES_DEFEATED: String = "BOSSES_DEFEATED"
const STAT_SHIPS_REPAIRED: String = "SHIPS_REPAIRED"

## Achievement API names — same "exact string the dashboard entry must match" contract as the stats
## above.
const ACH_FIRST_EXTRACTION: String = "ACH_FIRST_EXTRACTION"
const ACH_FIRST_WELLSPRING: String = "ACH_FIRST_WELLSPRING"
const ACH_FIRST_BOSS: String = "ACH_FIRST_BOSS"
const ACH_SHIPWRIGHT: String = "ACH_SHIPWRIGHT"
const ACH_CYCLE_5: String = "ACH_CYCLE_5"
const ACH_CYCLE_10: String = "ACH_CYCLE_10"
const ACH_CYCLE_15: String = "ACH_CYCLE_15"
const ACH_SALVAGE_500: String = "ACH_SALVAGE_500"
const ACH_SALVAGE_2000: String = "ACH_SALVAGE_2000"
const ACH_FIRST_UNLOCK: String = "ACH_FIRST_UNLOCK"

## Every achievement id that exists — the total `_cmd_steamstats` counts against, and the one place
## that has to be kept in sync by hand when an achievement is added or removed.
const ALL_ACHIEVEMENTS: PackedStringArray = [
	ACH_FIRST_EXTRACTION, ACH_FIRST_WELLSPRING, ACH_FIRST_BOSS, ACH_SHIPWRIGHT,
	ACH_CYCLE_5, ACH_CYCLE_10, ACH_CYCLE_15, ACH_SALVAGE_500, ACH_SALVAGE_2000, ACH_FIRST_UNLOCK,
]

## Cycle threshold -> the achievement it unlocks, checked every time `STAT_CYCLES_REACHED` might have
## moved. DESIGN.md's own escalation curve, and the literal milestones `docs/STEAM.md` §S4 suggests
## ("Cycle-depth achievements are natural here — Reach Cycle 5/10/15").
const CYCLE_ACHIEVEMENTS: Dictionary = {
	5: ACH_CYCLE_5,
	10: ACH_CYCLE_10,
	15: ACH_CYCLE_15,
}

## Lifetime-Salvage threshold -> the achievement it unlocks, checked every `salvage_banked` event.
const SALVAGE_ACHIEVEMENTS: Dictionary = {
	500: ACH_SALVAGE_500,
	2000: ACH_SALVAGE_2000,
}

## How often `_process()` re-reads `CycleService.current_cycle()`. Not driven by
## `EventBus.subscribe_cycle_advanced()` — see the header note on the poll vs. the (broken) signal.
const POLL_INTERVAL_SEC: float = 2.0

var _steam: Object = null
var _stats_ready: bool = false
var _data: Dictionary = {}
var _last_polled_cycle: int = 0
var _poll_accum: float = 0.0
## Override for `tools/steam_stats_check.gd` only — production code never sets this, so a check run
## never touches a real player's `user://steam_stats.json` and never pushes to a real Steam session.
var save_path: String = STEAM_STATS_SAVE.SAVE_PATH


func _ready() -> void:
	_data = STEAM_STATS_SAVE.load_data(save_path)
	_bind_steam()
	EVENT_BUS.subscribe_run_extracted(_on_run_extracted)
	EVENT_BUS.subscribe_run_wiped(_on_run_wiped)
	EVENT_BUS.subscribe_wellspring_capped(_on_wellspring_capped)
	EVENT_BUS.subscribe_boss_defeated(_on_boss_defeated)
	EVENT_BUS.subscribe_ship_repaired(_on_ship_repaired)
	EVENT_BUS.subscribe_salvage_banked(_on_salvage_banked)
	EVENT_BUS.subscribe_unlock_purchased(_on_unlock_purchased)
	_last_polled_cycle = _current_cycle()
	_check_cycle_stat(_last_polled_cycle)
	_register_commands()


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_extracted(_on_run_extracted)
	EVENT_BUS.unsubscribe_run_wiped(_on_run_wiped)
	EVENT_BUS.unsubscribe_wellspring_capped(_on_wellspring_capped)
	EVENT_BUS.unsubscribe_boss_defeated(_on_boss_defeated)
	EVENT_BUS.unsubscribe_ship_repaired(_on_ship_repaired)
	EVENT_BUS.unsubscribe_salvage_banked(_on_salvage_banked)
	EVENT_BUS.unsubscribe_unlock_purchased(_on_unlock_purchased)


func _process(delta: float) -> void:
	_poll_accum += delta
	if _poll_accum < POLL_INTERVAL_SEC:
		return
	_poll_accum = 0.0
	var cycle: int = _current_cycle()
	if cycle == _last_polled_cycle:
		return
	_last_polled_cycle = cycle
	_check_cycle_stat(cycle)


# ── Public reads ──────────────────────────────────────────────────────────────────────────────────


## This peer's own current value for `stat_id` (one of the `STAT_*` consts above), or 0 if it has
## never moved. Exposed for `tools/steam_stats_check.gd` and a future stats-screen UI.
func stat_value(stat_id: String) -> int:
	return int((_data.get("stats", {}) as Dictionary).get(stat_id, 0))


## Whether this peer has unlocked `achievement_id` (one of the `ACH_*` consts above).
func is_unlocked(achievement_id: String) -> bool:
	return bool((_data.get("achievements", {}) as Dictionary).get(achievement_id, false))


## True once this process has a live Steam session AND Steam has answered back with this user's
## current stats (`user_stats_received`) — the point at which a `setStatInt()`/`setAchievement()`
## call is meaningful rather than silently discarded. Local tracking above works identically either
## way; this only gates the real Steam push.
func steam_sync_ready() -> bool:
	return _stats_ready


# ── EventBus wiring ───────────────────────────────────────────────────────────────────────────────


func _on_run_extracted(cycle: int, _world_position: Vector3) -> void:
	_increment_stat(STAT_RUNS_EXTRACTED)
	_unlock(ACH_FIRST_EXTRACTION)
	_check_cycle_stat(cycle)


func _on_run_wiped(cycle: int, _world_position: Vector3) -> void:
	_increment_stat(STAT_RUNS_WIPED)
	_check_cycle_stat(cycle)


func _on_wellspring_capped(_wellspring_name: StringName, _world_position: Vector3) -> void:
	_increment_stat(STAT_WELLSPRINGS_CAPPED)
	_unlock(ACH_FIRST_WELLSPRING)


func _on_boss_defeated(_boss_id: StringName, _world_position: Vector3) -> void:
	_increment_stat(STAT_BOSSES_DEFEATED)
	_unlock(ACH_FIRST_BOSS)


func _on_ship_repaired(_ship_name: StringName, _world_position: Vector3) -> void:
	_increment_stat(STAT_SHIPS_REPAIRED)
	_unlock(ACH_SHIPWRIGHT)


func _on_salvage_banked(_earned: int, total_salvage: int, _cycle: int, _extracted: bool) -> void:
	_set_stat_max(STAT_LIFETIME_SALVAGE, total_salvage)
	for threshold: int in SALVAGE_ACHIEVEMENTS.keys():
		if total_salvage >= threshold:
			_unlock(String(SALVAGE_ACHIEVEMENTS[threshold]))


func _on_unlock_purchased(_unlock_id: StringName, _cost: int, _total_salvage: int) -> void:
	_unlock(ACH_FIRST_UNLOCK)


func _check_cycle_stat(cycle: int) -> void:
	_set_stat_max(STAT_CYCLES_REACHED, cycle)
	for threshold: int in CYCLE_ACHIEVEMENTS.keys():
		if cycle >= threshold:
			_unlock(String(CYCLE_ACHIEVEMENTS[threshold]))


func _current_cycle() -> int:
	var cycle_service: Node = get_node_or_null(^"/root/CycleService")
	if cycle_service == null or not cycle_service.has_method(&"current_cycle"):
		return 1
	return int(cycle_service.call("current_cycle"))


# ── Local persistence + Steam push ───────────────────────────────────────────────────────────────


func _set_stat_max(stat_id: String, value: int) -> void:
	if not _persistence_enabled():
		return
	var stats: Dictionary = _data.get("stats", {})
	if value <= int(stats.get(stat_id, 0)):
		return
	stats[stat_id] = value
	_data["stats"] = stats
	STEAM_STATS_SAVE.save_data(_data, save_path)
	_push_stat(stat_id, value)


func _increment_stat(stat_id: String, delta: int = 1) -> void:
	if not _persistence_enabled():
		return
	var stats: Dictionary = _data.get("stats", {})
	var value: int = int(stats.get(stat_id, 0)) + delta
	stats[stat_id] = value
	_data["stats"] = stats
	STEAM_STATS_SAVE.save_data(_data, save_path)
	_push_stat(stat_id, value)


func _unlock(achievement_id: String) -> void:
	if not _persistence_enabled():
		return
	var achievements: Dictionary = _data.get("achievements", {})
	if bool(achievements.get(achievement_id, false)):
		return
	achievements[achievement_id] = true
	_data["achievements"] = achievements
	STEAM_STATS_SAVE.save_data(_data, save_path)
	_push_achievement(achievement_id)


## Guards every disk write and Steam push against being triggered by an unrelated check's own test
## traffic — the exact trap `SalvageService._persistence_enabled()`'s own comment documents (a
## `--script` harness leaves `current_scene` null for its whole run; the real game never does).
func _persistence_enabled() -> bool:
	return save_path != STEAM_STATS_SAVE.SAVE_PATH or get_tree().current_scene != null


func _bind_steam() -> bool:
	if _steam != null:
		return true
	if not Engine.has_singleton(STEAM_SINGLETON):
		return false
	_steam = Engine.get_singleton(STEAM_SINGLETON)
	if _steam.has_signal(&"user_stats_received"):
		_steam.user_stats_received.connect(_on_user_stats_received)
	# Deliberately does NOT call SteamLobby.initialise() — see docs/DECISIONS.md and
	# RichPresenceService's own header for why: doing so from an eagerly-loaded autoload turns EVERY
	# headless `agent godot` run project-wide into a real SteamAPI_Init() call on any machine with a
	# Steam client running, confirmed the hard way while building this. This only reacts to Steam
	# state something else (a real hosted/joined session, an accepted invite) already brought up.
	var lobby: Node = get_node_or_null(^"/root/SteamLobby")
	if lobby != null and bool(lobby.call("is_ready")):
		# GodotSteam 4.14+ requests current stats automatically as part of init (no separate
		# requestCurrentStats() call exists in this build — confirmed against the linked binary, see
		# the addon's own changelog entry for 4.14). If Steam was already initialised by an earlier
		# action this session, `user_stats_received` may already have fired and been missed by the
		# connect() above — optimistically treat "already ready" as "already synced" rather than
		# silently never pushing anything for the rest of the session.
		_stats_ready = true
	return true


func _on_user_stats_received(_game_id: int, result: int, steam_id: int) -> void:
	if _steam == null or steam_id != int(_steam.getSteamID()):
		return
	if result != NET_CONFIG.STEAM_RESULT_OK:
		return
	_stats_ready = true
	_push_all()


func _push_all() -> void:
	var stats: Dictionary = _data.get("stats", {})
	for stat_id: String in stats.keys():
		_push_stat(stat_id, int(stats[stat_id]))
	var achievements: Dictionary = _data.get("achievements", {})
	for achievement_id: String in achievements.keys():
		if bool(achievements[achievement_id]):
			_push_achievement(achievement_id)


func _push_stat(stat_id: String, value: int) -> void:
	if not _bind_steam() or not _stats_ready:
		return
	_steam.setStatInt(stat_id, value)
	_steam.storeStats()


func _push_achievement(achievement_id: String) -> void:
	if not _bind_steam() or not _stats_ready:
		return
	_steam.setAchievement(achievement_id)
	_steam.storeStats()


# ── Commands (docs/COMMANDS.md §7 — task 3.16's convention) ─────────────────────────────────────


## LOCAL scope: reads THIS process's own stats/achievements, the same "acts on this machine's own
## Steam session" reasoning `SteamLobby._register_commands()` already documents for `lobby`.
func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"steamstats", {
		"scope": &"local",
		"args": [],
		"handler": _cmd_steamstats,
		"help": "steamstats — this peer's local Steam stat/achievement tally and sync status",
	})


func _cmd_steamstats(_ctx: Dictionary, _args: Dictionary) -> Dictionary:
	var stats: Dictionary = _data.get("stats", {})
	var achievements: Dictionary = _data.get("achievements", {})
	var unlocked_count: int = 0
	for value: Variant in achievements.values():
		if bool(value):
			unlocked_count += 1
	return {"ok": true, "message": "%d/%d achievements — Steam sync %s" % [
		unlocked_count, ALL_ACHIEVEMENTS.size(),
		"ready" if _stats_ready else "not ready (offline, or no Steam session yet)"
	], "data": {"stats": stats, "achievements": achievements, "steam_sync_ready": _stats_ready}}
