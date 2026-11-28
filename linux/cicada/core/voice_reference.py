from __future__ import annotations

import base64
import math
import os
import shutil
from array import array

from .audio import RATE, Wav
from .support import Paths

MIN_SECONDS = 10.0
MAX_SECONDS = 15.0

SLOW_CHARACTERS = 2.5
SLOW_WORDS = 1.6

CLONE = "clone"


def folder() -> str:
    return os.path.join(Paths.config(), "voice")


def audio_path() -> str:
    return os.path.join(folder(), "reference.wav")


def text_path() -> str:
    return os.path.join(folder(), "reference.txt")


def text() -> str | None:
    try:
        with open(text_path(), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def exists() -> bool:
    return os.path.isfile(audio_path()) and bool((text() or "").strip())


def duration() -> float:
    try:
        return len(Wav.read_file(audio_path())) / RATE
    except (OSError, ValueError):
        return 0.0


def reference() -> tuple[str, str] | None:
    t = (text() or "").strip()
    if not t:
        return None
    try:
        with open(audio_path(), "rb") as f:
            data = f.read()
    except OSError:
        return None
    return "data:audio/wav;base64," + base64.b64encode(data).decode(), t


def _private(path: str, mode: int, data: bytes) -> None:
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def save(samples: array, transcript: str) -> None:
    os.makedirs(folder(), mode=0o700, exist_ok=True)
    os.chmod(folder(), 0o700)
    _private(audio_path(), 0o600, Wav.bytes(trim(samples)))
    _private(text_path(), 0o600, transcript.strip().encode("utf-8"))
    global _saved_pace
    _saved_pace = None


def remove() -> None:
    global _saved_pace
    _saved_pace = None
    shutil.rmtree(folder(), ignore_errors=True)


def is_cjk(ch: str) -> bool:
    o = ord(ch)
    return 0x3040 <= o <= 0x30FF or 0x3400 <= o <= 0x4DBF or 0x4E00 <= o <= 0x9FFF or 0xAC00 <= o <= 0xD7AF or 0xF900 <= o <= 0xFAFF


def tokens(s: str) -> list:
    out, word = [], ""
    for ch in s:
        if is_cjk(ch):
            if word:
                out.append(word.lower())
                word = ""
            out.append(ch)
        elif ch.isalnum() or ch in "'’":
            word += "'" if ch == "’" else ch
        elif word:
            out.append(word.lower())
            word = ""
    if word:
        out.append(word.lower())
    return out


def _speech_windows(samples, rate: int = RATE):
    size = max(1, int(rate * 0.02))
    levels = []
    for i in range(0, len(samples), size):
        part = samples[i:i + size]
        levels.append(math.sqrt(sum((x / 32768.0) ** 2 for x in part) / len(part)))
    if not levels or max(levels) <= 0.003:
        return None
    floor = max(levels) * 0.0178
    loud = [i for i, l in enumerate(levels) if l >= floor]
    return loud[0], loud[-1], size


def speech_span(samples, rate: int = RATE) -> float | None:
    w = _speech_windows(samples, rate)
    return None if w is None else (w[1] - w[0] + 1) * w[2] / rate


TRIM_PAD = 0.2


def trim(samples, rate: int = RATE):
    w = _speech_windows(samples, rate)
    if w is None:
        return samples
    pad = int(TRIM_PAD * rate)
    return samples[max(0, w[0] * w[2] - pad):min(len(samples), (w[1] + 1) * w[2] + pad)]


def pace(transcript: str, samples, rate: int = RATE) -> float | None:
    units = len(tokens(transcript))
    span = speech_span(samples, rate)
    if units == 0 or span is None or span <= 0.5:
        return None
    return units / span


def is_slow(transcript: str, p: float) -> bool:
    t = tokens(transcript)
    characters = sum(1 for x in t if any(is_cjk(c) for c in x))
    return p < (SLOW_CHARACTERS if characters * 2 >= len(t) else SLOW_WORDS)


_saved_pace = None


def saved_is_slow() -> bool:
    global _saved_pace
    try:
        mtime = os.path.getmtime(audio_path())
    except OSError:
        return False
    if _saved_pace and _saved_pace[0] == mtime:
        return _saved_pace[1]
    t = text() or ""
    try:
        p = pace(t, Wav.read_file(audio_path()))
    except (OSError, ValueError):
        p = None
    slow = p is not None and is_slow(t, p)
    _saved_pace = (mtime, slow)
    return slow


def passage(code: str) -> str:
    k = (code or "en").split("-")[0].lower()
    if k == "zh":
        return "大家好，我是这次会议的主持人。今天我们主要讨论新产品的上线计划，包括时间安排、测试范围和市场推广。请大家先看一下屏幕上的议程。"
    if k == "ja":
        return "皆さん、こんにちは。今日の会議では、新製品の発売計画について話し合います。スケジュール、テストの範囲、そしてマーケティングについて順番に確認しましょう。"
    return ("Hello everyone, thanks for joining. Today we'll walk through the launch plan for the new product: the schedule, "
            "what we still need to test, and how we'll tell people about it. Let's start with the agenda on the screen.")


def check(samples, transcript: str) -> str | None:
    if len(trim(samples)) / RATE < MIN_SECONDS:
        return "short"
    if len(transcript.strip()) < 6:
        return "unclear"
    p = pace(transcript, samples)
    if p is not None and is_slow(transcript, p):
        return "slow"
    return None
