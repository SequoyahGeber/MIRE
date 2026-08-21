extends SceneTree

## F-301 — the fixture sweep. `ProceduralWorld` published ZERO `station` markers on some seeds, so
## a run could start on an island with crafting unreachable, and nothing caught it because
## `tools/procedural_world_check.gd` builds at ONE fixed seed that happens to get one. A per-seed
## fixture asserted at a single seed is not a per-seed fixture.
##
##   .agent/bin/agent godot --script tools/poi_required_station_check.gd
##
## This check runs at the PURE layer — `PoiMap.sites_for_island()` with the shipped content — rather
## than composing a whole `ProceduralWorld` per seed. That is deliberate and it is what makes a wide
## sweep affordable: placement is a pure function of `(world_seed, poi_defs, biome_defs)`
## (`world/gen/poi_map.gd`'s header), so a station that survives placement here is a station the
## composer's dumb marker loop will publish. The COMPOSITION half — that a surviving site actually
## becomes a `Station_<asset>` marker in `authored_world_marker` — is asserted once, at one seed, by
## `tools/procedural_world_check.gd`. Splitting it that way keeps this file able to sweep 128 seeds
## in seconds instead of booting 128 chunk streamers.
##
## Network authority: none. Everything here is a pure function of the seed, which is the entire
## reason a POI layout is derived on every peer rather than replicated (ARCHITECTURE.md §4).

const PoiMapScript := preload("res://world/gen/poi_map.gd")

## The two seeds F-301 measured failing, plus the two `procedural_world_check` pins — a regression
## of exactly this bug must fail at the seeds that filed it, by name, not just somewhere in a spread.
const NAMED_SEEDS: Array[int] = [3503374054, 3803646258, 987654321, 20260819]
## Plus a deterministic spread, so a future content change that narrows the station's constraints
## again is caught by seeds nobody has hand-picked. Knuth's multiplicative constant, masked to 32
## bits — the same integer-only discipline `PoiMap._kind_seed()` follows, so this list is identical
## on every platform.
const SWEEP_COUNT: int = 128
const SWEEP_STRIDE: int = 2654435761
const SWEEP_MASK: int = 0xFFFFFFFF

## A biome id no `BiomeDef` ships, so `PoiDef.accepts_biome()` rejects every dart at relax 0. The
## lever the negative control below uses to make a base pass fail on purpose (F-335).
const UNPLACEABLE_BIOME: StringName = &"__poi_check_no_such_biome__"

## Every `required` def must land on every seed (D-152). Kept as data rather than hard-coded to the
## station: the bug F-301 found is a CLASS — "a fixture the loop cannot run without, lost silently
## to placement rejection" — and the wellspring and shipwreck are the same class with the same
## failure mode.
const REQUIRED_KINDS: Array[StringName] = [&"wellspring", &"shipwreck", &"station_camp"]

