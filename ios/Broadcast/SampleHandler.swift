import AVFoundation
import CoreMedia
import Network
import ReplayKit

@objc(SampleHandler)
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.indaloop.cicada.broadcast", qos: .userInitiated)
    private var connection: NWConnection?
    private var ready = false
    private var done = false
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let (port, token) = Self.endpoint(), let p = NWEndpoint.Port(rawValue: port) else {
            queue.async { self.finish(Self.L("先在知了里点开始听")) }
            return
        }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let c = NWConnection(host: "127.0.0.1", port: p, using: params)
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .ready:
                c.send(content: Data((token + "\n").utf8), completion: .idempotent)
                self.ready = true
                self.watch(c)
            case .waiting, .failed:
                self.finish(Self.L(self.ready ? "知了已结束收听" : "先在知了里点开始听"))
            default:
                break
            }
        }
        connection = c
        c.start(queue: queue)
    }

    override func broadcastFinished() {
        queue.sync {
            done = true
            connection?.cancel()
            connection = nil
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .audioApp, let mono = Self.mono(sampleBuffer) else { return }
        queue.async { [weak self] in self?.send(mono) }
    }

    private func watch(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self, weak c] _, _, complete, error in
            guard let self, let c else { return }
            if complete || error != nil { self.finish(Self.L("知了已结束收听")) } else { self.watch(c) }
        }
    }

    private func send(_ mono: AVAudioPCMBuffer) {
        guard ready, !done, let c = connection else { return }
        if converter?.inputFormat != mono.format { converter = AVAudioConverter(from: mono.format, to: target) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * target.sampleRate / mono.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        let bytes = Int(out.frameLength) * 2
        var frame = Data(capacity: bytes + 4)
        withUnsafeBytes(of: UInt32(bytes).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(Data(bytes: samples, count: bytes))
        c.send(content: frame, completion: .idempotent)
    }

    private func finish(_ message: String) {
        guard !done else { return }
        done = true
        connection?.cancel()
        finishBroadcastWithError(NSError(domain: "Cicada", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }

    private static func L(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }

    private static func endpoint() -> (UInt16, String)? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String, !prefix.isEmpty,
              var app = Bundle.main.bundleIdentifier, app.hasSuffix(".broadcast") else { return nil }
        app.removeLast(".broadcast".count)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "cast-link",
                                    kSecAttrAccount as String: "endpoint", kSecAttrAccessGroup as String: prefix + app + ".cast",
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let parts = String(decoding: data, as: UTF8.self).split(separator: " ")
        guard parts.count == 2, let port = UInt16(parts[0]) else { return nil }
        return (port, String(parts[1]))
    }

    private static func mono(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let channels = Int(asbd.mChannelsPerFrame)
        let bytes = Int(asbd.mBitsPerChannel) / 8
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard frames > 0, channels > 0, [2, 4].contains(bytes) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length >= frames * channels * bytes else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard status == kCMBlockBufferNoErr,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = out.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            func sample(_ offset: Int) -> Float {
                if bytes == 2 {
                    var v = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                    if bigEndian { v = v.byteSwapped }
                    return Float(Int16(bitPattern: v)) / 32768
                }
                var v = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                if bigEndian { v = v.byteSwapped }
                return isFloat ? Float(bitPattern: v) : Float(Int32(bitPattern: v)) / 2_147_483_648
            }
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels {
                    sum += sample(interleaved ? (i * channels + c) * bytes : (c * frames + i) * bytes)
                }
                dst[i] = sum / Float(channels)
            }
        }
        out.frameLength = AVAudioFrameCount(frames)
        return out
    }
}
