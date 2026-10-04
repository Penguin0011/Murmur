import AppKit
import ApplicationServices
import Carbon

enum InsertionPolicy {
    case experimentalFallback, singleAttempt
}

enum InsertionMethod { case accessibility, paste }

/// Choose before writing: native AX and clipboard paste must never both run in app mode.
func insertionMethod(bundleID: String, policy: InsertionPolicy) -> InsertionMethod {
    let pasteApps: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
        "com.google.Chrome.canary", "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.brave.Browser", "com.openai.codex",
        "com.openai.chat", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord"
    ]
    return policy == .singleAttempt && pasteApps.contains(bundleID) ? .paste : .accessibility
}

struct FocusSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let role: String
    let subrole: String
    let value: String?
    let selection: CFRange?
    let secure: Bool
    let browserTypeUnknown: Bool
    var learningEligible: Bool { insertionTextRole(role) && !secure && !browserTypeUnknown && value != nil && selection != nil }
}

struct InsertionResult {
    enum Status: String { case verified, unverified, failed }
    let status: Status
    let detail: String
    let snapshot: FocusSnapshot?
}

enum InsertionError: Error, CustomStringConvertible {
    case unavailable(String)
    var description: String { switch self { case .unavailable(let reason): return reason } }
}

private func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func axString(_ element: AXUIElement, _ name: String) -> String? {
    axAttribute(element, name) as? String
}

func captureFocus() throws -> FocusSnapshot {
    guard AXIsProcessTrusted() else { throw InsertionError.unavailable("Accessibility permission is unavailable; no prompt requested") }
    // frontmostApplication only refreshes when the run loop delivers workspace notifications; polling callers sleep instead.
    RunLoop.current.run(until: Date())
    guard let frontmost = NSWorkspace.shared.frontmostApplication else {
        throw InsertionError.unavailable("No frontmost application")
    }
    let application = AXUIElementCreateApplication(frontmost.processIdentifier)
    func focusedElement(_ owner: AXUIElement) -> (AXUIElement?, AXError) {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &raw)
        guard error == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return (nil, error) }
        return (unsafeBitCast(raw, to: AXUIElement.self), error)
    }
    let systemFocus = focusedElement(AXUIElementCreateSystemWide())
    let appFocus = systemFocus.0 == nil ? focusedElement(application) : (nil, AXError.success)
    guard let element = systemFocus.0 ?? appFocus.0 else {
        throw InsertionError.unavailable("No accessible focused field; frontmost=\(frontmost.bundleIdentifier ?? "unknown") systemAX=\(systemFocus.1.rawValue) appAX=\(appFocus.1.rawValue)")
    }
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success,
          pid == frontmost.processIdentifier,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        throw InsertionError.unavailable("Frontmost application changed during focus capture")
    }
    let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    let role = axString(element, kAXRoleAttribute) ?? "unknown"
    let subrole = axString(element, kAXSubroleAttribute) ?? "unknown"
    // Native AX secure roles and explicit web input-type metadata are rejected.
    let inputType = axString(element, "AXDOMInputType")?.lowercased()
    let protected = axAttribute(element, "AXProtectedContent") as? Bool ?? false
    let secure = (subrole == kAXSecureTextFieldSubrole || role == kAXSecureTextFieldSubrole) || inputType == "password" || protected
    let browsers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary", "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser"]
    let browser = browsers.contains(bundleID)
    let knownWebType = ["text", "search", "email", "url", "tel", "number", "textarea"].contains(inputType ?? "")
    var selection: CFRange?
    if let rawRange = axAttribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(rawRange) == AXValueGetTypeID() {
        let rangeValue = unsafeBitCast(rawRange, to: AXValue.self)
        var range = CFRange()
        if AXValueGetType(rangeValue) == .cfRange && AXValueGetValue(rangeValue, .cfRange, &range) { selection = range }
    }
    return FocusSnapshot(element: element, pid: pid, bundleID: bundleID, role: role, subrole: subrole,
                         value: secure ? nil : axString(element, kAXValueAttribute), selection: secure ? nil : selection,
                         secure: secure, browserTypeUnknown: browser && !knownWebType)
}

