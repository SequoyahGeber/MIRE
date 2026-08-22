extends SceneTree

## F-580 — offline proof that a powerup a chest hands you CHANGES SOMETHING.
##
##   .agent/bin/agent godot --script tools/powerup_effects_check.gd
##
## `tools/attunement_effects_check.gd` asks this question of the twelve stats the four Attunements
## name. This file asks it of the WHOLE shipped roster, which is where F-580 was hiding: the grant
## path was correct end to end — loot tables carry POWERUP entries, `Chest` routes them to
## `PowerupService.host_grant()`, the stacks replicate and `powerup list` shows them — and 30 of the
## 72 authored powerups still did nothing, because every stat they name was a name in
## `PowerupDef.KNOWN_STATS` that no shipped code ever asked `PowerupService.stat()` for.
##
## Two halves, the same split and for the same reason as the Attunement check:
##
##   1. **The catalogue half.** Every stat named by any shipped PowerupDef must be in exactly one of
##      three buckets, and a stat in none of them fails the run — so a future content edit cannot
##      quietly author a dead stat again.
##
##        · `CONSUMER_SITES` — a recorded consumer whose source really does read it.
##        · `PENDING` — no system exists to read it. Empty as of F-585, which built the last of
##          them; it is kept because the next stat authored ahead of its system belongs here rather
##          than failing, and because an empty honest-list is a fact worth being able to see.
##        · `UNREACHABLE` — wired and correct, and still not something a player can meet, because
##          nothing puts the content in front of them. Reported, never passed silently.
##
##      The three-way split is the point. "Nobody wired the read", "there is no system to wire it
##      to" and "it is wired and no player can trigger it" are three different bugs with three
##      different fixes, and a check that collapsed them would be unactionable the day someone ran
##      it. The third bucket exists because F-585 wired `haul_speed` correctly into a system nothing
##      shipped ever reaches.
##   2. **The behaviour half.** The consumers reachable without a physics body are driven for real,
##      with a peer holding the powerup and a peer holding nothing, and the two answers must differ
##      in the direction docs/POWERUPS.md §2 promises.
##
## Drives the REGISTERED autoloads (F-068/F-069), offline, so `_owns_mutation()` is true everywhere
## and every host path below is the shipped one.

const HOST_PEER: int = 1
const BARE_PEER: int = 77

## stat name -> [source file that must contain the read, the PowerupService seam it goes through].
const CONSUMER_SITES: Dictionary = {
	# movement — client-authoritative, so `local_stat`
	&"move_speed": ["res://entities/player/player_controller.gd", "local_stat"],
	&"sprint_speed": ["res://entities/player/player_controller.gd", "local_stat"],
	&"jump_height": ["res://entities/player/player_controller.gd", "local_stat"],
	&"air_control": ["res://entities/player/player_controller.gd", "local_stat"],
	&"extra_jumps": ["res://entities/player/player_controller.gd", "local_stat"],
	&"move_speed_low_hp": ["res://entities/player/player_controller.gd", "local_stat"],
	&"move_speed_in_mire": ["res://entities/player/player_controller.gd", "local_stat"],
	&"knockback_taken": ["res://entities/player/player_controller.gd", "local_stat"],
	&"dodge_iframe_seconds": ["res://entities/player/player_controller.gd", "local_stat"],
	# health / survival — host
	&"max_hp": ["res://systems/health/player_health.gd", "stat"],
	&"damage_taken": ["res://systems/health/player_health.gd", "stat"],
	&"bleed_out_seconds": ["res://systems/health/player_health.gd", "stat"],
	&"revive_seconds": ["res://systems/health/player_health.gd", "stat"],
	&"revive_radius_m": ["res://systems/health/player_health.gd", "stat"],
	&"hunger_drain": ["res://systems/health/player_health.gd", "stat"],
	&"food_value": ["res://systems/health/player_health.gd", "stat"],
	&"blight_rate": ["res://systems/health/player_health.gd", "stat"],
	&"fall_damage_taken": ["res://systems/health/player_health.gd", "stat"],
	# stamina — client-local, same row as movement
	&"max_stamina": ["res://systems/health/player_health.gd", "local_stat"],
	&"stamina_regen": ["res://systems/health/player_health.gd", "local_stat"],
	&"stamina_cost": ["res://systems/health/player_health.gd", "local_stat"],
	# combat — host
	&"melee_damage": ["res://autoload/combat_service.gd", "stat"],
	&"melee_range_m": ["res://autoload/combat_service.gd", "stat"],
	&"attack_seconds": ["res://autoload/combat_service.gd", "stat"],
	&"melee_damage_low_hp": ["res://autoload/combat_service.gd", "stat"],
	&"melee_damage_at_night": ["res://autoload/combat_service.gd", "stat"],
	&"on_hit_lifesteal": ["res://autoload/combat_service.gd", "stat"],
	&"on_kill_heal_hp": ["res://autoload/combat_service.gd", "stat"],
	&"bow_damage": ["res://autoload/ranged_combat_service.gd", "stat"],
	&"arrow_save_chance": ["res://autoload/ranged_combat_service.gd", "stat"],
	&"aggro_radius_m": ["res://systems/enemies/enemy.gd", "stat"],
	# F-585: the two statuses live in one place on purpose — a player holding both a Fire Resonance
	# and an `ignite_chance` powerup must not get two competing burns.
	&"ignite_chance": ["res://autoload/resonance_service.gd", "stat"],
	&"slow_chance": ["res://autoload/resonance_service.gd", "stat"],
	&"slow_potency": ["res://autoload/resonance_service.gd", "stat"],
	&"haul_speed": ["res://systems/hauling/haulable.gd", "stat"],
	# economy / loot / work
	&"coin_gain": ["res://autoload/reward_service.gd", "stat"],
	&"chest_price": ["res://systems/loot/chest.gd", "stat"],
	&"loot_luck": ["res://systems/loot/chest.gd", "stat"],
	&"harvest_yield": ["res://systems/harvesting/harvestable.gd", "stat"],
	&"harvest_damage": ["res://systems/harvesting/harvestable.gd", "stat"],
	&"craft_seconds": ["res://autoload/crafting_service.gd", "stat"],
	&"ward_radius_m": ["res://autoload/build_service.gd", "stat"],
	&"structure_hp": ["res://autoload/build_service.gd", "stat"],
}

