extends Node

## PowerupService — autoload. Who holds which powerups, how they stack, and what that does to a stat.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Day/night, wave director, Cycle state, **active
## modifiers**" row): **HOST**. Only the host grants, revokes or clears. Clients never write a stack
## count; they receive one and read it. Two RPCs carry that (protocol 11):
##
##   · `net_powerup_snapshot` — rpc_id to ONE peer, their own full id -> count map.
##   · `net_powerup_counts`   — broadcast, per-peer per-family COUNTS only.
##
## The split is deliberate and is the spec's "owner gets full replication; teammates get counts
## only". A teammate needs to know you are three-deep in Fire — §4.4 makes that a social decision at
## every chest — but not which three Fire powerups you took. Sending the full map to everyone would
## also put the whole loot history of a six-player run on the wire every grant.
##
## THE ONE SEAM: systems ASK this service, it never reaches into systems.
##
##     speed = PowerupService.stat(peer_id, &"move_speed", BASE_SPEED)
##
## That direction is the whole point of the framework. A powerup that pushed values INTO
## PlayerController would make every new powerup a code change in the system it touches, which is
## exactly what DESIGN.md §4.4 says this must not be ("mostly data, not code"). Effects that cannot
## be expressed as a stat — §4.4's Resonances, which are qualitative — hook `resonance_active()` and
## implement themselves in their own task. This file stores the flag; it does not know what Blood
## resonance means.
##
## D-035 DISCIPLINE: stacks are keyed by peer id, and peer ids change across a reconnect. This
## service therefore does **not** drop state on `peer_left` — it waits for
## `NetSession.run_player_rebound(old, new)` to move it or `run_player_expired(peer)` to drop it.
## Releasing on `peer_left` is how InventoryService used to wipe an inventory on every reconnect;
## losing a run's powerups the same way would be worse, because unlike an inventory they cannot be
## re-gathered.

const LOG_CHANNEL: StringName = &"powerup"

## DESIGN.md §4.4: "Holding 3+ of a tag triggers a Resonance", 6+ a Greater Resonance. These are the
## thresholds the whole tag system is balanced around, so they live here as named constants rather
## than per-family data — a family that wants a different threshold is a design change worth
## noticing, not a number someone quietly edits in a .tres.
const RESONANCE_THRESHOLD: int = 3
const GREATER_RESONANCE_THRESHOLD: int = 6

enum Resonance { NONE, ACTIVE, GREATER }

## Host-side: peer id -> { powerup_id: StringName -> stacks: int }.
var _stacks: Dictionary[int, Dictionary] = {}
## Every peer's per-family counts, on every peer. Host fills it as it mutates; clients from the
## broadcast. peer id -> { family: StringName -> count: int }.
var _family_counts: Dictionary[int, Dictionary] = {}
## This peer's own full map, mirrored from the host's targeted snapshot. On the host this is simply
## its own entry in `_stacks`; the two are kept identical so `local_stat()` has one source.
##
## Untyped on purpose. Every value assigned to it arrives either from `Dictionary.duplicate()` or
## off the wire, and both hand back a plain Dictionary — assigning one to a
## `Dictionary[StringName, int]` throws at runtime on every single grant. The check caught it as a
## wall of engine-error lines under a green PASS count, which is the failure mode F-046/F-047 were
## filed for: this project's bar is zero failures AND zero error lines.
var _local_stacks: Dictionary = {}

## stat() is documented as a per-physics-frame query (movement asks it every tick), so its chain is
## kept allocation- and lookup-free (F-099): the transport node is cached once found, and resolved
## powerup definitions are memoized — content is loaded once at boot and never changes mid-run.
var _transport_node: Node
var _definition_cache: Dictionary[StringName, Resource] = {}

## Fires on the owning peer when its own stacks change — HUD, viewmodel, anything client-local.
signal local_powerups_changed(stacks: Dictionary)
## Fires wherever the count is known (host for anyone, every peer for the broadcast families) when a
## family crosses or falls back through a threshold. `tier` is a Resonance enum value.
signal resonance_changed(peer_id: int, family: StringName, tier: int)


func _ready() -> void:
	var transport: Node = _transport()
	transport.get("disconnected").connect(_on_disconnected)
	transport.get("peer_left").connect(_on_peer_left)
	transport.get("peer_joined").connect(_on_peer_joined)

	# D-035's consumer contract. NetSession owns run-player identity; this service only follows it.
	var session: Node = get_node_or_null(^"/root/NetSession")
	if session != null and session.has_signal(&"run_player_rebound"):
		session.connect(&"run_player_rebound", _on_run_player_rebound)
		session.connect(&"run_player_expired", _on_run_player_expired)
	_register_commands()



