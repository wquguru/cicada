package com.wquguru.cicada

object Pinyin {
    private val transform by lazy { android.icu.text.Transliterator.getInstance("Han-Latin; Latin-ASCII") }
    private val cache = HashMap<Char, String>()

    fun of(c: Char): String {
        if (!Character.isIdeographic(c.code)) return ""
        synchronized(cache) { cache[c]?.let { return it } }
        val s = synchronized(transform) { transform.transliterate(c.toString()) }.trim().lowercase()
        val out = if (s.any { it.code >= 128 } ) "" else s
        synchronized(cache) { if (cache.size < 5000) cache[c] = out }
        return out
    }
}
