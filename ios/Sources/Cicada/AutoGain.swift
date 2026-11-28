import AVFoundation
import MediaToolbox

struct AutoGain {
    private var level: Float = 0.02
    private var gain: Float = 1

    private static let target: Float = 0.08, maxGain: Float = 32
    private static let floor: Float = 0.0006

    mutating func apply(_ p: UnsafeMutablePointer<Float>, count n: Int) {
        guard n > 0 else { return }
        var sum: Float = 0, peak: Float = 0
        for i in 0..<n {
            let x = p[i]
            sum += x * x
            peak = max(peak, abs(x))
        }
        let rms = (sum / Float(n)).squareRoot()
        if rms > Self.floor { level += (rms - level) * (rms > level ? 0.3 : 0.05) }
        let want = min(max(Self.target / max(level, 1e-4), 1), Self.maxGain, 0.9 / max(peak, 1e-6))
        let to = want < gain ? want : gain + (want - gain) * 0.1
        let step = (to - gain) / Float(n)
        for i in 0..<n {
            gain += step
            p[i] = max(-1, min(1, p[i] * gain))
        }
        gain = to
    }
}

enum GainTap {
    private final class State {
        var gain = AutoGain()
        var float = false
    }

    @MainActor
    static func attach(to item: AVPlayerItem) async {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(State()).toOpaque()),
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let f = format.pointee
                Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().float =
                    f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard state.float else { return }
                for b in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let data = b.mData else { continue }
                    state.gain.apply(data.assumingMemoryBound(to: Float.self), count: Int(b.mDataByteSize) / MemoryLayout<Float>.size)
                }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else { return }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }
}
