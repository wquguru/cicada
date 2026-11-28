package cicada

data class VoiceOption(val id: String, val name: String, val tags: List<String>)

object VoiceCatalog {
    const val PHONE = "phone"
    const val CLONE = "clone"
    const val MING = "ming:"
    const val CLOUD = "cloud:"

    val languages = listOf("en" to "English", "zh" to "中文", "ja" to "日本語", "ko" to "한국어",
                           "es" to "Español", "fr" to "Français", "de" to "Deutsch", "pt" to "Português")

    fun key(code: String): String = code.substringBefore('-').ifEmpty { "en" }

    fun title(code: String): String = languages.firstOrNull { it.first == key(code) }?.second ?: code

    fun mingLanguage(code: String): String? = key(code).takeIf { it in listOf("ja", "ko", "de", "fr", "es") }

    fun ming(language: String): List<VoiceOption> {
        fun v(voice: String, name: String, vararg tags: String) = VoiceOption(MING + voice, name, tags.toList())
        return when (key(language)) {
            "en" -> listOf(v("US_Emma", "Emma", "女", "美式", "自然对话"), v("UK_George", "George", "男", "英式", "稳重"),
                           v("UK_Charlotte", "Charlotte", "女", "英式", "平稳"))
            "zh" -> listOf(v("灵小雅", "小雅", "女", "清亮", "播报"), v("灵小棠", "小棠", "女", "温和", "沉稳"),
                           v("灵小锋", "小锋", "男", "温暖", "亲切"), v("灵卓然", "卓然", "男", "沉着", "清楚"))
            "ja", "ko", "de", "fr", "es" -> listOf(v("US_Emma", "Emma", "女"), v("UK_George", "George", "男"))
            else -> emptyList()
        }
    }

    fun remote(language: String, config: AIConfig): List<VoiceOption> = when {
        !config.hasVoices -> emptyList()
        config.isLing -> ming(language)
        else -> config.voices.map { VoiceOption(CLOUD + it.id, it.id, listOf(it.gender).filter { g -> g.isNotEmpty() }) }
    }

    val phone = VoiceOption(PHONE, "手机的声音", listOf("本机"))
    val clone = VoiceOption(CLONE, "我自己的声音", emptyList())

    fun options(language: String, config: AIConfig): List<VoiceOption> = remote(language, config) + phone

    fun defaultId(language: String, config: AIConfig, speaks: Boolean): String =
        (if (speaks) remote(language, config).firstOrNull()?.id else null) ?: PHONE

    fun chosen(voices: Map<String, String>, language: String, config: AIConfig, speaks: Boolean, canClone: Boolean = false): String {
        val fallback = defaultId(language, config, speaks)
        val id = voices[key(language)] ?: return fallback
        return when {
            id == PHONE -> id
            id == CLONE -> if (canClone) id else fallback
            speaks && remote(language, config).any { it.id == id } -> id
            else -> fallback
        }
    }

    fun option(id: String, language: String, config: AIConfig): VoiceOption? =
        if (id == CLONE) clone else options(language, config).firstOrNull { it.id == id }

    fun sample(language: String): String = when (key(language)) {
        "zh" -> "谢谢大家。我们来看一下上线时间表，并确定谁负责麦克风测试。"
        "ja" -> "皆さん、ありがとうございます。発売スケジュールを確認しましょう。"
        "ko" -> "감사합니다. 출시 일정을 함께 확인해 보겠습니다."
        "es" -> "Gracias a todos. Revisemos el calendario de lanzamiento."
        "fr" -> "Merci à tous. Regardons ensemble le calendrier de lancement."
        "de" -> "Danke an alle. Schauen wir uns den Zeitplan für den Start an."
        "pt" -> "Obrigado a todos. Vamos ver o cronograma de lançamento."
        else -> "Thanks everyone. Let's look at the launch timeline and decide who owns the microphone tests."
    }
}
