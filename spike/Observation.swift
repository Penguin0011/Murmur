import Foundation

struct TermCorrection: Hashable {
    let source: String
    let target: String
}

/// Pure snapshots only: the caller owns AX access, monotonic time, focus identity and polling.
/// Start only after verified insertion, in a nonsecure field with readable value/selection.
struct DictationObservation {
    let sessionID: UUID
    /// The dictated span as inserted, original casing.
    let initial: String
    private let prefix: String
    private let suffix: String
    private let start: TimeInterval
    private(set) var range: NSRange
    private(set) var stopped = false
    private(set) var stopReason: String?
    private(set) var candidate: TermCorrection?
    /// The span's current text, original casing; nil once attribution is lost. The app feeds
    /// `initial` -> `edited` to the ledger, whose filter is broader than `candidate`'s one-letter rule.
    private(set) var edited: String?

    init?(sessionID: UUID = UUID(), value: String, insertedRange: NSRange, now: TimeInterval) {
        let text = value as NSString
        guard now.isFinite, insertedRange.location >= 0, insertedRange.length > 0,
              insertedRange.location <= text.length,
              insertedRange.length <= text.length - insertedRange.location,
              Range(insertedRange, in: value) != nil,
              Self.validBoundaries(insertedRange, value) else { return nil }
        // A span cutting a word cannot establish a whole-word correction.
        let before = text.substring(to: insertedRange.location)
        let inserted = text.substring(with: insertedRange)
        let after = text.substring(from: NSMaxRange(insertedRange))
        guard !(before.last?.isLetter == true && inserted.first?.isLetter == true),
              !(inserted.last?.isLetter == true && after.first?.isLetter == true) else { return nil }
        self.sessionID = sessionID
        self.initial = text.substring(with: insertedRange)
        self.prefix = text.substring(to: insertedRange.location)
        self.suffix = text.substring(from: NSMaxRange(insertedRange))
        self.range = insertedRange
        self.start = now
    }

    /// Returned evidence is provisional: replace this session's evidence on every snapshot.
    /// Call even on unchanged snapshots so expiry/focus/permission changes stop observation.
    mutating func observe(value: String, selection: NSRange, now: TimeInterval,
                          sameFocusedField: Bool, readableNonsecure: Bool) -> TermCorrection? {
        guard !stopped else { return candidate }
        guard readableNonsecure else { return stop("access or security lost") }
        guard now.isFinite, now >= start else { return stop("invalid clock") }
        guard sameFocusedField else { return stop("focus departed") }
        guard now - start < 60 else { return stop("window ended") }
        let text = value as NSString
        let prefixLength = (prefix as NSString).length
        let suffixLength = (suffix as NSString).length
        // ponytail: exact outside anchors reject even harmless outside edits; richer alignment needs live evidence.
        guard text.length >= prefixLength + suffixLength,
              text.substring(to: prefixLength) == prefix,
              text.substring(from: text.length - suffixLength) == suffix else {
            return stop("outside anchors changed")
        }
        let updatedRange = NSRange(location: prefixLength, length: text.length - prefixLength - suffixLength)
        guard Range(updatedRange, in: value) != nil, Self.validBoundaries(updatedRange, value),
              selection.location >= updatedRange.location,
              selection.length >= 0, selection.location <= NSMaxRange(updatedRange),
              selection.length <= NSMaxRange(updatedRange) - selection.location,
              Range(selection, in: value) != nil, Self.validBoundaries(selection, value) else { return stop("selection left dictated span") }
        // Text typed after the span stays in it; the ledger's word diff ignores added words.
        let current = text.substring(with: updatedRange)
        // A chat composer empties when Return sends it: keep the fix made before that.
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return stop("span cleared") }
        range = updatedRange
        edited = current
        candidate = Self.replacement(initial, current)
        return candidate
    }

    /// Finish after a final snapshot; evidence remains reversible by session ID in the ledger.
    mutating func finish() { stopped = true; stopReason = stopReason ?? "finished" }

    private mutating func stop(_ reason: String) -> TermCorrection? {
        stopped = true
        stopReason = reason
        // A valid prior correction survives focus departure, expiry or the caret moving elsewhere
        // (the text it was read from is unchanged). An invalidating edit removes it.
        if !["window ended", "focus departed", "selection left dictated span", "span cleared"].contains(reason) { candidate = nil; edited = nil }
        return candidate
    }

    private static func validBoundaries(_ range: NSRange, _ value: String) -> Bool {
        // AX offsets are UTF16; NSString accepts surrogate/combining/ZWJ fragments.
        // ponytail: linear boundary scan; indexed boundaries if large-field polling proves expensive.
        var offset = 0
        var boundaries: Set<Int> = [0]
        for character in value {
            offset += String(character).utf16.count
            boundaries.insert(offset)
        }
        return boundaries.contains(range.location) && boundaries.contains(NSMaxRange(range))
    }

    private static func oneLetterEdit(_ source: String, _ target: String) -> Bool {
        let a = Array(source), b = Array(target)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count >= b.count { i += 1 }
            if b.count >= a.count { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) == 1
    }

    private static func replacement(_ original: String, _ current: String) -> TermCorrection? {
        let before = original.components(separatedBy: " ")
        let after = current.components(separatedBy: " ")
        guard before.count == after.count else { return nil }
        let changes = before.indices.filter { before[$0] != after[$0] }
        guard changes.count == 1, let index = changes.first else { return nil }
        let source = before[index].lowercased()
        let target = after[index].lowercased()
        guard source != target, source.count >= 3, target.count >= 3,
              source.count <= 40, target.count <= 40,
              source.unicodeScalars.allSatisfy(CharacterSet.letters.contains),
              target.unicodeScalars.allSatisfy(CharacterSet.letters.contains),
              oneLetterEdit(source, target) else { return nil }
        // Structural candidate only. Even one letter can change meaning; ledger needs an eligibility gate.
        return TermCorrection(source: source, target: target)
    }
}

