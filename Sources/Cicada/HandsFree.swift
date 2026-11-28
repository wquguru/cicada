import Foundation

struct HandsFreeDetector {
    struct Tuning: Equatable {
        var onset = 0.1
        var bridge = 0.15
        var hangover = 1.0
        var longest = 20.0
        var margin: Float = 4
        var lowest: Float = 0.004
        var hold: Float = 0.5
        static let standard = Tuning()
    }

    enum Event: Equatable { case none, began, ended(cut: Bool) }

    var tuning: Tuning
    private(set) var talking = false
    private(set) var length = 0.0
    private var voiced = 0.0
    private var gap = 0.0
    private var quiet = 0.0
    private var quietest: [Float] = []
    private var second: Float = .infinity
    private var elapsed = 0.0

    init(tuning: Tuning = .standard) { self.tuning = tuning }

    var floor: Float { quietest.count < 3 ? tuning.lowest / tuning.margin : quietest.sorted()[quietest.count / 5] }
    var line: Float { max(tuning.lowest, floor * tuning.margin) }

    mutating func reset() {
        talking = false
        length = 0; voiced = 0; gap = 0; quiet = 0
    }

    var ready: Bool { quietest.count >= 3 }

    mutating func feed(rms: Float, seconds: Double) -> Event {
        learn(rms, seconds)
        guard ready else { return .none }
        if !talking {
            if rms >= line {
                voiced += seconds; gap = 0
            } else {
                gap += seconds
                if gap > tuning.bridge { voiced = 0 }
            }
            guard voiced >= tuning.onset else { return .none }
            talking = true
            length = voiced; quiet = 0; voiced = 0; gap = 0
            return .began
        }
        length += seconds
        quiet = rms >= line * tuning.hold ? 0 : quiet + seconds
        if quiet >= tuning.hangover {
            reset()
            return .ended(cut: false)
        }
        if length >= tuning.longest {
            length = 0
            return .ended(cut: true)
        }
        return .none
    }

    private mutating func learn(_ rms: Float, _ seconds: Double) {
        second = min(second, rms)
        elapsed += seconds
        guard elapsed >= 1 - 1e-9 else { return }
        quietest.append(second)
        if quietest.count > 10 { quietest.removeFirst() }
        second = .infinity
        elapsed = 0
    }
}
