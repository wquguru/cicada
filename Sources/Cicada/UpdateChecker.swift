import AppKit
import Foundation

@MainActor
final class UpdateChecker {
    struct Update: Equatable {
        let version: String
        let url: URL
        let zip: URL?
        let checksums: URL?
        let size: Int
    }

    static let repository = URL(string: "https://github.com/wquguru/cicada")!

    var feed = ProcessInfo.processInfo.environment["CICADA_UPDATE_FEED"].flatMap(URL.init(string:))
        ?? URL(string: "https://api.github.com/repos/wquguru/cicada/releases?per_page=20")!
    private let onUpdate: (Update?) -> Void
    private var timer: Timer?
    private var wakeObserver: Any?
    private var checking = false

    static let every: TimeInterval = 4 * 60 * 60
    static let stale: TimeInterval = 60 * 60

    private(set) var lastChecked = UserDefaults.standard.object(forKey: "updateLastChecked") as? Date {
        didSet { UserDefaults.standard.set(lastChecked, forKey: "updateLastChecked") }
    }

    init(onUpdate: @escaping (Update?) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { await self?.checkIfDue(after: Self.every) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            Task { try? await Task.sleep(for: .seconds(15)); await self?.checkIfDue(after: Self.stale) }
        }
    }

    func checkIfDue(after age: TimeInterval) async {
        guard Self.due(last: lastChecked, now: Date(), after: age) else { return }
        await check()
    }

    nonisolated static func due(last: Date?, now: Date, after age: TimeInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= age || last > now
    }

    @discardableResult
    func check() async -> Bool {
        guard !checking else { return true }
        checking = true
        defer { checking = false }
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 200 == 200,
              let releases = Self.decode(data) else { return false }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let update = Self.newestMac(in: releases)
        lastChecked = Date()
        debugLog("update: checked, latest Mac \(update?.version ?? "none"), running \(current)")
        onUpdate(update.flatMap { Self.isNewer($0.version, than: current) ? $0 : nil })
        return true
    }

    nonisolated static func decode(_ data: Data) -> [Release]? {
        let decoder = JSONDecoder()
        return (try? decoder.decode([Release].self, from: data))
            ?? (try? decoder.decode(Release.self, from: data)).map { [$0] }
    }

    #if arch(x86_64)
    nonisolated static let assetSuffix = "-macOS-Intel.zip"
    #else
    nonisolated static let assetSuffix = "-macOS-AppleSilicon.zip"
    #endif

    nonisolated static func newestMac(in releases: [Release], suffix: String = assetSuffix) -> Update? {
        let shipped = releases.compactMap { release -> Update? in
            guard release.draft != true, release.prerelease != true,
                  let url = URL(string: release.html_url),
                  let zip = release.assets.first(where: { $0.name.hasPrefix("Cicada-") && $0.name.hasSuffix(suffix) })
            else { return nil }
            let checksums = release.assets.first { $0.name == "checksums.txt" }
            return Update(version: release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v")), url: url,
                          zip: URL(string: zip.browser_download_url),
                          checksums: checksums.flatMap { URL(string: $0.browser_download_url) },
                          size: zip.size ?? 0)
        }
        return shipped.max { isNewer($1.version, than: $0.version) }
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let assets: [Asset]
        var draft: Bool? = nil
        var prerelease: Bool? = nil
    }

    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int?
    }
}
