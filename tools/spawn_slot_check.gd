extends SceneTree

## Reproduces F-129 headlessly: two players must never be handed the same spawn offset.
##
##   .agent/bin/agent godot --headless --script tools/spawn_slot_check.gd
##
## The bug shipped because the old slot expression looked obviously correct —
## `get_child_count() % SPAWN_OFFSETS.size()` reads like "the Nth player" and is right for a session
## that only ever grows. It is wrong the moment anyone leaves, and it presented as a *rendering*
## fault (a full-screen dark quad, which is DebugAvatarFace seen from inside another player's head)
## on whichever machine happened to join second. Nothing about the symptom pointed at spawning.
##
## So this asserts the property that actually matters — distinct peers hold distinct offsets — across
## the exact sequence that broke it: join, join, join, LEAVE, rejoin.
##
## Exits non-zero on failure.

var _failures: int = 0


func _init() -> void:
	# Autoloads do not exist yet during _init(); PlayerNet is only reachable once the tree is ready.
	root.ready.connect(_run, CONNECT_ONE_SHOT)


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, "" if detail.is_empty() else " — " + detail])


func _run() -> void:
	print("-- spawn slots (F-129) --")

	var net: Node = root.get_node_or_null("PlayerNet")
	if net == null:
		print("  FAIL  PlayerNet autoload is not registered")
		# The bail path needs the verdict as much as the end does, or an environment this check
		# cannot run in reads as "no verdict" rather than as the failure it is (F-555).
		print("SPAWN_SLOT_CHECK failures=1")
		quit(1)
		return

	# Host plus two clients, the shape of the session that surfaced this.
	var host: int = 1
	var a: int = 255386784
	var b: int = 1840122116

	var s_host: int = int(net.call("_claim_slot", host))
	var s_a: int = int(net.call("_claim_slot", a))
	var s_b: int = int(net.call("_claim_slot", b))
	_check("three peers get three distinct slots",
		s_host != s_a and s_a != s_b and s_host != s_b,
		"host=%d a=%d b=%d" % [s_host, s_a, s_b])

	_check("re-asking for a held slot is stable",
		int(net.call("_claim_slot", a)) == s_a,
		"a claim must not move while the player is still in the session")

	# The reproduction Sequoyah found: A leaves, then rejoins while B is still standing there.
	net.set("_slots", _without(net.get("_slots"), a))
	var s_a2: int = int(net.call("_claim_slot", a))
	_check("a rejoining player does not land on a peer who stayed",
		s_a2 != s_b and s_a2 != s_host,
		"rejoined into slot %d, but host=%d and b=%d are still occupied" % [s_a2, s_host, s_b])

	# And the freed index is the one that gets reused, rather than drifting outward forever.
	_check("the freed slot is reused rather than leaked", s_a2 == s_a,
		"expected the released slot %d back, got %d" % [s_a, s_a2])

	print("")
	# `agent verify` reads this line and fails the check outright when it is absent — an explicit,
	# greppable verdict is what stops a half-finished or crashed run passing by saying nothing
	# (F-293). This check reported in prose but never in that shape, so it was red however green
	# it ran (F-555).
	print("SPAWN_SLOT_CHECK failures=%d" % _failures)
	if _failures > 0:
		print("%d check(s) failed" % _failures)
		quit(1)
	else:
		print("all checks passed")
		quit(0)


func _without(slots: Dictionary, peer: int) -> Dictionary:
	var copy: Dictionary = slots.duplicate()
	copy.erase(peer)
	return copy
