package cicada

import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class ListenEngine(
    private val ling: LingClient,
    private val translator: Translator,
    private val store: SessionStore,
    private val notes: NotesEngine,
    private val settings: AppSettings,
) {
    private val gate = Any()
    private val pool = Executors.newCachedThreadPool { r -> Thread(r, "Listen").apply { isDaemon = true } }
    private var source: AudioSource? = null
    private var audio: LinkedBlockingQueue<ShortArray>? = null
    private var worker: Thread? = null
    private val done = HashMap<Int, Heard?>()
    private val segments = HashMap<Int, Segment>()
    private val inFlight = mutableListOf<Future<*>>()
    private var nextToDeliver = 1
    private var lineCount = 0
    private var last: TranscriptLine? = null
    private var lastEnd = 0.0
    private var hint: String? = null
    private var candidate: String? = null
    private var candidateVotes = 0
    private val listeners = mutableListOf<() -> Unit>()
    private val deliverLock = Any()

    @Volatile var speakers: SpeakerTagger? = null
    @Volatile var fixes: LiveFixes? = null
    @Volatile var onVoice: ((String) -> Unit)? = null
    private val voicePool = Executors.newSingleThreadExecutor { r -> Thread(r, "Voiceprints").apply { isDaemon = true } }
    private val voiceprints = HashMap<Int, Future<FloatArray?>>()
    private var voicesWaiting = 0
    private val voicesOn: Boolean get() = settings.speakerVoices && speakers?.available == true

    @Volatile var listening = false; private set
    @Volatile var sessionId: String? = null; private set
    @Volatile var sourceKind: String? = null; private set
    val spoken: String? get() = synchronized(gate) { hint }
    val pending: Int get() = synchronized(gate) { segments.size }
    @Volatile var problem: String? = null; private set
    @Volatile var problemKind: String? = null; private set
    private var serverErrors = 0
    @Volatile var level = 0.0; private set
    @Volatile var heardSeconds = 0.0; private set
    @Volatile var peak = 0.0; private set

    @Volatile var encoder: (ShortArray) -> Clip? = { null }

    init {
        translator.glossary = { notes.glossary() }
        notes.language = { Languages.englishName(settings.notesCode) }
    }

    fun onChange(listener: () -> Unit) { synchronized(listeners) { listeners.add(listener) } }
    private fun changed() { synchronized(listeners) { listeners.toList() }.forEach { it() } }

    val target: String get() = settings.targetCode

    private val END = ShortArray(0)
    private val HOLD = ShortArray(0)
    private val RELEASE = ShortArray(0)

    // MARK: 我说 (面对面 only): hold, say something, release → Ming → spoken in their language.

    var onWords: (() -> Unit)? = null

    var onSaid: ((text: String, lang: String) -> Unit)? = null
    @Volatile var holding = false; private set
    @Volatile var saying = false; private set
    @Volatile var muted = false
    @Volatile var sayProblem: String? = null; private set
    private val mine = ArrayList<ShortArray>()
    private var holdStart = 0.0
    private var saidCount = 0

    val canSay: Boolean get() = listening && sourceKind == "mic"

    val theirLanguage: String get() {
        val me = target
        val heard = spoken
        if (heard != null && !Languages.same(heard, me)) return heard
        return if (me.startsWith("en")) "zh-CN" else "en"
    }

    fun hold() {
        if (!canSay || holding) return
        holding = true
        sayProblem = null
        audio?.offer(HOLD)
        changed()
    }

    fun sayFailed(why: String) { sayProblem = why; changed() }

    fun inject(pcm: ShortArray) {
        var i = 0
        while (i < pcm.size) { audio?.offer(pcm.copyOfRange(i, minOf(pcm.size, i + 1600))); i += 1600 }
    }

    fun debugHeard(text: String, lang: String? = null) {
        val id = sessionId ?: return
        if (!listening) return
        val at = store.get(id)?.let { (System.currentTimeMillis() - it.startedAt.toEpochMilli()) / 1000.0 } ?: 0.0
        val seg = Segment(0, Math.round(at * 10) / 10.0, ShortArray(0))
        pool.execute { synchronized(deliverLock) { record(seg, Heard(lang ?: spoken ?: "zh-CN", text, null), null) }; changed() }
    }

    fun release() {
        if (!holding) return
        holding = false
        audio?.offer(RELEASE)
        changed()
    }

    @Volatile var tap: ((ShortArray) -> Unit)? = null

    fun start(from: AudioSource, kind: String) {
        if (listening) return
        val session = store.begin()
        sessionId = session.id
        sourceKind = kind
        synchronized(gate) {
            done.clear(); segments.clear(); inFlight.clear(); voiceprints.clear()
            nextToDeliver = 1; lineCount = 0; last = null; lastEnd = 0.0
            hint = null; candidate = null; candidateVotes = 0; problem = null; problemKind = null; serverErrors = 0
        }
        holding = false; saying = false; muted = false; sayProblem = null; saidCount = 0
        heardSeconds = 0.0; peak = 0.0
        notes.begin(session.id)
        speakers?.reset()
        fixes?.meetingStarted()
        val segmenter = Segmenter(if (kind == "mic") VoiceGate() else null)
        segmenter.onSegment = ::send
        val queue = LinkedBlockingQueue<ShortArray>()
        audio = queue
        worker = Thread({
            var mineOpen = false
            while (true) {
                val buf = queue.take()
                if (buf === END) break
                if (buf === HOLD) { mineOpen = true; synchronized(mine) { mine.clear() }; holdStart = heardSeconds; continue }
                if (buf === RELEASE) { if (mineOpen) { mineOpen = false; finishSaying() }; continue }
                if (mineOpen) synchronized(mine) { mine.add(buf) }
                segmenter.feed(if (mineOpen || muted) ShortArray(buf.size) else buf)
                level = Wav.rms(buf)
                peak = maxOf(peak * 0.995, level)
                heardSeconds += buf.size / Segmenter.RATE.toDouble()
            }
            segmenter.flush()
        }, "ListenWorker").apply { isDaemon = true; start() }
        source = from
        from.onSamples = { tap?.invoke(it); queue.offer(it) }
        listening = true
        from.start()
        Log.d("listen: started ${session.id} source=$kind target=$target")
        changed()
    }

    fun stop(endedAt: java.time.Instant? = null) {
        if (!listening) return
        val id = sessionId ?: return
        listening = false
        source?.let { it.onSamples = null; it.stop() }
        audio?.offer(END)
        worker?.join(5000)
        val deadline = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < deadline) {
            val waiting = synchronized(gate) { inFlight.filter { !it.isDone } }
            if (waiting.isEmpty()) break
            for (f in waiting) {
                try { f.get(maxOf(1, deadline - System.currentTimeMillis()), TimeUnit.MILLISECONDS) } catch (_: Exception) {}
            }
        }
        store.end(id, endedAt)
        Log.d("listen: stopped $id, $lineCount lines")
        changed()
        pool.execute { notes.finish() }
    }

    private fun finishSaying() {
        val pcm = synchronized(mine) {
            val all = ShortArray(mine.sumOf { it.size }); var at = 0
            for (b in mine) { b.copyInto(all, at); at += b.size }
            mine.clear(); all
        }
        if (pcm.size < Segmenter.RATE / 2 || !PressSpeech.spoken(pcm)) {
            sayProblem = if (pcm.size < Segmenter.RATE / 2) Strings.L("按住说完再松开") else Strings.L("没听到声音，靠近手机再说")
            changed(); return
        }
        saying = true
        changed()
        val t = Math.round(holdStart * 1000) / 1000.0
        pool.execute { say(pcm, t) }
    }

    private fun say(pcm: ShortArray, t: Double) {
        val id = sessionId ?: run { saying = false; return }
        val their = theirLanguage
        val me = target
        try {
            val heard = translator.hear(encode(pcm), their, me, pcm.size / Segmenter.RATE.toDouble())
            if (heard == null) { sayProblem = Strings.L("没听清，再说一次"); return }
            if (PressSpeech.filler(heard.original)) { Log.d("listen: only a filler heard, not said"); return }
            var dst = heard.translation
            if (dst == null && !Languages.same(heard.lang, their)) dst = translator.translate(heard.original, heard.lang, their, Translator.Kind.Speak)
            val sameLanguage = Languages.same(heard.lang, their)
            val probe = TranscriptLine(speaker = "me", src = heard.original, dst = dst, srcLang = heard.lang, dstLang = their)
            val text = speakable(probe)
            Log.d("listen: said ${heard.lang} -> $their, ${if (text != null) "speaking" else "not spoken"}")
            if (text == null && !sameLanguage) { sayProblem = Strings.L("这句没翻译成 · 没有说出去"); return }
            val n = synchronized(gate) { ++saidCount }
            val line = TranscriptLine(id = "m$n", t = t, speaker = "me", src = heard.original, dst = dst,
                                      srcLang = heard.lang, dstLang = their)
            synchronized(gate) { last = null }
            store.append(id, line.copy())
            onWords?.invoke()
            if (text != null) onSaid?.invoke(text, their) else sayProblem = Strings.L("这句已经是对方的语言")
        } catch (e: LingException) {
            val name = ling.hearName
            sayProblem = when {
                e.kind == LingException.Kind.Http && e.status in listOf(400, 404) && name != "Ling" -> Strings.L("这个模型听不了声音，换一个支持音频输入的")
                e.kind == LingException.Kind.NoKey || e.kind == LingException.Kind.InvalidKey ->
                    if (name == "Ling") Strings.L("Ling key 无效") else Strings.LF("%@ 的 key 无效", Strings.L(name))
                e.kind == LingException.Kind.Network || e.kind == LingException.Kind.Timeout ->
                    Strings.LF("这句没说出去 · 连不上 %@", Strings.L(name))
                else -> Strings.L("没听清，再说一次")
            }
            Log.d("listen: saying failed ${e.message}")
        } catch (e: Exception) {
            sayProblem = Strings.L("没听清，再说一次")
            Log.d("listen: saying failed ${e.javaClass.simpleName}")
        } finally {
            saying = false
            changed()
        }
    }

    private fun encode(pcm: ShortArray): Clip {
        if (!ling.config().isLing) return Clip.wav(pcm)
        val clip = try { encoder(pcm) } catch (e: Exception) { Log.d("listen: encode failed ${e.message}"); null }
        if (clip == null || clip.bytes.isEmpty()) return Clip.wav(pcm)
        return clip
    }

    private fun send(seg: Segment) {
        if (voicesOn) {
            val behind = synchronized(gate) { (voicesWaiting >= 2).also { if (!it) voicesWaiting++ } }
            if (behind) Log.d("speakers: voiceprints behind, segment ${seg.index} left unlabelled")
            else {
                val f = voicePool.submit<FloatArray?> {
                    val started = System.currentTimeMillis()
                    try {
                        speakers?.embed(seg.samples).also {
                            Log.d("speakers: segment ${seg.index} ${"%.1f".format(seg.seconds)}s voiceprint in ${System.currentTimeMillis() - started} ms")
                        }
                    } finally { synchronized(gate) { voicesWaiting-- } }
                }
                synchronized(gate) { voiceprints[seg.index] = f }
            }
        }
        val lang = synchronized(gate) { segments[seg.index] = seg; hint }
        Log.d("listen: segment ${seg.index} sent at ${"%.2f".format(seg.start)}+${"%.2f".format(seg.seconds)}")
        changed()
        val future = pool.submit {
            var heard: Heard? = null
            val started = System.currentTimeMillis()
            try {
                val clip = encode(seg.samples)
                val asked = settings.targetFor(lang)
                heard = translator.hear(clip, asked, lang, seg.seconds)?.let { h ->
                    if (settings.targetFor(h.lang) == asked) h else h.copy(translation = null)
                }
                synchronized(gate) { serverErrors = 0 }
                problem = null; problemKind = null
            } catch (e: LingException) {
                val shown = synchronized(gate) {
                    serverErrors = if (serverError(e)) serverErrors + 1 else 0
                    !serverError(e) || serverErrors >= SERVER_ERRORS_SHOWN
                }
                if (shown) {
                    val (kind, text) = problem(e, ling.hearName)
                    problemKind = kind; problem = text
                }
                Log.d("listen: segment ${seg.index} failed ${e.message}")
            } catch (e: Exception) {
                Log.d("listen: segment ${seg.index} failed ${e.javaClass.simpleName}")
            }
            Log.d("listen: segment ${seg.index} ${"%.1f".format(seg.seconds)}s -> ${heard?.lang ?: "nothing"} in ${System.currentTimeMillis() - started} ms")
            synchronized(gate) { done[seg.index] = heard }
            deliver()
        }
        synchronized(gate) { inFlight.add(future); inFlight.removeAll { it.isDone } }
    }

    private fun deliver() {
        val ready = mutableListOf<Pair<Segment, Heard?>>()
        synchronized(deliverLock) {
            synchronized(gate) {
                while (done.containsKey(nextToDeliver)) {
                    val heard = done.remove(nextToDeliver)
                    ready.add(segments.remove(nextToDeliver)!! to heard)
                    nextToDeliver++
                }
            }
            for ((seg, heard) in ready) {
                val print = synchronized(gate) { voiceprints.remove(seg.index) }
                if (heard != null) record(seg, heard, voice(print, seg, heard))
            }
        }
        if (ready.isNotEmpty()) changed()
    }

    private fun voice(print: Future<FloatArray?>?, seg: Segment, heard: Heard): Int? {
        if (print == null || heard.original.count { it.isLetter() } < 2) return null
        val vector = try { print.get(20, TimeUnit.SECONDS) } catch (e: Exception) {
            Log.d("speakers: voiceprint failed ${e.javaClass.simpleName}"); return null
        }
        return speakers?.label(vector, seg.seconds)
    }

    private fun record(seg: Segment, heard: Heard, voice: Int?) {
        val id = sessionId ?: return
        val target = settings.targetFor(heard.lang)
        synchronized(gate) {
            val h = hint
            if (h == null) hint = heard.lang
            else if (heard.lang != h) {
                if (candidate == heard.lang) candidateVotes++ else { candidate = heard.lang; candidateVotes = 1 }
                if (candidateVotes >= 2) { hint = candidate; candidate = null; candidateVotes = 0 }
            } else { candidate = null; candidateVotes = 0 }
        }

        val line: TranscriptLine
        var joined = false
        synchronized(gate) {
            val prev = last
            if (prev != null && continues(prev, seg.start - lastEnd, heard) && (voice == null || prev.voice == null || voice == prev.voice)) {
                prev.src = join(prev.src, heard.original, heard.lang)
                prev.dst = if (prev.dst == null || heard.translation == null) null else join(prev.dst!!, heard.translation, target)
                line = prev
                joined = true
            } else {
                line = TranscriptLine(id = "h${++lineCount}-${seg.index}", t = seg.start, speaker = "them",
                                      src = heard.original, dst = heard.translation, srcLang = heard.lang, dstLang = target, voice = voice)
                last = line
            }
            lastEnd = seg.start + seg.seconds
        }
        val copy = synchronized(gate) { line.copy() }
        if (!joined && heard.translation != null) translator.sentencesUntranslated = false
        if (joined) store.replace(id, copy) else store.append(id, copy)
        fixes?.applyKnown(copy.id, id)
        if (voice != null) onVoice?.invoke(id)
        onWords?.invoke()

        if (!joined && line.dst != null && line.srcLang != target && fixes != null) {
            val src = line.src
            val f = pool.submit {
                val dst = translator.fixLine(src, line.srcLang, target) ?: return@submit
                val updated = synchronized(gate) {
                    if (line.src != src) return@submit
                    line.dst = dst
                    line.copy()
                }
                store.replace(id, updated)
                changed()
            }
            synchronized(gate) { inFlight.add(f) }
        }
        if ((joined || line.dst == null) && line.srcLang != target) {
            val src = line.src
            pool.execute {
                val dst = translator.translate(src, line.srcLang, target, Translator.Kind.Sentence)
                if (dst == null) { changed(); return@execute }
                val updated = synchronized(gate) {
                    if (dst == null || line.src != src) return@execute
                    line.dst = dst
                    line.copy()
                }
                store.replace(id, updated)
                changed()
            }
        }
    }

    companion object {
        const val SERVER_ERRORS_SHOWN = 3

        fun serverError(e: LingException) = e.kind == LingException.Kind.Http && e.status >= 500

        fun problem(e: LingException, service: String): Pair<String?, String?> {
            val ling = service == "Ling"
            if (e.kind == LingException.Kind.Http && (e.status == 400 || e.status == 404) && !ling)
                return "key" to Strings.L("这个模型听不了声音，换一个支持音频输入的")
            if (serverError(e)) return "busy" to Strings.LF("%@ 暂时出错（HTTP %lld），稍后再试。", Strings.L(service), e.status)
            val kind = when (e.kind) {
                LingException.Kind.NoKey, LingException.Kind.InvalidKey -> "key"
                LingException.Kind.RateLimited -> "busy"
                LingException.Kind.Network, LingException.Kind.Timeout -> "network"
                else -> null
            }
            val name = Strings.L(service)
            val text = when (e.kind) {
                LingException.Kind.NoKey -> if (ling) Strings.L("需要 Ling key 才能听") else Strings.LF("需要 %@ 的 key 才能听", name)
                LingException.Kind.InvalidKey -> if (ling) Strings.L("Ling key 无效") else Strings.LF("%@ 的 key 无效", name)
                LingException.Kind.RateLimited -> if (ling) Strings.L("Ling 太忙，稍后再试") else Strings.LF("%@ 太忙，稍后再试", name)
                LingException.Kind.Network, LingException.Kind.Timeout -> Strings.LF("字幕和纪要等 %@ 恢复 · 连上后自动继续", name)
                else -> null
            }
            return kind to text
        }

        fun speakable(line: TranscriptLine): String? {
            val dst = line.dst?.trim() ?: return null
            if (line.speaker != "me" || dst.isEmpty() || Languages.same(line.srcLang, line.dstLang) || dst == line.src.trim()) return null
            return dst
        }

        fun continues(last: TranscriptLine, gap: Double, next: Heard): Boolean {
            if (gap > 0.8 || last.srcLang != next.lang) return false
            val text = last.src.trimEnd()
            if (text.isEmpty() || ".!?。！？…".contains(text.last())) return false
            val cjk = Languages.isCjkLanguage(next.lang)
            val size = if (cjk) text.length + next.original.length else "$text ${next.original}".split(' ').count { it.isNotEmpty() }
            return size <= if (cjk) 80 else 45
        }

        fun join(a: String, b: String, lang: String): String {
            val cjk = lang.startsWith("zh") || lang.startsWith("ja")
            return if (cjk) a.trimEnd() + b.trimStart() else a.trimEnd() + " " + b.trimStart()
        }
    }
}

