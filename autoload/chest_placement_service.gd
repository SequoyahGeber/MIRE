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
##   "Cache_<n>"          -> tier `basic` (the Reed Cache), free — the ladder's bottom rung handed
##                           out rather than sold, so a run always has coins before it has a price.
##   "Chest_<tier>_<n>"   -> tier is read straight out of the name and passed to `Chest.tier`
##                           unvalidated (Chest's own `_validate_configuration()` rejects an unknown
##                           id); cost/lock come from `_ECONOMY_FOR_TIER` below. Today's only writer
##                           is `build_gilded_chests()`'s `"Chest_gilded_<n>"`, ITEMS.md §6.4's
##                           1-2/island budget, alongside `build_ladder_chests()`'s five priced
##                           rungs — `tools/mapgen/hollowmere_layout.py`'s `validate()` enforces the
##                           counts at generation time, this bridge just instances whatever the
##                           layout actually shipped.
## Any other `loot`-kind marker (a decorative loot pickup with no chest behind it), or any marker of
## a different `kind` entirely, is left alone — same "only touch what you recognise" discipline
## `crafting_service.gd`'s `Station_` prefix already uses on the same marker group.
const CHEST_SCRIPT := preload("res://systems/loot/chest.gd")
const CRATE_CLOSED := preload("res://assets/loot/exports/loot_chest_crate_closed.glb")
const CRATE_OPEN := preload("res://assets/loot/exports/loot_chest_crate_open.glb")
const SMALL_CLOSED := preload("res://assets/loot/exports/loot_chest_small_closed.glb")
const SMALL_OPEN := preload("res://assets/loot/exports/loot_chest_small_open.glb")
const REINFORCED_CLOSED := preload("res://assets/loot/exports/loot_chest_reinforced_closed.glb")
const REINFORCED_OPEN := preload("res://assets/loot/exports/loot_chest_reinforced_open.glb")
const WARDED_CLOSED := preload("res://assets/loot/exports/loot_chest_warded_closed.glb")
const WARDED_OPEN := preload("res://assets/loot/exports/loot_chest_warded_open.glb")
const GILDED_CLOSED := preload("res://assets/loot/exports/loot_chest_gilded_closed.glb")
const GILDED_OPEN := preload("res://assets/loot/exports/loot_chest_gilded_open.glb")
const WELLSPRING_CLOSED := preload("res://assets/loot/exports/loot_chest_wellspring_closed.glb")
const WELLSPRING_OPEN := preload("res://assets/loot/exports/loot_chest_wellspring_open.glb")

const MARKER_GROUP: StringName = &"authored_world_marker"
const MARKER_KIND: String = "loot"
const CACHE_PREFIX: String = "Cache_"
const CHEST_PREFIX: String = "Chest_"
const BUILT_META: StringName = &"mire_chest_placed"

