import Combine
import SwiftUI

@main
struct CicadaApp: App {
    @StateObject private var model = AppModel()

    init() { ImportBackground.register() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.ling)
                .environmentObject(model.notes)
                .environmentObject(model.room)
                .onOpenURL { if !model.openedFile($0) { model.open($0) } }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    model.room.appBecameActive()
                }
                .modifier(DevWindow(model: model))
        }
    }
}

enum AppTab: String { case records, settings, search }

enum Pref {
    static let source = "sourceMode"
    static let target = "target"
    static let model = "aiModel"
    static let voices = "speakerVoices"
    static let notesLanguage = "notesLanguage"
    static let fixMisheard = "fixMisheard"
    static let askNames = "askNames"
    static let hear = "iosHear"
    static let myLang = "iosMyLang"
    static let welcomed = "iosWelcomed"
    static let recordAudio = "recordAudio"
    static let silenceEnd = "silenceEnd"
    static let silenceMinutes = "silenceMinutes"
    static var speakerMode: Bool { UserDefaults.standard.string(forKey: hear) == "speaker" }
    static var castMode: Bool { UserDefaults.standard.string(forKey: hear) == "cast" && CastLink.available }

    static var sourceAuto: Bool { (UserDefaults.standard.string(forKey: source) ?? "auto") == "auto" }

    static var sourceLang: Lang {
        let v = UserDefaults.standard.string(forKey: source) ?? "auto"
        if let lang = sourceLanguages.first(where: { $0.locale == v }) { return lang }
        let last = UserDefaults.standard.string(forKey: lastDetected)
        return likelySourceLanguages(last: last, systemLanguages: Locale.preferredLanguages).first ?? sourceLanguages[0]
    }
    static let lastDetected = "lastDetected"

    static func name(of lang: Lang) -> String {
        Locale.current.localizedString(forLanguageCode: lang.code) ?? lang.name
    }
    static var sourceCode: String { sourceAuto ? "auto" : sourceLang.code }
    static var sourceName: String { sourceAuto ? L("自动识别") : name(of: sourceLang) }

    static func pairText(_ source: String, _ target: String) -> String {
        let line = TranscriptLine(id: "", t: 0, speaker: "them", src: "", dst: nil, srcLang: source, dstLang: target)
        let s = Session(id: "", title: "", startedAt: Date(), endedAt: nil, lines: [line], hasAudio: false)
        return RecordList.pair(s, short: true) ?? ""
    }

    static func target(for source: String) -> String {
        let t = UserDefaults.standard.string(forKey: target) ?? "system"
        return t == "system" ? followSystemTarget(source: source, systemLanguages: Locale.preferredLanguages) : t
    }

    static var targetCode: String {
        let t = UserDefaults.standard.string(forKey: target) ?? "system"
        return t == "system" ? myLanguage(systemLanguages: Locale.preferredLanguages) : t
    }
}

