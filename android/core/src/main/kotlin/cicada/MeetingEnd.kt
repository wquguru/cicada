package cicada

class MeetingEndWatch(var config: Config, start: Double) {
    enum class Silence(val key: String) {
        Prompt("prompt"), End("end"), Off("off");
        companion object { fun of(key: String) = values().firstOrNull { it.key == key } ?: Prompt }
    }

    data class Config(
        val followApps: Boolean = true,
        val silence: Silence = Silence.Prompt,
        val silenceAfter: Double = 600.0,
        val countdown: Double = 60.0,
        val appGrace: Double = 30.0,
    )

    sealed class Reason {
        data class AppLeft(val name: String) : Reason()
        object Silence : Reason() { override fun toString() = "silence" }
        object NobodySpoke : Reason() { override fun toString() = "nobodySpoke" }
    }

    data class Pending(val reason: Reason, val deadline: Double)

    var pending: Pending? = null; private set
    var lastSpeech: Double = start; private set
    var inCall: Map<String, String> = emptyMap(); private set

    fun heard(now: Double) {
        lastSpeech = now
        if (pending?.reason == Reason.Silence) pending = null
    }

    fun keepGoing(now: Double) {
        pending = null
        lastSpeech = now
        inCall = emptyMap()
    }

    fun tick(now: Double, calls: Map<String, String>, said: Boolean): Reason? {
        if (!said) {
            inCall = if (config.followApps) calls else emptyMap()
            pending = null
            val inACall = config.followApps && calls.isNotEmpty()
            if (config.silence != Silence.Off && !inACall && now - lastSpeech >= config.silenceAfter) return Reason.NobodySpoke
            return null
        }
        if (config.followApps) {
            inCall = inCall + calls
            val hungUp = inCall.isNotEmpty() && inCall.keys.all { calls[it] == null }
            if (pending?.reason is Reason.AppLeft && !hungUp) pending = null
            if (hungUp && (pending == null || pending?.reason == Reason.Silence)) {
                val name = inCall.toSortedMap().values.firstOrNull() ?: ""
                pending = Pending(Reason.AppLeft(name), now + config.appGrace)
            }
        } else if (pending?.reason is Reason.AppLeft) {
            pending = null
        }
        val inACall = config.followApps && calls.isNotEmpty()
        if (pending == null && config.silence != Silence.Off && !inACall && now - lastSpeech >= config.silenceAfter) {
            if (config.silence == Silence.End) return Reason.Silence
            pending = Pending(Reason.Silence, now + config.countdown)
        }
        if ((config.silence == Silence.Off || inACall) && pending?.reason == Reason.Silence) pending = null
        val p = pending
        if (p != null && now >= p.deadline) {
            pending = null
            return p.reason
        }
        return null
    }
}
