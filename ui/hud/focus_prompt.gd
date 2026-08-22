extends CanvasLayer

## One look-at prompt for every interactable kind, plus the crosshair that says *what* you are
## looking at.
##
## ## Why this exists (F-431)
##
## Before this, a player had no way to learn that a pine is choppable, that an ore vein wants a
## pickaxe rather than an axe, or that the crate by the shore can be carried at all. Two prompts
## existed — `ui/building/door_prompt.gd` and the one inside `ui/loot/chest_ui.gd` — both proximity
## driven, both drawing their own panel at *different* screen offsets, so standing between a door
## and a chest drew two overlapping boxes. Everything else in the world was silent, and there was no
## crosshair anywhere in the game.
##
## This file replaces the guessing with one rule: **the thing under your crosshair tells you its
## name, what the swing or the key would do, and whether you are holding the wrong tool.**
##
## ## Targeting
##
## A single ray from the active camera, exactly the one `autoload/harvest_world.gd` already casts to
## decide what a swing hits — so the prompt and the swing can never disagree about the target. When
## the ray misses, a narrow aim cone falls back over every interactable group, so a crate at your
## feet still prompts — and, more importantly, so do the props that **have no collider at all**.
## That is not an edge case: `HarvestLibrary.Represent.BATCH` keeps dense flora (bushes, saplings,
## nettles) inside a chunk's MultiMesh with no body of its own, and a live probe of the procedural
## island found 208 of its 313 harvestables in exactly that state. Ray-only targeting would have
## left two thirds of the harvestable world silent — the very failure this file exists to end.
##
## The cone scan is why the poll runs at 15 Hz rather than per frame (F-099): it runs only when the
## ray found nothing, but it walks every group member when it does.
##
## ## NETWORK AUTHORITY: none (docs/ARCHITECTURE.md §2.2)
##
## Client-local presentation throughout. It reads replicated state that every peer already has
## (`Harvestable.health`, `Chest.opened`, `Haulable.carriers`, `BuildableDoor.open`) and predicts
## nothing. The one input it owns — [E] on a haulable — goes through `Haulable.request_pickup()`,
## whose host validates range and carrier count; see `_input()` for why that verb lives here.
##
## Joins nothing: it owns no cursor and blocks no input, so it is NOT part of the D-032
## `blocks_gameplay_input` interlock. It does respect it — while a cursor-owning panel is open the
## crosshair and the prompt both go away.

const MIRE_THEME := preload("res://ui/theme/mire_theme.gd")
const HARVEST_LIBRARY := preload("res://systems/harvesting/harvest_library.gd")
const ITEM_DROP := preload("res://systems/loot/item_drop.gd")

const HARVESTABLE_GROUP: StringName = &"harvestable"
const HAULABLE_GROUP: StringName = &"haulable"
const CHEST_GROUP: StringName = &"chest"
const DOOR_GROUP: StringName = &"door"
const ITEM_DROP_GROUP: StringName = &"item_drop"
const PLAYER_GROUP: StringName = &"players"
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"

## Which kind of thing the crosshair is on. Ordered by how specific the prompt is, and used by
## `tools/focus_prompt_check.gd` to assert a target without matching on English.
enum Kind { NONE, HARVESTABLE, HAULABLE, CHEST, DOOR, ITEM_DROP }

## Matches `HarvestWorld.MAX_RAY_DISTANCE_M` plus a little, so the prompt appears a step before the
## swing would connect rather than a step after — a prompt that lights up only once you are already
## in range teaches nothing.
const MAX_RAY_M: float = 5.0
## Half-angle of the fallback cone. Generous on purpose: it exists for things at your feet.
const FALLBACK_CONE_DEGREES: float = 50.0
## 15 Hz. The panel's content changes at walking speed, and a physics ray per frame on every peer is
## a cost with no readable benefit (F-099).
const POLL_SEC: float = 0.066

const PANEL_WIDTH_PX: float = 260.0
## Below the crosshair, not on it — text over the aim point is text you cannot aim through.
const PANEL_TOP_OFFSET_PX: float = 44.0
const BAR_HEIGHT_PX: float = 5.0


