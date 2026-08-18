class_name HaulableDef
extends Resource

## Static definition of one heavy-hauling object — docs/SPECS.md 3.10, DESIGN.md §4.5 "heavy
## hauling" / §5's solo rule. Authored by hand as a .tres in content/haulables/, same pattern as
## BuildableDef (ARCHITECTURE.md §3.1, "content is data, not code").
##
## NETWORK AUTHORITY: none directly. A definition is identical on every peer and never goes over the
## wire — only its `id` does, exactly like BuildableDef. Which haulable OBJECTS exist and who is
## carrying one is host-authoritative and lives in autoload/haul_service.gd and
## systems/hauling/haulable.gd (docs/ARCHITECTURE.md §2.2, "Carryable objects" row).

## Unique key. Must match across all peers — it is what goes over the network, never the resource
## path.
@export var id: StringName = &""
@export var display_name: String = ""

## The thing that actually gets spawned. Its root is expected to carry its own collision, same as
## BuildableDef.scene. Null falls back to a generated placeholder box sized from `size` below — see
## HaulService._generated_body() — so the framework works before any art exists (D-039 doctrine:
## build what the task needs, don't wait on an artist for the mechanic to be provable).
@export var scene: PackedScene

@export_group("Footprint")
## Full extents in metres, used only by the generated placeholder (art-less worked examples) and by
## nothing else — a real authored scene brings its own collider, same split BuildableDef makes.
@export var size: Vector3 = Vector3(1.0, 1.0, 1.5)

@export_group("Carry")
## How close a player must stand to request_pickup(), in metres.
@export_range(0.5, 10.0, 0.1, "or_greater") var pickup_range_m: float = 2.5
## Metres/second the OBJECT tracks the carriers' midpoint at when carried by two — "full speed" in
## docs/SPECS.md 3.10. This is a cap on the OBJECT's own motion, not the carriers' walk speed; it is
## what keeps a lying client's replicated position from teleporting the object (HaulMath.step(),
## proved by tools/haul_net_check.gd).
@export_range(0.1, 15.0, 0.1) var carry_track_speed_mps: float = 4.0
## DESIGN.md §5: "heavy hauling becomes a slow drag" solo. Fraction of carry_track_speed_mps a lone
## carrier drags the object at. ~0.4 is the design's own number.
@export_range(0.05, 1.0, 0.05) var solo_drag_multiplier: float = 0.4


## Same shape as BuildableDef's — registry.gd calls this before indexing and skips anything that
## fails, so a malformed .tres is a named boot error rather than a crash at pickup.
func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = []
	if id == &"":
		errors.append("id is empty")
	if display_name.is_empty():
		errors.append("display_name is empty")
	if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		errors.append("size must be positive on every axis (got %s)" % size)
	if pickup_range_m <= 0.0:
		errors.append("pickup_range_m must be positive")
	if carry_track_speed_mps <= 0.0:
		errors.append("carry_track_speed_mps must be positive")
	if solo_drag_multiplier <= 0.0 or solo_drag_multiplier > 1.0:
		errors.append("solo_drag_multiplier must be in (0, 1]")
	return errors
