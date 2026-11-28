import Foundation
import NaturalLanguage

struct RecordRefiner {
    struct Line {
        let id: Int
        let start: Double
        let end: Double
        let text: String
    }

    private(set) var lines: [Line] = []
    private var pending = ""
    private var heardThrough = -Double.infinity

    static let wait = 2.0

    mutating func emitted(id: Int, start: Double, end: Double, text: String) -> [(id: Int, text: String)] {
        guard start.isFinite, end.isFinite else { return [] }
        lines.append(Line(id: id, start: start, end: max(start, end), text: text))
        return settle(final: false)
    }

    mutating func heard(_ sentence: [Recognition.Run], through: Double? = nil) -> [(id: Int, text: String)] {
        guard let last = sentence.last else { return [] }
        pending += sentence.map(\.text).joined()
        heardThrough = max(heardThrough, through ?? last.end)
        return settle(final: false)
    }

    mutating func finish() -> [(id: Int, text: String)] { settle(final: true) }

    private mutating func settle(final: Bool) -> [(id: Int, text: String)] {
        var covered = 0
        while covered < lines.count {
            let l = lines[covered]
            let nextKnown = covered + 1 < lines.count
            guard final || heardThrough >= l.end - 0.05 && (nextKnown || heardThrough >= l.end + Self.wait) else { break }
            covered += 1
        }
        guard covered > 0 else { return [] }
        let settling = Array(lines[..<covered])
        lines.removeFirst(covered)
        let record = Array(pending)
        let context = settling.map(\.text) + (lines.first.map { [$0.text] } ?? [])
        let ends = Self.split(record, at: context, freeTail: !final)
        var out: [(id: Int, text: String)] = []
        var from = 0
        for (i, l) in settling.enumerated() {
            let to = final && i == settling.count - 1 ? record.count : ends[i]
            out.append((l.id, String(record[from..<max(from, to)])))
            from = max(from, to)
        }
        pending = String(record[from...])
        return out
    }

    static func split(_ record: [Character], at lines: [String], freeTail: Bool) -> [Int] {
        let live = Array(lines.joined())
        let n = live.count, m = record.count
        var bounds: [Int] = []
        var acc = 0
        for t in lines { acc += t.count; bounds.append(acc) }
        guard n > 0, m > 0 else { return bounds.map { _ in 0 } }
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                let same = Self.same(live[i - 1], record[j - 1])
                d[i][j] = min(d[i - 1][j - 1] + (same ? 0 : 1), d[i - 1][j] + 1, d[i][j - 1] + 1)
            }
        }
        var j = m
        if freeTail { j = (0...m).min { d[n][$0] < d[n][$1] || d[n][$0] == d[n][$1] && $0 > $1 }! }
        var at = Array(repeating: 0, count: n + 1)
        var low = at
        var i = n
        at[n] = j
        low[n] = j
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (Self.same(live[i - 1], record[j - 1]) ? 0 : 1) {
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
                low[i] = j
                continue
            }
            if at[i] == 0 { at[i] = j }
            low[i] = j
        }
        var ends = bounds.map { b in at[b] }
        let words = Self.wordStarts(record)
        let inside = HeardText.insideConnectives(record)
        let mark: (Character) -> Bool = { "。！？.!?".contains($0) }
        for k in ends.indices {
            let closed = lines[k].last.map(mark) ?? false
            var e = ends[k]
            if !closed { e = Self.snap(e, in: record) }
            else if bounds[k] > 0, case let p = low[bounds[k] - 1], p < e - 1, mark(record[p]) { e = p + 1 }
            if e == ends[k], e > 0, e < m, !words.contains(e) {
                let after = (e...m).first { words.contains($0) || $0 == m } ?? m
                let before = (0...e).last { words.contains($0) } ?? 0
                e = after - e <= e - before ? after : before
            }
            if closed, e > 0, e < m, mark(record[e]) { e += 1 }
            if let start = inside[e] { e = start }
            ends[k] = max(e, k > 0 ? ends[k - 1] : 0)
        }
        return ends
    }

    static func wordStarts(_ record: [Character]) -> Set<Int> {
        let text = String(record)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var starts: Set<Int> = [0, record.count]
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            starts.insert(text.distance(from: text.startIndex, to: range.lowerBound))
            starts.insert(text.distance(from: text.startIndex, to: range.upperBound))
            return true
        }
        return starts
    }

    static let snapReach = 6

    static func snap(_ e: Int, in record: [Character]) -> Int {
        func mark(_ c: Character) -> Bool { "，。？！；、,.?!;".contains(c) }
        guard e > 0, e < record.count, !mark(record[e - 1]) else { return e }
        for d in 0..<snapReach {
            if e + d < record.count, mark(record[e + d]) { return e + d + 1 }
            if e - 1 - d > 0, mark(record[e - 1 - d]) { return e - d }
        }
        return e
    }

    private static func same(_ a: Character, _ b: Character) -> Bool {
        a == b || a.lowercased() == b.lowercased()
    }
}
