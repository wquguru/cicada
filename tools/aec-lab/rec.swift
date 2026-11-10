// rec <seconds> <out.wav> [vpio]: records the MacBook Pro Microphone (pinned by name; the default input
// may be BlackHole), mono 48 kHz float. "vpio": through a VoiceProcessingIO unit instead (the control).
import AVFoundation
import AudioToolbox
import CoreAudio

let secs = Double(CommandLine.arguments[1])!
let url = URL(fileURLWithPath: CommandLine.arguments[2])
let vpio = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "vpio"

func device(named want: String) -> AudioObjectID {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var size = UInt32(0); AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    for id in ids {
        var n = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var name: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<CFString?>.size)
        if AudioObjectGetPropertyData(id, &n, 0, nil, &s, &name) == noErr, (name?.takeRetainedValue() as String?) == want { return id }
    }
    return 0
}
func defaultOutput() -> AudioObjectID {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var id = AudioObjectID(0); var s = UInt32(4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &id); return id
}

let mono48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
let file = try! AVAudioFile(forWriting: url, settings: mono48.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
let lock = NSLock()
var mic = device(named: "MacBook Pro Microphone")
precondition(mic != 0, "no MacBook Pro Microphone")

if !vpio {
    let e = AVAudioEngine()
    let inp = e.inputNode
    AudioUnitSetProperty(inp.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &mic, 4)
    let fmt = inp.outputFormat(forBus: 0)
    print("rec: plain mic, \(fmt.channelCount) ch \(fmt.sampleRate) Hz")
    let conv = AVAudioConverter(from: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate, channels: 1, interleaved: false)!, to: mono48)!
    inp.installTap(onBus: 0, bufferSize: 4800, format: fmt) { b, _ in
        // Average the channels ourselves: AVAudioConverter can't downmix a discrete layout (it writes zeros).
        let m = AVAudioPCMBuffer(pcmFormat: conv.inputFormat, frameCapacity: b.frameLength)!
        m.frameLength = b.frameLength
        let ch = Int(b.format.channelCount)
        for i in 0..<Int(b.frameLength) {
            var s: Float = 0
            for c in 0..<ch { s += b.floatChannelData![c][i] }
            m.floatChannelData![0][i] = s / Float(ch)
        }
        let o = AVAudioPCMBuffer(pcmFormat: mono48, frameCapacity: AVAudioFrameCount(Double(b.frameLength) * 48000 / fmt.sampleRate) + 16)!
        var given = false
        conv.convert(to: o, error: nil) { _, st in if given { st.pointee = .noDataNow; return nil }; given = true; st.pointee = .haveData; return m }
        lock.withLock { try? file.write(from: o) }
    }
    try! e.start()
    Thread.sleep(forTimeInterval: secs)
    e.stop()
} else {
    var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                         componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    var u: AudioUnit?
    AudioComponentInstanceNew(AudioComponentFindNext(nil, &desc)!, &u)
    let unit = u!
    var out = defaultOutput()
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, &mic, 4)
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &out, 4)
    var agc: UInt32 = 0
    AudioUnitSetProperty(unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0, &agc, 4)
    var asbd = mono48.streamDescription.pointee
    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    final class Box { var unit: AudioUnit?; var scratch = [Float](repeating: 0, count: 8192) }
    let box = Box(); box.unit = unit
    var cb = AURenderCallbackStruct(inputProc: { ref, flags, ts, _, frames, _ in
        let box = Unmanaged<Box>.fromOpaque(ref).takeUnretainedValue()
        let st = box.scratch.withUnsafeMutableBufferPointer { p -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: p.baseAddress))
            return AudioUnitRender(box.unit!, flags, ts, 1, frames, &list)
        }
        guard st == noErr else { return st }
        let o = AVAudioPCMBuffer(pcmFormat: mono48, frameCapacity: frames)!
        o.frameLength = frames
        box.scratch.withUnsafeBufferPointer { o.floatChannelData![0].update(from: $0.baseAddress!, count: Int(frames)) }
        lock.withLock { try? file.write(from: o) }
        return noErr
    }, inputProcRefCon: Unmanaged.passUnretained(box).toOpaque())
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    print("rec: vpio init \(AudioUnitInitialize(unit)) start \(AudioOutputUnitStart(unit))")
    Thread.sleep(forTimeInterval: secs)
    AudioOutputUnitStop(unit)
    AudioComponentInstanceDispose(unit)
}
print("rec: wrote \(file.length) frames")
lock.withLock { file.close() }
