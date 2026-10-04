import Foundation

// Deterministic, network-free checks for ModelDownload.swift. A fake transport serves fixture bytes.
// Run from the repository root:
// /opt/swift/usr/bin/swiftc -swift-version 5 app/ModelDownload.swift app/check_model_download.swift -o /tmp/cm && /tmp/cm

private var failures = 0
private var passes = 0

private func check(_ condition: @autoclosure () throws -> Bool, _ label: String, line: Int = #line) rethrows {
    if try condition() { passes += 1 } else { failures += 1; print("FAIL [line \(line)]: \(label)") }
}

private func expectError(_ expected: ModelDownloadError, _ label: String, line: Int = #line, _ body: () throws -> Void) {
    do { try body(); failures += 1; print("FAIL [line \(line)]: \(label): no error") } catch let error as ModelDownloadError {
        if error == expected { passes += 1 } else { failures += 1; print("FAIL [line \(line)]: \(label): got \(error)") }
    } catch { failures += 1; print("FAIL [line \(line)]: \(label): unexpected \(error)") }
}

private func sha256Hex(_ data: Data) -> String { let h = PortableSHA256(); h.update(data); return hexString(h.finalize()) }
private func sha1Hex(_ data: Data) -> String { let h = PortableSHA1(); h.update(data); return hexString(h.finalize()) }
private func blobSHA1Hex(_ data: Data) -> String { sha1Hex(Data("blob \(data.count)\0".utf8) + data) }
private func pattern(_ count: Int, seed: Int = 7) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) }) }

/// Serves fixture bytes by URL path. Honors Range (206) unless `ignoresRange`; records every request.
private final class FakeTransport: ModelDownloadTransport {
    var files: [String: Data] = [:]
    var statusOverride: [String: Int] = [:]
    var failAfterBytes: [String: Int] = [:]      // simulate a dropped connection
    var ignoresRange = false
    var chunkSize = 4096
    var onChunk: ((String, Int) -> Void)?        // (path, bytes delivered so far in this request)
    private(set) var requests: [ModelFetchRequest] = []

    func fetch(_ request: ModelFetchRequest, isCancelled: @escaping () -> Bool,
               onResponse: @escaping (Int) throws -> Void, onData: @escaping (Data) throws -> Void) throws {
        requests.append(request)
        let path = request.url.path
        if isCancelled() { throw ModelDownloadError.cancelled }
        if let status = statusOverride[path] { try onResponse(status); return }
        guard let body = files[path] else { try onResponse(404); return }
        var start = 0
        if request.rangeStart > 0 && !ignoresRange {
            guard request.rangeStart < Int64(body.count) else { try onResponse(416); return }
            start = Int(request.rangeStart)
            try onResponse(206)
        } else { try onResponse(200) }
        var delivered = 0
        var offset = start
        while offset < body.count {
            if isCancelled() { throw ModelDownloadError.cancelled }
            if let limit = failAfterBytes[path], delivered >= limit { throw ModelDownloadError.network }
            let end = min(body.count, offset + chunkSize)
            try onData(body.subdata(in: offset..<end))
            delivered += end - offset
            offset = end
            onChunk?(path, delivered)
        }
    }
}

/// Wraps the real hasher, counting calls and capturing downloader status while hashing.
private final class CountingHasher: FileHasher {
    var calls: [String] = []
    var observe: (() -> Void)?
    private let inner = StreamingFileHasher(chunkSize: 1000)
    func hexDigest(of file: URL, algorithm: ModelHashAlgorithm, isCancelled: () -> Bool) throws -> String {
        calls.append(file.lastPathComponent)
        observe?()
        return try inner.hexDigest(of: file, algorithm: algorithm, isCancelled: isCancelled)
    }
}

private struct Fixture {
    static let repository = "Example/tiny-model"
    static let revision = "0123456789abcdef0123456789abcdef01234567"
    var contents: [(String, Data, Bool)]   // (rfilename, bytes, isLFS)

