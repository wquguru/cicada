package cicada

import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

class SessionStore(loadNow: Boolean = true) {
    private val gate = Any()
    private val sessions = HashMap<String, Session>()
    private val dirty = HashSet<String>()
    private val saver = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "SessionStore").apply { isDaemon = true } }
    private var pendingSave: ScheduledFuture<*>? = null
    private val listeners = mutableListOf<(String) -> Unit>()

    @Volatile var liveId: String? = null; private set

    @Volatile var loaded = false; private set

    init { if (loadNow) load() }

    fun onChange(listener: (String) -> Unit) { synchronized(listeners) { listeners.add(listener) } }
    private fun fire(id: String) { synchronized(listeners) { listeners.toList() }.forEach { it(id) } }

    private fun folder(id: String) = File(Paths.sessions, id)
    private fun fileOf(id: String) = File(folder(id), "session.json")

    fun load() {
        val dirs = Paths.sessions.listFiles() ?: run { loaded = true; fire(""); return }
        for (dir in dirs) {
            val file = File(dir, "session.json")
            if (!file.isFile) continue
            try {
                val s = Session.read(file.readText()) ?: continue
                if (s.endedAt == null) {
                    s.endedAt = s.startedAt.plusMillis((((s.lines.lastOrNull()?.t ?: 0.0) + 5) * 1000).toLong())
                    synchronized(gate) { dirty.add(s.id) }
                    Log.d("store: closed interrupted ${s.id}")
                }
                synchronized(gate) { sessions.putIfAbsent(s.id, s) }
            } catch (e: Exception) { Log.d("store: skipped ${dir.name}: ${e.javaClass.simpleName}") }
        }
        loaded = true
        flush()
        fire("")
    }

    fun all(): List<Session> = synchronized(gate) { sessions.values.sortedByDescending { it.startedAt } }

    fun get(id: String): Session? = synchronized(gate) { sessions[id] }

    fun lines(id: String): List<TranscriptLine> = synchronized(gate) { sessions[id]?.lines?.map { it.copy() } ?: emptyList() }

    fun begin(at: Instant = Instant.now()): Session {
        val id = DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss").withZone(ZoneId.systemDefault()).format(at)
        val s = Session(id = id, title = defaultTitle(at), startedAt = at.truncatedTo(java.time.temporal.ChronoUnit.SECONDS))
        synchronized(gate) { sessions[id] = s }
        liveId = id
        return s
    }

    fun append(id: String, line: TranscriptLine) = mutate(id) { it.lines.add(line) }

    fun replace(id: String, line: TranscriptLine) = mutate(id) { s ->
        val i = s.lines.indexOfFirst { it.id == line.id }
        if (i >= 0) { line.fixes = s.lines[i].fixes; s.lines[i] = line }
    }

    fun setFixes(id: String, lineId: String, fixes: List<LineFix>) {
        val changed = synchronized(gate) {
            val l = sessions[id]?.lines?.firstOrNull { it.id == lineId } ?: return
            if ((l.fixes ?: emptyList<LineFix>()) == fixes) return
            l.fixes = if (fixes.isEmpty()) null else fixes.map { it.copy() }.toMutableList()
            true
        }
        if (changed) { markDirty(id); fire(id) }
    }

    fun lineHeard(text: String): Pair<String, TranscriptLine>? {
        val ids = listOfNotNull(liveId) + synchronized(gate) { sessions.values.filter { it.importing == true }.map { it.id } }
        for (id in ids) synchronized(gate) { sessions[id]?.lines?.lastOrNull { it.src == text }?.copy() }?.let { return id to it }
        return null
    }

    fun line(id: String, lineId: String): TranscriptLine? = synchronized(gate) { sessions[id]?.lines?.firstOrNull { it.id == lineId }?.copy() }

    fun setNotes(id: String, notes: MeetingNotes) = mutate(id) { it.notes = notes }

    fun rename(id: String, title: String) = mutate(id) { s ->
        val t = title.trim()
        if (t == displayTitle(s)) return@mutate
        if (t.isEmpty()) { s.title = defaultTitle(s.startedAt); s.renamed = false }
        else { s.title = t; s.renamed = true }
    }

    fun setVoiceName(id: String, voice: Int, name: String?) = mutate(id) { s ->
        val names = (s.voiceNames ?: emptyMap()).toMutableMap()
        if (name == null) names.remove(voice.toString()) else names[voice.toString()] = name.trim()
        s.voiceNames = names
    }

    fun setVoiceGuesses(id: String, guesses: Map<Int, VoiceGuess>, refuted: Map<Int, String> = emptyMap()) {
        if (guesses.isEmpty() && refuted.isEmpty()) return
        mutate(id) { s ->
            val all = (s.voiceGuesses ?: emptyMap()).toMutableMap()
            for ((v, name) in refuted) if (v !in guesses && all[v.toString()]?.name == name) all.remove(v.toString())
            for ((v, g) in guesses) all[v.toString()] = g
            s.voiceGuesses = all.ifEmpty { null }
        }
    }

    fun update(id: String, change: (Session) -> Unit) = mutate(id, change)

    fun audioFile(id: String) = File(folder(id), "system.m4a")

    fun end(id: String, at: Instant? = null) {
        val empty = synchronized(gate) {
            if (liveId == id) liveId = null
            val s = sessions[id] ?: return
            s.endedAt = at ?: Instant.now()
            s.lines.isEmpty()
        }
        if (empty) deleteNow(id) else { markDirty(id); flush() }
    }

    fun delete(id: String) {
        if (id == liveId) { Log.d("store: kept $id, it is live"); return }
        deleteNow(id)
    }

    private fun deleteNow(id: String) {
        synchronized(gate) { sessions.remove(id); dirty.remove(id) }
        try { folder(id).deleteRecursively() } catch (e: Exception) { Log.d("store: delete failed ${e.javaClass.simpleName}") }
        fire(id)
    }

    fun import(session: Session) {
        synchronized(gate) { sessions[session.id] = session }
        markDirty(session.id); flush(); fire(session.id)
    }

    private fun mutate(id: String, change: (Session) -> Unit) {
        synchronized(gate) { change(sessions[id] ?: return) }
        markDirty(id)
        fire(id)
    }

    private fun markDirty(id: String) {
        synchronized(gate) {
            dirty.add(id)
            pendingSave?.cancel(false)
            pendingSave = saver.schedule({ flush() }, 1500, TimeUnit.MILLISECONDS)
        }
    }

    fun flush() {
        val writes = synchronized(gate) {
            val list = dirty.mapNotNull { id -> sessions[id]?.let { id to Json.write(it.toJson()) } }
            dirty.clear()
            list
        }
        for ((id, json) in writes) {
            try {
                folder(id).mkdirs()
                val tmp = File(folder(id), "session.json.tmp")
                tmp.writeText(json)
                if (!tmp.renameTo(fileOf(id))) { fileOf(id).delete(); tmp.renameTo(fileOf(id)) }
            } catch (e: Exception) { Log.d("store: save failed ${e.javaClass.simpleName}") }
        }
    }

    companion object {
        fun defaultTitle(at: Instant): String =
            "会议 " + DateTimeFormatter.ofPattern("M月d日 HH:mm", Locale.ROOT).withZone(ZoneId.systemDefault()).format(at)

        private fun localDate(at: Instant, pattern: String): String =
            DateTimeFormatter.ofPattern(pattern, Strings.locale).withZone(ZoneId.systemDefault()).format(at)

        fun displayTitle(s: Session): String {
            if (s.renamed ?: !s.title.startsWith("会议 ")) return s.title
            val name = s.notes?.title
            if (name.isNullOrEmpty() && s.sourceFile != null) return s.sourceFile!!.substringBeforeLast('.')
            if (name.isNullOrEmpty()) return Strings.L("会议") + " " + localDate(s.startedAt, Strings.L("M月d日 HH:mm"))
            val thisYear = s.startedAt.atZone(ZoneId.systemDefault()).year == Instant.now().atZone(ZoneId.systemDefault()).year
            return localDate(s.startedAt, Strings.L(if (thisYear) "M月d日" else "yyyy年M月d日")) + " " + name
        }

        fun stamp(at: Instant): String = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm").withZone(ZoneId.systemDefault()).format(at)

        fun markdown(s: Session): String = TranscriptExport.markdown(s)
    }
}
