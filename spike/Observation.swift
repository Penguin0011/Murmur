import Foundation

struct TermCorrection: Hashable {
    let source: String
    let target: String
}

/// Pure snapshots only: the caller owns AX access, monotonic time, focus identity and polling.
/// Start only after verified insertion, in a nonsecure field with readable value/selection.
struct DictationObservation {
    let sessionID: UUID
    private let initial: String
    private let prefix: String
    private let suffix: String
    private let start: TimeInterval
    private(set) var range: NSRange
    private(set) var stopped = false
    private(set) var stopReason: String?
    private(set) var candidate: TermCorrection?

    init?(sessionID: UUID = UUID(), value: String, insertedRange: NSRange, now: TimeInterval) {
        let text = value as NSString
        guard now.isFinite, insertedRange.location >= 0, insertedRange.length > 0,
              insertedRange.location <= text.length,
              insertedRange.length <= text.length - insertedRange.location,
              Range(insertedRange, in: value) != nil,
              Self.validBoundaries(insertedRange, text) else { return nil }
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
        guard now.isFinite, now >= start, now - start < 60 else { return stop("window ended") }
        guard sameFocusedField, readableNonsecure else { return stop("focus or access lost") }
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
        guard Range(updatedRange, in: value) != nil, Self.validBoundaries(updatedRange, text),
              selection.location >= updatedRange.location,
              selection.length >= 0, selection.location <= NSMaxRange(updatedRange),
              selection.length <= NSMaxRange(updatedRange) - selection.location,
              Range(selection, in: value) != nil, Self.validBoundaries(selection, text) else { return stop("selection left dictated span") }
        let current = text.substring(with: updatedRange)
        // Any growth at the end could be ordinary appended typing. Do not attribute it as a correction.
        guard current == initial || !current.hasPrefix(initial) else { return stop("appended text") }
        range = updatedRange
        candidate = Self.replacement(initial, current)
        return candidate
    }

    /// Finish after a final snapshot; evidence remains reversible by session ID in the ledger.
    mutating func finish() { stopped = true; stopReason = stopReason ?? "finished" }

    private mutating func stop(_ reason: String) -> TermCorrection? {
        stopped = true
        stopReason = reason
        // A valid prior correction may survive a normal focus departure/expiry. An invalidating
        // edit/selection change removes it because attribution is no longer established.
        if reason != "window ended" && reason != "focus or access lost" { candidate = nil }
        return candidate
    }

    private static func validBoundaries(_ range: NSRange, _ text: NSString) -> Bool {
        for offset in [range.location, NSMaxRange(range)] where offset > 0 && offset < text.length {
            if (0xD800...0xDBFF).contains(text.character(at: offset - 1)) &&
                (0xDC00...0xDFFF).contains(text.character(at: offset)) { return false }
        }
        return true
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
    _ = appended.observe(value: "🙂 Acme done more", selection: NSRange(location: 12, length: 0), now: 1,
                         sameFocusedField: true, readableNonsecure: true)
    assert(appended.stopped && appended.candidate == nil)
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
    print("Observation checks passed")
}
