package cicada

import kotlin.math.sqrt

/// Each heard line's audio becomes a voiceprint (WeSpeaker ResNet34-LM, VoxCeleb, CC BY 4.0),
interface Voiceprinter {
    fun embed(samples: ShortArray): FloatArray?
}

class VoiceClusterer {
    private val sums = ArrayList<FloatArray>()

    fun merge(from: Int, into: Int) {
        if (from !in sums.indices || into !in sums.indices || from == into) return
        val a = sums[into]; val b = sums[from]
        for (i in a.indices) a[i] += b[i]
        b.fill(0f)
    }

    fun label(v: FloatArray, seconds: Double): Int? {
        var best = -1; var bestSim = -1f
        for ((i, s) in sums.withIndex()) {
            var dot = 0f; var sq = 0f
            for (k in s.indices) { dot += v[k] * s[k]; sq += s[k] * s[k] }
            val sim = dot / maxOf(sqrt(sq), 1.1920929e-07f)
            if (sim > bestSim) { bestSim = sim; best = i }
        }
        if (best >= 0 && bestSim >= JOIN) {
            val s = sums[best]
            for (k in s.indices) s[k] += v[k]
            return best
        }
        if (seconds >= NEW_SECONDS && (sums.isEmpty() || bestSim < START_NEW)) {
            sums.add(v.copyOf())
            return sums.size - 1
        }
        return null
    }

    companion object {
        const val NEW_SECONDS = 2.0
        const val JOIN = 0.5f
        const val START_NEW = 0.5f
    }
}

open class SpeakerTagger(private val voiceprints: Voiceprinter?) {
    private val gate = Any()
    private var clusterer = VoiceClusterer()

    val available: Boolean get() = voiceprints != null

    fun reset() = synchronized(gate) { clusterer = VoiceClusterer() }

    fun merge(from: Int, into: Int) = synchronized(gate) { clusterer.merge(from, into) }

    fun embed(samples: ShortArray): FloatArray? {
        if (samples.size < MIN_SECONDS * Segmenter.RATE) return null
        return voiceprints?.embed(samples)
    }

    open fun label(vector: FloatArray?, seconds: Double): Int? {
        vector ?: return null
        return synchronized(gate) { clusterer.label(vector, seconds) }
    }

    companion object { const val MIN_SECONDS = 0.5 }
}

class SpeakerNamer(private val ling: LingClient, private val store: SessionStore) {
    private val gate = Any()
    private val busy = HashSet<String>()
    private val asked = HashMap<String, Int>()

    fun guess(id: String, force: Boolean = false) {
        val s = store.get(id) ?: return
        if (!ling.hasKey) return
        val text: String
        val lines: List<TranscriptLine>
        synchronized(gate) {
            lines = store.lines(id)
            if (id in busy || !(force || lines.size >= (asked[id] ?: -1000) + 20)) return
            text = content(lines) ?: return
            val numbers = SpeakerLabels.voiceNumbers(lines)
            if (numbers.keys.all { s.voiceNames?.get(it.toString()) != null }) return
            busy.add(id)
            asked[id] = lines.size
        }
        Thread({
            try {
                val reply = ling.chat(text, INSTRUCTION, Priority.Notes, json = true, maxTokens = 300)
                val (found, refuted) = read(reply, lines)
                for ((key, g) in s.voiceGuesses ?: emptyMap()) {
                    val v = key.toIntOrNull() ?: continue
                    if (v !in found && !holds(g, v, lines)) refuted[v] = g.name
                }
                store.setVoiceGuesses(id, found, refuted)
                Log.d("speakers: names ${found.size} found, ${refuted.size} without evidence")
            } catch (e: LingException) {
                Log.d("speakers: names, ling failed ${e.message}")
            } catch (e: Exception) {
                Log.d("speakers: names failed ${e.javaClass.simpleName}")
            } finally {
                synchronized(gate) { busy.remove(id) }
            }
        }, "SpeakerNames").apply { isDaemon = true }.start()
    }

