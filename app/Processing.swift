import Foundation

// Text processing between transcription and insertion: dictionary, then optional cleanup, then
// the PRD bound check. Foundation only, so app/check_processing.swift runs on Linux.
//
// Order: DictionaryStore.apply runs first and in every mode (faithful included, PRD §4), so its
// preferred spellings are already in the text the cleanup guard compares against. Relevant
// entries are also passed as allowed terms, and as prompt terms on the cloud route.
//
// Failure policy (user decision, October 6, 2026: behave like Wispr Flow): a dictation is never held.
// When the guard rejects the cleaned words, the transcript's own words go in with the model's
// punctuation (`CleanupPipeline.punctuated`). A provider error, or a transfer that also fails the
// guard, falls back to local rules, and failing those, to the dictionary-applied transcript. Every
// text inserted has passed the guard or is the user's own words. Reasons stay content-free.

/// Where cleanup runs. `.local` is the RuleCleaner. `.cloud` means "through a `CleanupProvider`":
/// Gemini, OpenRouter, or a user-run local model server (see `CleanupChoice` in Routes.swift).
enum CleanupRoute: String, Codable, CaseIterable, Sendable {
    case local
    case cloud
}

/// What the controller does with a finished transcript.
enum ProcessingOutcome: Equatable, Sendable {
    /// Insert (or save, if insertion is off or unsafe) this text.
    case insert(String)
    /// Save `raw` (the unmodified transcript) for recovery and do not insert automatically. Only
    /// the controller produces this now (processing unavailable); `reason` is content-free.
    case heldForRecovery(raw: String, reason: CleanupFailureReason)
}

/// Settings owned by processing, persisted in UserDefaults.
struct ProcessingSettings: Equatable, Sendable {
    var options: CleanupOptions = .standard
    var route: CleanupRoute = .local
    var learningEnabled = true
    var learningRequiresReadableField = false
    /// Applied by AppController, as soon as the setting changes, through HistoryRouter.
    var historyMode: HistoryMode = .on
    /// Read by AppController for the automatic update check.
    var updateChecksEnabled = true

    enum Key {
        static let fillers = "cleanupFillers"
        static let corrections = "cleanupCorrections"
        static let lists = "cleanupLists"
        static let punctuation = "cleanupPunctuation"
        static let route = "cleanupRoute"
        static let learning = "learningEnabled"
        static let readableLearning = "learningRequiresReadableField"
        static let historyMode = "historyMode"
        static let updateChecks = "updateChecksEnabled"
    }

    /// Missing or unknown values fall back to the approved defaults (all comforts on, local route).
    static func load(from defaults: UserDefaults) -> ProcessingSettings {
        var settings = ProcessingSettings()
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        settings.options = CleanupOptions(fillers: flag(Key.fillers, true), corrections: flag(Key.corrections, true), lists: flag(Key.lists, true), punctuation: flag(Key.punctuation, true))
        settings.route = defaults.string(forKey: Key.route).flatMap(CleanupRoute.init(rawValue:)) ?? .local
        settings.learningEnabled = flag(Key.learning, true)
        settings.learningRequiresReadableField = flag(Key.readableLearning, false)
        settings.historyMode = defaults.string(forKey: Key.historyMode).flatMap(HistoryMode.init(rawValue:)) ?? .on
        settings.updateChecksEnabled = flag(Key.updateChecks, true)
        return settings
    }

    func save(to defaults: UserDefaults) {
        defaults.set(options.fillers, forKey: Key.fillers)
        defaults.set(options.corrections, forKey: Key.corrections)
        defaults.set(options.lists, forKey: Key.lists)
        defaults.set(options.punctuation, forKey: Key.punctuation)
        defaults.set(route.rawValue, forKey: Key.route)
        defaults.set(learningEnabled, forKey: Key.learning)
        defaults.set(learningRequiresReadableField, forKey: Key.readableLearning)
        defaults.set(historyMode.rawValue, forKey: Key.historyMode)
        defaults.set(updateChecksEnabled, forKey: Key.updateChecks)
    }
}

