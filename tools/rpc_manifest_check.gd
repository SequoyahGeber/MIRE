extends SceneTree

## Makes "bump PROTOCOL_VERSION when you change the wire" mechanical instead of remembered.
##
##   .agent/bin/agent godot --script tools/rpc_manifest_check.gd
##
## `net_version.gd` has always stated the rule. It was missed four times anyway — F-161, F-165,
## F-169, F-178, four agents, four tasks, same omission — because the failure is invisible when you
## cause it: two mismatched builds connect fine at the transport layer and only then read wrong
## values off the wire. This check scans every `@rpc` in the project, reduces it to one signature,
## and fails when that signature moves without the protocol version moving with it.
##
## WHEN THIS FAILS AND YOU DID CHANGE THE WIRE ON PURPOSE — the normal case:
##   1. bump `NetVersion.PROTOCOL_VERSION`, and add a line to its history block saying what changed;
##   2. paste the three constants this check prints into `core/net/rpc_manifest.gd`;
##   3. extend `tools/handshake_check.gd`'s hard-coded expectation, per the standing rule.
## Both 1 and 2, always. Re-recording the signature without bumping the version is precisely the
## mistake this exists to catch, so the check asserts they moved together.
const ManifestScript = preload("res://core/net/rpc_manifest.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	var entries: PackedStringArray = ManifestScript.scan()
	var signature: String = ManifestScript.signature(entries)

	check(entries.size() > 0, "the scanner found RPCs at all (%d)" % entries.size())
	if entries.is_empty():
		# A scanner that silently finds nothing would make every future run pass, which is worse than
		# any wire change it could miss.
		print("\nRPC_MANIFEST_CHECK failures=%d" % failures)
		finish()
		return

	_check_scanner_sanity(entries)

	var recorded: String = ManifestScript.RECORDED_SIGNATURE
	var version: int = NetVersion.PROTOCOL_VERSION
	var recorded_version: int = ManifestScript.RECORDED_PROTOCOL_VERSION

	if recorded == "PENDING":
		print("\n== first run: nothing recorded yet ==")
		_print_paste_block(signature, entries.size(), version)
		check(false, "the manifest has never been recorded — paste the block above into "
			+ "core/net/rpc_manifest.gd to arm this check")
	elif signature == recorded:
		print("\n== the wire surface is unchanged ==")
		check(version == recorded_version,
			"PROTOCOL_VERSION (%d) matches the recorded manifest (%d)" % [version, recorded_version]
				+ ("" if version == recorded_version
					else " — the version moved but no RPC did, so either the bump was for a "
						+ "SceneReplicationConfig change (fine: re-record) or it was a mistake"))
		check(entries.size() == ManifestScript.RECORDED_ENTRY_COUNT,
			"RPC count is still %d" % ManifestScript.RECORDED_ENTRY_COUNT)
	else:
		print("\n== THE WIRE SURFACE CHANGED ==")
		_report_drift(entries)
		check(version > recorded_version,
			"the wire changed, so PROTOCOL_VERSION must have been bumped: recorded %d, now %d"
				% [recorded_version, version])
		_print_paste_block(signature, entries.size(), version)
		# Even a correct bump leaves the manifest stale, and a stale manifest means the NEXT change
		# is invisible again. So this is a failure either way until the paste lands.
		check(false, "re-record the manifest (block above) so the next change is still caught")

	print("\nRPC_MANIFEST_CHECK failures=%d" % failures)
	finish()


## The scanner is the load-bearing part: if it silently under-counts, everything downstream passes
## while the wire drifts. These assert against RPCs known to exist, and against the two parsing
## cases most likely to break it.
func _check_scanner_sanity(entries: PackedStringArray) -> void:
	print("\n== the scanner actually parses what it claims ==")
	var joined: String = "\n".join(entries)
	for expected: String in [
		"net_submit_command", "net_command_result",   # 3.13, CommandService
		"net_rule_snapshot", "net_rule_changed",      # 3.14, RuleService
		"net_force_respawn",                          # 2.13, PlayerHealth
	]:
		check(joined.contains(expected), "found a known RPC: %s" % expected)

	check(joined.contains("|any_peer,call_remote,reliable"),
		"the @rpc config is captured, normalized and sorted")
	check(joined.contains("(int,"), "argument TYPES are captured, not just names")
	# A generic argument must not be split into two by a naive comma split. If this ever regresses,
	# the manifest becomes wrong in a way nobody would think to look for.
	var generics: int = 0
	for entry: String in entries:
		if entry.contains("Dictionary[") or entry.contains("Array["):
			generics += 1
	print("    (%d entr%s carry a generic type)" % [generics, "y" if generics == 1 else "ies"])


## Naming what moved is the whole difference between a useful failure and "the hash changed".
func _report_drift(entries: PackedStringArray) -> void:
	var recorded_count: int = ManifestScript.RECORDED_ENTRY_COUNT
	print("    RPC count: %d recorded -> %d now" % [recorded_count, entries.size()])
	print("    The current surface, in full — diff it against your last commit of rpc_manifest.gd:")
	for entry: String in entries:
		print("      %s" % entry)


func _print_paste_block(signature: String, count: int, version: int) -> void:
	print("")
	print("    --- paste into core/net/rpc_manifest.gd (AFTER bumping PROTOCOL_VERSION) ---")
	print("    const RECORDED_PROTOCOL_VERSION: int = %d" % version)
	print("    const RECORDED_SIGNATURE: String = \"%s\"" % signature)
	print("    const RECORDED_ENTRY_COUNT: int = %d" % count)
	print("    ---------------------------------------------------------------------------")


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