    companion object {
        const val INSTRUCTION = "Who are the people labelled 说话人N? Name one only when the transcript makes it clear: they " +
            "introduce themselves on a line labelled with their own 说话人N; someone addresses them by name just " +
            "before or after they speak (\"Thanks, George\" right after 说话人1's answer: 说话人1 is George); " +
            "or others name them as they speak. A name on a 对方 line, or far from any line of 说话人N (an advert, " +
            "a clip, people introducing themselves on another show), is not theirs. Speech recognition writes " +
            "names by ear and often misspells them: for a public figure (an official, an executive, a presenter) " +
            "recognisable from the name and what is said, write the name as the news spells it (\"Jensen Hwang\" " +
            "→ \"Jensen Huang\"); otherwise as written. Leave out anyone " +
            "you are unsure of. Reply as JSON: {\"speakers\": [{\"speaker\": 2, \"name\": \"George\", \"evidence\": \"L12\"}]}, " +
            "the evidence being the line with the name; an empty list if none. Check each name's spelling before replying."

        const val EVIDENCE_REACH = 2

        fun content(lines: List<TranscriptLine>): String? {
            val numbers = SpeakerLabels.voiceNumbers(lines)
            if (numbers.isEmpty()) return null
            val sb = StringBuilder("Meeting transcript. Speakers: 你 = the user; 说话人N = one person on the other side, told apart by voice; " +
                "对方 = someone on the other side, not identified.\n")
            for ((i, l) in lines.takeLast(400).withIndex()) {
                val n = if (l.speaker == "them") l.voice?.let { numbers[it] } else null
                val who = if (l.speaker == "me") "你" else if (n != null) "说话人$n" else "对方"
                sb.append("[L${i + 1} ${Languages.clock(l.t)} $who] ${l.shown}\n")
            }
            return sb.toString()
        }

        fun read(reply: String, all: List<TranscriptLine>): Pair<MutableMap<Int, VoiceGuess>, MutableMap<Int, String>> {
            val found = LinkedHashMap<Int, VoiceGuess>(); val refuted = LinkedHashMap<Int, String>()
            val a = reply.indexOf('{'); val z = reply.lastIndexOf('}')
            val list = (if (a in 0 until z) Json.parseObject(reply.substring(a, z + 1)) else null)?.get("speakers").arr() ?: return found to refuted
            val voiceOf = SpeakerLabels.voiceNumbers(all).entries.associate { (v, n) -> n to v }
            val lines = all.takeLast(400)
            fun count(v: Int) = all.count { it.voice == v }
            for (item in list) {
                val o = item.obj() ?: continue
                val n = o["speaker"]?.toString()?.removeSuffix(".0")?.toIntOrNull() ?: continue
                val v = voiceOf[n] ?: continue
                val name = o["name"].str()?.trim() ?: continue
                if (name.isEmpty() || name.length > 40) continue
                val e = o["evidence"]?.toString() ?: ""
                val i = (e.dropWhile { !it.isDigit() }.takeWhile { it.isDigit() }.toIntOrNull() ?: 0) - 1
                val near = if (i in lines.indices) lines.subList(maxOf(0, i - EVIDENCE_REACH), minOf(lines.size, i + EVIDENCE_REACH + 1)) else emptyList()
                if (near.none { it.speaker == "them" && it.voice == v }) { refuted[v] = name; continue }
                val other = found.entries.firstOrNull { it.value.name == name }?.key
                if (other != null) {
                    if (count(other) >= count(v)) continue
                    found.remove(other)
                }
                val l = lines[i]
                val quote = if (l.shown.length > 60) l.shown.take(60) + "…" else l.shown
                found[v] = VoiceGuess(name, "${Languages.clock(l.t)} “$quote”")
            }
            return found to refuted
        }

        fun holds(g: VoiceGuess, v: Int, lines: List<TranscriptLine>): Boolean {
            if (!g.evidence.contains("“")) return true
            val at = g.evidence.substringBefore("“").trim()
            val quote = g.evidence.substringAfter("“").removeSuffix("”").substringBefore("…")
            for ((i, l) in lines.withIndex()) {
                if (Languages.clock(l.t) == at && l.shown.startsWith(quote))
                    return lines.subList(maxOf(0, i - EVIDENCE_REACH), minOf(lines.size, i + EVIDENCE_REACH + 1))
                        .any { it.speaker == "them" && it.voice == v }
            }
            return true
        }
    }
}
