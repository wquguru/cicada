package cicada

import cicada.Strings.L
import cicada.Strings.LF

data class AICheck(
    val steps: List<Step> = StepID.values().map { Step(it, State.Untested) },
    val at: Long? = null,
    val passive: Boolean = false,
    val proxy: ProxyHint? = null,
    val balance: Double? = null,
    val translate: Speed? = null,
    val notes: Notes? = null,
) {
    sealed class Notes {
        object Running : Notes() { override fun toString() = "running" }
        data class Ok(val seconds: Double) : Notes() {
            override fun toString() = "ok(${String.format(java.util.Locale.US, "%.1f", seconds)}s)"
        }
        data class Fail(val why: Reason, val code: Int? = null) : Notes() {
            override fun toString() = "fail(${lower(why.name)}${code?.let { " $it" } ?: ""})"
        }
        val ok get() = this is Ok
        val reason get() = (this as? Fail)?.why
    }

    data class Speed(val seconds: Double, val thinks: Boolean) {
        val slow get() = thinks || seconds >= SLOW_AFTER
        companion object { const val SLOW_AFTER = 3.0 }
    }

    enum class StepID { Reach, Key, Text, Hear }

    enum class Reason { Unreachable, BadAddress, InvalidKey, MgmtKey, NoCredit, NoModel, NoJSON, Deaf, Busy, ServerError }

    sealed class State {
        object Running : State()
        data class Ok(val seconds: Double? = null) : State()
        object Busy : State()
        data class Fail(val reason: Reason, val code: Int? = null) : State()
        object Skipped : State()
        object Untested : State()
    }

    data class Step(val id: StepID, val state: State)

    enum class ProxyHint { SystemOn, None }

    data class Failure(val step: StepID, val reason: Reason, val code: Int?)

    operator fun get(id: StepID): State = steps.firstOrNull { it.id == id }?.state ?: State.Untested

    fun with(id: StepID, state: State) = copy(steps = steps.map { if (it.id == id) Step(id, state) else it })

    val failure: Failure? get() {
        for (s in steps) { val st = s.state; if (st is State.Fail) return Failure(s.id, st.reason, st.code) }
        return null
    }

    val running get() = steps.any { it.state == State.Running } || notes == Notes.Running
    val notesFailed get() = notes?.reason.let { it != null && it != Reason.Busy }
    val busy get() = steps.any { it.state == State.Busy }
    val passed get() = at != null && failure == null && !running
    val lowBalance get() = (balance ?: Double.POSITIVE_INFINITY) < LOW_BALANCE
    val slow get() = textFailure == null && translate?.slow == true
    val textFailure get() = failure?.takeIf { it.step != StepID.Hear }

    val needsUser: Boolean get() {
        val f = failure ?: return lowBalance
        return f.reason != Reason.Busy && f.reason != Reason.ServerError
    }

    fun fail(step: StepID, reason: Reason, code: Int? = null, reached: Boolean = true): AICheck {
        val proves = proves(step)
        var after = false
        val next = steps.map { s ->
            when {
                s.id == step -> { after = true; Step(s.id, State.Fail(reason, code)) }
                after -> Step(s.id, State.Skipped)
                reached && s.id in proves && !isOk(s.state) -> Step(s.id, State.Ok())
                s.id !in proves && s.state == State.Skipped -> Step(s.id, State.Untested)
                s.state == State.Running -> Step(s.id, State.Untested)
                else -> s
            }
        }
        return copy(steps = next, proxy = if (reason == Reason.Unreachable) proxy else null)
    }

    fun pass(step: StepID, seconds: Double?): AICheck {
        val proves = proves(step)
        val next = steps.map { s ->
            when {
                s.id == step -> Step(s.id, State.Ok(seconds))
                s.id in proves -> if (isOk(s.state)) s else Step(s.id, State.Ok())
                s.state == State.Skipped -> Step(s.id, State.Untested)
                else -> s
            }
        }
        return copy(steps = next, proxy = null)
    }

    // MARK: Words

    fun message(service: String, host: String, model: String, hearModel: String): String? {
        val f = failure ?: return if (busy) LF("%@ 现在很忙，key 没问题。开会时会自动重试。", service) else null
        return when (f.reason) {
            Reason.Unreachable -> LF("这台手机访问不到 %@。", host)
            Reason.BadAddress -> L("地址要用 https；这台手机和局域网里的服务可以用 http。")
            Reason.InvalidKey -> LF("%@ 说这个 key 无效，可能没复制全，或已删除。", service)
            Reason.MgmtKey -> L("这是 ZenMux 的管理 key，不能用来调用模型。请粘贴 sk-payg 开头的 key。")
            Reason.NoCredit -> LF("%@ 账户余额不足。", service)
            Reason.NoModel -> LF("%@ 上找不到 %@ 这个模型。", service, model)
            Reason.NoJSON -> L("这个服务不支持 JSON，纪要写不了；翻译照常。")
            Reason.Deaf -> LF("%@ 听不了声音。", hearModel)
            Reason.Busy -> LF("%@ 现在很忙，key 没问题。开会时会自动重试。", service)
            Reason.ServerError -> LF("%@ 暂时出错（HTTP %lld），稍后再试。", service, f.code ?: 0)
        }
    }

    fun blocking(service: String, textModel: String, hearModel: String): Pair<String, String>? {
        val f = failure ?: return null
        val stops = L("修好之前听不了")
        val notesStop = L("字幕照常，纪要先停下")
        return when (f.reason) {
            Reason.InvalidKey, Reason.MgmtKey -> LF("%@ 的 key 用不了", service) to stops
            Reason.NoCredit -> LF("%@ 账户余额不足。", service) to stops
            Reason.NoModel -> LF("%@ 上找不到 %@ 这个模型。", service, textModel.substringAfterLast('/')) to notesStop
            Reason.Deaf -> LF("%@ 听不了声音。", hearModel.substringAfterLast('/')) to stops
            Reason.BadAddress -> L("AI 服务的设置要改一下") to stops
            Reason.NoJSON -> L("AI 服务的设置要改一下") to notesStop
            Reason.Unreachable, Reason.Busy, Reason.ServerError -> null
        }
    }

    fun slowLine(googleOff: Boolean = false): String? {
        val t = translate?.takeIf { slow } ?: return null
        val secs = String.format(Strings.locale, "%.1f", t.seconds)
        if (googleOff) return if (t.thinks) LF("这个模型先思考再回答，翻一句要 %@ 秒，超过 6 秒这句就不等它了。在服务端关掉思考，或换一个不思考的模型。", secs)
            else LF("翻一句要 %@ 秒，超过 6 秒这句就不等它了。换一个更小的模型会快一些。", secs)
        return if (t.thinks) LF("这个模型先思考再回答，翻一句要 %@ 秒，超过 6 秒会改用 Google。在服务端关掉思考，或换一个不思考的模型。", secs)
        else LF("翻一句要 %@ 秒，超过 6 秒会改用 Google。换一个更小的模型会快一些。", secs)
    }

    fun notesLine(host: String, model: String, sharedKey: Boolean): String? {
        val n = notes as? Notes.Fail ?: return null
        return when (n.why) {
            Reason.InvalidKey, Reason.MgmtKey ->
                if (sharedKey) LF("%@ 不认上面的 key，给它单独填一个。", host) else LF("%@ 说这个 key 无效，可能没复制全，或已删除。", host)
            Reason.Unreachable -> LF("这台手机访问不到 %@。", host)
            Reason.BadAddress -> L("地址要用 https；这台手机和局域网里的服务可以用 http。")
            Reason.NoCredit -> LF("%@ 账户余额不足。", host)
            Reason.NoModel -> LF("%@ 上找不到 %@ 这个模型。", host, model)
            Reason.NoJSON -> L("这个模型没按要求返回 JSON，写不了纪要。换一个通用模型。")
            Reason.Deaf, Reason.Busy -> null
            Reason.ServerError -> LF("%@ 暂时出错（HTTP %lld），稍后再试。", host, n.code ?: 0)
        }
    }

    fun proxyLine(service: String, host: String): String? {
        if (failure?.reason != Reason.Unreachable) return null
        return when (proxy ?: return null) {
            ProxyHint.SystemOn -> LF("开了代理也连不上：换一个节点，或检查代理软件是否放过 %@。", host)
            ProxyHint.None -> LF("这台手机没开代理。在国内通常要开代理才能用 %@。", service)
        }
    }

    fun balanceLine(service: String): String? {
        val b = balance ?: return null
        if (!lowBalance) return null
        return LF("%@ 余额快用完了（还剩 $%@）", service, String.format(java.util.Locale.US, "%.2f", maxOf(0.0, b)))
    }

    val summary: String get() {
        val parts = steps.joinToString(" ") { s ->
            val v = when (val st = s.state) {
                State.Running -> "running"
                is State.Ok -> st.seconds?.let { "ok(${String.format(java.util.Locale.US, "%.1f", it)}s)" } ?: "ok"
                State.Busy -> "busy"
                is State.Fail -> "fail(${lower(st.reason.name)}${st.code?.let { " $it" } ?: ""})"
                State.Skipped -> "skipped"
                State.Untested -> "untested"
            }
            "${lower(s.id.name)}=$v"
        }
        return parts + (proxy?.let { " proxy=${lower(it.name)}" } ?: "") +
            (balance?.let { " balance=${String.format(java.util.Locale.US, "%.2f", it)}" } ?: "") + (if (passive) " passive" else "") +
            (translate?.let { " translate=${String.format(java.util.Locale.US, "%.1f", it.seconds)}s${if (it.thinks) " thinks" else ""}" } ?: "") +
            (notes?.let { " notes=$it" } ?: "")
    }

    companion object {
        const val LOW_BALANCE = 0.5

        fun isOk(s: State) = s is State.Ok

        fun proves(step: StepID): Set<StepID> = when (step) {
            StepID.Reach -> setOf(StepID.Reach)
            StepID.Key -> setOf(StepID.Reach, StepID.Key)
            StepID.Text -> setOf(StepID.Reach, StepID.Key, StepID.Text)
            StepID.Hear -> setOf(StepID.Reach, StepID.Key, StepID.Hear)
        }

        fun lower(name: String) = name.replaceFirstChar { it.lowercaseChar() }

        fun reasonNamed(name: String): Reason? = Reason.values().firstOrNull { lower(it.name).equals(name, ignoreCase = true) }

        fun title(id: StepID, host: String): String = when (id) {
            StepID.Reach -> LF("连上 %@", host)
            StepID.Key -> L("key 可以用")
            StepID.Text -> L("纪要和翻译")
            StepID.Hear -> L("听对方")
        }

        fun classify(e: LingException, step: StepID): Failure? = when (e.kind) {
            LingException.Kind.Network, LingException.Kind.Timeout -> Failure(StepID.Reach, Reason.Unreachable, null)
            LingException.Kind.InvalidKey -> Failure(StepID.Key, Reason.InvalidKey, null)
            LingException.Kind.RateLimited -> Failure(step, Reason.Busy, null)
            LingException.Kind.Http -> when {
                e.status == 402 -> Failure(StepID.Key, Reason.NoCredit, 402)
                step == StepID.Hear && e.status in DEAF_CODES -> Failure(StepID.Hear, Reason.Deaf, e.status)
                e.status == 400 || e.status == 404 ->
                    if (step == StepID.Key) Failure(StepID.Key, Reason.ServerError, e.status) else Failure(StepID.Text, Reason.NoModel, e.status)
                else -> Failure(step, Reason.ServerError, e.status)
            }
            LingException.Kind.NoKey, LingException.Kind.Hijacked, LingException.Kind.Parse -> null
        }

        val DEAF_CODES = listOf(400, 404, 415, 422)

        fun owner(key: String): Pair<String, Boolean>? {
            val k = key.trim()
            return when {
                k.startsWith("sk-or-") -> "openrouter" to false
                k.startsWith("sk-payg") -> "zenmux" to false
                k.startsWith("sk-mgmt") -> "zenmux" to true
                else -> null
            }
        }

        fun listedModels(body: String): Set<String>? {
            val root = Json.parseObject(body) ?: return null
            val ids = root["data"].arr().mapNotNull { it.obj()?.get("id").str() }.filter { it.isNotEmpty() }
            return if (ids.isEmpty()) null else ids.toSet()
        }

        fun listedHearing(body: String): Set<String>? {
            val root = Json.parseObject(body) ?: return null
            var told = false
            val ids = mutableSetOf<String>()
            for (raw in root["data"].arr()) {
                val m = raw.obj() ?: continue
                val id = m["id"].str() ?: continue
                val ins = (m["input_modalities"] ?: m["architecture"].obj()?.get("input_modalities")) ?: continue
                told = true
                if (ins.arr().any { it.str() == "audio" }) ids.add(id)
            }
            return if (told) ids else null
        }

        fun balance(key: Map<String, Any?>?, credits: Map<String, Any?>?): Double? {
            val k = key?.get("data").obj()?.get("limit_remaining").num()
            val d = credits?.get("data").obj()
            val total = d?.get("total_credits").num()
            val used = d?.get("total_usage").num()
            val c = if (total != null && used != null) total - used else null
            return when {
                k != null && c != null -> minOf(k, c)
                else -> k ?: c
            }
        }

        fun simulated(reason: Reason): AICheck {
            val r = AICheck()
            return when (reason) {
                Reason.Busy -> r.pass(StepID.Text, 1.2).pass(StepID.Hear, 0.9).with(StepID.Text, State.Busy)
                Reason.Unreachable, Reason.BadAddress -> r.fail(StepID.Reach, reason, reached = false)
                Reason.InvalidKey, Reason.NoCredit -> r.fail(StepID.Key, reason, code = if (reason == Reason.NoCredit) 402 else null)
                Reason.MgmtKey -> r.fail(StepID.Key, reason, reached = false)
                Reason.NoModel, Reason.NoJSON -> r.fail(StepID.Text, reason, code = 404)
                Reason.Deaf -> r.pass(StepID.Text, 1.1).fail(StepID.Hear, reason, code = 400)
                Reason.ServerError -> r.fail(StepID.Text, reason, code = 503)
            }
        }
    }
}
