from __future__ import annotations

import threading

from .support import Log

OURS = ("cicada_mic",)


class Input:
    def __init__(self, name: str, description: str = "", builtin: bool = False, bluetooth: bool = False,
                 virtual: bool = False):
        self.name = name
        self.description = description or name
        self.builtin = builtin
        self.bluetooth = bluetooth
        self.virtual = virtual

    def __repr__(self):
        return "Input(%s%s%s%s)" % (self.name, " builtin" if self.builtin else "", " bt" if self.bluetooth else "",
                                     " virtual" if self.virtual else "")


def parse_sources(text: str) -> list:
    out = []
    block: dict = {}
    props: dict = {}

    def close():
        name = block.get("Name")
        if not name:
            return
        monitor = block.get("Monitor of Sink", "n/a") not in ("n/a", "")
        api = props.get("device.api", "")
        virtual = monitor or not api or name in OURS or name.startswith("cicada_") or props.get("device.class") == "monitor"
        bluetooth = api == "bluez5" or props.get("device.bus") == "bluetooth"
        builtin = not bluetooth and (props.get("device.form_factor") == "internal" or
                                     (api == "alsa" and props.get("device.bus") == "pci"))
        out.append(Input(name, block.get("Description", ""), builtin, bluetooth, virtual))

    for raw in text.splitlines():
        line = raw.strip()
        if raw.startswith("Source #"):
            close()
            block, props = {}, {}
            continue
        if raw.startswith("\t\t") and " = " in line:
            k, _, v = line.partition(" = ")
            props[k.strip()] = v.strip().strip('"')
        elif ":" in line and raw.startswith("\t") and not raw.startswith("\t\t"):
            k, _, v = line.partition(":")
            block[k.strip()] = v.strip()
    close()
    return out


def pick(default: str | None, inputs: list, chosen: str = "") -> str | None:
    real = [i for i in inputs if not i.virtual]
    if chosen and any(i.name == chosen for i in real):
        return chosen
    d = next((i for i in real if i.name == default), None)
    if d is not None and not d.bluetooth:
        return d.name
    for want in (lambda i: i.builtin, lambda i: not i.bluetooth, lambda i: True):
        found = next((i for i in real if want(i)), None)
        if found is not None:
            return found.name
    return None


