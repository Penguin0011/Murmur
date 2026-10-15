import Foundation

// Checks for Insights.swift (gap #19). Run from the repository root (macOS or Linux):
// swiftc app/Insights.swift app/check_insights.swift -o /tmp/murmur-insights-check && /tmp/murmur-insights-check

nonisolated(unsafe) var failures = 0
func check(_ condition: Bool, _ name: String) {
    if !condition { failures += 1; print("FAIL: \(name)") }
}
func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.001 } ?? false }

func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!; return calendar
}
let utc = calendar("UTC")
/// Noon UTC on 2026-10-15.
let now = Date(timeIntervalSince1970: 1_792_065_600)
func item(_ daysAgo: Double, raw: String = "hello there", final: String? = nil, seconds: Double? = nil, app: String? = nil) -> InsightsItem {
    InsightsItem(recordedAt: now.addingTimeInterval(-daysAgo * 86400), rawText: raw, finalText: final ?? raw, seconds: seconds, app: app)
}
func stats(_ items: [InsightsItem], calendar: Calendar = utc, at: Date = now) -> Insights.Stats? {
    if case .stats(let stats) = Insights.compute(items, historyOn: true, now: at, calendar: calendar) { return stats }
    return nil
}

@main struct InsightsChecks {
    static func main() {
        // History off or empty says so instead of showing zeros.
        check(Insights.compute([item(0)], historyOn: false, now: now, calendar: utc) == .historyOff, "history off hides counts even with session-only entries")
        check(Insights.compute([], historyOn: true, now: now, calendar: utc) == .empty, "empty or expired history")
        check(Insights.compute([item(0, raw: "um", final: "")], historyOn: true, now: now, calendar: utc) == .empty, "held and filler-only entries produced no text")

        // Pace: five-character words per minute of speech, against 51.56 typed.
        // 50 characters = 10 standard words in 6 s = 100 WPM.
        let paced = stats([item(0, raw: "abcd abcd abcd abcd abcd abcd abcd abcd abcd abcde", seconds: 6)])
        check(near(paced?.wordsPerMinute, 100), "WPM uses five-character words")
        // Typing 10 standard words at 51.56 WPM takes 11.637 s; speaking took 6 s.
        check(near(paced?.secondsSaved, 10 / 51.56 * 60 - 6), "time saved is typing time minus speaking time")
        check(paced?.words == 10 && paced?.timedDictations == 1, "plain word count and timed count")
        // Pace over several entries is total words over total time, not an average of averages.
        let mixed = stats([item(0, raw: String(repeating: "x", count: 50), seconds: 6), item(0, raw: String(repeating: "x", count: 50), seconds: 18)])
        check(near(mixed?.wordsPerMinute, 20 / (24.0 / 60)), "pace pools words and time")
        // Slow speech never shows negative time saved.
        check(near(stats([item(0, raw: "short", seconds: 60)])?.secondsSaved, 0), "time saved is clamped at zero")
        // Entries from before durations were recorded count as words but not pace.
        let untimed = stats([item(0, raw: "one two three")])
        check(untimed?.wordsPerMinute == nil && untimed?.secondsSaved == nil && untimed?.words == 3 && untimed?.timedDictations == 0, "untimed entries have no pace")
        check(Insights.duration(40) == "40 s" && Insights.duration(720) == "12 min" && Insights.duration(3900) == "1 h 5 min", "duration text")

        // Words changed by cleanup and dictionary fixes.
        check(Insights.wordsChanged(raw: "um so the meeting is at three", final: "So the meeting is at 3.") == 3, "filler removed, capital, number")
        check(Insights.wordsChanged(raw: "same words", final: " same words") == 0, "leading space from insertion is not a change")
        check(Insights.wordsChanged(raw: "ship it to cube control", final: "ship it to kubectl") == 2, "two heard words become one")
        check(stats([item(0, raw: "um hello", final: "Hello")])?.wordsChanged == 2, "stats sum word changes")

        // Apps, where History has them.
        let apps = stats([item(0, app: "com.apple.TextEdit"), item(0, app: "com.apple.mail"), item(1, app: "com.apple.mail"), item(1)])
        check(apps?.apps == [.init(app: "com.apple.mail", count: 2), .init(app: "com.apple.TextEdit", count: 1)] && apps?.withoutApp == 1, "apps ranked, unknown counted apart")

        // Streaks.
        check(stats([item(0), item(1), item(2), item(5), item(6)]).map { [$0.currentStreak, $0.longestStreak] } == [3, 3], "current and longest")
        check(stats([item(1), item(2)])?.currentStreak == 2, "a streak ending yesterday is still current")
        check(stats([item(2), item(3), item(4), item(5)]).map { [$0.currentStreak, $0.longestStreak] } == [0, 4], "a missed day ends the current streak")
        check(stats([item(0), item(0.1), item(0.2)]).map { [$0.days.count, $0.currentStreak] } == [1, 1], "several dictations in one day count once")
        // The same instants fall on different local days in different time zones.
        // 23:30 UTC on Oct 14 and 00:30 UTC on Oct 15 are two days in UTC, one day (Oct 14) in New York.
        let lateUTC = Date(timeIntervalSince1970: 1_792_020_600), earlyUTC = Date(timeIntervalSince1970: 1_792_024_200)
        let pair = [InsightsItem(recordedAt: lateUTC, rawText: "a", finalText: "a", seconds: nil, app: nil),
                    InsightsItem(recordedAt: earlyUTC, rawText: "a", finalText: "a", seconds: nil, app: nil)]
        check(stats(pair, calendar: utc).map { [$0.days.count, $0.longestStreak] } == [2, 2], "two UTC days")
        check(stats(pair, calendar: calendar("America/New_York")).map { [$0.days.count, $0.longestStreak] } == [1, 1], "one New York day")
        // In Tokyo both are Oct 15 and "now" (noon UTC) is 21:00 Oct 15: a current streak of 1.
        check(stats(pair, calendar: calendar("Asia/Tokyo"))?.currentStreak == 1, "Tokyo today")
        // A daylight-saving change (Nov 1, 2026 in New York has 25 hours) does not break a streak.
        let newYork = calendar("America/New_York")
        let dstDays = (0..<4).map { newYork.date(from: DateComponents(year: 2026, month: 10, day: 30 + $0, hour: 9))! }
        let afterDST = newYork.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 18))!
        let dstItems = dstDays.map { InsightsItem(recordedAt: $0, rawText: "a", finalText: "a", seconds: nil, app: nil) }
        check(stats(dstItems, calendar: newYork, at: afterDST).map { [$0.currentStreak, $0.longestStreak] } == [4, 4], "streak across a DST change")

        if failures > 0 { print("\(failures) insights check(s) failed"); exit(1) }
        print("Insights checks passed.")
    }
}