func expectedInsertedValue(_ value: String?, selection: CFRange?, text: String) -> String? {
    guard let value, let selection, selection.location >= 0, selection.length >= 0 else { return nil }
    let source = value as NSString
    guard selection.location <= source.length, selection.length <= source.length - selection.location else { return nil }
    let range = NSRange(location: selection.location, length: selection.length)
    func splitsSurrogate(_ offset: Int) -> Bool {
        guard offset > 0 && offset < source.length else { return false }
        return (0xD800...0xDBFF).contains(source.character(at: offset - 1))
            && (0xDC00...0xDFFF).contains(source.character(at: offset))
    }
    guard !splitsSurrogate(range.location), !splitsSurrogate(range.location + range.length),
          Range(range, in: value) != nil else { return nil }
    return source.replacingCharacters(in: range, with: text)
}

func sameDestination(_ original: FocusSnapshot, _ current: FocusSnapshot) -> Bool {
    original.pid == current.pid && original.bundleID == current.bundleID && CFEqual(original.element, current.element) && !current.secure
        && original.role == current.role && original.subrole == current.subrole && insertionTextRole(current.role)
        && original.value == current.value
        && original.selection?.location == current.selection?.location
        && original.selection?.length == current.selection?.length
}

// Unknown context and selected-text replacement leave the transcript unchanged.
func textWithLeadingSpace(_ text: String, value: String?, selection: CFRange?, enabled: Bool) -> String {
    guard enabled, let first = text.first, !first.isWhitespace,
          !#",.!?;:)]}’'""#.contains(first), let value, let selection,
          selection.length == 0, selection.location > 0,
          let prefixRange = Range(NSRange(location: 0, length: selection.location), in: value),
          let previous = value[prefixRange].last, !previous.isWhitespace,
          !#"([{‘'"/\-–—"#.contains(previous) else { return text }
    let suffix = value[prefixRange.upperBound...]
    if let next = suffix.first, next.isLetter || next.isNumber { return text }
    return " " + text
}

/// Electron and Chromium text boxes often accept an AX selected-text write without applying it,
/// so single-attempt insertion pastes into any app that embeds one of those engines.
func embedsChromium(pid: pid_t) -> Bool {
    guard let frameworks = NSRunningApplication(processIdentifier: pid)?.bundleURL?.appendingPathComponent("Contents/Frameworks") else { return false }
    return ["Electron Framework.framework", "Chromium Embedded Framework.framework"].contains {
        FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path)
    }
}

func insertText(_ text: String, into destination: FocusSnapshot, policy: InsertionPolicy = .experimentalFallback) -> InsertionResult {
    func result(_ status: InsertionResult.Status, _ detail: String, _ snapshot: FocusSnapshot? = nil) -> InsertionResult {
        InsertionResult(status: status, detail: detail, snapshot: snapshot)
    }
    guard !text.isEmpty else { return result(.failed, "Empty output; no insertion attempted") }
    guard !destination.secure else { return result(.failed, "Secure field rejected") }
    guard insertionTextRole(destination.role) else { return result(.failed, "Focused element is not a supported text field") }
    if policy == .singleAttempt && (destination.value == nil || destination.selection == nil) {
        return result(.failed, "Destination cannot be compared safely; retain output for recovery")
    }
    guard let current = try? captureFocus(), sameDestination(destination, current) else {
        return result(.failed, "Focus, value, or selection changed; retain output for recovery")
    }
    let expected = expectedInsertedValue(current.value, selection: current.selection, text: text)
    if current.value != nil && current.selection != nil && expected == nil {
        return result(.failed, "Invalid UTF16 selection; no insertion attempted")
    }
    // Without an expected value, a successful write remains uncertain and must never be retried.
    let method = policy == .singleAttempt && embedsChromium(pid: current.pid) ? .paste : insertionMethod(bundleID: current.bundleID, policy: policy)
    var pasteMethod = "clipboard paste"
    if method == .accessibility {
        let write = AXUIElementSetAttributeValue(current.element, kAXSelectedTextAttribute as CFString, text as CFString)
        if policy == .singleAttempt {
            guard write == .success else {
                return result(.unverified, "AX write returned \(write.rawValue); retain output, no paste retry")
            }
            Thread.sleep(forTimeInterval: 0.3)
            return verifyInsertion(current, expected: expected, method: "AX selected-text write")
        }
        if write == .success {
            let written = verifyInsertion(current, expected: expected, method: "AX selected-text write")
            guard written.status == .unverified else { return written }
            // Some Chromium/Electron fields accept the write and drop it. Paste only if the field still reads exactly as before.
            // Browser fields of unknown type are included; secure fields were rejected above, and paste stays unverified there.
            // ponytail: fixed 300 ms settle; a write applied later than this would double-insert. Use change notifications in the app.
            Thread.sleep(forTimeInterval: 0.3)
            guard let settled = try? captureFocus(), sameDestination(current, settled),
                  silentWriteAllowsPaste(before: current.value, after: settled.value) else {
                return written
            }
            pasteMethod = "clipboard paste after unchanged AX write"
        } else if write != .attributeUnsupported && write != .notImplemented {
            return result(.unverified, "AX write returned \(write.rawValue); delivery uncertain, no paste retry")
        }
    }
    guard let rechecked = try? captureFocus(), sameDestination(current, rechecked) else {
        return result(.failed, "Destination changed before paste; no paste attempted")
    }
    if let failure = pasteThroughClipboard(text, restore: true, settle: policy == .singleAttempt ? 0.5 : 0.2, stillTarget: {
        (try? captureFocus()).map { sameDestination(current, $0) } ?? false
    }) { return result(.failed, failure) }
    return verifyInsertion(current, expected: expected, method: pasteMethod)
}

