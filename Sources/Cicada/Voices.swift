import AVFoundation
import Foundation

// MARK: - Catalog

struct VoiceOption: Identifiable, Equatable {
    enum Kind: Equatable {
        case ming(String)
        case cloud(String)
        case system(String)
        case clone
    }
    let id: String
    let name: String
    let tags: [String]
    let kind: Kind

    var needsKey: Bool { if case .system = kind { return false } else { return true } }
}

enum VoiceCatalog {
    enum Service: Equatable {
        case ming
        case cloud(label: String, voices: [CloudVoice])
        case none
    }
    nonisolated(unsafe) static var service: Service = .ming

    static let languages: [(key: String, title: String)] = [
        ("en", "English"), ("zh", "中文"), ("ja", "日本語"), ("ko", "한국어"),
        ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"), ("pt", "Português"),
    ]

    static func key(for code: String) -> String {
        let base = String(code.prefix(while: { $0 != "-" }))
        return base.isEmpty ? "en" : base
    }

    static func mingLanguage(for code: String) -> String? {
        let k = key(for: code)
        return ["ja", "ko", "de", "fr", "es"].contains(k) ? k : nil
    }

    static func ming(for language: String) -> [VoiceOption] {
        func v(_ voice: String, _ name: String, _ tags: [String]) -> VoiceOption {
            VoiceOption(id: "ming:\(voice)", name: name, tags: tags, kind: .ming(voice))
        }
        switch key(for: language) {
        case "en":
            return [v("US_Emma", "Emma", [L("女"), L("美式"), L("自然对话")]), v("UK_George", "George", [L("男"), L("英式"), L("稳重")]),
                    v("UK_Charlotte", "Charlotte", [L("女"), L("英式"), L("平稳")])]
        case "zh":
            return [v("灵小雅", "小雅", [L("女"), L("清亮"), L("播报")]), v("灵小棠", "小棠", [L("女"), L("温和"), L("沉稳")]),
                    v("灵小锋", "小锋", [L("男"), L("温暖"), L("亲切")]), v("灵卓然", "卓然", [L("男"), L("沉着"), L("清楚")])]
        case "ja", "ko", "de", "fr", "es":
            return [v("US_Emma", "Emma", [L("女"), "Ming"]), v("UK_George", "George", [L("男"), "Ming"])]
        default:
            return []
        }
    }

    static func system(for language: String) -> [VoiceOption] {
        let k = key(for: language)
        let prefix = language.hasPrefix("zh-TW") ? "zh-TW" : k == "zh" ? "zh-CN" : k
        let all = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isNoveltyVoice)
                && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        var out: [VoiceOption] = []
        for gender in [AVSpeechSynthesisVoiceGender.female, .male] {
            guard let best = all.filter({ $0.gender == gender }).max(by: { $0.quality.rawValue < $1.quality.rawValue }) else { continue }
            let quality = best.quality == .premium ? L("高品质") : best.quality == .enhanced ? L("增强") : L("标准")
            out.append(VoiceOption(id: "system:\(best.identifier)", name: best.name,
                                   tags: [gender == .female ? L("女") : L("男"), L("本机"), quality], kind: .system(best.identifier)))
        }
        return out
    }

    static func remote(for language: String) -> [VoiceOption] {
        switch service {
        case .ming: return ming(for: language)
        case .cloud(let label, let voices):
            return voices.map { VoiceOption(id: "cloud:\($0.id)", name: $0.id, tags: [$0.gender, label].filter { !$0.isEmpty },
                                            kind: .cloud($0.id)) }
        case .none: return []
        }
    }

    static func options(for language: String) -> [VoiceOption] { remote(for: language) + system(for: language) }

    static func defaultID(for language: String, hasKey: Bool) -> String? {
        (hasKey ? remote(for: language).first : nil)?.id ?? system(for: language).first?.id
    }

    static let cloneOption = VoiceOption(id: "clone", name: L("我自己的声音"), tags: [], kind: .clone)

    static func sample(for language: String) -> String {
        switch key(for: language) {
        case "zh": "谢谢大家。我们来看一下上线时间表，并确定谁负责麦克风测试。"
        case "ja": "皆さん、ありがとうございます。発売スケジュールを確認しましょう。"
        case "ko": "감사합니다. 출시 일정을 함께 확인해 보겠습니다."
        case "es": "Gracias a todos. Revisemos el calendario de lanzamiento."
        case "fr": "Merci à tous. Regardons ensemble le calendrier de lancement."
        case "de": "Danke an alle. Schauen wir uns den Zeitplan für den Start an."
        case "pt": "Obrigado a todos. Vamos ver o cronograma de lançamento."
        default: "Thanks everyone. Let's look at the launch timeline and decide who owns the microphone tests."
        }
    }
}

