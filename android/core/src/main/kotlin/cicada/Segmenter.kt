package cicada

class Segment(val index: Int, val start: Double, val samples: ShortArray) {
    val seconds get() = samples.size / Segmenter.RATE.toDouble()
}

class Segmenter(private val gate: VoiceGate? = null) {
    companion object {
        const val RATE = 16000
        private const val FRAME = 480
        private const val STEP = 160
        private const val ONSET = 3
        @Volatile var threshold = 0.01
        @Volatile var pause = 0.6
        @Volatile var maxLength = 8.0
        @Volatile var minSpeech = 0.25
        @Volatile var minWord = 0.2
        @Volatile var steady = 2.0
        @Volatile var dips = 2.5
        @Volatile var short = 2.0
        @Volatile var swell = Math.pow(10.0, 10 / 20.0)
        @Volatile var fade = Math.pow(10.0, 30 / 20.0)
        @Volatile var voiced = 0.15
        private const val PRE_ROLL = 0.15
        private const val TAIL = 0.15
        private const val CUT_WINDOW = 2.0
        @Volatile var above = 0.25
        private val HIGH_PASS = 1.0 / (1.0 + 2.0 * Math.PI * 100.0 / RATE)
    }

    private val pending = ShortList()
    private val current = ShortList()
    private val levels = ArrayList<Double>()
    private val highs = ArrayList<Double>()
    private val speech = ArrayList<Boolean>()
    private var sounding = 0
    private var carried = false
    private var hx = 0.0
    private var hy = 0.0
    private val before = ArrayDeque<Triple<ShortArray, Double, Double>>()
    private val idle = ArrayDeque<Double>()
    private var lead: Double? = null
    private var consumed = 0L
    private var currentStart = 0.0
    private var quietFrames = 0
    private var loudFrames = 0
    private var index = 0
    private var line = threshold

    var onSegment: ((Segment) -> Unit)? = null

    fun feed(samples: ShortArray) {
        pending.addAll(samples, 0, samples.size)
        val whole = pending.size / FRAME * FRAME
        var i = 0
        while (i < whole) { step(pending.slice(i, i + FRAME)); i += FRAME }
        pending.removeFirst(whole)
    }

    fun flush() {
        if (current.size > 0) close(current.size - quietFrames * FRAME + (TAIL * RATE).toInt())
    }

    private fun isSpeech(frame: ShortArray, level: Double): Boolean {
        gate?.let { g ->
            val on = g.voiced(level, FRAME / RATE.toDouble())
            sounding = if (on) sounding + FRAME / STEP else 0
            carried = false
            return on
        }
        var said = false
        var early = sounding > 0
        var i = 0
        while (i < frame.size) {
            val end = minOf(frame.size, i + STEP)
            var sum = 0.0
            for (k in i until end) sum += frame[k].toDouble() * frame[k]
            if (Math.sqrt(sum / (end - i)) / 32768 >= line) {
                if (++sounding >= ONSET && !said) { said = true; carried = early }
            } else { sounding = 0; early = false }
            i = end
        }
        return said
    }

    private fun step(frame: ShortArray) {
        val level = Wav.rms(frame)
        val high = high(frame)
        line = gate?.threshold ?: threshold
        val loud = isSpeech(frame, level)
        val now = consumed / RATE.toDouble()
        consumed += frame.size

        if (current.size == 0) {
            if (!loud) {
                idle.addLast(level)
                while (idle.size > (pause * RATE / FRAME).toInt()) idle.removeFirst()
                before.addLast(Triple(frame, level, high))
                while (before.size > PRE_ROLL * RATE / FRAME + 1) before.removeFirst()
                return
            }
            while (before.size > PRE_ROLL * RATE / FRAME + (if (carried) 1 else 0)) before.removeFirst()
            currentStart = now - before.size * FRAME / RATE.toDouble()
            lead = idle.minOrNull()
            idle.clear()
            for ((f, l, h) in before) { current.addAll(f, 0, f.size); levels.add(l); highs.add(h); speech.add(false) }
            before.clear()
            quietFrames = 0; loudFrames = 0
        }

        current.addAll(frame, 0, frame.size)
        levels.add(level)
        highs.add(high)
        speech.add(loud)
        if (loud) { quietFrames = 0; loudFrames++ } else quietFrames++

        if (quietFrames * FRAME >= pause * RATE) {
            close(current.size - quietFrames * FRAME + (TAIL * RATE).toInt())
        } else if (current.size >= maxLength * RATE) {
            val from = maxOf(1, levels.size - (CUT_WINDOW * RATE / FRAME).toInt())
            var cut = from
            for (i in from until levels.size) if (levels[i] < levels[cut]) cut = i
            close(cut * FRAME)
        }
    }

    internal fun isSteady(frameLevels: List<Double>): Boolean {
        val first = frameLevels.indexOfFirst { it >= line }
        val last = frameLevels.indexOfLast { it >= line }
        if (first < 0 || last <= first) return false
        val body = frameLevels.subList(first, last + 1)
        val top = body.map { maxOf(it, line) }.sorted()
        if (top[(0.9 * (top.size - 1)).toInt()] >= steady * top[(0.1 * (top.size - 1)).toInt()]) return false
        val low = body.map { maxOf(it, line / 8) }.sorted()
        return low[(0.5 * (low.size - 1)).toInt()] < dips * low[(0.1 * (low.size - 1)).toInt()]
    }

