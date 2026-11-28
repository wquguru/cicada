import Combine
import Foundation

// MARK: - Records

struct TranslateAttempt: Codable {
    let provider: String
    let seconds: Double
    let failure: String?
}

@MainActor
final class TranslateTrace {
    var attempts: [TranslateAttempt] = []
    var lingQueue: Double = 0
    var failedSeconds: Double { attempts.filter { $0.failure != nil }.reduce(0) { $0 + $1.seconds } }
    var via: String { attempts.first(where: { $0.failure == nil })?.provider ?? "none" }
    var fallbacks: [String] { attempts.compactMap { a in a.failure.map { "\(a.provider):\($0)" } } }
}

struct SentenceTiming: Codable, Identifiable {
    var id = UUID()
    let at: Date
    let side: String
    let chars: Int
    let recognize: Double?
    let queue: Double
    let translate: Double
    let voice: Double?
    let failed: Double
    let via: String
    let fallbacks: [String]
    var firstAudio: Double? = nil
    var total: Double { (recognize ?? 0) + translate }
}

struct AICall: Codable {
    let at: Date
    let provider: String
    let model: String
    let role: String
    let priority: String
    let queue: Double
    let seconds: Double
    let outcome: String
    let promptTokens: Int
    let completionTokens: Int
    var chars = 0
    var firstAudio: Double?
}

// MARK: - Recorder

@MainActor
final class Diagnostics: ObservableObject {
    @Published private(set) var sentences: [SentenceTiming] = []
    @Published private(set) var calls: [AICall] = []
    @Published private(set) var drafts = Drafts()
    @Published private(set) var startedAt: Date?
    @Published private(set) var endedAt: Date?

    var enabled: () -> Bool = { false }
    var folder: () -> URL? = { nil }

    func begin() {
        sentences = []
        calls = []
        drafts = Drafts()
        startedAt = Date()
        endedAt = nil
    }

    func end() { if startedAt != nil, endedAt == nil { endedAt = Date() } }

    func record(_ s: SentenceTiming) {
        guard enabled() else { return }
        sentences.append(s)
        if sentences.count > 500 { sentences.removeFirst(sentences.count - 500) }
        write("sentence", s)
        debugLog(String(format: "diag: %@ recognize=%@ translate=%.2f queue=%.2f via=%@%@", s.side,
                        s.recognize.map { String(format: "%.2f", $0) } ?? "-", s.translate, s.queue, s.via,
                        s.fallbacks.isEmpty ? "" : " fallbacks=" + s.fallbacks.joined(separator: ",")))
    }

    func record(_ c: AICall) {
        guard enabled() else { return }
        calls.append(c)
        if calls.count > 1000 { calls.removeFirst(calls.count - 1000) }
        write("call", c)
    }

    struct Drafts: Equatable {
        var n = 0
        var failed = 0
        var seconds: [Double] = []
    }

    func recordDraft(seconds: Double, ok: Bool) {
        guard enabled() else { return }
        drafts.n += 1
        if ok {
            drafts.seconds.append(seconds)
            if drafts.seconds.count > 2000 { drafts.seconds.removeFirst(drafts.seconds.count - 2000) }
        } else {
            drafts.failed += 1
        }
    }

    private func write<T: Encodable>(_ type: String, _ value: T) {
        guard let dir = folder() else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(value), var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        obj["type"] = type
        obj.removeValue(forKey: "id")
        guard var line = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let url = dir.appendingPathComponent("metrics.jsonl")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    // MARK: Summary

    struct Stat { let p50: Double; let p95: Double; let n: Int }

    static func stat(_ xs: [Double]) -> Stat? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let pick = { (q: Double) in s[min(s.count - 1, Int((q * Double(s.count - 1)).rounded()))] }
        return Stat(p50: pick(0.5), p95: pick(0.95), n: s.count)
    }

    var heard: [SentenceTiming] { sentences.filter { $0.side == "them" } }
    var said: [SentenceTiming] { sentences.filter { $0.side == "me" } }
    var endToEnd: Stat? { Self.stat(heard.map(\.total)) }
    var recognize: Stat? { Self.stat(heard.compactMap(\.recognize)) }
    var translate: Stat? { Self.stat(heard.map(\.translate)) }
    var speakBack: Stat? { Self.stat(said.map { ($0.recognize ?? 0) + $0.translate }) }
    var notesRounds: Stat? { Self.stat(calls.filter { $0.role == "notes" && $0.outcome == "ok" }.map(\.seconds)) }
    var toRoom: Stat? { Self.stat(said.compactMap { s in s.firstAudio.map { (s.recognize ?? 0) + s.translate + $0 } }) }
    var recognizeMine: Stat? { Self.stat(said.filter { $0.via != "ming" }.compactMap(\.recognize)) }
    var draftStat: Stat? { Self.stat(drafts.seconds) }

    struct Use: Identifiable {
        let role: String
        let provider: String
        let model: String
        var id: String { "\(role)|\(provider)|\(model)" }
        let n: Int
        let failed: Int
        let latency: Stat?
        let tokens: Int
        let chars: Int
        let reasons: [(String, Int)]
    }

