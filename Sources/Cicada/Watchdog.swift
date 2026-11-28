import Foundation

final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    static let stuckAfter = 2.0

    private let lock = NSLock()
    private var lastPong = Date()
    private var started = false
    private var stalled = false
    private var resumedAt: Date?

    func start() {
        let first = lock.withLock { () -> Bool in defer { started = true }; return !started }
        guard first else { return }
        let thread = Thread { [self] in run() }
        thread.name = "com.wquguru.cicada.watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
        debugLog("watchdog: watching the main thread (stuck after \(Self.stuckAfter) s)")
    }

    private func run() {
        var stuckSince: Date?
        while true {
            Thread.sleep(forTimeInterval: 0.25)
            DispatchQueue.main.async { [self] in
                lock.withLock {
                    if resumedAt == nil, stalled { resumedAt = Date() }
                    lastPong = Date()
                }
            }
            let silent = Date().timeIntervalSince(lock.withLock { lastPong })
            if silent >= Self.stuckAfter, stuckSince == nil {
                stuckSince = Date().addingTimeInterval(-silent)
                lock.withLock { stalled = true; resumedAt = nil }
                sample(silentFor: silent)
            } else if let since = stuckSince, let back = lock.withLock({ resumedAt }) {
                debugLog(String(format: "watchdog: main thread back after %.1f s", back.timeIntervalSince(since)))
                stuckSince = nil
                lock.withLock { stalled = false; resumedAt = nil }
            }
        }
    }

    private func sample(silentFor silent: Double) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let path = DevBuild.logPath.replacingOccurrences(of: ".log", with: "-hang-\(stamp).txt")
        debugLog(String(format: "watchdog: main thread stuck %.1f s, sampling to %@", silent, path))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = [String(ProcessInfo.processInfo.processIdentifier), "5", "-mayDie", "-file", path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            debugLog("watchdog: sample \(p.terminationStatus == 0 ? "written" : "failed (\(p.terminationStatus))")")
        } catch {
            debugLog("watchdog: sample failed to start: \(error)")
        }
    }
}
