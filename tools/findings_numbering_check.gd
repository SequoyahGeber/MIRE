extends SceneTree

## F-087's tripwire: `docs/FINDINGS.md` is deliberately unclaimed (F-006), so two lanes filing a
## finding in the same window can both read `agent brief`'s "next number" and both append as it.
## That produced F-058 (twice, both under '## Open'), and F-059/F-060 (one Open, one Resolved and
## already cited by a shipped commit) — `agent brief`/`claim` picked one arbitrarily, and
## `agent start`/`board` reported the Open one as "closed but still under '## Open'" because it
## matched the Resolved twin by number.
##
##   .agent/bin/agent godot --script tools/findings_numbering_check.gd
##
## SOURCE-TEXT check, like tools/net_check_pattern_check.gd — this is a doc-consistency property,
## not something a running game can fail against. `.agent/bin/agent`'s own `_duplicate_findings()`
## and `_findings_drift()` (`agent board`/`start`) catch the same two shapes at read time; this is
## the standing regression guard so a reintroduced collision fails a check instead of only printing
## a warning nobody reads.
##
## Trap 1 — the SAME F-number heads two entries under '## Open'. `brief`/`claim` then pick one of
## them arbitrarily (F-087).
##
## Trap 2 — an F-number heads an entry under '## Open' AND a (different) entry under '## Resolved'.
## `board` (reads state, which never downgrades status) hides it as done; `brief` (reads the doc)
## offers it as open work — the two records disagree about whether it's finished (F-071, F-087).
##
## Deliberately NOT checked: two entries with the same number both under '## Resolved' (F-052,
## F-055, F-056) — no routing risk, since nothing routes to a resolved finding (F-087's own fix note
## says so), so those are left as historical record on purpose. Flagging them here would make this
## check fail forever against a decision already made.

const PATH: String = "res://docs/FINDINGS.md"

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var text: String = FileAccess.get_file_as_string(PATH)
	if text.is_empty():
		fail("%s read as empty — path wrong, or the doc moved" % PATH)
		_finish(0, 0)
		return
	var lines: PackedStringArray = text.split("\n")

	var open_ids: Array[String] = []
	var resolved_ids: Array[String] = []
	var section: String = ""  # "" until the first section marker, then "open" or "resolved"
	var in_fence: bool = false  # "## How to file one" shows a fenced ### F-012 example; skip fences
	var heading_re := RegEx.new()
	heading_re.compile("^### (F-\\d+)\\s")

	for line: String in lines:
		if line.begins_with("```"):
			in_fence = not in_fence
			continue
		if in_fence:
			continue
		if line.begins_with("## Open"):
			section = "open"
			continue
		if line.begins_with("## Resolved"):
			section = "resolved"
			continue
		var m: RegExMatch = heading_re.search(line)
		if m == null:
			continue
		var fid: String = m.get_string(1)
		match section:
			"open":
				open_ids.append(fid)
			"resolved":
				resolved_ids.append(fid)
			_:
				fail("%s heading found before the first '## Open'/'## Resolved' marker — section scan is broken" % fid)

	check(not open_ids.is_empty(), "found at least one '### F-NNN' heading under '## Open' (%d found) — the scan itself is broken if this fails" % open_ids.size())
	check(not resolved_ids.is_empty(), "found at least one '### F-NNN' heading under '## Resolved' (%d found) — the scan itself is broken if this fails" % resolved_ids.size())

	print("\n== trap 1: one F-number heading two different entries under '## Open' ==")
	var open_seen: Dictionary = {}
	var open_dupes: Dictionary = {}
	for fid: String in open_ids:
		if open_seen.has(fid):
			open_dupes[fid] = true
		open_seen[fid] = true
	check(open_dupes.is_empty(), "no F-number used by more than one '## Open' entry (dupes: %s)"
		% ", ".join(open_dupes.keys()))

	print("\n== trap 2: an F-number under '## Open' also heads a different entry under '## Resolved' ==")
	var resolved_set: Dictionary = {}
	for fid: String in resolved_ids:
		resolved_set[fid] = true
	var collided: Array = []
	for fid: String in open_seen.keys():
		if resolved_set.has(fid):
			collided.append(fid)
	check(collided.is_empty(), "no F-number is both '## Open' and '## Resolved' (collided: %s)"
		% ", ".join(collided))

	_finish(open_ids.size(), resolved_ids.size())


func _finish(open_count: int, resolved_count: int) -> void:
	print("\nFINDINGS_NUMBERING_CHECK open=%d resolved=%d failures=%d" % [open_count, resolved_count, failures])
	quit(0 if failures == 0 else 1)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	fail(description)


func fail(description: String) -> void:
	failures += 1
	push_error("FAIL: %s" % description)