# ── Host mutation ────────────────────────────────────────────────────────────────────────────────


## Grants `count` stacks, clamped to the definition's `max_stacks`. Returns how many were ACTUALLY
## granted, which is 0 when the player is already capped — callers that charge a cost should check it
## rather than assume, the same way InventoryService.host_add() reports a partial add.
func host_grant(peer_id: int, powerup_id: StringName, count: int = 1) -> int:
	if not _owns_mutation() or peer_id <= 0 or count <= 0:
		return 0
	var definition: Resource = _definition(powerup_id)
	if definition == null:
		# warn, not error: this function's contract is already "returns how many were granted",
		# and 0 is a complete answer a caller is expected to read. ERROR in this project means an
		# invariant broke, and nothing has — an unknown id is a caller or content mistake that this
		# service handles cleanly. Warns always get through MireLog's channel filter, so it is still
		# seen; keeping it at error meant the negative path in powerup_check printed an engine-error
		# line under a green PASS count, which is exactly the shape F-046/F-047 were filed for.
		MireLog.warn(LOG_CHANNEL, "grant refused: no powerup '%s' in the registry" % powerup_id)
		return 0
	var held: Dictionary = _stacks.get_or_add(peer_id, {} as Dictionary)
	var current: int = int(held.get(powerup_id, 0))
	var maximum: int = int(definition.get(&"max_stacks"))
	var granted: int = mini(count, maxi(0, maximum - current))
	if granted <= 0:
		return 0
	held[powerup_id] = current + granted
	_commit(peer_id)
	MireLog.info(LOG_CHANNEL, "peer %d +%d %s (now %d/%d)" % [
		peer_id, granted, powerup_id, current + granted, maximum
	])
	return granted


## Returns how many stacks were actually removed. Reaching zero erases the entry rather than leaving
## a 0, so `_family_counts` and every `has()` below read the same way as a player who never had it.
func host_revoke(peer_id: int, powerup_id: StringName, count: int = 1) -> int:
	if not _owns_mutation() or count <= 0 or not _stacks.has(peer_id):
		return 0
	var held: Dictionary = _stacks[peer_id]
	var current: int = int(held.get(powerup_id, 0))
	if current <= 0:
		return 0
	var removed: int = mini(count, current)
	if current - removed <= 0:
		held.erase(powerup_id)
	else:
		held[powerup_id] = current - removed
	_commit(peer_id)
	return removed


func host_clear(peer_id: int) -> void:
	if not _owns_mutation() or not _stacks.has(peer_id):
		return
	_stacks[peer_id] = {}
	_commit(peer_id)


# ── The query seam ───────────────────────────────────────────────────────────────────────────────


## `(base + additive * stacks) * (1.0 + multiplicative * stacks)`, summed over every powerup the peer
## holds that names this stat. See D-044 for why additive-then-multiplicative and why both scale
## linearly instead of compounding.
##
## On the host this answers for anybody. On a client it answers for ITSELF — a client is only sent
## its own full map, so asking about a teammate returns `base`, which is the honest answer and not a
## silent zero. Client-authoritative systems (own movement, §2.2 row 1) ask about themselves, so this
## is the case that has to be right.
func stat(peer_id: int, stat_name: StringName, base: float) -> float:
	var held: Dictionary = _held_for(peer_id)
	if held.is_empty():
		return base
	var additive: float = 0.0
	var multiplicative: float = 0.0
	for powerup_id: StringName in held:
		var definition: Resource = _definition(powerup_id)
		if definition == null:
			continue
		var modifiers: Dictionary = definition.get(&"modifiers")
		if not modifiers.has(stat_name):
			continue
		var pair: Vector2 = modifiers[stat_name]
		var stacks: int = int(held[powerup_id])
		additive += pair.x * float(stacks)
		multiplicative += pair.y * float(stacks)
	return (base + additive) * (1.0 + multiplicative)


## Convenience for the common client-local case, so presentation code does not have to ask the
## transport who it is first.
func local_stat(stat_name: StringName, base: float) -> float:
	return stat(_local_peer_id(), stat_name, base)


func stacks_of(peer_id: int, powerup_id: StringName) -> int:
	return int(_held_for(peer_id).get(powerup_id, 0))


## Total stacks across every powerup carrying this tag. This is what a Resonance counts (§4.4), and
## it is deliberately NOT "how many distinct Fire powerups" — three stacks of one Fire powerup and
## one stack each of three different Fire powerups both resonate.
##
## Known on every peer for every player, because the broadcast carries exactly this.
func family_count(peer_id: int, family: StringName) -> int:
	return int(_family_counts.get(peer_id, {} as Dictionary).get(family, 0))


