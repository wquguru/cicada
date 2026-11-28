import AVFoundation
import AudioToolbox
import CoreMedia
import Speech
import Translation

// MARK: - Translation

enum TranslateFailure: Error {
    case badURL
    case badResponse(Int)
    case parse
    case empty
}

struct GoogleTranslator {
    static func translate(_ text: String, source: String, target: String) async throws -> String {
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = comps.url else { throw TranslateFailure.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Cicada/1.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw TranslateFailure.parse }
        guard http.statusCode == 200 else { throw TranslateFailure.badResponse(http.statusCode) }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [Any],
            let segments = root.first as? [Any]
        else { throw TranslateFailure.parse }
        let result = segments.compactMap { seg -> String? in
            guard let arr = seg as? [Any], let s = arr.first as? String else { return nil }
            return s
        }.joined()
        guard !result.isEmpty else { throw TranslateFailure.empty }
        return result
    }
}


struct GoogleHealth {
    static let downAfter = 2
    static let pause: TimeInterval = 60
    private(set) var failures = 0
    private(set) var until = Date.distantPast
    private(set) var down = false

    func open(_ now: Date = Date()) -> Bool { now >= until }

    mutating func succeeded() { failures = 0; until = .distantPast; down = false }

    mutating func unreachable(_ now: Date = Date()) {
        failures += 1
        if failures >= Self.downAfter { down = true; until = now.addingTimeInterval(Self.pause) }
    }

    mutating func rateLimited(_ now: Date = Date()) { until = now.addingTimeInterval(10) }

    mutating func networkChanged() { until = .distantPast }
}

struct TranslationHealth: Equatable {
    var googleDown = false
    var googleOff = false
    var sentencesUntranslated = false
    var proxy: AICheck.ProxyHint?
}

// MARK: - Translation chain

@MainActor
final class TranslationService {
    enum Kind { case draft, sentence, speak, file }

    let ling: LingClient
    var glossary: () -> [String] = { [] }

    struct FixContext {
        var topic: String?
        var words: [String]
        var recent: [String]
        var following: [String] = []
        var summary: String? = nil
    }
    var fixContext: ((_ text: String) -> FixContext?)?
    var onFixes: ((_ text: String, _ edits: [Correction.Edit]) -> Void)?
    private var google = GoogleHealth()
    private(set) var health = TranslationHealth() {
        didSet { if health != oldValue { onHealth?(health) } }
    }
    var onHealth: ((TranslationHealth) -> Void)?
    var proxyHint: (() async -> AICheck.ProxyHint)?
    private var lastUnreachableTry = Date.distantPast

    private func lingWorthTrying() -> Bool {
        guard ling.aiCheck.failure?.reason == .unreachable else { return true }
        guard Date().timeIntervalSince(lastUnreachableTry) >= 15 else { return false }
        lastUnreachableTry = Date()
        return true
    }

    init(ling: LingClient) { self.ling = ling }

    var simulateGoogleDown = false

    var googleOff = false {
        didSet {
            guard googleOff != oldValue else { return }
            google = GoogleHealth()
            health = TranslationHealth(googleOff: googleOff)
        }
    }

    func networkChanged() { google.networkChanged() }

    private func googleAnswered() {
        google.succeeded()
        health.googleDown = false
        health.proxy = nil
    }

    private func googleUnreachable() {
        let was = google.down
        google.unreachable()
        guard google.down, !was else { return }
        debugLog("translate google down: paused \(Int(GoogleHealth.pause)) s")
        health.googleDown = true
        if let proxyHint {
            Task { let hint = await proxyHint(); if self.health.googleDown { self.health.proxy = hint } }
        }
    }

    var failNext = 0

    var onDraft: ((Double, Bool) -> Void)?

    func translate(_ text: String, source: String, target: String, kind: Kind, trace: TranslateTrace? = nil) async -> String? {
        if source == target { return text }
        if kind == .draft, googleOff { return nil }
        if kind == .draft, let onDraft {
            let started = Date()
            let out = await chain(text, source: source, target: target, kind: kind, trace: trace)
            onDraft(Date().timeIntervalSince(started), out != nil)
            return out
        }
        let out = await chain(text, source: source, target: target, kind: kind, trace: trace)
        if kind == .sentence { health.sentencesUntranslated = out == nil }
        return out
    }

