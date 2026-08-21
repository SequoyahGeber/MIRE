extends SceneTree

## F-326's proof: an interrupted save must leave the PREVIOUS valid save on disk.
##
## All five `user://` player saves used to open their destination with `FileAccess.WRITE`, which
## truncates it before the replacement payload exists. Because every loader in `core/save/` is
## resilient — a corrupt file resolves to defaults rather than an error — the failure was silent:
## the player would not see a crash, they would see their Salvage, unlocks, stats or keybinds reset
## to zero. `tools/json_result_race_check.gd` measured the same mechanism for the check harness's own
## result files; this check owns the player-facing half of it.
##
## Four phases, in increasing strength:
##
##   A. Contract — every shipped writer round-trips through `AtomicJson`, reports success, and leaves
##      no `.part` scratch file behind.
##   B. Injected write failure — the real `AtomicJson.write()` is given a destination whose `.part`
##      sibling cannot be created. It must report failure AND leave the destination byte-identical.
##   C. Injected interruption — the truncate-then-refill sequence and the write-to-`.part` sequence
##      are each stopped at the same point, half a document in. The old form leaves an unparseable
##      file (the negative control: this is the hazard, and it is real); the new form leaves the
##      original save intact and still readable. Deterministic, not a timing race.
##   D. Source tripwire — none of the five writers may open its own destination with
##      `FileAccess.WRITE` again. This is what makes the check outlive its authors: a hand-rolled
##      writer that reintroduces the truncate turns this red even if it round-trips correctly on a
##      machine that never crashes.
##
##   .agent/bin/agent godot --script tools/save_atomicity_check.gd
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Local filesystem I/O on one machine — no transport is
## started, no game system is touched, no replicated state exists to arbitrate.

const SALVAGE_SAVE := preload("res://core/save/salvage_save.gd")
const UNLOCK_SAVE := preload("res://core/save/unlock_save.gd")
const RUN_RECORD_SAVE := preload("res://core/save/run_record_save.gd")
const STEAM_STATS_SAVE := preload("res://core/save/steam_stats_save.gd")
const SETTINGS_SAVE := preload("res://core/save/settings_save.gd")

## Every path is named so a real save can never collide with it, and every one is removed at the end.
const BASE: String = "user://save_atomicity_check_"
const ROUNDTRIP_PATH: String = BASE + "roundtrip.json"
const BLOCKED_PATH: String = BASE + "blocked.json"
const TORN_PATH: String = BASE + "torn.json"
const SURVIVOR_PATH: String = BASE + "survivor.json"
const ALL_PATHS: PackedStringArray = [ROUNDTRIP_PATH, BLOCKED_PATH, TORN_PATH, SURVIVOR_PATH]

## The five shipped writers, as (label, script, sample payload, probe key, probe value).
const WRITERS: Array = [
	["SalvageSave", SALVAGE_SAVE, {"total_salvage": 4321}, "total_salvage", 4321],
	["UnlockSave", UNLOCK_SAVE, {"purchased_ids": ["fungal_charm"]}, "", 0],
	["RunRecordSave", RUN_RECORD_SAVE, {"cycle_reached": 9}, "cycle_reached", 9],
	["SteamStatsSave", STEAM_STATS_SAVE, {"stats": {"runs": 3}}, "", 0],
	["SettingsSave", SETTINGS_SAVE, {"master_volume": 0.5}, "", 0],
]

## The value the survivor save carries. Any assertion that reads this back is asserting that the
## ORIGINAL document — not a replacement, not a default — is what an interrupted write left behind.
const SURVIVOR_TOTAL: int = 1234

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_cleanup()

	_check_writer_contract()
	_check_injected_write_failure()
	_check_injected_interruption()
	_check_no_writer_truncates()

	_cleanup()
	# Standing rule 4 (docs/SPECS.md): phases B and C provoke every one of these deliberately —
	# the blocked `.part` open, and the resilient loader resolving the negative control's torn file
	# to defaults. Declared, not silenced: an undeclared ERROR line in a green run is itself a defect,
	# and the last two are the same pair `salvage_check`/`unlock_check` declare for a corrupt fixture.
	print("\nSAVE_ATOMICITY_CHECK failures=%d"
		% failures
		+ " · EXPECTED_ERROR_PATTERNS=\"could not open|left unchanged"
		+ "|Parse JSON failed|did not contain a JSON object\"")
	finish()


