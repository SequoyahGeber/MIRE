extends SceneTree

## F-487: crafting stations form tiered families, and the FIRST TIER OF EVERY FAMILY MUST BE
## BUILDABLE FROM BASE GATHERED RESOURCES (Sequoyah, 2026-08-21).
##
## "Base gathered" means an item the world hands the player directly — something a HarvestableDef
## yields. Not a crafted intermediate, and above all not a loot or POI drop: the anvil once cost a
## wellglass_shard that only the wellspring dropped, and the furnace cost flint that nothing in the
## game produced, so the whole forge branch could fail to open in a run (F-485, F-487).
##
## Higher tiers are exactly where crafted intermediates belong — that is what makes them upgrades —
## so this only constrains tier 1, and separately insists every family's tiers are contiguous from 1
## and that each station has a buildable to make it.

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if registry == null:
		_finish()
		return

	var base_items: Dictionary = {}
	for path: String in _tres_in("res://content/harvestables"):
		var harvestable: Resource = load(path)
		var yielded: StringName = StringName(harvestable.get("yield_item_id"))
		if yielded != &"":
			base_items[yielded] = true
	check(base_items.size() >= 4, "the world yields a set of base resources to build from")

	var families: Dictionary = {}   # family -> {tier -> Array[station id]}
	for path: String in _tres_in("res://content/stations"):
		var station: Resource = load(path)
		var id: StringName = StringName(station.get("id"))
		var family: StringName = StringName(station.get("family"))
		var tier: int = int(station.get("tier"))
		check(family != &"", "station %s names a family" % id)
		if not families.has(family):
			families[family] = {}
		if not families[family].has(tier):
			families[family][tier] = []
		families[family][tier].append(id)

	for family: StringName in families:
		var tiers: Array = families[family].keys()
		tiers.sort()
		check(tiers[0] == 1, "family %s starts at tier 1 (starts at %d)" % [family, tiers[0]])
		for i: int in tiers.size():
			check(tiers[i] == i + 1,
				"family %s has no gap in its tiers (got %s)" % [family, str(tiers)])

		for station_id: StringName in families[family][tiers[0]]:
			var buildable: Resource = registry.call("get_buildable", station_id)
			check(buildable != null,
				"tier-1 station %s has a buildable to raise it" % station_id)
			if buildable == null:
				continue
			var cost: Dictionary = buildable.get("cost")
			check(not cost.is_empty(), "tier-1 station %s costs something" % station_id)
			for item_id: StringName in cost:
				check(base_items.has(item_id),
					"tier-1 %s costs only base gathered resources — %s is %s"
						% [station_id, item_id, "gathered" if base_items.has(item_id) else "NOT gathered"])

	_finish()


func _tres_in(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return out
	for file_name: String in dir.get_files():
		if file_name.ends_with(".tres"):
			out.append("%s/%s" % [dir_path, file_name])
	out.sort()
	return out


func check(ok: bool, label: String) -> void:
	if ok:
		print("  ok   %s" % label)
	else:
		failures += 1
		print("  FAIL %s" % label)


func _finish() -> void:
	print("\n%s — %d failure(s)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(0 if failures == 0 else 1)
