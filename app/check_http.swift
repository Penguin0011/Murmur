import Foundation

@main struct HTTPChecks {
    static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let transport = URLSessionTransport(maximumResponseBytes: 1024)
        for status in [307, 308] {
            var request = URLRequest(url: base.appendingPathComponent("redirect/\(status)"))
            request.httpMethod = "POST"; request.httpBody = Data("synthetic-transcript".utf8)
            request.setValue("synthetic-key", forHTTPHeaderField: "x-goog-api-key")
            let response = try await transport.send(request)
            precondition(response.status == status)
        }
        for path in ["large", "streamed"] {
            do { _ = try await transport.send(URLRequest(url: base.appendingPathComponent(path))); preconditionFailure("Oversized response accepted") }
            catch { precondition((error as? URLError)?.code == .dataLengthExceedsMaximum) }
        }
        let ok = try await transport.send(URLRequest(url: base.appendingPathComponent("ok")))
        precondition(ok.status == 200 && ok.body == Data("ok".utf8))
        let task = Task { try await transport.send(URLRequest(url: base.appendingPathComponent("slow"))) }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        do { _ = try await task.value; preconditionFailure("Canceled request answered") }
        catch { precondition((error as? URLError)?.code == .cancelled) }
        print("HTTP checks passed: redirects refused, declared/streamed response limits, normal response, cancellation.")
    }
}
