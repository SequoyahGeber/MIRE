extends SceneTree

## F-281 — THE RUN-SCOPE ENUMERATION TRIPWIRE.
##
## F-281's three items are each fixed (F-268 HaulService, F-277 AttunementService, F-278 DayNight),
## but its TITLE is not about three systems — it is about an enumeration being short. D-149 wrote
## that enumeration as prose ("Only RUN-scoped state resets: Cycle, Mire corruption, Cycle Modifiers,
## inventory, health, enemies, buildables, chest/wellspring/ship progress") and prose does not fail a
## check when the code outgrows it. It went short four separate times — F-259 (WaveSpawner), F-268
## (BuildService, HaulService), F-277 (AttunementService), F-278 (DayNight) — and three of those were
## found TWICE, independently, by two lanes each. That is not bad luck; it is a list nothing verifies.
##
## So this check is the list. Every autoload in `project.godot`, plus the run-scoped nodes that live
## in the level tree instead of an autoload, is classified here as exactly one of:
##
##   RESETS  — it subscribes `EventBus.run_restarted` and this check asserts the subscription is
##             still there. What the handler DOES is asserted by the behavioural checks
##             (`run_restart_check`, `day_night_restart_check`, `attunement_restart_check`,
##             `harvest_restart_check`, `run_restart_spawn_check`, `run_restart_net_check`).
##   a reason — it deliberately does NOT subscribe, and the string IS the recorded reason. This check
##             asserts it still does not subscribe, because a reason that has quietly become false is
##             how F-259 and F-277 both got missed on a first pass.
##
## The tripwire is the classification being TOTAL. A new autoload nobody classified fails this check
## with "classify it in D-178", which is the one moment somebody is actually thinking about whether
## the thing they just wrote is run-scoped. That is the moment F-281's class keeps escaping.
##
## Deliberately source-text scanning, not runtime introspection: `EventBus`'s subscriber list is not
## enumerable at runtime (it is a static Callable registry — `core/events/event_bus.gd`), and a
## runtime probe could only see subscriptions from nodes that happen to be in THIS tree. The failure
## this catches is a file that was written without the subscription at all, which is a source fact.
##
##   .agent/bin/agent godot --script tools/run_scope_audit_check.gd

const PROJECT_PATH: String = "res://project.godot"
const SUBSCRIBE_CALL: String = "subscribe_run_restarted"

## The marker for "this one resets, and the subscription is the assertion".
const RESETS: String = ""

