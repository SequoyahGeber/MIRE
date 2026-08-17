extends SceneTree

## Focused proof for F-032: a run-player identity survives a reconnect, cannot be stolen from a live
## peer, expires when nobody comes back, and carries an inventory across a peer-id change.
##
## The registry is pure data, so its rules are tested directly rather than through a session. The
## InventoryService half is driven through NetSession's two signals, which is exactly the seam a
## gameplay system consumes.

const RUN_IDENTITY := preload("res://core/net/run_identity.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	_check_registry()
	_check_inventory_handover()
	print("RUN_IDENTITY_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _check_registry() -> void:
	var reg: RefCounted = RUN_IDENTITY.new()
	var now: int = 1_000_000

	# ── a first join mints ────────────────────────────────────────────────────────────────────────
	var first: Dictionary = reg.call("claim", 100, "")
	var token: String = String(first.get("token", ""))
	check(not token.is_empty(), "a first join is issued a token")
	check(token.length() == RUN_IDENTITY.TOKEN_BYTES * 2, "the token is %d bytes of hex"
		% RUN_IDENTITY.TOKEN_BYTES)
	check(int(first.get("rebound_from", -1)) == 0, "a first join rebinds nothing")
	check(reg.call("token_for", 100) == token, "the registry maps peer to token")
	check(bool(reg.call("is_live", 100)), "a connected peer is live")

	var second: Dictionary = reg.call("claim", 200, "")
	check(String(second.get("token", "")) != token, "two players get different tokens")

	# ── rule 1: a live peer's identity cannot be stolen ───────────────────────────────────────────
	var thief: Dictionary = reg.call("claim", 300, token)
	check(String(thief.get("token", "")) != token,
		"presenting a live player's token gets a fresh identity, not theirs")
	check(int(thief.get("rebound_from", -1)) == 0, "a refused steal rebinds nothing")
	check(reg.call("peer_for", token) == 100, "the live player keeps its own token")

	# ── the reconnect this whole finding is about ─────────────────────────────────────────────────
	check(reg.call("mark_left", 100, now) == token, "a departure returns the token it parked")
	check(not bool(reg.call("is_live", 100)), "a departed peer is no longer live")
	check(int(reg.call("orphan_count")) == 1, "one identity is parked")
	var back: Dictionary = reg.call("claim", 999, token)
	check(String(back.get("token", "")) == token, "a returning player keeps its token")
	check(int(back.get("rebound_from", -1)) == 100, "the rebind names the peer id it used to hold")
	check(reg.call("token_for", 999) == token, "the token now maps to the new peer id")
	check(reg.call("token_for", 100) == "", "the old peer id is released")
	check(int(reg.call("orphan_count")) == 0, "reclaiming clears the parked identity")

	# ── two players reconnecting together do not swap ─────────────────────────────────────────────
	var a_token: String = String((reg.call("claim", 11, "") as Dictionary).get("token", ""))
	var b_token: String = String((reg.call("claim", 22, "") as Dictionary).get("token", ""))
	reg.call("mark_left", 11, now)
	reg.call("mark_left", 22, now)
	check(int(reg.call("orphan_count")) == 2, "both departures park")
	var b_back: Dictionary = reg.call("claim", 44, b_token)
	var a_back: Dictionary = reg.call("claim", 33, a_token)
	check(int(b_back.get("rebound_from", -1)) == 22 and int(a_back.get("rebound_from", -1)) == 11,
		"each returning player rebinds to its OWN previous peer id, in any order")

	# ── expiry ────────────────────────────────────────────────────────────────────────────────────
	var grace_msec: int = int(RUN_IDENTITY.ORPHAN_GRACE_SEC * 1000.0)
	reg.call("mark_left", 999, now)
	check((reg.call("expire", now + grace_msec - 1) as Array).is_empty(),
		"an identity inside its grace window is not expired")
	check(int(reg.call("orphan_count")) == 1, "it is still parked")
	var dead: Array = reg.call("expire", now + grace_msec + 1)
	check(dead.size() == 1 and int(dead[0]) == 999,
		"an identity past its grace window expires, naming the peer its state is keyed under")
	check(reg.call("peer_for", token) == 0, "an expired token is forgotten")
	check(int(reg.call("orphan_count")) == 0, "nothing is left parked")

	check(RUN_IDENTITY.ORPHAN_GRACE_SEC > 7.5,
		"the grace window outlasts NetSession's whole rejoin ladder")


## The gameplay half: a store keyed by one peer id must arrive at another, intact, and must not be
## released while the player might still return.
func _check_inventory_handover() -> void:
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var session: Node = root.get_node_or_null(^"NetSession")
	check(inventory != null, "InventoryService autoload exists")
	check(session != null, "NetSession autoload exists")
	if inventory == null or session == null:
		return
	check(session.has_signal(&"run_player_rebound"), "NetSession exposes run_player_rebound")
	check(session.has_signal(&"run_player_expired"), "NetSession exposes run_player_expired")
	check(session.has_method("run_token"), "a peer can read its own run token")
	check(String(session.call("run_token")).is_empty(), "no token is held outside a session")

	# Offline the host is peer 1 and owns mutation, so host_add is the real grant path.
	check(bool(inventory.call("host_add", 1, &"log", 5)), "host grants the departing player logs")
	check(int(inventory.call("host_count", 1, &"log")) == 5, "the store holds them")

	# peer_left must no longer be a wipe — this is the actual defect F-032 recorded.
	inventory.call("_on_peer_left", 1)
	check(int(inventory.call("host_count", 1, &"log")) == 5,
		"a departure alone does not release the inventory")

	session.emit_signal(&"run_player_rebound", 1, 77)
	check(int(inventory.call("host_count", 77, &"log")) == 5,
		"the rebind carries the whole store to the new peer id")
	check((inventory.call("host_slots", 1) as Array).is_empty(),
		"nothing is left under the old peer id")

	session.emit_signal(&"run_player_expired", 77)
	check((inventory.call("host_slots", 77) as Array).is_empty(),
		"expiry releases the store, so a player who never returns holds nothing")


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
