extends SceneTree

## Rendered proof for F-431 — what the two new pieces of UI actually look like.
##
##   .agent/bin/agent godot --windowed --script tools/focus_prompt_shot.gd
##
## `tools/focus_prompt_check.gd` proves the *wording*; nothing but pixels proves that the reticle is
## visible against the world, that the panel sits below the aim point rather than over it, and that
## the hover card is legible. Windowed because a framebuffer is required to read back (F-077).
##
## Three shots: a tree you can chop, the same tree while holding the wrong tool and half felled, and
## the inventory hover card for a weapon.

const FOCUS_PROMPT_SCRIPT := preload("res://ui/hud/focus_prompt.gd")
const ITEM_TOOLTIP := preload("res://ui/inventory/item_tooltip.gd")
const HARVESTABLE_SCRIPT := preload("res://systems/harvesting/harvestable.gd")

const READY_PATH: String = "/tmp/mire_focus_prompt_ready.png"
const BLOCKED_PATH: String = "/tmp/mire_focus_prompt_blocked.png"
const TOOLTIP_PATH: String = "/tmp/mire_item_tooltip.png"

var _focus: Node


func _initialize() -> void:
	_render.call_deferred()


func _render() -> void:
	_resize(Vector2i(1280, 720))
	await process_frame
	await process_frame

	_focus = root.get_node(^"FocusPrompt")

	# A lit ground plane behind the reticle. A prompt shot against the void proves nothing about
	# readability, which is the whole reason this file renders instead of asserting.
	_build_backdrop()

	var definition: Resource = load("res://content/harvestables/wild_tree.tres")
	var tree: Node3D = Node3D.new()
	tree.set_script(HARVESTABLE_SCRIPT)
	tree.set(&"definition", definition)
	tree.position = Vector3(0.0, 0.0, -3.0)
	root.add_child(tree)
	await process_frame

	# Holding an axe. `describe()` reads the live hotbar, which this file has no inventory to fill,
	# so the ready state is composed the way the player would see it and rendered through the same
	# path — see `_show()`.
	var ready: Dictionary = _focus.call(&"describe", tree, FOCUS_PROMPT_SCRIPT.Kind.HARVESTABLE)
	ready["action"] = "Chop with Stone Axe"
	ready["blocked"] = false
	_show(tree, FOCUS_PROMPT_SCRIPT.Kind.HARVESTABLE, ready)
	await _save(READY_PATH)

	# Half felled, and the wrong tool in hand: the bar appears and the action line turns into the
	# instruction. Forced rather than driven through an inventory — this file renders states, the
	# check next door proves they are reachable.
	tree.set(&"health", 3)
	var view: Dictionary = _focus.call(&"describe", tree, FOCUS_PROMPT_SCRIPT.Kind.HARVESTABLE)
	view["action"] = "Needs an axe"
	view["blocked"] = true
	_show(tree, FOCUS_PROMPT_SCRIPT.Kind.HARVESTABLE, view)
	await _save(BLOCKED_PATH)

	_focus.visible = false
	await _render_tooltip()
	quit(0)


func _render_tooltip() -> void:
	var item: ItemDef = load("res://content/items/stone_axe.tres") as ItemDef
	var layer := CanvasLayer.new()
	layer.layer = 90
	root.add_child(layer)

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.04, 0.03, 1.0)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(backdrop)

	var card: Control = ITEM_TOOLTIP.build(item, 1)
	card.position = Vector2(480.0, 240.0)
	layer.add_child(card)
	await _save(TOOLTIP_PATH)


## Drives the autoload's own render path with a target it would otherwise have to raycast for —
## there is no player and no camera pivot here, and building one would prove the map, not the UI.
func _show(node: Node3D, kind: int, view: Dictionary = {}) -> void:
	_focus.set(&"_focus", node)
	_focus.set(&"_focus_kind", kind)
	_focus.set(&"_focus_view", view if not view.is_empty() else _focus.call(&"describe", node, kind))
	_focus.call(&"_render")
	# The poll would immediately re-target off a camera that does not exist and blank all of that.
	_focus.set_process(false)


func _build_backdrop() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 1
	root.add_child(layer)
	var gradient := ColorRect.new()
	gradient.set_anchors_preset(Control.PRESET_FULL_RECT)
	gradient.color = Color(0.31, 0.38, 0.29, 1.0)
	layer.add_child(gradient)
	var sky := ColorRect.new()
	sky.set_anchors_preset(Control.PRESET_TOP_WIDE)
	sky.anchor_bottom = 0.45
	sky.color = Color(0.62, 0.70, 0.74, 1.0)
	layer.add_child(sky)


func _resize(window_size: Vector2i) -> void:
	root.content_scale_size = window_size
	root.size = window_size


func _save(path: String) -> bool:
	await process_frame
	await process_frame
	await process_frame
	var image: Image = root.get_texture().get_image()
	var error: Error = image.save_png(path)
	if error != OK:
		push_error("focus prompt screenshot failed: %s" % error_string(error))
		quit(1)
		return false
	print("FOCUS_PROMPT_SHOT %s %dx%d" % [path, image.get_width(), image.get_height()])
	return true
