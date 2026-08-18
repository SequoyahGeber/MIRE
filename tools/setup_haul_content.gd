extends SceneTree

## Deterministic authoring helper for task 3.10's worked example — same shape and same reasoning as
## tools/setup_station_content.gd: Godot serializes the resource so typed fields stay valid, rather
## than hand-writing .tres text. `scene` is deliberately left unset — no haulable art exists yet
## (task 3.7's split for buildables applies here too: content/buildables/wall.tres ships the same
## way), so HaulService's generated AnimatableBody3D placeholder is what actually spawns until art
## exists. Sequoyah authors the rest of the family by hand (AGENTS.md: never bulk-generate content).
##
## RE-RUNNING OVERWRITES content/haulables/heavy_ore_crate.tres. Do not re-run once tuning has
## started (pickup_range_m, carry_track_speed_mps, solo_drag_multiplier are inspector-tunable after
## this).

const HAULABLE_DEF_SCRIPT := preload("res://systems/hauling/haulable_def.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/haulables"))

	# DESIGN.md §4.5: "high-tier ore requires 2 players to carry" — the worked example this task's
	# framework is proven against.
	var crate: Resource = HAULABLE_DEF_SCRIPT.new()
	crate.set("id", &"heavy_ore_crate")
	crate.set("display_name", "Heavy Ore Crate")
	crate.set("size", Vector3(1.0, 1.0, 1.5))
	crate.set("pickup_range_m", 2.5)
	crate.set("carry_track_speed_mps", 4.0)
	crate.set("solo_drag_multiplier", 0.4)
	_save(crate, "res://content/haulables/heavy_ore_crate.tres")

	print("HAUL_CONTENT_SETUP resources=1 failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _save(resource: Resource, path: String) -> void:
	var error: Error = ResourceSaver.save(resource, path)
	if error == OK:
		print("SAVED: %s" % path)
		return
	failures += 1
	push_error("FAILED: %s (%s)" % [path, error_string(error)])
