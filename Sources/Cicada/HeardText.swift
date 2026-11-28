import Foundation
import NaturalLanguage

enum HeardText {
    static func clean(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\s*[.。]{2,}|\s*…+"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"…(?:[\s,，]*…)+"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([,，])(?:\s*[,，])+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[,，]\s*…|…\s*[,，]"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,，.。…?？!！;；:：])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        let lead: Set<Character> = [".", ",", ";", ":", "!", "?", "…", "、", "，", "。", "；", "：", "！", "？", "-", "–", "—"]
        s = String(s.drop(while: { lead.contains($0) || $0.isWhitespace }))
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fuller(final: String, draft: String) -> String {
        let cjk = (final + draft).unicodeScalars.contains { $0.properties.isIdeographic }
        func size(_ s: String) -> Int {
            cjk ? s.filter { $0.isLetter || $0.isNumber }.count
                : s.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
        }
        let f = size(final), d = size(draft)
        guard d >= f + (cjk ? 6 : 3), Double(d) >= Double(f) * 1.15 else { return final }
        return clean(draft)
    }

    static func endsInLatin(_ text: String) -> Bool {
        let isCJK: (Character) -> Bool = { c in
            c.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
        }
        let tail = text.reversed().prefix(while: { !isCJK($0) })
        return tail.filter { $0.isASCII && $0.isLetter }.count >= 15
    }

    static func endsSentence(_ draft: String) -> Bool {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard let last = t.last, "。！？.!?".contains(last), !t.hasSuffix(".."),
              !(last == "." && t.dropLast().last?.isNumber == true) else { return false }
        let cjk = t.unicodeScalars.contains { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) }
        return cjk ? t.filter(\.isLetter).count >= 12 : t.split(separator: " ").count >= 5
    }

    static func splitAtSentenceEnd(_ text: String) -> (head: String, tail: String)? {
        var i = text.endIndex
        while i > text.startIndex {
            i = text.index(before: i)
            let head = String(text[...i])
            guard "。！？.!?".contains(text[i]), endsSentence(head) else { continue }
            let tail = text[text.index(after: i)...].trimmingCharacters(in: .whitespaces)
            guard tail.contains(where: \.isLetter) else { return nil }
            return (head.trimmingCharacters(in: .whitespaces), tail)
        }
        return nil
    }

    enum Boundary: Int, Comparable {
        case word
        case clause
        case sentence
        static func < (a: Boundary, b: Boundary) -> Bool { a.rawValue < b.rawValue }
    }

    static let connectives: Set<String> = ["所以", "但是", "因为", "然后", "可是", "而且", "不过", "其实", "反正",
                                           "如果", "虽然", "或者", "另外", "接下来", "总之", "因此", "于是", "就是说"]
    static let particles: Set<String> = ["吧", "呢", "吗", "啊", "嘛", "呀", "啦"]

    static func insideConnectives(_ chars: [Character]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for c in connectives {
            let w = Array(c)
            guard chars.count >= w.count else { continue }
            for p in 0...(chars.count - w.count) where Array(chars[p..<(p + w.count)]) == w {
                for i in (p + 1)..<(p + w.count) { out[i] = p }
            }
        }
        return out
    }

    static func isCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) }
    }

    static func size(_ text: String) -> Int {
        isCJK(text) ? text.filter(\.isLetter).count : text.split(whereSeparator: \.isWhitespace).count
    }

    static func clauseFrom(_ code: String) -> Int { code.hasPrefix("zh") ? 24 : (code == "ja" ? 40 : 20) }
    static func capped(_ code: String) -> Int { ["zh", "ja"].contains(where: code.hasPrefix) ? 60 : 25 }

    static func boundaries(_ text: String, language code: String) -> [(at: Int, kind: Boundary)] {
        var out: [Int: Boundary] = [:]
        func add(_ at: Int, _ kind: Boundary) {
            guard at > 0, at < text.count else { return }
            out[at] = max(out[at] ?? kind, kind)
        }
        let commas: Set<Character> = code.hasPrefix("zh") ? ["，", ","] : (code == "ja" ? ["、", "，"] : [","])
        for (i, ch) in text.enumerated() {
            if "。！？!?".contains(ch) || (ch == "." && i + 1 < text.count) { add(i + 1, .sentence) }
            if commas.contains(ch) { add(i + 1, .clause) }
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if code.hasPrefix("zh") { tokenizer.setLanguage(.simplifiedChinese) }
        var starts = Set<Int>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            starts.insert(start)
            add(start, .word)
            if code.hasPrefix("zh"), particles.contains(String(text[range])) {
                add(text.distance(from: text.startIndex, to: range.upperBound), .clause)
            }
            return true
        }
        if code.hasPrefix("zh") {
            let chars = Array(text)
            var found: [Int: Int] = [:]
            for p in starts {
                for c in connectives where p + c.count <= chars.count && String(chars[p..<(p + c.count)]) == c
                    && (starts.contains(p + c.count) || p + c.count == chars.count) {
                    found[p] = c.count
                }
            }
            for p in found.keys where !found.contains(where: { $0.key + $0.value == p }) { add(p, .clause) }
            for (p, n) in found { for i in (p + 1)..<(p + n) where out[i] == .word { out[i] = nil } }
        }
        return out.keys.sorted().map { at in
            var a = at
            while a < text.count, text[text.index(text.startIndex, offsetBy: a)].isWhitespace { a += 1 }
            return (a, out[at]!)
        }
    }

    static func split(_ text: String, near: Int, kind: Boundary, language code: String) -> (head: String, tail: String)? {
        if let s = split(text, near: near, kind: kind, within: max(8, near / 3), language: code) { return s }
        return kind > .word ? split(text, near: near, kind: .word, within: 3, language: code) : nil
    }

    private static func split(_ text: String, near: Int, kind: Boundary, within: Int,
                              language code: String) -> (head: String, tail: String)? {
        let fit = boundaries(text, language: code).filter { b in
            guard b.kind >= kind, abs(b.at - near) <= within else { return false }
            let head = String(text.prefix(b.at)), tail = String(text.dropFirst(b.at))
            return size(head) >= (isCJK(head) ? 12 : 5) && tail.contains(where: \.isLetter)
        }
        guard let best = fit.min(by: { (abs($0.at - near), -$0.kind.rawValue) < (abs($1.at - near), -$1.kind.rawValue) }) else { return nil }
        let head = text.prefix(best.at).trimmingCharacters(in: .whitespaces)
        let tail = text.dropFirst(best.at).trimmingCharacters(in: .whitespaces)
        return (head, tail)
    }

    static let joinGap = 1.5
    static let joinWords = 40

    static func continues(_ previous: String, _ next: String, gap: Double, cut: Bool) -> Bool {
        guard gap >= -0.5, gap <= joinGap, let last = previous.last, let first = next.first else { return false }
        let cjk = previous.unicodeScalars.contains { $0.properties.isIdeographic }
        let size = cjk ? previous.count / 2 : previous.split(separator: " ").count
        guard size < joinWords else { return false }
        if isCJK(previous + next), Self.size(previous + next) > capped("zh") { return false }
        switch last {
        case "?", "!", "？", "！": return false
        case ".", "。": return cut && first.isLowercase
        default: return true
        }
    }

    static func join(_ previous: String, _ next: String) -> String {
        let cjk = previous.unicodeScalars.contains { $0.properties.isIdeographic }
        var head = previous
        if head.hasSuffix(".") && !head.hasSuffix("…") { head.removeLast() }
        if head.hasSuffix("。") { head.removeLast() }
        return cjk ? head + next : head + " " + next
    }
}
