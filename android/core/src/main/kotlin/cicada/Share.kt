package cicada

import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

enum class ShareScope(val id: String) { Notes("notes"), Full("full") }

object ShareProjection {
    fun doc(s: Session, scope: ShareScope, names: Boolean, removed: Set<Int> = emptySet(), dropNotes: Boolean = false): Map<String, Any?> {
        val numbers = SpeakerLabels.numbers(s.lines)
        val nameMap = if (names) SpeakerLabels.names(s) else emptyMap()
        fun who(l: TranscriptLine): String {
            if (l.speaker == "me") return Strings.L("分享者")
            val n = numbers[l.id] ?: return Strings.L("对方")
            return if (names) SpeakerLabels.label(n, nameMap) else Strings.LF("说话人 %lld", n)
        }
        val lines = ArrayList<Map<String, Any?>>()
        if (scope == ShareScope.Full) s.lines.forEachIndexed { i, l ->
            if (i in removed || l.src.isEmpty()) return@forEachIndexed
            val dst = l.dst?.takeIf { it.isNotEmpty() && it != l.src }
            lines.add(mapOf("t" to round(l.t), "who" to who(l), "src" to l.src, "dst" to dst))
        }
        val raw = s.notes
        val notes = if (dropNotes || raw == null || raw.isEmpty) null else {
            val n = if (names) SpeakerLabels.named(raw, nameMap) else raw
            mapOf(
                "summary" to n.summary,
                "topics" to n.topics.map { mapOf("start" to round(it.start), "title" to it.title, "summary" to it.summary, "points" to it.points) },
                "conclusions" to n.conclusions.map { mapOf("text" to it.text, "t" to it.t?.let(::round)) },
                "todos" to n.todos.map { mapOf("text" to it.text, "owner" to (if (names) it.owner else null), "t" to it.t?.let(::round)) },
                "terms" to if (names) n.terms.map { mapOf("name" to it.name, "note" to it.note) } else emptyList(),
            )
        }
        val hidden = (if (scope == ShareScope.Full) removed.size else 0) + (if (dropNotes && raw != null && !raw.isEmpty) 1 else 0)
        return mapOf(
            "v" to 1, "title" to SessionStore.displayTitle(s), "startedAt" to Iso8601.write(s.startedAt),
            "duration" to Math.round(s.durationSeconds), "langs" to languages(s.lines),
            "notes" to notes, "lines" to lines, "hidden" to hidden,
        )
    }

    fun languages(lines: List<TranscriptLine>): List<String> {
        val count = LinkedHashMap<String, Int>()
        for (l in lines) if (l.dst != null) {
            val key = base(l.srcLang) + ">" + base(l.dstLang)
            count[key] = (count[key] ?: 0) + 1
        }
        val top = count.entries.fold(null as Map.Entry<String, Int>?) { best, e -> if (best == null || e.value > best.value) e else best } ?: return emptyList()
        return top.key.split(">").filter { it.isNotEmpty() }
    }

    private fun base(code: String) = (code.split("-").firstOrNull { it.isNotEmpty() } ?: code).lowercase()

    fun round(t: Double): Double = Math.signum(t) * Math.floor(Math.abs(t) * 10 + 0.5) / 10

    fun encode(doc: Map<String, Any?>): String = Json.write(doc, pretty = false, slashes = false)
}

data class ShareHit(val part: String, val from: Int?, val to: Int?, val questions: List<String>) {
    companion object {
        fun from(o: Map<String, Any?>) = ShareHit(o["part"].str() ?: "", o["from"].int(), o["to"].int(), o["questions"].arr().mapNotNull { it.str() })

        fun recordLines(hits: List<ShareHit>, kept: List<Int>): Set<Int> {
            val out = HashSet<Int>()
            for (h in hits) if (h.part == "lines") {
                val a = h.from ?: continue; val b = h.to ?: continue
                if (a > b) continue
                for (i in a..b) if (i >= 0 && i < kept.size) out.add(kept[i])
            }
            return out
        }
    }
}

object SharePassword {
    const val ITERATIONS = 210_000

