class_name InventoryStore
extends RefCounted

## Pure stable-slot inventory data. InventoryService owns authority and networking; this class only
## enforces stack, capacity, removal, movement, and transaction invariants against Registry content.

var _registry: Node
var _slot_count: int
var _primary_slot_count: int
var _slots: Array[Dictionary] = []


func _init(registry: Node, slot_count: int, primary_slot_count: int = 0) -> void:
	_registry = registry
	_slot_count = maxi(slot_count, 1)
	_primary_slot_count = (
		_slot_count if primary_slot_count <= 0 else clampi(primary_slot_count, 1, _slot_count)
	)
	_clear()


func slot_count() -> int:
	return _slot_count


func slots_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for slot: Dictionary in _slots:
		result.append(slot.duplicate())
	return result


func slot_at(index: int) -> Dictionary:
	if index < 0 or index >= _slots.size():
		return {}
	return _slots[index].duplicate()


func count(item_id: StringName) -> int:
	var total: int = 0
	for slot: Dictionary in _slots:
		if _slot_item_id(slot) == item_id:
			total += int(slot.get("amount", 0))
	return total


func capacity_for(item_id: StringName) -> int:
	var stack_size: int = _stack_size(item_id)
	if stack_size <= 0:
		return 0
	var capacity: int = 0
	for slot: Dictionary in _slots:
		if slot.is_empty():
			capacity += stack_size
		elif _slot_item_id(slot) == item_id:
			capacity += stack_size - int(slot.get("amount", 0))
	return capacity


func can_add(item_id: StringName, amount: int) -> bool:
	return amount > 0 and capacity_for(item_id) >= amount


## All-or-nothing. A grant never silently drops the part that did not fit. Empty primary slots are
## visited before the trailing region, so InventoryService fills the backpack before hotbar overflow.
func add(item_id: StringName, amount: int) -> bool:
	if not can_add(item_id, amount):
		return false
	var stack_size: int = _stack_size(item_id)
	var remaining: int = amount
	for index: int in _slots.size():
		var slot: Dictionary = _slots[index]
		if _slot_item_id(slot) != item_id:
			continue
		var moved: int = mini(stack_size - int(slot.get("amount", 0)), remaining)
		if moved <= 0:
			continue
		slot["amount"] = int(slot.get("amount", 0)) + moved
		_slots[index] = slot
		remaining -= moved
		if remaining == 0:
			return true
	for index: int in _slots.size():
		if not _slots[index].is_empty():
			continue
		var moved: int = mini(stack_size, remaining)
		_slots[index] = {"item_id": item_id, "amount": moved}
		remaining -= moved
		if remaining == 0:
			return true
	return false


func can_remove(item_id: StringName, amount: int) -> bool:
	return amount > 0 and _stack_size(item_id) > 0 and count(item_id) >= amount


## All-or-nothing. Consume high primary slots first, then the trailing region. InventoryService uses
## the backpack as primary and the hotbar as trailing, so crafting/removal preserves equipped stacks
## whenever the backpack alone can pay the cost.
func remove(item_id: StringName, amount: int) -> bool:
	if not can_remove(item_id, amount):
		return false
	var remaining: int = amount
	for index: int in _removal_order():
		var slot: Dictionary = _slots[index]
		if _slot_item_id(slot) != item_id:
			continue
		var current: int = int(slot.get("amount", 0))
		var moved: int = mini(current, remaining)
		current -= moved
		remaining -= moved
		_slots[index] = {} if current == 0 else {"item_id": item_id, "amount": current}
		if remaining == 0:
			return true
	return false


func _removal_order() -> Array[int]:
	var result: Array[int] = []
	for index: int in range(_primary_slot_count - 1, -1, -1):
		result.append(index)
	for index: int in range(_slot_count - 1, _primary_slot_count - 1, -1):
		result.append(index)
	return result


