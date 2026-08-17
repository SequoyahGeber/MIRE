extends SceneTree

## Deterministic authoring helper for task 2.8's single vertical-slice weapon. Bulk weapon content is
## not a task yet; one authored WeaponDef plus CombatService's code-built unarmed fallback is the
## whole of melee v1. Godot serializes the resource so its typed script reference stays valid.
##
## Tuning task 2.9 edits `content/weapons/stone_axe.tres` in the inspector — not this file. Re-running
## this script overwrites those tuned values, so do not re-run it after 2.9 has touched the resource.

const WEAPON_DEF_SCRIPT := preload("res://systems/combat/weapon_def.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/weapons"))

	var axe: Resource = WEAPON_DEF_SCRIPT.new()
	axe.set("item_id", &"stone_axe")
	axe.set("display_name", "Stone Axe")
	# Heavier and slower than bare hands, and it hits about three times as hard. These are 2.9's
	# starting point, not a tuned answer.
	axe.set("wind_up_seconds", 0.24)
	axe.set("commit_seconds", 0.12)
	axe.set("recovery_seconds", 0.32)
	axe.set("range_m", 2.6)
	axe.set("arc_degrees", 100.0)
	axe.set("vertical_reach_m", 2.4)
	axe.set("damage", 3)
	axe.set("hitstop_seconds", 0.075)
	axe.set("shake_magnitude", 0.12)
	axe.set("shake_duration", 0.22)
	axe.set("impact_audible_range_m", 24.0)
	_save(axe, "res://content/weapons/stone_axe.tres")

	print("COMBAT_CONTENT_SETUP resources=1 failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _save(resource: Resource, path: String) -> void:
	var error: Error = ResourceSaver.save(resource, path)
	if error == OK:
		print("SAVED: %s" % path)
		return
	failures += 1
	push_error("FAILED: %s (%s)" % [path, error_string(error)])
