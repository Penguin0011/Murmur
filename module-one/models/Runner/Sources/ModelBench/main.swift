import AVFoundation
import FluidAudio
import Foundation

// Explicit local directory: no mutable-main download or implicit network access.
@main struct ModelBench {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "Usage: ModelBench MODEL_DIRECTORY AUDIO_FILE", code: 1)
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
        let prepared = Date()
        let text = try await manager.transcribe(buffer)
        let coldDone = Date()
        let warmText = try await manager.transcribe(buffer)
        let warmDone = Date()
        let output: [String: Any] = ["text": text,
            "load_seconds": loaded.timeIntervalSince(start),
            "audio_prepare_seconds": prepared.timeIntervalSince(loaded),
            "cold_transcribe_seconds": coldDone.timeIntervalSince(prepared),
            "warm_transcribe_seconds": warmDone.timeIntervalSince(coldDone), "warm_text": warmText]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    }
}