## The aim reticle. A dot plus four ticks, drawn rather than textured so it stays crisp at any
## resolution and costs no import. It reacts to the focus target — that reaction IS the "this is
## interactable" signal the world was missing, and it reads before any text does.
class Reticle extends Control:
	var player_colour: Color = MIRE_THEME.TEXT
	var size_scale: float = 1.0
	var opacity: float = 1.0
	var high_contrast: bool = false
	var focused: bool = false:
		set(value):
			if focused == value:
				return
			focused = value
			queue_redraw()
	## Warn state: the target is real but the held tool cannot bite it. Amber ring, not green.
	var blocked: bool = false:
		set(value):
			if blocked == value:
				return
			blocked = value
			queue_redraw()

	func _draw() -> void:
		var centre := size * 0.5
		var colour: Color = player_colour
		if focused:
			colour = MIRE_THEME.AMBER if blocked else MIRE_THEME.MOSS
		colour.a = (0.9 if focused else 0.55) * opacity

		var gap: float = (6.0 if focused else 4.0) * size_scale
		var tick: float = (5.0 if focused else 3.0) * size_scale
		var width: float = (2.0 if focused else 1.0) * size_scale
		# A dark pass under every stroke: the reticle has to stay readable against a bright sky and
		# against a black cave wall, and one colour cannot do both.
		var shadow := Color(0.0, 0.0, 0.0, colour.a * (1.0 if high_contrast else 0.6))
		for pass_index: int in 2:
			var offset: float = 1.0 if pass_index == 0 else 0.0
			var stroke: Color = shadow if pass_index == 0 else colour
			var stroke_width: float = width + 1.0 if pass_index == 0 else width
			for direction: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
				draw_line(
					centre + direction * gap + Vector2.ONE * offset,
					centre + direction * (gap + tick) + Vector2.ONE * offset,
					stroke,
					stroke_width,
				)
		draw_circle(centre, 1.5, colour)


var _root: Control
var _reticle: Reticle
var _panel: PanelContainer
var _title_label: Label
var _action_label: RichTextLabel
var _hint_label: Label
var _bar_back: ColorRect
var _bar_fill: ColorRect

var _poll_timer: float = 0.0
var _focus: Node3D
var _focus_kind: Kind = Kind.NONE
var _focus_view: Dictionary = {}


func _ready() -> void:
	# Under DoorPrompt (5) and far under ChestUI (52): this is world furniture, and any panel that
	# takes the cursor should cover it.
	layer = 4
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_build_ui()
	_apply_crosshair_settings()
	var settings: Node = get_node_or_null(^"/root/SettingsService")
	if settings != null and settings.has_signal(&"settings_changed"):
		settings.connect(&"settings_changed", _apply_crosshair_settings)
	set_process(true)


func _apply_crosshair_settings() -> void:
	if _reticle == null:
		return
	var settings: Node = get_node_or_null(^"/root/SettingsService")
	if settings == null:
		return
	_reticle.size_scale = float(settings.call(&"crosshair_size"))
	_reticle.opacity = float(settings.call(&"crosshair_opacity"))
	_reticle.player_colour = Color.from_string(String(settings.call(&"crosshair_colour")), Color.WHITE)
	_reticle.high_contrast = bool(settings.call(&"crosshair_high_contrast"))
	_reticle.queue_redraw()


func _process(delta: float) -> void:
	_poll_timer -= delta
	if _poll_timer > 0.0:
		return
	_poll_timer = POLL_SEC
	refresh_now()


## The one input this file owns. Doors and chests already route [E] themselves — `DoorPrompt` and
## `ChestUI` are autoloads with their own `_input()` and their own request calls, and duplicating
## that here would send two requests per press. Haulables had NO input path at all: `request_pickup()`
## existed and nothing in the shipped game ever called it, so every crate in the world was scenery
## (D-039 — wire it, don't write it down as someone else's job).
func _input(event: InputEvent) -> void:
	if get_viewport().is_input_handled():
		return
	if not event.is_action_pressed(&"interact"):
		return
	var focus_owner: Control = get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit or focus_owner is TextEdit:
		return
	if _blocking_ui_open():
		return
	if not try_carry_focus():
		return
	get_viewport().set_input_as_handled()


