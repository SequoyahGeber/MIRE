class_name RunIdentity
extends RefCounted

## Stable per-run player identity, so host-owned state can follow a player across a reconnect (F-032).
##
## The problem: an ENet client that drops and rejoins gets a **new peer id** — 1.7's lifecycle check
## saw peer `1037623507` come back as `361299977`. Every host-owned system keys its state by peer id,
## so from their point of view one player left forever and a different one arrived. `InventoryService`
## did the only safe thing available and released the departed inventory, because the alternative —
## handing an orphaned inventory to "the next joiner" — gives the wrong inventory the moment two
## players reconnect together.
##
## The fix is an opaque token the host mints once per run-player and the client presents on every
## join. The host, and only the host, decides what a token means; a client can lie about one but the
## worst it can do is claim an identity that is currently unoccupied, which is exactly what a rejoin
## is. Two rules make that safe:
##
## 1. **A token whose peer is still connected is never reassigned.** A second client presenting it
##    gets a fresh identity instead, so nobody can steal a live player's state.
## 2. **A token expires.** State is not held for a player who is never coming back, and the grace
##    window is longer than `NetSession`'s whole rejoin ladder so a genuine reconnect always lands
##    inside it.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): HOST. Only the host holds a registry; a client holds
## nothing but the one token it was issued. Tokens are never broadcast — the host tells each client
## its own and no one else's.
##
## Pure data, no node and no RPCs, so it is testable without a session — same reasoning as
## `net_version.gd`.

## 16 bytes of real entropy, hex-encoded. Not `randi()`: this is an identity, and two peers minting
## the same one would swap their inventories.
const TOKEN_BYTES: int = 16

## How long a departed player's identity — and therefore its state — is held before release.
## `NetSession`'s rejoin ladder is 0.5 + 1 + 2 + 4 s of backoff plus connect time, so this is roughly
## an order of magnitude of headroom. It is a run-scoped hold, not a save: D-010 says a run is one
## sitting, so nothing here survives the process.
const ORPHAN_GRACE_SEC: float = 90.0

## token -> {"peer": int, "left_at_msec": int}. `left_at_msec` is 0 while the peer is connected.
var _by_token: Dictionary[String, Dictionary] = {}
## peer id -> token, for the reverse lookup every caller actually has in hand.
var _by_peer: Dictionary[int, String] = {}
var _crypto := Crypto.new()


## Resolve who [param peer_id] is, given the token it presented. [param presented] is "" on a first
## join. Returns `{"token": String, "rebound_from": int}`, where `rebound_from` is the peer id this
## player used to hold, or 0 if this is a new identity.
func claim(peer_id: int, presented: String) -> Dictionary:
	if peer_id <= 0:
		return {"token": "", "rebound_from": 0}

	var record: Dictionary = _by_token.get(presented, {}) as Dictionary
	var claimable: bool = (
		not presented.is_empty()
		and not record.is_empty()
		# Rule 1: a live peer's identity is not up for grabs. Re-presenting your own token while
		# still connected is fine and is a no-op rebind.
		and (int(record.get("left_at_msec", 0)) > 0 or int(record.get("peer", 0)) == peer_id)
	)
	if not claimable:
		return {"token": _mint(peer_id), "rebound_from": 0}

	var previous: int = int(record.get("peer", 0))
	_by_peer.erase(previous)
	_by_peer[peer_id] = presented
	_by_token[presented] = {"peer": peer_id, "left_at_msec": 0}
	return {"token": presented, "rebound_from": previous if previous != peer_id else 0}


## Start the grace clock for a peer that has gone. Returns its token, or "" if it had none.
func mark_left(peer_id: int, now_msec: int) -> String:
	var token: String = String(_by_peer.get(peer_id, ""))
	if token.is_empty():
		return ""
	_by_token[token] = {"peer": peer_id, "left_at_msec": maxi(now_msec, 1)}
	return token


## Tokens whose grace has run out, released as they are returned. The peer id each one last held
## comes back with it, because that is the key every gameplay system stored its state under.
func expire(now_msec: int) -> Array[int]:
	var grace_msec: int = int(ORPHAN_GRACE_SEC * 1000.0)
	var dead: Array[int] = []
	for token: String in _by_token.keys():
		var record: Dictionary = _by_token[token]
		var left: int = int(record.get("left_at_msec", 0))
		if left <= 0 or now_msec - left < grace_msec:
			continue
		dead.append(int(record.get("peer", 0)))
		_by_peer.erase(int(record.get("peer", 0)))
		_by_token.erase(token)
	return dead


func token_for(peer_id: int) -> String:
	return String(_by_peer.get(peer_id, ""))


func peer_for(token: String) -> int:
	return int((_by_token.get(token, {}) as Dictionary).get("peer", 0))


## True while this peer is connected under a known identity.
func is_live(peer_id: int) -> bool:
	var token: String = token_for(peer_id)
	if token.is_empty():
		return false
	return int((_by_token[token] as Dictionary).get("left_at_msec", 0)) == 0


## Identities currently parked, waiting to be reclaimed.
func orphan_count() -> int:
	var total: int = 0
	for token: String in _by_token:
		if int((_by_token[token] as Dictionary).get("left_at_msec", 0)) > 0:
			total += 1
	return total


func clear() -> void:
	_by_token.clear()
	_by_peer.clear()


func _mint(peer_id: int) -> String:
	# Drop whatever this peer held before: minting means the old identity was not claimable, so
	# leaving the reverse lookup pointing at it would strand the new one.
	var stale: String = String(_by_peer.get(peer_id, ""))
	if not stale.is_empty():
		_by_token.erase(stale)

	var token: String = _crypto.generate_random_bytes(TOKEN_BYTES).hex_encode()
	# A collision is not credible at 128 bits, but a silent identity swap is bad enough that the
	# check is worth its two lines.
	while _by_token.has(token):
		token = _crypto.generate_random_bytes(TOKEN_BYTES).hex_encode()
	_by_token[token] = {"peer": peer_id, "left_at_msec": 0}
	_by_peer[peer_id] = token
	return token
