#!/usr/bin/env python3
"""Objective checks over rendered MIRE audio — the part of listening a
machine can do. Taste stays human; this proves the files are technically
clean before anyone spends ears on them.

    python3 tools/audio/audio_check.py [--build-dir DIR]

Checks every SFX wav in assets/audio/sfx/ and, if --build-dir is given (the
dir render_music.py wrote), the two music master WAVs plus their committed
OGGs (via ffprobe). Exits non-zero on any failure, prints PASS/FAIL per rule
like the tools/*_check.gd scripts do.

Rules:
  all files : no clipped samples, |DC offset| < 0.002, peak <= -0.9 dBFS
  sfx       : mono, 0.03 s <= duration <= 3 s, RMS >= -40 dBFS
  music wav : stereo, 3:30 <= duration <= 4:00, -26 <= RMS <= -14 dBFS,
              loop seam continuity (|first - last| within the track's own
              99.9th-percentile sample-to-sample delta, x2 headroom)
  music ogg : exists, ffprobe duration within 0.5 s of the wav
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


def check_sfx(path: str) -> None:
    name = os.path.basename(path)
    sig, sr = ma.read_wav(path)
    dur = sig.shape[1] / sr
    check(sr == ma.SR, f"{name}: sample rate {sr} == {ma.SR}")
    check(sig.shape[0] == 1, f"{name}: mono ({sig.shape[0]} ch)")
    check(0.03 <= dur <= 3.0, f"{name}: duration {dur:.2f}s in [0.03, 3.0]")
    check(ma.rms_db(sig) >= -40.0, f"{name}: rms {ma.rms_db(sig):.1f} dBFS >= -40")
    common_checks(name, sig)


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
    args = parser.parse_args()

    sfx_paths = sorted(glob.glob(os.path.join(repo, "assets", "audio", "sfx", "*.wav")))
    check(len(sfx_paths) > 0, f"found {len(sfx_paths)} sfx wavs")
    for path in sfx_paths:
        check_sfx(path)

    if args.build_dir:
        for track in ("ambient_day", "ambient_night"):
            wav = os.path.join(args.build_dir, track + ".wav")
            ogg = os.path.join(repo, "assets", "audio", "music", track + ".ogg")
            if os.path.exists(wav):
                check_music(wav, ogg)
            else:
                check(False, f"{track}.wav present in --build-dir")

    print(f"\nAUDIO_CHECK failures={failures}")
    sys.exit(0 if failures else 1)


if __name__ == "__main__":
    main()
