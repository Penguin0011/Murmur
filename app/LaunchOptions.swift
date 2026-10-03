import Foundation

struct LaunchOptions {
    var preview = false
    var testAudio: String?
    var expectedApp: String?
    var quitAfter: Double?

    init(arguments: [String]) throws {
        var seen = Set<String>()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard seen.insert(flag).inserted else { throw LaunchError("Duplicate launch option") }
            switch flag {
            case "--preview": preview = true
            case "--test-audio", "--expected-app", "--quit-after":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty, !arguments[index].hasPrefix("--") else {
                    throw LaunchError("Missing launch option value")
                }
                let value = arguments[index]
                if flag == "--test-audio" { testAudio = value }
                else if flag == "--expected-app" { expectedApp = value }
                else {
                    guard let seconds = Double(value), seconds.isFinite, (0.1...60).contains(seconds) else {
                        throw LaunchError("Invalid quit delay")
                    }
                    quitAfter = seconds
                }
            default: throw LaunchError("Unknown launch option")
            }
            index += 1
        }
        guard (testAudio == nil) == (expectedApp == nil) else { throw LaunchError("Audio probe requires both audio and expected app") }
        guard testAudio == nil || (!preview && quitAfter == nil) else { throw LaunchError("Audio probe cannot mix with preview or timed quit") }
    }
}

struct LaunchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
