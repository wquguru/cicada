import AVFoundation
import Network
import ReplayKit
import UIKit

final class CastLink: @unchecked Sendable {
    enum State: Equatable { case waiting, connected, ended }

    static var available: Bool {
        guard let dir = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("CicadaBroadcast.appex").path)
    }
    static var extensionID: String { (Bundle.main.bundleIdentifier ?? "") + ".broadcast" }

    var onAudio: ((AVAudioPCMBuffer) -> Void)?
    var onState: (@MainActor (State) -> Void)?
    private let queue = DispatchQueue(label: "com.indaloop.cicada.cast", qos: .userInitiated)
    private var listener: NWListener?
    private var connection: NWConnection?
    private let token = UUID().uuidString
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener?.port?.rawValue else { return }
                CastEndpoint.store(port: port, token: self.token)
                debugLog("cast: waiting on port \(port)")
            case .failed(let error):
                debugLog("cast: listener failed \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            onAudio = nil
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
        }
        CastEndpoint.clear()
    }

    private func accept(_ c: NWConnection) {
        guard connection == nil else { c.cancel(); return }
        connection = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            switch state {
            case .failed, .cancelled:
                guard let self, let c, self.connection === c else { return }
                self.lost()
            default: break
            }
        }
        c.start(queue: queue)
        let want = token.utf8.count + 1
        c.receive(minimumIncompleteLength: want, maximumLength: want) { [weak self, weak c] data, _, _, _ in
            guard let self, let c else { return }
            guard let data, String(decoding: data, as: UTF8.self) == self.token + "\n" else {
                debugLog("cast: wrong token, closed")
                c.cancel()
                if self.connection === c { self.connection = nil }
                return
            }
            debugLog("cast: broadcast connected")
            self.report(.connected)
            self.readFrame(c)
        }
    }

    private func readFrame(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak c] head, _, done, error in
            guard let self, let c else { return }
            guard let head, head.count == 4, error == nil else { if done || error != nil { self.close(c) }; return }
            let count = Int(head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            guard count > 0, count <= 1 << 20, count % 2 == 0 else { self.close(c); return }
            c.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self, weak c] body, _, done, error in
                guard let self, let c else { return }
                guard let body, body.count == count, error == nil else { self.close(c); return }
                if let b = self.buffer(body) { self.onAudio?(b) }
                if done { self.close(c) } else { self.readFrame(c) }
            }
        }
    }

    private func buffer(_ data: Data) -> AVAudioPCMBuffer? {
        let n = data.count / 2
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)), let dst = b.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            for i in 0..<n { dst[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768 }
        }
        b.frameLength = AVAudioFrameCount(n)
        return b
    }

    private func close(_ c: NWConnection) {
        c.cancel()
        if connection === c { lost() }
    }

    private func lost() {
        connection = nil
        debugLog("cast: broadcast ended")
        report(.ended)
    }

    private func report(_ s: State) {
        let cb = onState
        DispatchQueue.main.async { MainActor.assumeIsolated { cb?(s) } }
    }
}

enum CastEndpoint {
    private static var group: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String, !prefix.isEmpty,
              let id = Bundle.main.bundleIdentifier else { return nil }
        return prefix + id + ".cast"
    }

    private static var query: [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "cast-link",
                                kSecAttrAccount as String: "endpoint"]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    static func store(port: UInt16, token: String) {
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data("\(port) \(token)".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { debugLog("cast: keychain store failed \(status)") }
        #if targetEnvironment(simulator)
        debugLog("cast: simulator endpoint \(port) \(token)")
        #endif
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}

@MainActor
enum CastPicker {
    private static var picker: RPSystemBroadcastPickerView?

    static func show() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        picker?.removeFromSuperview()
        let p = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        p.preferredExtension = CastLink.extensionID
        p.showsMicrophoneButton = false
        p.alpha = 0.01
        p.isAccessibilityElement = false
        window.addSubview(p)
        picker = p
        let button = p.subviews.compactMap { $0 as? UIButton }.first
        debugLog("cast: picker \(button == nil ? "has no button" : "shown")")
        button?.sendActions(for: .touchUpInside)
    }
}
