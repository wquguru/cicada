import Foundation

struct ModelProblem: Equatable {
    enum Cause: Equatable {
        case offline
        case disk
        case limit
        case dictation(String)
        case other(String?)
    }

    let lang: Lang
    let cause: Cause
    let picked: Bool

    static let lowDisk: Int64 = 1_000_000_000

    static func cause(of error: Error, online: Bool, freeBytes: Int64?) -> Cause {
        let chain = errorChain(error as NSError)
        if chain.contains(where: { $0.domain == "SFSpeechErrorDomain" && $0.code == 11 })
            || chain.contains(where: { $0.localizedDescription.contains("Too many allocated locales") }) {
            return .limit
        }
        if let own = chain.first(where: { Recognition.needsUser($0) }) { return .dictation(own.localizedDescription) }
        let offlineCodes = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                            NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                            NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff]
        if chain.contains(where: { $0.domain == NSURLErrorDomain && offlineCodes.contains($0.code) }) { return .offline }
        if chain.contains(where: { ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError)
            || ($0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC)) }) {
            return .disk
        }
        if !online { return .offline }
        if let freeBytes, freeBytes < lowDisk { return .disk }
        if let own = chain.first(where: { $0.domain == "LiveSubsSpeech" }) { return .other(own.localizedDescription) }
        return .other(nil)
    }

    private static func errorChain(_ error: NSError) -> [NSError] {
        var out = [error]
        if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError { out += errorChain(under) }
        for under in error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] ?? [] { out += errorChain(under) }
        return out
    }

    static func freeBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func simulated(_ kind: String) -> NSError {
        switch kind {
        case "offline": return NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        case "disk": return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        case "limit": return NSError(domain: "SFSpeechErrorDomain", code: 11,
                                     userInfo: [NSLocalizedDescriptionKey: "Too many allocated locales, 5 maximum."])
        default: return NSError(domain: "SimulatedModelFailure", code: 1)
        }
    }
}
