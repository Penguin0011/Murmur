import Foundation

@main struct LaunchChecks {
    static func main() throws {
        let normal = try LaunchOptions(arguments: [])
        precondition(!normal.preview && normal.testAudio == nil)
        let preview = try LaunchOptions(arguments: ["--preview", "--quit-after", "1"])
        precondition(preview.preview && preview.quitAfter == 1)
        let probe = try LaunchOptions(arguments: ["--test-audio", "/tmp/synthetic.wav", "--expected-app", "com.apple.TextEdit"])
        precondition(probe.expectedApp == "com.apple.TextEdit")
        let rejected = [
            ["--test-audio"], ["--test-audio", "--expected-app", "com.apple.TextEdit"],
            ["--test-audio", "/tmp/synthetic.wav"], ["--expected-app", "com.apple.TextEdit"],
            ["--preview", "--preview"], ["--unknown"], ["--quit-after", "nan"],
            ["--quit-after", "0"], ["--quit-after", "61"], ["--quit-after"],
            ["--test-audio", "a", "--expected-app", ""],
            ["--test-audio", "a", "--expected-app", "b", "--preview"],
            ["--test-audio", "a", "--expected-app", "b", "--quit-after", "1"]
        ]
        for args in rejected {
            do { _ = try LaunchOptions(arguments: args); fatalError("Invalid launch accepted") }
            catch is LaunchError {}
        }
        print("Launch checks passed: normal/preview/probe and 13 invalid argument combinations.")
    }
}