## Pick up whatever haulable is focused, or put down the one already being carried. Returns whether
## a request was actually sent, so the caller knows whether the press was consumed.
func try_carry_focus() -> bool:
	var carried: Node3D = _carried_haulable()
	if carried != null:
		carried.call(&"request_drop")
		refresh_now()
		return true
	refresh_now()
	if _focus == null or (_focus_kind != Kind.HAULABLE and _focus_kind != Kind.ITEM_DROP):
		return false
	_focus.call(&"request_pickup")
	refresh_now()
	return true


# ── Read side, for checks and for anything that wants to know what the player is looking at ──────


func focus_kind() -> int:
	return int(_focus_kind)


func focus_node() -> Node3D:
	return _focus


func focus_title() -> String:
	return String(_focus_view.get("title", ""))


func focus_action() -> String:
	return String(_focus_view.get("action", ""))


func focus_hint() -> String:
	return String(_focus_view.get("hint", ""))


## Remaining health as 0..1, or -1 when this kind of target has no progress to show.
func focus_ratio() -> float:
	return float(_focus_view.get("ratio", -1.0))


func is_prompt_visible() -> bool:
	return _panel != null and _panel.visible


func is_reticle_visible() -> bool:
	return _reticle != null and _reticle.visible


## Re-target and redraw immediately instead of waiting out `POLL_SEC`. Called on every press so the
## prompt can never act on a target the player has already looked away from.
func refresh_now() -> void:
	_focus = null
	_focus_kind = Kind.NONE
	_focus_view = {}
	if not _blocking_ui_open():
		var carried: Node3D = _carried_haulable()
		if carried != null:
			# What you are carrying outranks what you are looking at: with a crate on your shoulder
			# the only verb that matters is putting it down.
			_focus = carried
			_focus_kind = Kind.HAULABLE
		else:
			_acquire_focus()
		if _focus != null:
			_focus_view = describe(_focus, _focus_kind)
			if _focus_view.is_empty():
				_focus = null
				_focus_kind = Kind.NONE
	_render()


## What the prompt would say about `node`. Public and free of any camera or viewport so a headless
## check can assert the wording against a hand-built prop — the reason F-151's orphaned UI went
## unnoticed was that nothing could exercise it without a window.
##
## Returns an empty Dictionary when the node is not worth prompting for at all (a felled tree, an
## already-looted chest), which the caller reads as "no focus".
func describe(node: Node3D, kind: int = -1) -> Dictionary:
	if node == null or not is_instance_valid(node):
		return {}
	var resolved: Kind = _kind_of(node) if kind < 0 else (kind as Kind)
	match resolved:
		Kind.HARVESTABLE:
			return _describe_harvestable(node)
		Kind.HAULABLE:
			return _describe_haulable(node)
		Kind.CHEST:
			return _describe_chest(node)
		Kind.DOOR:
			return _describe_door(node)
		Kind.ITEM_DROP:
			return _describe_item_drop(node)
		_:
			return {}


# ── Descriptions ─────────────────────────────────────────────────────────────────────────────────


