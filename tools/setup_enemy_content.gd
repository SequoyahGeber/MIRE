extends SceneTree

## Deterministic authoring helper for task 2.10's single vertical-slice enemy. Bulk enemy content is
## task 5.x; one authored EnemyDef plus A-006's crawler model is the whole of Enemy v1.
##
## Task 2.9 tunes `content/enemies/crawler.tres` in the inspector. Re-running this overwrites those
## values, so do not re-run it afterwards.

const ENEMY_DEF_SCRIPT := preload("res://systems/enemies/enemy_def.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/enemies"))

	var crawler: Resource = ENEMY_DEF_SCRIPT.new()
	crawler.set("id", &"crawler")
	crawler.set("display_name", "Hollow Crawler")
	crawler.set("model", load("res://assets/enemies/exports/enemy_crawler.glb") as PackedScene)
	# A-006 measured it: 1.10 m long, 0.59 m tall, origin at the ground between its feet.
	crawler.set("radius_m", 0.45)
	crawler.set("height_m", 0.6)
	crawler.set("max_health", 12)
	crawler.set("corpse_seconds", 2.5)
	crawler.set("move_speed", 3.4)
	crawler.set("stop_distance_m", 1.5)
	crawler.set("turn_speed_rad", 6.0)
	crawler.set("aggro_radius_m", 18.0)
	crawler.set("deaggro_radius_m", 26.0)
	crawler.set("attack_range_m", 2.0)
	crawler.set("attack_damage", 6)
	# 0.4 s each, matching the authored attack_tell and attack clips. Changing these without
	# re-authoring the clips desynchronises the telegraph from the hit (DESIGN.md §6).
	crawler.set("attack_tell_seconds", 0.4)
	crawler.set("attack_seconds", 0.4)
	crawler.set("attack_recovery_seconds", 0.5)
	_save(crawler, "res://content/enemies/crawler.tres")

	print("ENEMY_CONTENT_SETUP resources=1 failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _save(resource: Resource, path: String) -> void:
	var error: Error = ResourceSaver.save(resource, path)
	if error == OK:
		print("SAVED: %s" % path)
		return
	failures += 1
	push_error("FAILED: %s (%s)" % [path, error_string(error)])
