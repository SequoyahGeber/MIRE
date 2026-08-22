# AUDIO.md — MIRE's sound, and how to extend it

MIRE's audio is **synthesized in-repo from committed recipes** (D-066). No sample packs, no
licensed tracks: `tools/audio/` renders every asset deterministically from numpy DSP code, so the
recipe/score is the source of truth and the committed `.ogg`/`.wav` files are reproducible build
products. Steam AI-disclosure note: these are code-generated assets — disclose accordingly at
store-page time.

## What exists

| Asset | File | What it is |
|---|---|---|
| Day ambient | `assets/audio/music/ambient_day.ogg` | 3:44 seamless loop, D Dorian over a D pedal. Pads voice-lead a slow soprano arc (E–E–F–G–C5–A–G–F→E); Karplus-Strong motif, rare FM bells. RMS −19 dBFS |
| Night ambient | `assets/audio/music/ambient_night.ogg` | 3:44 seamless loop, A Aeolian; section 5 is Bb-maj7 over the A pedal (the dread chord, bells strike its #11). Sub-root swells, three far FM groans. RMS −21 dBFS |
| Menu theme | `assets/audio/music/menu_theme.ogg` | "Hollowmere Hymn", 1:41 loop. Folk lament: bowed viol over a hammered-dulcimer ostinato, D Dorian. Plays while the front end is on screen (`ThemeMusicDirector`, cue `menu`) |
| Landfall theme | `assets/audio/music/theme_landfall.ogg` | "Wake the Deep", 1:57 loop. Heroic A-B-A: horns take the tune from the strings over choir and drums. One pass at run start, then an 8 s fade (cue `landfall`) |
| Cycle theme | `assets/audio/music/theme_cycle.ogg` | "Mire Rites", 1:11 loop. Percussive 6/8 building across four stages to a hard stop. One pass on `cycle_advanced` at Cycle 2+ (cue `cycle`) |
| Dawn theme | `assets/audio/music/theme_dawn.ogg` | "First Light", 2:12 loop. A two-tune jig set: double jig in 6/8 at session tempo, D Dorian into G Mixolydian and home again, whistle/fiddle/bodhrán/dulcimer. One pass on the night→day crossing after a night survived, then a 3 s fade (cue `dawn`) |
| Boss stinger | `assets/audio/music/boss_stinger.ogg` | ~7.2s non-looping one-shot (task 5.5), NIGHT's own palette — a low FM groan rises into a sub thump and a dissonant pair of detuned FM bells, then rings out on the same reverb IR shape. Played by `BossMusicDirector` (client-local autoload) on `EventBus.boss_engaged`/`boss_phase_changed`/`boss_defeated` |
| 131 SFX | `assets/audio/sfx/*.wav` | mono 16-bit 44.1 kHz, 266 files. Twelve systems: harvesting, movement, melee, ranged, creatures, the player, building, crafting, items and loot, UI, progression, ambient spot effects. `python3 tools/audio/render_sfx.py --list` prints the catalogue with a one-line intent per sound |

All of it is played by three client-local autoloads — `AmbientMusicDirector` (the day/night bed),
`ThemeMusicDirector` (the four authored themes, D-187/D-196), and `SfxDirector` (every sound effect) —
routed to the Master/Music/SFX buses `SettingsService` creates at runtime.

Palette rules that keep it one game: both tracks share the same pad/pluck/bell voices; reward
sounds (pickup, chest sparkle) are tuned in **D**, the day track's home, so loot always rings in
key with the world. Ambience has **no percussion** — it must not impose a tempo on a procedurally
paced world. SFX are **mono** because `AudioStreamPlayer3D` spatialises mono sources.

## Re-rendering

```bash
python3 tools/audio/render_sfx.py            # -> assets/audio/sfx/ + preview reel in build dir
python3 tools/audio/render_music.py          # -> assets/audio/music/*.ogg + master wav/mp3 in build dir
python3 tools/audio/audio_check.py --build-dir <build dir>   # objective pass: clipping/DC/RMS/loop seams
python3 tools/audio/repro_check.py           # F-176: proves re-renders are actually reproducible
.agent/bin/agent godot --script tools/audio_import_check.gd  # proves the assets load in-engine
```

(`agent godot` runs an import pass before every scripted run — F-093 — so no separate
`--import` step is needed after re-rendering.)

Deps: system `python3` + numpy, plus `python3 -m pip install --user soundfile` (OGG Vorbis — the
brew ffmpeg lacks libvorbis, and one giant soundfile write segfaults, hence the chunked writes in
`render_music.py`). ffmpeg is only needed for the MP3 listening copies.

**Reproducibility (F-176):** renders are seeded, and the PCM synthesis is bit-for-bit
deterministic — re-running `render_music.py` produces byte-identical master `.wav` files, proven
by `tools/audio/repro_check.py`. This held only after fixing `pad_note_spans()`, which iterated a
raw Python `set` of note names; `set` string order depends on the per-process hash seed
(`PYTHONHASHSEED`), and that order fed the sequence of draws from the shared seeded `rng`, so
every re-render's pad jitter/gain/pan silently differed despite the fixed seed. It now iterates
`sorted(wanted)`. The shipped `.ogg` files are a different claim: raw OGG bytes are **not**
byte-identical across encodes even from byte-identical PCM input, because libsndfile's OGG writer
stamps a random per-stream serial number into the container on every encode (an OGG-format
property, not a MIRE bug) — `repro_check.py` accounts for this by decoding both re-renders back to
PCM and comparing *that*, which does match exactly. Change a seed, get a sibling variation.

**Loudness contract:** music masters to RMS −19 (day) / −21 (night) dBFS, peaks ≤ −1.5. SFX are
peak-normalised per recipe (−2.5 to −8 dBFS) with headroom for the mixer. Keep new sounds inside
these envelopes; `audio_check.py` enforces the hard limits.

**Loops:** the tracks are rendered circularly (reverb/release tails fold onto the head), and
`loop=true` lives in the two committed `.ogg.import` sidecars — gitignore exceptions following the
`icon.svg.import` precedent, because a fresh clone would otherwise re-import with loop=false.

## The overhaul option sets (task 7.2, 2026-08-21)

Everything above is **v1**. `tools/audio/render_sfx_options.py` and `tools/audio/render_theme.py`
render the **candidates for a v2 pass** — options to pick from, not shipped assets. Nothing they
produce lands in `assets/` until an explicit `--ship`, and until then the v1 files stay in place.

```bash
python3 tools/audio/render_theme.py               # 5 theme candidates -> <build>/themes/
python3 tools/audio/render_sfx_options.py         # 11 families x 3 takes -> <build>/sfx_options/
python3 tools/audio/audio_check.py --theme-dir <build>/themes
python3 tools/audio/audio_check.py --sfx-dir <build>/sfx_options/wav
```

**Themes.** Six candidates, all loop-folded (`wrap_loop`, same as the ambient beds) because a menu is
somewhere a player can sit. **Four of the six shipped** — Sequoyah picked `hollowmere_hymn`,
`wake_the_deep` and `mire_rites` on 2026-08-21; D-187 records which moment each one was bound to and
why the intuitive pairing was rejected. `first_light_jig` came later the same day and was written
*to* a moment rather than picked for one — see D-196:

| Candidate | Style | Carried by | Key | Status |
|---|---|---|---|---|
| `hollowmere_hymn` | folk lament | bowed viol over a hammered-dulcimer ostinato | D Dorian | **shipped** as `menu_theme.ogg` |
| `wake_the_deep` | heroic adventure | horns + strings + choir, A-B-A, full arrangement | D Dorian | **shipped** as `theme_landfall.ogg` |
| `mire_rites` | percussive 6/8 | frame drums, bone flute, chanted choir, four-stage build | D Dorian | **shipped** as `theme_cycle.ogg` |
| `first_light_jig` | celebratory folk dance | bone whistle + fiddle over bodhrán and dulcimer, two-tune set | D Dorian → G Mixolydian | **shipped** as `theme_dawn.ogg` |
| `the_long_sink` | dark cinematic | low horns, sub swells, the bII dread chord | A Aeolian | held — a natural act/boss bed |
| `still_water` | eerie minimal | music box through tape warble, no pulse | D Dorian | held — shares the hymn's melody |

They share the ambience's modal world and reuse its pad/pluck/bell voices, so any of them still
sounds like Hollowmere. `hollowmere_hymn` and `still_water` share a melody deliberately — the second
is the first heard through the wrong end of the mire — so picking one leaves the other usable as a
late-game or diegetic variant. Percussion in three of them does **not** break the no-percussion rule
above: that rule protects *ambience* from imposing a tempo on a procedurally-paced world, and a menu
has no world to pace.

`first_light_jig` is the one that is not about the mire. It is written to the form rather than to a
guess at it — 6/8, eight-bar parts played AABB, the accent on quavers 1 and 4, and every group of
three lilted long-short-short (`jig_bars()`'s LILT table; a flat 6/8 is not a jig). Two minutes is
too long for one tune repeated, so it is a **set**, which is how the music is actually played: tune
one twice, change of tune, tune two twice, then the head of tune one to finish. The second tune is G
Mixolydian — the *same seven notes* as everything else MIRE is written in, tonic moved to G — so the
change lifts without leaving the game's modal world, and the drone follows it D→G→D. Every change of
intensity in it is a change of who is playing, never a fade or a filter: the sixteen bars at 0:32
are the fiddle taking the tune with the whistle out entirely, and the four bars at 2:04 are
everything dropping away before the band comes back for the button.

```bash
python3 tools/audio/render_theme.py --ship menu_theme=hollowmere_hymn \
    theme_landfall=wake_the_deep theme_cycle=mire_rites theme_dawn=first_light_jig
.agent/bin/agent godot --script tools/theme_music_check.gd    # proves they play, at their moments
```

A candidate is promoted under the **asset name of the role it won**, not under its working title, so
the mapping lives in `ThemeMusicDirector.CUE_PATHS` and not in a filename. Re-pointing a cue at a
different candidate is one `--ship` plus one line there. The two held candidates stay renderable from
the same seeds — nothing about them is lost by not shipping them.

**SFX takes.** Every family gets **A / B / C** — three different answers to "what is this made of and
how hard did you hit it", not three seeds of one recipe (that is what the per-sound *variants*
already are). Each take ships its family's full variant count, so a winner drops in with the
round-robin play sites unchanged. Audition via `<build>/sfx_options/<family>_options.mp3`; takes are
slated with **pips** — one before A, two before B, three before C — because a listener two minutes
into a reel otherwise has no way to know which take they are hearing.

```bash
python3 tools/audio/render_sfx_options.py --ship axe_hit_wood=B melee_hit=C ui_click=A ...
```

That copies the winners into `assets/audio/sfx/` under the canonical names and prints the take table
to paste back into this file. It is the only path here that writes into `assets/`, and therefore the
only one that takes the F-196 import-cache lock — the render paths deliberately skip it, because the
guard boots Godot for a full re-import on release and the renders touch nothing Godot imports.

**Why the takes sound different from v1 at all:** `mire_voices.modal_bank` — a bank of
exponentially-decaying partials, the physical model behind any struck object. Material lives almost
entirely in the partial *ratios* and their relative decay times; v1 approximated struck material with
fixed sine triples over pink-noise beds, which is why several v1 impacts read as "click plus noise"
rather than as wood, stone, or bone. `grain_scatter` does the same job for debris and rattles.

## `mire_voices.py` — the extended palette

`mire_audio.py` covers the ambient palette. A theme needs a voice that can *sing a line*, so
`tools/audio/mire_voices.py` adds, on the same numpy-only, explicit-`Generator` contract:

- **sustained**: `bowed` (viol/fiddle — MIRE's lead voice), `choir` (formant-filtered massed voices,
  vowels in `VOWELS`), `horn` (FM brass whose brightness tracks its own envelope), `flute` (breathy
  bone whistle), `glass_pad` (stretched-partial cold pad), `music_box`, `dulcimer` (multi-course
  Karplus-Strong — the detuned smear is the whole character).
- **percussion**: `membrane` (drumhead with real circular mode ratios), `log_drum`, `shaker`,
  `grain_scatter`.
- **impact**: `modal_bank`, `noise_impact`, `body_drop`, `transient`.
- **processing**: `tape_warble`, `echo`, `formant_filter`, `phase_of`/`vibrato_curve`.

`phase_of` matters more than it looks: vibrato and glide must be built by integrating a per-sample
frequency curve into phase. Modulating a fixed-phase sine's argument instead modulates *position*,
not pitch, and clicks on every zero crossing.

## SFX v2 — objects, not waveforms (2026-08-21)

The v1 SFX were layered by ear from a click, a sine drop and a noise bed, with every resonance and
decay time hand-picked. Sequoyah's verdict on hearing them was that most were "wildly inaccurate",
and the research says exactly why: **frequency-dependent decay rate, not spectral content, is the
dominant perceptual cue for material** (Klatzky, Pai & Krotkov, *Presence* 9(4), 2000). Choosing one
decay per partial is what destroys that cue, so every v1 impact read as an unnamed substance.

`tools/audio/mire_material.py` replaces that approach. A recipe now names a **material** and a
**geometry** and lets the physics do the rest:

- **Decay is derived, never authored.** A material is a loss factor η; every mode decays at
  `τ = 1/(π·f·η)`. High modes die faster than low ones at a rate set by the substance and nothing
  else, which is what makes wood sound like wood at any pitch or size. Anchored on published loss
  factors (steel ~1e-3, aluminium ~6e-3, gypsum ~3e-2, neoprene ~2e-1).
- **Mounting damping is added on top**, because published figures are for a specimen ringing freely
  and almost nothing in a game is: a trunk is rooted, a plank is nailed in, a blade is gripped.
  Without it a struck dry plank rings for 0.7 s — a xylophone bar on a stand, not a palisade.
- **Excitation is a contact time, not a click.** A collision force is a half-sine of duration `T_c`,
  so its spectrum rolls off above `1/(2·T_c)`. A padded mallet cannot make a bright sound however
  hard it is swung. `hardness` therefore changes *timbre*, not volume.
- **Mode ratios come from real geometry**: free-free bar `1 : 2.756 : 5.404` (the xylophone series),
  circular membrane `1 : 1.593 : 2.135`, stopped tube odd-harmonics; irregular solids get
  quasi-random incommensurate ratios, which is the honest model for a rock and is why one clacks
  rather than rings.
- **Water is the Minnaert bubble model** throughout: `f = 3.26/r`, and the pitch *rises* as the
  bubble collapses. That rising chirp is the entire signature of water, and a swamp game gets it
  wrong at its peril.

Measured separation, one struck object per material: iron 2.1 s, mire crystal 266 ms, dry wood
83 ms, granite 33 ms, bone 19 ms, mud 39 ms. v1 had no mechanism that could produce that spread.

Layering follows Tsugi's GameSynth foley breakdowns and what a foley stage actually does — a **body**
(mass moving), a **resonance** (the object's modes), a **texture** (crush, splinter, grit, water),
and a **mechanism** where a real one exists (a latch, a bowstring, a ratchet) — with layers offset a
few milliseconds so they do not mask each other into one thick click. Foley practice also decided
several materials outright: bone snaps are celery, so `hit_bone` is a bright bar mode over a fibrous
tear; wet flesh is a sodden chamois, so `hit_flesh` is a heavily damped membrane with no ring; dead
vegetation is unspooled cassette tape, so plant harvest is dense fine grains rather than noise.

### The mix is loudness, not peak

v1 peak-normalised everything into a −2.5..−8 dBFS band, which put a footstep within 6 dB of a
falling tree. Peak normalisation also rates three cricket chirps across two seconds as loud as a
gunshot while leaving them inaudible, because one sample says nothing about what the ear integrates.

The catalogue's level column is now **peak short-term loudness** — the loudest 100 ms, as RMS — with
a soft limiter before a −1.2 dBFS true-peak ceiling. (Recipes built on impulse trains have >25 dB
crest; without limiting, one spike costs the whole file 12 dB.) Bands:

| Band | What lives there |
|---|---|
| −13 .. −16 | once-per-event world sounds: a tree falling, a boss, a rare drop |
| −17 .. −21 | the player's own actions: chopping, hitting, building, looting |
| −22 .. −27 | things that fire every second or two: swings, steps, ambience |
| −28 .. −34 | things that fire constantly or sit behind everything: UI, insects |

`audio_check.py` gates the band and asserts the whole catalogue's spread stays under 30 dB.

## `SfxDirector` — the thing that plays them

Before it, `assets/audio/sfx/` was referenced by nothing outside a check: rendered, imported,
loudness-checked, documented, and silent. That is F-373's failure at 227× the scale, and it reports
no error.

**The wiring lives in one autoload and edits no gameplay code.** Nearly every event worth a sound is
already a signal on an autoload service that already carries a world position
(`CombatService.attack_landed`, `BuildService.piece_placed`, `PlayerHealth.player_downed`,
`EventBus.cycle_advanced`, …), so `SfxDirector` subscribes rather than asking each system to call it.
Three reasons, in order of importance: it makes ARCHITECTURE.md §2.2's "client-local presentation"
row structurally true instead of a convention; those signals are already replicated-event-driven, so
every peer hears the same sounds with **no audio RPC** (and there must never be one); and it does not
fight file claims on combat, building and the player controller.

Two things have no signal and are **driven** instead:

- **Footsteps.** Distance travelled while grounded, one step per `STEP_STRIDE_M`, surface chosen by a
  downward raycast (buildable/rock by group and name, otherwise water level → mud level → grass by
  height). Distance-based rather than timed, so sprinting and the movement powerups stay correct
  without knowing audio exists. Below the water line it plays `swim_stroke` instead.
- **Ambient life.** A cue every 5–16 s at 7–26 m around the player, from a day pool (birds, insects,
  leaves) or a night pool (frogs, something further off), the phase re-derived from the replicated
  `time_of_day` — *not* from `DayNight`'s signals, which are host-only, the same trap
  `AmbientMusicDirector` documents.

**Ambience is per biome** (task 7.1's own words). `BiomeMap.biome_at()` resolves the player's biome
every four seconds, and each of the seven biomes has its own day and night cast — gulls and lapping
water on the shore, frogs and gas and reeds in the marsh, a woodpecker in deep forest, crows and thin
edge-toned wind on the heath and highland, scree settling on high ground. Duplicated entries in a
pool are weights. `sfx_check.gd` asserts every biome has both pools and that no two are identical,
because a missing pool silently falls back to the generic one and looks like it works.

**Each of the six powerup families resonates in its own voice** rather than sharing one chime —
`resonance_changed` already carries the family, and throwing that away means a player who has been
stacking Cold all run cannot hear that it was Cold that landed. All six resolve into D and sit at the
same loudness, so none of them is the good one; only the material differs.

**Creatures make noise when they move**, driven the same way the player's footsteps are — distance
travelled, not a timer, so something closing on you sounds like it is closing on you. Arthropods get
a stutter of three or four chitin taps per step (more than two legs is the whole tell); a tusker gets
one heavy pad in wet ground. Range-limited hard, because a dozen creatures stepping across an island
is a wash that hides the one that matters.

`Enemy.state` is a replicated property with no signal, so the enemies group is **polled** five times
a second for the two transitions worth hearing — noticing the player, and winding up to strike — plus
an occasional idle vocal from whichever nearby creature is standing still. Same trade as the footstep
driver: the enemy script stays unaware that audio exists.

The **whole UI** is wired without a line in any UI file: `gui_focus_changed` is the hover and every
`BaseButton` reports its own press, both picked up through `SceneTree.node_added`.

Material selection is keyed on def **id** (`HARVEST_HIT_CUE`, `TARGET_MATERIAL_CUE`,
`WEAPON_SWING_CUE`), never on a scene or a level — release worlds are procedurally generated. Sound
fields on the defs themselves are the eventual right home; those tables are the seam until
`weapon_def`/`harvestable_def` grow them, and they are one file to move.

`autoload/sfx_catalogue.gd` is **generated** by `render_sfx.py`. Hand-maintaining it would let the
two halves drift silently — the game would ask for a variant that is not there, get null, and play
nothing. `tools/sfx_check.gd` asserts every catalogue file loads, that the catalogue and the
directory agree exactly in both directions, and that **every cue name in every mapping table exists**
— a typo there is a sound that never plays and that nothing else would notice.

## Adding a sound

1. Write a recipe in `tools/audio/render_sfx.py` composing `mire_material` voices — `struck()`,
   `strike_noise()`, `body()`, `splash()`, `bubble_cloud()`, `friction()`, `granular()`, `air_arc()`,
   `cloth()`, `crackle()` — plus `mire_voices` for anything with a pitch and `mire_audio` for the
   primitives underneath. Name a material and a geometry; do not hand-pick decay times.
2. Register it in `CATALOGUE` with variant count, reverb send, target loudness and system.
3. Re-render (this also regenerates `autoload/sfx_catalogue.gd`), then add a play site — usually one
   line in `SfxDirector._connect_events()` plus a handler.
4. Run the checks:

```bash
python3 tools/audio/audio_check.py                                  # loudness band + mix spread
.agent/bin/agent godot --script tools/sfx_check.gd                  # wiring, arity, coverage
.agent/bin/agent godot --script tools/sfx_runtime_probe.gd -- host  # what a live world actually plays
```

`sfx_check` drives handlers directly and proves the plumbing; the runtime probe boots the real world
and reads `SfxDirector.play_counts` to see what the game actually made a noise about. Both are
needed, because every interesting failure — a grounded test that is always false, a biome lookup that
throws, an enemy poll that never finds its group — passes the static check and produces silence.
(The probe currently cannot assert on footsteps: a headless boot never streams terrain collision, so
the player falls forever — F-429. It prints a NOTE rather than failing, and `sfx_check` covers the
stride logic against a synthetic body instead.)

For anything the player triggers repeatedly ship 3–4 seeded variants; `SfxDirector` round-robins them
with ±4% pitch scatter automatically.

## Who plays what

Three client-local directors, all on the "Music" bus `SettingsService` (7.5) creates, so one slider
governs all of them:

| Autoload | Owns | Ducked by |
|---|---|---|
| `AmbientMusicDirector` (F-373) | the day/night bed, 8 s crossfade at dusk | a boss stinger (to 0.28) or any theme (to 0.10) |
| `ThemeMusicDirector` (D-187, D-196) | the four authored themes | nothing — a theme owns the mix |
| `BossMusicDirector` (5.5) | the boss stinger | nothing |
| `SfxDirector` | all 113 sound effects, on the SFX bus | nothing |

The bed's duck floor of 0.10 is deliberate rather than zero: `_apply_channel()` *stops* a channel
below `AUDIBLE_EPSILON`, and a stopped `AudioStreamPlayer` resumes at the head of a 3:44 loop — so a
cycle cue ending mid-run would silently rewind the ambience.

**A hard boundary is a snap, never a fade** (F-430). At the two moments there is nothing to
cross-fade *from* — the first frame of the process, and a run restart — the theme takes its cue
straight to full gain and the bed comes up already ducked underneath it. Fading across a boundary
went wrong twice over: a cue at gain 0 is not quiet but *stopped*, so the theme made no sound at all
until the first `_process`, and the first frame of a real boot is the one that builds
`run/main_scene` — 347 ms headless, seconds with shaders. The bed (started from its own `_ready()`,
at full, because no theme was playing yet to duck it) scored that entire stall alone, and then the
frame's `delta` — the whole stall — crossed both fades in one `move_toward` step, so the intended
1.5 s cross-fade was heard as a cut. Sequoyah reported it as "the old theme song plays for 2-3
seconds before switching to the new one".

Two consequences worth keeping in mind before touching either director. `AmbientMusicDirector` must
not start its beds from `_ready()`: autoloads ready in `project.godot` order and `ThemeMusicDirector`
is registered below it, so at that instant "is a theme playing" is unanswerable. And the same is true
one dispatch at a time on `run_restarted`, which is why the bed defers its snap by a frame rather
than reading the duck inside the handler. `tools/theme_music_check.gd`'s "a hard boundary is a snap"
section replays the restart boundary and asserts both halves.

**One cue is not `SfxDirector`'s** (F-581). `item_pickup` and `powerup_pickup` are played by
`ui/hud/pickup_hud.gd` off `PickupFeedService.pickup_received`, because the grant happens on the HOST
and the sound belongs to whoever *received* it — a signal `SfxDirector` cannot hear from the machine
it is running on. `SfxDirector` had an `item_pickup` line all along, hung off inventory *operation*
confirmations, so moving a stack around your pack made the pickup sound and actually picking
something up made none. The director still owns `chest_open` and `loot_rare` at the chest itself,
which are world sounds everyone nearby hears; the reel adds its own per-face `ui_hover` tick and a
`ui_confirm` clunk when it lands, through `play_at()`.

## Network authority (ARCHITECTURE.md §2.2)

Audio is **client-local presentation**. Nothing here replicates: playback is triggered by gameplay
events that are already replicated (hits, breaks, pickups, day/night crossings). There are no
audio RPCs and must never be any.

## Not done yet (next tasks)

- **SFX wiring**: `weapon_def.gd` / `harvestable_def.gd` sound fields + play sites — those files
  are under F-113/F-114 claims right now; wire after they clear. Bind sounds to the **asset defs**,
  never to a scene or map — release worlds are procgen.
- **Buses & mix pass** (7.1's remainder): Master / Music / SFX / UI buses, settings sliders — done,
  task 7.5.
- **The `menu` cue has no moment yet.** `project.godot`'s `run/main_scene` still boots straight into
  the world while task 4.19's cutover is in flight, so nothing puts the `mire_frontend` group on
  screen in the shipped path. `ThemeMusicDirector` already handles it — when 4.19 flips the boot
  scene the menu theme starts working with no change here.
- **128 of 131 cues are triggered.** The three that are not — `equip_blade`, `equip_tool`,
  `equip_bow` — are waiting on a system that does not exist: the game has no equip/hotbar concept at
  all, so there is nothing to hang them on. `tools/sfx_check.gd` prints the coverage every run and
  fails if the unwired list grows past twelve, which is what stops it drifting quietly.
- **`assets/audio/sfx/` is ~49 MB** of uncompressed PCM. That is right at runtime — short SFX should
  not pay a decode cost — but every re-render writes 227 new blobs into git history. Worth a look
  before the catalogue is tuned many more times.
- **More music** (7.2's remainder): combat-intensity stems for escalation. `the_long_sink` is already
  rendered and is the obvious act/boss bed if that lands. Boss (5.5) is
  done — one shared stinger cue, not per-boss stems; a future task can add per-boss/per-phase cues
  through `BossDef.engage_music_cue`/`BossPhaseDef.music_cue`, which exist but route to the shared
  cue only (`BossMusicDirector.CUE_PATHS` has one entry today).
