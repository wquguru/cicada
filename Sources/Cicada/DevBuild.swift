import Foundation

enum DevBuild {
    static let label: String? = {
        if let stamp = Bundle.main.object(forInfoDictionaryKey: "LiveSubsDev") as? String { return stamp }
        return Bundle.main.bundleIdentifier == nil ? "swift run" : nil
    }()

    static var isDev: Bool { label != nil }

    static var supportFolder: String { isDev ? "LiveSubs Dev" : "LiveSubs" }

    static let channel = ProcessInfo.processInfo.environment["CICADA_DEBUG_CHANNEL"].flatMap { $0.isEmpty ? nil : $0 }
    static var debugChannel: String { "com.wquguru.cicada.debug" + (channel.map { "." + $0 } ?? "") }

    static var logPath: String {
        let base = isDev ? "/tmp/livesubs-dev-debug" : "/tmp/livesubs-debug"
        return base + (channel.map { "-" + $0 } ?? "") + ".log"
    }
}
