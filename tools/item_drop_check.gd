extends SceneTree

## Headless proof for F-535: a harvest yield becomes a physical drop, the drop pays out on proximity
## or on [E], and a refused grant leaves the item lying there instead of voiding it.
##
## Uses the real Registry, InventoryService and ItemDropService autoloads, with a fake player body in
## the `players` group standing in for a spawned one — the drop identifies collectors by a body's
## multiplayer authority, which is exactly what a real player node carries.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const ITEM_DEF_SCRIPT := preload("res://systems/inventory/item_def.gd")
const ITEM_DROP_SCRIPT := preload("res://systems/loot/item_drop.gd")
const FOCUS_PROMPT_SCRIPT := preload("res://ui/hud/focus_prompt.gd")

const TEST_ITEM_ID: StringName = &"check_drop_log"

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var registry: Node = root.get_node_or_null(^"Registry")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var drops: Node = root.get_node_or_null(^"ItemDropService")
	check(registry != null, "Registry autoload exists")
	check(inventory != null, "InventoryService autoload exists")
	check(drops != null, "ItemDropService autoload is registered")
	if registry == null or inventory == null or drops == null:
		finish()
		return

	# F-060: read, mutate, .set() back — Registry.items is strictly typed.
	var item: Resource = ITEM_DEF_SCRIPT.new()
	item.set("id", TEST_ITEM_ID)
	item.set("display_name", "Check Log")
	var icon := PlaceholderTexture2D.new()
	icon.size = Vector2(64, 64)
	item.set("icon", icon)
	var items: Dictionary = registry.get("items")
	items[TEST_ITEM_ID] = item
	registry.set("items", items)

	var player := CharacterBody3D.new()
	player.name = "1"
	player.add_to_group(&"players")
	player.set_multiplayer_authority(1)
	root.add_child(player)
	# Out of every pickup range to start: the drop must NOT be collected on the frame it lands.
	player.global_position = Vector3(0.0, 0.0, 20.0)
	await process_frame

	var before: int = int(inventory.call("host_count", 1, TEST_ITEM_ID))

	# ── A yield spawns a drop rather than crediting the pack ───────────────────────────────────
	EVENT_BUS.emit_harvest_yielded(&"check_tree", 1, TEST_ITEM_ID, 4, Vector3.ZERO)
	await process_frame
	check(int(drops.call("live_count")) == 1, "a harvest yield spawns exactly one ground drop")
	check(
		int(inventory.call("host_count", 1, TEST_ITEM_ID)) == before,
		"the yield credits nothing while the item is still on the ground"
	)
	var drop: Node3D = (drops.call("live_drops") as Array)[0] as Node3D
	check(int(drop.get("amount")) == 4, "the drop carries the whole yield")
	check(drop.is_in_group(&"item_drop"), "the drop joins the item_drop group the prompt scans")
	check(not bool(drop.call("is_collectable")), "a freshly popped drop has not armed yet")

	# The look Sequoyah asked for: the item's own icon, floating clear of the ground and facing you.
	var sprite: Sprite3D = null
	for child: Node in drop.get_children():
		if child is Sprite3D:
			sprite = child as Sprite3D
	check(sprite != null, "the drop draws the item's icon as a billboard")
	if sprite != null:
		check(sprite.texture == icon, "the billboard uses the item's own inventory icon")
		check(sprite.billboard == BaseMaterial3D.BILLBOARD_ENABLED, "the icon always faces the camera")
		check(not sprite.shaded, "the icon is unshaded, so a drop in shadow is still legible")
		check(sprite.position.y > 0.3, "the icon floats above the ground rather than lying in it")

	# ── A second yield of the same item merges instead of spawning a second body ───────────────
	EVENT_BUS.emit_harvest_yielded(&"check_tree", 1, TEST_ITEM_ID, 3, Vector3.ZERO)
	await process_frame
	check(int(drops.call("live_count")) == 1, "a second yield at the same spot merges into one pile")
	check(int(drop.get("amount")) == 7, "the merge folds the amount in")

	# ── Arming ────────────────────────────────────────────────────────────────────────────────
	for _tick: int in 40:
		await physics_frame
	check(bool(drop.call("is_collectable")), "the drop arms after its settle window")
	check(
		int(inventory.call("host_count", 1, TEST_ITEM_ID)) == before,
		"an armed drop still pays nobody who is standing 20 m away"
	)

	# ── The prompt describes it and offers [E] ────────────────────────────────────────────────
	var prompt: CanvasLayer = FOCUS_PROMPT_SCRIPT.new() as CanvasLayer
	root.add_child(prompt)
	await process_frame
	var view: Dictionary = prompt.call("describe", drop) as Dictionary
	check(not view.is_empty(), "the focus prompt describes a ground drop")
	check(String(view.get("action", "")) == "Pick up", "the prompt offers Pick up")
	check(String(view.get("key", "")) == "E", "the prompt binds it to E")
	check(String(view.get("title", "")).contains("7"), "the prompt shows the stack size")
	prompt.queue_free()

	# ── Manual pickup out of range is refused, in range pays out ──────────────────────────────
	check(
		not bool(await _request(drop)),
		"a manual pickup from across the clearing is refused"
	)
	player.global_position = drop.global_position + Vector3(0.0, 0.0, 2.0)
	await physics_frame
	check(bool(await _request(drop)), "a manual pickup within reach is accepted")
	await process_frame
	check(
		int(inventory.call("host_count", 1, TEST_ITEM_ID)) == before + 7,
		"the pack is credited only once the drop is collected"
	)
	check(int(drops.call("live_count")) == 0, "a collected drop despawns")

	# ── Auto pickup: walk into it ─────────────────────────────────────────────────────────────
	player.global_position = Vector3(0.0, 0.0, 20.0)
	await physics_frame
	EVENT_BUS.emit_harvest_yielded(&"check_tree", 1, TEST_ITEM_ID, 2, Vector3.ZERO)
	await process_frame
	var walked: Node3D = (drops.call("live_drops") as Array)[0] as Node3D
	for _tick: int in 40:
		await physics_frame
	player.global_position = walked.global_position
	for _tick: int in 20:
		await physics_frame
	check(int(drops.call("live_count")) == 0, "walking onto an armed drop collects it")
	check(
		int(inventory.call("host_count", 1, TEST_ITEM_ID)) == before + 9,
		"the auto pickup credits the walker"
	)

	# ── Cleanup ───────────────────────────────────────────────────────────────────────────────
	drops.call("host_clear_all")
	var cleanup: Dictionary = registry.get("items")
	cleanup.erase(TEST_ITEM_ID)
	registry.set("items", cleanup)
	player.queue_free()
	print("ITEM_DROP_CHECK failures=%d" % failures)
	finish()


## Sends a pickup request and waits for its confirmation, so the check asserts the host's answer
## rather than a guess about timing. Offline, the answer is emitted synchronously.
func _request(drop: Node3D) -> bool:
	var answer: Array = [false]
	var handler: Callable = func(_id: int, accepted: bool, _reason: String) -> void:
		answer[0] = accepted
	drop.connect(&"pickup_confirmed", handler)
	drop.call(&"request_pickup")
	await process_frame
	if is_instance_valid(drop) and drop.is_connected(&"pickup_confirmed", handler):
		drop.disconnect(&"pickup_confirmed", handler)
	return bool(answer[0])


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