func resonance_tier(peer_id: int, family: StringName) -> int:
	var count: int = family_count(peer_id, family)
	if count >= GREATER_RESONANCE_THRESHOLD:
		return Resonance.GREATER
	if count >= RESONANCE_THRESHOLD:
		return Resonance.ACTIVE
	return Resonance.NONE


## The flag §4.4's qualitative effects hook. Data only: this service does not know that Blood
## resonance heals on kill — the task that ships that effect asks this and implements itself.
func resonance_active(peer_id: int, family: StringName) -> bool:
	return resonance_tier(peer_id, family) != Resonance.NONE


func greater_resonance_active(peer_id: int, family: StringName) -> bool:
	return resonance_tier(peer_id, family) == Resonance.GREATER


## Every family this peer has any stake in, and its count. For a HUD that wants to show progress
## toward a Resonance rather than only the crossing.
func families_of(peer_id: int) -> Dictionary:
	return (_family_counts.get(peer_id, {} as Dictionary) as Dictionary).duplicate()


func local_stacks() -> Dictionary:
	return _local_stacks.duplicate()


# ── Internals ────────────────────────────────────────────────────────────────────────────────────


func _held_for(peer_id: int) -> Dictionary:
	if _owns_mutation():
		return _stacks.get(peer_id, {} as Dictionary)
	return _local_stacks if peer_id == _local_peer_id() else {} as Dictionary


## Recomputes derived state and republishes. Every host mutation ends here, so there is exactly one
## place where family counts, resonance transitions and the wire can disagree with `_stacks` — and it
## is this one.
func _commit(peer_id: int) -> void:
	var before: Dictionary = (_family_counts.get(peer_id, {} as Dictionary) as Dictionary).duplicate()
	var after: Dictionary = _recompute_families(peer_id)
	_family_counts[peer_id] = after

	for family: StringName in _union_keys(before, after):
		var was: int = _tier_for_count(int(before.get(family, 0)))
		var now: int = _tier_for_count(int(after.get(family, 0)))
		if was != now:
			resonance_changed.emit(peer_id, family, now)
			MireLog.info(LOG_CHANNEL, "peer %d %s resonance %d -> %d" % [peer_id, family, was, now])

	if peer_id == _local_peer_id():
		_local_stacks = (_stacks.get(peer_id, {} as Dictionary) as Dictionary).duplicate()
		local_powerups_changed.emit(_local_stacks.duplicate())

	_publish(peer_id)


func _recompute_families(peer_id: int) -> Dictionary:
	var counts: Dictionary = {}
	for powerup_id: StringName in _stacks.get(peer_id, {} as Dictionary):
		var definition: Resource = _definition(powerup_id)
		if definition == null:
			continue
		var stacks: int = int((_stacks[peer_id] as Dictionary)[powerup_id])
		for family: StringName in (definition.get(&"tags") as Array):
			counts[family] = int(counts.get(family, 0)) + stacks
	return counts


func _tier_for_count(count: int) -> int:
	if count >= GREATER_RESONANCE_THRESHOLD:
		return Resonance.GREATER
	if count >= RESONANCE_THRESHOLD:
		return Resonance.ACTIVE
	return Resonance.NONE


func _union_keys(a: Dictionary, b: Dictionary) -> Array:
	var keys: Array = a.keys()
	for key: Variant in b:
		if not a.has(key):
			keys.append(key)
	return keys


func _publish(peer_id: int) -> void:
	if not bool(_transport().call("is_active")):
		return
	# F-059: rpc_id() to a peer that has already gone throws "unknown peer ID". D-035 keeps the
	# state alive through the grace window on purpose, so publishing to a parked run-player is the
	# NORMAL case here, not an edge one — guard it rather than trusting the state to imply presence.
	if peer_id != NetConfig.HOST_PEER_ID and _peer_connected(peer_id):
		net_powerup_snapshot.rpc_id(peer_id, _stacks.get(peer_id, {} as Dictionary))
	net_powerup_counts.rpc(peer_id, _family_counts.get(peer_id, {} as Dictionary))


# ── Replication (host -> clients, reliable: a dropped grant is a lost powerup) ────────────────────


@rpc("authority", "call_remote", "reliable")
func net_powerup_snapshot(stacks: Dictionary) -> void:
	if _owns_mutation():
		return
	_local_stacks = stacks.duplicate()
	local_powerups_changed.emit(_local_stacks.duplicate())


