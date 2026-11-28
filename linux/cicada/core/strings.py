from __future__ import annotations

import os
import plistlib

_table: dict = {}
_plurals: dict = {}
language = "zh-Hans"


def load(ui: str, folders: list) -> None:
    global _table, _plurals, language
    head = ui.replace("_", "-").split("-")[0]
    language = head if head in ("en", "ja", "ko") else "zh-Hans"
    t: dict = {}
    for folder in folders:
        for name in ("Localizable.strings", "Linux.strings"):
            path = os.path.join(folder, language + ".lproj", name)
            if os.path.isfile(path):
                with open(path, encoding="utf-8") as f:
                    t.update(parse(f.read()))
    _table = t
    _plurals = {}
    for folder in folders:
        path = os.path.join(folder, language + ".lproj", "Localizable.stringsdict")
        if os.path.isfile(path):
            with open(path, "rb") as f:
                _plurals.update(parse_plurals(f.read()))


def parse_plurals(data: bytes) -> dict:
    d = plistlib.loads(data)
    return {k: v for k, v in d.items() if isinstance(v, dict) and isinstance(v.get("NSStringLocalizedFormatKey"), str)}


def _category(n) -> str:
    return "one" if language == "en" and isinstance(n, (int, float)) and n == 1 else "other"


def L(key: str) -> str:
    v = _table.get(key)
    return v if v else key


def LF(key: str, *args) -> str:
    plural = _plurals.get(key)
    text = plural["NSStringLocalizedFormatKey"] if plural else L(key)
    out = []
    nxt = 0
    i = 0
    while i < len(text):
        if plural and text[i] == "%":
            j, pos = i + 1, None
            if j + 1 < len(text) and text[j].isdigit() and text[j + 1] == "$":
                pos, j = int(text[j]) - 1, j + 2
            end = text.find("@", j + 2) if text.startswith("#@", j) else -1
            if end > 0:
                if pos is None:
                    pos, nxt = nxt, nxt + 1
                n = args[pos] if 0 <= pos < len(args) else ""
                forms = plural.get(text[j + 2:end]) or {}
                form = forms.get(_category(n)) or forms.get("other", "")
                out.append(form.replace("%lld", str(n)).replace("%ld", str(n)).replace("%d", str(n)))
                i = end + 1
                continue
        if text.startswith("%%", i):
            out.append("%")
            i += 2
            continue
        m = next((t for t in ("%@", "%lld", "%d") if text.startswith(t, i)), None)
        if m:
            out.append(str(args[nxt]) if nxt < len(args) else "")
            nxt += 1
            i += len(m)
            continue
        if text[i] == "%" and i + 3 < len(text) and text[i + 1].isdigit() and text[i + 2] == "$":
            spec = next((t for t in ("@", "lld", "d") if text.startswith(t, i + 3)), None)
            if spec:
                n = int(text[i + 1]) - 1
                out.append(str(args[n]) if 0 <= n < len(args) else "")
                i += 3 + len(spec)
                continue
        out.append(text[i])
        i += 1
    return "".join(out)


def parse(text: str) -> dict:
    result = {}
    i = 0
    n = len(text)

    def read():
        nonlocal i
        while i < n:
            if text[i] == '"':
                break
            if text.startswith("/*", i):
                e = text.find("*/", i + 2)
                i = n if e < 0 else e + 2
                continue
            if text.startswith("//", i):
                e = text.find("\n", i)
                i = n if e < 0 else e + 1
                continue
            i += 1
        if i >= n:
            return None
        i += 1
        b = []
        while i < n and text[i] != '"':
            if text[i] == "\\" and i + 1 < n:
                i += 1
                b.append({"n": "\n", "t": "\t"}.get(text[i], text[i]))
            else:
                b.append(text[i])
            i += 1
        i += 1
        return "".join(b)

    while True:
        k = read()
        if k is None:
            break
        v = read()
        if v is None:
            break
        result[k] = v
    return result
