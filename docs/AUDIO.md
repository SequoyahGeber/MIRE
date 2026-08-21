# AUDIO.md — MIRE's sound, and how to extend it

MIRE's audio is **synthesized in-repo from committed recipes** (D-066). No sample packs, no
licensed tracks: `tools/audio/` renders every asset deterministically from numpy DSP code, so the
recipe/score is the source of truth and the committed `.ogg`/`.wav` files are reproducible build
products. Steam AI-disclosure note: these are code-generated assets — disclose accordingly at
store-page time.

## What exists (v1, tasks 7.1/7.2)

| Asset | File | What it is |
|---|---|---|
| Day ambient | `assets/audio/music/ambient_day.ogg` | 3:44 seamless loop, D Dorian over a D pedal. Pads voice-lead a slow soprano arc (E–E–F–G–C5–A–G–F→E); Karplus-Strong motif, rare FM bells. RMS −19 dBFS |
| Night ambient | `assets/audio/music/ambient_night.ogg` | 3:44 seamless loop, A Aeolian; section 5 is Bb-maj7 over the A pedal (the dread chord, bells strike its #11). Sub-root swells, three far FM groans. RMS −21 dBFS |
| Menu theme | `assets/audio/music/menu_theme.ogg` | "Hollowmere Hymn", 1:41 loop. Folk lament: bowed viol over a hammered-dulcimer ostinato, D Dorian. Plays while the front end is on screen (`ThemeMusicDirector`, cue `menu`) |
| Landfall theme | `assets/audio/music/theme_landfall.ogg` | "Wake the Deep", 1:57 loop. Heroic A-B-A: horns take the tune from the strings over choir and drums. One pass at run start, then an 8 s fade (cue `landfall`) |
| Cycle theme | `assets/audio/music/theme_cycle.ogg` | "Mire Rites", 1:11 loop. Percussive 6/8 building across four stages to a hard stop. One pass on `cycle_advanced` at Cycle 2+ (cue `cycle`) |
| Boss stinger | `assets/audio/music/boss_stinger.ogg` | ~7.2s non-looping one-shot (task 5.5), NIGHT's own palette — a low FM groan rises into a sub thump and a dissonant pair of detuned FM bells, then rings out on the same reverb IR shape. Played by `BossMusicDirector` (client-local autoload) on `EventBus.boss_engaged`/`boss_phase_changed`/`boss_defeated` |
| 19 SFX | `assets/audio/sfx/*.wav` | mono 16-bit 44.1 kHz: axe/pick hits (3 variants each), tree/stone breaks, melee whoosh+hit (2 each), mud footsteps (3), item pickup, chest open, ui click, build place |

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

**Themes.** Five candidates in five styles, all loop-folded (`wrap_loop`, same as the ambient beds)
because a menu is somewhere a player can sit. **Three of the five shipped** — Sequoyah picked
`hollowmere_hymn`, `wake_the_deep` and `mire_rites` on 2026-08-21; D-187 records which moment each
one was bound to and why the intuitive pairing was rejected:

| Candidate | Style | Carried by | Key | Status |
|---|---|---|---|---|
| `hollowmere_hymn` | folk lament | bowed viol over a hammered-dulcimer ostinato | D Dorian | **shipped** as `menu_theme.ogg` |
| `wake_the_deep` | heroic adventure | horns + strings + choir, A-B-A, full arrangement | D Dorian | **shipped** as `theme_landfall.ogg` |
| `mire_rites` | percussive 6/8 | frame drums, bone flute, chanted choir, four-stage build | D Dorian | **shipped** as `theme_cycle.ogg` |
| `the_long_sink` | dark cinematic | low horns, sub swells, the bII dread chord | A Aeolian | held — a natural act/boss bed |
| `still_water` | eerie minimal | music box through tape warble, no pulse | D Dorian | held — shares the hymn's melody |

They share the ambience's modal world and reuse its pad/pluck/bell voices, so any of them still
sounds like Hollowmere. `hollowmere_hymn` and `still_water` share a melody deliberately — the second
is the first heard through the wrong end of the mire — so picking one leaves the other usable as a
late-game or diegetic variant. Percussion in three of them does **not** break the no-percussion rule
above: that rule protects *ambience* from imposing a tempo on a procedurally-paced world, and a menu
has no world to pace.

```bash
python3 tools/audio/render_theme.py --ship menu_theme=hollowmere_hymn \
    theme_landfall=wake_the_deep theme_cycle=mire_rites
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

## Adding a sound

Add a recipe function in `tools/audio/render_sfx.py` composing `mire_audio` primitives
(`ks_pluck`, `fm_bell`, `burst_train`, `swept_bandpass`, `thump`, `click`…), register it in
`RECIPES` with variant count + reverb send + peak, re-render, run both checks. For repetitive
actions ship 3 seeded variants; play sites should round-robin them with ±4% `pitch_scale` scatter.

## Who plays what

Three client-local directors, all on the "Music" bus `SettingsService` (7.5) creates, so one slider
governs all of them:

| Autoload | Owns | Ducked by |
|---|---|---|
| `AmbientMusicDirector` (F-373) | the day/night bed, 8 s crossfade at dusk | a boss stinger (to 0.28) or any theme (to 0.10) |
| `ThemeMusicDirector` (D-187) | the three authored themes | nothing — a theme owns the mix |
| `BossMusicDirector` (5.5) | the boss stinger | nothing |

The bed's duck floor of 0.10 is deliberate rather than zero: `_apply_channel()` *stops* a channel
below `AUDIBLE_EPSILON`, and a stopped `AudioStreamPlayer` resumes at the head of a 3:44 loop — so a
cycle cue ending mid-run would silently rewind the ambience.

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
- **SFX v2 picks.** `render_sfx_options.py` has A/B/C rendered for all 11 families and none of them
  are chosen yet; `assets/audio/sfx/` still holds the v1 takes. One `--ship` per pick.
- **More music** (7.2's remainder): combat-intensity stems for escalation. `the_long_sink` is already
  rendered and is the obvious act/boss bed if that lands. Boss (5.5) is
  done — one shared stinger cue, not per-boss stems; a future task can add per-boss/per-phase cues
  through `BossDef.engage_music_cue`/`BossPhaseDef.music_cue`, which exist but route to the shared
  cue only (`BossMusicDirector.CUE_PATHS` has one entry today).
