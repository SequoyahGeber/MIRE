#!/usr/bin/env python3
"""Objective checks over rendered MIRE audio — the part of listening a
machine can do. Taste stays human; this proves the files are technically
clean before anyone spends ears on them.

    python3 tools/audio/audio_check.py [--build-dir DIR]

Checks every SFX wav in assets/audio/sfx/ and, if --build-dir is given (the
dir render_music.py wrote), the two music master WAVs plus their committed
OGGs (via ffprobe). Exits non-zero on any failure, prints PASS/FAIL per rule
like the tools/*_check.gd scripts do.

Candidate audio — the A/B/C option wavs from render_sfx_options.py and the
theme masters from render_theme.py — is checked the same way before anyone
spends ears on it, via --sfx-dir and --theme-dir. A candidate that clips or
sits at -45 dBFS is not a taste question, and finding that out during the
listening pass wastes the only scarce resource here.

Rules:
  all files : no clipped samples, |DC offset| < 0.002, peak <= -0.9 dBFS
  sfx       : mono, 0.03 s <= duration <= 6 s, peak short-term loudness in
              [-40, -11] dBFS, and no two files more than 30 dB apart in it
  music wav : stereo, 3:30 <= duration <= 4:00, -26 <= RMS <= -14 dBFS,
              loop seam continuity (|first - last| within the track's own
              99.9th-percentile sample-to-sample delta, x2 headroom)
  music ogg : exists, ffprobe duration within 0.5 s of the wav
  theme wav : stereo, 60 s <= duration <= 240 s, -26 <= RMS <= -14 dBFS,
              loop seam continuity (same rule as the ambient beds)
"""

from __future__ import annotations

import argparse
import glob
import math
import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mire_audio as ma  # noqa: E402

failures = 0


def check(cond: bool, msg: str) -> None:
    global failures
    if cond:
        print(f"PASS: {msg}")
    else:
        failures += 1
        print(f"FAIL: {msg}")


def peak_db(sig: np.ndarray) -> float:
    return 20.0 * math.log10(max(float(np.max(np.abs(sig))), 1e-9))


def common_checks(name: str, sig: np.ndarray) -> None:
    clipped = int(np.sum(np.abs(sig) >= 32766.0 / 32767.0))
    check(clipped == 0, f"{name}: no clipped samples ({clipped})")
    dc = float(np.max(np.abs(np.mean(sig, axis=-1))))
    check(dc < 0.002, f"{name}: DC offset {dc:.5f} < 0.002")
    check(peak_db(sig) <= -0.9, f"{name}: peak {peak_db(sig):.2f} dBFS <= -0.9")


def short_term_loudness_db(sig: np.ndarray, window_s: float = 0.1) -> float:
    """Peak short-term loudness — the loudest 100 ms, as RMS. The same measure
    `render_sfx.py` normalises to, reimplemented here rather than imported so
    this check would catch the renderer's own measure drifting.

    Full-file RMS is not usable as a gate on this catalogue: a sound that is one
    transient inside a long tail measures 20 dB below a continuous one at the
    same perceived level, so an RMS floor would fail every sparse asset while
    passing genuinely inaudible dense ones."""
    mono = sig[0] if sig.ndim == 2 else sig
    n = mono.shape[0]
    w = min(int(window_s * ma.SR), n)
    if w < 2:
        return 20.0 * math.log10(max(float(np.sqrt(np.mean(mono ** 2))), 1e-9))
    power = np.concatenate([[0.0], np.cumsum(mono ** 2)])
    frames = np.sqrt(np.maximum((power[w:] - power[:-w]) / w, 0.0))
    return 20.0 * math.log10(max(float(np.max(frames)), 1e-9))


def check_sfx(path: str) -> float:
    name = os.path.basename(path)
    sig, sr = ma.read_wav(path)
    dur = sig.shape[1] / sr
    check(sr == ma.SR, f"{name}: sample rate {sr} == {ma.SR}")
    check(sig.shape[0] == 1, f"{name}: mono ({sig.shape[0]} ch)")
    # 6 s, not 3: a tree coming down genuinely takes four seconds from the first
    # fibre giving way to the ground impact, and truncating it to fit a rule
    # would remove the landing, which is the half the sound exists for.
    check(0.03 <= dur <= 6.0, f"{name}: duration {dur:.2f}s in [0.03, 6.0]")
    loud = short_term_loudness_db(sig)
    # Floor at -40 rather than -36: a UI hover tick is 55 ms long, and a sound
    # shorter than the measurement window legitimately reads a few dB under a
    # longer one at the same peak. Moving the tick UP to satisfy the gate would
    # distort the mix to please the meter — a hover should be barely there.
    check(-40.0 <= loud <= -11.0,
          f"{name}: short-term loudness {loud:.1f} dBFS in [-40, -11]")
    common_checks(name, sig)
    return loud


