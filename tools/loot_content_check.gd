extends SceneTree

## Verify the authored chest economy: every loot table in `content/loot/`, every id it names, and
## the four things `docs/ITEMS.md` §5 needs a chest to be able to do — charge a price, want a key,
## hand out a powerup, and let `loot_luck` lean on rarity (F-140).
##
## Run with:  .agent/bin/agent godot --script tools/loot_content_check.gd
##
## The important half is the ID RESOLUTION pass. A LootEntry naming an item that does not exist is
## silent at every level below this one: the table validates, the chest opens, `host_add` returns
## false, and the player is simply handed less than the table promised. Authored tables reference 45
## ids across two namespaces, and a typo in any of them is invisible until someone notices a tier
## feels stingy — so every id gets resolved here, against the real Registry.

const CHEST_SCRIPT := preload("res://systems/loot/chest.gd")
const LOOT_ENTRY_SCRIPT := preload("res://systems/loot/loot_entry.gd")

const LOOT_DIR: String = "res://content/loot"
const KEY_ITEM_ID: StringName = &"flint"   # stands in for the Rusted Key until W2's keys are authored

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var registry: Node = root.get_node_or_null(^"Registry")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var powerups: Node = root.get_node_or_null(^"PowerupService")
	check(registry != null, "Registry autoload exists")
	check(inventory != null, "InventoryService autoload exists")
	check(powerups != null, "PowerupService autoload exists")
	if registry == null or inventory == null or powerups == null:
		_finish()
		return

	var tables: Array[Resource] = _load_tables()
	check(tables.size() >= 7, "every authored loot table loads (%d found)" % tables.size())

	# ── Content: validity and id resolution ─────────────────────────────────────────────────────
	var item_lines: int = 0
	var powerup_lines: int = 0
	var rarity_lines: int = 0
	for table: Resource in tables:
		var id := StringName(String(table.get("id")))
		var errors: PackedStringArray = table.call("validation_errors")
		check(errors.is_empty(), "%s validates" % id, "; ".join(errors))
		check(bool(registry.call("has_loot_table", id)), "%s is indexed by Registry" % id)
		for entry: Resource in table.get("entries") as Array:
			var granted_id := StringName(String(entry.get("item_id")))
			var kind: int = int(entry.get("kind"))
			if int(entry.get("rarity")) > 0:
				rarity_lines += 1
			if kind == LOOT_ENTRY_SCRIPT.Kind.POWERUP:
				powerup_lines += 1
				check(
					registry.call("get_powerup", granted_id) != null,
					"%s: powerup '%s' exists" % [id, granted_id]
				)
			else:
				item_lines += 1
				check(
					registry.call("get_item", granted_id) != null,
					"%s: item '%s' exists" % [id, granted_id]
				)
	print("LOOT_CONTENT tables=%d item_lines=%d powerup_lines=%d rarity_lines=%d" % [
		tables.size(), item_lines, powerup_lines, rarity_lines
	])
	check(powerup_lines > 0, "the authored tables actually use POWERUP entries")
	check(rarity_lines > 0, "the authored tables actually use rarity, so loot_luck has a consumer")

	# ── loot_luck really biases the draw ────────────────────────────────────────────────────────
	var gilded: Resource = registry.call("get_loot_table", &"gilded") as Resource
	if gilded != null:
		var plain: int = _troll_pulls(gilded, 0.0)
		var lucky: int = _troll_pulls(gilded, 1.0)
		# The one rarity-0 line in the Gilded pool is the joke axe. Luck multiplies every OTHER
		# line's weight, so the joke gets rarer — that is the whole mechanism, measured.
		check(lucky < plain, "loot_luck shifts the Gilded pool away from its rarity-0 line (%d -> %d of 4000)" % [plain, lucky])

	# ── A chest that charges, locks, and grants a powerup ───────────────────────────────────────
	var peer: int = NetConfig.HOST_PEER_ID
	powerups.call("host_clear", peer)
	var chest: Node3D = CHEST_SCRIPT.new() as Node3D
	chest.name = "LootCheckChest"
	chest.set("tier", &"gilded")
	chest.set("cost_coins", 40)
	chest.set("locked_by", KEY_ITEM_ID)
	root.add_child(chest)
	await process_frame

	var results: Array = []
	chest.connect(&"open_confirmed", func(rid, accepted, granted, detail):
		results.append({"id": rid, "accepted": accepted, "granted": granted, "detail": detail})
	)

	# Broke and keyless.
	chest.call("request_open")
	check(results.size() == 1 and not bool(results[0]["accepted"]), "an unaffordable chest is refused")
	check(not bool(chest.get("opened")), "a refused chest stays closed and re-openable")

	# Coins but no key.
	inventory.call("host_add", peer, &"coins", 100)
	chest.call("request_open")
	check(results.size() == 2 and not bool(results[1]["accepted"]), "coins alone do not open a locked chest")
	check(
		String(results[1]["detail"]).contains("locked"),
		"the refusal says it is locked", String(results[1]["detail"])
	)
	check(int(inventory.call("host_count", peer, &"coins")) == 100, "a refused open charges nothing")

	# Coins and key.
	inventory.call("host_add", peer, KEY_ITEM_ID, 1)
	chest.call("host_seed_rng", 4242)
	chest.call("request_open")
	check(results.size() == 3 and bool(results[2]["accepted"]), "a paid, unlocked chest opens")
	check(int(inventory.call("host_count", peer, &"coins")) >= 60, "the price was charged")
	check(int(inventory.call("host_count", peer, KEY_ITEM_ID)) == 0, "the key was consumed")
	var granted: Dictionary = results[2]["granted"]
	check(not granted.is_empty(), "the open granted something")
	var held: Dictionary = powerups.call("_held_for", peer)
	var granted_powerups: int = 0
	for granted_id: StringName in granted:
		if registry.call("get_powerup", granted_id) != null:
			granted_powerups += 1
			check(int(held.get(granted_id, 0)) > 0, "PowerupService actually holds '%s'" % granted_id)
	print("LOOT_CHEST granted=%s powerups=%d" % [granted, granted_powerups])

	# chest_price is read, not decorative.
	var priced: Node3D = CHEST_SCRIPT.new() as Node3D
	priced.name = "LootCheckPriced"
	priced.set("tier", &"bog")
	priced.set("cost_coins", 100)
	root.add_child(priced)
	await process_frame
	var full_price: int = int(priced.call("_price_for", peer))
	powerups.call("host_grant", peer, &"the_landlord", 1)
	var discounted: int = int(priced.call("_price_for", peer))
	check(full_price == 100, "an unmodified price is the authored price", str(full_price))
	check(discounted == 50, "The Landlord's -50% chest_price reaches the till", str(discounted))
	var luck: float = float(priced.call("_luck_for", peer))
	check(is_equal_approx(luck, 0.3), "The Landlord's +30% loot_luck reaches the roll", str(luck))
	powerups.call("host_grant", peer, &"second_glance", 1)
	var stacked: float = float(priced.call("_luck_for", peer))
	check(
		stacked > luck,
		"a second, differently-authored loot_luck powerup adds to it", "%.3f -> %.3f" % [luck, stacked]
	)
	powerups.call("host_clear", peer)
	_finish()


## How often the Gilded pool coughs up its one rarity-0 line, over a fixed stream.
func _troll_pulls(table: Resource, luck: float) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260818
	var pulls: int = 0
	for _index: int in 4000:
		var roll: Dictionary = table.call("roll", rng, luck)
		if int((roll.get("items", {}) as Dictionary).get(&"stone_axe", 0)) > 0:
			pulls += 1
	return pulls


func _load_tables() -> Array[Resource]:
	var out: Array[Resource] = []
	var dir := DirAccess.open(LOOT_DIR)
	if dir == null:
		check(false, "content/loot is readable")
		return out
	var names: Array[String] = []
	for file_name in dir.get_files():
		if file_name.ends_with(".tres"):
			names.append(file_name)
	names.sort()
	for file_name in names:
		var table: Resource = load("%s/%s" % [LOOT_DIR, file_name]) as Resource
		if table == null:
			check(false, "%s loads" % file_name)
			continue
		out.append(table)
	return out


func check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		print("PASS: %s" % label)
		return
	failures += 1
	print("FAIL: %s%s" % [label, "" if detail.is_empty() else " — " + detail])


func _finish() -> void:
	print("LOOT_CONTENT_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
