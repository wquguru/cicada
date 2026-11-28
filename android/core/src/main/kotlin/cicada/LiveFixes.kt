package cicada

class LiveFixes(val store: SessionStore, val vocabulary: Vocabulary, private val settings: AppSettings) {
    class Toast(val text: String, val at: Long = System.currentTimeMillis())
    @Volatile var toast: Toast? = null; private set

    private val refused = HashSet<String>()
    private val refusals = HashMap<String, Int>()
    private val deferred = HashSet<String>()
    private class Step(val session: String, val lines: Map<String, List<LineFix>>, val words: List<Vocabulary.Term>,
                       val refused: Set<String>, val deferred: Set<String>)
    private val undoStack = ArrayDeque<Step>()
    private val listeners = mutableListOf<() -> Unit>()

    fun onChange(listener: () -> Unit) { synchronized(listeners) { listeners.add(listener) } }
    private fun changed() { synchronized(listeners) { listeners.toList() }.forEach { it() } }

    @Synchronized fun meetingStarted() { refused.clear(); deferred.clear(); undoStack.clear() }

    private fun pair(a: String, b: String) = a + "\u001F" + b
    private fun key(f: LineFix) = Correction.core(f.from, f.to).let { pair(it.first, it.second) }

    // MARK: The service's proposals

    class Context(val topic: String?, val words: List<String>, val recent: List<String>,
                  val following: List<String> = emptyList(), val summary: String? = null)

    fun context(text: String): Context? {
        if (!settings.fixMisheard) return null
        val words = vocabulary.promptLines()
        val (id, line) = store.lineHeard(text) ?: return Context(null, words, emptyList())
        val s = store.get(id) ?: return Context(null, words, emptyList())
        val lines = store.lines(id)
        val i = lines.indexOfFirst { it.id == line.id }
        return Context(
            topic = s.notes?.title ?: if (s.renamed == true) s.title else null,
            words = words,
            recent = if (i < 0) emptyList() else lines.subList(maxOf(0, i - 3), i).map { it.shown },
            following = if (i < 0) emptyList() else lines.subList(i + 1, minOf(lines.size, i + 4)).map { it.shown },
            summary = s.notes?.summary?.takeIf { it.isNotEmpty() },
        )
    }

    @Synchronized fun received(text: String, edits: List<Correction.Edit>) {
        if (!settings.fixMisheard) return
        val (id, line) = store.lineHeard(text) ?: return
        val fresh = mutableListOf<LineFix>()
        for (e in edits) {
            val verdict = Correction.decide(e, known = { a, b -> vocabulary.knows(a, b) }, rejected = { a, b -> pair(a, b) in refused })
            Log.d("fix $verdict c=${"%.2f".format(e.confidence)} line=${line.id}")
            when {
                verdict == Correction.Verdict.Apply -> {
                    fresh.add(LineFix(e.from, e.to))
                    vocabulary.used(Correction.core(e.from, e.to).second)
                }
                verdict == Correction.Verdict.Ask && settings.askNames -> fresh.add(LineFix(e.from, e.to, ask = true))
            }
        }
        val before = line.fixes ?: emptyList()
        val fixes = known(line.src, Correction.merge(before, fresh))
        val dropped = before.count { it.applied && it.user != true && it !in fixes }
        if (dropped > 0) Log.d("fix recheck took back $dropped line=${line.id}")
        set(fixes, line.id, id)
    }

    @Synchronized fun applyKnown(lineId: String, id: String) {
        if (!settings.fixMisheard) return
        val l = store.line(id, lineId) ?: return
        set(known(l.src, l.fixes ?: emptyList()), lineId, id)
    }

    private fun known(src: String, fixes: List<LineFix>): List<LineFix> {
        val out = fixes.toMutableList()
        for (t in vocabulary.terms) {
            for (h in t.heard) {
                if (t.source != "user" && Correction.translation(h, t.word)) continue
                if (h.length < 2 || Correction.word(h, src) == null || pair(h, t.word) in refused || vocabulary.owners(h, t.word).isNotEmpty()) continue
                if (out.any { it.from == h || (it.applied && it.from.contains(h)) || (it.off == true && it.from == h) }) continue
                out.add(LineFix(h, t.word))
            }
        }
        return out
    }

    private fun set(fixes: List<LineFix>, lineId: String, id: String) {
        val l = store.line(id, lineId) ?: return
        if (fixes == (l.fixes ?: emptyList<LineFix>())) return
        store.setFixes(id, lineId, fixes)
        changed()
    }

    // MARK: 待确认

    class Waiting(val line: TranscriptLine, val fix: LineFix)

    fun pending(id: String): List<Waiting> {
        val seen = HashSet<String>()
        val out = mutableListOf<Waiting>()
        for (l in store.lines(id)) for (f in l.fixes ?: emptyList()) if (f.ask == true && seen.add(key(f))) out.add(Waiting(l, f))
        return out
    }

    class Asking(val line: TranscriptLine, val fix: LineFix, val of: Int)

    @Synchronized fun asking(id: String): Asking? {
        val open = pending(id).filter { key(it.fix) !in deferred }
        val first = open.firstOrNull() ?: return null
        return Asking(first.line, first.fix, minOf(open.size, ASK_AT_ONCE))
    }

    @Synchronized fun later(fix: LineFix, id: String) {
        remember(id, emptyList())
        deferred.add(key(fix))
        say(Strings.L("已收进人名和术语，稍后再看"))
    }

