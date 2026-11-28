import AVFoundation
import SoundAnalysis

enum SoundKind {
    struct Verdict: Equatable {
        var speech: Double
        var music: Double
    }

    static let speechLine = 0.3
    static let window = 1.0
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private final class Observer: NSObject, SNResultsObserving {
        var verdict = Verdict(speech: 0, music: 0)
        var windows = 0
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let c = result as? SNClassificationResult else { return }
            windows += 1
            verdict.speech = max(verdict.speech, c.classification(forIdentifier: "speech")?.confidence ?? 0)
            verdict.music = max(verdict.music, c.classification(forIdentifier: "music")?.confidence ?? 0)
        }
    }

    static func judge(_ samples: [Float]) -> Verdict? {
        guard !samples.isEmpty else { return nil }
        let frames = max(samples.count, Int(window * 16000))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        dst.update(repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: samples.count) }
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: window, preferredTimescale: 16000)
            request.overlapFactor = 0.5
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let observer = Observer()
            try analyzer.add(request, withObserver: observer)
            analyzer.analyze(buffer, atAudioFramePosition: 0)
            analyzer.completeAnalysis()
            return observer.windows > 0 ? observer.verdict : nil
        } catch {
            debugLog("sound kind: \(error.localizedDescription)")
            return nil
        }
    }

    static func judge(_ samples: [Int16]) -> Verdict? {
        judge(samples.map { Float($0) / 32768 })
    }
}