## Phase A — the shipped writers still work, and they clean up after themselves.
func _check_writer_contract() -> void:
	print("\n== A · every shipped writer round-trips durably ==")
	for entry: Array in WRITERS:
		var label: String = entry[0]
		var script: GDScript = entry[1]
		var payload: Dictionary = (entry[2] as Dictionary).duplicate(true)
		var path: String = ROUNDTRIP_PATH
		_remove(path)
		_remove(path + ".part")

		var ok: bool = script.save_data(payload, path)
		check(ok, "%s.save_data() reports success" % label)
		check(FileAccess.file_exists(path), "%s wrote the destination" % label)
		check(not FileAccess.file_exists(path + ".part"),
			"%s left no .part scratch file behind" % label)

		var loaded: Dictionary = script.load_data(path)
		check(int(loaded.get("schema_version", -1)) == int(script.SCHEMA_VERSION),
			"%s stamps the current schema_version through the atomic path" % label)
		var probe_key: String = entry[3]
		if not probe_key.is_empty():
			check(int(loaded.get(probe_key, -1)) == int(entry[4]),
				"%s round-trips its payload (%s)" % [label, probe_key])
		_remove(path)


## Phase B — a write that cannot even begin must not cost the player the save they already had.
##
## The injection is a DIRECTORY sitting where the `.part` file needs to go, so `FileAccess.open()`
## fails at the first step. Under the old code the equivalent failure was impossible to survive: the
## destination itself was the thing being opened, so by the time anything could fail it was already
## truncated.
func _check_injected_write_failure() -> void:
	print("\n== B · a failed write leaves the previous save untouched ==")
	_remove(BLOCKED_PATH)
	check(SALVAGE_SAVE.save_data({"total_salvage": SURVIVOR_TOTAL}, BLOCKED_PATH),
		"the good save was written first")
	var before: PackedByteArray = FileAccess.get_file_as_bytes(BLOCKED_PATH)
	check(before.size() > 0, "the good save has content to lose")

	var part_dir: String = ProjectSettings.globalize_path(BLOCKED_PATH + ".part")
	DirAccess.make_dir_absolute(part_dir)
	check(DirAccess.dir_exists_absolute(part_dir), "the .part path is blocked by a directory")

	var ok: bool = SALVAGE_SAVE.save_data({"total_salvage": 999}, BLOCKED_PATH)
	check(not ok, "save_data() reports the failure instead of returning silently")

	var after: PackedByteArray = FileAccess.get_file_as_bytes(BLOCKED_PATH)
	check(after == before, "the destination is byte-identical after the failed write")
	check(int(SALVAGE_SAVE.load_data(BLOCKED_PATH).get("total_salvage", -1)) == SURVIVOR_TOTAL,
		"the previous save still loads as itself, not as a default")

	DirAccess.remove_absolute(part_dir)
	check(SALVAGE_SAVE.save_data({"total_salvage": 777}, BLOCKED_PATH),
		"the writer recovers once the obstruction is gone")
	_remove(BLOCKED_PATH)


