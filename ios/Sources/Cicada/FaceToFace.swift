import AVFoundation
import Foundation

@MainActor
final class FaceToFace: ObservableObject {
    enum Side: String { case me, them }

    enum Phase: Equatable {
        case idle
        case hearing(Side)
        case translating(Side)
        case speaking(Side)
    }

    struct Turn: Equatable {
        var side: Side
        var said: String
        var translation: String
    }

    @Published private(set) var active = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var heard = ""
    @Published private(set) var draftTranslation = ""
    @Published private(set) var last: Turn?
    @Published private(set) var problem = ""
    @Published var mine: Lang
    @Published var theirs: Lang

    private let store: SessionStore
    private let translator: TranslationService
    private let ling: LingClient
    private let mic = FaceMic()
    private let voice = FaceVoice()
    private var stream: RecognitionStream?
    private var reader: Task<Void, Never>?
    private var finals: [String] = []
    private var sessionID: String?
    private var startedAt = Date()
    private var counter = 0
    private var draftAsked = Date.distantPast
    private var turnTask: Task<Void, Never>?
    var debugText: String?

    @Published private(set) var handsFree = UserDefaults.standard.bool(forKey: FaceToFace.handsFreeKey)
    @Published private(set) var turnSide: Side = .me
    static let handsFreeKey = "iosFaceHandsFree"
    private var detector = HandsFreeDetector()
    private var misses = 0

