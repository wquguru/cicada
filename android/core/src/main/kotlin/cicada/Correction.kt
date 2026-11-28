package cicada

data class LineFix(
    var from: String,
    var to: String,
    var ask: Boolean? = null,
    var off: Boolean? = null,
    var user: Boolean? = null,
) {
    val applied: Boolean get() = ask != true && off != true

    fun toJson(): Map<String, Any?> = mapOf("from" to from, "to" to to, "ask" to ask, "off" to off, "user" to user)

    companion object {
        fun from(o: Map<String, Any?>) = LineFix(o["from"].str() ?: "", o["to"].str() ?: "", o["ask"].bool(), o["off"].bool(), o["user"].bool())
    }
}

object Correction {
    data class Edit(val from: String, val to: String, val confidence: Double)

    enum class Verdict { Apply, Ask, Drop }

    const val APPLY_AT = 0.6
    const val SPELLING_AT = 0.8
    const val ASK_AT = 0.8

    @Volatile var pinyinOf: (Char) -> String = { "" }

    private fun word(c: Char) = c.code < 128 && c.isLetterOrDigit()

    fun core(from: String, to: String): Pair<String, String> {
        val a = from; val b = to
        var i = 0
        while (i < minOf(a.length, b.length) && a[i] == b[i]) i++
        var j = 0
        while (j < minOf(a.length, b.length) - i && a[a.length - 1 - j] == b[b.length - 1 - j]) j++
        if ((i < a.length && word(a[i])) || (i < b.length && word(b[i]))) { while (i > 0 && word(a[i - 1])) i-- }
        if ((a.length - j - 1 >= 0 && word(a[a.length - j - 1])) || (b.length - j - 1 >= 0 && word(b[b.length - j - 1]))) {
            while (j > 0 && word(a[a.length - j])) j--
        }
        while (a.length - j - i < 2 || b.length - j - i < 2) {
            if (j > 0 && !word(a[a.length - j])) j-- else if (i > 0 && !word(a[i - 1])) i-- else break
        }
        return a.substring(i, maxOf(i, a.length - j)) to b.substring(i, maxOf(i, b.length - j))
    }

    fun label(f: LineFix): Pair<String, String> {
        val c = core(f.from, f.to)
        return if (c.first.isEmpty() || c.second.isEmpty()) f.from to f.to else c
    }

    fun decide(e: Edit, known: (String, String) -> Boolean, rejected: (String, String) -> Boolean): Verdict {
        val (cf, ct) = core(e.from, e.to)
        if (cf.isEmpty() || ct.isEmpty() || cf.lowercase() == ct.lowercase() || rejected(e.from, e.to) || rejected(cf, ct)) return Verdict.Drop
        if (known(e.from, e.to) || known(cf, ct)) return Verdict.Apply
        if (e.confidence < APPLY_AT) return Verdict.Drop
        val latinFrom = cf.any { it.code < 128 && it.isLetter() }; val latinTo = ct.any { it.code < 128 && it.isLetter() }
        if (!latinFrom && !latinTo && han(cf) && han(ct) && soundsAlike(cf, ct)) return Verdict.Apply
        if (latinFrom && latinTo && cf.all { it.code < 128 } && ct.all { it.code < 128 } && e.confidence >= SPELLING_AT &&
            distance(cf.lowercase(), ct.lowercase()) <= 2) return Verdict.Apply
        if (latinTo && e.confidence >= ASK_AT && nameShaped(ct)) return Verdict.Ask
        return Verdict.Drop
    }

    fun nameShaped(s: String): Boolean = s.any { it.code < 128 && (it.isUpperCase() || it.isDigit()) }

    fun translation(heard: String, word: String): Boolean =
        han(heard) && word.any { it.code < 128 && it.isLetter() } && word.all { it.code < 128 } && !nameShaped(word)

    fun pinyin(s: String): List<String> = s.map { pinyinOf(it).trim().lowercase() }

    private val initials = listOf("zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q",
                                  "x", "r", "z", "c", "s", "y", "w")

    private fun split(syllable: String): Pair<String, String> {
        for (i in initials) if (syllable.startsWith(i)) return i to syllable.substring(i.length)
        return "" to syllable
    }

    fun soundsAlike(a: String, b: String): Boolean {
        val x = pinyin(a); val y = pinyin(b)
        if (x.size != y.size || x.isEmpty() || x.any { it.isEmpty() } || y.any { it.isEmpty() }) return false
        var score = 0.0
        for ((p, q) in x.zip(y)) {
            if (p == q) { score += 1; continue }
            val (i1, f1) = split(p); val (i2, f2) = split(q)
            if (i1 == i2 || f1 == f2 || f1.replace("ng", "n") == f2.replace("ng", "n")) score += 0.5
        }
        return score / x.size >= 0.75
    }

    fun han(s: String): Boolean = s.isNotEmpty() && s.codePoints().allMatch { Character.isIdeographic(it) }

