extends SceneTree

## F-439 — the reverse of `tools/art_coverage_check.gd`: every shipped export must be reachable
## from something the GAME loads.
##
##   .agent/bin/agent godot --script tools/asset_usage_check.gd
##
## `art_coverage_check.gd` measures the forward direction — a definition whose art slot is empty or
## whose path has rotted. This measures the other one: an export that was modelled, exported,
## catalogued, previewed and committed, and that no definition, scene, scatter table or map layout
## ever names. Art is the most expensive thing made in this repo, so an unreferenced export is the
## most wasteful failure it has, and it is silent by construction — nothing breaks, nothing errors,
## the asset simply never appears in the game.
##
## F-395 is why this exists. It found 141 authored-map assets the procedural island never placed —
## eighteen finished trees among them, which is why the island read as having one tree species — and
## closed with the line this file is the answer to: "Nothing checks that the two agree, so the gap
## is invisible."
##
## Two rules make this measurement correct rather than merely plausible, and both were learned by
## getting them wrong first:
##
##   MATCH ON THE STEM, NOT THE FILENAME. Scatter entries name assets as `asset = &"bush_round_a"`
##   with `kit = "flora"` on a separate line, and `world/gen/authored_world.gd` composes the path
##   at runtime as `res://assets/%s/exports/%s.glb`. The string `bush_round_a.glb` appears nowhere.
##   A sweep for filenames reports almost the entire flora and environment kit as dead, which is
##   both wrong and — because it is so obviously wrong — the kind of result that gets a lint
##   switched off. Matching is word-bounded so `pickup_coin` does not satisfy `pickup_coin_stack`.
##
##   `catalog.json` IS NOT A CONSUMER. Every `assets/*/catalog.json` in this repo is read only by
##   `tools/*_check.gd`, never by the game. A catalogued asset is a VALIDATED asset, not a USED
##   one, and counting the catalog as a reference makes every asset pass forever. For the same
##   reason `docs/` and `tools/` are excluded: an asset named only in a tracker row and a build
##   script is exactly the asset this check exists to find.
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Read-only measurement, no engine state.

const ASSETS_DIR := "res://assets/"
const ART_SUFFIXES: PackedStringArray = [".glb", ".png"]

## Directories under `assets/` that hold no shipped art. `preview/` is contact sheets, `source/` is
## third-party reference kept for study only (never shipped — see the reference-art rule), and
## `audit/` is screenshots from past investigations.
const NON_SHIPPING_DIRS: PackedStringArray = ["preview", "source", "audit"]

## Top-level directories that are NOT consumers. `assets/` would let a catalog vouch for itself,
## `docs/` and `tools/` describe and validate art rather than using it.
const NON_CONSUMER_DIRS: PackedStringArray = ["res://assets", "res://docs", "res://tools",
	"res://.godot", "res://.agent", "res://.git"]

const CONSUMER_SUFFIXES: PackedStringArray = [".gd", ".tres", ".tscn", ".json", ".gdshader"]

## Exports allowed to be unreferenced, with the reason. NAMED, never inferred — adding one is a
## decision somebody makes on purpose, exactly as `art_coverage_check.gd` handles its exemptions.
## An entry here is a promise that the asset is deliberately held, not forgotten.
const EXEMPT: Dictionary[String, String] = {}

