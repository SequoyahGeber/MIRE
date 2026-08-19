extends SceneTree

## F-248's tripwire: M8's real-App-ID dependency (8.1/8.2 gate the actual deliverable of several
## later M8 tasks — D-132 already lived this for 8.4) was nowhere the board could see, so a task
## could read as independently routable while it was really waiting on Sequoyah's own paperwork.
##
##   .agent/bin/agent godot --script tools/roadmap_dependency_check.gd
##
## SOURCE-TEXT check, like tools/findings_numbering_check.gd — this is a doc-consistency property,
## not something a running game can fail against. A real `depends_on` field on task rows (rendered
## by `agent brief`/`board`) is the harder fix F-248 named and deliberately left undone — that is
## real harness work and its own design call, not a rider on a doc fix. This check instead guards
## the cheap standin: a standing dependency note at the top of `docs/ROADMAP.md`'s M8 section
## (F-248's own "cheaper" option). It fails if the note goes missing, or if the task ids it names
## drift out of sync with the M8 table — the exact way a doc note rots silently otherwise.

const PATH: String = "res://docs/ROADMAP.md"

## Tasks the note claims are genuinely gated on 8.1/8.2 landing a real App ID.
const GATED_IDS: PackedStringArray = ["8.5", "8.6", "8.7", "8.9", "8.11"]

## Tasks the note calls out as the counter-example — read as gated but shipped anyway by building
## against the placeholder (D-132/D-148). If either flips back to `todo`-and-unshipped in a way
## that makes this claim stale, a human needs to know, not just this check.
const COUNTEREXAMPLE_IDS: PackedStringArray = ["8.3", "8.4"]

const PREREQ_IDS: PackedStringArray = ["8.1", "8.2"]

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var text: String = FileAccess.get_file_as_string(PATH)
	if text.is_empty():
		fail("%s read as empty — path wrong, or the doc moved" % PATH)
		_finish()
		return

	var m8_start: int = text.find("## M8")
	check(m8_start != -1, "found an '## M8' section heading")
	if m8_start == -1:
		_finish()
		return

	# M8 is the last milestone section (ROADMAP.md's own "Scope-cut levers" epilogue follows it),
	# so the section body runs from '## M8' to the next '## ' heading, or EOF.
	var next_heading: int = text.find("\n## ", m8_start + 1)
	var m8_body: String = text.substr(m8_start, (next_heading - m8_start) if next_heading != -1 else -1)

	check(m8_body.find("Dependency note (F-248)") != -1,
		"M8 section still carries the F-248 standing dependency note")
	check(m8_body.find("tools/roadmap_dependency_check.gd") != -1,
		"the note names this check, so a future editor knows drift here is caught, not just read")

	print("\n== every id the note cites still exists as a real M8 table row ==")
	for tid: String in PREREQ_IDS + GATED_IDS + COUNTEREXAMPLE_IDS:
		check(m8_body.find("| %s |" % tid) != -1,
			"M8 table still has a row for %s (renumbering would silently orphan the note)" % tid)

	print("\n== the note actually names every task it claims is gated ==")
	for tid: String in GATED_IDS:
		check(m8_body.find(tid) != -1,
			"F-248 note text mentions %s (it's in this check's GATED_IDS list)" % tid)

	print("\n== the note actually names its own counter-example ==")
	for tid: String in COUNTEREXAMPLE_IDS:
		check(m8_body.find(tid) != -1,
			"F-248 note text mentions %s (it's in this check's COUNTEREXAMPLE_IDS list)" % tid)

	_finish()


func _finish() -> void:
	print("\nROADMAP_DEPENDENCY_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	fail(description)


func fail(description: String) -> void:
	failures += 1
	push_error("FAIL: %s" % description)
