class_name AtomicJson
extends RefCounted

## The one durable-write seam every `user://` player save goes through (F-326).
##
## A plain `FileAccess.open(path, FileAccess.WRITE)` truncates the destination the moment it opens
## it, so the only valid copy of a save is destroyed BEFORE the replacement exists. Any interruption
## in the window that follows — a crash, a kill, a full disk, a pulled power cable — leaves an empty
## or half-written JSON document behind. Every loader in `core/save/` is resilient and falls back to
## defaults on a parse failure, which means the failure mode is silent: the player does not see an
## error, they see their progression reset to zero.
##
## `tools/json_result_race_check.gd` already measured this exact mechanism for the check harness's
## own result files — 64 torn reads on the plain write, ZERO on write-to-`.part`-then-rename — and
## every two-process check in `tools/` adopted the atomic form. The player-facing saves never did.
## This class is that same form, shared, so the five writers cannot drift apart again.
##
## The sequence is: serialize into a sibling `.part` file, verify the bytes actually landed, close,
## then `DirAccess.rename_absolute()` over the destination. POSIX `rename(2)` swaps a directory
## entry, so a reader — and a crash — sees either the whole previous document or the whole next one.
## If ANY step before the rename fails, the destination is never touched and the previous save is
## still the file on disk. That is the property this class exists to guarantee.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): NONE. This is local filesystem I/O on one player's
## own machine, below the level any authority question reaches — it has no peers, no RPCs and no
## replicated state, exactly like the `SalvageSave`/`SettingsSave` callers that own it.

## Suffix for the sibling scratch file. Same directory as the destination on purpose: `rename(2)` is
## only atomic WITHIN a filesystem, so a temp in `/tmp` or an OS temp dir would silently degrade to a
## copy-then-delete on any machine where `user://` lives on a different volume.
const PART_SUFFIX: String = ".part"


## Serializes `data` to `path` durably and returns whether the destination now holds it.
##
## `label` is the caller's class name, so a failure reads like the `push_error()` it replaced
## ("SalvageSave: ..."). On `false` the destination is UNCHANGED — that is the contract, and the
## reason a caller may treat a failed save as "the old save survived" rather than as data loss.
static func write(path: String, data: Dictionary, label: String) -> bool:
	var part_path: String = path + PART_SUFFIX
	var file: FileAccess = FileAccess.open(part_path, FileAccess.WRITE)
	if file == null:
		push_error("%s: could not open %s for write (%s)"
			% [label, part_path, error_string(FileAccess.get_open_error())])
		return false

	var document: String = JSON.stringify(data)
	file.store_string(document)
	file.flush()
	# Checked BEFORE the rename, because this is the disk-full case: `store_string()` reports a short
	# write here, and bailing now leaves the previous save as the file on disk.
	var store_error: Error = file.get_error()
	if store_error != OK:
		push_error("%s: could not write %s (%s) — %s left unchanged"
			% [label, part_path, error_string(store_error), path])
		file.close()
		_discard(part_path)
		return false
	file.close()

	# The scratch file is re-opened and measured rather than trusted. A save is a few hundred bytes,
	# so this costs nothing, and it is the last moment at which a short write can still be caught
	# while the good copy is intact.
	var expected: int = document.to_utf8_buffer().size()
	var written: int = _byte_length(part_path)
	if written != expected:
		push_error("%s: %s is %d byte(s), expected %d — %s left unchanged"
			% [label, part_path, written, expected, path])
		_discard(part_path)
		return false

	var rename_error: Error = DirAccess.rename_absolute(
		ProjectSettings.globalize_path(part_path), ProjectSettings.globalize_path(path))
	if rename_error != OK:
		push_error("%s: could not replace %s (%s) — previous save left unchanged"
			% [label, path, error_string(rename_error)])
		_discard(part_path)
		return false
	return true


## Byte length of `path`, or -1 if it cannot be opened. Deliberately not `FileAccess.file_exists()` +
## `get_length()`: a file that exists but cannot be re-opened has not been written durably either.
static func _byte_length(path: String) -> int:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	var length: int = file.get_length()
	file.close()
	return length


## Removes a scratch file that will never be promoted. A leftover `.part` is harmless — the next
## write overwrites it — but leaving one behind makes a `user://` directory look mid-write forever.
static func _discard(part_path: String) -> void:
	if FileAccess.file_exists(part_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(part_path))
