from __future__ import annotations

import os
import time

from ..core import aac
from ..core.audio import RATE
from ..core.support import Log

try:
    import gi
    gi.require_version("Gst", "1.0")
    from gi.repository import Gst
    Gst.init(None)
except (ImportError, ValueError) as _e:
    Gst = None

ENCODERS = ("fdkaacenc", "avenc_aac", "voaacenc", "faac")
DECODERS = ("avdec_aac", "fdkaacdec", "faad")
_found: dict = {}


def _has(name: str) -> bool:
    if name not in _found:
        _found[name] = Gst is not None and Gst.ElementFactory.find(name) is not None
    return _found[name]


def encoder() -> str | None:
    if not all(_has(e) for e in ("appsrc", "audioconvert", "audioresample", "aacparse", "mp4mux", "filesink")):
        return None
    return next((e for e in ENCODERS if _has(e)), None)


def can_play() -> bool:
    return _has("playbin") and any(_has(d) for d in DECODERS)


def rescan() -> None:
    if Gst is None or (encoder() is not None and can_play()):
        return
    Gst.update_registry()
    for name in [n for n, found in _found.items() if not found]:
        del _found[name]


def codecs() -> dict:
    return {"gst": Gst is not None, "encoder": encoder(), "decoders": [d for d in DECODERS if _has(d)], "play": can_play()}


def _make(name: str, **props):
    e = Gst.ElementFactory.make(name, None)
    if e is None:
        raise RuntimeError("no element %s" % name)
    for k, v in props.items():
        e.set_property(k.replace("_", "-"), v)
    return e


def _wait(pipeline, seconds: float):
    msg = pipeline.get_bus().timed_pop_filtered(int(seconds * Gst.SECOND), Gst.MessageType.EOS | Gst.MessageType.ERROR)
    if msg is None:
        return "timeout"
    if msg.type == Gst.MessageType.ERROR:
        err, _dbg = msg.parse_error()
        return err.message
    return None


class Recorder:
    def __init__(self, path: str):
        self.path = path
        self.partial = aac.partial(path)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        enc = encoder()
        p = Gst.Pipeline.new("record")
        self.src = _make("appsrc", format=Gst.Format.TIME, is_live=False, block=False,
                         caps=Gst.Caps.from_string("audio/x-raw,format=S16LE,rate=%d,channels=1,layout=interleaved" % RATE))
        coder = _make(enc)
        if coder.find_property("bitrate") is not None:
            coder.set_property("bitrate", 32000)
        chain = [self.src, _make("audioconvert"), _make("audioresample"), coder, _make("aacparse"),
                 _make("capsfilter", caps=Gst.Caps.from_string("audio/mpeg,mpegversion=4,stream-format=adts")),
                 _make("filesink", location=self.partial, buffer_mode=2, sync=False, **{"async": False})]
        for e in chain:
            p.add(e)
        for a, b in zip(chain, chain[1:]):
            if not a.link(b):
                raise RuntimeError("can't link %s to %s" % (a.get_name(), b.get_name()))
        if p.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            p.set_state(Gst.State.NULL)
            raise RuntimeError("won't start")
        self.pipeline = p
        self.samples = 0
        self.failed = False
        Log.d("record: %s with %s" % (os.path.basename(os.path.dirname(path)), enc))

    def write(self, samples) -> None:
        if self.failed:
            return
        msg = self.pipeline.get_bus().pop_filtered(Gst.MessageType.ERROR)
        if msg is not None:
            self.failed = True
            Log.d("record: failed %s" % msg.parse_error()[0].message)
            return
        data = samples.tobytes()
        buf = Gst.Buffer.new_wrapped(data)
        buf.pts = self.samples * Gst.SECOND // RATE
        buf.duration = len(samples) * Gst.SECOND // RATE
        self.samples += len(samples)
        self.src.emit("push-buffer", buf)

    def close(self) -> None:
        if self.pipeline is None:
            return
        self.src.emit("end-of-stream")
        why = _wait(self.pipeline, 10)
        self.pipeline.set_state(Gst.State.NULL)
        self.pipeline = None
        Log.d("record: closed after %.1f s%s" % (self.samples / RATE, (" (%s)" % why) if why else ""))

    def finish(self, until: float | None = None) -> None:
        finish(self.path, until)
        if self.on_finished is not None:
            self.on_finished()

    on_finished = None


