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
static var _boss_engaged_subscribers: Array[Callable] = []
static var _boss_phase_changed_subscribers: Array[Callable] = []
static var _boss_defeated_subscribers: Array[Callable] = []
static var _run_restarted_subscribers: Array[Callable] = []
static var _world_rebuilt_subscribers: Array[Callable] = []
static var _tier_reached_subscribers: Array[Callable] = []
static var _enemy_killed_subscribers: Array[Callable] = []
## Monotonic count of `world_rebuilt` emits — the PULL half of that event. See its block below.
static var _world_generation: int = 0


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
## Fires on EVERY peer's own bus the moment `CycleService` advances a Cycle (task 6.1, DESIGN.md
## §5.1) — the host emits directly from `_announce()`; a client re-derives the identical emit from
## `WorldDeltaLog`'s replicated record of that same advance landing locally
## (`CycleService._on_world_delta_applied()`, F-250). Before F-250, `CycleService._announce()` gated
## this whole emit behind a host-only guard, so a client's own subscribers never fired at all —
## `SteamStats`/`RichPresenceService` (task 8.3) worked around that by polling
## `CycleService.current_cycle()` instead; a new subscriber no longer needs to.
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
## Fires on EVERY peer, the instant `CycleModifierService` draws a Cycle Modifier from the deck
## (task 6.2, DESIGN.md §5.1 item 2) — the host emits directly from `_announce()`; a client
## re-derives the identical emit from `WorldDeltaLog`'s replicated records of that same draw landing
## locally (`CycleModifierService._on_world_delta_applied()`, F-254). Before F-254 this read "emitted
## by the HOST only": `_announce()` is reachable only through a host-gated `host_draw_modifier()`, so
## a client's own subscribers never fired at all — the same root cause F-250 fixed for
## `cycle_advanced` above, found by that task's own sweep and left live one task longer because a
## draw's `cycle` argument was not stored anywhere a client could read it back from.
##
## On the host it is fired from inside the same `cycle_advanced` handler that draws it, so a listener
## never sees a Cycle advance without also seeing that Cycle's draw (or its absence, if the deck had
## nothing eligible left). On a client the two are independent replicated records and may land in
## either order — a client-side listener that needs the pairing must read
## `CycleService.current_cycle()` rather than assume this fired second.
##
## A late joiner gets NO backlog of draws that predate its join (`net_world_snapshot` bypasses the
## signal that drives the client-side re-derivation, by design) — it reads the caught-up stack from
## `CycleModifierService.active_modifier_ids()` instead. Subscribe for "a modifier was JUST drawn",
## not to build up the stack.
##
## F-245 wired real gameplay consumers for all seven modifiers; they read
## `CycleModifierService.has_modifier()`/`drought_active()` on demand rather than subscribing here,
## so this remains the seam for a REACTION to a draw (a toast, a HUD banner) rather than for the
## effects themselves.
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


## Listener signature: (boss_id: StringName, world_position: Vector3) -> void
##
## Task 5.5's boss framework. Fires once per boss encounter, on EVERY peer, the instant `Boss.phase`
## first leaves its dormant value (-1) — the same moment the boss takes its first target. This is the
## "music stinger" hook: `BossMusicDirector` (client-local, task 5.5) is its one consumer today, and
## a future HUD flourish or camera nudge can subscribe here too.
##
## **Fires from `Boss.phase`'s own setter, never from a host-only guard.** `phase` is a REPLICATED
## property (same `SceneReplicationConfig`/ALWAYS shape `state`/`health`/`hit_counter` already use on
## `Enemy`) — the host sets it directly, a client's copy receives it over the wire and its own local
## setter runs identically, so both processes reach this emit from their own call site. This is the
## D-107/D-108 fix pattern (`docs/FINDINGS.md` F-168 was the standing example of getting it wrong,
## since fixed) applied from the start rather than retrofitted after a client-side bug report.
static func subscribe_boss_engaged(listener: Callable) -> void:
	_prune_invalid(_boss_engaged_subscribers)
	if listener.is_valid() and not _boss_engaged_subscribers.has(listener):
		_boss_engaged_subscribers.append(listener)


static func unsubscribe_boss_engaged(listener: Callable) -> void:
	_boss_engaged_subscribers.erase(listener)


static func emit_boss_engaged(boss_id: StringName, world_position: Vector3) -> void:
	_prune_invalid(_boss_engaged_subscribers)
	for listener: Callable in _boss_engaged_subscribers.duplicate():
		listener.call(boss_id, world_position)


static func boss_engaged_subscriber_count() -> int:
	_prune_invalid(_boss_engaged_subscribers)
	return _boss_engaged_subscribers.size()


## Listener signature: (boss_id: StringName, previous_phase: int, new_phase: int,
##      world_position: Vector3) -> void
##
## The `boss_engaged` counterpart for every phase transition AFTER the first (a health-threshold
## crossing into `BossPhaseDef` index `new_phase`, per `BossDef.phase_for_health_fraction()`).
## `previous_phase` is never -1 here — that transition is `boss_engaged` instead, so a stinger
## consumer never has to special-case "engaged" out of a phase-change list. Same replicated-setter
## guarantee as `boss_engaged` above: every peer's own `Boss.phase` setter fires this locally.
static func subscribe_boss_phase_changed(listener: Callable) -> void:
	_prune_invalid(_boss_phase_changed_subscribers)
	if listener.is_valid() and not _boss_phase_changed_subscribers.has(listener):
		_boss_phase_changed_subscribers.append(listener)


