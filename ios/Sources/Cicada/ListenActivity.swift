import ActivityKit
import Foundation

struct ListenActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var line: String
        var source: String
        var people: Int
        var paused = false
    }

    var startedAt: Date
    var pair: String
}
