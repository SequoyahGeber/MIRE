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

---

# The Peatling (enemy ladder, tier 1)

Task 5.11, `docs/ENEMIES.md` §3. The second rigged family in `assets/enemies/`, built by its own
generator and sharing this directory's `catalog.json` with A-006 — each generator now REPLACES only
its own rows and leaves the other's alone, so either can be re-run without erasing the other.

| Asset | Family | Contents |
|---|---|---|
| `enemy_peatling` | enemy | Slime-mould blob — skinned mesh, 8-bone rig, the same 6 clips |
| `enemy_peatling_fragment_gel` | debris | A gobbet of gel with a dying vein in it |
| `enemy_peatling_fragment_husk` | debris | The dried film it leaves, and the pebble it never digested |

0.61 m wide, 0.87 m deep and **0.32 m tall**: knee height, low and wide, under the player's natural
aim line. 462 polygons.

The subject is *Physarum polycephalum*, the acellular slime mould, not a generic RPG slime — a
migrating plasmodium is fan-shaped at its leading edge with the mass trailing behind it, organises
into a network of vein-like tubules that are thick at the base and fine toward the margin, and moves
by **shuttle streaming**: cytoplasm surges one way for a few seconds, stops, and reverses. The fan is
the silhouette, the veins are the surface detail and the only emissive, and the reversal is why the
idle clip is deliberately asymmetric rather than a symmetric throb — a symmetric throb reads as
breathing, and this thing has no lungs.

**Scale is a keyed channel on this rig**, unlike A-006's. A crawler is plates on a skeleton and never
changes volume; a slime is a bag of fluid, and squash is its entire animation language. The tell is
therefore a *silhouette* change — it hauls itself up into a column, the tallest it ever gets — which
is the only readable telegraph available to something knee-high in fog.

Every clip is authored **shorter than or equal to** the `EnemyDef` window it plays under, so `Enemy`
never cuts one mid-motion. See `content/enemies/peatling.tres`.

```bash
Blender --background --python tools/blender/build_enemy_peatling.py
.agent/bin/agent godot --headless --script tools/enemy_peatling_check.gd
```

The check covers the import (rig, skin, all six clips under their engine-side names, exactly two
looping), **which way the model actually faces** — measured off the vertex arrays of every surface
and asserted against the `.tres`'s `model_yaw_offset_degrees`, so F-039's "the exporter turns
Blender's -Y forward into a model that faces backward" is a fact the suite knows rather than one
every author re-derives — and the corruption stain end to end, from a real kill through the real
damage seam to the Mire grid.


---

# The Fen Stalker (enemy ladder, tier 2)

Task 5.11, `docs/ENEMIES.md` §4. Third rigged family here, and the third generator sharing this
directory's `catalog.json` — each replaces only its own rows.

| Asset | Family | Contents |
|---|---|---|
| `enemy_fen_stalker` | enemy | Heron-like ambush predator — skinned mesh, 19-bone rig, the same 6 clips |
| `enemy_fen_stalker_fragment_plume` | debris | Torn flank feathers with one glowing quill |
| `enemy_fen_stalker_fragment_bill` | debris | The bill, snapped off with a piece of skull |

0.45 x 1.22 x **1.94 m** and 520 polygons. It looks down at a 1.8 m player, which is the point: tier
1 is knee-high, tier 2 is over your head.

Modelled on grey herons and bitterns. Three facts do all the work. The **legs are 53% of the height**
— that proportion is the silhouette. The **neck is a spring**: a real heron folds it into a
mid-cervical Z-bend and fires the head forward on it, so the tell coils and the attack releases, and
none of that timing had to be invented. And **bitterns freeze** — motionless, bill straight up, held
until the threat leaves — which is why `idle` here is the least animated clip in the game and why
`ambush_damage_multiplier` has something to hide behind.

Two traps this family paid for, both worth knowing before authoring the next one:

* **Clip length is LAST FRAME over fps, not the number of intervals.** A clip keyed 1..16 imports as
  0.533 s, not 0.5 s. Every `*_FRAMES` constant in both generators is therefore one less than the
  count it looks like, and both checks assert the imported length against the authored `.tres`
  instead of trusting the generator.
* **Extending a folded chain means turning every segment the SAME way.** The first pass alternated
  the extension the way the fold alternates, and the strike came back reading as "the bird looked
  up" — it kept its S, so it never got longer, which is the only thing a strike is for.

```bash
Blender --background --python tools/blender/build_enemy_fen_stalker.py
.agent/bin/agent godot --headless --script tools/enemy_fen_stalker_check.gd
```

The check covers the import, the yaw offset measured off the mesh (F-039), the ambush end to end
through the real state machine — first strike doubled, second not, a dodged strike still spends it,
losing the target re-arms it — and the stat band the tier's identity lives in.


---

# The Bog Bulwark (enemy ladder, tier 3)

Task 5.11, `docs/ENEMIES.md` §5. Fourth rigged family here.

| Asset | Family | Contents |
|---|---|---|
| `enemy_bog_bulwark` | enemy | Armoured shell-beast — skinned mesh, 20-bone rig, the same 6 clips |
| `enemy_bog_bulwark_fragment_scute` | debris | A keel plate cracked off with its spike still on it |
| `enemy_bog_bulwark_fragment_beak` | debris | The hooked beak, with the lure still faintly lit behind it |

1.96 x 3.03 x 1.18 m and 721 polygons — the largest thing in the roster and the first that is wider
than a doorway.

Modelled on the alligator snapping turtle. The **three keels** — one centre line, one either side,
each a row of pyramid elevations carrying a spike — are the silhouette; without them it is a boulder
with legs. The **hooked beak** shears against the lower jaw, so the strike is a snap that closes. The
**plastron is small and protects little**, which is a fact about the animal and also the entire
origin of `EnemyDef.armor_arc_degrees`. And it **fishes**: the one emissive on the body is a
`glowcap`-green lure inside the mouth, visible only when the jaws are open.

