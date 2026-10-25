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

        // Gap #12: an entry whose target is a spoken command applies first and is never a hint.
        do {
            let d = dir.appendingPathComponent("commands")
            let commands = try DictionaryStore(directory: d)
            let command = try commands.add(preferred: "question mark", variants: ["Kocia Mark"])
            try commands.add(preferred: "Marc", variants: ["mark"])
            try commands.add(preferred: "Kocia Inc", variants: ["kocia mark please"])
            check(DictionaryStore.isCommandTarget(command), "command phrase recognised as a command target")
            check(commands.apply(to: "Is it done kocia mark") == "Is it done question mark", "misheard command replaced")
            check(commands.apply(to: "Kocia Mark") == "question mark", "command target keeps its form at a sentence start")
            check(commands.apply(to: "kocia mark please") == "question mark please", "command target wins over a longer entry")
            check(commands.apply(to: "ask mark") == "ask Marc", "other entries still apply")
            check(commands.vocabularyTerms == ["Marc", "Kocia Inc"], "command target excluded from transcription vocabulary")
            check(!commands.relevantEntries(for: "kocia mark").contains { $0.id == command.id }
                  && !commands.relevantEntries(for: "question mark").contains { $0.id == command.id }, "command target excluded from cleanup hints")
        }

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
        // With a lexicon: case, spacing, acronym and short-name fixes (user decision, October 4, 2026).
        let words: Set<String> = lexicon.union(["notion", "git", "hub", "every", "one", "everyone", "api", "son", "call"])
        let ordinary: (String) -> Bool = { words.contains($0) }
        for (source, target) in [("jira", "Jira"), ("git hub", "GitHub"), ("para keet", "Parakeet"), ("a p i", "API"), ("J son", "JSON"), ("Jon", "John")] {
            check(CorrectionFilter.evaluate(source: source, target: target, isCommonWord: ordinary) == .accepted(source: source, target: target), "\(source) -> \(target) learned with a lexicon")
        }
        check(CorrectionFilter.evaluate(source: "call jira", target: "call Jira", isCommonWord: ordinary) == .accepted(source: "jira", target: "Jira"), "case fix trims its context")
        check(CorrectionFilter.evaluate(source: "notion", target: "Notion", isCommonWord: ordinary) == .rejected(.ordinaryWords), "recasing an ordinary word is not learned")
        let phraseWords = words.union(["spacey", "boy"])
        let phraseLexicon: (String) -> Bool = { phraseWords.contains($0) }
        check(CorrectionFilter.evaluate(source: "spacey boy", target: "spaceyboi", isCommonWord: phraseLexicon) == .accepted(source: "spacey boy", target: "spaceyboi"), "joined name learned despite contextual component")
        let rustLexicon: (String) -> Bool = { ["rust", "c"].contains($0) }
        check(CorrectionFilter.evaluate(source: "rust C", target: "rustc", isCommonWord: rustLexicon) == .accepted(source: "rust C", target: "rustc"), "capitalized single-letter term component is learned")
        check(CorrectionFilter.evaluate(source: "every one", target: "everyone", isCommonWord: ordinary) != .accepted(source: "every one", target: "everyone"), "joining ordinary words is not learned")
        check(CorrectionFilter.evaluate(source: "a boy", target: "aboy", isCommonWord: { ["a", "boy", "aboy"].contains($0) }) != .accepted(source: "a boy", target: "aboy"), "short function word join is not learned")
        let functionWordLexicon: (String) -> Bool = { ["a", "boy", "i", "am"].contains($0) }
        check(CorrectionFilter.evaluate(source: "A boy", target: "aboy", isCommonWord: functionWordLexicon) == .rejected(.contextualWord), "sentence-case A does not enable learning")
        check(CorrectionFilter.evaluate(source: "I am", target: "iam", isCommonWord: functionWordLexicon) == .rejected(.contextualWord), "pronoun I does not enable learning")
        check(CorrectionFilter.evaluate(source: "jira", target: "Jira") == .rejected(.caseOnly), "no lexicon: case fix skipped")
        check(CorrectionFilter.evaluate(source: "git hub", target: "GitHub") == .rejected(.punctuationOnly), "no lexicon: spacing fix skipped")
        check(CorrectionFilter.evaluate(source: "Jon", target: "John") == .rejected(.tooShort), "no lexicon: short word skipped")
        // History, October 2026: garbled names whose consonants shift (similarity 0.57 and 0.71).
        let names: (String) -> Bool = { ["codecs", "codex", "claud", "claude", "buzzard", "lunch", "launch"].contains($0) }
        check(CorrectionFilter.evaluate(source: "ChadJuT", target: "ChatGPT", isCommonWord: names) == .accepted(source: "ChadJuT", target: "ChatGPT"), "garbled product name learned with a lexicon")
        check(CorrectionFilter.evaluate(source: "In Buzari's", target: "In Buzzati's", isCommonWord: names) == .accepted(source: "Buzari", target: "Buzzati"), "possessive name learned as its stem")
        check(CorrectionFilter.evaluate(source: "ChadJuT", target: "ChatGPT") == .rejected(.notRespelling), "no lexicon: loose respelling skipped")
        check(CorrectionFilter.evaluate(source: "Buzari", target: "buzzard", isCommonWord: names) == .rejected(.notRespelling), "loose respelling never lands on an ordinary word")
        check(CorrectionFilter.evaluate(source: "codecs", target: "Codex", isCommonWord: names) == .rejected(.ordinaryWords), "codecs -> Codex stays unlearned")
        check(CorrectionFilter.evaluate(source: "claud", target: "Claude", isCommonWord: names) == .rejected(.ordinaryWords), "claud -> Claude stays unlearned")
        check(CorrectionFilter.evaluate(source: "Quorbix", target: "Fredlin", isCommonWord: names) == .rejected(.notRespelling), "dissimilar unfamiliar words skipped")
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

        // Gap #11 (October 16, 2026): one settled fix adds the spelling with the misheard form,
        // replaced from the next dictation on.
        do {
            let (dict, ledger) = try fresh("promote")
            let a = UUID(), b = UUID()
            try check(ledger.record(obs(a, "Acme", "Akme")) == .provisional, "first observation provisional")
            check(dict.apply(to: "Ask Acme today") == "Ask Acme today", "provisional evidence replaces nothing")
            try check(ledger.settle(sessionID: a).map(\.preferred) == ["Akme"], "one fix learns")
            check(learned(dict).count == 1 && learned(dict)[0].variants == ["Acme"], "one fix adds the misheard form as a variant")
            check(dict.vocabularyTerms == ["Akme"], "learned spelling reaches transcription vocabulary")
            check(dict.apply(to: "Ask Acme today") == "Ask Akme today", "one fix replaces from the next dictation")
            check(ledger.evidence.isEmpty, "evidence consumed on promotion")
            try check(ledger.record(obs(b, "acme", "AKME", 10)) == .provisional, "repeat fix (case differs) records")
            try check(ledger.settle(sessionID: b).isEmpty, "repeat fix adds nothing")
            check(learned(dict).count == 1 && learned(dict)[0].variants == ["Acme"] && ledger.evidence.isEmpty,
                  "repeat fix confirms without a duplicate or leftover evidence")
            // Ledger file holds only short strings.
            let raw = try String(contentsOf: dir.appendingPathComponent("promote/ledger.json"), encoding: .utf8)
            check(!raw.contains("Ask"), "ledger has no document text")
            let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("promote/ledger.json").path)[.posixPermissions] as? NSNumber
            check(mode?.intValue == 0o600, "ledger file is 0600")
        }

        // Two observations in the same session learn once.
        do {
            let (dict, ledger) = try fresh("same-session")
            let a = UUID()
            try ledger.record(obs(a, "Acme", "Akme"))
            try ledger.record(obs(a, "Acme", "Akme", 5))
            try ledger.settle(sessionID: a)
            try check(ledger.settle(sessionID: a).isEmpty, "settling twice is harmless")
            try check(ledger.record(obs(a, "Acme", "Akme", 6)) == .sessionClosed, "closed session ignored")
            check(learned(dict).count == 1 && learned(dict)[0].variants == ["Acme"] && ledger.evidence.isEmpty, "same session counts once")
        }

        // Gap #9: settle on stable text, then keep watching the same session.
        do {
            let (dict, ledger) = try fresh("early-settle")
            let a = UUID(), b = UUID(), c = UUID()
            try ledger.record(obs(a, "Acme", "Akme"))
            try check(ledger.settle(sessionID: a).map(\.preferred) == ["Akme"], "early settle learns before the window closes")
            check(dict.apply(to: "Ask Acme") == "Ask Akme", "early settle replaces")
            try check(ledger.record(obs(a, "Acme", "Akme", 1)) == .sessionClosed, "same reading after an early settle changes nothing")
            try check(ledger.record(obs(a, "Acme", "Akmee", 2)) == .provisional, "a later edit re-records the session")
            check(learned(dict).isEmpty && ledger.evidence.map(\.target) == ["Akmee"] && ledger.provisionalSessions == [a],
                  "later edit withdraws the early replacement and replaces the evidence")
            try check(ledger.settle(sessionID: a).map(\.preferred) == ["Akmee"] && ledger.blocked.isEmpty,
                      "settling the replacement learns it without a conflict")
            // Back to the first fix, settled again: learned once.
            try ledger.record(obs(a, "Acme", "Akme", 3)); try ledger.settle(sessionID: a)
            try ledger.settle(sessionID: a)
            check(learned(dict).count == 1 && learned(dict)[0].preferred == "Akme" && learned(dict)[0].variants == ["Acme"],
                  "a session settled twice learns once")
            try ledger.record(obs(b, "Acme", "Akme", 10)); try ledger.settle(sessionID: b)
            check(dict.apply(to: "Ask Acme") == "Ask Akme" && learned(dict).count == 1, "another session's same fix confirms it")
            // A second fix after an early settle keeps the first fix's replacement.
            let (dict3, ledger3) = try fresh("early-second-fix")
            let d = UUID(), e = UUID()
            try ledger3.record(obs(d, "Acme", "Akme")); try ledger3.settle(sessionID: d)
            try ledger3.record(obs(e, "Acme met Zorblat", "Akme met Zorblat", 10)); try ledger3.settle(sessionID: e)
            let owner = learned(dict3)[0].id
            try check(ledger3.record(obs(e, "Acme met Zorblat", "Akme met Zorblatt", 11)) == .provisional, "second fix in the same span records")
            check(dict3.apply(to: "Ask Acme") == "Ask Akme" && learned(dict3)[0].id == owner, "first fix's replacement survives a second fix")
            try check(ledger3.settle(sessionID: e).map(\.preferred) == ["Zorblatt"], "second fix learns its own replacement")
            check(dict3.apply(to: "Ask Acme met Zorblat") == "Ask Akme met Zorblatt", "both replacements apply after the final settle")
            // Undo after an early settle withdraws what it promoted.
            let (dict2, ledger2) = try fresh("early-undo")
            try ledger2.record(obs(c, "Acme", "Akme")); try ledger2.settle(sessionID: c)
            try ledger2.revert(sessionID: c)
            check(learned(dict2).isEmpty && ledger2.evidence.isEmpty && ledger2.tombstones.isEmpty, "undo after an early settle withdraws the replacement")
        }

        // The notice's Undo removes what it learned and tombstones it.
        do {
            let (dict, ledger) = try fresh("notice-undo")
            let a = UUID(), b = UUID()
            try ledger.record(obs(a, "Akash", "Aakash")); try ledger.settle(sessionID: a)
            try ledger.record(obs(b, "Aakesh", "Aakash")); let added = try ledger.settle(sessionID: b)
            let id = learned(dict)[0].id
            check(added.map(\.id) == [id] && learned(dict)[0].variants == ["Akash", "Aakesh"], "a second mishearing joins the entry and is announced")
            try ledger.undoLearned(entryID: id)
            check(learned(dict).map(\.variants) == [["Akash"]] && dict.apply(to: "Aakesh") == "Aakesh", "Undo removes only the announced variant")
            check(ledger.tombstones.contains(.init(source: "aakesh", target: "aakash")), "Undo tombstones the variant")
            try check(ledger.record(obs(UUID(), "Aakesh", "Aakash")) == .tombstoned, "an undone fix is not learned again")
            try ledger.undoLearned(entryID: id)
            check(learned(dict).isEmpty && ledger.tombstones.contains(.init(source: "akash", target: "aakash")), "Undo of a new entry deletes and tombstones it")
            try ledger.undoLearned(entryID: id)
            check(learned(dict).isEmpty, "a stale Undo does nothing")
        }

        // Gap #10: a History edit learns through the same filter and rules, as its own session.
        do {
            let (dict, ledger) = try fresh("history-edit")
            try check(ledger.learnFromEdit(original: "I talked to Acme today.", edited: "I talked to Akme today.").map(\.preferred) == ["Akme"],
                      "history edit learns")
            check(dict.apply(to: "Ask Acme") == "Ask Akme", "a history edit replaces in one step")
            try check(ledger.learnFromEdit(original: "I accept the terms.", edited: "I decline the terms.").isEmpty
                      && ledger.evidence.isEmpty && learned(dict).count == 1, "history meaning edit rejected by the filter")
            try check(ledger.learnFromEdit(original: "Same text.", edited: "Same text.").isEmpty, "unchanged history text learns nothing")
            try ledger.learnFromEdit(original: "Acme shipped it.", edited: "Akmee shipped it.")
            check(learned(dict).isEmpty && ledger.suppressedSources.contains("acme"), "a conflicting history edit suppresses")
            try ledger.unblock(.heard("acme"))
            try ledger.learnFromEdit(original: "Acme shipped it.", edited: "Akme shipped it.")
            try ledger.deleteLearned(id: learned(dict)[0].id)
            try check(ledger.learnFromEdit(original: "Acme again", edited: "Akme again").isEmpty && learned(dict).isEmpty,
                      "history edit honours tombstones")
            try ledger.setLearningEnabled(false)
            try check(ledger.learnFromEdit(original: "Zorblat", edited: "Zorblatt").isEmpty && ledger.evidence.isEmpty,
                      "history edit learns nothing with learning off")
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

        // A conflicting second fix suppresses and withdraws until reset.
        do {
            let (dict, ledger) = try fresh("conflict")
            let a = UUID(), b = UUID(), c = UUID()
            try ledger.record(obs(a, "Acme", "Akme")); try ledger.settle(sessionID: a)
            check(dict.apply(to: "Acme") == "Akme", "first fix replaces")
            try ledger.record(obs(b, "Acme", "Acmee")); try ledger.settle(sessionID: b)
            check(ledger.suppressedSources.contains("acme") && learned(dict).isEmpty && dict.apply(to: "Acme") == "Acme",
                  "a conflicting second fix suppresses and withdraws the replacement")
            check(ledger.tombstones.isEmpty, "a conflict does not tombstone")
            try check(ledger.record(obs(c, "Acme", "Akme")) == .suppressed, "suppressed source not recorded")
            try ledger.settle(sessionID: c)
            check(learned(dict).isEmpty, "no promotion while suppressed")
            try ledger.reset()
            check(ledger.suppressedSources.isEmpty, "reset clears suppression")
            let d = UUID()
            try ledger.record(obs(d, "Acme", "Akme")); try ledger.settle(sessionID: d)
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

        // Revert removes evidence and withdraws the promotion it supported.
        do {
            let (dict, ledger) = try fresh("revert")
            let a = UUID(), b = UUID()
            try ledger.record(obs(a, "Acme", "Akme"))
            try ledger.revert(sessionID: a)
            check(ledger.evidence.isEmpty, "revert removes provisional evidence")
            try ledger.settle(sessionID: a)
            check(learned(dict).isEmpty, "reverted evidence does not count")
            try ledger.record(obs(b, "Acme", "Akme")); try ledger.settle(sessionID: b)
            check(learned(dict).count == 1, "promoted by b")
            try ledger.revert(sessionID: b)
            check(learned(dict).isEmpty && dict.apply(to: "Acme") == "Acme", "revert after promotion withdraws the replacement")
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

        // Word diff: separate fixes, a fix followed by typing, rewrites and deletions.
        do {
            typealias C = CorrectionFilter.Change
            try check(CorrectionFilter.replacements("call ACME about Gira", "call Akme about Jira").get() == [C(source: "ACME", targets: ["Akme"]), C(source: "Gira", targets: ["Jira"])], "two fixes are two changes")
            try check(CorrectionFilter.replacements("pay Acme", "pay Akme and more").get() == [C(source: "Acme", targets: ["Akme", "Akme and", "Akme and more"])], "fix then typing: shortest reading first")
            try check(CorrectionFilter.replacements("call Acme today", "call Akme today and more").get() == [C(source: "Acme", targets: ["Akme"])], "words added after the span are ignored")
            check(CorrectionFilter.replacements("call Acme today", "call today") == .failure(.deletion), "deletion")
            check(CorrectionFilter.replacements("maybe the team wants a new plan", "I think we should ship old stuff") == .failure(.tooManyWords), "rewrite")
            try check(CorrectionFilter.replacements("acme", "Acme").get() == [C(source: "acme", targets: ["Acme"])], "a case change is a change")
        }

        // A case fix is learned from one fix and its reversal withdraws it.
        do {
            let d = dir.appendingPathComponent("case-tiers")
            let dict = try DictionaryStore(directory: d)
            let ledger = try CorrectionLedger(directory: d, dictionary: dict)
            ledger.isCommonWord = { ["call", "the"].contains($0) }
            let first = UUID(); try ledger.record(obs(first, "call jira", "call Jira")); try ledger.settle(sessionID: first)
            check(learned(dict).map(\.preferred) == ["Jira"] && learned(dict)[0].variants == ["jira"], "case fix: one fix adds the variant")
            check(dict.apply(to: "open jira now") == "open Jira now", "case fix applies")
            let r = UUID(); try ledger.record(obs(r, "Jira", "jira")); try ledger.settle(sessionID: r)
            check(learned(dict).isEmpty, "lowercasing it again withdraws it")
            check(ledger.blocked == [.heard("jira"), .spelling("Jira")], "reversal blocks the heard form and the spelling")
            try ledger.unblock(.spelling("jira")); try ledger.unblock(.heard("jira"))
            check(ledger.blocked.isEmpty, "unblocked")
            let s = UUID()
            try check(ledger.record(obs(s, "call jira", "call Jira")) == .provisional, "learnable again after unblocking")
        }

        // Two mishearings of one spelling share one entry; a deleted word is never re-learned.
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

        // Migration: an old first-tier hint and its settled evidence are not promoted at load or by an
        // unrelated settle; the next fix of that pair adds the variant, and Undo withdraws only that.
        do {
            let d = dir.appendingPathComponent("legacy-hint")
            let dict = try DictionaryStore(directory: d)
            let entry = try dict.add(preferred: "Akme", variants: [], source: .learned)
            let old = UUID()
            let legacy = #"{"evidence":[{"correction":{"observedAt":0,"sessionID":"\#(old.uuidString)","source":"Acme","target":"Akme"},"settled":true}],"learningEnabled":true,"promotions":[{"entryID":"\#(entry.id.uuidString)","kind":"hint","pair":{"source":"acme","target":"akme"},"sessions":["\#(old.uuidString)"]}],"suppressed":[],"tombstones":[],"version":1}"#
            try PrivateFiles.write(Data(legacy.utf8), to: d.appendingPathComponent(CorrectionLedger.fileName))
            let ledger = try CorrectionLedger(directory: d, dictionary: dict)
            check(ledger.evidence.count == 1 && learned(dict)[0].variants.isEmpty && dict.apply(to: "Ask Acme") == "Ask Acme", "old hint not promoted at load")
            let x = UUID(); try ledger.record(obs(x, "Zorblat", "Zorblatt")); try ledger.settle(sessionID: x)
            check(dict.apply(to: "Ask Acme") == "Ask Acme", "an unrelated settle does not promote old evidence")
            let y = UUID(); try ledger.record(obs(y, "Acme", "Akme")); let upgraded = try ledger.settle(sessionID: y)
            check(upgraded.map(\.id) == [entry.id] && dict.apply(to: "Ask Acme") == "Ask Akme" && ledger.evidence.allSatisfy { $0.target != "Akme" },
                  "the next fix upgrades the old hint and is announced")
            try ledger.undoLearned(entryID: entry.id)
            check(learned(dict).map(\.variants).contains([]) && dict.apply(to: "Ask Acme") == "Ask Acme"
                  && ledger.tombstones.contains(.init(source: "acme", target: "akme")), "Undo of the upgrade removes and tombstones the variant")
        }

        // Manual entry already owns the source: no duplicate learned entry.
        do {
            let (dict, ledger) = try fresh("manual")
            try dict.add(preferred: "Akme", variants: ["Acme"])
            let s = UUID(); try ledger.record(obs(s, "Acme", "Akme")); try ledger.settle(sessionID: s)
            check(learned(dict).isEmpty && ledger.evidence.isEmpty, "manual entry not duplicated")
        }

        // The ledger passes its lexicon to the filter: an ordinary-word swap is still never learned.
        do {
            let (dict, ledger) = try fresh("lexicon")
            ledger.isCommonWord = { ["lunch", "launch"].contains($0) }
            let s = UUID()
            try check(try ledger.record(obs(s, "lunch", "launch")) == .rejected(.ordinaryWords), "ledger uses lexicon")
            try check(ledger.settle(sessionID: s).isEmpty && learned(dict).isEmpty, "ordinary-word swap rejected under one-fix learning")
        }

        // History, October 2026: one fix of a garbled name in pasted text.
        do {
            let (dict, ledger) = try fresh("garbled")
            ledger.isCommonWord = { ["errors", "across", "the", "or", "codex", "app", "latest", "version"].contains($0) }
            let s = UUID()
            try ledger.record(obs(s, "errors across the ChadJuT or Codex app", "errors across the ChatGPT or Codex app"))
            try check(try ledger.settle(sessionID: s).map(\.preferred) == ["ChatGPT"], "ChadJuT fix learned from one edit")
            check(dict.apply(to: "the ChadJuT app", isCommonWord: ledger.isCommonWord) == "the ChatGPT app", "learned form replaced")
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

        // Persistence across launches: a promotion and provisional evidence survive a restart.
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
            check(ledger.evidence.count == 1 && ledger.provisionalSessions == [c] && learned(dict).count == 1, "ledger round-trip")
            try ledger.record(obs(b, "Acme", "Akme")); try ledger.settle(sessionID: b)
            check(learned(dict).count == 1, "a repeat fix after restart confirms")
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
        let quarantine = history.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 700).write(to: quarantine.appendingPathComponent("damaged.json"))
        try FileManager.default.createSymbolicLink(at: history.appendingPathComponent("outside-link"), withDestinationURL: dir)
        try check(HistoryCap.usage(directory: history) == 3700, "quarantined bytes count without following symlinks")
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
        try FileManager.default.createDirectory(at: locations.chunks, withIntermediateDirectories: true)
        try Data([4, 5, 6]).write(to: locations.chunks.appendingPathComponent("chunk.wav"))
        var keychainCalled = false
        let report = DataWipe.deleteAllData(locations) { keychainCalled = true; return ["gemini-api-key"] }
        check(report.succeeded && keychainCalled && report.keychainItems == ["gemini-api-key"], "deleteAll reports keychain removal")
        check(report.removed.count == 4, "history, dictionary+ledger, retry audio and abandoned chunks removed")
        for url in [locations.history, locations.dictionary, locations.ledger, locations.retryAudio, locations.chunks] {
            check(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) gone")
        }
        try dict.reload(); try ledger.reload()
        check(dict.entries.isEmpty && ledger.evidence.isEmpty, "reloaded stores are empty")
        struct KeychainFailure: Error {}
        let second = DataWipe.deleteAllData(locations) { throw KeychainFailure() }
        // reload() recreated the empty dictionary directory; the other locations are absent.
        check(second.absent.count == 3 && second.removed.count == 1 && !second.succeeded && second.failures.count == 1, "absent data and keychain failure reported")
    }
}
