class_name LootEntry
extends Resource

## One weighted line of a LootTableDef's roll: this item, this amount range, this relative weight.
## Same split RecipeIngredient uses for RecipeDef — a small, reusable value object rather than
## parallel arrays on the table itself.

## What this line grants. ITEM goes through InventoryService; POWERUP goes through
## PowerupService's grant seam, host-side, on the same open. `DESIGN.md` §4.4 has always said
## powerups come out of chests, and `docs/ITEMS.md` §5 cannot express a single chest tier without
## this — "common powerups 55%" is most of what a Bog Chest is.
enum Kind {
	ITEM,     ## `item_id` names an ItemDef in content/items/
	POWERUP,  ## `item_id` names a PowerupDef in content/powerups/
}

## Deliberately NOT a second id field. One id, one namespace switch: a parallel `powerup_id` would
## make every table author decide which of two fields to fill and every reader check both.
@export var kind: Kind = Kind.ITEM
@export var item_id: StringName = &""
@export_range(1, 999, 1) var min_amount: int = 1
@export_range(1, 999, 1) var max_amount: int = 1
## How special this line is, 0 (filler) to 3 (jackpot). This is what the shipped `loot_luck` stat
## biases toward — before this field it had no consumer at all, so three authored powerups promised
## better loot and did nothing (F-140). Rarity never changes what an entry GIVES; it only changes
## how much luck can lean on its weight, which keeps D-063 honest: tune frequency, not potency.
@export_range(0, 3, 1) var rarity: int = 0
## Relative, not a probability — LootTableDef normalises against the sum of every entry's weight.
@export_range(0.01, 1000.0, 0.01, "or_greater") var weight: float = 1.0