    @Synchronized fun answer(fix: LineFix, yes: Boolean, id: String) {
        val c = Correction.core(fix.from, fix.to)
        val lines = store.lines(id)
        val touched = lines.filter { l -> (l.fixes ?: emptyList()).any { it.ask == true && Correction.core(it.from, it.to) == c } }
        val others = if (yes) lines.filter { l -> l.src.contains(c.first) && touched.none { it.id == l.id } } else emptyList()
        remember(id, (touched + others).map { it.id })
        for (l in touched) {
            val fixes = (l.fixes ?: emptyList()).map { f ->
                if (f.ask == true && Correction.core(f.from, f.to) == c) f.copy(ask = null, user = if (yes) true else f.user, off = if (yes) f.off else true) else f
            }
            set(fixes, l.id, id)
        }
        if (yes) {
            vocabulary.confirm(c.first, c.second)
            for (l in others) applyKnown(l.id, id)
        } else {
            refused.add(pair(c.first, c.second))
        }
        Log.d("fix answered ${if (yes) "yes" else "no"}")
        say(if (yes) Strings.LF("已改 %@ → %@，记进词表", c.first, c.second) else Strings.LF("这场不再问 %@", c.first))
    }

    @Synchronized fun revert(fix: LineFix, lineId: String, id: String) {
        val l = store.line(id, lineId) ?: return
        val fixes = l.fixes ?: return
        val k = fixes.indexOfFirst { it.from == fix.from && it.to == fix.to && it.applied }
            .takeIf { it >= 0 } ?: fixes.indexOfFirst { it.from == fix.from && it.to == fix.to }
        if (k < 0) return
        remember(id, listOf(lineId))
        set(fixes.mapIndexed { i, f -> if (i == k) f.copy(off = true, ask = null, user = null) else f }, lineId, id)
        val c = Correction.core(fix.from, fix.to)
        refused.add(pair(c.first, c.second)); refused.add(pair(fix.from, fix.to))
        val n = (refusals[pair(c.first, c.second)] ?: 0) + 1
        refusals[pair(c.first, c.second)] = n
        if (n >= 2) vocabulary.forget(c.first, c.second)
        Log.d("fix reverted line=$lineId")
        say(Strings.LF("已改回 %@，这场不再改", Correction.label(fix).first))
    }

    // MARK: 改这句…

    class Same(val heard: String, val count: Int, val swap: Boolean)

    fun sameHeard(lineId: String, id: String, edited: String): Same? {
        val lines = store.lines(id)
        val l = lines.firstOrNull { it.id == lineId } ?: return null
        val e = Correction.userEdit(l.shown, edited, l.src, l.fixes ?: emptyList()) ?: return null
        val n = if (e.swap) lines.count { it.shown.contains(e.fix.from) } else 1
        return Same(e.heard, maxOf(1, n), e.swap)
    }

    @Synchronized fun edit(lineId: String, id: String, edited: String, everywhere: Boolean, keep: Boolean): Int {
        val lines = store.lines(id)
        val l = lines.firstOrNull { it.id == lineId } ?: return 0
        val e = Correction.userEdit(l.shown, edited, l.src, l.fixes ?: emptyList()) ?: return 0
        val (fix, heard) = e
        val everywhere = everywhere && e.swap
        val targets = if (everywhere) lines.filter { it.shown.contains(fix.from) } else listOf(l)
        remember(id, targets.map { it.id })
        for (t in targets) {
            val fixes = (t.fixes ?: emptyList()).filter { !(it.from == fix.from && it.to == fix.to) }.map { f ->
                if (f.ask == true && (f.from.contains(heard) || heard.contains(f.from))) f.copy(ask = null, off = true) else f
            }
            set(fixes + fix, t.id, id)
        }
        val word = Correction.core(fix.from, fix.to).second.trim()
        val learned = keep && everywhere && Vocabulary.learnable(heard, word) != null
        if (learned) vocabulary.confirm(heard, word, "user")
        Log.d("fix edited lines=${targets.size} learned=$learned")
        val (a, b) = if (e.swap) heard to word else fix.from to fix.to
        say(if (learned) Strings.LF("已改 %lld 处：%@ → %@，记进词表", targets.size, a, b) else Strings.LF("已改 %lld 处：%@ → %@", targets.size, a, b))
        return targets.size
    }

    // MARK: 撤销

    private fun remember(id: String, lines: List<String>) {
        val all = store.lines(id)
        val before = lines.associateWith { lid -> all.firstOrNull { it.id == lid }?.fixes?.map { it.copy() } ?: emptyList() }
        undoStack.addLast(Step(id, before, vocabulary.terms, refused.toSet(), deferred.toSet()))
        if (undoStack.size > 20) undoStack.removeFirst()
    }

    val canUndo: Boolean @Synchronized get() = undoStack.isNotEmpty()

    @Synchronized fun undo() {
        val step = undoStack.removeLastOrNull() ?: return
        for ((lid, fixes) in step.lines) store.setFixes(step.session, lid, fixes)
        vocabulary.restore(step.words)
        refused.clear(); refused.addAll(step.refused)
        deferred.clear(); deferred.addAll(step.deferred)
        toast = null
        Log.d("fix undone")
        changed()
    }

    fun toastNow(now: Long = System.currentTimeMillis()): Toast? = toast?.takeIf { now - it.at < TOAST_MS }

    private fun say(text: String) {
        toast = Toast(text)
        changed()
    }

    companion object {
        const val ASK_AT_ONCE = 3
        const val TOAST_MS = 6000L
    }
}
