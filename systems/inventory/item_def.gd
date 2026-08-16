class_name ItemDef
extends Resource

## Static definition of one item kind. Authored by hand as a .tres in content/items/ — see
## ARCHITECTURE.md §3.1. `registry.gd` loads every .tres in that folder at boot and indexes it by `id`.
##
## Network authority: none directly. Item *instances* (which stack holds how many) are host-authoritative
## (ARCHITECTURE.md §2.2, "Inventory / crafting" row) — that's systems/inventory, not this definition.

enum Category { RESOURCE, TOOL, WEAPON, CONSUMABLE }

## Unique key. Must match across all peers — it's what goes over the network, never the resource path.
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var icon: Texture2D
@export var category: Category = Category.RESOURCE
@export var stack_size: int = 99
## Scene used when this item exists as a physical pickup in the world (dropped, harvested). Optional —
## items that are only ever crafting intermediates may not need one yet.
@export var world_model: PackedScene