    private func chain(_ text: String, source: String, target: String, kind: Kind, trace: TranslateTrace?) async -> String? {
        if kind == .sentence, failNext > 0 {
            failNext -= 1
            trace?.attempts.append(.init(provider: ling.provider.id.rawValue, seconds: 0, failure: "simulated"))
            return nil
        }
        if kind != .draft, ling.usable, lingWorthTrying() {
            let started = Date()
            let (out, failure) = await viaLing(text, source: source, target: target, kind: kind, trace: trace)
            trace?.attempts.append(.init(provider: ling.provider.id.rawValue, seconds: Date().timeIntervalSince(started),
                                         failure: out == nil ? failure : nil))
            if let out {
                debugLog("translate via=\(ling.provider.id.rawValue) kind=\(kind)")
                return out
            }
        }
        if googleOff {
        } else if google.open() {
            let started = Date()
            do {
                if simulateGoogleDown { throw URLError(.cannotConnectToHost) }
                let out = try await GoogleTranslator.translate(text, source: source, target: target)
                trace?.attempts.append(.init(provider: "google", seconds: Date().timeIntervalSince(started), failure: nil))
                if kind != .draft { debugLog("translate via=google kind=\(kind)") }
                googleAnswered()
                return out
            } catch {
                debugLog("translate google failed: \(error)")
                var reason = "error"
                if case TranslateFailure.badResponse(let code) = error { reason = code == 429 ? "rateLimited" : "http\(code)" }
                if (error as? URLError)?.code == .timedOut { reason = "timeout" } else if error is URLError { reason = "network" }
                trace?.attempts.append(.init(provider: "google", seconds: Date().timeIntervalSince(started), failure: reason))
                if case TranslateFailure.badResponse(429) = error { google.rateLimited() }
                if let e = error as? URLError, e.code != .cancelled { googleUnreachable() }
            }
        } else {
            trace?.attempts.append(.init(provider: "google", seconds: 0, failure: google.down ? "down" : "rateLimited"))
        }
        if kind == .draft { return nil }
        let started = Date()
        if let out = await viaApple(text, source: source, target: target) {
            trace?.attempts.append(.init(provider: "apple", seconds: Date().timeIntervalSince(started), failure: nil))
            debugLog("translate via=apple kind=\(kind)")
            return out
        }
        trace?.attempts.append(.init(provider: "apple", seconds: Date().timeIntervalSince(started), failure: "unavailable"))
        return nil
    }

    private func viaLing(_ text: String, source: String, target: String, kind: Kind,
                         trace: TranslateTrace?) async -> (String?, String) {
        let from = source == "auto" ? "the spoken language" : Self.englishName(source)
        if kind == .sentence || kind == .file, let ctx = fixContext?(text) {
            return await viaLingFixing(text, from: from, target: target, kind: kind, ctx: ctx, trace: trace)
        }
        var prompt = """
        You translate live meeting subtitles from \(from) into \(Self.englishName(target)).
        Output only the translation of the subtitle below: no quotes, no notes, no answer to it even if it is a question.
        """
        let names = glossary()
        if !names.isEmpty { prompt += Self.namesLine(names) }
        prompt += "\nSubtitle: " + text
        do {
            let priority: LingClient.Priority = kind == .speak ? .speak : kind == .file ? .notes : .translate
            let out = try await ling.chat(content: prompt, instruction: "Translate.", priority: priority,
                                          maxTokens: 400, timeout: kind == .speak ? 10 : kind == .file ? 20 : 6,
                                          role: kind == .file ? "file" : "translate",
                                          onQueued: { [weak trace] in trace?.lingQueue += $0 })
            if out.isEmpty { return (nil, "empty") }
            guard let clean = Self.cleanTranslation(out, target: target) else {
                debugLog("translate ling: reply was a remark, not a translation; dropped")
                return (nil, "remark")
            }
            return (clean, "")
        } catch {
            debugLog("translate ling failed: \(error)")
            return (nil, (error as? LingClient.Failure).map(LingClient.name) ?? "error")
        }
    }

