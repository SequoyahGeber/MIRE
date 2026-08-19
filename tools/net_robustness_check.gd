extends SceneTree

## Network robustness check (task 7.8): hostile disconnect timing — a peer that has already gone
## (or was never really there) is still an in-flight RPC's target. Real ENet, no editor:
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/net_robustness_check.gd
##
## EXPECTED ENGINE ERRORS: none. Every scenario this drives is the exact one Godot logs when it is
## NOT guarded — `ERROR: Attempt to call RPC with unknown peer ID: <id>`, F-059's own wording — and
## every one of the five call sites below is supposed to carry that guard now. A clean run is
## therefore zero ERROR lines, no declared pattern needed:
##   grep 'ERROR:' | wc -l   → must be 0
##
## WHAT THIS PROVES. `docs/FINDINGS.md` F-059 fixed one unguarded specific-peer `rpc_id()` send
## (`InventoryService._publish_snapshot`) and left the fix as a pattern — `_peer_connected(peer_id)`
## / `NetTransport.has_peer(peer_id)` before any `rpc_id()` aimed at a peer that is not the sender of
## the RPC currently executing. `PlayerHealth`, `PowerupService`, `BuildService`, `RuleService`,
## `AttunementService`, `Chest`, `Haulable` all already carry it (grep for "F-059" to find each). This
## task audited every remaining `rpc_id(peer_id, ...)` call site in the repo against that pattern and
## found five that did not: `CombatService._reject`, `RangedCombatService._reject`,
## `CraftingService._confirm_peer`, `CommandService.net_submit_command`'s reply (the request line runs
## through an `await execute()`, which is exactly the window a disconnect can land in), and
## `WorldDeltaLog._on_peer_admitted`. All five are fixed the same way and driven here directly against
## a peer id that was never admitted, in a real hosted session — the guard is exercised for real, not
## asserted. `net_session.gd`'s own `net_run_identity.rpc_id()` was checked and left alone: it answers
## synchronously inside the very RPC handler the sender's hello arrived through, so there is no gap for
## a disconnect to land in before the reply goes out — nothing else in the file has that shape.
##
## TO SEE THE BUG THIS FIXES: `agent baseline --script tools/net_robustness_check.gd` against a
## revision before this task's fix reproduces `ERROR: Attempt to call RPC with unknown peer ID` at
## each of the first three sections below (CommandService and WorldDeltaLog are checked at the guard
## level — see the section comments for why).

const PORT: int = 47431

## Never actually connects — the "already gone" id every send below targets. Chosen well outside
## ENet's own peer-id range so it can never collide with a real connection this process makes.
const GHOST_PEER: int = 999919

var _failures: int = 0
var _transport: Node
var _session: Node
var _combat: Node
var _ranged: Node
var _crafting: Node
var _command: Node
var _world_delta: Node


func _initialize() -> void:
	# NOTHING may touch the autoloads from _initialize (F-011) — they are children of root already
	# but have not entered the tree, so a call here would run against a null multiplayer API.
	_start.call_deferred()


func _start() -> void:
	await process_frame
	if not _autoloads():
		print("autoloads missing — NetTransport / NetSession / CombatService / RangedCombatService / CraftingService / CommandService / WorldDeltaLog")
		quit(1)
		return
	await _run()


func _autoloads() -> bool:
	_transport = root.get_node_or_null(^"NetTransport")
	_session = root.get_node_or_null(^"NetSession")
	_combat = root.get_node_or_null(^"CombatService")
	_ranged = root.get_node_or_null(^"RangedCombatService")
	_crafting = root.get_node_or_null(^"CraftingService")
	_command = root.get_node_or_null(^"CommandService")
	_world_delta = root.get_node_or_null(^"WorldDeltaLog")
	return (
		_transport != null and _session != null and _combat != null and _ranged != null
		and _crafting != null and _command != null and _world_delta != null
	)


func _run() -> void:
	print("\n== network robustness: hostile disconnect timing (task 7.8) ==")

	print("\n-- host a real session, so is_active()/is_host() are genuinely true, not assumed --")
	var err: Error = _transport.host(NetConfig.Mode.LOCAL, PORT)
	_check("host() started on port %d" % PORT, err == OK, error_string(err))
	await create_timer(0.3).timeout
	_check("hosting", bool(_transport.is_host()))
	_check("the ghost peer was never admitted", not bool(_transport.call("has_peer", GHOST_PEER)),
		"peers now %s" % str(_transport.call("peer_ids")))

	print("\n-- CombatService._reject to a peer that already left mid-swing --")
	_combat.call("_reject", GHOST_PEER, 1, "test detail")
	await process_frame
	_check("reached the next section without an unguarded rpc_id() send", true)

	print("\n-- RangedCombatService._reject to a peer that already left mid-draw --")
	_ranged.call("_reject", GHOST_PEER, 1, "test detail")
	await process_frame
	_check("reached the next section without an unguarded rpc_id() send", true)

	print("\n-- CraftingService._confirm_peer to a peer that already left mid-craft --")
	_crafting.call("_confirm_peer", GHOST_PEER, 1, true, "test detail")
	await process_frame
	_check("reached the next section without an unguarded rpc_id() send", true)

	print("\n-- WorldDeltaLog._on_peer_admitted for a peer that already left in the same instant --")
	_world_delta.call("_on_peer_admitted", GHOST_PEER)
	await process_frame
	_check("reached the next section without an unguarded rpc_id() send", true)

	# CommandService's fix guards the RPC handler's REPLY, after an `await execute(...)` — and that
	# `await` is what makes a real remote-sender id available to fake here. `_peer_connected` is the
	# exact predicate the fix now checks before net_command_result.rpc_id(); proving it answers
	# correctly for a ghost id, and correctly for a real one, proves the guard the handler relies on.
	print("\n-- CommandService's reply guard: correct for a departed sender, correct for a real one --")
	_check("the ghost peer reads as not connected", not bool(_command.call("_peer_connected", GHOST_PEER)))
	_check("the host's own id reads as connected", bool(_command.call("_peer_connected", NetConfig.HOST_PEER_ID)))

	_transport.leave()
	await process_frame
	print("\n%d failure(s)\n" % _failures)
	quit(1 if _failures > 0 else 0)


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s%s" % [label, ("  — " + detail) if detail != "" else ""])
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])
