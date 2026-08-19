class_name EventBus
extends RefCounted

## Cross-system event seam. This is intentionally a static dispatcher rather than an autoload:
## callers can use it from code-built gameplay nodes without adding another singleton or touching a
## scene. Subscribers must unsubscribe when they leave the tree; invalid callables are also pruned
## before every dispatch.
##
## Network authority: none. The bus never sends an RPC or changes gameplay state. Producers are
## responsible for emitting only from the authority that owns their event. Harvestable emits its
## yield event on the host, and the host-owned inventory layer introduced by task 2.4 consumes it.

static var _harvest_yielded_subscribers: Array[Callable] = []
static var _enemy_attack_landed_subscribers: Array[Callable] = []
static var _wellspring_capped_subscribers: Array[Callable] = []
static var _wellspring_recorrupted_subscribers: Array[Callable] = []
static var _cycle_advanced_subscribers: Array[Callable] = []
static var _cycle_modifier_drawn_subscribers: Array[Callable] = []
static var _ship_repaired_subscribers: Array[Callable] = []
static var _run_extracted_subscribers: Array[Callable] = []
static var _run_wiped_subscribers: Array[Callable] = []
static var _salvage_banked_subscribers: Array[Callable] = []
static var _unlock_purchased_subscribers: Array[Callable] = []


## Listener signature:
##     (harvestable_id: StringName, peer_id: int, item_id: StringName,
##      amount: int, world_position: Vector3) -> void
static func subscribe_harvest_yielded(listener: Callable) -> void:
	_prune_invalid(_harvest_yielded_subscribers)
	if listener.is_valid() and not _harvest_yielded_subscribers.has(listener):
		_harvest_yielded_subscribers.append(listener)


static func unsubscribe_harvest_yielded(listener: Callable) -> void:
	_harvest_yielded_subscribers.erase(listener)


static func emit_harvest_yielded(
	harvestable_id: StringName,
	peer_id: int,
	item_id: StringName,
	amount: int,
	world_position: Vector3
) -> void:
	_prune_invalid(_harvest_yielded_subscribers)
	# A listener may unsubscribe while handling the event. Iterate a snapshot so that does not skip
	# whichever listener happened to follow it in the live array.
	for listener: Callable in _harvest_yielded_subscribers.duplicate():
		listener.call(harvestable_id, peer_id, item_id, amount, world_position)


static func harvest_yielded_subscriber_count() -> int:
	_prune_invalid(_harvest_yielded_subscribers)
	return _harvest_yielded_subscribers.size()


## Listener signature:
##     (enemy_id: StringName, peer_id: int, damage: int, world_position: Vector3) -> void
##
## Emitted by the HOST only, at the moment an enemy's telegraphed swing resolves (task 2.10). It
## exists because player health does not: task 2.13 (downed → bleed-out → revive) owns what an
## enemy hit costs, and inventing a health field inside the enemy to avoid an event would have put
## player state under the wrong system.
static func subscribe_enemy_attack_landed(listener: Callable) -> void:
	_prune_invalid(_enemy_attack_landed_subscribers)
	if listener.is_valid() and not _enemy_attack_landed_subscribers.has(listener):
		_enemy_attack_landed_subscribers.append(listener)


static func unsubscribe_enemy_attack_landed(listener: Callable) -> void:
	_enemy_attack_landed_subscribers.erase(listener)


static func emit_enemy_attack_landed(
	enemy_id: StringName, peer_id: int, damage: int, world_position: Vector3
) -> void:
	_prune_invalid(_enemy_attack_landed_subscribers)
	for listener: Callable in _enemy_attack_landed_subscribers.duplicate():
		listener.call(enemy_id, peer_id, damage, world_position)


static func enemy_attack_landed_subscriber_count() -> int:
	_prune_invalid(_enemy_attack_landed_subscribers)
	return _enemy_attack_landed_subscribers.size()


## Listener signature: (wellspring_name: StringName, world_position: Vector3) -> void
##
## Emitted by the HOST only, the instant a Wellspring's ritual timer completes (task 4.8). No
## reward, chest, Mire hook or Attunement grant lives here — D-092 defers those to whichever future
## task actually has something to hook them to (4.9-4.11's Mire, a reward system not yet built);
## this event is that seam.
static func subscribe_wellspring_capped(listener: Callable) -> void:
	_prune_invalid(_wellspring_capped_subscribers)
	if listener.is_valid() and not _wellspring_capped_subscribers.has(listener):
		_wellspring_capped_subscribers.append(listener)


