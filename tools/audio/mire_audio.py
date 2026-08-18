"""MIRE audio synthesis toolkit — pure numpy, no scipy.

Every game sound is rendered from code by this module: the recipe/score IS the
asset (D-058). Renders are deterministic — every stochastic voice takes an
explicit numpy Generator, and the render scripts seed them with fixed values,
so re-running a render script reproduces the committed audio bit-for-bit.

Design notes that keep the output clean:
- Only sine-built oscillators (additive, FM) and Karplus-Strong — nothing here
  can alias, so there is no band-limiting machinery to get wrong.
- All filtering is FFT-domain with gentle Butterworth-shaped magnitudes
  (order <= 3). Zero-phase pre-ringing at these slopes is < 1 ms and inaudible
  on our material; in exchange filters are exact, stable, and vectorised.
- Reverb is convolution with a synthetic exponentially-decaying stereo IR —
  the best quality-per-line reverb available without external deps.
- Loopable tracks render length L plus the reverb tail, then the tail is
  added back onto the head (circular render), so the loop seam carries the
  same reverb energy as everywhere else.

Deps: numpy only (system python3). ffmpeg (brew) is used by render scripts to
encode OGG/MP3 — not imported here.
"""

from __future__ import annotations

import math
import struct
import wave

import numpy as np

SR = 44100


# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------

def db(gain_db: float) -> float:
    """dB -> linear amplitude."""
    return 10.0 ** (gain_db / 20.0)


def seconds(n_samples: int) -> float:
    return n_samples / SR


def samples(dur_s: float) -> int:
    return int(round(dur_s * SR))


def time_vector(n: int) -> np.ndarray:
    return np.arange(n, dtype=np.float64) / SR


_NOTE_OFFSETS = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def note_hz(name: str) -> float:
    """'A4' -> 440.0, 'Bb2' -> 116.54, 'F#3' -> 185.0."""
    letter = name[0].upper()
    rest = name[1:]
    accidental = 0
    if rest and rest[0] in "#b":
        accidental = 1 if rest[0] == "#" else -1
        rest = rest[1:]
    octave = int(rest)
    midi = 12 * (octave + 1) + _NOTE_OFFSETS[letter] + accidental
    return 440.0 * 2.0 ** ((midi - 69) / 12.0)


def cos_ramp(n: int, up: bool) -> np.ndarray:
    """Raised-cosine 0->1 (up) or 1->0 (down) over n samples."""
    if n <= 0:
        return np.zeros(0)
    x = np.linspace(0.0, math.pi, n)
    ramp = 0.5 - 0.5 * np.cos(x)
    return ramp if up else ramp[::-1].copy()


def env_asr(n: int, attack_s: float, release_s: float) -> np.ndarray:
    """Attack-sustain-release envelope with raised-cosine ramps, length n."""
    a = min(samples(attack_s), n)
    r = min(samples(release_s), max(n - a, 0))
    env = np.ones(n)
    if a > 0:
        env[:a] = cos_ramp(a, up=True)
    if r > 0:
        env[n - r:] = env[n - r:] * cos_ramp(r, up=False)
    return env


def exp_decay(n: int, tau_s: float) -> np.ndarray:
    return np.exp(-time_vector(n) / max(tau_s, 1e-4))