## The interesting one. A tree that needs an axe has to say so *while you are holding the pickaxe* —
## that sentence is the whole tutorial for MIRE's tool classes, and `damage_from_tool()` is the same
## function the host uses to resolve the swing, so the prompt cannot promise a hit the host refuses.
func _describe_harvestable(node: Node3D) -> Dictionary:
	if not bool(node.get(&"active")):
		return {}
	var definition: Resource = node.get(&"definition") as Resource
	if definition == null:
		return {}

	var weapon: Resource = _local_weapon()
	var tool_class: int = int(weapon.get(&"tool_class")) if weapon != null else 0
	var power: int = int(weapon.get(&"harvest_power")) if weapon != null else 0
	var damage: int = int(definition.call(&"damage_from_tool", tool_class, power))
	var required: int = int(definition.get(&"required_tool"))

	var action: String = ""
	var blocked: bool = damage <= 0
	if blocked:
		action = "Needs %s" % _tool_phrase(required)
	else:
		var held: String = String(weapon.get(&"display_name")) if weapon != null else ""
		action = "%s with %s" % [_harvest_verb(required), held] if not held.is_empty() \
			else _harvest_verb(required)

	var max_health: int = maxi(int(definition.get(&"max_health")), 1)
	var health: int = clampi(int(node.get(&"health")), 0, max_health)
	var ratio: float = float(health) / float(max_health)

	return {
		"title": String(definition.call(&"label")),
		"action": action,
		"hint": _yield_hint(definition),
		# Full health means nothing has been chipped off yet, and an untouched bar is noise.
		"ratio": ratio if health < max_health else -1.0,
		"blocked": blocked,
		"key": "",
	}


func _describe_haulable(node: Node3D) -> Dictionary:
	var definition: Resource = _haulable_def(node)
	var display_name: String = String(definition.get(&"display_name")) if definition != null else ""
	if display_name.is_empty():
		display_name = String(node.get(&"def_id")).replace("_", " ").capitalize()

	var mine: bool = bool(node.call(&"is_carrying", _local_peer_id()))
	var carriers: int = int(node.call(&"carrier_count"))
	var hint: String = ""
	if mine:
		# DESIGN.md §4.5: solo is a drag, two is full speed. Say it while the player is under the
		# weight, which is the only moment the number means anything.
		hint = "Carried together" if carriers >= 2 else "Slow alone — a second pair of hands doubles it"
	elif carriers >= 2:
		hint = "Already carried by two"
	elif carriers == 1:
		hint = "Help carry it"

	return {
		"title": display_name,
		"action": "Put down" if mine else "Pick up",
		"hint": hint,
		"ratio": -1.0,
		"blocked": carriers >= 2 and not mine,
		"key": "E",
	}


## Deliberately terse. A drop names itself and its count and nothing else — most of them are
## collected by walking over them, and the press is only the fallback for the one that rolled under
## a root. [param node] is `systems/loot/item_drop.gd`.
func _describe_item_drop(node: Node3D) -> Dictionary:
	if not bool(node.call(&"is_collectable")):
		return {}
	var amount: int = int(node.get(&"amount"))
	var title: String = String(node.call(&"display_name"))
	if amount > 1:
		title = "%s ×%d" % [title, amount]
	return {
		"title": title,
		"action": "Pick up",
		"hint": "",
		"ratio": -1.0,
		"blocked": false,
		"key": "E",
	}


func _describe_chest(node: Node3D) -> Dictionary:
	var tier: String = String(node.get(&"tier")).replace("_", " ").capitalize()
	var title: String = "%s Chest" % tier if not tier.is_empty() else "Chest"
	if bool(node.get(&"opened")):
		return {
			"title": title, "action": "Emptied", "hint": "", "ratio": -1.0,
			"blocked": true, "key": "",
		}
	var cost: int = int(node.get(&"cost_coins"))
	return {
		"title": title,
		"action": "Open",
		"hint": "Costs %d coins" % cost if cost > 0 else "",
		"ratio": -1.0,
		"blocked": false,
		"key": "E",
	}


func _describe_door(node: Node3D) -> Dictionary:
	return {
		"title": "Door",
		"action": "Close" if bool(node.get(&"open")) else "Open",
		"hint": "",
		"ratio": -1.0,
		"blocked": false,
		"key": "E",
	}


## "Chop"/"Mine"/"Gather", from `HarvestLibrary.Tool`. Gather is the honest verb for a bush: it asks
## for no tool and bare hands work.
func _harvest_verb(required_tool: int) -> String:
	match required_tool:
		HARVEST_LIBRARY.Tool.CHOP:
			return "Chop"
		HARVEST_LIBRARY.Tool.MINE:
			return "Mine"
		_:
			return "Gather"