static func unsubscribe_wellspring_capped(listener: Callable) -> void:
	_wellspring_capped_subscribers.erase(listener)


static func emit_wellspring_capped(wellspring_name: StringName, world_position: Vector3) -> void:
	_prune_invalid(_wellspring_capped_subscribers)
	for listener: Callable in _wellspring_capped_subscribers.duplicate():
		listener.call(wellspring_name, world_position)


static func wellspring_capped_subscriber_count() -> int:
	_prune_invalid(_wellspring_capped_subscribers)
	return _wellspring_capped_subscribers.size()


## Listener signature: (wellspring_name: StringName, world_position: Vector3) -> void
##
## Emitted by the HOST only, the instant a capped Wellspring's re-corruption timer finishes (task
## 6.4, DESIGN.md §5.1 item 1: "Capped Wellsprings begin re-corrupting"). The Wellspring itself goes
## back to `capped == false`, exactly its pre-ritual state, so the same channel ritual recaptures it.
## `MireGrid` is this event's own first consumer — it undoes the per-cap spread-rate reduction
## `wellspring_capped` granted, the symmetric half of that hook.
static func subscribe_wellspring_recorrupted(listener: Callable) -> void:
	_prune_invalid(_wellspring_recorrupted_subscribers)
	if listener.is_valid() and not _wellspring_recorrupted_subscribers.has(listener):
		_wellspring_recorrupted_subscribers.append(listener)


static func unsubscribe_wellspring_recorrupted(listener: Callable) -> void:
	_wellspring_recorrupted_subscribers.erase(listener)


static func emit_wellspring_recorrupted(wellspring_name: StringName, world_position: Vector3) -> void:
	_prune_invalid(_wellspring_recorrupted_subscribers)
	for listener: Callable in _wellspring_recorrupted_subscribers.duplicate():
		listener.call(wellspring_name, world_position)


static func wellspring_recorrupted_subscriber_count() -> int:
	_prune_invalid(_wellspring_recorrupted_subscribers)
	return _wellspring_recorrupted_subscribers.size()


## Listener signature: (cycle: int) -> void
##
## Emitted by the HOST only, the moment `CycleService` advances a Cycle (task 6.1, DESIGN.md §5.1).
## No Cycle Modifier is drawn here — 6.2 owns the deck/draw/stacking framework, which does not exist
## yet; this event is the seam it drives off, the same "future task's hook" role D-092 gave
## wellspring_capped above.
static func subscribe_cycle_advanced(listener: Callable) -> void:
	_prune_invalid(_cycle_advanced_subscribers)
	if listener.is_valid() and not _cycle_advanced_subscribers.has(listener):
		_cycle_advanced_subscribers.append(listener)


static func unsubscribe_cycle_advanced(listener: Callable) -> void:
	_cycle_advanced_subscribers.erase(listener)


static func emit_cycle_advanced(cycle: int) -> void:
	_prune_invalid(_cycle_advanced_subscribers)
	for listener: Callable in _cycle_advanced_subscribers.duplicate():
		listener.call(cycle)


static func cycle_advanced_subscriber_count() -> int:
	_prune_invalid(_cycle_advanced_subscribers)
	return _cycle_advanced_subscribers.size()


## Listener signature: (modifier_id: StringName, cycle: int) -> void
##
## Emitted by the HOST only, the instant `CycleModifierService` draws a Cycle Modifier from the deck
## (task 6.2, DESIGN.md §5.1 item 2) — fired from inside the same `cycle_advanced` handler that draws
## it, so a listener never sees a Cycle advance without also seeing that Cycle's draw (or its
## absence, if the deck had nothing eligible left). No modifier EFFECT is wired to any gameplay
## system here — this is the seam a future consumer (PowerupService, WaveSpawner, MireGrid) hangs an
## actual effect off, the same "future task's hook" role D-092 gave `wellspring_capped` and D-100
## gave `cycle_advanced` itself.
static func subscribe_cycle_modifier_drawn(listener: Callable) -> void:
	_prune_invalid(_cycle_modifier_drawn_subscribers)
	if listener.is_valid() and not _cycle_modifier_drawn_subscribers.has(listener):
		_cycle_modifier_drawn_subscribers.append(listener)


