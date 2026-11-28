from __future__ import annotations

import queue
import threading
import time
from array import array
from concurrent.futures import ThreadPoolExecutor, wait

from . import strings
from .audio import RATE, Wav
from .ling import LingError
from .models import TranscriptLine
from .roommic import EchoGate, EchoMatch, Heard, VoiceGate
from .segmenter import Segmenter
from .support import Log, english_name, is_cjk_language
from .translator import Translator

_END = object()
ROOM_IDS = 1_000_000


class RoomMix:
    DELAY = RATE
    LIMIT = 30 * RATE

    def __init__(self, rec):
        self.rec = rec
        self._lock = threading.Lock()
        self._main = array("h")
        self._at = 0
        self._room = array("h")
        self._room_at = 0

    def write(self, buf) -> None:
        with self._lock:
            self._main.extend(buf)
            out = self._take(len(self._main) - self.DELAY)
        if out:
            self.rec.write(out)

    def room(self, buf, at: int) -> None:
        with self._lock:
            end = self._room_at + len(self._room)
            if not self._room:
                self._room_at = at
            elif at > end:
                self._room.frombytes(bytes(2 * (at - end)))
            elif at < end:
                buf = buf[end - at:]
            self._room.extend(buf)
            self._drop(self._at)
            over = len(self._room) - self.LIMIT
            if over > 0:
                del self._room[:over]
                self._room_at += over

    def close(self) -> None:
        with self._lock:
            out = self._take(len(self._main))
            if self._room and self._room_at >= self._at:
                out.frombytes(bytes(2 * (self._room_at - self._at)))
                out.extend(self._room)
                self._room = array("h")
        if out:
            self.rec.write(out)
        self.rec.close()

    def finish(self, until=None) -> None:
        self.rec.finish(until)

    def _drop(self, upto: int) -> None:
        late = min(len(self._room), upto - self._room_at)
        if late > 0:
            del self._room[:late]
            self._room_at += late

    def _take(self, n: int):
        if n <= 0:
            return array("h")
        out, self._main = self._main[:n], self._main[n:]
        start, self._at = self._at, self._at + n
        self._drop(start)
        if self._room and self._room_at < self._at:
            off = self._room_at - start
            k = min(len(self._room), self._at - self._room_at)
            room = self._room
            for i in range(k):
                v = out[off + i] + room[i]
                out[off + i] = 32767 if v > 32767 else -32768 if v < -32768 else v
            del self._room[:k]
            self._room_at += k
        return out


class _Lane:
    def __init__(self, via: str | None = None, first: int = 0):
        self.via = via
        self.first = first
        self.source = None
        self.audio = None
        self.worker = None
        self.done: dict = {}
        self.segments: dict = {}
        self.next = first + 1
        self.last = None
        self.last_end = 0.0
        self.hint = None
        self.candidate = None
        self.votes = 0
        self.level = 0.0
        self.peak = 0.0
        self.heard_seconds = 0.0
        self.gate = None
        self.muted = False