/// Stand-in for a field with no readable text (VS Code's stub, web canvases): a virtual copy of
/// the pasted span, edited by the keys typed after it, starting with the caret at its end. Its
/// `value`/`selection` feed `DictationObservation` as snapshots with no text around the span.
/// `lost` (a ⌘/⌃ chord such as undo, or an edit outside the span) drops the evidence; `departed`
/// (Return, Tab, vertical caret keys, or the caret leaving the span) keeps it, like focus departure.
/// After a click the caret could be anywhere: every caret position and every selection of 1–3 whole words
/// is followed at once, and the span reads as the single edit `resolve` finds plausible.
/// ponytail: the target app's own autocorrect/autocomplete is invisible here; the ledger's filter
/// and two-session rule are the backstop. Read the field instead wherever AX exposes it.
struct KeystrokeSpan {
    enum Key: Equatable {
        case text(String), backspace(word: Bool), forwardDelete
        case left(word: Bool, extend: Bool), right(word: Bool, extend: Bool), other
    }
    enum State { case editing, departed, lost }
    private(set) var chars: [Character]
    private(set) var state = State.editing
    private var anchor: Int, caret: Int
    /// Where the caret might be after a click; empty while its position is known.
    private var guesses: [KeystrokeSpan] = []
    private var typedSinceClick = false
    private var unresolved = false
    /// Picks the plausible reading among the guesses (the ledger's filter in the app).
    var resolve: ([String]) -> String? = { _ in nil }

    init(_ text: String) { chars = Array(text); anchor = chars.count; caret = chars.count }
    private init(_ chars: [Character], anchor: Int, caret: Int) { self.chars = chars; self.anchor = anchor; self.caret = caret }

    var value: String { String(chars) }
    /// UTF16 range, as AX reports selections. Unknown after a click: the span start stands in.
    var selection: NSRange {
        if !guesses.isEmpty { return NSRange(location: 0, length: 0) }
        func utf16(_ index: Int) -> Int { String(chars[..<index]).utf16.count }
        let low = min(anchor, caret), high = max(anchor, caret)
        return NSRange(location: utf16(low), length: utf16(high) - utf16(low))
    }

