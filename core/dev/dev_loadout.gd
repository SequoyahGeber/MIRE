extends Node

## Grants a starting loadout so the game is playable before progression exists, and adds the console
## commands for poking at it.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, inventory row): **HOST**. Grants go through
## `InventoryService.host_add()`, which is a trusted host seam with no client RPC — a client cannot
## ask for a loadout, and this node does nothing at all on one. The list below is a debug
## convenience, not progression: task 3.x owns what a real run starts with, and `enabled` is how this
## stops being true without deleting anything.
##
## It hangs off `PlayerNet.player_spawned` (F-018) rather than polling or reaching into PlayerNet's
## container, which is exactly what that signal was added for.
##
## HARNESSES GET NO KIT (F-052). The offline `current_scene` gate below only protects `--script`
## runs that never open a session — but the two-process net checks open REAL sessions, players
## spawn, and this node silently granted 13 stacks into inventories whose checks begin with "host
## creates the client inventory empty". Four checks went red the day this shipped. So: a process
## launched with `--script` never grants, unless it opts in by setting the environment variable
## `MIRE_DEV_LOADOUT=1` in its `_initialize()` (autoloads are ready but no player has spawned yet,
## so the opt-in always lands in time). `dev_loadout_check` and `viewmodel_check` opt in — they are
## ABOUT the loadout. The shipped game never runs with `--script`, so players are unaffected.

const HOTBAR_START_INDEX: int = 24

## The switch. Off means no grants and the console commands still work — turn it off the moment
## starting gear becomes a design question rather than a "let me actually play it" one.
@export var enabled: bool = true

## F-043, decided in 2.13: the iron sword stays OUT of this list (option b — console-only until 3.x
## loot places it in the world). Two reasons, not one: the hotbar below is already full at 8/8
## (HOTBAR_SLOT_COUNT), so adding it `hotbar: true` would silently fail to reach the bar per
## _move_to_hotbar's own contract, landing in the backpack instead — not "in someone's hand"; and its
## WeaponDef numbers are still 2.9's unpassed placeholders (F-036), so handing out the strongest
## melee option by default would pollute 2.14's playtest signal on the weapons that ARE tuned. `give
## iron_sword` still reaches it for anyone who wants to test it deliberately.
##
## Given to every player when they spawn. Tools first so they land in the backpack in a readable
## order, then the resources 2.6's recipe wants.
## `hotbar: true` puts a stack on the bar instead of leaving it in the pack. This matters more than
## it looks: 2.4 fills backpack slots before hotbar ones, so a plain grant leaves you holding
## nothing and needing to open Tab and drag before you can swing at all — which is the same
## complaint as having no sword.
@export var loadout: Array[Dictionary] = [
	{"item": &"stone_axe", "count": 1, "hotbar": true},
	{"item": &"cleaver", "count": 1, "hotbar": true},
	{"item": &"skewer", "count": 1, "hotbar": true},
	{"item": &"repair_hammer", "count": 1, "hotbar": true},
	{"item": &"iron_pickaxe", "count": 1, "hotbar": true},
	{"item": &"short_bow", "count": 1, "hotbar": true},
	{"item": &"log", "count": 20, "hotbar": true},
	{"item": &"stone", "count": 20, "hotbar": true},
	{"item": &"wooden_axe", "count": 1},
	{"item": &"wooden_pickaxe", "count": 1},
	{"item": &"stone_pickaxe", "count": 1},
	{"item": &"arrow", "count": 12},
	{"item": &"iron_ore", "count": 10},
]

## Peers already granted this session, so a rebind or a late signal cannot hand out a second set.
var _granted: Dictionary[int, bool] = {}


func _ready() -> void:
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net != null and player_net.has_signal(&"player_spawned"):
		player_net.connect(&"player_spawned", _on_player_spawned)

	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport != null:
		transport.get("disconnected").connect(func() -> void: _granted.clear())

	_register_commands()
	# Offline there is no spawn signal — the level's hand-placed Player is already there — so the
	# grant is driven from _process instead, gated on a real level being up. See _process.
	set_process(true)


func grant(peer_id: int) -> bool:
	if not enabled or _harness_without_optin() or not _owns_grants() or peer_id <= 0 \
			or _granted.has(peer_id):
		return false
	var inventory: Node = get_node_or_null(^"/root/InventoryService")
	if inventory == null:
		return false
	_granted[peer_id] = true

	var given: int = 0
	for entry: Dictionary in loadout:
		var item_id := StringName(entry.get("item", &""))
		var count: int = int(entry.get("count", 0))
		if item_id == &"" or count <= 0:
			continue
		if not _item_exists(item_id):
			MireLog.warn(&"content", "DevLoadout: no item '%s' — skipped" % item_id)
			continue
		if bool(inventory.call("host_add", peer_id, item_id, count)):
			given += 1
			if bool(entry.get("hotbar", false)):
				_move_to_hotbar(inventory, peer_id, item_id)
	MireLog.info(&"content", "DevLoadout: granted %d stack(s) to peer %d" % [given, peer_id])
	return given > 0


