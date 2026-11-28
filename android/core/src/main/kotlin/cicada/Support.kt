package cicada

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object Paths {
    @Volatile var root: File = File(System.getenv("CICADA_HOME") ?: (System.getProperty("java.io.tmpdir") + "/cicada-cli"))
    @Volatile var log: File = File(System.getProperty("java.io.tmpdir"), "cicada-debug.log")
    val sessions get() = File(root, "Sessions")
    val settings get() = File(root, "settings.json")
    val vocabulary get() = File(root, "vocabulary.json")
    val keyFile get() = keyFile("ling")
    fun keyFile(service: String) = File(root, if (service == "ling") "ling-api-key" else "ai-key-$service")
}

object Log {
    private val gate = Any()
    @Volatile var echo = false
    @Volatile var sink: ((String) -> Unit)? = null
    private val clock = object : ThreadLocal<SimpleDateFormat>() {
        override fun initialValue() = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    }

    fun d(message: String) {
        val line = "${clock.get()!!.format(Date())} $message"
        synchronized(gate) {
            try { Paths.log.appendText(line + "\n") } catch (_: Exception) {}
            if (echo) System.err.println(line)
        }
        sink?.invoke(message)
    }
}

data class Lang(val name: String, val code: String)

object Languages {
    val sources = listOf(
        Lang("English", "en"), Lang("日本語", "ja"), Lang("中文", "zh-CN"), Lang("한국어", "ko"),
        Lang("Español", "es"), Lang("Français", "fr"), Lang("Deutsch", "de"), Lang("Português", "pt"),
    )

    val targets = listOf(
        Lang("简体中文", "zh-CN"), Lang("繁體中文", "zh-TW"), Lang("English", "en"), Lang("日本語", "ja"),
        Lang("한국어", "ko"), Lang("Español", "es"), Lang("Français", "fr"), Lang("Deutsch", "de"), Lang("Português", "pt"),
    )

    fun englishName(code: String): String = when (code) {
        "zh-CN" -> "Simplified Chinese"
        "zh-TW" -> "Traditional Chinese"
        else -> Locale.forLanguageTag(code).getDisplayLanguage(Locale.ENGLISH).ifEmpty { code }
    }

    fun fromSystem(tag: String): String {
        val parts = tag.split('-', '_')
        if (parts[0] != "zh") return parts[0]
        if ("Hant" in parts) return "zh-TW"
        if ("Hans" in parts) return "zh-CN"
        return if (parts.any { it in setOf("TW", "HK", "MO") }) "zh-TW" else "zh-CN"
    }

    fun myLanguage(prefs: List<String>): String = fromSystem(prefs.firstOrNull { it.startsWith("zh") } ?: prefs.firstOrNull() ?: "zh-Hans")

    fun followSystemTarget(source: String?, prefs: List<String>): String {
        val mine = myLanguage(prefs)
        if (source == null || source != mine) return mine
        return prefs.map(::fromSystem).firstOrNull { it != mine } ?: if (mine.startsWith("zh")) "en" else "zh-CN"
    }

    fun normalize(reported: String?, fallback: String): String {
        if (reported.isNullOrBlank()) return fallback
        val r = reported.trim().trim('.', '`', '"')
        val head = r.split('-', '_')[0].lowercase()
        if (head == "zh" || head == "cmn" || head == "yue")
            return if (r.contains("TW", ignoreCase = true) || r.contains("Hant", ignoreCase = true)) "zh-TW" else "zh-CN"
        return if (head.length == 2 || head.length == 3) head else fallback
    }

    private fun isCjk(cp: Int) = cp in 0x3040..0x9FFF || cp in 0xAC00..0xD7AF

    private fun count(text: String): Pair<Int, Int> {
        var letters = 0; var cjk = 0
        text.codePoints().forEach { cp ->
            if (Character.isLetter(cp)) { letters++; if (isCjk(cp)) cjk++ }
        }
        return letters to cjk
    }

    fun inScript(text: String, target: String): Boolean {
        val (letters, cjk) = count(text)
        if (letters == 0) return true
        val wantsCjk = target.startsWith("zh") || target.startsWith("ja") || target.startsWith("ko")
        return if (wantsCjk) cjk > 0 else cjk * 2 <= letters
    }

    fun writtenIn(text: String, englishLanguage: String): Boolean {
        val (letters, cjk) = count(text)
        if (letters == 0) return true
        val wantsCjk = listOf("Chinese", "Japanese", "Korean").any { englishLanguage.contains(it) }
        return if (wantsCjk) cjk * 5 >= letters else cjk * 2 < letters
    }

    fun clock(t: Double): String {
        val s = maxOf(0.0, t).toInt()
        return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%02d:%02d".format(s / 60, s % 60)
    }

    fun same(a: String, b: String): Boolean {
        if (a.equals(b, ignoreCase = true)) return true
        val (x, y) = a.substringBefore('-') to b.substringBefore('-')
        return x.equals(y, ignoreCase = true) && (!a.contains('-') || !b.contains('-'))
    }

    fun isCjkLanguage(code: String) = code.startsWith("zh") || code.startsWith("ja") || code.startsWith("ko")
}
