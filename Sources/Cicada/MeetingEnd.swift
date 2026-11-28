import Foundation

struct MeetingEndWatch: Equatable {
    enum Silence: String { case prompt, end, off }

    struct Config: Equatable {
        var followApps = true
        var silence: Silence = .prompt
        var silenceAfter: TimeInterval = 600
        var countdown: TimeInterval = 60
        var appGrace: TimeInterval = 30
    }

    enum Reason: Equatable {
        case appLeft(String)
        case silence
        case nobodySpoke
    }

    struct Pending: Equatable {
        var reason: Reason
        var deadline: Date
    }

    var config: Config
    private(set) var pending: Pending?
    private(set) var lastSpeech: Date
    private(set) var inCall: [String: String] = [:]

    init(config: Config, start: Date) {
        self.config = config
        lastSpeech = start
    }

    mutating func heard(at now: Date) {
        lastSpeech = now
        if pending?.reason == .silence { pending = nil }
    }

    mutating func keepGoing(at now: Date) {
        pending = nil
        lastSpeech = now
        inCall = [:]
    }

    mutating func tick(at now: Date, calls: [String: String], said: Bool) -> Reason? {
        guard said else {
            inCall = config.followApps ? calls : [:]
            pending = nil
            let inACall = config.followApps && !calls.isEmpty
            if config.silence != .off, !inACall, now.timeIntervalSince(lastSpeech) >= config.silenceAfter { return .nobodySpoke }
            return nil
        }
        if config.followApps {
            for (id, name) in calls { inCall[id] = name }
            let hungUp = !inCall.isEmpty && inCall.keys.allSatisfy { calls[$0] == nil }
            if case .appLeft = pending?.reason, !hungUp { pending = nil }
            if hungUp, pending == nil || pending?.reason == .silence {
                let name = inCall.sorted { $0.key < $1.key }.first?.value ?? ""
                pending = Pending(reason: .appLeft(name), deadline: now.addingTimeInterval(config.appGrace))
            }
        } else if case .appLeft = pending?.reason {
            pending = nil
        }
        let inACall = config.followApps && !calls.isEmpty
        if pending == nil, config.silence != .off, !inACall, now.timeIntervalSince(lastSpeech) >= config.silenceAfter {
            if config.silence == .end { return .silence }
            pending = Pending(reason: .silence, deadline: now.addingTimeInterval(config.countdown))
        }
        if config.silence == .off || inACall, pending?.reason == .silence { pending = nil }
        if let p = pending, now >= p.deadline {
            pending = nil
            return p.reason
        }
        return nil
    }
}