## The rest of what `tools/world_contract_check.gd` demands of a shipped island but that content
## does NOT mark `required`: a chest to open (`loot_cache` -> kind `loot` -> ChestPlacementService)
## and somewhere for the night wave to come from (`enemy_nest` -> EnemyWorld.ambient_spawn_points).
## Both place multiple sites and both currently survive every seed measured, so making them
## `required` would buy nothing today — but they are one content tweak away from F-301's exact
## failure, and the contract check would then fail as a coin flip on the procedural arm with no clue
## which content change caused it. Asserted as a SEED SWEEP rather than as a `required` flag,
## deliberately: the demand is "at least one lands", not "content declares an intent". D-183.
const LOOP_FIXTURE_KINDS: Array[StringName] = [&"loot_cache", &"enemy_nest"]

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if registry == null:
		return finish()

	var poi_defs: Array = (registry.get(&"poi") as Dictionary).values()
	var biome_defs: Array = (registry.get(&"biomes") as Dictionary).values()
	check(poi_defs.size() > 0, "Registry indexed the POI defs (%d)" % poi_defs.size())
	check(biome_defs.size() > 0, "Registry indexed the biome defs (%d)" % biome_defs.size())
	if poi_defs.is_empty():
		return finish()

	var registered: Array[StringName] = _registered_station_assets(registry)
	check(registered.size() > 0,
		"Registry indexed at least one StationDef to resolve a marker against (%s)" % [registered])

	# ── the content contract that makes the sweep below possible at all ───────────────────────────
	# Asserted separately from the sweep because the two fail for different reasons and the fix
	# differs: a def that is not `required` never reaches D-152's relax ladder, so it CAN place zero
	# and the sweep would just report "some seeds have no station" without saying why.
	var defs_by_id: Dictionary = {}
	for definition: Resource in poi_defs:
		defs_by_id[StringName(String(definition.get(&"id")))] = definition
	for required_id: StringName in REQUIRED_KINDS:
		var definition: Resource = defs_by_id.get(required_id, null)
		if not check(definition != null, "content still ships a `%s` POI def" % required_id):
			continue
		check(bool(definition.get(&"required")),
			"`%s` is marked required, so zero placements gets D-152's relax ladder rather than a "
			% required_id + "shrug")

	var station_def: Resource = defs_by_id.get(&"station_camp", null)
	if station_def != null:
		check(String(station_def.get(&"marker_kind")) == "station",
			"`station_camp` publishes marker kind `station` — the kind CraftingService scans for")
		check(registered.has(_asset_of(station_def)),
			"`station_camp`'s marker name resolves to a REGISTERED StationDef asset (`%s`) — a "
			% _asset_of(station_def) + "marker naming scenery would satisfy the kind and still "
			+ "leave crafting unreachable (world_contract_check's own lesson)")

	# ── the sweep ─────────────────────────────────────────────────────────────────────────────────
	var seeds: Array[int] = _sweep_seeds()
	var report: Dictionary = _sweep(seeds, poi_defs, biome_defs, defs_by_id, registered)
	for swept_id: StringName in _swept_kinds():
		var missing: Array = report[swept_id]
		check(missing.is_empty(),
			"every one of %d seeds placed a `%s` — %d without one%s" % [
				seeds.size(), swept_id, missing.size(), _sample(missing)])
	var station_missing: Array = report[&"registered_station"]
	check(station_missing.is_empty(),
		"every one of %d seeds placed a site whose marker resolves to a REGISTERED station — %d "
		% [seeds.size(), station_missing.size()] + "without one%s" % _sample(station_missing))

	# ── the detector's own teeth (F-261/F-275: vary the FIXTURE, never the shipped source) ────────
	if station_def != null:
		_check_relax_ladder_has_teeth(seeds, station_def, poi_defs, biome_defs, defs_by_id, registered)

	print("\nPOI_REQUIRED_STATION_CHECK seeds=%d failures=%d" % [seeds.size(), failures])
	finish()


## F-335: the negative control, redesigned so it can actually fail.
##
## **What broke it.** The old control cleared `required` on a duplicate of the station def and
## expected some seeds to lose their station — the state the tree was in when F-301 was filed. After
## the 4.18 terrain retune the base (relax 0) pass succeeds on every one of the 132 seeds, so the
## ladder never fires, so removing the ladder changes nothing: the control reported zero lost seeds
## and the check exited red while the product was fine. That is the worst possible reading, because
## the red says "the guarantee is broken" when what it means is "the guarantee is currently
## unexercised". A control whose teeth depend on the terrain staying stingy is not a control.
##
## **What replaces it.** Make the base pass IMPOSSIBLE for a fixture def, then run it both ways. The
## fixture asks for a biome that does not exist, so `PoiDef.accepts_biome()` rejects every dart at
## relax 0 — deterministically, on every seed, regardless of how generous the island becomes. Rung 1
## waives the biome test, so:
##
##   * `required = true`  -> the ladder fires and the site lands on EVERY seed
##   * `required = false` -> no ladder, and the site is lost on EVERY seed
##
## Both directions asserted. That demonstrates exactly D-152's guarantee — "a REQUIRED kind that
## placed nothing gets the ladder, not a shrug" — and that `required` is the flag gating it. The
## shipped content is never touched (F-261/F-275): only a `duplicate()` is mutated.
func _check_relax_ladder_has_teeth(
	seeds: Array[int], station_def: Resource, poi_defs: Array, biome_defs: Array,
	defs_by_id: Dictionary, registered: Array[StringName]
) -> void:
	var recovered: Dictionary = _sweep_with_fixture(
		seeds, station_def, true, poi_defs, biome_defs, defs_by_id, registered)
	var lost_with_ladder: Array = recovered[&"registered_station"]
	check(lost_with_ladder.is_empty(),
		"NEGATIVE: a station whose authored biome cannot be satisfied is still placed on all %d "
		% seeds.size() + "seeds — the relax ladder is what recovers it (%d lost%s)"
			% [lost_with_ladder.size(), _sample(lost_with_ladder)])

	var abandoned: Dictionary = _sweep_with_fixture(
		seeds, station_def, false, poi_defs, biome_defs, defs_by_id, registered)
	var lost_without: Array = abandoned[&"registered_station"]
	check(lost_without.size() == seeds.size(),
		"NEGATIVE: with `required` cleared the same unplaceable station is lost on all %d seeds "
		% seeds.size() + "— the ladder, and only the ladder, was doing the work (%d lost%s)"
			% [lost_without.size(), _sample(lost_without)])
	for named: int in NAMED_SEEDS.slice(0, 2):
		check(lost_without.has(named),
			"NEGATIVE: seed %d — one F-301 measured failing — is among them, so this check still "
			% named + "speaks about the seeds the original bug was filed on")