static func unsubscribe_cycle_modifier_drawn(listener: Callable) -> void:
	_cycle_modifier_drawn_subscribers.erase(listener)


static func emit_cycle_modifier_drawn(modifier_id: StringName, cycle: int) -> void:
	_prune_invalid(_cycle_modifier_drawn_subscribers)
	for listener: Callable in _cycle_modifier_drawn_subscribers.duplicate():
		listener.call(modifier_id, cycle)


static func cycle_modifier_drawn_subscriber_count() -> int:
	_prune_invalid(_cycle_modifier_drawn_subscribers)
	return _cycle_modifier_drawn_subscribers.size()


## Listener signature: (ship_name: StringName, world_position: Vector3) -> void
##
## Emitted by the HOST only, the instant `ExtractionShip.repair_stage` reaches its final stage (task
## 6.5, DESIGN.md §5.2: "From Cycle 3, the wreck can be repaired with mid-tier resources"). No
## departure happens here — boarding and the group confirm flow are a separate step the crew still
## has to choose to take. This is only the "the wreck is seaworthy" moment, the seam a future VFX/
## audio cue hangs off, same "future task's hook" role D-092 gave `wellspring_capped`.
static func subscribe_ship_repaired(listener: Callable) -> void:
	_prune_invalid(_ship_repaired_subscribers)
	if listener.is_valid() and not _ship_repaired_subscribers.has(listener):
		_ship_repaired_subscribers.append(listener)


static func unsubscribe_ship_repaired(listener: Callable) -> void:
	_ship_repaired_subscribers.erase(listener)


static func emit_ship_repaired(ship_name: StringName, world_position: Vector3) -> void:
	_prune_invalid(_ship_repaired_subscribers)
	for listener: Callable in _ship_repaired_subscribers.duplicate():
		listener.call(ship_name, world_position)


static func ship_repaired_subscriber_count() -> int:
	_prune_invalid(_ship_repaired_subscribers)
	return _ship_repaired_subscribers.size()


## Listener signature: (cycle: int, world_position: Vector3) -> void
##
## Emitted by the HOST only, the instant every present, connected player has held the group confirm
## together long enough to complete `ExtractionShip`'s departure (task 6.5, DESIGN.md §5.2: boarding
## "ends the run successfully: you bank your full Salvage, and your run is recorded at the Cycle you
## reached"). Nothing here banks anything — `SalvageService` (task 6.6) is this signal's one
## consumer, applying the superlinear reward curve and persisting the result locally. Its
## `run_wiped` counterpart lives just below.
static func subscribe_run_extracted(listener: Callable) -> void:
	_prune_invalid(_run_extracted_subscribers)
	if listener.is_valid() and not _run_extracted_subscribers.has(listener):
		_run_extracted_subscribers.append(listener)


static func unsubscribe_run_extracted(listener: Callable) -> void:
	_run_extracted_subscribers.erase(listener)


static func emit_run_extracted(cycle: int, world_position: Vector3) -> void:
	_prune_invalid(_run_extracted_subscribers)
	for listener: Callable in _run_extracted_subscribers.duplicate():
		listener.call(cycle, world_position)


static func run_extracted_subscriber_count() -> int:
	_prune_invalid(_run_extracted_subscribers)
	return _run_extracted_subscribers.size()


## Listener signature: (cycle: int, world_position: Vector3) -> void
##
## The `run_extracted` counterpart DESIGN.md §5.2 names but nothing has built yet: "dying instead
## banks a fraction" needs a signal to bank against, the same way boarding needed `run_extracted`.
## Task 6.6 (Salvage) adds this seam ahead of task 6.7 ("Lose condition"), which is the task that
## will actually decide WHEN a run has ended in defeat — team wipe with no bleed-out revive pending,
## or the island fully consumed (docs/SPECS.md's 6.7 look-ahead). Nothing here detects that; 6.7
## must call `emit_run_wiped()` from wherever it lands that verdict, reusing this exact signal rather
## than inventing a second one — `SalvageService` (task 6.6) is already wired to only this name.
##
## **6.7 must fire this the same way task 6.6 fixed `ExtractionShip.departed`'s emit: from a
## REPLICATED property's setter, not a host-only guard.** `EventBus` is a per-process static — an
## emit call that only runs inside a host-only `if` (the shape `_finish_departure()` used before
## 6.6, and the shape `Wellspring._finish_cap()` still uses for `wellspring_capped`) never reaches a
## client's own local bus at all, so that peer's own Salvage would never bank. See docs/FINDINGS.md
## for the general version of this trap.
static func subscribe_run_wiped(listener: Callable) -> void:
	_prune_invalid(_run_wiped_subscribers)
	if listener.is_valid() and not _run_wiped_subscribers.has(listener):
		_run_wiped_subscribers.append(listener)