/// Stages `text` on the clipboard and posts ⌘V, then waits `settle` seconds for the app to read it.
/// `restore` puts the previous clipboard back; otherwise the text stays there for a manual paste.
/// `stillTarget` is checked once more after staging. Returns why nothing was pasted, or nil.
func pasteThroughClipboard(_ text: String, restore: Bool, settle: TimeInterval, stillTarget: () -> Bool) -> String? {
    let clipboard = NSPasteboard.general
    var saved: [NSPasteboardItem] = []
    let oldCount = clipboard.changeCount
    for item in clipboard.pasteboardItems ?? [] {
        let copy = NSPasteboardItem()
        for type in item.types {
            guard let data = item.data(forType: type) else { return "Clipboard could not be preserved; no paste attempted" }
            copy.setData(data, forType: type)
        }
        saved.append(copy)
    }
    guard clipboard.changeCount == oldCount else { return "Clipboard changed during preservation; no paste attempted" }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
        return "Cannot create paste events"
    }
    let stagedItem = NSPasteboardItem()
    let ownershipType = NSPasteboard.PasteboardType("org.dictation.spike.clipboard-owner")
    let ownershipToken = UUID().uuidString
    guard stagedItem.setString(text, forType: .string),
          stagedItem.setString(ownershipToken, forType: ownershipType) else {
        return "Cannot prepare clipboard text"
    }
    func ownsClipboard(_ expectedCount: Int) -> Bool {
        let before = clipboard.changeCount
        let token = clipboard.string(forType: ownershipType)
        return clipboardOwnershipVerified(expectedCount: expectedCount, beforeCount: before,
                                          afterCount: clipboard.changeCount, expectedToken: ownershipToken, actualToken: token)
    }
    guard clipboard.changeCount == oldCount else { return "Clipboard changed before staging; no paste attempted" }
    let clearedCount = clipboard.clearContents()
    guard clipboard.changeCount == clearedCount else { return "Clipboard changed after clearing; no paste attempted" }
    guard clipboard.writeObjects([stagedItem]) else {
        // Restore only our unchanged empty clear or a partial write carrying our unique token.
        let failureCount = clipboard.changeCount
        let stillEmpty = failureCount == clearedCount && (clipboard.pasteboardItems ?? []).isEmpty
            && clipboard.changeCount == clearedCount
        if stillEmpty || ownsClipboard(failureCount) {
            clipboard.clearContents()
            if !saved.isEmpty { clipboard.writeObjects(saved) }
        }
        return "Could not stage clipboard text"
    }
    // NSPasteboard has no atomic compare-and-restore; another writer can race this bounded check.
    let stagedCount = clipboard.changeCount
    defer {
        if restore, ownsClipboard(stagedCount) {
            clipboard.clearContents()
            if !saved.isEmpty { clipboard.writeObjects(saved) }
        }
    }
    guard stillTarget() else { return "Destination changed after clipboard staging; no paste attempted" }
    guard ownsClipboard(stagedCount) else {
        return "Clipboard ownership changed; no paste attempted"
    }
    down.flags = .maskCommand; up.flags = .maskCommand
    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    // ponytail: bounded clipboard lease; apps taking longer than `settle` may miss the paste.
    // Focus checking, posting, and clipboard restoration cannot be atomic on macOS.
    Thread.sleep(forTimeInterval: settle)
    return nil
}