## Every autoload in `project.godot`, classified. Keys are the script paths as `project.godot` spells
## them, minus the `*res://` prefix. Adding an autoload without adding a row here fails this check.
const AUTOLOAD_SCOPE: Dictionary[String, String] = {
	# ── Run-scoped: these are D-149's enumeration, as the code actually has it ────────────────────
	"autoload/attunement_service.gd": RESETS,       # F-277/D-167 — selections are run-scoped
	"autoload/build_service.gd": RESETS,            # F-268 — placed buildables
	"autoload/defeat_service.gd": RESETS,           # F-243 — the defeat latch itself
	"autoload/enemy_world.gd": RESETS,              # F-243 — live enemies
	"autoload/environment_vfx.gd": RESETS,          # dressing tied to the island (see F-303)
	"autoload/harvest_world.gd": RESETS,            # node depletion
	"autoload/haul_service.gd": RESETS,             # F-268/F-281 item 2 — spawned haulables
	"autoload/inventory_service.gd": RESETS,        # F-243 — the run's items
	"autoload/powerup_service.gd": RESETS,          # F-243 — granted stacks
	"systems/cycle/cycle_modifier_service.gd": RESETS,  # F-243 — the drawn stack
	"systems/environment/day_night.gd": RESETS,     # F-278/F-281 item 3 — the clock
	"systems/health/player_health.gd": RESETS,      # F-243/F-279/F-298 — health, respawn, stamina
	"systems/waves/wave_spawner.gd": RESETS,        # F-259 — roster and night latch
	"ui/attunement/attunement_ui.gd": RESETS,       # F-277 — the picker re-arms per run
	"ui/hud/defeat_hud.gd": RESETS,                 # F-243 — the terminal overlay closes
	"ui/hud/extraction_hud.gd": RESETS,             # F-243 — the same overlay, extraction side
	"world/mire/mire_grid.gd": RESETS,              # F-243 — corruption spread

	# ── Deliberately NOT run-scoped. The string is the reason, and it is asserted. ────────────────
	"systems/cycle/cycle_service.gd":
		"emitter — host_restart_run() resets the Cycle and then EMITS run_restarted; it cannot subscribe to its own emit",
	"core/game_state.gd":
		"the restart path WRITES run_seed rather than clearing it — D-161 draws a fresh seed per run",
	"autoload/world_delta_log.gd":
		"derived — _reseed_local() clears _state, and D-161 makes every restart draw a fresh seed",
	"autoload/crafting_service.gd":
		"derived — F-286/D-170: the cache key folds EventBus.world_generation(), a pull seam, not a subscription",
	"autoload/salvage_service.gd":
		"self-clearing — _wellsprings_capped_this_run resets at bank time; run_restart_check asserts it",
	"autoload/reward_service.gd":
		"self-clearing — _next_reward_event_id is a monotonic id counter, not run state",
	"autoload/entity_directory.gd":
		"self-clearing — snapshot() prunes dead instance ids every call; _serials is monotonic per boot by design",
	"autoload/combat_service.gd":
		"self-clearing — local swing phase and _host_swings entries expire within one swing",
	"autoload/ranged_combat_service.gd":
		"self-clearing — shot phase and _flight_visuals expire when the projectile lands",
	"autoload/boss_music_director.gd":
		"self-clearing — _streams is a load cache and the cues are ~7 s non-looping one-shots",
	"autoload/chest_placement_service.gd":
		"self-clearing — _refresh_scheduled transient only; the Chest node owns the run-scoped half",
	"autoload/wellspring_service.gd":
		"self-clearing — _refresh_scheduled transient only; the Wellspring node owns the run-scoped half",
	"autoload/extraction_service.gd":
		"self-clearing — _refresh_scheduled transient only; ExtractionShip owns the run-scoped half",
	"autoload/rich_presence_service.gd":
		"derived — compute_status_text() reads CycleService per call (D-149's last third)",
	"autoload/unlock_service.gd":
		"session-scoped BY DESIGN — meta-progression must survive a run, that is what it is for",
	"autoload/steam_stats.gd": "session-scoped — lifetime stats and achievements, meta not run",
	"autoload/rule_service.gd":
		"session-scoped — _values are operator knobs set via the `rule` console verb; a host who sets one wants it to hold",
	"autoload/god_mode_service.gd":
		"session-scoped — an operator playtest toggle intentionally holds across run restarts and clears when the process/session ends",
	"autoload/settings_service.gd": "session-scoped — user settings",
	"autoload/graphics_quality.gd": "session-scoped — user settings",
	"autoload/net_transport.gd": "session-scoped — the session outlives the run",
	"core/net/net_session.gd": "session-scoped — the session outlives the run",
	"autoload/steam_lobby.gd": "session-scoped — the lobby outlives the run",
	"autoload/player_net.gd":
		"session-scoped — peers, slots and the spawner are per-SESSION; the per-run half is PlayerHealth's (F-279, F-298)",
	"autoload/net_interp.gd": "session-scoped — smoothing state for live peers",
	"autoload/run_record.gd": RESETS,               # F-328 — `_pending` is a half-built record
	"autoload/registry.gd": "boot-time — content defs, immutable after load",
	"autoload/command_service.gd": "boot-time — the command registry",
	"autoload/debug_console.gd": "no run state — debug chrome",
	"autoload/debug_overlay.gd": "no run state — debug chrome",
	"ui/debug/net_debug_panel.gd": "no run state — debug chrome",
	"core/dev/dev_frame_cap.gd": "no run state — dev harness",
	"core/dev/dev_launch.gd": "no run state — dev harness",
	"core/dev/dev_loadout.gd":
		"KNOWN GAP, filed as F-300 — _granted is boot-only, so the autoexec loadout survives exactly one run",
	"ui/hud/vitals_hud.gd": "derived — reads PlayerHealth every frame",
	"ui/hud/boss_health_hud.gd": "derived — follows boss_engaged/boss_defeated",
	"ui/hud/wellspring_hud.gd": "derived — reads the Wellspring node",
	"ui/inventory/inventory_ui.gd": "derived — reads InventoryService",
	"ui/crafting/crafting_ui.gd": "derived — reads CraftingService",
	"ui/loot/chest_ui.gd": "derived — reads the Chest node",
	"ui/building/door_prompt.gd": "derived — reads the door it is aimed at",
	"ui/hud/focus_prompt.gd":
		"derived — every frame it re-targets from the camera and re-reads the prop it lands on; it caches nothing across a poll, let alone across a run",
	"ui/lobby/lobby_menu.gd": "session-scoped — lobby chrome",
	"ui/menu/main_menu.gd": "session-scoped — menu chrome",
	"ui/menu/unlock_menu.gd": "session-scoped — meta chrome, reads UnlockService",
	"ui/menu_stack.gd":
		"session-scoped — navigation chrome (MENU-2). Its state is the stack of screens the PLAYER opened; a run boundary does not make an open Settings screen wrong, and screens that do care pop themselves",
	"ui/menu/pause_menu.gd":
		"session-scoped — menu chrome (MENU-5). Its only state is `_screen`, cleared by that screen's own `tree_exited`, so it cannot outlive what it points at",
}

## Run-scoped state that is NOT an autoload. D-149 chose per-node `host_reset_for_new_run()` over a
## scene reload for exactly these, so they are half of its enumeration and none of them would be
## caught by an autoload sweep — which is how the autoload-only sweep habit stays honest.
const SCENE_SCOPE: Array[String] = [
	"systems/loot/chest.gd",                 # D-149 — chest progress
	"systems/wellspring/wellspring.gd",      # D-149 — wellspring progress
	"systems/extraction/extraction_ship.gd", # D-149 — ship repair progress
	"world/gen/procedural_world.gd",         # F-258/D-161 — the island itself
	"world/gen/resource_scatter_field.gd",   # depletion memory
]