    fun verifier(password: String, salt: ByteArray, iterations: Int = ITERATIONS): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(password.toByteArray(Charsets.UTF_8).let { if (it.isEmpty()) ByteArray(1) else it }, "HmacSHA256"))
        var u = mac.doFinal(salt + byteArrayOf(0, 0, 0, 1))
        val out = u.copyOf()
        for (i in 1 until iterations) {
            u = mac.doFinal(u)
            for (k in out.indices) out[k] = (out[k].toInt() xor u[k].toInt()).toByte()
        }
        return out
    }

    fun make(random: java.util.Random = SecureRandom()): String {
        val w = WORDS.split(" ")
        return "${w[random.nextInt(w.size)]}-${10 + random.nextInt(90)}-${w[random.nextInt(w.size)]}"
    }

    private const val WORDS = "amber apple arrow aspen basil beach birch bloom brook cedar cherry cloud coral comet dawn delta dune ember fern field flint frost grove harbor hazel honey iris island jade lake lark lemon lily linen maple meadow mint moss olive orbit pearl pine plum pond quartz rain reed river ruby sage sand shell silk sky slate snow spruce stone storm sun tide tulip velvet willow wind"
}

data class ShareRecord(
    val id: String, val url: String, val token: String, val expiresAt: Instant,
    val scope: String, val password: String?, val createdAt: Instant,
) {
    fun toJson(): Map<String, Any?> = mapOf(
        "id" to id, "url" to url, "token" to token, "expiresAt" to Iso8601.write(expiresAt),
        "scope" to scope, "password" to password, "createdAt" to Iso8601.write(createdAt),
    )

    fun daysLeft(now: Instant = Instant.now()): Long =
        maxOf(1L, Math.ceil((expiresAt.epochSecond - now.epochSecond - 600) / 86400.0).toLong())

    fun message(title: String, now: Instant = Instant.now()): String {
        val left = daysLeft(now)
        val valid = if (left >= 365) Strings.L("1 年内有效") else Strings.LF("%lld 天内有效", left)
        val last = password?.let { Strings.LF("密码：%@（%@）", it, valid) } ?: valid
        return listOf(Strings.LF("「%@」会议记录", title), url, last).joinToString("\n")
    }

    companion object {
        fun from(o: Map<String, Any?>): ShareRecord? {
            val id = o["id"].str() ?: return null
            return ShareRecord(id, o["url"].str() ?: return null, o["token"].str() ?: return null,
                               Iso8601.read(o["expiresAt"].str()) ?: return null, o["scope"].str() ?: "notes",
                               o["password"].str(), Iso8601.read(o["createdAt"].str()) ?: Instant.EPOCH)
        }
    }
}

object ShareStore {
    val folder get() = File(Paths.root, "Shares")
    val deviceFile get() = File(Paths.root, "share-device.json")

    fun read(sessionId: String): ShareRecord? =
        try { Json.parseObject(File(folder, "$sessionId.json").readText())?.let(ShareRecord::from) } catch (_: Exception) { null }

    fun save(r: ShareRecord, sessionId: String) = writePrivate(File(folder, "$sessionId.json"), Json.write(r.toJson()))

    fun remove(sessionId: String) { File(folder, "$sessionId.json").delete() }

    fun all(): Map<String, ShareRecord> =
        (folder.listFiles() ?: emptyArray()).filter { it.name.endsWith(".json") }
            .mapNotNull { f -> read(f.name.removeSuffix(".json"))?.let { f.name.removeSuffix(".json") to it } }.toMap()

    fun writePrivate(f: File, text: String): Boolean = try {
        f.parentFile?.mkdirs()
        val tmp = File(f.path + ".tmp")
        tmp.writeText(text)
        tmp.setReadable(false, false); tmp.setReadable(true, true)
        tmp.setWritable(false, false); tmp.setWritable(true, true)
        if (!tmp.renameTo(f)) { f.writeText(text); tmp.delete() }
        true
    } catch (e: Exception) {
        Log.d("share: could not write ${f.name} ${e.javaClass.simpleName}")
        false
    }
}

