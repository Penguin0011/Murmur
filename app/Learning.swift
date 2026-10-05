import Foundation

// Correction ledger: provisional evidence from attributed post-insertion edits, a conservative
// candidate filter, and promotion of consistent mappings into learned dictionary entries.
// Stores only short source/target strings, never surrounding document text.

/// One attributed replacement from the observation layer (spike `DictationObservation`).
struct ObservedCorrection: Codable, Equatable {
    let sessionID: UUID
    let source: String
    let target: String
    let observedAt: Date
}

enum CandidateRejection: String, Codable, Error {
    case empty, identical, caseOnly, punctuationOnly, unsupportedCharacters, tooManyWords
    case deletion, insertion, negation, number, antonym, contextualWord, tooShort, inflection, ordinaryWords, notRespelling
}

enum CandidateVerdict: Equatable {
    /// The reduced replacement (shared leading/trailing words removed), original casing kept.
    case accepted(source: String, target: String)
    case rejected(CandidateRejection)
}

/// Proposed semantic promotion rule (pending user approval; see PRD Milestone 1 decisions).
///
/// A replacement is a learning candidate only when the target is a plausible respelling of the
/// source, i.e. the kind of error a transcriber makes on a name or term, not a change in meaning:
///
/// 1. Structure: after removing shared leading/trailing words, both sides hold 1...3 words made of
///    letters/digits (apostrophe/hyphen inside words only). Case-only and punctuation/spacing-only
///    changes, deletions, insertions/appends and longer rewrites are rejected.
/// 2. Meaning guards (reject): a negation word or negating prefix differs (not, never, n't, un-,
///    dis-, ...); either side contains a digit or a number word; the pair is a listed antonym;
///    either side contains a common function word or a listed homophone (their/there, to/too,
///    affect/effect, accept/except ...) because those corrections depend on context; an
///    inflection-only change (report/reports, walk/walked) or a vowel-only change in a short word
///    (ran/run, sing/sang). Optional lexicon guard: when an `isCommonWord` lookup is supplied
///    (e.g. NSSpellChecker on macOS), reject when every word on both sides is an ordinary word,
///    since swapping one real word for another (casual/causal, lunch/launch) is usually a
///    meaning edit, not a transcription respelling. Acme -> Akme passes because "Akme" is not.
/// 3. Respelling: both sides have at least 4 letters, and either the normalized edit similarity
///    is >= 0.75, or the consonant-class phonetic keys are equal and similarity is >= 0.5.
///    (Acme -> Akme: similarity 0.75, passes. accept -> decline: antonym and dissimilar, fails.)
/// 4. Known term: when the target is already the preferred spelling of an enabled manual entry,
///    rule 3 is waived (rules 1 and 2, including the lexicon guard, still apply).
///
/// When unsure, skip: every rejection drops the observation without asking the user.
enum CorrectionFilter {
    static let maxWords = 3
    static let minLetters = 4
    /// With a lexicon, short names and acronyms (Jon -> John, sequel -> SQL) are allowed.
    static let minLettersWithLexicon = 2
    static let directSimilarity = 0.75
    static let phoneticSimilarity = 0.5

