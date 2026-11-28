import Foundation

struct VoiceActivity {
    struct Tuning: Equatable {
        var onset: Double
        var hold: Float
        static let none = Tuning(onset: 0, hold: 1)
        static let standard = Tuning(onset: 0.03, hold: 0.5)
    }

    static let shortestPause = 0.12

    var gate: VoiceGate
    var tuning: Tuning
    private(set) var voicedTotal = 0.0
    private(set) var silenceRun = 0.0
    private(set) var sinceGap = 0.0
    private(set) var pause: (end: Double, length: Double) = (0, 0)
    private var speaking = false
    private var pending = 0.0
    private let gap: Double

    init(gate: VoiceGate = VoiceGate(), tuning: Tuning = .standard, gap: Double) {
        self.gate = gate
        self.tuning = tuning
        self.gap = gap
    }

    mutating func clearPause() { pause = (0, 0) }

    mutating func feed(_ samples: UnsafeBufferPointer<Float>, rate: Double, clock: Double, pauses: Bool = true) -> Bool {
        let step = gate.adaptive ? samples.count : max(1, Int(rate / 100))
        var voiced = false
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + step)
            var sum: Float = 0
            for k in i..<end { sum += samples[k] * samples[k] }
            let rms = (sum / Float(end - i)).squareRoot()
            if feed(rms: rms, seconds: Double(end - i) / rate, clock: clock + Double(i) / rate, pauses: pauses) { voiced = true }
            i = end
        }
        return voiced
    }

    mutating func feed(rms: Float, seconds: Double, clock: Double, pauses: Bool = true) -> Bool {
        let hold = gate.adaptive ? 1 : tuning.hold
        let line = gate.threshold
        let loud = gate.voiced(rms, seconds: seconds) || (speaking && rms >= line * hold)
        if !loud {
            speaking = false
            silenceRun += pending + seconds
            pending = 0
            sinceGap += seconds
            return false
        }
        if !speaking {
            pending += seconds
            guard pending >= tuning.onset else {
                sinceGap += seconds
                return false
            }
            let started = clock + seconds - pending
            if silenceRun >= Self.shortestPause, pauses { pause = (started, silenceRun) }
            if silenceRun >= gap { sinceGap = pending - seconds }
            voicedTotal += pending - seconds
            speaking = true
            silenceRun = 0
            pending = 0
        }
        voicedTotal += seconds
        sinceGap += seconds
        return true
    }
}
