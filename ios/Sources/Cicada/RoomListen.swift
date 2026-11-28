import AVFoundation
import Foundation
import Network

@MainActor
final class RoomListen: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id: String
        var src: String
        var dst: String?
        var voice: Int?
        var t: Double
    }

    @Published private(set) var isRunning = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var lines: [Line] = []
    @Published private(set) var draft = ""
    @Published private(set) var draftTranslation = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var status = ""
    @Published private(set) var sessionID: String?
    @Published private(set) var speakerMode = false
    @Published private(set) var paused = false
    @Published private(set) var cast = false
    @Published private(set) var castState: CastLink.State?
    @Published private(set) var castSilent = false
    @Published private(set) var micBusy = false
    private var userPaused = false
    var onWantsPicker: (() -> Void)?

    enum StartProblem: Equatable {
        case microphone
        case micBusy
        case model(ModelProblem)
        case other(String)
    }
    @Published private(set) var problem: StartProblem?
    @Published private(set) var downloading: (name: String, since: Date)?
    static var simulatedModelFailure: String?
    private var lastStart: (source: String, target: String, voices: Bool, speaker: Bool, cast: Bool)?
    private let path = NWPathMonitor()
    private var online = true

    var onLine: ((Line) -> Void)?
    var onHeard: ((_ session: String, _ lineID: String) -> Void)?
    var onEnded: ((_ session: String) -> Void)?
    static var silent = false
    private var silentClock = 0.0
    var onStateChange: (() -> Void)?
    var onMeeting: ((Bool) -> Void)?
    var onTiming: ((SentenceTiming) -> Void)?
    private var finalTiming: [String: (at: Date, recognize: Double)] = [:]

    private let store: SessionStore
    private let translator: TranslationService
    private let notes: NotesEngine
    private let speakers = SpeakerTagger()
    private let audio = RoomAudio()
    private var stream: RecognitionStream?
    private var reader: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var lang = sourceLanguages[0]
    private var target = "zh-Hans"
    private var counter = 0
    private var last: (id: String, src: String, end: Double)?
    private var draftAsked = Date.distantPast
    private var draftEpoch = 0
    private var heardVoice = false

    private var auto = false
    private var settled = true
    private var candidates: [Lang] = []
    private var detection = LanguageDetection()
    private var held: [Recognition.Piece] = []
    private var detector: Task<Void, Never>?
    private var lastVoiceAt = Date.distantPast
    private var generation = 0

    private var refiner: RecordRefiner?
    private var refinerGen = 0
    private var recordTask: Task<Void, Never>?
    private var segCounter = 0
    private var lineOfSegment: [Int: String] = [:]
    private var refining: [String: [(id: Int, text: String, settled: String?)]] = [:]
    static var recordTrackOff = false
    private static let maxCandidates = 4
    private static let giveUpSeconds = 90.0

    init(store: SessionStore, translator: TranslationService, notes: NotesEngine) {
        self.store = store
        self.translator = translator
        self.notes = notes
        speakers.onVoice = { [weak self] lineID, voice in
            guard let self else { return }
            self.store.setVoice(lineID: lineID, voice)
            if let i = self.lines.firstIndex(where: { $0.id == lineID }) { self.lines[i].voice = voice }
        }
        speakers.onProfile = { [weak self] lineID, voice, match in
            guard let self, let id = self.store.liveID else { return }
            self.store.setVoice(lineID: lineID, voice)
            self.store.setVoiceProfile(id, voice: voice, ref: match.ref)
            self.profiles?.markSeen(id: match.profile.id)
            if let i = self.lines.firstIndex(where: { $0.id == lineID }) { self.lines[i].voice = voice }
            debugLog("voice profiles: heard \(match.profile.name) (\(String(format: "%.2f", match.similarity)))")
        }
        path.pathUpdateHandler = { [weak self] p in
            let up = p.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, up != self.online else { return }
                    self.online = up
                    if up, case .model(let m)? = self.problem, m.cause == .offline { self.retry() }
                }
            }
        }
        path.start(queue: .global(qos: .utility))
    }

    func retry() {
        guard !isRunning, let s = lastStart else { return }
        debugLog("room: start again after \(String(describing: problem))")
        start(source: s.source, target: s.target, voices: s.voices, speaker: s.speaker, cast: s.cast)
    }

    func dismissProblem() { problem = nil }

    var profiles: SpeakerProfileStore? { didSet { speakers.profiles = profiles } }

    func bind(voice: Int, profile: SpeakerProfile) { speakers.bind(voice: voice, profile: profile) }

    var speakerCount: Int { Set(lines.compactMap(\.voice)).count }

    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    var languagePair: (source: String, target: String) { (lang.code, target) }

    func start(source: String, target: String, voices: Bool, speaker: Bool = false, cast: Bool = false) {
        guard !isRunning else { return }
        lastStart = (source, target, voices, speaker, cast)
        problem = nil
        speakerMode = speaker && !cast
        self.cast = cast
        castState = nil
        castSilent = false
        micBusy = false
        paused = false
        userPaused = false
        auto = source == "auto"
        settled = true
        held = []
        lang = sourceLanguages.first { $0.locale == source } ?? Pref.sourceLang
        self.target = target
        status = L("正在准备…")
        isRunning = true
        onStateChange?()
        Task { await begin(voices: voices) }
    }

    private func begin(voices: Bool) async {
        await stopping?.value
        guard isRunning else { return }
        lines = []
        draft = ""
        draftTranslation = ""
        last = nil
        counter = 0
        speakers.reset()
        heldJoin = nil
        voicePending = [:]
        if Self.silent {
            let s = store.begin()
            store.markLiveInRoom()
            sessionID = s.id
            startedAt = s.startedAt
            notes.begin(s.id)
            status = ""
            debugLog("room: listening silent (debug), no audio, session=\(s.id)")
            onStateChange?()
            return
        }
        let allowed = cast ? true : await AVAudioApplication.requestRecordPermission()
        guard allowed else {
            problem = .microphone
            fail(L("请在设置里允许知了使用麦克风"))
            return
        }
        do {
            settled = true
            held = []
            if auto {
                candidates = await autoCandidates()
                guard isRunning else { return }
                lang = initialSourceLanguage(candidates: candidates, last: UserDefaults.standard.string(forKey: Pref.lastDetected),
                                             systemLanguages: Locale.preferredLanguages)
                target = Pref.target(for: lang.code)
                settled = candidates.count < 2
                detection.start()
                debugLog("room: auto candidates=\(candidates.map(\.locale)) start=\(lang.locale)")
            }
            if await Recognition.status(lang.locale) != .installed {
                try await fetch(lang)
            }
            let live = try await Recognition.start(lang.locale, drafts: true, confidence: true)
            guard isRunning else { await live.cancel(); return }
            let stream = await withRecord(live)
            guard isRunning else { await stream.cancel(); return }
            self.stream = stream
            let s = store.begin()
            if !speakerMode && !cast { store.markLiveInRoom() }
            sessionID = s.id
            startedAt = s.startedAt
            notes.begin(s.id)
            audio.voices = voices
            audio.onInterruption = { [weak self] began in self?.interrupted(began) }
            audio.onCast = { [weak self] state in self?.castChanged(state) }
            let keep = UserDefaults.standard.bool(forKey: Pref.recordAudio)
            do {
                try audio.start(recognizer: stream, recording: keep ? AudioFileWriter.partial(store.systemAudioURL(s.id)) : nil,
                                keep: !settled, cast: cast)
            } catch where Self.micTaken(error) && !cast {
                debugLog("room: microphone taken by another app: \(error)")
                stop()
                problem = .micBusy
                status = L("别的 app 在用麦克风")
                return
            }
            heardVoice = false
            audio.onLevel = { [weak self] v in
                guard let self, !self.paused else { return }
                self.level = v
                if v > 0.55 {
                    self.heardVoice = true
                    self.lastVoiceAt = Date()
                    if self.status == L("没听到声音，请拔掉耳机或调大音量") { self.status = "" }
                    if !self.settled, self.status.isEmpty { self.status = L("正在识别语言…") }
                }
            }
            read(stream)
            status = cast ? L("点“开始直播”后开始听") : ""
            if cast { castState = .waiting; onWantsPicker?() }
            onMeeting?(true)
            if speakerMode { watchSilence(s.id) }
            if !settled { watchLanguage() }
            debugLog("room: listening locale=\(lang.locale) target=\(target) speaker=\(speakerMode) cast=\(cast) format=\(stream.format) session=\(s.id)")
            onStateChange?()
        } catch let failure as ModelFailure {
            problem = .model(failure.problem)
            fail(L("没能下载 \(lang.name) 语音模型"))
        } catch {
            debugLog("room: start failed: \(error)")
            let message = Recognition.needsUser(error) ? error.localizedDescription : L("没能开始听，再试一次")
            problem = .other(message)
            fail(message)
        }
    }

    private func read(_ stream: RecognitionStream) {
        generation += 1
        let gen = generation
        reader = Task { [weak self] in
            do {
                for try await piece in stream.results { self?.handle(piece, gen) }
            } catch {
                guard let self, gen == self.generation else { return }
                debugLog("room: recognizer ended: \(error)")
                guard self.isRunning else { return }
                self.stop()
                self.status = L("识别中断了，请重新开始听")
            }
        }
    }

    // MARK: 自动识别

    private func autoCandidates() async -> [Lang] {
        let likely = likelySourceLanguages(last: UserDefaults.standard.string(forKey: Pref.lastDetected),
                                           systemLanguages: Locale.preferredLanguages).prefix(2)
        var out: [Lang] = []
        for lang in likely {
            if await Recognition.status(lang.locale) != .installed {
                do { try await fetch(lang) } catch {
                    debugLog("room: auto can't fetch \(lang.locale): \(error)")
                    continue
                }
            }
            out.append(lang)
        }
        for lang in sourceLanguages where out.count < Self.maxCandidates && !out.contains(lang) {
            if await Recognition.status(lang.locale) == .installed { out.append(lang) }
        }
        return out
    }

    private func watchLanguage() {
        detector?.cancel()
        detector = Task { [weak self] in
            var checkedAt = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isRunning, !self.settled else { return }
                if self.paused { continue }
                let kept = self.audio.keptSeconds
                if kept > Self.giveUpSeconds {
                    debugLog("room: auto gave up after \(Int(kept))s, staying in \(self.lang.locale)")
                    self.settle()
                    return
                }
                guard kept >= 5, kept - checkedAt >= 4, Date().timeIntervalSince(self.lastVoiceAt) < 3 else { continue }
                checkedAt = kept
                let ranked = await LanguageDetector.rank(self.audio.keptClip(last: 8), candidates: self.candidates)
                guard self.isRunning, !self.settled else { return }
                debugLog("room: auto check " + ranked.map { String(format: "%@=%.2f", $0.lang.locale, $0.score) }.joined(separator: " "))
                switch self.detection.apply(ranked, active: self.lang) {
                case .confirmed:
                    self.settle()
                case .switchTo(let other, _):
                    await self.switchTo(other)
                default:
                    if self.detection.settledEnough { self.settle() }
                }
            }
        }
    }

    private func settle() {
        guard !settled else { return }
        settled = true
        audio.stopKeeping()
        UserDefaults.standard.set(lang.locale, forKey: Pref.lastDetected)
        if status == L("正在识别语言…") { status = "" }
        debugLog("room: auto settled on \(lang.locale), \(held.count) lines held")
        let pieces = held
        held = []
        for p in pieces { handle(p, generation) }
        onStateChange?()
    }

    private func switchTo(_ other: Lang) async {
        guard let live = try? await Recognition.start(other.locale, drafts: true, confidence: true) else {
            debugLog("room: auto can't start \(other.locale), staying in \(lang.locale)")
            settle()
            return
        }
        guard isRunning, !settled else { await live.cancel(); return }
        let next = await withRecord(live, locale: other.locale)
        guard isRunning, !settled else { await next.cancel(); return }
        let old = stream
        lang = other
        target = Pref.target(for: other.code)
        held = []
        draft = ""
        draftTranslation = ""
        reader?.cancel()
        stream = next
        read(next)
        audio.replay(into: next)
        Task { await old?.cancel() }
        debugLog("room: auto switched to \(other.locale)")
        settle()
    }

    private func interrupted(_ began: Bool) {
        guard isRunning, !cast else { return }
        micBusy = began && CastLink.available
        if began {
            guard !paused else { return }
            paused = true
            level = 0
            status = L("已暂停，结束后接着听")
            debugLog("room: interrupted")
            return
        }
        guard paused, !userPaused else { return }
        do {
            try audio.resume()
            paused = false
            status = L("继续听")
            debugLog("room: resumed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.status == L("继续听") { self?.status = "" }
            }
        } catch {
            debugLog("room: resume failed: \(error)")
            resumeWhenActive = true
        }
        onStateChange?()
    }

    private var resumeWhenActive = false

    func setPaused(_ on: Bool) {
        guard isRunning, sessionID != nil, on != userPaused else { return }
        userPaused = on
        if on {
            paused = true
            level = 0
            draft = ""
            draftTranslation = ""
            status = L("已暂停")
            if !Self.silent { audio.pause() }
            debugLog("room: paused by the user")
        } else {
            do {
                if !Self.silent { try audio.resume() }
                paused = false
                status = ""
                debugLog("room: resumed by the user")
            } catch {
                debugLog("room: resume failed: \(error)")
                userPaused = true
            }
        }
        onStateChange?()
    }

    func appBecameActive() {
        guard resumeWhenActive, isRunning, paused else { return }
        resumeWhenActive = false
        interrupted(false)
    }

    private func watchSilence(_ id: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.isRunning, self.sessionID == id, !self.paused,
                  !self.heardVoice, self.lines.isEmpty, self.status.isEmpty else { return }
            self.status = L("没听到声音，请拔掉耳机或调大音量")
        }
    }

    func debugInterrupt(_ began: Bool) { audio.debugInterrupt(began) }

    // MARK: 手机里的声音

    static func micTaken(_ error: Error) -> Bool {
        let code = (error as NSError).code
        return [AVAudioSession.ErrorCode.insufficientPriority.rawValue, AVAudioSession.ErrorCode.cannotStartRecording.rawValue,
                AVAudioSession.ErrorCode.isBusy.rawValue].contains(code)
    }

    func switchToCast() {
        guard isRunning, !cast, sessionID != nil else { return }
        do {
            try audio.switchToCast()
        } catch {
            debugLog("room: can't switch to the phone's sound: \(error)")
            status = L("没能开始听，再试一次")
            return
        }
        cast = true
        speakerMode = false
        micBusy = false
        paused = false
        userPaused = false
        resumeWhenActive = false
        castSilent = false
        castState = .waiting
        status = L("点“开始直播”后开始听")
        debugLog("room: switched to the phone's sound")
        onWantsPicker?()
        onStateChange?()
    }

    func showPicker() { onWantsPicker?() }

    func dismissMicBusy() { micBusy = false }

    func waitOutSilence() { castSilent = false; castWaited = true }

    private var castWaited = false

    private func castChanged(_ state: CastLink.State) {
        guard isRunning, cast else { return }
        castState = state
        switch state {
        case .connected:
            if status == L("点“开始直播”后开始听") { status = "" }
            castWaited = false
            watchCastSilence(sessionID)
        case .ended:
            debugLog("room: the broadcast stopped, ending")
            stop()
        case .waiting:
            break
        }
        onStateChange?()
    }

    private func watchCastSilence(_ id: String?) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.isRunning, self.cast, self.sessionID == id, self.castState == .connected else { return }
            let heard = self.audio.castHeard
            debugLog("cast: after 15 s heard=\(heard)")
            if !heard && !self.castWaited && self.lines.isEmpty { self.castSilent = true }
            while !heard, self.isRunning, self.cast, self.sessionID == id {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.audio.castHeard { self.castSilent = false; return }
            }
        }
    }

    struct ModelFailure: Error { let problem: ModelProblem }

    private func fetch(_ lang: Lang) async throws {
        status = L("正在下载 \(lang.name) 语音模型…")
        downloading = (lang.name, Date())
        defer { downloading = nil }
        var freed = false
        while true {
            let simulated = Self.simulatedModelFailure
            do {
                if let simulated {
                    Self.simulatedModelFailure = nil
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    throw ModelProblem.simulated(simulated)
                }
                try await Recognition.install(lang.locale)
                return
            } catch {
                let cause = ModelProblem.cause(of: error, online: online, freeBytes: ModelProblem.freeBytes())
                debugLog("room: model problem \(lang.locale): \(cause)")
                if cause == .limit, simulated == nil, !freed, await freeModelSlot(for: lang) {
                    freed = true
                    continue
                }
                throw ModelFailure(problem: ModelProblem(lang: lang, cause: cause, picked: true))
            }
        }
    }

    private func freeModelSlot(for wanted: Lang) async -> Bool {
        let keep = Set(likelySourceLanguages(last: UserDefaults.standard.string(forKey: Pref.lastDetected),
                                             systemLanguages: Locale.preferredLanguages).map(\.locale) + [wanted.locale, lang.locale])
        for locale in await Recognition.reservedLocales() where !keep.contains(locale) {
            if await Recognition.release(locale) {
                debugLog("room: model limit, gave back \(locale) for \(wanted.locale)")
                return true
            }
        }
        return false
    }

    private func fail(_ message: String) {
        status = message
        isRunning = false
        onStateChange?()
    }

    func stop(endedAt: Date? = nil) {
        guard isRunning else { return }
        detector?.cancel()
        detector = nil
        if !settled, sessionID != nil { settle() }
        if let h = heldJoin {
            heldJoin = nil
            voicePending[h.piece.start] = appendLine(h.piece, h.text)
        }
        settled = true
        isRunning = false
        paused = false
        userPaused = false
        micBusy = false
        castSilent = false
        castState = nil
        resumeWhenActive = false
        if !Self.silent { audio.stop() }
        let stream = self.stream, reader = self.reader, recordTask = self.recordTask
        self.stream = nil
        self.reader = nil
        stopping = Task {
            await stream?.finish()
            reader?.cancel()
            await recordTask?.value
            notes.finish()
            let ended = sessionID
            store.end(at: endedAt, heardSpeech: heardVoice)
            if let ended, store.session(ended) != nil { onEnded?(ended) }
            debugLog("room: stopped lines=\(lines.count)")
            onMeeting?(false)
            sessionID = nil
            startedAt = nil
            level = 0
            onStateChange?()
        }
        onStateChange?()
    }

    private func handle(_ piece: Recognition.Piece, _ gen: Int) {
        guard gen == generation else { return }
        if !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            heardVoice = true
            lastVoiceAt = Date()
            if !settled, status.isEmpty { status = L("正在识别语言…") }
        }
        guard settled else {
            if piece.isFinal { held.append(piece) }
            return
        }
        let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard piece.isFinal else {
            if text != draft {
                draft = text
                translateDraft()
            }
            return
        }
        let final = HeardText.fuller(final: HeardText.clean(text), draft: draft)
        draft = ""
        draftTranslation = ""
        draftEpoch += 1
        guard final.contains(where: \.isLetter), startedAt != nil else { return }
        contentLog("FINAL [\(lang.locale)] \(final)")
        if let h = heldJoin {
            heldJoin = nil
            voicePending[h.piece.start] = appendLine(h.piece, h.text)
        }
        if let prev = last, lines.last?.id == prev.id,
           HeardText.continues(prev.src, final, gap: piece.start - prev.end, cut: false) {
            if audio.voices, final.filter(\.isLetter).count >= 2,
               let samples = audio.voiceSamples(from: piece.start, to: piece.end) {
                heldJoin = (piece, final)
                let key = piece.start
                speakers.voice(of: samples) { [weak self] a in self?.heardVoice(key, a) }
                return
            }
            joinLine(piece, final, onto: prev)
            return
        }
        let id = appendLine(piece, final)
        if let samples = audio.voiceSamples(from: piece.start, to: piece.end) {
            speakers.tag(lineID: id, samples: samples)
        }
    }

    private var heldJoin: (piece: Recognition.Piece, text: String)?
    private var voicePending: [Double: String] = [:]

    private func heardVoice(_ key: Double, _ a: SpeakerAssignment) {
        guard let h = heldJoin, h.piece.start == key else {
            if let id = voicePending.removeValue(forKey: key) { apply(a, to: id) }
            return
        }
        heldJoin = nil
        if let prev = last, let line = lines.last, line.id == prev.id,
           a.voice == nil || line.voice == nil || a.voice == line.voice {
            joinLine(h.piece, h.text, onto: prev)
        } else {
            apply(a, to: appendLine(h.piece, h.text))
        }
    }

    private func apply(_ a: SpeakerAssignment, to id: String) {
        guard let voice = a.voice else { return }
        if let match = a.match, match.kind == .auto { speakers.onProfile?(id, voice, match) } else { speakers.onVoice?(id, voice) }
    }

    private func joinLine(_ piece: Recognition.Piece, _ final: String, onto prev: (id: String, src: String, end: Double)) {
        let joined = HeardText.join(prev.src, final)
        last = (prev.id, joined, piece.end)
        emitted(piece, final, line: prev.id)
        finalTiming[prev.id] = (Date(), max(0, audio.fedSeconds - piece.end))
        store.setSource(lineID: prev.id, joined)
        if let i = lines.firstIndex(where: { $0.id == prev.id }) { lines[i].src = joined }
        if let sid = sessionID { onHeard?(sid, prev.id) }
        translate(prev.id, joined)
    }

    @discardableResult
    private func appendLine(_ piece: Recognition.Piece, _ final: String) -> String {
        counter += 1
        let id = "r\(counter)"
        let t = max(0, Date().timeIntervalSince(startedAt ?? Date()) - max(0, audio.fedSeconds - piece.start))
        store.append(TranscriptLine(id: id, t: t, speaker: "them", src: final, dst: nil,
                                    srcLang: lang.code, dstLang: target))
        lines.append(Line(id: id, src: final, dst: nil, voice: nil, t: t))
        if let sid = sessionID { onHeard?(sid, id) }
        if lines.count > 60 { lines.removeFirst(lines.count - 60) }
        last = (id, final, piece.end)
        emitted(piece, final, line: id)
        finalTiming[id] = (Date(), max(0, audio.fedSeconds - piece.end))
        translate(id, final)
        return id
    }

    // MARK: 会后重听

    private func withRecord(_ live: RecognitionStream, locale: String? = nil) async -> RecognitionStream {
        recordTask?.cancel()
        recordTask = nil
        refiner = nil
        lineOfSegment = [:]
        refining = [:]
        guard !Self.recordTrackOff,
              let record = try? await Recognition.startRecord(locale ?? lang.locale, format: live.format) else { return live }
        refinerGen += 1
        let gen = refinerGen
        refiner = RecordRefiner()
        let session = sessionID
        recordTask = Task { [weak self] in
            do {
                for try await sentence in record.sentences {
                    guard let self, gen == self.refinerGen, self.refiner != nil else { return }
                    contentLog("RECORD \(sentence.runs.map(\.text).joined())")
                    self.settled(self.refiner!.heard(sentence.runs, through: sentence.through), session: session)
                }
            } catch {
                debugLog("room: record track: \(error)")
            }
            guard let self, gen == self.refinerGen, self.refiner != nil else { return }
            self.settled(self.refiner!.finish(), session: session)
            self.refiner = nil
        }
        debugLog("room: record track on \(locale ?? lang.locale)")
        return TeeStream(live: live, record: record)
    }

    private func emitted(_ piece: Recognition.Piece, _ text: String, line: String) {
        guard refiner != nil else { return }
        segCounter += 1
        let seg = segCounter
        lineOfSegment[seg] = line
        refining[line, default: []].append((seg, text, nil))
        settled(refiner!.emitted(id: seg, start: piece.start, end: piece.end, text: text), session: sessionID)
    }

    private func settled(_ out: [(id: Int, text: String)], session: String?) {
        for o in out { refined(o.id, o.text, session: session ?? sessionID) }
    }

    private func refined(_ seg: Int, _ text: String, session: String?) {
        guard let session, let line = lineOfSegment.removeValue(forKey: seg), var segs = refining[line],
              let k = segs.firstIndex(where: { $0.id == seg }) else { return }
        let heard = HeardText.clean(text)
        segs[k].settled = heard.contains(where: \.isLetter) ? heard : segs[k].text
        refining[line] = segs
        guard segs.allSatisfy({ $0.settled != nil }) else { return }
        refining[line] = nil
        let parts = segs.map { $0.settled! }
        let whole = parts.dropFirst().reduce(parts[0]) { HeardText.join($0, $1) }
        guard let rec = store.session(session)?.lines.first(where: { $0.id == line }), whole != rec.src else { return }
        store.setSource(in: session, lineID: line, whole)
        if let i = lines.firstIndex(where: { $0.id == line }) { lines[i].src = whole }
        if last?.id == line { last?.src = whole }
        onHeard?(session, line)
        contentLog("REFINE \(line): \(rec.src) => \(whole)")
        debugLog("room: refined \(line)")
        Task { [weak self] in
            guard let self, let out = await self.translator.translate(whole, source: rec.srcLang, target: rec.dstLang, kind: .sentence) else { return }
            guard self.store.session(session)?.lines.first(where: { $0.id == line })?.src == whole else { return }
            self.store.setTranslation(in: session, lineID: line, out)
            if let i = self.lines.firstIndex(where: { $0.id == line }) { self.lines[i].dst = out }
        }
    }

    func debugHeard(_ text: String) {
        guard isRunning, Self.silent, sessionID != nil else { return }
        silentClock += 30
        let at = silentClock
        handle(Recognition.Piece(text: text, isFinal: true, start: at, end: at + 2, confidence: nil), generation)
    }

    func debugHeard(_ text: String, translation: String) {
        debugHeard(text)
        guard let i = lines.lastIndex(where: { $0.src == text }) else { return }
        lines[i].dst = translation
        store.setTranslation(lineID: lines[i].id, translation)
        onLine?(lines[i])
    }

    private func translate(_ id: String, _ text: String, retry: Int = 0) {
        let source = lang.code, target = self.target
        let trace = TranslateTrace(), asked = Date()
        Task {
            let result = await translator.translate(text, source: source, target: target, kind: .sentence, trace: trace)
            if let timing = finalTiming.removeValue(forKey: id), !trace.attempts.isEmpty {
                onTiming?(SentenceTiming(at: timing.at, side: "them", chars: text.count, recognize: timing.recognize,
                                         queue: trace.lingQueue, translate: Date().timeIntervalSince(asked), voice: nil,
                                         failed: trace.failedSeconds, via: result == nil ? "none" : trace.via, fallbacks: trace.fallbacks))
            }
            guard let out = result else {
                debugLog("room: translation failed, try \(retry + 1)")
                guard retry < 2 else { return }
                try? await Task.sleep(nanoseconds: UInt64(retry == 0 ? 10 : 20) * 1_000_000_000)
                guard isRunning, lines.first(where: { $0.id == id })?.src == text else { return }
                translate(id, text, retry: retry + 1)
                return
            }
            guard let i = lines.firstIndex(where: { $0.id == id }), lines[i].src == text else { return }
            lines[i].dst = out
            store.setTranslation(lineID: id, out)
            contentLog("TRANSLATE [\(source)→\(target)] \(text) => \(out)")
            onLine?(lines[i])
        }
    }

    private func translateDraft() {
        guard Date().timeIntervalSince(draftAsked) > 1, draft.count >= 6 else { return }
        draftAsked = Date()
        let epoch = draftEpoch, text = draft, source = lang.code, target = self.target
        Task {
            let out = await translator.translate(text, source: source, target: target, kind: .draft)
            guard epoch == draftEpoch, let out else { return }
            draftTranslation = out
        }
    }
}

