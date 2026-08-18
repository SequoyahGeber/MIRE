class_name LootEntry
extends Resource

## One weighted line of a LootTableDef's roll: this item, this amount range, this relative weight.
## Same split RecipeIngredient uses for RecipeDef — a small, reusable value object rather than
## parallel arrays on the table itself.

@export var item_id: StringName = &""
@export_range(1, 999, 1) var min_amount: int = 1
@export_range(1, 999, 1) var max_amount: int = 1
## Relative, not a probability — LootTableDef normalises against the sum of every entry's weight.
@export_range(0.01, 1000.0, 0.01, "or_greater") var weight: float = 1.0
