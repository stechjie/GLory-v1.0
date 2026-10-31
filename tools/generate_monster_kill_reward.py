"""Rebuild original battle feedback accents using Python's standard library.

No sampled or third-party audio is used. Deterministic modal synthesis layers a
bright metallic coin strike, lighter coin contacts and a soft landing transient.
Run from any directory; the default output is the project's battle audio folder.
The mono PCM16 asset is intentionally short and inexpensive on mobile devices.
Use --kind kill_streak or --kind lane_clear for the two HUD accents. Omitting
--kind preserves the original monster kill asset byte for byte.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import struct
import wave


SAMPLE_RATE = 44_100
DURATION_SEC = 0.390
TARGET_PEAK_DBFS = -2.5


def synthesize() -> list[float]:
    rng = random.Random(20261030)
    count = round(SAMPLE_RATE * DURATION_SEC)
    samples = [0.0] * count

    # Inharmonic modes read as small metal objects rather than a musical chord.
    modes = ((1.0, 1.0, 1.0), (1.47, 0.32, 0.63), (2.09, 0.19, 0.43),
             (2.73, 0.09, 0.28), (3.41, 0.045, 0.19))

    def coin(start: float, frequency: float, gain: float, decay: float) -> None:
        first = round(start * SAMPLE_RATE)
        for index in range(first, count):
            t = (index - first) / SAMPLE_RATE
            attack = 1.0 - math.exp(-t / 0.00065)
            metal = sum(
                amplitude * math.sin(math.tau * frequency * ratio * t)
                * math.exp(-t / (decay * lifetime))
                for ratio, amplitude, lifetime in modes
            )
            samples[index] += gain * attack * metal

    coin(0.002, 1690.0, 0.88, 0.090)
    coin(0.037, 2218.0, 0.34, 0.080)
    coin(0.071, 2723.0, 0.13, 0.052)
    coin(0.106, 1981.0, 0.055, 0.039)

    # Brief high-passed taps add the tactile contact between coins, while a
    # low-passed, quiet landing avoids a brittle bell-only sound.
    for start, gain in ((0.001, 0.19), (0.033, 0.08), (0.069, 0.045)):
        first = round(start * SAMPLE_RATE)
        previous_noise = 0.0
        for index in range(first, min(count, first + round(0.018 * SAMPLE_RATE))):
            t = (index - first) / SAMPLE_RATE
            noise = rng.uniform(-1.0, 1.0)
            high_pass = (noise - previous_noise) * 0.5
            previous_noise = noise
            envelope = (1.0 - math.exp(-t / 0.0004)) * math.exp(-t / 0.0025)
            samples[index] += high_pass * envelope * gain

    low_noise = 0.0
    for index in range(round(0.082 * SAMPLE_RATE), count):
        t = index / SAMPLE_RATE - 0.082
        low_noise += 0.09 * (rng.uniform(-1.0, 1.0) - low_noise)
        envelope = (1.0 - math.exp(-t / 0.001)) * math.exp(-t / 0.014)
        samples[index] += (low_noise * 0.065 + math.sin(math.tau * 260.0 * t) * 0.024) * envelope

    # Remove DC and fade the tail to exact silence; keep the fast attack intact.
    dc = sum(samples) / count
    tail_start = round((DURATION_SEC - 0.045) * SAMPLE_RATE)
    for index, value in enumerate(samples):
        head_fade = min(1.0, index / (SAMPLE_RATE * 0.001))
        tail_p = max(0.0, (index - tail_start) / (count - 1 - tail_start))
        tail_fade = 0.5 + 0.5 * math.cos(math.pi * tail_p)
        samples[index] = (value - dc) * head_fade * tail_fade
    peak = max(abs(value) for value in samples)
    gain = 10.0 ** (TARGET_PEAK_DBFS / 20.0) / peak
    return [value * gain for value in samples]


def synthesize_hud_accent(kind: str) -> list[float]:
    """Damped metal for a streak; a warm resolved chime for a cleared lane."""
    duration = 0.310 if kind == "kill_streak" else 0.560
    count = round(SAMPLE_RATE * duration)
    samples = [0.0] * count
    notes = ((0.002, 1180.0, 0.86, 0.075), (0.047, 1572.0, 0.44, 0.080))
    if kind == "lane_clear":
        notes = ((0.003, 622.0, 0.66, 0.145), (0.022, 933.0, 0.39, 0.145),
                 (0.057, 1244.0, 0.31, 0.140), (0.084, 1866.0, 0.075, 0.085))
    for start, frequency, amplitude, decay in notes:
        first = round(start * SAMPLE_RATE)
        for index in range(first, count):
            t = (index - first) / SAMPLE_RATE
            attack = 1.0 - math.exp(-t / 0.0012)
            body = math.sin(math.tau * frequency * t) * math.exp(-t / decay)
            body += 0.17 * math.sin(math.tau * frequency * 2.18 * t) * math.exp(-t / (decay * 0.44))
            body += 0.05 * math.sin(math.tau * frequency * 3.47 * t) * math.exp(-t / (decay * 0.23))
            samples[index] += amplitude * attack * body
    # A quiet low transient supplies closure without any shattering/noise burst.
    if kind == "lane_clear":
        for index in range(count):
            t = index / SAMPLE_RATE
            samples[index] += 0.10 * math.sin(math.tau * 155.0 * t) * (1.0 - math.exp(-t / 0.002)) * math.exp(-t / 0.035)
    dc = sum(samples) / count
    tail_start = count - round(0.060 * SAMPLE_RATE)
    for index, value in enumerate(samples):
        fade_p = max(0.0, (index - tail_start) / (count - 1 - tail_start))
        envelope = min(1.0, index / (SAMPLE_RATE * 0.001)) * (0.5 + 0.5 * math.cos(math.pi * fade_p))
        samples[index] = (value - dc) * envelope
    gain = 10.0 ** (-3.0 / 20.0) / max(abs(value) for value in samples)
    return [value * gain for value in samples]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=("monster", "kill_streak", "lane_clear"), default="monster")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    filenames = {"monster": "monster_kill_reward.wav", "kill_streak": "kill_streak.wav", "lane_clear": "lane_clear_accent.wav"}
    if args.output is None:
        args.output = Path(__file__).resolve().parents[1] / "assets/audio/sfx/battle" / filenames[args.kind]
    samples = synthesize() if args.kind == "monster" else synthesize_hud_accent(args.kind)
    pcm = [round(value * 32767.0) for value in samples]
    if any(abs(value) >= 32767 for value in pcm):
        raise RuntimeError("Unexpected clipping; refusing to write the asset")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(args.output), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(struct.pack(f"<{len(pcm)}h", *pcm))

    peak = max(abs(value) for value in pcm) / 32768.0
    rms = math.sqrt(sum((value / 32768.0) ** 2 for value in pcm) / len(pcm))
    print(json.dumps({
        "output": str(args.output.resolve()),
        "duration_sec": len(pcm) / SAMPLE_RATE,
        "sample_rate": SAMPLE_RATE,
        "channels": 1,
        "bits": 16,
        "peak_dbfs": round(20.0 * math.log10(peak), 3),
        "rms_dbfs": round(20.0 * math.log10(rms), 3),
        "clipped_samples": sum(abs(value) >= 32767 for value in pcm),
        "tail_last_sample": pcm[-1],
        "sha256": hashlib.sha256(args.output.read_bytes()).hexdigest(),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
