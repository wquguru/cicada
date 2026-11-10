import AVFoundation
import CoreAudio

/// Debug (`aecDump:<seconds>`): records what the Mac plays (a system audio tap of its own) and the
/// plain room mic side by side, each with the host time of its first sample, so echo cancellation
/// can be tried offline against the reference the app would really have. Files in /tmp:
/// cicada-aec-tap.wav, cicada-aec-mic.wav, cicada-aec.json.
final class EchoDump: @unchecked Sendable {
    private let lock = NSLock()
    private var tapFile: AVAudioFile?
    private var micFile: AVAudioFile?
    private var tapStart: UInt64 = 0
    private var micStart: UInt64 = 0
    private var tap: SystemAudioTap?
    private let mic = AVAudioEngine()

    func run(seconds: Double, device: OutputDevice?, done: @escaping (String) -> Void) {
        let tap = SystemAudioTap()
        self.tap = tap
        tap.onTimedAudio = { [self] buf, host in write(buf, host, tap: true) }
        do { try tap.start() } catch { done("tap failed: \(error)"); return }
        AudioDevices.pinInput(mic, to: device)
        let input = mic.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { tap.stop(); done("no mic"); return }
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate, channels: 1, interleaved: false)!
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [self] buf, when in
            // Average the channels: the built-in mic can come as a discrete multichannel array.
            guard let m = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength), let src = buf.floatChannelData else { return }
            m.frameLength = buf.frameLength
            let ch = Int(buf.format.channelCount)
            for i in 0..<Int(buf.frameLength) {
                var s: Float = 0
                for c in 0..<ch { s += src[c][i] }
                m.floatChannelData![0][i] = s / Float(ch)
            }
            write(m, when.hostTime, tap: false)
        }
        do { try mic.start() } catch { tap.stop(); done("mic failed: \(error)"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            mic.inputNode.removeTap(onBus: 0)
            mic.stop()
            tap.stop()
            let info: String = lock.withLock {
                var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
                func ms(_ h: UInt64) -> Double { Double(h) * Double(tb.numer) / Double(tb.denom) / 1e6 }
                let s = String(format: #"{"tapRate":%.0f,"micRate":%.0f,"tapFrames":%lld,"micFrames":%lld,"micMinusTapMs":%.2f}"#,
                               tapFile?.processingFormat.sampleRate ?? 0, micFile?.processingFormat.sampleRate ?? 0,
                               tapFile?.length ?? 0, micFile?.length ?? 0, ms(micStart) - ms(tapStart))
                tapFile = nil; micFile = nil // closes them
                return s
            }
            try? info.write(toFile: "/tmp/cicada-aec.json", atomically: true, encoding: .utf8)
            self.tap = nil
            done(info)
        }
    }

    private func write(_ buf: AVAudioPCMBuffer, _ host: UInt64, tap: Bool) {
        lock.withLock {
            if tap {
                if tapFile == nil {
                    tapFile = try? AVAudioFile(forWriting: URL(fileURLWithPath: "/tmp/cicada-aec-tap.wav"), settings: buf.format.settings,
                                               commonFormat: .pcmFormatFloat32, interleaved: false)
                    tapStart = host
                }
                try? tapFile?.write(from: buf)
            } else {
                if micFile == nil {
                    micFile = try? AVAudioFile(forWriting: URL(fileURLWithPath: "/tmp/cicada-aec-mic.wav"), settings: buf.format.settings,
                                               commonFormat: .pcmFormatFloat32, interleaved: false)
                    micStart = host
                }
                try? micFile?.write(from: buf)
            }
        }
    }
}
