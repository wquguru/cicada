import AVFoundation
import CoreAudio
import Foundation

extension AudioDevices {
    static func inputs() -> [OutputDevice] {
        devices(scope: kAudioObjectPropertyScopeInput).filter {
            !$0.uid.hasPrefix("VPAUAggregateAudioDevice") && !isEchoReference($0.id)
        }
    }

    static func isEchoReference(_ device: AudioObjectID) -> Bool {
        let t = transport(device)
        guard device == SystemAudioTap.defaultOutputDevice(),
              t != kAudioDeviceTransportTypeBluetooth, t != kAudioDeviceTransportTypeBluetoothLE else { return false }
        func streams(_ scope: AudioObjectPropertyScope) -> [AudioStreamID] {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                  mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
            var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ids) == noErr else { return [] }
            return ids
        }
        let inputs = streams(kAudioObjectPropertyScopeInput)
        guard !inputs.isEmpty, !streams(kAudioObjectPropertyScopeOutput).isEmpty else { return false }
        return inputs.allSatisfy { id in
            var type: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyTerminalType,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &type)
            return type == kAudioStreamTerminalTypeUnknown
        }
    }

    static var defaultInput: OutputDevice? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return inputs().first { $0.id == id }
    }

    static func pinInput(_ engine: AVAudioEngine, to device: OutputDevice?) {
        guard let device, let unit = engine.inputNode.audioUnit else { return }
        var cur = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &size)
        guard cur != device.id else { return }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioObjectID>.size))
        debugLog("mic: recording from \(device.name) status=\(status)")
    }

    static func inputDevice(of engine: AVAudioEngine) -> String {
        guard let unit = engine.inputNode.audioUnit else { return "-" }
        var cur = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &size)
        return name(cur) ?? "\(cur)"
    }

    @discardableResult
    static func setDefaultInput(_ device: OutputDevice) -> Bool {
        var id = device.id
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                                UInt32(MemoryLayout<AudioObjectID>.size), &id)
        if status != noErr { debugLog("system mic: set default input \(device.name) failed \(status)") }
        return status == noErr
    }
}

enum SystemMicPlan {
    struct Device: Equatable {
        var uid: String
        var isVirtual: Bool
    }

    static func original(saved: String, current: String?, inputs: [Device]) -> String? {
        let real = inputs.filter { !$0.isVirtual }
        if real.contains(where: { $0.uid == saved }) { return saved }
        if let current, real.contains(where: { $0.uid == current }) { return current }
        return real.first?.uid
    }

    static func recording(chosen: String, saved: String, current: String?, inputs: [Device]) -> String? {
        if inputs.contains(where: { $0.uid == chosen && !$0.isVirtual }) { return chosen }
        return original(saved: saved, current: current, inputs: inputs)
    }
}

@MainActor
final class SystemMic {
    enum State: Equatable {
        case off
        case switched(original: String)
        case notRestored(original: String)
        case moved(to: String)
    }

    let settings: AppSettings
    private(set) var state: State = .off

    init(settings: AppSettings) { self.settings = settings }

    private var plan: [SystemMicPlan.Device] {
        AudioDevices.inputs().map { .init(uid: $0.uid, isVirtual: $0.isVirtualMic) }
    }

    private func device(_ uid: String?) -> OutputDevice? {
        guard let uid else { return nil }
        return AudioDevices.inputs().first { $0.uid == uid }
    }

    var recordingDevice: OutputDevice? {
        device(SystemMicPlan.recording(chosen: settings.speakMic, saved: settings.savedSystemInput,
                                       current: AudioDevices.defaultInput?.uid, inputs: plan))
    }

    var realInputs: [OutputDevice] { AudioDevices.inputs().filter { !$0.isVirtualMic } }

    func engage(wanted: Bool) {
        guard wanted else { release(); return }
        guard let virtual = AudioDevices.inputs().first(where: \.isVirtualMic) else { refresh(wanted: wanted); return }
        let current = AudioDevices.defaultInput
        if settings.savedSystemInput.isEmpty || device(settings.savedSystemInput) == nil,
           let original = SystemMicPlan.original(saved: settings.savedSystemInput, current: current?.uid, inputs: plan) {
            settings.savedSystemInput = original
        }
        if current?.uid != virtual.uid {
            AudioDevices.setDefaultInput(virtual)
            debugLog("system mic: \(current?.name ?? "-") → \(virtual.name), will restore \(device(settings.savedSystemInput)?.name ?? "-")")
        }
        refresh(wanted: wanted)
    }

    func release() {
        let current = AudioDevices.defaultInput
        if current?.isVirtualMic ?? false,
           let back = device(SystemMicPlan.original(saved: settings.savedSystemInput, current: nil, inputs: plan)) {
            AudioDevices.setDefaultInput(back)
            debugLog("system mic: restored \(back.name)")
        }
        if !settings.savedSystemInput.isEmpty { settings.savedSystemInput = "" }
        state = .off
    }

    @discardableResult
    func refresh(wanted: Bool) -> State {
        let saved = settings.savedSystemInput
        let current = AudioDevices.defaultInput
        let originalName = device(SystemMicPlan.original(saved: saved, current: nil, inputs: plan))?.name ?? ""
        let next: State
        if saved.isEmpty {
            next = .off
        } else if current?.isVirtualMic ?? false {
            next = wanted ? .switched(original: originalName) : .notRestored(original: originalName)
        } else if wanted {
            next = .moved(to: current?.name ?? "")
        } else {
            settings.savedSystemInput = ""
            next = .off
        }
        state = next
        return next
    }
}