/// Owns the dictionary and correction ledger and turns a raw transcript into an outcome.
/// Not thread-safe: the app calls it from the main thread only.
final class ProcessingCoordinator {
    let dictionary: DictionaryStore
    let ledger: CorrectionLedger
    private(set) var settings: ProcessingSettings
    private let defaults: UserDefaults
    /// The local route's cleaner. Tests substitute failing or misbehaving cleaners.
    var localCleaner: Cleaner = RuleCleaner()
    /// The cloud route's provider. Nil means the cloud route is not configured, so local rules run.
    /// AppController sets it from `RoutePlan` (selected provider and Keychain key) at each start.
    var cloudCleaner: CleanupProvider?
    /// The last provider error from `processAsync`, for a content-free notice. Main thread.
    private(set) var lastProviderError: ProviderError?
    /// Why the last dictation did not get its full cleanup (content-free), or nil. Main thread.
    private(set) var lastFallback: CleanupFailureReason?
    /// What the punctuation transfer is guarded as: sentence punctuation and capitals, no word changes.
    static let punctuationOnly = CleanupOptions(fillers: false, corrections: false, lists: false, punctuation: true)

    /// `directory` holds dictionary.json and ledger.json (MurmurDataLocations.standard layout).
    /// `isCommonWord` is the learning lexicon (NSSpellChecker in the app; a fake set in checks).
    init(directory: URL, defaults: UserDefaults = .standard, isCommonWord: ((String) -> Bool)? = nil) throws {
        self.defaults = defaults
        dictionary = try DictionaryStore(directory: directory)
        ledger = try CorrectionLedger(directory: directory, dictionary: dictionary)
        ledger.isCommonWord = isCommonWord
        settings = ProcessingSettings.load(from: defaults)
        if ledger.learningEnabled != settings.learningEnabled { try ledger.setLearningEnabled(settings.learningEnabled) }
    }

    /// Persists settings and keeps the ledger's learning switch in step with them.
    func update(_ next: ProcessingSettings, persist: Bool = true) throws {
        if ledger.learningEnabled != next.learningEnabled { try ledger.setLearningEnabled(next.learningEnabled) }
        settings = next
        if persist { next.save(to: defaults) }
    }

    // MARK: Processing

    /// Dictionary-applied text and the relevant terms for this transcript.
    private func prepare(_ raw: String) -> (text: String, terms: [String]) {
        let applied = dictionary.apply(to: raw)
        var seen = Set<UUID>()
        var terms: [String] = []
        for entry in dictionary.relevantEntries(for: raw) + dictionary.relevantEntries(for: applied) where seen.insert(entry.id).inserted {
            terms.append(entry.preferred)
        }
        return (applied, terms)
    }

    /// Local rules, guarded; the dictionary-applied text itself if they fail the guard.
    private func localClean(_ text: String, terms: [String]) -> String {
        switch CleanupPipeline.process(raw: text, options: settings.options, cleaner: localCleaner, allowedTerms: terms) {
        case .cleaned(let cleaned), .unchanged(let cleaned): return cleaned
        case .heldForRecovery(_, let reason): lastFallback = lastFallback ?? reason; return text
        }
    }

    /// Synchronous path, used by the app on the local route. It never calls the network: on the
    /// cloud route it uses local rules. The app calls `processAsync` whenever the route is not local rules.
    func process(_ raw: String) -> ProcessingOutcome {
        lastProviderError = nil; lastFallback = nil
        let prepared = prepare(raw)
        if settings.route == .cloud && settings.options.anyEnabled { lastFallback = .cleanerFailed }
        return .insert(localClean(prepared.text, terms: prepared.terms))
    }