## Move/split/merge for task 2.5's drag/drop UI. amount <= 0 means the whole source stack.
func move_stack(from_index: int, to_index: int, amount: int = 0) -> bool:
	if not _valid_index(from_index) or not _valid_index(to_index) or from_index == to_index:
		return false
	var source: Dictionary = _slots[from_index]
	if source.is_empty():
		return false
	var source_amount: int = int(source.get("amount", 0))
	var move_amount: int = source_amount if amount <= 0 else amount
	if move_amount <= 0 or move_amount > source_amount:
		return false

	var item_id: StringName = _slot_item_id(source)
	var target: Dictionary = _slots[to_index]
	if target.is_empty():
		_slots[to_index] = {"item_id": item_id, "amount": move_amount}
		_set_source_remainder(from_index, item_id, source_amount - move_amount)
		return true

	var target_item_id: StringName = _slot_item_id(target)
	if target_item_id == item_id:
		var available: int = _stack_size(item_id) - int(target.get("amount", 0))
		var merged: int = mini(move_amount, available)
		if merged <= 0:
			return false
		target["amount"] = int(target.get("amount", 0)) + merged
		_slots[to_index] = target
		_set_source_remainder(from_index, item_id, source_amount - merged)
		return true

	# A whole-stack drag swaps unlike items. Partial stacks cannot swap because that would duplicate
	# the untouched source remainder into the destination.
	if move_amount != source_amount:
		return false
	_slots[from_index] = target
	_slots[to_index] = source
	return true


## Atomic crafting seam: validate and apply every removal, then every addition, or restore exactly.
func apply_transaction(removals: Dictionary, additions: Dictionary) -> bool:
	if removals.is_empty() and additions.is_empty():
		return false
	var backup: Array[Dictionary] = slots_snapshot()
	for item_id: StringName in _sorted_ids(removals):
		if not remove(item_id, int(removals[item_id])):
			_restore(backup)
			return false
	for item_id: StringName in _sorted_ids(additions):
		if not add(item_id, int(additions[item_id])):
			_restore(backup)
			return false
	return true


static func snapshot_is_valid(slots: Array, registry: Node, expected_slot_count: int) -> bool:
	if slots.size() != expected_slot_count or registry == null:
		return false
	for value: Variant in slots:
		if not (value is Dictionary):
			return false
		var slot := value as Dictionary
		if slot.is_empty():
			continue
		var item_id := StringName(String(slot.get("item_id", "")))
		var amount: int = int(slot.get("amount", 0))
		if item_id == &"" or amount <= 0 or not bool(registry.call("has_item", item_id)):
			return false
		var definition := registry.call("get_item", item_id) as Resource
		if definition == null or amount > int(definition.get("stack_size")):
			return false
	return true


static func normalize_snapshot(slots: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value: Variant in slots:
		var slot := value as Dictionary
		if slot.is_empty():
			result.append({})
		else:
			result.append({
				"item_id": StringName(String(slot.get("item_id", ""))),
				"amount": int(slot.get("amount", 0)),
			})
	return result


func _stack_size(item_id: StringName) -> int:
	if _registry == null or item_id == &"" or not bool(_registry.call("has_item", item_id)):
		return 0
	var definition := _registry.call("get_item", item_id) as Resource
	return maxi(int(definition.get("stack_size")), 1) if definition != null else 0


func _slot_item_id(slot: Dictionary) -> StringName:
	return StringName(String(slot.get("item_id", "")))


func _valid_index(index: int) -> bool:
	return index >= 0 and index < _slots.size()


func _set_source_remainder(index: int, item_id: StringName, amount: int) -> void:
	_slots[index] = {} if amount == 0 else {"item_id": item_id, "amount": amount}


func _sorted_ids(values: Dictionary) -> Array[StringName]:
	var result: Array[StringName] = []
	for key: Variant in values:
		result.append(StringName(String(key)))
	result.sort()
	return result


func _restore(snapshot: Array[Dictionary]) -> void:
	_slots.clear()
	for slot: Dictionary in snapshot:
		_slots.append(slot.duplicate())


func _clear() -> void:
	_slots.clear()
	for _index: int in _slot_count:
		_slots.append({})
