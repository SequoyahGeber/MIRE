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

## F-333 made this a TOKEN BUCKET rather than a hard minimum interval.
##
## The interval gate bounded abuse correctly and broke ordinary use at the same time. A peer doing
## normal sequential work — grant an item, craft it, place the result, demolish it — issues several
## commands inside 100 ms and had all but the first REJECTED, not delayed. Three shipped integration
## checks (`command_net_check`, `command_craft_build_net_check`, `entity_net_check`) failed on it,
## which is the executable contract declining to adopt the behaviour.
##
## A bucket separates the two things the interval gate conflated. `burst` is how many requests may
## arrive at once, which is what ordinary use needs; the refill rate — one token per
## `min_interval_msec` — is the SUSTAINED ceiling, which is the only thing F-232 was actually
## protecting. A scripted flood still flattens to the same rate it did before; a human, or a check,
## doing four things in a row no longer gets told to slow down.
##
## `peer_id -> [tokens, last_msec]`. Two-element array rather than two dictionaries so a peer's whole
## state is added and erased in one place and cannot half-survive a `reset()`.
var _buckets: Dictionary[int, Array] = {}


## True (consuming one token) if this peer may act now; false with no side effect otherwise.
##
## A peer's very first call always passes — the bucket starts full, because there is nothing to have
## flooded yet. `burst` of 1 reproduces the pre-F-333 minimum-interval behaviour exactly, which is
## why callers that want the old semantics can simply not pass it.
func allow(peer_id: int, min_interval_msec: int, burst: int = 1) -> bool:
	var capacity: float = float(maxi(burst, 1))
	var interval: float = float(maxi(min_interval_msec, 1))
	var now: int = Time.get_ticks_msec()

	var bucket: Array = _buckets.get(peer_id, [capacity, now])
	var tokens: float = float(bucket[0])
	var last: int = int(bucket[1])
	# Fractional accrual, so a caller arriving at 60 ms of a 100 ms interval keeps the 0.6 it earned
	# instead of losing it to integer truncation and drifting slower than the advertised rate.
	tokens = minf(capacity, tokens + float(now - last) / interval)

	if tokens < 1.0:
		# Deliberately still records the refill: dropping the timestamp on a rejection would restart
		# accrual from now and make a spamming peer strictly slower than the ceiling says, which is a
		# rate limit that lies about its own rate.
		_buckets[peer_id] = [tokens, now]
		return false
	_buckets[peer_id] = [tokens - 1.0, now]
	return true


## F-059's shape, same reason every other per-peer Dictionary in this codebase erases on departure:
## a peer id can be reused by Steam/ENet across sessions, and a stale timestamp would otherwise gate a
## brand-new connection against a flood that never happened. Callers key this off
## `NetSession.run_player_expired`/peer_left, not this file — it has no signal of its own to hear one.
func reset(peer_id: int) -> void:
	_buckets.erase(peer_id)
