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
// punctuation (`CleanupPipeline.punctuated`), retaining guarded rule-based spoken corrections.
// A provider error, or a transfer that also fails the guard, falls back to local rules, and failing
// those, to the dictionary-applied transcript. Every
// text inserted has passed the guard or is the user's own words. Reasons stay content-free.

/// Where cleanup runs. `.local` is the RuleCleaner. `.cloud` means "through a `CleanupProvider`":
/// Gemini, a custom OpenAI-compatible endpoint, a user-run local model server, or Apple's on-device
/// model (see `CleanupChoice` in Routes.swift).
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
    /// Screen context for AI cleanup routes (gap #8): opt-in, off by default. A writing mode can override it.
    var screenContext = false

    enum Key {
        static let fillers = "cleanupFillers"
        static let corrections = "cleanupCorrections"
        static let lists = "cleanupLists"
        static let punctuation = "cleanupPunctuation"
        static let polish = "cleanupPolish"
        static let professional = "cleanupProfessional"
        static let spoken = "cleanupSpokenCommands"
        static let route = "cleanupRoute"
        static let learning = "learningEnabled"
        static let readableLearning = "learningRequiresReadableField"
        static let historyMode = "historyMode"
        static let updateChecks = "updateChecksEnabled"
        static let screenContext = "cleanupScreenContext"
    }

    /// Missing or unknown values fall back to the approved defaults (all comforts on, local route).
    static func load(from defaults: UserDefaults) -> ProcessingSettings {
        var settings = ProcessingSettings()
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        settings.options = CleanupOptions(fillers: flag(Key.fillers, true), corrections: flag(Key.corrections, true), lists: flag(Key.lists, true), punctuation: flag(Key.punctuation, true), polish: flag(Key.polish, false), professional: flag(Key.professional, false), spoken: flag(Key.spoken, true))
        settings.route = defaults.string(forKey: Key.route).flatMap(CleanupRoute.init(rawValue:)) ?? .local
        settings.learningEnabled = flag(Key.learning, true)
        settings.learningRequiresReadableField = flag(Key.readableLearning, false)
        settings.historyMode = defaults.string(forKey: Key.historyMode).flatMap(HistoryMode.init(rawValue:)) ?? .on
        settings.updateChecksEnabled = flag(Key.updateChecks, true)
        settings.screenContext = flag(Key.screenContext, false)
        return settings
    }

    func save(to defaults: UserDefaults) {
        defaults.set(options.fillers, forKey: Key.fillers)
        defaults.set(options.corrections, forKey: Key.corrections)
        defaults.set(options.lists, forKey: Key.lists)
        defaults.set(options.punctuation, forKey: Key.punctuation)
        defaults.set(options.polish, forKey: Key.polish)
        defaults.set(options.professional, forKey: Key.professional)
        defaults.set(options.spoken, forKey: Key.spoken)
        defaults.set(route.rawValue, forKey: Key.route)
        defaults.set(learningEnabled, forKey: Key.learning)
        defaults.set(learningRequiresReadableField, forKey: Key.readableLearning)
        defaults.set(historyMode.rawValue, forKey: Key.historyMode)
        defaults.set(updateChecksEnabled, forKey: Key.updateChecks)
        defaults.set(screenContext, forKey: Key.screenContext)
    }
}

// MARK: - Writing modes (gaps #6-#8)

/// A user-defined writing mode. Unset overrides inherit the Cleanup settings.
struct WritingMode: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = "New mode"
    var enabled = true
    /// Bundle IDs of the app focused when recording started.
    var apps: [String] = []
    /// "host", "host/path", "*.host" or "host/path/*"; a subdomain matches its host.
    var websites: [String] = []
    /// Said at the start or end of a dictation; stripped from the text.
    var triggers: [String] = []
    /// Nil inherits the Cleanup settings.
    var options: CleanupOptions? = nil
    /// Formal is the default and leaves text as cleanup wrote it.
    var tone: Tone = .formal
    /// Nil inherits the global screen-context setting.
    var screenContext: Bool? = nil
    /// Sent to AI cleanup routes only; capped at `WritingModeLimits.instructions` characters.
    var instructions = ""
}

/// How one dictation is processed: the global settings with the matched mode's overrides.
struct DictationStyle: Equatable, Sendable {
    var options: CleanupOptions
    var tone: Tone = .formal
    var instructions = ""
    /// Captured screen text, used only when the mode or the global setting has screen context on
    /// and only on an AI route. Set it to nil otherwise.
    var context: ScreenContext? = nil

    init(options: CleanupOptions, tone: Tone = .formal, instructions: String = "", context: ScreenContext? = nil) {
        self.options = options; self.tone = tone; self.instructions = instructions; self.context = context
    }

