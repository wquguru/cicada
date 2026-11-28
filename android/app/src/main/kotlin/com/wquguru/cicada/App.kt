package com.wquguru.cicada

import android.app.Application
import android.content.Context
import android.content.Intent
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import cicada.AIKey
import cicada.AppSettings
import cicada.Correction
import cicada.LiveFixes
import cicada.Vocabulary
import cicada.AudioSource
import cicada.LingClient
import cicada.ListenEngine
import cicada.Log
import cicada.MeetingEndWatch
import cicada.NotesEngine
import cicada.Paths
import cicada.PcmAudioSource
import cicada.Providers
import cicada.SessionStore
import cicada.ShareClient
import cicada.SpeakerLabels
import cicada.SpeakerNamer
import cicada.SpeakerTagger
import cicada.Strings
import cicada.Translator
import cicada.VoiceCatalog
import cicada.VoiceReference
import cicada.Wav
import java.io.File
import java.util.Locale
import java.util.concurrent.Executors

class CicadaApp : Application() {
    lateinit var settings: AppSettings
    lateinit var key: AIKey
    lateinit var ling: LingClient
    lateinit var store: SessionStore
    lateinit var notes: NotesEngine
    lateinit var translator: Translator
    lateinit var listen: ListenEngine
    lateinit var vocabulary: Vocabulary
    lateinit var fixes: LiveFixes
    lateinit var namer: SpeakerNamer
    lateinit var overlay: Overlay
    lateinit var voice: Voice
    lateinit var updates: AppUpdates
    lateinit var folderExport: FolderExporter
    val share by lazy {
        ShareClient("android", (packageManager.getPackageInfo(packageName, 0).versionName ?: "0.0.0").substringBefore('-'))
    }
    val main = Handler(Looper.getMainLooper())
    val background = Executors.newCachedThreadPool { r -> Thread(r, "App").apply { isDaemon = true } }
    private val observers = LinkedHashSet<() -> Unit>()
    private var refreshQueued = false
    private var tileListening = false
    private var samplePlayer: MediaPlayer? = null
    @Volatile var startProblem: String? = null
    private var resumed = 0
    val foreground get() = resumed > 0
    @Volatile var micSilenced = false
    var overlayClosed = false
    var overlayThisMeeting = false
    private var recorder: Recorder? = null
    @Volatile var importing: FileSource? = null; private set

