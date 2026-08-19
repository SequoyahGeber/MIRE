extends SceneTree

## Makes F-232/F-233's hostile-client audit a standing check instead of a one-time sweep.
##
##   .agent/bin/agent godot --script tools/rpc_surface_audit_check.gd
##
## F-232 read every `@rpc("any_peer")` handler in the project by hand and found two doing real
## per-call host work with no throttle (fixed with `RpcRateLimiter`, D-141). F-233 named the rest —
## O(1) handlers, and a few already self-guarded (`Harvestable`'s per-peer cooldown,
## `CombatService`/`RangedCombatService`'s in-flight swing/shot lock) — so a future pass would not
## have to re-derive the list by hand again. A hand-derived list goes stale the moment someone adds a
## handler and forgets to re-run the audit; this check makes that impossible to do silently.
##
## `RpcManifest.scan()` (the same scanner `rpc_manifest_check.gd` uses for wire-signature drift) finds
## every `any_peer` entry point in the project. Each one must appear in exactly one bucket below:
## `RATE_LIMITED` (gated through `RpcRateLimiter`), `SELF_GUARDED` (its own cooldown/in-flight lock),
## or `BOUNDED_O1` (a dictionary lookup, a squared-distance check, a bounds-checked write — no
## unbounded work per call). An entry in none of them is a new handler nobody has triaged yet, and
## fails the check by design — see the failure message for what to do about it.
const ManifestScript = preload("res://core/net/rpc_manifest.gd")

## `BuildService`/`CommandService` — see docs/DECISIONS.md D-141 for why these two, and only these two,
## needed a real throttle rather than relying on their O(1) shape.
const RATE_LIMITED: PackedStringArray = [
	"res://autoload/build_service.gd::net_request_place",
	"res://autoload/build_service.gd::net_request_destroy",
	"res://autoload/command_service.gd::net_submit_command",
]

## Each already bounds its own call rate without `RpcRateLimiter`: `Harvestable` keys a per-peer
## `Time.get_ticks_msec()` cooldown off `definition.request_cooldown_seconds`;
## `CombatService`/`RangedCombatService` allow at most one swing/shot in flight per peer.
const SELF_GUARDED: PackedStringArray = [
	"res://systems/harvesting/harvestable.gd::net_request_hit",
	"res://autoload/combat_service.gd::net_request_attack",
	"res://autoload/ranged_combat_service.gd::net_request_shot",
]

## Real per-call work is a `Dictionary.has()`, a squared-distance check, a bounds-checked array write,
## or (for the connection handshake) work bounded by the connected-peer count — nothing that scales
## with world or entity count. docs/FINDINGS.md's F-233 write-up is the audit record for this bucket.
const BOUNDED_O1: PackedStringArray = [
	"res://systems/loot/chest.gd::net_request_open",
	"res://systems/wellspring/wellspring.gd::net_request_toggle_channel",
	"res://autoload/crafting_service.gd::net_request_craft",
	"res://systems/health/player_health.gd::net_request_consume_item",
	"res://systems/health/player_health.gd::net_request_revive",
	"res://systems/health/player_health.gd::net_report_local_stamina",
	"res://systems/hauling/haulable.gd::net_request_pickup",
	"res://systems/hauling/haulable.gd::net_request_drop",
	"res://systems/building/buildable_door.gd::net_request_toggle",
	"res://systems/extraction/extraction_ship.gd::net_request_repair",
	"res://systems/extraction/extraction_ship.gd::net_request_toggle_departure",
	"res://autoload/net_transport.gd::net_request_display_name",
	"res://autoload/attunement_service.gd::net_request_attunement",
	"res://autoload/inventory_service.gd::net_request_remove",
	"res://autoload/inventory_service.gd::net_request_move_stack",
	"res://core/net/net_session.gd::net_client_hello",
]

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	var entries: PackedStringArray = ManifestScript.scan()
	check(entries.size() > 0, "the scanner found RPCs at all (%d)" % entries.size())
	if entries.is_empty():
		print("\nRPC_SURFACE_AUDIT_CHECK failures=%d" % failures)
		finish()
		return

	var known: Dictionary = {}
	_index(RATE_LIMITED, "RATE_LIMITED", known)
	_index(SELF_GUARDED, "SELF_GUARDED", known)
	_index(BOUNDED_O1, "BOUNDED_O1", known)

	var any_peer_keys: Dictionary = {}
	for entry: String in entries:
		if not entry.contains("|") or not entry.split("|")[1].contains("any_peer"):
			continue
		var key: String = _key_of(entry)
		any_peer_keys[key] = true
		var bucket: String = String(known.get(key, ""))
		check(not bucket.is_empty(),
			"%s is triaged (found in %s)" % [key, bucket if not bucket.is_empty() else "NEITHER — new, unaudited handler"])

	print("\n== every triaged handler still exists ==")
	for key: String in known:
		check(any_peer_keys.has(key), "%s (%s) is still in the project" % [key, known[key]])

	print("\nRPC_SURFACE_AUDIT_CHECK failures=%d" % failures)
	finish()


func _index(list: PackedStringArray, bucket: String, out: Dictionary) -> void:
	for key: String in list:
		if out.has(key):
			push_error("FAIL: %s listed in more than one bucket" % key)
			failures += 1
		out[key] = bucket


## `res://path::func_name(arg,types)|config` -> `res://path::func_name`.
func _key_of(entry: String) -> String:
	var paren: int = entry.find("(")
	return entry.substr(0, paren)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
