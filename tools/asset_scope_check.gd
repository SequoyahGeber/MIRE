extends SceneTree

## F-255 — the standing guard for D-159: no asset may promise a space the terrain cannot hold.
##
##   .agent/bin/agent godot --script tools/asset_scope_check.gd
##
## D-142 put 3D density and caves on the cut list, so the shipped world is a 2D heightfield with
## nothing below grade. An asset that shows a mouth into the ground is therefore a promise the
## terrain cannot keep — a player walks up to it, tries to go in, and finds solid ground.
##
## This has now been caught three separate times by three separate readers, each after the asset
## list had already been written: F-237 (`cave entrance`, A-016), F-255 (`flooded cellar entrance`,
## A-020) and F-255's own sibling sweep (`burrow entrance`, A-016b). Every one of them was found by
## a human re-reading a table, which is exactly the kind of vigilance that stops happening. So the
## rule is asserted here instead, against the files where an asset gets NAMED — the tracker rows,
## the kit READMEs and the Blender build scripts — rather than against the finished GLBs, because
## by the time the GLB exists somebody has already spent a day in Blender.
##
## The rule, stated as the lint enforces it: a line in those files may name a below-grade interior
## (`cave`, `cellar`, `tunnel`, `catacomb`, `crypt`, `basement`, `dungeon`, `undercroft`,
## `mine shaft`) or an `<x> entrance` ONLY IF the same line cites the finding or decision that
## settles it — an `F-NNN` or `D-NNN`. That exemption is the point, not a loophole: recording the
## cut is exactly what F-237 and F-255 did, and a row that names a cave without saying why is
## precisely the row that gets built. Prose about a cut reads the same as prose proposing one; the
## citation is the only thing that distinguishes them, so the citation is what is required.
##
## Nothing here reads the engine, so it costs no import and no scene tree — but it runs through
## `agent godot` like everything else (F-044), and it lives in `tools/` so the next asset batch's
## work order can name it alongside that kit's own dimensional check.

## Where assets get named. Directories are walked for the file names given.
const TRACKER_PATH := "res://docs/ASSET_TRACKER.md"
const ASSETS_DIR := "res://assets/"
const BLENDER_DIR := "res://tools/blender/"

## A below-grade interior, by name. Word-bounded so `crypt` does not match `_crypto` and `cave`
## does not match `caved-in` (a caved-in floor slab is a surface, and A-020 is scoped to have one).
const INTERIOR_NOUNS := "cave|cellar|catacomb|crypt|basement|dungeon|tunnel|undercroft|mine ?shaft"
## `entrance` on its own. `entry` is deliberately NOT here: it matches `catalog entry`, `SIZE entry`
## and `carpentry` across a dozen build scripts, and a lint with false positives gets ignored.
const OPENING_WORD := "entrance"
## The citation that turns a mention into a record.
const CITATION := "\\b[FD]-[0-9]{3}\\b"

var _failures: int = 0
var _lines_scanned: int = 0
var _files_scanned: int = 0
var _re_interior: RegEx
var _re_opening: RegEx
var _re_citation: RegEx


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _initialize() -> void:
	print("=== MIRE F-255 — asset scope: no promised space the heightfield cannot hold (D-159) ===")
	print("Godot %s | %s" % [Engine.get_version_info()["string"], OS.get_name()])

	_re_interior = RegEx.create_from_string("(?i)\\b(%s)s?\\b" % INTERIOR_NOUNS)
	_re_opening = RegEx.create_from_string("(?i)\\b%s\\b" % OPENING_WORD)
	_re_citation = RegEx.create_from_string(CITATION)

	var targets := _targets()
	print("scanning %d file(s) where assets get named\n" % targets.size())

	for path: String in targets:
		_scan(path)

	print("")
	_check("every kit README and build script was reachable", _files_scanned == targets.size(),
		"read %d of %d" % [_files_scanned, targets.size()])
	# A lint that silently scans nothing passes forever. Assert it actually read the corpus.
	_check("the corpus is non-trivial (>500 lines)", _lines_scanned > 500,
		"only %d line(s) scanned" % _lines_scanned)
	_check("the tracker itself was scanned", targets.has(TRACKER_PATH))

	print("")
	_check_no_built_asset()

	print("\n%d line(s) across %d file(s) scanned" % [_lines_scanned, _files_scanned])
	print("%d failure(s)\n" % _failures)
	quit(1 if _failures > 0 else 0)


## Every file where an asset gets a name before it gets a mesh.
func _targets() -> Array[String]:
	var out: Array[String] = [TRACKER_PATH]
	for kit: String in DirAccess.get_directories_at(ASSETS_DIR):
		var readme := "%s%s/README.md" % [ASSETS_DIR, kit]
		if FileAccess.file_exists(readme):
			out.append(readme)
	for name: String in DirAccess.get_files_at(BLENDER_DIR):
		if name.begins_with("build_") and name.ends_with(".py"):
			out.append(BLENDER_DIR + name)
	out.sort()
	return out


func _scan(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_failures += 1
		print("  FAIL  cannot read %s" % path)
		return
	_files_scanned += 1
	var line_no := 0
	var offenders: Array[String] = []
	while not file.eof_reached():
		var line := file.get_line()
		line_no += 1
		_lines_scanned += 1
		var interior := _re_interior.search(line)
		var opening := _re_opening.search(line)
		if interior == null and opening == null:
			continue
		if _re_citation.search(line) != null:
			continue  # named WITH its reason — that is the record F-237/F-255 exist to leave.
		var what: String = interior.get_string() if interior != null else opening.get_string()
		offenders.append("line %d names `%s` with no F-/D- citation" % [line_no, what])
	_check("%s promises nothing below grade" % path.trim_prefix("res://"), offenders.is_empty(),
		"; ".join(offenders))


## The second half of the rule: nothing may have been BUILT under one of those names either. A
## re-scoped tracker row is worth nothing if a `cave_entrance.glb` shipped anyway.
func _check_no_built_asset() -> void:
	var offenders: Array[String] = []
	for kit: String in DirAccess.get_directories_at(ASSETS_DIR):
		var exports := "%s%s/exports/" % [ASSETS_DIR, kit]
		if not DirAccess.dir_exists_absolute(exports):
			continue
		for name: String in DirAccess.get_files_at(exports):
			if not name.ends_with(".glb"):
				continue
			# `_` is a word character, so `\bentrance\b` never fires inside `cave_entrance`.
			var stem := name.get_basename().replace("_", " ")
			if _re_interior.search(stem) != null or _re_opening.search(stem) != null:
				offenders.append("%s%s" % [exports.trim_prefix("res://"), name])
	_check("no exported GLB is named for a below-grade interior", offenders.is_empty(),
		", ".join(offenders))
