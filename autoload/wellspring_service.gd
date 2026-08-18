extends Node

## Runtime bridge between an authored map's `objective` marker and task 4.8's Wellspring component.
## Same split `autoload/harvest_world.gd` uses for harvestable holders: the map's deterministic
## layout builder (`world/gen/authored_world.gd`) drops a marker, this bridge discovers it after
## scene construction and builds the live gameplay node there. No map layout needs a
## gameplay-specific edit.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none of its own — this runs identically on every
## peer so the Wellspring node (and its RPC/synchronizer paths) land in the same place everywhere.
## Wellspring itself owns the ritual's actual authority.

const WELLSPRING_SCRIPT := preload("res://systems/wellspring/wellspring.gd")

## `authored_world.gd` publishes `authored_world_marker` with meta `kind == "objective"` for every
## Wellspring the layout places (currently one, Hollowmere's `objective` marker). Playtest Hollow
## has no equivalent marker kind — it predates POI placement (task 4.7) and is deprecated for new
## content per DELEGATION.md's Hollowmere note, so it gets no Wellspring.
const MARKER_GROUP: StringName = &"authored_world_marker"
const OBJECTIVE_KIND: String = "objective"
const BUILT_META: StringName = &"mire_wellspring_built"

var _refresh_scheduled: bool = false


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	_schedule_refresh()


func refresh_current_scene() -> void:
	_refresh_scheduled = false
	for node: Node in get_tree().get_nodes_in_group(MARKER_GROUP):
		_maybe_build(node as Node3D)


## Only a marker entering the tree warrants a rescan — same filter `harvest_world.gd` uses and for
## the same reason (F-099): without it, every node the game ever adds schedules a full group scan.
func _on_node_added(node: Node) -> void:
	if node.is_in_group(MARKER_GROUP):
		_schedule_refresh()


func _schedule_refresh() -> void:
	if _refresh_scheduled:
		return
	_refresh_scheduled = true
	call_deferred("refresh_current_scene")


func _maybe_build(marker: Node3D) -> void:
	if marker == null or marker.has_meta(BUILT_META):
		return
	if String(marker.get_meta(&"kind", "")) != OBJECTIVE_KIND:
		return
	marker.set_meta(BUILT_META, true)
	var wellspring: Node3D = WELLSPRING_SCRIPT.new() as Node3D
	wellspring.name = "Wellspring_%s" % marker.name
	marker.add_child(wellspring)
