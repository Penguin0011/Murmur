@preconcurrency import CoreML
import FluidAudio
import Foundation

/// `ModelBench DIARIZER_DIRECTORY --diarize KEPT_WAV THRESHOLD` (PRD 11.8): FluidAudio's offline
/// pipeline (community-1 segmentation, WeSpeaker embeddings, PLDA and VBx) over a meeting's kept
/// Them stream, a 16 kHz mono 16-bit WAV. Prints one JSON line, {"segments":[{"speaker","start","end"}]},
/// then exits, so the memory goes back when it is done.
///
/// Voice embeddings never leave this process: only speaker ids and times are printed, nothing is
/// exported, and the models are loaded straight from the pinned, hash-checked folder, never through
/// FluidAudio's downloader (which could fetch or purge files on its own).
enum Diarize {
    static func run(models: URL, audio: URL, threshold: Double) async throws {
        ModelHub.offlineMode = true
        let start = Date()
        var config = OfflineDiarizerConfig(clusteringThreshold: threshold)
        config.export = .none
        config.exposeChunkEmbeddings = false
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: try await load(models))
        let loaded = Date()
        let source = try Int16WaveSource(audio)
        let result = try await manager.process(audioSource: source, audioLoadingSeconds: 0)
        let segments: [[String: Any]] = result.segments.map {
            ["speaker": $0.speakerId, "start": Double($0.startTimeSeconds), "end": Double($0.endTimeSeconds)]
        }
        try ModelBench.emit(["segments": segments, "load_seconds": loaded.timeIntervalSince(start),
                             "process_seconds": Date().timeIntervalSince(loaded), "audio_seconds": Double(source.sampleCount) / 16_000])
    }

    /// The five pinned files. FBank runs on the CPU (faster there, as FluidAudio does); the rest may use the Neural Engine.
    static func load(_ directory: URL) async throws -> OfflineDiarizerModels {
        let start = Date()
        func model(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: configuration)
        }
        let names = ModelNames.OfflineDiarizer.self
        let segmentation = try model(names.segmentationFile, .all), embedding = try model(names.embeddingFile, .all)
        let rho = try model(names.pldaRhoFile, .all), fbank = try model(names.fbankFile, .cpuOnly)
        // plda-parameters.json: tensors.psi.data_base64 holds little-endian Float32 values.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(names.pldaParameters))) as? [String: Any]
        guard let encoded = ((json?["tensors"] as? [String: Any])?["psi"] as? [String: Any])?["data_base64"] as? String,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !data.isEmpty, data.count % 4 == 0
        else { throw NSError(domain: "Invalid PLDA parameters", code: 3) }
        let psi = ModelBench.floats(data).map(Double.init)
        return OfflineDiarizerModels(segmentationModel: segmentation, fbankModel: fbank, embeddingModel: embedding,
                                     pldaRhoModel: rho, pldaPsi: psi, compilationDuration: Date().timeIntervalSince(start))
    }
}

/// Reads the kept WAV in place (memory-mapped), so a 2-hour stream is neither loaded into memory
/// nor copied to a temporary file outside Murmur's private folder.
struct Int16WaveSource: AudioSampleSource {
    static let header = 44
    let data: Data
    let sampleCount: Int

    init(_ url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count > Self.header else { throw NSError(domain: "Empty audio", code: 2) }
        sampleCount = (data.count - Self.header) / 2
    }

    /// Copies what exists and leaves the rest of `destination` untouched, as FluidAudio's own sources do.
    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        let start = max(0, offset)
        guard count > 0, start < sampleCount else { return }
        let available = min(sampleCount - start, count)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: Self.header + start * 2)
            for i in 0..<available { destination[i] = Float(Int16(littleEndian: base.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32_768 }
        }
    }
}