    static let negations: Set<String> = [
        "not", "no", "never", "none", "nobody", "nothing", "nowhere", "neither", "nor", "without",
        "cannot", "can't", "won't", "don't", "doesn't", "didn't", "isn't", "aren't", "wasn't",
        "weren't", "shouldn't", "wouldn't", "couldn't", "mustn't", "haven't", "hasn't", "hadn't", "ain't",
    ]
    static let negatingPrefixes = ["un", "in", "im", "il", "ir", "dis", "non", "non-", "mis", "anti", "anti-"]

    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "trillion", "dozen", "half", "quarter",
        "first", "second", "third", "fourth", "fifth", "once", "twice", "single", "double", "triple",
    ]

    static let antonyms: [(String, String)] = [
        ("accept", "decline"), ("accept", "reject"), ("accept", "refuse"), ("approve", "deny"),
        ("approve", "reject"), ("allow", "block"), ("allow", "deny"), ("yes", "no"), ("true", "false"),
        ("open", "close"), ("open", "closed"), ("start", "stop"), ("start", "end"), ("begin", "end"),
        ("increase", "decrease"), ("enable", "disable"), ("include", "exclude"), ("add", "remove"),
        ("always", "never"), ("before", "after"), ("more", "less"), ("most", "least"), ("up", "down"),
        ("left", "right"), ("buy", "sell"), ("win", "lose"), ("push", "pull"), ("hot", "cold"),
        ("high", "low"), ("minimum", "maximum"), ("min", "max"), ("inside", "outside"),
        ("import", "export"), ("input", "output"), ("arrive", "depart"), ("send", "receive"),
        ("confirm", "cancel"), ("pass", "fail"), ("success", "failure"), ("agree", "refuse"),
        ("early", "late"), ("earlier", "later"), ("above", "below"), ("over", "under"),
        ("first", "last"), ("love", "hate"), ("like", "dislike"), ("good", "bad"), ("better", "worse"),
        ("best", "worst"), ("happy", "sad"), ("easy", "hard"), ("safe", "unsafe"), ("legal", "illegal"),
        ("public", "private"), ("present", "absent"), ("online", "offline"), ("on", "off"), ("in", "out"),
    ]
    private static let antonymSet: Set<String> = Set(antonyms.flatMap { ["\($0.0)|\($0.1)", "\($0.1)|\($0.0)"] })

    /// Context-dependent words: never learned as a global substitution.
    static let contextualWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "of", "off", "to", "too", "two", "for", "four", "fore",
        "from", "form", "in", "on", "at", "by", "buy", "bye", "with", "is", "are", "was", "were", "be",
        "been", "being", "am", "it", "its", "it's", "their", "there", "they're", "your", "you're", "then",
        "than", "here", "hear", "where", "wear", "we're", "know", "no", "now", "new", "knew", "write",
        "right", "rite", "whether", "weather", "affect", "effect", "accept", "except", "lose", "loose",
        "quiet", "quite", "advice", "advise", "principal", "principle", "stationary", "stationery",
        "compliment", "complement", "who's", "whose", "see", "sea", "would", "wood", "peace", "piece",
        "break", "brake", "our", "hour", "i", "me", "my", "mine", "we", "us", "he", "she", "him", "her",
        "his", "hers", "they", "them", "this", "that", "these", "those", "will", "shall", "can", "could",
        "should", "may", "might", "must", "do", "does", "did", "has", "have", "had", "which", "witch",
        "weak", "week", "wait", "weight", "meet", "meat", "mail", "male", "sale", "sail", "plain",
        "plane", "pair", "pear", "pare", "flour", "flower", "allowed", "aloud", "led", "lead", "past",
        "passed", "threw", "through", "thru", "whole", "hole", "one", "won", "son", "sun", "ad", "add",
        "sent", "cent", "scent", "site", "sight", "cite", "die", "dye", "fair", "fare", "dear", "deer",
        "bare", "bear", "hi", "high", "made", "maid", "tail", "tale", "waist", "waste", "way", "weigh",
        "role", "roll", "rain", "reign", "rein", "steal", "steel", "suite", "sweet", "ware", "where's",
        "lie", "lay", "farther", "further", "fewer", "less", "who", "whom", "what",
        "when", "why", "how", "yes", "not", "so", "sew", "sow", "very", "vary",
    ]

    private static let inflectionSuffixes = ["s", "es", "ed", "d", "ing", "er", "ers", "est", "ly", "'s", "s'", "ies", "ied"]

    /// `isCommonWord` receives one folded word and returns true for an ordinary dictionary word.
    static func evaluate(source: String, target: String, manualPreferred: Set<String> = [],
                         isCommonWord: ((String) -> Bool)? = nil) -> CandidateVerdict {
        let s = TermText.collapseWhitespace(source)
        let t = TermText.collapseWhitespace(target)
        if s.isEmpty && t.isEmpty { return .rejected(.empty) }
        if t.isEmpty { return .rejected(.deletion) }
        if s.isEmpty { return .rejected(.insertion) }
        if s == t { return .rejected(.identical) }
        // Case (jira -> Jira), spacing (git hub -> GitHub) and short-word (Jon -> John) fixes are
        // learned only when the lexicon can tell names and terms from ordinary words.
        let caseOnly = TermText.fold(s) == TermText.fold(t)
        if caseOnly, isCommonWord == nil { return .rejected(.caseOnly) }
        let spacing = !caseOnly && letters(TermText.fold(s)) == letters(TermText.fold(t))
        if spacing, isCommonWord == nil || TermText.tokens(s).count == TermText.tokens(t).count { return .rejected(.punctuationOnly) }

        var sw = TermText.tokens(s), tw = TermText.tokens(t)
        if sw.isEmpty { return .rejected(.insertion) }
        if tw.isEmpty { return .rejected(.deletion) }
        guard wordsOnly(s, sw), wordsOnly(t, tw) else { return .rejected(.unsupportedCharacters) }

        // Shared surrounding words are context, not part of the replacement.
        func same(_ a: TermText.Token, _ b: TermText.Token) -> Bool { caseOnly ? a.text == b.text : a.folded == b.folded }
        while let a = sw.first, let b = tw.first, same(a, b) { sw.removeFirst(); tw.removeFirst() }
        while let a = sw.last, let b = tw.last, same(a, b) { sw.removeLast(); tw.removeLast() }
        if tw.isEmpty { return .rejected(.deletion) }
        if sw.isEmpty { return .rejected(.insertion) }
        guard sw.count <= maxWords, tw.count <= maxWords else { return .rejected(.tooManyWords) }

        let sf = sw.map(\.folded), tf = tw.map(\.folded)
        if isSubsequence(tf, of: sf) { return .rejected(.deletion) }
        if isSubsequence(sf, of: tf) { return .rejected(.insertion) }
        if negationFlip(sf, tf) { return .rejected(.negation) }
        if (sf + tf).contains(where: { $0.contains(where: \.isNumber) || numberWords.contains($0) }) {
            return .rejected(.number)
        }
        for a in sf { for b in tf where antonymSet.contains("\(a)|\(b)") { return .rejected(.antonym) } }
        // Spelled-out letters ("a p i" -> API) are not the function words they look like.
        if (spacing ? tf : sf + tf).contains(where: { contextualWords.contains($0) }) { return .rejected(.contextualWord) }

        let sLetters = letters(sf.joined()), tLetters = letters(tf.joined())
        let floor = isCommonWord == nil ? minLetters : minLettersWithLexicon
        guard sLetters.count >= floor, tLetters.count >= floor else { return .rejected(.tooShort) }
        if !caseOnly, sf.count == 1, tf.count == 1, inflectionOnly(sf[0], tf[0]) { return .rejected(.inflection) }

        let reduced = CandidateVerdict.accepted(source: sw.map(\.text).joined(separator: " "),
                                                target: tw.map(\.text).joined(separator: " "))
        // An all-capitals target (API, SQL, JSON) is a deliberate acronym, not an ordinary word.
        let acronym = tw.allSatisfy { $0.text.count >= 2 && $0.text.allSatisfy { !$0.isLetter || $0.isUppercase } }
        if let isCommonWord, !acronym, (sf + tf).allSatisfy(isCommonWord) { return .rejected(.ordinaryWords) }
        if manualPreferred.contains(tf.joined(separator: " ")) { return reduced }
        let similarity = self.similarity(sLetters, tLetters)
        if similarity >= directSimilarity { return reduced }
        if similarity >= phoneticSimilarity, phoneticKey(sLetters) == phoneticKey(tLetters) { return reduced }
        return .rejected(.notRespelling)
    }

    struct Change: Equatable {
        /// The original words, as dictated.
        let source: String
        /// Readings of the new words, tried in order. Usually one; a run at the end of the span
        /// that grew may be a fix followed by more typing, so its first 1...3 words come first.
        let targets: [String]
    }

    /// The replaced word runs from `original` to `current`, aligned by longest common
    /// subsequence of words (case-sensitive, so jira -> Jira is a change) (the helper's BoostFilter aligns the same way, in another
    /// target). Words added after the span, or anywhere with nothing replaced, are ignored, so a
    /// fix followed by more typing still counts, and two fixes in one dictation are two changes.
    /// Fails for an edit that deletes words, or replaces more than half of a long span (a rewrite).
    static func replacements(_ original: String, _ current: String) -> Result<[Change], CandidateRejection> {
        let a = TermText.tokens(original), b = TermText.tokens(current)
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i].text == b[j].text ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var changes: [Change] = []
        var replaced = 0
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i].text == b[j].text { i += 1; j += 1; continue }
            let i0 = i, j0 = j
            while (i < a.count || j < b.count) && !(i < a.count && j < b.count && a[i].text == b[j].text) {
                if j < b.count && (i == a.count || dp[i][j + 1] >= dp[i + 1][j]) { j += 1 } else { i += 1 }
            }
            if i == i0 { continue }                      // words added: not a correction
            if j == j0 { return .failure(.deletion) }
            replaced += i - i0
            let words = b[j0..<j].map(\.text)
            let whole = words.joined(separator: " ")
            let targets = i == a.count && words.count > i - i0
                ? (1..<words.count).prefix(maxWords).map { words.prefix($0).joined(separator: " ") } + [whole]
                : [whole]
            changes.append(Change(source: a[i0..<i].map(\.text).joined(separator: " "), targets: targets))
        }
        // ponytail: half-the-span rewrite cut-off is a guess; tune with real correction logs.
        if replaced > max(maxWords, a.count / 2) { return .failure(.tooManyWords) }
        if !changes.isEmpty { return .success(changes) }
        if b.count > a.count { return .failure(.insertion) }
        // Same words: name the case, punctuation or spacing change.
        if case .rejected(let reason) = evaluate(source: original, target: current) { return .failure(reason) }
        return .failure(.identical)
    }

    /// Of `candidates` (what a span might now read, when the caret position is unknown), the one
    /// reading whose every replaced run is an accepted respelling of the original, preferring the
    /// reading that changes the fewest words (a retyped word over one merged with its neighbour).
    /// Readings that imply the same fix (one of several identical words retyped) count as one.
    /// Nil when none, or several equally small but different fixes, qualify.
    static func plausibleEdit(original: String, candidates: [String], isCommonWord: ((String) -> Bool)? = nil) -> String? {
        func accepted(_ changes: [Change], _ lexicon: ((String) -> Bool)?) -> Bool {
            changes.allSatisfy { change in
                if case .accepted = evaluate(source: change.source, target: change.targets.last!, isCommonWord: lexicon) { return true }
                return false
            }
        }
        // The spell checker is slow, so it only sees readings that pass every other rule.
        var passing: [(cost: Int, reading: String, changes: [Change])] = []
        let a = Array(original)
        for candidate in Set(candidates) where candidate != original {
            // Each guess differs only around its caret: diff just that stretch, widened to whole words.
            let b = Array(candidate)
            var start = 0, tail = 0
            while start < min(a.count, b.count), a[start] == b[start] { start += 1 }
            while tail < min(a.count, b.count) - start, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
            while start > 0, TermText.isCore(a[start - 1]) || TermText.isJoiner(a[start - 1]) { start -= 1 }
            while tail > 0, TermText.isCore(a[a.count - tail]) || TermText.isJoiner(a[a.count - tail]) { tail -= 1 }
            guard case .success(let changes) = replacements(String(a[start..<(a.count - tail)]), String(b[start..<(b.count - tail)])),
                  accepted(changes, nil) else { continue }
            passing.append((changes.reduce(0) { $0 + max(TermText.tokens($1.source).count, TermText.tokens($1.targets.last!).count) }, candidate, changes))
        }
        var best: (cost: Int, fix: [Change], reading: String?)?
        for item in passing.sorted(by: { ($0.cost, $0.reading) < ($1.cost, $1.reading) }) {
            if let best, item.cost > best.cost { break }
            guard isCommonWord == nil || accepted(item.changes, isCommonWord) else { continue }
            if best == nil { best = (item.cost, item.changes, item.reading) }
            else if best!.fix != item.changes { best!.reading = nil }
        }
        return best?.reading
    }

    /// Lowercased letters and digits only.
    static func letters(_ text: String) -> String { String(text.filter(TermText.isCore)).lowercased() }

    /// 1 - Levenshtein distance / longer length, over Characters.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var previous = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in stride(from: 1, through: y.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        let distance = x.isEmpty ? y.count : previous[y.count]
        return 1 - Double(distance) / Double(max(x.count, y.count))
    }

    /// Soundex-style consonant classes over the whole word (no truncation), with c/k/q/s/z in one
    /// class so Acme/Akme and Kubernetes/Coopernetties share a key. Vowels only separate repeats;
    /// a leading vowel is marked "V".
    static func phoneticKey(_ word: String) -> String {
        let text = letters(word).replacingOccurrences(of: "ph", with: "f")
        func code(_ c: Character) -> Character {
            switch c {
            case "b", "f", "p", "v": return "1"
            case "c", "g", "j", "k", "q", "s", "x", "z": return "2"
            case "d", "t": return "3"
            case "l": return "4"
            case "m", "n": return "5"
            case "r": return "6"
            default: return "0"
            }
        }
        var key = ""
        var last: Character = " "
        for (index, c) in text.enumerated() {
            let value = code(c)
            if index == 0 && value == "0" { key.append("V") }
            if value != last && value != "0" { key.append(value) }
            last = value
        }
        return key
    }

    private static func wordsOnly(_ text: String, _ words: [TermText.Token]) -> Bool {
        words.map(\.folded).joined(separator: " ") == TermText.fold(text)
    }

    private static func isSubsequence(_ needle: [String], of haystack: [String]) -> Bool {
        guard needle.count < haystack.count else { return false }
        var i = 0
        for word in haystack where i < needle.count && word == needle[i] { i += 1 }
        return i == needle.count
    }

    private static func negationFlip(_ a: [String], _ b: [String]) -> Bool {
        func negated(_ words: [String]) -> Set<String> {
            Set(words.filter { negations.contains($0) || $0.hasSuffix("n't") })
        }
        if negated(a) != negated(b) { return true }
        for x in a {
            for y in b {
                for prefix in negatingPrefixes where y == prefix + x || x == prefix + y { return true }
            }
        }
        return false
    }

    private static func inflectionOnly(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if long.hasPrefix(short), inflectionSuffixes.contains(String(long.dropFirst(short.count))) { return true }
        // y -> ies/ied (party/parties)
        if short.hasSuffix("y"), long.hasPrefix(short.dropLast()),
           ["ies", "ied"].contains(String(long.dropFirst(short.count - 1))) { return true }
        // A vowel-only change in a short word is usually tense/number (ran/run), not a respelling.
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        if a.count <= 5, b.count <= 5, a.count == b.count,
           a.filter({ !vowels.contains($0) }) == b.filter({ !vowels.contains($0) }) { return true }
        return false
    }
}

