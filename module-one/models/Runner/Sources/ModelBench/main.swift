import AVFoundation
import FluidAudio
import Foundation

// Explicit local directory: no mutable-main download or implicit network access.
@main struct ModelBench {
    static func main() async throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--serve" {
            try await serve(models: URL(fileURLWithPath: CommandLine.arguments[1])); return
        }
        let single = CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--single"
        guard CommandLine.arguments.count == 3 || single else {
            throw NSError(domain: "Usage: ModelBench MODEL_DIRECTORY AUDIO_FILE [--single] | ModelBench MODEL_DIRECTORY --serve", code: 1)
        }
        let manager = UnifiedAsrManager()
        let start = Date()
        try await manager.loadModels(from: URL(fileURLWithPath: CommandLine.arguments[1]))
        let loaded = Date()
        let samples = try readSamples(CommandLine.arguments[2])
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
        try emit(output)
    }

    /// Loads the model once, prints {"ready":true}, then answers one JSON line per audio path read
    /// from stdin until stdin closes. A failed request answers {"error":…} and the server keeps going.
    static func serve(models: URL) async throws {
        let manager = UnifiedAsrManager()
        let start = Date()
        try await manager.loadModels(from: models)
        try emit(["ready": true, "load_seconds": Date().timeIntervalSince(start)])
        while let path = readLine() {
            let begin = Date()
            do {
                let samples = try readSamples(path)
                let prepared = Date()
                let text = try await manager.transcribe(samples)
                try emit(["text": text, "audio_prepare_seconds": prepared.timeIntervalSince(begin),
                          "warm_transcribe_seconds": Date().timeIntervalSince(prepared)])
            } catch {
                try emit(["error": "transcription failed"])
            }
        }
    }

    static func readSamples(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.length > 0, file.length <= Int64(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)) else {
            throw NSError(domain: "Invalid or oversized audio", code: 2)
        }
        try file.read(into: buffer)
        return try AudioConverter().resampleBuffer(buffer)
    }

    static func emit(_ object: [String: Any]) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
        fflush(stdout)
    }
}