## Per-tier (cost_coins, locked_by) for a `"Chest_<tier>_<n>"` marker.
##
## THE LADDER (D-215). Five tiers — basic, common, rare, epic, legendary — priced so each rung costs
## roughly twice the one below it and pays out visibly better odds, not merely bigger numbers: the
## powerup share of a roll climbs 5% → 48% → 50% → 55% → 72% across the ladder, and the RARITY of the
## powerup lines climbs with it (content/loot/*.tres). That is what makes saving up read as a choice
## rather than as arithmetic — a legendary is four commons, and the player is asking whether four
## ordinary rolls beat one that is mostly rarity-3.
##
## Each rung also has its OWN silhouette (`_visuals_for_tier()` below), because a price ladder a
## player has to open a UI to read is not a ladder. Sizes run 0.62 m → 1.12 m and the palettes are
## deliberately unrelated: grey deadwood, warm timber, dark iron, ward teal, gold.
##
## `Cache_<n>` is the ladder's free entry point rather than a sixth tier: same `basic` table, same
## crate mesh, cost 0. Muck's proven loop, kept — free caches seed the coins that priced chests
## spend (`docs/ITEMS.md` §5), and a run whose first chest wants 10 coins the player cannot have
## is a run that opens on a locked door.
##
## `docs/ITEMS.md` §5's "Getting in" column sometimes offers two gates for one tier ("~60 coins **or**
## a Rusted Key") but `Chest._accept_open_request()` charges `cost_coins` AND `locked_by` together in
## ONE transaction — it has no "either" mode. A single placed instance can therefore only express ONE
## gate, so the ladder is priced in coins throughout and the key-only containers stay their own
## tiers: `gilded` (Gilded Key, ITEMS.md line 243) and `sunken` ("risk-priced rather than
## coin-priced" — the hazard IS the price). Recorded as D-122.
const _ECONOMY_FOR_TIER: Dictionary[StringName, Dictionary] = {
	&"basic": {"cost_coins": 10, "locked_by": &""},
	&"common": {"cost_coins": 30, "locked_by": &""},
	&"rare": {"cost_coins": 75, "locked_by": &""},
	&"epic": {"cost_coins": 150, "locked_by": &""},
	&"legendary": {"cost_coins": 300, "locked_by": &""},
	&"gilded": {"cost_coins": 0, "locked_by": &"gilded_key"},
	&"sunken": {"cost_coins": 0, "locked_by": &""},
}

## Per-tier locator tint, RGB only. The warm mote `Chest._build_locator()` puts over an unopened
## chest is the FIRST thing a player sees of a container — usually before the mesh resolves through
## grass — so it carries the tier read at exactly the range where silhouette cannot. Colours match
## each mesh's own palette so the mote never promises a tier the chest is not.
const _LOCATOR_TINT_FOR_TIER: Dictionary[StringName, Color] = {
	&"basic": Color(0.78, 0.74, 0.66),
	&"common": Color(1.0, 0.72, 0.30),
	&"rare": Color(0.72, 0.84, 0.92),
	&"epic": Color(0.36, 0.94, 0.90),
	&"legendary": Color(1.0, 0.84, 0.22),
	&"gilded": Color(1.0, 0.84, 0.22),
	&"sunken": Color(0.70, 0.42, 0.95),
	&"wellspring": Color(0.70, 0.42, 0.95),
}


var _refresh_scheduled: bool = false
## Tiers already reported by `_gate_is_satisfiable()` — see its header for why this warns once.
var _unsatisfiable_tiers_warned: Dictionary[StringName, bool] = {}


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
	# The economy is resolved BEFORE the gate is tested, because they must be the same economy.
	# Review catch (wick3d4184, 2026-08-22): a `Cache_`-prefixed marker overrides the tier's row
	# with a free, unlocked one, so testing the gate against `_ECONOMY_FOR_TIER` alone asked about a
	# row this marker does not use. Unreachable today — `Cache_` maps to `basic`, which has no
	# `locked_by` — but safe by DATA rather than by construction, which is the same criticism that
	# fixed `station_count()` an hour ago.
	var economy: Dictionary = (
		{"cost_coins": 0, "locked_by": &""} if String(marker.name).begins_with(CACHE_PREFIX)
		else _ECONOMY_FOR_TIER.get(tier, {})
	)
	if not _gate_is_satisfiable(tier, economy):
		# F-574: refuse to build a container the game has no way to let anyone open. `gilded` is
		# key-only by D-122 and its key does not exist yet (`gilded_key` is A-047 art, still
		# QUEUED), so `content/poi/treasure_gilded.tres`'s two sites an island were shipping two
		# fully-built, locator-tinted, permanently unopenable chests. A visible promise the game
		# cannot keep is strictly worse than an empty site, so the site stays empty.
		#
		# Deliberately a runtime gate on the ITEM rather than a deletion of the tier: nothing here
		# changes when the key ships. The moment `content/items/gilded_key.tres` exists and
		# registers, this test passes and the gilded chests light up with no edit to this file.
		marker.set_meta(BUILT_META, true)
		return
	marker.set_meta(BUILT_META, true)
	var chest: Node3D = CHEST_SCRIPT.new() as Node3D
	chest.name = "Chest_%s" % marker.name
	# `economy` was resolved above, before the gate test. A Reed Cache is the `basic` TABLE handed
	# out rather than sold, so the price comes from the marker prefix and not from the tier alone:
	# the tier decides what is inside, the marker decides whether you pay for it. Without that
	# split, `basic`'s own 10-coin rung would price the eight free caches a run needs before it has
	# any coins to price them with.
	# Property order matches tools/loot_content_check.gd's own worked example: every @export set
	# BEFORE add_child(), since _ready() (and therefore _validate_configuration()) fires the moment
	# the chest enters the tree.
	chest.set("tier", tier)
	chest.set("cost_coins", int(economy.get("cost_coins", 0)))
	chest.set("locked_by", economy.get("locked_by", &""))
	var visuals: Array[PackedScene] = _visuals_for_tier(tier)
	chest.set("closed_scene", visuals[0])
	chest.set("open_scene", visuals[1])
	chest.set("locator_tint", _LOCATOR_TINT_FOR_TIER.get(tier, Color(1.0, 0.64, 0.12)))
	marker.add_child(chest)


