import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import Speech

// MARK: - Output devices

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    var isVirtualMic: Bool {
        let n = name.lowercased()
        return n.contains("blackhole") || n.contains("livesubs") || n.contains("cicada") || n.contains("loopback")
    }
}

enum AudioDevices {
    static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0) }
        return status == noErr ? value as String : nil
    }

    static func outputs() -> [OutputDevice] { devices(scope: kAudioObjectPropertyScopeOutput) }

    static func devices(scope: AudioObjectPropertyScope) -> [OutputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &s) == noErr, s > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName),
                  !uid.hasPrefix("com.wquguru.cicada") else { return nil }
            return OutputDevice(id: id, uid: uid, name: name)
        }
    }

    static var virtualMic: OutputDevice? { outputs().first(where: \.isVirtualMic) }

    static func name(_ device: AudioObjectID) -> String? { string(device, kAudioObjectPropertyName) }

    static var defaultOutput: OutputDevice? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return outputs().first { $0.id == id }
    }
}

// MARK: - Speak engine

@MainActor
final class SpeakEngine {
    enum Phase { case idle, listening, translating, speaking }

    var onLive: ((_ phase: Phase, _ source: String, _ translation: String) -> Void)?
    var onUtterance: ((_ source: String, _ translation: String, _ from: String, _ to: String, _ secondsAgo: Double) -> Void)?
    var onStatus: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    var translate: ((_ text: String, _ from: String, _ to: String, _ trace: TranslateTrace) async -> String?)?
    var interpret: ((_ wav: Data, _ from: String, _ to: String, _ trace: TranslateTrace) async -> (original: String, translation: String)?)?
    var onTiming: ((SentenceTiming) -> Void)?
    var onLatency: ((Double) -> Void)?
    var probe: SpeakProbe?
    private var releasedAt: Date?
    private(set) var firstAudioAt: Date?
    private(set) var lastVoice = ""
    var inputDevice: (() -> OutputDevice?)?
    var roomLanguage: (() -> String?)?

