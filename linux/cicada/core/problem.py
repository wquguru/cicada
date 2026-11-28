from __future__ import annotations

from . import aicheck
from .strings import L, LF

BLOCKING = (aicheck.INVALID_KEY, aicheck.MGMT_KEY, aicheck.NO_CREDIT, aicheck.NO_MODEL,
            aicheck.BAD_ADDRESS, aicheck.NO_JSON, aicheck.DEAF)
NOTES_ONLY = (aicheck.NO_MODEL, aicheck.NO_JSON)
UNREACHABLE_AFTER = 120.0


def blocking(reason: str | None) -> bool:
    return reason in BLOCKING


def stops_hearing(reason: str | None) -> bool:
    return blocking(reason) and reason not in NOTES_ONLY


def title(reason: str | None, service: str, text_model: str, hear_model: str) -> str | None:
    if not blocking(reason):
        return None
    return {aicheck.INVALID_KEY: lambda: LF("%@ 的 key 用不了", service),
            aicheck.MGMT_KEY: lambda: LF("%@ 的 key 用不了", service),
            aicheck.NO_CREDIT: lambda: LF("%@ 账户余额不足。", service),
            aicheck.NO_MODEL: lambda: LF("%@ 上找不到 %@ 这个模型。", service, text_model),
            aicheck.DEAF: lambda: LF("%@ 听不了声音。", hear_model or service)}.get(reason, lambda: L("AI 服务的设置要改一下"))()


class Notices:
    def __init__(self, wait: float = UNREACHABLE_AFTER):
        self.wait = wait
        self.sent: set = set()
        self.since: float | None = None

    def start(self) -> None:
        self.sent = set()
        self.since = None

    def tick(self, now: float, listening: bool, reason: str | None, shown: bool) -> str | None:
        if reason == aicheck.UNREACHABLE and listening:
            if self.since is None:
                self.since = now
        else:
            self.since = None
        if not listening or shown:
            return None
        if blocking(reason):
            kind = "blocking"
        elif self.since is not None and now - self.since >= self.wait:
            kind = "unreachable"
        else:
            return None
        if kind in self.sent:
            return None
        self.sent.add(kind)
        return kind