    static func standard(seed: Int = 7) -> Fixture {
        Fixture(contents: [
            ("config.json", Data("{\"name\":\"tiny\"}\n".utf8), false),
            ("enc.mlmodelc/model.mil", pattern(9_000, seed: seed + 1), false),
            ("enc.mlmodelc/weights/weight.bin", pattern(70_000, seed: seed), true),
        ])
    }

    func json(batch: [String]? = nil, hashOverride: [String: String] = [:], revision: String = Fixture.revision,
              license: [String: Any]? = nil, repository: String = Fixture.repository) -> Data {
        let files: [[String: Any]] = contents.map { name, bytes, lfs in
            var entry: [String: Any] = ["rfilename": name, "size": bytes.count, "git_blob_sha1": hashOverride[name] ?? blobSHA1Hex(bytes)]
            if lfs { entry["lfs"] = ["sha256": hashOverride[name] ?? sha256Hex(bytes), "size": bytes.count, "pointerSize": 130] }
            return entry
        } + [["rfilename": "README.md", "size": 5, "git_blob_sha1": String(repeating: "a", count: 40)]]
        var model: [String: Any] = ["revision": revision, "files": files, "batch_files": batch ?? contents.map { $0.0 }]
        if let license { model["license"] = license }
        return try! JSONSerialization.data(withJSONObject: ["models": [repository: model]])
    }

    func manifest(hashOverride: [String: String] = [:]) throws -> ModelManifest {
        try ModelManifest(data: json(hashOverride: hashOverride), repository: Fixture.repository)
    }

    func serve(_ transport: FakeTransport) {
        for (name, bytes, _) in contents { transport.files["/\(Fixture.repository)/resolve/\(Fixture.revision)/\(name)"] = bytes }
    }

    var total: Int64 { contents.reduce(0) { $0 + Int64($1.1.count) } }
}

private func path(_ name: String) -> String { "/\(Fixture.repository)/resolve/\(Fixture.revision)/\(name)" }
private func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }

