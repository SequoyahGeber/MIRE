extends SceneTree

## Headless proof for F-431 — the look-at prompt and the inventory hover card.
##
##   .agent/bin/agent godot --script tools/focus_prompt_check.gd
##
## Two halves, both windowless.
##
## First, `FocusPrompt.describe()` against hand-built props. That method takes no camera and no
## viewport precisely so this check can exist: the wording a player reads is a pure function of the
## prop's own state and the definition the host already trusts, so it can be asserted the way
## `HaulMath` is. It is also the half that catches the bug this finding is really about — a prompt
## that says "Chop" while the host's `damage_from_tool()` would return 0.
##
## Second, `ItemTooltip.build()` over the REAL shipped content. Every `content/items/*.tres` is run
## through it, which is what turns "the card works" into "the card works for every item in the
## game" — the failure mode of the string it replaced was one item with an unset field, not a
## broken layout.

const FOCUS_PROMPT_SCRIPT := preload("res://ui/hud/focus_prompt.gd")
const ITEM_TOOLTIP := preload("res://ui/inventory/item_tooltip.gd")
const HARVESTABLE_SCRIPT := preload("res://systems/harvesting/harvestable.gd")
const HARVESTABLE_DEF_SCRIPT := preload("res://systems/harvesting/harvestable_def.gd")
const WEAPON_DEF_SCRIPT := preload("res://systems/combat/weapon_def.gd")
const HARVEST_LIBRARY := preload("res://systems/harvesting/harvest_library.gd")

const ITEM_DIR: String = "res://content/items/"
const HARVESTABLE_DIR: String = "res://content/harvestables/"

