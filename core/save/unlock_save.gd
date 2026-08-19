class_name UnlockSave
extends RefCounted

## Meta-progression persistence for the unlock tree (task 6.9, DESIGN.md §4.6) — which UnlockDef
## ids this player has already spent Salvage on. Same "the run's outcome persists, the run itself
## does not" carve-out D-010 already gave Salvage (task 6.6): purchases are meta-progression, not
## saved-run state, and were always meant to survive between sessions.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Unlocks" row): NONE. Same reasoning as
## SalvageSave — per-player account state on that player's own machine, nothing another peer ever
## reads.
##
## Pure data I/O, no autoload: autoload/unlock_service.gd is the runtime seam that decides WHEN to
## spend; this class only knows how to get a Dictionary on and off disk. Same shape as
## `core/save/salvage_save.gd`, a deliberate sibling file rather than a second top-level key on
## Salvage's own save (docs/DELEGATION.md's 6.6 note names this as the reuse point).

const SAVE_PATH: String = "user://unlocks.json"
const SCHEMA_VERSION: int = 1


## Reads `path` (defaults to `SAVE_PATH`) and returns an always-valid, always-current-schema
## Dictionary — a missing file, a corrupt file and an old-schema file all resolve to something the
## caller can use without checking first. `path` is only ever overridden by `tools/unlock_check.gd`,
## so a check run never touches a real player's save.
static func load_data(path: String = SAVE_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _default_data()
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("UnlockSave: could not open %s for read (%s)" % [path, error_string(FileAccess.get_open_error())])
		return _default_data()
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("UnlockSave: %s did not contain a JSON object, starting fresh" % path)
		return _default_data()
	return _migrate(parsed as Dictionary)


## Writes `data` to `path` (defaults to `SAVE_PATH`), stamping the current schema version. Whole-file
## overwrite, not an append or a diff — the save is small (a list of ids), so there is nothing an
## incremental write would save that is worth the corruption risk of a partial one.
static func save_data(data: Dictionary, path: String = SAVE_PATH) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("UnlockSave: could not open %s for write (%s)" % [path, error_string(FileAccess.get_open_error())])
		return
	data["schema_version"] = SCHEMA_VERSION
	file.store_string(JSON.stringify(data))
	file.close()


static func _default_data() -> Dictionary:
	return {
		&"schema_version": SCHEMA_VERSION,
		&"purchased_ids": [],
	}


## The migration switch `salvage_save.gd`'s own comment calls "this task's real deliverable" for
## every future schema bump — one more `if version < N:` block here, upgrading in place, rather than
## a reader that has to understand every historical shape at once. Today there is only one shipped
## schema, so this pass does nothing but backfill missing keys (an interrupted first write, or a
## hand-edited file) — the seam exists and is exercised even though it has nothing to migrate
## FROM yet.
static func _migrate(data: Dictionary) -> Dictionary:
	var version: int = int(data.get("schema_version", 0))
	if version < 1:
		var ids: Array = data.get("purchased_ids", [])
		data["purchased_ids"] = ids
		version = 1
	data["schema_version"] = version
	return data
