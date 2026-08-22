class_name AnimalDef
extends Resource

## Static definition of one animal — docs/FAUNA.md §2/§3. Authored by hand as a `.tres` in
## `content/animals/`, loaded by `registry.gd` at boot and indexed by `id`, exactly as `EnemyDef`,
## `ItemDef` and `PowerupDef` are (ARCHITECTURE.md §3.1, "content is data, not code").
##
## NETWORK AUTHORITY: none directly. A definition is identical on every peer and is never sent —
## only its `id` crosses the wire. WHERE the animals are and how many is host-authoritative and
## lives in `autoload/fauna_service.gd` (ARCHITECTURE.md §2.2, "Enemy AI, spawns" row: fauna is
## spawned world content and follows the same authority).
##
## ## Why herds are a property of the DEF and not of the spawner
##
## §3: "A lone cow in a field reads as a bug; five reads as a place." Herd size differs per species
## and is a design fact about the animal — chickens 4–8, deer 2–4, a hare alone — so it belongs
## beside the animal rather than as a spawner constant that would have to grow a per-species table.

## §2's roster is ten designs; nothing here enforces which, because a species is content. What IS
## enforced is that a weight names a biome the world actually has — see `validation_errors()`.
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""

## Biome id -> relative weight. A biome absent from this map is a biome the species never spawns in,
## which is how "Fen Stilts on shore/marsh only" is expressed without a second exclusion list.
## Weights are relative within one species, not across species: the population target decides how
## many animals exist, this decides where THIS one goes.
@export var biome_weights: Dictionary[StringName, float] = {}

## §3's herd. Inclusive; `herd_min == herd_max == 1` is a solitary animal (the hare).
@export_range(1, 24, 1) var herd_min: int = 1
@export_range(1, 24, 1) var herd_max: int = 1
## How far from the herd's anchor point its members scatter. Small enough that a herd reads as one
## group rather than as several animals that happen to share a field.
@export_range(0.5, 30.0, 0.5) var herd_spread_m: float = 6.0

## §3: "Never in corrupted ground." Above this corruption value the species is removed from the
## spawn mask. Per-species rather than global because Phase 6 turns animals that stand in corruption
## Mire-touched, and a hardier species tolerating more before it flees is a design lever that wants
## to already exist when that lands.
@export_range(0.0, 1.0, 0.01) var max_corruption: float = 0.15

## Ground the species will stand on. A cow on a cliff face is the fauna version of the floating-prop
## bug the scatter field's grounding pass exists to prevent.
@export_range(0.0, 1.0, 0.01) var max_slope: float = 0.55
## Below this world height the position is water, not shore. Phase 1 keeps every species out of it;
## the wading birds of §2 will want their own band and that is a second field, not a special case.
@export var min_height_m: float = 0.6

## D-218, the art seam (wick1c650c, Phase 2). Agreed vocabulary, asserted here rather than only on
## the exporter side so a mismatched import fails a check instead of failing silently in play:
##
##   · kit `assets/fauna/`, one export per species at `exports/<id>.glb`
##   · ids are BARE — `chicken`, `cow`, `deer`, `hare`, `boar`, `songbird`, no prefix
##   · every species ships the same four runtime clips
##
## The loop trap is worth knowing before authoring any of them: Godot's glTF importer treats a
## `-loop` suffix on a clip name as an INSTRUCTION — it strips the suffix and sets loop mode. A clip
## exported without it arrives with loop mode off, so `idle` plays once and freezes, and the animal
## stops idling two seconds after it spawns, forever. `idle` and `walk` must loop; `flee` and `death`
## must not.
const CLIP_IDLE: StringName = &"idle"
const CLIP_WALK: StringName = &"walk"
const CLIP_FLEE: StringName = &"flee"
const CLIP_DEATH: StringName = &"death"
const RUNTIME_CLIPS: Array[StringName] = [CLIP_IDLE, CLIP_WALK, CLIP_FLEE, CLIP_DEATH]
## The two that must arrive with loop mode set, i.e. the two the exporter must name with `-loop`.
const LOOPING_CLIPS: Array[StringName] = [CLIP_IDLE, CLIP_WALK]
## Where Phase 2's exports land. `%s` is the bare species id.
const MODEL_PATH_TEMPLATE: String = "res://assets/fauna/exports/%s.glb"


## Placeholder presentation, used until Phase 2's art batch replaces it (§5: one placeholder species
## proves the system before any art exists). `body_size_m` is the capsule's height, `tint` its
## colour. Both are ignored the moment `model` is authored.
@export var body_size_m: float = 1.0
@export var tint: Color = Color(0.72, 0.63, 0.48)
@export var model: PackedScene


## Content errors, in the shape `LootTableDef.validation_errors()` uses so
## `tools/fauna_check.gd` can report them the same way the loot checks do. `known_biomes` is passed
## in rather than read from a Registry singleton, so this stays a pure function a check can call
## with a fixture.
func validation_errors(known_biomes: Array = []) -> PackedStringArray:
	var errors := PackedStringArray()
	if id == &"":
		errors.append("id is empty")
	if display_name.is_empty():
		errors.append("%s: display_name is empty" % id)
	if biome_weights.is_empty():
		errors.append("%s: no biome_weights — the species can never spawn anywhere" % id)
	if herd_min > herd_max:
		errors.append("%s: herd_min %d exceeds herd_max %d" % [id, herd_min, herd_max])
	for biome: StringName in biome_weights:
		if float(biome_weights[biome]) <= 0.0:
			errors.append("%s: biome '%s' has a non-positive weight" % [id, biome])
		# A weight naming a biome this world does not have is the silent-typo failure D-044 killed
		# `resonance_family` to prevent: `&"grassland"` and `&"Grassland"` are different keys and the
		# misspelt one simply never spawns anything.
		if not known_biomes.is_empty() and not known_biomes.has(biome):
			errors.append("%s: biome '%s' is not a biome this world defines" % [id, biome])
	return errors


## Inclusive herd size for one spawn, rolled from the caller's own generator — never `randi()`,
## which would perturb any seeded stream sharing it (AGENTS.md).
func roll_herd_size(rng: RandomNumberGenerator) -> int:
	return rng.randi_range(mini(herd_min, herd_max), maxi(herd_min, herd_max))
