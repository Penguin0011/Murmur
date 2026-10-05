import AppKit
import AVFoundation
import FluidAudio
import Foundation

// Explicit local directory: no mutable-main download or implicit network access.
@main struct ModelBench {
    static let usage = "Usage: ModelBench MODEL_DIRECTORY (AUDIO_FILE [--single] | --serve) [--ctc CTC_DIRECTORY --vocabulary VOCABULARY_JSON]"

    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        // Dictionary support: the pinned CTC model rescores the transcript toward the vocabulary.
        var ctc: URL?, vocabulary: URL?
        if let index = arguments.firstIndex(of: "--ctc"), index + 3 < arguments.count,
           arguments[index + 2] == "--vocabulary" {
            ctc = URL(fileURLWithPath: arguments[index + 1]); vocabulary = URL(fileURLWithPath: arguments[index + 3])
            arguments.removeSubrange(index...(index + 3))
        }
        guard arguments.contains("--ctc") == false, arguments.contains("--vocabulary") == false else {
            throw NSError(domain: usage, code: 1)
        }
        if arguments.count == 2 && arguments[1] == "--serve" {
            try await serve(models: URL(fileURLWithPath: arguments[0]), ctc: ctc, vocabulary: vocabulary); return
        }
        let single = arguments.count == 3 && arguments[2] == "--single"
        guard arguments.count == 2 || single else { throw NSError(domain: usage, code: 1) }
        let manager = UnifiedAsrManager()
        let start = Date()
        try await manager.loadModels(from: URL(fileURLWithPath: arguments[0]))
        let (dictionary, vocabularyError) = await Dictionary.load(ctc: ctc, vocabulary: vocabulary)
        let loaded = Date()
        let samples = try readSamples(arguments[1])
        let prepared = Date()
        let text = try await transcribe(samples, manager, dictionary)
        let coldDone = Date()
        var output: [String: Any] = ["text": text,
            "load_seconds": loaded.timeIntervalSince(start),
            "audio_prepare_seconds": prepared.timeIntervalSince(loaded),
            "cold_transcribe_seconds": coldDone.timeIntervalSince(prepared),
            "vocabulary_terms": dictionary?.terms ?? 0, "vocabulary_error": vocabularyError]
        if !single {
            output["warm_text"] = try await transcribe(samples, manager, dictionary)
            output["warm_transcribe_seconds"] = Date().timeIntervalSince(coldDone)
        }
        try emit(output)
    }

    /// Loads the model once, prints {"ready":true}, then answers one JSON line per audio path read
    /// from stdin until stdin closes. A failed request answers {"error":…} and the server keeps going.
    /// A line `{"boundary": PATH}` (a clip spanning a cut between two recording chunks) answers
    /// {"replacements":[{"from":…,"to":…}]}: the dictionary replacements kept in that clip, so the
    /// app can repair a term the cut split. Without dictionary support it answers none.
    static func serve(models: URL, ctc: URL?, vocabulary: URL?) async throws {
        let manager = UnifiedAsrManager()
        let start = Date()
        try await manager.loadModels(from: models)
        let (dictionary, vocabularyError) = await Dictionary.load(ctc: ctc, vocabulary: vocabulary)
        try emit(["ready": true, "load_seconds": Date().timeIntervalSince(start), "vocabulary_terms": dictionary?.terms ?? 0, "vocabulary_error": vocabularyError])
        while let line = readLine() {
            if line.hasPrefix("{") {
                let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                guard let clip = request?["boundary"] as? String else { try emit(["error": "unknown request"]); continue }
                let found = (try? await boundaryReplacements(clip, manager, dictionary)) ?? []
                try emit(["replacements": found.map { ["from": $0.from, "to": $0.to] }])
                continue
            }
            let path = line
            let begin = Date()
            do {
                let samples = try readSamples(path)
                let prepared = Date()
                let text = try await transcribe(samples, manager, dictionary)
                try emit(["text": text, "audio_prepare_seconds": prepared.timeIntervalSince(begin),
                          "warm_transcribe_seconds": Date().timeIntervalSince(prepared)])
            } catch {
                try emit(["error": "transcription failed"])
            }
        }
    }

    /// Dictionary support: the pinned CTC model rescores each transcript toward the user's terms,
    /// then BoostFilter keeps only replacements of words that are not ordinary English (or listed
    /// aliases, or joined spellings). FluidAudio reads the CTC tokenizer from its default cache
    /// directory, so the app installs the CTC model there.
    struct Dictionary {
        let session: VocabularyBoostingSession
        let aliases: Set<String>
        let terms: Int

        /// Never fails transcription: any vocabulary or CTC error means no boosting, reported as
        /// `vocabulary_error` (content-free) so the app can say dictionary support is unavailable.
        static func load(ctc: URL?, vocabulary: URL?) async -> (Dictionary?, Bool) {
            do { return (try await Dictionary(ctc: ctc, vocabulary: vocabulary), false) } catch { return (nil, true) }
        }

        /// Reads `{"terms":[{"text":…,"aliases":[…]}]}` (FluidAudio's vocabulary JSON) and tokenizes
        /// each term with the CTC tokenizer. nil when no vocabulary was given or none is usable.
        init?(ctc: URL?, vocabulary: URL?) async throws {
            guard let ctc, let vocabulary else { return nil }
            let context = try CustomVocabularyContext.load(from: vocabulary)
            let tokenizer = try await CtcTokenizer.load(from: ctc)
            let terms = context.terms.compactMap { term -> CustomVocabularyTerm? in
                let ids = tokenizer.encode(term.text)
                return ids.isEmpty ? nil : CustomVocabularyTerm(text: term.text, weight: term.weight, aliases: term.aliases,
                                                                 ctcTokenIds: ids, minSimilarity: term.minSimilarity)
            }
            guard !terms.isEmpty else { return nil }
            let tokenized = CustomVocabularyContext(terms: terms, alpha: context.alpha, minCtcScore: context.minCtcScore,
                                                    minSimilarity: context.minSimilarity,
                                                    minCombinedConfidence: context.minCombinedConfidence,
                                                    minTermLength: context.minTermLength)
            session = try await VocabularyBoostingSession(vocabulary: tokenized, ctcModels: try await CtcModels.loadDirect(from: ctc),
                                                          config: VocabularyBoostingSession.itnDefaultConfig)
            aliases = Set(terms.flatMap { $0.aliases ?? [] }.map { BoostFilter.words($0).map(\.folded).joined(separator: " ") })
            self.terms = terms.count
        }
    }

    static func transcribe(_ samples: [Float], _ manager: UnifiedAsrManager, _ dictionary: Dictionary?) async throws -> String {
        guard let dictionary else { return try await manager.transcribe(samples) }
        let raw = try await manager.transcribeWithTimings(samples)
        guard let rescored = await dictionary.session.rescore(text: raw.text, tokenTimings: raw.tokenTimings, audioSamples: samples),
              rescored.text != raw.text else { return raw.text }
        return await MainActor.run {
            BoostFilter.filter(raw: raw.text, rescored: rescored.text, aliases: dictionary.aliases, isCommonWord: isCommonEnglishWord)
        }
    }

    static func boundaryReplacements(_ path: String, _ manager: UnifiedAsrManager, _ dictionary: Dictionary?) async throws -> [(from: String, to: String)] {
        guard let dictionary else { return [] }
        let samples = try readSamples(path)
        let raw = try await manager.transcribeWithTimings(samples)
        guard let rescored = await dictionary.session.rescore(text: raw.text, tokenTimings: raw.tokenTimings, audioSamples: samples),
              rescored.text != raw.text else { return [] }
        return await MainActor.run {
            BoostFilter.replacements(raw: raw.text, rescored: rescored.text, aliases: dictionary.aliases, isCommonWord: isCommonEnglishWord)
                .map { ($0.from, $0.to) }
        }
    }

    /// Same lexicon as the app's learning filter: a word is ordinary when the English spell checker
    /// finds no misspelling in it. Main thread only.
    @MainActor static func isCommonEnglishWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    static func readSamples(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.length > 0, file.length <= Int64(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)) else {
            throw NSError(domain: "Invalid or oversized audio", code: 2)
        }
        try file.read(into: buffer)
        return try AudioConverter().resampleBuffer(buffer)
    }

    static func emit(_ object: [String: Any]) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
        fflush(stdout)
    }
}