var failures: int = 0


func _init() -> void:
	print("\n== RUN-SCOPE ENUMERATION AUDIT (F-281) ==\n")

	var declared: Array[String] = _declared_autoloads()
	if declared.is_empty():
		_fail("could not read the [autoload] section of %s at all" % PROJECT_PATH)
		_finish()
		return
	print("read %d autoload(s) from project.godot" % declared.size())

	_check_totality(declared)
	_check_autoload_classifications(declared)
	_check_scene_scope()

	_finish()


# ── The three assertions ─────────────────────────────────────────────────────────────────────────


## The tripwire proper: the classification must cover project.godot exactly, in both directions.
func _check_totality(declared: Array[String]) -> void:
	var before: int = failures
	for path: String in declared:
		if not AUTOLOAD_SCOPE.has(path):
			_fail((
				"autoload '%s' is not classified. Decide whether its state is RUN-scoped: if it is, "
				+ "subscribe EventBus.run_restarted and add it here as RESETS; if it is not, add it "
				+ "here with the reason. Record the call in D-178."
			) % path)
	for path: String in AUTOLOAD_SCOPE:
		if not declared.has(path):
			_fail((
				"'%s' is classified here but is no longer an autoload in project.godot — remove the "
				+ "row, or the enumeration is describing a file nothing loads."
			) % path)
	if failures == before:
		print("PASS: the classification covers project.godot's autoloads exactly (%d)" % declared.size())


## Every RESETS row still subscribes; every reasoned row still does not.
func _check_autoload_classifications(declared: Array[String]) -> void:
	var before: int = failures
	var resets: int = 0
	var reasoned: int = 0
	for path: String in declared:
		if not AUTOLOAD_SCOPE.has(path):
			continue
		var reason: String = AUTOLOAD_SCOPE[path]
		var subscribes: bool = _subscribes(path)
		if reason == RESETS:
			resets += 1
			if not subscribes:
				_fail((
					"'%s' is classified RUN-scoped but no longer calls %s — a reset the enumeration "
					+ "claims is happening is not happening."
				) % [path, SUBSCRIBE_CALL])
		else:
			reasoned += 1
			if subscribes:
				_fail((
					"'%s' now calls %s, but is classified as not run-scoped ('%s'). The reason is "
					+ "stale — reclassify it as RESETS."
				) % [path, SUBSCRIBE_CALL, reason])
			elif reason.strip_edges().is_empty():
				_fail("'%s' has an empty reason — say WHY it is not run-scoped" % path)
	if failures == before:
		print("PASS: %d autoload(s) reset on run_restarted, all still subscribed" % resets)
		print("PASS: %d autoload(s) deliberately do not, each with a reason that is still true" % reasoned)


## The level-tree half of D-149's enumeration.
func _check_scene_scope() -> void:
	var before: int = failures
	for path: String in SCENE_SCOPE:
		if not _exists(path):
			_fail("'%s' is enumerated as run-scoped but no longer exists" % path)
		elif not _subscribes(path):
			_fail((
				"'%s' is run-scoped state outside an autoload and no longer calls %s — an autoload "
				+ "sweep cannot see this one, which is why it is listed separately."
			) % [path, SUBSCRIBE_CALL])
	if failures == before:
		print("PASS: %d non-autoload run-scoped node(s) still reset" % SCENE_SCOPE.size())


# ── Reading the source ───────────────────────────────────────────────────────────────────────────


## `project.godot`'s [autoload] section, as bare `res://`-less script paths. Parsed by hand rather
## than with ConfigFile because the values carry the `*` singleton-enable prefix and ConfigFile hands
## them back as one opaque string anyway — and a headless SceneTree has no ProjectSettings listing
## that separates autoloads from every other setting cleanly.
func _declared_autoloads() -> Array[String]:
	var out: Array[String] = []
	var text: String = _read(PROJECT_PATH)
	if text.is_empty():
		return out
	var in_section: bool = false
	for raw_line: String in text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.begins_with("["):
			in_section = line == "[autoload]"
			continue
		if not in_section or line.is_empty() or line.begins_with(";"):
			continue
		var equals: int = line.find("=")
		if equals < 0:
			continue
		var value: String = line.substr(equals + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
		var path: String = value.trim_prefix("*")
		if not path.begins_with("res://"):
			continue
		out.append(path.trim_prefix("res://"))
	return out


func _subscribes(path: String) -> bool:
	return _read("res://" + path).contains(SUBSCRIBE_CALL)


func _exists(path: String) -> bool:
	return FileAccess.file_exists("res://" + path)


func _read(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text


# ── Reporting ────────────────────────────────────────────────────────────────────────────────────


func _fail(message: String) -> void:
	failures += 1
	print("FAIL: %s" % message)


func _finish() -> void:
	print("\nRUN_SCOPE_AUDIT_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)