object PressSpeech {
    private const val FRAME = 480
    private const val NEEDED = 0.3
    private val fillers = setOf("嗯", "啊", "呃", "哦", "唔", "额", "噢", "哎", "um", "uh", "hmm", "hm", "mm", "mhm", "ah", "oh", "er", "えー", "あの", "음", "어")

    fun spoken(pcm: ShortArray): Boolean {
        if (pcm.size < FRAME) return false
        val levels = ArrayList<Double>()
        var i = 0
        while (i + FRAME <= pcm.size) {
            var sum = 0.0
            for (k in i until i + FRAME) { val v = pcm[k] / 32768.0; sum += v * v }
            levels.add(Math.sqrt(sum / FRAME))
            i += FRAME
        }
        val floor = levels.sorted()[levels.size / 10]
        val line = minOf(0.016, maxOf(0.0063, floor * 3))
        return levels.count { it >= line } * FRAME / 16000.0 >= NEEDED
    }

    fun filler(text: String): Boolean {
        val trimmed = text.trim()
        if (trimmed.length in 1..12 && trimmed.last() in ":：") return true
        val words = text.lowercase().split(Regex("[^\\p{L}]+")).filter { it.isNotEmpty() }
        return words.isEmpty() || words.all { w -> w in fillers || (w.length > 1 && w.toSet().size == 1 && w.substring(0, 1) in fillers) }
    }
}