/// For a focused field that cannot be read back (web editors, custom text views, no accessible
/// focus): paste into the frontmost app and leave the text on the clipboard in case it missed.
/// Refused while Secure Input is on, which covers password fields that hide from Accessibility.
func pasteIntoFrontmostApp(_ text: String) -> InsertionResult {
    func failed(_ detail: String) -> InsertionResult { InsertionResult(status: .failed, detail: detail, snapshot: nil) }
    guard !text.isEmpty else { return failed("Empty output; no insertion attempted") }
    guard !IsSecureEventInputEnabled() else { return failed("Secure input is on; no paste attempted") }
    RunLoop.current.run(until: Date())
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else { return failed("No other app is frontmost") }
    if let failure = pasteThroughClipboard(text, restore: false, settle: 0.1, stillTarget: {
        RunLoop.current.run(until: Date())
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && !IsSecureEventInputEnabled()
    }) { return failed(failure) }
    return InsertionResult(status: .unverified, detail: "clipboard paste into an unreadable field; text left on the clipboard", snapshot: nil)
}

private func verifyInsertion(_ before: FocusSnapshot, expected: String?, method: String) -> InsertionResult {
    let after = try? captureFocus()
    let matched = after.map { $0.pid == before.pid && CFEqual($0.element, before.element) && !$0.secure && readbackMatches(expected, $0.value) } ?? false
    let verified = insertionReadbackVerified(expected: expected, actual: after?.value,
                                             sameField: matched, browserTypeUnknown: before.browserTypeUnknown || (after?.browserTypeUnknown ?? true))
    // Lengths only: the detail is logged, so it must never carry the text.
    let lengths = "readback \(after?.value.map { String($0.utf16.count) } ?? "unreadable") vs expected \(expected.map { String($0.utf16.count) } ?? "unknown")"
    return InsertionResult(status: verified ? .verified : .unverified,
                           detail: verified ? "\(method) matched full-field readback" : "\(method) delivery unverified (\(lengths)); retain output, never automatically retry",
                           snapshot: matched ? after : nil)
}

func insertionReadbackVerified(expected: String?, actual: String?, sameField: Bool, browserTypeUnknown: Bool) -> Bool {
    sameField && !browserTypeUnknown && readbackMatches(expected, actual)
}

/// Rich text boxes (Electron, ProseMirror) report non-breaking spaces, zero-width spaces, CRLF or
/// a trailing newline for text that is otherwise identical. A doubled or misplaced insertion still
/// differs after this normalization.
func readbackMatches(_ expected: String?, _ actual: String?) -> Bool {
    guard let expected, let actual else { return false }
    func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return normalized(expected) == normalized(actual)
}

/// A write reported successful may fall back to paste only when read-back proves nothing changed.
func silentWriteAllowsPaste(before: String?, after: String?) -> Bool {
    before != nil && after == before
}

func clipboardOwnershipVerified(expectedCount: Int, beforeCount: Int, afterCount: Int, expectedToken: String, actualToken: String?) -> Bool {
    beforeCount == expectedCount && afterCount == expectedCount && actualToken == expectedToken
}

func insertionTextRole(_ role: String) -> Bool {
    role == kAXTextFieldRole || role == kAXTextAreaRole
}

