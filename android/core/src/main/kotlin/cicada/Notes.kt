package cicada

import java.time.Instant
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

class NotesEngine(private val ling: LingClient, private val store: SessionStore) {
    enum class State { Idle, Updating, NoKey, InvalidKey, RateLimited, Failed }

    private val gate = Any()
    private val timer = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "Notes").apply { isDaemon = true } }
    private val work = Executors.newSingleThreadExecutor { r -> Thread(r, "NotesWork").apply { isDaemon = true } }
    private var tick: ScheduledFuture<*>? = null
    private var sessionId: String? = null
    private var inFlight = false
    private var pendingFinal: String? = null
    private var finalId: String? = null
    private var lastAttempt = 0L
    private val listeners = mutableListOf<() -> Unit>()

    @Volatile var notes = MeetingNotes(); private set
    @Volatile var status = State.Idle; private set
    @Volatile var shownId: String? = null; private set
    @Volatile var finalDone: ((String) -> Unit)? = null

    fun settling(id: String): Boolean = synchronized(gate) { sessionId == id || finalId == id || pendingFinal == id } || generating == id

    @Volatile var language: () -> String = { "Simplified Chinese" }

    fun onChange(listener: () -> Unit) { synchronized(listeners) { listeners.add(listener) } }
    private fun changed() { synchronized(listeners) { listeners.toList() }.forEach { it() } }

    fun glossary(): List<String> = notes.terms.take(30).map {
        if (it.heard.isEmpty()) "${it.name} (${it.note})" else "${it.name} (${it.note}; misheard as ${it.heard.joinToString(", ")})"
    }

    fun begin(id: String) {
        synchronized(gate) {
            sessionId = id; shownId = id
            notes = store.get(id)?.notes ?: MeetingNotes()
            status = if (ling.hasKey) State.Idle else State.NoKey
            lastAttempt = System.currentTimeMillis()
            tick?.cancel(false)
            tick = timer.scheduleWithFixedDelay({ tick() }, 5, 5, TimeUnit.SECONDS)
        }
        changed()
    }

    fun finish() {
        val id = synchronized(gate) {
            tick?.cancel(false); tick = null
            val id = sessionId; sessionId = null; id
        } ?: return
        update(id, final = true)
    }

    fun show(id: String) {
        synchronized(gate) { shownId = id; notes = store.get(id)?.notes ?: MeetingNotes() }
        changed()
    }

    @Volatile var generating: String? = null; private set

    fun generate(id: String) {
        if (generating == id) return
        generating = id
        changed()
        work.execute {
            try { update(id, final = true) } finally { generating = null; changed() }
        }
    }

    private fun tick() {
        val id = synchronized(gate) {
            if ((status == State.NoKey || status == State.InvalidKey) && ling.usable) { status = State.Idle; changed() }
            val id = sessionId ?: return
            if (inFlight) return
            val s = store.get(id) ?: return
            if (s.lines.size <= notes.covered) return
            val since = (System.currentTimeMillis() - lastAttempt) / 1000.0
            val due = if (notes.isEmpty) s.lines.size >= 3 || since > 20 else since >= INTERVAL
            if (!due) return
            id
        }
        work.execute { update(id, final = false) }
    }

    private fun update(id: String, final: Boolean) {
        val session: Session
        val base: MeetingNotes
        val prior: List<NoteTerm>
        synchronized(gate) {
            if (inFlight) { if (final) pendingFinal = id; return }
            fun over() { if (final) finalDone?.invoke(id) }
            session = store.get(id) ?: run { over(); return }
            if (session.lines.isEmpty()) { over(); return }
            if (!ling.hasKey) { status = State.NoKey; changed(); over(); return }
            inFlight = true
            if (final) finalId = id
            lastAttempt = System.currentTimeMillis()
            status = State.Updating
            base = if (final) MeetingNotes() else if (id == shownId) notes else session.notes ?: MeetingNotes()
            prior = (if (id == shownId) notes else session.notes)?.terms ?: emptyList()
        }
        changed()
        try {
            val lines = store.lines(id)
            val from = if (final) 0 else minOf(base.covered, lines.size)
            val lang = language()
            val frozen = if (final) 0 else maxOf(0, base.topics.size - EDITABLE_TOPICS)
            val numbers = SpeakerLabels.numbers(lines)
            val names = SpeakerLabels.names(session)
            val prompt = prompt(base, lines, from, lang, final, frozen = frozen, numbers = numbers, names = names)
            val startedAt = lines.firstOrNull()?.t ?: 0.0
            var next: MeetingNotes? = if (final) longFinal(lines, numbers, names, lang, startedAt) else null
            for (attempt in 1..(if (final) 2 else 1)) {
                if (next != null) break
                val raw = ling.chat(prompt, "Update the notes. Write them in $lang.", Priority.Notes, json = true, maxTokens = 6000, timeout = 90.0, patient = final)
                val parsed = parse(raw, lines.map { it.t }, startedAt) ?: break
                if (written(parsed, lang)) { next = parsed; break }
                Log.d("notes: ${if (final) "final" else "live"} reply not in $lang (attempt $attempt), dropped")
            }
            if (next == null) {
                Log.d("notes: no usable reply, kept the previous notes")
                status = State.Failed
                return
            }
            if (!final) next.topics = merge(base.topics, frozen, next.topics).toMutableList()
            next.terms = NoteTerm.keepingOrder(prior, next.terms).toMutableList()
            next.terms = heardAsSaid(next.terms, lines).toMutableList()
            carryTimes(base, next)
            next.title = next.title ?: base.title ?: session.notes?.title
            next.covered = lines.size
            next.updatedAt = Instant.now()
            next.final = final
            synchronized(gate) { if (id == shownId) notes = next }
            store.setNotes(id, next)
            status = State.Idle
            Log.d("notes: ${if (final) "final" else "live"} update ${lines.size - from} new lines -> ${next.topics.size} topics, ${next.terms.size} terms")
        } catch (e: LingException) {
            status = when (e.kind) {
                LingException.Kind.InvalidKey -> State.InvalidKey
                LingException.Kind.RateLimited -> State.RateLimited
                LingException.Kind.NoKey -> State.NoKey
                else -> State.Failed
            }
            Log.d("notes: update failed ${e.message}")
        } catch (e: Exception) {
            status = State.Failed
            Log.d("notes: update failed ${e.javaClass.simpleName}")
        } finally {
            val queued = synchronized(gate) { inFlight = false; if (final) finalId = null; pendingFinal.also { pendingFinal = null } }
            changed()
            if (final) finalDone?.invoke(id)
            if (queued != null) update(queued, final = true)
        }
    }

    private fun longFinal(lines: List<TranscriptLine>, numbers: Map<String, Int>, names: Map<Int, String>,
                          lang: String, startedAt: Double): MeetingNotes? {
        val parts = parts(lines)
        if (parts.size <= 1) return null
        val started = System.currentTimeMillis()
        val times = lines.map { it.t }
        val pool = Executors.newFixedThreadPool(parts.size) { r -> Thread(r, "NotesPart").apply { isDaemon = true } }
        val replies = try {
            pool.invokeAll(parts.mapIndexed { i, range ->
                val prompt = prompt(MeetingNotes(), lines.subList(0, range.last + 1), range.first, lang, final = true,
                                    numbers = numbers, names = names, part = i + 1 to parts.size)
                Callable {
                    try {
                        ling.chat(prompt, "Write the notes for this part. Write them in $lang.", Priority.Notes, json = true, maxTokens = 6000, timeout = 90.0)
                    } catch (e: Exception) { null }
                }
            }).map { it.get() }
        } finally { pool.shutdown() }
        val notes = mutableListOf<String>()
        val topics = mutableListOf<NoteTopic>()
        for ((i, raw) in replies.withIndex()) {
            val parsed = raw?.let { parse(it, times, startedAt) }
            val a = raw?.indexOf('{') ?: -1; val b = raw?.lastIndexOf('}') ?: -1
            val part = if (parsed != null && parsed.topics.isNotEmpty() && a >= 0 && b > a) Json.parseObject(raw!!.substring(a, b + 1)) else null
            if (part == null) {
                Log.d("notes: final part ${i + 1}/${parts.size} failed, one pass instead")
                return null
            }
            notes.add(Json.write(part - "topics", pretty = false))
            topics += thinned(parsed!!.topics, partTopics(parts.size), lines[parts[i].last].t)
        }
        val prompt = mergePrompt(notes, lines, lang)
        for (attempt in 1..2) {
            val raw = try {
                ling.chat(prompt, "Merge the notes. Write them in $lang.", Priority.Notes, json = true, maxTokens = 6000, timeout = 90.0)
            } catch (e: Exception) { break }
            val merged = parse(raw, times, startedAt) ?: break
            merged.topics = topics
            if (written(merged, lang)) {
                Log.d("notes: final in ${parts.size} parts -> ${merged.topics.size} topics in ${(System.currentTimeMillis() - started) / 1000} s")
                return merged
            }
            Log.d("notes: merged reply not in $lang (attempt $attempt), dropped")
        }
        Log.d("notes: merging ${parts.size} parts failed, one pass instead")
        return null
    }

    companion object {
        const val INTERVAL = 45.0
        const val MAX_TOPICS = 8
        const val LIVE_MAX_TOPICS = 12
        const val TOPIC_SUMMARY_LIMIT = 160
        const val EDITABLE_TOPICS = 2

        fun merge(old: List<NoteTopic>, frozen: Int, returned: List<NoteTopic>): List<NoteTopic> {
            val kept = old.take(frozen).toMutableList()
            val fixed = kept.map { it.title }.toSet()
            val own = returned.filter { it.title !in fixed }
            var tail = if (kept.isEmpty()) own else own.takeLast(old.size - kept.size + 1)
            if (tail.isEmpty()) return old
            tail.forEach { it.summary = shortened(it.summary) }
            tail = capped(tail, LIVE_MAX_TOPICS - minOf(kept.size, 1))
            while (kept.size + tail.size > LIVE_MAX_TOPICS && kept.size >= 2) {
                val ends = kept.drop(1).map { it.start } + tail[0].start
                val i = (0 until kept.size - 1).minBy { ends[it + 1] - kept[it].start }
                kept[i] = joined(kept[i], kept[i + 1])
                kept.removeAt(i + 1)
            }
            return capped(kept + tail, LIVE_MAX_TOPICS)
        }

        fun joined(a: NoteTopic, b: NoteTopic): NoteTopic {
            val fromA = minOf(a.points.size, maxOf(2, 4 - b.points.size))
            val fromB = minOf(b.points.size, 4 - fromA)
            val times = (0 until fromA).map { a.pointTime(it) } + (0 until fromB).map { b.pointTime(it) }
            val gap = if (a.summary.isEmpty() || a.summary.last() in "。！？；") "" else " "
            return NoteTopic(start = a.start, title = "${a.title} / ${b.title}", summary = a.summary + gap + b.summary,
                             points = (a.points.take(fromA) + b.points.take(fromB)).toMutableList(),
                             pointTimes = if (times.any { it != null }) times.toMutableList() else null, fishbone = a.fishbone ?: b.fishbone)
        }

        fun capped(topics: List<NoteTopic>, count: Int): List<NoteTopic> {
            val out = topics.toMutableList()
            while (out.size > maxOf(1, count)) {
                val extra = out.removeAt(out.size - 1)
                val last = out.removeAt(out.size - 1)
                val times = last.points.indices.map { last.pointTime(it) } + extra.points.indices.map { extra.pointTime(it) }
                out.add(NoteTopic(start = last.start, title = last.title, summary = last.summary, points = (last.points + extra.points).toMutableList(),
                                  pointTimes = if (times.any { it != null }) times.toMutableList() else null, fishbone = last.fishbone))
            }
            return out
        }

        fun heardAsSaid(terms: List<NoteTerm>, lines: List<TranscriptLine>): List<NoteTerm> = terms.map { t ->
            NoteTerm(t.name, t.note, t.heard.filter { h -> lines.any { it.src.contains(h, ignoreCase = true) } }.toMutableList())
        }

        fun shortened(summary: String): String {
            if (summary.length <= TOPIC_SUMMARY_LIMIT) return summary
            val head = summary.take(TOPIC_SUMMARY_LIMIT)
            val end = head.indexOfAny("。！？；.!?;".toCharArray(), 10)
            return if (end >= 0) head.take(end + 1) else head.trimEnd() + "…"
        }

        fun carryTimes(old: MeetingNotes, next: MeetingNotes) {
            val known = HashMap<String, Double>()
            for (t in old.topics) for (i in t.points.indices) t.pointTime(i)?.let { known.putIfAbsent(t.points[i], it) }
            for (t in next.topics) {
                val times = t.points.mapIndexed { i, p -> min(t.pointTime(i), known[p]) }.toMutableList()
                t.pointTimes = if (times.any { it != null }) times else null
                times.filterNotNull().minOrNull()?.let { if (it < t.start) t.start = it }
            }
            val items = HashMap<String, Double>()
            for (i in old.conclusions + old.todos) i.t?.let { items.putIfAbsent(i.text, it) }
            for (i in next.conclusions + next.todos) i.t = min(i.t, items[i.text])
        }

        private fun min(a: Double?, b: Double?) = if (a == null) b else if (b == null) a else minOf(a, b)

        fun written(notes: MeetingNotes, language: String) =
            Languages.writtenIn(notes.summary + notes.topics.joinToString("") { it.title }, language)

        // MARK: Prompt (Notes.swift › prompt, word for word)

        fun prompt(notes: MeetingNotes, lines: List<TranscriptLine>, from: Int, language: String, final: Boolean,
                   frozen: Int = 0, part: Pair<Int, Int>? = null,
                   numbers: Map<String, Int> = emptyMap(), names: Map<Int, String> = emptyMap()): String {            fun line(i: Int): String {
                val l = lines[i]
                val n = numbers[l.id]
                val who = if (l.speaker == "me") "你" else if (n != null) names[n] ?: "说话人$n" else if (numbers.isEmpty()) "对方" else "未识别"
                return "[L${i + 1} ${Languages.clock(l.t)} $who] ${l.shown}"
            }
            val current = if (notes.isEmpty) "{}" else compactJson(notes, frozen)
            val context = maxOf(0, from - 2)
            val task = part?.let { "that has just ended. It was long, so it is noted in parts: write the notes for part ${it.first} of ${it.second} only, from the lines below" }
                ?: if (final) "that has just ended. Rewrite them from the whole transcript" else "that is still going on. Update them with the new lines"
            var p = "You keep notes for a meeting $task.\n" +
                "Write the notes in $language. Return JSON only.\n"
            if (!final) {
                if (frozen > 0) {
                    p += "Earlier topics (settled: kept as they are, do not return them):\n" +
                        notes.topics.take(frozen).joinToString("\n") { "- ${Languages.clock(it.start)} ${it.title}: ${it.summary}" } + "\n\n"
                }
                p += "Current notes (JSON${if (frozen > 0) ", latest topics only" else ""}):\n$current\n\n"
            }
            if (context < from) p += "Already covered (context only):\n" + (context until from).joinToString("\n") { line(it) } + "\n\n"
            p += "${if (final) "Transcript" else "New lines"} (id, mm:ss, speaker 对方=the other side / 你=me / a name or 说话人N=one person on the other side, told apart by voice and possibly wrong / 未识别=someone on the other side not identified, text). Speech recognition makes mistakes, often in names: correct them from context, and write a public figure's name as the news spells it.\n"
            p += (from until lines.size).joinToString("\n") { line(it) }
            if (final && from < lines.size) {
                val span = lines.last().t - lines[from].t
                val most = maxOf(1, minOf(part?.let { partTopics(it.second) } ?: MAX_TOPICS, (span / 180).toInt() + 1))
                p += "\n\nThis ${if (part == null) "meeting" else "part"} ran ${Languages.clock(span)}: use at most $most topic${if (most == 1) "" else "s"}."
            } else if (!final && notes.topics.isNotEmpty() && lines.isNotEmpty() && lines.last().t - notes.topics.last().start < 120) {
                val topic = notes.topics.last()
                p += "\n\nThe current topic \"${topic.title}\" started at ${Languages.clock(topic.start)}, under 2 minutes ago: do not start a new topic in this update; add the new lines to it."
            } else if (!final && notes.topics.isEmpty()) {
                p += "\n\nThese are the first lines: make one topic."
            }
            return p + "\n\n" + format(language, final, frozen)
        }

        private fun format(language: String, final: Boolean, frozen: Int): String =
            "Return the full notes as one JSON object with exactly these keys:\n" +
                "{\"title\": \"the meeting's name: what it is about, a few words\",\n" +
                " \"summary\": \"2-3 sentences on the whole meeting so far\",\n" +
                " \"topics\": [{\"start\": seconds, \"title\": \"short title\", \"summary\": \"one sentence on the whole topic\", \"points\": [{\"text\": \"key point\", \"evidence\": [\"L4\"]}], \"evidence\": [\"L3\"],\n" +
                "             \"fishbone\": null or {\"question\": \"the problem or question\", \"branches\": [{\"label\": \"2-6 words\", \"detail\": \"one short line\", \"t\": seconds, \"evidence\": [\"L5\"]}]}}],\n" +
                " \"conclusions\": [{\"text\": \"...\", \"evidence\": [\"L7\", \"L8\"]}],\n" +
                " \"todos\": [{\"text\": \"...\", \"owner\": \"对方\" or \"你\" or null, \"evidence\": [\"L9\"]}],\n" +
                " \"terms\": [{\"name\": \"correct spelling\", \"note\": \"who or what, a few words\", \"heard\": [\"how it was misrecognised\"]}]}\n" +
                "Rules (be brief: these notes are read at a glance during the meeting):\n" +
                "- title: a name for the whole meeting, like a calendar entry (at most 12 Chinese characters or 6 words; no date, no quotes, not \"会议\" alone). Keep the current title unless the meeting's subject has clearly changed.\n" +
                "- summary: at most 3 short sentences.\n" +
                "- Topics in time order, ${if (frozen > 0) "returning only the topics in the current notes and at most one new one after them" else "at most $MAX_TOPICS in total"}. A topic is a stretch of the meeting, usually 3-10 minutes, not a single remark: start a new one only when the subject clearly changes and the current topic started at least 2 minutes before the newest line${if (final) "" else "; add at most one new topic per update"}. Otherwise add to the current one, and merge small neighbouring topics. Keep earlier topics as they are unless new lines correct them. The last topic is the one being discussed now.\n" +
                "- A topic's summary is one sentence on the whole topic, at most 40 Chinese characters or 25 words: as the topic grows, rewrite it; never append to it or narrate what came next (\"最新\", \"又\", \"补充\", \"then\", \"later\").\n" +
                "- At most 4 points per topic, each one short phrase. Merge rather than repeat.\n" +
                "- At most 5 conclusions and only real to-dos (often none).\n" +
                "- Add a fishbone only to a topic that discusses causes, reasons or factors (3-5 branches); otherwise null.\n" +
                "- Every topic, point, branch, conclusion and to-do needs evidence: the ids of the lines that say it. Never state anything the transcript does not say.\n" +
                "- terms: at most 10 in total, replacing less useful ones rather than adding: first names the transcript misspells (heard), then the people, places and jargon a reader would not know. Leave out what everyone knows (a famous company, index or politician) unless it was misheard. name is the correct spelling in the transcript's language (no translation in brackets); heard lists only the wrong forms the transcript used, and only of that same thing: a name said again and again in one spelling that context doesn't tie to a known one (\"我们 twoty\", \"our platform\") is a thing of its own, its own term with that spelling, not a mishearing of a similar name; note is a few words.\n" +
                "- Write the meeting title and every summary, title, point, branch, conclusion and to-do in $language, even when the transcript is in another language. Only term names keep the transcript's spelling.\n" +
                "- Write about what was said, never about the transcript or recognition quality.\n" +
                "- Use empty arrays when there is nothing. No markdown, no text outside the JSON."

        // MARK: Long meetings

        const val SPLIT_MINUTES = 100.0
        const val PART_MINUTES = 60.0
        fun parts(lines: List<TranscriptLine>): List<IntRange> {
            if (lines.isEmpty()) return emptyList()
            val first = lines.first().t; val last = lines.last().t
            val minutes = (last - first) / 60
            if (minutes <= SPLIT_MINUTES) return listOf(lines.indices)
            val count = Math.ceil(minutes / PART_MINUTES).toInt()
            val length = (last - first) / count
            val bounds = mutableListOf(0)
            for (k in 1 until count) {
                val at = first + length * k
                val i = lines.indexOfFirst { it.t >= at }
                if (i > bounds.last()) bounds.add(i)
            }
            bounds.add(lines.size)
            return bounds.zipWithNext { a, b -> a until b }
        }

        fun partTopics(parts: Int) = maxOf(2, MAX_TOPICS / maxOf(1, parts))

        fun thinned(topics: List<NoteTopic>, count: Int, end: Double): List<NoteTopic> {
            val list = topics.toMutableList()
            while (list.size > maxOf(1, count)) {
                fun span(i: Int) = (if (i + 2 < list.size) list[i + 2].start else end) - list[i].start
                val pairs = 0 until list.size - 1
                val same = pairs.firstOrNull { subject(list[it].title) == subject(list[it + 1].title) }
                val at = same ?: pairs.minBy { span(it) }
                val one = joined(list[at], list[at + 1])
                if (same != null) { one.title = list[at].title; one.summary = list[at].summary }
                list[at] = one
                list.removeAt(at + 1)
            }
            return list
        }

        fun subject(title: String): String {
            val t = title.trim()
            if (t.isEmpty() || t.last() !in "）)") return t
            val open = t.lastIndexOfAny(charArrayOf('（', '('))
            return if (open > 0) t.substring(0, open).trim() else t
        }

        fun mergePrompt(parts: List<String>, lines: List<TranscriptLine>, language: String): String {
            var p = "You keep notes for a meeting that has just ended. It was long, so each part was noted on its own; below are those notes, in time order (JSON; evidence ids are transcript lines, L1 the first). Merge them into the notes for the whole meeting.\n" +
                "Write the notes in $language. Return JSON only.\n\n"
            for ((i, part) in parts.withIndex()) p += "Part ${i + 1} of ${parts.size}:\n$part\n\n"
            if (lines.isNotEmpty()) {
                p += "This meeting ran ${Languages.clock(lines.last().t - lines.first().t)}. Return \"topics\": []: the parts' topics are kept as they are. Name and summarise the whole meeting, every part of it; keep each conclusion, to-do and term once, with the evidence ids it had (joined when you merge two).\n\n"
            }
            return p + format(language, final = true, frozen = 0)
        }

        private fun compactJson(n: MeetingNotes, from: Int = 0): String {
            val o = linkedMapOf<String, Any?>()
            if (n.title != null) o["title"] = n.title
            o["summary"] = n.summary
            o["topics"] = n.topics.drop(from).map {
                mapOf("start" to it.start, "title" to it.title, "summary" to it.summary, "points" to it.points, "fishbone" to it.fishbone?.toJson())
            }
            o["conclusions"] = n.conclusions.map { it.text }
            o["todos"] = n.todos.map { it.text }
            o["terms"] = n.terms.map { it.toJson() }
            return Json.write(o, pretty = false)
        }

        // MARK: Parse

        fun parse(raw: String, times: List<Double>, startedAt: Double): MeetingNotes? {
            val a = raw.indexOf('{'); val b = raw.lastIndexOf('}')
            if (a < 0 || b <= a) return null
            val root = Json.parseObject(raw.substring(a, b + 1)) ?: return null

            fun s(v: Any?) = (v as? String)?.trim() ?: ""
            fun lineNumbers(v: Any?): Set<Int> = v.arr().mapNotNull { id ->
                s(id).dropWhile { !it.isDigit() }.takeWhile { it.isDigit() }.toIntOrNull()?.takeIf { it in 1..times.size }
            }.toSet()
            fun support(v: Any?) = lineNumbers(v).size
            fun time(v: Any?): Double? = lineNumbers(v).minOrNull()?.let { times[it - 1] }
            fun objects(v: Any?) = v.arr().mapNotNull { it.obj() }

            val n = MeetingNotes(summary = s(root["summary"]))
            val title = s(root["title"]).trim('"', '“', '”', '「', '」', '《', '》')
            n.title = title.ifEmpty { null }
            for (t in objects(root["topics"])) {
                val topicTitle = s(t["title"])
                if (topicTitle.isEmpty()) continue
                var fish: Fishbone? = null
                t["fishbone"].obj()?.let { f ->
                    val branches = objects(f["branches"]).map { br ->
                        FishboneBranch(label = s(br["label"]), detail = s(br["detail"]), t = time(br["evidence"]) ?: br["t"].num(), support = support(br["evidence"]))
                    }.filter { it.label.isNotEmpty() }.toMutableList()
                    if (branches.size >= 2) fish = Fishbone(s(f["question"]), branches)
                }
                val points = mutableListOf<String>()
                val pointTimes = mutableListOf<Double?>()
                for (p in t["points"].arr()) {
                    val po = p.obj()
                    val text = if (po != null) s(po["text"]) else s(p)
                    if (text.isEmpty()) continue
                    points.add(text)
                    pointTimes.add(po?.let { time(it["evidence"]) })
                }
                val said = (listOf(time(t["evidence"])) + pointTimes).filterNotNull().minOrNull()
                n.topics.add(NoteTopic(start = said ?: t["start"].num() ?: startedAt, title = topicTitle, summary = s(t["summary"]), points = points,
                                       pointTimes = if (pointTimes.any { it != null }) pointTimes else null, fishbone = fish))
            }
            fun items(key: String) = objects(root[key]).map { i ->
                NoteItem(text = s(i["text"]), owner = s(i["owner"]).ifEmpty { null }, support = support(i["evidence"]), t = time(i["evidence"]))
            }.filter { it.text.isNotEmpty() }.toMutableList()
            n.conclusions = items("conclusions")
            n.todos = items("todos")
            n.terms = objects(root["terms"]).map { t ->
                val name = s(t["name"])
                NoteTerm(name = name, note = s(t["note"]), heard = t["heard"].arr().map { s(it) }.filter { it.isNotEmpty() && it != name }.toMutableList())
            }.filter { it.name.isNotEmpty() }.toMutableList()
            if (n.terms.size > 20) n.terms = NoteTerm.ordered(n.terms).take(20).toMutableList()
            return if (n.isEmpty) null else n
        }
    }
}
