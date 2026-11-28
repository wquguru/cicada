from __future__ import annotations

import errno
import json
import os
import secrets
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta

from . import jsonfmt, session_store
from .models import iso_read, iso_write, now
from .support import Log, Paths

DENIED = "denied"
MISSING = "missing"
FAILED = "failed"

PROBE = ".cicada-check"

_BANNED = set('/\\:*?"<>|#^[]')


def name(s) -> str:
    renamed = s.renamed if s.renamed is not None else not s.title.startswith("会议 ")
    if renamed:
        return s.title
    if s.notes is not None and s.notes.title:
        return s.notes.title
    if s.sourceFile:
        return os.path.splitext(s.sourceFile)[0]
    return ""


def _trim(s: str) -> str:
    return s.strip(" .")


def safe_name(n: str) -> str:
    spaced = "".join(" " if c in _BANNED or ord(c) < 0x20 else c for c in n)
    out = _trim(" ".join(spaced.split()))
    if len(out.encode("utf-8")) > 120:
        cut, size = [], 0
        for c in out:
            size += len(c.encode("utf-8"))
            if size > 120:
                break
            cut.append(c)
        out = _trim("".join(cut))
    return out


def _local(at: datetime, tz=None) -> datetime:
    return at.astimezone(tz) if tz is not None else at.astimezone()


