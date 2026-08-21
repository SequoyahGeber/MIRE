extends Node

## GodModeService — the single playtesting-state seam for invulnerability, flight, and future
## God-mode abilities.
##
## Network authority (docs/ARCHITECTURE.md §2.2): COMMAND EXECUTION/HOST for the toggle and player
## health for invulnerability; OWN PLAYER MOVEMENT/CLIENT for flight. `god` is a HOST-scope command,
## so CommandService re-parses it on the host and enforces op status. The host keeps the canonical
## peer set and sends only the approved result to that peer's owning client. PlayerHealth reads the
## host set before any hp mutation; PlayerController reads only this process's local approved state.
##
## Future God-mode powers belong behind `is_enabled()` / `is_local_enabled()` instead of growing
## separate cheat flags in their consuming systems.

signal god_mode_changed(peer_id: int, enabled: bool)
## Settings UI feedback for the op-gated request path. `enabled` is the requested value; `accepted`
## says whether the host applied it, and `detail` is safe to show directly beside the toggle.
signal god_mode_request_completed(enabled: bool, accepted: bool, detail: String)

const LOG_CHANNEL: StringName = &"dev"

var _enabled_peers: Dictionary[int, bool] = {}
var _transport_node: Node
## CommandService handle -> requested enabled value. Stored before submission because a solo/host
## command completes synchronously inside `submit_with_handle()`.
var _pending_requests: Dictionary[int, bool] = {}


func _ready() -> void:
	_register_commands()
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service != null and command_service.has_signal(&"command_result"):
		command_service.connect(&"command_result", _on_command_result)
	var session: Node = get_node_or_null(^"/root/NetSession")
	if session == null:
		return
	if session.has_signal(&"run_player_rebound"):
		session.connect(&"run_player_rebound", _on_run_player_rebound)
	if session.has_signal(&"run_player_expired"):
		session.connect(&"run_player_expired", _on_run_player_expired)
	if session.has_signal(&"session_ended"):
		session.connect(&"session_ended", _on_session_ended)


## Host/solo-only mutation seam. Returns false for an absent peer or a non-authoritative caller.
## Enabling first commits immunity, then revives/heals through PlayerHealth's existing host seams, so
## a tester can recover even if they toggle God mode after already being downed.
func host_set_enabled(peer_id: int, enabled: bool) -> bool:
	if not _owns_mutation() or peer_id <= 0 or not _peer_exists(peer_id):
		return false
	_set_cached(peer_id, enabled)
	if enabled:
		_restore_health(peer_id)
	if peer_id == _local_peer_id():
		return true
	if bool(_transport().call(&"is_active")):
		net_set_local_enabled.rpc_id(peer_id, enabled)
	return true


func host_toggle(peer_id: int) -> bool:
	return host_set_enabled(peer_id, not is_enabled(peer_id))


## Canonical on the host. A client intentionally knows only its own approved state.
func is_enabled(peer_id: int) -> bool:
	return _enabled_peers.get(peer_id, false)


func is_local_enabled() -> bool:
	return is_enabled(_local_peer_id())


## UI-friendly front door. Always travels through the same HOST-scope `god` command as the console:
## solo/host completes synchronously; a client submits to the host and receives the ordinary op-gated
## CommandResult. The settings screen never gets a privileged second mutation path.
func request_local_enabled(enabled: bool) -> bool:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		god_mode_request_completed.emit(enabled, false, "CommandService unavailable")
		return false
	var handle: int = int(command_service.call(&"reserve_handle"))
	_pending_requests[handle] = enabled
	var ctx: Dictionary = command_service.call(&"build_local_ctx", &"settings")
	command_service.call(
		&"submit_with_handle", handle, "god %s" % ("on" if enabled else "off"), ctx)
	return true


func _on_command_result(handle: int, result: Dictionary) -> void:
	if not _pending_requests.has(handle):
		return
	var requested: bool = _pending_requests[handle]
	_pending_requests.erase(handle)
	var accepted: bool = bool(result.get("ok", false))
	var detail: String = String(result.get("message", ""))
	if accepted:
		# On a remote client the dedicated host RPC may arrive just before or just after the command
		# result. The result itself is host-authored and reliable, so adopting its approved value here
		# makes the checkbox immediate without weakening PlayerHealth's host-side canonical set.
		_set_cached(_local_peer_id(), bool(result.get("data", {}).get("enabled", requested)))
	god_mode_request_completed.emit(requested, accepted, detail)


