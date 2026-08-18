class_name PowerupDef
extends Resource

## Static definition of one powerup. Authored by hand as a .tres in content/powerups/ — see
## ARCHITECTURE.md §3.1 ("content is data, not code") and DESIGN.md §4.4. `registry.gd` loads every
## .tres in that folder at boot and indexes it by `id`.
##
## NETWORK AUTHORITY: none directly. A definition is identical on every peer and is never sent — only
## its `id` goes over the wire. Which player HOLDS how many of it is host-authoritative state and
## lives in autoload/powerup_service.gd (docs/ARCHITECTURE.md §2.2, "active modifiers" row).
##
## DESIGN.md §4.4 is the contract this shape serves: "1–2 tags", "holding 3+ of a tag triggers a
## Resonance", and "mostly data, not code — once the framework exists, new content is a resource
## file". Task 3.4 authors 40–60 of these in the inspector against the one worked example here.

## Unique key. Must match across all peers — it is what goes over the network, never the resource
## path. Convention matches content/items: lowercase, underscores.
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var icon: Texture2D

## The Resonance families this powerup counts toward — §4.4's `Fire` `Blood` `Kinetic` `Fungal`
## `Cold` `Void`. One or two, per the design; nothing here enforces two, because a future powerup
## that belongs to three families is a balance question, not a schema violation.
##
## These ARE the families: there is no second `resonance_family` field, because §4.4 keys its
## thresholds off the tags themselves and two names for one concept is how they drift apart. See
## D-044.
@export var tags: Array[StringName] = []

## How many copies of THIS powerup one player may hold. Distinct from a Resonance threshold, which
## counts a whole family across different powerups: three different Fire powerups resonate at one
## stack each.
@export_range(1, 99, 1) var max_stacks: int = 5

## Stat name -> per-stack modifier, as `Vector2(additive, multiplicative)`.
##
## `PowerupService.stat()` applies N stacks as `(base + additive * N) * (1.0 + multiplicative * N)`.
## Additive first, then multiplicative, and BOTH scale linearly with the stack count rather than
## compounding — see D-044. A `Vector2(0.0, 0.08)` on `move_speed` is "+8% per stack"; a
## `Vector2(2.0, 0.0)` on `max_hp` is "+2 flat per stack".
@export var modifiers: Dictionary[StringName, Vector2] = {}


## Same shape as LootTableDef's — registry.gd calls this before indexing and skips anything that
## fails, so a malformed .tres is a named boot error rather than a crash three systems downstream.
func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = []
	if id == &"":
		errors.append("id is empty")
	if display_name.is_empty():
		errors.append("display_name is empty")
	if max_stacks < 1:
		errors.append("max_stacks must be at least 1")
	for tag: StringName in tags:
		if tag == &"":
			errors.append("tags contains an empty entry")
	if tags.is_empty() and modifiers.is_empty():
		errors.append("does nothing: no tags and no modifiers")
	for stat_name: StringName in modifiers:
		if stat_name == &"":
			errors.append("modifiers contains an empty stat name")
	return errors