## The honest list: a stat whose CONSUMING SYSTEM does not exist yet, and the reason. This is not a
## suppression list — a stat here still means a shipped powerup that does nothing, and every entry is
## a real gap. It is separated from the failures above because "nobody wired the read" and "there is
## no system to wire it to" are different bugs with different fixes, and collapsing them would make
## this check unactionable the day someone runs it.
const PENDING: Dictionary = {}

## The third state, and F-585 is why it exists. A stat can have a real, correct consumer and STILL
## never fire in a shipped run, because nothing puts the content in front of a player. That is a
## different fact from "nobody wired the read" (which fails above) and from "there is no system to
## wire it to" (`PENDING`), and collapsing it into either would be a lie in a different direction:
## calling it PENDING understates the work already done, and passing it silently as live would let
## `powerup_effects_check` assert that a powerup works when no player can ever trigger it.
##
## An entry here still means a powerup nobody will feel. It is reported, not failed, because the fix
## is in a different system entirely and deleting the wiring would be the wrong response.
const UNREACHABLE: Dictionary = {
	&"haul_speed": "wired in Haulable._haul_speed_scale(), but nothing outside tools/ ever spawns a haulable — HaulService.host_spawn() has no shipped gameplay caller",
}

var failures: int = 0
var registry: Node
var powerups: Node
var health: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return

	_check_every_authored_stat_is_accounted_for()
	_check_no_powerup_is_entirely_inert()
	_check_damage_taken()
	_check_stamina_stats()
	_check_fall_damage()

	print("\nPOWERUP_EFFECTS_CHECK failures=%d" % failures)
	finish()


func _check_wiring() -> bool:
	print("== the services these effects run through are registered ==")
	registry = root.get_node_or_null(^"Registry")
	powerups = root.get_node_or_null(^"PowerupService")
	health = root.get_node_or_null(^"PlayerHealth")
	check(registry != null, "Registry is registered as an autoload")
	check(powerups != null, "PowerupService is registered as an autoload")
	check(health != null, "PlayerHealth is registered as an autoload")
	return registry != null and powerups != null and health != null


## The regression guard. A grep against the consumer's source, deliberately — driving every consumer
## would need a physics body for half of them, and a stat with NO consumer at all is the whole bug.
func _check_every_authored_stat_is_accounted_for() -> void:
	print("\n== every stat a shipped powerup names is read, or is a recorded PENDING gap ==")
	var authored: Dictionary[StringName, StringName] = _authored_stats()
	check(not authored.is_empty(), "the shipped roster names at least one stat")
	var sources: Dictionary[String, String] = {}
	for stat_name: StringName in authored:
		if PENDING.has(stat_name):
			print("PENDING: '%s' (e.g. %s) — %s" % [
				stat_name, authored[stat_name], PENDING[stat_name]
			])
			continue
		if not CONSUMER_SITES.has(stat_name):
			check(false, ("'%s' (authored by %s) has no consumer recorded — wire the read and add " +
				"it to CONSUMER_SITES, or record it in PENDING with the system it waits on") % [
					stat_name, authored[stat_name]
				])
			continue
		var site: Array = CONSUMER_SITES[stat_name]
		var path: String = String(site[0])
		if not sources.has(path):
			sources[path] = _read_source(path)
		var source: String = sources[path]
		check(source != "", "%s is readable" % path)
		check(source.contains("&\"%s\"" % stat_name),
			"'%s' is read through PowerupService.%s() in %s" % [stat_name, site[1], path])
		if UNREACHABLE.has(stat_name):
			# Wired and correct, and still not something a player can meet. Said out loud rather
			# than counted as a pass.
			print("UNREACHABLE: '%s' — %s" % [stat_name, UNREACHABLE[stat_name]])


