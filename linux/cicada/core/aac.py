from __future__ import annotations

import os

SAMPLES_PER_FRAME = 1024
_RATES = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)


def partial(path: str) -> str:
    return os.path.splitext(path)[0] + ".aac"


def frames(data: bytes):
    i = 0
    n = len(data)
    while i + 7 <= n:
        if data[i] != 0xFF or (data[i + 1] & 0xF6) != 0xF0:
            return
        rate_index = (data[i + 2] >> 2) & 0x0F
        length = ((data[i + 3] & 0x03) << 11) | (data[i + 4] << 3) | (data[i + 5] >> 5)
        if length < 7 or i + length > n or rate_index >= len(_RATES):
            return
        yield i, length, _RATES[rate_index]
        i += length


def seconds(data: bytes) -> float:
    return sum(SAMPLES_PER_FRAME / rate for _o, _l, rate in frames(data))


def cut(data: bytes, until: float | None) -> bytes:
    end = 0
    t = 0.0
    for off, length, rate in frames(data):
        if until is not None and t >= until:
            break
        end = off + length
        t += SAMPLES_PER_FRAME / rate
    return data[:end]


def trim(path: str, until: float | None) -> None:
    with open(path, "rb") as f:
        data = f.read()
    kept = cut(data, until)
    if len(kept) != len(data):
        with open(path, "wb") as f:
            f.write(kept)