@rpc("authority", "call_remote", "reliable")
func net_powerup_counts(peer_id: int, families: Dictionary) -> void:
	if _owns_mutation():
		return
	var before: Dictionary = (_family_counts.get(peer_id, {} as Dictionary) as Dictionary).duplicate()
	_family_counts[peer_id] = families.duplicate()
	for family: StringName in _union_keys(before, families):
		var was: int = _tier_for_count(int(before.get(family, 0)))
		var now: int = _tier_for_count(int(families.get(family, 0)))
		if was != now:
			resonance_changed.emit(peer_id, family, now)


# ── Lifecycle ────────────────────────────────────────────────────────────────────────────────────


## D-035, the load-bearing half: a departure is NOT a reason to drop a run-player's powerups. A
## reconnect arrives as a new peer id and `run_player_rebound` moves the state onto it; only
## `run_player_expired` means they are not coming back.
func _on_peer_left(_peer_id: int) -> void:
	pass


## Without this a joiner knows nothing until somebody happens to gain a powerup — its own map would
## be empty and every teammate's Resonance invisible, silently, for as long as nobody opened a chest.
## Publishing on mutation alone is only correct if every peer was present for every mutation, which
## is exactly what a mid-run join is not. Found by writing the two-process check, not by reading
## this file.
func _on_peer_joined(peer_id: int) -> void:
	if not _owns_mutation() or not _peer_connected(peer_id):
		return
	_publish(peer_id)
	for known_peer: int in _family_counts:
		if known_peer != peer_id:
			net_powerup_counts.rpc_id(peer_id, known_peer, _family_counts[known_peer])


func _on_run_player_rebound(old_peer_id: int, new_peer_id: int) -> void:
	if not _owns_mutation() or not _stacks.has(old_peer_id):
		return
	_stacks[new_peer_id] = _stacks[old_peer_id]
	_stacks.erase(old_peer_id)
	if _family_counts.has(old_peer_id):
		# Move the counts to the new id BEFORE discarding the old one, so _commit(new_peer_id)
		# below diffs against the pre-rebind counts and does not re-fire resonance_changed for
		# thresholds the player already crossed under the old id.
		_family_counts[new_peer_id] = _family_counts[old_peer_id]
		_retire_broadcast(old_peer_id, _family_counts[old_peer_id])
		_family_counts.erase(old_peer_id)
	_commit(new_peer_id)


func _on_run_player_expired(peer_id: int) -> void:
	if not _owns_mutation():
		return
	if _family_counts.has(peer_id):
		_retire_broadcast(peer_id, _family_counts[peer_id])
	_stacks.erase(peer_id)
	_family_counts.erase(peer_id)


## F-089: the shared tail of rebound (old id) and expiry. `net_powerup_counts` has no deletion path
## of its own, so an id that is about to be discarded from `_family_counts` must be broadcast as
## empty first — otherwise every teammate keeps the last nonzero count they heard for an id that no
## longer exists (a ghost Resonance that survives reconnect or expiry forever). `before` is the
## about-to-be-discarded id's own counts, not the target of a rebind, so the downward transition is
## attributed to the id that is actually going away.
func _retire_broadcast(peer_id: int, before: Dictionary) -> void:
	for family: StringName in before:
		var was: int = _tier_for_count(int(before[family]))
		if was != Resonance.NONE:
			resonance_changed.emit(peer_id, family, Resonance.NONE)
			MireLog.info(LOG_CHANNEL, "peer %d %s resonance %d -> %d" % [peer_id, family, was, Resonance.NONE])
	if bool(_transport().call("is_active")):
		net_powerup_counts.rpc(peer_id, {})


func _on_disconnected() -> void:
	_stacks.clear()
	_family_counts.clear()
	_local_stacks.clear()
	local_powerups_changed.emit({})


func _definition(powerup_id: StringName) -> Resource:
	var cached: Resource = _definition_cache.get(powerup_id)
	if cached != null:
		return cached
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return null
	var definition: Resource = registry.call(&"get_powerup", powerup_id)
	if definition != null:
		_definition_cache[powerup_id] = definition
	return definition


func _owns_mutation() -> bool:
	var transport: Node = _transport()
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _peer_connected(peer_id: int) -> bool:
	return bool(_transport().call("has_peer", peer_id))


func _local_peer_id() -> int:
	var peer_id: int = int(_transport().call("local_peer_id"))
	return peer_id if peer_id > 0 else NetConfig.HOST_PEER_ID


## Path-resolved (F-011 — harnesses install the transport at /root), cached once found (F-099).
func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node(^"/root/NetTransport")
	return _transport_node


