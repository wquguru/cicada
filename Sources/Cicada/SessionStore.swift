#if os(macOS)
import AppKit
#endif
import Foundation

struct TranscriptLine: Codable, Identifiable, Equatable {
    var id: String
    var t: Double
    var speaker: String
    var src: String
    var dst: String?
    var srcLang: String
    var dstLang: String
    var voice: Int? = nil
    var via: String? = nil
    var fixes: [LineFix]? = nil
}

struct VoiceGuess: Codable, Equatable {
    var name: String
    var evidence: String
}

struct Session: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var lines: [TranscriptLine]
    var hasAudio: Bool
    var notes: MeetingNotes?
    var renamed: Bool?
    var voiceNames: [String: String]? = nil
    var voiceGuesses: [String: VoiceGuess]? = nil
    var voiceProfiles: [String: VoiceProfileRef]? = nil
    var voiceSuggestions: [String: VoiceProfileRef]? = nil
    var sourceFile: String? = nil
    var sourcePath: String? = nil
    var importing: Bool? = nil
    var fromRecording: Bool { sourceFile == nil && sourcePath != nil }
    var room: Bool? = nil

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    var displayTitle: String {
        if renamed ?? !title.hasPrefix("会议 ") { return title }
        guard let name = notes?.title, !name.isEmpty else {
            if let file = sourceFile { return (file as NSString).deletingPathExtension }
            return L("会议 \(dateText(startedAt, "MMMdHHmm"))")
        }
        let thisYear = Calendar.current.isDate(startedAt, equalTo: Date(), toGranularity: .year)
        return "\(dateText(startedAt, thisYear ? "MMMd" : "yMMMd")) \(name)"
    }

    static func defaultTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return "会议 \(f.string(from: date))"
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var liveID: String?
    @Published private(set) var audioFinished: String?

    let root: URL
    private var saveWork: [String: DispatchWorkItem] = [:]
    var onSave: ((String) -> Void)?

    init(root: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? base.appendingPathComponent("\(DevBuild.supportFolder)/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        load()
    }

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func systemAudioURL(_ id: String) -> URL { folder(id).appendingPathComponent("system.m4a") }
    func micAudioURL(_ id: String) -> URL { folder(id).appendingPathComponent("mic.m4a") }
    func roomAudioURL(_ id: String) -> URL { folder(id).appendingPathComponent("room.m4a") }
    private func audioURLs(_ id: String) -> [URL] { [systemAudioURL(id), micAudioURL(id), roomAudioURL(id)] }

    private func load() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [Session] = []
        for dir in dirs {
            if let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
               var s = try? decoder.decode(Session.self, from: data) {
                if s.endedAt == nil { s.endedAt = s.lines.last.map { s.startedAt.addingTimeInterval($0.t + 5) } ?? s.startedAt }
                if s.id != liveID, hasPartialAudio(s.id) {
                    s.hasAudio = true
                    finishAudio(s.id)
                }
                out.append(s)
            }
        }
        sessions = out.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: Live session

    @discardableResult
    func begin() -> Session {
        let now = Date()
        let fid = DateFormatter()
        fid.dateFormat = "yyyyMMdd-HHmmss"
        let s = Session(id: fid.string(from: now), title: Session.defaultTitle(now),
                        startedAt: now, endedAt: nil, lines: [], hasAudio: false)
        sessions.insert(s, at: 0)
        liveID = s.id
        try? FileManager.default.createDirectory(at: folder(s.id), withIntermediateDirectories: true)
        return s
    }

    func end(at: Date? = nil, heardSpeech: Bool = false) {
        guard let id = liveID, let i = index(id) else { liveID = nil; return }
        let now = Date()
        sessions[i].endedAt = at.map { min(now, max(sessions[i].startedAt, $0)) } ?? now
        liveID = nil
        sessions[i].hasAudio = audioURLs(id).contains {
            FileManager.default.fileExists(atPath: $0.path) || FileManager.default.fileExists(atPath: AudioFileWriter.partial($0).path)
        }
        if sessions[i].lines.isEmpty {
            guard heardSpeech, sessions[i].hasAudio else {
                try? FileManager.default.removeItem(at: folder(id))
                sessions.remove(at: i)
                return
            }
            let system = systemAudioURL(id), room = roomAudioURL(id)
            let heard = [system, AudioFileWriter.partial(system), room, AudioFileWriter.partial(room)]
                .contains { FileManager.default.fileExists(atPath: $0.path) }
            sessions[i].sourcePath = (heard ? system : micAudioURL(id)).path
        }
        saveNow(id)
        finishAudio(id, until: at == nil ? nil : sessions[i].duration)
    }

    private func hasPartialAudio(_ id: String) -> Bool {
        audioURLs(id).contains { FileManager.default.fileExists(atPath: AudioFileWriter.partial($0).path) }
    }

    func finishAudio(_ id: String, until: Double? = nil) {
        let urls = audioURLs(id), system = systemAudioURL(id), room = roomAudioURL(id)
        Task.detached(priority: .utility) {
            for u in urls { await AudioFileWriter.finish(u, until: until) }
            Self.foldRoom(room, into: system)
            await self.markAudioFinished(id)
        }
    }

    nonisolated private static func foldRoom(_ room: URL, into system: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: room.path), !fm.fileExists(atPath: AudioFileWriter.partial(system).path) else { return }
        if !fm.fileExists(atPath: system.path) {
            try? fm.moveItem(at: room, to: system)
        } else if AudioFileWriter.mix(room, into: system) {
            try? fm.removeItem(at: room)
        }
    }

    private func markAudioFinished(_ id: String) {
        audioFinished = id
    }

    var liveStart: Date? { liveID.flatMap { index($0) }.map { sessions[$0].startedAt } }

    func markLiveInRoom() {
        guard let id = liveID, let i = index(id), sessions[i].room != true else { return }
        sessions[i].room = true
        scheduleSave(id)
    }

    func append(_ line: TranscriptLine) {
        guard let id = liveID, let i = index(id) else { return }
        sessions[i].lines.append(line)
        scheduleSave(id)
    }

    func setTranslation(lineID: String, _ text: String) {
        guard let id = liveID, let i = index(id),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].dst = text
        scheduleSave(id)
    }

    func setSource(lineID: String, _ text: String) {
        guard let id = liveID, let i = index(id),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].src = text
        scheduleSave(id)
    }

    func setSource(in id: String, lineID: String, _ text: String) {
        guard let i = index(id), let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].src = text
        scheduleSave(id)
    }

    func setVoice(lineID: String, _ voice: Int) {
        guard let id = liveID else { return }
        setVoice(in: id, lineID: lineID, voice)
    }

    func setVoice(in id: String, lineID: String, _ voice: Int) {
        guard let i = index(id),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].voice = voice
        scheduleSave(id)
    }

    func setLineVoices(_ id: String, lines ids: Set<String>, _ voice: Int) {
        guard let i = index(id) else { return }
        for j in sessions[i].lines.indices where ids.contains(sessions[i].lines[j].id) && sessions[i].lines[j].speaker == "them" {
            sessions[i].lines[j].voice = voice
        }
        saveNow(id)
    }

    struct VoiceSnapshot {
        let voices: [String: Int?]
        let names: [String: String]?
        let guesses: [String: VoiceGuess]?
        let profiles: [String: VoiceProfileRef]?
        let suggestions: [String: VoiceProfileRef]?
    }

    func voiceSnapshot(_ id: String) -> VoiceSnapshot? {
        guard let s = session(id) else { return nil }
        var voices: [String: Int?] = [:]
        for l in s.lines { voices[l.id] = .some(l.voice) }
        return VoiceSnapshot(voices: voices, names: s.voiceNames, guesses: s.voiceGuesses,
                             profiles: s.voiceProfiles, suggestions: s.voiceSuggestions)
    }

    func restore(_ id: String, _ snap: VoiceSnapshot) {
        guard let i = index(id) else { return }
        for j in sessions[i].lines.indices {
            if let v = snap.voices[sessions[i].lines[j].id] { sessions[i].lines[j].voice = v }
        }
        sessions[i].voiceNames = snap.names
        sessions[i].voiceGuesses = snap.guesses
        sessions[i].voiceProfiles = snap.profiles
        sessions[i].voiceSuggestions = snap.suggestions
        saveNow(id)
    }

    func setVoiceName(_ id: String, voice: Int, _ name: String?) {
        guard let i = index(id) else { return }
        var names = sessions[i].voiceNames ?? [:]
        names[String(voice)] = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[i].voiceNames = names.isEmpty ? nil : names
        saveNow(id)
    }

    func setVoiceProfile(_ id: String, voice: Int, ref: VoiceProfileRef?) {
        guard let i = index(id) else { return }
        var profiles = sessions[i].voiceProfiles ?? [:]
        profiles[String(voice)] = ref
        sessions[i].voiceProfiles = profiles.isEmpty ? nil : profiles
        if var suggestions = sessions[i].voiceSuggestions {
            suggestions[String(voice)] = nil
            sessions[i].voiceSuggestions = suggestions.isEmpty ? nil : suggestions
        }
        saveNow(id)
    }

    func setVoiceSuggestion(_ id: String, voice: Int, _ ref: VoiceProfileRef?) {
        guard let i = index(id) else { return }
        var suggestions = sessions[i].voiceSuggestions ?? [:]
        suggestions[String(voice)] = ref
        sessions[i].voiceSuggestions = suggestions.isEmpty ? nil : suggestions
        saveNow(id)
    }

    func setVoiceGuesses(_ id: String, _ guesses: [Int: VoiceGuess], refuted: [Int: String] = [:]) {
        guard let i = index(id), !guesses.isEmpty || !refuted.isEmpty else { return }
        var all = sessions[i].voiceGuesses ?? [:]
        for (v, name) in refuted where guesses[v] == nil && all[String(v)]?.name == name { all[String(v)] = nil }
        for (v, g) in guesses { all[String(v)] = g }
        guard all != sessions[i].voiceGuesses else { return }
        sessions[i].voiceGuesses = all.isEmpty ? nil : all
        saveNow(id)
    }

    func mergeVoice(_ id: String, _ from: Int, into: Int) {
        guard let i = index(id), from != into else { return }
        for j in sessions[i].lines.indices where sessions[i].lines[j].voice == from { sessions[i].lines[j].voice = into }
        if var names = sessions[i].voiceNames, let moved = names.removeValue(forKey: String(from)) {
            if names[String(into)] == nil, !moved.isEmpty { names[String(into)] = moved }
            sessions[i].voiceNames = names.isEmpty ? nil : names
        }
        if var guesses = sessions[i].voiceGuesses, let moved = guesses.removeValue(forKey: String(from)) {
            if guesses[String(into)] == nil { guesses[String(into)] = moved }
            sessions[i].voiceGuesses = guesses.isEmpty ? nil : guesses
        }
        if var profiles = sessions[i].voiceProfiles, let moved = profiles.removeValue(forKey: String(from)) {
            if profiles[String(into)] == nil { profiles[String(into)] = moved }
            sessions[i].voiceProfiles = profiles.isEmpty ? nil : profiles
        }
        if var suggestions = sessions[i].voiceSuggestions {
            suggestions[String(from)] = nil
            sessions[i].voiceSuggestions = suggestions.isEmpty ? nil : suggestions
        }
        saveNow(id)
    }

    func setNotes(_ id: String, _ notes: MeetingNotes) {
        guard let i = index(id) else { return }
        sessions[i].notes = notes
        id == liveID ? scheduleSave(id) : saveNow(id)
    }

    // MARK: Imported files

    func beginImport(file: URL, recordedAt: Date, duration: Double) -> Session {
        let fid = DateFormatter()
        fid.dateFormat = "yyyyMMdd-HHmmss"
        let id = "import-\(fid.string(from: Date()))-\(UUID().uuidString.prefix(4).lowercased())"
        var s = Session(id: id, title: Session.defaultTitle(recordedAt), startedAt: recordedAt,
                        endedAt: recordedAt.addingTimeInterval(max(1, duration)), lines: [], hasAudio: false)
        s.sourceFile = file.lastPathComponent
        s.sourcePath = file.path
        s.importing = true
        sessions.append(s)
        sessions.sort { $0.startedAt > $1.startedAt }
        saveNow(id)
        return s
    }

    func restartImport(_ id: String) {
        guard let i = index(id) else { return }
        sessions[i].lines = []
        sessions[i].notes = nil
        sessions[i].voiceNames = nil
        sessions[i].voiceGuesses = nil
        sessions[i].voiceProfiles = nil
        sessions[i].voiceSuggestions = nil
        sessions[i].importing = true
        saveNow(id)
    }

    @discardableResult
    func backupTranscript(_ id: String) -> URL? {
        guard let i = index(id), !sessions[i].lines.isEmpty || sessions[i].notes != nil else { return nil }
        saveNow(id)
        let dir = folder(id)
        let src = dir.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dst = dir.appendingPathComponent("session.before-retranscribe-\(stamp).json")
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            return dst
        } catch {
            debugLog("backup transcript failed: \(error)")
            return nil
        }
    }

    func append(_ line: TranscriptLine, to id: String) {
        guard let i = index(id) else { return }
        sessions[i].lines.append(line)
        scheduleSave(id)
    }

    func setFixes(in id: String, lineID: String, _ fixes: [LineFix]) {
        guard let i = index(id), let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        guard sessions[i].lines[j].fixes ?? [] != fixes else { return }
        sessions[i].lines[j].fixes = fixes.isEmpty ? nil : fixes
        scheduleSave(id)
    }

    func lineHeard(as text: String) -> (session: String, line: TranscriptLine)? {
        let ids = ([liveID].compactMap { $0 }) + sessions.filter { $0.importing == true }.map(\.id)
        for id in ids {
            if let s = session(id), let l = s.lines.last(where: { $0.src == text }) { return (id, l) }
        }
        return nil
    }

    func setTranslation(in id: String, lineID: String, _ text: String) {
        guard let i = index(id), let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].dst = text
        scheduleSave(id)
    }

    func finishImport(_ id: String) {
        guard let i = index(id) else { return }
        sessions[i].importing = nil
        saveWork.removeValue(forKey: id)?.cancel()
        saveNow(id)
    }

    // MARK: Editing

    func rename(_ id: String, to title: String) {
        guard let i = index(id) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != sessions[i].displayTitle else { return }
        if t.isEmpty {
            sessions[i].title = Session.defaultTitle(sessions[i].startedAt)
            sessions[i].renamed = false
        } else {
            sessions[i].title = t
            sessions[i].renamed = true
        }
        id == liveID ? scheduleSave(id) : saveNow(id)
    }

    func delete(_ id: String) {
        guard id != liveID, let i = index(id) else { return }
        saveWork.removeValue(forKey: id)?.cancel()
        try? FileManager.default.removeItem(at: folder(id))
        sessions.remove(at: i)
    }

    func session(_ id: String?) -> Session? { id.flatMap { index($0) }.map { sessions[$0] } }

    private func index(_ id: String) -> Int? { sessions.firstIndex(where: { $0.id == id }) }

    private func scheduleSave(_ id: String) {
        guard saveWork[id] == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveWork[id] = nil; self?.saveNow(id) }
        }
        saveWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func saveNow(_ id: String) {
        guard let s = session(id) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(s) else { return }
        try? FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        try? data.write(to: folder(id).appendingPathComponent("session.json"), options: .atomic)
        onSave?(id)
    }
}

