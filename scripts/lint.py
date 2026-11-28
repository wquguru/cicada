#!/usr/bin/env python3
"""Usage: lint.py [--staged] [--update-baseline]

--staged: only the files about to be committed, and no Swift build (the pre-commit hook).
--update-baseline: accept today's compiler and shellcheck warnings into scripts/lint-baseline.txt."""
import collections, re, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "scripts/lint-baseline.txt"
ANSI = re.compile(r"\x1b\[[0-9;]*m|\x1b\]8;;[^\x1b]*\x1b\\")


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split("\n")


def files(staged):
    names = git("diff", "--cached", "--name-only", "--diff-filter=ACMR") if staged else git("ls-files")
    return [n for n in names if n and (ROOT / n).is_file()]


def is_shell(name):
    p = ROOT / name
    if p.suffix == ".sh":
        return True
    if p.suffix:
        return False
    head = p.read_bytes()[:64].split(b"\n", 1)[0]
    return head.startswith(b"#!") and b"sh" in head and b"python" not in head


def shellcheck(names):
    if not names or not shutil.which("shellcheck"):
        return []
    out = subprocess.run(["shellcheck", "-S", "warning", "-f", "gcc", *names], cwd=ROOT,
                         capture_output=True, text=True).stdout
    return [re.sub(r":\d+:\d+:", ":", line) for line in out.splitlines() if line]


def swift_warnings():
    for d in ("Sources/Cicada", "Sources/CicadaIcon"):
        for f in (ROOT / d).glob("*.swift"):
            f.touch()
    out = subprocess.run(["swift", "build", "--build-path", ".build/lint"], cwd=ROOT,
                         capture_output=True, text=True)
    text = ANSI.sub("", out.stdout + out.stderr)
    if out.returncode:
        print(text[-4000:], file=sys.stderr)
        sys.exit("lint: swift build failed")
    found = set()
    for m in re.finditer(r"^(/\S+?):\d+:\d+: warning: (.+?)(?: \[#\w+\])?$", text, re.M):
        found.add(f"{Path(m.group(1)).relative_to(ROOT)}: warning: {m.group(2)}")
    return sorted(found)


def main():
    if set(sys.argv[1:]) - {"--staged", "--update-baseline"}:
        sys.exit(__doc__)
    staged = "--staged" in sys.argv
    if staged and "--update-baseline" in sys.argv:
        sys.exit("lint: --update-baseline needs the full run")
    names = files(staged)
    errors = []

    if not staged or "AGENTS.md" in names:
        if subprocess.run([sys.executable, "scripts/check-agents.py"], cwd=ROOT).returncode:
            errors.append("AGENTS.md")

    source = [n for n in names if Path(n).suffix in (".swift", ".kt", ".kts", ".cs", ".c", ".h", ".js", ".mjs", ".py", ".ps1", ".html", ".css") or is_shell(n)]
    source = [n for n in source if not n.startswith("docs/")]
    if source and subprocess.run([sys.executable, "scripts/comments.py", "check", *source], cwd=ROOT).returncode:
        errors.append("comments")

    for n in names:
        if n.endswith(".py"):
            try:
                compile((ROOT / n).read_bytes(), n, "exec")
            except SyntaxError as e:
                print(f"{n}:{e.lineno}: {e.msg}", file=sys.stderr)
                errors.append(n)
        elif n.endswith((".js", ".mjs")) and shutil.which("node"):
            if subprocess.run(["node", "--check", n], cwd=ROOT).returncode:
                errors.append(n)
    shells = [n for n in names if is_shell(n)]
    for n in shells:
        if subprocess.run(["bash", "-n", n], cwd=ROOT).returncode:
            errors.append(n)

    warnings = shellcheck(shells)
    if not staged:
        warnings += swift_warnings()
    if "--update-baseline" in sys.argv:
        BASELINE.write_text("".join(w + "\n" for w in sorted(warnings)), encoding="utf-8")
        print(f"lint: {len(warnings)} warnings in the baseline")
    else:
        known = collections.Counter(BASELINE.read_text(encoding="utf-8").splitlines()) if BASELINE.exists() else collections.Counter()
        new = collections.Counter(warnings) - known
        for w in sorted(new.elements()):
            print(w, file=sys.stderr)
        if new:
            errors.append(f"{sum(new.values())} new warnings (fix them; scripts/lint.py --update-baseline only for ones that must stay)")

    if errors:
        sys.exit("lint failed: " + ", ".join(errors))
    print("lint ok")


if __name__ == "__main__":
    main()