## F-580's headline number, as an assertion. A powerup every one of whose modifiers is unread is a
## chest reward that does nothing — the player-visible bug, one layer above the stat catalogue.
func _check_no_powerup_is_entirely_inert() -> void:
	print("\n== no shipped powerup consists solely of unread stats ==")
	var inert: PackedStringArray = PackedStringArray()
	var blocked: PackedStringArray = PackedStringArray()
	var unreachable_only: PackedStringArray = PackedStringArray()
	for definition: Resource in _shipped_powerups():
		var modifiers: Dictionary = definition.get(&"modifiers")
		if modifiers.is_empty():
			# A modifier-free powerup is a Resonance/qualitative one (§4.4) and is out of scope here:
			# its effect is not a stat, so a stat catalogue cannot judge it.
			continue
		var live: bool = false
		var reachable: bool = false
		var all_pending: bool = true
		for stat_name: StringName in modifiers:
			if CONSUMER_SITES.has(stat_name):
				live = true
				if not UNREACHABLE.has(stat_name):
					reachable = true
					break
				continue
			if not PENDING.has(stat_name):
				all_pending = false
		if live and reachable:
			continue
		if live:
			# Every stat it names is wired, and every one of them is unreachable content-side. The
			# powerup is not broken and the player still cannot feel it.
			unreachable_only.append(String(definition.get(&"id")))
			continue
		if all_pending:
			# Inert, but for a reason already recorded above and in docs/POWERUPS.md's pending table:
			# there is no system to read its stat. Reported, not failed — failing here would mean the
			# only way to go green is to delete shipped content, which is the wrong fix for a missing
			# system and would quietly shrink the roster every time a task slipped.
			blocked.append(String(definition.get(&"id")))
			continue
		inert.append(String(definition.get(&"id")))
	if not unreachable_only.is_empty():
		print("UNREACHABLE: %d powerup(s) fully wired but not reachable in a shipped run: %s" % [
			unreachable_only.size(), ", ".join(unreachable_only)
		])
	if not blocked.is_empty():
		print("PENDING: %d powerup(s) inert only because their system does not exist yet: %s" % [
			blocked.size(), ", ".join(blocked)
		])
	check(inert.is_empty(), "no powerup is inert for want of a read (inert: %s)" % (
		", ".join(inert) if not inert.is_empty() else "none"
	))


## docs/POWERUPS.md §2: `damage_taken` is "incoming damage after the attacker's calc", negative
## multiplier = armour. Driven through the real host seam, against a peer holding nothing.
func _check_damage_taken() -> void:
	print("\n== damage_taken reduces what a landed hit actually removes ==")
	var armour: StringName = _powerup_naming(&"damage_taken")
	if armour == &"":
		check(false, "some shipped powerup names damage_taken")
		return

	health.call(&"host_reset_for_new_run")
	powerups.call(&"host_clear_all")
	var bare_before: int = int(health.call(&"host_hp", HOST_PEER))
	if bare_before <= 0:
		# No spawned state for this peer in a bare offline boot: seed one the same way the host does.
		check(false, "PlayerHealth has host state for peer %d to damage" % HOST_PEER)
		return
	health.call(&"host_apply_damage", HOST_PEER, 10, 0)
	var bare_loss: int = bare_before - int(health.call(&"host_hp", HOST_PEER))

	health.call(&"host_reset_for_new_run")
	var granted: int = int(powerups.call(&"host_grant", HOST_PEER, armour, 3))
	check(granted > 0, "'%s' grants to peer %d" % [armour, HOST_PEER])
	var armoured_before: int = int(health.call(&"host_hp", HOST_PEER))
	health.call(&"host_apply_damage", HOST_PEER, 10, 0)
	var armoured_loss: int = armoured_before - int(health.call(&"host_hp", HOST_PEER))

	check(bare_loss == 10, "a bare peer loses the full 10 (lost %d)" % bare_loss)
	check(armoured_loss < bare_loss,
		"3 stacks of '%s' reduce a 10-damage hit (%d -> %d)" % [armour, bare_loss, armoured_loss])
	check(armoured_loss >= 1, "a landed hit still costs at least 1 hp (cost %d)" % armoured_loss)
	powerups.call(&"host_clear_all")