    mutating func depart() { if state == .editing { state = .departed } }

    /// Takes the plausible reading of the guesses as `value`. Resolving runs the ledger's filter
    /// (tens of ms on a long span), so the app calls this on its poll, not per keystroke.
    mutating func refresh() {
        guard unresolved else { return }
        unresolved = false
        if let reading = resolve(guesses.map(\.value)) { chars = Array(reading) }
    }

    /// A click in the app (a double-click is two). A click after typing that still has no
    /// plausible reading ends the watch; otherwise the guesses restart from the current text.
    /// ponytail: one guess per caret position and word, O(span length) work per key; bound the
    /// span if very long dictations make keystrokes lag.
    mutating func click() {
        guard state == .editing else { return }
        if typedSinceClick {
            guard let reading = resolve(guesses.map(\.value)) else { state = .departed; return }
            chars = Array(reading)
        }
        typedSinceClick = false; unresolved = false
        let words = chars.indices.filter { isWord(chars[$0]) && ($0 == 0 || !isWord(chars[$0 - 1])) }
        // Selections of 1–3 whole words cover a double-click and a mouse drag across a spacing fix
        // (git hub → GitHub); the ledger learns at most 3 words per side.
        guesses = (0...chars.count).map { KeystrokeSpan(chars, anchor: $0, caret: $0) }
            + words.flatMap { start in
                var end = start
                return (0..<3).compactMap { _ -> KeystrokeSpan? in
                    end = wordEnd(after: end)
                    return end <= chars.count ? KeystrokeSpan(chars, anchor: start, caret: end) : nil
                }
            }
    }

    mutating func apply(_ key: Key) {
        guard state == .editing else { return }
        if !guesses.isEmpty {
            if key == .other { state = .lost; return }
            typedSinceClick = true
            var seen = Set<String>()
            let next = guesses.compactMap { guess -> KeystrokeSpan? in
                var next = guess
                next.apply(key)
                return next.state == .editing && seen.insert("\(next.anchor) \(next.caret) \(next.value)").inserted ? next : nil
            }
            // Return or a caret key ends the edit: settle what was typed before it.
            if next.isEmpty { refresh(); state = .departed; return }
            guesses = next
            unresolved = true
            return
        }
        let low = min(anchor, caret), high = max(anchor, caret)
        switch key {
        case .text(let text):
            // Return, Tab, Escape (control) and arrow/Home/End/Page keys (private-use U+F700...) end the
            // edit (a chat sends, the caret moves away) without undoing it.
            guard !text.isEmpty else { state = .lost; return }
            guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) || (0xF700...0xF8FF).contains($0.value) }) else { state = .departed; return }
            chars.replaceSubrange(low..<high, with: Array(text)); caret = low + text.count; anchor = caret
        case .backspace(let word):
            if low < high { remove(low..<high); return }
            let start = word ? wordStart(before: caret) : caret - 1
            guard start >= 0, caret > 0 else { state = .lost; return }
            remove(start..<caret)
        case .forwardDelete:
            if low < high { remove(low..<high); return }
            guard caret < chars.count else { state = .lost; return }
            remove(caret..<caret + 1)
        case .left(let word, let extend):
            var next = !extend && low < high ? low : caret
            if word || extend || low == high { next = word ? wordStart(before: next) : next - 1 }
            guard next >= 0 else { state = .departed; return }
            caret = next; if !extend { anchor = next }
        case .right(let word, let extend):
            var next = !extend && low < high ? high : caret
            if word || extend || low == high { next = word ? wordEnd(after: next) : next + 1 }
            guard next <= chars.count else { state = .departed; return }
            caret = next; if !extend { anchor = next }
        case .other:
            state = .lost
        }
    }

    private mutating func remove(_ range: Range<Int>) { chars.removeSubrange(range); caret = range.lowerBound; anchor = caret }
    private func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" }
    /// macOS Option-Left: skip separators, then the word. -1 when that would leave the span.
    private func wordStart(before index: Int) -> Int {
        var i = index
        while i > 0, !isWord(chars[i - 1]) { i -= 1 }
        guard i > 0 else { return -1 }
        while i > 0, isWord(chars[i - 1]) { i -= 1 }
        return i
    }
    private func wordEnd(after index: Int) -> Int {
        var i = index
        while i < chars.count, !isWord(chars[i]) { i += 1 }
        guard i < chars.count else { return chars.count + 1 }
        while i < chars.count, isWord(chars[i]) { i += 1 }
        return i
    }
}