// MARK: - Export

enum TranscriptExport {
    static func clock(_ t: Double) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    nonisolated(unsafe) static var voices = false

    static func speakerName(_ line: TranscriptLine, _ numbers: [String: Int] = [:], _ names: [Int: String] = [:]) -> String {
        if line.speaker == "me" { return L("你 · 同传") }
        if let n = numbers[line.id] { return SpeakerLabels.label(n, names) }
        return numbers.isEmpty ? L("对方") : L("未识别")
    }

    static func speakerNumbers(_ s: Session) -> [String: Int] { voices ? SpeakerLabels.numbers(s) : [:] }

    static func saysWho(_ s: Session, _ numbers: [String: Int]) -> Bool { s.sourceFile == nil || !numbers.isEmpty }

    static func header(_ s: Session) -> String {
        let mins = Int(s.duration / 60)
        return "\(dateText(s.startedAt, "yMMMdHHmm")) · " + (mins < 1 ? L("不到 1 分钟") : L("\(mins) 分钟"))
    }

    static func notesMarkdown(_ n: MeetingNotes?) -> String {
        guard let n, !n.isEmpty else { return "" }
        var out = "## \(L("纪要"))\n\n\(n.summary)\n\n"
        for t in n.topics {
            out += "### \(clock(t.start)) \(t.title)\n\n"
            if !t.summary.isEmpty { out += "\(t.summary)\n\n" }
            for p in t.points { out += "- \(p)\n" }
            if let f = t.fishbone {
                out += "\n**\(f.question)**\n\n"
                for b in f.branches { out += "- \(b.label)：\(b.detail)\n" }
            }
            out += "\n"
        }
        if !n.conclusions.isEmpty { out += "### \(L("结论"))\n\n" + n.conclusions.map { "- \($0.text)\n" }.joined() + "\n" }
        if !n.todos.isEmpty {
            out += "### \(L("待办"))\n\n" + n.todos.map { "- [ ] \($0.withOwner)\n" }.joined() + "\n"
        }
        if !n.terms.isEmpty {
            out += "### \(L("人名和术语"))\n\n" + n.terms.map { "- **\($0.name)** \($0.note)\n" }.joined() + "\n"
        }
        return out
    }

