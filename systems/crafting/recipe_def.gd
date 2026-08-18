class_name RecipeDef
extends Resource

## Static definition of one craftable recipe. Authored by hand as a .tres in content/recipes/ —
## see ARCHITECTURE.md §3.1. `registry.gd` loads every .tres in that folder at boot and indexes it by
## `id`.
##
## Network authority: none directly, same as ItemDef — this is the recipe *definition*, not a craft
## attempt. Task 2.6 (craft request → host validates → grants) is what's host-authoritative.

## Unique key, referenced by craft requests instead of a resource path.
@export var id: StringName = &""
@export var display_name: String = ""
## Which crafting station this recipe requires, e.g. &"workbench". M2's vertical slice has exactly
## one station — see ROADMAP.md 2.6 — so this is a free-form key rather than an enum for now.
@export var station: StringName = &"workbench"
@export var inputs: Array[RecipeIngredient] = []
@export var output_item: ItemDef
@export var output_count: int = 1

## 0 (default) crafts instantly, exactly like every recipe before task 3.1 — the shipped stone_axe
## recipe needs no edit to keep working. Above 0, CraftingService runs a host-side timer of this many
## seconds before committing the transaction; the furnace's iron_ingot recipe is the worked example.
@export_range(0.0, 120.0, 0.5) var craft_time_sec: float = 0.0
