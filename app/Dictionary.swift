import Foundation

// Custom dictionary: manual and learned term preferences, applied to dictated text.
// Foundation only, so it builds on Linux checks and on macOS 26.

struct DictionaryError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum EntrySource: String, Codable { case manual, learned }

struct DictionaryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    /// The spelling written into dictated text, exactly as stored (e.g. "Akme", "iPhone").
    var preferred: String
    /// Spoken variants or commonly mistaken forms. Matched exactly (case-insensitive, whole words).
    var variants: [String]
    let source: EntrySource
    let createdAt: Date
    var enabled: Bool
}

/// Word tokenizer shared by dictionary matching and the learning filter.
/// A word is a run of letters/digits (including combining marks); an apostrophe or hyphen
/// joins two word characters ("don't", "e-mail"), so "Acme" never matches inside
/// "Acmeville", "Acme's" or "Acme-based".
enum TermText {
    struct Token {
        let start: Int   // index into the Character array
        let end: Int     // exclusive
        let text: String
        var folded: String { TermText.fold(text) }
    }

    static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
    }

    static func isCore(_ c: Character) -> Bool { c.isLetter || c.isNumber }
    static func isJoiner(_ c: Character) -> Bool { c == "'" || c == "\u{2019}" || c == "-" }

    static func tokens(_ chars: [Character]) -> [Token] {
        var result: [Token] = []
        var i = 0
        while i < chars.count {
            guard isCore(chars[i]) else { i += 1; continue }
            var j = i + 1
            while j < chars.count {
                if isCore(chars[j]) { j += 1; continue }
                if isJoiner(chars[j]), j + 1 < chars.count, isCore(chars[j + 1]) { j += 2; continue }
                break
            }
            result.append(Token(start: i, end: j, text: String(chars[i..<j])))
            i = j
        }
        return result
    }

    static func tokens(_ text: String) -> [Token] { tokens(Array(text)) }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Folded word key for a phrase, or nil when the phrase holds anything besides words and
    /// single spaces (punctuation is not part of a match key).
    static func phraseKey(_ phrase: String) -> String? {
        let normalized = collapseWhitespace(phrase)
        let words = tokens(normalized)
        guard !words.isEmpty else { return nil }
        let key = words.map(\.folded).joined(separator: " ")
        return key == fold(normalized) ? key : nil
    }
}