## Phase C — the interruption itself, injected at the one instant that matters.
##
## Both sequences are stopped half a document in: the old form has already truncated the destination,
## the new form has only touched a scratch file. This is what a crash, a kill or a full disk does,
## reproduced deterministically rather than raced for.
func _check_injected_interruption() -> void:
	print("\n== C · an interrupted write cannot destroy the previous save ==")
	var whole: String = JSON.stringify({"schema_version": 1, "total_salvage": SURVIVOR_TOTAL})
	var half: String = whole.substr(0, int(whole.length() / 2.0))

	# Negative control. If this ever stops failing, the check has lost its teeth, not gained safety:
	# it means the hazard F-326 describes can no longer be demonstrated and the assertion below
	# proves nothing.
	_remove(TORN_PATH)
	check(SALVAGE_SAVE.save_data({"total_salvage": SURVIVOR_TOTAL}, TORN_PATH),
		"negative control starts from a valid save")
	var torn_file: FileAccess = FileAccess.open(TORN_PATH, FileAccess.WRITE)  # truncates HERE
	torn_file.store_string(half)
	torn_file.flush()
	torn_file = null  # the process dies before the rest of the document is written
	check(not _parses_whole(TORN_PATH),
		"negative control: truncate-then-refill leaves an unparseable file when interrupted")
	check(int(SALVAGE_SAVE.load_data(TORN_PATH).get("total_salvage", -1)) != SURVIVOR_TOTAL,
		"negative control: the old value is gone — this is the data loss F-326 filed")

	# The shipped sequence, interrupted at the same point.
	_remove(SURVIVOR_PATH)
	check(SALVAGE_SAVE.save_data({"total_salvage": SURVIVOR_TOTAL}, SURVIVOR_PATH),
		"the survivor case starts from the same valid save")
	var part_file: FileAccess = FileAccess.open(SURVIVOR_PATH + ".part", FileAccess.WRITE)
	part_file.store_string(half)
	part_file.flush()
	part_file = null  # the process dies before the rename
	check(_parses_whole(SURVIVOR_PATH),
		"the destination is still a whole document after the interruption")
	check(int(SALVAGE_SAVE.load_data(SURVIVOR_PATH).get("total_salvage", -1)) == SURVIVOR_TOTAL,
		"the previous save survived the interrupted write intact")

	# A crash leaves its scratch file behind; the next save must not be jammed by it.
	check(SALVAGE_SAVE.save_data({"total_salvage": 55}, SURVIVOR_PATH),
		"a stale .part from a previous crash does not block the next save")
	check(int(SALVAGE_SAVE.load_data(SURVIVOR_PATH).get("total_salvage", -1)) == 55,
		"the next save after a crash lands normally")
	_remove(TORN_PATH)
	_remove(SURVIVOR_PATH)
	_remove(SURVIVOR_PATH + ".part")


## Phase D — the regression tripwire.
##
## Phases A-C all pass on a machine that never fails a write, which is every developer machine. This
## one reads the source: a writer that opens its own destination for writing has reintroduced F-326
## no matter how green the behavioral phases look.
func _check_no_writer_truncates() -> void:
	print("\n== D · no writer opens its destination for truncating writes ==")
	for entry: Array in WRITERS:
		var label: String = entry[0]
		var script_path: String = (entry[1] as GDScript).resource_path
		var source: String = FileAccess.get_file_as_string(script_path)
		check(not source.is_empty(), "%s source is readable (%s)" % [label, script_path])
		check(not source.contains("FileAccess.WRITE"),
			"%s no longer opens a destination with FileAccess.WRITE" % label)
		check(source.contains("AtomicJson.write("),
			"%s writes through the shared durable seam" % label)


## True only for a file that exists and parses as a whole JSON object. `JSON.new().parse()` rather
## than the static `JSON.parse_string()` on purpose: this function's job is to REPORT a torn file,
## and the static form would `ERR_PRINT` one undeclared engine error per torn sample it found.
func _parses_whole(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var raw: String = FileAccess.get_file_as_string(path)
	if raw.is_empty():
		return false
	var json := JSON.new()
	if json.parse(raw) != OK:
		return false
	return json.data is Dictionary


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _cleanup() -> void:
	for path: String in ALL_PATHS:
		_remove(path)
		_remove(path + ".part")
		var part_dir: String = ProjectSettings.globalize_path(path + ".part")
		if DirAccess.dir_exists_absolute(part_dir):
			DirAccess.remove_absolute(part_dir)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
