from __future__ import annotations


def key(code: str) -> str:
    return (code or "en").split("-")[0].lower() or "en"


def ming_language(code: str, config=None) -> str | None:
    if config is not None and not config.is_ling:
        return None
    k = key(code)
    return k if k in ("ja", "ko", "de", "fr", "es") else None


_CATALOG = {
    "en": [("US_Emma", "Emma", ["女", "美式", "自然对话"]), ("UK_George", "George", ["男", "英式", "稳重"]),
           ("UK_Charlotte", "Charlotte", ["女", "英式", "平稳"])],
    "zh": [("灵小雅", "小雅", ["女", "清亮", "播报"]), ("灵小棠", "小棠", ["女", "温和", "沉稳"]),
           ("灵小锋", "小锋", ["男", "温暖", "亲切"]), ("灵卓然", "卓然", ["男", "沉着", "清楚"])],
}
_OTHER = [("US_Emma", "Emma", ["女"]), ("UK_George", "George", ["男"])]

ROOM_LANGUAGES = ["en", "zh-CN", "zh-TW", "ja", "ko", "es", "fr", "de"]


def voices(code: str, config=None) -> list:
    if config is not None and not config.is_ling:
        return [(v.id, v.id, [v.gender] if v.gender else []) for v in config.voices]
    k = key(code)
    if k in _CATALOG:
        return _CATALOG[k]
    return _OTHER if k in ("ja", "ko", "de", "fr", "es") else []


def default_voice(code: str, config=None) -> str | None:
    v = voices(code, config)
    return v[0][0] if v else None


CLONE = "clone"


def clones(config) -> bool:
    return config is None or bool(getattr(config.provider, "clones", False))


def chosen(choice: str | None, code: str, config=None, has_reference: bool = False) -> str | None:
    if choice == CLONE:
        return CLONE if has_reference and clones(config) else default_voice(code, config)
    names = [v for v, _n, _t in voices(code, config)]
    return choice if choice in names else default_voice(code, config)


def sample(code: str) -> str:
    return {
        "zh": "谢谢大家。我们来看一下上线时间表，并确定谁负责麦克风测试。",
        "ja": "皆さん、ありがとうございます。発売スケジュールを確認しましょう。",
        "ko": "감사합니다. 출시 일정을 함께 확인해 보겠습니다.",
        "es": "Gracias a todos. Revisemos el calendario de lanzamiento.",
        "fr": "Merci à tous. Regardons ensemble le calendrier de lancement.",
        "de": "Danke an alle. Schauen wir uns den Zeitplan für den Start an.",
        "pt": "Obrigado a todos. Vamos ver o cronograma de lançamento.",
    }.get(key(code), "Thanks everyone. Let's look at the launch timeline and decide who owns the microphone tests.")