# ── Commands (docs/COMMANDS.md §7 — task 3.16) ───────────────────────────────────────────────────


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"powerup", {
		"scope": &"host",
		"args": [
			{"name": "op", "type": &"enum", "values": ["give", "clear", "list"]},
			{"name": "target", "type": &"peer", "optional": true, "default": 0},
			{"name": "powerup", "type": &"string", "optional": true, "default": ""},
			{"name": "stacks", "type": &"int", "optional": true, "default": 1, "min": 1},
		],
		"handler": _cmd_powerup,
		"help": "powerup give|clear|list [peer] [powerup_id] [stacks] — grant, wipe or list powerups",
	})
	command_service.call("register_spec", &"stat", {
		"scope": &"host",
		"args": [
			{"name": "name", "type": &"string"},
			{"name": "target", "type": &"peer", "optional": true, "default": 0},
			{"name": "base", "type": &"float", "optional": true, "default": 1.0},
		],
		"handler": _cmd_stat,
		"help": "stat <stat_name> [peer] [base] — what this peer's powerups do to a stat",
	})


## `powerup_id` is typed as a raw string, not the `powerup_id` arg type, for the same reason the
## `rule` value is: it is optional and follows a subcommand, so `powerup clear 5` must not fail
## parsing on a missing third token. Validation happens in the branch that actually needs an id —
## and `host_grant` refuses an unknown one anyway, which is where the authoritative answer lives.
func _cmd_powerup(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var operation: String = String(args.get("op", "list"))
	var peer_id: int = int(args.get("target", 0))
	if peer_id <= 0:
		peer_id = int(ctx.get("peer_id", NetConfig.HOST_PEER_ID))

	if operation == "clear":
		var held: int = (stacks_for(peer_id) as Dictionary).size()
		host_clear(peer_id)
		return {"ok": true, "message": "cleared %d powerup(s) from peer %d" % [held, peer_id],
			"data": {"peer": peer_id, "cleared": held}}

	if operation == "list":
		var held: Dictionary = stacks_for(peer_id)
		if held.is_empty():
			return {"ok": true, "message": "peer %d holds no powerups" % peer_id,
				"data": {"peer": peer_id, "powerups": {}}}
		var lines: PackedStringArray = ["peer %d holds %d powerup(s):" % [peer_id, held.size()]]
		for id: Variant in held:
			lines.append("  %s x%d" % [id, int(held[id])])
		return {"ok": true, "message": "\n".join(lines),
			"data": {"peer": peer_id, "powerups": held}}

	var powerup_id := StringName(String(args.get("powerup", "")).strip_edges())
	if powerup_id == &"":
		return {"ok": false, "message": "usage: powerup give <peer> <powerup_id> [stacks]", "data": {}}
	var granted: int = host_grant(peer_id, powerup_id, int(args.get("stacks", 1)))
	if granted <= 0:
		# host_grant returns 0 for both "no such powerup" and "already capped", and its own log line
		# distinguishes them. Say both here rather than guessing which one the player hit.
		return {"ok": false,
			"message": "granted nothing — '%s' is unknown, or peer %d is already at max stacks"
				% [powerup_id, peer_id], "data": {"peer": peer_id, "granted": 0}}
	return {"ok": true, "message": "peer %d +%d %s" % [peer_id, granted, powerup_id],
		"data": {"peer": peer_id, "powerup": String(powerup_id), "granted": granted}}


## The read that makes the whole framework debuggable: what does this player's stack actually DO to
## a number? `base` defaults to 1.0 so the answer reads as a plain multiplier when you do not care
## about the real base value.
func _cmd_stat(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var peer_id: int = int(args.get("target", 0))
	if peer_id <= 0:
		peer_id = int(ctx.get("peer_id", NetConfig.HOST_PEER_ID))
	var stat_name := StringName(String(args.get("name", "")))
	var base: float = float(args.get("base", 1.0))
	var value: float = stat(peer_id, stat_name, base)
	return {"ok": true, "message": "peer %d %s: %.4f (base %.4f)" % [peer_id, stat_name, value, base],
		"data": {"peer": peer_id, "stat": String(stat_name), "value": value, "base": base}}


## The host-side read `powerup list`/`clear` need. Public because a command is a legitimate caller of
## host state, and returning a COPY because handing out the live dictionary would let any caller
## mutate stacks without going through host_grant/host_revoke — the second mutation path §3.3 bans.
func stacks_for(peer_id: int) -> Dictionary:
	return (_stacks.get(peer_id, {} as Dictionary) as Dictionary).duplicate()
