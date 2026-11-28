import Foundation

struct LineFix: Codable, Equatable, Hashable {
    var from: String
    var to: String
    var ask: Bool? = nil
    var off: Bool? = nil
    var user: Bool? = nil

    var applied: Bool { ask != true && off != true }
}

enum Correction {
    struct Edit: Equatable {
        var from: String
        var to: String
        var confidence: Double
    }

    enum Verdict: Equatable { case apply, ask, drop }

    static let applyAt = 0.6
    static let spellingAt = 0.8
    static let askAt = 0.8

    static func core(_ from: String, _ to: String) -> (from: String, to: String) {
        let a = Array(from), b = Array(to)
        var i = 0
        while i < min(a.count, b.count), a[i] == b[i] { i += 1 }
        var j = 0
        while j < min(a.count, b.count) - i, a[a.count - 1 - j] == b[b.count - 1 - j] { j += 1 }
        let word: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let fromEdge = { (k: Int) -> Bool in (k < a.count && word(a[k])) || (k < b.count && word(b[k])) }
        if fromEdge(i) { while i > 0, word(a[i - 1]) { i -= 1 } }
        if (a.count - j - 1 >= 0 && word(a[a.count - j - 1])) || (b.count - j - 1 >= 0 && word(b[b.count - j - 1])) {
            while j > 0, word(a[a.count - j]) { j -= 1 }
        }
        while a.count - j - i < 2 || b.count - j - i < 2 {
            if j > 0, !word(a[a.count - j]) { j -= 1 } else if i > 0, !word(a[i - 1]) { i -= 1 } else { break }
        }
        return (String(a[i..<(a.count - j)]), String(b[i..<(b.count - j)]))
    }

    static func label(_ f: LineFix) -> (from: String, to: String) {
        let c = core(f.from, f.to)
        return c.from.isEmpty || c.to.isEmpty ? (f.from, f.to) : c
    }

    static func decide(_ e: Edit, known: (String, String) -> Bool, rejected: (String, String) -> Bool) -> Verdict {
        let c = core(e.from, e.to)
        guard !c.from.isEmpty, !c.to.isEmpty, c.from.lowercased() != c.to.lowercased(),
              !rejected(e.from, e.to), !rejected(c.from, c.to) else { return .drop }
        if known(e.from, e.to) || known(c.from, c.to) { return .apply }
        guard e.confidence >= applyAt else { return .drop }
        let latinFrom = c.from.contains(where: \.isASCIILetter), latinTo = c.to.contains(where: \.isASCIILetter)
        if !latinFrom, !latinTo, han(c.from), han(c.to), soundsAlike(c.from, c.to) { return .apply }
        if latinFrom, latinTo, c.from.allSatisfy(\.isASCII), c.to.allSatisfy(\.isASCII), e.confidence >= spellingAt,
           c.from.lowercased() != c.to.lowercased(), distance(c.from.lowercased(), c.to.lowercased()) <= 2 {
            return .apply
        }
        if latinTo, e.confidence >= askAt, nameShaped(c.to) { return .ask }
        return .drop
    }

    static func nameShaped(_ s: String) -> Bool {
        s.contains { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    static func translation(heard: String, word: String) -> Bool {
        han(heard) && word.contains(where: \.isASCIILetter) && word.allSatisfy(\.isASCII) && !nameShaped(word)
    }

    static func pinyin(_ s: String) -> [String] {
        s.map { ch in
            let m = NSMutableString(string: String(ch))
            CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
            CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
            return (m as String).lowercased().trimmingCharacters(in: .whitespaces)
        }
    }

    private static let initials = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q",
                                   "x", "r", "z", "c", "s", "y", "w"]

    private static func split(_ syllable: String) -> (String, String) {
        for i in initials where syllable.hasPrefix(i) { return (i, String(syllable.dropFirst(i.count))) }
        return ("", syllable)
    }

    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let x = pinyin(a), y = pinyin(b)
        guard x.count == y.count, !x.isEmpty else { return false }
        var score = 0.0
        for (p, q) in zip(x, y) {
            if p == q { score += 1; continue }
            let (i1, f1) = split(p), (i2, f2) = split(q)
            if i1 == i2 || f1 == f2 || f1.replacingOccurrences(of: "ng", with: "n") == f2.replacingOccurrences(of: "ng", with: "n") {
                score += 0.5
            }
        }
        return score / Double(x.count) >= 0.75
    }

