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
.agent/bin/agent godot --script tools/audio_import_check.gd  # proves the assets load in-engine
```

(`agent godot` runs an import pass before every scripted run — F-093 — so no separate
`--import` step is needed after re-rendering.)

Deps: system `python3` + numpy, plus `python3 -m pip install --user soundfile` (OGG Vorbis — the
brew ffmpeg lacks libvorbis, and one giant soundfile write segfaults, hence the chunked writes in
`render_music.py`). ffmpeg is only needed for the MP3 listening copies. Renders are seeded:
re-running reproduces the committed files bit-for-bit; change a seed, get a sibling variation.

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

- **MusicDirector autoload** (client-local): play `ambient_day.ogg`, crossfade ~8 s to
  `ambient_night.ogg` on DayNight's `night_started` / back on `day_started` (signal names proven in
  `tools/day_night_check.gd`). Two `AudioStreamPlayer`s on a `Music` bus is enough.
- **SFX wiring**: `weapon_def.gd` / `harvestable_def.gd` sound fields + play sites — those files
  are under F-113/F-114 claims right now; wire after they clear. Bind sounds to the **asset defs**,
  never to a scene or map — release worlds are procgen.
- **Buses & mix pass** (7.1's remainder): Master / Music / SFX / UI buses, settings sliders (7.5).
- **More music** (7.2's remainder): menu theme, combat-intensity stems for escalation, boss (5.5).
