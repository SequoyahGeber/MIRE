extends SceneTree

## Scratch probe for F-163: proves `expr as Array[T]` does NOT perform an element-wise runtime
## conversion of an already-untyped Array, and checks which of the alternative conversion forms
## actually compile and work, since the finding's own suggested fix needs verifying before it goes
## into docs/SPECS.md's standing rules. Throwaway, like tools/_probe_food_grip.gd.
##
##   .agent/bin/agent godot --script tools/_probe_typed_array_convert.gd

const CYCLE_MODIFIER_DEF := preload("res://systems/cycle/cycle_modifier_def.gd")


func _initialize() -> void:
	var untyped: Array = [&"weather", &"corruption"]

	var via_as: Array = untyped as Array[StringName]
	print("`as Array[StringName]` -> typed builtin=%d (0 == not typed)" % via_as.get_typed_builtin())
	_try_set("as", via_as)

	var via_builtin_ctor: Array = Array(untyped, TYPE_STRING_NAME, &"", null)
	print("`Array(expr, TYPE_STRING_NAME, &\"\", null)` -> typed builtin=%d (%d == TYPE_STRING_NAME)"
		% [via_builtin_ctor.get_typed_builtin(), TYPE_STRING_NAME])
	_try_set("builtin ctor", via_builtin_ctor)

	var via_assign: Array[StringName] = []
	via_assign.assign(untyped)
	print("`Array[StringName]().assign(expr)` -> typed builtin=%d" % via_assign.get_typed_builtin())
	_try_set("assign", via_assign)

	quit()


func _try_set(label: String, value: Array) -> void:
	var def: Resource = CYCLE_MODIFIER_DEF.new()
	def.set(&"tags", value)
	var stored: Array = def.get(&"tags")
	print("  .set('tags', %s) -> stored=%s" % [label, str(stored)])