static func unsubscribe_boss_phase_changed(listener: Callable) -> void:
	_boss_phase_changed_subscribers.erase(listener)


static func emit_boss_phase_changed(
	boss_id: StringName, previous_phase: int, new_phase: int, world_position: Vector3
) -> void:
	_prune_invalid(_boss_phase_changed_subscribers)
	for listener: Callable in _boss_phase_changed_subscribers.duplicate():
		listener.call(boss_id, previous_phase, new_phase, world_position)


static func boss_phase_changed_subscriber_count() -> int:
	_prune_invalid(_boss_phase_changed_subscribers)
	return _boss_phase_changed_subscribers.size()


## Listener signature: (boss_id: StringName, world_position: Vector3) -> void
##
## Fires once per boss, on every peer, the instant its `state` first reaches `Enemy.State.DEAD`.
## Hung off `Boss._play_state_animation()` rather than `Enemy._enter_death()` on purpose: the death
## override lives on the HOST call path only (`host_apply_damage()` gates entry), the same host-only
## shape F-168 fixed for `Wellspring.capped`. `_play_state_animation()` is instead called
## from `state`'s own replicated setter — already proven, on every peer, by the fact that a client's
## copy of an ordinary `Enemy` already plays its death clip with no RPC of its own — so hanging the
## emit there gets every peer's own bus for free instead of needing a second fix later.
static func subscribe_boss_defeated(listener: Callable) -> void:
	_prune_invalid(_boss_defeated_subscribers)
	if listener.is_valid() and not _boss_defeated_subscribers.has(listener):
		_boss_defeated_subscribers.append(listener)


static func unsubscribe_boss_defeated(listener: Callable) -> void:
	_boss_defeated_subscribers.erase(listener)


static func emit_boss_defeated(boss_id: StringName, world_position: Vector3) -> void:
	_prune_invalid(_boss_defeated_subscribers)
	for listener: Callable in _boss_defeated_subscribers.duplicate():
		listener.call(boss_id, world_position)


static func boss_defeated_subscriber_count() -> int:
	_prune_invalid(_boss_defeated_subscribers)
	return _boss_defeated_subscribers.size()


## Listener signature: () -> void
##
## F-243: the seam every run-scoped system resets itself off — `CycleService.host_restart_run()`'s
## whole job. Same two-channel shape `cycle_advanced` already established (F-250): the host emits
## directly from `host_restart_run()`; a client re-derives the identical emit from the
## `run`/`generation` `WorldDeltaLog` record that same call writes, landing locally
## (`CycleService._on_world_delta_applied()`). Every subscriber below is expected to reset its OWN
## state and self-guard on whatever authority check it already uses (`_owns_mutation()`,
## `_owns_simulation()`, ...) — this signal does not imply "you are the host", only "a new run just
## began"; a client-only reset (a HUD's terminal overlay, for instance) needs no guard at all.
static func subscribe_run_restarted(listener: Callable) -> void:
	_prune_invalid(_run_restarted_subscribers)
	if listener.is_valid() and not _run_restarted_subscribers.has(listener):
		_run_restarted_subscribers.append(listener)


static func unsubscribe_run_restarted(listener: Callable) -> void:
	_run_restarted_subscribers.erase(listener)


static func emit_run_restarted() -> void:
	_prune_invalid(_run_restarted_subscribers)
	for listener: Callable in _run_restarted_subscribers.duplicate():
		listener.call()


static func run_restarted_subscriber_count() -> int:
	_prune_invalid(_run_restarted_subscribers)
	return _run_restarted_subscribers.size()


## Listener signature: () -> void
##
## F-286/D-175 — "a world composer just re-derived its contract nodes IN PLACE". Emitted at the END
## of `ProceduralWorld.rebuild_for_seed()`, once the new `PoiSites`/`SpawnMarker`/marker groups are
## published, so a handler that re-reads the tree sees the NEW island and never the torn-down one.
##
## `run_restarted` is NOT a substitute, on three counts. It fires on both maps, and the authored one
## tears nothing down (D-170 records what a blanket reaction to it costs there). Its dispatch order
## is against you: `ProceduralWorld` subscribes to it too, from `_ready()`, and every autoload
## subscribed earlier — so an autoload's handler runs while the ENDED island is still standing.
## And `rebuild_for_seed()` is public: a console reroll or a `--script` check driving it directly
## emits no `run_restarted` at all, which is the gap D-170 had to cover with a periodic sweep.
static func subscribe_world_rebuilt(listener: Callable) -> void:
	_prune_invalid(_world_rebuilt_subscribers)
	if listener.is_valid() and not _world_rebuilt_subscribers.has(listener):
		_world_rebuilt_subscribers.append(listener)