    static func han(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0.properties.isIdeographic }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var prev = row[0]
            row[0] = i + 1
            for (j, cb) in b.enumerated() {
                let cur = row[j + 1]
                row[j + 1] = min(row[j + 1] + 1, row[j] + 1, prev + (ca == cb ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    static func word(_ s: String, in text: String) -> Range<String.Index>? {
        let latin: (Character?) -> Bool = { $0.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false }
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: s, range: from..<text.endIndex) {
            let before = r.lowerBound > text.startIndex ? text[text.index(before: r.lowerBound)] : nil
            let after = r.upperBound < text.endIndex ? text[r.upperBound] : nil
            if !(latin(s.first) && latin(before)), !(latin(s.last) && latin(after)) { return r }
            from = text.index(after: r.lowerBound)
        }
        return nil
    }

    static func apply(_ fixes: [LineFix], to src: String) -> (text: String, marks: [Range<String.Index>]) {
        var text = src
        var spans: [(String, Int)] = []
        let ordered = fixes.filter { $0.user != true } + fixes.filter { $0.user == true }
        for f in ordered where f.applied && !f.from.isEmpty {
            guard let r = word(f.from, in: text) ?? text.range(of: f.from) else { continue }
            let start = text.distance(from: text.startIndex, to: r.lowerBound)
            let delta = f.to.count - f.from.count
            spans = spans.map { $0.1 > start ? ($0.0, $0.1 + delta) : $0 }
            text.replaceSubrange(r, with: f.to)
            spans.append((f.to, start))
        }
        let marks = spans.compactMap { word, offset -> Range<String.Index>? in
            guard offset + word.count <= text.count else { return nil }
            let lo = text.index(text.startIndex, offsetBy: offset)
            return lo..<text.index(lo, offsetBy: word.count)
        }
        return (text, marks.sorted { $0.lowerBound < $1.lowerBound })
    }

    static func parse(_ reply: String, subtitle: String) -> (translation: String, edits: [Edit])? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
              let data = String(reply[open...close]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translation = o["translation"] as? String else { return nil }
        let raw = o["fixes"] as? [[String: Any]] ?? []
        var edits: [Edit] = []
        for f in raw {
            guard let from = f["from"] as? String, let to = f["to"] as? String, !from.isEmpty, from != to,
                  subtitle.contains(from) else { continue }
            let c = (f["confidence"] as? Double) ?? (f["confidence"] as? NSNumber)?.doubleValue ?? 0
            edits.append(Edit(from: from, to: to, confidence: c))
        }
        return (translation.trimmingCharacters(in: .whitespacesAndNewlines), edits)
    }

    static func merge(_ old: [LineFix], _ new: [LineFix]) -> [LineFix] {
        let kept = old.filter { $0.off == true || $0.user == true }
        let fresh = new.filter { n in
            let c = core(n.from, n.to)
            return !kept.contains { $0.from == n.from || core($0.from, $0.to).from == c.from }
        }
        return kept + fresh
    }

    static func userEdit(shown: String, edited: String, src: String, fixes: [LineFix]) -> (fix: LineFix, heard: String, swap: Bool)? {
        let new = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != shown else { return nil }
        let a = Array(shown), b = Array(new)
        var p = 0
        while p < min(a.count, b.count), a[p] == b[p] { p += 1 }
        var q = 0
        while q < min(a.count, b.count) - p, a[a.count - 1 - q] == b[b.count - 1 - q] { q += 1 }
        let swap = a.count - p - q > 0 && b.count - p - q > 0
        let latin: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
        var tokens: [Range<Int>] = []
        var k = 0
        while k < a.count {
            var e = k + 1
            if latin(a[k]) { while e < a.count, latin(a[e]) { e += 1 } }
            tokens.append(k..<e)
            k = e
        }
        var start = p, end = a.count - q
        if let t = tokens.first(where: { $0.contains(start) }) { start = t.lowerBound }
        if end > start, let t = tokens.first(where: { $0.contains(end - 1) }) { end = t.upperBound }
        func span() -> String { String(a[start..<end]) }
        func count(_ x: String) -> Int {
            guard !x.isEmpty else { return 0 }
            var n = 0, r = shown.startIndex..<shown.endIndex
            while let f = shown.range(of: x, range: r) { n += 1; r = f.upperBound..<shown.endIndex }
            return n
        }
        func replacement() -> String { String(b[start..<(b.count - (a.count - end))]) }
        while !span().contains(where: { $0.isLetter || $0.isNumber }) || count(span()) != 1 || replacement().isEmpty {
            if let t = tokens.last(where: { $0.upperBound <= start }) { start = t.lowerBound }
            else if let t = tokens.first(where: { $0.lowerBound >= end }) { end = t.upperBound }
            else { break }
        }
        let from = span()
        let to = replacement()
        guard !from.isEmpty, from != to else { return nil }
        var heard = from
        if !src.contains(from), let earlier = fixes.first(where: { $0.applied && from.contains($0.to) }) {
            heard = core(earlier.from, earlier.to).from
        }
        return (LineFix(from: from, to: to, user: true), heard, swap)
    }
}

extension TranscriptLine {
    var shown: String { fixes.map { Correction.apply($0, to: src).text } ?? src }
}

private extension Character {
    var isASCIILetter: Bool { isASCII && isLetter }
}