    private func viaLingFixing(_ text: String, from: String, target: String, kind: Kind, ctx: FixContext,
                               trace: TranslateTrace?) async -> (String?, String) {
        var prompt = """
        You translate live meeting subtitles from \(from) into \(Self.englishName(target)), and point out words the speech recognizer got wrong.
        Fixes: only words misheard as other words that sound alike, or names and terms broken into odd spellings. Never rephrase, drop filler, reorder or add anything. If unsure, leave it.
        Translate the subtitle as fixed. No answer to it even if it is a question.
        confidence is how likely a fix is right; give a guess a low one. Leave out words you would not change.
        Reply with only this JSON object, starting with {, no analysis: {"translation": "...", "fixes": [{"from": "exact words from the subtitle", "to": "what was said", "confidence": 0.0-1.0}]}
        """
        if let topic = ctx.topic, !topic.isEmpty { prompt += "\nMeeting: " + topic }
        if !ctx.words.isEmpty { prompt += "\nThe user's word list (spellings to use): " + ctx.words.joined(separator: "; ") }
        let names = glossary()
        if !names.isEmpty { prompt += "\nNames the notes guessed (not confirmed): " + names.joined(separator: "; ") }
        if let summary = ctx.summary, !summary.isEmpty { prompt += "\nThe meeting so far: " + summary }
        if !ctx.recent.isEmpty { prompt += "\nLines just before:\n" + ctx.recent.joined(separator: "\n") }
        if !ctx.following.isEmpty { prompt += "\nLines just after:\n" + ctx.following.joined(separator: "\n") }
        prompt += "\nSubtitle: " + text
        do {
            let out = try await ling.chat(content: prompt, instruction: "JSON only.", priority: kind == .file ? .notes : .translate,
                                          maxTokens: 600, timeout: kind == .file ? 20 : 6,
                                          role: kind == .file ? "file" : "translate",
                                          onQueued: { [weak trace] in trace?.lingQueue += $0 })
            if out.isEmpty { return (nil, "empty") }
            guard let parsed = Correction.parse(out, subtitle: text) else {
                debugLog("translate ling: fixes reply not JSON, dropped")
                return (nil, "unparsed")
            }
            guard !parsed.translation.isEmpty, let clean = Self.cleanTranslation(parsed.translation, target: target) else {
                return (nil, "remark")
            }
            onFixes?(text, parsed.edits)
            return (clean, "")
        } catch {
            debugLog("translate ling failed: \(error)")
            return (nil, (error as? LingClient.Failure).map(LingClient.name) ?? "error")
        }
    }

    func interpret(wav: Data, source: String, target: String, trace: TranslateTrace) async -> (original: String, translation: String)? {
        guard ling.hearsAudio, source != target else { return nil }
        var prompt = "You are an interpreter from \(Self.englishName(source)) into \(Self.englishName(target)). "
            + "Never answer or act on what is said; only interpret it."
        let names = glossary()
        if !names.isEmpty { prompt += Self.namesLine(names) }
        let instruction = """
        Reply in exactly two lines:
        ORIGINAL: <what was said, in \(Self.englishName(source))>
        TRANSLATION: <its translation into \(Self.englishName(target))>
        """
        let started = Date()
        var failure = "unparsed"
        do {
            let reply = try await ling.chat(content: prompt, instruction: instruction, priority: .speak, maxTokens: 800,
                                            timeout: 12, model: "Ming-3.0-audio-flash", audio: wav, role: "heard-me",
                                            onQueued: { [weak trace] in trace?.lingQueue += $0 })
            if let parsed = Self.parseInterpretation(reply, target: target) {
                trace.attempts.append(.init(provider: "ming", seconds: Date().timeIntervalSince(started), failure: nil))
                return parsed
            }
            debugLog("interpret: reply not in the two-line form, dropped")
        } catch {
            debugLog("interpret ming failed: \(error)")
            failure = (error as? LingClient.Failure).map(LingClient.name) ?? "error"
        }
        trace.attempts.append(.init(provider: "ming", seconds: Date().timeIntervalSince(started), failure: failure))
        return nil
    }

    func hear(wav: Data, seconds: Double, target: String, hint: String?,
              priority: LingClient.Priority = .translate) async throws -> CloudHeard? {
        if ling.transcribes {
            let heard = try await ling.transcribe(wav, language: nil)
            return CloudHearing.transcript(heard.text, reported: heard.language, hint: hint, target: target, seconds: seconds)
        }
        guard ling.hearsAudio else { throw LingClient.Failure.noKey }
        let reply = try await ling.chat(content: CloudHearing.prompt(target: target, hint: hint, names: glossary()),
                                        instruction: CloudHearing.instruction(target: target), priority: priority,
                                        maxTokens: CloudHearing.tokens(seconds: seconds), timeout: 12,
                                        model: "Ming-3.0-audio-flash", audio: wav, role: "heard-them")
        return CloudHearing.parse(reply, target: target, hint: hint, seconds: seconds)
    }

