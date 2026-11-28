package cicada

import java.net.URI
import java.util.Base64

data class Model(val id: String, val note: String = "")

data class CloudVoice(val id: String, val gender: String)

class Provider(
    val id: String,
    val name: String,
    val base: String?,
    val site: String?,
    val textModels: List<Model> = emptyList(),
    val hearModels: List<Model> = emptyList(),
    val voiceModels: List<Model> = emptyList(),
    val voices: List<CloudVoice> = emptyList(),
    val clones: Boolean = false,
    val spacing: Double = 0.1,
) {
    val hasVoices get() = voiceModels.isNotEmpty()
}

object Providers {
    val GEMINI_VOICES = listOf(CloudVoice("Kore", "女"), CloudVoice("Aoede", "女"), CloudVoice("Charon", "男"), CloudVoice("Puck", "男"))

    val LING = Provider("ling", "Ling", "https://api.ant-ling.com/v1/", "https://chat.ant-ling.com/platform/api",
        textModels = listOf(Model("Ling-3.1-flash", "更准"), Model("Ling-3.0-flash", "更快、更省")),
        hearModels = listOf(Model("Ming-3.0-audio-flash")),
        voiceModels = listOf(Model("Ming-3.0-tts-0.5B")), clones = true, spacing = 0.6)

    val OPENROUTER = Provider("openrouter", "OpenRouter", "https://openrouter.ai/api/v1/", "https://openrouter.ai/settings/keys",
        textModels = listOf(Model("inclusionai/ling-3.1-flash", "和 Ling 同款"), Model("qwen/qwen3.8-flash", "中文好")),
        hearModels = listOf(Model("qwen/qwen3.8-omni-flash", "没人说话时不乱写"), Model("google/gemini-3.1-flash-lite", "最快，偶尔把杂音写成字")),
        voiceModels = listOf(Model("google/gemini-3.8-flash-tts", "效果和价格最均衡"), Model("google/gemini-3.8-flash-lite-tts", "更省")),
        voices = GEMINI_VOICES)

    val ZENMUX = Provider("zenmux", "ZenMux", "https://zenmux.ai/api/v1/", "https://zenmux.ai/settings/keys",
        textModels = listOf(Model("inclusionai/ling-3.0-flash", "和 Ling 同款"), Model("qwen/qwen3.8-flash", "中文好")),
        hearModels = listOf(Model("qwen/qwen3.8-omni-flash", "没人说话时不乱写"), Model("bytedance/doubao-seed-2.0-mini", "更快"),
                            Model("google/gemini-3.1-flash-lite", "最快，偶尔把杂音写成字")),
        voiceModels = listOf(Model("google/gemini-3.8-flash-tts", "效果和价格最均衡"), Model("google/gemini-3.8-flash-lite-tts", "更省")),
        voices = GEMINI_VOICES)

    val CUSTOM = Provider("custom", "其他（兼容 OpenAI）", null, null)

    val ALL = listOf(LING, OPENROUTER, ZENMUX, CUSTOM)

    fun named(raw: String?): Provider = ALL.firstOrNull { it.id == raw } ?: LING

    const val NOTES_MODEL = "custom.notes"

    fun isLocal(hostOrUrl: String): Boolean = host(hostOrUrl) in listOf("localhost", "127.0.0.1", "::1")

