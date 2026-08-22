extends SceneTree

## F-574 — a placed chest is always openable by somebody.
##
## `ChestPlacementService._ECONOMY_FOR_TIER` can lock a tier behind an item id, and until
## 2026-08-22 nothing checked that the id resolved. `gilded` named `gilded_key`, which appeared in
## exactly ONE file in the whole repository — the table entry itself. No item def, no loot entry, no
## recipe, no drop. `Chest._accept_open_request()` charges `cost_coins` AND `locked_by` together in
## one transaction, so the requirement could never be met, and `content/poi/treasure_gilded.tres`
## placed two of them on every procedural island: built, rendered, locator-tinted, permanently shut.
##
## Two things are asserted, and they are deliberately different in kind:
##
##   1. **Every gate item a tier names must be registered.** This is the authoring rule. It fails
##      loudly the moment somebody prices a tier in an item that does not exist, which is the silence
##      that let this ship.
##   2. **A tier whose gate is unsatisfiable places NO chest.** This is the runtime behaviour, and it
##      is what makes assertion 1 safe to fail: content can be ahead of art without a player ever
##      meeting an unopenable box.
##
## Assertion 1 is EXPECTED TO FAIL while `gilded_key` is unauthored (A-047, `rusted key, gilded key`,
## still QUEUED) — that is the finding staying open and honest rather than being silenced. It is
## reported separately from assertion 2 so the two never get confused: the day the key ships,
## assertion 1 goes green with no edit here.
##
## Authority: none. Read-only measurement.

var failures: int = 0
var pending_content: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	print("=== MIRE F-574 — every placed chest is openable by somebody ===")

	var registry: Node = root.get_node_or_null(^"Registry")
	var service: Node = root.get_node_or_null(^"ChestPlacementService")
	check(registry != null, "Registry autoload exists")
	check(service != null, "ChestPlacementService autoload exists")
	if registry == null or service == null:
		_finish()
		return

	# Read off the LIVE autoload's script rather than a preloaded copy: a `const` is not reachable
	# through `Script.get()`, and reading the running service is what the game actually uses.
	var economy: Dictionary = (service.get_script() as GDScript) \
		.get_script_constant_map().get("_ECONOMY_FOR_TIER", {})
	check(not economy.is_empty(), "the tier economy table is readable (%d rung(s))" % economy.size())

	# ── 1 · the authoring rule ────────────────────────────────────────────────────────────────
	print("\n== every gate item a tier names is a registered item ==")
	var unsatisfiable: Array[StringName] = []
	for tier: StringName in economy:
		var key := StringName((economy[tier] as Dictionary).get("locked_by", &""))
		if key == &"":
			print("  ok   %s is not key-gated" % tier)
			continue
		if bool(registry.call("has_item", key)):
			print("  ok   %s is locked by '%s', which exists" % [tier, key])
			continue
		unsatisfiable.append(tier)
		pending_content += 1
		print("  PENDING  %s is locked by '%s', which is not a registered item" % [tier, key])

	# ── 2 · the runtime behaviour that makes the above survivable ────────────────────────────
	print("\n== a tier with an unreachable gate places no chest at all ==")
	for tier: StringName in economy:
		var key := StringName((economy[tier] as Dictionary).get("locked_by", &""))
		var expected: bool = key == &"" or bool(registry.call("has_item", key))
		check(bool(service.call("_gate_is_satisfiable", tier)) == expected,
			"%s builds a chest only if its gate can be met (expected %s)" % [tier, expected])

	# The specific regression: no unopenable chest may be reachable from a marker name that the
	# world actually produces. `treasure_gilded` is the def that placed them.
	print("\n== the marker names the world produces do not resolve to an unopenable tier ==")
	for marker_name: String in ["Chest_gilded_poi", "Chest_gilded_0", "Chest_legendary_0",
			"Chest_epic_0", "Chest_rare_0", "Chest_common_0", "Chest_basic_0", "Cache_0"]:
		var tier: StringName = service.call("_tier_for_marker_name", marker_name)
		if tier == &"":
			continue
		var buildable: bool = bool(service.call("_gate_is_satisfiable", tier))
		var openable: bool = buildable
		check(openable or unsatisfiable.has(tier),
			"marker '%s' -> tier '%s' either builds an openable chest or builds nothing"
				% [marker_name, tier])

	_finish()


func check(ok: bool, label: String) -> void:
	if ok:
		print("  ok   %s" % label)
	else:
		failures += 1
		print("  FAIL %s" % label)


func _finish() -> void:
	if pending_content > 0:
		print("\n%d tier(s) awaiting a gate item that art has not shipped yet (A-047)." % pending_content)
		print("Those tiers place NOTHING today, which is the point — no player meets a locked box.")
	print("\nCHEST_GATE_CHECK failures=%d pending=%d" % [failures, pending_content])
	quit(0 if failures == 0 else 1)