func runInsertionChecks() {
    assert(readbackMatches("Hi there.", "Hi\u{00A0}there.\n") && readbackMatches(" a b", "a\u{200B} b"))
    assert(!readbackMatches("Hi there.", "Hi there. Hi there.") && !readbackMatches("ab", nil) && !readbackMatches(nil, "ab"))
    assert(insertionMethod(bundleID: "com.openai.codex", policy: .singleAttempt) == .paste)
    assert(insertionMethod(bundleID: "com.google.Chrome", policy: .singleAttempt) == .paste)
    assert(insertionMethod(bundleID: "com.microsoft.VSCode", policy: .singleAttempt) == .paste)
    assert(insertionMethod(bundleID: "com.apple.TextEdit", policy: .singleAttempt) == .accessibility)
    assert(insertionMethod(bundleID: "com.google.Chrome", policy: .experimentalFallback) == .accessibility)
    let element = AXUIElementCreateApplication(123)
    func destination(pid: pid_t = 123, bundleID: String = "com.apple.TextEdit", value: String = "abc",
                     selection: CFRange = CFRange(location: 3, length: 0), secure: Bool = false) -> FocusSnapshot {
        FocusSnapshot(element: element, pid: pid, bundleID: bundleID, role: kAXTextFieldRole,
                      subrole: "unknown", value: value, selection: selection, secure: secure, browserTypeUnknown: false)
    }
    assert(sameDestination(destination(), destination()))
    assert(!sameDestination(destination(), destination(pid: 124)))
    assert(!sameDestination(destination(), destination(bundleID: "other")))
    assert(!sameDestination(destination(), destination(value: "abcd")))
    assert(!sameDestination(destination(), destination(selection: CFRange(location: 2, length: 0))))
    assert(!sameDestination(destination(), destination(secure: true)))
    assert(insertionTextRole(kAXTextFieldRole))
    assert(insertionTextRole(kAXTextAreaRole))
    assert(!insertionTextRole("AXWebArea"))
    assert(!insertionTextRole("AXDocument"))
    assert(!insertionTextRole("AXComboBox"))
    assert(clipboardOwnershipVerified(expectedCount: 4, beforeCount: 4, afterCount: 4, expectedToken: "ours", actualToken: "ours"))
    assert(!clipboardOwnershipVerified(expectedCount: 4, beforeCount: 4, afterCount: 4, expectedToken: "ours", actualToken: "other"))
    assert(!clipboardOwnershipVerified(expectedCount: 4, beforeCount: 4, afterCount: 4, expectedToken: "ours", actualToken: nil))
    assert(!clipboardOwnershipVerified(expectedCount: 4, beforeCount: 5, afterCount: 5, expectedToken: "ours", actualToken: "ours"))
    assert(!clipboardOwnershipVerified(expectedCount: 4, beforeCount: 4, afterCount: 5, expectedToken: "ours", actualToken: "ours"))
    assert(silentWriteAllowsPaste(before: "Chat probe: ", after: "Chat probe: "))
    assert(!silentWriteAllowsPaste(before: "Chat probe: ", after: "Chat probe: Acme"))
    assert(!silentWriteAllowsPaste(before: nil, after: nil))
    assert(insertionReadbackVerified(expected: "text", actual: "text", sameField: true, browserTypeUnknown: false))
    assert(!insertionReadbackVerified(expected: "text", actual: "text", sameField: true, browserTypeUnknown: true))
    assert(!insertionReadbackVerified(expected: "text", actual: "text", sameField: false, browserTypeUnknown: false))
    assert(!insertionReadbackVerified(expected: "text", actual: "old", sameField: true, browserTypeUnknown: false))
    assert(!insertionReadbackVerified(expected: nil, actual: nil, sameField: true, browserTypeUnknown: false))
    assert(expectedInsertedValue("A😀B", selection: CFRange(location: 1, length: 2), text: "X") == "AXB")
    assert(expectedInsertedValue("A😀B", selection: CFRange(location: 2, length: 0), text: "X") == nil)
    assert(expectedInsertedValue("abc", selection: CFRange(location: 3, length: 0), text: "!") == "abc!")
    assert(expectedInsertedValue("abc", selection: CFRange(location: 4, length: 0), text: "x") == nil)
    assert(expectedInsertedValue("abc", selection: CFRange(location: 2, length: Int.max), text: "x") == nil)
    assert(expectedInsertedValue(nil, selection: CFRange(location: 0, length: 0), text: "x") == nil)
}