    init(store: SessionStore, translator: TranslationService, ling: LingClient) {
        self.store = store
        self.translator = translator
        self.ling = ling
        mine = Self.lang(UserDefaults.standard.string(forKey: Pref.myLang)) ?? Self.defaultMine
        theirs = Pref.sourceLang
        if theirs == mine { theirs = sourceLanguages.first { $0 != mine } ?? sourceLanguages[0] }
        mic.onLevel = { [weak self] rms, seconds in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.level(rms, seconds) } }
        }
    }

    static func lang(_ locale: String?) -> Lang? { sourceLanguages.first { $0.locale == locale } }

    static var defaultMine: Lang {
        let code = myLanguage(systemLanguages: Locale.preferredLanguages)
        return sourceLanguages.first { $0.code == code }
            ?? sourceLanguages.first { $0.code.hasPrefix(String(code.prefix(2))) }
            ?? sourceLanguages[2]
    }

    func lang(_ side: Side) -> Lang { side == .me ? mine : theirs }

    func setLanguages(mine m: Lang, theirs t: Lang) {
        mine = m
        theirs = t
        UserDefaults.standard.set(m.locale, forKey: Pref.myLang)
        UserDefaults.standard.set(t.locale, forKey: Pref.sourceAuto ? Pref.lastDetected : Pref.source)
    }

    // MARK: The screen

    func open() {
        guard !active else { return }
        active = true
        phase = .idle
        last = nil
        problem = ""
        debugLog("face: open \(mine.locale) ⇄ \(theirs.locale)")
        if handsFree { turnSide = .me; misses = 0; listenNext(after: 0.3) }
    }

    func close() {
        guard active else { return }
        cancelTurn()
        voice.stop()
        mic.stop()
        if sessionID != nil {
            store.end()
            debugLog("face: closed, \(counter) turns in \(sessionID ?? "")")
        }
        sessionID = nil
        counter = 0
        active = false
        phase = .idle
    }

    // MARK: A turn

    func press(_ side: Side) {
        guard active else { return }
        if case .speaking = phase { voice.stop() }
        if case .hearing = phase { return }
        cancelTurn()
        heard = ""
        draftTranslation = ""
        problem = ""
        finals = []
        phase = .hearing(side)
        let lang = lang(side)
        debugLog("face: hearing \(side.rawValue) \(lang.locale)")
        guard debugText == nil else { return }
        turnTask = Task {
            do {
                guard await AVAudioApplication.requestRecordPermission() else {
                    fail(L("请在设置里允许知了使用麦克风"))
                    return
                }
                if await Recognition.status(lang.locale) != .installed {
                    heard = L("正在下载 \(lang.name) 语音模型…")
                    try await Recognition.install(lang.locale)
                    heard = ""
                }
                let stream = try await Recognition.start(lang.locale, drafts: true, speaking: true)
                guard phase == .hearing(side) else { await stream.cancel(); return }
                self.stream = stream
                try mic.start(into: stream)
                reader = Task { [weak self] in
                    do {
                        for try await piece in stream.results { self?.heard(piece, side: side) }
                    } catch {
                        debugLog("face: recognizer ended: \(error)")
                    }
                }
            } catch {
                debugLog("face: can't listen: \(error)")
                fail(Recognition.needsUser(error) ? error.localizedDescription : L("没能下载 \(lang.name) 语音模型"))
            }
        }
    }

    func release(_ side: Side) {
        guard phase == .hearing(side) else { return }
        phase = .translating(side)
        turnTask = Task {
            var text: String
            if let t = debugText {
                text = t
                debugText = nil
            } else {
                mic.stop()
                await stream?.finish()
                await reader?.value
                stream = nil
                reader = nil
                text = HeardText.fuller(final: finals.joined(separator: " "), draft: heard)
            }
            text = HeardText.clean(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard phase == .translating(side) else { return }
            guard text.contains(where: \.isLetter) else {
                phase = .idle
                heard = ""
                if handsFree { turnOver(side, spoken: false); return }
                problem = L("没听清，按住再说一次")
                return
            }
            heard = text
            await turn(side, text)
        }
    }

    private func heard(_ piece: Recognition.Piece, side: Side) {
        guard phase == .hearing(side) || phase == .translating(side) else { return }
        let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if piece.isFinal {
            if !text.isEmpty { finals.append(text) }
            heard = finals.joined(separator: " ")
        } else {
            heard = (finals + [text]).joined(separator: " ")
        }
        translateDraft(side)
    }

    private func translateDraft(_ side: Side) {
        guard Date().timeIntervalSince(draftAsked) > 1, heard.count >= 4 else { return }
        draftAsked = Date()
        let text = heard, from = lang(side).code, to = lang(side == .me ? .them : .me).code
        Task {
            guard let out = await translator.translate(text, source: from, target: to, kind: .draft),
                  phase == .hearing(side) else { return }
            draftTranslation = out
        }
    }

    private func turn(_ side: Side, _ text: String) async {
        let from = lang(side), to = lang(side == .me ? .them : .me)
        guard let out = await translator.translate(text, source: from.code, target: to.code, kind: .speak),
              !out.isEmpty else {
            guard phase == .translating(side) else { return }
            phase = .idle
            problem = translator.health.googleDown && !ling.hasKey && ling.provider.id == .ling ? L("连不上翻译，填 Ling key 后不用代理也能用")
                : translator.health.googleDown ? L("网络连不上，连上后再说一次") : L("没翻译出来，再说一次")
            debugLog("face: translation failed")
            turnOver(side, spoken: false)
            return
        }
        guard phase == .translating(side) else { return }
        let t = Turn(side: side, said: text, translation: out)
        last = t
        heard = ""
        draftTranslation = ""
        record(t, from: from, to: to)
        phase = .speaking(side)
        contentLog("FACE [\(from.code)→\(to.code)] \(text) => \(out)")
        await voice.speak(out, language: to.code, ling: ling.hasKey ? ling : nil, mine: side == .them)
        if phase == .speaking(side) { phase = .idle; turnOver(side, spoken: true) }
    }

    func debugTurn(_ side: Side, said: String, translation: String) {
        guard active else { return }
        let from = lang(side), to = lang(side == .me ? .them : .me)
        let t = Turn(side: side, said: said, translation: translation)
        last = t
        problem = ""
        record(t, from: from, to: to)
        phase = .speaking(side)
        turnTask = Task {
            await voice.speak(translation, language: to.code, ling: ling.hasKey ? ling : nil, mine: side == .them)
            if phase == .speaking(side) { phase = .idle }
        }
    }

    private func record(_ t: Turn, from: Lang, to: Lang) {
        if sessionID == nil {
            let s = store.begin()
            sessionID = s.id
            startedAt = s.startedAt
        }
        counter += 1
        store.append(TranscriptLine(id: "t\(counter)", t: Date().timeIntervalSince(startedAt), speaker: t.side.rawValue,
                                    src: t.said, dst: t.translation, srcLang: from.code, dstLang: to.code))
    }

    // MARK: 不用按键

    func setHandsFree(_ on: Bool) {
        handsFree = on
        UserDefaults.standard.set(on, forKey: Self.handsFreeKey)
        debugLog("face: hands-free \(on)")
        misses = 0
        if on {
            turnSide = .me
            listenNext()
        } else if case .hearing = phase {
            cancelTurn()
            phase = .idle
            heard = ""
        }
    }

    func giveTurn(_ side: Side) {
        guard handsFree, active else { return }
        if case .hearing(let s) = phase, s == side { return }
        if case .speaking = phase { voice.stop() }
        cancelTurn()
        phase = .idle
        heard = ""
        problem = ""
        misses = 0
        turnSide = side
        listenNext()
    }

    private func listenNext(after delay: Double = 0) {
        guard handsFree, active else { return }
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard handsFree, active, phase == .idle else { return }
            guard misses < 3 else { debugLog("face: hands-free waits for a tap"); return }
            detector.reset()
            press(turnSide)
        }
    }

    private func level(_ rms: Float, _ seconds: Double) {
        guard handsFree, case .hearing(let side) = phase else { return }
        if case .ended = detector.feed(rms: rms, seconds: seconds) {
            debugLog("face: hands-free heard a pause")
            release(side)
        }
    }

    private func turnOver(_ side: Side, spoken: Bool) {
        guard handsFree else { return }
        if spoken {
            misses = 0
            turnSide = side == .me ? .them : .me
        } else {
            misses += 1
        }
        listenNext(after: 0.4)
    }

    private func cancelTurn() {
        turnTask?.cancel()
        turnTask = nil
        mic.stop()
        if let s = stream { Task { await s.cancel() } }
        stream = nil
        reader?.cancel()
        reader = nil
    }

    private func fail(_ message: String) {
        cancelTurn()
        phase = .idle
        heard = ""
        problem = message
        if handsFree { misses = 3 }
    }
}