def finish(path: str, until: float | None = None) -> bool:
    src = aac.partial(path)
    if not os.path.isfile(src) or Gst is None or not (_has("aacparse") and _has("mp4mux")):
        return False
    try:
        aac.trim(src, until)
    except OSError as e:
        Log.d("record: trim failed %s" % type(e).__name__)
    try:
        os.remove(path)
    except OSError:
        pass
    if os.path.getsize(src) == 0:
        os.remove(src)
        return False
    p = Gst.Pipeline.new("rewrap")
    chain = [_make("filesrc", location=src), _make("aacparse"), _make("mp4mux"), _make("filesink", location=path)]
    for e in chain:
        p.add(e)
    for a, b in zip(chain, chain[1:]):
        a.link(b)
    p.set_state(Gst.State.PLAYING)
    why = _wait(p, 120)
    p.set_state(Gst.State.NULL)
    if why:
        Log.d("record: rewrap failed %s: %s" % (os.path.basename(os.path.dirname(path)), why))
        try:
            os.remove(path)
        except OSError:
            pass
        return False
    os.remove(src)
    Log.d("record: saved %s" % os.path.basename(os.path.dirname(path)))
    return True


class Player:
    def __init__(self, path: str, on_change=None):
        self.on_change = on_change
        self.rate = 1.0
        self.playing = False
        self.started = False
        self.following = True
        self._length = 0.0
        self._seeking = None
        pb = _make("playbin", uri=Gst.filename_to_uri(path))
        tempo = Gst.ElementFactory.make("scaletempo", None)
        if tempo is not None:
            pb.set_property("audio-filter", tempo)
        self.pb = pb
        bus = pb.get_bus()
        bus.add_signal_watch()
        bus.connect("message::eos", self._eos)
        bus.connect("message::error", self._error)
        pb.set_state(Gst.State.PAUSED)

    def close(self) -> None:
        if self.pb is None:
            return
        self.pb.get_bus().remove_signal_watch()
        self.pb.set_state(Gst.State.NULL)
        self.pb = None
        self.playing = False

    @property
    def length(self) -> float:
        if self._length <= 0 and self.pb is not None:
            ok, d = self.pb.query_duration(Gst.Format.TIME)
            if ok and d > 0:
                self._length = d / Gst.SECOND
        return self._length

    @property
    def time(self) -> float:
        if self.pb is None:
            return 0.0
        ok, t = self.pb.query_position(Gst.Format.TIME)
        t = max(0.0, t / Gst.SECOND) if ok else 0.0
        if self._seeking is not None:
            to, at = self._seeking
            if abs(t - to) > 0.5 and time.monotonic() - at < 1.5:
                return to
            self._seeking = None
        return t

    def toggle(self) -> None:
        if self.playing:
            self.pause()
        else:
            if self.length and self.time >= self.length - 0.1:
                self.seek(0)
            self.play()

    def play(self) -> None:
        if self.pb is None:
            return
        self.pb.set_state(Gst.State.PLAYING)
        self.playing = self.started = True
        self._changed()

    def pause(self) -> None:
        if self.pb is None:
            return
        self.pb.set_state(Gst.State.PAUSED)
        self.playing = False
        self._changed()

    def user_scrolled(self) -> None:
        if self.following and self.playing:
            self.following = False
            self._changed()

    def follow(self) -> None:
        if not self.following:
            self.following = True
            self._changed()

    def play_from(self, t: float) -> None:
        self.seek(t)
        self.play()

    def seek(self, t: float) -> None:
        if self.pb is None:
            return
        t = max(0.0, min(t, self.length or t))
        self.following = True
        self._seeking = (t, time.monotonic())
        self.pb.seek(self.rate, Gst.Format.TIME, Gst.SeekFlags.FLUSH | Gst.SeekFlags.ACCURATE,
                     Gst.SeekType.SET, int(t * Gst.SECOND), Gst.SeekType.NONE, -1)

    def next_rate(self) -> None:
        self.rate = 1.0 if self.rate >= 2 else self.rate + 0.5
        following = self.following
        self.seek(self.time)
        self.following = following
        self._changed()

    def _eos(self, *_):
        self.pb.set_state(Gst.State.PAUSED)
        self.playing = False
        self._changed()

    def _error(self, _bus, msg):
        Log.d("play: %s" % msg.parse_error()[0].message)
        self.playing = False
        self._changed()

    def _changed(self) -> None:
        if self.on_change is not None:
            self.on_change()