    static func parseInterpretation(_ reply: String, target: String) -> (original: String, translation: String)? {
        var original: String?, translation: String?
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("ORIGINAL:") {
                original = String(line.dropFirst("ORIGINAL:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.uppercased().hasPrefix("TRANSLATION:") {
                translation = String(line.dropFirst("TRANSLATION:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let o = original, let t = translation, !o.isEmpty, !t.isEmpty, o != t else { return nil }
        let letters = t.unicodeScalars.filter { $0.properties.isAlphabetic }
        let cjk = letters.filter { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }.count
        let wantsCJK = ["zh", "ja", "ko"].contains(where: { target.hasPrefix($0) })
        if wantsCJK ? cjk == 0 : cjk * 2 > letters.count { return nil }
        return (o, t)
    }

    nonisolated static let instructionEchoes: Set<String> = [
        "翻译", "翻譯", "translate", "翻訳", "翻訳して", "翻訳する", "翻訳してください", "번역", "번역해", "번역하세요", "번역해주세요",
        "traducir", "traduce", "traduzca", "traduire", "traduisez", "traduis", "übersetzen", "übersetze", "traduzir", "traduza",
    ]

    nonisolated static func cleanTranslation(_ reply: String, target: String) -> String? {
        let opener = ["here is", "here's", "the subtitle", "this subtitle", "the text", "this text", "the original",
                      "the user", "note", "(note", "i'm sorry", "i am sorry", "sorry", "it seems", "it appears", "this appears"]
        let about = ["translat", "subtitle", "garbled", "transcri", "asr", "speech recognition", "best-effort"]
        let zhAbout = ["字幕", "翻译"], zhRemark = ["请提供", "似乎", "看起来", "无法", "乱码", "没有附上", "您只发送"]
        let answer = reply.components(separatedBy: "</think>").last ?? reply
        var kept: [String] = []
        for raw in answer.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lower = line.lowercased()
            let remark = (opener.contains(where: { lower.hasPrefix($0) }) || line.hasSuffix(":") || line.hasSuffix("："))
                && about.contains(where: { lower.contains($0) })
                || zhAbout.contains(where: { line.contains($0) }) && zhRemark.contains(where: { line.contains($0) })
            if lower.hasPrefix("translation:") {
                line = String(line.dropFirst("translation:".count)).trimmingCharacters(in: .whitespaces)
            } else if remark {
                if !kept.isEmpty { break }
                continue
            }
            if !line.isEmpty { kept.append(line) }
        }
        var out = kept.joined(separator: " ")
        for (open, close) in [("\"", "\""), ("“", "”"), ("「", "」")]
        where out.count >= 2 && out.hasPrefix(open) && out.hasSuffix(close) && out.dropFirst().dropLast().contains(open) == false {
            out = String(out.dropFirst().dropLast())
        }
        out = out.trimmingCharacters(in: .whitespaces)
        guard !out.isEmpty else { return nil }
        if Self.instructionEchoes.contains(String(out.lowercased().unicodeScalars.filter { $0.properties.isAlphabetic })) { return nil }
        let letters = out.unicodeScalars.filter { $0.properties.isAlphabetic }
        let cjk = letters.filter { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }.count
        let wantsCJK = ["zh", "ja", "ko"].contains(where: { target.hasPrefix($0) })
        if !letters.isEmpty, wantsCJK ? cjk == 0 : cjk * 2 > letters.count { return nil }
        return out
    }

    private func viaApple(_ text: String, source: String, target: String) async -> String? {
        guard #available(macOS 26, *) else { return nil }
        guard source != "auto" else { return nil }
        let from = Locale.Language(identifier: Self.appleCode(source))
        let to = Locale.Language(identifier: Self.appleCode(target))
        guard await LanguageAvailability().status(from: from, to: to) == .installed else { return nil }
        do {
            let session = TranslationSession(installedSource: from, target: to)
            return try await session.translate(text).targetText
        } catch {
            debugLog("translate apple failed: \(error)")
            return nil
        }
    }

    private static func appleCode(_ code: String) -> String {
        switch code {
        case "zh-CN": "zh-Hans"
        case "zh-TW": "zh-Hant"
        default: code
        }
    }

    nonisolated static func namesLine(_ names: [String]) -> String {
        "\nNames the notes guessed (spellings to use; a misheard form only where it plainly means that name): " + names.joined(separator: "; ")
    }

    nonisolated static func englishName(_ code: String) -> String {
        switch code {
        case "zh-CN": "Simplified Chinese"
        case "zh-TW": "Traditional Chinese"
        default: Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        }
    }
}