def check_theme(path: str) -> None:
    """Theme candidates loop (render_theme.finish folds the tail onto the head),
    so they get the same seam rule as the ambient beds. Their length is free —
    a theme is as long as it needs to be."""
    name = os.path.basename(path)
    sig, sr = ma.read_wav(path)
    dur = sig.shape[1] / sr
    check(sr == ma.SR, f"{name}: sample rate {sr} == {ma.SR}")
    check(sig.shape[0] == 2, f"{name}: stereo ({sig.shape[0]} ch)")
    check(60.0 <= dur <= 240.0, f"{name}: duration {dur:.1f}s in [60, 240]")
    rms = ma.rms_db(sig)
    check(-26.0 <= rms <= -14.0, f"{name}: rms {rms:.1f} dBFS in [-26, -14]")
    common_checks(name, sig)
    seam = float(np.max(np.abs(sig[:, 0] - sig[:, -1])))
    typical = float(np.percentile(np.abs(np.diff(sig, axis=-1)), 99.9))
    check(seam <= max(typical * 2.0, 0.02),
          f"{name}: loop seam step {seam:.4f} <= 2x typical delta {typical:.4f}")


def check_music(wav_path: str, ogg_path: str) -> None:
    name = os.path.basename(wav_path)
    sig, sr = ma.read_wav(wav_path)
    dur = sig.shape[1] / sr
    check(sr == ma.SR, f"{name}: sample rate {sr} == {ma.SR}")
    check(sig.shape[0] == 2, f"{name}: stereo ({sig.shape[0]} ch)")
    check(210.0 <= dur <= 240.0, f"{name}: duration {dur:.1f}s in [210, 240]")
    rms = ma.rms_db(sig)
    check(-26.0 <= rms <= -14.0, f"{name}: rms {rms:.1f} dBFS in [-26, -14]")
    common_checks(name, sig)

    # loop seam: the wrap from last sample to first must look like any other
    # sample-to-sample step in the track
    seam = float(np.max(np.abs(sig[:, 0] - sig[:, -1])))
    typical = float(np.percentile(np.abs(np.diff(sig, axis=-1)), 99.9))
    check(seam <= max(typical * 2.0, 0.02),
          f"{name}: loop seam step {seam:.4f} <= 2x typical delta {typical:.4f}")

    check(os.path.exists(ogg_path), f"{os.path.basename(ogg_path)}: exists")
    if os.path.exists(ogg_path):
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", ogg_path],
            capture_output=True, text=True)
        ogg_dur = float(out.stdout.strip() or 0)
        check(abs(ogg_dur - dur) < 0.5,
              f"{os.path.basename(ogg_path)}: ogg duration {ogg_dur:.2f}s ~= wav {dur:.2f}s")


def main() -> None:
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", default=None,
                        help="dir holding the music master WAVs (from render_music.py)")
    parser.add_argument("--sfx-dir", default=None,
                        help="check this dir's wavs as SFX instead of assets/audio/sfx/ "
                             "(render_sfx_options.py's wav/ dir)")
    parser.add_argument("--theme-dir", default=None,
                        help="check this dir's wavs as theme candidates (render_theme.py)")
    args = parser.parse_args()

    sfx_root = args.sfx_dir or os.path.join(repo, "assets", "audio", "sfx")
    sfx_paths = sorted(glob.glob(os.path.join(sfx_root, "*.wav")))
    check(len(sfx_paths) > 0, f"found {len(sfx_paths)} sfx wavs")
    levels: dict[str, float] = {}
    for path in sfx_paths:
        levels[os.path.basename(path)] = check_sfx(path)

    # The mix, as one assertion. v1 shipped everything peak-normalised into a
    # 6 dB band, so a footstep was as loud as a falling tree; the failure mode
    # this guards is the opposite one, a catalogue that has drifted so far apart
    # that something is inaudible next to its neighbours.
    if levels:
        loudest = max(levels, key=levels.get)
        quietest = min(levels, key=levels.get)
        spread = levels[loudest] - levels[quietest]
        check(spread <= 30.0,
              f"mix spread {spread:.1f} dB <= 30 "
              f"({loudest} {levels[loudest]:.1f} .. {quietest} {levels[quietest]:.1f})")

    if args.theme_dir:
        theme_paths = sorted(glob.glob(os.path.join(args.theme_dir, "*.wav")))
        check(len(theme_paths) > 0, f"found {len(theme_paths)} theme wavs")
        for path in theme_paths:
            check_theme(path)

    if args.build_dir:
        for track in ("ambient_day", "ambient_night"):
            wav = os.path.join(args.build_dir, track + ".wav")
            ogg = os.path.join(repo, "assets", "audio", "music", track + ".ogg")
            if os.path.exists(wav):
                check_music(wav, ogg)
            else:
                check(False, f"{track}.wav present in --build-dir")

    print(f"\nAUDIO_CHECK failures={failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
