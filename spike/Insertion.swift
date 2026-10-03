import AppKit
import ApplicationServices

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

private func sameDestination(_ original: FocusSnapshot, _ current: FocusSnapshot) -> Bool {
    original.pid == current.pid && CFEqual(original.element, current.element) && !current.secure
        && original.role == current.role && insertionTextRole(current.role)
        && original.value == current.value
        && original.selection?.location == current.selection?.location
        && original.selection?.length == current.selection?.length
}

func insertText(_ text: String, into destination: FocusSnapshot) -> InsertionResult {
    func result(_ status: InsertionResult.Status, _ detail: String, _ snapshot: FocusSnapshot? = nil) -> InsertionResult {
        InsertionResult(status: status, detail: detail, snapshot: snapshot)
    }
    guard !text.isEmpty else { return result(.failed, "Empty output; no insertion attempted") }
    guard !destination.secure else { return result(.failed, "Secure field rejected") }
    guard insertionTextRole(destination.role) else { return result(.failed, "Focused element is not a supported text field") }
    guard let current = try? captureFocus(), sameDestination(destination, current) else {
        return result(.failed, "Focus, value, or selection changed; retain output for recovery")
    }
    let expected = expectedInsertedValue(current.value, selection: current.selection, text: text)
    if current.value != nil && current.selection != nil && expected == nil {
        return result(.failed, "Invalid UTF16 selection; no insertion attempted")
    }
    // Without an expected value, a successful write remains uncertain and must never be retried.
    let write = AXUIElementSetAttributeValue(current.element, kAXSelectedTextAttribute as CFString, text as CFString)
    if write == .success {
        return verifyInsertion(current, expected: expected, method: "AX selected-text write")
    }
    guard write == .attributeUnsupported || write == .notImplemented else {
        return result(.unverified, "AX write returned \(write.rawValue); delivery uncertain, no paste retry")
    }
    guard let rechecked = try? captureFocus(), sameDestination(current, rechecked) else {
        return result(.failed, "Destination changed before paste; no paste attempted")
    }
    let clipboard = NSPasteboard.general
    var saved: [NSPasteboardItem] = []
    let oldCount = clipboard.changeCount
    for item in clipboard.pasteboardItems ?? [] {
        let copy = NSPasteboardItem()
        for type in item.types {
            guard let data = item.data(forType: type) else { return result(.failed, "Clipboard could not be preserved; no paste attempted") }
            copy.setData(data, forType: type)
        }
        saved.append(copy)
    }
    guard clipboard.changeCount == oldCount else { return result(.failed, "Clipboard changed during preservation; no paste attempted") }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
        return result(.failed, "Cannot create paste events")
    }
    let stagedItem = NSPasteboardItem()
    let ownershipType = NSPasteboard.PasteboardType("org.dictation.spike.clipboard-owner")
    let ownershipToken = UUID().uuidString
    guard stagedItem.setString(text, forType: .string),
          stagedItem.setString(ownershipToken, forType: ownershipType) else {
        return result(.failed, "Cannot prepare clipboard text")
    }
    func ownsClipboard(_ expectedCount: Int) -> Bool {
        let before = clipboard.changeCount
        let token = clipboard.string(forType: ownershipType)
        return clipboardOwnershipVerified(expectedCount: expectedCount, beforeCount: before,
                                          afterCount: clipboard.changeCount, expectedToken: ownershipToken, actualToken: token)
    }
    guard clipboard.changeCount == oldCount else { return result(.failed, "Clipboard changed before staging; no paste attempted") }
    let clearedCount = clipboard.clearContents()
    guard clipboard.changeCount == clearedCount else { return result(.failed, "Clipboard changed after clearing; no paste attempted") }
    guard clipboard.writeObjects([stagedItem]) else {
        // Restore only our unchanged empty clear or a partial write carrying our unique token.
        let failureCount = clipboard.changeCount
        let stillEmpty = failureCount == clearedCount && (clipboard.pasteboardItems ?? []).isEmpty
            && clipboard.changeCount == clearedCount
        if stillEmpty || ownsClipboard(failureCount) {
            clipboard.clearContents()
            if !saved.isEmpty { clipboard.writeObjects(saved) }
        }
        return result(.failed, "Could not stage clipboard text")
    }
    // NSPasteboard has no atomic compare-and-restore; another writer can race this bounded check.
    let stagedCount = clipboard.changeCount
    defer {
        if ownsClipboard(stagedCount) {
            clipboard.clearContents()
            if !saved.isEmpty { clipboard.writeObjects(saved) }
        }
    }
    guard let finalFocus = try? captureFocus(), sameDestination(current, finalFocus) else {
        return result(.failed, "Destination changed after clipboard staging; no paste attempted")
    }
    guard ownsClipboard(stagedCount) else {
        return result(.failed, "Clipboard ownership changed; no paste attempted")
    }
    down.flags = .maskCommand; up.flags = .maskCommand
    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    // ponytail: bounded synchronous spike wait; use asynchronous completion in the application.
    Thread.sleep(forTimeInterval: 0.2)
    return verifyInsertion(current, expected: expected, method: "clipboard paste")
}

private func verifyInsertion(_ before: FocusSnapshot, expected: String?, method: String) -> InsertionResult {
    let after = try? captureFocus()
    let matched = after.map { $0.pid == before.pid && CFEqual($0.element, before.element) && !$0.secure && expected != nil && $0.value == expected } ?? false
    let verified = insertionReadbackVerified(expected: expected, actual: after?.value,
                                             sameField: matched, browserTypeUnknown: before.browserTypeUnknown || (after?.browserTypeUnknown ?? true))
    return InsertionResult(status: verified ? .verified : .unverified,
                           detail: verified ? "\(method) matched full-field readback" : "\(method) delivery unverified; retain output, never automatically retry",
                           snapshot: matched ? after : nil)
}

func insertionReadbackVerified(expected: String?, actual: String?, sameField: Bool, browserTypeUnknown: Bool) -> Bool {
    sameField && !browserTypeUnknown && expected != nil && actual == expected
}

func clipboardOwnershipVerified(expectedCount: Int, beforeCount: Int, afterCount: Int, expectedToken: String, actualToken: String?) -> Bool {
    beforeCount == expectedCount && afterCount == expectedCount && actualToken == expectedToken
}

func insertionTextRole(_ role: String) -> Bool {
    role == kAXTextFieldRole || role == kAXTextAreaRole
}

func runInsertionChecks() {
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
