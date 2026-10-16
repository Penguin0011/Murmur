import Foundation

// Meeting detection (PRD 11.7, gap #23): when a known call app or a browser has used the microphone
// for a few seconds, offer to take meeting notes. Rules only; no Core Audio, no UI, nothing stored but
// the settings. It only ever offers: a meeting starts from Take Notes, never from here.

/// Settings → Meetings: the global switch (on by default, Q6) and the per-app "Never" list.
enum CallDetectionSettings {
    static let enabledKey = "callDetectionEnabled"
    static let neverKey = "callDetectionNever"
    static func enabled(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }
    static func never(_ defaults: UserDefaults) -> [String] { defaults.stringArray(forKey: neverKey) ?? [] }
    static func addNever(_ bundleID: String, _ defaults: UserDefaults) {
        var list = never(defaults)
        if !list.contains(where: { $0.lowercased() == bundleID.lowercased() }) { list.append(bundleID) }
        defaults.set(list, forKey: neverKey)
    }
    static func removeNever(_ bundleID: String, _ defaults: UserDefaults) {
        defaults.set(never(defaults).filter { $0.lowercased() != bundleID.lowercased() }, forKey: neverKey)
    }
}

struct CallOffer: Equatable {
    let app: CallApp
    /// "Zoom is using the microphone. Take meeting notes?" (PRD 11.7). A browser's microphone use may
    /// be voice input or search, so its question does not claim a call (Q5). Murmur reads no window
    /// titles or URLs to tell them apart.
    var text: String { "\(app.name) is using the microphone." }
    var question: String { app.isBrowser ? "If this is a call, take meeting notes?" : "Take meeting notes?" }
    var neverLabel: String { "Never for \(app.name)" }
    var source: MeetingSource { MeetingSource(name: app.name, bundleID: app.bundleID) }
}

struct CallDetector {
    /// Input must run this long before an offer, which filters a short voice search (PRD 11.7).
    static let minimumInput: TimeInterval = 5
    /// A microphone session ends only after input has been off this long, so a device switch or a
    /// mute that briefly stops input does not offer again in the same call.
    static let sessionGrace: TimeInterval = 15
    /// How long the offer stays up.
    static let offerLifetime: TimeInterval = 30

    /// Apps that can trigger an offer: the call-app and browser catalog, plus Telegram's non-App-Store client.
    static let apps = CallApp.catalog + [CallApp(bundleID: "com.tdesktop.Telegram", name: "Telegram", isBrowser: false, helpers: [])]

    struct Conditions {
        var enabled = true
        var never: [String] = []
        var meetingLive = false
        var dictating = false
        /// Murmur's bundle ID; it and its helpers never trigger an offer.
        var ownBundleID: String?
        /// Running apps' bundle IDs, for crediting a helper outside an app's prefix (Safari's
        /// `com.apple.WebKit.GPU` serves every WebKit app) only while that app is open. nil: not checked.
        var running: Set<String>?
    }

    private struct Session { var since: TimeInterval; var lastSeen: TimeInterval; var offered = false }
    /// Per app (canonical bundle ID), the current microphone session.
    private var sessions: [String: Session] = [:]

    /// The catalog app a process belongs to, ignoring case; an own-prefix match beats a shared helper.
    static func app(for bundleID: String, running: Set<String>? = nil) -> CallApp? {
        let id = bundleID.lowercased()
        guard !id.isEmpty else { return nil }
        if let own = apps.first(where: { id == $0.bundleID.lowercased() || id.hasPrefix($0.bundleID.lowercased() + ".") }) { return own }
        let open = running.map { Set($0.map { $0.lowercased() }) }
        return apps.first { app in app.helpers.contains { $0.lowercased() == id } && open.map { $0.contains(app.bundleID.lowercased()) } != false }
    }

    static func isOwn(_ bundleID: String, ownBundleID: String?) -> Bool {
        guard let own = ownBundleID?.lowercased(), !own.isEmpty else { return false }
        let id = bundleID.lowercased()
        return id == own || id.hasPrefix(own + ".")
    }

    /// Called about once a second with the bundle IDs of processes whose input is running.
    /// Returns an offer at most once per app per microphone session.
    mutating func update(inputs: [String], now: TimeInterval, _ conditions: Conditions) -> CallOffer? {
        var seen: [String: CallApp] = [:]
        for id in inputs where !Self.isOwn(id, ownBundleID: conditions.ownBundleID) {
            if let app = Self.app(for: id, running: conditions.running) { seen[app.bundleID] = app }
        }
        for key in seen.keys {
            if sessions[key] == nil { sessions[key] = Session(since: now, lastSeen: now) } else { sessions[key]!.lastSeen = now }
        }
        sessions = sessions.filter { now - $0.value.lastSeen < Self.sessionGrace }
        // A meeting covers whatever call is running: no offer for it after Stop either.
        if conditions.meetingLive { for key in sessions.keys { sessions[key]!.offered = true }; return nil }
        // Dictation only defers the offer; it comes once dictation ends if the call is still running.
        guard conditions.enabled, !conditions.dictating else { return nil }
        let never = Set(conditions.never.map { $0.lowercased() })
        for (key, app) in seen.sorted(by: { $0.key < $1.key }) {
            guard var session = sessions[key], !session.offered, now - session.since >= Self.minimumInput,
                  !never.contains(key.lowercased()) else { continue }
            session.offered = true; sessions[key] = session
            return CallOffer(app: app)
        }
        return nil
    }
}