    fun isNearby(hostOrUrl: String): Boolean {
        val h = host(hostOrUrl).lowercase()
        if (isLocal(h) || h.endsWith(".local")) return true
        val labels = h.split('.')
        val parts = labels.mapNotNull { it.toIntOrNull() }
        if (labels.size == 4 && parts.size == 4 && parts.all { it in 0..255 }) {
            val (a, b) = parts
            return a == 10 || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 172 && b in 16..31) || (a == 100 && b in 64..127)
        }
        if (':' in h) return h.startsWith("fc") || h.startsWith("fd") || h.startsWith("fe80")
        return false
    }

    private fun host(hostOrUrl: String): String {
        val s = hostOrUrl.trim()
        val u = if ("://" in s) s else "http://$s"
        val host = try { URI(u).host } catch (_: Exception) { null } ?: s
        return host.trim('[', ']')
    }

    fun customBase(raw: String?): String? {
        var s = raw?.trim() ?: return null
        if (s.isEmpty()) return null
        if ("://" !in s) s = (if (isNearby(s)) "http://" else "https://") + s
        if (!s.endsWith("/")) s += "/"
        val uri = try { URI(s) } catch (_: Exception) { return null }
        val host = uri.host ?: return null
        return when (uri.scheme) {
            "https" -> s
            "http" -> if (isNearby(host)) s else null
            else -> null
        }
    }

    fun configFrom(s: AppSettings): AIConfig {
        val p = named(s.aiProvider)
        if (p.id == "ling") {
            val text = if (p.textModels.any { it.id == s.model }) s.model else p.textModels[0].id
            return AIConfig(p, p.base, text, p.hearModels[0].id, p.voiceModels[0].id, p.base)
        }
        if (p.id == "custom") {
            val base = customBase(s.aiCustomBase)
            val voice = s.aiVoiceModels["custom"]?.trim().orEmpty()
            val voiceBase = if (s.aiCustomVoiceBase.isNotBlank()) customBase(s.aiCustomVoiceBase) else base
            val name = s.aiCustomVoice.trim()
            val hearBase = if (s.aiCustomHearBase.isNotBlank()) customBase(s.aiCustomHearBase) else base
            val textModel = s.aiModels["custom"]?.trim().orEmpty()
            val notesModel = s.aiModels[NOTES_MODEL]?.trim().orEmpty()
            val notesAddress = if (s.aiCustomNotesOwn) s.aiCustomNotesBase.trim() else ""
            val notesBase = if (notesAddress.isEmpty()) null else customBase(notesAddress)
            return AIConfig(p, base, textModel, s.aiHearModels["custom"]?.trim().orEmpty(),
                            voice.ifEmpty { null }, if (voice.isNotEmpty()) voiceBase else null, name.ifEmpty { null }, hearBase,
                            notesModel = notesModel.takeIf { it.isNotEmpty() && it != textModel },
                            notesBase = notesBase.takeIf { it != base }, notesOwnService = s.aiCustomNotesOwn,
                            notesBadAddress = notesAddress.isNotEmpty() && notesBase == null)
        }
        return AIConfig(p, p.base, s.aiModels[p.id]?.ifBlank { null } ?: p.textModels[0].id,
                        s.aiHearModels[p.id]?.ifBlank { null } ?: p.hearModels[0].id,
                        s.aiVoiceModels[p.id]?.ifBlank { null } ?: p.voiceModels[0].id, p.base)
    }

    private val NOT_CHAT = Regex("(embed|whisper|tts|transcribe|dall-e|image|moderation|realtime|sora|search|video|seedance|wan\\d)")

    fun catalog(body: String, recommended: List<String>, hears: Boolean): List<String> {
        val root = Json.parseObject(body) ?: return recommended
        val ids = mutableListOf<String>()
        for (raw in root["data"].arr()) {
            val m = raw.obj() ?: continue
            val id = m["id"].str() ?: continue
            if (id.isEmpty() || id.endsWith(":batch")) continue
            val a = m["architecture"].obj()
            val ins = (m["input_modalities"] ?: a?.get("input_modalities")).arr().mapNotNull { it.str() }
            val outs = (m["output_modalities"] ?: a?.get("output_modalities")).arr().mapNotNull { it.str() }
            if (outs.isNotEmpty() && "text" !in outs) continue
            if (ins == listOf("audio")) continue
            if (hears && "audio" !in ins) continue
            if (outs.isEmpty() && NOT_CHAT.containsMatchIn(id)) continue
            ids.add(id)
        }
        return recommended + ids.filter { it !in recommended }.distinct().sorted()
    }
}

class AIConfig(
    val provider: Provider,
    val base: String?,
    val textModel: String,
    val hearModel: String,
    val voiceModel: String? = null,
    val voiceBase: String? = null,
    val customVoice: String? = null,
    val hearBase: String? = base,
    val notesModel: String? = null,
    val notesBase: String? = null,
    val notesOwnService: Boolean = false,
    val notesBadAddress: Boolean = false,
) {
    val notesApart get() = provider.id == "custom" && (notesModel != null || notesBase != null || notesOwnService)

    val forNotes: AIConfig get() = if (!notesApart) this else
        AIConfig(provider, notesBase ?: base, notesModel ?: textModel, hearModel, voiceModel, voiceBase, customVoice, hearBase,
                 notesModel, notesBase, notesOwnService, notesBadAddress)

    val isLing get() = provider.id == "ling"
    val hasVoices get() = voiceModel != null && voiceBase != null

    val voices: List<CloudVoice> get() = when {
        !hasVoices || isLing -> emptyList()
        provider.id == "custom" -> customVoice?.let { listOf(CloudVoice(it, "")) } ?: emptyList()
        else -> provider.voices
    }

    val hearsElsewhere get() = hearBase != base

    fun shape(body: MutableMap<String, Any?>, maxTokens: Int, templateKwargs: Boolean = true) {
        body["max_tokens"] = maxTokens
        body["temperature"] = 0.2
        if (isLing) body["thinking"] = mapOf("type" to "disabled")
        else if (provider.id == "openrouter" || provider.id == "zenmux") body["reasoning"] = mapOf("enabled" to false)
        else if (provider.id == "custom" && templateKwargs) body["chat_template_kwargs"] = mapOf("enable_thinking" to false)
    }

    companion object {
        fun thought(root: Map<String, Any?>): Boolean {
            val message = root["choices"].arr().firstOrNull().obj()?.get("message").obj()
            for (k in listOf("reasoning_content", "reasoning")) if (!message?.get(k).str().isNullOrBlank()) return true
            val n = root["usage"].obj()?.get("completion_tokens_details").obj()?.get("reasoning_tokens").num()
            if (n != null && n > 0) return true
            return message?.get("content").str()?.contains("<think>") == true
        }
    }

    fun audioPart(audio: ByteArray, model: String, type: String = "audio/wav"): Map<String, Any?> {
        val b64 = Base64.getEncoder().encodeToString(audio)
        if (isLing) return mapOf("type" to "audio_url", "audio_url" to mapOf("url" to "data:$type;base64,$b64"))
        val data = if (model.substringAfterLast('/').startsWith("qwen")) "data:audio/wav;base64,$b64" else b64
        return mapOf("type" to "input_audio", "input_audio" to mapOf("data" to data, "format" to "wav"))
    }
}
