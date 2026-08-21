class_name SalvageSave
extends RefCounted

## Meta-progression persistence for Salvage (task 6.6, DESIGN.md §4.6) — the one piece of state that
## survives a run, per `DESIGN.md`'s explicit cut list: "Saving and resuming a run across sessions"
## stays cut (D-010), but the run's OUTCOME (how much Salvage it banked) is not the run itself, and
## always was meant to persist ("every run banks Salvage").
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Salvage" row): NONE. This is per-player account
## state on that player's own machine, the same way a Steam achievement or a local settings file is —
## there is no "two clients disagree" case to arbitrate, because no other peer ever reads it.
##
## Pure data I/O, no autoload: `SalvageService` is the runtime seam that decides WHEN to bank;
## this class only knows how to get a Dictionary on and off disk. `docs/SPECS.md`'s own 6.6
## look-ahead names the path and the field: `user://salvage.json`, `schema_version: 1`, "a migration
## switch from day one — versioning is this task's real deliverable."

const SAVE_PATH: String = "user://salvage.json"
const SCHEMA_VERSION: int = 1


## Reads `path` (defaults to `SAVE_PATH`) and returns an always-valid, always-current-schema
## Dictionary — a missing file, a corrupt file and an old-schema file all resolve to something the
## caller can use without checking first. `path` is only ever overridden by `tools/salvage_check.gd`,
## so a check run never touches a real player's save.
static func load_data(path: String = SAVE_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _default_data()
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("SalvageSave: could not open %s for read (%s)" % [path, error_string(FileAccess.get_open_error())])
		return _default_data()
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("SalvageSave: %s did not contain a JSON object, starting fresh" % path)
		return _default_data()
	return _migrate(parsed as Dictionary)


## Writes `data` to `path` (defaults to `SAVE_PATH`), stamping the current schema version. Whole-file
## overwrite, not an append or a diff — the save is small (a handful of scalars), so there is nothing
## an incremental write would save that is worth the corruption risk of a partial one.
##
## Durable, via `AtomicJson` (F-326): the document lands in a sibling `.part` file and is renamed over
## the destination, so an interrupted write leaves the PREVIOUS save intact rather than an empty file
## that `load_data()` would silently resolve to a zero balance. `false` means the save did not happen
## AND the old one survived.
static func save_data(data: Dictionary, path: String = SAVE_PATH) -> bool:
	data["schema_version"] = SCHEMA_VERSION
	return AtomicJson.write(path, data, "SalvageSave")


static func _default_data() -> Dictionary:
	return {
		&"schema_version": SCHEMA_VERSION,
		&"total_salvage": 0,
	}


## The migration switch `docs/SPECS.md`'s 6.6 look-ahead calls "this task's real deliverable" —
## every future schema bump adds one more `if version < N:` block here, upgrading in place, rather
## than a reader that has to understand every historical shape at once. Today there is only one
## shipped schema, so this pass does nothing but backfill missing keys (an interrupted first write,
## or a hand-edited file) — the seam exists and is exercised even though it has nothing to migrate
## FROM yet.
static func _migrate(data: Dictionary) -> Dictionary:
	var version: int = int(data.get("schema_version", 0))
	if version < 1:
		data["total_salvage"] = int(data.get("total_salvage", 0))
		version = 1
	data["schema_version"] = version
	return data
