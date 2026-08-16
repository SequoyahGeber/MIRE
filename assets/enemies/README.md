# MIRE prototype enemy set

Batch A-006 is the first rigged and animated asset family in the project: one Mire crawler with the
six clips a melee enemy needs, the nest it spawns from, and the two pieces it leaves when it dies.
Runtime GLBs are in `exports/`; the editable source is `../source/enemy_crawler.blend`. The source
directory is excluded from Godot import by `../source/.gdignore`.

## Included assets

| Asset | Family | Contents |
|---|---|---|
| `enemy_crawler` | enemy | Six-legged Mire crawler — skinned mesh, 17-bone rig, 6 animation clips |
| `enemy_crawler_nest` | spawner | Open, toothed nest with an emissive throat; the crawler's spawn point |
| `enemy_crawler_fragment_shell` | debris | Carapace shard for the death burst |
| `enemy_crawler_fragment_leg` | debris | Severed leg for the death burst |

`catalog.json` is the exact inventory and records dimensions, mesh-part counts, polygon counts, bone
counts, clip names, and embedded materials. `preview/enemies_preview.png` shows all four assets;
`preview/enemies_scale_preview.png` shows them beside a one-metre ruler with 20 cm ticks and a 20 cm
cube; `preview/crawler_pose_sheet.png` is the rig's contact sheet — eight key poses across all six
clips, each with the 20 cm cube for scale.

The crawler stands 0.59 m tall and 1.10 m long: dog-sized, low and wide. These are presentation
assets. They contain no collision, health, damage, AI, spawn rules, aggro, loot, or network
authority. Spawning, targeting, attack timing, hit registration and death remain host-authoritative.

## Animation clips

| Clip in the GLB | Clip in Godot | Length | Loops | Purpose |
|---|---|---:|---|---|
| `idle-loop` | `idle` | 2.0 s | yes | Breathing, slow head sway |
| `locomotion-loop` | `locomotion` | 0.8 s | yes | Tripod walk cycle |
| `attack_tell` | `attack_tell` | 0.4 s | no | Rear up, jaws open — the readable window |
| `attack` | `attack` | 0.4 s | no | Lunge and bite, then recover |
| `hit` | `hit` | 0.3 s | no | Flinch backward and drop |
| `death` | `death` | 1.0 s | no | Rear, collapse onto its side, settle |

**The names differ between the file and the engine, and gameplay must use the Godot column.** Godot 4
reads the `-loop` suffix as an instruction to set the clip looping and then strips it, so the GLB's
`idle-loop` arrives as `idle`. Asking the `AnimationPlayer` for `"idle-loop"` fails at runtime.

`attack_tell` and `attack` are deliberately separate clips that chain: the attack's first frame is
the tell's last frame, so playing them back to back has no pop, and combat code can hold, cancel or
re-time the tell without touching the strike. The 0.4 s tell length comes from `docs/DESIGN.md` §6.

`death` ends flat and still rather than mid-fall, so whatever takes over afterwards — a corpse mesh,
a ragdoll, the fragments — inherits a settled pose.

## The rig

17 bones: `root`, `body`, `abdomen`, `head`, `jaw`, and six legs of two bones each. Only `root` is
non-deforming; every other bone owns geometry.

**Skinning is rigid, one bone per part, not automatic weights.** Each mesh part is built separately,
has all of its vertices assigned to a single vertex group at weight 1.0, and only then is joined into
one mesh. Automatic weights would smear influence across flat-shaded chitin plates and bend parts
that should stay solid. It also makes the bind reproducible: the same script always produces the same
weights.

The rest pose has the feet on the ground with the origin at world zero, so the crawler drops into a
scene with no vertical offset. Note that the foot *joints* sit 3.3 mm above zero: a leg segment is a
tapered cone whose end cap is perpendicular to a tilted axis, so the cap's corner hangs below the
joint. The geometry touches the ground; the skeleton is what compensates.

Forward is -Y in Blender, which the exporter converts to -Z — the direction Godot treats as forward.

## Rebuild and verification

```bash
Blender --background --python tools/blender/build_enemy_crawler.py
```

Deterministic: two consecutive clean rebuilds produce byte-identical GLBs and catalog, and
pixel-identical previews. Requires Blender 5.2.

```bash
Godot --headless --path . --script tools/enemy_crawler_check.gd
```

Checks the half of the contract that only Godot can answer — that the imported crawler still carries
a 17-bone skeleton and a skinned mesh, that all six clips arrive under their engine-side names, that
exactly `idle` and `locomotion` loop, and that the other three assets import as plain static meshes.

Godot scene wiring, collision, and the enemy's actual behaviour remain Sequoyah's work in the editor.
