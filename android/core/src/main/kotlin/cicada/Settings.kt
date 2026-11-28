package cicada

import java.util.Locale

class AppSettings(
    var target: String = "system",
    var notesLanguage: String = "system",
    var model: String = LingClient.DEFAULT_MODEL,
    var aiProvider: String = "ling",
    var aiModels: MutableMap<String, String> = mutableMapOf(),
    var aiHearModels: MutableMap<String, String> = mutableMapOf(),
    var aiVoiceModels: MutableMap<String, String> = mutableMapOf(),
    var aiCustomBase: String = "",
    var aiCustomVoiceBase: String = "",
    var aiCustomVoice: String = "",
    var aiCustomHearBase: String = "",
    var aiCustomOnly: Boolean = false,
    var aiCustomNotesOwn: Boolean = false,
    var aiCustomNotesBase: String = "",
    var view: String = "notes",
    var showInCapture: Boolean = false,
    var onboarded: Boolean = false,
    var uiLanguage: String = "system",
    var source: String = "playback",
    var overlay: Boolean = true,
    var silenceEnd: String = "prompt",
    var silenceMinutes: Double = 10.0,
    var speakerVoices: Boolean = true,
    var recordAudio: Boolean = true,
    var speakBack: Boolean = true,
    var speakVoices: MutableMap<String, String> = mutableMapOf(),
    var fixMisheard: Boolean = true,
    var askNames: Boolean = true,
    var exportOn: Boolean = false,
    var exportFolder: String = "",
    var exportName: String = "",
    var updateLastChecked: Long? = null,
    var updateNotified: String? = null,
) {
    val targetCode: String get() = if (target == "system") Languages.myLanguage(systemLanguages()) else target
    val notesCode: String get() = if (notesLanguage == "system") targetCode else notesLanguage

    fun targetFor(source: String?): String =
        if (target == "system") Languages.followSystemTarget(source, systemLanguages()) else target

    fun aiConfig(): AIConfig = Providers.configFrom(this)

    val customOnly: Boolean get() = aiCustomOnly && aiProvider == "custom"

    fun toJson(): Map<String, Any?> = mapOf(
        "target" to target, "notesLanguage" to notesLanguage, "model" to model, "view" to view,
        "aiProvider" to aiProvider, "aiModels" to aiModels.toSortedMap(), "aiHearModels" to aiHearModels.toSortedMap(),
        "aiVoiceModels" to aiVoiceModels.toSortedMap(), "aiCustomBase" to aiCustomBase,
        "aiCustomVoiceBase" to aiCustomVoiceBase, "aiCustomVoice" to aiCustomVoice,
        "aiCustomHearBase" to aiCustomHearBase, "aiCustomOnly" to aiCustomOnly,
        "aiCustomNotesOwn" to aiCustomNotesOwn, "aiCustomNotesBase" to aiCustomNotesBase,
        "showInCapture" to showInCapture, "onboarded" to onboarded, "uiLanguage" to uiLanguage,
        "source" to source, "overlay" to overlay, "silenceEnd" to silenceEnd, "silenceMinutes" to silenceMinutes,
        "speakerVoices" to speakerVoices, "recordAudio" to recordAudio, "speakBack" to speakBack,
        "speakVoices" to speakVoices.toSortedMap(), "fixMisheard" to fixMisheard, "askNames" to askNames,
        "exportOn" to exportOn, "exportFolder" to exportFolder, "exportName" to exportName,
        "updateLastChecked" to updateLastChecked, "updateNotified" to updateNotified,
    )

    fun save() {
        try {
            Paths.root.mkdirs()
            Paths.settings.writeText(Json.write(toJson()))
        } catch (e: Exception) { Log.d("settings: save failed ${e.javaClass.simpleName}") }
    }

    companion object {
        @Volatile var systemLanguages: () -> List<String> = { listOf(Locale.getDefault().toLanguageTag()) }

        fun load(): AppSettings {
            try {
                if (Paths.settings.isFile) {
                    val o = Json.parseObject(Paths.settings.readText())
                    if (o != null) {
                        val d = AppSettings()
                        return AppSettings(
                            target = o["target"].str() ?: d.target, notesLanguage = o["notesLanguage"].str() ?: d.notesLanguage,
                            model = o["model"].str() ?: d.model, view = o["view"].str() ?: d.view,
                            aiProvider = o["aiProvider"].str() ?: d.aiProvider,
                            aiModels = strings(o["aiModels"]), aiHearModels = strings(o["aiHearModels"]),
                            aiVoiceModels = strings(o["aiVoiceModels"]), aiCustomBase = o["aiCustomBase"].str() ?: "",
                            aiCustomVoiceBase = o["aiCustomVoiceBase"].str() ?: "", aiCustomVoice = o["aiCustomVoice"].str() ?: "",
                            aiCustomHearBase = o["aiCustomHearBase"].str() ?: "", aiCustomOnly = o["aiCustomOnly"].bool() ?: false,
                            aiCustomNotesOwn = o["aiCustomNotesOwn"].bool() ?: false, aiCustomNotesBase = o["aiCustomNotesBase"].str() ?: "",
                            showInCapture = o["showInCapture"].bool() ?: false, onboarded = o["onboarded"].bool() ?: false,
                            uiLanguage = o["uiLanguage"].str() ?: d.uiLanguage, source = o["source"].str() ?: d.source,
                            overlay = o["overlay"].bool() ?: true,
                            silenceEnd = o["silenceEnd"].str() ?: d.silenceEnd,
                            silenceMinutes = (o["silenceMinutes"] as? Number)?.toDouble() ?: d.silenceMinutes,
                            speakerVoices = o["speakerVoices"].bool() ?: true, recordAudio = o["recordAudio"].bool() ?: true,
                            speakBack = o["speakBack"].bool() ?: true, speakVoices = strings(o["speakVoices"]),
                            fixMisheard = o["fixMisheard"].bool() ?: true, askNames = o["askNames"].bool() ?: true,
                            exportOn = o["exportOn"].bool() ?: false, exportFolder = o["exportFolder"].str() ?: "",
                            exportName = o["exportName"].str() ?: "",
                            updateLastChecked = (o["updateLastChecked"] as? Number)?.toLong(), updateNotified = o["updateNotified"].str(),
                        )
                    }
                }
            } catch (e: Exception) { Log.d("settings: unreadable, defaults used (${e.javaClass.simpleName})") }
            return AppSettings()
        }

        private fun strings(v: Any?): MutableMap<String, String> =
            v.obj()?.mapNotNull { (k, x) -> x.str()?.let { k to it } }?.toMap(mutableMapOf()) ?: mutableMapOf()
    }
}
