extends SceneTree

## Headless verification for asset batch A-006 (docs/ASSET_TRACKER.md).
##
## Run with:
##   Godot --headless --path . --script tools/enemy_crawler_check.gd
##
## Checks what only Godot can answer: that the imported crawler still has a
## skeleton with every bone, an AnimationPlayer holding all six clips, and that
## the two clips whose names end in "-loop" actually came back with a looping
## loop_mode while the other four did not. The exporter-side checks (skin
## weights, clip durations, catalog agreement) live in the batch's Python
## validation; this is the half that depends on Godot's import pipeline.

const EXPORTS := "res://assets/enemies/exports/"

const EXPECTED_STATIC := [
	"enemy_crawler_nest",
	"enemy_crawler_fragment_shell",
	"enemy_crawler_fragment_leg",
]

## Godot 4 turns the "-loop" name suffix into a looping animation on import AND
## CONSUMES THE SUFFIX: the GLB ships "idle-loop", the imported scene holds
## "idle". Gameplay must therefore ask the AnimationPlayer for "idle", never for
## the exported name — which is the whole reason this check exists rather than
## trusting the exporter's clip list.
##
## Anything not listed as looping must play once. A looping death clip is a
## corpse that keeps twitching.
const EXPECTED_CLIPS := {
	"idle": true,
	"locomotion": true,
	"attack_tell": false,
	"attack": false,
	"hit": false,
	"death": false,
}

const EXPECTED_BONES := 17

var _failures: int = 0


func _fail(message: String) -> void:
	_failures += 1
	printerr("  FAIL  %s" % message)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok    %s" % message)
	else:
		_fail(message)


func _find_node(root: Node, type: String) -> Node:
	if root.get_class() == type:
		return root
	for child in root.get_children():
		var found := _find_node(child, type)
		if found != null:
			return found
	return null


func _initialize() -> void:
	print("A-006 enemy set — imported-scene check")

	var crawler_scene := load(EXPORTS + "enemy_crawler.glb") as PackedScene
	if crawler_scene == null:
		_fail("enemy_crawler.glb did not import as a PackedScene")
		_finish()
		return
	var crawler := crawler_scene.instantiate()

	var skeleton := _find_node(crawler, "Skeleton3D") as Skeleton3D
	if skeleton == null:
		_fail("no Skeleton3D — the crawler imported unrigged")
	else:
		_check(skeleton.get_bone_count() == EXPECTED_BONES,
			"skeleton has %d bones (expected %d)" % [skeleton.get_bone_count(), EXPECTED_BONES])

	var mesh_instance := _find_node(crawler, "MeshInstance3D") as MeshInstance3D
	if mesh_instance == null:
		_fail("no MeshInstance3D in the imported crawler")
	else:
		_check(mesh_instance.skin != null, "mesh is skinned to the skeleton")
		var mesh := mesh_instance.mesh
		_check(mesh != null and mesh.get_surface_count() > 0,
			"mesh has %d surfaces" % [0 if mesh == null else mesh.get_surface_count()])

	var player := _find_node(crawler, "AnimationPlayer") as AnimationPlayer
	if player == null:
		_fail("no AnimationPlayer — the clips did not survive import")
	else:
		var names := player.get_animation_list()
		for clip_name: String in EXPECTED_CLIPS:
			if not names.has(clip_name):
				_fail("missing clip '%s'" % clip_name)
				continue
			var animation := player.get_animation(clip_name)
			var should_loop: bool = EXPECTED_CLIPS[clip_name]
			var loops := animation.loop_mode != Animation.LOOP_NONE
			var length_ok := animation.length > 0.0
			_check(loops == should_loop and length_ok,
				"clip '%s' length %.2fs loop=%s (expected loop=%s)"
					% [clip_name, animation.length, loops, should_loop])
		for extra: String in names:
			if not EXPECTED_CLIPS.has(extra):
				_fail("unexpected extra clip '%s'" % extra)

	crawler.free()

	for static_name: String in EXPECTED_STATIC:
		var scene := load(EXPORTS + static_name + ".glb") as PackedScene
		if scene == null:
			_fail("%s.glb did not import as a PackedScene" % static_name)
			continue
		var instance := scene.instantiate()
		var mesh_node := _find_node(instance, "MeshInstance3D") as MeshInstance3D
		var has_mesh := mesh_node != null and mesh_node.mesh != null
		var has_rig := _find_node(instance, "Skeleton3D") != null
		var has_player := _find_node(instance, "AnimationPlayer") != null
		_check(has_mesh and not has_rig and not has_player,
			"%s imports as a static mesh" % static_name)
		instance.free()

	_finish()


func _finish() -> void:
	if _failures == 0:
		print("A-006 check PASSED")
	else:
		printerr("A-006 check FAILED with %d problem(s)" % _failures)
	# `agent verify` reads this line and fails the check outright when it is absent — an explicit,
	# greppable verdict is what stops a half-finished or crashed run passing by saying nothing
	# (F-293). This check reported in prose but never in that shape, so it was red however green
	# it ran (F-555).
	print("ENEMY_CRAWLER_CHECK failures=%d" % _failures)
	quit(1 if _failures > 0 else 0)