    static let roles = ["translate", "heard-me", "voice", "notes", "speakers"]

    var uses: [Use] {
        Dictionary(grouping: calls.filter { Self.roles.contains($0.role) }) { "\($0.role)|\($0.provider)|\($0.model)" }
            .values.compactMap { xs -> Use? in
                guard let c = xs.first else { return nil }
                let ok = xs.filter { $0.outcome == "ok" }
                let failed = xs.filter { $0.outcome != "ok" && $0.outcome != "cancelled" }
                var reasons: [String: Int] = [:]
                for f in failed { reasons[f.outcome, default: 0] += 1 }
                return Use(role: c.role, provider: c.provider, model: c.model, n: xs.count, failed: failed.count,
                           latency: Self.stat(c.role == "voice" ? ok.compactMap(\.firstAudio) : ok.map(\.seconds)),
                           tokens: xs.reduce(0) { $0 + $1.promptTokens + $1.completionTokens },
                           chars: xs.reduce(0) { $0 + $1.chars },
                           reasons: reasons.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, $0.value) })
            }
            .sorted { a, b in
                let (i, j) = (Self.roles.firstIndex(of: a.role) ?? 99, Self.roles.firstIndex(of: b.role) ?? 99)
                return i != j ? i < j : a.n != b.n ? a.n > b.n : (a.provider, a.model) < (b.provider, b.model)
            }
    }

    var retreats: [(String, Int)] {
        let services = Set(AIProvider.all.map(\.id.rawValue))
        let xs = sentences.filter { s in s.fallbacks.contains { services.contains(String($0.split(separator: ":").first ?? "")) } }
        return Dictionary(grouping: xs, by: \.via).map { ($0.key, $0.value.count) }.sorted { ($0.1, $1.0) > ($1.1, $0.0) }
    }
    var voiceChars: Int { calls.filter { $0.role == "voice" }.reduce(0) { $0 + $1.chars } }

    var viaCounts: [(String, Int, Double)] {
        Dictionary(grouping: sentences, by: \.via).map { via, xs in
            (via, xs.count, Self.stat(xs.map(\.translate))?.p50 ?? 0)
        }.sorted { ($0.1, $1.0) > ($1.1, $0.0) }
    }

    var fallbackCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for s in sentences { for f in s.fallbacks { counts[f, default: 0] += 1 } }
        for c in calls where c.outcome == "rateLimited" && c.role == "notes" { counts["notes:rateLimited", default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, $0.value) }
    }

    var lingRate: Double {
        let since = Date().addingTimeInterval(-10)
        return Double(calls.filter { $0.at > since }.count) / 10
    }
    var maxQueue: Double { calls.map(\.queue).max() ?? 0 }
    var tokens: (Int, Int) { calls.reduce((0, 0)) { ($0.0 + $1.promptTokens, $0.1 + $1.completionTokens) } }

    func report(version: String, service: AIConfig) -> String {
        func f(_ s: Stat?) -> String { s.map { String(format: "p50 %.2fs p95 %.2fs n=%d", $0.p50, $0.p95, $0.n) } ?? "-" }
        var lines = [L("\(appDisplayName) \(version) 诊断  \(Date())"),
                     "AI: \(service.provider.id.rawValue) · \(service.textModel)" + (service.voiceModel.map { " · " + $0 } ?? "")]
        if let startedAt { lines.append(String(format: L("本场 %.0f 分钟"), (endedAt ?? Date()).timeIntervalSince(startedAt) / 60)) }
        lines.append(L("说完到出字幕 ") + f(endToEnd))
        lines.append(L("识别定稿 ") + f(recognize))
        lines.append(L("翻译 ") + f(translate))
        lines.append(L("同声传译（松开到对方听到）") + f(toRoom))
        for u in uses {
            var line = "\(u.role) \(u.provider) \(u.model) \(f(u.latency)) calls=\(u.n) failed=\(u.failed)"
            if !u.reasons.isEmpty { line += " (" + u.reasons.map { "\($0.0) \($0.1)" }.joined(separator: ", ") + ")" }
            if u.tokens > 0 { line += " tokens=\(u.tokens)" }
            if u.chars > 0 { line += " chars=\(u.chars)" }
            lines.append(line)
        }
        if drafts.n > 0 { lines.append("draft google \(f(draftStat)) calls=\(drafts.n) failed=\(drafts.failed)") }
        lines.append(L("翻译来源 ") + viaCounts.map { String(format: "%@ %d (p50 %.2fs)", $0.0, $0.1, $0.2) }.joined(separator: " · "))
        lines.append(L("换后备 ") + (fallbackCounts.isEmpty ? L("无") : fallbackCounts.map { "\($0.0) \($0.1)" }.joined(separator: " · ")))
        let t = tokens
        lines.append(String(format: L("AI 请求 %d 次 · 排队最久 %.2fs · token %d/%d"), calls.count, maxQueue, t.0, t.1))
        return lines.joined(separator: "\n")
    }
}