    /// Full path including the cloud route. Always inserts: see the failure policy above.
    /// Main actor: the dictionary is read on the main thread; only the provider calls run elsewhere.
    @MainActor func processAsync(_ raw: String) async -> ProcessingOutcome {
        lastProviderError = nil; lastFallback = nil
        guard settings.route == .cloud else { return process(raw) }
        let prepared = prepare(raw)
        let options = settings.options, terms = prepared.terms
        if !options.anyEnabled || prepared.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .insert(prepared.text) }
        guard let provider = cloudCleaner else { lastFallback = .cleanerFailed; return .insert(localClean(prepared.text, terms: terms)) }
        // On the slow Gemma fallback, long text is cleaned in parallel sections, each guarded on its own.
        let sections = (provider as? GeminiCleanupProvider)?.onFallback == true ? CleanupSections.split(prepared.text) : [prepared.text]
        let results = await withTaskGroup(of: (Int, CloudAttempt).self) { group in
            for (index, section) in sections.enumerated() {
                group.addTask { (index, await Self.cloudClean(section, provider: provider, options: options, terms: terms)) }
            }
            var out = Array(repeating: CloudAttempt(text: nil, reason: .cleanerFailed, error: nil), count: sections.count)
            for await (index, attempt) in group { out[index] = attempt }
            return out
        }
        var parts: [String] = []
        for (section, attempt) in zip(sections, results) {
            if let reason = attempt.reason { lastFallback = lastFallback ?? reason }
            if let error = attempt.error { lastProviderError = lastProviderError ?? error }
            let text = attempt.text ?? localClean(section, terms: terms)
            if !text.isEmpty { parts.append(text) }
        }
        return .insert(parts.joined(separator: " "))
    }

    /// One section's cloud result. Nil `text` means use local rules; `reason` is why the full
    /// cleanup was not used, and `error` the provider error, if any.
    struct CloudAttempt: Sendable {
        var text: String?
        var reason: CleanupFailureReason?
        var error: ProviderError?
    }

    /// One provider call, no retry (a rate limit or an outage would only fail again). If the guard
    /// rejects the cleaned words, the transcript's words take the model's punctuation instead.
    private static func cloudClean(_ section: String, provider: CleanupProvider, options: CleanupOptions, terms: [String]) async -> CloudAttempt {
        let output: String
        do { output = try await provider.cleanup(CleanupPrompt.build(transcript: section, options: options, dictionaryTerms: terms)) }
        catch { return CloudAttempt(text: nil, reason: .cleanerFailed, error: error as? ProviderError) }
        let reason: CleanupFailureReason
        switch CleanupPipeline.judge(raw: section, cleaned: output, options: options, allowedTerms: terms, soundsLike: DictionaryStore.soundsLike) {
        case .cleaned(let text), .unchanged(let text): return CloudAttempt(text: text, reason: nil, error: nil)
        case .heldForRecovery(_, let why): reason = why
        }
        if options.punctuation, let words = CleanupPipeline.punctuated(raw: section, cleaned: output, terms: terms),
           case .cleaned(let text) = CleanupPipeline.judge(raw: section, cleaned: words, options: punctuationOnly, allowedTerms: terms) {
            return CloudAttempt(text: text, reason: reason, error: nil)
        }
        return CloudAttempt(text: nil, reason: reason, error: nil)
    }

    // MARK: Learning

    /// One change to a watched dictated span (AppController polls `DictationObservation`).
    /// An edit becomes provisional evidence; back to the original (undo) or lost attribution
    /// (pass `original`) drops this session's evidence. Call `settle` when the window closes.
    /// Returns what the ledger made of it, or nil when the span went back to the original.
    @discardableResult
    func observeSpan(sessionID: UUID, original: String, current: String) throws -> CorrectionLedger.RecordOutcome? {
        // The ledger diffs the span word by word, so punctuation and unchanged words never reach the filter.
        if current == original { try ledger.revert(sessionID: sessionID); return nil }
        return try observe(ObservedCorrection(sessionID: sessionID, source: original, target: current, observedAt: Date()))
    }

    /// Feeds one attributed correction while its observation window is open. With learning off
    /// nothing is recorded.
    @discardableResult
    func observe(_ correction: ObservedCorrection) throws -> CorrectionLedger.RecordOutcome {
        guard settings.learningEnabled else { return .learningDisabled }
        return try ledger.record(correction)
    }

    /// The observation window closed: commit evidence. Returns newly learned entries.
    @discardableResult
    func settle(sessionID: UUID) throws -> [DictionaryEntry] {
        try ledger.settle(sessionID: sessionID)
    }

    // MARK: Dictionary editing

    /// Variants are comma-separated; blanks are dropped.
    private static func variantList(_ variants: String) -> [String] {
        variants.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @discardableResult
    func addEntry(preferred: String, variants: String) throws -> DictionaryEntry {
        try dictionary.add(preferred: preferred, variants: Self.variantList(variants), source: .manual)
    }

    /// Edits an entry in place; a learned entry stays learned. Its ledger promotion is keyed by
    /// entry ID, so old evidence cannot re-promote the original spelling alongside the edit.
    func updateEntry(id: UUID, preferred: String, variants: String, enabled: Bool) throws {
        guard var entry = dictionary.entries.first(where: { $0.id == id }) else { throw DictionaryError("Dictionary entry not found") }
        entry.preferred = preferred; entry.variants = Self.variantList(variants); entry.enabled = enabled
        try dictionary.update(entry)
    }

    /// A learned entry is tombstoned so old evidence cannot re-promote it.
    func deleteEntry(id: UUID) throws {
        if dictionary.entries.first(where: { $0.id == id })?.source == .learned { try ledger.deleteLearned(id: id) }
        else { try dictionary.delete(id: id) }
    }

    /// Removes learned entries and all learning evidence; manual entries stay.
    func resetLearned() throws { try ledger.reset() }
}