## Moves the stack of [param item_id] out of the backpack and onto the first free hotbar slot, using
## the same host-validated move any drag would. Silent no-op if the bar is full — a loadout that
## overflows should still grant everything.
func _move_to_hotbar(inventory: Node, peer_id: int, item_id: StringName) -> void:
	var slots: Array = inventory.call("host_slots", peer_id)
	var source: int = -1
	for index: int in mini(HOTBAR_START_INDEX, slots.size()):
		if StringName(String((slots[index] as Dictionary).get("item_id", ""))) == item_id:
			source = index
			break
	if source < 0:
		return
	for index: int in range(HOTBAR_START_INDEX, slots.size()):
		if (slots[index] as Dictionary).is_empty():
			inventory.call("host_move_stack", peer_id, source, index, 0)
			return


func granted_peers() -> PackedInt32Array:
	var ids: PackedInt32Array = PackedInt32Array()
	for peer_id: int in _granted:
		ids.append(peer_id)
	ids.sort()
	return ids


## A `--script` process is a harness; harnesses assert exact inventory contents, so the kit stays
## out unless the harness says it is about the kit (F-052). Checked per call, not cached: the
## opt-in env var is set in a harness's `_initialize()`, which runs after this autoload's `_ready`.
func _harness_without_optin() -> bool:
	if not OS.get_cmdline_args().has("--script"):
		return false
	return OS.get_environment("MIRE_DEV_LOADOUT") != "1"


func _on_player_spawned(peer_id: int, _body: Node3D) -> void:
	# Deferred: this fires during add_child, and InventoryService creates the peer's store from its
	# own peer_joined handler. Granting into a store that does not exist yet silently drops it.
	grant.call_deferred(peer_id)


## Grants offline, once, and ONLY once a real level is running.
##
## `current_scene` is the gate, and it is load-bearing: a `--script` harness is its own main loop and
## never has one, so without this every headless check in `tools/` booted with a full inventory and
## a stocked hotbar. Four of them started failing the moment this autoload existed — an inventory
## check that asserts "starts empty" is right to fail when something quietly filled it.
func _process(_delta: float) -> void:
	if get_tree().current_scene == null:
		return
	set_process(false)
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport != null and bool(transport.call("is_active")):
		return
	grant(NetConfig.HOST_PEER_ID)


func _item_exists(item_id: StringName) -> bool:
	var registry: Node = get_node_or_null(^"/root/Registry")
	return registry != null and bool(registry.call("has_item", item_id))


# ── Console (docs/COMMANDS.md §2.1 — migrated off DebugConsole.register() in task 3.13) ────────────


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"give", {
		"scope": &"host",
		"args": [
			{"name": "item", "type": &"item_id"},
			{"name": "count", "type": &"int", "optional": true, "default": 1, "min": 1, "max": 999},
		],
		"handler": _cmd_give,
		"help": "give <item_id> [count] — grant to yourself",
	})
	command_service.call("register_spec", &"loadout", {
		"scope": &"host", "args": [], "handler": _cmd_loadout,
		"help": "loadout — re-grant the starting loadout",
	})
	command_service.call("register_spec", &"items", {
		"scope": &"local", "args": [], "handler": _cmd_items,
		"help": "items — list every registered item id",
	})


## CommandService has already validated `item` against Registry and clamped `count` to [1, 999] —
## this handler only needs to move the item. `ctx.peer_id` is who ISSUED the command (host itself, or
## an opped client via the RPC path); there is no `target` selector yet (that lands with 3.15's
## EntityDirectory), so `give` always grants to the issuer, matching what it always did.
func _cmd_give(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var item_id: StringName = args.get("item", &"")
	var count: int = int(args.get("count", 1))
	var inventory: Node = get_node_or_null(^"/root/InventoryService")
	var peer_id: int = int(ctx.get("peer_id", _local_peer()))
	if inventory == null or not bool(inventory.call("host_add", peer_id, item_id, count)):
		return {"ok": false, "message": "could not grant %s (inventory full?)" % item_id, "data": {}}
	# Exact text kept: whatever the next task's check greps for `give`'s success line should not have
	# to change because 3.13 rehomed the plumbing underneath it.
	return {"ok": true, "message": "gave %d x %s" % [count, item_id],
		"data": {"item": String(item_id), "count": count}}


func _cmd_loadout(ctx: Dictionary, _args: Dictionary) -> Dictionary:
	var peer_id: int = int(ctx.get("peer_id", _local_peer()))
	_granted.erase(peer_id)
	var granted: bool = grant(peer_id)
	return {"ok": granted, "message": "granted the starting loadout" if granted else "nothing granted",
		"data": {}}


func _cmd_items(_ctx: Dictionary, _args: Dictionary) -> String:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return "no registry"
	var ids: Array[String] = []
	for id: StringName in (registry.get("items") as Dictionary):
		ids.append(String(id))
	ids.sort()
	return ", ".join(ids)


func _local_peer() -> int:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null:
		return NetConfig.HOST_PEER_ID
	var peer_id: int = int(transport.call("local_peer_id"))
	return peer_id if peer_id > 0 else NetConfig.HOST_PEER_ID


func _owns_grants() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))