@main struct ModelDownloadChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-model-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try hashVectors(root)
        try manifestChecks()
        try pinnedManifestChecks()
        try installChecks(root.appendingPathComponent("install"))
        try mismatchChecks(root.appendingPathComponent("mismatch"))
        try cancelAndRetryChecks(root.appendingPathComponent("cancel"))
        try failureChecks(root.appendingPathComponent("failure"))
        try removeAndCorruptChecks(root.appendingPathComponent("remove"))
        messageChecks()
        print("\(passes) checks passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func hashVectors(_ dir: URL) throws {
        // FIPS 180 vectors and Python hashlib outputs.
        check(sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256 empty")
        check(sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 abc")
        check(sha1Hex(Data()) == "da39a3ee5e6b4b0d3255bfef95601890afd80709", "sha1 empty")
        check(sha1Hex(Data("abc".utf8)) == "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1 abc")
        let twoBlock = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
        check(sha256Hex(twoBlock) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "sha256 448-bit")
        check(sha1Hex(twoBlock) == "84983e441c3bd26ebaae4aa1f95129e5e54670f1", "sha1 448-bit")
        check(sha256Hex(Data(repeating: 0x61, count: 1_000_000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "sha256 million a")
        check(blobSHA1Hex(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a", "blob sha1 hello")

        // 1 MiB buffer, byte i = (i*31+7) & 0xff; expected digests from Python hashlib.
        let mebibyte = pattern(1 << 20)
        let expected256 = "06b7bbfb7824aa03382051691630eb26de85102d1b08a81e907ec0744cd8a286"
        let expected1 = "95421610b8ddd86c86e3269bfd24d2a79199245f"
        check(sha256Hex(mebibyte) == expected256, "sha256 1 MiB one shot")
        check(sha1Hex(mebibyte) == expected1, "sha1 1 MiB one shot")
        // Streaming with awkward chunk sizes must match the one-shot digest.
        for step in [1, 63, 64, 65, 1000, 4097] {
            let a = PortableSHA256(), b = PortableSHA1()
            var offset = 0
            let limit = step == 1 ? 5000 : mebibyte.count   // single-byte feed over a prefix only, for speed
            while offset < limit { let end = min(limit, offset + step); a.update(mebibyte.subdata(in: offset..<end)); b.update(mebibyte.subdata(in: offset..<end)); offset = end }
            if step == 1 {
                check(hexString(a.finalize()) == sha256Hex(mebibyte.prefix(5000)), "sha256 byte-at-a-time")
                check(hexString(b.finalize()) == sha1Hex(mebibyte.prefix(5000)), "sha1 byte-at-a-time")
            } else {
                check(hexString(a.finalize()) == expected256, "sha256 chunked \(step)")
                check(hexString(b.finalize()) == expected1, "sha1 chunked \(step)")
            }
        }
        // Padding boundaries 55/56/57/63/64 bytes agree between one-shot and split feeds.
        for length in [55, 56, 57, 63, 64, 119, 120] {
            let data = pattern(length)
            let a = PortableSHA256(); a.update(data.prefix(length / 2)); a.update(data.suffix(from: length / 2))
            check(hexString(a.finalize()) == sha256Hex(data), "sha256 split \(length)")
        }
        // File hasher streams from disk.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("vector.bin")
        try mebibyte.write(to: file)
        let hasher = StreamingFileHasher(chunkSize: 70_001)
        try check(try hasher.hexDigest(of: file, algorithm: .sha256, isCancelled: { false }) == expected256, "file sha256")
        try check(try hasher.hexDigest(of: file, algorithm: .blobSHA1, isCancelled: { false }) == blobSHA1Hex(mebibyte), "file blob sha1")
        expectError(.cancelled, "hasher honors cancel") { _ = try hasher.hexDigest(of: file, algorithm: .sha256, isCancelled: { true }) }
        expectError(.fileSystem, "hasher missing file") { _ = try hasher.hexDigest(of: dir.appendingPathComponent("none"), algorithm: .sha256, isCancelled: { false }) }
    }

    static func manifestChecks() throws {
        let fixture = Fixture.standard()
        let manifest = try fixture.manifest()
        check(manifest.files.map { $0.rfilename } == fixture.contents.map { $0.0 }, "only batch files, in order")
        check(manifest.totalBytes == fixture.total, "total is sum of pinned sizes")
        check(manifest.files[0].algorithm == .blobSHA1 && manifest.files[2].algorithm == .sha256, "lfs uses sha256, others blob sha1")
        check(manifest.resolveURL(for: manifest.files[2])?.absoluteString
              == "https://huggingface.co/\(Fixture.repository)/resolve/\(Fixture.revision)/enc.mlmodelc/weights/weight.bin", "resolve url")
        let spaced = ModelManifestFile(rfilename: "a b/c#d.bin", size: 1, checksum: "", algorithm: .sha256)
        check(manifest.resolveURL(for: spaced)?.absoluteString.hasSuffix("/a%20b/c%23d.bin") == true, "url components percent-encoded")

        expectError(.invalidManifest, "branch revision rejected") { _ = try ModelManifest(data: fixture.json(revision: "main"), repository: Fixture.repository) }
        expectError(.invalidManifest, "wrong repository") { _ = try ModelManifest(data: fixture.json(), repository: "Other/model") }
        expectError(.invalidManifest, "batch entry missing from files") { _ = try ModelManifest(data: fixture.json(batch: ["config.json", "missing.bin"]), repository: Fixture.repository) }
        expectError(.invalidManifest, "duplicate batch entry") { _ = try ModelManifest(data: fixture.json(batch: ["config.json", "config.json"]), repository: Fixture.repository) }
        expectError(.invalidManifest, "malformed checksum") { _ = try fixture.manifest(hashOverride: ["config.json": "xyz"]) }
        expectError(.invalidManifest, "not json") { _ = try ModelManifest(data: Data("nope".utf8)) }
        expectError(.invalidManifest, "empty batch") { _ = try ModelManifest(data: fixture.json(batch: []), repository: Fixture.repository) }

        // Path traversal and other unsafe names are rejected before anything is downloaded.
        for bad in ["../evil", "/etc/passwd", "a/../../b", "a//b", "./a", "a/./b", "a\\..\\b", "~/x", "a\u{0}b", "a\nb", "", "x/", "w.part"] {
            var evil = fixture
            evil.contents.append((bad, Data("x".utf8), false))
            expectError(.unsafePath, "unsafe name \(bad.debugDescription)") { _ = try evil.manifest() }
        }
        var nested = fixture
        nested.contents.append(("config.json/inner", Data("x".utf8), false))
        expectError(.unsafePath, "file nested inside a file") { _ = try nested.manifest() }
        check(ModelManifest.isSafeRelativePath("parakeet_unified_decoder.mlmodelc/weights/weight.bin"), "real names are safe")
        check(!ModelManifest.isSafeRepository("../x") && !ModelManifest.isSafeRepository("a/b/c") && ModelManifest.isSafeRepository("FluidInference/parakeet-unified-en-0.6b-coreml"), "repository validation")

        // License: pinned only when the manifest records one; never invented.
        check(!manifest.license.isPinned && manifest.license.declarations.isEmpty && manifest.license.note.contains("not recorded"), "unknown repo license is honestly unknown")
        let pinned = try ModelManifest(data: fixture.json(license: ["name": "Example License", "url": "https://example.com/license"]), repository: Fixture.repository)
        check(pinned.license.isPinned && pinned.license.declarations.first?.name == "Example License", "pinned license read from manifest")
        let insecure = try ModelManifest(data: fixture.json(license: ["name": "X", "url": "http://example.com"]), repository: Fixture.repository)
        check(!insecure.license.isPinned, "non-https license link ignored")
    }

    static func pinnedManifestChecks() throws {
        let url = URL(fileURLWithPath: "module-one/models/artifact-pins.json")
        guard FileManager.default.fileExists(atPath: url.path) else { check(false, "run from repository root: artifact-pins.json not found"); return }
        let manifest = try ModelManifest(contentsOf: url)
        check(manifest.revision == "d32e972dd4315f1dc3f6be28fb2aab0ab3e80358", "pinned revision")
        check(manifest.files.count == 19, "19 pinned batch files")
        check(manifest.totalBytes == 1_801_783_964, "pinned download size 1,801,783,964 bytes")
        check(manifest.files.first.flatMap { manifest.resolveURL(for: $0) }?.absoluteString
              == "https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml/resolve/d32e972dd4315f1dc3f6be28fb2aab0ab3e80358/config.json", "pinned resolve url")
        check(!manifest.files.contains { $0.rfilename.contains("streaming") }, "streaming encoders not in batch set")
        let license = manifest.license
        check(!license.isPinned && license.declarations.map { $0.name } == ["NVIDIA Open Model License", "CC-BY-4.0"], "both declared licenses shown, marked unpinned")
        check(license.declarations.allSatisfy { $0.url.scheme == "https" }, "license links are https")
        let downloader = ModelDownloader(manifest: manifest, target: URL(fileURLWithPath: "/tmp/never-used/model"), transport: FakeTransport())
        check(downloader.downloadSize == 1_801_783_964 && downloader.license == license, "downloader exposes size and license before download")
        // Dictionary support: the CTC model, with its CC-BY-4.0 license recorded in the pins.
        let ctc = try ModelManifest(contentsOf: url, repository: "FluidInference/parakeet-ctc-110m-coreml")
        check(ctc.revision == "accdafd8cf8a2ff1cabe3c11e54416b405d409aa" && ctc.files.count == 12 && ctc.totalBytes == 102_802_455, "CTC pins: revision, 12 files, 102,802,455 bytes")
        check(ctc.license.isPinned && ctc.license.declarations.map(\.name) == ["CC-BY-4.0"], "CTC license pinned")
        check(Set(ctc.files.map(\.rfilename)).isSuperset(of: ["tokenizer.json", "vocab.json", "AudioEncoder.mlmodelc/weights/weight.bin", "MelSpectrogram.mlmodelc/weights/weight.bin"]), "CTC files FluidAudio loads are pinned")
    }

    static func installChecks(_ dir: URL) throws {
        let fixture = Fixture.standard()
        let transport = FakeTransport(); fixture.serve(transport)
        let hasher = CountingHasher()
        let target = dir.appendingPathComponent("models/parakeet")
        let downloader = ModelDownloader(manifest: try fixture.manifest(), target: target, transport: transport, hasher: hasher,
                                         freeSpace: { _ in 1 << 40 })
        var seen: [ModelStatus] = [downloader.status()]
        hasher.observe = { seen.append(downloader.status()) }
        var progress: [ModelDownloadProgress] = []
        check(downloader.status() == .notDownloaded, "starts not downloaded")
        try downloader.install { progress.append($0); seen.append(downloader.status()) }
        check(downloader.status() == .ready, "ready after install")
        for (name, bytes, _) in fixture.contents { check(read(target.appendingPathComponent(name)) == bytes, "installed \(name)") }
        check(!FileManager.default.fileExists(atPath: downloader.stagingDirectory.path), "staging moved into place")
        check(transport.requests.map { $0.url.path } == fixture.contents.map { path($0.0) }, "fetched exactly the batch files")
        check(transport.requests.allSatisfy { $0.rangeStart == 0 }, "fresh download has no Range")
        check(zip(progress, progress.dropFirst()).allSatisfy { $0.bytesDone <= $1.bytesDone }, "progress monotonic")
        check(progress.last == ModelDownloadProgress(bytesDone: fixture.total, totalBytes: fixture.total), "progress ends at total")
        check(progress.allSatisfy { $0.totalBytes == fixture.total }, "progress total is manifest total")
        check(seen.first == .notDownloaded && seen.contains(.verifying) && seen.contains { if case .downloading = $0 { return true }; return false },
              "status passes notDownloaded -> downloading -> verifying")
        check(hasher.calls.count == 3, "each file hashed once")
        check(downloader.verifyInstalled() == .ready, "full verification passes")
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)) ?? []
        check(siblings == ["parakeet"], "no leftovers beside target")

        // A concurrent second install is refused while one is running.
        let busyTransport = FakeTransport(); fixture.serve(busyTransport)
        let busyTarget = dir.appendingPathComponent("busy/model")
        let busy = ModelDownloader(manifest: try fixture.manifest(), target: busyTarget, transport: busyTransport, freeSpace: { _ in nil })
        var nestedError: ModelDownloadError?
        var removeError: ModelDownloadError?
        busyTransport.onChunk = { _, _ in
            if nestedError == nil { do { try busy.install() } catch { nestedError = error as? ModelDownloadError } }
            if removeError == nil { do { try busy.remove() } catch { removeError = error as? ModelDownloadError } }
        }
        try busy.install()
        check(nestedError == .busy, "second install while running is busy")
        check(removeError == .busy, "remove while running is busy")
        check(busy.status() == .ready, "busy refusal did not disturb install")

        // Async wrapper.
        let asyncTransport = FakeTransport(); fixture.serve(asyncTransport)
        let asyncDownloader = ModelDownloader(manifest: try fixture.manifest(), target: dir.appendingPathComponent("async/model"), transport: asyncTransport, freeSpace: { _ in nil })
        let done = DispatchSemaphore(value: 0)
        var result: Result<Void, ModelDownloadError>?
        asyncDownloader.start { result = $0; done.signal() }
        check(done.wait(timeout: .now() + 30) == .success, "start completes")
        if case .success = result { check(asyncDownloader.status() == .ready, "start installs") } else { check(false, "start succeeded") }
    }

    static func mismatchChecks(_ dir: URL) throws {
        let good = Fixture.standard()
        let target = dir.appendingPathComponent("model")
        // Install v1, then attempt an update whose served weight does not match its pin.
        let transport = FakeTransport(); good.serve(transport)
        try ModelDownloader(manifest: try good.manifest(), target: target, transport: transport, freeSpace: { _ in nil }).install()
        let original = read(target.appendingPathComponent("enc.mlmodelc/weights/weight.bin"))

        let updated = Fixture.standard(seed: 99)
        let tampered = FakeTransport(); updated.serve(tampered)
        var corrupted = updated.contents[2].1; corrupted[100] ^= 0xff
        tampered.files[path("enc.mlmodelc/weights/weight.bin")] = corrupted
        let downloader = ModelDownloader(manifest: try updated.manifest(), target: target, transport: tampered, freeSpace: { _ in nil })
        expectError(.checksumMismatch, "tampered file rejected") { try downloader.install() }
        check(read(target.appendingPathComponent("enc.mlmodelc/weights/weight.bin")) == original, "target untouched after mismatch")
        check(read(target.appendingPathComponent("enc.mlmodelc/model.mil")) == good.contents[1].1, "target keeps old files")
        check(downloader.status() == .failed(.checksumMismatch), "status reports checksum failure")
        let staged = downloader.stagingDirectory.appendingPathComponent("enc.mlmodelc/weights/weight.bin")
        check(!FileManager.default.fileExists(atPath: staged.path) && !FileManager.default.fileExists(atPath: staged.path + ".part"), "bad bytes discarded")

        // Same with no prior model: nothing appears at the target.
        let fresh = dir.appendingPathComponent("fresh")
        let freshDownloader = ModelDownloader(manifest: try updated.manifest(), target: fresh, transport: tampered, freeSpace: { _ in nil })
        expectError(.checksumMismatch, "mismatch without prior model") { try freshDownloader.install() }
        check(!FileManager.default.fileExists(atPath: fresh.path), "no target created on mismatch")

        // Oversized body is cut off as a mismatch, not written past the pinned size.
        let oversized = FakeTransport(); good.serve(oversized)
        oversized.files[path("config.json")] = good.contents[0].1 + Data("extra".utf8)
        let big = ModelDownloader(manifest: try good.manifest(), target: dir.appendingPathComponent("big"), transport: oversized, freeSpace: { _ in nil })
        expectError(.checksumMismatch, "oversized body rejected") { try big.install() }

        // A successful retry with correct bytes replaces the old model atomically.
        updated.serve(tampered)
        try downloader.install()
        check(read(target.appendingPathComponent("enc.mlmodelc/weights/weight.bin")) == updated.contents[2].1, "update installed after fix")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".model") }
        check(leftovers.isEmpty, "old model and staging cleaned up")
    }

    static func cancelAndRetryChecks(_ dir: URL) throws {
        let fixture = Fixture.standard()
        let target = dir.appendingPathComponent("model")
        let transport = FakeTransport(); fixture.serve(transport)
        let hasher = CountingHasher()
        let downloader = ModelDownloader(manifest: try fixture.manifest(), target: target, transport: transport, hasher: hasher, freeSpace: { _ in nil })
        let weight = path("enc.mlmodelc/weights/weight.bin")
        transport.onChunk = { p, delivered in if p == weight && delivered >= 20_000 { downloader.cancel() } }
        expectError(.cancelled, "cancel mid-download") { try downloader.install() }
        check(!FileManager.default.fileExists(atPath: target.path), "cancel leaves no model at target")
        check(downloader.status() == .failed(.cancelled), "status after cancel")
        let staging = downloader.stagingDirectory
        let partial = staging.appendingPathComponent("enc.mlmodelc/weights/weight.bin.part")
        let partialSize = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.intValue ?? -1
        check(partialSize >= 20_000 && partialSize < 70_000, "partial kept in staging for resume")
        check(FileManager.default.fileExists(atPath: staging.appendingPathComponent("config.json").path), "verified file kept in staging")
        downloader.cancel()   // cancel when idle is harmless

        // Retry: verified files are re-hashed locally, not re-downloaded; the partial resumes via Range.
        transport.onChunk = nil
        let before = transport.requests.count
        hasher.calls.removeAll()
        try downloader.install()
        let retried = Array(transport.requests[before...])
        check(retried.map { $0.url.path } == [weight], "retry fetches only the unfinished file")
        check(retried.first?.rangeStart == Int64(partialSize), "retry resumes from partial length")
        check(hasher.calls.filter { $0 == "config.json" }.count == 1 && hasher.calls.count == 3, "verified files re-hashed, not downloaded")
        check(read(target.appendingPathComponent("enc.mlmodelc/weights/weight.bin")) == fixture.contents[2].1, "resumed file intact")
        check(downloader.status() == .ready, "ready after retry")

        // Server that ignores Range: the partial restarts from zero and still verifies.
        let restartTarget = dir.appendingPathComponent("restart")
        let noRange = FakeTransport(); fixture.serve(noRange); noRange.ignoresRange = true
        let restart = ModelDownloader(manifest: try fixture.manifest(), target: restartTarget, transport: noRange, freeSpace: { _ in nil })
        noRange.failAfterBytes[weight] = 30_000
        expectError(.network, "dropped connection is a network error") { try restart.install() }
        check(restart.status() == .failed(.network), "status after drop")
        noRange.failAfterBytes = [:]
        var lastProgress: ModelDownloadProgress?
        try restart.install { lastProgress = $0 }
        check(noRange.requests.last?.rangeStart ?? 0 > 0, "resume was attempted")
        check(read(restartTarget.appendingPathComponent("enc.mlmodelc/weights/weight.bin")) == fixture.contents[2].1, "restart without Range verifies")
        check(lastProgress?.bytesDone == fixture.total, "progress corrected after restart")

        // Stray files in staging are not installed.
        let strayTarget = dir.appendingPathComponent("stray")
        let strayTransport = FakeTransport(); fixture.serve(strayTransport)
        let stray = ModelDownloader(manifest: try fixture.manifest(), target: strayTarget, transport: strayTransport, freeSpace: { _ in nil })
        try FileManager.default.createDirectory(at: stray.stagingDirectory.appendingPathComponent("junk"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stray.stagingDirectory.appendingPathComponent("junk/evil.bin"))
        try Data("x".utf8).write(to: stray.stagingDirectory.appendingPathComponent("extra.json"))
        try stray.install()
        let installed = (FileManager.default.enumerator(atPath: strayTarget.path)?.allObjects as? [String] ?? []).sorted()
        check(installed == ["config.json", "enc.mlmodelc", "enc.mlmodelc/model.mil", "enc.mlmodelc/weights", "enc.mlmodelc/weights/weight.bin"], "only pinned files installed")

        // A staged final file that was altered after verification is re-downloaded.
        let alteredTarget = dir.appendingPathComponent("altered")
        let alteredTransport = FakeTransport(); fixture.serve(alteredTransport)
        let altered = ModelDownloader(manifest: try fixture.manifest(), target: alteredTarget, transport: alteredTransport, freeSpace: { _ in nil })
        try FileManager.default.createDirectory(at: altered.stagingDirectory, withIntermediateDirectories: true)
        try Data("{\"name\":\"evil\"}\n".utf8).write(to: altered.stagingDirectory.appendingPathComponent("config.json"))
        try altered.install()
        check(alteredTransport.requests.contains { $0.url.path == path("config.json") }, "altered staged file re-fetched")
        check(read(alteredTarget.appendingPathComponent("config.json")) == fixture.contents[0].1, "altered staged file replaced")
    }

    static func failureChecks(_ dir: URL) throws {
        let fixture = Fixture.standard()
        let weight = path("enc.mlmodelc/weights/weight.bin")
        let transport = FakeTransport(); fixture.serve(transport)
        transport.statusOverride[weight] = 404
        let target = dir.appendingPathComponent("model")
        let downloader = ModelDownloader(manifest: try fixture.manifest(), target: target, transport: transport, freeSpace: { _ in nil })
        expectError(.httpStatus(404), "HTTP status surfaced") { try downloader.install() }
        check(downloader.status() == .failed(.httpStatus(404)), "status failed(httpStatus)")
        check(!FileManager.default.fileExists(atPath: target.path), "no target after HTTP error")
        transport.statusOverride[weight] = 503
        expectError(.httpStatus(503), "server error surfaced") { try downloader.install() }

        // Preflight disk check uses manifest sizes.
        let full = ModelDownloader(manifest: try fixture.manifest(), target: dir.appendingPathComponent("full"), transport: FakeTransport(),
                                   freeSpace: { _ in fixture.total - 1 })
        expectError(.diskFull, "not enough free space") { try full.install() }
        check(full.status() == .failed(.diskFull), "status failed(diskFull)")

        // Write-error classification.
        check(ModelDownloadError.fromWrite(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == .diskFull, "ENOSPC is disk full")
        check(ModelDownloadError.fromWrite(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == .diskFull, "out of space is disk full")
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        check(ModelDownloadError.fromWrite(wrapped) == .diskFull, "underlying ENOSPC is disk full")
        check(ModelDownloadError.fromWrite(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == .fileSystem, "EACCES is file system")

        // Unwritable parent: file-system error, classified, no crash.
        let blocker = dir.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let blocked = ModelDownloader(manifest: try fixture.manifest(), target: blocker.appendingPathComponent("model"), transport: FakeTransport(), freeSpace: { _ in nil })
        expectError(.fileSystem, "unwritable location") { try blocked.install() }

        // A failed attempt is cleared by the next successful one.
        transport.statusOverride = [:]
        try downloader.install()
        check(downloader.status() == .ready, "failure cleared by success")
    }

    static func removeAndCorruptChecks(_ dir: URL) throws {
        let fixture = Fixture.standard()
        let target = dir.appendingPathComponent("model")
        let transport = FakeTransport(); fixture.serve(transport)
        let downloader = ModelDownloader(manifest: try fixture.manifest(), target: target, transport: transport, freeSpace: { _ in nil })
        try downloader.remove()   // removing nothing is fine
        check(downloader.status() == .notDownloaded, "remove when absent")
        try downloader.install()

        // Corruption detected cheaply (size) by status(), and by hash in verifyInstalled().
        let weight = target.appendingPathComponent("enc.mlmodelc/weights/weight.bin")
        var bytes = fixture.contents[2].1; bytes[5] ^= 1
        try bytes.write(to: weight)
        check(downloader.status() == .ready, "same-size corruption invisible to cheap status")
        check(downloader.verifyInstalled() == .corrupt(ModelDownloader.corruptReason), "hash check finds corruption")
        try FileManager.default.removeItem(at: target.appendingPathComponent("config.json"))
        check(downloader.status() == .corrupt(ModelDownloader.corruptReason), "missing file is corrupt")

        // Interrupted download, then remove: both target and staging go away.
        transport.onChunk = { _, delivered in if delivered >= 8000 { downloader.cancel() } }
        expectError(.cancelled, "cancel before remove") { try downloader.install() }
        check(FileManager.default.fileExists(atPath: downloader.stagingDirectory.path), "staging present before remove")
        try downloader.remove()
        check(!FileManager.default.fileExists(atPath: target.path), "remove deletes model directory")
        check(!FileManager.default.fileExists(atPath: downloader.stagingDirectory.path), "remove deletes staging")
        check(downloader.status() == .notDownloaded, "status after remove")

        // A plain file at the target path is reported, not trusted.
        try Data("x".utf8).write(to: target)
        check(downloader.status() == .corrupt(ModelDownloader.notDirectoryReason), "file at target is corrupt")
        try downloader.remove()
        check(downloader.status() == .notDownloaded, "remove clears a bad target")
    }

    static func messageChecks() {
        let all: [ModelDownloadError] = [.network, .diskFull, .checksumMismatch, .httpStatus(500), .cancelled, .invalidManifest, .unsafePath, .fileSystem, .busy]
        for error in all {
            let message = error.userMessage
            check(!message.isEmpty && !message.contains("/") && !message.lowercased().contains("huggingface") && !message.contains(".bin"),
                  "content-free message for \(error)")
        }
        check(Set(all.map { $0.userMessage }).count == all.count, "messages distinct")
        check(ModelDownloadError.httpStatus(404).userMessage.contains("404"), "status code shown")
    }
}
