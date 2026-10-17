import Foundation

// Home and Insights (gap #19): counted on this Mac from the History entries Murmur still keeps.
// Nothing here is stored or sent anywhere. Foundation only, so app/check_insights.swift runs alone.

/// What Insights needs from one History entry.
struct InsightsItem: Equatable {
    let recordedAt: Date
    let rawText: String
    let finalText: String
    /// Recording length; nil for entries saved before Murmur recorded it.
    let seconds: Double?
    /// Bundle ID of the app the text was pasted into; nil when unknown or not pasted.
    let app: String?
}

enum Insights: Equatable {
    /// History is off, so nothing is kept to count.
    case historyOff
    /// History is on but holds nothing: nothing dictated yet, or it has all expired.
    case empty
    case stats(Stats)

    struct AppCount: Equatable { let app: String; let count: Int; var words: Int = 0 }

    struct Stats: Equatable {
        var recordingSeconds: Double?
        var dailyWords: [Date: Int] = [:]
        var hourlyDictations = Array(repeating: 0, count: 24)
        var averageWords: Double { dictations > 0 ? Double(words) / Double(dictations) : 0 }
        var dictations = 0
        /// Words in the text Murmur produced.
        var words = 0
        /// Speaking pace in five-character words per minute, from entries with a recorded length.
        var wordsPerMinute: Double?
        /// Typing the same text at `typingWPM` minus the time spent speaking it, never below zero.
        var secondsSaved: Double?
        /// Dictations that have a recorded length (pace and time saved count only these).
        var timedDictations = 0
        /// Words that differ between the raw transcript and the final text.
        var wordsChanged = 0
        /// Most words first; ties by bundle ID so the order is stable.
        var apps: [AppCount] = []
        /// Dictations with no app recorded.
        var withoutApp = 0
        /// Start of each local day with at least one dictation.
        var days: Set<Date> = []
        var currentStreak = 0
        var longestStreak = 0
    }

    /// Average typing speed: 51.56 WPM (SD 20.2) over 168,000 volunteers copying sentences in an online
    /// test, where one word is any five characters. Dhakal, Feit, Kristensson and Oulasvirta,
    /// "Observations on Typing from 136 Million Keystrokes", CHI 2018, doi:10.1145/3173574.3174220.
    /// Copying is faster than composing, so time saved against it is conservative.
    static let typingWPM = 51.56

    /// `historyOn` is the applied History mode. With History off, session-only entries are not counted:
    /// they vanish at quit, so a streak or total from them would mislead.
    static func compute(_ items: [InsightsItem], historyOn: Bool, now: Date, calendar: Calendar) -> Insights {
        guard historyOn else { return .historyOff }
        let used = items.filter { !$0.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !used.isEmpty else { return .empty }
        var stats = Stats()
        var spoken = 0.0, seconds = 0.0, saved = 0.0
        var apps: [String: Int] = [:], appWords: [String: Int] = [:]
        for item in used {
            let final = item.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            stats.dictations += 1
            let count = words(final).count
            stats.words += count
            stats.dailyWords[calendar.startOfDay(for: item.recordedAt), default: 0] += count
            stats.hourlyDictations[calendar.component(.hour, from: item.recordedAt)] += 1
            stats.wordsChanged += wordsChanged(raw: item.rawText, final: final)
            if let length = item.seconds, length.isFinite, length > 0 {
                stats.timedDictations += 1
                spoken += standardWords(item.rawText); seconds += length
                saved += standardWords(final) / typingWPM * 60 - length
            }
            if let app = item.app, !app.isEmpty { apps[app, default: 0] += 1; appWords[app, default: 0] += count } else { stats.withoutApp += 1 }
            stats.days.insert(calendar.startOfDay(for: item.recordedAt))
        }
        if seconds > 0 { stats.recordingSeconds = seconds; stats.wordsPerMinute = spoken / (seconds / 60); stats.secondsSaved = max(0, saved) }
        stats.apps = apps.map { AppCount(app: $0.key, count: $0.value, words: appWords[$0.key, default: 0]) }
            .sorted { $0.words != $1.words ? $0.words > $1.words : $0.app < $1.app }
        (stats.currentStreak, stats.longestStreak) = streaks(stats.days, now: now, calendar: calendar)
        return .stats(stats)
    }

    static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
    }

    /// The typing-test word: five characters, spaces included.
    static func standardWords(_ text: String) -> Double {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines).count) / 5
    }

    /// Replaced, removed or added words between raw and final, a replacement counting once.
    /// It sees cleanup, dictionary spellings applied after transcription and edits made in History
    /// (gap #10); the local model's own vocabulary pass happens before the raw text, so it is not seen.
    static func wordsChanged(raw: String, final: String) -> Int {
        let diff = words(final).map(String.init).difference(from: words(raw).map(String.init))
        return max(diff.insertions.count, diff.removals.count)
    }

    /// Days in a row with a dictation. The current streak still counts when the last one was
    /// yesterday, since today is not over. Days come from `calendar`, so its time zone decides them.
    static func streaks(_ days: Set<Date>, now: Date, calendar: Calendar) -> (current: Int, longest: Int) {
        let sorted = days.sorted()
        var longest = 0, run = 0
        var previous: Date?
        for day in sorted {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day { run += 1 } else { run = 1 }
            longest = max(longest, run); previous = day
        }
        let today = calendar.startOfDay(for: now)
        var current = 0
        var cursor = days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while days.contains(cursor) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return (current, longest)
    }

    /// "12 min", "1 h 5 min", "40 s".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
