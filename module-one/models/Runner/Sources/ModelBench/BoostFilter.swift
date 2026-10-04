import Foundation

/// Decides which dictionary replacements from CTC rescoring to keep. Foundation only, so
/// app/check_boost_filter.swift can test it without the model.
///
/// Rescoring swaps transcript words for dictionary terms that sound alike, and on its own it also
/// turns ordinary speech into terms ("nothing" -> "Notion", "remind" -> "Gemini"). A replaced span
/// is kept only when one of these holds:
/// - its letters equal the term's ("open router" -> "OpenRouter", a joined or recased spelling),
/// - it is a "heard as" alias the user listed for that term,
/// - at least one replaced word is not an ordinary dictionary word ("cubectal" -> "kubectl"), and
///   the span is spelled at least half like the term, so a name is never swallowed with its
///   neighbours ("Priya about" -> "Notion").
/// The output is the raw transcript with only the kept replacements applied, so punctuation the
/// rescorer drops around a replacement ("I mean," -> "I Sean") is never lost.
enum BoostFilter {
    struct Word { let start: String.Index; let end: String.Index; let folded: String }

    static func words(_ text: String) -> [Word] {
        var result: [Word] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i].isLetter || text[i].isNumber else { i = text.index(after: i); continue }
            var j = text.index(after: i)
            while j < text.endIndex {
                if text[j].isLetter || text[j].isNumber { j = text.index(after: j); continue }
                let next = text.index(after: j)
                if "'\u{2019}-".contains(text[j]), next < text.endIndex, text[next].isLetter || text[next].isNumber { j = next; continue }
                break
            }
            result.append(Word(start: i, end: j, folded: fold(String(text[i..<j]))))
            i = j
        }
        return result
    }

    static func fold(_ text: String) -> String { text.replacingOccurrences(of: "\u{2019}", with: "'").lowercased() }
    static func letters(_ text: String) -> String { String(fold(text).filter { $0.isLetter || $0.isNumber }) }

    /// `aliases`: folded alias phrases ("cube cuddle"). `isCommonWord` receives one folded word.
    static func filter(raw: String, rescored: String, aliases: Set<String>, isCommonWord: (String) -> Bool) -> String {
        guard raw != rescored else { return raw }
        let a = words(raw), b = words(rescored)
        // LCS over folded words; unmatched runs between matches are the replaced spans.
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i].folded == b[j].folded ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var kept: [(Range<String.Index>, String)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i].folded == b[j].folded { i += 1; j += 1; continue }
            let i0 = i, j0 = j
            while (i < a.count || j < b.count) && !(i < a.count && j < b.count && a[i].folded == b[j].folded) {
                if j < b.count && (i == a.count || dp[i][j + 1] >= dp[i + 1][j]) { j += 1 } else { i += 1 }
            }
            // A pure insertion or deletion keeps the raw words: rescoring only replaces spans.
            guard i > i0, j > j0 else { continue }
            let rawSpan = String(raw[a[i0].start..<a[i - 1].end]), newSpan = String(rescored[b[j0].start..<b[j - 1].end])
            let rawWords = a[i0..<i].map(\.folded)
            let keep = letters(rawSpan) == letters(newSpan) || aliases.contains(rawWords.joined(separator: " "))
                || (rawWords.contains { !isCommonWord($0) } && similarity(letters(rawSpan), letters(newSpan)) >= 0.5)
            if keep { kept.append((a[i0].start..<a[i - 1].end, newSpan)) }
        }
        var output = raw
        for (range, text) in kept.reversed() { output.replaceSubrange(range, with: text) }
        return output
    }

    /// 1 - Levenshtein distance / longer length (the learning filter's measure).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return x.isEmpty && y.isEmpty ? 1 : 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count { current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}
