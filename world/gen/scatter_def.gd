class_name ScatterDef
extends Resource

## One biome's resource-scatter table (task 4.4) — author this as a `.tres` in `content/scatter/`.
## `ResourceScatter` (the pure placement generator) reads it to decide what grows where; it never
## reads a map or a node, only this data plus the shared world seed.
##
## Network authority: none. Content, identical on every peer, exactly like `BiomeDef` — see
## `world/gen/resource_scatter.gd`'s header for how the PLACEMENTS this table produces stay
## deterministic and unreplicated, and `world/gen/resource_scatter_field.gd`'s header for the one
## piece that IS host-authoritative (whether a placed harvestable is still standing).

## F-016: a brand-new class_name is not bare-resolvable in a fresh headless clone (no editor scan
## has rebuilt .godot/global_script_class_cache.cfg yet). Preload it and use the constant as the
## array type — same fix `systems/loot/loot_table_def.gd` already uses for `LootEntry`; entries are
## handled below as plain `Resource` with `.get()`, never cast back to `ScatterEntry`.
const SCATTER_ENTRY := preload("res://world/gen/scatter_entry.gd")

@export var id: StringName = &""
## Which `BiomeDef.id` this table dresses. A point outside this biome never rolls against it.
@export var biome_id: StringName = &""
## Spacing of the jittered placement grid. Smaller = denser and costs more per chunk (trees want
## this large, ground-hugging scatter wants it small) — matches `world/gen/undergrowth.gd`'s own
## cell-size tradeoff, just per-table instead of one map-wide constant.
@export_range(1.0, 32.0, 0.5) var cell_size_m: float = 6.0
## How far a point may drift from its grid cell's centre, as a fraction of `cell_size_m`. 0 = a
## rigid grid (reads as planted rows); close to 1 = almost as irregular as a dart-throw, at the
## cost of occasional close pairs a true Poisson-disc would reject. `ResourceScatter`'s own header
## records why a jittered grid was chosen over full Poisson-disc for this task.
@export_range(0.0, 1.0, 0.01) var jitter_fraction: float = 0.6
## Chance any single grid cell spawns something at all — the empty majority is what keeps a forest
## from reading as a hedge maze of uniform density.
@export_range(0.0, 1.0, 0.01) var coverage: float = 0.35
## Surface-height band (m, inclusive) this table may dress. The defaults accept everything. Bands
## exist because a biome is not a dry-land promise: since the sea-level rebase the `shore` biome
## classifies the SEABED too (its `height_min` is -100), and a beach-grass table without a floor
## would carpet the bottom of the ocean. Streams likewise dip low ground below the meadow line —
## a meadow table sets `min_height` above the bed so grass does not grow out of the water.
@export var min_height: float = -1000.0
@export var max_height: float = 1000.0
@export var entries: Array[SCATTER_ENTRY] = []


func total_weight() -> float:
	var total := 0.0
	for entry: Resource in entries:
		if entry != null:
			total += maxf(float(entry.get(&"weight")), 0.0)
	return total


## `roll` must be in `[0, total_weight())` — callers draw it themselves so the same RNG stream also
## covers the coverage check and the jitter/rotation/scale draws for the same point, deterministically.
func pick_entry(roll: float) -> Resource:
	var cursor := 0.0
	for entry: Resource in entries:
		if entry == null:
			continue
		cursor += maxf(float(entry.get(&"weight")), 0.0)
		if roll < cursor:
			return entry
	return null


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if id == &"":
		errors.append("id is empty")
	if biome_id == &"":
		errors.append("biome_id is empty")
	if entries.is_empty():
		errors.append("entries is empty")
	if total_weight() <= 0.0:
		errors.append("no entry has a positive weight")
	for index: int in entries.size():
		var entry: Resource = entries[index]
		if entry == null:
			errors.append("entries[%d] is empty" % index)
			continue
		if entry.has_method(&"validation_errors"):
			for entry_error: String in (entry.call(&"validation_errors") as PackedStringArray):
				errors.append("entries[%d]: %s" % [index, entry_error])
	return errors
