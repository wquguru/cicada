#!/usr/bin/env python3
import datetime
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "https://github.com/wquguru/cicada"
SUBJECT = re.compile(r"^(feat|fix|perf)(?:\(([^)]*)\))?!?: (.+)$")


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def commits():
    try:
        since = git("describe", "--tags", "--abbrev=0") + "..HEAD"
    except subprocess.CalledProcessError:
        since = "HEAD"
    out = git("log", "--reverse", "--format=%H%x09%s", since)
    entries = [line.split("\t", 1) for line in out.splitlines() if line]
    bodies = git("log", "--format=%B", since)
    gone = re.findall(r"\b[Rr]everts (?:commit )?([0-9a-f]{7,40})\b", bodies)
    return [(sha, subject) for sha, subject in entries if not any(sha.startswith(g) for g in gone)]


PLATFORMS = {"mac": "Mac", "windows": "Windows", "android": "Android", "linux": "Linux", "site": "Website"}
UNSHIPPED = {"ios"}


def platforms(scope):
    scopes = re.split(r"[,\s]+", scope or "")
    names = [PLATFORMS[s] for s in scopes if s in PLATFORMS]
    if not names and any(s in UNSHIPPED for s in scopes):
        return []
    return names or ["Mac"]


def section(version, summary, entries=None):
    groups = {name: {"New": [], "Fixed": []} for name in PLATFORMS.values()}
    for sha, subject in commits() if entries is None else entries:
        m = SUBJECT.match(subject)
        if not m:
            continue
        kind, scope, text = m.groups()
        line = f"- {text[0].upper() + text[1:]} ([{sha[:7]}]({REPO}/commit/{sha}))"
        for name in platforms(scope):
            groups[name]["New" if kind == "feat" else "Fixed"].append(line)
    lines = [f"## {version} — {datetime.date.today().isoformat()}", ""]
    if summary:
        lines += [summary, ""]
    for name, kinds in groups.items():
        if not any(kinds.values()):
            if name != "Website":
                lines += [f"### {name}", "", "No changes; released to keep every platform on the same version.", ""]
            continue
        lines += [f"### {name}", ""]
        if name == "Website":
            lines += [*kinds["New"], *kinds["Fixed"], ""]
            continue
        for kind, items in kinds.items():
            if items:
                lines += [f"#### {kind}", "", *items, ""]
    return "\n".join(lines)


def main():
    if len(sys.argv) < 2 or not re.fullmatch(r"\d+\.\d+\.\d+", sys.argv[1]):
        sys.exit("usage: scripts/changelog.py <x.y.z> [--print]")
    version = sys.argv[1]
    path = os.path.join(ROOT, "CHANGELOG.md")
    text = open(path, encoding="utf-8").read()
    m = re.search(r"^## Unreleased\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    summary = m.group(1).strip() if m else ""
    if not m:
        m = re.search(rf"^## {re.escape(version)} — .*?\n(.*?)(?=^## |\Z)", text, re.M | re.S)
        summary = m.group(1).split("\n### ", 1)[0].strip() if m else ""
    new = section(version, summary)
    if "--print" in sys.argv:
        print(new)
        return
    if m:
        text = text[:m.start()] + new + "\n" + text[m.end():]
    else:
        first = re.search(r"^## ", text, re.M)
        at = first.start() if first else len(text)
        text = text[:at] + new + "\n" + text[at:]
    open(path, "w", encoding="utf-8").write(text)


if __name__ == "__main__":
    main()
