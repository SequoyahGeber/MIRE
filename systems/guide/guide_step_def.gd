class_name GuideStepDef
extends Resource

## One line of in-run guidance — an objective, a tip, or the fanfare for a tool tier. Authored by
## hand as a .tres in content/guide/ (ARCHITECTURE.md §3.1, "content is data, not code"), loaded and
## indexed by `id` at boot like every other content family. `docs/PROGRESSION.md` §5 is the spec.
##
## Network authority: **none, and not even a little.** Guidance is presentation
## (`ARCHITECTURE.md` §2.2, "VFX, audio, camera, UI" row): each peer evaluates its own steps against
## state it already holds, and nothing here is ever sent, requested or validated. A step that wants
## to know a PARTY fact reads a replicated one (the tool tier, a Wellspring's `capped`) rather than
## asking anyone.

enum Kind {
	## The one line that says what to do next. Exactly one objective is ever on screen: the
	## eligible one with the lowest `order`. It disappears the moment it is satisfied.
	OBJECTIVE,
	## A one-shot card fired by a situation — the first tree that will not fall, the first night.
	## Shown once and then never again for this player (see `once_per_profile`).
	TIP,
}

## The predicate vocabulary. Deliberately an ENUM and deliberately small — `PROGRESSION.md` §5.4
## records the call: the moment guidance takes an expression string, game logic starts living in
## content and no check can prove coverage again. A new kind of condition is a new member here, and
## therefore a change someone reviews.
enum Condition {
	## Always true. The default `require`, and never a useful `satisfied_by`.
	ALWAYS,
	## The LOCAL player holds at least `count` of `arg`.
	HAS_ITEM,
	## The party's tool ladder has reached rung `count` (`ProgressionService`).
	TIER_REACHED,
	## At least `count` stations of kind `arg` exist in the world — a party fact: your teammate's
	## workbench advances your objective line.
	STATION_BUILT,
	## At least `count` Wellsprings are currently capped.
	WELLSPRINGS_CAPPED,
	## The run has reached Cycle `count`.
	CYCLE_AT_LEAST,
	## At least `count` bosses have been defeated in front of this peer this run.
	BOSS_KILLED,
	## It is night, right now.
	NIGHT,
	## A live enemy is within `count` metres of the local player.
	ENEMY_NEARBY,
	## The local player is looking at a harvestable their held tool cannot chip — the exact moment
	## a new player concludes the tree is broken. The single highest-value trigger in the file.
	TOOL_BLOCKED,
	## The local player is standing on corrupted ground.
	ON_CORRUPTED_GROUND,
	## The local player is downed, or bleeding out.
	SELF_DOWNED,
	## The extraction wreck is repaired and ready to board.
	SHIP_REPAIRED,
	## Never true. A step whose `satisfied_by` is this stays on screen until something else outranks
	## it — which is how the endgame line ("push a Cycle, or leave") behaves.
	NEVER,
}

@export var id: StringName = &""
@export var kind: Kind = Kind.OBJECTIVE

## What the player reads. One sentence, imperative, no lore (`ITEMS.md` R5's tone rule). Input
## actions may be written as `[interact]` and are substituted with the player's real binding at
## display time, so a rebound key is never wrong on screen.
@export_multiline var text: String = ""

## Objective sort order, low first. The eligible-and-unsatisfied step with the lowest order is the
## one on screen; ties break on `id` so the choice is stable rather than load-order dependent.
## Ignored for tips.
@export_range(0, 1000, 1) var order: int = 100

@export_group("Eligibility")
## Must hold before this step can appear at all. `ALWAYS` means "from the first frame".
@export var require: Condition = Condition.ALWAYS
@export var require_arg: StringName = &""
@export_range(0, 999, 1) var require_count: int = 1

@export_group("Completion")
## For an OBJECTIVE: what finishes it. For a TIP: what fires it.
@export var satisfied_by: Condition = Condition.ALWAYS
@export var satisfied_arg: StringName = &""
@export_range(0, 999, 1) var satisfied_count: int = 1

@export_group("Tips")
## A tip shown once per PROFILE, not once per run — a returning player is not re-taught things they
## learned three runs ago. False makes it once per run, which is right for a tip about a run-scoped
## situation (a Cycle modifier, say) and wrong for a tutorial line.
@export var once_per_profile: bool = true
## How long the card stays up. Objectives ignore this: they stay until satisfied.
@export_range(1.0, 20.0, 0.5) var seconds: float = 5.0


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if id == &"":
		errors.append("id is empty")
	if text.strip_edges().is_empty():
		errors.append("text is empty")
	if kind == Kind.TIP and satisfied_by == Condition.ALWAYS:
		errors.append("a TIP with satisfied_by = ALWAYS fires on the first frame of every run")
	if kind == Kind.TIP and satisfied_by == Condition.NEVER:
		errors.append("a TIP with satisfied_by = NEVER can never fire")
	if kind == Kind.OBJECTIVE and satisfied_by == Condition.ALWAYS:
		errors.append("an OBJECTIVE satisfied by ALWAYS is complete before it is shown")
	if _needs_arg(require) and require_arg == &"":
		errors.append("require %s needs require_arg" % Condition.keys()[require])
	if _needs_arg(satisfied_by) and satisfied_arg == &"":
		errors.append("satisfied_by %s needs satisfied_arg" % Condition.keys()[satisfied_by])
	return errors


## The two conditions that address a piece of content by id. Everything else is a count or a state.
static func _needs_arg(condition: Condition) -> bool:
	return condition == Condition.HAS_ITEM or condition == Condition.STATION_BUILT