var _failures: int = 0
var _checked: int = 0


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _initialize() -> void:
	print("=== MIRE F-439 — asset usage: every shipped export is reachable from the game ===")
	print("Godot %s | %s" % [Engine.get_version_info()["string"], OS.get_name()])

	var exports := _shipped_exports()
	var corpus := _consumer_corpus()
	print("%d shipped export(s) | %d consumer file(s)\n" % [exports.size(), corpus.size()])

	# A sweep that silently reads nothing passes forever. Assert the corpus is real before
	# trusting a single "unreferenced" verdict from it.
	_check("the consumer corpus is non-trivial (>200 files)", corpus.size() > 200,
		"only %d file(s)" % corpus.size())
	_check("shipped exports were found (>200)", exports.size() > 200,
		"only %d export(s)" % exports.size())
	# The stem rule, asserted rather than trusted: this is the bug that made the first version of
	# this check useless, so it is pinned by a test rather than by the comment above.
	_check("stem matching is live (a known scatter asset resolves)",
		_referenced("bush_round_a", corpus),
		"`bush_round_a` is placed by content/scatter/forest_undergrowth.tres — if this fails, "
		+ "matching regressed to filenames and every verdict below is wrong")
	print("")

	var unused: Dictionary[String, PackedStringArray] = {}
	for path: String in exports:
		_checked += 1
		var stem := path.get_file().get_basename()
		if EXEMPT.has(stem):
			continue
		if _referenced(stem, corpus):
			continue
		var kit := path.trim_prefix(ASSETS_DIR).get_slice("/", 0)
		if not unused.has(kit):
			unused[kit] = PackedStringArray()
		unused[kit].append(stem)

	var total := 0
	for kit: String in unused:
		total += unused[kit].size()

	if total == 0:
		_check("every shipped export is referenced by something the game loads", true)
	else:
		_failures += 1
		print("  FAIL  %d of %d shipped export(s) are referenced by nothing the game loads"
			% [total, _checked])
		var kits := unused.keys()
		kits.sort()
		for kit: String in kits:
			var names := unused[kit]
			names.sort()
			print("\n        %s  (%d)" % [kit, names.size()])
			for name: String in names:
				print("          %s" % name)
		print("\n        Not necessarily deletions. An unreferenced export is usually a kit built")
		print("        ahead of the content that would place it — the fix is a scatter entry, an")
		print("        item def or a scene, not `rm`. If one is deliberately held, name it in")
		print("        EXEMPT with the reason.")

	print("\n%d export(s) checked" % _checked)
	print("%d failure(s)\n" % _failures)
	quit(1 if _failures > 0 else 0)


## Every file under `assets/<kit>/exports/` that is shipped art.
func _shipped_exports() -> Array[String]:
	var out: Array[String] = []
	for kit: String in DirAccess.get_directories_at(ASSETS_DIR):
		if NON_SHIPPING_DIRS.has(kit):
			continue
		var exports := "%s%s/exports/" % [ASSETS_DIR, kit]
		if not DirAccess.dir_exists_absolute(exports):
			continue
		for name: String in DirAccess.get_files_at(exports):
			for suffix: String in ART_SUFFIXES:
				if name.ends_with(suffix):
					out.append(exports + name)
					break
	out.sort()
	return out


## Everything that can legitimately make the game load an asset. Read once, held as text — the
## corpus is a few hundred small files and re-reading it per asset would be 500x the I/O.
func _consumer_corpus() -> Array[String]:
	var out: Array[String] = []
	_walk("res://", out)
	return out


func _walk(dir: String, out: Array[String]) -> void:
	for sub: String in DirAccess.get_directories_at(dir):
		if sub.begins_with("."):
			continue
		var child := dir.path_join(sub)
		if NON_CONSUMER_DIRS.has(child):
			continue
		_walk(child, out)
	for name: String in DirAccess.get_files_at(dir):
		for suffix: String in CONSUMER_SUFFIXES:
			if name.ends_with(suffix):
				var text := FileAccess.get_file_as_string(dir.path_join(name))
				if text != "":
					out.append(text)
				break


## Word-bounded so `pickup_coin` is not satisfied by `pickup_coin_stack`. `_` is a word character
## in RegEx, which is what makes the boundary do the right thing on these names for free.
func _referenced(stem: String, corpus: Array[String]) -> bool:
	var re := RegEx.create_from_string("\\b%s\\b" % stem)
	for text: String in corpus:
		if re.search(text) != null:
			return true
	return false
