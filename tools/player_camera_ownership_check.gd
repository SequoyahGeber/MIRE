extends SceneTree

## F-529: a replicated remote/rejoining Player must never enter a viewport with its camera already
## current. PlayerController activates only the locally-owned camera in _ready(); the scene default
## therefore has to be false.

const PLAYER_SCENE: PackedScene = preload("res://entities/player/player.tscn")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var first: Node = PLAYER_SCENE.instantiate()
	var rejoin: Node = PLAYER_SCENE.instantiate()
	var first_camera := first.get_node_or_null(^"CameraPivot/Camera3D") as Camera3D
	var rejoin_camera := rejoin.get_node_or_null(^"CameraPivot/Camera3D") as Camera3D
	check(first_camera != null and not first_camera.current,
		"a player scene enters the tree with camera ownership inactive")
	check(rejoin_camera != null and not rejoin_camera.current,
		"a second/rejoining player cannot steal the viewport from its scene default")
	first.free()
	rejoin.free()
	print("PLAYER_CAMERA_OWNERSHIP_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
