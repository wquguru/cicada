import AVFoundation
import CoreAudio

protocol AudioSource: AnyObject {
    var onAudio: ((AVAudioPCMBuffer) -> Void)? { get set }
    func start() throws
    func stop()
}

extension SystemAudioTap: AudioSource {}

enum RoomMicPlan {
    struct Input: Equatable {
        let uid: String
        var builtIn = false
        var bluetooth = false
        var virtual = false
    }

    static func pick(defaultUID: String?, inputs: [Input], preferredUID: String? = nil) -> String? {
        if let preferred = inputs.first(where: { $0.uid == preferredUID }), !preferred.virtual {
            return preferred.uid
        }
        if let d = inputs.first(where: { $0.uid == defaultUID }), !d.virtual, !d.bluetooth { return d.uid }
        return inputs.first(where: \.builtIn)?.uid
            ?? inputs.first(where: { !$0.virtual && !$0.bluetooth })?.uid
            ?? inputs.first(where: { !$0.virtual })?.uid
    }
}

struct VoiceGate {
    static let fixed: Float = 0.01
    static let lowest: Float = 0.0015
    static let blocksPerSecond = 12
    var adaptive = false
    private var quietest: [Float] = []
    private var second: Float = .infinity
    private var elapsed = 0.0

    init(adaptive: Bool = false) { self.adaptive = adaptive }

    var threshold: Float {
        guard adaptive else { return Self.fixed }
        guard quietest.count >= 3 else { return 0.004 }
        let floor = quietest.sorted()[quietest.count / 5]
        return min(Self.fixed, max(Self.lowest, floor * 2))
    }

    mutating func voiced(_ rms: Float, seconds: Double = 1.0 / Double(blocksPerSecond)) -> Bool {
        let on = rms >= threshold
        guard adaptive else { return on }
        second = min(second, rms)
        elapsed += seconds
        if elapsed >= 1 - 1e-9 {
            quietest.append(second)
            if quietest.count > 30 { quietest.removeFirst() }
            second = .infinity
            elapsed = 0
        }
        return on
    }
}

enum RoomMicLoss {
    static func detail(next: String?, builtIn: Bool, both: Bool) -> String {
        guard let next else { return both ? L("只听电脑了") : L("没有别的麦克风，已暂停") }
        return builtIn ? L("已改用 Mac 自带的麦克风") : L("已改用 \(next)")
    }
}

extension AudioDevices {
    static func transport(_ device: AudioObjectID) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return value
    }

    static var roomMic: OutputDevice? { roomMic() }

    static func roomMic(excluding: Set<String> = [], preferredUID: String? = nil) -> OutputDevice? {
        let all = roomMicInputs(excluding: excluding)
        let uid = RoomMicPlan.pick(defaultUID: defaultInput?.uid, inputs: all.map(\.plan), preferredUID: preferredUID)
        return all.first { $0.device.uid == uid }?.device
    }

    static func roomMicChoices(excluding: Set<String> = []) -> [(device: OutputDevice, bluetooth: Bool)] {
        roomMicInputs(excluding: excluding).filter { !$0.plan.virtual }.map { ($0.device, $0.plan.bluetooth) }
    }

    private static func roomMicInputs(excluding: Set<String>) -> [(device: OutputDevice, plan: RoomMicPlan.Input)] {
        inputs().filter { !excluding.contains($0.uid) }.map { d in
            let t = transport(d.id)
            return (d, .init(uid: d.uid, builtIn: t == kAudioDeviceTransportTypeBuiltIn,
                             bluetooth: t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE,
                             virtual: d.isVirtualMic || d.uid.hasPrefix("CADefaultDeviceAggregate")))
        }
    }
}

final class EchoGate: @unchecked Sendable {
    static let hang = 0.4
    static let music = 4.0
    static let stretchGap = 1.5
    static let during = 0.15
    static let quietAfter = 1.0
    static let echoRatio: Float = 3
    static let clearRatio: Float = 2
    static let enough = 3.0
    static let window = 20.0

