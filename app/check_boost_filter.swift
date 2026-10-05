import Foundation

// Checks for the dictionary rescoring filter in the transcription helper.
// swiftc module-one/models/Runner/Sources/ModelBench/BoostFilter.swift app/check_boost_filter.swift -o /tmp/murmur-boost-check && /tmp/murmur-boost-check

private var failures = 0, passes = 0
private func check(_ condition: Bool, _ label: String, line: Int = #line) {
    if condition { passes += 1 } else { failures += 1; print("FAIL [line \(line)]: \(label)") }
}

// A tiny stand-in for the spell checker's lexicon.
private let common: Set<String> = ["i", "mean", "it", "is", "not", "a", "big", "deal", "nothing", "else", "option", "works", "for", "me",
    "remind", "to", "call", "dad", "getting", "the", "build", "green", "open", "router", "through", "calls", "basin", "store", "rows", "in",
    "coming", "like", "that", "run", "get", "pods", "send", "report", "cube", "cuddle", "have", "seen", "neither", "she", "said", "i'm"]
private func f(_ raw: String, _ rescored: String, aliases: Set<String> = []) -> String {
    BoostFilter.filter(raw: raw, rescored: rescored, aliases: aliases, isCommonWord: { common.contains($0) })
}

@main struct BoostFilterChecks {
    static func main() {
        // Measured false positives (synthetic speech, 20-term dictionary): restored.
        check(f("Output the word approved and nothing else.", "Output the word approved and Notion else.") == "Output the word approved and nothing else.", "nothing -> Notion reverted")
        check(f("Neither option works for me.", "Neither Notion works for me.") == "Neither option works for me.", "option -> Notion reverted")
        check(f("She said, um, I'm not coming.", "She said, um, I'm Notion") == "She said, um, I'm not coming.", "two common words -> one term reverted")
        check(f("Remind me to call dad at 7.", "Gemini me to call dad at 7.") == "Remind me to call dad at 7.", "sentence-initial common word reverted")
        check(f("I mean, it is not a big deal.", "I Sean, it is not a big deal.") == "I mean, it is not a big deal.", "mean -> Sean reverted")
        // Measured true positives: kept.
        check(f("Run cubectal get pods.", "Run kubectl get pods.") == "Run kubectl get pods.", "misheard non-word kept")
        check(f("Send the ShelfMud report.", "Send the Shelfmate report.") == "Send the Shelfmate report.", "ShelfMud kept")
        check(f("Store the Rosin Supa Basin root calls through open router.", "Store the Rosin Supabase root calls through OpenRouter") == "Store the Rosin Supabase root calls through OpenRouter.", "partly common span and joined spelling kept")
        check(f("Push the change to CloudEv now.", "Push the change to Clouddev now.") == "Push the change to Clouddev now.", "CloudEv kept")
        // A listed alias is kept even when its words are ordinary.
        check(f("run cube cuddle now", "run kubectl now", aliases: ["cube cuddle"]) == "run kubectl now", "alias of common words kept")
        check(f("run cube cuddle now", "run kubectl now") == "run cube cuddle now", "unlisted common words reverted")
        // Mixed: one kept, one reverted, in the same text.
        check(f("Run cubectal, I mean nothing else.", "Run kubectl, I Sean Notion else.") == "Run kubectl, I mean nothing else.", "per-span decisions")
        check(f("Unchanged text.", "Unchanged text.") == "Unchanged text.", "identical text")
        check(f("Ask Priya about it.", "Ask Notion it.") == "Ask Priya about it.", "a name is not swallowed with its neighbours")
        check(BoostFilter.similarity("akash", "aakash") > 0.8 && BoostFilter.similarity("", "") == 1, "similarity")
        check(f("Nor does it support offline mode.", "Nor does it support offline mode") == "Nor does it support offline mode.", "punctuation the rescorer dropped is kept")
        check(f("Bring it, I mean, if you can.", "Bring it, I Sean if you can.") == "Bring it, I mean, if you can.", "punctuation around a reverted span is kept")
        check(f("", "") == "", "empty")
        print("\(passes) checks passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