class ListenEngine:
    def __init__(self, ling, translator, store, notes, settings):
        self.ling = ling
        self.translator = translator
        self.store = store
        self.notes = notes
        self.settings = settings
        self._gate = threading.RLock()
        self._pool = ThreadPoolExecutor(max_workers=8, thread_name_prefix="Listen")
        self._main = _Lane()
        self._room = None
        self.echo_gate = EchoGate()
        self.gated = False
        self._recent_online: list = []
        self._held: list = []
        self._main_loud_at = 0.0
        self._in_flight: list = []
        self._line_count = 0
        self._listeners = []
        self.listening = False
        self.session_id = None
        self.recorder = None
        self._recording = None
        self.source_kind = None
        self.problem = None
        self.problem_kind = None
        self._server_errors = 0
        self.loudness = None
        self.speakers = None
        self.on_voice = None
        self.fixes = None
        self._voice_pool = ThreadPoolExecutor(1, thread_name_prefix="Voiceprint")
        self._deliver_lock = threading.Lock()
        self._voices_waiting = 0
        self.notes_for: dict = {}
        notes.language = lambda sid: english_name(self.notes_code(sid))
        translator.glossary = notes.glossary

    @property
    def level(self) -> float:
        return self._main.level

    @property
    def peak(self) -> float:
        return self._main.peak

    @property
    def heard_seconds(self) -> float:
        return self._main.heard_seconds

    @property
    def _hint(self):
        return self._main.hint

    def on_change(self, listener) -> None:
        self._listeners.append(listener)

    def _changed(self) -> None:
        for l in list(self._listeners):
            l()

    @property
    def target(self) -> str:
        return self.settings.target_code

    def meeting_language(self, sid: str | None) -> str | None:
        s = self.store.get(sid) if sid else None
        counts: dict = {}
        for l in (s.lines if s else []):
            if l.speaker != "me" and l.srcLang:
                counts[l.srcLang] = counts.get(l.srcLang, 0) + 1
        if counts:
            return max(counts, key=counts.get)
        return self._hint if self.listening and sid == self.session_id else None

    def notes_choice(self, sid: str | None) -> str:
        return self.notes_for.get(sid, self.settings.notesLanguage)

    def notes_code(self, sid: str | None) -> str:
        return self.settings.notes_code(self.notes_choice(sid), self.meeting_language(sid))

    def set_notes_language(self, choice: str, meeting_only: bool = False) -> None:
        live = self.session_id if self.listening else None
        before = self.notes_code(live) if live else None
        if meeting_only and live:
            self.notes_for[live] = choice
        else:
            self.settings.notesLanguage = choice
            self.settings.save()
        if live and self.notes_code(live) != before:
            self.notes.rewrite()
        Log.d("notesLanguage=%s meetingOnly=%s" % (self.notes_code(live) if live else choice, meeting_only))
        self._changed()

    @property
    def spoken(self):
        with self._gate:
            return self._main.hint or (self._room.hint if self._room is not None else None)

    @property
    def pending(self) -> int:
        with self._gate:
            return sum(len(l.segments) for l in self._lanes())

    def _lanes(self) -> list:
        return [self._main] + ([self._room] if self._room is not None else [])

    @property
    def recording(self) -> bool:
        return self.listening and self._recording is not None

    @property
    def hears_room_too(self) -> bool:
        return self._room is not None

    def start(self, source, kind: str, mic: bool = False) -> None:
        if self.listening:
            return
        session = self.store.begin()
        self.session_id = session.id
        self.source_kind = kind
        with self._gate:
            self._main = _Lane()
            self._room = None
            self._recent_online, self._held = [], []
            self._in_flight.clear()
            self._line_count = 0
            self.problem = self.problem_kind = None
            self._server_errors = 0
        self.notes.begin(session.id)
        if self.speakers is not None:
            self.speakers.reset()
        self._recording = None
        if self.recorder is not None:
            try:
                rec = self.recorder(session.id)
                self._recording = RoomMix(rec) if rec is not None else None
            except Exception as e:  # noqa: BLE001
                Log.d("listen: no recording (%s)" % type(e).__name__)
        self.listening = True
        self._run(self._main)
        self.attach(source, mic)
        Log.d("listen: started %s source=%s target=%s" % (session.id, kind, self.target))
        self._changed()

    def _run(self, lane, at: float = 0.0) -> None:
        segmenter = Segmenter()
        segmenter.consumed = clock = int(at * RATE)
        segmenter.on_segment = lambda seg: self._send(lane, seg)
        q: queue.Queue = queue.Queue()
        lane.audio = q

        def work():
            nonlocal clock
            while True:
                buf = q.get()
                if buf is _END:
                    break
                seconds = len(buf) / RATE
                if lane.muted:
                    buf = array("h", bytes(len(buf) * 2))
                rec = self._recording
                if rec is not None:
                    if lane is self._main:
                        rec.write(buf)
                    else:
                        rec.room(buf, clock)
                clock += len(buf)
                now = time.monotonic()
                if lane is not self._main and self.gated:
                    self.echo_gate.room_level(Wav.rms(buf), seconds, now)
                    if self.echo_gate.closed(now):
                        buf = array("h", bytes(len(buf) * 2))
                level = Wav.rms(buf)
                gate = lane.gate
                if gate is not None:
                    gate.voiced(level, seconds)
                    segmenter.threshold = gate.threshold
                elif segmenter.threshold != Segmenter.threshold:
                    del segmenter.threshold
                segmenter.feed(buf)
                lane.level = level
                lane.peak = max(lane.peak * 0.995, level)
                if lane is self._main and gate is None:
                    loud = level >= Segmenter.threshold
                    if self.loudness is not None:
                        self.loudness.add(loud)
                    if loud:
                        self._main_loud_at = now
                        if self.gated:
                            self.echo_gate.hold(now)
                lane.heard_seconds += seconds
            segmenter.flush()
        lane.worker = threading.Thread(target=work, name="ListenWorker", daemon=True)
        lane.worker.start()

    def attach(self, source, mic: bool = False) -> None:
        lane = self._main
        old = lane.source
        if old is not None:
            old.on_samples = None
            old.stop()
        lane.gate = VoiceGate(adaptive=True) if mic else None
        lane.via = "room" if mic else None
        if mic and self.session_id:
            self.store.mark_room(self.session_id)
        lane.source = source
        source.on_samples = lane.audio.put
        source.start()
        if old is not None:
            Log.d("listen: source changed to %s" % ("a microphone" if mic else "the computer's audio"))

    def set_muted(self, on: bool) -> None:
        for lane in self._lanes():
            if lane.gate is not None and lane.muted != on:
                lane.muted = on
                Log.d("listen: room mic %s" % ("muted" if on else "open"))

    def start_room(self, source, gated: bool) -> None:
        if not self.listening or self._room is not None:
            return
        forced = self.echo_gate.forced
        self.echo_gate = EchoGate()
        self.echo_gate.forced = forced
        lane = _Lane(via="room", first=ROOM_IDS)
        lane.gate = VoiceGate(adaptive=True)
        lane.muted = any(l.muted for l in self._lanes())
        self.gated = gated
        self._run(lane, self._main.heard_seconds)
        with self._gate:
            self._room = lane
        self.store.mark_room(self.session_id)
        lane.source = source
        source.on_samples = lane.audio.put
        source.start()
        Log.d("listen: room side started (%s)" % ("gated" if gated else "echo cancelled"))
        self._changed()

    def stop_room(self) -> None:
        with self._gate:
            lane, self._room = self._room, None
        if lane is None:
            return
        self._end_lane(lane)
        self._release_all()
        self.gated = False
        Log.d("listen: room side stopped")
        self._changed()

    def stop(self, ended_at=None) -> None:
        if not self.listening:
            return
        self.listening = False
        for lane in self._lanes():
            self._end_lane(lane)
        with self._gate:
            waiting = list(self._in_flight)
        wait(waiting, timeout=15)
        self._release_all()
        self._room = None
        self.gated = False
        sid = self.session_id
        rec, self._recording = self._recording, None
        if rec is not None:
            rec.close()
        if sid is None:
            return
        self.store.end(sid, ended_at)
        s = self.store.get(sid)
        if rec is not None and s is not None:
            until = s.duration if ended_at is not None else None
            self._pool.submit(rec.finish, until)
        Log.d("listen: stopped %s, %d lines" % (sid, self._line_count))
        self._changed()
        self._pool.submit(self.notes.finish)

    @staticmethod
    def _end_lane(lane) -> None:
        if lane.source is not None:
            lane.source.on_samples = None
            lane.source.stop()
        if lane.audio is not None:
            lane.audio.put(_END)
        if lane.worker is not None:
            lane.worker.join(5)

    @property
    def voices_on(self) -> bool:
        return bool(self.speakers is not None and getattr(self.settings, "speakerVoices", False) and self.speakers.available)

    def _send(self, lane, seg) -> None:
        seg.index += lane.first
        wav = Wav.bytes(seg.samples)
        seg.voiceprint = None
        if self.voices_on:
            with self._gate:
                behind = self._voices_waiting >= 2
                if not behind:
                    self._voices_waiting += 1
            if behind:
                Log.d("speakers: voiceprints behind, segment %d left unlabelled" % seg.index)
            else:
                def embed(samples=seg.samples):
                    try:
                        return self.speakers.embed(samples)
                    finally:
                        with self._gate:
                            self._voices_waiting -= 1
                seg.voiceprint = self._voice_pool.submit(embed)
        with self._gate:
            lane.segments[seg.index] = seg
            lang = lane.hint
        seg.asked = self.settings.resolved_target(lang)
        self._changed()

        def job():
            heard = None
            started = time.monotonic()
            try:
                heard = self.translator.hear(wav, seg.asked, lang)
                with self._gate:
                    self._server_errors = 0
                self.problem = self.problem_kind = None
            except LingError as e:
                with self._gate:
                    self._server_errors = self._server_errors + 1 if server_error(e) else 0
                    shown = not server_error(e) or self._server_errors >= SERVER_ERRORS_SHOWN
                if shown:
                    self.problem_kind, self.problem = problem(e, self.ling.provider.name, self.ling.config().hear_model)
                Log.d("listen: segment %d failed %s" % (seg.index, e))
            except Exception as e:  # noqa: BLE001
                Log.d("listen: segment %d failed %s" % (seg.index, type(e).__name__))
            Log.d("listen: segment %d %.1fs -> %s in %d ms" % (seg.index, seg.seconds, heard.lang if heard else "nothing",
                                                              (time.monotonic() - started) * 1000))
            with self._gate:
                lane.done[seg.index] = heard
            self._deliver(lane)
        f = self._pool.submit(job)
        with self._gate:
            self._in_flight.append(f)
            self._in_flight = [x for x in self._in_flight if not x.done()]

    def _deliver(self, lane) -> None:
        with self._deliver_lock:
            ready = []
            with self._gate:
                while lane.next in lane.done:
                    heard = lane.done.pop(lane.next)
                    ready.append((lane.segments.pop(lane.next), heard))
                    lane.next += 1
            for seg, heard in ready:
                if heard is None:
                    continue
                if lane is not self._main:
                    self._heard_in_room(lane, seg, heard)
                else:
                    self._record(lane, seg, heard)
                    self._heard_online(heard.original, seg.seconds)
                    if heard.original.strip():
                        self.echo_gate.heard_words(time.monotonic())
        if ready:
            self._changed()

    def _heard_online(self, text: str, seconds: float) -> None:
        if self._room is None:
            return
        now = time.monotonic()
        with self._gate:
            self._recent_online.append(Heard(text, now - seconds, now))
            self._recent_online = [h for h in self._recent_online if h.end >= now - 20]
            online = list(self._recent_online)
            dropped = [h for h in self._held if EchoMatch.is_echo(h[3], online)]
            self._held = [h for h in self._held if h not in dropped]
        for _ in dropped:
            Log.d("listen: room line dropped as an echo")

    def _heard_in_room(self, lane, seg, heard) -> None:
        now = time.monotonic()
        h = Heard(heard.original, now - seg.seconds, now)
        with self._gate:
            online = list(self._recent_online)
        if EchoMatch.is_echo(h, online):
            Log.d("listen: room line dropped as an echo")
            return
        if now - self._main_loud_at >= EchoMatch.window:
            self._record(lane, seg, heard)
            return
        entry = (lane, seg, heard, h)
        with self._gate:
            self._held.append(entry)
        timer = threading.Timer(EchoMatch.hold, self._release, (entry,))
        timer.daemon = True
        timer.start()

    def _release(self, entry) -> None:
        with self._deliver_lock:
            with self._gate:
                if entry not in self._held:
                    return
                self._held.remove(entry)
            self._record(*entry[:3])
        self._changed()

    def _release_all(self) -> None:
        with self._deliver_lock:
            with self._gate:
                held, self._held = self._held, []
            for entry in held:
                self._record(*entry[:3])

    def _voice(self, seg, heard):
        future = getattr(seg, "voiceprint", None)
        if future is None or sum(1 for c in heard.original if c.isalpha()) < 2:
            return None
        try:
            vector = future.result(timeout=20)
        except Exception as e:  # noqa: BLE001
            Log.d("speakers: voiceprint failed %s" % type(e).__name__)
            return None
        return self.speakers.label(vector, seg.seconds)

    def _record(self, lane, seg, heard) -> None:
        sid = self.session_id
        if sid is None:
            return
        target = self.settings.resolved_target(heard.lang)
        translation = heard.translation if getattr(seg, "asked", target) == target else None
        voice = self._voice(seg, heard)
        with self._gate:
            h = lane.hint
            if h is None:
                lane.hint = heard.lang
            elif heard.lang != h:
                if lane.candidate == heard.lang:
                    lane.votes += 1
                else:
                    lane.candidate, lane.votes = heard.lang, 1
                if lane.votes >= 2:
                    lane.hint, lane.candidate, lane.votes = lane.candidate, None, 0
            else:
                lane.candidate, lane.votes = None, 0
            prev = lane.last
            joined = False
            if prev is not None and continues(prev, seg.start - lane.last_end, heard) and (
                    voice is None or prev.voice is None or voice == prev.voice):
                prev.src = join(prev.src, heard.original, heard.lang)
                prev.dst = None if prev.dst is None or translation is None else join(prev.dst, translation, target)
                line = prev
                joined = True
            else:
                self._line_count += 1
                line = TranscriptLine(id="h%d-%d" % (self._line_count, seg.index), t=seg.start, speaker="them",
                                      src=heard.original, dst=translation, srcLang=heard.lang, dstLang=target,
                                      voice=voice, via=lane.via)
                lane.last = line
            lane.last_end = seg.start + seg.seconds
            copy = line.copy()
        if joined:
            self.store.replace(sid, copy)
        else:
            self.store.append(sid, copy)
        if voice is not None and self.on_voice is not None:
            self.on_voice(sid)
        if self.fixes is not None:
            self.fixes.apply_known(copy.id, sid)
        fixing = self.settings.fixMisheard and self.fixes is not None
        if (joined or line.dst is None or fixing) and line.srcLang != target:
            src = line.src
            only_fix = not joined and line.dst is not None

            def retranslate():
                if only_fix:
                    dst = self.translator.fix(src, line.srcLang, target)
                    if dst is None:
                        return
                else:
                    dst = self.translator.translate(src, line.srcLang, target, Translator.SENTENCE)
                if dst is None:
                    self._changed()
                    return
                with self._gate:
                    if line.src != src:
                        return
                    line.dst = dst
                    updated = line.copy()
                self.store.replace(sid, updated)
                self._changed()
            self._pool.submit(retranslate)


