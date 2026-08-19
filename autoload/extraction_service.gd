extends Node

## Runtime bridge between an authored map's `shipwreck` marker and task 6.5's ExtractionShip
## component. Same split `autoload/wellspring_service.gd` uses for the Wellspring ritual: the map's
## deterministic layout builder (`world/gen/authored_world.gd`) drops a marker, this bridge discovers
## it after scene construction and builds the live gameplay node there. No map layout needs a
## gameplay-specific edit.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none of its own — this runs identically on every
## peer so the ExtractionShip node (and its RPC/synchronizer paths) land in the same place
## everywhere. ExtractionShip itself owns the repair/departure authority.
##
## `content/poi/shipwreck.tres` already authors the procedural placement (task 4.7's PoiMap, target
## 3/island) — this bridge does NOT consume it. F-139 already recorded that the live game still ships
## the authored Hollowmere map, not the procedural pipeline, and `world/gen/authored_world.gd` has no
## `shipwreck` marker kind yet for this bridge to find — see docs/FINDINGS.md for the gap this leaves
## (the same shape as F-146's chest-placement gap). Building against the marker anyway, rather than
## against PoiMap, keeps this bridge's shape identical to WellspringService's already-proven one and
## ready the moment either the marker or the cutover lands.

const EXTRACTION_SHIP_SCRIPT := preload("res://systems/extraction/extraction_ship.gd")

const MARKER_GROUP: StringName = &"authored_world_marker"
const SHIPWRECK_KIND: String = "shipwreck"
const BUILT_META: StringName = &"mire_extraction_ship_built"

var _refresh_scheduled: bool = false


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	_schedule_refresh()


func refresh_current_scene() -> void:
	_refresh_scheduled = false
	for node: Node in get_tree().get_nodes_in_group(MARKER_GROUP):
		_maybe_build(node as Node3D)


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
	if String(marker.get_meta(&"kind", "")) != SHIPWRECK_KIND:
		return
	marker.set_meta(BUILT_META, true)
	var ship: Node3D = EXTRACTION_SHIP_SCRIPT.new() as Node3D
	ship.name = "ExtractionShip_%s" % marker.name
	marker.add_child(ship)