func _tool_phrase(required_tool: int) -> String:
	match required_tool:
		HARVEST_LIBRARY.Tool.CHOP:
			return "an axe"
		HARVEST_LIBRARY.Tool.MINE:
			return "a pickaxe"
		_:
			return "a better tool"


func _yield_hint(definition: Resource) -> String:
	var item_id: StringName = StringName(String(definition.get(&"yield_item_id")))
	if item_id == &"":
		return ""
	var amount: int = maxi(int(definition.get(&"yield_amount")), 1)
	var display_name: String = String(item_id).replace("_", " ").capitalize()
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry != null:
		var item: Resource = registry.call(&"get_item", item_id) as Resource
		if item != null and not String(item.get(&"display_name")).is_empty():
			display_name = String(item.get(&"display_name"))
	return "Yields %s ×%d" % [display_name, amount]


# ── Targeting ────────────────────────────────────────────────────────────────────────────────────


func _acquire_focus() -> void:
	var camera: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null or camera.get_world_3d() == null:
		return
	var origin: Vector3 = camera.global_position
	var forward: Vector3 = -camera.global_basis.z

	var query := PhysicsRayQueryParameters3D.create(origin, origin + forward * MAX_RAY_M)
	query.collide_with_areas = true
	var player_body: CollisionObject3D = _local_player() as CollisionObject3D
	if player_body != null:
		query.exclude = [player_body.get_rid()]
	var hit: Dictionary = camera.get_world_3d().direct_space_state.intersect_ray(query)
	var interactable: Node3D = _interactable_ancestor(hit.get("collider") as Node)
	if interactable != null:
		_focus = interactable
		_focus_kind = _kind_of(interactable)
		return
	_acquire_fallback(origin, forward)


## Every group, best-aligned wins. See the file header for why harvestables are in here despite
## being the largest group by an order of magnitude.
func _acquire_fallback(origin: Vector3, forward: Vector3) -> void:
	var cone: float = cos(deg_to_rad(FALLBACK_CONE_DEGREES))
	var best_dot: float = cone
	for group: StringName in [ITEM_DROP_GROUP, DOOR_GROUP, CHEST_GROUP, HAULABLE_GROUP, HARVESTABLE_GROUP]:
		for node: Node in get_tree().get_nodes_in_group(group):
			var candidate := node as Node3D
			if candidate == null or not candidate.is_inside_tree():
				continue
			var offset: Vector3 = candidate.global_position - origin
			var distance: float = offset.length()
			if distance > _reach_of(candidate, group) or distance < 0.001:
				continue
			var alignment: float = forward.dot(offset / distance)
			if alignment <= best_dot:
				continue
			best_dot = alignment
			_focus = candidate
			_focus_kind = _kind_of(candidate)


## Each interactable states its own reach, so the prompt can never offer an interaction the host
## would refuse — the rule `ui/building/door_prompt.gd` already followed for doors.
func _reach_of(node: Node3D, group: StringName) -> float:
	match group:
		ITEM_DROP_GROUP:
			# The drop's own manual reach, and only once it has armed — an item still popping out of
			# the stump would refuse the press, so prompting for it teaches the wrong thing.
			if not bool(node.call(&"is_collectable")):
				return 0.0
			return ITEM_DROP.MANUAL_PICKUP_RANGE_M
		DOOR_GROUP:
			return float(node.get(&"interact_range_m"))
		CHEST_GROUP:
			return float(node.get(&"request_range_m"))
		HAULABLE_GROUP:
			var definition: Resource = _haulable_def(node)
			return float(definition.get(&"pickup_range_m")) if definition != null else 2.5
		HARVESTABLE_GROUP:
			# The prop's own `request_range_m`, and only while it is still standing — a depleted
			# bush is scenery, and describing it would cost a Dictionary per poll to throw away.
			var harvest_def: Resource = node.get(&"definition") as Resource
			if harvest_def == null or not bool(node.get(&"active")):
				return 0.0
			return float(harvest_def.get(&"request_range_m"))
		_:
			return 0.0