## The three client-local stamina stats, through the same public accessors player_controller.gd uses
## to gate sprint, jump and dodge. Offline, so the local peer IS the host peer.
func _check_stamina_stats() -> void:
	print("\n== max_stamina / stamina_regen / stamina_cost reach their consumers ==")
	powerups.call(&"host_clear_all")
	var bare_max: float = float(health.call(&"local_max_stamina"))
	var bare_jump_cost: float = float(health.call(&"local_jump_stamina_cost"))
	check(bare_max > 0.0, "a bare peer has a stamina pool (%.1f)" % bare_max)

	var pool: StringName = _powerup_naming(&"max_stamina")
	if pool != &"":
		powerups.call(&"host_grant", HOST_PEER, pool, 3)
		var boosted: float = float(health.call(&"local_max_stamina"))
		check(boosted > bare_max,
			"3 stacks of '%s' raise the pool (%.1f -> %.1f)" % [pool, bare_max, boosted])
		check(float(health.call(&"local_stamina")) <= boosted,
			"current stamina never exceeds the raised ceiling")
		powerups.call(&"host_clear_all")

	var discount: StringName = _powerup_naming(&"stamina_cost")
	if discount != &"":
		powerups.call(&"host_grant", HOST_PEER, discount, 3)
		var cheaper: float = float(health.call(&"local_jump_stamina_cost"))
		check(cheaper < bare_jump_cost,
			"3 stacks of '%s' make a jump cheaper (%.2f -> %.2f)" % [
				discount, bare_jump_cost, cheaper
			])
		check(cheaper >= 0.0, "a stamina cost never goes negative (%.2f)" % cheaper)
		powerups.call(&"host_clear_all")

	check(is_equal_approx(float(health.call(&"local_jump_stamina_cost")), bare_jump_cost),
		"clearing the stacks restores the authored jump cost")


## docs/POWERUPS.md §2: `fall_damage_taken` is landing damage, negative mult = softer. Driven through
## the real host seam, including the floor below which a landing costs nothing at all.
func _check_fall_damage() -> void:
	print("\n== fall damage exists, and fall_damage_taken softens it ==")
	var safe: float = float(health.get(&"FALL_SAFE_SPEED_MPS"))
	health.call(&"host_reset_for_new_run")
	powerups.call(&"host_clear_all")
	check(int(health.call(&"host_apply_fall_damage", HOST_PEER, safe)) == 0,
		"a landing at exactly the safe speed (%.1f m/s) costs nothing" % safe)
	var bare: int = int(health.call(&"host_apply_fall_damage", HOST_PEER, safe + 9.0))
	check(bare > 0, "a hard landing costs real hp (%d)" % bare)

	var cushion: StringName = _powerup_naming(&"fall_damage_taken")
	if cushion == &"":
		check(false, "some shipped powerup names fall_damage_taken")
		return
	health.call(&"host_reset_for_new_run")
	powerups.call(&"host_grant", HOST_PEER, cushion, 3)
	var softened: int = int(health.call(&"host_apply_fall_damage", HOST_PEER, safe + 9.0))
	check(softened < bare,
		"3 stacks of '%s' soften the same landing (%d -> %d)" % [cushion, bare, softened])
	powerups.call(&"host_clear_all")


# ── Shared ───────────────────────────────────────────────────────────────────────────────────────


## Every stat any shipped powerup names -> one powerup id that names it, for the failure message.
func _authored_stats() -> Dictionary[StringName, StringName]:
	var named: Dictionary[StringName, StringName] = {}
	for definition: Resource in _shipped_powerups():
		for stat_name: StringName in (definition.get(&"modifiers") as Dictionary):
			if not named.has(stat_name):
				named[stat_name] = StringName(String(definition.get(&"id")))
	return named


func _shipped_powerups() -> Array[Resource]:
	var all: Array[Resource] = []
	# Registry exposes the whole map rather than an id list, and this is the only caller that wants
	# every powerup at once — reading `powerups` directly beats adding an accessor for one probe.
	for definition: Variant in (registry.get(&"powerups") as Dictionary).values():
		if definition != null:
			all.append(definition as Resource)
	return all


## One shipped powerup that names this stat, or &"" — so the behaviour half drives REAL content
## rather than a fixture, and stays correct if the content is retuned.
func _powerup_naming(stat_name: StringName) -> StringName:
	for definition: Resource in _shipped_powerups():
		if (definition.get(&"modifiers") as Dictionary).has(stat_name):
			return StringName(String(definition.get(&"id")))
	return &""


func _read_source(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
