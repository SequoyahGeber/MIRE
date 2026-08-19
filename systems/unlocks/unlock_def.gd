class_name UnlockDef
extends Resource

## Static definition of one purchasable meta-progression unlock. Authored by hand as a .tres in
## content/unlocks/ — see ARCHITECTURE.md §3.1 ("content is data, not code") and DESIGN.md §4.6.
## `registry.gd` loads every .tres in that folder at boot and indexes it by `id`.
##
## DESIGN.md §4.6's hard rule: "Salvage unlocks variety, never power." This schema is how that rule
## is enforced structurally rather than by convention — there is no numeric stat/bonus field
## anywhere on this resource, so "+5% damage" is not a thing an author can save into this file, the
## same shape D-044 already used to make a stray stat impossible to author onto PowerupDef.
##
## NETWORK AUTHORITY: none directly — identical on every peer, never sent, only ever referenced by
## `id`. Whether one has been PURCHASED is per-player account state and lives in
## autoload/unlock_service.gd (docs/ARCHITECTURE.md §2.2, "Unlocks" row) — the same "definition vs.
## live state" split RuleDef/RuleService and HookDef/CommandService already use.

## DESIGN.md §4.6's own list of what Salvage may unlock, verbatim: "new powerups in the pool, new
## Attunements, new POI types, new enemy types, new Cycle Modifiers, new island modifiers,
## cosmetics, new starting loadout options (sidegrades)." A category outside this closed set is a
## typo that can never be checked for consistently — same reasoning `PowerupDef.KNOWN_FAMILIES`
## already uses for Resonance tags.
const KNOWN_CATEGORIES: Array[StringName] = [
	&"powerup", &"attunement", &"poi", &"enemy", &"cycle_modifier", &"island_modifier",
	&"cosmetic", &"loadout",
]

## Unique key. Must match across all peers — it is what a future gate check compares, never the
## resource path. Convention matches every other content family: lowercase, underscores.
@export var id: StringName = &""
@export var category: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
## Salvage cost. Always positive — a free row is not a Salvage sink and defeats the point of the
## tree (nothing to spend toward).
@export_range(0, 99999, 1) var cost: int = 0
## The id of the content this unlock reveals — a PowerupDef/AttunementDef/PoiDef/etc id in the
## family named by `category`. Left empty for a cosmetic/loadout row that has no gated content id
## of its own (e.g. a colour swatch) — the same "not every field applies to every row" shape
## RuleDef's bounds fields already use.
@export var gates_id: StringName = &""


## Same shape as every sibling Def — registry.gd calls this before indexing and skips anything that
## fails, so a malformed .tres is a named boot error rather than a crash three systems downstream.
func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if id == &"":
		errors.append("id is empty")
	if display_name.is_empty():
		errors.append("display_name is empty")
	if category == &"":
		errors.append("category is empty")
	elif not KNOWN_CATEGORIES.has(category):
		errors.append("category '%s' is not a known §4.6 kind (%s)" % [
			category, ", ".join(KNOWN_CATEGORIES)
		])
	if cost <= 0:
		errors.append("cost must be positive — a free unlock is not a Salvage sink")
	return errors
