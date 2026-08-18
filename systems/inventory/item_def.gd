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

@export_group("Consumable")
## Hunger restored when this item is eaten through PlayerHealth.request_consume_item() (task 3.8).
## Only meaningful on category == CONSUMABLE; zero is a valid "doesn't fill you up" value, not a bug.
@export_range(0.0, 100.0, 1.0) var hunger_restore: float = 0.0
## Hp restored in the same request, clamped to max_hp. Zero is a valid "food that doesn't heal."
@export_range(0, 500, 1) var hp_restore: int = 0

@export_group("First person")
## Shown in the player's hand while this item is the selected hotbar slot (F-041). A-004 exports a
## `*_viewmodel.glb` beside every `*_world.glb` for exactly this. Null means an empty hand, which is
## correct for a log or a lump of stone.
@export var view_model: PackedScene
## Where the viewmodel sits relative to the camera. Per-item on purpose: A-004's exports are
## horizontally centred with **ground-level origins**, so the grip is somewhere up the handle and
## differs by design — a 1.38 m axe and a sword do not hold the same way. Tunable in the inspector so
## a new weapon that sits wrong is three numbers, not a code change.
@export var grip_offset: Vector3 = Vector3(0.24, -0.26, -0.42)
@export var grip_rotation_degrees: Vector3 = Vector3(-8.0, 168.0, 6.0)
@export_range(0.05, 3.0, 0.01) var grip_scale: float = 0.55