@MainActor
final class FixPrefs: FixSwitches {
    var fixMisheard: Bool { UserDefaults.standard.bool(forKey: Pref.fixMisheard) }
    var askNames: Bool { UserDefaults.standard.bool(forKey: Pref.askNames) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var store = SessionStore()
    let ling = LingClient()
    let diagnostics = Diagnostics()
    lazy var notes = NotesEngine(ling: ling, store: store)
    lazy var translator: TranslationService = {
        let t = TranslationService(ling: ling)
        t.onHealth = { [weak self] h in self?.translationHealth = h }
        return t
    }()
    @Published var translationHealth = TranslationHealth()
    var translationDown: Bool { translationHealth.googleDown && translationHealth.sentencesUntranslated }
    lazy var room: RoomListen = {
        let r = RoomListen(store: store, translator: translator, notes: notes)
        r.onStateChange = { [weak self] in self?.listeningChanged() }
        r.onLine = { [weak self] line in self?.showOnLockScreen(line) }
        roomWatch = r.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.showInPiP() }
        }
        return r
    }()
    let importPrefs = ImportPrefs()
    let folderPrefs = FolderPrefs()
    lazy var folderExport = FolderExporter(store: store, settings: folderPrefs)
    @Published var showFolder = false
    lazy var importer: FileImporter = {
        let i = FileImporter(store: store, settings: importPrefs, translator: translator, profiles: profiles)
        i.onFinished = { [weak self] id in
            guard let self else { return }
            self.folderExport.ended(id)
            for ref in self.store.session(id)?.voiceProfiles?.values ?? [:].values { self.profiles.markSeen(id: ref.id) }
            self.speakerProfiles = self.profiles.all()
            guard self.ling.hasKey else { return }
            self.notes.generate(for: id)
        }
        ImportBackground.importer = i
        return i
    }()
    lazy var face = FaceToFace(store: store, translator: translator, ling: ling)
    @Published var showFace = false
    let profiles = SpeakerProfileStore()
    @Published var speakerProfiles: [SpeakerProfile] = []
    @Published var speakerMemoryBusy = false
    @Published var speakerProblem: (String, String)?
    @Published var showPeople = false
    @Published var noteEdit: NoteEdit?
    @Published var copiedNotes: String?
    @Published var showAIService = false
    @Published var showVoices = false
    @Published var showQuickStart = false
    @Published var exporting: String?
    @Published var importProblem: String?
    let pip = PiPSubtitles()
    private var roomWatch: AnyCancellable?
    let liveActivity = LiveActivityController()
    let vocabulary = Vocabulary(url: Vocabulary.defaultURL)
    lazy var fixes = makeFixes()
    @Published var ending: MeetingEndWatch.Pending?
    var endWatch: MeetingEndWatch?
    var endTimer: Timer?
    var endHeard = (lines: 0, draft: "")
    var endTimesOverride: (Double, Double)?
    @Published var livePage: LivePage = .subtitles
    @Published var liveHidden = false
    @Published var focusSpeaker: Int?
    @Published var tab: AppTab = .records
    @Published var selection: String? { didSet { if selection != oldValue { recordPage = firstPage(selection) } } }
    @Published var searchPath: [String] = [] { didSet { if searchPath.last != oldValue.last { recordPage = firstPage(searchPath.last) } } }
    @Published var recordPage: RecordPage = .transcript
    @Published var query = ""
    @Published var searchMatch = 0
    @Published var showSettings = false
    @Published var comingSoon: String?
    @Published var speakerUndo: SpeakerUndo?
    @Published var namingSpeaker: Int?
    @Published var editingLine: LineEdit?
    @Published var openLine: String?
    @Published var showWordList = false
    @Published var wordImport: String?
    @Published var editingWord: String?
    @Published var deletedWord: DeletedWord?
    @Published var wordConflict: WordConflict?
    @Published var showWelcome = !UserDefaults.standard.bool(forKey: Pref.welcomed)
    @Published var welcomeStep = 0
    @Published var devWindow: CGSize?

    init() {
        UserDefaults.standard.register(defaults: [Pref.source: "auto", Pref.voices: true, Pref.model: LingClient.models[0], Pref.notesLanguage: "mine",
                                                  Pref.fixMisheard: true, Pref.askNames: true, Pref.recordAudio: true,
                                                  Pref.silenceEnd: "prompt", Pref.silenceMinutes: 10.0])
        TranscriptExport.voices = UserDefaults.standard.bool(forKey: Pref.voices)
        ling.config = { AIPrefs.config }
        AIPrefs.applyVoices()
        translator.googleOff = AIPrefs.googleOff
        wireNotes()
        folderExport.settling = { [weak self] id in self?.notes.settling(id) ?? false }
        store.onSave = { [weak self] id in self?.folderExport.saved(id) }
        notes.finalDone = { [weak self] id in self?.folderExport.settled(id) }
        room.onEnded = { [weak self] id in self?.folderExport.ended(id) }
        room.profiles = profiles
        room.onWantsPicker = { CastPicker.show() }
        speakerProfiles = profiles.all()
        folderExport.retry()
        wireFixes()
        #if targetEnvironment(simulator)
        HostRecognizer.install()
        #endif
        DebugChannel.listen(self)
        IntentHub.run = { [weak self] action in self?.intent(action) }
        debugLog("ios launch \(DevBuild.label ?? "release") sessions=\(store.sessions.count) key=\(ling.hasKey)")
        if ling.hasKey { Task { await ling.check() } }
    }

    // MARK: 听会议室

    func startListening(cast: Bool? = nil) {
        guard !room.isRunning else { return }
        selection = nil
        liveHidden = false
        searchPath = []
        tab = .records
        livePage = ling.hasKey ? .notes : .subtitles
        fixes.meetingStarted()
        room.start(source: Pref.sourceAuto ? "auto" : Pref.sourceLang.locale, target: Pref.target(for: Pref.sourceCode), voices: UserDefaults.standard.bool(forKey: Pref.voices),
                   speaker: Pref.speakerMode, cast: (cast ?? Pref.castMode) && CastLink.available)
    }

    private func showInPiP() {
        guard room.isRunning, room.speakerMode || room.cast else { return }
        let waiting = room.cast ? L("正在听手机里的声音…") : L("正在听外放…")
        let last = room.lines.last
        let shown = last.flatMap { l in store.session(room.sessionID)?.lines.first { $0.id == l.id }?.shown } ?? last?.src
        if room.paused || !room.status.isEmpty {
            pip.show(src: "", dst: "", note: room.paused ? L("已暂停，结束后接着听") : room.status)
        } else if !room.draft.isEmpty {
            pip.show(src: room.draft, dst: room.draftTranslation, note: waiting)
        } else {
            pip.show(src: shown ?? "", dst: last?.dst ?? "", note: shown == nil ? waiting : "")
        }
    }

    func stopListening() { room.stop() }

    func showOnLockScreen(_ line: RoomListen.Line) {
        var shown = line
        if let rec = store.session(room.sessionID)?.lines.first(where: { $0.id == line.id }) { shown.src = rec.shown }
        liveActivity.update(line: shown)
    }

    func intent(_ action: IntentHub.Action) {
        debugLog("intent: \(action)")
        switch action {
        case .start:
            if showFace { closeFace() }
            showWelcome = false
            startListening()
        case .stop: stopListening()
        case .togglePause: room.setPaused(!room.paused)
        }
    }

    private func listeningChanged() {
        objectWillChange.send()
        liveActivity.setPaused(room.paused)
        pip.setEnabled(room.isRunning && (room.speakerMode || room.cast))
        if room.isRunning, let start = room.startedAt {
            liveActivity.start(startedAt: start, pair: Pref.pairText(room.languagePair.source, room.languagePair.target))
            watchEnd()
        } else if !room.isRunning {
            liveActivity.end()
            stopWatchingEnd()
        }
    }

    private func firstPage(_ id: String?) -> RecordPage {
        store.session(id)?.notes == nil ? .transcript : .notes
    }

    func generateNotes(_ id: String) {
        guard ling.hasKey else { return }
        recordPage = .notes
        notes.generate(for: id)
    }

    func wireFixes() {
        translator.fixContext = { [weak self] text in self?.fixes.context(for: text) }
        diagnostics.enabled = { true }
        ling.onCall = { [weak self] in self?.diagnostics.record($0) }
        translator.onDraft = { [weak self] in self?.diagnostics.recordDraft(seconds: $0, ok: $1) }
        room.onTiming = { [weak self] in self?.diagnostics.record($0) }
        room.onMeeting = { [weak self] began in if began { self?.diagnostics.begin() } else { self?.diagnostics.end() } }
        translator.onFixes = { [weak self] text, edits in self?.fixes.received(text, edits) }
        room.onHeard = { [weak self] session, line in self?.fixes.applyKnown(lineID: line, in: session) }
    }

    func makeFixes() -> LiveFixes {
        let f = LiveFixes(store: store, vocabulary: vocabulary, settings: FixPrefs())
        f.onChange = { [weak self] in self?.objectWillChange.send() }
        f.onLineFixed = { [weak self] session, line in
            guard let self, session == self.room.sessionID, let last = self.room.lines.last, last.id == line.id else { return }
            self.showOnLockScreen(last)
        }
        vocabulary.onChange = { [weak self] in self?.objectWillChange.send() }
        return f
    }

    func wireNotes() {
        notes.language = { [weak self] id in TranslationService.englishName(self?.notesLanguageCode(id) ?? Pref.targetCode) }
    }

    // MARK: Notes language (the Mac's AppModel.notesLanguageCode)

    func meetingLanguage(_ id: String) -> String? {
        let heard = store.session(id)?.lines.filter { $0.speaker != "me" }.map(\.srcLang) ?? []
        return Dictionary(heard.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }?.key
    }

    func notesLanguageCode(_ id: String) -> String {
        UserDefaults.standard.string(forKey: Pref.notesLanguage) == "source" ? (meetingLanguage(id) ?? Pref.targetCode) : Pref.targetCode
    }

    // MARK: Editing a record (the Mac's rules live in SessionStore)

    func rename(_ id: String, to title: String) {
        store.rename(id, to: title)
        debugLog("rename \(id) renamed=\(store.session(id)?.renamed ?? false)")
    }

    func deleteSession(_ id: String) {
        importer.cancel(id)
        ImportFiles.remove(store.session(id)?.sourcePath)
        if selection == id { selection = nil }
        searchPath.removeAll { $0 == id }
        if speakerUndo?.session == id { speakerUndo = nil }
        store.delete(id)
        folderExport.deleted(id)
        debugLog("delete \(id) sessions=\(store.sessions.count)")
    }

    // MARK: 词表

    func deleteWord(_ t: Vocabulary.Term) {
        let index = vocabulary.terms.firstIndex(of: t) ?? 0
        vocabulary.remove(t.word)
        let d = DeletedWord(term: t, index: index)
        deletedWord = d
        if editingWord == t.word { editingWord = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.deletedWord == d { self?.deletedWord = nil }
        }
    }

    func addHeard(_ text: String, to t: Vocabulary.Term) {
        let h = text.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, h.count <= 40 else { return }
        if let owner = vocabulary.owners(ofHeard: h, except: t.word).first {
            wordConflict = WordConflict(word: t.word, heard: h, owner: owner)
        } else {
            vocabulary.confirm(heard: h, word: t.word, source: t.source)
        }
    }

    // MARK: Speakers (the Mac's AppModel.renameSpeaker / mergeSpeaker / undoSpeakerEdit)

    func renameSpeaker(session id: String, voice: Int, _ name: String?) {
        guard let s = store.session(id) else { return }
        let n = SpeakerLabels.voiceNumbers(s)[voice] ?? 0
        let before = SpeakerLabels.label(n, SpeakerLabels.names(s))
        speakerEdit(id) { store.setVoiceName(id, voice: voice, name) }
        let after = store.session(id).map { SpeakerLabels.label(n, SpeakerLabels.names($0)) } ?? before
        if after != before { speakerUndo?.text = L("\(before) 已改成 \(after)") } else { speakerUndo = nil }
    }

    func mergeSpeaker(session id: String, _ from: Int, into: Int) {
        guard let s = store.session(id) else { return }
        let numbers = SpeakerLabels.voiceNumbers(s), names = SpeakerLabels.names(s)
        let a = SpeakerLabels.label(numbers[from] ?? 0, names), b = SpeakerLabels.label(numbers[into] ?? 0, names)
        speakerEdit(id) { store.mergeVoice(id, from, into: into) }
        speakerUndo?.text = L("\(a) 已并入 \(b)")
    }

    func undoSpeakerEdit() {
        guard let u = speakerUndo else { return }
        speakerUndo = nil
        store.restore(u.session, u.snapshot)
        debugLog("speakers: undo \(u.session)")
    }

    private func speakerEdit(_ id: String, _ change: () -> Void) {
        guard let snap = store.voiceSnapshot(id) else { return }
        change()
        let undo = SpeakerUndo(session: id, snapshot: snap, text: "")
        speakerUndo = undo
        debugLog("speakers: edit \(id)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.speakerUndo?.id == undo.id { self?.speakerUndo = nil }
        }
    }

    func open(_ url: URL) {
        guard DevBuild.isDev, url.scheme == "cicada-dev", url.host == "debug",
              let cmd = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "cmd" })?.value else { return }
        debugCommand(cmd)
    }
}

extension AppModel {
    var diagnosticsReport: String {
        var sys = utsname()
        uname(&sys)
        let model = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return diagnostics.report(version: "\(version) (\(build))", service: AIPrefs.config)
            + "\n\(model) · iOS \(UIDevice.current.systemVersion) · \(DeviceLoad.line)"
    }
}
