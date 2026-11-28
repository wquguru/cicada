from __future__ import annotations

import threading
import time

from . import correction
from .correction import Edit
from .vocabulary import learnable
from .models import LineFix
from .strings import L, LF
from .support import Log

ASK_AT_ONCE = 3
TOAST_SECONDS = 6.0


def _pair(a: str, b: str) -> str:
    return a + "\x1f" + b


def _key(f: LineFix) -> str:
    return _pair(*correction.core(f.from_, f.to))


class FixContext:
    def __init__(self, words: list, topic: str | None = None, recent: list | None = None,
                 following: list | None = None, summary: str | None = None):
        self.topic = topic
        self.words = words
        self.recent = recent or []
        self.following = following or []
        self.summary = summary


class LiveFixes:
    def __init__(self, store, vocabulary, settings):
        self.store = store
        self.vocabulary = vocabulary
        self.settings = settings
        self.on_change = None
        self._gate = threading.RLock()
        self._refused: set = set()
        self._refusals: dict = {}
        self._deferred: set = set()
        self._undo: list = []
        self.toast = None

    def meeting_started(self) -> None:
        with self._gate:
            self._refused, self._deferred, self._undo = set(), set(), []

    def _changed(self) -> None:
        if self.on_change is not None:
            self.on_change()

    def context(self, text: str) -> FixContext | None:
        if not self.settings.fixMisheard:
            return None
        ctx = FixContext(self.vocabulary.prompt_lines())
        hit = self.store.line_heard(text)
        s = self.store.get(hit[0]) if hit else None
        if s is not None:
            ctx.topic = s.notes.title if s.notes and s.notes.title else (s.title if s.renamed else None)
            ctx.summary = s.notes.summary if s.notes and s.notes.summary else None
            lines = self.store.lines(s.id)
            i = next((k for k, l in enumerate(lines) if l.id == hit[1].id), None)
            if i is not None:
                ctx.recent = [l.shown for l in lines[max(0, i - 3):i]]
                ctx.following = [l.shown for l in lines[i + 1:i + 4]]
        return ctx

    def received(self, text: str, edits: list) -> None:
        if not self.settings.fixMisheard:
            return
        hit = self.store.line_heard(text)
        if hit is None:
            return
        sid, line = hit
        with self._gate:
            fresh = []
            for e in edits:
                verdict = correction.decide(e, self.vocabulary.knows, lambda a, b: _pair(a, b) in self._refused)
                Log.d("fix %s c=%.2f line=%s" % (verdict, e.confidence, line.id))
                if verdict == correction.APPLY:
                    fresh.append(LineFix(e.from_, e.to))
                    self.vocabulary.used(correction.core(e.from_, e.to)[1])
                elif verdict == correction.ASK and self.settings.askNames:
                    fresh.append(LineFix(e.from_, e.to, ask=True))
            before = line.fixes or []
            fixes = self._known(line.src, correction.merge(before, fresh))
            dropped = sum(1 for f in before if f.applied and f.user is not True and f not in fixes)
            if dropped:
                Log.d("fix recheck took back %d line=%s" % (dropped, line.id))
            self._set(fixes, line.id, sid)

    def apply_known(self, line_id: str, sid: str) -> None:
        if not self.settings.fixMisheard:
            return
        with self._gate:
            l = self.store.line(sid, line_id)
            if l is not None:
                self._set(self._known(l.src, l.fixes or []), line_id, sid)

    def _known(self, src: str, fixes: list) -> list:
        out = list(fixes)
        for t in self.vocabulary.snapshot():
            for h in t.heard:
                if len(h) < 2 or correction.word(h, src) < 0 or _pair(h, t.word) in self._refused \
                        or (t.source != "user" and correction.translation(h, t.word)) or self.vocabulary.owners(h, t.word):
                    continue
                if any(f.from_ == h or (f.applied and h in f.from_) or (f.off is True and f.from_ == h) for f in out):
                    continue
                out.append(LineFix(h, t.word))
        return out

    def _set(self, fixes: list, line_id: str, sid: str) -> None:
        l = self.store.line(sid, line_id)
        if l is None or fixes == (l.fixes or []):
            return
        self.store.set_fixes(sid, line_id, fixes)
        self._changed()

    def pending(self, sid: str) -> list:
        seen, out = set(), []
        for l in self.store.lines(sid):
            for f in l.fixes or []:
                if f.ask is True and _key(f) not in seen:
                    seen.add(_key(f))
                    out.append((l, f))
        return out

    def asking(self, sid: str):
        with self._gate:
            open_ = [p for p in self.pending(sid) if _key(p[1]) not in self._deferred]
        if not open_:
            return None
        return open_[0][0], open_[0][1], 1, min(len(open_), ASK_AT_ONCE)

    def later(self, fix: LineFix, sid: str) -> None:
        with self._gate:
            self._remember(sid, [])
            self._deferred.add(_key(fix))
        self._say(L("已收进人名和术语，稍后再看"))

    def answer(self, fix: LineFix, yes: bool, sid: str) -> None:
        c = correction.core(fix.from_, fix.to)
        with self._gate:
            touched = [l for l in self.store.lines(sid)
                       if any(f.ask is True and correction.core(f.from_, f.to) == c for f in l.fixes or [])]
            ids = {l.id for l in touched}
            others = [l for l in self.store.lines(sid) if c[0] in l.src and l.id not in ids] if yes else []
            self._remember(sid, [l.id for l in touched + others])
            for l in touched:
                fixes = [f.copy() for f in l.fixes]
                for f in fixes:
                    if f.ask is True and correction.core(f.from_, f.to) == c:
                        f.ask = None
                        if yes:
                            f.user = True
                        else:
                            f.off = True
                self._set(fixes, l.id, sid)
            if yes:
                self.vocabulary.confirm(c[0], c[1])
                for l in others:
                    self.apply_known(l.id, sid)
            else:
                self._refused.add(_pair(*c))
        Log.d("fix answered %s" % ("yes" if yes else "no"))
        self._say(LF("已改 %@ → %@，记进词表", c[0], c[1]) if yes else LF("这场不再问 %@", c[0]))

    def revert(self, fix: LineFix, line_id: str, sid: str) -> None:
        with self._gate:
            l = self.store.line(sid, line_id)
            if l is None or not l.fixes:
                return
            same = [i for i, f in enumerate(l.fixes) if f.from_ == fix.from_ and f.to == fix.to]
            k = next((i for i in same if l.fixes[i].applied), same[0] if same else None)
            if k is None:
                return
            self._remember(sid, [line_id])
            fixes = [f.copy() for f in l.fixes]
            fixes[k].off, fixes[k].ask, fixes[k].user = True, None, None
            self._set(fixes, line_id, sid)
            c = correction.core(fix.from_, fix.to)
            self._refused.add(_pair(*c))
            self._refused.add(_pair(fix.from_, fix.to))
            n = self._refusals.get(_pair(*c), 0) + 1
            self._refusals[_pair(*c)] = n
            if n >= 2:
                self.vocabulary.forget(c[0], c[1])
        Log.d("fix reverted line=%s" % line_id)
        self._say(LF("已改回 %@，这场不再改", correction.label(fix)[0]))

    def same_heard(self, line_id: str, sid: str, edited: str):
        l = self.store.line(sid, line_id)
        if l is None:
            return None
        e = correction.user_edit(l.shown, edited, l.src, l.fixes or [])
        if e is None:
            return None
        n = sum(1 for x in self.store.lines(sid) if e[0].from_ in x.shown) if e[2] else 1
        return e[1], max(1, n), e[2]

    def edit(self, line_id: str, sid: str, edited: str, everywhere: bool, remember: bool) -> int:
        with self._gate:
            l = self.store.line(sid, line_id)
            e = correction.user_edit(l.shown, edited, l.src, l.fixes or []) if l else None
            if e is None:
                return 0
            fix, heard, swap = e
            everywhere = everywhere and swap
            targets = [x for x in self.store.lines(sid) if fix.from_ in x.shown] if everywhere else [l]
            self._remember(sid, [t.id for t in targets])
            for t in targets:
                fixes = []
                for f in t.fixes or []:
                    if f.from_ == fix.from_ and f.to == fix.to:
                        continue
                    f = f.copy()
                    if f.ask is True and (heard in f.from_ or f.from_ in heard):
                        f.ask, f.off = None, True
                    fixes.append(f)
                self._set(fixes + [fix.copy()], t.id, sid)
            word = correction.core(fix.from_, fix.to)[1].strip()
            learned = remember and everywhere and learnable(heard, word) is not None
            if learned:
                self.vocabulary.confirm(heard, word, source="user")
        Log.d("fix edited lines=%d learned=%s" % (len(targets), learned))
        a, b = (heard, word) if swap else (fix.from_, fix.to)
        self._say(LF("已改 %lld 处：%@ → %@，记进词表", len(targets), a, b) if learned
                  else LF("已改 %lld 处：%@ → %@", len(targets), a, b))
        return len(targets)

    def _remember(self, sid: str, line_ids: list) -> None:
        lines = {l.id: l for l in self.store.lines(sid)}
        before = {i: [f.copy() for f in (lines[i].fixes or [])] for i in line_ids if i in lines}
        self._undo.append((sid, before, self.vocabulary.snapshot(), set(self._refused), set(self._deferred)))
        del self._undo[:-20]

    @property
    def can_undo(self) -> bool:
        return bool(self._undo)

    def undo(self) -> None:
        with self._gate:
            if not self._undo:
                return
            sid, lines, words, refused, deferred = self._undo.pop()
            for lid, fixes in lines.items():
                self.store.set_fixes(sid, lid, fixes)
            self.vocabulary.restore(words)
            self._refused, self._deferred = refused, deferred
            self.toast = None
        Log.d("fix undone")
        self._changed()

    def _say(self, text: str) -> None:
        self.toast = (text, time.monotonic())
        self._changed()

    def toast_text(self) -> str | None:
        t = self.toast
        return t[0] if t and time.monotonic() - t[1] < TOAST_SECONDS else None


def fixed_words(lines: list) -> list:
    out: dict = {}
    for l in lines:
        for f in l.fixes or []:
            if f.applied:
                cf, ct = correction.label(f)
                word = ct.strip()
                heard, n = out.get(word, ([], 0))
                if cf not in heard:
                    heard.append(cf)
                out[word] = (heard, n + 1)
    return sorted(((w, h, n) for w, (h, n) in out.items()), key=lambda x: -x[2])


__all__ = ["LiveFixes", "FixContext", "Edit", "fixed_words", "ASK_AT_ONCE"]