def _offset(at: datetime) -> str:
    off = at.utcoffset() or timedelta(0)
    minutes = int(off.total_seconds()) // 60
    sign = "-" if minutes < 0 else "+"
    minutes = abs(minutes)
    return "%s%02d:%02d" % (sign, minutes // 60, minutes % 60)


def _stamp(at: datetime, tz=None) -> str:
    l = _local(at, tz)
    return l.strftime("%Y-%m-%dT%H:%M:%S") + _offset(l)


def stem(s, tz=None) -> str:
    date = _local(s.startedAt, tz).strftime("%Y-%m-%d %H%M")
    safe = safe_name(name(s))
    return "%s %s" % (date, safe) if safe else date


def file_name(st: str, taken) -> str:
    n = 1
    while True:
        candidate = "%s.md" % st if n == 1 else "%s %d.md" % (st, n)
        if not taken(candidate):
            return candidate
        n += 1


def quote(s: str) -> str:
    out = ['"']
    for c in s:
        if c == "\\":
            out.append("\\\\")
        elif c == '"':
            out.append('\\"')
        elif c == "\n":
            out.append("\\n")
        elif c == "\r":
            out.append("\\r")
        elif c == "\t":
            out.append("\\t")
        elif ord(c) < 0x20:
            out.append("\\u%04x" % ord(c))
        else:
            out.append(c)
    out.append('"')
    return "".join(out)


def frontmatter(s, tz=None) -> str:
    ended = s.endedAt or s.startedAt
    languages = sorted({l.srcLang for l in s.lines})
    notes = "none" if s.notes is None or s.notes.is_empty else ("final" if s.notes.final else "draft")
    minutes = max(0, int((ended - s.startedAt).total_seconds() // 60))
    return "".join([
        "---\n",
        "cicada: 1\n",
        "id: %s\n" % quote(s.id),
        "title: %s\n" % quote(name(s)),
        "started: %s\n" % quote(_stamp(s.startedAt, tz)),
        "ended: %s\n" % quote(_stamp(ended, tz)),
        "minutes: %d\n" % minutes,
        "languages: [%s]\n" % ", ".join(quote(x) for x in languages),
        "source: %s\n" % quote("meeting" if s.sourceFile is None else "file"),
        "notes: %s\n" % quote(notes),
        'tags: ["cicada"]\n',
        "---\n",
    ])


def document(s, voices: bool = False) -> str:
    return frontmatter(s) + session_store.markdown(s, voices=voices)


def obsidian_configs() -> list:
    config = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return [os.path.join(config, "obsidian", "obsidian.json"),
            os.path.expanduser("~/.var/app/md.obsidian.Obsidian/config/obsidian/obsidian.json")]


def obsidian_vaults(text: str, exists=os.path.isdir) -> list:
    try:
        root = json.loads(text)
    except (ValueError, TypeError):
        return []
    vaults = root.get("vaults") if isinstance(root, dict) else None
    if not isinstance(vaults, dict):
        return []
    found = []
    for v in vaults.values():
        path = v.get("path") if isinstance(v, dict) else None
        if not isinstance(path, str) or not exists(path):
            continue
        ts = v.get("ts")
        found.append((path, ts if isinstance(ts, (int, float)) and not isinstance(ts, bool) else 0))
    found.sort(key=lambda p: p[1], reverse=True)
    return [p for p, _ in found]


def all_vaults() -> list:
    out = []
    for f in obsidian_configs():
        try:
            with open(f, encoding="utf-8") as h:
                text = h.read()
        except OSError:
            continue
        out += [v for v in obsidian_vaults(text) if v not in out]
    return out


def vault_of(folder: str, vaults=None) -> str | None:
    for v in all_vaults() if vaults is None else vaults:
        v = v.rstrip("/") or "/"
        if folder == v or folder.startswith(v + "/"):
            return v
    return None


def documents_dir() -> str:
    home = os.path.expanduser("~")
    try:
        out = subprocess.run(["xdg-user-dir", "DOCUMENTS"], capture_output=True, text=True, timeout=2).stdout.strip()
        if out and os.path.normpath(out) != os.path.normpath(home):
            return out
    except (OSError, subprocess.SubprocessError):
        pass
    return os.path.join(home, "Documents")


def default_folder(vaults=None, documents: str | None = None) -> str:
    vaults = all_vaults() if vaults is None else vaults
    if vaults:
        return os.path.join(vaults[0], "Cicada")
    return os.path.join(documents or documents_dir(), "Cicada")


def short_path(folder: str) -> str:
    folder = os.path.normpath(folder)
    parent = os.path.dirname(folder)
    return "%s › %s" % (os.path.basename(parent) or parent, os.path.basename(folder) or folder)


def _classify(e: BaseException, folder: str) -> tuple:
    if isinstance(e, PermissionError) or getattr(e, "errno", None) in (errno.EACCES, errno.EPERM):
        return DENIED, ""
    if not os.path.isdir(folder):
        return MISSING, ""
    return FAILED, (getattr(e, "strerror", None) or str(e) or type(e).__name__)


def ensure(folder: str) -> tuple | None:
    if os.path.exists(folder):
        return None if os.path.isdir(folder) else (MISSING, "")
    if not os.path.isdir(os.path.dirname(os.path.normpath(folder))):
        return MISSING, ""
    try:
        os.mkdir(folder)
    except FileExistsError:
        pass
    except OSError as e:
        return _classify(e, folder)
    return None


def probe(folder: str) -> tuple | None:
    p = ensure(folder)
    if p is not None:
        return p
    path = os.path.join(folder, PROBE)
    try:
        with open(path, "wb"):
            pass
        os.remove(path)
        return None
    except OSError as e:
        return _classify(e, folder)


def write_atomic(path: str, data: bytes) -> None:
    folder = os.path.dirname(path)
    tmp = os.path.join(folder, ".cicada-%s.tmp" % secrets.token_hex(4))
    try:
        with open(tmp, "xb") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def write_jobs(jobs: list, folder: str, ours: dict) -> list:
    p = ensure(folder)
    if p is not None:
        return [("stopped",) + p]
    ours = dict(ours)
    out = []
    for sid, st, old, data in jobs:
        mine = {n for k, n in ours.items() if k != sid}

        def taken(candidate, old=old, mine=mine):
            if candidate == old:
                return False
            return candidate in mine or os.path.lexists(os.path.join(folder, candidate))
        n = file_name(st, taken)
        path = os.path.join(folder, n)
        if n == old:
            try:
                with open(path, "rb") as f:
                    if f.read() == data:
                        out.append(("unchanged", sid))
                        continue
            except OSError:
                pass
        try:
            write_atomic(path, data)
        except Exception as e:  # noqa: BLE001
            out.append(("stopped",) + _classify(e, folder))
            return out
        if old and old != n:
            try:
                os.remove(os.path.join(folder, old))
            except OSError:
                pass
        ours[sid] = n
        out.append(("wrote", sid, n))
    return out


class Index:
    def __init__(self, folder: str = "", files=None, pending=None, lastFile=None, lastAt=None):
        self.folder = folder
        self.files = dict(files or {})
        self.pending = list(pending or [])
        self.lastFile = lastFile
        self.lastAt = lastAt

    def to_json(self) -> dict:
        o = {"folder": self.folder, "files": self.files, "pending": self.pending}
        if self.lastFile is not None:
            o["lastFile"] = self.lastFile
        if self.lastAt is not None:
            o["lastAt"] = iso_write(self.lastAt)
        return o

    @staticmethod
    def read(text: str) -> "Index":
        o = jsonfmt.parse_object(text) or {}
        files = o.get("files") if isinstance(o.get("files"), dict) else {}
        pending = o.get("pending") if isinstance(o.get("pending"), list) else []
        return Index(folder=o.get("folder") if isinstance(o.get("folder"), str) else "",
                     files={k: v for k, v in files.items() if isinstance(v, str)},
                     pending=[x for x in pending if isinstance(x, str)],
                     lastFile=o.get("lastFile") if isinstance(o.get("lastFile"), str) else None,
                     lastAt=iso_read(o.get("lastAt") if isinstance(o.get("lastAt"), str) else None))


def index_path() -> str:
    return os.path.join(Paths.data(), "FolderExport.json")


class FolderExporter:
    def __init__(self, store, settings, index_file: str | None = None, delay: float = 2.0):
        self.store = store
        self.settings = settings
        self.index_file = index_file or index_path()
        self.delay = delay
        self.settling = lambda sid: False
        self.voices = lambda: False
        self.on_denied = None
        self.problem = None
        self.problem_message = ""
        self.checking = False
        self._gate = threading.RLock()
        self._work = ThreadPoolExecutor(max_workers=1, thread_name_prefix="FolderExport")
        self._timer = None
        self._notified = False
        self._listeners = []
        self.index = Index()
        try:
            with open(self.index_file, encoding="utf-8") as f:
                self.index = Index.read(f.read())
        except OSError:
            pass

    def on_change(self, listener) -> None:
        self._listeners.append(listener)

    def _changed(self) -> None:
        for l in list(self._listeners):
            l()

    @property
    def on(self) -> bool:
        return bool(self.settings.exportOn and self.settings.exportFolder)

    @property
    def folder(self) -> str | None:
        return self.settings.exportFolder or None

    def file(self, sid: str) -> str | None:
        with self._gate:
            if not self.on or self.index.folder != self.settings.exportFolder:
                return None
            n = self.index.files.get(sid)
        return os.path.join(self.settings.exportFolder, n) if n else None

    def is_pending(self, sid: str) -> bool:
        with self._gate:
            return self.on and sid in self.index.pending

    def ready(self, s) -> bool:
        return s.endedAt is not None and not s.importing and bool(s.lines) and s.id != self.store.live

    def unwritten(self) -> list:
        with self._gate:
            files, pending = set(self.index.files), set(self.index.pending)
        return [s for s in self.store.all() if self.ready(s) and s.id not in files and s.id not in pending]

    def ended(self, sid: str) -> None:
        if not self.on:
            return
        with self._gate:
            if sid not in self.index.pending:
                self.index.pending.append(sid)
            self._save()
        self._schedule()

    def saved(self, sid: str) -> None:
        if not self.on:
            return
        with self._gate:
            if sid not in self.index.files and sid not in self.index.pending:
                return
            if sid not in self.index.pending:
                self.index.pending.append(sid)
        self._schedule()

    def settled(self, sid: str) -> None:
        with self._gate:
            waiting = self.on and sid in self.index.pending
        if waiting:
            self._schedule()

    def write_all(self) -> None:
        if not self.on:
            return
        ids = [s.id for s in self.unwritten()]
        with self._gate:
            self.index.pending += [i for i in ids if i not in self.index.pending]
            self._save()
        self._submit(False)

    def retry(self) -> None:
        with self._gate:
            waiting = self.on and bool(self.index.pending)
        if waiting:
            self._schedule(0.5, from_meeting=False)

    def deleted(self, sid: str) -> None:
        with self._gate:
            self.index.files.pop(sid, None)
            if sid in self.index.pending:
                self.index.pending.remove(sid)
            self._save()

    def choose(self, folder: str) -> None:
        folder = os.path.normpath(os.path.expanduser(folder))
        self.settings.exportFolder = folder
        self.settings.exportOn = True
        self.settings.save()
        with self._gate:
            if self.index.folder != folder:
                self.index = Index(folder=folder)
            self._save()
            self.checking = True
            self.problem, self.problem_message = None, ""
        self._changed()

        def check():
            result = probe(folder)
            with self._gate:
                self.checking = False
                self.problem, self.problem_message = result or (None, "")
                if result is None:
                    self._notified = False
            Log.d("folder export: check %s" % (result[0] if result else "ok"))
            self._changed()
            if result is None:
                self.retry()
        self._work.submit(check)

    def turn_off(self) -> None:
        self.settings.exportOn = False
        self.settings.save()
        with self._gate:
            self.problem, self.problem_message = None, ""
        self._changed()

    def _schedule(self, delay: float | None = None, from_meeting: bool = True) -> None:
        with self._gate:
            if self._timer is not None:
                self._timer.cancel()
            t = threading.Timer(self.delay if delay is None else delay, self._submit, (from_meeting,))
            t.daemon = True
            t.from_meeting = from_meeting
            self._timer = t
            t.start()

    def _submit(self, from_meeting: bool) -> None:
        self._work.submit(self._flush, from_meeting)

    def wait(self) -> None:
        with self._gate:
            t, self._timer = self._timer, None
        if t is not None and t.is_alive():
            t.cancel()
            self._submit(t.from_meeting)
        self._work.submit(lambda: None).result()

    def _flush(self, from_meeting: bool) -> None:
        try:
            self._flush_now(from_meeting)
        except Exception as e:  # noqa: BLE001
            Log.d("folder export: flush failed %s" % type(e).__name__)

    def _flush_now(self, from_meeting: bool) -> None:
        if not self.on:
            return
        folder = self.settings.exportFolder
        jobs = []
        with self._gate:
            if self.index.folder != folder:
                self.index = Index(folder=folder, pending=self.index.pending)
            for sid in list(self.index.pending):
                s = self.store.snapshot(sid)
                if s is None:
                    self.index.pending.remove(sid)
                    continue
                if not self.ready(s) or self.settling(sid):
                    continue
                try:
                    jobs.append((sid, stem(s), self.index.files.get(sid), document(s, self.voices()).encode("utf-8")))
                except Exception as e:  # noqa: BLE001
                    Log.d("folder export: %s not rendered %s" % (sid, type(e).__name__))
            self._save()
            ours = dict(self.index.files)
        if not jobs:
            return
        outcomes = write_jobs(jobs, folder, ours)
        stopped = None
        with self._gate:
            if self.index.folder != folder:
                return
            for o in outcomes:
                if o[0] == "wrote":
                    self.index.files[o[1]] = o[2]
                    if o[1] in self.index.pending:
                        self.index.pending.remove(o[1])
                    self.index.lastFile, self.index.lastAt = o[2], now()
                elif o[0] == "unchanged":
                    if o[1] in self.index.pending:
                        self.index.pending.remove(o[1])
                else:
                    stopped = o
            self._save()
            self.problem, self.problem_message = (stopped[1], stopped[2]) if stopped else (None, "")
            notify = False
            if stopped is None:
                self._notified = False
            elif stopped[1] == DENIED and from_meeting and not self._notified:
                self._notified = notify = True
        Log.d("folder export: %d written, %s" % (sum(1 for o in outcomes if o[0] == "wrote"), stopped[1] if stopped else "ok"))
        self._changed()
        if notify and self.on_denied is not None:
            self.on_denied()

    def _save(self) -> None:
        try:
            os.makedirs(os.path.dirname(self.index_file), exist_ok=True)
            write_atomic(self.index_file, jsonfmt.write(self.index.to_json()).encode("utf-8"))
        except OSError as e:
            Log.d("folder export: index not saved %s" % type(e).__name__)

    def state(self) -> dict:
        with self._gate:
            return {"on": self.on, "folder": self.folder, "problem": self.problem, "message": self.problem_message,
                    "checking": self.checking, "index": self.index.to_json(), "unwritten": [s.id for s in self.unwritten()]}
