import Foundation

enum DevBuild {
    static let label: String? = Bundle.main.object(forInfoDictionaryKey: "LiveSubsDev") as? String

    static var isDev: Bool { label != nil }

    static var supportFolder: String { isDev ? "LiveSubs Dev" : "LiveSubs" }

    static var logPath: String {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(isDev ? "livesubs-dev-debug.log" : "livesubs-debug.log").path
    }
}

func debugLog(_ message: String) {
    let line = "\(Date()) \(message)\n"
    let path = DevBuild.logPath
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8) ?? Data())
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

func contentLog(_ message: @autoclosure () -> String) {
    if UserDefaults.standard.bool(forKey: "debug") { debugLog(message()) }
}
