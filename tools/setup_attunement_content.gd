extends SceneTree

## Deterministic authoring helper for task 3.9's four Attunements (DESIGN.md §4.5's fixed roster —
## not an open content pool, so all four ship here rather than one worked example plus Sequoyah's
## authoring; see D-070 in docs/DECISIONS.md). Godot serializes these resources so typed fields and
## subresources stay valid, same reasoning as setup_station_content.gd / setup_haul_content.gd.
##
## Each Attunement is a thin AttunementDef pointing at ONE backing PowerupDef
## (content/powerups/attunement_<role>.tres, max_stacks 1, no §4.4 tags — an Attunement is not part
## of the Resonance system) that carries the stat-shaped half of DESIGN §4.5's table. The magnitudes
## below are placeholder-tuned, like every other 3.x worked example's numbers — Sequoyah retunes them
## in the inspector; the qualitative, non-stat halves of each role (taunts, Ward turrets, terrain
## sight, the Ward build lockout) are out of scope per D-070 and not represented here at all.
##
## RE-RUNNING OVERWRITES all eight files below. Do not re-run once tuning has started.

const POWERUP_DEF_SCRIPT := preload("res://systems/powerups/powerup_def.gd")
const ATTUNEMENT_DEF_SCRIPT := preload("res://systems/attunement/attunement_def.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/powerups"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/attunements"))

	_make(
		&"warden", "Warden",
		"Better at: ward radius, structure HP, taunts. Worse at: movement speed, gather rate.",
		{
			&"ward_radius_m": Vector2(2.0, 0.0),
			&"move_speed": Vector2(0.0, -0.10),
			&"harvest_yield": Vector2(0.0, -0.15),
		}
	)
	_make(
		&"forager", "Forager",
		"Better at: gather yield & speed, food, sees resources through terrain. Worse at: melee damage.",
		{
			&"harvest_yield": Vector2(0.0, 0.25),
			&"food_value": Vector2(0.0, 0.20),
			&"melee_damage": Vector2(0.0, -0.15),
		}
	)
	_make(
		&"tinker", "Tinker",
		"Better at: craft cost, station tiers, can build Ward turrets. Worse at: health pool.",
		{
			&"craft_seconds": Vector2(0.0, -0.20),
			&"max_hp": Vector2(0.0, -0.15),
		}
	)
	_make(
		&"reaver", "Reaver",
		"Better at: melee/ranged damage, coin drops. Worse at: takes Blight faster, can't build Wards.",
		{
			&"melee_damage": Vector2(0.0, 0.15),
			&"bow_damage": Vector2(0.0, 0.15),
			&"coin_gain": Vector2(0.0, 0.15),
			&"blight_rate": Vector2(0.0, 0.20),
		}
	)

	print("ATTUNEMENT_CONTENT_SETUP resources=8 failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _make(role_id: StringName, display_name: String, description: String, modifiers: Dictionary) -> void:
	var powerup_id := StringName("attunement_%s" % role_id)

	var powerup: Resource = POWERUP_DEF_SCRIPT.new()
	powerup.set("id", powerup_id)
	powerup.set("display_name", "%s Attunement" % display_name)
	powerup.set("description", description)
	powerup.set("tags", [] as Array[StringName])  # not part of the §4.4 Resonance system
	powerup.set("max_stacks", 1)
	var typed_modifiers: Dictionary[StringName, Vector2] = {}
	for stat_name: Variant in modifiers:
		typed_modifiers[stat_name as StringName] = modifiers[stat_name] as Vector2
	powerup.set("modifiers", typed_modifiers)
	_save(powerup, "res://content/powerups/attunement_%s.tres" % role_id)

	var attunement: Resource = ATTUNEMENT_DEF_SCRIPT.new()
	attunement.set("id", role_id)
	attunement.set("display_name", display_name)
	attunement.set("description", "One of DESIGN.md §4.5's four run-scoped roles.")
	var parts: PackedStringArray = description.split(". Worse at: ")
	attunement.set("better_at", parts[0].trim_prefix("Better at: "))
	attunement.set("worse_at", (parts[1] if parts.size() > 1 else "").trim_suffix("."))
	attunement.set("granted_powerup_id", powerup_id)
	_save(attunement, "res://content/attunements/%s.tres" % role_id)


func _save(resource: Resource, path: String) -> void:
	var error: Error = ResourceSaver.save(resource, path)
	if error == OK:
		print("SAVED: %s" % path)
		return
	failures += 1
	push_error("FAILED: %s (%s)" % [path, error_string(error)])