def fade_edges(sig: np.ndarray, fade_s: float = 0.004) -> np.ndarray:
    """Anti-click: raised-cosine fade on both ends, in place."""
    n = sig.shape[-1]
    f = min(samples(fade_s), n // 2)
    if f > 0:
        sig[..., :f] *= cos_ramp(f, up=True)
        sig[..., -f:] *= cos_ramp(f, up=False)
    return sig


def slow_noise(n: int, rate_hz: float, rng: np.random.Generator) -> np.ndarray:
    """Smooth random curve in [-1, 1]: control points at rate_hz, cosine-interpolated.
    The organic wobble behind pad drift, wind gusts, and creak irregularity."""
    n_points = max(int(seconds(n) * rate_hz) + 3, 4)
    points = rng.uniform(-1.0, 1.0, n_points)
    pos = np.linspace(0.0, n_points - 1.001, n)
    idx = pos.astype(np.int64)
    frac = pos - idx
    smooth = 0.5 - 0.5 * np.cos(np.pi * frac)
    return points[idx] * (1.0 - smooth) + points[idx + 1] * smooth


# ---------------------------------------------------------------------------
# noise + FFT-domain filtering
# ---------------------------------------------------------------------------

def white(n: int, rng: np.random.Generator) -> np.ndarray:
    return rng.uniform(-1.0, 1.0, n)


def pink(n: int, rng: np.random.Generator) -> np.ndarray:
    """1/f-shaped noise via spectral shaping."""
    spec = np.fft.rfft(white(n, rng))
    f = np.fft.rfftfreq(n, 1.0 / SR)
    f[0] = f[1] if n > 1 else 1.0
    spec *= 1.0 / np.sqrt(f)
    out = np.fft.irfft(spec, n)
    peak = np.max(np.abs(out))
    return out / peak if peak > 0 else out


def _butter_mag(f: np.ndarray, fc: float, order: int, kind: str) -> np.ndarray:
    fc = max(fc, 1.0)
    with np.errstate(divide="ignore"):
        if kind == "lp":
            ratio = f / fc
        else:  # hp
            ratio = np.where(f > 0, fc / np.maximum(f, 1e-9), np.inf)
    return 1.0 / np.sqrt(1.0 + ratio ** (2 * order))


def fft_filter(sig: np.ndarray, fc_low: float | None = None,
               fc_high: float | None = None, order: int = 2) -> np.ndarray:
    """Zero-phase filter. fc_low = highpass cutoff, fc_high = lowpass cutoff."""
    n = sig.shape[-1]
    spec = np.fft.rfft(sig)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    h = np.ones_like(f)
    if fc_low is not None:
        h *= _butter_mag(f, fc_low, order, "hp")
    if fc_high is not None:
        h *= _butter_mag(f, fc_high, order, "lp")
    return np.fft.irfft(spec * h, n)


def swept_bandpass(sig: np.ndarray, centers_hz: np.ndarray, octaves: float = 1.0,
                   order: int = 2, block: int = 2048) -> np.ndarray:
    """Time-varying bandpass via Hann overlap-add blocks. centers_hz is per-sample."""
    n = sig.shape[-1]
    hop = block // 4  # Hann^2 is COLA-constant at 75% overlap (sums to 1.5)
    window = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(block) / block)
    padded = np.concatenate([np.zeros(block), sig, np.zeros(2 * block)])
    out = np.zeros_like(padded)
    f = np.fft.rfftfreq(block, 1.0 / SR)
    half = 2.0 ** (octaves / 2.0)
    for start in range(0, n + 2 * block - hop, hop):
        centre_idx = min(max(start - block + block // 2, 0), n - 1)
        fc = float(centers_hz[centre_idx])
        chunk = padded[start:start + block]
        spec = np.fft.rfft(chunk * window)
        h = _butter_mag(f, fc / half, order, "hp") * _butter_mag(f, fc * half, order, "lp")
        out[start:start + block] += np.fft.irfft(spec * h, block) * window
    return out[block:block + n] / 1.5


# ---------------------------------------------------------------------------
# voices
# ---------------------------------------------------------------------------

def sine(freq_hz: float, dur_s: float, phase: float = 0.0) -> np.ndarray:
    t = time_vector(samples(dur_s))
    return np.sin(2 * np.pi * freq_hz * t + phase)


def sine_glide(f0: float, f1: float, dur_s: float, curve: float = 1.0) -> np.ndarray:
    """Sine with exponential-ish frequency glide f0 -> f1 (phase-continuous)."""
    n = samples(dur_s)
    shape = np.linspace(0.0, 1.0, n) ** curve
    freq = f0 * (f1 / f0) ** shape
    phase = 2 * np.pi * np.cumsum(freq) / SR
    return np.sin(phase)


DEFAULT_HARMONICS = ((1, 1.0), (2, 0.42), (3, 0.24), (4, 0.15),
                     (5, 0.09), (6, 0.06), (8, 0.035))


def additive_pad(freq_hz: float, dur_s: float, rng: np.random.Generator,
                 harmonics=DEFAULT_HARMONICS, detune_cents: float = 4.0,
                 shimmer: float = 0.35, darkness: float = 0.0) -> np.ndarray:
    """Warm organ-ish pad note: detuned harmonic pairs with slow independent
    amplitude drift. darkness 0..1 rolls off upper harmonics (night voicing)."""
    n = samples(dur_s)
    t = time_vector(n)
    out = np.zeros(n)
    for h, amp in harmonics:
        amp = amp * (1.0 - darkness) ** (h - 1) if darkness > 0 else amp
        if amp < 1e-4:
            continue
        for sign in (-1.0, 1.0):
            cents = sign * rng.uniform(0.3, detune_cents)
            f = freq_hz * h * 2.0 ** (cents / 1200.0)
            if f > SR * 0.45:
                continue
            drift = 1.0 + shimmer * 0.5 * (slow_noise(n, 0.13, rng) + 1.0)
            out += amp * 0.5 * drift * np.sin(2 * np.pi * f * t + rng.uniform(0, 2 * np.pi))
    peak = np.max(np.abs(out))
    return out / peak if peak > 0 else out


def ks_pluck(freq_hz: float, dur_s: float, rng: np.random.Generator,
             damp: float = 0.996, bright: float = 0.7) -> np.ndarray:
    """Karplus-Strong plucked string, vectorised one period at a time."""
    n = samples(dur_s)
    period = max(int(round(SR / freq_hz)), 2)
    buf = white(period, rng)
    # darken the excitation for softer picks
    soft = np.convolve(buf, [0.5, 0.5], mode="same")
    prev = bright * buf + (1.0 - bright) * soft
    out = np.empty(n)
    carry = prev[-1]
    pos = 0
    while pos < n:
        shifted = np.empty_like(prev)
        shifted[0] = carry
        shifted[1:] = prev[:-1]
        cur = damp * 0.5 * (prev + shifted)
        k = min(period, n - pos)
        out[pos:pos + k] = cur[:k]
        carry = prev[-1]
        prev = cur
        pos += k
    return fade_edges(out, 0.002)


def fm_bell(freq_hz: float, dur_s: float, rng: np.random.Generator,
            ratio: float = 2.756, index: float = 2.2) -> np.ndarray:
    """Inharmonic FM bell/glint. Decay time scales inversely with pitch."""
    n = samples(dur_s)
    t = time_vector(n)
    tau = min(max(300.0 / freq_hz, 0.4), 3.0)
    mod_env = np.exp(-t / (tau * 0.35))
    modulator = index * mod_env * np.sin(2 * np.pi * freq_hz * ratio * t + rng.uniform(0, 6.28))
    carrier = np.sin(2 * np.pi * freq_hz * t + modulator)
    return fade_edges(carrier * np.exp(-t / tau), 0.003)


def fm_groan(f0: float, f1: float, dur_s: float, rng: np.random.Generator,
             ratio: float = 1.93, index: float = 4.0) -> np.ndarray:
    """Low gliding FM growl — the distant thing in the dark. Band-limited by
    a post lowpass; swells in and out so it never startles, only unsettles."""
    n = samples(dur_s)
    t = time_vector(n)
    shape = np.linspace(0.0, 1.0, n)
    freq = f0 * (f1 / f0) ** shape
    phase = 2 * np.pi * np.cumsum(freq) / SR
    idx_env = index * (1.0 - 0.7 * shape)
    modulator = idx_env * np.sin(phase * ratio + rng.uniform(0, 6.28))
    raw = np.sin(phase + modulator)
    raw += 0.4 * np.sin(0.5 * phase + rng.uniform(0, 6.28))
    raw = fft_filter(raw, fc_low=30.0, fc_high=420.0, order=2)
    swell = np.sin(np.pi * np.clip(t / seconds(n), 0, 1)) ** 1.5
    wobble = 1.0 + 0.25 * slow_noise(n, 1.7, rng)
    return raw * swell * wobble


def burst_train(dur_s: float, rate_start_hz: float, rate_end_hz: float,
                rng: np.random.Generator, jitter: float = 0.25) -> np.ndarray:
    """Stick-slip impulse train with sweeping rate — the skeleton of creaks."""
    n = samples(dur_s)
    out = np.zeros(n)
    t = 0.0
    while t < dur_s:
        frac = t / dur_s
        rate = rate_start_hz * (rate_end_hz / rate_start_hz) ** frac
        i = samples(t)
        if i < n:
            out[i] = rng.uniform(0.6, 1.0) * (1.0 if rng.uniform() > 0.5 else -1.0)
        t += (1.0 / rate) * (1.0 + rng.uniform(-jitter, jitter))
    return out


# ---------------------------------------------------------------------------
# reverb
# ---------------------------------------------------------------------------

def make_ir(dur_s: float, rng: np.random.Generator, tau_s: float = 1.0,
            predelay_s: float = 0.02, hf_ratio: float = 0.35,
            stereo: bool = True) -> np.ndarray:
    """Synthetic IR: decorrelated exponentially-decaying noise, highs dying
    faster than lows (hf_ratio · tau), sparse early reflections, pre-delay."""
    n = samples(dur_s)
    t = time_vector(n)
    channels = 2 if stereo else 1
    ir = np.zeros((channels, n))
    for c in range(channels):
        lo = fft_filter(white(n, rng), fc_high=2200.0, order=1) * np.exp(-t / tau_s)
        hi = fft_filter(white(n, rng), fc_low=1800.0, order=1) * np.exp(-t / (tau_s * hf_ratio))
        tail = lo + 0.7 * hi
        for _ in range(6):  # early reflections
            at = samples(rng.uniform(0.008, 0.07))
            if at < n:
                tail[at] += rng.uniform(0.15, 0.4) * (1 if rng.uniform() > 0.5 else -1)
        ir[c] = tail
    pre = np.zeros((channels, samples(predelay_s)))
    ir = np.concatenate([pre, ir], axis=1)
    energy = np.sqrt(np.sum(ir ** 2, axis=1, keepdims=True))
    return ir / np.maximum(energy, 1e-9)


def convolve_fft(sig: np.ndarray, kernel: np.ndarray) -> np.ndarray:
    """Overlap-add FFT convolution of a 1-D signal with a 1-D kernel.
    Output length = len(sig) + len(kernel) - 1."""
    n, m = sig.shape[-1], kernel.shape[-1]
    out_len = n + m - 1
    block = 1 << max(int(math.ceil(math.log2(4 * m))), 14)
    step = block - m + 1
    k_spec = np.fft.rfft(kernel, block)
    out = np.zeros(out_len + block)
    for start in range(0, n, step):
        chunk = sig[start:start + step]
        spec = np.fft.rfft(chunk, block)
        out[start:start + block] += np.fft.irfft(spec * k_spec, block)
    return out[:out_len]


def reverb_stereo(bus: np.ndarray, ir: np.ndarray) -> np.ndarray:
    """Convolve a stereo bus (2, n) with a stereo IR (2, m) -> (2, n + m - 1)."""
    return np.stack([convolve_fft(bus[0], ir[0]), convolve_fft(bus[1], ir[1])])


# ---------------------------------------------------------------------------
# mixing / mastering / io
# ---------------------------------------------------------------------------

def pan_stereo(mono: np.ndarray, pan: float = 0.0) -> np.ndarray:
    """Equal-power pan, pan in [-1, 1]. Returns (2, n)."""
    angle = (pan + 1.0) * math.pi / 4.0
    return np.stack([mono * math.cos(angle), mono * math.sin(angle)])


class Mix:
    """A stereo timeline with a dry bus and a reverb-send bus.
    add() places a signal at a time with a dry gain and a send gain;
    render() convolves the send bus once and sums."""

    def __init__(self, dur_s: float, tail_s: float = 0.0):
        self.n = samples(dur_s)
        total = self.n + samples(tail_s)
        self.dry = np.zeros((2, total))
        self.send = np.zeros((2, total))

    def add(self, sig: np.ndarray, at_s: float, gain_db: float = 0.0,
            pan: float = 0.0, send_db: float = -100.0) -> None:
        stereo = pan_stereo(sig, pan) if sig.ndim == 1 else sig
        start = max(samples(at_s), 0)  # humanised starts may land slightly negative
        end = min(start + stereo.shape[1], self.dry.shape[1])
        if start >= end:
            return
        seg = stereo[:, : end - start]
        self.dry[:, start:end] += seg * db(gain_db)
        if send_db > -90:
            self.send[:, start:end] += seg * db(send_db)

    def render(self, ir: np.ndarray | None, wet_db: float = 0.0) -> np.ndarray:
        out = self.dry.copy()
        if ir is not None and np.any(self.send):
            wet = reverb_stereo(self.send, ir) * db(wet_db)
            keep = min(wet.shape[1], out.shape[1])
            out[:, :keep] += wet[:, :keep]
        return out


def wrap_loop(sig: np.ndarray, loop_len_s: float) -> np.ndarray:
    """Circular render: fold everything past the loop length back onto the
    head, so reverb/release tails cross the seam exactly like any other bar."""
    n = samples(loop_len_s)
    out = sig[:, :n].copy()
    tail = sig[:, n:]
    fold = min(tail.shape[1], n)
    out[:, :fold] += tail[:, :fold]
    return out


def master(sig: np.ndarray, peak_db: float = -1.2) -> np.ndarray:
    """DC strip, gentle soft-knee limit, normalise to peak_db."""
    sig = sig - np.mean(sig, axis=-1, keepdims=True)
    sig = np.tanh(sig / 0.9) * 0.9  # only bites on stray transients
    peak = np.max(np.abs(sig))
    if peak > 0:
        sig = sig * (db(peak_db) / peak)
    return sig


def rms_db(sig: np.ndarray) -> float:
    return 20.0 * math.log10(max(float(np.sqrt(np.mean(sig ** 2))), 1e-9))


def write_wav(path: str, sig: np.ndarray, rng: np.random.Generator | None = None) -> None:
    """16-bit PCM with TPDF dither. sig is (n,) mono or (2, n) stereo, in [-1, 1]."""
    if sig.ndim == 1:
        sig = sig[np.newaxis, :]
    channels, n = sig.shape
    dither = np.zeros((channels, n))
    if rng is not None:
        dither = (rng.uniform(-0.5, 0.5, (channels, n)) +
                  rng.uniform(-0.5, 0.5, (channels, n))) / 32767.0
    data = np.clip(sig + dither, -1.0, 1.0)
    pcm = (data * 32767.0).astype("<i2")
    interleaved = pcm.T.reshape(-1)
    with wave.open(path, "wb") as f:
        f.setnchannels(channels)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(interleaved.tobytes())


def read_wav(path: str) -> tuple[np.ndarray, int]:
    """Returns ((channels, n) float in [-1, 1], sample_rate)."""
    with wave.open(path, "rb") as f:
        channels = f.getnchannels()
        sr = f.getframerate()
        width = f.getsampwidth()
        raw = f.readframes(f.getnframes())
    if width != 2:
        raise ValueError(f"{path}: expected 16-bit wav, got {width * 8}-bit")
    pcm = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32767.0
    return pcm.reshape(-1, channels).T.copy(), sr