    fun distance(a: String, b: String): Int {
        val row = IntArray(b.length + 1) { it }
        for ((i, ca) in a.withIndex()) {
            var prev = row[0]
            row[0] = i + 1
            for ((j, cb) in b.withIndex()) {
                val cur = row[j + 1]
                row[j + 1] = minOf(row[j + 1] + 1, row[j] + 1, prev + if (ca == cb) 0 else 1)
                prev = cur
            }
        }
        return row[b.length]
    }

    fun parse(reply: String, subtitle: String): Pair<String, List<Edit>>? {
        val open = reply.indexOf('{'); val close = reply.lastIndexOf('}')
        if (open < 0 || close <= open) return null
        val o = Json.parseObject(reply.substring(open, close + 1)) ?: return null
        val translation = o["translation"].str() ?: return null
        val edits = mutableListOf<Edit>()
        for (f in o["fixes"].arr()) {
            val m = f.obj() ?: continue
            val from = m["from"].str() ?: continue; val to = m["to"].str() ?: continue
            if (from.isEmpty() || from == to || !subtitle.contains(from)) continue
            edits.add(Edit(from, to, (m["confidence"] as? Number)?.toDouble() ?: 0.0))
        }
        return translation.trim() to edits
    }

    fun merge(old: List<LineFix>, new: List<LineFix>): List<LineFix> {
        val kept = old.filter { it.off == true || it.user == true }
        val fresh = new.filter { n ->
            val c = core(n.from, n.to).first
            kept.none { it.from == n.from || core(it.from, it.to).first == c }
        }
        return kept + fresh
    }

    data class UserEdit(val fix: LineFix, val heard: String, val swap: Boolean)

    fun userEdit(shown: String, edited: String, src: String, fixes: List<LineFix>): UserEdit? {
        val new = edited.trim()
        if (new.isEmpty() || new == shown) return null
        val a = shown.codePoints().toArray(); val b = new.codePoints().toArray()
        fun str(x: IntArray, from: Int, to: Int) = String(x, from, to - from)
        var p = 0
        while (p < minOf(a.size, b.size) && a[p] == b[p]) p++
        var q = 0
        while (q < minOf(a.size, b.size) - p && a[a.size - 1 - q] == b[b.size - 1 - q]) q++
        val swap = a.size - p - q > 0 && b.size - p - q > 0
        fun latin(c: Int) = c < 128 && Character.isLetterOrDigit(c)
        val tokens = mutableListOf<IntRange>()
        var k = 0
        while (k < a.size) {
            var e = k + 1
            if (latin(a[k])) while (e < a.size && latin(a[e])) e++
            tokens.add(k until e)
            k = e
        }
        var start = p; var end = a.size - q
        tokens.firstOrNull { start in it }?.let { start = it.first }
        if (end > start) tokens.firstOrNull { end - 1 in it }?.let { end = it.last + 1 }
        fun span() = str(a, start, end)
        fun count(x: String): Int {
            if (x.isEmpty()) return 0
            var n = 0; var at = shown.indexOf(x)
            while (at >= 0) { n++; at = shown.indexOf(x, at + x.length) }
            return n
        }
        fun replacement() = str(b, start, b.size - (a.size - end))
        while (span().codePoints().noneMatch { Character.isLetterOrDigit(it) } || count(span()) != 1 || replacement().isEmpty()) {
            val before = tokens.lastOrNull { it.last + 1 <= start }
            val after = tokens.firstOrNull { it.first >= end }
            if (before != null) start = before.first else if (after != null) end = after.last + 1 else break
        }
        val from = span()
        val to = replacement()
        if (from.isEmpty() || from == to) return null
        var heard = from
        if (!src.contains(from)) fixes.firstOrNull { it.applied && from.contains(it.to) }?.let { heard = core(it.from, it.to).first }
        return UserEdit(LineFix(from, to, user = true), heard, swap)
    }

    class Applied(val text: String, val marks: List<IntRange>)

    fun word(s: String, text: String): Int? {
        if (s.isEmpty()) return null
        var from = 0
        while (from < text.length) {
            val at = text.indexOf(s, from)
            if (at < 0) return null
            val end = at + s.length
            val before = at > 0 && word(text[at - 1])
            val after = end < text.length && word(text[end])
            if (!(word(s.first()) && before) && !(word(s.last()) && after)) return at
            from = at + 1
        }
        return null
    }

    fun apply(fixes: List<LineFix>, src: String): Applied {
        var text = src
        val spans = mutableListOf<Pair<String, Int>>()
        val ordered = fixes.filter { it.user != true } + fixes.filter { it.user == true }
        for (f in ordered) {
            if (!f.applied || f.from.isEmpty()) continue
            val start = word(f.from, text) ?: text.indexOf(f.from)
            if (start < 0) continue
            val delta = f.to.length - f.from.length
            for (k in spans.indices) if (spans[k].second > start) spans[k] = spans[k].first to spans[k].second + delta
            text = text.substring(0, start) + f.to + text.substring(start + f.from.length)
            spans.add(f.to to start)
        }
        val marks = spans.filter { (w, o) -> o + w.length <= text.length && w.isNotEmpty() }
            .map { (w, o) -> o until o + w.length }.sortedBy { it.first }
        return Applied(text, marks)
    }
}
