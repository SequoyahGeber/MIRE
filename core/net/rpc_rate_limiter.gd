class_name RpcRateLimiter
extends RefCounted

## Per-peer minimum-interval gate for a host-side RPC handler (F-232's hostile-client audit).
##
## Every `net_request_*`/`net_submit_*` handler in this project already re-derives the caller from
## `multiplayer.get_remote_sender_id()` and re-validates state/range/ownership host-side — a lying
## client cannot forge who it is or what it owns. What none of them bound before this is HOW OFTEN a
## connected peer may ask: `BuildService.net_request_place()` runs a real
## `PhysicsDirectSpaceState3D` overlap query per call even when the placement is rejected, and
## `CommandService.net_submit_command()` runs `EntityDirectory.snapshot()` (a full entity-group scan)
## for any LOCAL-scope command with zero op check. A connected peer looping either costs the host real
## per-frame work for free, no exploit of any single request required — see docs/FINDINGS.md F-232.
##
## Harvestable/CombatService/RangedCombatService already avoid this, each in its own shape (a per-
## definition request cooldown, an in-flight swing/shot lock) — this generalizes the same idea into
## one reusable gate so the next host RPC does not have to reinvent it. NOT a replacement for those:
## an in-flight lock is still the tighter guard where a request naturally has one outcome in flight at
## a time, and stays as-is.
##
## Network authority: none — a private per-caller bookkeeping helper, not a networked system of its
## own. `Time.get_ticks_msec()` is real engine time, not run-seeded, so nothing about determinism
## applies here the way it does to world generation.

var _last_request_msec: Dictionary[int, int] = {}


## True and records "now" as the peer's last allowed request the instant at least
## [param min_interval_msec] have passed since its last allowed one; false (and no side effect)
## otherwise. A peer's very first call always passes — there is nothing to have flooded yet.
func allow(peer_id: int, min_interval_msec: int) -> bool:
	var now: int = Time.get_ticks_msec()
	var last: int = _last_request_msec.get(peer_id, -min_interval_msec)
	if now - last < min_interval_msec:
		return false
	_last_request_msec[peer_id] = now
	return true


## F-059's shape, same reason every other per-peer Dictionary in this codebase erases on departure:
## a peer id can be reused by Steam/ENet across sessions, and a stale timestamp would otherwise gate a
## brand-new connection against a flood that never happened. Callers key this off
## `NetSession.run_player_expired`/peer_left, not this file — it has no signal of its own to hear one.
func reset(peer_id: int) -> void:
	_last_request_msec.erase(peer_id)
