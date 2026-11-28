from pathlib import Path as _Path


def _version() -> str:
    here = _Path(__file__).resolve().parent.parent
    for p in (here / "VERSION", here.parent / "VERSION"):
        try:
            return p.read_text(encoding="utf-8").strip()
        except OSError:
            pass
    return "0"


VERSION = _version()