@rpc("authority", "call_remote", "reliable")
func net_set_local_enabled(enabled: bool) -> void:
	var peer_id: int = _local_peer_id()
	if peer_id <= 0:
		return
	_set_cached(peer_id, enabled)


func _set_cached(peer_id: int, enabled: bool) -> void:
	var previous: bool = is_enabled(peer_id)
	if enabled:
		_enabled_peers[peer_id] = true
	else:
		_enabled_peers.erase(peer_id)
	if previous == enabled:
		return
	MireLog.info(LOG_CHANNEL, "God mode %s for peer %d" % ["ON" if enabled else "OFF", peer_id])
	god_mode_changed.emit(peer_id, enabled)


func _restore_health(peer_id: int) -> void:
	var health: Node = get_node_or_null(^"/root/PlayerHealth")
	if health == null:
		return
	if health.has_method(&"host_is_downed") and bool(health.call(&"host_is_downed", peer_id)):
		health.call(&"host_revive", peer_id)
	if health.has_method(&"host_heal"):
		health.call(&"host_heal", peer_id, 0)


func _peer_exists(peer_id: int) -> bool:
	if not bool(_transport().call(&"is_active")):
		return peer_id == NetConfig.HOST_PEER_ID
	return bool(_transport().call(&"has_peer", peer_id))


func _owns_mutation() -> bool:
	if bool(_transport().call(&"is_host")):
		return true
	return not bool(_transport().call(&"is_active")) \
		and not bool(_transport().call(&"is_connecting"))


func _local_peer_id() -> int:
	var peer_id: int = int(_transport().call(&"local_peer_id"))
	return peer_id if peer_id > 0 else NetConfig.HOST_PEER_ID


func _transport() -> Node:
	if not is_instance_valid(_transport_node):
		_transport_node = get_node(^"/root/NetTransport")
	return _transport_node


func _on_run_player_rebound(old_peer_id: int, new_peer_id: int) -> void:
	if not is_enabled(old_peer_id):
		return
	_enabled_peers.erase(old_peer_id)
	_set_cached(new_peer_id, true)
	if new_peer_id != _local_peer_id() and bool(_transport().call(&"has_peer", new_peer_id)):
		net_set_local_enabled.rpc_id(new_peer_id, true)


func _on_run_player_expired(peer_id: int) -> void:
	_set_cached(peer_id, false)


func _on_session_ended(_reason: int, _detail: String) -> void:
	var peers: Array[int] = []
	peers.assign(_enabled_peers.keys())
	for peer_id: int in peers:
		_set_cached(peer_id, false)


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call(&"register_spec", &"god", {
		"scope": &"host",
		"args": [{
			"name": "state", "type": &"enum", "values": ["toggle", "on", "off", "status"],
			"optional": true, "default": "toggle",
		}],
		"handler": _cmd_god,
		"help": "god [toggle|on|off|status] — toggle invulnerability and flight for yourself",
	})


func _cmd_god(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var peer_id: int = int(ctx.get("peer_id", NetConfig.HOST_PEER_ID))
	var operation: String = String(args.get("state", "toggle"))
	if operation == "status":
		var current: bool = is_enabled(peer_id)
		return _command_result(current, peer_id, true)

	var enabled: bool = operation == "on" or (operation == "toggle" and not is_enabled(peer_id))
	if not host_set_enabled(peer_id, enabled):
		return {
			"ok": false,
			"message": "could not change God mode for peer %d" % peer_id,
			"data": {"peer": peer_id},
		}
	return _command_result(enabled, peer_id, true)


func _command_result(enabled: bool, peer_id: int, ok: bool) -> Dictionary:
	return {
		"ok": ok,
		"message": "God mode %s — invulnerable; fly with movement/look, jump up, dodge down" %
			("ON" if enabled else "OFF"),
		"data": {"peer": peer_id, "enabled": enabled},
	}
