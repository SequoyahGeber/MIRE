extends Node

## RichPresenceService — autoload. Task 8.3: the human-readable Steam rich presence line shown next
## to a friend's name ("status" key) — distinct from the "connect" key `SteamLobby._advertise_joinable()`
## / `_clear_joinable()` already manage, which controls the Join Game button, not the text (F-123/
## F-127 shipped that half already; docs/ROADMAP.md's 8.3 row names this display half as the one
## still open). Register as autoload `RichPresenceService` → res://autoload/rich_presence_service.gd,
## after `SteamLobby`, `NetTransport` and `CycleService` in `project.godot` (F-051 — read by node
## path only, so this only matters in the "already registered" sense).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Achievements, stats, rich presence" row): NONE —
## per-peer local text about THIS process's own play state, the same category Salvage/Unlocks/a
## Steam achievement already sit in. Every peer computes its own string from its own locally-visible
## state; nothing here is replicated and no two peers ever compare presence text.
##
## POLLS `CycleService.current_cycle()` on a 2s timer rather than subscribing to
## `EventBus.subscribe_cycle_advanced()` — written when that event never reached a real connected
## client at all (F-250, `CycleService._announce()`'s emit gated behind a host-only guard). F-250 has
## since fixed the signal itself (`CycleService._on_world_delta_applied()` now re-derives the same
## emit on every peer), so a NEW client-side Cycle consumer no longer needs this workaround — but
## this file's own poll is left as-is rather than swapped, since it already works, needs no upkeep,
## and presence text updating up to 2s after a real advance is not a bug worth a mid-task rewrite of
## working code.
##
## NO SEPARATE "IN THE MENU" STATE. The obvious first design was a menu/in-run state machine
## ("In the menu" vs "In a run — Cycle N", `docs/STEAM.md` §S4's own suggested wording) — dropped
## once `ui/menu/main_menu.gd` and D-110 made it clear no such phase exists in the shipped game:
## `run/main_scene` boots straight into a live `levels/hollowmere.tscn` with a Cycle already ticking
## (`MireGrid._ready()` draws the seed immediately), and `MainMenu` never gates play. Inventing a
## "menu" presence state would describe a boot phase that does not exist rather than the game that
## does, so presence is just "Cycle N" — the true state — with the connected party size appended
## once there is one to report.
##
## Degrades to a clear no-op when GodotSteam is absent or Steam is not running, same contract every
## other Steam-facing file in this codebase promises. `compute_status_text()` is pure and needs no
## Steam at all, so the display logic is fully testable headlessly — see `tools/steam_stats_check.gd`.
##
## DELIBERATELY NEVER CALLS `SteamLobby.initialise()` ITSELF — only publishes through
## `SteamLobby.set_status()` once Steam is ALREADY up (`_initialised` inside that file), same
## opt-in-only posture `_advertise_joinable()`/`_clear_joinable()` already have. The first version of
## this task called `initialise()` eagerly from here so a solo player would still get live presence
## without ever hosting/joining a lobby — reverted the same session: on any machine with a real Steam
## client running (this dev machine included), that turned EVERY headless `agent godot` run project-
## wide into a real `SteamAPI_Init()` call, confirmed by running `tools/salvage_check.gd` before and
## after and diffing the log — the "before" has no Steam client startup lines or ObjectDB-leak
## warnings at exit, the "after" (with eager init) does. A presence-only task is not the place to
## widen how eagerly the whole project talks to a live third-party client; see docs/DECISIONS.md.

const POLL_INTERVAL_SEC: float = 2.0

var _last_text: String = ""
var _poll_accum: float = 0.0


func _ready() -> void:
	_refresh()


func _process(delta: float) -> void:
	_poll_accum += delta
	if _poll_accum < POLL_INTERVAL_SEC:
		return
	_poll_accum = 0.0
	_refresh()


## The text this peer would currently publish. Exposed (and pure — no Steam call, no autoload
## mutation) so `tools/steam_stats_check.gd` can assert the string logic with no Steam client at all.
func compute_status_text() -> String:
	var cycle: int = _current_cycle()
	var party: int = _party_size()
	if party > 1:
		return "Cycle %d · %d players" % [cycle, party]
	return "Cycle %d" % cycle


func _refresh() -> void:
	var text: String = compute_status_text()
	if text == _last_text:
		return
	_last_text = text
	var lobby: Node = get_node_or_null(^"/root/SteamLobby")
	if lobby != null and lobby.has_method(&"set_status"):
		lobby.call("set_status", text)


func _current_cycle() -> int:
	var cycle_service: Node = get_node_or_null(^"/root/CycleService")
	if cycle_service == null or not cycle_service.has_method(&"current_cycle"):
		return 1
	return int(cycle_service.call("current_cycle"))


## `NetTransport.peer_ids()` is empty while offline (never 1 — see its own doc comment), so a solo or
## LOCAL-dev session and an actual lone host both correctly fall through to the plain "Cycle N" line.
func _party_size() -> int:
	var net_transport: Node = get_node_or_null(^"/root/NetTransport")
	if net_transport == null or not net_transport.has_method(&"peer_ids"):
		return 0
	return (net_transport.call("peer_ids") as PackedInt32Array).size()