def continues(last, gap: float, nxt) -> bool:
    if gap > 0.8 or last.srcLang != nxt.lang:
        return False
    text = last.src.rstrip()
    if not text or text[-1] in ".!?。！？…":
        return False
    cjk = is_cjk_language(nxt.lang)
    size = len(text) + len(nxt.original) if cjk else len((text + " " + nxt.original).split())
    return size <= (80 if cjk else 45)


def join(a: str, b: str, lang: str) -> str:
    cjk = lang.startswith(("zh", "ja"))
    return a.rstrip() + b.lstrip() if cjk else a.rstrip() + " " + b.lstrip()


SERVER_ERRORS_SHOWN = 3


def server_error(e: LingError) -> bool:
    return e.kind == LingError.HTTP and e.status >= 500


def problem(e: LingError, service: str, hear_model: str = ""):
    L, LF = strings.L, strings.LF
    ling = service == "Ling"
    service = service if ling else L(service)
    if e.kind == LingError.HTTP and e.status in (400, 404, 415, 422) and not ling:
        return "key", LF("%@ 听不了声音。", hear_model or service)
    if server_error(e):
        return "busy", LF("%@ 暂时出错（HTTP %lld），稍后再试。", service, e.status)
    kind = {LingError.NO_KEY: "key", LingError.INVALID_KEY: "key", LingError.RATE_LIMITED: "busy",
            LingError.NETWORK: "network", LingError.TIMEOUT: "network"}.get(e.kind)
    away = LF("字幕和纪要等 %@ 恢复 · 连上后自动继续", service)
    if ling:
        text = {LingError.NO_KEY: L("需要 Ling key 才能听"), LingError.INVALID_KEY: L("Ling key 无效"),
                LingError.RATE_LIMITED: L("Ling 太忙，稍后再试"), LingError.NETWORK: away,
                LingError.TIMEOUT: away}.get(e.kind)
    else:
        text = {LingError.NO_KEY: LF("需要 %@ 的 key 才能听", service), LingError.INVALID_KEY: LF("%@ 的 key 无效", service),
                LingError.RATE_LIMITED: LF("%@ 太忙，稍后再试", service), LingError.NETWORK: away,
                LingError.TIMEOUT: away}.get(e.kind)
    return kind, text