/// Owner-only private JSON files with atomic replacement, using FileManager only.
/// The containing directory is 0700, so the short interval before the file's own 0600
/// attribute is applied is not readable by other users.
enum PrivateFiles {
    static func prepareDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path) {
            guard attrs[.type] as? FileAttributeType == .typeDirectory else {
                throw DictionaryError("Private storage requires a real directory")
            }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func write(_ data: Data, to url: URL) throws {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           attrs[.type] as? FileAttributeType != .typeRegular {
            throw DictionaryError("Private file is not a regular file")
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// nil when the file does not exist yet.
    static func read(_ url: URL) throws -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        guard attrs[.type] as? FileAttributeType == .typeRegular else {
            throw DictionaryError("Private file is not a regular file")
        }
        return try Data(contentsOf: url)
    }
}

/// Persists entries as `dictionary.json` in `directory`. Every mutation writes through.
///
/// Case policy for `apply(to:)`: the preferred spelling is inserted exactly as stored,
/// because it is the user's chosen form ("iPhone", "Akme", "kubectl"). The only exception:
/// when the matched words start a sentence (text start, or after . ! ? or a newline,
/// ignoring opening quotes/brackets), the original began with an uppercase letter, and the
/// preferred spelling contains no uppercase letters at all, its first letter is capitalized.
/// So "kubectl" stays "kubectl" mid-sentence and becomes "Kubectl" at a sentence start,
/// while "iPhone" is never altered.
final class DictionaryStore {
    static let fileName = "dictionary.json"
    static let maxVariantWords = 6
    static let maxLength = 100

    let directory: URL
    private(set) var entries: [DictionaryEntry] = []
    private var file: URL { directory.appendingPathComponent(Self.fileName) }

    private struct FileFormat: Codable {
        var version = 1
        var entries: [DictionaryEntry]
    }

    init(directory: URL) throws {
        self.directory = directory
        try reload()
    }

    /// Re-reads from disk; an absent file means an empty dictionary (e.g. after Delete all data).
    func reload() throws {
        try PrivateFiles.prepareDirectory(directory)
        guard let data = try PrivateFiles.read(file) else { entries = []; return }
        let decoded = try JSONDecoder().decode(FileFormat.self, from: data)
        guard decoded.version == 1 else { throw DictionaryError("Unsupported dictionary version") }
        entries = decoded.entries
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try PrivateFiles.write(try encoder.encode(FileFormat(entries: entries)), to: file)
    }

    @discardableResult
    func add(preferred: String, variants: [String], source: EntrySource = .manual,
             enabled: Bool = true, now: Date = Date()) throws -> DictionaryEntry {
        let entry = DictionaryEntry(id: UUID(), preferred: preferred, variants: variants,
                                    source: source, createdAt: now, enabled: enabled)
        let validated = try validate(entry)
        entries.append(validated)
        try save()
        return validated
    }

    /// Replaces the entry with the same id. `source` and `createdAt` are kept from the stored entry.
    func update(_ entry: DictionaryEntry) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw DictionaryError("Dictionary entry not found")
        }
        let stored = entries[index]
        let merged = DictionaryEntry(id: stored.id, preferred: entry.preferred, variants: entry.variants,
                                     source: stored.source, createdAt: stored.createdAt, enabled: entry.enabled)
        entries[index] = try validate(merged)
        try save()
    }

    func delete(id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw DictionaryError("Dictionary entry not found")
        }
        entries.remove(at: index)
        try save()
    }

    /// Removes every learned entry and keeps manual ones. Returns what was removed.
    /// To also forget evidence and tombstones, call `CorrectionLedger.reset()`, which calls this.
    @discardableResult
    func resetLearned() throws -> [DictionaryEntry] {
        let removed = entries.filter { $0.source == .learned }
        entries.removeAll { $0.source == .learned }
        try save()
        return removed
    }

    /// Gap #12: spoken commands a dictionary entry may target ("Kocia Mark" -> "question mark").
    /// Derived from `RuleCleaner.markCommands` (plus its "@" phrases) so the two never drift. Dictionary
    /// application runs before cleanup (`ProcessingCoordinator.prepare`), so these entries apply first.
    static let commandPhrases: Set<String> = Set(RuleCleaner.markCommands.map { $0.0.joined(separator: " ") } + ["at the rate", "at sign"])
    /// An entry whose preferred form is a spoken command: applied ahead of other entries and kept
    /// out of every transcription boost and cleanup hint (it is not a word to bias toward).
    static func isCommandTarget(_ entry: DictionaryEntry) -> Bool {
        TermText.phraseKey(entry.preferred).map(commandPhrases.contains) ?? false
    }

    /// The enabled entry whose variant matches `phrase` (folded, whole words), if any.
    func entry(forVariant phrase: String) -> DictionaryEntry? {
        guard let key = TermText.phraseKey(phrase) else { return nil }
        return variantTable()[key]
    }

    private func validate(_ entry: DictionaryEntry) throws -> DictionaryEntry {
        let preferred = TermText.collapseWhitespace(entry.preferred)
        guard !preferred.isEmpty, preferred.count <= Self.maxLength,
              !TermText.tokens(preferred).isEmpty else {
            throw DictionaryError("Preferred spelling must contain a word")
        }
        var seen = Set<String>()
        var variants: [String] = []
        for raw in entry.variants {
            let variant = TermText.collapseWhitespace(raw)
            if variant.isEmpty { continue }
            guard variant.count <= Self.maxLength, let key = TermText.phraseKey(variant) else {
                throw DictionaryError("Variants may contain only words separated by spaces")
            }
            guard key.split(separator: " ").count <= Self.maxVariantWords else {
                throw DictionaryError("Variants are limited to \(Self.maxVariantWords) words")
            }
            if seen.insert(key).inserted { variants.append(variant) }
        }
        if entry.enabled {
            for other in entries where other.enabled && other.id != entry.id {
                for variant in other.variants where seen.contains(TermText.phraseKey(variant) ?? "") {
                    throw DictionaryError("“\(variant)” already belongs to “\(other.preferred)”")
                }
            }
        }
        return DictionaryEntry(id: entry.id, preferred: preferred, variants: variants,
                               source: entry.source, createdAt: entry.createdAt, enabled: entry.enabled)
    }

    /// Folded variant key -> entry. Command targets win, then manual entries over learned ones,
    /// then older entries.
    private func variantTable() -> [String: DictionaryEntry] {
        var table: [String: DictionaryEntry] = [:]
        let ordered = entries.filter(\.enabled).sorted {
            let command0 = Self.isCommandTarget($0), command1 = Self.isCommandTarget($1)
            if command0 != command1 { return command0 }
            if $0.source != $1.source { return $0.source == .manual }
            return $0.createdAt < $1.createdAt
        }
        for entry in ordered {
            for variant in entry.variants {
                guard let key = TermText.phraseKey(variant), table[key] == nil else { continue }
                table[key] = entry
            }
        }
        return table
    }

    /// Replaces whole-word variant phrases with preferred spellings. Matching is exact on the
    /// stored variants after case folding: no fuzzy or phonetic matching, so similar-sounding
    /// words are never touched. Words in a phrase must be separated by spaces/tabs only (a line
    /// break or punctuation ends a phrase). At each position a command-target phrase wins (gap #12),
    /// then the longest phrase; replaced text is never matched again, so another entry cannot
    /// rewrite words inside an inserted command ("question mark" stays, even with mark -> Marc).
    func apply(to text: String) -> String {
        let table = variantTable()
        guard !table.isEmpty else { return text }
        let maxWords = table.keys.map { $0.split(separator: " ").count }.max() ?? 1
        let lengths = Array(stride(from: maxWords, through: 1, by: -1))
        let chars = Array(text)
        let words = TermText.tokens(chars)
        var output = ""
        var cursor = 0
        var i = 0
        while i < words.count {
            let spans = lengths.filter { $0 <= words.count - i }.compactMap { length -> (Int, DictionaryEntry)? in
                let span = words[i..<(i + length)]
                guard Self.spacedPhrase(span, chars), let entry = table[span.map(\.folded).joined(separator: " ")] else { return nil }
                return (length, entry)
            }
            guard let (length, entry) = spans.first(where: { Self.isCommandTarget($0.1) }) ?? spans.first else { i += 1; continue }
            let start = words[i].start, end = words[i + length - 1].end
            output += String(chars[cursor..<start])
            output += Self.isCommandTarget(entry) ? entry.preferred
                : Self.cased(entry.preferred, original: String(chars[start..<end]), sentenceStart: Self.atSentenceStart(start, chars))
            cursor = end
            i += length
        }
        output += String(chars[cursor...])
        return output
    }

    static let maxNearMatches = 10

    /// Enabled preferred spellings for transcription biasing, manual entries first, commas removed
    /// (callers join with ", "). Unlike `relevantEntries`, this is the whole enabled dictionary,
    /// because nothing can be filtered before a transcript exists.
    var vocabularyTerms: [String] {
        var seen = Set<String>()
        let enabled = entries.filter { $0.enabled && !Self.isCommandTarget($0) }
        return (enabled.filter { $0.source == .manual } + enabled.filter { $0.source == .learned }).compactMap { entry in
            let term = TermText.collapseWhitespace(entry.preferred.replacingOccurrences(of: ",", with: " "))
            return seen.insert(TermText.fold(term)).inserted ? term : nil
        }
    }

    /// Entries a cloud stage may receive for this text: enabled entries whose preferred spelling
    /// or a variant occurs in the text as whole words, then up to `maxNearMatches` entries whose
    /// preferred spelling sounds like a 1–3 word span of the text (the learning filter's
    /// similarity rules), so a misheard term can still be corrected by cleanup. Never the whole
    /// dictionary. `apply(to:)` stays exact; only the cleanup hint uses near matches.
    func relevantEntries(for text: String) -> [DictionaryEntry] {
        let exact = exactEntries(for: text).filter { !Self.isCommandTarget($0) }
        let exactIDs = Set(exact.map(\.id))
        let candidates = entries.filter { $0.enabled && !exactIDs.contains($0.id) && !Self.isCommandTarget($0) }
        guard !candidates.isEmpty else { return exact }
        let chars = Array(text)
        let words = TermText.tokens(chars)
        var spans = Set<String>()
        for i in words.indices {
            for length in 1...min(CorrectionFilter.maxWords, words.count - i) {
                let span = words[i..<(i + length)]
                guard Self.spacedPhrase(span, chars) else { break }
                spans.insert(CorrectionFilter.letters(span.map(\.text).joined()))
            }
        }
        var near: [DictionaryEntry] = []
        for entry in candidates where near.count < Self.maxNearMatches {
            let target = CorrectionFilter.letters(entry.preferred)
            if spans.contains(where: { Self.soundsLike($0, target) }) { near.append(entry) }
        }
        return exact + near
    }

    /// The learning filter's respelling test on letters only: at least 4 letters each, and either
    /// matching phonetic keys with similarity >= 0.5, or similarity >= 0.75 for terms of 6+ letters.
    static func soundsLike(_ heard: String, _ term: String) -> Bool {
        guard heard.count >= CorrectionFilter.minLetters, term.count >= CorrectionFilter.minLetters,
              Double(min(heard.count, term.count)) >= Double(max(heard.count, term.count)) * CorrectionFilter.phoneticSimilarity
        else { return false }
        let similarity = CorrectionFilter.similarity(heard, term)
        // Edit similarity alone is too loose for short terms ("mean" is 0.75 from "Sean").
        if similarity >= CorrectionFilter.directSimilarity && term.count >= 6 { return true }
        return similarity >= CorrectionFilter.phoneticSimilarity && CorrectionFilter.phoneticKey(heard) == CorrectionFilter.phoneticKey(term)
    }

    private func exactEntries(for text: String) -> [DictionaryEntry] {
        let chars = Array(text)
        let words = TermText.tokens(chars)
        var present = Set<String>()
        let phrases = entries.filter(\.enabled).flatMap { [$0.preferred] + $0.variants }
        let maxWords = phrases.compactMap { TermText.phraseKey($0)?.split(separator: " ").count }.max() ?? 0
        for i in words.indices {
            for length in 1...max(1, min(maxWords, words.count - i)) where i + length <= words.count {
                let span = words[i..<(i + length)]
                guard Self.spacedPhrase(span, chars) else { break }
                present.insert(span.map(\.folded).joined(separator: " "))
            }
        }
        return entries.filter { entry in
            entry.enabled && ([entry.preferred] + entry.variants).contains { phrase in
                guard let key = TermText.phraseKey(phrase) ?? Self.wordKey(phrase) else { return false }
                return present.contains(key)
            }
        }
    }

    /// Key for a preferred spelling that contains punctuation ("Node.js" -> "node js").
    private static func wordKey(_ phrase: String) -> String? {
        let words = TermText.tokens(phrase)
        return words.isEmpty ? nil : words.map(\.folded).joined(separator: " ")
    }

    private static func spacedPhrase(_ span: ArraySlice<TermText.Token>, _ chars: [Character]) -> Bool {
        var previous: TermText.Token?
        for token in span {
            if let previous {
                let gap = chars[previous.end..<token.start]
                guard !gap.isEmpty, gap.allSatisfy({ $0 == " " || $0 == "\t" }) else { return false }
            }
            previous = token
        }
        return true
    }

    private static func atSentenceStart(_ index: Int, _ chars: [Character]) -> Bool {
        var j = index - 1
        while j >= 0 {
            let c = chars[j]
            if c.isNewline { return true }
            if c.isWhitespace || "\"'“‘([{".contains(c) { j -= 1; continue }
            return ".!?".contains(c)
        }
        return true
    }

    private static func cased(_ preferred: String, original: String, sentenceStart: Bool) -> String {
        guard sentenceStart, original.first?.isUppercase == true,
              !preferred.contains(where: { $0.isUppercase }), let first = preferred.first else { return preferred }
        return first.uppercased() + preferred.dropFirst()
    }
}
