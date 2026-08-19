extends Node

## Runtime bridge between an authored map's `loot` markers and the shipped `Chest` component
## (`systems/loot/chest.gd`) — the piece F-146 found missing: "nothing in the game places a chest,
## so the gilded tier's 1-2/island budget has no owner." Same split `wellspring_service.gd` and
## `crafting_service.gd` already use for `authored_world.gd`'s other marker kinds: the map's
## deterministic layout builder drops a marker, this bridge discovers it after scene construction
## and builds the live gameplay node there. No map layout needs a gameplay-specific script edit —
## `tools/mapgen/hollowmere_layout.py` only ever emits data.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Chest placement" row): **none of its own.** This
## runs identically on every peer — same layout, same markers, same deterministic tier/cost/lock
## derived from each marker's own name — so every `Chest` node lands at the same NodePath on every
## peer without a byte crossing the wire, the same reasoning `wellspring_service.gd` documents for
## the objective marker. `Chest` itself keeps the real authority: opening one is host-validated
## exactly as `systems/loot/chest.gd`'s own header describes.
##
## MARKER NAME CONVENTION (`tools/mapgen/hollowmere_layout.py` is the only writer today):
##   "Cache_<n>"          -> tier `small` (the Reed Cache), free — the 8 waymark caches already
##                           shipped as decorative `loot_chest_small_closed` props before this
##                           bridge existed; this is their first live gameplay consumer.
##   "Chest_<tier>_<n>"   -> tier is read straight out of the name and passed to `Chest.tier`
##                           unvalidated (Chest's own `_validate_configuration()` rejects an unknown
##                           id); cost/lock come from `_ECONOMY_FOR_TIER` below. Today's only writer
##                           is `build_gilded_chests()`'s `"Chest_gilded_<n>"`, ITEMS.md §6.4's
##                           1-2/island budget — `tools/mapgen/hollowmere_layout.py`'s `validate()`
##                           enforces the count at generation time, this bridge just instances
##                           whatever the layout actually shipped.
## Any other `loot`-kind marker (a decorative loot pickup with no chest behind it), or any marker of
## a different `kind` entirely, is left alone — same "only touch what you recognise" discipline
## `crafting_service.gd`'s `Station_` prefix already uses on the same marker group.
const CHEST_SCRIPT := preload("res://systems/loot/chest.gd")

const MARKER_GROUP: StringName = &"authored_world_marker"
const MARKER_KIND: String = "loot"
const CACHE_PREFIX: String = "Cache_"
const CHEST_PREFIX: String = "Chest_"
const BUILT_META: StringName = &"mire_chest_placed"

## Per-tier (cost_coins, locked_by) for a `"Chest_<tier>_<n>"` marker. `docs/ITEMS.md` §5's
## "Getting in" column sometimes offers two gates for one tier (Strongbox: "~60 coins **or** a
## Rusted Key") but `Chest._accept_open_request()` charges `cost_coins` AND `locked_by` together in
## ONE transaction — it has no "either" mode. A single placed instance can therefore only express
## ONE gate, so this table picks the coin gate for the tiers that have one (bog, strongbox) and
## leaves the key-only alternative as a distinct instance a future placement can add, rather than
## inventing a two-gate mode `Chest` was never built for. Gilded has no coin option in the item
## catalog itself ("Gilded Key ... opens the Gilded Chest", ITEMS.md line 243) so it is key-only.
## Sunken is "risk-priced rather than coin-priced" (ITEMS.md §5) — unpriced and unlocked; the hazard
## IS the price. Recorded as D-122.
const _ECONOMY_FOR_TIER: Dictionary[StringName, Dictionary] = {
	&"bog": {"cost_coins": 25, "locked_by": &""},
	&"strongbox": {"cost_coins": 60, "locked_by": &""},
	&"gilded": {"cost_coins": 0, "locked_by": &"gilded_key"},
	&"sunken": {"cost_coins": 0, "locked_by": &""},
}

var _refresh_scheduled: bool = false


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	_schedule_refresh()


## Test/debug seam, same shape `wellspring_service.gd` exposes: force a full rescan rather than
## waiting for the next `node_added` signal.
func refresh_current_scene() -> void:
	_refresh_scheduled = false
	for node: Node in get_tree().get_nodes_in_group(MARKER_GROUP):
		_maybe_build(node as Node3D)


## Only a marker entering the tree warrants a rescan — same filter `harvest_world.gd` and
## `wellspring_service.gd` use and for the same reason (F-099): without it, every node the game
## ever adds schedules a full group scan.
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
	if String(marker.get_meta(&"kind", "")) != MARKER_KIND:
		return
	var tier: StringName = _tier_for_marker_name(marker.name)
	if tier == &"":
		return
	marker.set_meta(BUILT_META, true)
	var chest: Node3D = CHEST_SCRIPT.new() as Node3D
	chest.name = "Chest_%s" % marker.name
	var economy: Dictionary = _ECONOMY_FOR_TIER.get(tier, {})
	# Property order matches tools/loot_content_check.gd's own worked example: every @export set
	# BEFORE add_child(), since _ready() (and therefore _validate_configuration()) fires the moment
	# the chest enters the tree.
	chest.set("tier", tier)
	chest.set("cost_coins", int(economy.get("cost_coins", 0)))
	chest.set("locked_by", economy.get("locked_by", &""))
	marker.add_child(chest)


func _tier_for_marker_name(marker_name: String) -> StringName:
	if marker_name.begins_with(CACHE_PREFIX):
		return &"small"
	if marker_name.begins_with(CHEST_PREFIX):
		var rest: String = marker_name.substr(CHEST_PREFIX.length())
		var underscore: int = rest.find("_")
		var tier_part: String = rest if underscore < 0 else rest.substr(0, underscore)
		if tier_part != "":
			return StringName(tier_part)
	return &""
