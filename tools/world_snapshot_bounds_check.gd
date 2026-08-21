extends SceneTree

## F-332: a joining client must not allocate whatever the host tells it to.
##
## `WorldDeltaLog.net_world_snapshot()` receives the uncompressed size over the wire and used to hand
## it straight to `PackedByteArray.decompress()`, with `> 0` as the only validation. That allocation
## happens before the payload's type is checked, so a malicious host, a buggy one, or a corrupted
## packet could ask a joining client for an arbitrarily large buffer at the most vulnerable moment in
## its lifecycle — the one RPC it must accept to catch up at all.
##
## Every case below drives the real RPC handler directly with hostile arguments and asserts the same
## two things: the snapshot is refused, and the log's existing state is EXACTLY as it was. The second
## half is the one that matters. A guard that rejects a bad snapshot but leaves the log half-replaced
## has turned a denial of service into a silent desync, which is worse.
##
##   .agent/bin/agent godot --script tools/world_snapshot_bounds_check.gd
##
## Authority: docs/ARCHITECTURE.md §2.2's world-mutation row (HOST). This check never opens a
## session — it calls the receiving half directly, which is the code a client runs, and is the only
## way to deliver bytes a well-behaved host would never send.

## Preloaded for their constants — a script constant is not an object property, so it has to be read
## off the script rather than off the autoload instance.
const WorldDeltaLogScript := preload("res://autoload/world_delta_log.gd")
const MireGridSimScript := preload("res://world/mire/mire_grid_sim.gd")

const KIND: StringName = &"snapshot_bounds_check"
const CHUNK := Vector2i(7, -3)
const KEY: String = "sentinel"
const SENTINEL: int = 8_675_309

var failures: int = 0
var _log: Node = null


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_log = root.get_node_or_null(^"WorldDeltaLog")
	if _log == null:
		push_error("FAIL: WorldDeltaLog autoload missing")
		quit(1)
		return

	_check_budget_is_derived()
	_check_legitimate_snapshot_still_lands()
	_check_hostile_inputs()

	# Standing rule 4 (docs/SPECS.md): every refusal below warns on purpose. Declared, not silenced.
	print("\nWORLD_SNAPSHOT_BOUNDS_CHECK failures=%d" % failures
		+ " · EXPECTED_WARNING_PATTERNS=\"refused a snapshot|refused a|decompressed to|did not decode\"")
	quit(0 if failures == 0 else 1)


## The cap has to follow the world. A number somebody typed once is a number that silently becomes
## either a denial-of-service hole or a broken late join the first time the grid changes size.
func _check_budget_is_derived() -> void:
	print("\n== the budget is derived from the world, not picked ==")
	var cells: int = MireGridSimScript.CELL_COUNT
	var entries: int = WorldDeltaLogScript.MAX_SNAPSHOT_ENTRIES
	var budget: int = WorldDeltaLogScript.MAX_SNAPSHOT_BYTES
	check(cells > 0, "MireGridSim publishes a cell count (%d)" % cells)
	check(entries >= cells,
		"the entry budget covers a fully corrupted Mire (%d entries vs %d cells)" % [entries, cells])
	check(budget == entries * WorldDeltaLogScript.SNAPSHOT_BYTES_PER_ENTRY,
		"the byte budget is entries x bytes-per-entry (%d)" % budget)
	check(budget > 0 and budget < (1 << 31),
		"the byte budget is finite and allocatable (%d bytes)" % budget)


## The guard must not have broken the thing it guards. A late joiner still has to catch up.
func _check_legitimate_snapshot_still_lands() -> void:
	print("\n== a well-formed snapshot is still adopted ==")
	var payload: Dictionary = {CHUNK: {String(KIND): {KEY: SENTINEL}}}
	var raw: PackedByteArray = var_to_bytes(payload)
	var compressed: PackedByteArray = raw.compress(FileAccess.COMPRESSION_GZIP)
	_log.call(&"net_world_snapshot", 12345, raw.size(), compressed)
	check(int(_log.call(&"latest", CHUNK, KIND, KEY, 0)) == SENTINEL,
		"an honest snapshot is decompressed and adopted")
	check(int(_log.call(&"entry_count")) == 1, "and it replaced the log wholesale, as designed")


## The hostile cases. Each one runs against a log that already holds the sentinel above, so
## "unchanged" is a fact this check can read back rather than an absence it has to trust.
func _check_hostile_inputs() -> void:
	print("\n== hostile snapshots are refused, and refused without damage ==")
	var budget: int = WorldDeltaLogScript.MAX_SNAPSHOT_BYTES
	var honest: PackedByteArray = var_to_bytes({CHUNK: {String(KIND): {KEY: 1}}})
	var honest_gz: PackedByteArray = honest.compress(FileAccess.COMPRESSION_GZIP)

	# The headline case: a size no machine should attempt to allocate.
	_expect_refused("a declared size of 1 TiB", 1 << 40, honest_gz)
	# One byte past the budget — the boundary, so the cap is proven to be the thing rejecting it.
	_expect_refused("a declared size one byte past the budget", budget + 1, honest_gz)
	# A compressed payload larger than the budget, rejected before any decompression is attempted.
	var oversized := PackedByteArray()
	oversized.resize(budget + 1)
	_expect_refused("a compressed payload larger than the budget", 64, oversized)
	# Truthfully sized but not actually that payload — the declared size was simply a lie.
	_expect_refused("a declared size that does not match the payload", honest.size() + 512, honest_gz)
	# Not gzip at all. `decompress()` fails and returns nothing.
	var garbage := PackedByteArray([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33])
	_expect_refused("bytes that are not a gzip stream", 4096, garbage)
	# Valid gzip, valid size, decodes to something that is not a Dictionary.
	var not_a_dict: PackedByteArray = var_to_bytes(42)
	_expect_refused("a payload that decodes to an int rather than a Dictionary",
		not_a_dict.size(), not_a_dict.compress(FileAccess.COMPRESSION_GZIP))
	# An empty compressed payload with a plausible size.
	_expect_refused("an empty compressed payload", 128, PackedByteArray())
	# The pre-existing zero/negative guard, kept covered so a refactor cannot drop it.
	_expect_refused("a declared size of zero", 0, honest_gz)
	_expect_refused("a negative declared size", -1, honest_gz)


func _expect_refused(label: String, original_size: int, compressed: PackedByteArray) -> void:
	var before_count: int = int(_log.call(&"entry_count"))
	var before_value: int = int(_log.call(&"latest", CHUNK, KIND, KEY, 0))
	_log.call(&"net_world_snapshot", 999, original_size, compressed)
	var intact: bool = int(_log.call(&"entry_count")) == before_count \
		and int(_log.call(&"latest", CHUNK, KIND, KEY, 0)) == before_value
	check(intact, "%s is refused and the existing log is untouched" % label)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
