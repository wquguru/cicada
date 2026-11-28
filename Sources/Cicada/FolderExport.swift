#if os(macOS)
import AppKit
#endif
import Foundation
import UserNotifications

@MainActor protocol FolderExportPrefs: AnyObject {
    var exportOn: Bool { get set }
    var exportFolder: String { get set }
    var exportFolderURL: URL? { get }
}

extension FolderExportPrefs {
    var exportFolderURL: URL? { exportFolder.isEmpty ? nil : URL(fileURLWithPath: exportFolder, isDirectory: true) }
}

enum FolderExportFormat {
    static func name(_ s: Session) -> String {
        if s.renamed ?? !s.title.hasPrefix("会议 ") { return s.title }
        if let t = s.notes?.title, !t.isEmpty { return t }
        if let file = s.sourceFile { return (file as NSString).deletingPathExtension }
        return ""
    }

    static func safeName(_ name: String) -> String {
        let banned = Set("/\\:*?\"<>|#^[]".unicodeScalars)
        let spaced = String(String.UnicodeScalarView(name.unicodeScalars.map { banned.contains($0) || $0.value < 0x20 ? " " : $0 }))
        var out = trim(spaced.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        if out.utf8.count > 120 {
            var cut = String.UnicodeScalarView()
            var bytes = 0
            for u in out.unicodeScalars {
                bytes += String(u).utf8.count
                if bytes > 120 { break }
                cut.append(u)
            }
            out = trim(String(cut))
        }
        return out
    }

    private static func trim(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        while let f = scalars.first, f == " " || f == "." { scalars.removeFirst() }
        while let l = scalars.last, l == " " || l == "." { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    static func stem(_ s: Session, timeZone: TimeZone = .current) -> String {
        let date = format(s.startedAt, "yyyy-MM-dd HHmm", timeZone)
        let safe = safeName(name(s))
        return safe.isEmpty ? date : "\(date) \(safe)"
    }

    static func fileName(_ stem: String, taken: (String) -> Bool) -> String {
        var n = 1
        while true {
            let name = n == 1 ? "\(stem).md" : "\(stem) \(n).md"
            if !taken(name) { return name }
            n += 1
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    static func frontmatter(_ s: Session, timeZone: TimeZone = .current) -> String {
        let ended = s.endedAt ?? s.startedAt
        let languages = Set(s.lines.map(\.srcLang)).sorted { Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }
        let notes = s.notes.map { $0.isEmpty ? "none" : $0.final ? "final" : "draft" } ?? "none"
        return """
        ---
        cicada: 1
        id: \(quote(s.id))
        title: \(quote(name(s)))
        started: \(quote(format(s.startedAt, "yyyy-MM-dd'T'HH:mm:ssxxx", timeZone)))
        ended: \(quote(format(ended, "yyyy-MM-dd'T'HH:mm:ssxxx", timeZone)))
        minutes: \(max(0, Int(ended.timeIntervalSince(s.startedAt) / 60)))
        languages: [\(languages.map(quote).joined(separator: ", "))]
        source: \(quote(s.sourceFile == nil ? "meeting" : "file"))
        notes: \(quote(notes))
        tags: ["cicada"]
        ---

        """
    }

    static func document(_ s: Session) -> String { frontmatter(s) + TranscriptExport.markdown(s) }

    private static func format(_ date: Date, _ pattern: String, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.dateFormat = pattern
        return f.string(from: date)
    }

    static func obsidianVaults(_ json: Data, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [URL] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let vaults = root["vaults"] as? [String: [String: Any]] else { return [] }
        return vaults.values
            .compactMap { v -> (String, Double)? in
                guard let path = v["path"] as? String, exists(path) else { return nil }
                return (path, (v["ts"] as? NSNumber)?.doubleValue ?? 0)
            }
            .sorted { $0.1 > $1.1 }
            .map { URL(fileURLWithPath: $0.0, isDirectory: true) }
    }

    #if os(macOS)
    static var obsidianVaults: [URL] {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        return (try? Data(contentsOf: file)).map { obsidianVaults($0) } ?? []
    }
    #endif
}

@MainActor final class FolderExporter: ObservableObject {
    enum Problem: Equatable {
        case denied
        case missing
        case failed(String)
    }

    struct Index: Codable, Equatable {
        var folder: String = ""
        var files: [String: String] = [:]
        var pending: [String] = []
        var lastFile: String? = nil
        var lastAt: Date? = nil
    }

    @Published private(set) var index = Index()
    @Published private(set) var problem: Problem?
    @Published private(set) var checking = false

    let store: SessionStore
    let settings: any FolderExportPrefs
    var settling: (String) -> Bool = { _ in false }
    private let indexURL: URL
    private let queue = DispatchQueue(label: "cicada.folder-export")
    private var scheduled: DispatchWorkItem?
    private var notified = false

    init(store: SessionStore, settings: any FolderExportPrefs, indexURL: URL? = nil) {
        self.store = store
        self.settings = settings
        self.indexURL = indexURL ?? store.root.deletingLastPathComponent().appendingPathComponent("FolderExport.json")
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: self.indexURL), let i = try? d.decode(Index.self, from: data) { index = i }
    }

    var on: Bool { settings.exportOn && !settings.exportFolder.isEmpty }
    var folder: URL? { settings.exportFolder.isEmpty ? nil : settings.exportFolderURL }

    func file(for id: String) -> URL? {
        guard on, let folder, index.folder == settings.exportFolder, let name = index.files[id] else { return nil }
        return folder.appendingPathComponent(name)
    }

    func isPending(_ id: String) -> Bool { on && index.pending.contains(id) }

    func ready(_ s: Session) -> Bool { s.endedAt != nil && s.importing != true && !s.lines.isEmpty && s.id != store.liveID }

    var unwritten: [Session] {
        store.sessions.filter { ready($0) && index.files[$0.id] == nil && !index.pending.contains($0.id) }
    }

    static func shortPath(_ url: URL) -> String {
        let fm = FileManager.default
        return [url.deletingLastPathComponent().path, url.path].map { fm.displayName(atPath: $0) }.joined(separator: " › ")
    }

    #if os(macOS)
    static func vault(of url: URL) -> URL? {
        FolderExportFormat.obsidianVaults.first { url.path == $0.path || url.path.hasPrefix($0.path + "/") }
    }
    #endif

    // MARK: Triggers

    func ended(_ id: String) {
        guard on else { return }
        if !index.pending.contains(id) { index.pending.append(id) }
        saveIndex()
        schedule()
    }

    func saved(_ id: String) {
        guard on, index.files[id] != nil || index.pending.contains(id) else { return }
        if !index.pending.contains(id) { index.pending.append(id) }
        schedule()
    }

    func settled(_ id: String) { if on, index.pending.contains(id) { schedule() } }

    func writeAll() {
        guard on else { return }
        index.pending += unwritten.map(\.id)
        saveIndex()
        flush(fromMeeting: false)
    }

    func retry() {
        guard on, !index.pending.isEmpty else { return }
        schedule(after: 0.5, fromMeeting: false)
    }

    func deleted(_ id: String) {
        index.files[id] = nil
        index.pending.removeAll { $0 == id }
        saveIndex()
    }

    // MARK: Choosing the folder

    func choose(_ url: URL) {
        settings.exportFolder = url.path
        settings.exportOn = true
        if index.folder != url.path { index = Index(folder: url.path) }
        saveIndex()
        checking = true
        problem = nil
        queue.async {
            let result = Self.probe(url)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.checking = false
                self.problem = result
                if result == nil { self.notified = false; self.retry() }
                debugLog("folder export: \(url.path) → \(result.map { "\($0)" } ?? "ok")")
            } }
        }
    }

    func turnOff() {
        settings.exportOn = false
        problem = nil
    }

    // MARK: Writing

    private func schedule(after delay: Double = 2, fromMeeting: Bool = true) {
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush(fromMeeting: fromMeeting) }
        }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    struct Job: Sendable {
        let id: String
        let stem: String
        let old: String?
        let text: String
    }

    enum Outcome: Sendable, Equatable {
        case wrote(id: String, name: String)
        case unchanged(id: String)
        case stopped(Problem)
    }

    private func flush(fromMeeting: Bool) {
        guard on, let folder else { return }
        if index.folder != folder.path { index = Index(folder: folder.path, pending: index.pending) }
        var jobs: [Job] = []
        for id in index.pending {
            guard let s = store.session(id) else { index.pending.removeAll { $0 == id }; continue }
            guard ready(s), !settling(id) else { continue }
            jobs.append(Job(id: id, stem: FolderExportFormat.stem(s), old: index.files[id], text: FolderExportFormat.document(s)))
        }
        saveIndex()
        guard !jobs.isEmpty else { return }
        let ours = index.files
        queue.async {
            let outcomes = Self.write(jobs, to: folder, ours: ours)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(outcomes, folder: folder.path, fromMeeting: fromMeeting) } }
        }
    }

    private func apply(_ outcomes: [Outcome], folder: String, fromMeeting: Bool) {
        guard index.folder == folder else { return }
        var stopped: Problem?
        for o in outcomes {
            switch o {
            case .wrote(let id, let name):
                index.files[id] = name
                index.pending.removeAll { $0 == id }
                index.lastFile = name
                index.lastAt = Date()
            case .unchanged(let id):
                index.pending.removeAll { $0 == id }
            case .stopped(let p):
                stopped = p
            }
        }
        saveIndex()
        problem = stopped
        if stopped == nil { notified = false }
        if stopped == .denied, fromMeeting, !notified {
            notified = true
            notifyDenied()
        }
    }

    nonisolated static func write(_ jobs: [Job], to folder: URL, ours: [String: String]) -> [Outcome] {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        if let p = ensure(folder) { return [.stopped(p)] }
        let fm = FileManager.default
        var ours = ours
        var out: [Outcome] = []
        for job in jobs {
            let mine = Set(ours.filter { $0.key != job.id }.values)
            let name = FolderExportFormat.fileName(job.stem) { candidate in
                if candidate == job.old { return false }
                return mine.contains(candidate) || fm.fileExists(atPath: folder.appendingPathComponent(candidate).path)
            }
            let url = folder.appendingPathComponent(name)
            if name == job.old, let now = try? String(contentsOf: url, encoding: .utf8), now == job.text {
                out.append(.unchanged(id: job.id))
                continue
            }
            do {
                try Data(job.text.utf8).write(to: url, options: .atomic)
            } catch {
                out.append(.stopped(classify(error, folder)))
                return out
            }
            if let old = job.old, old != name { try? fm.removeItem(at: folder.appendingPathComponent(old)) }
            ours[job.id] = name
            out.append(.wrote(id: job.id, name: name))
        }
        return out
    }

    nonisolated private static func ensure(_ folder: URL) -> Problem? {
        var st = stat()
        if stat(folder.path, &st) == 0 { return (st.st_mode & S_IFMT) == S_IFDIR ? nil : .missing }
        if errno == EPERM || errno == EACCES { return .denied }
        if stat(folder.deletingLastPathComponent().path, &st) != 0 { return errno == EPERM || errno == EACCES ? .denied : .missing }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) } catch { return classify(error, folder) }
        return nil
    }

    nonisolated static func probe(_ folder: URL) -> Problem? {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        if let p = ensure(folder) { return p }
        let file = folder.appendingPathComponent(".cicada-check")
        do {
            try Data().write(to: file)
            try? FileManager.default.removeItem(at: file)
            return nil
        } catch {
            return classify(error, folder)
        }
    }

    nonisolated private static func classify(_ error: Error, _ folder: URL) -> Problem {
        let ns = error as NSError
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
        if ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError
            || posix == Int(EPERM) || posix == Int(EACCES) { return .denied }
        var st = stat()
        if stat(folder.path, &st) != 0 { return errno == EPERM || errno == EACCES ? .denied : .missing }
        return .failed(ns.localizedDescription)
    }

    private func saveIndex() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func notifyDenied() {
        guard let folder else { return }
        let title = L("纪要没存到文件夹"), body = L("知了没有权限写入 \(Self.shortPath(folder))。点按去设置")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = ["problem": "folder"]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "problem-folder", content: content, trigger: nil)) { error in
                debugLog(error.map { "folder export: notification not shown: \($0)" } ?? "folder export: notified denied")
            }
        }
    }

    #if os(macOS)
    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }
    #endif
}