class ShareClient(
    private val platform: String,
    private val version: String,
    private val transport: Transport = UrlTransport,
    var base: String = "https://cicada.indaloop.app",
) {
    var deviceFile: File? = null
    private val keyFile get() = deviceFile ?: ShareStore.deviceFile

    sealed class Outcome {
        class Shared(val record: ShareRecord) : Outcome()
        class Blocked(val hits: List<ShareHit>, val kept: List<Int>) : Outcome()
        class Failed(val code: String, val retryAfter: Int?) : Outcome()
    }

    class Stats(val id: String, val expiresAt: Double, val state: String, val views: Int)

    class Failure(val code: String, val retryAfter: Int? = null) : Exception(code)

    data class Options(
        val scope: ShareScope = ShareScope.Notes, val days: Int = 7, val names: Boolean = false,
        val password: String? = null, val summaryInPreview: Boolean = false,
        val removed: Set<Int> = emptySet(), val dropNotes: Boolean = false,
    )

    private val random = SecureRandom()
    private val gate = Any()

    private class Device(val seed: ByteArray, val pub: ByteArray, val id: String?, val server: String?)

    private fun loadDevice(): Device {
        val o = try { Json.parseObject(keyFile.readText()) } catch (_: Exception) { null }
        val seed = try { o?.get("key").str()?.let { Base64.getDecoder().decode(it) } } catch (_: Exception) { null }
        if (o != null && seed != null && seed.size == 32) return Device(seed, Ed25519.publicKey(seed), o["device"].str(), o["server"].str())
        val fresh = ByteArray(32).also(random::nextBytes)
        saveDevice(fresh, null, null)
        return Device(fresh, Ed25519.publicKey(fresh), null, null)
    }

    private fun saveDevice(seed: ByteArray, id: String?, server: String?) {
        ShareStore.writePrivate(keyFile, Json.write(mapOf("key" to Base64.getEncoder().encodeToString(seed), "device" to id, "server" to server)))
    }

    private fun device(force: Boolean = false): Device = synchronized(gate) {
        val d = loadDevice()
        if (!force && d.id != null && d.server == base) return d
        val nonce = proofOfWork(d.pub)
        val body = Json.write(mapOf("key" to b64url(d.pub), "pow" to b64url(nonce), "platform" to platform, "version" to version), pretty = false)
        val r = send("POST", "/api/v1/devices", body, emptyMap(), null)
        val id = Json.parseObject(r.body)?.get("device").str()
        if (r.status != 201 || id == null) {
            Log.d("share: register failed ${r.status} ${code(r.body) ?: "?"}")
            throw Failure(code(r.body) ?: "register_failed", Json.parseObject(r.body)?.get("retryAfter").int())
        }
        saveDevice(d.seed, id, base)
        Log.d("share: device registered")
        return Device(d.seed, d.pub, id, base)
    }

    private fun send(method: String, path: String, body: String?, headers: Map<String, String>, signer: Device?): Transport.Response {
        val h = LinkedHashMap<String, String>()
        h["Content-Type"] = "application/json"
        h["X-Cicada-Client"] = "$platform/$version"
        h.putAll(headers)
        if (signer != null) {
            val time = (System.currentTimeMillis() / 1000).toString()
            val nonce = b64url(ByteArray(16).also(random::nextBytes))
            val bytes = (body ?: "").toByteArray(Charsets.UTF_8)
            val message = "$method\n$path\n$time\n$nonce\n${hex(sha256(bytes))}"
            h["X-Cicada-Device"] = signer.id!!
            h["X-Cicada-Time"] = time
            h["X-Cicada-Nonce"] = nonce
            h["X-Cicada-Signature"] = b64url(Ed25519.sign(signer.seed, message.toByteArray(Charsets.UTF_8), signer.pub))
        }
        return try { transport.send(base + path, method, body, h, 90_000) } catch (e: IOException) { throw Failure("network") }
    }

    private fun signed(method: String, path: String, body: String? = null, headers: Map<String, String> = emptyMap()): Transport.Response {
        var r = send(method, path, body, headers, device())
        if (r.status == 401 && code(r.body) == "unknown_device") r = send(method, path, body, headers, device(force = true))
        return r
    }

    fun share(s: Session, o: Options): Outcome {
        val doc = ShareProjection.doc(s, o.scope, o.names, o.removed, o.dropNotes)
        val kept = if (o.scope == ShareScope.Full) s.lines.indices.filter { it !in o.removed && s.lines[it].src.isNotEmpty() } else emptyList()
        val encoded = ShareProjection.encode(doc)
        val body = LinkedHashMap<String, Any?>()
        body["doc"] = doc
        body["scope"] = o.scope.id
        body["days"] = o.days
        body["summaryInPreview"] = o.summaryInPreview
        o.password?.let { pw ->
            val salt = ByteArray(16).also(random::nextBytes)
            body["password"] = mapOf("salt" to b64url(salt), "iter" to SharePassword.ITERATIONS,
                                     "hash" to b64url(sha256(SharePassword.verifier(pw, salt))))
        }
        return try {
            val settings = "${o.scope.id}|${o.days}|${o.names}|${o.password ?: ""}|${o.summaryInPreview}"
            val idem = s.id + "-" + hex(sha256(encoded.toByteArray(Charsets.UTF_8) + settings.toByteArray(Charsets.UTF_8)).copyOf(8))
            val r = signed("POST", "/api/v1/shares", Json.write(body, pretty = false, slashes = false), mapOf("Idempotency-Key" to idem))
            val obj = Json.parseObject(r.body) ?: emptyMap()
            when (r.status) {
                200, 201 -> {
                    val id = obj["id"].str(); val url = obj["url"].str(); val token = obj["token"].str(); val exp = obj["expiresAt"].num()
                    if (id == null || url == null || token == null || exp == null) return Outcome.Failed("server_error", null)
                    ShareStore.read(s.id)?.takeIf { it.id != id }?.let { revoke(it, null) }
                    val rec = ShareRecord(id, url, token, Instant.ofEpochSecond(exp.toLong()), o.scope.id, o.password, Instant.now())
                    ShareStore.save(rec, s.id)
                    Log.d("share: ${s.id} shared (${o.scope.id}, ${o.days} days${if (o.password == null) "" else ", password"})")
                    Outcome.Shared(rec)
                }
                422 -> {
                    val hits = obj["hits"].arr().mapNotNull { it.obj()?.let(ShareHit::from) }
                    Log.d("share: ${s.id} blocked " + hits.joinToString("; ") { h ->
                        h.part + (h.from?.let { " $it-${h.to ?: it}" } ?: "") + " " + h.questions.joinToString(",")
                    })
                    Outcome.Blocked(hits, kept)
                }
                else -> {
                    Log.d("share: ${s.id} failed ${r.status} ${obj["code"].str() ?: "?"}")
                    Outcome.Failed(obj["code"].str() ?: "server_error", obj["retryAfter"].int())
                }
            }
        } catch (f: Failure) {
            Outcome.Failed(f.code, f.retryAfter)
        } catch (e: Exception) {
            Log.d("share: failed ${e.javaClass.simpleName}")
            Outcome.Failed("server_error", null)
        }
    }

    fun revoke(r: ShareRecord, sessionId: String?): Boolean {
        val ok = try {
            val res = signed("DELETE", "/api/v1/shares/${r.id}", headers = mapOf("Authorization" to "Bearer ${r.token}"))
            (res.status == 204 || res.status == 404).also { if (!it) Log.d("share: revoke ${r.id} failed ${res.status} ${code(res.body) ?: "?"}") }
        } catch (e: Exception) {
            Log.d("share: revoke ${r.id} failed ${e.message}")
            false
        }
        if (ok && sessionId != null) ShareStore.remove(sessionId)
        return ok
    }

    fun stats(ids: List<String>): Map<String, Stats> {
        if (ids.isEmpty()) return emptyMap()
        return try {
            val r = signed("GET", "/api/v1/shares?ids=${ids.joinToString(",")}")
            if (r.status != 200) return emptyMap()
            Json.parseObject(r.body)?.get("shares").arr().mapNotNull { it.obj() }.mapNotNull { o ->
                val id = o["id"].str() ?: return@mapNotNull null
                id to Stats(id, o["expiresAt"].num() ?: 0.0, o["state"].str() ?: "", o["views"].int() ?: 0)
            }.toMap()
        } catch (_: Exception) { emptyMap() }
    }

    companion object {
        fun proofOfWork(pub: ByteArray): ByteArray {
            val md = MessageDigest.getInstance("SHA-256")
            val nonce = ByteArray(8)
            var n = 0L
            while (true) {
                for (i in 0 until 8) nonce[i] = (n ushr (56 - 8 * i)).toByte()
                md.update(pub); md.update(nonce)
                val h = md.digest()
                if (h[0].toInt() == 0 && h[1].toInt() == 0 && (h[2].toInt() and 0xFF) < 16) return nonce.copyOf()
                n++
            }
        }

        fun sha256(b: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(b)
        fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
        fun b64url(b: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(b)
        private fun code(body: String) = Json.parseObject(body)?.get("code").str()
    }
}