Its vertebrae are fused to its shell, so the rig has **no spine chain** and its `hit` clip is a
shudder rather than a recoil — there is nothing in the middle of it that bends. The eyes are
`critical` red, per the roster-wide directive.

```bash
Blender --background --python tools/blender/build_enemy_bog_bulwark.py
.agent/bin/agent godot --headless --script tools/enemy_bog_bulwark_check.gd
```

The check covers the import, the yaw offset measured off the mesh, and the armour from every side
that matters: reduced from dead ahead, unreduced from behind, correct on both sides of the arc
boundary, never reduced when there is no locatable instigator (armour must fail OPEN), and no
`hit_counter` bump on a deflect — which is the entire feedback channel for "you are hitting the wrong
end of this thing".

## A roster-wide note: the eyes are red

Sequoyah, on seeing the ladder: *"red eyes on the enemies please, i think its scarier."* Every
generator in this directory now points its eye material at `critical` (`#F17661` over a `#FF5030`
glow) instead of the palette's warm gold `eye` token — warm gold reads as alive and curious, and an
enemy has to read as hostile at a glance, in fog, at distance. The Peatling, which has no eyes at
all, was given two red points suspended in its gel for the same reason: an eyeless blob reads as
scenery.

The correct fix is to change the `eye` token itself in `mire_art.PALETTE`, which repoints every
enemy at once. That file was claimed by another agent for the whole of task 5.11, so these are
per-generator overrides until it is free.


---

# The Bloatcap (enemy ladder, tier 4)

Task 5.11, `docs/ENEMIES.md` §6. Fifth rigged family here.

| Asset | Family | Contents |
|---|---|---|
| `enemy_bloatcap` | enemy | Walking puffball — skinned mesh, 12-bone rig, the same 6 clips |
| `enemy_bloatcap_fragment_husk` | debris | Torn sac skin with the warts still on it |
| `enemy_bloatcap_fragment_gleba` | debris | A clot of spore mass, still lit, in a scrap of the ostiole |

1.38 m across and 1.22 m tall, 592 polygons. The ladder's first **pale** creature, and deliberately
the most visible thing in a night wave.

Modelled on *Lycoperdon*. Pear-shaped with a flattened top and a stem-like base; covered in short
cone-shaped spines and granular warts; and pierced at the top by an **ostiole** through which the
spores are ejected at about a metre per second, forming a cloud in a hundredth of a second. So the
tell is the sac FILLING and the attack is it EMPTYING — the strike is a deflation, not a swing. The
gleba inside is corrupted purple and visible through the dilating ostiole, which is how a player
reads how close it is to going off.

The `sac` bone carries almost the whole creature and acts almost entirely through **scale**; the
`ostiole` is its own bone specifically so it can dilate, and the check asserts that it still is one,
because if it stops being one the telegraph stops existing.

```bash
Blender --background --python tools/blender/build_enemy_bloatcap.py
.agent/bin/agent godot --headless --script tools/enemy_bloatcap_check.gd
```

The check covers the import; that the model really is radially symmetric (this is the one family
whose facing assertion is the *opposite* of the others' — it has no front, and `vision_angle_deg =
360` has to be an accurate description rather than a shortcut); and the burst from the outside in —
everyone inside the radius including a player who was never targeted, nobody outside it, height not
saving you, the death burst, and a kind with no burst authored still resolving exactly one
single-target hit.


---

# The Mire Herald (enemy ladder, tier 5)

Task 5.11, `docs/ENEMIES.md` §7. The sixth and last rigged family here, and the top of the ladder.

| Asset | Family | Contents |
|---|---|---|
| `enemy_mire_herald` | enemy | Bog-preserved giant deer — skinned mesh, 20-bone rig, the same 6 clips |
| `enemy_mire_herald_fragment_antler` | debris | A broken palm with two points and a crystal on it |
| `enemy_mire_herald_fragment_hide` | debris | Sodden hide and a length of rib |

**3.36 m across the antlers**, 3.10 m long, 2.73 m tall, 688 polygons. The largest thing in the game.

Modelled on *Megaloceros giganteus*, whose best-preserved remains come out of peat bogs. The antlers
are **palmate** — flattened palms with points along the outer edge, spanning up to 3.5 m and weighing
around 40 kg — and the hump over the shoulders is the elongated vertebrae that carry them: **the hump
is the anatomical reason the antlers are allowed to exist**, and a model without it wears its rack
like a hat.

Two things this family learned the hard way, both worth knowing:

* **Span is the read, and height is not span.** The first pass ran the palms up to z 2.62 and the
  rack came back looking tall rather than wide. Every centimetre spent going up is one not spent
  going sideways.
* **Sweep the palms FORWARD of the beam.** Swept back, the same geometry lies across the creature's
  own shoulders and reads as cargo; swept forward it frames the head like a pair of open hands,
  which is the iconic read and also the one that puts the points between the animal and whatever it
  is facing.

Its preview is shot nearly head-on, unlike every other family here, for the same reason.

```bash
Blender --background --python tools/blender/build_enemy_mire_herald.py
.agent/bin/agent godot --headless --script tools/enemy_mire_herald_check.gd
```

The check covers the import, the antler span and the yaw offset, and the aura over TIME rather than
at an instant: standing still corrupts the ground and keeps corrupting it, walking corrupts a trail
rather than a spot, a corpse stops, and a kind with no aura authored never touches the grid. It also
asserts that tier 1 still corrupts by dying — the two rungs share `MireGrid.host_add_corruption()`
deliberately, and if they ever stop sharing it the ladder has stopped being a ladder.
