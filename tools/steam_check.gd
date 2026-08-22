extends SceneTree

## Smoke test for the GodotSteam GDExtension (task 1.1). Proves the extension actually loaded into
## stock Godot, that the classes M1 depends on exist, and — if the Steam client is running — that
## Steamworks initialises against App ID 480 (Spacewar).
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/steam_check.gd
##
## Run this after any Godot or GodotSteam version change. R5 in ARCHITECTURE.md §9 is exactly the
## failure this catches: the engine updates, the extension silently stops loading, and the first
## symptom is a confusing Steam bug three tasks later.
##
## Exits non-zero on failure. Initialising while the Steam client is running briefly shows you as
## playing Spacewar — that is the test working, not a mistake.

## The engine is pinned (D-001, D-022). GodotSteam breaking on a point release is risk R5, and it
## presents as a confusing Steam bug rather than an obvious version error — so an unplanned engine
## change should fail here, loudly, before it costs a debugging session. Upgrading means: change this
## line deliberately, re-run this check, update D-022.
const PINNED_ENGINE: String = "4.7.1.stable.official"

var _failures: int = 0


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _initialize() -> void:
	print("\n-- engine --")
	var info: Dictionary = Engine.get_version_info()
	var build: String = "%d.%d.%d.%s.%s" % [info.get("major", 0), info.get("minor", 0),
		info.get("patch", 0), info.get("status", "?"), info.get("build", "?")]
	_check("engine pinned at %s" % PINNED_ENGINE, build == PINNED_ENGINE,
		"running %s — if this upgrade was deliberate, update PINNED_ENGINE and D-022" % build)
	print("  build hash %s" % str(info.get("hash", "?")).substr(0, 9))

	print("\n-- extension loaded --")
	var has_steam: bool = ClassDB.class_exists("Steam")
	_check("Steam class registered", has_steam, "the .gdextension did not load")
	# SteamMultiplayerPeer is what NetTransport's STEAM mode plugs into (task 1.4). If it is missing,
	# the extension loaded but this build cannot carry our multiplayer — worth failing loudly now
	# rather than discovering it mid-1.4.
	_check("SteamMultiplayerPeer class registered", ClassDB.class_exists("SteamMultiplayerPeer"),
		"STEAM transport for task 1.4 has no peer class")

	if not has_steam:
		_finish()
		return

	print("  API surface: %d methods, %d constants"
		% [ClassDB.class_get_method_list("Steam", true).size(),
			ClassDB.class_get_integer_constant_list("Steam", true).size()])

	print("\n-- steamworks init (App ID 480) --")
	_verify_init()
	_finish()


func _verify_init() -> void:
	var steam: Object = Engine.get_singleton("Steam")
	if steam == null:
		_check("Steam singleton available", false, "class exists but no singleton")
		return

	if not steam.has_method("steamInitEx"):
		_check("steamInitEx present", false, "API changed — check the GodotSteam version")
		return

	# app_id 0 means "read steam_appid.txt", which this repo pins to NetConfig.STEAM_APP_ID — 480
	# (Spacewar) until task 8.2 swaps it, per STEAM.md §2. tools/steam/apply_ids.sh writes both, so
	# they agree by construction; the getAppID() assertion below is what notices if they ever don't.
	var result: Dictionary = steam.steamInitEx()
	var status: int = int(result.get("status", -1))
	var verbal: String = str(result.get("verbal", "no message"))
	# 0 is STEAM_API_INIT_RESULT_OK across GodotSteam 4.x.
	_check("steamInitEx() succeeded", status == 0, "status %d — %s" % [status, verbal])

	if status != 0:
		print("  note: this fails when the Steam client is not running. Start Steam and re-run.")
		return

	print("  %s" % verbal)
	if steam.has_method("isSteamRunning"):
		_check("client reports running", bool(steam.isSteamRunning()))
	if steam.has_method("getSteamID"):
		var id: int = int(steam.getSteamID())
		_check("logged in (SteamID resolved)", id != 0, "SteamID 0 means no active user")
		if id != 0 and steam.has_method("getPersonaName"):
			print("  signed in as %s (%d)" % [str(steam.getPersonaName()), id])
	if steam.has_method("getAppID"):
		var app_id: int = int(steam.getAppID())
		# Asserting agreement with NetConfig rather than a hardcoded 480: the literal would have to
		# be edited again at task 8.2 (and would fail loudly and uselessly until someone did),
		# whereas this stays a real claim — the dev-run App ID matches the runtime one (F-257).
		var expected_app_id: int = NetConfig.STEAM_APP_ID
		_check(
			"running as App ID %d (steam_appid.txt agrees with NetConfig)" % expected_app_id,
			app_id == expected_app_id,
			"got %d, NetConfig.STEAM_APP_ID is %d — steam_appid.txt and core/net/net_config.gd have drifted; run tools/steam/apply_ids.sh, which writes both" % [app_id, expected_app_id]
		)

	if steam.has_method("steamShutdown"):
		steam.steamShutdown()


func _finish() -> void:
	print("")
	if _failures == 0:
		print("all checks passed")
	else:
		print("%d check(s) failed" % _failures)
	# `failures=N`, not "%d check(s) failed" — F-562. `_verify_verdict()` in `.agent/bin/agent`
	# reads a verdict with `failures\s*=\s*(\d+)` or `\b(\d+)\s+failures?\b`, and
	# "0 check(s) failed" matches NEITHER: the word "check(s)" sits between the number and the
	# failure noun, exactly as "functional" did in chunk_stream_check. So this check reported
	# "missing failures verdict" and went red however green it ran. The human line stays because it
	# is what a person reading the log wants.
	#
	# WHEN STEAM IS NOT RUNNING this verdict is deliberately non-zero rather than green. The
	# `steamInitEx() succeeded` assertion above already counts that as a failure, and that is the
	# honest answer: a run without a Steam client proves nothing about Steam, and "could not verify"
	# must not be indistinguishable from "verified". Same judgement as the headless bails under
	# F-555/F-556. The `note:` line above says which of the two happened, so a reader is never left
	# guessing whether the extension is broken or the client is simply closed.
	print("STEAM_CHECK failures=%d" % _failures)
	quit(1 if _failures > 0 else 0)
