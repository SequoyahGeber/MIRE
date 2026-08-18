class_name HookDef
extends Resource

## Static definition of one event -> function binding — the datapack-style "when X happens, run Y"
## seam docs/COMMANDS.md §5.2 asks for. Authored by hand as a .tres in content/hooks/ and loaded by
## registry.gd at boot, exactly like every other content family (RuleDef is the closest sibling).
##
## A HookDef only describes the BINDING; the function it names is separate content
## (content/functions/<function>.mcmd, COMMANDS.md §5.1). autoload/command_service.gd is what
## actually subscribes to the named event's real signal and runs the function when it fires — see
## its `_wire_hooks()` / `wire_hook()`.
##
## Network authority: none for the definition itself — every peer loads the identical content and
## agrees on what bindings EXIST. Whether one actually fires is host_only by default (below), which
## matches the shipped event vocabulary: night_started/day_started/enemy_died are all host-only
## signals today, so a hook bound to any of them only ever runs on the host/offline peer anyway.

## Event vocabulary is intentionally open text, not an enum: COMMANDS.md §5.2 names it as growing
## ("starts with what exists"), and CommandService's own `_HOOK_EVENTS` table is the single place
## that maps a name to a real signal. A HookDef naming an event with no binding there fails loudly
## at wire time (a MireLog error), not silently — see CommandService.wire_hook().
@export var id: StringName = &""
@export var event: StringName = &""

## Must match a function known to CommandService — normally a content/functions/<function>.mcmd
## file, but a check may also bind to one registered at runtime via `register_function()`.
@export var function: StringName = &""

## True by default: every event this task ships (night_started/day_started/enemy_died) is already
## host-only at the signal source (DayNight, EnemyWorld), so this flag has no live effect yet — it
## exists so a future client-presentation event (a UI flourish on `enemy_died`, say) does not need a
## new field to opt out of the host gate. `false` means "run on whichever peer the signal fired on,"
## never "run on every peer" — a hook never re-broadcasts by itself.
@export var host_only: bool = true

## Disabled by default, per COMMANDS.md §5.2 (filed as D-094 with this task): gameplay-by-hook is a
## design decision for M6's Cycle Modifiers to own, not this track. The worked example
## (content/hooks/night_siege.tres) ships with this false; flipping it is how you try it.
@export var enabled: bool = false

@export_multiline var description: String = ""


## Same shape as every other Def's validation_errors() — registry.gd calls this before indexing and
## skips anything that fails, so a malformed .tres is a named boot error rather than a hook that
## silently never fires.
func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = []
	if id == &"":
		errors.append("id is empty")
	if event == &"":
		errors.append("event is empty")
	if function == &"":
		errors.append("function is empty")
	return errors
