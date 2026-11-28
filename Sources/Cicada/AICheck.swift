import Foundation

struct AICheck: Equatable {
    enum StepID: String, CaseIterable { case reach, key, text }

    enum Reason: String, CaseIterable {
        case unreachable, badAddress, invalidKey, mgmtKey, noCredit, noModel, noJSON, busy, serverError
    }

    enum State: Equatable {
        case running
        case ok(seconds: Double?)
        case busy
        case fail(Reason, code: Int? = nil)
        case skipped
        case untested
    }

    struct Step: Equatable {
        let id: StepID
        var state: State
    }

    enum ProxyHint: Equatable {
        case systemOn
        case appRunning(port: Int)
        case none
    }

    var steps: [Step] = StepID.allCases.map { Step(id: $0, state: .untested) }
    var at: Date?
    var passive = false
    var proxy: ProxyHint?
    var localNetworkDenied = false
    var balance: Double?
    var translate: Speed?
    var hear: Hearing?
    var notes: Notes?

    enum Notes: Equatable {
        case running
        case ok(seconds: Double)
        case fail(Reason, code: Int? = nil)
        var ok: Bool { if case .ok = self { true } else { false } }
        var reason: Reason? { if case .fail(let r, _) = self { r } else { nil } }
    }

    struct Speed: Equatable {
        let seconds: Double
        let thinks: Bool
        static let slowAfter = 3.0
        var slow: Bool { thinks || seconds >= Self.slowAfter }
    }

    enum Hearing: Equatable {
        case ok(seconds: Double)
        case unreachable
        case localNetworkDenied
        case fail(code: Int?)
        var ok: Bool { if case .ok = self { true } else { false } }
    }

    var slow: Bool { failure == nil && translate?.slow == true }

    static let lowBalance = 0.5

