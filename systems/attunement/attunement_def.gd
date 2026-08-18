class_name AttunementDef
extends Resource

## Static definition of one Attunement — DESIGN.md §4.5's "roles without classes". Authored by hand
## as a .tres in content/attunements/ (D-006) and loaded by autoload/registry.gd at boot, same shape
## as PowerupDef/StationDef.
##
## NETWORK AUTHORITY: none directly. A definition is identical on every peer and never sent — only
## its `id` goes over the wire. Which run-player picked which one is host-authoritative state and
## lives in autoload/attunement_service.gd (docs/ARCHITECTURE.md §2.2, "Attunement selection" row).
##
## task 3.9's spec is explicit: "Effects are PowerupService modifiers granted at selection —
## attunement is *data over 3.3*, zero new stat plumbing." So an AttunementDef carries NO modifiers
## of its own — `granted_powerup_id` names an ordinary PowerupDef (content/powerups/, max_stacks 1,
## no §4.4 tags — an Attunement is not part of the Resonance system) that AttunementService grants
## through PowerupService.host_grant() the moment a pick is locked in. See D-045 for why the
## qualitative, non-stat halves of DESIGN §4.5's table (Warden's taunts, Tinker's Ward turrets,
## Forager's terrain sight, Reaver's Ward lockout) are not represented here.

## Unique key. Must match across all peers — it is what goes over the network alongside the peer id,
## never the resource path. Convention matches content/items and content/powerups: lowercase,
## underscores.
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var icon: Texture2D

## DESIGN §4.5's two-column table, kept as flavour text the selection UI renders verbatim. Not a
## structured stat list — the stats that ARE implemented already say so through the modifiers on
## `granted_powerup_id`'s PowerupDef; this is the sentence for the parts that are not (yet) code.
@export var better_at: String = ""
@export var worse_at: String = ""

## The PowerupDef (content/powerups/) this Attunement grants one stack of on selection. Must resolve
## through Registry.get_powerup() — AttunementService.host_grant() warns and refuses cleanly if it
## does not, the same way PowerupService.host_grant() already handles an unknown id.
@export var granted_powerup_id: StringName = &""


## Same shape as PowerupDef/LootTableDef's — registry.gd calls this before indexing and skips
## anything that fails, so a malformed .tres is a named boot error rather than a crash three systems
## downstream.
func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = []
	if id == &"":
		errors.append("id is empty")
	if display_name.is_empty():
		errors.append("display_name is empty")
	if granted_powerup_id == &"":
		errors.append("granted_powerup_id is empty — an Attunement with no backing PowerupDef grants nothing")
	return errors