func _interactable_ancestor(collider: Node) -> Node3D:
	var cursor: Node = collider
	while cursor != null:
		if _kind_of(cursor) != Kind.NONE:
			return cursor as Node3D
		cursor = cursor.get_parent()
	return null


func _kind_of(node: Node) -> Kind:
	if node == null or not node is Node3D:
		return Kind.NONE
	# Doors before harvestables: a wooden door is in neither group twice today, but a future
	# breakable one would be, and "open it" beats "chop it" when both are true.
	if node.is_in_group(ITEM_DROP_GROUP):
		return Kind.ITEM_DROP
	if node.is_in_group(DOOR_GROUP):
		return Kind.DOOR
	if node.is_in_group(CHEST_GROUP):
		return Kind.CHEST
	if node.is_in_group(HAULABLE_GROUP):
		return Kind.HAULABLE
	if node.is_in_group(HARVESTABLE_GROUP):
		return Kind.HARVESTABLE
	return Kind.NONE


func _carried_haulable() -> Node3D:
	var peer_id: int = _local_peer_id()
	if peer_id <= 0:
		return null
	for node: Node in get_tree().get_nodes_in_group(HAULABLE_GROUP):
		var haulable := node as Node3D
		if haulable == null or not haulable.has_method(&"is_carrying"):
			continue
		if bool(haulable.call(&"is_carrying", peer_id)):
			return haulable
	return null


func _haulable_def(node: Node3D) -> Resource:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return null
	return registry.call(&"get_haulable", StringName(String(node.get(&"def_id")))) as Resource


## The weapon the local peer would swing right now — the same answer `CombatService` gives the host,
## fetched through the node path rather than the bare autoload name so a `--script` harness that
## boots without autoloads gets a null instead of a parse-time failure.
func _local_weapon() -> Resource:
	var combat: Node = get_node_or_null(^"/root/CombatService")
	var inventory_ui: Node = get_node_or_null(^"/root/InventoryUI")
	if combat == null or inventory_ui == null:
		return null
	var slot: int = int(inventory_ui.call(&"selected_hotbar_slot"))
	return combat.call(&"weapon_for_hotbar_index", slot) as Resource


func _local_peer_id() -> int:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport != null and bool(transport.call(&"is_active")):
		return multiplayer.get_unique_id()
	return 1


## The body in `&"players"` this peer has authority over — the same lookup `ChestUI` and `DoorPrompt`
## use. PlayerNet indexes by peer id and has no "which one is mine" accessor, and authority is the
## honest answer in both offline and session play.
func _local_player() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(PLAYER_GROUP):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null


func _blocking_ui_open() -> bool:
	for node: Node in get_tree().get_nodes_in_group(BLOCKING_UI_GROUP):
		if node is CanvasItem and (node as CanvasItem).visible:
			return true
		if node.has_method(&"is_open") and bool(node.call(&"is_open")):
			return true
	return false


# ── Presentation ─────────────────────────────────────────────────────────────────────────────────


