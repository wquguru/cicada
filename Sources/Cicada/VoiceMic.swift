import AVFoundation
import AudioToolbox
import CoreAudio

final class VoiceMic: @unchecked Sendable {
    var advancedDucking = false
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private let queue = DispatchQueue(label: "com.wquguru.cicada.voicemic")
    private let lock = NSLock()
    private enum UnitState {
        case none
        case ready(AudioUnit, input: AudioObjectID, output: AudioObjectID, advanced: Bool)
        case stale(AudioUnit)
    }
    private var state = UnitState.none
    private var unit: AudioUnit? {
        switch state {
        case .none: nil
        case .ready(let u, _, _, _), .stale(let u): u
        }
    }
    private var building = false
    private var consumers: [String: (AVAudioPCMBuffer) -> Void] = [:]
    private var processed: Set<String> = []
    private var bypassed: Bool?
    private var waiting: [(Bool) -> Void] = []
    private var scratch = [Float](repeating: 0, count: 8192)
    private nonisolated(unsafe) var renders = 0
    private nonisolated(unsafe) var renderError: OSStatus = noErr
    var onUnitChanged: (() -> Void)?

    deinit {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
        }
    }

    var inUse: Bool { lock.withLock { !consumers.isEmpty } }

    func serves(_ key: String, input: AudioObjectID) -> Bool {
        let output = SystemAudioTap.defaultOutputDevice()
        return lock.withLock {
            guard consumers[key] != nil, case .ready(_, let i, let o, let a) = state else { return false }
            return i == input && o == output && a == advancedDucking
        }
    }

    func prepare(input: AudioObjectID, then: ((Bool) -> Void)? = nil) {
        guard let output = SystemAudioTap.defaultOutputDevice() else { then?(false); return }
        lock.lock()
        var ready = false
        let advanced = advancedDucking
        if case .ready(_, let i, let o, let a) = state { ready = (i, o, a) == (input, output, advanced) }
        if ready { lock.unlock(); then?(true); return }
        if let then { waiting.append(then) }
        if building { lock.unlock(); return }
        building = true
        lock.unlock()
        queue.async { [self] in
            let t0 = Date()
            let made = make(input: input, output: output, advanced: advanced)
            let (ok, told) = lock.withLock { () -> (Bool, [(Bool) -> Void]) in
                if let old = unit, consumers.isEmpty { AudioComponentInstanceDispose(old); state = .none }
                var ok = false
                if let made, unit == nil { state = .ready(made, input: input, output: output, advanced: advanced); bypassed = nil; ok = true } else if let made { AudioComponentInstanceDispose(made) }
                building = false
                defer { waiting = [] }
                return (ok, waiting)
            }
            debugLog(String(format: "voice mic: %@ in %.1f s (input %u, output %u)", ok ? "ready" : "failed",
                            Date().timeIntervalSince(t0), input, output))
            onUnitChanged?()
            told.forEach { $0(ok) }
        }
    }

    func attach(_ key: String, input: AudioObjectID, processing: Bool = true, onAudio: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
        guard let output = SystemAudioTap.defaultOutputDevice() else { return false }
        lock.lock()
        guard case .ready(let unit, let i, let o, _) = state, (i, o) == (input, output) else { lock.unlock(); return false }
        let first = consumers.isEmpty
        consumers[key] = onAudio
        if processing { processed.insert(key) } else { processed.remove(key) }
        lock.unlock()
        applyBypass(unit)
        guard first else { return true }
        let status = AudioOutputUnitStart(unit)
        if status != noErr {
            debugLog("voice mic: start failed \(status)")
            lock.withLock { consumers = [:]; state = .stale(unit) }
            return false
        }
        debugLog("voice mic: started for \(key)")
        return true
    }

    func detach(_ key: String) {
        lock.lock()
        guard consumers.removeValue(forKey: key) != nil else { lock.unlock(); return }
        processed.remove(key)
        guard consumers.isEmpty, let unit else {
            let u = unit
            lock.unlock()
            if let u { applyBypass(u) }
            return
        }
        lock.unlock()
        AudioOutputUnitStop(unit)
        debugLog("voice mic: stopped (\(key) was the last)")
    }

    private func applyBypass(_ unit: AudioUnit) {
        let change: Bool? = lock.withLock {
            let b = processed.isEmpty
            if bypassed == b { return nil }
            bypassed = b
            return b
        }
        guard let bypass = change else { return }
        debugLog("voice mic: \(renders) renders since the last change, last error \(renderError)")
        renders = 0
        renderError = noErr
        var value: UInt32 = bypass ? 1 : 0
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size)
        let stopped = running != 0 ? AudioOutputUnitStop(unit) : noErr
        let status = AudioUnitSetProperty(unit, kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global, 0,
                                          &value, UInt32(MemoryLayout<UInt32>.size))
        let started = running != 0 ? AudioOutputUnitStart(unit) : noErr
        debugLog("voice mic: processing \(bypass ? "off" : "on") (running \(running), stop \(stopped), set \(status), start \(started))")
    }

    func release() {
        let old: AudioUnit? = lock.withLock {
            guard consumers.isEmpty, let u = unit else { return nil }
            state = .none
            bypassed = nil
            return u
        }
        if let old {
            AudioComponentInstanceDispose(old)
            debugLog("voice mic: released")
            onUnitChanged?()
        }
    }

    private func make(input: AudioObjectID, output: AudioObjectID, advanced: Bool) -> AudioUnit? {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var made: AudioUnit?
        guard AudioComponentInstanceNew(comp, &made) == noErr, let u = made else { return nil }
        func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: T) -> Bool {
            let status = withUnsafeBytes(of: value) {
                AudioUnitSetProperty(u, property, scope, element, $0.baseAddress, UInt32($0.count))
            }
            if status != noErr { debugLog("voice mic: property \(property) failed \(status)") }
            return status == noErr
        }
        var ok = set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, input)
            && set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, output)
        _ = set(kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0, UInt32(0))
        _ = set(kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0,
                AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: DarwinBoolean(advanced), mDuckingLevel: advanced ? .max : .min))
        let asbd = Self.format.streamDescription.pointee
        ok = ok && set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, asbd)
            && set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, asbd)
        ok = ok && set(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                       AURenderCallbackStruct(inputProc: { ref, flags, ts, _, frames, _ in
                           Unmanaged<VoiceMic>.fromOpaque(ref).takeUnretainedValue().render(flags, ts, frames)
                       }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()))
        if ok, AudioUnitInitialize(u) == noErr { return u }
        AudioComponentInstanceDispose(u)
        return nil
    }

    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>,
                        _ frames: UInt32) -> OSStatus {
        guard let unit, frames > 0, Int(frames) <= scratch.count else { return noErr }
        let status = scratch.withUnsafeMutableBufferPointer { p -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: p.baseAddress))
            return AudioUnitRender(unit, flags, ts, 1, frames, &list)
        }
        let listeners = lock.withLock { Array(consumers.values) }
        renders += 1
        if status != noErr { renderError = status }
        guard status == noErr, !listeners.isEmpty, let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames),
              let dst = out.floatChannelData?[0] else { return status }
        out.frameLength = frames
        scratch.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: Int(frames)) }
        listeners.forEach { $0(out) }
        return noErr
    }
}