class VoiceGate:
    fixed = 0.01
    lowest = 0.0015

    def __init__(self, adaptive: bool = False):
        self.adaptive = adaptive
        self._quietest: list = []
        self._second = float("inf")
        self._elapsed = 0.0

    @property
    def threshold(self) -> float:
        if not self.adaptive:
            return self.fixed
        if len(self._quietest) < 3:
            return 0.004
        floor = sorted(self._quietest)[len(self._quietest) // 5]
        return min(self.fixed, max(self.lowest, floor * 2))

    def voiced(self, rms: float, seconds: float = 0.1) -> bool:
        on = rms >= self.threshold
        if not self.adaptive:
            return on
        self._second = min(self._second, rms)
        self._elapsed += seconds
        if self._elapsed >= 1 - 1e-9:
            self._quietest.append(self._second)
            if len(self._quietest) > 30:
                self._quietest.pop(0)
            self._second = float("inf")
            self._elapsed = 0.0
        return on


def heard_both(lines) -> bool:
    room = online = False
    for l in lines:
        if l.speaker != "them":
            continue
        if l.via == "room":
            room = True
        else:
            online = True
        if room and online:
            return True
    return False


def place_starts(lines) -> set:
    out, last, first = set(), None, True
    for l in lines:
        key = "me" if l.speaker == "me" else l.via
        if l.speaker != "me" and (first or key != last):
            out.add(l.id)
        last, first = key, False
    return out


class EchoGate:
    hang = 0.4
    music = 20.0
    stretch_gap = 1.5
    during = 0.15
    quiet_after = 1.0
    echo_ratio = 3.0
    clear_ratio = 2.0
    enough = 3.0
    window = 20.0

    def __init__(self):
        self._lock = threading.Lock()
        self._until = 0.0
        self._last_loud = float("-inf")
        self._stretch_start = float("-inf")
        self._last_words = float("-inf")
        self._during: list = []
        self._quiet: list = []
        self._echo = True
        self.forced = None

    @property
    def echo(self) -> bool:
        with self._lock:
            return self._echo if self.forced is None else self.forced

    def _music(self, now: float) -> bool:
        return (now - self._last_loud <= self.stretch_gap and now - self._stretch_start >= self.music
                and self._last_words < now - self.music)

    def playing_music(self, now: float) -> bool:
        with self._lock:
            return self._music(now)

    def hold(self, now: float) -> None:
        with self._lock:
            if now - self._last_loud > self.stretch_gap:
                self._stretch_start = now
            self._last_loud = now
            echo = self._echo if self.forced is None else self.forced
            if self._music(now) or not echo:
                return
            self._until = max(self._until, now + self.hang)

    def heard_words(self, now: float) -> None:
        with self._lock:
            self._last_words = now

    def closed(self, now: float) -> bool:
        with self._lock:
            return now < self._until

    def room_level(self, rms: float, seconds: float, now: float) -> None:
        with self._lock:
            since = now - self._last_loud
            if since <= self.during:
                self._during.append((now, rms, seconds))
            elif since >= self.quiet_after:
                self._quiet.append((now, rms, seconds))
            else:
                return
            self._during = [b for b in self._during if b[0] >= now - self.window]
            self._quiet = [b for b in self._quiet if b[0] >= now - self.window * 3]
            r = self.ratio([(b[1], b[2]) for b in self._during], [(b[1], b[2]) for b in self._quiet])
            if r is None:
                return
            was = self._echo
            if r >= self.echo_ratio:
                self._echo = True
            elif r < self.clear_ratio:
                self._echo = False
            if was != self._echo:
                Log.d("room echo: %s (x%.1f)" % ("speakers reach the mic" if self._echo else "none", r))
                if not self._echo:
                    self._until = 0.0

    @classmethod
    def ratio(cls, during: list, quiet: list):
        if sum(s for _, s in during) < cls.enough or sum(s for _, s in quiet) < cls.enough:
            return None
        d = sorted(r for r, _ in during)
        q = sorted(r for r, _ in quiet)
        return d[len(d) * 4 // 5] / max(q[len(q) // 5], 0.0002)


class Heard:
    def __init__(self, text: str, start: float, end: float):
        self.text = text
        self.start = start
        self.end = end


class EchoMatch:
    window = 3.0
    hold = 2.5
    contained = 0.6

    @classmethod
    def is_echo(cls, room: Heard, online: list) -> bool:
        near = [o for o in online if o.end >= room.start - cls.window and o.start <= room.end + cls.window]
        if not near:
            return False
        r = units(room.text)
        if not r:
            return False
        o = [units(x.text) for x in near]
        if len(r) <= 2:
            return any(x == r for x in o)
        mine = set(_pairs(r))
        theirs = set(p for x in o for p in _pairs(x))
        return len(mine & theirs) / len(mine) >= cls.contained


def _cjk(c: str) -> bool:
    v = ord(c)
    return (0x3040 <= v <= 0x30FF or 0x3400 <= v <= 0x4DBF or 0x4E00 <= v <= 0x9FFF or 0xAC00 <= v <= 0xD7AF
            or 0xF900 <= v <= 0xFAFF)


def units(text: str) -> list:
    out, word = [], ""
    for c in text.lower():
        if _cjk(c):
            if word:
                out.append(word)
                word = ""
            out.append(c)
        elif c.isalnum():
            word += c
        elif word:
            out.append(word)
            word = ""
    if word:
        out.append(word)
    return out


def _pairs(u: list) -> list:
    return u if len(u) < 2 else [u[i - 1] + " " + u[i] for i in range(1, len(u))]
