extends PanelContainer

## The card that appears when the cursor rests on an inventory or hotbar slot.
##
## ## Why this replaced a string (F-431)
##
## `InventorySlot` set `tooltip_text` to "name\ndescription" and let Godot draw its default tooltip.
## That answered the one question the player already knew the answer to — the icon is right there —
## and none of the ones they actually hover to ask: *is this axe better than the one I'm holding?
## how many fit in a stack? how much hunger does this mushroom fix? does this pickaxe even work on
## trees?* Every one of those numbers was already authored on `ItemDef`/`WeaponDef` and simply never
## shown.
##
## So this reads the same definitions the host reads. `harvest_power` in particular is printed as
## what it means — "Chop · power 2" — because MIRE's whole tool-class rule (F-113: a pickaxe never
## fells a tree) is invisible without it, and the world prompt in `ui/hud/focus_prompt.gd` is the
## only other place it surfaces.
##
## ## NETWORK AUTHORITY: none
##
## Presentation over immutable content resources, identical on every peer.

const MIRE_THEME := preload("res://ui/theme/mire_theme.gd")
const HARVEST_LIBRARY := preload("res://systems/harvesting/harvest_library.gd")

const MAX_WIDTH_PX: float = 300.0

## Human labels for `ItemDef.Category`, in enum order. Indexed, not matched, so a new category is a
## compile-visible one-line edit rather than a silent fall-through to "Resource".
const CATEGORY_NAMES: PackedStringArray = ["Resource", "Tool", "Weapon", "Consumable"]

var _column: VBoxContainer


## Builds the whole card for `item`. `amount` is what the hovered stack actually holds, so the stack
## line can read "12 / 99" rather than a lone capacity the player has to compare by hand.
static func build(item: ItemDef, amount: int) -> Control:
	var tooltip := new()
	tooltip._compose(item, amount)
	return tooltip


func _compose(item: ItemDef, amount: int) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = MIRE_THEME.PANEL
	style.border_color = MIRE_THEME.BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(MIRE_THEME.RADIUS_FIELD)
	style.set_content_margin_all(10)
	add_theme_stylebox_override("panel", style)
	custom_minimum_size = Vector2(180.0, 0.0)
	# Godot sizes a custom tooltip to its content and will happily let a long description run off
	# the screen edge; the wrap below only bites if the card is bounded first.
	size = Vector2(MAX_WIDTH_PX, 0.0)

	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 4)
	add_child(_column)

	if item == null:
		_add_title("Empty slot", MIRE_THEME.MUTED)
		return

	_add_title(item.display_name if not item.display_name.is_empty() else String(item.id),
		MIRE_THEME.TEXT)
	_add_caption(_category_line(item), MIRE_THEME.AMBER)

	if not item.description.is_empty():
		_add_rule()
		_add_body(item.description, MIRE_THEME.MUTED)

	var stats: PackedStringArray = _stat_lines(item, amount)
	if not stats.is_empty():
		_add_rule()
		for line: String in stats:
			_add_caption(line, MIRE_THEME.TEXT)


## Category, plus the attack style for anything that swings — "Weapon · Slash" says more about how a
## sword plays than the word "Weapon" does on its own.
func _category_line(item: ItemDef) -> String:
	var index: int = int(item.category)
	var category: String = CATEGORY_NAMES[index] if index >= 0 and index < CATEGORY_NAMES.size() \
		else "Item"
	var style: String = _attack_style_name(item.attack_style)
	return category if style.is_empty() else "%s · %s" % [category, style]


## The numbers, in the order a player asks for them: what it does in a fight, what it does to the
## world, what it does to your hunger, and how many of it you can hold.
func _stat_lines(item: ItemDef, amount: int) -> PackedStringArray:
	var lines := PackedStringArray()
	var registry: Node = _registry()

	var weapon: Resource = null
	var ranged: Resource = null
	if registry != null:
		weapon = registry.call(&"get_weapon", item.id) as Resource
		ranged = registry.call(&"get_ranged_weapon", item.id) as Resource

	if weapon != null:
		lines.append("Damage  %d" % int(weapon.get(&"damage")))
		lines.append("Reach  %.1f m" % float(weapon.get(&"range_m")))
		lines.append("Swing  %.2f s" % float(weapon.call(&"swing_seconds")))
		var power: int = int(weapon.get(&"harvest_power"))
		var tool_class: int = int(weapon.get(&"tool_class"))
		if power > 0 and tool_class != HARVEST_LIBRARY.Tool.NONE:
			lines.append("%s  power %d" % [_tool_class_name(tool_class), power])
	elif ranged != null:
		lines.append("Damage  %d" % int(ranged.get(&"damage")))
		lines.append("Range  %.0f m" % float(ranged.get(&"max_range_m")))
		lines.append("Draw  %.2f s" % float(ranged.get(&"draw_seconds")))
		var ammo: StringName = StringName(String(ranged.get(&"ammo_item_id")))
		if ammo != &"":
			lines.append("Ammo  %s" % _item_name(registry, ammo))

	if item.category == ItemDef.Category.CONSUMABLE:
		if item.hunger_restore > 0.0:
			lines.append("Restores  %d hunger" % roundi(item.hunger_restore))
		if item.hp_restore > 0:
			lines.append("Heals  %d hp" % item.hp_restore)

	if item.stack_size > 1:
		lines.append("Stack  %d / %d" % [maxi(amount, 0), item.stack_size])
	return lines


## `get_node_or_null()` is not available here: Godot builds a custom tooltip and only parents it
## afterwards, so this Control is outside the tree for the whole of `_compose()`. Reach the autoload
## through the SceneTree's root instead, and tolerate its absence so a headless check that never
## booted the autoloads still gets a card.
func _registry() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(^"Registry")


func _tool_class_name(tool_class: int) -> String:
	match tool_class:
		HARVEST_LIBRARY.Tool.CHOP:
			return "Chop"
		HARVEST_LIBRARY.Tool.MINE:
			return "Mine"
		_:
			return "Harvest"


func _attack_style_name(style: int) -> String:
	match style:
		ItemDef.AttackStyle.CHOP:
			return "Chop"
		ItemDef.AttackStyle.SMASH:
			return "Smash"
		ItemDef.AttackStyle.SLASH:
			return "Slash"
		ItemDef.AttackStyle.THRUST:
			return "Thrust"
		_:
			return ""


func _item_name(registry: Node, item_id: StringName) -> String:
	if registry != null:
		var item: Resource = registry.call(&"get_item", item_id) as Resource
		if item != null and not String(item.get(&"display_name")).is_empty():
			return String(item.get(&"display_name"))
	return String(item_id).replace("_", " ").capitalize()


func _add_title(text: String, colour: Color) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", MIRE_THEME.BODY)
	label.add_theme_color_override("font_color", colour)
	_column.add_child(label)


func _add_caption(text: String, colour: Color) -> void:
	if text.is_empty():
		return
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", MIRE_THEME.CAPTION)
	label.add_theme_color_override("font_color", colour)
	_column.add_child(label)


func _add_body(text: String, colour: Color) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(MAX_WIDTH_PX - 20.0, 0.0)
	label.add_theme_font_size_override("font_size", MIRE_THEME.CAPTION)
	label.add_theme_color_override("font_color", colour)
	_column.add_child(label)


func _add_rule() -> void:
	var rule := ColorRect.new()
	rule.color = MIRE_THEME.BORDER
	rule.color.a = 0.5
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	_column.add_child(rule)
