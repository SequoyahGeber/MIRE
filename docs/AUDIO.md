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

## Adding a sound

Add a recipe function in `tools/audio/render_sfx.py` composing `mire_audio` primitives
(`ks_pluck`, `fm_bell`, `burst_train`, `swept_bandpass`, `thump`, `click`…), register it in
`RECIPES` with variant count + reverb send + peak, re-render, run both checks. For repetitive
actions ship 3 seeded variants; play sites should round-robin them with ±4% `pitch_scale` scatter.

## Network authority (ARCHITECTURE.md §2.2)

Audio is **client-local presentation**. Nothing here replicates: playback is triggered by gameplay
events that are already replicated (hits, breaks, pickups, day/night crossings). There are no
audio RPCs and must never be any.

## Not done yet (next tasks)

- **Ambient MusicDirector autoload** (client-local, still not built — do not confuse with task 5.5's
  `BossMusicDirector`, a separate one-shot-stinger autoload that ships): play `ambient_day.ogg`,
  crossfade ~8 s to `ambient_night.ogg` on DayNight's `night_started` / back on `day_started` (signal
  names proven in `tools/day_night_check.gd`). Two `AudioStreamPlayer`s on the "Music" bus
  `SettingsService` (7.5) already creates is enough.
- **SFX wiring**: `weapon_def.gd` / `harvestable_def.gd` sound fields + play sites — those files
  are under F-113/F-114 claims right now; wire after they clear. Bind sounds to the **asset defs**,
  never to a scene or map — release worlds are procgen.
- **Buses & mix pass** (7.1's remainder): Master / Music / SFX / UI buses, settings sliders — done,
  task 7.5.
- **More music** (7.2's remainder): menu theme, combat-intensity stems for escalation. Boss (5.5) is
  done — one shared stinger cue, not per-boss stems; a future task can add per-boss/per-phase cues
  through `BossDef.engage_music_cue`/`BossPhaseDef.music_cue`, which exist but route to the shared
  cue only (`BossMusicDirector.CUE_PATHS` has one entry today).