/// Persists `ledger.json` in `directory`. Lifecycle per dictation session:
/// `record` (provisional, replaces that session's earlier evidence) while the observation window
/// is open, then `settle` when it closes; `revert` removes the session's evidence at any time
/// (and withdraws a promotion it supported). Learning has two tiers (user decision, October 4, 2026):
/// one settled fix adds the target as a vocabulary hint (a learned entry with no variants, so
/// transcription is biased toward it but no text is replaced); a second consistent fix from another
/// session adds the source as a variant of that same entry, so it is replaced from then on.
/// A conflicting settled target suppresses the source until `reset()`. A learned entry the user
/// deletes is tombstoned with its evidence cleared, and a tombstoned target is never learned again
/// from any source; `reset()` clears tombstones.
final class CorrectionLedger {
    static let fileName = "ledger.json"
    static let requiredSessions = 2

    enum RecordOutcome: Equatable {
        case learningDisabled, sessionClosed, provisional, suppressed, tombstoned
        case rejected(CandidateRejection)
    }

    /// Folded source and target, except that a case-only fix keeps the target's casing
    /// (jira -> Jira), since folding would make it identical to its source.
    struct Pair: Codable, Hashable {
        let source: String
        let target: String
        init(source: String, target: String) { self.source = source; self.target = target }
        init(of source: String, _ target: String) {
            self.source = TermText.fold(source)
            self.target = TermText.fold(target) == self.source ? target : TermText.fold(target)
        }
        /// The target as other keys see it (preferred spellings and tombstones compare folded).
        var folded: String { TermText.fold(target) }
    }

