// Runs the real meeting-detection rules (CallDetector) against the real Core Audio process list
// (AudioProcessList), once a second as the app does, and prints every change in microphone use and
// every offer. For the W7c evidence (PRD 11.10). Reads bundle IDs only; records nothing.
//
//   SDKROOT="$(dirname "$(xcrun --show-sdk-path)")/MacOSX26.sdk" swiftc -swift-version 5 -parse-as-library -suppress-warnings \
//     module-one/capture/Capture.swift app/Retention.swift app/Meetings.swift app/MeetingCapture.swift app/CallDetection.swift \
//     app/tools/probe_call_detection.swift -o /tmp/probe-detection
//   /tmp/probe-detection SECONDS [--own BUNDLE_ID] [--meeting-live] [--dictating] [--never BUNDLE_ID] [--off]
import AppKit

@main enum Probe {
    static func main() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let seconds = Int(args.dropFirst().first ?? "") ?? 60
        var conditions = CallDetector.Conditions(enabled: !args.contains("--off"), never: value("--never").map { [$0] } ?? [],
                                                 meetingLive: args.contains("--meeting-live"), dictating: args.contains("--dictating"),
                                                 ownBundleID: value("--own") ?? "cc.clouddev.dictation")
        var detector = CallDetector()
        var previous: [String] = []
        let start = Date()
        var cpu = 0.0
        for _ in 0..<seconds {
            let t = Date().timeIntervalSince(start)
            let before = clock()
            let inputs = AudioProcessList.all().filter(\.input).map(\.bundleID)
            conditions.running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            let offer = detector.update(inputs: inputs, now: t, conditions)
            cpu += Double(clock() - before) / Double(CLOCKS_PER_SEC)
            if inputs.sorted() != previous { print(String(format: "%6.1f s  input: %@", t, inputs.sorted().joined(separator: ", ").isEmpty ? "(none)" : inputs.sorted().joined(separator: ", "))); previous = inputs.sorted() }
            if let offer { print(String(format: "%6.1f s  OFFER: %@ %@ [%@]", t, offer.text, offer.question, offer.neverLabel)) }
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1)
        }
        print(String(format: "poll CPU: %.2f ms per poll (%d polls)", cpu * 1000 / Double(seconds), seconds))
    }
}
