extends Node

## UnlockService — autoload. Task 6.9 (DESIGN.md §4.6): the purchase/persistence half of the
## Salvage-funded unlock tree. "Salvage unlocks variety, never power" is enforced upstream, in
## UnlockDef's own schema — there is no stat field to spend Salvage on — not by a runtime check
## in here; this service only knows how to sell rows and remember which ones sold.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Unlocks" row): NONE. Same reasoning and the same
## per-peer `user://` shape as SalvageService (task 6.6, D-107): a purchase is per-player account
## state, no two peers ever compare unlock sets, and every peer runs this exact autoload reacting
## only to ITS OWN local calls. F-173 records the real consequence of that: `is_content_unlocked()`
## cannot safely gate anything the host decides once for the whole party (a loot roll, an enemy
## roster, a POI list) without the peers' unlock sets first agreeing — which they may not.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const UNLOCK_SAVE := preload("res://core/save/unlock_save.gd")

var _purchased: Dictionary[StringName, bool] = {}
## Override for `tools/unlock_check.gd` only — production code never sets this, so it always reads
## `UnlockSave.SAVE_PATH` and a check run never touches a real player's save file. Same D-107 shape
## SalvageService's own `save_path` uses.
var save_path: String = UNLOCK_SAVE.SAVE_PATH


func _ready() -> void:
	_load()


## True once `unlock_id` has been bought on THIS peer.
func is_purchased(unlock_id: StringName) -> bool:
	return _purchased.has(unlock_id)


## This peer's own purchased ids, in no particular order.
func purchased_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	ids.assign(_purchased.keys())
	return ids


## True when `content_id` (a PowerupDef/AttunementDef/etc id, matched against every UnlockDef's own
## `gates_id`) is either ungated — no UnlockDef names it, so nothing stops it appearing — or gated
## and this peer has already purchased the UnlockDef that gates it. The seam a future consumer
## calls before adding something to a pool; see this file's own header and F-173 for why nothing
## calls it yet.
func is_content_unlocked(content_id: StringName) -> bool:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method("unlock_defs"):
		return true
	var defs: Dictionary = registry.call("unlock_defs")
	for def: Resource in defs.values():
		if StringName(String(def.get(&"gates_id"))) == content_id:
			return is_purchased(StringName(String(def.get(&"id"))))
	return true


## Spends this peer's own Salvage (via `SalvageService.spend_salvage()`) and marks `unlock_id`
## purchased, in one attempt. Returns false, with no state changed either side, if `unlock_id` does
## not exist, is already purchased, persistence is disabled (D-107's guard — see
## `_persistence_enabled()`), or the Salvage balance is short — the same "price and grant happen
## as one transaction, a failure changes nothing" shape `Chest._accept_open_request()` already
## uses for coins.
func purchase(unlock_id: StringName) -> bool:
	if not _persistence_enabled():
		return false
	if is_purchased(unlock_id):
		return false
	var def: Resource = _definition(unlock_id)
	if def == null:
		return false
	var salvage_service: Node = get_node_or_null(^"/root/SalvageService")
	if salvage_service == null or not salvage_service.has_method("spend_salvage"):
		return false
	var cost: int = int(def.get(&"cost"))
	if not bool(salvage_service.call("spend_salvage", cost)):
		return false
	_purchased[unlock_id] = true
	var ids: Array = []
	for id: StringName in _purchased.keys():
		ids.append(String(id))
	UNLOCK_SAVE.save_data({"purchased_ids": ids}, save_path)
	EVENT_BUS.emit_unlock_purchased(unlock_id, cost, int(salvage_service.call("total_salvage")))
	return true


func _definition(unlock_id: StringName) -> Resource:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method("get_unlock"):
		return null
	return registry.call("get_unlock", unlock_id) as Resource


func _load() -> void:
	var data: Dictionary = UNLOCK_SAVE.load_data(save_path)
	_purchased.clear()
	for raw_id: String in (data.get(&"purchased_ids", []) as Array):
		_purchased[StringName(raw_id)] = true


## Guards every disk write against being triggered by an unrelated check's own test traffic — the
## exact D-107 trap `SalvageService._persistence_enabled()` records: a `--script` harness never
## loads `project.godot`'s `run/main_scene` (`current_scene` stays null for the whole run), which
## the real game always does, so that is the one signal available to every future
## `user://`-persisting autoload for free. `tools/unlock_check.gd` opts back in by overriding
## `save_path` away from the real one.
func _persistence_enabled() -> bool:
	return save_path != UNLOCK_SAVE.SAVE_PATH or get_tree().current_scene != null