struct CorrectionEvidence {
    private var sessions: [UUID: TermCorrection] = [:]

    /// Supply final settled evidence only. Updating with nil removes undo/reversion evidence.
    mutating func update(sessionID: UUID, correction: TermCorrection?) {
        sessions[sessionID] = correction
    }

    /// Default denies all candidates. Caller must establish a spelling/known-term relationship;
    /// capitalization, edit size and repetition alone cannot establish preserved meaning.
    func promoted(eligible: (TermCorrection) -> Bool = { _ in false }) -> [TermCorrection] {
        let bySource = Dictionary(grouping: sessions.values, by: \.source)
        return bySource.values.compactMap { corrections in
            guard corrections.count >= 2, Set(corrections.map(\.target)).count == 1,
                  let correction = corrections.first, eligible(correction) else { return nil }
            return correction
        }.sorted { $0.source < $1.source }
    }
}

func runObservationChecks() {
    func tracker(_ value: String = "🙂 Acme done") -> DictationObservation {
        DictationObservation(value: value, insertedRange: NSRange(location: 3, length: 9), now: 0)!
    }
    let corrected = TermCorrection(source: "acme", target: "akme")
    var observation = tracker()
    assert(observation.observe(value: "🙂 Akme done", selection: NSRange(location: 7, length: 0), now: 1,
                               sameFocusedField: true, readableNonsecure: true) == corrected)
    assert(observation.range == NSRange(location: 3, length: 9))
    assert(observation.observe(value: "🙂 Acme done", selection: NSRange(location: 7, length: 0), now: 2,
                               sameFocusedField: true, readableNonsecure: true) == nil)
    var ledger = CorrectionEvidence()
    let first = UUID(), second = UUID(), third = UUID()
    ledger.update(sessionID: first, correction: corrected)
    assert(ledger.promoted(eligible: { $0 == corrected }).isEmpty)
    ledger.update(sessionID: first, correction: corrected)
    assert(ledger.promoted(eligible: { $0 == corrected }).isEmpty)
    ledger.update(sessionID: second, correction: corrected)
    assert(ledger.promoted().isEmpty)
    assert(ledger.promoted(eligible: { $0 == corrected }) == [corrected])
    ledger.update(sessionID: third, correction: TermCorrection(source: "acme", target: "ackme"))
    assert(ledger.promoted(eligible: { _ in true }).isEmpty)
    ledger.update(sessionID: third, correction: nil)
    ledger.update(sessionID: second, correction: nil)
    assert(ledger.promoted(eligible: { _ in true }).isEmpty)
    var outside = tracker()
    _ = outside.observe(value: "x🙂 Acme done", selection: NSRange(location: 7, length: 0), now: 1,
                        sameFocusedField: true, readableNonsecure: true)
    assert(outside.stopped && outside.candidate == nil)
    var appended = tracker()
    _ = appended.observe(value: "🙂 Akme done more", selection: NSRange(location: 12, length: 0), now: 1,
                         sameFocusedField: true, readableNonsecure: true)
    assert(!appended.stopped && appended.edited == "Akme done more")  // a fix, then more typing, stays attributed
    var sent = tracker()
    _ = sent.observe(value: "🙂 Akme done", selection: NSRange(location: 7, length: 0), now: 1, sameFocusedField: true, readableNonsecure: true)
    _ = sent.observe(value: "🙂 ", selection: NSRange(location: 3, length: 0), now: 2, sameFocusedField: true, readableNonsecure: true)
    assert(sent.stopped && sent.edited == "Akme done")  // Return sent the message: the fix stands
    for reset in ["", "\n", " \n\t ", "\r\n", "\u{00A0}"] {
        for prior in [nil, "Acme done", "Akme done"] as [String?] {
            var item = tracker()
            if let prior {
                _ = item.observe(value: "🙂 " + prior, selection: NSRange(location: 3, length: 0), now: 1,
                                 sameFocusedField: true, readableNonsecure: true)
            }
            _ = item.observe(value: "🙂 " + reset, selection: NSRange(location: 3, length: 0), now: 2,
                             sameFocusedField: true, readableNonsecure: true)
            assert(item.stopped && item.stopReason == "span cleared")
            assert(item.edited == prior && item.candidate == (prior == "Akme done" ? corrected : nil))
            _ = item.observe(value: "", selection: NSRange(location: 0, length: 0), now: 3,
                             sameFocusedField: false, readableNonsecure: true)
            assert(item.edited == prior)
        }
    }
    var selection = tracker()
    _ = selection.observe(value: "🙂 Acme done", selection: NSRange(location: 0, length: 0), now: 1,
                          sameFocusedField: true, readableNonsecure: true)
    assert(selection.stopped)
    for reason in ["expiry", "focus", "secure"] {
        var item = tracker()
        _ = item.observe(value: "🙂 Acme done", selection: NSRange(location: 7, length: 0),
                         now: reason == "expiry" ? 60 : 1,
                         sameFocusedField: reason != "focus", readableNonsecure: reason != "secure")
        assert(item.stopped)
    }
    for value in ["🙂 ACME done", "🙂 Acme! done", "🙂 done", "🙂 Acme undone now", "🙂 I decline"] {
        var item = tracker()
        assert(item.observe(value: value, selection: NSRange(location: 3, length: 0), now: 1,
                            sameFocusedField: true, readableNonsecure: true) == nil)
    }
    assert(DictationObservation(value: "🙂", insertedRange: NSRange(location: 1, length: 1), now: 0) == nil)
    for (focused, readable, time, retained) in [(true, false, 2.0, false),
                                                 (false, false, 60.0, false),
                                                 (false, true, 2.0, true),
                                                 (true, true, 60.0, true),
                                                 (true, true, .nan, false)] {
        var item = tracker()
        _ = item.observe(value: "🙂 Akme done", selection: NSRange(location: 7, length: 0), now: 1,
                         sameFocusedField: true, readableNonsecure: true)
        _ = item.observe(value: "", selection: NSRange(location: 0, length: 0), now: time,
                         sameFocusedField: focused, readableNonsecure: readable)
        assert(item.stopped && (item.candidate != nil) == retained)
    }
    for fragment in ["e\u{301}", "👩‍💻", "🇺🇸"] {
        assert(DictationObservation(value: fragment, insertedRange: NSRange(location: 0, length: 1), now: 0) == nil)
    }
    assert(DictationObservation(value: "Acmes", insertedRange: NSRange(location: 0, length: 4), now: 0) == nil)
    var combined = DictationObservation(value: "e\u{301} Acme", insertedRange: NSRange(location: 3, length: 4), now: 0)!
    assert(combined.observe(value: "e\u{301} Akme", selection: NSRange(location: 7, length: 0), now: 1,
                            sameFocusedField: true, readableNonsecure: true) == corrected)
    var splitSelection = DictationObservation(value: "Acme e\u{301}", insertedRange: NSRange(location: 0, length: 7), now: 0)!
    assert(splitSelection.observe(value: "Akme e\u{301}", selection: NSRange(location: 6, length: 0), now: 1,
                                 sameFocusedField: true, readableNonsecure: true) == nil)
    assert(splitSelection.stopped)
    print("Observation checks passed")
}
