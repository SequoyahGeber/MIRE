class_name BuildableDef
extends Resource

## Static definition of one buildable piece. Authored by hand as a .tres in content/buildables/ —
## ARCHITECTURE.md §3.1, "content is data, not code". Task 3.7 authors the real set (walls, floors,
## ramps, doors, Wards) against the two worked examples this task ships.
##
## NETWORK AUTHORITY: none directly. A definition is identical on every peer and never goes over the
## wire — only its `id` does. Which pieces EXIST in the world is host-authoritative and lives in
## autoload/build_service.gd (docs/ARCHITECTURE.md §2.2, "world mutation" row).

## Unique key. Must match across all peers — it is what goes over the network, never the resource
## path.
## Tab order in the build bar, most-used first: you raise walls far more often than you re-site a
## workbench. Anything not listed sorts after these, alphabetically — see `category_rank()`.
const CATEGORY_ORDER: Array[StringName] = [&"structure", &"defence", &"station"]

## Tab labels. A category with no entry here is title-cased from its own id, so an unlisted
## category still reads as a word rather than as a raw key.
const CATEGORY_LABELS: Dictionary[StringName, String] = {
	&"structure": "STRUCTURE",
	&"defence": "DEFENCE",
	&"station": "STATION",
}


## Sort key for the tab strip: listed categories in `CATEGORY_ORDER`, everything else after them.
static func category_rank(name: StringName) -> int:
	var index: int = CATEGORY_ORDER.find(name)
	return index if index >= 0 else CATEGORY_ORDER.size()


static func category_label(name: StringName) -> String:
	if CATEGORY_LABELS.has(name):
		return CATEGORY_LABELS[name]
	return String(name).replace("_", " ").to_upper()


## Which tab of the build bar this piece appears under (F-483). The bar is one row above the
## hotbar and cycles tabs rather than wrapping, so this is what keeps the row a row no matter how
## many buildables the set grows to — F-477 already took it from 15 to 22 and the wrapped flow was
## four rows tall, covering the ghost it exists to help you aim.
##
## A StringName rather than an enum so content can add a tab without a code change (§3.1, "content
## is data, not code"). `CATEGORY_ORDER` fixes the tab order; a category not named there sorts last
## alphabetically rather than being dropped, so a new one is visible the moment it is authored.
@export var category: StringName = &"structure"

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var icon: Texture2D

## The thing that actually gets placed. Its root is expected to carry its own collision; the
## validator measures the box below rather than the scene, so a piece can be validated before it is
## ever instantiated — which is what lets the ghost and the host agree without either loading the
## other's copy.
@export var scene: PackedScene

@export_group("Footprint")
## Full extents in metres, centred on the placement origin at floor level: X wide, Y tall, Z deep.
## Kept as data rather than measured off `scene` so the ghost, the host and this check all reason
## about the same box, and so a piece whose art overhangs its footprint is a deliberate choice.
@export var size: Vector3 = Vector3(2.0, 3.0, 0.25)
## Placement snaps to this grid in metres. 0 disables snapping — free placement, for decoration.
@export_range(0.0, 8.0, 0.05) var snap_step: float = 1.0
## Rotation snaps to this many degrees. 90 gives the four cardinal facings walls want; 15 suits
## something decorative. 0 disables rotation snapping.
@export_range(0.0, 180.0, 1.0) var rotation_step_degrees: float = 90.0

@export_group("Placement rules")
## Needs solid ground (or another piece) beneath its footprint. False for a piece meant to bridge a
## gap, which is a design decision rather than a physics one.
@export var requires_support: bool = true
## Steepest ground this may sit on. A wall on a 40 degree slope is how you get a fort with holes
## under it that crawlers walk through.
@export_range(0.0, 89.0, 1.0) var max_ground_slope_degrees: float = 30.0
## How far from the builder it may be placed, in metres.
@export_range(1.0, 32.0, 0.5) var max_build_range_m: float = 6.0

@export_group("Cost")
## item_id -> amount, spent through InventoryService.host_transaction() when the HOST accepts the
## placement. Empty is a valid free piece.
@export var cost: Dictionary[StringName, int] = {}
## Fraction of the cost returned on destruction. 1.0 is a full refund, 0.0 none.
@export_range(0.0, 1.0, 0.05) var refund_fraction: float = 0.5

@export_group("Combat")
## Hit points before combat destroys the piece. Read by `BuildService._net_spawn_piece()` and owned
## host-side by `systems/building/buildable_piece.gd` — see F-085. Unreplicated on purpose (that
## script's own doc comment says why); only the definition's number needs to agree across peers, and
## definitions are already identical everywhere.
@export_range(1, 500, 1) var max_hp: int = 25

@export_group("Ward")
## Non-zero makes this a Ward structure. The FIELD ships here in 3.6; the Mire reads it in 4.11 —
## nothing in this task acts on it, deliberately, so 4.11 does not have to migrate content that was
## authored without it.
@export_range(0.0, 64.0, 0.5) var ward_radius_m: float = 0.0


func is_ward() -> bool:
	return ward_radius_m > 0.0


## Half-extents of the footprint box, which is what a physics shape query wants.
func half_extents() -> Vector3:
	return size * 0.5


## Same shape as LootTableDef's and PowerupDef's — registry.gd calls this before indexing and skips
## anything that fails, so a malformed .tres is a named boot error rather than a crash at placement.
func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = []
	if id == &"":
		errors.append("id is empty")
	if display_name.is_empty():
		errors.append("display_name is empty")
	if category == &"":
		errors.append("category is empty — every piece needs a build-bar tab (F-483)")
	if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		errors.append("size must be positive on every axis (got %s)" % size)
	if max_build_range_m <= 0.0:
		errors.append("max_build_range_m must be positive")
	if max_hp <= 0:
		errors.append("max_hp must be positive")
	for item_id: StringName in cost:
		if item_id == &"":
			errors.append("cost contains an empty item id")
		elif cost[item_id] <= 0:
			errors.append("cost for '%s' must be positive" % item_id)
	return errors