// MARK: - The user's own voice

enum VoiceReference {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DevBuild.supportFolder).appendingPathComponent("voice")
    }
    static var audioURL: URL { folder.appendingPathComponent("reference.wav") }
    static var textURL: URL { folder.appendingPathComponent("reference.txt") }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: audioURL.path) && !(text ?? "").isEmpty
    }
    static var text: String? { try? String(contentsOf: textURL, encoding: .utf8) }

    static var duration: Double {
        guard let f = try? AVAudioFile(forReading: audioURL) else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    static func reference() -> (audio: String, text: String)? {
        #if !CICADA_IOS
        trimSaved()
        #endif
        guard let data = try? Data(contentsOf: audioURL), let text, !text.isEmpty else { return nil }
        return ("data:audio/wav;base64," + data.base64EncodedString(), text)
    }

    static func save(wav: URL, text: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        if fm.fileExists(atPath: audioURL.path) { try fm.removeItem(at: audioURL) }
        try fm.copyItem(at: wav, to: audioURL)
        trim(audioURL)
        try Data(text.utf8).write(to: textURL)
        for url in [audioURL, textURL] {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var u = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? u.setResourceValues(values)
        }
    }

    static func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Pace

    #if !CICADA_IOS

    static let slowCharacters = 2.5, slowWords = 1.6

    static func pace(text: String, samples: [Float], sampleRate: Double) -> Double? {
        let units = SpeakScore.tokens(text).count
        guard units > 0, let span = speechSpan(samples, sampleRate: sampleRate), span > 0.5 else { return nil }
        return Double(units) / span
    }

    static func isSlow(text: String, pace: Double) -> Bool {
        let tokens = SpeakScore.tokens(text)
        let characters = tokens.filter { $0.unicodeScalars.contains(where: SpeakScore.isCJK) }.count
        return pace < (characters * 2 >= tokens.count ? slowCharacters : slowWords)
    }

    static func speechSpan(_ samples: [Float], sampleRate: Double) -> Double? {
        guard let w = speechWindows(samples, sampleRate: sampleRate) else { return nil }
        return Double(w.last - w.first + 1) * Double(w.size) / sampleRate
    }

    #endif

    static func trimmed(_ samples: [Float], sampleRate: Double) -> ArraySlice<Float> {
        guard let w = speechWindows(samples, sampleRate: sampleRate) else { return samples[...] }
        let pad = Int(sampleRate * 0.2)
        return samples[max(0, w.first * w.size - pad)..<min(samples.count, (w.last + 1) * w.size + pad)]
    }

    @discardableResult
    static func trim(_ url: URL) -> Bool {
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] else { return false }
        let rate = f.processingFormat.sampleRate
        let all = Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
        let kept = trimmed(all, sampleRate: rate)
        guard all.count - kept.count > Int(rate * 0.05),
              let out = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(kept.count)),
              let dst = out.floatChannelData?[0] else { return false }
        kept.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: kept.count) }
        out.frameLength = AVAudioFrameCount(kept.count)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".trim-\(UUID().uuidString).wav")
        do {
            do {
                let w = try AVAudioFile(forWriting: tmp, settings: f.fileFormat.settings,
                                        commonFormat: f.processingFormat.commonFormat, interleaved: f.processingFormat.isInterleaved)
                try w.write(from: out)
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    #if !CICADA_IOS
    private static var checkedTrim: Date?
    static func trimSaved() {
        let date = (try? audioURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let date, date != checkedTrim else { return }
        if trim(audioURL) { debugLog("voice clone: trimmed the saved recording to \(String(format: "%.1f", duration)) s") }
        checkedTrim = (try? audioURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    #endif

    private static func speechWindows(_ samples: [Float], sampleRate: Double) -> (first: Int, last: Int, size: Int)? {
        let size = max(1, Int(sampleRate * 0.02))
        var levels: [Float] = []
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + size)
            var sum: Float = 0
            for k in i..<end { sum += samples[k] * samples[k] }
            levels.append((sum / Float(end - i)).squareRoot())
            i = end
        }
        guard let loudest = levels.max(), loudest > 0.003 else { return nil }
        let floor = loudest * 0.0178
        guard let first = levels.firstIndex(where: { $0 >= floor }),
              let last = levels.lastIndex(where: { $0 >= floor }) else { return nil }
        return (first, last, size)
    }

    #if !CICADA_IOS
    static func pace(of url: URL, text: String) -> Double? {
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] else { return nil }
        return pace(text: text, samples: Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength))),
                    sampleRate: f.processingFormat.sampleRate)
    }

    private static var savedPace: (date: Date, slow: Bool)?

    static var savedIsSlow: Bool {
        guard let date = (try? audioURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              let text else { return false }
        if let c = savedPace, c.date == date { return c.slow }
        let slow = pace(of: audioURL, text: text).map { isSlow(text: text, pace: $0) } ?? false
        savedPace = (date, slow)
        return slow
    }
    #endif

    static func passage(for locale: String) -> String {
        switch VoiceCatalog.key(for: locale) {
        case "zh": "大家好，我是这次会议的主持人。今天我们主要讨论新产品的上线计划，包括时间安排、测试范围和市场推广。请大家先看一下屏幕上的议程。"
        case "ja": "皆さん、こんにちは。今日の会議では、新製品の発売計画について話し合います。スケジュール、テストの範囲、そしてマーケティングについて順番に確認しましょう。"
        default: "Hello everyone, thanks for joining. Today we'll walk through the launch plan for the new product: the schedule, what we still need to test, and how we'll tell people about it. Let's start with the agenda on the screen."
        }
    }
}

