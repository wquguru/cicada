import Foundation

struct SpeakerProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var embedding: [Float]
    var sampleCount: Int
    var createdAt: Date
    var updatedAt: Date
    var lastSeenAt: Date?
    var consentAt: Date?
    var notes: String? = nil
}

struct VoiceProfileRef: Codable, Equatable {
    var id: UUID
    var name: String
    var similarity: Float
}

enum SpeakerMatchKind: Equatable {
    case auto
    case suggested
}

struct SpeakerProfileMatch: Equatable {
    let profile: SpeakerProfile
    let similarity: Float
    let kind: SpeakerMatchKind

    var ref: VoiceProfileRef {
        VoiceProfileRef(id: profile.id, name: profile.name, similarity: similarity)
    }
}

struct SpeakerMatchPolicy: Equatable {
    var auto: Float = 0.70
    var suggested: Float = 0.55
    var margin: Float = 0.08
}

enum SpeakerEmbedding {
    static let dimensions = 256

    static func normalized(_ v: [Float]) -> [Float]? {
        guard v.count == dimensions else { return nil }
        var sum: Float = 0
        for x in v { sum += x * x }
        guard sum.isFinite, sum > 0 else { return nil }
        let scale = sum.squareRoot()
        let out = v.map { $0 / scale }
        return out.allSatisfy(\.isFinite) ? out : nil
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == dimensions, b.count == dimensions else { return nil }
        var dot: Float = 0
        for i in 0..<dimensions { dot += a[i] * b[i] }
        return dot.isFinite ? dot : nil
    }

    static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard !vectors.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: dimensions)
        for v in vectors {
            guard v.count == dimensions else { continue }
            for i in 0..<dimensions { sum[i] += v[i] }
        }
        return normalized(sum)
    }

    static func blended(old: [Float], fresh: [Float], sampleCount: Int) -> [Float]? {
        guard old.count == dimensions, fresh.count == dimensions else { return nil }
        let weight = Float(min(max(1, sampleCount), 20))
        var sum = [Float](repeating: 0, count: dimensions)
        for i in 0..<dimensions { sum[i] = old[i] * weight + fresh[i] }
        return normalized(sum)
    }
}

final class SpeakerProfileStore: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var cached: [SpeakerProfile] = []

    var onChange: (([SpeakerProfile]) -> Void)?

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DevBuild.supportFolder)
            .appendingPathComponent("VoiceProfiles", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    init(url: URL = SpeakerProfileStore.defaultURL) {
        self.url = url
        cached = Self.load(from: url)
        try? Self.protectDirectory(url.deletingLastPathComponent())
        try? Self.protectFile(url)
    }

    func all() -> [SpeakerProfile] {
        lock.lock()
        defer { lock.unlock() }
        return cached.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func snapshot() -> [SpeakerProfile] {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    func match(_ embedding: [Float], policy: SpeakerMatchPolicy = SpeakerMatchPolicy()) -> SpeakerProfileMatch? {
        guard let probe = SpeakerEmbedding.normalized(embedding) else { return nil }
        let profiles = snapshot()
            .filter { $0.embedding.count == SpeakerEmbedding.dimensions && !$0.name.isEmpty }
            .compactMap { p -> (SpeakerProfile, Float)? in
                guard let v = SpeakerEmbedding.normalized(p.embedding),
                      let score = SpeakerEmbedding.cosine(probe, v) else { return nil }
                return (p, score)
            }
            .sorted { $0.1 > $1.1 }
        guard let best = profiles.first, best.1 >= policy.suggested else { return nil }
        let second = profiles.dropFirst().first?.1
        let clear = second == nil || (best.1 - second!) >= policy.margin
        return SpeakerProfileMatch(profile: best.0, similarity: best.1,
                                   kind: best.1 >= policy.auto && clear ? .auto : .suggested)
    }

    @discardableResult
    func remember(name: String, embedding: [Float], at date: Date = Date()) -> SpeakerProfile? {
        let clean = Self.cleanName(name)
        guard !clean.isEmpty, let v = SpeakerEmbedding.normalized(embedding) else { return nil }
        let p = SpeakerProfile(id: UUID(), name: clean, embedding: v, sampleCount: 1,
                               createdAt: date, updatedAt: date, lastSeenAt: nil, consentAt: date)
        mutate { $0.append(p) }
        return p
    }

    @discardableResult
    func updateEmbedding(id: UUID, embedding: [Float], at date: Date = Date()) -> Bool {
        guard let v = SpeakerEmbedding.normalized(embedding) else { return false }
        var updated = false
        mutate { profiles in
            guard let i = profiles.firstIndex(where: { $0.id == id }),
                  let blended = SpeakerEmbedding.blended(old: profiles[i].embedding, fresh: v,
                                                         sampleCount: profiles[i].sampleCount) else { return }
            profiles[i].embedding = blended
            profiles[i].sampleCount += 1
            profiles[i].updatedAt = date
            updated = true
        }
        return updated
    }

    @discardableResult
    func rename(id: UUID, to name: String, at date: Date = Date()) -> Bool {
        let clean = Self.cleanName(name)
        guard !clean.isEmpty else { return false }
        var updated = false
        mutate { profiles in
            guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
            profiles[i].name = clean
            profiles[i].updatedAt = date
            updated = true
        }
        return updated
    }

    @discardableResult
    func setNotes(id: UUID, _ notes: String, at date: Date = Date()) -> Bool {
        var updated = false
        mutate { profiles in
            guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
            let clean = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            profiles[i].notes = clean.isEmpty ? nil : String(clean.prefix(2000))
            profiles[i].updatedAt = date
            updated = true
        }
        return updated
    }

    func delete(id: UUID) {
        mutate { $0.removeAll { $0.id == id } }
    }

    func deleteAll() {
        mutate { $0.removeAll() }
    }

    func markSeen(id: UUID, at date: Date = Date()) {
        let old = snapshot().first { $0.id == id }?.lastSeenAt
        guard old == nil || date.timeIntervalSince(old!) > 60 else { return }
        mutate { profiles in
            guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
            profiles[i].lastSeenAt = date
        }
    }


    private func mutate(_ change: (inout [SpeakerProfile]) -> Void) {
        lock.lock()
        change(&cached)
        let snapshot = cached
        lock.unlock()
        save(snapshot)
        onChange?(snapshot)
    }

    private func save(_ profiles: [SpeakerProfile]) {
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.protectDirectory(dir)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profiles)
            try data.write(to: url, options: .atomic)
            try Self.protectFile(url)
        } catch {
            debugLog("voice profiles: save failed \(error)")
        }
    }

    private static func load(from url: URL) -> [SpeakerProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([SpeakerProfile].self, from: data) else { return [] }
        return decoded.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.embedding.count == SpeakerEmbedding.dimensions
        }
    }

    private static func cleanName(_ name: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(40))
    }

    private static func protectDirectory(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func protectFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