final class FaceMic: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.indaloop.cicada.face")
    private let convert = PCMConverter()
    private var stream: RecognitionStream?
    var onLevel: ((Float, Double) -> Void)?

    func start(into stream: RecognitionStream) throws {
        try FaceAudio.activate()
        engine = AVAudioEngine()
        queue.sync { self.stream = stream }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self, let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            if let onLevel = self.onLevel, let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
                onLevel((sum / Float(buffer.frameLength)).squareRoot(), Double(buffer.frameLength) / buffer.format.sampleRate)
            }
            self.queue.async {
                guard let s = self.stream, let c = self.convert.convert(copy, to: s.format) else { return }
                s.append(c)
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync { stream = nil }
    }
}

enum FaceAudio {
    static func activate() throws {
        let s = AVAudioSession.sharedInstance()
        if s.category != .playAndRecord || s.mode != .default {
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        }
        try s.setActive(true)
    }
}

@MainActor
final class FaceVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let synth = AVSpeechSynthesizer()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var spoken: CheckedContinuation<Void, Never>?
    private var streaming: Task<Bool, Never>?

    override init() {
        super.init()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        synth.delegate = self
    }

    func speak(_ text: String, language: String, ling: LingClient?, voiceID: String? = nil, mine: Bool = false) async {
        stop()
        try? FaceAudio.activate()
        let id = voiceID ?? SpeakVoices.chosenID(for: language, hasKey: ling != nil, mine: mine, clones: ling?.clones ?? false)
        if let ling, let stream = Self.stream(text, id: id, language: language, ling: ling) {
            let task = Task { await self.play(stream) }
            streaming = task
            if await task.value { debugLog("face: spoke with \(id ?? "-")"); return }
            if Task.isCancelled || streaming == nil { return }
            debugLog("face: Ling sent nothing, the phone's voice instead")
        }
        let u = AVSpeechUtterance(string: text)
        let picked = id.flatMap { $0.hasPrefix("system:") ? AVSpeechSynthesisVoice(identifier: String($0.dropFirst(7))) : nil }
        u.voice = picked ?? AVSpeechSynthesisVoice(language: Locale(identifier: language).language.minimalIdentifier)
            ?? AVSpeechSynthesisVoice(language: language)
        await withCheckedContinuation { c in
            spoken = c
            synth.speak(u)
        }
        debugLog("face: spoke with the phone's voice")
    }

    private static func stream(_ text: String, id: String?, language: String, ling: LingClient) -> AsyncThrowingStream<Data, Error>? {
        let lang = VoiceCatalog.mingLanguage(for: language)
        if id == VoiceCatalog.cloneOption.id {
            guard ling.clones else { return nil }
            guard let ref = VoiceReference.reference() else { return nil }
            return ling.speech(text, voice: nil, reference: ref, language: lang)
        }
        if let id, id.hasPrefix("cloud:") { return ling.speech(text, voice: String(id.dropFirst(6))) }
        guard let id, id.hasPrefix("ming:") else { return nil }
        return ling.speech(text, voice: String(id.dropFirst(5)), language: lang)
    }

    private func play(_ stream: AsyncThrowingStream<Data, Error>) async -> Bool {
        var carry = Data(), frames = 0
        do {
            for try await chunk in stream {
                if Task.isCancelled { break }
                var bytes = carry + chunk
                if bytes.count % 2 == 1 { carry = bytes.suffix(1); bytes = bytes.dropLast() } else { carry = Data() }
                let n = bytes.count / 2
                guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { continue }
                buf.frameLength = AVAudioFrameCount(n)
                bytes.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: Int16.self)
                    let dst = buf.floatChannelData![0]
                    for i in 0..<n { dst[i] = Float(Int16(littleEndian: src[i])) / 32768 }
                }
                if !engine.isRunning { try engine.start() }
                player.scheduleBuffer(buf, completionHandler: nil)
                if !player.isPlaying { player.play() }
                frames += n
            }
        } catch {
            debugLog("face: Ming failed: \(error)")
        }
        guard frames > 0 else { return false }
        let seconds = Double(frames) / 24_000
        if let t = player.lastRenderTime, let p = player.playerTime(forNodeTime: t) {
            let left = seconds - Double(p.sampleTime) / p.sampleRate
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64((left + 0.2) * 1_000_000_000)) }
        }
        player.stop()
        return true
    }

    func stop() {
        streaming?.cancel()
        streaming = nil
        player.stop()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if let s = spoken { spoken = nil; s.resume() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        MainActor.assumeIsolated { spoken?.resume(); spoken = nil }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        MainActor.assumeIsolated { spoken?.resume(); spoken = nil }
    }
}
