extends RefCounted

## RunRecordSave — MENU-7: what the last run was, on disk (docs/MENU.md §4, §6.2).
##
## Use by preload, never as a bare identifier (SPECS.md standing rule 1):
##     const RunRecordSave := preload("res://core/save/run_record_save.gd")
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): NONE. Per-player account state on that player's own
## machine, exactly like `SalvageSave` — no other peer ever reads it, so there is no disagreement to
## arbitrate. This does not persist a RUN (D-010's cut stands); it persists a run's *outcome*, which
## is a handful of scalars and is the whole point of "how far did you get".
##
## ## Why its own file rather than a key inside `salvage.json`
##
## `SalvageService` owns `user://salvage.json` and rewrites it whole on every bank and every spend
## (`save_data()` is a whole-file overwrite, deliberately). A second writer adding a `last_run` key
## to that same file would have its key silently dropped by the next spend that loaded, mutated and
## rewrote the dictionary without it. Separate file, separate owner, no coordination needed.
##
## Pure data I/O and no autoload, matching `SalvageSave`: `autoload/run_record.gd` decides WHEN to
## write; this only knows how to get a Dictionary on and off disk.

const SAVE_PATH: String = "user://last_run.json"
const SCHEMA_VERSION: int = 1


## Reads `path` and returns an always-valid, current-schema Dictionary — a missing file, a corrupt
## file and an old-schema file all resolve to something the caller can use without checking first.
static func load_data(path: String = SAVE_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _default_data()
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("RunRecordSave: could not open %s for read (%s)"
			% [path, error_string(FileAccess.get_open_error())])
		return _default_data()
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("RunRecordSave: %s did not contain a JSON object, starting fresh" % path)
		return _default_data()
	return _migrate(parsed as Dictionary)


static func save_data(data: Dictionary, path: String = SAVE_PATH) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("RunRecordSave: could not open %s for write (%s)"
			% [path, error_string(FileAccess.get_open_error())])
		return
	data["schema_version"] = SCHEMA_VERSION
	file.store_string(JSON.stringify(data))
	file.close()


## `has_run` is what the title screen's last-expedition card keys off. It is a separate flag rather
## than "cycle > 0" because a run that ended on Cycle 1 is still a run worth reporting, and a fresh
## install must show no card at all rather than a Cycle 0 one that reads as "you already failed".
static func _default_data() -> Dictionary:
	return {
		&"schema_version": SCHEMA_VERSION,
		&"has_run": false,
		&"cycle": 0,
		&"ending": "",
		&"cause_line": "",
		&"salvage_banked": 0,
		&"modifiers": [],
		&"seed": 0,
	}


static func _migrate(data: Dictionary) -> Dictionary:
	var version: int = int(data.get("schema_version", 0))
	if version < 1:
		var defaults: Dictionary = _default_data()
		for key: Variant in defaults:
			if not data.has(key):
				data[key] = defaults[key]
		version = 1
	data["schema_version"] = version
	return data
