"""Original procedural chapter-one audio. No external samples or dependencies.

Run without arguments to rebuild assets/audio; --check verifies reproducibility,
PCM headers, headroom and loop seams without changing files. Music uses a
periodic synthesis buffer so the last/first sample transition remains continuous.
This is a modest synthetic sound palette, not a recorded orchestral score.
"""
from __future__ import annotations

import argparse
from array import array
import hashlib
import math
from pathlib import Path
import random
import sys
import wave

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'assets' / 'audio'
TAU = math.tau


def pitch(note: float) -> float:
    return 440.0 * 2.0 ** ((note - 69.0) / 12.0)


def envelope(t: float, length: float, attack: float = .012, release: float = .08) -> float:
    if t < 0 or t >= length:
        return 0.0
    return min(1.0, t / attack) * min(1.0, (length - t) / release)


def sfx(kind: str, rate: int = 44100) -> tuple[int, int, array]:
    lengths = {
        'card_play': .24, 'damage': .28, 'shield': .48, 'heal': .72,
        'cast': .95, 'mark': .76, 'interrupt': .48, 'ot': .48,
        'win': 1.8, 'loss': 1.7, 'death': .68, 'dispel': .57,
    }
    duration = lengths[kind]
    rng = random.Random(int.from_bytes(hashlib.sha256(kind.encode()).digest()[:8], 'big'))
    signal = array('d')
    previous_noise = 0.0
    for index in range(round(duration * rate)):
        t = index / rate
        x = t / duration
        noise = rng.uniform(-1, 1)
        previous_noise = .72 * previous_noise + .28 * noise
        soft_noise = previous_noise
        if kind == 'card_play':
            value = (.7 * soft_noise + .25 * math.sin(TAU * (190 * t + 620 * t * t))) * math.sin(math.pi * x) ** 1.4
        elif kind == 'damage':
            value = (.50 * math.sin(TAU * (100 * t - 95 * t * t)) + .55 * soft_noise) * math.exp(-13 * t)
        elif kind == 'shield':
            value = sum(math.sin(TAU * f * t) * math.exp(-k * t) * amp for f, k, amp in ((310, 7, .45), (731, 11, .22), (1297, 17, .10)))
        elif kind in ('heal', 'dispel'):
            notes = (74, 77, 81) if kind == 'heal' else (81, 77, 86)
            value = 0.0
            for step, note in enumerate(notes):
                dt = t - step * .09
                if dt >= 0:
                    value += .26 * math.sin(TAU * pitch(note) * dt) * math.exp(-4.5 * dt) * envelope(dt, duration - step * .09, .012, .10)
        elif kind == 'cast':
            value = (.16 * math.sin(TAU * (130 * t + 110 * t * t)) + .10 * math.sin(TAU * (195 * t + 165 * t * t)) + .2 * soft_noise) * (.2 + .8 * x)
        elif kind == 'mark':
            pulse = math.sin(TAU * 4 * t) ** 6
            value = (.34 * math.sin(TAU * 392 * t) + .14 * math.sin(TAU * 415.3 * t)) * (.25 + .75 * pulse)
        elif kind == 'interrupt':
            value = (.3 * math.sin(TAU * (620 * t - 490 * t * t)) + .35 * soft_noise) * math.exp(-6 * t)
        elif kind == 'ot':
            value = (.34 * math.sin(TAU * 220 * t) + .20 * math.sin(TAU * 329.6 * t)) * (.25 + .75 * math.sin(TAU * 5 * t) ** 4)
        elif kind == 'death':
            value = (.34 * math.sin(TAU * (105 * t - 35 * t * t)) + .20 * soft_noise) * math.exp(-4 * t)
        else:
            notes = (50, 57, 62, 65, 69) if kind == 'win' else (50, 49, 45, 38)
            value = 0.0
            for step, note in enumerate(notes):
                dt = t - step * .18
                if dt >= 0:
                    voice = math.sin(TAU * pitch(note) * dt) + .22 * math.sin(TAU * pitch(note) * 2 * dt)
                    value += .17 * voice * math.exp(-2.1 * dt) * envelope(dt, duration - step * .18, .018, .18)
        signal.append(value * envelope(t, duration, .004, .07))
    return rate, 1, normalize(signal, .68)