static func unsubscribe_world_rebuilt(listener: Callable) -> void:
	_world_rebuilt_subscribers.erase(listener)


## The counter is bumped BEFORE the dispatch, deliberately: a subscriber that reads a
## generation-keyed cache from inside its own handler must see the new value, not the one it is
## being told is stale.
static func emit_world_rebuilt() -> void:
	_world_generation += 1
	_prune_invalid(_world_rebuilt_subscribers)
	for listener: Callable in _world_rebuilt_subscribers.duplicate():
		listener.call()


static func world_rebuilt_subscriber_count() -> int:
	_prune_invalid(_world_rebuilt_subscribers)
	return _world_rebuilt_subscribers.size()


## How many times a world has been re-derived in place this process. For consumers that hold no
## state to reset, only something CACHED off the scene: fold this into the cache key and the entry
## dies with the island it was read from. O(1), needs no subscription to keep alive, and — unlike a
## handler — cannot be raced by a query that lands before this event reaches a given subscriber.
## `CraftingService._station_positions_for()` is the worked example (F-286).
static func world_generation() -> int:
	return _world_generation


## Listener signature: (tier: int, item_id: StringName) -> void
##
## Task 3.18's tool ladder (`docs/PROGRESSION.md` §4). Fires when the PARTY first crafts an item
## whose `ItemDef.tool_tier` is above the run's high-water mark — the "the iron age begins" moment,
## once per rung per run, never once per player. `item_id` is the item that did it, so a consumer
## can say *what* opened the tier rather than only its number.
##
## Fires on EVERY peer. `ProgressionService` raises the mark host-side and records it into
## `WorldDeltaLog`; a client re-derives the identical emit when that record lands
## (`ProgressionService._on_world_delta_applied()`). That is the same no-new-RPC shape D-099/D-100
## gave `cycle_advanced`, and it is deliberate: F-250 and F-254 are both the bug you get from
## emitting a party fact behind a host-only guard, and this event is a party fact.
##
## Consumers today: `GuideService`'s tier fanfare (3.19) and `SalvageService`'s "tiers reached"
## milestone, which `DESIGN.md` §4.6 has always listed and which had no fact to read until now.
static func subscribe_tier_reached(listener: Callable) -> void:
	_prune_invalid(_tier_reached_subscribers)
	if listener.is_valid() and not _tier_reached_subscribers.has(listener):
		_tier_reached_subscribers.append(listener)


static func unsubscribe_tier_reached(listener: Callable) -> void:
	_tier_reached_subscribers.erase(listener)


static func emit_tier_reached(tier: int, item_id: StringName) -> void:
	_prune_invalid(_tier_reached_subscribers)
	for listener: Callable in _tier_reached_subscribers.duplicate():
		listener.call(tier, item_id)


static func tier_reached_subscriber_count() -> int:
	_prune_invalid(_tier_reached_subscribers)
	return _tier_reached_subscribers.size()


## Listener signature:
##     (enemy_id: StringName, coin_min: int, coin_max: int, instigator_peer_id: int,
##      world_position: Vector3) -> void
##
## F-539's kill bounty. Fires from `Enemy._enter_death()`, which — unlike `Boss.phase`'s setter
## above — is reached ONLY through `host_apply_damage()`'s `_owns_simulation()` guard, so this event
## is HOST-ONLY by construction and is deliberately not a party fact a client re-derives. It exists
## to pay a killer, and paying flows through `InventoryService.host_add()`, which is host-authority
## anyway and already replicates its result; a client emitting this locally would have nothing to do
## with it. `RewardService` is its one consumer.
##
## `coin_min`/`coin_max` are the dead kind's authored `EnemyDef` bounty range, passed rather than
## looked up so a consumer never has to resolve the def of a body that is already a corpse. A range
## of 0..0 means this kind pays nothing and the event is still emitted, because "it died and was
## worth nothing" is a fact a future consumer (a kill counter, a stat) still wants.
static func subscribe_enemy_killed(listener: Callable) -> void:
	_prune_invalid(_enemy_killed_subscribers)
	if listener.is_valid() and not _enemy_killed_subscribers.has(listener):
		_enemy_killed_subscribers.append(listener)


static func unsubscribe_enemy_killed(listener: Callable) -> void:
	_enemy_killed_subscribers.erase(listener)


static func emit_enemy_killed(
	enemy_id: StringName,
	coin_min: int,
	coin_max: int,
	instigator_peer_id: int,
	world_position: Vector3,
) -> void:
	_prune_invalid(_enemy_killed_subscribers)
	for listener: Callable in _enemy_killed_subscribers.duplicate():
		listener.call(enemy_id, coin_min, coin_max, instigator_peer_id, world_position)


static func enemy_killed_subscriber_count() -> int:
	_prune_invalid(_enemy_killed_subscribers)
	return _enemy_killed_subscribers.size()


static func _prune_invalid(subscribers: Array[Callable]) -> void:
	for index: int in range(subscribers.size() - 1, -1, -1):
		if not subscribers[index].is_valid():
			subscribers.remove_at(index)