final class EchoCancelledRoomMic: AudioSource, @unchecked Sendable {
    var onAudio: ((AVAudioPCMBuffer) -> Void)?
    var onFailed: (() -> Void)?
    private let mic: VoiceMic
    private let device: OutputDevice
    private let lock = NSLock()
    private var _muted = false
    private var stopped = false
    var muted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue } }
    }
    var deviceName: String { device.name }
    var deviceUID: String { device.uid }

    private let processing: Bool
    var echoGate: EchoGate?

    init(mic: VoiceMic, device: OutputDevice, processing: Bool = true) {
        self.mic = mic
        self.device = device
        self.processing = processing
    }

    func start() throws {
        mic.prepare(input: device.id) { [weak self] ok in
            guard let self else { return }
            guard !self.lock.withLock({ self.stopped }) else { self.mic.release(); return }
            let attached = ok && self.mic.attach("room", input: self.device.id, processing: self.processing) { [weak self] buf in self?.deliver(buf) }
            if !attached {
                debugLog("room mic: echo cancellation unavailable, plain mic instead")
                self.onFailed?()
            } else {
                debugLog("room mic started \(self.processing ? "with echo cancellation" : "through the unit, bypassed"): \(self.device.name)")
            }
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        mic.detach("room")
        mic.release()
    }

    private func deliver(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        if let gate = echoGate, let d = buf.floatChannelData?[0], n > 0 {
            var sum: Float = 0
            for i in 0..<n { sum += d[i] * d[i] }
            gate.roomLevel((sum / Float(n)).squareRoot(), seconds: Double(n) / buf.format.sampleRate)
        }
        if muted || echoGate?.closed() == true {
            guard let quiet = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength) else { return }
            quiet.frameLength = buf.frameLength
            if let d = quiet.floatChannelData?[0] { d.update(repeating: 0, count: n) }
            onAudio?(quiet)
            return
        }
        onAudio?(buf)
    }
}
