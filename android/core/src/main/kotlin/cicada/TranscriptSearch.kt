package cicada

object TranscriptSearch {
    fun terms(query: String, notes: List<NoteTerm>): List<String> {
        val q = query.trim()
        if (q.isEmpty()) return emptyList()
        val out = mutableListOf(q)
        for (t in notes) {
            val forms = listOf(t.name) + t.heard
            if (forms.any { it.isNotEmpty() && (it.contains(q, ignoreCase = true) || q.contains(it, ignoreCase = true)) })
                for (f in forms) if (f.isNotEmpty() && f !in out) out += f
        }
        return out
    }

    fun matches(l: TranscriptLine, terms: List<String>): Boolean =
        terms.any { l.shown.contains(it, ignoreCase = true) || (l.dst ?: "").contains(it, ignoreCase = true) }

    fun matches(lines: List<TranscriptLine>, terms: List<String>): List<String> =
        if (terms.isEmpty()) emptyList() else lines.filter { matches(it, terms) }.map { it.id }

    fun ranges(text: String, terms: List<String>): List<IntRange> {
        val found = mutableListOf<IntRange>()
        for (term in terms) {
            if (term.isEmpty()) continue
            var from = 0
            while (true) {
                val i = text.indexOf(term, from, ignoreCase = true)
                if (i < 0) break
                val r = i until i + term.length
                if (found.none { it.first <= r.last && r.first <= it.last }) found += r
                from = i + term.length
            }
        }
        return found.sortedBy { it.first }
    }
}