    /// `context` is dropped unless screen context is on for this mode (or globally, when the mode does not say).
    init(mode: WritingMode?, settings: ProcessingSettings, context: ScreenContext? = nil) {
        self.init(options: mode?.options ?? settings.options, tone: mode?.tone ?? .formal,
                  instructions: String((mode?.instructions ?? "").prefix(WritingModeLimits.instructions)),
                  context: (mode?.screenContext ?? settings.screenContext) ? context : nil)
    }
}

enum WritingModes {
    static let defaultsKey = "writingModes"

    static func load(from defaults: UserDefaults) -> [WritingMode] {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([WritingMode].self, from: $0) } ?? []
    }

    static func save(_ modes: [WritingMode], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(modes) { defaults.set(data, forKey: defaultsKey) }
    }

    /// The browser URL is read only when an enabled mode lists a website.
    static func needsURL(_ modes: [WritingMode]) -> Bool { modes.contains { $0.enabled && !$0.websites.isEmpty } }

    /// The mode for the app (and page) focused when recording started: a website match wins over an
    /// app match; within a tier the first mode in the list wins.
    static func match(_ modes: [WritingMode], bundleID: String?, url: URL?) -> WritingMode? {
        let enabled = modes.filter(\.enabled)
        if let url, let mode = enabled.first(where: { $0.websites.contains { websiteMatches($0, url: url) } }) { return mode }
        guard let bundleID = bundleID?.lowercased(), !bundleID.isEmpty else { return nil }
        return enabled.first { $0.apps.contains { $0.lowercased() == bundleID } }
    }

    /// Trigger word first, then website, then app. Returns the mode and the transcript to process.
    static func resolve(_ modes: [WritingMode], transcript: String, bundleID: String?, url: URL?) -> (mode: WritingMode?, text: String) {
        if let hit = trigger(modes, in: transcript) { return hit }
        return (match(modes, bundleID: bundleID, url: url), transcript)
    }

    /// "github.com" matches github.com and any subdomain, never "notgithub.com". A path matches
    /// itself and anything below it by whole segments; "/*" and a leading "*." add nothing.
    /// Scheme, port, query and case are ignored.
    static func websiteMatches(_ pattern: String, url: URL) -> Bool {
        var p = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["https://", "http://", "*.", "www."] where p.hasPrefix(prefix) { p.removeFirst(prefix.count) }
        let slash = p.firstIndex(of: "/") ?? p.endIndex
        let hostPattern = p[..<slash].split(separator: ":").first.map(String.init) ?? ""
        var path = String(p[slash...])
        while path.hasSuffix("*") || path.hasSuffix("/") { path.removeLast() }
        guard !hostPattern.isEmpty, let host = url.host?.lowercased() else { return false }
        guard host == hostPattern || host.hasSuffix("." + hostPattern) else { return false }
        guard !path.isEmpty else { return true }
        let urlPath = url.path.lowercased()
        return urlPath == path || urlPath.hasPrefix(path + "/")
    }

    /// The first enabled mode whose trigger is said at the start or the end, with the trigger removed.
    static func trigger(_ modes: [WritingMode], in transcript: String) -> (mode: WritingMode, text: String)? {
        for mode in modes where mode.enabled {
            for phrase in mode.triggers {
                if let text = stripTrigger(phrase, from: transcript) { return (mode, text) }
            }
        }
        return nil
    }

    /// Whole words only ("code" never matches "codebase"), and only at either end; a dictation that
    /// is nothing but the trigger does not match. "Slack mode, fix it" -> "Fix it";
    /// "Fix it, slack mode." -> "Fix it."
    static func stripTrigger(_ phrase: String, from text: String) -> String? {
        let words = CleanupGuard.words(phrase).map(\.lower)
        guard !words.isEmpty else { return nil }
        var t = CleanupText.tokenize(text)
        let wi = t.indices.filter { t[$0].kind == .word }
        guard wi.count > words.count else { return nil }
        func separator(_ tok: CleanupToken) -> Bool { tok.kind == .space || tok.isComma || tok.isDash || tok.text == ":" || tok.text == ";" }
        if wi.prefix(words.count).map({ t[$0].lower }) == words {
            let capital = t[wi[0]].text.first?.isUppercase ?? false
            var k = wi[words.count - 1] + 1
            if k < t.count, t[k].isTerminal, t[k].text != "\n" { k += 1 } // "Email mode. Fix it."
            while k < t.count, separator(t[k]) || t[k].text == "\n" { k += 1 }
            t.removeSubrange(0..<k)
            if capital, let first = t.firstIndex(where: { $0.kind == .word }) { t[first].text = CleanupText.capitalized(t[first].text) }
            return CleanupText.render(t)
        }
        if wi.suffix(words.count).map({ t[$0].lower }) == words {
            let start = wi[wi.count - words.count]
            let end = t.lastIndex(where: { $0.kind != .space })!
            let mark = t[end].isTerminal && t[end].text != "\n" ? t[end].text : ""
            var k = start
            while k > 0, separator(t[k - 1]) { k -= 1 }
            // "Fix it. Slack mode." keeps the period that ended the dictated sentence.
            if k > 0, t[k - 1].isTerminal { return CleanupText.render(Array(t[..<k])) }
            return CleanupText.render(Array(t[..<k])) + mark
        }
        return nil
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
    /// The cleanup model's output the guard rejected in the last dictation, or nil. Main thread.
    private(set) var lastRejectedOutput: String?
    /// Which path supplied the last dictation's text. Main thread.
    private(set) var lastOutcome: CleanupPath?
    /// What the punctuation transfer is guarded as: sentence punctuation and capitals, no word changes.
    static let punctuationOnly = CleanupOptions(fillers: false, corrections: false, lists: false, punctuation: true)

    /// `directory` holds dictionary.json and ledger.json (MurmurDataLocations.standard layout).
    /// `isCommonWord` guards learning and dictionary respelling (NSSpellChecker in the app).
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
        let applied = dictionary.apply(to: raw, isCommonWord: ledger.isCommonWord)
        var seen = Set<UUID>()
        var terms: [String] = []
        for entry in dictionary.relevantEntries(for: raw) + dictionary.relevantEntries(for: applied) where seen.insert(entry.id).inserted {
            terms.append(entry.preferred)
        }
        return (applied, terms)
    }

    /// Local rules, guarded; the dictionary-applied text itself if they fail the guard.
    private func localClean(_ text: String, terms: [String], options: CleanupOptions) -> String {
        let local = Self.localRules(text, terms: terms, options: options, cleaner: localCleaner)
        if let reason = local.reason { lastFallback = lastFallback ?? reason }
        return local.text
    }

    /// Every enabled local operation (spoken commands, fillers, corrections, lists), guarded. A nil
    /// `reason` means the rules passed the guard; otherwise `text` is the input with only the
    /// spoken commands and "instead" corrections resolved.
    static func localRules(_ text: String, terms: [String], options: CleanupOptions, cleaner: Cleaner = RuleCleaner()) -> (text: String, reason: CleanupFailureReason?) {
        var options = options
        let text = options.corrections && options.polish ? RuleCleaner.applyInsteadCorrections(options.spoken ? RuleCleaner.spokenCommands(text) : text) : text
        options.polish = false // Broader AI grammar and phrasing edits have no local fallback.
        options.professional = false
        switch CleanupPipeline.process(raw: text, options: options, cleaner: cleaner, allowedTerms: terms) {
        case .cleaned(let cleaned), .unchanged(let cleaned): return (cleaned, nil)
        case .heldForRecovery(_, let reason): return (text, reason)
        }
    }

    /// Synchronous path, used by the app on the local route. It never calls the network: on the
    /// cloud route it uses local rules. The app calls `processAsync` whenever the route is not local rules.
    /// `style` carries a writing mode's overrides; nil uses the settings. Screen context and custom
    /// instructions are never used here: local rules send nothing and take no instructions.
    func process(_ raw: String, style: DictationStyle? = nil) -> ProcessingOutcome {
        lastProviderError = nil; lastFallback = nil; lastRejectedOutput = nil; lastOutcome = nil
        let style = style ?? DictationStyle(mode: nil, settings: settings)
        let prepared = prepare(raw)
        if settings.route == .cloud && style.options.anyEnabled { lastFallback = .cleanerFailed }
        lastOutcome = !style.options.anyEnabled ? .off : settings.route == .cloud ? .localRules : .localRoute
        return .insert(toned(localClean(prepared.text, terms: prepared.terms, options: style.options), input: prepared.text, style: style))
    }

    /// The mode's tone, applied last to whichever text was chosen (gap #7). Never on the email layout,
    /// and only as exactly `Tone.apply`, which `CleanupGuard.acceptsTone` checks.
    private func toned(_ text: String, input: String, style: DictationStyle) -> String {
        guard style.tone != .formal, !text.isEmpty, !(style.options.spoken && RuleCleaner.emailLayout(input) != nil) else { return text }
        let next = style.tone.apply(text)
        return CleanupGuard.acceptsTone(base: text, toned: next, tone: style.tone) ? next : text
    }

    /// Full path including the cloud route. Always inserts: see the failure policy above.
    /// Main actor: the dictionary is read on the main thread; only the provider calls run elsewhere.
    @MainActor func processAsync(_ raw: String, style: DictationStyle? = nil) async -> ProcessingOutcome {
        lastProviderError = nil; lastFallback = nil; lastRejectedOutput = nil; lastOutcome = nil
        guard settings.route == .cloud else { return process(raw, style: style) }
        let style = style ?? DictationStyle(mode: nil, settings: settings)
        let prepared = prepare(raw)
        let options = style.options, terms = prepared.terms
        var context = style.context, instructions = style.instructions
        // ponytail: fixed caps keep prompt + a 400-word section inside Apple's ~4K-token window; size by token count if it still overflows.
        if cloudCleaner?.id == .appleIntelligence, var c = context {
            c.selected = String(c.selected.prefix(400)); c.clipboard = String(c.clipboard.prefix(400)); c.window = String(c.window.prefix(1_000))
            context = c
        }
        if !options.anyEnabled { lastOutcome = .off }
        if !options.anyEnabled || prepared.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .insert(toned(prepared.text, input: prepared.text, style: style)) }
        guard let provider = cloudCleaner else { lastFallback = .cleanerFailed; lastOutcome = .localRules; return .insert(toned(localClean(prepared.text, terms: terms, options: options), input: prepared.text, style: style)) }
        // On the slow Gemma fallback, long text is cleaned in parallel sections, each guarded on its own.
        // Apple's on-device model splits longer text, to stay inside its context window (AppleCleanup.swift).
        let sections = (provider as? GeminiCleanupProvider)?.onFallback == true ? CleanupSections.split(prepared.text)
            : provider.id == .appleIntelligence ? CleanupSections.split(prepared.text, target: 400) : [prepared.text]
        let results = await withTaskGroup(of: (Int, CloudAttempt).self) { group in
            for (index, section) in sections.enumerated() {
                group.addTask { (index, await Self.cloudClean(section, provider: provider, options: options, terms: terms, context: context, instructions: instructions)) }
            }
            var out = Array(repeating: CloudAttempt(text: nil, reason: .cleanerFailed, error: nil), count: sections.count)
            for await (index, attempt) in group { out[index] = attempt }
            return out
        }
        // The worst section decides.
        lastOutcome = results.contains { $0.text == nil } ? .localRules : results.contains { $0.reason != nil } ? .modelPunctuationOnLocal : .modelAccepted
        var parts: [String] = []
        for (section, attempt) in zip(sections, results) {
            if let reason = attempt.reason { lastFallback = lastFallback ?? reason }
            if let error = attempt.error { lastProviderError = lastProviderError ?? error }
            // A rejected output may echo screen context, so it is not kept for History when context was sent.
            if context == nil, let rejected = attempt.rejected { lastRejectedOutput = (lastRejectedOutput.map { $0 + "\n\n" } ?? "") + rejected }
            let text = attempt.text ?? localClean(section, terms: terms, options: options)
            if !text.isEmpty { parts.append(text) }
        }
        return .insert(toned(parts.joined(separator: " "), input: prepared.text, style: style))
    }

    /// One section's cloud result. Nil `text` means use local rules; `reason` is why the full
    /// cleanup was not used, `error` the provider error, and `rejected` the output the guard refused.
    struct CloudAttempt: Sendable {
        var text: String?
        var reason: CleanupFailureReason?
        var error: ProviderError?
        var rejected: String? = nil
    }

    /// One provider call, no retry (a rate limit or an outage would only fail again). If the guard
    /// rejects the cleaned words, the transcript's words take the model's punctuation instead.
    /// The guard judges against the transcript section only: screen context never widens what it accepts.
    private static func cloudClean(_ section: String, provider: CleanupProvider, options: CleanupOptions, terms: [String],
                                   context: ScreenContext? = nil, instructions: String = "") async -> CloudAttempt {
        let output: String
        do { output = try await provider.cleanup(CleanupPrompt.build(transcript: section, options: options, dictionaryTerms: terms, context: context, instructions: instructions)) }
        catch { return CloudAttempt(text: nil, reason: .cleanerFailed, error: error as? ProviderError) }
        let reason: CleanupFailureReason
        switch CleanupPipeline.judge(raw: section, cleaned: output, options: options, allowedTerms: terms, soundsLike: DictionaryStore.soundsLike) {
        case .cleaned(let text), .unchanged(let text): return CloudAttempt(text: text, reason: nil, error: nil)
        case .heldForRecovery(_, let why): reason = why
        }
        // Transfer punctuation onto the full local cleanup, so rejecting the model's rewrite never
        // skips the enabled local operations (fillers, corrections, lists, spoken commands).
        let fallback = localRules(section, terms: terms, options: options).text
        if options.punctuation, let words = CleanupPipeline.punctuated(raw: fallback, cleaned: output, terms: terms),
           case .cleaned(let text) = CleanupPipeline.judge(raw: fallback, cleaned: words, options: punctuationOnly, allowedTerms: terms) {
            return CloudAttempt(text: text, reason: reason, error: nil, rejected: output)
        }
        return CloudAttempt(text: nil, reason: reason, error: nil, rejected: output)
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