## One sweep with `station_camp` swapped for a duplicate that cannot satisfy its own biome, and
## `required` set as given. Only the duplicate is mutated; `poi_defs` and the Registry are untouched.
func _sweep_with_fixture(
	seeds: Array[int], station_def: Resource, required: bool, poi_defs: Array, biome_defs: Array,
	defs_by_id: Dictionary, registered: Array[StringName]
) -> Dictionary:
	var fixture: Resource = station_def.duplicate()
	fixture.set(&"biomes", [UNPLACEABLE_BIOME] as Array[StringName])
	fixture.set(&"required", required)
	var mutated: Array = []
	for definition: Resource in poi_defs:
		mutated.append(fixture if StringName(String(definition.get(&"id"))) == &"station_camp"
			else definition)
	var mutated_by_id: Dictionary = defs_by_id.duplicate()
	mutated_by_id[&"station_camp"] = fixture
	return _sweep(seeds, mutated, biome_defs, mutated_by_id, registered)


## The two lists above, in one pass. Order matters only for readable output: the `required` kinds
## report first, because a failure there also explains a failure below it.
func _swept_kinds() -> Array[StringName]:
	var kinds: Array[StringName] = REQUIRED_KINDS.duplicate()
	kinds.append_array(LOOP_FIXTURE_KINDS)
	return kinds


## One sweep over `seeds`, returning `{def_id: [seeds that placed none], registered_station: [...]}`.
## Takes the def list as an argument rather than reading the Registry so the negative pass above can
## hand it a modified fixture without touching shipped content.
func _sweep(seeds: Array[int], poi_defs: Array, biome_defs: Array, defs_by_id: Dictionary,
		registered: Array[StringName]) -> Dictionary:
	var report: Dictionary = {&"registered_station": []}
	for required_id: StringName in _swept_kinds():
		report[required_id] = []
	for world_seed: int in seeds:
		var sites: Array[Dictionary] = PoiMapScript.sites_for_island(
			world_seed, poi_defs, biome_defs)
		var counts: Dictionary = {}
		var registered_stations: int = 0
		for site: Dictionary in sites:
			var def_id := StringName(String(site.get("def_id", &"")))
			counts[def_id] = int(counts.get(def_id, 0)) + 1
			var definition: Resource = defs_by_id.get(def_id, null)
			if definition == null or String(definition.get(&"marker_kind")) != "station":
				continue
			if registered.has(_asset_of(definition)):
				registered_stations += 1
		for required_id: StringName in _swept_kinds():
			if int(counts.get(required_id, 0)) < 1:
				(report[required_id] as Array).append(world_seed)
		if registered_stations < 1:
			(report[&"registered_station"] as Array).append(world_seed)
	return report


## `NAMED_SEEDS` first so a failure report leads with the seeds F-301 measured, then the spread.
func _sweep_seeds() -> Array[int]:
	var seeds: Array[int] = NAMED_SEEDS.duplicate()
	for index: int in range(SWEEP_COUNT):
		var value: int = ((index + 1) * SWEEP_STRIDE) & SWEEP_MASK
		if not seeds.has(value):
			seeds.append(value)
	return seeds


## The asset name a marker of this def would carry — `Station_<asset>` with the prefix trimmed, the
## exact resolution `CraftingService` and `tools/world_contract_check.gd` perform on the node name.
func _asset_of(definition: Resource) -> StringName:
	return StringName(String(definition.get(&"marker_name")).trim_prefix("Station_"))


## Every StationDef's `world_scene`, the set a marker name must land in to count as REGISTERED.
func _registered_station_assets(registry: Node) -> Array[StringName]:
	var assets: Array[StringName] = []
	var stations: Dictionary = registry.get(&"stations") as Dictionary
	for id: Variant in stations:
		assets.append(StringName(String((stations[id] as Resource).get(&"world_scene"))))
	return assets


## First few offending seeds, named. A bare count sends the next reader back to reproduce the sweep;
## a seed is something they can paste straight into a build.
func _sample(missing: Array) -> String:
	if missing.is_empty():
		return ""
	return " — e.g. %s" % [missing.slice(0, 4)]


func check(condition: bool, description: String) -> bool:
	if condition:
		print("PASS: %s" % description)
		return true
	failures += 1
	push_error("FAIL: %s" % description)
	return false


func finish() -> void:
	print("\nPOI_REQUIRED_STATION_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