    private let lock = NSLock()
    private var until: Double = 0
    private var lastLoud: Double = -.infinity
    private var stretchStart: Double = -.infinity
    private var lastWords: Double = -.infinity
    private var during: [(t: Double, rms: Float, s: Double)] = []
    private var quiet: [(t: Double, rms: Float, s: Double)] = []
    private var _echo = true
    private var loud: [Double] = []
    var forced: Bool?

    func reset() {
        lock.withLock {
            during = []
            quiet = []
            _echo = true
        }
        debugLog("room echo: measuring again")
    }

    func hold(now: Double = CFAbsoluteTimeGetCurrent()) {
        lock.withLock {
            loud.append(now)
            loud.removeAll { $0 < now - Self.window * 3 }
            if now - lastLoud > Self.stretchGap { stretchStart = now }
            lastLoud = now
            guard !musicLocked(now), echoLocked else { return }
            until = max(until, now + Self.hang)
        }
    }

    func heardWords(now: Double = CFAbsoluteTimeGetCurrent()) {
        lock.withLock {
            lastWords = now
            if now - lastLoud < Self.hang, echoLocked { until = max(until, lastLoud + Self.hang) }
        }
    }

    func closed(now: Double = CFAbsoluteTimeGetCurrent()) -> Bool {
        lock.withLock { now < until }
    }

    func playedShare(from: Double, to: Double) -> Double {
        lock.withLock {
            guard echoLocked, to > from else { return 0 }
            let steps = max(1, Int((to - from) / 0.1))
            var hit = 0
            for i in 0..<steps {
                let t = from + (Double(i) + 0.5) * (to - from) / Double(steps)
                if loud.contains(where: { $0 <= t + Self.hang && $0 >= t - Self.hang }) { hit += 1 }
            }
            return Double(hit) / Double(steps)
        }
    }

    var echo: Bool { lock.withLock { echoLocked } }
    func playingMusic(now: Double = CFAbsoluteTimeGetCurrent()) -> Bool { lock.withLock { musicLocked(now) } }

    private var echoLocked: Bool { forced ?? _echo }

    private func musicLocked(_ now: Double) -> Bool {
        now - lastLoud <= Self.stretchGap && now - stretchStart >= Self.music && lastWords < now - Self.music
    }

    func roomLevel(_ rms: Float, seconds: Double, now: Double = CFAbsoluteTimeGetCurrent()) {
        lock.withLock {
            let since = now - lastLoud
            if since <= Self.during { during.append((now, rms, seconds)) } else if since >= Self.quietAfter { quiet.append((now, rms, seconds)) } else { return }
            during.removeAll { $0.t < now - Self.window }
            quiet.removeAll { $0.t < now - Self.window * 3 }
            if let ratio = Self.ratio(during: during.map { ($0.rms, $0.s) }, quiet: quiet.map { ($0.rms, $0.s) }) {
                let was = _echo
                if ratio >= Self.echoRatio { _echo = true } else if ratio < Self.clearRatio { _echo = false }
                if was != _echo {
                    debugLog("room echo: \(_echo ? "speakers reach the mic" : "none") (×\(String(format: "%.1f", ratio)))")
                    if !_echo { until = 0 }
                }
            }
        }
    }

    var summary: String {
        lock.withLock {
            let d = during.map(\.rms).sorted(), q = quiet.map(\.rms).sorted()
            let mid = d.isEmpty ? 0 : d[d.count * 4 / 5], floor = q.isEmpty ? 0 : q[q.count / 5]
            return String(format: "during=%.1fs p80=%.4f quiet=%.1fs floor=%.4f", during.reduce(0) { $0 + $1.s }, mid,
                          quiet.reduce(0) { $0 + $1.s }, floor)
        }
    }