## Can anybody actually open a chest of this tier — is its key an item that exists?
##
## F-574: `_ECONOMY_FOR_TIER` can name a `locked_by` item, and nothing checked that the id resolves.
## `gilded` named `gilded_key`, which appeared in exactly one file in the entire repository: the
## table entry itself. No item def, no loot entry, no recipe, no drop. `Chest._accept_open_request()`
## charges `cost_coins` AND `locked_by` in one transaction, so the requirement could never be met.
##
## Warns ONCE per tier rather than per placed chest — six sites an island times every reseed is a log
## nobody reads, and the point of the warning is that an authored gate is unreachable, which is a
## fact about content and not about this instance.
func _gate_is_satisfiable(tier: StringName, economy: Dictionary = {}) -> bool:
	# Defaulting to the tier's own row keeps the one-argument form callable from checks, which ask
	# about a TIER rather than about a placed marker.
	var row: Dictionary = economy if not economy.is_empty() else _ECONOMY_FOR_TIER.get(tier, {})
	var key := StringName(row.get("locked_by", &""))
	if key == &"":
		return true
	if Registry.has_item(key):
		return true
	if not _unsatisfiable_tiers_warned.has(tier):
		_unsatisfiable_tiers_warned[tier] = true
		push_warning(
			"ChestPlacementService: tier '%s' is locked by item '%s', which is not registered — "
			% [tier, key]
			+ "placing no chests of that tier rather than unopenable ones (F-574)"
		)
	return false


## One silhouette per ladder rung, in price order, plus the Mire's own container for the tiers that
## are not on the ladder at all. Nothing is shared between two ladder rungs: the moment two prices
## look alike, the price stops being information.
func _visuals_for_tier(tier: StringName) -> Array[PackedScene]:
	if tier == &"basic":
		return [CRATE_CLOSED, CRATE_OPEN]
	if tier == &"common":
		return [SMALL_CLOSED, SMALL_OPEN]
	if tier == &"rare":
		return [REINFORCED_CLOSED, REINFORCED_OPEN]
	if tier == &"epic":
		return [WARDED_CLOSED, WARDED_OPEN]
	if tier == &"legendary" or tier == &"gilded":
		return [GILDED_CLOSED, GILDED_OPEN]
	# `sunken` and `wellspring` are the Mire's containers, not purchases.
	return [WELLSPRING_CLOSED, WELLSPRING_OPEN]


func _tier_for_marker_name(marker_name: String) -> StringName:
	if marker_name.begins_with(CACHE_PREFIX):
		return &"basic"
	if marker_name.begins_with(CHEST_PREFIX):
		var rest: String = marker_name.substr(CHEST_PREFIX.length())
		var underscore: int = rest.find("_")
		var tier_part: String = rest if underscore < 0 else rest.substr(0, underscore)
		if tier_part != "":
			return StringName(tier_part)
	return &""