func _render() -> void:
	if _root == null:
		return
	var blocked_ui: bool = _blocking_ui_open()
	_reticle.visible = not blocked_ui
	_reticle.focused = _focus != null
	_reticle.blocked = bool(_focus_view.get("blocked", false))

	if _focus == null or blocked_ui:
		_panel.visible = false
		return

	_title_label.text = focus_title()
	var key: String = String(_focus_view.get("key", ""))
	var action: String = focus_action()
	if action.is_empty():
		_action_label.visible = false
	else:
		_action_label.visible = true
		var accent: Color = MIRE_THEME.AMBER if bool(_focus_view.get("blocked", false)) \
			else MIRE_THEME.MOSS
		if key.is_empty():
			_action_label.text = "[center][color=#%s]%s[/color][/center]" % [
				accent.to_html(false), action,
			]
		else:
			_action_label.text = "[center][color=#%s][%s][/color]  %s[/center]" % [
				MIRE_THEME.AMBER.to_html(false), key, action,
			]

	# Keep yield information in the description/API, but suppress it visually while blocked: the
	# missing-tool correction is the only useful next sentence in that state.
	var hint: String = "" if bool(_focus_view.get("blocked", false)) else focus_hint()
	_hint_label.visible = not hint.is_empty()
	_hint_label.text = hint

	var ratio: float = focus_ratio()
	_bar_back.visible = ratio >= 0.0
	if ratio >= 0.0:
		_bar_fill.anchor_right = clampf(ratio, 0.0, 1.0)
		_bar_fill.color = MIRE_THEME.MOSS.lerp(MIRE_THEME.ERROR, 1.0 - clampf(ratio, 0.0, 1.0))
	_panel.visible = true


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "FocusPromptRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_reticle = Reticle.new()
	_reticle.name = "Reticle"
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reticle.set_anchors_preset(Control.PRESET_CENTER)
	_reticle.custom_minimum_size = Vector2(32.0, 32.0)
	_reticle.size = Vector2(32.0, 32.0)
	_reticle.offset_left = -16.0
	_reticle.offset_top = -16.0
	_reticle.offset_right = 16.0
	_reticle.offset_bottom = 16.0
	_root.add_child(_reticle)

	_panel = PanelContainer.new()
	_panel.name = "Prompt"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -PANEL_WIDTH_PX * 0.5
	_panel.offset_right = PANEL_WIDTH_PX * 0.5
	_panel.offset_top = PANEL_TOP_OFFSET_PX
	_panel.offset_bottom = PANEL_TOP_OFFSET_PX
	_panel.grow_vertical = Control.GROW_DIRECTION_END

	var style := StyleBoxFlat.new()
	style.bg_color = MIRE_THEME.PANEL
	style.bg_color.a = 0.88
	style.border_color = MIRE_THEME.BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(MIRE_THEME.RADIUS_FIELD)
	style.set_content_margin_all(10)
	_panel.add_theme_stylebox_override("panel", style)
	_root.add_child(_panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(column)

	_title_label = Label.new()
	_title_label.name = "Title"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", MIRE_THEME.BODY)
	_title_label.add_theme_color_override("font_color", MIRE_THEME.TEXT)
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_title_label)

	_action_label = RichTextLabel.new()
	_action_label.name = "Action"
	_action_label.bbcode_enabled = true
	_action_label.fit_content = true
	_action_label.scroll_active = false
	_action_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_action_label.add_theme_color_override("default_color", MIRE_THEME.TEXT)
	_action_label.add_theme_font_size_override("normal_font_size", MIRE_THEME.CAPTION + 1)
	column.add_child(_action_label)

	_bar_back = ColorRect.new()
	_bar_back.name = "HealthBar"
	# Darker than MireTheme.FIELD: the bar sits *inside* an already-dark panel, and the empty half of
	# a half-felled tree has to read as empty rather than as more panel.
	_bar_back.color = Color(0.0, 0.0, 0.0, 0.45)
	_bar_back.custom_minimum_size = Vector2(0.0, BAR_HEIGHT_PX)
	_bar_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_back.visible = false
	column.add_child(_bar_back)

	_bar_fill = ColorRect.new()
	_bar_fill.name = "HealthFill"
	_bar_fill.color = MIRE_THEME.MOSS
	_bar_fill.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_bar_fill.anchor_right = 1.0
	_bar_fill.offset_right = 0.0
	_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_back.add_child(_bar_fill)

	_hint_label = Label.new()
	_hint_label.name = "Hint"
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.add_theme_font_size_override("font_size", MIRE_THEME.CAPTION)
	_hint_label.add_theme_color_override("font_color", MIRE_THEME.MUTED)
	_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_label.visible = false
	column.add_child(_hint_label)

	_panel.visible = false


## True when the player is looking at something their held tool cannot chip — the "Needs an axe"
## state `_describe_harvestable()` computes for the prompt. Exposed for `GuideService`'s
## `TOOL_BLOCKED` condition (task 3.19): that tip has to fire at exactly the moment this prompt
## turns amber, and re-deriving the answer there would be a second copy of the host's own
## `damage_from_tool()` call — the one thing this file exists to keep singular.
func focus_is_blocked() -> bool:
	return bool(_focus_view.get("blocked", false))