    private struct Evidence: Codable {
        var correction: ObservedCorrection
        var settled: Bool
        var pair: Pair { Pair(of: correction.source, correction.target) }
    }

    private struct Promotion: Codable {
        enum Kind: String, Codable { case hint, variant }
        let entryID: UUID
        let pair: Pair
        let sessions: [UUID]
        /// nil: created the entry with `pair.source` as its variant (also every version-1 promotion
        /// written before tiers). `.hint`: created the entry with no variant. `.variant`: added
        /// `pair.source` to an entry another promotion created.
        var kind: Kind?
        var replaces: Bool { kind != .hint }
    }

    private struct State: Codable {
        var version = 1
        var learningEnabled = true
        var evidence: [Evidence] = []
        var suppressed: Set<String> = []
        var tombstones: Set<Pair> = []
        var promotions: [Promotion] = []
    }

    let directory: URL
    let dictionary: DictionaryStore
    /// Optional lexicon for the ordinary-words guard (see `CorrectionFilter`). Not persisted.
    /// On macOS: `{ NSSpellChecker.shared.checkSpelling(of: $0, startingAt: 0).location == NSNotFound }`.
    var isCommonWord: ((String) -> Bool)?
    private var state = State()
    private var file: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL, dictionary: DictionaryStore) throws {
        self.directory = directory
        self.dictionary = dictionary
        try reload()
    }

    func reload() throws {
        try PrivateFiles.prepareDirectory(directory)
        guard let data = try PrivateFiles.read(file) else { state = State(); return }
        let decoded = try JSONDecoder().decode(State.self, from: data)
        guard decoded.version == 1 else { throw DictionaryError("Unsupported ledger version") }
        state = decoded
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try PrivateFiles.write(try encoder.encode(state), to: file)
    }

    // MARK: Inspection

    var learningEnabled: Bool { state.learningEnabled }
    var evidence: [ObservedCorrection] { state.evidence.map(\.correction) }
    var provisionalSessions: Set<UUID> { Set(state.evidence.filter { !$0.settled }.map(\.correction.sessionID)) }
    var suppressedSources: Set<String> { state.suppressed }
    var tombstones: Set<Pair> { state.tombstones }

    // MARK: Controls

    /// Off records nothing and drops in-flight provisional evidence. Existing learned entries keep
    /// applying until the user deletes or resets them.
    func setLearningEnabled(_ enabled: Bool) throws {
        state.learningEnabled = enabled
        if !enabled { state.evidence.removeAll { !$0.settled } }
        try save()
    }

    /// Feed the latest attributed replacement for a session while its window is open.
    @discardableResult
    func record(_ observed: ObservedCorrection) throws -> RecordOutcome {
        guard state.learningEnabled else { return .learningDisabled }
        try reconcile()
        let session = observed.sessionID
        if state.evidence.contains(where: { $0.correction.sessionID == session && $0.settled }) { return .sessionClosed }
        state.evidence.removeAll { $0.correction.sessionID == session }
        var outcome: RecordOutcome?
        var rejection = CandidateRejection.identical
        switch CorrectionFilter.replacements(observed.source, observed.target) {
        case .failure(let reason):
            rejection = reason
        case .success(let changes):
            for change in changes {
                // A run that grew past the end of the span may hold the fix plus typing after it:
                // the shortest accepted reading wins.
                var verdict = CandidateVerdict.rejected(.notRespelling)
                for target in change.targets {
                    verdict = CorrectionFilter.evaluate(source: change.source, target: target,
                                                        manualPreferred: manualPreferredKeys(), isCommonWord: isCommonWord)
                    if case .accepted = verdict { break }
                }
                switch verdict {
                case .rejected(let reason):
                    if outcome == nil, rejection == .identical { rejection = reason }
                case .accepted(let source, let target):
                    let pair = Pair(of: source, target)
                    if state.tombstones.contains(where: { $0.folded == pair.folded }) { if outcome == nil { outcome = .tombstoned } }
                    else if state.suppressed.contains(pair.source) { if outcome == nil { outcome = .suppressed } }
                    else {
                        let reduced = ObservedCorrection(sessionID: session, source: source, target: target, observedAt: observed.observedAt)
                        state.evidence.append(Evidence(correction: reduced, settled: false))
                        outcome = .provisional
                    }
                }
            }
        }
        try save()
        return outcome ?? .rejected(rejection)
    }

    /// The session's observation window closed: commit its evidence and promote if consistent.
    /// Returns entries newly added to the dictionary (a variant added to an existing entry is not).
    @discardableResult
    func settle(sessionID: UUID) throws -> [DictionaryEntry] {
        try reconcile()
        guard state.learningEnabled else {
            state.evidence.removeAll { $0.correction.sessionID == sessionID && !$0.settled }
            try save()
            return []
        }
        var pairs: [Pair] = []
        for index in state.evidence.indices where state.evidence[index].correction.sessionID == sessionID && !state.evidence[index].settled {
            state.evidence[index].settled = true
            if !pairs.contains(state.evidence[index].pair) { pairs.append(state.evidence[index].pair) }
        }
        guard !pairs.isEmpty else { return [] }
        var promoted: [DictionaryEntry] = []

        for pair in pairs {
            if let reversed = state.promotions.first(where: { $0.pair != pair && $0.pair.source == pair.folded && $0.pair.folded == pair.source }) {
                // The user changed a learned replacement back: withdraw it and never re-learn it.
                withdraw(reversed, tombstone: true)
                state.suppressed.insert(pair.source)
                state.evidence.removeAll { $0.correction.sessionID == sessionID && $0.pair == pair }
            } else {
                let settled = state.evidence.filter { $0.settled && $0.pair.source == pair.source }
                let targets = Set(settled.map(\.pair.target))
                    .union(state.promotions.filter { $0.pair.source == pair.source }.map(\.pair.target))
                if targets.count > 1 {
                    state.suppressed.insert(pair.source)
                    state.evidence.removeAll { $0.pair.source == pair.source }
                    for promotion in state.promotions where promotion.pair.source == pair.source { withdraw(promotion, tombstone: false) }
                } else if !state.promotions.contains(where: { $0.pair == pair && $0.replaces }),
                          let latest = settled.max(by: { $0.correction.observedAt < $1.correction.observedAt }) {
                    let sessions = Array(Set(settled.map(\.correction.sessionID)))
                    if let existing = dictionary.entry(forVariant: latest.correction.source) {
                        // A manual or other entry already owns this form; consume matching evidence only.
                        if TermText.fold(existing.preferred) == pair.folded {
                            state.evidence.removeAll { $0.pair.source == pair.source }
                        }
                    } else if sessions.count >= Self.requiredSessions {
                        // Second consistent fix: the misheard form is replaced from now on, as another
                        // variant of the learned entry for this spelling when there is one.
                        if var owner = dictionary.entries.first(where: { $0.source == .learned && TermText.fold($0.preferred) == pair.folded }) {
                            owner.variants.append(latest.correction.source)
                            try dictionary.update(owner)
                            state.promotions.append(Promotion(entryID: owner.id, pair: pair, sessions: sessions, kind: .variant))
                        } else {
                            let entry = try dictionary.add(preferred: latest.correction.target,
                                                           variants: [latest.correction.source], source: .learned)
                            state.promotions.append(Promotion(entryID: entry.id, pair: pair, sessions: sessions))
                            promoted.append(entry)
                        }
                        // Evidence is consumed; the promotion keeps only session IDs for revert.
                        state.evidence.removeAll { $0.pair.source == pair.source }
                    } else if !dictionary.entries.contains(where: { TermText.fold($0.preferred) == pair.folded }) {
                        // First fix: a vocabulary hint only. Evidence stays for the second tier.
                        let entry = try dictionary.add(preferred: latest.correction.target, variants: [], source: .learned)
                        state.promotions.append(Promotion(entryID: entry.id, pair: pair, sessions: sessions, kind: .hint))
                        promoted.append(entry)
                    }
                }
            }
        }
        try save()
        return promoted
    }

    /// Undo/reversion: removes the session's evidence. If a promotion relied on this session, its
    /// learned entry is withdrawn (not tombstoned; fresh evidence may promote it again).
    func revert(sessionID: UUID) throws {
        try reconcile()
        state.evidence.removeAll { $0.correction.sessionID == sessionID }
        for promotion in state.promotions where promotion.sessions.contains(sessionID) { withdraw(promotion, tombstone: false) }
        try save()
    }

    /// Delete a learned entry: it stops applying and is tombstoned so old evidence cannot
    /// re-promote it. Deleting through `DictionaryStore.delete` directly has the same effect at
    /// the ledger's next operation (see `reconcile`).
    func deleteLearned(id: UUID) throws {
        guard let entry = dictionary.entries.first(where: { $0.id == id }), entry.source == .learned else {
            throw DictionaryError("Not a learned entry")
        }
        try dictionary.delete(id: id)
        try reconcile()
        // Learned entries without a ledger promotion (e.g. ledger file lost) still get tombstones.
        for variant in entry.variants {
            state.tombstones.insert(Pair(source: TermText.fold(variant), target: TermText.fold(entry.preferred)))
            state.evidence.removeAll { $0.pair.source == TermText.fold(variant) }
        }
        try save()
    }

    /// Forget all evidence, suppressions and tombstones, and remove all learned entries.
    /// Manual entries and the learning toggle are kept.
    func reset() throws {
        let enabled = state.learningEnabled
        state = State()
        state.learningEnabled = enabled
        try dictionary.resetLearned()
        try save()
    }

    /// A learned entry missing from the dictionary was deleted by the user: tombstone its mapping.
    func reconcile() throws {
        var changed = false
        for promotion in state.promotions where !dictionary.entries.contains(where: { $0.id == promotion.entryID }) {
            forget(promotion, tombstone: true)
            changed = true
        }
        if changed { try save() }
    }

    /// Undoes what a promotion added: its variant, or its whole entry (and every promotion on it).
    private func withdraw(_ promotion: Promotion, tombstone: Bool) {
        if promotion.kind == .variant {
            if var entry = dictionary.entries.first(where: { $0.id == promotion.entryID }) {
                entry.variants.removeAll { TermText.fold($0) == promotion.pair.source }
                try? dictionary.update(entry)
            }
            forget(promotion, tombstone: tombstone)
        } else {
            try? dictionary.delete(id: promotion.entryID)
            for other in state.promotions where other.entryID == promotion.entryID { forget(other, tombstone: tombstone) }
        }
    }

    private func forget(_ promotion: Promotion, tombstone: Bool) {
        state.promotions.removeAll { $0.entryID == promotion.entryID && $0.pair == promotion.pair }
        if tombstone {
            state.tombstones.insert(promotion.pair)
            state.evidence.removeAll { $0.pair.source == promotion.pair.source }
        }
    }

    private func manualPreferredKeys() -> Set<String> {
        Set(dictionary.entries.filter { $0.enabled && $0.source == .manual }
            .compactMap { entry -> String? in
                let words = TermText.tokens(entry.preferred)
                return words.isEmpty ? nil : words.map(\.folded).joined(separator: " ")
            })
    }
}