final class RoomAudio: @unchecked Sendable {
    var voices = true
    var onLevel: (@MainActor (Float) -> Void)?
    var onInterruption: (@MainActor (Bool) -> Void)?
    var onCast: (@MainActor (CastLink.State) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var held = false
    private var link: CastLink?
    private var silence: AVAudioEngine?
    private var castHold = false
    private var castSound = false

    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.indaloop.cicada.room", qos: .userInitiated)
    private var toRecognizer = PCMConverter()
    private let toVoice = PCMConverter()
    private let voiceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var stream: RecognitionStream?
    private var recorder: AVAudioFile?
    private var recordGain = AutoGain()
    private var recordingURL: URL?
    private var fed = 0.0
    private var ring: [Float] = []
    private var ringStart = 0.0
    private var lastLevel = Date.distantPast
    private var keeping = false
    private var kept: [AVAudioPCMBuffer] = []
    private var keptFrames = 0

    var fedSeconds: Double { queue.sync { fed } }
    var casting: Bool { link != nil }
    var castHeard: Bool { queue.sync { castSound } }
    var keptSeconds: Double { queue.sync { Double(keptFrames) / 16_000 } }

    func keptClip(last seconds: Double) -> [AVAudioPCMBuffer] {
        queue.sync {
            var out: [AVAudioPCMBuffer] = [], frames = 0
            for b in kept.reversed() where Double(frames) < seconds * 16_000 {
                out.insert(b, at: 0)
                frames += Int(b.frameLength)
            }
            return out
        }
    }

    func stopKeeping() {
        queue.sync {
            keeping = false
            kept = []
            keptFrames = 0
        }
    }

    func replay(into recognizer: RecognitionStream) {
        queue.sync {
            stream = recognizer
            toRecognizer = PCMConverter()
            fed = 0
            let conv = PCMConverter()
            for b in kept {
                guard let c = conv.convert(b, to: recognizer.format) else { continue }
                recognizer.append(c)
                fed += Double(c.frameLength) / c.format.sampleRate
            }
            keeping = false
            kept = []
            keptFrames = 0
        }
    }

    func start(recognizer: RecognitionStream, recording: URL?, keep: Bool = false, cast: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        if cast {
            reset(recognizer: recognizer, recording: recording, keep: keep)
            try beginCast()
            observe(session)
            return
        }
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
        try session.setActive(true)
        engine = AVAudioEngine()
        reset(recognizer: recognizer, recording: recording, keep: keep)
        try tapAndStart()
        observe(session)
    }

    func switchToCast() throws {
        guard link == nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        held = false
        try beginCast()
    }

    private func beginCast() throws {
        queue.sync {
            castHold = false
            castSound = false
            toRecognizer = PCMConverter()
        }
        keepAwake()
        let link = CastLink()
        link.onAudio = { [weak self] b in
            guard let self else { return }
            self.queue.async {
                guard !self.castHold else { return }
                if !self.castSound, let p = b.floatChannelData?[0] {
                    for i in 0..<Int(b.frameLength) where abs(p[i]) > 0.0001 { self.castSound = true; break }
                }
                self.feed(b)
            }
        }
        link.onState = onCast
        try link.start()
        self.link = link
    }

    private func keepAwake() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let e = silence ?? AVAudioEngine()
            _ = e.mainMixerNode
            e.mainMixerNode.outputVolume = 0
            if !e.isRunning { try e.start() }
            silence = e
            debugLog("cast: keeping awake with a silent mixable output")
        } catch {
            debugLog("cast: keep awake failed: \(error)")
        }
    }

    private func reset(recognizer: RecognitionStream, recording: URL?, keep: Bool) {
        queue.sync {
            stream = recognizer
            recordingURL = recording
            recordGain = AutoGain()
            fed = 0
            ring = []
            ringStart = 0
            keeping = keep
            kept = []
            keptFrames = 0
        }
    }

    private func tapAndStart() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        debugLog("room: input \(format) route=\(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName))")
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            self.queue.async { self.feed(copy) }
        }
        engine.prepare()
        try engine.start()
    }

    func pause() {
        held = true
        if link != nil { queue.sync { castHold = true }; return }
        engine.pause()
    }

    func resume() throws {
        held = false
        if link != nil { queue.sync { castHold = false }; return }
        try AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try tapAndStart() }
    }

    private func observe(_ session: AVAudioSession) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] n in
                guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                let began = type == .began
                if let self, self.link != nil {
                    debugLog("cast: own session interrupted=\(began)")
                    if !began { self.keepAwake() }
                    return
                }
                self?.held = began
                if began { self?.engine.pause() }
                let cb = self?.onInterruption
                MainActor.assumeIsolated { cb?(began) }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self, !self.held, !self.engine.isRunning else { return }
                debugLog("room: engine configuration changed")
                try? self.tapAndStart()
            },
        ]
    }

    func debugInterrupt(_ began: Bool) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: (began ? AVAudioSession.InterruptionType.began : .ended).rawValue])
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let link {
            link.stop()
            self.link = nil
            silence?.stop()
            silence = nil
        } else {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        queue.sync {
            stream = nil
            recorder = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let stream else { return }
        if let c = toRecognizer.convert(buffer, to: stream.format) {
            stream.append(c)
            fed += Double(c.frameLength) / c.format.sampleRate
        }
        guard let v = toVoice.convert(buffer, to: voiceFormat), let p = v.floatChannelData?[0] else { return }
        let n = Int(v.frameLength)
        if recorder == nil, let url = recordingURL { recorder = AudioFileWriter.open(url, format: voiceFormat) }
        if let recorder, let loud = v.copy() as? AVAudioPCMBuffer, let q = loud.floatChannelData?[0] {
            recordGain.apply(q, count: n)
            try? recorder.write(from: loud)
        }
        if keeping {
            kept.append(v)
            keptFrames += n
        }
        if voices {
            ring.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
            let keep = 60 * 16_000
            if ring.count > keep + 16_000 {
                let drop = ring.count - keep
                ring.removeFirst(drop)
                ringStart += Double(drop) / 16_000
            }
        } else {
            ringStart = fed
        }
        if Date().timeIntervalSince(lastLevel) > 0.08 {
            lastLevel = Date()
            var sum: Float = 0
            for i in 0..<n { sum += p[i] * p[i] }
            let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
            let db = 20 * log10(max(rms, 1e-6))
            let v = max(0, min(1, (db + 50) / 40))
            let cb = onLevel
            DispatchQueue.main.async { MainActor.assumeIsolated { cb?(v) } }
        }
    }

    func voiceSamples(from: Double, to: Double) -> [Float]? {
        queue.sync {
            guard voices else { return nil }
            let a = max(0, Int((from - ringStart) * 16_000)), b = min(ring.count, Int((to - ringStart) * 16_000))
            guard b - a >= Int(Voiceprints.minSeconds * 16_000) else { return nil }
            return Array(ring[a..<min(b, a + Int(Voiceprints.maxSeconds * 16_000))])
        }
    }
}