    static func ratio(during: [(Float, Double)], quiet: [(Float, Double)]) -> Float? {
        guard during.reduce(0, { $0 + $1.1 }) >= enough, quiet.reduce(0, { $0 + $1.1 }) >= enough else { return nil }
        let d = during.map(\.0).sorted(), q = quiet.map(\.0).sorted()
        let floor = max(q[q.count / 5], 0.0002)
        return d[d.count * 4 / 5] / floor
    }
}

final class RoomMic: AudioSource {
    var onAudio: ((AVAudioPCMBuffer) -> Void)?
    var echoGate: EchoGate?
    private var engine = AVAudioEngine()
    private let device: OutputDevice?
    private let lock = NSLock()
    private var _muted = false
    var muted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue } }
    }

    private var configObserver: NSObjectProtocol?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init(device: OutputDevice?) { self.device = device }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        if let defaultInputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultInputAddress, .main, defaultInputListener)
        }
    }

    private var startedAt = Date.distantPast

    private func restart(_ why: String) {
        guard !stopped, Date().timeIntervalSince(startedAt) > 1 else { return }
        debugLog("room mic: \(why), restarting")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine = AVAudioEngine()
        do { try start() } catch { debugLog("room mic restart failed: \(error)") }
    }

    var deviceName: String { device?.name ?? AudioDevices.inputDevice(of: engine) }
    var deviceUID: String? { device?.uid }

    func start() throws {
        startedAt = Date()
        silence = .waiting
        AudioDevices.pinInput(engine, to: device)
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "RoomMic", code: -1, userInfo: [NSLocalizedDescriptionKey: L("没有可用的麦克风")])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self, buf.frameLength > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength),
                  let dst = out.floatChannelData?[0] else { return }
            out.frameLength = buf.frameLength
            let n = Int(buf.frameLength)
            let channels = Int(buf.format.channelCount)
            if let src = buf.floatChannelData, channels > 0 {
                if Self.simulateSilence { for c in 0..<channels { src[c].update(repeating: 0, count: n) } }
                var sum: Float = 0
                var sound = false
                for i in 0..<n { let v = src[0][i]; sum += v * v; if v != 0 { sound = true } }
                self.echoGate?.roomLevel((sum / Float(max(n, 1))).squareRoot(), seconds: Double(n) / format.sampleRate)
                self.watchSilence(sound: sound)
            }
            if self.muted || self.echoGate?.closed() == true || channels == 0 || buf.floatChannelData == nil {
                dst.update(repeating: 0, count: n)
            } else if let src = buf.floatChannelData {
                dst.update(from: src[0], count: n)
                if channels > 1 {
                    for c in 1..<channels { for i in 0..<n { dst[i] += src[c][i] } }
                    let scale = 1 / Float(channels)
                    for i in 0..<n { dst[i] *= scale }
                }
            }
            self.onAudio?(out)
        }
        engine.prepare()
        try engine.start()
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.restart("audio configuration changed")
            }
        }
        if defaultInputListener == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.restart("system input changed")
            }
            defaultInputListener = listener
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultInputAddress, .main, listener)
        }
    }

    // MARK: A microphone that delivers nothing

    static let silentAfter = 5.0
    nonisolated(unsafe) static var simulateSilence = false
    var onSilent: (() -> Void)?
    private enum SilenceWatch { case waiting, silentSince(Date), settled }
    private var silence = SilenceWatch.waiting
    private var reopenedForSilence = false

    private func watchSilence(sound: Bool) {
        let since: Date
        switch silence {
        case .settled: return
        case .waiting: since = Date()
        case .silentSince(let d): since = d
        }
        if sound { silence = .settled; return }
        silence = .silentSince(since)
        guard Date().timeIntervalSince(since) >= Self.silentAfter else { return }
        silence = .settled
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            if !self.reopenedForSilence {
                self.reopenedForSilence = true
                self.startedAt = .distantPast
                self.restart("silent since it started")
            } else {
                debugLog("room mic: still silent after opening it again")
                self.onSilent?()
            }
        }
    }

    private var stopped = false

    func stop() {
        stopped = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