static func unsubscribe_run_wiped(listener: Callable) -> void:
	_run_wiped_subscribers.erase(listener)


static func emit_run_wiped(cycle: int, world_position: Vector3) -> void:
	_prune_invalid(_run_wiped_subscribers)
	for listener: Callable in _run_wiped_subscribers.duplicate():
		listener.call(cycle, world_position)


static func run_wiped_subscriber_count() -> int:
	_prune_invalid(_run_wiped_subscribers)
	return _run_wiped_subscribers.size()


## Listener signature: (earned: int, total_salvage: int, cycle: int, extracted: bool) -> void
##
## Emitted LOCALLY by `SalvageService` (task 6.6) on whichever peer just banked, the instant it
## finishes writing `SalvageSave` — `earned` is this run's payout (already fraction-applied if
## `extracted` is false), `total_salvage` is that peer's new lifetime balance, `cycle` is the Cycle
## the run ended at. This is the seam task 6.8 ("run summary: ... Salvage earned") builds its screen
## from — nothing here shows UI or ends a session, same "future task's hook" role D-092 gave
## `wellspring_capped`.
static func subscribe_salvage_banked(listener: Callable) -> void:
	_prune_invalid(_salvage_banked_subscribers)
	if listener.is_valid() and not _salvage_banked_subscribers.has(listener):
		_salvage_banked_subscribers.append(listener)


static func unsubscribe_salvage_banked(listener: Callable) -> void:
	_salvage_banked_subscribers.erase(listener)


static func emit_salvage_banked(earned: int, total_salvage: int, cycle: int, extracted: bool) -> void:
	_prune_invalid(_salvage_banked_subscribers)
	for listener: Callable in _salvage_banked_subscribers.duplicate():
		listener.call(earned, total_salvage, cycle, extracted)


static func salvage_banked_subscriber_count() -> int:
	_prune_invalid(_salvage_banked_subscribers)
	return _salvage_banked_subscribers.size()


## Listener signature: (unlock_id: StringName, cost: int, total_salvage: int) -> void
##
## Emitted LOCALLY by `UnlockService` (task 6.9) on whichever peer just spent Salvage on
## `unlock_id`, the instant it finishes writing `UnlockSave` — `cost` is what that row charged,
## `total_salvage` is that peer's new balance after the spend. Same "future task's hook" role
## `salvage_banked` plays for 6.8's run summary: nothing here shows UI or gates any pool, it only
## announces that a purchase happened.
static func subscribe_unlock_purchased(listener: Callable) -> void:
	_prune_invalid(_unlock_purchased_subscribers)
	if listener.is_valid() and not _unlock_purchased_subscribers.has(listener):
		_unlock_purchased_subscribers.append(listener)


static func unsubscribe_unlock_purchased(listener: Callable) -> void:
	_unlock_purchased_subscribers.erase(listener)


static func emit_unlock_purchased(unlock_id: StringName, cost: int, total_salvage: int) -> void:
	_prune_invalid(_unlock_purchased_subscribers)
	for listener: Callable in _unlock_purchased_subscribers.duplicate():
		listener.call(unlock_id, cost, total_salvage)


static func unlock_purchased_subscriber_count() -> int:
	_prune_invalid(_unlock_purchased_subscribers)
	return _unlock_purchased_subscribers.size()


static func _prune_invalid(subscribers: Array[Callable]) -> void:
	for index: int in range(subscribers.size() - 1, -1, -1):
		if not subscribers[index].is_valid():
			subscribers.remove_at(index)