#if !CICADA_IOS
@MainActor
final class VoiceRecorder: ObservableObject {
    enum Phase: Equatable { case idle, recording, checking, ready, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var transcript = ""

    static let maxSeconds = 30.0
    static let minSeconds = 8.0

    private let engine = AVAudioEngine()
    private nonisolated(unsafe) var file: AVAudioFile?
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private var timer: Timer?
    private var started = Date()
    private(set) var url = FileManager.default.temporaryDirectory.appendingPathComponent("livesubs-voice-\(UUID().uuidString).wav")
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var locale = "zh-CN"

    func start(locale: String, device: OutputDevice?) {
        stopEngine()
        self.locale = locale
        transcript = ""
        try? FileManager.default.removeItem(at: url)
        let input = engine.inputNode
        AudioDevices.pinInput(engine, to: device)
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let f = try? AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true),
              let conv = AVAudioConverter(from: inFormat, to: format) else {
            phase = .failed(L("麦克风没收到声音，请检查麦克风权限"))
            return
        }
        file = f
        converter = conv
        let outFormat = format
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self, let conv = self.converter, let file = self.file else { return }
            let ratio = outFormat.sampleRate / buffer.format.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return }
            var fed = false
            conv.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            try? file.write(from: out)
            var peak: Float = 0
            if let ch = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[i])) }
            }
            Task { @MainActor in self.level = min(1, peak * 2.5) }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            phase = .failed(L("无法打开麦克风：\(error.localizedDescription)"))
            return
        }
        started = Date()
        seconds = 0
        phase = .recording
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.seconds = Date().timeIntervalSince(self.started)
                if self.seconds >= Self.maxSeconds { self.finish() }
            }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func finish() {
        guard phase == .recording else { return }
        stopEngine()
        guard seconds >= Self.minSeconds else {
            phase = .failed(L("录音太短了，请至少朗读 \(Int(Self.minSeconds)) 秒"))
            return
        }
        phase = .checking
        let url = url, locale = locale
        Task {
            let text = await Self.transcribe(url, locale: locale)
            self.transcript = text
            guard text.count >= 6 else { self.phase = .failed(L("没听清录音内容，请换个安静的地方再录一次")); return }
            let pace = VoiceReference.pace(of: url, text: text)
            debugLog("voice clone: \(text.count) chars, pace \(pace.map { String(format: "%.1f", $0) } ?? "-")/s")
            if let pace, VoiceReference.isSlow(text: text, pace: pace) {
                self.phase = .failed(L("读得有点慢，克隆的声音也会这么慢。请用平时说话的语速再录一次"))
                return
            }
            self.phase = .ready
        }
    }

    func cancel() {
        stopEngine()
        phase = .idle
        try? FileManager.default.removeItem(at: url)
    }

    private func stopEngine() {
        timer?.invalidate()
        timer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        converter = nil
        level = 0
    }

    private static func transcribe(_ url: URL, locale: String) async -> String {
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil else { return "" }
        return await LoopbackTest.transcribe([buf], locale: locale)
    }
}
#endif
