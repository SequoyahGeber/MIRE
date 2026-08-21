class_name SteamStatsSave
extends RefCounted

## Local persistence for Steam stats/achievements (task 8.3) — same shape as `SalvageSave`
## (task 6.6) and `UnlockSave` (task 6.9), the two prior "per-player account state" save files.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Achievements, stats, rich presence" row): NONE.
## This is per-player account state on that player's own machine — the same category Salvage's own
## save-file comment already puts a Steam achievement in. No peer ever reads another peer's copy.
##
## Pure data I/O, no autoload: `SteamStats` (autoload) decides WHEN a stat changes or an achievement
## unlocks and pushes to the real Steam API; this class only knows how to get a Dictionary on and
## off disk, so `SteamStats` keeps working (and this file stays testable headlessly) whether or not
## GodotSteam/a Steam client is present. Two flat Dictionaries, not one row per id: `stats` maps a
## stat's API name (see `SteamStats`'s `STAT_*` consts) to its current int value, `achievements`
## maps an achievement's API name to `true` once unlocked — an id absent from either dict simply
## means "still at its default" (0, or locked), so a fresh save is `{}`/`{}` and needs no seeding.

const SAVE_PATH: String = "user://steam_stats.json"
const SCHEMA_VERSION: int = 1


## Reads `path` (defaults to `SAVE_PATH`) and returns an always-valid, always-current-schema
## Dictionary — a missing file, a corrupt file and an old-schema file all resolve to something the
## caller can use without checking first. `path` is only ever overridden by
## `tools/steam_stats_check.gd`, so a check run never touches a real player's save.
static func load_data(path: String = SAVE_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _default_data()
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("SteamStatsSave: could not open %s for read (%s)" % [path, error_string(FileAccess.get_open_error())])
		return _default_data()
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("SteamStatsSave: %s did not contain a JSON object, starting fresh" % path)
		return _default_data()
	return _migrate(parsed as Dictionary)


## Writes `data` to `path` (defaults to `SAVE_PATH`), stamping the current schema version. Whole-file
## overwrite, not an append or a diff — same reasoning as `SalvageSave.save_data()`: the save is a
## handful of small dictionaries, so there is nothing an incremental write would save that is worth
## the corruption risk of a partial one.
##
## Durable, via `AtomicJson` (F-326): the document lands in a sibling `.part` file and is renamed over
## the destination, so an interrupted write leaves the PREVIOUS stats intact rather than an empty file
## that `load_data()` would silently resolve to zeroed lifetime counters. `false` means the save did
## not happen AND the old one survived.
static func save_data(data: Dictionary, path: String = SAVE_PATH) -> bool:
	data["schema_version"] = SCHEMA_VERSION
	return AtomicJson.write(path, data, "SteamStatsSave")


static func _default_data() -> Dictionary:
	return {
		&"schema_version": SCHEMA_VERSION,
		&"stats": {},
		&"achievements": {},
	}


## The migration switch `SalvageSave`/`UnlockSave` both already carry — today only backfills missing
## keys (an interrupted first write, or a hand-edited file), same "the seam exists and is exercised
## even with nothing to migrate FROM yet" status those two started with.
static func _migrate(data: Dictionary) -> Dictionary:
	var version: int = int(data.get("schema_version", 0))
	if version < 1:
		if typeof(data.get("stats")) != TYPE_DICTIONARY:
			data["stats"] = {}
		if typeof(data.get("achievements")) != TYPE_DICTIONARY:
			data["achievements"] = {}
		version = 1
	data["schema_version"] = version
	return data
