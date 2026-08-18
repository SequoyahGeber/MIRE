extends Node

## Run seed authority — docs/ARCHITECTURE.md §4: "The host picks a seed; the seed is replicated to
## clients." `ARCHITECTURE.md` §3 already reserves this file's path for "act, day, seed, run status
## (host-authoritative)"; task 6.1 (Cycle state machine) is where the rest of that slot gets built.
## This task (4.6) only needs the seed half, so it claims the reserved name/location now rather than
## inventing a second `core/net/run_seed.gd` that 6.1 would later have to merge with this one.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): HOST picks `run_seed`, once, from real entropy —
## the same reasoning D-041 gives for `Chest.host_seed_rng()`: nothing today needs this run to be
## reproducible across restarts, only that every peer IN the run agrees, which replication (not a
## fixed constant) already provides. `autoload/world_delta_log.gd` is what actually gets the value
## to a client — this file only holds it and decides when a fresh one is drawn.

signal seed_ready(value: int)

var run_seed: int = 0
var _seed_ready: bool = false


## Host-only. Called once per hosted session (`NetTransport.server_started`) and lazily by
## [method ensure_seed] for offline/host-of-one play, which never fires that signal at all.
func host_generate_seed() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	run_seed = rng.randi()
	_seed_ready = true
	seed_ready.emit(run_seed)
	return run_seed


## Client-side: adopt the value the host sent. Also safe to call host-side with its own value —
## idempotent, so callers never need to branch on who they are.
func set_replicated_seed(value: int) -> void:
	run_seed = value
	_seed_ready = true
	seed_ready.emit(run_seed)


func is_seed_ready() -> bool:
	return _seed_ready


## Anything that wants a seed right now — a headless harness, offline play that never opens a
## session — and does not want to reason about whether one has been drawn yet.
func ensure_seed() -> int:
	if not _seed_ready:
		host_generate_seed()
	return run_seed


## Mirrors `RunIdentity.clear()`'s reasoning: a run's seed does not outlive its session. The next
## hosted session draws a fresh one rather than reusing the last run's island.
func reset() -> void:
	run_seed = 0
	_seed_ready = false


func _ready() -> void:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null:
		return
	transport.get("server_started").connect(_on_hosting)
	transport.get("disconnected").connect(_on_disconnected)
	if bool(transport.call("is_active")) and bool(transport.call("is_host")):
		_on_hosting.call_deferred()


func _on_hosting() -> void:
	host_generate_seed()


func _on_disconnected() -> void:
	reset()
