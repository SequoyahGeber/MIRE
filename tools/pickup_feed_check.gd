extends SceneTree

## F-581's proof: loot has a moment now, and every pickup says so.
##
##   .agent/bin/agent godot --script tools/pickup_feed_check.gd
##
## What it asserts, in the order a player meets it:
##
##   1. `PickupFeedService` announces a grant to the peer that earned it, in both namespaces (an
##      item and a powerup), and resolves display names and icons for each.
##   2. `PickupHud` turns those announcements into bottom-left feed lines, merges a repeat of the
##      same pickup instead of stacking rows, and lets a line expire.
##   3. A powerup announcement also fires the ceremony — the family-tinted screen flash and the
##      named card — and lands in the top-left held-powerup row with its stack count.
##   4. `ChestUI` no longer blocks: the reveal is `ui/loot/chest_reel.gd` in the world, and the UI
##      is not in `blocks_gameplay_input` while it plays.
##
## Everything here is client-local presentation, so the check runs offline against the autoloads —
## there is no host/client split to stand up.

const CHEST_REEL := preload("res://ui/loot/chest_reel.gd")
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	await _check_feed_service()
	await _check_feed_lines()
	await _check_powerup_ceremony()
	await _check_chest_reel()

	print("\nPICKUP_FEED_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _check_feed_service() -> void:
	print("\n== PickupFeedService ==")
	var feed: Node = root.get_node_or_null(^"PickupFeedService")
	check(feed != null, "PickupFeedService autoload exists")
	if feed == null:
		return

	var seen: Array[Dictionary] = []
	var listener: Callable = func(kind: StringName, id: StringName, amount: int,
			source: StringName) -> void:
		seen.append({"kind": kind, "id": id, "amount": amount, "source": source})
	feed.connect(&"pickup_received", listener)

	var powerup_id: StringName = _any_powerup_id()
	feed.call(&"host_notify", NetConfig.HOST_PEER_ID, &"item", &"mushroom", 3, &"ground")
	if powerup_id != &"":
		feed.call(&"host_notify", NetConfig.HOST_PEER_ID, &"powerup", powerup_id, 1, &"chest")
	# The three refusals the seam owes its callers: a capped grant, an empty id, and an unknown peer
	# must all say nothing rather than announcing "+0".
	feed.call(&"host_notify", NetConfig.HOST_PEER_ID, &"item", &"mushroom", 0, &"ground")
	feed.call(&"host_notify", NetConfig.HOST_PEER_ID, &"item", &"", 5, &"ground")
	feed.call(&"host_notify", 0, &"item", &"mushroom", 5, &"ground")
	await process_frame
	feed.disconnect(&"pickup_received", listener)

	var expected: int = 2 if powerup_id != &"" else 1
	check(seen.size() == expected,
		"only real grants are announced (%d of %d announcements)" % [seen.size(), expected])
	if seen.size() > 0:
		check(seen[0]["kind"] == &"item" and seen[0]["id"] == &"mushroom"
			and int(seen[0]["amount"]) == 3 and seen[0]["source"] == &"ground",
			"an item grant arrives intact, source included")
	if powerup_id != &"":
		check(feed.call(&"kind_of", powerup_id) == &"powerup",
			"kind_of() resolves an authored powerup id to the powerup namespace")
	check(feed.call(&"kind_of", &"mushroom") == &"item",
		"kind_of() resolves an item id to the item namespace")
	check(String(feed.call(&"display_name_of", &"item", &"definitely_not_authored"))
		== "Definitely Not Authored",
		"an unknown id still gets a human-readable name rather than a raw token")


func _check_feed_lines() -> void:
	print("\n== the bottom-left feed ==")
	var hud: Node = root.get_node_or_null(^"PickupHud")
	var feed: Node = root.get_node_or_null(^"PickupFeedService")
	check(hud != null, "PickupHud autoload exists")
	if hud == null or feed == null:
		return

	# `_check_feed_service()` above announced real grants through this same live HUD, so the feed is
	# NOT empty when this section starts — age those lines out first. Asserting against a dirty feed
	# is exactly how this check failed on its first run.
	_drain_feed(hud)
	check(hud.call(&"feed_lines").is_empty(), "the feed starts this section empty")

	feed.call(&"host_notify", NetConfig.HOST_PEER_ID, &"item", &"mushroom", 3, &"ground")
	await process_frame
	var lines: PackedStringArray = hud.call(&"feed_lines")
	check(lines.size() == 1, "one pickup draws one line (%d)" % lines.size())
	check(lines.size() > 0 and lines[0].begins_with("+3"),
		"the line names the amount: %s" % [lines])

	# A second helping of the same thing inside the merge window bumps the count in place — the
	# ten-logs-from-one-tree case that would otherwise fill the corner with identical rows.
	feed.call(&"host_notify", NetConfig.HOST_PEER_ID, &"item", &"mushroom", 2, &"ground")
	await process_frame
	lines = hud.call(&"feed_lines")
	check(lines.size() == 1, "the same pickup again merges instead of stacking (%d)" % lines.size())
	check(lines.size() > 0 and lines[0].begins_with("+5"), "the merged line totals: %s" % [lines])

	feed.call(&"host_notify", NetConfig.HOST_PEER_ID, &"item", &"coins", 12, &"chest")
	await process_frame
	check(hud.call(&"feed_lines").size() == 2, "a different pickup gets its own line")

	_drain_feed(hud)
	check(hud.call(&"feed_lines").is_empty(), "feed lines expire rather than accumulating forever")


## Ages every live feed line past its hold and its fade, rather than waiting the seconds out in real
## time. The budget is a literal on purpose: `Object.get()` does not see script CONSTANTS, so reading
## FEED_HOLD_SEC off the HUD returns null and silently turns this loop into a no-op.
func _drain_feed(hud: Node) -> void:
	var elapsed: float = 0.0
	while elapsed < 8.0:
		hud.call(&"_tick_feed", 0.25)
		elapsed += 0.25


func _check_powerup_ceremony() -> void:
	print("\n== the powerup ceremony ==")
	var hud: Node = root.get_node_or_null(^"PickupHud")
	var feed: Node = root.get_node_or_null(^"PickupFeedService")
	var powerups: Node = root.get_node_or_null(^"PowerupService")
	var powerup_id: StringName = _any_powerup_id()
	check(powerup_id != &"", "content authors at least one powerup to test with")
	if hud == null or feed == null or powerups == null or powerup_id == &"":
		return

	feed.call(&"host_notify", NetConfig.HOST_PEER_ID, &"powerup", powerup_id, 1, &"chest")
	await process_frame
	check(float(hud.call(&"flash_alpha")) > 0.0, "a powerup grant flashes the screen its family colour")
	var title: String = String(hud.call(&"card_title"))
	check(not title.is_empty(), "the card names what was granted: '%s'" % title)
	check(title == String(feed.call(&"display_name_of", &"powerup", powerup_id)),
		"the card shows the powerup's authored display name")

	# The row is driven by held state, not by the announcement — it has to survive a reconnect, a
	# late join and a snapshot, none of which replay the feed.
	powerups.call(&"host_grant", NetConfig.HOST_PEER_ID, powerup_id, 2)
	await process_frame
	var row: Array = hud.call(&"powerup_row_ids")
	check(row.has(powerup_id), "a held powerup appears in the top-left row: %s" % [row])

	powerups.call(&"host_clear", NetConfig.HOST_PEER_ID)
	await process_frame
	check(not (hud.call(&"powerup_row_ids") as Array).has(powerup_id),
		"losing every stack removes the tile again")


func _check_chest_reel() -> void:
	print("\n== the reveal ==")
	var chest_ui: Node = root.get_node_or_null(^"ChestUI")
	check(chest_ui != null, "ChestUI autoload exists")
	if chest_ui == null:
		return
	check(not chest_ui.is_in_group(BLOCKING_UI_GROUP),
		"opening a chest never takes the screen — the reveal is in the world (F-581)")

	var host := Node3D.new()
	root.add_child(host)
	var reel := Node3D.new()
	reel.set_script(CHEST_REEL)
	host.add_child(reel)
	var powerup_id: StringName = _any_powerup_id()
	var granted: Dictionary = {&"coins": 20, &"mushroom": 1}
	if powerup_id != &"":
		granted[powerup_id] = 1
	reel.call(&"configure", granted)
	await process_frame

	check(reel.get_node_or_null(^"ReelWindow") != null, "the reel builds its slot window")
	check(reel.get_node_or_null(^"ReelIcon") != null, "the reel builds its face")
	check(reel.get_node_or_null(^"ReelLight") != null, "the reel lights the clearing while it spins")
	check(reel.get_node_or_null(^"ReelBurst") != null, "the reel builds its settle burst")
	if powerup_id != &"":
		# A powerup always wins the headline: it is the thing that changes the run, and a reel that
		# lands on "20 coins" when a powerup was in the same haul is selling the wrong thing.
		check(reel.call(&"_headline_of", granted) == powerup_id,
			"the reel lands on the powerup, not the coins")
	check(reel.call(&"_headline_of", {&"coins": 40, &"mushroom": 2}) == &"mushroom",
		"with no powerup the reel prefers a real item over a coin pile")

	# Drive it past its own spin without waiting for it in real time.
	# Comfortably past SPIN_SEC; a constant is not readable through `Object.get()`.
	reel.call(&"_process", 5.0)
	check(bool(reel.get(&"_settled")), "the reel settles when its spin is spent")

	# Freed rather than queued: `quit()` follows within a frame or two of this check returning, and a
	# queued free that never gets its frame is reported as a leaked ObjectDB instance at exit.
	host.free()


## Any authored powerup id, so this check does not hard-code a content file that may be rebalanced
## or renamed out from under it.
func _any_powerup_id() -> StringName:
	var registry: Node = root.get_node_or_null(^"Registry")
	if registry == null:
		return &""
	var powerups: Variant = registry.get(&"powerups")
	if not (powerups is Dictionary):
		return &""
	var ids: Array[StringName] = []
	for id: StringName in powerups:
		ids.append(id)
	# StringName's `<` compares interned identity, not string content — F-175. A stable pick keeps
	# this check's failures reproducible.
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return ids[0] if not ids.is_empty() else &""


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
