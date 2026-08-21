extends CanvasLayer

## Client-local door interaction: find the nearest placed door and turn one [E] press into exactly
## one `request_toggle()`.
##
## `systems/building/buildable_door.gd` remains the only authority — this predicts nothing. It
## exists because a system nothing calls is not shipped (F-151, the same week `ui/loot/chest_ui.gd`
## was found orphaned), and because a door with no prompt is a door a player walks past.
##
## **It no longer draws that prompt.** The panel this file used to build was one of two — the other
## lived in `ui/loot/chest_ui.gd`, at a different screen offset, so standing between a door and a
## chest drew two overlapping boxes and a tree drew none at all. Every prompt is now one case of the
## single look-at prompt in `ui/hud/focus_prompt.gd` (F-431). What stays here is the half that was
## always door-specific: which door, and what one press does to it.
##
## Joins nothing: it owns no cursor and blocks no input, so it is NOT part of the D-032
## `blocks_gameplay_input` interlock. It does respect it — while any cursor-owning panel is open,
## [E] belongs to that panel.

const DOOR_GROUP: StringName = &"door"
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"


func _ready() -> void:
	layer = 5
	process_mode = Node.PROCESS_MODE_ALWAYS


func _input(event: InputEvent) -> void:
	if get_viewport().is_input_handled():
		return
	if not event.is_action_pressed(&"interact"):
		return
	var focus_owner: Control = get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit or focus_owner is TextEdit:
		return
	if _blocking_ui_open():
		return
	var door: Node3D = nearest_door()
	if door == null:
		return
	if bool(door.call("request_toggle")):
		get_viewport().set_input_as_handled()


## Nearest door whose own `interact_range_m` the player is actually inside — the door decides its
## reach, so a press can never ask for an interaction the host would refuse.
func nearest_door() -> Node3D:
	var player: Node3D = _local_player()
	if player == null:
		return null
	var best: float = INF
	var nearest: Node3D = null
	for node: Node in get_tree().get_nodes_in_group(DOOR_GROUP):
		var door: Node3D = node as Node3D
		if door == null or not door.is_inside_tree():
			continue
		var reach: float = float(door.get(&"interact_range_m"))
		var distance: float = door.global_position.distance_to(player.global_position)
		if distance <= reach and distance < best:
			best = distance
			nearest = door
	return nearest


func _blocking_ui_open() -> bool:
	for node: Node in get_tree().get_nodes_in_group(BLOCKING_UI_GROUP):
		if node is CanvasItem and (node as CanvasItem).visible:
			return true
		if node.has_method(&"is_open") and bool(node.call(&"is_open")):
			return true
	return false


## The same lookup `ui/loot/chest_ui.gd` uses: the body in `&"players"` this peer has authority
## over. PlayerNet indexes by peer id and has no "which one is mine" accessor, and authority is the
## honest answer in both offline and session play.
func _local_player() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null
