import Foundation

// Deterministic checks for Dictionary.swift, Learning.swift and Retention.swift over a temp directory.
// swiftc app/Dictionary.swift app/Learning.swift app/Retention.swift app/check_dictionary.swift -o /tmp/cd && /tmp/cd

private var failures = 0
private var passes = 0

private func check(_ condition: @autoclosure () throws -> Bool, _ label: String, line: Int = #line) rethrows {
    if try condition() { passes += 1 } else { failures += 1; print("FAIL [line \(line)]: \(label)") }
}

private struct Item: RetainedHistoryItem { let id: String; let recordedAt: Date }

@main struct DictionaryChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-dictionary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try dictionaryChecks(root.appendingPathComponent("dict"))
        try filterChecks()
        try learningChecks(root.appendingPathComponent("learn"))
        try retentionChecks(root.appendingPathComponent("retention"))
        print("\(passes) checks passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func dictionaryChecks(_ dir: URL) throws {
        let store = try DictionaryStore(directory: dir)
        let acme = try store.add(preferred: "Akme", variants: ["Acme", "ack me"])
        try store.add(preferred: "New York City", variants: ["new york city", "nyc"])
        try store.add(preferred: "New Yorker", variants: ["new york"])
        try store.add(preferred: "kubectl", variants: ["cube cuddle"])
        try store.add(preferred: "iPhone", variants: ["i phone"])

        // Word boundaries: never inside other words, hyphenated or possessive forms.
        check(store.apply(to: "Acme and Acmeville") == "Akme and Acmeville", "Acme not inside Acmeville")
        check(store.apply(to: "Acme's plan, Acme-based, MyAcme, acme.") == "Acme's plan, Acme-based, MyAcme, Akme.", "boundaries")
        check(store.apply(to: "call ACME now") == "call Akme now", "case-insensitive match, preferred as stored")
        check(store.apply(to: "please ack me later") == "please Akme later", "multiword variant")
        check(store.apply(to: "ack\nme") == "ack\nme", "line break ends a phrase")
        check(store.apply(to: "ack, me") == "ack, me", "punctuation ends a phrase")
        // Longest match wins.
        check(store.apply(to: "I love new york city.") == "I love New York City.", "longest match")
        check(store.apply(to: "I love new york.") == "I love New Yorker.", "shorter phrase when longer absent")
        // Case policy.
        check(store.apply(to: "Cube cuddle is installed. cube cuddle again") == "Kubectl is installed. kubectl again", "sentence-initial capitalization of lowercase preferred")
        check(store.apply(to: "I phone you. My i phone") == "iPhone you. My iPhone", "mixed-case preferred never altered")
        // No fuzzy matching.
        check(store.apply(to: "Acne and Akmee and acmes") == "Acne and Akmee and acmes", "similar words untouched")
        check(store.apply(to: "café ☕ Acme 🙂") == "café ☕ Akme 🙂", "unicode neighbours")
        check(store.apply(to: "") == "", "empty text")

        // relevantEntries minimality.
        let relevant = store.relevantEntries(for: "Ask Acme about it")
        check(relevant.map(\.id) == [acme.id], "only the matching entry is relevant")
        check(store.relevantEntries(for: "nothing here").isEmpty, "no entries for unrelated text")
        check(store.relevantEntries(for: "Akme already right").map(\.id) == [acme.id], "preferred spelling counts")
        check(store.relevantEntries(for: "Acmeville").isEmpty, "relevance uses word boundaries")
        // Near matches feed the cleanup hint only; apply() never uses them.
        let kube = try store.add(preferred: "Kubernetes", variants: [])
        let cloud = try store.add(preferred: "clouddev", variants: [])
        check(store.relevantEntries(for: "deploy it to coopernetties").map(\.id) == [kube.id], "misheard single word is near")
        check(store.relevantEntries(for: "ship cloud dev today").map(\.id) == [cloud.id], "split words spelling the term are near")
        check(store.apply(to: "deploy it to coopernetties") == "deploy it to coopernetties", "near match never applied")
        check(store.relevantEntries(for: "Can we meet for lunch tomorrow at the office?").isEmpty, "ordinary sentence pulls in no terms")
        var offKube = kube; offKube.enabled = false
        try store.update(offKube)
        check(store.relevantEntries(for: "deploy it to coopernetties").isEmpty, "disabled entry is never near")
        try store.delete(id: kube.id); try store.delete(id: cloud.id)
        check(store.vocabularyTerms == ["Akme", "New York City", "New Yorker", "kubectl", "iPhone"], "vocabulary terms: enabled preferred spellings in order")

        // Validation, edit, disable, delete.
        do { try store.add(preferred: "Other", variants: ["acme"]); check(false, "duplicate variant accepted") } catch { check(true, "") }
        do { try store.add(preferred: "X", variants: ["a,b"]); check(false, "punctuated variant accepted") } catch { check(true, "") }
        var edited = acme
        edited.enabled = false
        try store.update(edited)
        check(store.apply(to: "Acme") == "Acme", "disabled entry not applied")
        check(store.relevantEntries(for: "Acme").isEmpty, "disabled entry not relevant")
        edited.enabled = true
        edited.variants = ["acme corp"]
        try store.update(edited)
        check(store.apply(to: "Acme Corp and Acme") == "Akme and Acme", "edited variants")

        // Persistence and permissions.
        let reloaded = try DictionaryStore(directory: dir)
        check(reloaded.entries == store.entries, "dictionary round-trip")
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("dictionary.json").path)[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o600, "dictionary file is 0600")
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        check(dirMode?.intValue == 0o700, "dictionary directory is 0700")
        try store.delete(id: acme.id)
        check(store.apply(to: "Acme Corp") == "Acme Corp", "deleted entry not applied")

        // resetLearned keeps manual entries.
        try store.add(preferred: "Zylo", variants: ["xylo"], source: .learned)
        let manualCount = store.entries.filter { $0.source == .manual }.count
        let removed = try store.resetLearned()
        check(removed.count == 1 && store.entries.allSatisfy { $0.source == .manual } && store.entries.count == manualCount, "resetLearned removes only learned")
    }

    static func filterChecks() throws {
        func verdict(_ s: String, _ t: String, manual: Set<String> = []) -> CandidateVerdict {
            CorrectionFilter.evaluate(source: s, target: t, manualPreferred: manual)
        }
        check(verdict("Acme", "Akme") == .accepted(source: "Acme", target: "Akme"), "Acme -> Akme accepted")
        check(verdict("I accept", "I decline") == .rejected(.antonym), "accept -> decline rejected")
        check(verdict("accept", "decline") == .rejected(.antonym), "bare accept -> decline rejected")
        check(verdict("Acme", "acme") == .rejected(.caseOnly), "case-only")
        check(verdict("Acme", "Acme!") == .rejected(.punctuationOnly), "punctuation-only")
        check(verdict("e mail", "e-mail") == .rejected(.punctuationOnly), "spacing/hyphen only")
        check(verdict("Acme", "") == .rejected(.deletion), "deletion")
        check(verdict("Acme Corp", "Acme") == .rejected(.deletion), "word deletion")
        check(verdict("Acme", "Acme Corp") == .rejected(.insertion), "append")
        check(verdict("Acme", "big Acme") == .rejected(.insertion), "prefix insertion")
        check(verdict("one two three", "four five six") == .rejected(.number), "number words")
        check(verdict("alpha beta gamma delta", "alpho betta gamme delto") == .rejected(.tooManyWords), "broad rewrite")
        check(verdict("will go", "will not go") == .rejected(.insertion), "inserted negation is an insertion")
        check(verdict("is able", "is unable") == .rejected(.negation), "negating prefix")
        check(verdict("should go", "shouldn't go") == .rejected(.negation), "n't flip")
        check(verdict("Room 12", "Room 21") == .rejected(.number), "digit change")
        check(verdict("seven", "eleven") == .rejected(.number), "number word change")
        check(verdict("there", "their") == .rejected(.contextualWord), "homophone")
        check(verdict("report", "reports") == .rejected(.inflection), "plural")
        check(verdict("walk", "walked") == .rejected(.inflection), "tense")
        check(verdict("sing", "sang") == .rejected(.inflection), "vowel-only short word")
        check(verdict("Jon", "John") == .rejected(.tooShort), "short names skipped")
        check(verdict("table", "chair") == .rejected(.notRespelling), "unrelated words")
        check(verdict("Acme,", "Akme,") == .rejected(.unsupportedCharacters), "punctuation inside candidate")
        check(verdict("Catherine", "Kathryn") == .accepted(source: "Catherine", target: "Kathryn"), "phonetic respelling")
        check(verdict("cooper netties", "Kubernetes") == .accepted(source: "cooper netties", target: "Kubernetes"), "multiword to term")
        check(verdict("the Acme team", "the Akme team") == .accepted(source: "Acme", target: "Akme"), "shared context words trimmed")
        check(verdict("Fred", "Quorbix") == .rejected(.notRespelling), "dissimilar without manual entry")
        check(verdict("Fred", "Quorbix", manual: ["quorbix"]) == .accepted(source: "Fred", target: "Quorbix"), "known manual term waives similarity")
        check(verdict("accept", "decline", manual: ["decline"]) == .rejected(.antonym), "manual term does not waive meaning guards")
        // Optional lexicon guard: real-word swaps are rejected, term respellings still pass.
        let lexicon: Set<String> = ["casual", "causal", "lunch", "launch", "cloud", "acme", "team"]
        let common: (String) -> Bool = { lexicon.contains($0) }
        check(CorrectionFilter.evaluate(source: "casual", target: "causal") == .accepted(source: "casual", target: "causal"), "without lexicon a real-word swap passes (known limit)")
        check(CorrectionFilter.evaluate(source: "casual", target: "causal", isCommonWord: common) == .rejected(.ordinaryWords), "lexicon rejects real-word swap")
        check(CorrectionFilter.evaluate(source: "lunch", target: "launch", isCommonWord: common) == .rejected(.ordinaryWords), "lunch -> launch")
        check(CorrectionFilter.evaluate(source: "Acme", target: "Akme", isCommonWord: common) == .accepted(source: "Acme", target: "Akme"), "lexicon keeps Acme -> Akme")
        check(CorrectionFilter.evaluate(source: "Cloud", target: "Claude", manualPreferred: ["claude"], isCommonWord: { lexicon.contains($0) || $0 == "claude" }) == .rejected(.ordinaryWords), "manual term does not waive lexicon guard")
    }

    static func learningChecks(_ dir: URL) throws {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func obs(_ session: UUID, _ s: String, _ t: String, _ offset: TimeInterval = 0) -> ObservedCorrection {
            ObservedCorrection(sessionID: session, source: s, target: t, observedAt: t0.addingTimeInterval(offset))
        }
        func fresh(_ name: String) throws -> (DictionaryStore, CorrectionLedger) {
            let d = dir.appendingPathComponent(name)
            let dict = try DictionaryStore(directory: d)
            return (dict, try CorrectionLedger(directory: d, dictionary: dict))
        }
        func learned(_ dict: DictionaryStore) -> [DictionaryEntry] { dict.entries.filter { $0.source == .learned } }

        // Once adds a vocabulary hint; twice in separate sessions adds the replacement.
        do {
            let (dict, ledger) = try fresh("promote")
            let a = UUID(), b = UUID()
            try check(ledger.record(obs(a, "Acme", "Akme")) == .provisional, "first observation provisional")
            try check(ledger.settle(sessionID: a).map(\.preferred) == ["Akme"], "one observation adds a hint")
            check(learned(dict).count == 1 && learned(dict)[0].variants.isEmpty, "hint has no variants")
            check(dict.vocabularyTerms == ["Akme"], "hint reaches transcription vocabulary")
            check(dict.apply(to: "Ask Acme today") == "Ask Acme today", "hint replaces nothing")
            try check(ledger.record(obs(b, "acme", "AKME", 10)) == .provisional, "second observation (case differs)")
            let promoted = try ledger.settle(sessionID: b)
            check(promoted.isEmpty && learned(dict).count == 1 && learned(dict)[0].variants == ["acme"], "two sessions add the variant to the hint")
            check(dict.apply(to: "Ask Acme today") == "Ask Akme today", "learned entry applies (first spelling kept)")
            check(ledger.evidence.isEmpty, "evidence consumed on promotion")
            // Ledger file holds only short strings.
            let raw = try String(contentsOf: dir.appendingPathComponent("promote/ledger.json"), encoding: .utf8)
            check(!raw.contains("Ask"), "ledger has no document text")
            let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("promote/ledger.json").path)[.posixPermissions] as? NSNumber
            check(mode?.intValue == 0o600, "ledger file is 0600")
        }

        // Two observations in the same session do not promote.
        do {
            let (dict, ledger) = try fresh("same-session")
            let a = UUID()
            try ledger.record(obs(a, "Acme", "Akme"))
            try ledger.record(obs(a, "Acme", "Akme", 5))
            try ledger.settle(sessionID: a)
            try check(ledger.settle(sessionID: a).isEmpty, "settling twice is harmless")
            try check(ledger.record(obs(a, "Acme", "Akme", 6)) == .sessionClosed, "closed session ignored")
            check(learned(dict).count == 1 && learned(dict)[0].variants.isEmpty && ledger.evidence.count == 1, "same session counts once")
        }

        // accept -> decline never promotes.
        do {
            let (dict, ledger) = try fresh("antonym")
            for i in 0..<3 {
                let s = UUID()
                try check(ledger.record(obs(s, "I accept", "I decline", Double(i))) == .rejected(.antonym), "accept->decline rejected")
                try ledger.settle(sessionID: s)
            }
            check(learned(dict).isEmpty && ledger.evidence.isEmpty, "antonym never stored or promoted")
        }

        // Case-only and punctuation-only never stored.
        do {
            let (_, ledger) = try fresh("case")
            try check(ledger.record(obs(UUID(), "acme", "Acme")) == .rejected(.caseOnly), "case-only rejected")
            try check(ledger.record(obs(UUID(), "Acme", "Acme.")) == .rejected(.punctuationOnly), "punctuation-only rejected")
            check(ledger.evidence.isEmpty, "nothing stored")
        }

        // A conflict suppresses promotion until reset.
        do {
            let (dict, ledger) = try fresh("conflict")
            let a = UUID(), b = UUID(), c = UUID()
            try ledger.record(obs(a, "Acme", "Akme")); try ledger.settle(sessionID: a)
            try ledger.record(obs(b, "Acme", "Acmee")); try ledger.settle(sessionID: b)
            check(ledger.suppressedSources.contains("acme"), "conflict suppresses source")
            try check(ledger.record(obs(c, "Acme", "Akme")) == .suppressed, "suppressed source not recorded")
            try ledger.settle(sessionID: c)
            check(learned(dict).isEmpty, "no promotion while suppressed")
            try ledger.reset()
            check(ledger.suppressedSources.isEmpty, "reset clears suppression")
            let d = UUID(), e = UUID()
            try ledger.record(obs(d, "Acme", "Akme")); try ledger.settle(sessionID: d)
            try ledger.record(obs(e, "Acme", "Akme")); try ledger.settle(sessionID: e)
            check(learned(dict).count == 1, "promotion possible again after reset")
        }

        // Conflict after promotion withdraws the learned entry.
        do {
            let (dict, ledger) = try fresh("late-conflict")
            for target in ["Akme", "Akme", "Acmee"] {
                let s = UUID(); try ledger.record(obs(s, "Acme", target)); try ledger.settle(sessionID: s)
            }
            check(learned(dict).isEmpty && ledger.suppressedSources.contains("acme"), "late conflict demotes and suppresses")
        }

        // Revert removes evidence (provisional or settled) and withdraws dependent promotion.
        do {
            let (dict, ledger) = try fresh("revert")
            let a = UUID(), b = UUID()
            try ledger.record(obs(a, "Acme", "Akme"))
            try ledger.revert(sessionID: a)
            check(ledger.evidence.isEmpty, "revert removes provisional evidence")
            try ledger.settle(sessionID: a)
            try ledger.record(obs(b, "Acme", "Akme")); try ledger.settle(sessionID: b)
            check(learned(dict).allSatisfy(\.variants.isEmpty), "reverted evidence does not count")
            let c = UUID()
            try ledger.record(obs(c, "Acme", "Akme")); try ledger.settle(sessionID: c)
            check(learned(dict).count == 1, "promoted with b and c")
            try ledger.revert(sessionID: c)
            check(learned(dict).count == 1 && learned(dict)[0].variants.isEmpty, "revert after promotion withdraws the variant, b's hint stays")
            check(ledger.tombstones.isEmpty, "revert does not tombstone")
        }

        // Rejected later snapshot replaces earlier provisional evidence for that session.
        do {
            let (_, ledger) = try fresh("replace")
            let a = UUID()
            try ledger.record(obs(a, "Acme", "Akme"))
            try check(ledger.record(obs(a, "Acme", "Acme!")) == .rejected(.punctuationOnly), "rejected snapshot")
            check(ledger.evidence.isEmpty, "rejected snapshot clears session evidence")
        }

        // Deleted learned entry is not re-promoted from old evidence.
        do {
            let (dict, ledger) = try fresh("delete")
            let a = UUID(), b = UUID(), c = UUID()
            try ledger.record(obs(a, "Acme", "Akme")); try ledger.settle(sessionID: a)
            try ledger.record(obs(b, "Acme", "Akme")); try ledger.settle(sessionID: b)
            // Unsettled third observation in flight while the user deletes the entry.
            try ledger.record(obs(c, "Acme", "Akme"))
            let entry = learned(dict)[0]
            try ledger.deleteLearned(id: entry.id)
            check(dict.apply(to: "Acme") == "Acme", "deleted learned entry stops applying")
            try check(ledger.settle(sessionID: c).isEmpty && learned(dict).isEmpty, "not re-promoted from old evidence")
            let d = UUID()
            try check(ledger.record(obs(d, "Acme", "Akme")) == .tombstoned, "tombstoned pair not recorded")
            // Deleting through the dictionary directly is detected too.
            let x = UUID(), y = UUID()
            try ledger.record(obs(x, "Zorblat", "Zorblatt")); try ledger.settle(sessionID: x)
            try ledger.record(obs(y, "Zorblat", "Zorblatt")); try ledger.settle(sessionID: y)
            let zor = learned(dict).first { $0.preferred == "Zorblatt" }
            check(zor != nil, "second learned entry")
            if let zor { try dict.delete(id: zor.id) }
            let z = UUID()
            try check(ledger.record(obs(z, "Zorblat", "Zorblatt")) == .tombstoned, "direct dictionary delete tombstones")
        }

        // User reverting a learned replacement withdraws and tombstones it.
        do {
            let (dict, ledger) = try fresh("reverse")
            for _ in 0..<2 { let s = UUID(); try ledger.record(obs(s, "Acme", "Akme")); try ledger.settle(sessionID: s) }
            check(learned(dict).count == 1, "promoted before reversal")
            let r = UUID()
            try ledger.record(obs(r, "Akme", "Acme")); try ledger.settle(sessionID: r)
            check(learned(dict).isEmpty && ledger.tombstones.contains(.init(source: "acme", target: "akme")), "reversal withdraws and tombstones")
        }

        // Tiers: two mishearings of one spelling share one entry; a deleted word is never re-learned.
        do {
            let (dict, ledger) = try fresh("tiers")
            for source in ["Akash", "Akash", "Aakesh", "Aakesh"] {
                let s = UUID(); try ledger.record(obs(s, source, "Aakash")); try ledger.settle(sessionID: s)
            }
            check(learned(dict).count == 1 && learned(dict)[0].variants == ["Akash", "Aakesh"], "one entry gathers both mishearings")
            try ledger.deleteLearned(id: learned(dict)[0].id)
            let s = UUID()
            try check(ledger.record(obs(s, "Akesh", "Aakash")) == .tombstoned, "deleted word not re-learned from a new mishearing")
        }

        // A version-1 ledger written before tiers (promotion without kind) still withdraws its entry.
        do {
            let d = dir.appendingPathComponent("legacy")
            let dict = try DictionaryStore(directory: d)
            let entry = try dict.add(preferred: "Akme", variants: ["Acme"], source: .learned)
            let legacy = #"{"evidence":[],"learningEnabled":true,"promotions":[{"entryID":"\#(entry.id.uuidString)","pair":{"source":"acme","target":"akme"},"sessions":[]}],"suppressed":[],"tombstones":[],"version":1}"#
            try PrivateFiles.write(Data(legacy.utf8), to: d.appendingPathComponent(CorrectionLedger.fileName))
            let ledger = try CorrectionLedger(directory: d, dictionary: dict)
            let r = UUID(); try ledger.record(obs(r, "Akme", "Acme")); try ledger.settle(sessionID: r)
            check(learned(dict).isEmpty, "legacy promotion decodes and reversal withdraws it")
        }

        // Manual entry already owns the source: no duplicate learned entry.
        do {
            let (dict, ledger) = try fresh("manual")
            try dict.add(preferred: "Akme", variants: ["Acme"])
            for _ in 0..<2 { let s = UUID(); try ledger.record(obs(s, "Acme", "Akme")); try ledger.settle(sessionID: s) }
            check(learned(dict).isEmpty, "manual entry not duplicated")
        }

        // The ledger passes its lexicon to the filter.
        do {
            let (_, ledger) = try fresh("lexicon")
            ledger.isCommonWord = { ["lunch", "launch"].contains($0) }
            try check(try ledger.record(obs(UUID(), "lunch", "launch")) == .rejected(.ordinaryWords), "ledger uses lexicon")
        }

        // Learning off records nothing.
        do {
            let (dict, ledger) = try fresh("off")
            let a = UUID()
            try ledger.record(obs(a, "Acme", "Akme"))
            try ledger.setLearningEnabled(false)
            check(ledger.evidence.isEmpty, "disabling drops provisional evidence")
            for _ in 0..<3 {
                let s = UUID()
                try check(ledger.record(obs(s, "Acme", "Akme")) == .learningDisabled, "off records nothing")
                try ledger.settle(sessionID: s)
            }
            check(ledger.evidence.isEmpty && learned(dict).isEmpty, "nothing stored or promoted while off")
            let reopened = try CorrectionLedger(directory: dir.appendingPathComponent("off"), dictionary: dict)
            check(!reopened.learningEnabled, "toggle persists")
        }

        // Persistence across launches: one session before restart, one after.
        do {
            let d = dir.appendingPathComponent("persist")
            let a = UUID(), b = UUID(), c = UUID()
            do {
                let dict = try DictionaryStore(directory: d)
                let ledger = try CorrectionLedger(directory: d, dictionary: dict)
                try ledger.record(obs(a, "Acme", "Akme")); try ledger.settle(sessionID: a)
                try ledger.record(obs(c, "Zorblat", "Zorblatt"))  // provisional survives too
            }
            let dict = try DictionaryStore(directory: d)
            let ledger = try CorrectionLedger(directory: d, dictionary: dict)
            check(ledger.evidence.count == 2 && ledger.provisionalSessions == [c], "ledger round-trip")
            try ledger.record(obs(b, "Acme", "Akme")); try ledger.settle(sessionID: b)
            check(learned(dict).count == 1, "promotion across launches")
            let again = try CorrectionLedger(directory: d, dictionary: try DictionaryStore(directory: d))
            try again.revert(sessionID: a)
            try check(DictionaryStore(directory: d).entries.filter { $0.source == .learned }.isEmpty, "promotion sessions persist for revert")
        }
    }

    static func retentionChecks(_ dir: URL) throws {
        let history = dir.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var items: [Item] = []
        for i in 0..<5 {
            let item = Item(id: UUID().uuidString, recordedAt: base.addingTimeInterval(Double(i) * 60))
            try Data(repeating: 0x20, count: 1000).write(to: history.appendingPathComponent(item.id + ".json"))
            items.append(item)
        }
        try check(HistoryCap.usage(directory: history) == 5000, "usage sums files")
        check(HistoryCap.defaultCapBytes == 50 * 1024 * 1024, "50 MB default cap")

        // Pure plan: drop oldest first until within cap.
        let sizes = Dictionary(uniqueKeysWithValues: items.map { ($0.id, Int64(1000)) })
        let plan = HistoryCap.plan(entries: items.shuffled(), sizes: sizes, retention: .thirtyDays, capBytes: 2500)
        check(plan.dropped.map(\.id) == items.prefix(3).map(\.id), "drops the three oldest")
        check(plan.status == .withinCap(usedBytes: 2000, capBytes: 2500), "within cap after drop")
        let single = HistoryCap.plan(entries: [items[4]], sizes: sizes, retention: .sixMonths, capBytes: 500)
        check(single.dropped.isEmpty && single.status == .overCap(usedBytes: 1000, capBytes: 500), "newest entry kept")
        // Forever warns instead of dropping.
        let forever = HistoryCap.plan(entries: items, sizes: sizes, retention: .forever, capBytes: 2500)
        check(forever.dropped.isEmpty && forever.status == .overCap(usedBytes: 5000, capBytes: 2500) && forever.status.warning != nil, "forever over cap warns")
        let near = HistoryCap.plan(entries: items, sizes: sizes, retention: .forever, capBytes: 5400)
        check(near.status == .approachingCap(usedBytes: 5000, capBytes: 5400) && near.status.warning != nil, "forever approaching warns")
        let fine = HistoryCap.plan(entries: items, sizes: sizes, retention: .forever, capBytes: 50_000)
        check(fine.status.warning == nil, "no warning well under cap")

        // Enforce against the directory with a delete closure.
        var deleted: [String] = []
        let result = try HistoryCap.enforce(entries: items, directory: history, retention: .thirtyDays, capBytes: 3000) { item in
            deleted.append(item.id)
            try FileManager.default.removeItem(at: history.appendingPathComponent(item.id + ".json"))
        }
        check(deleted == items.prefix(2).map(\.id) && result.status.usedBytes == 3000, "enforce deletes oldest")
        try check(HistoryCap.usage(directory: history) == 3000, "files removed")
        let remaining = Array(items.suffix(3))
        try check(HistoryCap.capStatus(entries: remaining, directory: history, retention: .forever, capBytes: 3200) == .approachingCap(usedBytes: 3000, capBytes: 3200), "capStatus forever")
        let noDrop = try HistoryCap.enforce(entries: remaining, directory: history, retention: .forever, capBytes: 1000) { _ in check(false, "forever must not delete") }
        check(noDrop.dropped.isEmpty, "forever enforce drops nothing")
        check(HistoryRetention(rawValue: "six-months") == .sixMonths && HistoryRetention(rawValue: "30-days") == .thirtyDays, "retention strings match HistoryStore")

        // History-off mode.
        check(!HistoryMode.off.persistsTranscripts && HistoryMode.on.persistsTranscripts, "history mode flag")
        check(HistoryMode.offDisclosure.contains("cannot be recovered"), "history-off disclosure")

        // Delete all data.
        let base2 = dir.appendingPathComponent("Dictation")
        let locations = MurmurDataLocations.standard(base: base2)
        let dict = try DictionaryStore(directory: locations.dictionary)
        try dict.add(preferred: "Akme", variants: ["Acme"])
        let ledger = try CorrectionLedger(directory: locations.ledger, dictionary: dict)
        try ledger.record(ObservedCorrection(sessionID: UUID(), source: "Acme", target: "Akme", observedAt: base))
        try FileManager.default.createDirectory(at: locations.history, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: locations.history.appendingPathComponent(UUID().uuidString + ".json"))
        try FileManager.default.createDirectory(at: locations.retryAudio, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: locations.retryAudio.appendingPathComponent("retry.wav"))
        var keychainCalled = false
        let report = DataWipe.deleteAllData(locations) { keychainCalled = true; return ["fireworks-api-key"] }
        check(report.succeeded && keychainCalled && report.keychainItems == ["fireworks-api-key"], "deleteAll reports keychain removal")
        check(report.removed.count == 3, "history, dictionary+ledger, retry audio removed")
        for url in [locations.history, locations.dictionary, locations.ledger, locations.retryAudio] {
            check(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) gone")
        }
        try dict.reload(); try ledger.reload()
        check(dict.entries.isEmpty && ledger.evidence.isEmpty, "reloaded stores are empty")
        struct KeychainFailure: Error {}
        let second = DataWipe.deleteAllData(locations) { throw KeychainFailure() }
        // reload() recreated the empty dictionary directory; the other locations are absent.
        check(second.absent.count == 2 && second.removed.count == 1 && !second.succeeded && second.failures.count == 1, "absent data and keychain failure reported")
    }
}
