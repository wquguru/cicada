from __future__ import annotations

import os

from . import jsonfmt
from .support import Log, Paths, follow_system_target, my_language, system_language, system_languages

DEFAULT_MODEL = "Ling-3.1-flash"


class AppSettings:
    FIELDS = {
        "target": "system",
        "notesLanguage": "mine",
        "model": DEFAULT_MODEL,
        "aiProvider": "ling",
        "aiModels": {},
        "aiHearModels": {},
        "aiVoiceModels": {},
        "aiCustomBase": "",
        "aiCustomVoiceBase": "",
        "aiCustomVoice": "",
        "aiCustomHearBase": "",
        "aiCustomNotesOwn": False,
        "aiCustomNotesBase": "",
        "aiCustomOnly": False,
        "view": "notes",
        "showInCapture": False,
        "onboarded": False,
        "heardSystemAudio": False,
        "sampleSeen": False,
        "speakLater": False,
        "trayHintShown": False,
        "showInDock": True,
        "uiLanguage": "system",
        "recordAudio": True,
        "exportOn": False,
        "exportFolder": "",
        "fixMisheard": True,
        "askNames": True,
        "speakerVoices": True,
        "speakEnabled": False,
        "speakFrom": "system",
        "speakTo": "room",
        "speakVoices": {},
        "speakHeadphones": False,
        "listenSource": "system",
        "roomMic": "",
        "endWithApp": True,
        "silenceEnd": "prompt",
        "silenceMinutes": 10,
    }

    SOURCES = ("system", "room", "both")

    def __init__(self, **kw):
        for k, v in self.FIELDS.items():
            v = kw.get(k, v)
            setattr(self, k, dict(v) if isinstance(v, dict) else v)

    @property
    def target_code(self) -> str:
        return my_language(system_languages()) if self.target == "system" else self.target

    def resolved_target(self, source: str | None) -> str:
        return follow_system_target(source, system_languages()) if self.target == "system" else self.target

    def ai_config(self):
        from .providers import config_from
        return config_from(self)

    def notes_code(self, choice: str | None = None, meeting: str | None = None) -> str:
        return meeting if (choice or self.notesLanguage) == "source" and meeting else self.target_code

    @property
    def google_off(self) -> bool:
        return self.aiProvider == "custom" and self.aiCustomOnly

    @property
    def hears_room(self) -> bool:
        return self.listenSource != "system"

    @property
    def speak_from_code(self) -> str:
        return self.target_code if self.speakFrom == "system" else self.speakFrom

    @property
    def ui_code(self) -> str:
        return system_language() if self.uiLanguage == "system" else self.uiLanguage

    def to_json(self) -> dict:
        return {k: getattr(self, k) for k in self.FIELDS}

    def save(self) -> None:
        try:
            os.makedirs(Paths.config(), exist_ok=True)
            with open(Paths.settings(), "w", encoding="utf-8") as f:
                f.write(jsonfmt.write(self.to_json()))
        except OSError as e:
            Log.d("settings: save failed %s" % type(e).__name__)

    @staticmethod
    def load() -> "AppSettings":
        try:
            if os.path.isfile(Paths.settings()):
                with open(Paths.settings(), encoding="utf-8") as f:
                    o = jsonfmt.parse_object(f.read())
                if o is not None:
                    kw = {k: o[k] for k, d in AppSettings.FIELDS.items() if k in o and type(o[k]) is type(d)}
                    if kw.get("notesLanguage") not in (None, "mine", "source"):
                        kw["notesLanguage"] = "mine"
                    kw.pop("listenSource", None)
                    return AppSettings(**kw)
        except OSError as e:
            Log.d("settings: unreadable, defaults used (%s)" % type(e).__name__)
        return AppSettings()
