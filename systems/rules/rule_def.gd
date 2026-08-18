class_name RuleDef
extends Resource

## Static definition of one gamerule — a runtime knob the host can retune mid-session with
## `rule <id> <value>`, Minecraft-style. Authored by hand as a .tres in content/rules/ and loaded by
## registry.gd at boot, exactly like every other content family (docs/COMMANDS.md §4.1).
##
## A RuleDef is only the DESCRIPTION of a knob: its id, type, bounds, and default. The live value
## lives in autoload/rule_service.gd, which seeds itself from these defaults and is the only thing
## allowed to change one. Splitting it that way is what lets a rule reset to its authored default
## every boot without anybody writing persistence code (COMMANDS.md §4.2: "a run is one sitting",
## D-010).
##
## Network authority: none, same as every other content Def. Every peer loads the identical
## content/rules/*.tres and therefore agrees on what the knobs ARE; what a knob currently IS is
## host-authoritative and replicated by RuleService (ARCHITECTURE.md §2.2).

## Every value is stored as a float, whatever the declared type — one storage shape means one RPC
## shape, one clamp path, and one `rule` command instead of three. BOOL is 0/1 and INT rounds; the
## type only decides how a value is parsed on the way in and rendered on the way out.
enum Type { BOOL, INT, FLOAT }

## The id the code asks for: `RuleService.value(&"day_length_seconds")`. Must match the id used by
## the owning system, which keeps its own `@export` as the fallback (COMMANDS.md §4.3).
@export var id: StringName = &""
@export var display_name: String = ""
@export var type: Type = Type.FLOAT

## The value every peer boots with, and the value `rule <id> reset` returns to. Authored in the
## rule's own units (seconds, count, per-second rate); BOOL uses 0.0 / 1.0.
@export var default_value: float = 0.0

## Inclusive clamp applied to every set, including the default. `min_value == max_value` means
## unclamped — the spec's own convention (COMMANDS.md §4.1), and the reason this pair defaults to
## 0/0 rather than to ±INF: an author who never thinks about bounds gets an unbounded knob, not a
## knob silently pinned to zero.
@export var min_value: float = 0.0
@export var max_value: float = 0.0

## One line, shown by the `rules` listing. Say what the knob DOES, not what its default is — the
## listing already prints the value beside it.
@export_multiline var description: String = ""


## Same shape as every other Def's validation_errors() — registry.gd calls this before indexing and
## skips anything that fails, so a malformed .tres is a named boot error rather than a rule that
## silently does not exist and sends every reader back to its export fallback.
func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = []
	if id == &"":
		errors.append("id is empty")
	if display_name.is_empty():
		errors.append("display_name is empty")
	if min_value > max_value:
		errors.append("min_value (%f) is greater than max_value (%f)" % [min_value, max_value])
	if is_clamped() and (default_value < min_value or default_value > max_value):
		errors.append("default_value (%f) is outside [%f, %f]" % [default_value, min_value, max_value])
	return errors


## `min == max` is the spec's "unclamped" sentinel, so an author CAN pin a knob to a single legal
## value only by making the range degenerate — which reads as "unclamped" instead. That is a fair
## trade: a one-value rule is a constant, and a constant does not want to be a rule.
func is_clamped() -> bool:
	return min_value < max_value


## The one place a raw number becomes a legal value for this rule: clamp first, then quantize to the
## declared type. Everything that writes a value goes through here — the boot seed, the `rule`
## command, and the host's own setter — so a BOOL can never hold 0.4 and an INT can never hold 3.7,
## no matter which path set it.
func coerce(raw: float) -> float:
	var value: float = raw
	if is_clamped():
		value = clampf(value, min_value, max_value)
	match type:
		Type.BOOL:
			return 1.0 if value != 0.0 else 0.0
		Type.INT:
			return float(roundi(value))
		_:
			return value


## How the `rules` listing and every CommandResult message render this rule's value. Typed rendering
## matters more than it looks: "dev_loadout_enabled = 1" reads like a count, and an INT population
## printed as "4.0" reads like someone's rounding bug.
func format_value(value: float) -> String:
	match type:
		Type.BOOL:
			return "true" if value != 0.0 else "false"
		Type.INT:
			return str(roundi(value))
		_:
			# %.4f then trimmed: hunger_drain_per_sec is 0.0833 and must not print as "0.08", while
			# day_length_seconds is 900 and must not print as "900.0000".
			var text: String = "%.4f" % value
			text = text.rstrip("0")
			return text.rstrip(".") if text.ends_with(".") else text


func type_name() -> String:
	match type:
		Type.BOOL:
			return "bool"
		Type.INT:
			return "int"
		_:
			return "float"


## Rendered into the `rules` listing after the value, so an author retuning a knob can see the legal
## window without opening the .tres.
func range_text() -> String:
	if not is_clamped():
		return "unbounded"
	return "%s..%s" % [format_value(min_value), format_value(max_value)]
