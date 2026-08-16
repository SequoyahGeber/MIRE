extends SceneTree

## Headless structural proof for the runtime-generated playtest map.

const MAP_SCRIPT: Script = preload("res://world/gen/test_map_props.gd")
const GREYBOX_SCENE: String = "res://levels/greybox_test.tscn"
const EXPECTED_ZONES := [
	"SpawnCamp",
	"WestForest",
	"NorthRuins",
	"EastMire",
	"SouthRidge",
	"RoutesAndBoundary",
]

var _failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(GREYBOX_SCENE) as PackedScene
	_check(packed != null, "greybox scene loads")
	if packed == null:
		quit(1)
		return

	var scene := packed.instantiate() as Node3D
	_check(scene != null, "greybox scene instantiates as Node3D")
	if scene == null:
		quit(1)
		return
	root.add_child(scene)
	current_scene = scene

	# The project autoload ran before this script installed a current scene, so add a scoped builder.
	var builder := MAP_SCRIPT.new() as Node
	root.add_child(builder)
	for _frame: int in 12:
		await process_frame

	var map_root := scene.get_node_or_null(^"PlaytestMap") as Node3D
	_check(map_root != null, "PlaytestMap root exists")
	if map_root == null:
		_finish()
		return

	for zone_name: String in EXPECTED_ZONES:
		_check(map_root.get_node_or_null(NodePath(zone_name)) != null, "zone exists: %s" % zone_name)

	var assets: Array[Node] = get_nodes_in_group(&"playtest_asset")
	var visuals: Array[Node] = get_nodes_in_group(&"playtest_visual")
	var colliders: Array[Node] = get_nodes_in_group(&"playtest_collider")
	var zones: Array[Node] = get_nodes_in_group(&"playtest_zone")
	_check(assets.size() >= 150, "at least 150 placed asset instances (%d)" % assets.size())
	_check(visuals.size() == assets.size(), "every placed asset has a visual (%d)" % visuals.size())
	_check(colliders.size() >= 80, "at least 80 collision shapes (%d)" % colliders.size())
	_check(zones.size() == 6, "exactly 6 map zones (%d)" % zones.size())

	for old_name: String in ["Ramps", "Stairs", "Gaps", "Walls"]:
		_check(scene.get_node_or_null(NodePath(old_name)) == null, "old greybox group removed: %s" % old_name)

	var ground_mesh := scene.get_node_or_null(^"Ground/Mesh") as MeshInstance3D
	_check(ground_mesh != null and ground_mesh.material_override != null, "ground received map material")
	_check(scene.get_node_or_null(^"Player") != null, "player remains in the map")
	print(
		"PLAYTEST_MAP_SUMMARY zones=%d assets=%d visuals=%d colliders=%d failures=%d"
		% [zones.size(), assets.size(), visuals.size(), colliders.size(), _failures]
	)
	_finish()


func _check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	_failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	var exit_code: int = 0 if _failures == 0 else 1
	quit(exit_code)
