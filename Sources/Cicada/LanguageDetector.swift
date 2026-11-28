import AVFoundation

// MARK: - Spoken language detection

enum LanguageDetector {
    struct Candidate {
        let lang: Lang
        let confidence: Double
        let chars: Int
        let text: String
        let score: Double
    }

    static func rank(_ clip: [AVAudioPCMBuffer], candidates: [Lang]) async -> [Candidate] {
        await withTaskGroup(of: Candidate?.self) { group in
            for lang in candidates {
                group.addTask { await evaluate(clip, lang: lang) }
            }
            var out: [Candidate] = []
            for await c in group { if let c { out.append(c) } }
            return out.sorted { $0.score > $1.score }
        }
    }

    private static func evaluate(_ clip: [AVAudioPCMBuffer], lang: Lang) async -> Candidate? {
        guard let heard = await Recognition.transcribe(clip, locale: lang.locale) else { return nil }
        return Candidate(lang: lang, confidence: heard.confidence, chars: heard.letters, text: heard.text,
                         score: score(conf: heard.confidence, chars: heard.letters, text: heard.text, lang: lang))
    }

    static func saysNothing(_ ranked: [Candidate]) -> Bool {
        ranked.count >= 2 && ranked.allSatisfy { $0.chars <= 3 }
    }

    static func score(conf: Double, chars: Int, text: String, lang: Lang) -> Double {
        guard chars > 0 else { return 0 }
        let lengthFactor = min(1.0, Double(chars) / 6.0)
        var scriptFactor = 1.0
        if ["ja", "zh-CN", "ko"].contains(lang.code) {
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            let latin = letters.filter { $0.isASCII }.count
            if !letters.isEmpty, Double(latin) / Double(letters.count) > 0.5 { scriptFactor = 0.75 }
        }
        return conf * lengthFactor * scriptFactor
    }
}


// MARK: - What detection has settled

struct LanguageDetection {
    enum Verdict: Equatable {
        case unknown
        case notThis
        case confirmed
    }

    enum Decision: Equatable {
        case none
        case notThis(Lang, firstTime: Bool)
        case noneOfThem(now: Bool)
        case ambiguous
        case confirmed(Lang)
        case switchTo(Lang, replayAll: Bool)
        case pending(Lang)
    }

    private(set) var verdict = Verdict.unknown
    private(set) var pendingSwitch: Lang?
    var due = true
    private(set) var checking = false
    private(set) var lastCheckAt = Date.distantPast
    var nextPeriodic = 30.0
    private(set) var ambiguous = 0
    private var unsureStreak = 0
    private var sureStreak = 0

    var confirmed: Bool { verdict == .confirmed }
    var mismatch: Bool { verdict == .notThis }
    var settledEnough: Bool { confirmed || (ambiguous >= 2 && !mismatch) }

    mutating func start() { self = LanguageDetection() }

    mutating func modeChanged() {
        verdict = .unknown
        pendingSwitch = nil
        due = true
    }

    mutating func redetect() {
        if verdict == .confirmed { verdict = .unknown }
        pendingSwitch = nil
        due = true
        ambiguous = 0
        unsureStreak = 0
        sureStreak = 0
        lastCheckAt = .distantPast
    }

    mutating func modelFetched(ok: Bool) {
        if ok { clearMismatch(); unsureStreak = 0; sureStreak = 0 }
        due = true
    }

    mutating func clearMismatch() { if verdict == .notThis { verdict = .unknown } }

    mutating func unconfirm() { if verdict == .confirmed { verdict = .unknown } }

    mutating func setConfirmed(_ on: Bool) { if on { verdict = .confirmed } else { unconfirm() } }

    mutating func picked() {
        verdict = .confirmed
        pendingSwitch = nil
        due = false
        unsureStreak = 0
        sureStreak = 0
    }

    mutating func checkStarted(at now: Date = Date()) {
        due = false
        lastCheckAt = now
        checking = true
    }

    mutating func checkEnded() { checking = false }

    mutating func apply(_ ranked: [LanguageDetector.Candidate], active: Lang?) -> Decision {
        guard let best = ranked.first else { return .none }
        if LanguageDetector.saysNothing(ranked) {
            if !confirmed || mismatch { due = true }
            return .none
        }
        if ranked.count == 1 {
            guard best.lang == active, best.confidence >= 0.6, best.score >= 0.6 else {
                if confirmed { return .none }
                let first = !mismatch
                verdict = .notThis
                return .notThis(best.lang, firstTime: first)
            }
            clearMismatch()
        }
        if ranked.count >= 2, best.score < 0.72 {
            unsureStreak += 1
            sureStreak = 0
            var now = false
            if unsureStreak >= 2, verdict == .unknown {
                verdict = .notThis
                now = true
            }
            if !confirmed { due = true }
            return .noneOfThem(now: now)
        }
        unsureStreak = 0
        if mismatch, ranked.count >= 2 {
            sureStreak += 1
            if sureStreak < 2 {
                due = true
                return .none
            }
        }
        let runnerUp = ranked.dropFirst().first?.score ?? 0
        guard best.confidence >= 0.6, best.score - runnerUp >= 0.08 else {
            ambiguous += 1
            if !confirmed { due = true }
            return .ambiguous
        }
        if best.lang == active {
            verdict = .confirmed
            pendingSwitch = nil
            return .confirmed(best.lang)
        }
        let currentScore = ranked.first(where: { $0.lang == active })?.score ?? 0
        let overwhelming = best.score - currentScore >= 0.30
        if !confirmed || overwhelming || pendingSwitch == best.lang {
            let replayAll = !confirmed
            verdict = .confirmed
            pendingSwitch = nil
            return .switchTo(best.lang, replayAll: replayAll)
        }
        pendingSwitch = best.lang
        due = true
        return .pending(best.lang)
    }
}
