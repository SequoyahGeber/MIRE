extends SceneTree

## F-013 — every MultiplayerSynchronizer this project builds joins NetConfig.SYNCED_GROUP, so the
## net debug panel's synced-entity line counts senders instead of reading 0.
##
## Checks the two construction sites that exist today (PlayerController, DummyReplicant) by building
## each one for real and reading the tree back, rather than grepping for the call — a synchronizer
## added to a group AFTER it enters the tree, or on a node that is never actually added, would pass
## a grep and fail here.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/synced_group_check.gd
##
## Exits non-zero on failure.

var _failures: int = 0
var _player: Node
var _dummy: Node
var _dummy_script: GDScript


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _initialize() -> void:
	# load() at runtime, not preload at class scope: autoloads are not compile-time identifiers in a
	# --script main loop (F-011), and both scripts below reference NetConfig.
	_player = load("res://entities/player/player.tscn").instantiate()
	# Named for a peer id, which is what makes PlayerController adopt spawn authority the same way a
	# real spawn does. Authority must be settled before the node enters the tree (F-012).
	_player.name = "1"
	root.add_child(_player)

	# No class_name on dummy_replicant.gd (it is spike-only), so its constants are read off the
	# script object rather than a global identifier.
	_dummy_script = load("res://core/net/dummy_replicant.gd")
	_dummy = _dummy_script.new()
	_dummy.configure(0, 1)
	root.add_child(_dummy)

	# Both synchronizers are built in _ready(), which runs off the deferred queue — nothing is in the
	# tree yet at this point. Hand control back and check on the next frame.
	call_deferred(&"_after_ready")


func _after_ready() -> void:
	print("\n-- player synchronizer --")
	var player_sync: Node = _player.get_node_or_null(NodePath(NetConfig.PLAYER_SYNC_NODE))
	_check("player built a synchronizer", player_sync != null)
	if player_sync != null:
		_check("player synchronizer is in the group",
			player_sync.is_in_group(NetConfig.SYNCED_GROUP))

	print("\n-- dummy replicant synchronizer --")
	var dummy_sync: Node = _dummy.get_node_or_null(NodePath(_dummy_script.SYNC_NODE_NAME))
	_check("dummy built a synchronizer", dummy_sync != null)
	if dummy_sync != null:
		_check("dummy synchronizer is in the group",
			dummy_sync.is_in_group(NetConfig.SYNCED_GROUP))

	print("\n-- what the panel would read --")
	# The same call DebugOverlay.track_group() makes for its count line.
	var counted: int = get_nodes_in_group(NetConfig.SYNCED_GROUP).size()
	_check("group counts both synchronizers", counted == 2, "counted %d" % counted)

	print("")
	if _failures == 0:
		print("PASS — synced group populated at every construction site")
	else:
		print("FAIL — %d check(s) failed" % _failures)
	quit(0 if _failures == 0 else 1)