    static func markdown(_ s: Session) -> String {
        var out = "# \(s.displayTitle)\n\n\(header(s))\n\n"
        let notes = notesMarkdown(s.notes)
        if !notes.isEmpty { out += notes + "## \(L("文字记录"))\n\n" }
        let numbers = speakerNumbers(s), names = SpeakerLabels.names(s)
        for l in s.lines {
            let who = saysWho(s, numbers) ? " \(speakerName(l, numbers, names))" : ""
            out += "**[\(clock(l.t))]\(who)**  \n\(l.shown)\n"
            if let d = l.dst, d != l.shown { out += "> \(d)\n" }
            out += "\n"
        }
        return out
    }

    static func srt(_ s: Session) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        var out = ""
        for (i, l) in s.lines.enumerated() {
            let next = i + 1 < s.lines.count ? s.lines[i + 1].t : l.t + 4
            let end = max(l.t + 1, min(next, l.t + 8))
            let tag = l.speaker == "me" ? "[\(L("同传"))] " : ""
            out += "\(i + 1)\n\(ts(l.t)) --> \(ts(end))\n\(tag)\(l.shown)\n"
            if let d = l.dst, d != l.shown { out += "\(d)\n" }
            out += "\n"
        }
        return out
    }

    #if os(macOS)
    static func docx(_ s: Session) throws -> Data {
        let doc = NSMutableAttributedString()
        func add(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .black, after: CGFloat = 4) {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = after
            doc.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: p,
            ]))
        }
        add(s.displayTitle, size: 20, weight: .bold, after: 6)
        add(header(s), size: 10, color: .darkGray, after: 14)
        if let n = s.notes, !n.isEmpty {
            add(L("纪要"), size: 15, weight: .bold, after: 6)
            add(n.summary, size: 11, after: 10)
            for t in n.topics {
                add("\(clock(t.start))  \(t.title)", size: 12, weight: .semibold, after: 3)
                if !t.summary.isEmpty { add(t.summary, size: 11, color: .darkGray, after: 3) }
                for p in t.points { add("• \(p)", size: 11, after: 2) }
                if let f = t.fishbone {
                    add(f.question, size: 11, weight: .semibold, after: 2)
                    for b in f.branches { add("  – \(b.label)：\(b.detail)", size: 11, after: 2) }
                }
                add("", size: 6, after: 4)
            }
            if !n.conclusions.isEmpty {
                add(L("结论"), size: 12, weight: .semibold, after: 3)
                for c in n.conclusions { add("• \(c.text)", size: 11, after: 2) }
            }
            if !n.todos.isEmpty {
                add(L("待办"), size: 12, weight: .semibold, after: 3)
                for t in n.todos { add("☐ \(t.withOwner)", size: 11, after: 2) }
            }
            add(L("文字记录"), size: 15, weight: .bold, after: 6)
        }
        let numbers = speakerNumbers(s), names = SpeakerLabels.names(s)
        for l in s.lines {
            add("[\(clock(l.t))]" + (saysWho(s, numbers) ? " \(speakerName(l, numbers, names))" : ""), size: 9, weight: .semibold, color: .darkGray, after: 2)
            add(l.shown, size: 11, after: 2)
            if let d = l.dst, d != l.shown { add(d, size: 11, color: NSColor(calibratedWhite: 0.3, alpha: 1), after: 10) }
        }
        return try doc.data(from: NSRange(location: 0, length: doc.length),
                            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }
    #endif
}
