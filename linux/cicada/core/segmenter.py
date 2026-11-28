from __future__ import annotations

import math
from array import array
from collections import deque

from .audio import RATE, Wav

FRAME = 480
STEP = 160
ONSET = 3
PRE_ROLL = 0.15
TAIL = 0.15
CUT_WINDOW = 2.0
HIGH_PASS = 1.0 / (1.0 + 2.0 * math.pi * 100.0 / RATE)


class Segment:
    def __init__(self, index: int, start: float, samples: array):
        self.index = index
        self.start = start
        self.samples = samples

    @property
    def seconds(self) -> float:
        return len(self.samples) / RATE


class Segmenter:
    threshold = 0.01
    pause = 0.6
    max_length = 8.0
    min_speech = 0.25
    min_word = 0.2
    steady = 2.0
    dips = 2.5
    short = 2.0
    swell = 10 ** (10 / 20)
    fade = 10 ** (30 / 20)
    voiced = 0.15
    above = 0.25

    def __init__(self):
        self.pending = array("h")
        self.current = array("h")
        self.levels: list = []
        self.highs: list = []
        self.speech: list = []
        self.sounding = 0
        self.carried = False
        self._hx = 0.0
        self._hy = 0.0
        self.before: deque = deque()
        self.idle: deque = deque(maxlen=int(self.pause * RATE / FRAME))
        self.lead = None
        self.consumed = 0
        self.current_start = 0.0
        self.quiet = 0
        self.loud = 0
        self.index = 0
        self.on_segment = None

    def feed(self, samples) -> None:
        self.pending.extend(samples)
        whole = len(self.pending) // FRAME * FRAME
        for i in range(0, whole, FRAME):
            self._step(self.pending[i:i + FRAME])
        del self.pending[:whole]

    def flush(self) -> None:
        if len(self.current):
            self._close(len(self.current) - self.quiet * FRAME + int(TAIL * RATE))

    def _speech(self, frame) -> bool:
        said = False
        carried = self.sounding > 0
        for i in range(0, len(frame), STEP):
            if Wav.rms(frame[i:i + STEP]) >= self.threshold:
                self.sounding += 1
                if self.sounding >= ONSET and not said:
                    said = True
                    self.carried = carried
            else:
                self.sounding = 0
                carried = False
        return said

    def _step(self, frame: array) -> None:
        level = Wav.rms(frame)
        high = self._high(frame)
        loud = self._speech(frame)
        now = self.consumed / RATE
        self.consumed += len(frame)
        if not len(self.current):
            if not loud:
                self.idle.append(level)
                self.before.append((frame, level, high))
                while len(self.before) > PRE_ROLL * RATE / FRAME + 1:
                    self.before.popleft()
                return
            while len(self.before) > PRE_ROLL * RATE / FRAME + self.carried:
                self.before.popleft()
            self.current_start = now - len(self.before) * FRAME / RATE
            self.lead = min(self.idle) if self.idle else None
            self.idle.clear()
            for f, l, h in self.before:
                self.current.extend(f)
                self.levels.append(l)
                self.highs.append(h)
                self.speech.append(False)
            self.before.clear()
            self.quiet = self.loud = 0
        self.current.extend(frame)
        self.levels.append(level)
        self.highs.append(high)
        self.speech.append(loud)
        if loud:
            self.quiet = 0
            self.loud += 1
        else:
            self.quiet += 1
        if self.quiet * FRAME >= self.pause * RATE:
            self._close(len(self.current) - self.quiet * FRAME + int(TAIL * RATE))
        elif len(self.current) >= self.max_length * RATE:
            frm = max(1, len(self.levels) - int(CUT_WINDOW * RATE / FRAME))
            cut = frm
            for i in range(frm, len(self.levels)):
                if self.levels[i] < self.levels[cut]:
                    cut = i
            self._close(cut * FRAME)

    def _steady(self, levels) -> bool:
        loud = [i for i, l in enumerate(levels) if l >= self.threshold]
        if len(loud) < 2:
            return False
        body = levels[loud[0]:loud[-1] + 1]
        top = sorted(max(l, self.threshold) for l in body)
        if top[int(0.9 * (len(top) - 1))] >= self.steady * top[int(0.1 * (len(top) - 1))]:
            return False
        low = sorted(max(l, self.threshold / 8) for l in body)
        return low[int(0.5 * (len(low) - 1))] < self.dips * low[int(0.1 * (len(low) - 1))]

    def _isolated(self, levels) -> bool:
        loud = [i for i, l in enumerate(levels) if l >= self.threshold]
        if not loud or (loud[-1] - loud[0] + 1) * FRAME > self.short * RATE:
            return False
        quiet = self.threshold / 4
        after = levels[loud[-1] + 1:]
        if self.lead is None or self.lead > quiet or not after or min(after) > quiet:
            return False
        steps = [Wav.rms(self.current[i:i + STEP]) for i in range(0, len(self.current) - STEP + 1, STEP)]
        rise = min(quiet, max(steps) / self.fade)
        sound = [i for i, l in enumerate(steps) if l >= rise]
        body = sorted(max(l, self.threshold / 8) for l in steps[sound[0]:sound[-1] + 1])
        low = max(2, int(0.05 * (len(body) - 1)))
        return low < len(body) and body[int(0.9 * (len(body) - 1))] >= self.swell * body[low] and self._voiced(levels)

    def _voiced(self, levels) -> bool:
        full = sorted(levels)[int(0.9 * (len(levels) - 1))] / math.sqrt(2)
        slow = 0
        for i, l in enumerate(levels):
            if l < full:
                continue
            f = self.current[i * FRAME:(i + 1) * FRAME]
            crossings = sum(1 for k in range(1, len(f)) if (f[k] >= 0) != (f[k - 1] >= 0))
            if crossings < self.voiced * (len(f) - 1):
                slow += 1
        return slow >= 2

    def _high(self, frame) -> float:
        a, x0, y, total = HIGH_PASS, self._hx, self._hy, 0.0
        for x in frame:
            y = a * (y + x - x0)
            x0 = x
            total += y * y
        self._hx, self._hy = float(x0), y
        return math.sqrt(total / len(frame)) / 32768 if len(frame) else 0.0

    def _rumble(self, levels, highs) -> bool:
        full = above = 0.0
        for l, h in zip(levels, highs):
            if l >= self.threshold:
                full += l * l
                above += h * h
        return above < self.above * full

    def _close(self, end_at: int) -> None:
        end = max(0, min(end_at, len(self.current)))
        samples = self.current[:end]
        rest = self.current[end:]
        rest_levels = self.levels[min(len(self.levels), end // FRAME):]
        rest_highs = self.highs[min(len(self.highs), end // FRAME):]
        rest_speech = self.speech[min(len(self.speech), end // FRAME):]
        start = self.current_start
        sent = self.levels[:end // FRAME]
        if self._isolated(self.levels):
            sound = sum(1 for l in sent if l >= self.threshold / 4)
            speech = sound * FRAME >= self.min_word * RATE
        else:
            speech = self.loud * FRAME >= self.min_speech * RATE and not self._steady(sent)
        speech = speech and not self._rumble(sent, self.highs[:end // FRAME])
        self.current = array("h")
        self.levels = []
        self.highs = []
        self.speech = []
        self.quiet = self.loud = 0
        if speech and self.on_segment:
            self.index += 1
            self.on_segment(Segment(self.index, round(start * 1000) / 1000.0, samples))
        elif speech:
            self.index += 1
        if any(rest_speech):
            self.current_start = start + end / RATE
            self.lead = None
            self.current.extend(rest)
            self.levels = list(rest_levels)
            self.highs = list(rest_highs)
            self.speech = list(rest_speech)
            trailing = 0
            for v in reversed(self.speech):
                if v:
                    break
                trailing += 1
            self.quiet = trailing
            self.loud = sum(self.speech)