    override fun onCreate() {
        super.onCreate()
        shared = this
        Paths.root = filesDir
        Paths.log = File(cacheDir, if (BuildConfig.DEBUG) "cicada-dev-debug.log" else "cicada-debug.log")
        if (BuildConfig.DEBUG) Log.sink = { android.util.Log.d("Cicada", it) }
        settings = AppSettings.load()
        SpeakerLabels.voices = settings.speakerVoices
        AppSettings.systemLanguages = {
            val list = android.content.res.Resources.getSystem().configuration.locales
            (0 until list.size()).map { list[it].toLanguageTag() }
        }
        loadStrings()
        key = AIKey(KeystoreProtector, service = { settings.aiProvider })
        ling = LingClient(key, config = { settings.aiConfig() })
        ling.proxyHint = { AiCheckViews.proxyHint(this) }
        watchNetwork()
        store = SessionStore(loadNow = false)
        folderExport = FolderExporter(this)
        background.execute { val t = System.currentTimeMillis(); store.load(); Log.d("store: loaded ${store.all().size} in ${System.currentTimeMillis() - t} ms") }
        notes = NotesEngine(ling, store)
        translator = Translator(ling)
        translator.googleOff = settings.customOnly
        listen = ListenEngine(ling, translator, store, notes, settings)
        Correction.pinyinOf = Pinyin::of
        vocabulary = Vocabulary()
        fixes = LiveFixes(store, vocabulary, settings)
        listen.fixes = fixes
        translator.fixContext = { fixes.context(it) }
        translator.onFixes = { text, edits -> fixes.received(text, edits) }
        fixes.onChange(::changed)
        vocabulary.onChange(::changed)
        listen.speakers = SpeakerTagger(NativeVoiceprints.create(this))
        namer = SpeakerNamer(ling, store)
        listen.onVoice = { namer.guess(it) }
        listen.encoder = { pcm ->
            val t = System.currentTimeMillis()
            AacEncoder.encode(pcm)?.also { Log.d("listen: ${pcm.size * 2 / 1024} KB PCM → ${it.bytes.size / 1024} KB ${it.type} in ${System.currentTimeMillis() - t} ms") }
        }
        overlay = Overlay(this)
        voice = Voice(this)
        listen.onSaid = ::speakAloud
        listen.onWords = { main.post { endWatch?.heard(now()); setEnding(endWatch?.pending) } }
        listen.onChange(::changed)
        notes.onChange(::changed)
        store.onChange { changed() }
        store.onChange { id -> main.post {
            if (id.isEmpty()) folderExport.retry()
            else if (store.get(id) == null) folderExport.deleted(id) else folderExport.saved(id)
        } }
        notes.finalDone = { id -> main.post { folderExport.settled(id) } }
        main.post { folderExport.retry() }
        ling.onChange(::changed)
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityPreCreated(a: android.app.Activity, b: android.os.Bundle?) {
                if (Build.VERSION.SDK_INT >= 33 && a !is ProjectionActivity) a.setRecentsScreenshotEnabled(false)
            }
            override fun onActivityResumed(a: android.app.Activity) {
                if (resumed++ == 0) folderExport.retry()
                updateOverlay()
            }
            override fun onActivityPaused(a: android.app.Activity) { resumed--; main.postDelayed(::updateOverlay, 400) }
            override fun onActivityCreated(a: android.app.Activity, b: android.os.Bundle?) {}
            override fun onActivityStarted(a: android.app.Activity) {}
            override fun onActivityStopped(a: android.app.Activity) {}
            override fun onActivitySaveInstanceState(a: android.app.Activity, b: android.os.Bundle) {}
            override fun onActivityDestroyed(a: android.app.Activity) {}
        })
        Log.d("app: launch ${if (BuildConfig.DEBUG) "dev" else "release"} sdk=${Build.VERSION.SDK_INT}")
        if (ling.hasKey) background.execute { ling.check() }
        updates = AppUpdates(this)
        updates.start()
    }

    fun loadStrings() {
        val ui = if (settings.uiLanguage == "system") Locale.getDefault().toLanguageTag() else settings.uiLanguage
        Strings.load(ui) { rel -> try { assets.open("Resources/$rel").use { it.readBytes().toString(Charsets.UTF_8) } } catch (_: Exception) { null } }
    }

    // MARK: Changes

    fun observe(observer: () -> Unit): () -> Unit {
        observers.add(observer)
        return { observers.remove(observer) }
    }

    fun changed() {
        main.post {
            if (refreshQueued) return@post
            refreshQueued = true
            main.postDelayed({
                refreshQueued = false
                updateOverlay()
                overlay.refresh()
                if (listen.listening != tileListening) { tileListening = listen.listening; ListenTile.refresh(this) }
                ListenService.refresh(this)
                observers.toList().forEach { it() }
            }, 16)
        }
    }

    // MARK: Listening

    val canOverlay get() = Settings.canDrawOverlays(this)

    @Volatile var starting = 0L

    fun startListening(context: Context, kind: String, gate: Boolean = true) {
        if (gate && context is android.app.Activity && !listen.listening && ling.hasKey) { AiCheckViews.start(context, kind); return }
        startIntent(context, kind, gate = false)?.let { context.startActivity(it) }
    }

    fun startIntent(context: Context, kind: String, gate: Boolean = true): Intent? {
        if (listen.listening) return null
        if (System.currentTimeMillis() - starting < 60_000) return null
        startProblem = null
        if (!ling.hasKey) return Intent(context, OnboardingActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (gate && AiCheckViews.blocks(this))
            return Intent(context, MainActivity::class.java).putExtra("start", kind).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        starting = System.currentTimeMillis()
        return Intent(context, ProjectionActivity::class.java).putExtra("kind", kind).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    fun began(source: AudioSource, kind: String) {
        starting = 0
        micSilenced = false
        (source as? RecordSource)?.onSilenced = { silenced -> if (silenced != micSilenced) { micSilenced = silenced; changed() } }
        source.onEnded = { reason ->
            if (reason != null) {
                Log.d("listen: source ended $reason")
                startProblem = Strings.L("声音来源停了")
                stopListening()
            }
        }
        overlayClosed = false
        overlayThisMeeting = false
        overlay.collapsed = false
        listen.start(source, kind)
        startRecording()
        watchEnd()
        if (kind == "mic") background.execute { voice.warm() }
        openLive()
    }

    // MARK: 我说 (面对面)

    fun holdToSay() {
        if (voice.speaking) { voice.stop(); listen.muted = false }
        listen.hold()
    }

    fun releaseToSay() = listen.release()

    fun voiceId(lang: String): String =
        VoiceCatalog.chosen(settings.speakVoices, lang, ling.config(), ling.speaks, ling.clones && VoiceReference.exists)

    fun saveVoiceReference(pcm: ShortArray, text: String, lang: String): Boolean = try {
        VoiceReference.save(pcm, text)
        Log.d("voice clone saved ${pcm.size / 16000} s")
        settings.speakVoices[VoiceCatalog.key(lang)] = VoiceCatalog.CLONE
        saveSettings()
        true
    } catch (e: Exception) { Log.d("voice clone save failed ${e.javaClass.simpleName}"); false }

    fun removeVoiceReference() {
        VoiceReference.remove()
        settings.speakVoices.entries.removeAll { it.value == VoiceCatalog.CLONE }
        saveSettings()
        Log.d("voice clone removed")
    }

    private fun speakIn(id: String, text: String, lang: String, onStart: () -> Unit, onEnd: () -> Unit,
                        draft: Pair<String, String>? = null): Voice.Result {
        if (id == VoiceCatalog.CLONE) {
            val ref = draft ?: VoiceReference.reference()
            if (ref == null || !ling.clones) { onEnd(); return Voice.Result.Failed }
            return voice.speakCloud(ling, text, null, VoiceCatalog.mingLanguage(lang), onStart, onEnd, reference = ref)
        }
        return if (id.startsWith(VoiceCatalog.MING)) voice.speakCloud(ling, text, id.removePrefix(VoiceCatalog.MING), VoiceCatalog.mingLanguage(lang), onStart, onEnd)
               else voice.speakCloud(ling, text, id.removePrefix(VoiceCatalog.CLOUD), null, onStart, onEnd)
    }

    private fun speakAloud(text: String, lang: String) {
        listen.muted = true
        changed()
        val id = voiceId(lang)
        Log.d("voice: $lang in $id")
        if (id != VoiceCatalog.PHONE) {
            background.execute {
                val r = speakIn(id, text, lang, onStart = { changed() }, onEnd = {})
                if (r == Voice.Result.Spoken) main.postDelayed({ if (!voice.speaking) { listen.muted = false; changed() } }, 400)
                else speakWithPhone(text, lang)
            }
            return
        }
        speakWithPhone(text, lang)
    }

    @Volatile var previewing: String? = null; private set

    fun previewVoice(id: String, lang: String, text: String = VoiceCatalog.sample(lang), draft: Pair<String, String>? = null,
                     failed: (String) -> Unit = {}) {
        voice.stop()
        previewing = id
        changed()
        fun done() = main.post { if (previewing == id) previewing = null; changed() }
        if (id == VoiceCatalog.PHONE) {
            background.execute {
                val r = voice.speak(text, lang, onStart = {}, onEnd = { done() })
                if (r != Voice.Result.Spoken) {
                    done()
                    main.post { failed(Strings.L(if (r == Voice.Result.NoVoice) "手机不会读这个语言" else "没能读出来")) }
                }
            }
            return
        }
        background.execute {
            val r = speakIn(id, text, lang, onStart = {}, onEnd = { done() }, draft = draft)
            Log.d("voice: preview $id $lang ${r.name}")
            if (r != Voice.Result.Spoken) main.post { failed(Strings.L("没能读出来")) }
        }
    }

    private fun speakWithPhone(text: String, lang: String) {
        val r = voice.speak(text, lang, onStart = { changed() }, onEnd = {
            main.postDelayed({ if (!voice.speaking) { listen.muted = false; changed() } }, 400)
        })
        if (r == Voice.Result.Spoken) main.postDelayed({ if (listen.muted && !voice.speaking) { listen.muted = false; changed() } }, 3_000L + text.length * 150L)
        if (r != Voice.Result.Spoken) {
            listen.muted = false
            listen.sayFailed(if (r == Voice.Result.NoVoice) Strings.L("手机不会读这个语言") else Strings.L("没能读出来"))
        }
    }

    // MARK: Meeting end (the Mac's MeetingEndWatch: on Android only "nobody spoke", since no app

    @Volatile var ending: MeetingEndWatch.Pending? = null; private set
    @Volatile var autoEnded = false; private set
    private var endWatch: MeetingEndWatch? = null
    var endTimesOverride: Pair<Double, Double>? = null

    private fun now() = System.currentTimeMillis() / 1000.0

    private val endConfig: MeetingEndWatch.Config get() = MeetingEndWatch.Config(
        followApps = false,
        silence = MeetingEndWatch.Silence.of(settings.silenceEnd),
        silenceAfter = endTimesOverride?.first ?: (settings.silenceMinutes * 60),
        countdown = endTimesOverride?.second ?: 60.0,
    )

    private val endTick = object : Runnable {
        override fun run() {
            val w = endWatch ?: return
            if (!listen.listening) return
            w.config = endConfig
            val said = listen.sessionId?.let { store.lines(it).isNotEmpty() } ?: false
            val reason = w.tick(now(), emptyMap(), said)
            setEnding(w.pending)
            if (reason != null) { autoEnd(reason, w); return }
            main.postDelayed(this, if (w.pending != null) 1000 else 2000)
        }
    }

    private fun watchEnd() {
        autoEnded = false
        endWatch = MeetingEndWatch(endConfig, now())
        main.removeCallbacks(endTick)
        main.postDelayed(endTick, 2000)
    }

    private fun setEnding(p: MeetingEndWatch.Pending?) {
        if (p == ending) { if (p != null) changed(); return }
        if (p != null) Log.d("meeting end: pending ${p.reason}, ends in ${(p.deadline - now()).toInt()} s")
        else if (ending != null) Log.d("meeting end: pending cleared")
        ending = p
        changed()
    }

    fun endingTitle(p: MeetingEndWatch.Pending): String = when (val r = p.reason) {
        is MeetingEndWatch.Reason.AppLeft -> Strings.LF("%@ 已挂断", r.name)
        else -> Strings.LF("已经 %lld 分钟没人说话", maxOf(1, Math.round(endConfig.silenceAfter / 60).toInt()))
    }

    fun endingLeft(p: MeetingEndWatch.Pending) = maxOf(0, Math.round(p.deadline - now()).toInt())

    fun endingDetail(p: MeetingEndWatch.Pending) = Strings.LF("%lld 秒后结束会议并整理纪要", endingLeft(p))

    fun keepRecording() {
        endWatch?.keepGoing(now())
        setEnding(null)
        Log.d("meeting end: kept going")
    }

    private fun autoEnd(reason: MeetingEndWatch.Reason, w: MeetingEndWatch) {
        if (reason == MeetingEndWatch.Reason.NobodySpoke) {
            Log.d("meeting end: nobody spoke for ${w.config.silenceAfter.toInt()} s, stopped")
            stopListening()
            return
        }
        val at = java.time.Instant.ofEpochMilli(((w.lastSpeech + 5) * 1000).toLong())
        Log.d("meeting end: ended by itself ($reason), end time ${(now() - w.lastSpeech - 5).toInt()} s ago")
        stopListening(endedAt = at) { autoEnded = true; changed() }
    }

    fun openLive() {
        startActivity(Intent(this, ListeningActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
    }

    fun stopListening(endedAt: java.time.Instant? = null, then: (() -> Unit)? = null) {
        voice.stop()
        autoEnded = false
        endWatch = null
        setEnding(null)
        val rec = recorder; recorder = null; listen.tap = null
        val recId = listen.sessionId
        val imported = importing; importing = null
        background.execute {
            listen.stop(endedAt)
            recId?.let { namer.guess(it, force = true) }
            if (imported != null && recId != null) store.update(recId) { it.importing = null }
            recId?.let { id -> main.post { folderExport.ended(id) } }
            rec?.finish { ok -> if (ok && recId != null && store.get(recId) != null) store.update(recId) { it.hasAudio = true } }
            main.post {
                starting = 0
                micSilenced = false
                stopService(Intent(this, ListenService::class.java))
                samplePlayer?.release(); samplePlayer = null
                changed()
                then?.invoke()
            }
        }
    }

    fun listenToFile(file: File?, play: Boolean, showLive: Boolean = !play) {
        if (listen.listening) return
        if (!ling.hasKey) { startProblem = noKeyText(); changed(); return }
        val source = if (file != null) PcmAudioSource(file) else PcmAudioSource({ assets.open("sample.wav").use { Wav.read(it) } })
        source.onEnded = { reason ->
            main.postDelayed({ if (listen.listening && listen.sourceKind == "file") stopListening() }, if (reason == null) 3000 else 0)
        }
        overlayClosed = false
        overlayThisMeeting = false
        overlay.collapsed = false
        listen.start(source, "file")
        startRecording()
        watchEnd()
        if (showLive) openLive()
        if (play) {
            try {
                val fd = assets.openFd("sample.wav")
                samplePlayer = MediaPlayer().apply {
                    setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
                    prepare(); start()
                }
            } catch (e: Exception) { Log.d("sample: play failed ${e.javaClass.simpleName}") }
        }
        changed()
    }

    fun updateOverlay() {
        val want = listen.listening && (settings.overlay || overlayThisMeeting) && canOverlay && resumed == 0 && !overlayClosed
        if (want) overlay.show() else if (!overlay.forced) overlay.hide()
    }

    fun setView(view: String) {
        settings.view = view; settings.save()
        overlay.rebuild()
        changed()
    }

    fun saveSettings() { settings.save(); SpeakerLabels.voices = settings.speakerVoices; changed() }

    // MARK: AI 服务

    fun noKeyText(): String = ling.provider.let { p ->
        if (p.id == "ling") Strings.L("需要 Ling key 才能听") else Strings.LF("需要 %@ 的 key 才能听", Strings.L(p.name))
    }

    fun setAiProvider(id: String, check: Boolean = true) {
        if (Providers.named(id).id != id || id == settings.aiProvider) return
        settings.aiProvider = id
        settings.save()
        Log.d("ai: provider $id")
        aiChanged(check)
    }

    val canSwitchToLing: Boolean get() = settings.aiProvider != "ling" && Paths.keyFile("ling").isFile

    fun switchToLing() {
        if (!canSwitchToLing) return
        setAiProvider("ling")
    }

    fun setAiModel(kind: String, model: String) {
        val s = settings
        val p = s.aiProvider
        if (kind == "text" && p == "ling") s.model = model.ifEmpty { LingClient.DEFAULT_MODEL }
        else if (kind == "notes") {
            if (model.isNotEmpty()) s.aiModels[Providers.NOTES_MODEL] = model else s.aiModels.remove(Providers.NOTES_MODEL)
        } else {
            val table = when (kind) { "text" -> s.aiModels; "hear" -> s.aiHearModels; "voice" -> s.aiVoiceModels; else -> return }
            if (model.isNotEmpty()) table[p] = model else table.remove(p)
        }
        s.save()
        aiChanged()
    }

    fun setNotesOwn(on: Boolean) {
        settings.aiCustomNotesOwn = on
        settings.save()
        aiChanged()
    }

    fun setNotesBase(raw: String) {
        settings.aiCustomNotesBase = raw.trim()
        settings.save()
        aiChanged()
    }

    fun setNotesKey(raw: String?): Boolean {
        val ok = if (raw == null) { ling.removeNotesKey(); true } else ling.setNotesKey(raw)
        if (ok) aiChanged()
        return ok
    }

    fun aiChanged(check: Boolean = true) {
        translator.googleOff = settings.customOnly
        ling.keyChanged()
        if (check && ling.hasKey) background.execute { ling.check() }
        changed()
    }

    fun setCustomOnly(on: Boolean) {
        settings.aiCustomOnly = on
        settings.save()
        translator.googleOff = settings.customOnly
        Log.d("ai: custom only ${if (on) "on" else "off"}")
        changed()
    }

    fun recheck() { if (ling.hasKey && !ling.aiCheck.running) background.execute { ling.check() } }

    fun useRecommended(kind: String) {
        val p = ling.provider
        val first = (if (kind == "hear") p.hearModels else p.textModels).firstOrNull()?.id ?: return
        Log.d("ai: recommended $kind model chosen")
        setAiModel(kind, if (p.id == "ling") first else "")
    }

    fun switchService(id: String, key: String) {
        settings.aiProvider = id
        settings.save()
        translator.googleOff = settings.customOnly
        Log.d("ai: provider $id (the key's own)")
        if (!this.key.save(key)) return
        aiChanged()
    }

    private fun watchNetwork() {
        val cm = getSystemService(android.net.ConnectivityManager::class.java) ?: return
        val recheck = Runnable { background.execute { ling.networkChanged() } }
        fun later() { main.removeCallbacks(recheck); main.postDelayed(recheck, 3000) }
        try {
            cm.registerDefaultNetworkCallback(object : android.net.ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: android.net.Network) = later()
                override fun onLinkPropertiesChanged(network: android.net.Network, lp: android.net.LinkProperties) = later()
            })
        } catch (e: Exception) { Log.d("ai: no network callback ${e.javaClass.simpleName}") }
    }

    private fun startRecording() {
        val id = listen.sessionId ?: return
        if (!settings.recordAudio) return
        val rec = Recorder(store.audioFile(id))
        recorder = rec
        listen.tap = { rec.write(it) }
    }

    // MARK: 导入录音或视频 (the Mac's FileImport)

    fun importFile(context: Context, uri: android.net.Uri) {
        if (listen.listening) { startProblem = Strings.L("正在听的时候不能导入，先结束这场会议"); changed(); return }
        if (!ling.hasKey) { context.startActivity(Intent(context, OnboardingActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); return }
        startProblem = null
        try { context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) } catch (_: Exception) {}
        val intent = Intent(context, ListenService::class.java).putExtra("kind", "import").setData(uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startForegroundService(intent)
    }

    fun beginImport(uri: android.net.Uri) {
        if (listen.listening) return
        val name = FileSource.name(this, uri)
        val source = FileSource(this, uri)
        source.onEnded = { reason ->
            if (reason != null) main.post { startProblem = Strings.L("这个文件读不出声音"); changed() }
            main.postDelayed({
                if (!listen.listening || importing !== source) return@postDelayed
                val start = listen.sessionId?.let { store.get(it) }?.startedAt
                stopListening(endedAt = start?.plusMillis((source.done * 1000).toLong()))
            }, if (reason == null) 3000 else 0)
        }
        overlayClosed = true
        importing = source
        listen.start(source, "file")
        listen.sessionId?.let { id -> store.update(id) { it.sourceFile = name; it.importing = true } }
        startRecording()
        Log.d("import: started")
        changed()
        val tick = object : Runnable {
            override fun run() { if (importing === source) { changed(); main.postDelayed(this, 500) } }
        }
        main.postDelayed(tick, 500)
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        if (settings.uiLanguage == "system") { loadStrings(); changed() }
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        store.flush()
    }

    companion object {
        lateinit var shared: CicadaApp
    }
}

val Context.cicada: CicadaApp get() = applicationContext as CicadaApp
