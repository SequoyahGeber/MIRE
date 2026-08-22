class_name PowerupDef
extends Resource

## Static definition of one powerup. Authored by hand as a .tres in content/powerups/ — see
## ARCHITECTURE.md §3.1 ("content is data, not code") and DESIGN.md §4.4. `registry.gd` loads every
## .tres in that folder at boot and indexes it by `id`.
##
## NETWORK AUTHORITY: none directly. A definition is identical on every peer and is never sent — only
## its `id` goes over the wire. Which player HOLDS how many of it is host-authoritative state and
## lives in autoload/powerup_service.gd (docs/ARCHITECTURE.md §2.2, "active modifiers" row).
##
## DESIGN.md §4.4 is the contract this shape serves: "1–2 tags", "holding 3+ of a tag triggers a
## Resonance", and "mostly data, not code — once the framework exists, new content is a resource
## file". Task 3.4 authors 40–60 of these in the inspector against the one worked example here,
## and against docs/POWERUPS.md — the stat catalog, the authoring conventions, and the 60-powerup
## design sketch that validated this schema before content was committed to it (F-078, D-179).

## §4.4's six families, exactly. A tag outside this list is a typo minting a phantom family —
## `&"fire"` and `&"Fire"` count separately and the misspelt one can never resonate, which is the
## same silent failure D-044 killed `resonance_family` to prevent. A SEVENTH family is a design
## event that ships with its own Resonance effect tasks; adding it here is the trivial last step.
const KNOWN_FAMILIES: Array[StringName] = [
	&"Fire", &"Blood", &"Kinetic", &"Fungal", &"Cold", &"Void",
]

## The stat vocabulary — docs/POWERUPS.md §2 is the same list with meanings, sign conventions and
## consuming systems; keep the two in step (F-078). Every name is the exact quantity a consuming
## system computes, so `(base + add·N)·(1 + mult·N)` reads literally; reductions are negative
## values on the consumed quantity, never separate "resist" stats. A name here does NOT mean a
## system reads it yet — 3.4's spec is explicit that stats wire up one line at a time in each
## system's own task. It means the name is settled, so content authored today and the system task
## that arrives later cannot drift apart. Inventing a new stat = one row in POWERUPS.md + one line
## here, on purpose: a decision you notice, not a typo in file 43 of 60.
const KNOWN_STATS: Array[StringName] = [
	# movement — player_controller.gd, client-auth own movement
	&"move_speed", &"sprint_speed", &"jump_height", &"air_control", &"extra_jumps",
	&"fall_damage_taken",
	# health / survival — systems/health/player_health.gd, host
	&"max_hp", &"damage_taken", &"knockback_taken", &"bleed_out_seconds",
	&"revive_seconds", &"revive_radius_m", &"hunger_drain", &"food_value", &"blight_rate",
	# stamina — 3.8
	&"max_stamina", &"stamina_regen", &"stamina_cost", &"dodge_iframe_seconds",
	# combat — host combat path over WeaponDef bases, plus status/event hooks
	&"melee_damage", &"melee_range_m", &"attack_seconds", &"bow_damage",
	&"ignite_chance", &"slow_chance", &"slow_potency",
	&"on_hit_lifesteal", &"on_kill_heal_hp", &"arrow_save_chance", &"aggro_radius_m",
	# economy / loot — chests, kill rewards
	&"coin_gain", &"chest_price", &"loot_luck",
	# harvest / craft / build
	&"harvest_yield", &"harvest_damage", &"craft_seconds", &"haul_speed", &"ward_radius_m",
	&"structure_hp",
	# condition-suffixed (closed set — POWERUPS.md §2; the consumer owning the condition chains
	# these onto the unconditional pass, the service stays condition-blind, D-179)
	&"melee_damage_low_hp", &"move_speed_low_hp", &"melee_damage_at_night", &"move_speed_in_mire",
]

## Unique key. Must match across all peers — it is what goes over the network, never the resource
## path. Convention matches content/items: lowercase, underscores.
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var icon: Texture2D

## The Resonance families this powerup counts toward — §4.4's `Fire` `Blood` `Kinetic` `Fungal`
## `Cold` `Void`. One or two, per the design; nothing here enforces two, because a future powerup
## that belongs to three families is a balance question, not a schema violation.
##
## These ARE the families: there is no second `resonance_family` field, because §4.4 keys its
## thresholds off the tags themselves and two names for one concept is how they drift apart. See
## D-044.
@export var tags: Array[StringName] = []

## How many copies of THIS powerup one player may hold. Distinct from a Resonance threshold, which
## counts a whole family across different powerups: three different Fire powerups resonate at one
## stack each.
@export_range(1, 99, 1) var max_stacks: int = 5

## Stat name -> per-stack modifier, as `Vector2(additive, multiplicative)`.
##
## `PowerupService.stat()` applies N stacks as `(base + additive * N) * (1.0 + multiplicative * N)`.
## Additive first, then multiplicative, and BOTH scale linearly with the stack count rather than
## compounding — see D-044. A `Vector2(0.0, 0.08)` on `move_speed` is "+8% per stack"; a
## `Vector2(2.0, 0.0)` on `max_hp` is "+2 flat per stack".
@export var modifiers: Dictionary[StringName, Vector2] = {}


## Same shape as LootTableDef's — registry.gd calls this before indexing and skips anything that
## fails, so a malformed .tres is a named boot error rather than a crash three systems downstream.
func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = []
	if id == &"":
		errors.append("id is empty")
	if display_name.is_empty():
		errors.append("display_name is empty")
	if max_stacks < 1:
		errors.append("max_stacks must be at least 1")
	for tag: StringName in tags:
		if tag == &"":
			errors.append("tags contains an empty entry")
		elif not KNOWN_FAMILIES.has(tag):
			errors.append("tag '%s' is not a §4.4 family (%s) — a misspelt tag mints a phantom family that can never resonate" % [
				tag, ", ".join(KNOWN_FAMILIES)
			])
	if tags.is_empty() and modifiers.is_empty():
		errors.append("does nothing: no tags and no modifiers")
	for stat_name: StringName in modifiers:
		if stat_name == &"":
			errors.append("modifiers contains an empty stat name")
			continue
		if not KNOWN_STATS.has(stat_name):
			errors.append("stat '%s' is not in the catalog — if intentional, add it to docs/POWERUPS.md §2 and PowerupDef.KNOWN_STATS" % stat_name)
		var pair: Vector2 = modifiers[stat_name]
		if pair == Vector2.ZERO:
			errors.append("modifier for '%s' is Vector2.ZERO, which does nothing" % stat_name)
		# D-044 stacks multipliers LINEARLY, so a negative multiplicative crosses zero where
		# mult·max_stacks ≤ −1 and the stat inverts (hunger that refills itself). The bound is
		# base-independent, so it is checkable here; additive sign limits are the consumer's clamp.
		if 1.0 + pair.y * float(max_stacks) <= 0.0:
			errors.append("modifier for '%s': multiplicative %.2f at max_stacks %d crosses zero ((1 + m·N) = %.2f) — raise the multiplier or lower max_stacks" % [
				stat_name, pair.y, max_stacks, 1.0 + pair.y * float(max_stacks)
			])
	return errors