    subscript(_ id: StepID) -> State {
        get { steps.first { $0.id == id }?.state ?? .untested }
        set { if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].state = newValue } }
    }

    var failure: (step: StepID, reason: Reason, code: Int?)? {
        for s in steps { if case .fail(let r, let code) = s.state { return (s.id, r, code) } }
        return nil
    }

    var running: Bool { steps.contains { $0.state == .running } || notes == .running }
    var notesFailed: Bool { notes?.reason.map { $0 != .busy } ?? false }
    var busy: Bool { steps.contains { $0.state == .busy } }
    var passed: Bool { at != nil && failure == nil && !running }
    var lowBalance: Bool { (balance ?? .infinity) < Self.lowBalance }

    var needsUser: Bool {
        guard let f = failure else { return lowBalance }
        return f.reason != .busy && f.reason != .serverError
    }

    mutating func fail(_ step: StepID, _ reason: Reason, code: Int? = nil, reached: Bool = true) {
        var after = false
        for i in steps.indices {
            if steps[i].id == step { steps[i].state = .fail(reason, code: code); after = true }
            else if after { steps[i].state = .skipped }
            else if reached, !Self.isOK(steps[i].state) { steps[i].state = .ok(seconds: nil) }
        }
        if reason != .unreachable { proxy = nil; localNetworkDenied = false }
    }

    mutating func pass(upTo step: StepID, seconds: Double?) {
        var after = false
        for i in steps.indices {
            if after {
                if steps[i].state == .skipped { steps[i].state = .untested }
            } else if steps[i].id == step {
                steps[i].state = .ok(seconds: seconds)
                after = true
            } else if !Self.isOK(steps[i].state) {
                steps[i].state = .ok(seconds: nil)
            }
        }
        proxy = nil
        localNetworkDenied = false
    }

    var needsLocalNetwork: Bool {
        (failure?.reason == .unreachable && localNetworkDenied) || hear == .localNetworkDenied
    }

    static func isOK(_ s: State) -> Bool { if case .ok = s { true } else { false } }

    static func firstStep(_ provider: AIProvider.Kind) -> StepID {
        provider == .openrouter || provider == .openai ? .key : .text
    }

    static func classify(_ failure: LingClient.Failure, at step: StepID) -> (StepID, Reason, Int?)? {
        switch failure {
        case .network, .timeout: return (.reach, .unreachable, nil)
        case .invalidKey: return (.key, .invalidKey, nil)
        case .rateLimited: return (step, .busy, nil)
        case .http(402): return (.key, .noCredit, 402)
        case .http(let code) where code == 400 || code == 404: return (step == .key ? .key : .text, step == .key ? .serverError : .noModel, code)
        case .http(let code) where code >= 500: return (step, .serverError, code)
        case .http(let code): return (step, .serverError, code)
        case .noKey, .hijacked, .parse: return nil
        }
    }

    static func owner(ofKey key: String) -> (service: AIProvider.Kind, management: Bool)? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.hasPrefix("sk-or-") { return (.openrouter, false) }
        if k.hasPrefix("sk-payg") { return (.zenmux, false) }
        if k.hasPrefix("sk-mgmt") { return (.zenmux, true) }
        return nil
    }

    static func listedModels(_ data: Data) -> Set<String>? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return nil }
        let ids = list.compactMap { $0["id"] as? String }
        return ids.isEmpty ? nil : Set(ids)
    }

    static func balance(key: [String: Any]?, credits: [String: Any]?) -> Double? {
        let k = (key?["data"] as? [String: Any])?["limit_remaining"] as? Double
        var c: Double?
        if let d = credits?["data"] as? [String: Any], let total = d["total_credits"] as? Double,
           let used = d["total_usage"] as? Double { c = total - used }
        switch (k, c) {
        case let (a?, b?): return min(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    // MARK: Words

    static func title(_ id: StepID, host: String) -> String {
        switch id {
        case .reach: L("连上 \(host)")
        case .key: L("key 可以用")
        case .text: L("纪要和翻译")
        }
    }

    func message(service: String, host: String, model: String) -> String? {
        guard let f = failure else { return busy ? L("\(service) 现在很忙，key 没问题。开会时会自动重试。") : nil }
        switch f.reason {
        case .unreachable where localNetworkDenied: return L("知了没有本地网络权限，连不上 \(host)。")
        case .unreachable: return L("这台 Mac 访问不到 \(host)。")
        case .badAddress: return L("地址要用 https；这台 Mac 和局域网里的服务可以用 http。")
        case .invalidKey: return L("\(service) 说这个 key 无效，可能没复制全，或已删除。")
        case .mgmtKey: return L("这是 ZenMux 的管理 key，不能用来调用模型。请粘贴 sk-payg 开头的 key。")
        case .noCredit: return L("\(service) 账户余额不足。")
        case .noModel: return L("\(service) 上找不到 \(model) 这个模型。")
        case .noJSON: return L("这个服务不支持 JSON，纪要写不了；翻译照常。")
        case .busy: return L("\(service) 现在很忙，key 没问题。开会时会自动重试。")
        case .serverError: return L("\(service) 暂时出错（HTTP \(f.code ?? 0)），稍后再试。")
        }
    }

    func slowLine(googleOff: Bool = false) -> String? {
        guard slow, let t = translate else { return nil }
        let secs = String(format: "%.1f", t.seconds)
        if googleOff {
            return t.thinks ? L("这个模型先思考再回答，翻一句要 \(secs) 秒，超过 6 秒这句就不等它了。在服务端关掉思考，或换一个不思考的模型。")
                : L("翻一句要 \(secs) 秒，超过 6 秒这句就不等它了。换一个更小的模型会快一些。")
        }
        return t.thinks ? L("这个模型先思考再回答，翻一句要 \(secs) 秒，超过 6 秒会改用 Google。在服务端关掉思考，或换一个不思考的模型。")
            : L("翻一句要 \(secs) 秒，超过 6 秒会改用 Google。换一个更小的模型会快一些。")
    }

    func notesLine(host: String, model: String, sharedKey: Bool) -> String? {
        guard let reason = notes?.reason else { return nil }
        switch reason {
        case .invalidKey, .mgmtKey:
            return sharedKey ? L("\(host) 不认上面的 key，给它单独填一个。") : L("\(host) 说这个 key 无效，可能没复制全，或已删除。")
        case .unreachable: return L("这台 Mac 访问不到 \(host)。")
        case .badAddress: return L("地址要用 https；这台 Mac 和局域网里的服务可以用 http。")
        case .noCredit: return L("\(host) 账户余额不足。")
        case .noModel: return L("\(host) 上找不到 \(model) 这个模型。")
        case .noJSON: return L("这个模型没按要求返回 JSON，写不了纪要。换一个通用模型。")
        case .busy: return nil
        case .serverError:
            if case .fail(_, let code) = notes { return L("\(host) 暂时出错（HTTP \(code ?? 0)），稍后再试。") }
            return nil
        }
    }

    func hearLine(host: String, model: String) -> String? {
        switch hear {
        case .unreachable?: return L("这台 Mac 访问不到 \(host)，开会时先用本机识别。")
        case .localNetworkDenied?: return L("知了没有本地网络权限，连不上 \(host)，开会时先用本机识别。")
        case .fail(let code)?: return L("\(model) 没接受音频（HTTP \(code ?? 0)），开会时先用本机识别。")
        default: return nil
        }
    }

    func proxyLine(service: String, host: String) -> String? {
        guard failure?.reason == .unreachable, let proxy, !AIProvider.isNearby(host) else { return nil }
        switch proxy {
        case .systemOn: return L("开了代理也连不上：换一个节点，或检查代理软件是否放过 \(host)。")
        case .appRunning(let port): return L("代理软件在运行（端口 \(String(port))），但没开系统代理。在代理软件里打开“系统代理”。")
        case .none: return L("这台电脑没开代理。在国内通常要开代理才能用 \(service)。")
        }
    }

    func balanceLine(service: String) -> String? {
        guard lowBalance, let balance else { return nil }
        let left = String(format: "%.2f", max(0, balance))
        return L("\(service) 余额快用完了（还剩 $\(left)）")
    }

    var summary: String {
        steps.map { s -> String in
            let v: String = switch s.state {
            case .running: "running"
            case .ok(let sec): sec.map { "ok(\(String(format: "%.1f", $0))s)" } ?? "ok"
            case .busy: "busy"
            case .fail(let r, let code): "fail(\(r.rawValue)\(code.map { " \($0)" } ?? ""))"
            case .skipped: "skipped"
            case .untested: "untested"
            }
            return "\(s.id.rawValue)=\(v)"
        }.joined(separator: " ") + (proxy.map { " proxy=\($0)" } ?? "") + (localNetworkDenied ? " localNetwork=denied" : "") + (balance.map { " balance=\(String(format: "%.2f", $0))" } ?? "")
            + (passive ? " passive" : "")
            + (translate.map { " translate=\(String(format: "%.1f", $0.seconds))s\($0.thinks ? " thinks" : "")" } ?? "")
            + (hear.map { " hear=\($0)" } ?? "")
            + (notes.map { " notes=\($0)" } ?? "")
    }
}