    let settings: AppSettings
    private(set) var phase: Phase = .idle {
        didSet {
            if phase == .idle { unitIdle() }
            if handsFree, phase == .idle || phase == .speaking, !segments.isEmpty {
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.nextSegment() } }
            }
        }
    }

    private var mic = AVAudioEngine()
    private let voiceMic: VoiceMic
    var echoCancel = true
    private var echoInput: AudioObjectID? {
        guard micTaken?() != true, let d = inputDevice?(), !d.isVirtualMic else { return nil }
        return d.id
    }
    private let micQueue = DispatchQueue(label: "com.wquguru.cicada.mic", qos: .userInitiated)
    private let converter = PCMConverter()
    private var analyzerFormat: AVAudioFormat?
    private var analyzerLocale = ""
    private nonisolated(unsafe) var feeding = false
    private var finals: [String] = []
    private var volatile = ""
    private var pressStarted = Date()
    private var pressPlain = false
    var micTaken: (() -> Bool)?
    var playedShare: ((Date, Date) -> Double)?
    static let echoShare = 0.5
    private nonisolated(unsafe) var micRecorder: AVAudioFile?
    private nonisolated(unsafe) var micRecordURL: URL?
    private nonisolated(unsafe) var pressSamples: [Int16] = []
    private nonisolated(unsafe) var pressConverter = PCMConverter()
    private nonisolated static let pressFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    private nonisolated static let pressLimit = 16_000 * 60

    private let synth = AVSpeechSynthesizer()
    private var out = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var outObserver: NSObjectProtocol?
    private var outFormat: AVAudioFormat?
    private var outDevice: OutputDevice?
    private var outDeviceUID: String?
    private(set) var lastDevice: OutputDevice?
    var debugOutputURL: URL?

    init(settings: AppSettings, voiceMic: VoiceMic) {
        self.settings = settings
        self.voiceMic = voiceMic
        wireOutput()
    }

    // MARK: Hands-free

    var handsFree = false {
        didSet { if handsFree != oldValue { refreshHandsFree() } }
    }
    static let handsFreeVoiced = 0.8
    private var pressHandsFree = false
    var meetingSaid: ((_ text: String, _ from: Date, _ to: Date) async -> Bool)?
    private var handsFreeInput: AudioObjectID?
    private var handsFreeTimer: Timer?
    private var segments: [(buffers: [AVAudioPCMBuffer], start: Date, end: Date)] = []
    private nonisolated(unsafe) var detector = HandsFreeDetector()
    private nonisolated(unsafe) var recent: [AVAudioPCMBuffer] = []
    private nonisolated(unsafe) var recentSeconds = 0.0
    private nonisolated(unsafe) var segment: [AVAudioPCMBuffer]?
    private nonisolated(unsafe) var segmentStart = Date()
    private nonisolated(unsafe) var dump: FileHandle?
    func setHandsFreeDump(_ path: String?) {
        micQueue.sync {
            try? dump?.close()
            dump = nil
            guard let path else { return }
            FileManager.default.createFile(atPath: path, contents: nil)
            dump = FileHandle(forWritingAtPath: path)
        }
    }
    private nonisolated static let lookback = 0.8

    func refreshHandsFree() {
        let want = handsFree && settings.speakEnabled && echoCancel && analyzerFormat != nil ? echoInput : nil
        if let d = handsFreeInput, want != d || !voiceMic.serves("handsfree", input: d) { stopHandsFree() }
        if handsFree, handsFreeTimer == nil {
            handsFreeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHandsFree() }
            }
        } else if !handsFree {
            handsFreeTimer?.invalidate()
            handsFreeTimer = nil
        }
        guard let d = want, handsFreeInput == nil else { return }
        handsFreeInput = d
        voiceMic.advancedDucking = true
        voiceMic.prepare(input: d) { [weak self] ok in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.handsFreeInput == d else {
                        if self.phase == .idle { self.unitIdle() }
                        return
                    }
                    let queue = self.micQueue
                    let attached = ok && self.voiceMic.attach("handsfree", input: d) { [weak self] buf in
                        queue.async { self?.hear(buf) }
                    }
                    if !attached { self.handsFreeInput = nil }
                    debugLog("hands-free: \(attached ? "listening" : "mic not ready, trying again")")
                }
            }
        }
    }

    private func stopHandsFree() {
        guard handsFreeInput != nil else { return }
        handsFreeInput = nil
        voiceMic.detach("handsfree")
        micQueue.sync { detector.reset(); segment = nil; recent = []; recentSeconds = 0 }
        voiceMic.advancedDucking = false
        if phase == .idle { unitIdle() }
        debugLog("hands-free: stopped")
    }

    private nonisolated func hear(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        guard n > 0, let d = buf.floatChannelData?[0] else { return }
        let seconds = Double(n) / buf.format.sampleRate
        dump?.write(Data(bytes: d, count: n * 4))
        if feeding {
            segment = nil
            detector.reset()
            return
        }
        recent.append(buf)
        recentSeconds += seconds
        while recentSeconds - Double(recent[0].frameLength) / buf.format.sampleRate >= Self.lookback {
            recentSeconds -= Double(recent.removeFirst().frameLength) / buf.format.sampleRate
        }
        var sum: Float = 0
        for i in 0..<n { sum += d[i] * d[i] }
        let rms = (sum / Float(n)).squareRoot()
        let line = detector.line
        switch detector.feed(rms: rms, seconds: seconds) {
        case .began:
            segment = recent
            segmentStart = Date().addingTimeInterval(-recentSeconds)
            debugLog(String(format: "hands-free: voice began (%.0f dB over a %.0f dB line)", 20 * log10(max(rms, 1e-6)), 20 * log10(line)))
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.voiceBegan() } }
        case .ended(let cut):
            guard let s = segment else { return }
            let start = segmentStart
            segment = cut ? [] : nil
            segmentStart = Date()
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.voiceEnded(s, start: start, cut: cut) } }
        case .none:
            segment?.append(buf)
        }
    }

    private func voiceBegan() {
        if phase == .idle { onLive?(.listening, "", "") }
    }

    private func voiceEnded(_ buffers: [AVAudioPCMBuffer], start: Date, cut: Bool) {
        debugLog(String(format: "hands-free: sentence of %.1f s%@", Date().timeIntervalSince(start), cut ? " (cut, still talking)" : ""))
        segments.append((buffers, start, Date()))
        nextSegment()
    }

    private func nextSegment() {
        guard phase == .idle || phase == .speaking, !segments.isEmpty else { return }
        guard let format = analyzerFormat, let input = beginUtterance() else {
            debugLog("hands-free: transcriber not ready, sentence dropped")
            segments.removeFirst()
            return
        }
        let s = segments.removeFirst()
        pressStarted = s.start
        pressPlain = false
        pressHandsFree = true
        phase = .listening
        let conv = PCMConverter()
        for buf in s.buffers {
            guard let c = conv.convert(buf, to: format) else { continue }
            input.append(c)
            micQueue.sync { keepForMing(c) }
        }
        releasedAt = s.end
        finishUtterance()
    }

    private func wireOutput() {
        out.attach(player)
        outObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: out, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    func newOutputEngine() {
        if phase == .speaking {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.newOutputEngine() }
            }
            return
        }
        if let outObserver { NotificationCenter.default.removeObserver(outObserver) }
        player.stop()
        out.stop()
        out = AVAudioEngine()
        player = AVAudioPlayerNode()
        outFormat = nil
        outDeviceUID = nil
        wireOutput()
        debugLog("voice output: new engine after the voice mic changed")
    }

    var targetCode: String {
        if settings.speakTo != "room" { return settings.speakTo }
        let room = roomLanguage?() ?? "en"
        return room == settings.speakFromLang.code ? "en" : room
    }

    var micDeviceName: String { AudioDevices.inputDevice(of: mic) }

    func setRecording(_ url: URL?) {
        micQueue.sync {
            micRecorder = nil
            micRecordURL = url
        }
    }

    // MARK: Transcriber

    func prepare() async {
        let lang = settings.speakFromLang
        guard analyzerLocale != lang.locale || analyzerFormat == nil else { return }
        do {
            try await Recognition.install(lang.locale) { _ in self.onStatus?(L("正在下载 \(lang.name) 语音模型…")) }
            analyzerFormat = await Recognition.format(lang.locale, drafts: true)
            analyzerLocale = lang.locale
            debugLog("speak transcriber ready locale=\(lang.locale)")
        } catch {
            debugLog("speak transcriber failed: \(error)")
            onStatus?(L("无法准备语音识别：\(error.localizedDescription)"))
        }
    }

    var keepUnit = false {
        didSet { if keepUnit != oldValue, phase == .idle { unitIdle() } }
    }

    private func unitIdle() {
        if keepUnit, echoCancel, let d = echoInput { voiceMic.prepare(input: d) } else if !voiceMic.inUse { voiceMic.release() }
    }

    func teardownAnalyzer() async {
        if let input = utterance?.input { Task { await input.cancel() } }
        utterance = nil
        analyzerFormat = nil
        analyzerLocale = ""
    }

    private var utterance: (input: RecognitionStream, text: Task<String, Never>)?

    private func beginUtterance() -> RecognitionStream? {
        guard let format = analyzerFormat else { return nil }
        let lang = settings.speakFromLang
        let stream = Recognition.startNow(lang.locale, drafts: true, format: format)
        finals = []
        volatile = ""
        micQueue.sync { pressSamples = []; pressConverter = PCMConverter() }
        let task = Task { [weak self] () -> String in
            do {
                for try await r in stream.results { self?.handle(r) }
            } catch {
                debugLog("speak recognition error: \(error)")
            }
            return self?.currentText ?? ""
        }
        utterance = (stream, task)
        return stream
    }

    private func handle(_ r: Recognition.Piece) {
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.isFinal {
            if !text.isEmpty { finals.append(text) }
            volatile = ""
        } else {
            volatile = text
        }
        if phase == .listening { onLive?(.listening, currentText, "") }
    }

    private var currentText: String {
        let j = joiner(for: settings.speakFromLang.code)
        return (finals + [volatile]).filter { !$0.isEmpty }.joined(separator: j.isEmpty ? "" : " ")
    }

    // MARK: Push to talk

    func pressBegan() {
        guard settings.speakEnabled || probe != nil else { return }
        guard phase == .idle || phase == .speaking else {
            debugLog("speak: press while \(phase) ignored")
            return
        }
        if probe == nil {
            if settings.listensToRoom { onNotice?(L("同声传译是给线上会议用的")); return }
            if outputDevice() == nil { onNotice?(L("还没装虚拟麦克风，线上的人听不到你")); return }
        }
        guard let format = analyzerFormat, let input = beginUtterance() else {
            Task { await prepare() }
            onNotice?(L("语音识别仍在准备中，请再按一次"))
            return
        }
        debugLog("speak: press began")
        pressStarted = Date()
        pressHandsFree = false
        phase = .listening
        onLive?(.listening, "", "")
        startMic(format: format, input: input)
    }

    func pressCancelled() {
        guard phase == .listening else { return }
        stopMic()
        if let input = utterance?.input { Task { await input.cancel() } }
        utterance = nil
        micQueue.sync { pressSamples = [] }
        finals = []
        volatile = ""
        phase = .idle
        onLive?(.idle, "", "")
        debugLog("speak: press cancelled (chord)")
    }

    func pressEnded() {
        guard phase == .listening else { return }
        debugLog("speak: press ended")
        releasedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.finishUtterance() }
        }
    }

    func speakFile(_ url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else {
            debugLog("speakFile: unreadable \(url.path)")
            return
        }
        var buffers: [AVAudioPCMBuffer] = []
        while true {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
                  (try? file.read(into: buf)) != nil, buf.frameLength > 0 else { break }
            buffers.append(buf)
        }
        Task { await speakBuffers(buffers) }
    }

    @discardableResult
    func speakBuffers(_ buffers: [AVAudioPCMBuffer]) async -> Bool {
        guard phase == .idle || phase == .speaking, let format = analyzerFormat, let input = beginUtterance() else {
            debugLog("speakBuffers: not ready")
            return false
        }
        pressStarted = Date()
        pressHandsFree = false
        phase = .listening
        onLive?(.listening, "", "")
        let conv = PCMConverter()
        for buf in buffers {
            if let c = conv.convert(buf, to: format) {
                input.append(c)
                micQueue.sync { keepForMing(c) }
            }
            let seconds = Double(buf.frameLength) / buf.format.sampleRate
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        releasedAt = Date()
        finishUtterance()
        return true
    }

    private func startMic(format: AVAudioFormat, input cont: RecognitionStream) {
        if echoCancel || voiceMic.inUse, let device = echoInput {
            pressPlain = false
            let press = pressStarted
            voiceMic.prepare(input: device) { [weak self] ok in
                Task { @MainActor in self?.attachPress(press, ok: ok, device: device, format: format, input: cont) }
            }
            return
        }
        startPlainMic(format: format, input: cont)
    }

    private func attachPress(_ press: Date, ok: Bool, device: AudioObjectID, format: AVAudioFormat, input cont: RecognitionStream) {
        guard phase == .listening, pressStarted == press, utterance?.input === cont else {
            if phase == .idle { unitIdle() }
            return
        }
        let conv = converter
        let queue = micQueue
        feeding = true
        let started = ok && voiceMic.attach("press", input: device) { [weak self] buf in
            queue.async {
                guard let self, self.feeding, let c = conv.convert(buf, to: format) else { return }
                cont.append(c)
                self.recordMic(c)
                self.keepForMing(c)
            }
        }
        debugLog(String(format: "speak: mic %@ after %.2f s", started ? "with echo cancellation" : "plain, echo cancellation failed",
                        Date().timeIntervalSince(press)))
        if !started { startPlainMic(format: format, input: cont) }
    }

    private func startPlainMic(format: AVAudioFormat, input cont: RecognitionStream) {
        pressPlain = true
        if !voiceMic.inUse { voiceMic.release() }
        if mic.isRunning { mic.inputNode.removeTap(onBus: 0); mic.stop() }
        mic = AVAudioEngine()
        let inputNode = mic.inputNode
        AudioDevices.pinInput(mic, to: inputDevice?())
        let inFormat = inputNode.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            onNotice?(L("没有可用的麦克风"))
            phase = .idle
            return
        }
        inputNode.removeTap(onBus: 0)
        let conv = converter
        let queue = micQueue
        feeding = true
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            queue.async {
                guard let self, self.feeding else { return }
                if let c = conv.convert(buf, to: format) {
                    cont.append(c)
                    self.recordMic(c)
                    self.keepForMing(c)
                }
            }
        }
        do {
            try mic.start()
        } catch {
            debugLog("mic start failed: \(error)")
            onNotice?(L("麦克风无法启动，请在系统设置里允许\(appDisplayName)使用麦克风"))
            phase = .idle
        }
    }

    private nonisolated func keepForMing(_ buffer: AVAudioPCMBuffer) {
        guard pressSamples.count < Self.pressLimit,
              let c = pressConverter.convert(buffer, to: Self.pressFormat), let p = c.int16ChannelData else { return }
        pressSamples.append(contentsOf: UnsafeBufferPointer(start: p[0], count: Int(c.frameLength)))
    }

    private func takePressWAV() -> (wav: Data?, spoken: Bool, voiced: Double) {
        let samples = micQueue.sync { () -> [Int16] in
            defer { pressSamples = [] }
            return pressSamples
        }
        let measure = PressSpeech.measure(samples)
        let spoken = measure.spoken
        debugLog("speak: press of \(String(format: "%.1f", Double(samples.count) / 16_000)) s, \(measure.summary)")
        guard samples.count >= 16_000 / 4 else { return (nil, spoken, measure.voiced) }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { buf in
            for s in buf { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        }
        return (d, spoken, measure.voiced)
    }

    private nonisolated func recordMic(_ buffer: AVAudioPCMBuffer) {
        guard let url = micRecordURL else { return }
        if micRecorder == nil { micRecorder = AudioFileWriter.open(AudioFileWriter.partial(url), format: buffer.format) }
        try? micRecorder?.write(from: buffer)
    }

    private func stopMic() {
        micQueue.sync { feeding = false }
        voiceMic.detach("press")
        if mic.isRunning {
            mic.inputNode.removeTap(onBus: 0)
            mic.stop()
        }
    }

    private func finishUtterance() {
        stopMic()
        phase = .translating
        let probe = self.probe
        self.probe = nil
        guard let u = utterance else { phase = .idle; probe?.finish(); return }
        utterance = nil
        Task { await u.input.finish() }
        let released = releasedAt ?? Date()
        releasedAt = nil
        let (wav, spoken, voiced) = takePressWAV()
        probe?.released = released
        let quiet = wav != nil && !spoken && probe == nil
        if pressHandsFree, voiced < Self.handsFreeVoiced {
            debugLog(String(format: "hands-free: only %.2f s of voice, nothing sent", voiced))
            Task { _ = await u.text.value }
            finals = []
            volatile = ""
            phase = .idle
            onLive?(.idle, "", "")
            return
        }
        if pressPlain, probe == nil, let share = playedShare?(pressStarted, released), share > Self.echoShare {
            debugLog(String(format: "speak: the Mac played through %.0f%% of the press (echo), nothing sent", share * 100))
            Task { _ = await u.text.value }
            finals = []
            volatile = ""
            phase = .idle
            onLive?(.idle, "", L("对方在说话时说的，没有说出去"))
            return
        }
        probe?.pressWAV = wav
        let from = settings.speakFromLang.code
        let to = targetCode
        let trace = TranslateTrace()
        let route = route?(to) ?? .system(nil)
        if case .stream = route, let device = outputDevice() { configureOutput(format: Self.streamFormat, device: device); try? out.start() }
        let interpret = self.interpret
        let startMing = { Task { () -> (original: String, translation: String)? in
            guard let wav, let interpret else { return nil }
            return await interpret(wav, from, to, trace)
        } }
        let early = quiet ? nil : startMing()
        Task {
            var text = await u.text.value
            finals = []
            volatile = ""
            if quiet {
                guard !pressPlain, released.timeIntervalSince(pressStarted) >= 1, !text.isEmpty, !PressSpeech.filler(text) else {
                    debugLog("speak: nothing said in the press, nothing sent")
                    phase = .idle
                    onLive?(.idle, "", L("没听清你说的，没有说出去"))
                    return
                }
                debugLog("speak: quiet press, but the on-device recognizer heard \(text.count) chars: sending")
            }
            if !text.isEmpty { onLive?(.translating, text, "") }
            let heard = await (early ?? startMing()).value
            debugLog("speak: on-device heard \(text.count) chars, Ming \(heard.map { "\($0.original.count)" } ?? "-") chars")
            if let heard { text = heard.original }
            let short = EchoMatch.units(text).count < 3
            var echo = false
            if pressHandsFree, !text.isEmpty, !short { echo = await meetingSaid?(text, pressStarted, released) == true }
            if pressHandsFree, !text.isEmpty, short || echo {
                debugLog("hands-free: \(text.count) chars, \(short ? "too short" : "the meeting's own words"): nothing sent")
                phase = .idle
                onLive?(.idle, "", "")
                return
            }
            let textAt = Date()
            probe?.text = text
            probe?.textAt = textAt
            guard !text.isEmpty, !PressSpeech.filler(text) else {
                if !text.isEmpty { debugLog("speak: only a filler heard, nothing sent") }
                phase = .idle
                onLive?(.idle, "", "")
                probe?.finish()
                return
            }
            onLive?(.translating, text, "")
            let result: String?
            if let heard {
                result = heard.translation
            } else {
                result = await translate?(text, from, to, trace)
            }
            let translatedAt = Date()
            probe?.translation = result
            probe?.translatedAt = translatedAt
            probe?.via = result == nil ? "none" : trace.via
            probe?.from = from
            probe?.to = to
            @MainActor func timing(voice: Double?, firstAudio: Double? = nil) -> SentenceTiming {
                SentenceTiming(at: textAt, side: "me", chars: text.count, recognize: textAt.timeIntervalSince(released),
                               queue: trace.lingQueue, translate: translatedAt.timeIntervalSince(textAt), voice: voice,
                               failed: trace.failedSeconds, via: result == nil ? "none" : trace.via, fallbacks: trace.fallbacks,
                               firstAudio: firstAudio)
            }
            guard let translated = result else {
                debugLog("speak: translation failed, nothing sent")
                if probe == nil { onTiming?(timing(voice: nil)) }
                phase = .idle
                onLive?(.idle, text, L("这句没翻译成 · 没有说出去"))
                probe?.finish()
                return
            }
            guard outputDevice() != nil else {
                debugLog("speak: no virtual mic, nothing sent")
                if probe == nil { onTiming?(timing(voice: nil)) }
                phase = .idle
                onLive?(.idle, text, L("没有虚拟麦克风 · 没有说出去"))
                probe?.finish()
                return
            }
            contentLog("SPEAK [\(from)→\(to)] via=\(trace.via) \(text) => \(translated)")
            debugLog("speak: via=\(trace.via) recognize \(String(format: "%.2f", textAt.timeIntervalSince(released))) s translate \(String(format: "%.2f", translatedAt.timeIntervalSince(textAt))) s fallbacks=\(trace.fallbacks)")
            if probe == nil { onUtterance?(text, translated, from, to, Date().timeIntervalSince(pressStarted)) }
            phase = .speaking
            onLive?(.speaking, text, translated)
            await speak(translated, language: to, route: route)
            if let probe {
                probe.firstAudioAt = firstAudioAt
                probe.voice = lastVoice
                probe.device = lastDevice
                probe.finish()
            } else {
                onTiming?(timing(voice: Date().timeIntervalSince(translatedAt),
                                 firstAudio: firstAudioAt.map { $0.timeIntervalSince(translatedAt) }))
                if let first = firstAudioAt { onLatency?(first.timeIntervalSince(released)) }
            }
            if phase == .speaking { phase = .idle }
            onLive?(.idle, text, translated)
        }
    }

    // MARK: Voice output

    private func voice(for code: String, identifier: String? = nil) -> AVSpeechSynthesisVoice? {
        if let identifier, let v = AVSpeechSynthesisVoice(identifier: identifier) { return v }
        let lang = code == "zh-CN" ? "zh-CN" : code == "zh-TW" ? "zh-TW" : code
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        return voices.max(by: { $0.quality.rawValue < $1.quality.rawValue }) ?? AVSpeechSynthesisVoice(language: lang)
    }

    func outputDevice() -> OutputDevice? {
        let all = AudioDevices.outputs()
        if let d = all.first(where: { $0.uid == settings.speakOutput }), d.isVirtualMic { return d }
        return all.first(where: \.isVirtualMic)
    }

    private func synthesize(_ text: String, language: String, voiceID: String?) async -> [AVAudioPCMBuffer] {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice(for: language, identifier: voiceID)
        return await SpeechWriter.write(u, with: synth)
    }

    enum VoiceRoute {
        case stream((String) -> AsyncThrowingStream<Data, Error>)
        case system(String?)
    }

    var route: ((String) -> VoiceRoute)?
    var streamName: () -> String = { "ming" }

    func speak(_ text: String, language: String, device override: OutputDevice? = nil, route forced: VoiceRoute? = nil) async {
        var voiceID: String?
        firstAudioAt = nil
        lastDevice = override ?? outputDevice()
        switch forced ?? route?(language) ?? .system(nil) {
        case .stream(let make):
            let name = streamName()
            lastVoice = name
            if await speakStream(make(text), device: override ?? outputDevice()) { return }
            lastVoice = "system (\(name) failed)"
        case .system(let id):
            lastVoice = "system"
            voiceID = id
        }
        let buffers = await synthesize(text, language: language, voiceID: voiceID)
        guard let first = buffers.first else { return }
        if let url = debugOutputURL, let f = AudioFileWriter.open(url, format: first.format) {
            for b in buffers { try? f.write(from: b) }
        }
        let device = override ?? outputDevice()
        configureOutput(format: first.format, device: device)
        do {
            if !out.isRunning { try out.start() }
        } catch {
            debugLog("voice output failed: \(error)")
            return
        }
        guard outputReady(for: first.format) else { return }
        for b in buffers.dropLast() { player.scheduleBuffer(b, completionHandler: nil) }
        firstAudioAt = Date()
        player.play()
        let seconds = buffers.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        await waitPlayed(buffers[buffers.count - 1], limit: seconds + 2)
        var cur = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        if let unit = out.outputNode.audioUnit {
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &sz)
        }
        debugLog("spoke \(buffers.count) buffers to \(device?.name ?? "default output") id=\(device?.id ?? 0) readback=\(cur)")
    }

    private func speakStream(_ stream: AsyncThrowingStream<Data, Error>, device: OutputDevice?) async -> Bool {
        let format = Self.streamFormat
        let started = Date()
        var seconds = 0.0
        var carry = Data()
        var count = 0
        var firstAt: TimeInterval?
        do {
            for try await chunk in stream {
                var bytes = carry + chunk
                if bytes.count % 2 == 1 { carry = bytes.suffix(1); bytes = bytes.dropLast() } else { carry = Data() }
                let frames = bytes.count / 2
                guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
                buf.frameLength = AVAudioFrameCount(frames)
                seconds += Double(frames) / format.sampleRate
                bytes.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: Int16.self)
                    let dst = buf.floatChannelData![0]
                    for i in 0..<frames { dst[i] = Float(Int16(littleEndian: src[i])) / 32768 }
                }
                if count == 0 {
                    firstAt = Date().timeIntervalSince(started)
                    firstAudioAt = Date()
                    configureOutput(format: format, device: device)
                }
                guard outputReady(for: format) else { break }
                player.scheduleBuffer(buf, completionHandler: nil)
                if !player.isPlaying { player.play() }
                count += 1
            }
        } catch {
            debugLog("ming voice failed: \(error)")
            if count == 0 { return false }
        }
        guard count > 0 else { return false }
        if let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240), let first = firstAudioAt {
            tail.frameLength = 240
            await waitPlayed(tail, limit: max(0, seconds - Date().timeIntervalSince(first)) + 2)
        }
        debugLog("spoke ming \(count) chunks to \(device?.name ?? "default output") first audio \(String(format: "%.2f", firstAt ?? 0)) s")
        return true
    }

    private static let streamFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    private func waitPlayed(_ buffer: AVAudioPCMBuffer, limit: TimeInterval) async {
        guard outputReady(for: buffer.format) else { return }
        let once = Once()
        let played = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in once.run { cont.resume(returning: true) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { once.run { cont.resume(returning: false) } }
        }
        if !played {
            debugLog("voice output stalled (engine running=\(out.isRunning)), rebuilt")
            resetOutput()
        }
    }

    private func outputChanged() {
        guard let format = outFormat else { return }
        let playing = player.isPlaying
        out.disconnectNodeOutput(player)
        out.connect(player, to: out.mainMixerNode, format: format)
        do { try out.start() } catch { debugLog("voice output restart failed: \(error)"); return }
        if playing { player.play() }
        debugLog("voice output: configuration changed, engine restarted (playing=\(playing))")
    }

    func resetOutput() {
        player.stop()
        out.stop()
        outFormat = nil
        outDeviceUID = nil
    }

    private func configureOutput(format: AVAudioFormat, device: OutputDevice?) {
        let uid = device?.uid ?? ""
        guard outFormat != format || outDeviceUID != uid else { return }
        player.stop()
        out.stop()
        if let device, let unit = out.outputNode.audioUnit {
            var id = device.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioObjectID>.size))
        }
        out.disconnectNodeOutput(player)
        out.connect(player, to: out.mainMixerNode, format: format)
        outFormat = format
        outDeviceUID = uid
        outDevice = device
    }

    private func outputReady(for format: AVAudioFormat) -> Bool {
        if outFormat != format { configureOutput(format: format, device: outDevice) }
        guard !out.isRunning else { return true }
        do { try out.start(); return true } catch {
            debugLog("voice output failed: \(error)")
            return false
        }
    }

    func preview() {
        Task { await speak(targetCode.hasPrefix("zh") ? "这是对方会听到的声音。" : "This is the voice the room will hear.", language: targetCode) }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

final class SpeechWriter: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var cont: CheckedContinuation<[AVAudioPCMBuffer], Never>?

    static func write(_ u: AVSpeechUtterance, with synth: AVSpeechSynthesizer) async -> [AVAudioPCMBuffer] {
        let writer = SpeechWriter()
        let previous = synth.delegate
        synth.delegate = writer
        defer { synth.delegate = previous }
        return await withCheckedContinuation { cont in
            writer.cont = cont
            synth.write(u) { buf in
                guard let pcm = buf as? AVAudioPCMBuffer, pcm.frameLength > 0 else { writer.end(); return }
                writer.lock.withLock { writer.buffers.append(pcm) }
            }
        }
    }

    private func end() {
        let done = lock.withLock { () -> (CheckedContinuation<[AVAudioPCMBuffer], Never>, [AVAudioPCMBuffer])? in
            guard let c = cont else { return nil }
            cont = nil
            return (c, buffers)
        }
        done?.0.resume(returning: done!.1)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { end() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { end() }
}

enum PressSpeech {
    static let frame = 480
    static let needed = 0.3

    static func filler(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, ":：".contains(last), trimmed.count <= 12 { return true }
        return words.allSatisfy { w in fillers.contains(w) || (w.count > 1 && Set(w).count == 1 && fillers.contains(String(w.first!))) }
    }
    static let fillers: Set<String> = ["嗯", "啊", "呃", "哦", "唔", "额", "噢", "哎", "um", "uh", "hmm", "hm", "mm", "mhm", "ah", "oh", "er", "えー", "あの", "음", "어"]

    struct Measure: Equatable {
        var voiced: Double
        var floor: Float
        var line: Float
        var spoken: Bool { voiced >= PressSpeech.needed }
        var summary: String {
            func db(_ v: Float) -> String { v > 0 ? String(format: "%.0f", 20 * log10(v)) : "-inf" }
            return "voiced \(String(format: "%.2f", voiced)) s, quiet \(db(floor)) dBFS, line \(db(line)) dBFS"
        }
    }

    static func spoken(_ samples: [Int16]) -> Bool { measure(samples).spoken }

    static func measure(_ samples: [Int16]) -> Measure {
        guard samples.count >= frame else { return Measure(voiced: 0, floor: 0, line: 0) }
        var levels: [Float] = []
        var i = 0
        while i + frame <= samples.count {
            var sum: Float = 0
            for k in i..<(i + frame) { let v = Float(samples[k]) / 32768; sum += v * v }
            levels.append((sum / Float(frame)).squareRoot())
            i += frame
        }
        let floor = levels.sorted()[levels.count / 10]
        let line = min(0.016, max(0.0063, floor * 3))
        let voiced = Double(levels.filter { $0 >= line }.count) * Double(frame) / 16_000
        return Measure(voiced: voiced, floor: floor, line: line)
    }
}

