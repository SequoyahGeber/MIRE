class_name ScatterEntry
extends Resource

## One asset a `ScatterDef` may place. Weight is relative to the other entries in the SAME table —
## it does not need to sum to any particular total.
##
## Network authority: none. Content, identical on every peer (ARCHITECTURE.md §2.2).

## Matches `HarvestLibrary`/`AssetVfxLibrary`'s asset id convention (the GLB's own file name, no
## extension) — stamping the same id here is what lets a scattered tree or bush be classified
## harvestable, swayed by wind, etc. for free, exactly like a hand-authored map's props.
@export var asset: StringName = &""
## Which `res://assets/<kit>/exports/<asset>.glb` this id resolves to — same kit/asset split
## `world/gen/authored_world.gd` already uses.
@export var kit: String = ""
@export_range(0.01, 1000.0, 0.01, "or_greater") var weight: float = 1.0
@export_range(0.1, 10.0, 0.01) var min_scale: float = 0.9
@export_range(0.1, 10.0, 0.01) var max_scale: float = 1.1


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if asset == &"":
		errors.append("asset is empty")
	if kit.is_empty():
		errors.append("kit is empty")
	if weight <= 0.0:
		errors.append("weight must be positive")
	if min_scale <= 0.0:
		errors.append("min_scale must be positive")
	if max_scale < min_scale:
		errors.append("max_scale must be >= min_scale")
	return errors
