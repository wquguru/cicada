import AppKit
@preconcurrency import UserNotifications

@MainActor
final class Updates: ObservableObject {
    enum Check { case idle, checking, upToDate, failed }

    @Published private(set) var update: UpdateChecker.Update?
    @Published private(set) var check = Check.idle
    @Published private(set) var lastChecked: Date?
    @Published private(set) var progress: Double?
    @Published var failure: String?
    private(set) var installing = false

    private(set) lazy var checker: UpdateChecker = UpdateChecker { [weak self] in
        self?.update = $0
        self?.lastChecked = self?.checker.lastChecked
        self?.notifyIfDue()
    }
    var busy: () -> Bool = { false }
    private var started = false

    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    func start() {
        lastChecked = checker.lastChecked
        guard !DevBuild.isDev || ProcessInfo.processInfo.environment["CICADA_UPDATE_FEED"] != nil else { return }
        started = true
        checker.start()
    }

    func panelOpened() {
        guard started, check != .checking else { return }
        Task { await checker.checkIfDue(after: UpdateChecker.stale) }
    }

    static func checkedAgo(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return L("刚刚查过") }
        if s < 3600 { return L("\(Int(s / 60)) 分钟前查过") }
        if s < 86_400 { return L("\(Int(s / 3600)) 小时前查过") }
        return L("\(Int(s / 86_400)) 天前查过")
    }

    private var notified: String? {
        get { UserDefaults.standard.string(forKey: "updateNotified") }
        set { UserDefaults.standard.set(newValue, forKey: "updateNotified") }
    }

    nonisolated static func shouldNotify(_ version: String, notified: String?, busy: Bool) -> Bool {
        !busy && version != notified
    }

    func notifyIfDue() {
        let center = UNUserNotificationCenter.current()
        guard let update else {
            center.removeDeliveredNotifications(withIdentifiers: ["update"])
            return
        }
        guard Self.shouldNotify(update.version, notified: notified, busy: busy()) else {
            debugLog("update: \(update.version) not notified (told \(notified ?? "-"), busy \(busy()))")
            return
        }
        notified = update.version
        let content = UNMutableNotificationContent()
        content.title = L("知了有新版本 \(update.version)")
        content.body = L("点按安装，完成后自动重新打开")
        content.userInfo = ["update": update.version]
        let request = UNNotificationRequest(identifier: "update", content: content, trigger: nil)
        let version = update.version
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { debugLog("update: notification not allowed"); return }
            UNUserNotificationCenter.current().add(request) { error in
                debugLog(error.map { "update: notification not shown: \($0)" } ?? "update: notified \(version)")
            }
        }
    }

    func checkNow() {
        guard check != .checking else { return }
        check = .checking
        Task {
            let reached = await checker.check()
            check = update != nil ? .idle : reached ? .upToDate : .failed
            try? await Task.sleep(for: .seconds(4))
            if check != .checking { check = .idle }
        }
    }

    func install(model: AppModel) {
        guard let update, progress == nil else { return }
        if model.running, let id = model.store.liveID, !(model.store.session(id)?.lines.isEmpty ?? true) {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = L("正在记录会议")
            alert.informativeText = L("安装更新会结束这场记录，已记下的内容会保存。")
            alert.addButton(withTitle: L("结束并更新"))
            alert.addButton(withTitle: L("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            model.stop()
        }
        progress = 0
        failure = nil
        installing = true
        Task {
            do {
                try await Updater.install(update) { [weak self] in self?.progress = $0 }
            } catch {
                debugLog("update install failed: \(error.localizedDescription)")
                installing = false
                progress = nil
                failure = error.localizedDescription
                NSWorkspace.shared.open(update.url)
            }
        }
    }
}