def music(kind: str, rate: int = 22050) -> tuple[int, int, array]:
    duration = 24 if kind in ('menu', 'chapter') else 16
    count = duration * rate
    left = array('d', [0.0]) * count
    right = array('d', [0.0]) * count
    root_note = 38 if kind != 'boss' else 26
    # Rounded frequencies have an integer number of cycles in each music loop.
    drone_frequency = round(pitch(root_note) * duration) / duration
    for index in range(count):
        t = index / rate
        breathing = .78 + .22 * math.cos(TAU * t / duration)
        low = .11 * math.sin(TAU * drone_frequency * t) + .04 * math.sin(TAU * drone_frequency * 2 * t)
        haze_l = .025 * math.sin(TAU * (round(pitch(root_note + 19) * duration) / duration) * t)
        haze_r = .025 * math.sin(TAU * ((round(pitch(root_note + 19) * duration) + 1) / duration) * t)
        left[index] = (low + haze_l) * breathing
        right[index] = (low + haze_r) * breathing
    chords = ((50, 53, 57), (46, 50, 53), (43, 46, 50), (45, 49, 52))
    if kind == 'chapter':
        chords = ((38, 45, 53), (41, 48, 55), (43, 50, 58), (45, 52, 61))
    elif kind == 'boss':
        chords = ((38, 45, 50), (38, 44, 53), (34, 41, 50), (33, 40, 49))
    bar = duration / 4
    for chord_index, chord in enumerate(chords):
        for voice, note in enumerate(chord):
            add_voice(left, right, rate, chord_index * bar, bar + 2.0, note, .12, .7 + voice * .11, .6, 1.7)
    # Bell details, not a borrowed melody; each short phrase belongs to this script.
    detail_notes = (74, 69, 77, 72, 74, 65, 73, 69)
    for step, note in enumerate(detail_notes):
        add_voice(left, right, rate, step * duration / 8 + .45, 2.4, note, .035 if kind == 'menu' else .022, .2 + (step % 3) * .3, .012, 1.8)
    if kind == 'boss':
        for beat in range(32):
            start = beat * .5
            add_drum(left, right, rate, start, .44, .12 if beat % 4 == 0 else .055, beat)
    elif kind == 'chapter':
        for beat in range(8):
            add_drum(left, right, rate, beat * 3, .65, .035, beat)
    result = array('d')
    for a, b in zip(left, right):
        result.append(a)
        result.append(b)
    return rate, 2, normalize(result, .50)


def add_voice(left: array, right: array, rate: int, start: float, duration: float, note: int,
              amplitude: float, pan: float, attack: float, release: float) -> None:
    frequency = pitch(note)
    offset = round(start * rate)
    for index in range(round(duration * rate)):
        t = index / rate
        # Sine partials provide a soft bowed/glass-like synth, with no saw aliasing.
        value = (math.sin(TAU * frequency * t) + .16 * math.sin(TAU * frequency * 2 * t))
        value *= amplitude * envelope(t, duration, attack, release)
        at = (offset + index) % len(left)
        left[at] += value * math.sqrt(1 - pan)
        right[at] += value * math.sqrt(pan)


def add_drum(left: array, right: array, rate: int, start: float, duration: float,
             amplitude: float, seed: int) -> None:
    rng = random.Random(2900 + seed)
    offset = round(start * rate)
    smooth = 0.0
    for index in range(round(duration * rate)):
        t = index / rate
        smooth = .86 * smooth + .14 * rng.uniform(-1, 1)
        value = (math.sin(TAU * (78 * t - 35 * t * t)) + .7 * smooth)
        value *= amplitude * math.exp(-10 * t) * envelope(t, duration, .003, .12)
        at = (offset + index) % len(left)
        left[at] += value
        right[at] += value


def normalize(values: array, peak: float) -> array:
    maximum = max(abs(v) for v in values)
    scale = peak / maximum if maximum else 0.0
    return array('h', (round(v * scale * 32767) for v in values))


def pcm_bytes(samples: array) -> bytes:
    if sys.byteorder == 'little':
        return samples.tobytes()
    converted = array('h', samples)
    converted.byteswap()
    return converted.tobytes()


def write_asset(path: Path, rate: int, channels: int, samples: array, check: bool) -> None:
    raw = pcm_bytes(samples)
    if check:
        with wave.open(str(path), 'rb') as audio:
            assert audio.getparams()[:4] == (channels, 2, rate, len(samples) // channels), path
            assert audio.readframes(audio.getnframes()) == raw, f'{path}: changed PCM; regenerate or update its source'
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(path), 'wb') as audio:
            audio.setnchannels(channels)
            audio.setsampwidth(2)
            audio.setframerate(rate)
            audio.writeframes(raw)
    assert max(abs(v) for v in samples) < 28000, f'{path}: missing headroom'
    if channels == 2:
        # This is continuity at the seam, not a forced silent break in the music.
        for channel in range(channels):
            assert abs(samples[channel] - samples[-channels + channel]) < 2200, f'{path}: discontinuous loop'
    else:
        assert samples[0] == 0 and abs(samples[-1]) < 20, f'{path}: effect edge click'
    print(f'{path.relative_to(ROOT)}: {len(samples) / channels / rate:.2f}s, {rate}Hz, {channels}ch')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    for kind in ('card_play', 'damage', 'shield', 'heal', 'cast', 'mark', 'interrupt', 'ot', 'win', 'loss', 'death', 'dispel'):
        write_asset(OUTPUT / 'sfx' / f'{kind}.wav', *sfx(kind), args.check)
    for kind in ('menu', 'chapter', 'boss'):
        write_asset(OUTPUT / 'music' / f'{kind}.wav', *music(kind), args.check)
    print('15 original procedural audio assets verified.' if args.check else '15 original procedural audio assets generated.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
