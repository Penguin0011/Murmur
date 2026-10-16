// Meeting detection W7c checks (PRD 11.7). No Core Audio, no UI, no network.
// swiftc app/Retention.swift app/Meetings.swift app/CallDetection.swift app/check_call_detection.swift -o /tmp/murmur-detection-check && /tmp/murmur-detection-check
import Foundation

nonisolated(unsafe) var failures = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    if (try? condition()) == true { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") }
}

/// Feeds the same inputs once a second from `from` to `to` and returns every offer's app name.
func run(_ detector: inout CallDetector, _ inputs: [String], from: Int, to: Int, _ conditions: CallDetector.Conditions = .init()) -> [String] {
    (from...to).compactMap { detector.update(inputs: inputs, now: TimeInterval($0), conditions)?.app.name }
}

@main enum DetectionChecks {
    static func main() {
        let own = CallDetector.Conditions(ownBundleID: "cc.clouddev.dictation")

        // Offer conditions: a listed app after 5 s of input, once.
        do {
            var d = CallDetector()
            check(run(&d, ["us.zoom.xos"], from: 0, to: 4, own).isEmpty, "no offer before 5 s of input")
            check(run(&d, ["us.zoom.xos"], from: 5, to: 5, own) == ["Zoom"], "offer at 5 s for a listed call app")
            check(run(&d, ["us.zoom.xos"], from: 6, to: 120, own).isEmpty, "one offer per app session")
            var voice = CallDetector()
            check(run(&voice, ["com.google.Chrome.helper"], from: 0, to: 2, own).isEmpty && run(&voice, [], from: 3, to: 60, own).isEmpty, "a 2-second voice search gets no offer")
            var none = CallDetector()
            check(run(&none, ["com.apple.Music", "com.example.recorder", ""], from: 0, to: 30, own).isEmpty, "unlisted apps and empty IDs never offer")
        }

        // Sessions: a short gap is the same call; a long one is a new call.
        do {
            var d = CallDetector()
            _ = run(&d, ["us.zoom.xos"], from: 0, to: 10, own)
            check(run(&d, [], from: 11, to: 20, own).isEmpty, "input off for 10 s")
            check(run(&d, ["us.zoom.xos"], from: 21, to: 60, own).isEmpty, "a device switch inside the grace period does not offer again")
            _ = run(&d, [], from: 61, to: 61 + Int(CallDetector.sessionGrace), own)
            check(run(&d, ["us.zoom.xos"], from: 100, to: 105, own) == ["Zoom"], "a new microphone session offers again")
        }

        // Helpers and case: matched by prefix, ignoring case; out-of-prefix helpers only while the app is open.
        do {
            check(CallDetector.app(for: "company.thebrowser.browser.helper")?.name == "Arc", "Arc's lowercase helper maps to Arc")
            check(CallDetector.app(for: "US.ZOOM.XOS")?.name == "Zoom", "bundle IDs match ignoring case")
            check(CallDetector.app(for: "com.google.Chrome.helper.renderer")?.name == "Google Chrome", "nested helper maps to its app")
            check(CallDetector.app(for: "com.google.Chromeish") == nil, "a longer ID that is not a helper does not match")
            check(CallDetector.app(for: "com.apple.WebKit.GPU", running: ["com.apple.Safari"])?.name == "Safari", "WebKit GPU credits Safari while Safari is open")
            check(CallDetector.app(for: "com.apple.WebKit.GPU", running: ["com.apple.mail"]) == nil, "WebKit GPU alone (Mail) is not Safari")
            check(CallDetector.app(for: "com.apple.avconferenced", running: ["com.apple.FaceTime"])?.name == "FaceTime", "FaceTime's conference helper maps to FaceTime")
            check(CallDetector.app(for: "com.tdesktop.Telegram")?.name == "Telegram", "Telegram Desktop is listed")
        }

        // Murmur's own processes never trigger an offer.
        do {
            var d = CallDetector()
            check(run(&d, ["cc.clouddev.dictation", "CC.CloudDev.Dictation.ModelBench"], from: 0, to: 30, own).isEmpty, "Murmur and its helpers never offer")
            check(CallDetector.isOwn("cc.clouddev.dictation.helper", ownBundleID: "cc.clouddev.dictation") && !CallDetector.isOwn("us.zoom.xos", ownBundleID: "cc.clouddev.dictation"), "own-process test")
        }

        // Suppression: a meeting uses up the call's offer; dictation only defers it.
        do {
            var d = CallDetector()
            var meeting = own; meeting.meetingLive = true
            check(run(&d, ["us.zoom.xos"], from: 0, to: 30, meeting).isEmpty, "no offer while a meeting records")
            check(run(&d, ["us.zoom.xos"], from: 31, to: 60, own).isEmpty, "no offer after Stop for the call that was recorded")
            var e = CallDetector()
            var dictating = own; dictating.dictating = true
            check(run(&e, ["us.zoom.xos"], from: 0, to: 20, dictating).isEmpty, "no offer while Murmur is dictating")
            check(run(&e, ["us.zoom.xos"], from: 21, to: 21, own) == ["Zoom"], "the deferred offer comes once dictation ends")
        }

        // "Never" and the global switch.
        do {
            var d = CallDetector()
            var never = own; never.never = ["US.ZOOM.XOS"]
            check(run(&d, ["us.zoom.xos", "com.google.Chrome"], from: 0, to: 30, never) == ["Google Chrome"], "Never for Zoom, ignoring case; others still offer")
            var off = own; off.enabled = false
            var e = CallDetector()
            check(run(&e, ["us.zoom.xos"], from: 0, to: 30, off).isEmpty, "the global switch off: no offer")
            let defaults = UserDefaults(suiteName: "murmur-detection-check-" + UUID().uuidString)!
            check(CallDetectionSettings.enabled(defaults), "detection is on by default (Q6)")
            CallDetectionSettings.addNever("us.zoom.xos", defaults); CallDetectionSettings.addNever("US.zoom.xos", defaults)
            check(CallDetectionSettings.never(defaults) == ["us.zoom.xos"], "Never is stored once")
            CallDetectionSettings.removeNever("US.ZOOM.XOS", defaults)
            check(CallDetectionSettings.never(defaults).isEmpty, "removing from the Never list undoes it")
        }

        // Wording: a browser's offer never claims a call.
        do {
            let chrome = CallOffer(app: CallDetector.app(for: "com.google.Chrome")!), zoom = CallOffer(app: CallDetector.app(for: "us.zoom.xos")!)
            check(chrome.text == "Google Chrome is using the microphone.", "browser: \"<Browser> is using the microphone\"")
            check(chrome.question.hasPrefix("If this is a call"), "browser question does not claim a call")
            check(zoom.text == "Zoom is using the microphone." && zoom.question == "Take meeting notes?", "call app wording (PRD 11.7)")
            check(zoom.neverLabel == "Never for Zoom", "Never button names the app")
            check(zoom.source == MeetingSource(name: "Zoom", bundleID: "us.zoom.xos") && !zoom.source.allApps && !zoom.source.micOnly, "Take Notes preselects the app as the source")
        }

        print(failures == 0 ? "All detection checks passed." : "\(failures) detection checks failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
