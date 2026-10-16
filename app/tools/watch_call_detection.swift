// Prints what call detection (W7c, PRD 11.7) sees, once a second: the bundle IDs of processes
// running audio input, and any offer the real CallDetector would show. Content-free; reads no
// audio, window or URL. For the live checks in PRD 11.10: start a call in each app and watch.
//
//   swiftc -swift-version 5 -parse-as-library app/Retention.swift app/Meetings.swift app/MeetingNotes.swift \
//     module-one/capture/Capture.swift app/MeetingCapture.swift app/tools/watch_call_detection.swift -o /tmp/wcd && /tmp/wcd [seconds]
import Foundation

@main enum WatchCallDetection {
    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let seconds = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 60
        var detector = CallDetector()
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<seconds {
            let now = ProcessInfo.processInfo.systemUptime - start
            let clients = AudioProcessList.all()
            let inputs = clients.filter(\.input).map(\.bundleID)
            let offer = detector.update(now: now, inputs: inputs, own: "cc.clouddev.dictation", enabled: true, never: [], meeting: false, dictating: false)
            print(String(format: "%5.1f s", now), "processes=\(clients.count) input=\(inputs.map { $0.isEmpty ? "(no bundle ID)" : $0 })", offer.map { "OFFER: " + CallDetector.text($0.app) } ?? "")
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