    internal fun isWord(frameLevels: List<Double>): Boolean {
        val first = frameLevels.indexOfFirst { it >= line }
        val last = frameLevels.indexOfLast { it >= line }
        if (first < 0 || (last - first + 1) * FRAME > short * RATE) return false
        val quiet = line / 4
        val q = lead ?: return false
        if (q > quiet || last + 1 >= frameLevels.size || frameLevels.subList(last + 1, frameLevels.size).minOrNull()!! > quiet) return false
        val samples = current.slice(0, current.size)
        val steps = ArrayList<Double>()
        var i = 0
        while (i + STEP <= samples.size) {
            var sum = 0.0
            for (k in i until i + STEP) sum += samples[k].toDouble() * samples[k]
            steps.add(Math.sqrt(sum / STEP) / 32768)
            i += STEP
        }
        val rise = minOf(quiet, steps.max() / fade)
        val from = steps.indexOfFirst { it >= rise }
        val to = steps.indexOfLast { it >= rise }
        val body = steps.subList(from, to + 1).map { maxOf(it, line / 8) }.sorted()
        val low = maxOf(2, (0.05 * (body.size - 1)).toInt())
        return low < body.size && body[(0.9 * (body.size - 1)).toInt()] >= swell * body[low] && isVoiced(frameLevels, samples)
    }

    private fun isVoiced(frameLevels: List<Double>, samples: ShortArray): Boolean {
        val full = frameLevels.sorted()[(0.9 * (frameLevels.size - 1)).toInt()] / Math.sqrt(2.0)
        var slow = 0
        for (i in frameLevels.indices) {
            if (frameLevels[i] < full) continue
            val start = i * FRAME
            val end = minOf(samples.size, start + FRAME)
            var crossings = 0
            for (k in start + 1 until end) if ((samples[k] >= 0) != (samples[k - 1] >= 0)) crossings++
            if (crossings < voiced * (end - start - 1)) slow++
        }
        return slow >= 2
    }

    private fun high(frame: ShortArray): Double {
        val a = HIGH_PASS
        var x0 = hx; var y = hy; var total = 0.0
        for (s in frame) {
            val x = s.toDouble()
            y = a * (y + x - x0)
            x0 = x
            total += y * y
        }
        hx = x0; hy = y
        return if (frame.isEmpty()) 0.0 else Math.sqrt(total / frame.size) / 32768
    }

    internal fun isRumble(frameLevels: List<Double>, frameHighs: List<Double>): Boolean {
        var full = 0.0; var above = 0.0
        for (i in 0 until minOf(frameLevels.size, frameHighs.size)) {
            if (frameLevels[i] < line) continue
            full += frameLevels[i] * frameLevels[i]
            above += frameHighs[i] * frameHighs[i]
        }
        return above < Segmenter.above * full
    }

    private fun close(endAt: Int) {
        val end = endAt.coerceIn(0, current.size)
        val samples = current.slice(0, end)
        val rest = current.slice(end, current.size)
        val restLevels = ArrayList(levels.subList(minOf(levels.size, end / FRAME), levels.size))
        val restHighs = ArrayList(highs.subList(minOf(highs.size, end / FRAME), highs.size))
        val restSpeech = ArrayList(speech.subList(minOf(speech.size, end / FRAME), speech.size))
        val start = currentStart
        val sent = ArrayList(levels.subList(0, minOf(levels.size, end / FRAME)))
        val said = if (isWord(levels)) sent.count { it >= line / 4 } * FRAME >= minWord * RATE
            else loudFrames * FRAME >= minSpeech * RATE && !isSteady(sent)
        val heard = said && !isRumble(sent, ArrayList(highs.subList(0, sent.size)))
        current.clear(); levels.clear(); highs.clear(); speech.clear()
        quietFrames = 0; loudFrames = 0
        if (heard) onSegment?.invoke(Segment(++index, Math.round(start * 1000) / 1000.0, samples))

        if (restSpeech.any { it }) {
            currentStart = start + end / RATE.toDouble()
            lead = null
            current.addAll(rest, 0, rest.size)
            levels.addAll(restLevels)
            highs.addAll(restHighs)
            speech.addAll(restSpeech)
            var trailing = 0
            for (i in speech.indices.reversed()) { if (speech[i]) break; trailing++ }
            quietFrames = trailing
            loudFrames = speech.count { it }
        }
    }
}

class VoiceGate {
    companion object {
        const val FIXED = 0.01
        const val LOWEST = 0.0015
    }
    private val quietest = ArrayDeque<Double>()
    private var second = Double.POSITIVE_INFINITY
    private var elapsed = 0.0

    val threshold: Double get() {
        if (quietest.size < 3) return 0.004
        val floor = quietest.sorted()[quietest.size / 5]
        return minOf(FIXED, maxOf(LOWEST, floor * 2))
    }

    fun voiced(rms: Double, seconds: Double): Boolean {
        val on = rms >= threshold
        second = minOf(second, rms)
        elapsed += seconds
        if (elapsed >= 1 - 1e-9) {
            quietest.addLast(second)
            if (quietest.size > 30) quietest.removeFirst()
            second = Double.POSITIVE_INFINITY
            elapsed = 0.0
        }
        return on
    }
}

internal class ShortList {
    private var a = ShortArray(RATE_HINT)
    var size = 0; private set

    fun addAll(src: ShortArray, from: Int, to: Int) {
        val n = to - from
        if (size + n > a.size) a = a.copyOf(maxOf(a.size * 2, size + n))
        System.arraycopy(src, from, a, size, n)
        size += n
    }

    fun slice(from: Int, to: Int): ShortArray = a.copyOfRange(from, to)

    fun removeFirst(n: Int) {
        System.arraycopy(a, n, a, 0, size - n)
        size -= n
    }

    fun clear() { size = 0 }

    private companion object { const val RATE_HINT = 16000 }
}
