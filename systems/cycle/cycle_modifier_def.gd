class_name CycleModifierDef
extends Resource

## Static definition of one Cycle Modifier — DESIGN.md §5.1 item 2, "a Cycle Modifier is drawn from
## a deck and announced." Authored by hand as a .tres in content/cycle_modifiers/ (D-006 content
## family), one at a time (AGENTS.md — never bulk-generate content data).
##
## A CycleModifierDef is only the DESCRIPTION of a modifier: its id, flavor, when it may enter the
## deck, how likely it is relative to other eligible modifiers, and which tags block it. Framework
## only — task 6.2's scope is deck/draw/stacking/weighting/tags, not wiring any modifier's actual
## gameplay effect into PowerupService/WaveSpawner/MireGrid; that is a consumer task querying
## `CycleModifierService.has_modifier(id)` or subscribing to its EventBus signal (see that file's
## header and docs/SPECS.md §6.2).
##
## Network authority: none, same as every other content Def (ARCHITECTURE.md §2.2) — every peer
## loads the identical content/cycle_modifiers/*.tres and agrees on what modifiers EXIST. Which ones
## are currently drawn is host-authoritative state, owned by CycleModifierService.

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""

## Cycle-weighted rule #1 (eligibility): the deck will not offer this modifier before this Cycle.
## DESIGN.md's own example table implies early-game modifiers ("Long Night") and late-game ones
## ("Bloom", "The Hunt") are not equally likely at Cycle 2 vs Cycle 9 — this is that knob.
@export var min_cycle: int = 1

## Cycle-weighted rule #2 (likelihood): relative draw weight the Cycle this modifier first becomes
## eligible (`min_cycle`). Must be positive — a modifier with zero pull could never be drawn and
## should not be in the deck at all.
@export var base_weight: float = 1.0

## Added to `base_weight` once per Cycle past `min_cycle` — the "chaos increases over time" half of
## DESIGN.md §5.1 ("Cycle 9 is chaotic in a way you couldn't design by hand"). Zero by default (flat
## weight once eligible); may be negative for a modifier that fits best right at `min_cycle` and
## should fade out relative to its peers deeper in the run. The floor is 0 — see `weight_at()`.
@export var weight_growth_per_cycle: float = 0.0

## Incompatibility tags (DESIGN.md Q7 mitigation: "tag modifiers as incompatible"). `tags` is what
## this modifier IS; `incompatible_tags` is what it refuses to stack alongside. The check in
## CycleModifierService is symmetric — a candidate is blocked if any of its own `incompatible_tags`
## is already active, OR if any of its own `tags` appears in an already-active modifier's
## `incompatible_tags` — so two authors adding opposite modifiers only need one of them to declare
## the exclusion, not both.
@export var tags: Array[StringName] = []
@export var incompatible_tags: Array[StringName] = []

## Explicit id-level exclusion, for the rare pair that should never stack together but shares no
## natural tag worth inventing. Checked in addition to the tag rules above, not instead of them.
@export var incompatible_with: Array[StringName] = []


## Same shape as every other Def's validation_errors() — the loader calls this before indexing and
## skips anything that fails, so a malformed .tres is a named boot error, not a modifier that
## silently never enters the deck.
func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = []
	if id == &"":
		errors.append("id is empty")
	if display_name.is_empty():
		errors.append("display_name is empty")
	if min_cycle < 1:
		errors.append("min_cycle (%d) must be >= 1" % min_cycle)
	if base_weight <= 0.0:
		errors.append("base_weight (%f) must be > 0" % base_weight)
	return errors


## This modifier's draw weight at the given Cycle, or 0.0 if it is not yet eligible (`cycle <
## min_cycle`) or its growth has driven it non-positive. Never negative — a candidate with zero
## weight is simply excluded from the draw, not given a negative pull.
func weight_at(cycle: int) -> float:
	if cycle < min_cycle:
		return 0.0
	return maxf(0.0, base_weight + weight_growth_per_cycle * float(cycle - min_cycle))
