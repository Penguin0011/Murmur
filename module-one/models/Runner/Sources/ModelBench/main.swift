import AVFoundation
import FluidAudio
import Foundation

// Explicit local directory: no mutable-main download or implicit network access.
@main struct ModelBench {
    static func main() async throws {
        let single = CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--single"
        guard CommandLine.arguments.count == 3 || single else {
            throw NSError(domain: "Usage: ModelBench MODEL_DIRECTORY AUDIO_FILE [--single]", code: 1)
        }
        let manager = UnifiedAsrManager()
        let start = Date()
        try await manager.loadModels(from: URL(fileURLWithPath: CommandLine.arguments[1]))
        let loaded = Date()
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[2]))
        guard file.length > 0, file.length <= Int64(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)) else {
            throw NSError(domain: "Invalid or oversized audio", code: 2)
        }
        try file.read(into: buffer)
        let samples = try AudioConverter().resampleBuffer(buffer)
        let prepared = Date()
        let text = try await manager.transcribe(samples)
        let coldDone = Date()
        var output: [String: Any] = ["text": text,
            "load_seconds": loaded.timeIntervalSince(start),
            "audio_prepare_seconds": prepared.timeIntervalSince(loaded),
            "cold_transcribe_seconds": coldDone.timeIntervalSince(prepared)]
        if !single {
            output["warm_text"] = try await manager.transcribe(samples)
            output["warm_transcribe_seconds"] = Date().timeIntervalSince(coldDone)
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    }
}