var failures: int = 0
var _focus: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var registered: Node = root.get_node_or_null(^"FocusPrompt")
	check(registered != null, "FocusPrompt is registered as an autoload — a UI nothing loads is not shipped (F-051)")

	# The autoload itself polls a camera that does not exist here. Describe-only work goes through
	# a second, inert instance so this check never races that poll.
	_focus = FOCUS_PROMPT_SCRIPT.new()
	_focus.name = "FocusPromptUnderTest"
	root.add_child(_focus)
	await process_frame
	_focus.set_process(false)
	_focus.set_process_input(false)

	_check_authored_harvestable_names()
	_check_harvestable_wording()
	_check_depleted_is_not_a_target()
	_check_item_cards()

	# Freed rather than queue_freed: `quit()` on the next line means the deferred queue never runs,
	# and a check that reports leaks teaches the next reader to ignore leak warnings.
	root.remove_child(_focus)
	_focus.free()

	print("FOCUS_PROMPT_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


# ── Content ──────────────────────────────────────────────────────────────────────────────────────


## Every shipped definition names itself. The fallback in `HarvestableDef.label()` exists so a new
## one is never blank on screen, but "Wild Tree" is not a name anybody authored — leaning on it is
## the thing this check is here to stop.
func _check_authored_harvestable_names() -> void:
	print("\n-- authored harvestable names --")
	var unnamed := PackedStringArray()
	for file_name: String in _tres_in(HARVESTABLE_DIR):
		var definition: Resource = load(HARVESTABLE_DIR + file_name)
		if definition == null:
			continue
		if String(definition.get(&"display_name")).is_empty():
			unnamed.append(file_name)
		else:
			check(
				not String(definition.call(&"label")).is_empty(),
				"%s labels itself \"%s\"" % [file_name, definition.call(&"label")]
			)
	check(unnamed.is_empty(), "every harvestable definition authors a display_name (%s)" % [unnamed])


# ── Wording ──────────────────────────────────────────────────────────────────────────────────────


## The sentence the whole finding is about: hold the wrong tool and the prompt has to say so, in the
## same breath the host would refuse the swing in.
func _check_harvestable_wording() -> void:
	print("\n-- harvestable wording --")

	var definition: Resource = HARVESTABLE_DEF_SCRIPT.new()
	definition.set(&"id", &"check_pine")
	definition.set(&"display_name", "Pine")
	definition.set(&"max_health", 6)
	definition.set(&"required_tool", HARVEST_LIBRARY.Tool.CHOP)
	definition.set(&"yield_item_id", &"log")
	definition.set(&"yield_amount", 3)

	var tree: Node3D = _harvestable(definition)

	var view: Dictionary = _focus.call(&"describe", tree, FOCUS_PROMPT_SCRIPT.Kind.HARVESTABLE)
	check(String(view.get("title", "")) == "Pine", "the prompt calls it by its authored name")
	check(
		String(view.get("hint", "")).contains("3"),
		"the prompt says what it yields (%s)" % view.get("hint", "")
	)
	check(
		float(view.get("ratio", 0.0)) < 0.0,
		"an untouched prop shows no health bar — an always-full bar is noise"
	)

	# Chipped: the bar appears, and only then.
	tree.set(&"health", 3)
	view = _focus.call(&"describe", tree, FOCUS_PROMPT_SCRIPT.Kind.HARVESTABLE)
	check(
		is_equal_approx(float(view.get("ratio", -1.0)), 0.5),
		"a half-felled prop reports 0.5 (%s)" % view.get("ratio", -1.0)
	)

	# Wrong tool. `damage_from_tool()` is the host's own function, so this asserts the prompt and
	# the host agree rather than asserting a string in isolation.
	var pickaxe: Resource = _weapon(HARVEST_LIBRARY.Tool.MINE, 1)
	check(
		int(definition.call(&"damage_from_tool", HARVEST_LIBRARY.Tool.MINE, 1)) == 0,
		"a wooden pickaxe genuinely cannot chip this pine — the premise of the next assertion"
	)
	view = _focus.call(&"describe", tree, FOCUS_PROMPT_SCRIPT.Kind.HARVESTABLE)
	var blocked_action: String = _action_holding(tree, pickaxe)
	check(
		blocked_action == "Needs an axe",
		"the wrong tool is named as the missing one, not left to guesswork (%s)" % blocked_action
	)

	var axe: Resource = _weapon(HARVEST_LIBRARY.Tool.CHOP, 2)
	var allowed_action: String = _action_holding(tree, axe)
	check(
		allowed_action.begins_with("Chop"),
		"the right tool gets the verb, not a warning (%s)" % allowed_action
	)

	_free_node(tree)


## A felled tree is scenery until it respawns, and prompting for it would promise a swing that does
## nothing.
func _check_depleted_is_not_a_target() -> void:
	print("\n-- depleted props --")
	var definition: Resource = HARVESTABLE_DEF_SCRIPT.new()
	definition.set(&"id", &"check_bush")
	definition.set(&"display_name", "Bush")
	definition.set(&"max_health", 3)
	definition.set(&"yield_item_id", &"branch")

	var bush: Node3D = _harvestable(definition)
	bush.set(&"active", false)
	var view: Dictionary = _focus.call(&"describe", bush, FOCUS_PROMPT_SCRIPT.Kind.HARVESTABLE)
	check(view.is_empty(), "a depleted prop describes as nothing at all (%s)" % [view])
	_free_node(bush)


# ── The hover card ───────────────────────────────────────────────────────────────────────────────


## Every shipped item, not a sample. A card that crashes or comes out blank on one `.tres` with an
## unset field is exactly the failure the plain string used to hide.
func _check_item_cards() -> void:
	print("\n-- inventory hover cards --")
	var built: int = 0
	var blank := PackedStringArray()
	for file_name: String in _tres_in(ITEM_DIR):
		var item: ItemDef = load(ITEM_DIR + file_name) as ItemDef
		if item == null:
			continue
		var card: Control = ITEM_TOOLTIP.build(item, 1)
		if card == null or _text_of(card).strip_edges().is_empty():
			blank.append(file_name)
		else:
			built += 1
		if card != null:
			card.free()
	check(built > 0, "at least one item card was built (%d)" % built)
	check(blank.is_empty(), "no shipped item produces a blank card (%s)" % [blank])

	# The stack line is the one number the icon cannot show, so assert it directly rather than
	# trusting "not blank".
	var stackable: ItemDef = _first_item_where(func(item: ItemDef) -> bool: return item.stack_size > 1)
	if stackable != null:
		var card: Control = ITEM_TOOLTIP.build(stackable, 12)
		var text: String = _text_of(card)
		check(
			text.contains("12") and text.contains(str(stackable.stack_size)),
			"a partial stack reads as held / capacity for %s" % stackable.id
		)
		card.free()
	else:
		check(false, "no stackable item in content/items — the stack line cannot be proved")

	var empty_card: Control = ITEM_TOOLTIP.build(null, 0)
	check(
		_text_of(empty_card).contains("Empty"),
		"an empty slot still gets a card rather than a crash"
	)
	empty_card.free()


# ── Helpers ──────────────────────────────────────────────────────────────────────────────────────


## `describe()` reads the held weapon off CombatService, which needs an inventory this check has no
## business building. Assert the branch through the same definition function instead — the prompt's
## own choice between "Needs …" and the verb is one `if` over exactly this value.
func _action_holding(prop: Node3D, weapon: Resource) -> String:
	var definition: Resource = prop.get(&"definition") as Resource
	var damage: int = int(definition.call(
		&"damage_from_tool", int(weapon.get(&"tool_class")), int(weapon.get(&"harvest_power"))
	))
	if damage <= 0:
		return "Needs %s" % _focus.call(&"_tool_phrase", int(definition.get(&"required_tool")))
	return "%s with %s" % [
		_focus.call(&"_harvest_verb", int(definition.get(&"required_tool"))),
		String(weapon.get(&"display_name")),
	]


func _free_node(node: Node) -> void:
	root.remove_child(node)
	node.free()


func _harvestable(definition: Resource) -> Node3D:
	var node := Node3D.new()
	node.set_script(HARVESTABLE_SCRIPT)
	node.set(&"definition", definition)
	root.add_child(node)
	return node


func _weapon(tool_class: int, harvest_power: int) -> Resource:
	var weapon: Resource = WEAPON_DEF_SCRIPT.new()
	weapon.set(&"display_name", "Check Tool")
	weapon.set(&"tool_class", tool_class)
	weapon.set(&"harvest_power", harvest_power)
	return weapon


func _first_item_where(predicate: Callable) -> ItemDef:
	for file_name: String in _tres_in(ITEM_DIR):
		var item: ItemDef = load(ITEM_DIR + file_name) as ItemDef
		if item != null and bool(predicate.call(item)):
			return item
	return null


## Every Label in the card, flattened. The card is built from Labels rather than one RichTextLabel
## so it can wrap and align per line; this is how a check reads it back.
func _text_of(node: Node) -> String:
	var text: String = ""
	if node is Label:
		text += (node as Label).text + "\n"
	for child: Node in node.get_children():
		text += _text_of(child)
	return text


func _tres_in(directory: String) -> PackedStringArray:
	var names := PackedStringArray()
	for file_name: String in DirAccess.get_files_at(directory):
		if file_name.ends_with(".tres"):
			names.append(file_name)
	names.sort()
	return names


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
