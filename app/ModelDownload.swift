import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Downloads the pinned Parakeet Unified batch files from Hugging Face, verifies every byte against
// artifact-pins.json, and moves the verified set into place with one rename. Foundation only, so the
// checks also run on Linux (no CryptoKit): SHA-256 and SHA-1 are small streaming implementations.

// MARK: - Hashing

/// Streaming SHA-256 (FIPS 180-4). Feed any number of chunks, then call `finalize()` once.
final class PortableSHA256 {
    private let core = DigestCore(sha256: true)
    init() {}
    func update(_ data: Data) { data.withUnsafeBytes { core.absorb($0) } }
    func finalize() -> [UInt8] { core.finish() }
}

/// Streaming SHA-1. Used only to match the blob IDs Hugging Face publishes for non-LFS files;
/// it is an integrity check against pinned values, not a security boundary on its own.
final class PortableSHA1 {
    private let core = DigestCore(sha256: false)
    init() {}
    func update(_ data: Data) { data.withUnsafeBytes { core.absorb($0) } }
    func finalize() -> [UInt8] { core.finish() }
}

/// Shared 64-byte-block engine. Raw buffers and closure-free loops keep unoptimized (debug) app
/// builds usable: `@_optimize(speed)` makes the hot functions fast even when the target is -Onone.
private final class DigestCore {
    private static let sha256K: UnsafeMutablePointer<UInt32> = {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        let table = UnsafeMutablePointer<UInt32>.allocate(capacity: 64)  // process-lifetime constant
        table.initialize(from: k, count: 64)
        return table
    }()

    private let isSHA256: Bool
    private let k: UnsafeMutablePointer<UInt32>
    private let h = UnsafeMutablePointer<UInt32>.allocate(capacity: 8)
    private let w = UnsafeMutablePointer<UInt32>.allocate(capacity: 80)
    private let pending = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
    private var pendingCount = 0
    private var totalBytes: UInt64 = 0
    private var finished = false

    init(sha256: Bool) {
        isSHA256 = sha256
        k = DigestCore.sha256K
        let initial: [UInt32] = sha256
            ? [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
            : [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0, 0, 0, 0]
        h.initialize(from: initial, count: 8)
        w.initialize(repeating: 0, count: 80)
    }

    deinit { h.deallocate(); w.deallocate(); pending.deallocate() }

    @_optimize(speed) func absorb(_ bytes: UnsafeRawBufferPointer) {
        precondition(!finished, "digest already finalized")
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        let count = bytes.count
        totalBytes &+= UInt64(count)
        var offset = 0
        if pendingCount > 0 {
            let take = min(64 - pendingCount, count)
            (pending + pendingCount).copyMemory(from: base, byteCount: take)
            pendingCount += take; offset = take
            if pendingCount < 64 { return }
            compress(UnsafeRawPointer(pending)); pendingCount = 0
        }
        while count - offset >= 64 { compress(base + offset); offset += 64 }
        if count > offset { pending.copyMemory(from: base + offset, byteCount: count - offset); pendingCount = count - offset }
    }

    func finish() -> [UInt8] {
        let bitLength = totalBytes &* 8
        var tail: [UInt8] = [0x80]
        let afterMarker = (pendingCount + 1) % 64
        tail.append(contentsOf: repeatElement(0, count: afterMarker <= 56 ? 56 - afterMarker : 120 - afterMarker))
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        tail.withUnsafeBytes { absorb($0) }
        finished = true
        var out = [UInt8]()
        for i in 0..<(isSHA256 ? 8 : 5) {
            let word = h[i]
            out += [UInt8(word >> 24), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)]
        }
        return out
    }

    @_optimize(speed) private func compress(_ p: UnsafeRawPointer) {
        if isSHA256 { sha256Block(p) } else { sha1Block(p) }
    }

    @_optimize(speed) private func sha256Block(_ p: UnsafeRawPointer) {
        let w = self.w, k = self.k, h = self.h
        var i = 0
        while i < 16 { w[i] = UInt32(bigEndian: p.loadUnaligned(fromByteOffset: i &* 4, as: UInt32.self)); i &+= 1 }
        while i < 64 {
            let x = w[i &- 15], y = w[i &- 2]
            let s0 = ((x >> 7) | (x << 25)) ^ ((x >> 18) | (x << 14)) ^ (x >> 3)
            let s1 = ((y >> 17) | (y << 15)) ^ ((y >> 19) | (y << 13)) ^ (y >> 10)
            w[i] = w[i &- 16] &+ s0 &+ w[i &- 7] &+ s1
            i &+= 1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        i = 0
        while i < 64 {
            let bigS1 = ((e >> 6) | (e << 26)) ^ ((e >> 11) | (e << 21)) ^ ((e >> 25) | (e << 7))
            let t1 = hh &+ bigS1 &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
            let bigS0 = ((a >> 2) | (a << 30)) ^ ((a >> 13) | (a << 19)) ^ ((a >> 22) | (a << 10))
            let t2 = bigS0 &+ ((a & b) ^ (a & c) ^ (b & c))
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            i &+= 1
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
    }

    @_optimize(speed) private func sha1Block(_ p: UnsafeRawPointer) {
        let w = self.w, h = self.h
        var i = 0
        while i < 16 { w[i] = UInt32(bigEndian: p.loadUnaligned(fromByteOffset: i &* 4, as: UInt32.self)); i &+= 1 }
        while i < 80 {
            let x = w[i &- 3] ^ w[i &- 8] ^ w[i &- 14] ^ w[i &- 16]
            w[i] = (x << 1) | (x >> 31)
            i &+= 1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
        i = 0
        while i < 80 {
            let f: UInt32, k: UInt32
            if i < 20 { f = (b & c) | (~b & d); k = 0x5A827999 }
            else if i < 40 { f = b ^ c ^ d; k = 0x6ED9EBA1 }
            else if i < 60 { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC }
            else { f = b ^ c ^ d; k = 0xCA62C1D6 }
            let t = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
            e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = t
            i &+= 1
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
    }
}

func hexString(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out = [UInt8](); out.reserveCapacity(bytes.count * 2)
    for byte in bytes { out.append(digits[Int(byte >> 4)]); out.append(digits[Int(byte & 0x0f)]) }
    return String(decoding: out, as: UTF8.self)
}

enum ModelHashAlgorithm: Equatable {
    /// Plain SHA-256 of the file bytes (Hugging Face LFS `sha256`).
    case sha256
    /// SHA-1 of `"blob <size>\0" + bytes` (the `git_blob_sha1` field in the pins).
    case blobSHA1
}

/// Computes file digests. Injected so tests can count calls or simulate failures.
protocol FileHasher {
    /// Returns the lowercase hex digest. Must read in bounded chunks and throw
    /// `ModelDownloadError.cancelled` promptly once `isCancelled()` returns true.
    func hexDigest(of file: URL, algorithm: ModelHashAlgorithm, isCancelled: () -> Bool) throws -> String
}

/// Default hasher: streams the file in 1 MiB chunks through the portable digests.
struct StreamingFileHasher: FileHasher {
    var chunkSize = 1 << 20

    func hexDigest(of file: URL, algorithm: ModelHashAlgorithm, isCancelled: () -> Bool) throws -> String {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file) } catch { throw ModelDownloadError.fileSystem }
        defer { try? handle.close() }
        let sha256 = PortableSHA256(), sha1 = PortableSHA1()
        if algorithm == .blobSHA1 {
            guard let size = fileSize(file) else { throw ModelDownloadError.fileSystem }
            sha1.update(Data("blob \(size)\0".utf8))
        }
        while true {
            if isCancelled() { throw ModelDownloadError.cancelled }
            let chunk: Data
            do { chunk = try handle.read(upToCount: chunkSize) ?? Data() } catch { throw ModelDownloadError.fileSystem }
            if chunk.isEmpty { break }
            switch algorithm {
            case .sha256: sha256.update(chunk)
            case .blobSHA1: sha1.update(chunk)
            }
        }
        return hexString(algorithm == .sha256 ? sha256.finalize() : sha1.finalize())
    }
}

private func fileSize(_ url: URL) -> Int64? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          (attrs[.type] as? FileAttributeType) == .typeRegular else { return nil }
    return (attrs[.size] as? NSNumber)?.int64Value
}

// MARK: - Errors

/// Every case maps to a short, user-facing message that names no file, path, or URL.
enum ModelDownloadError: Error, Equatable {
    case network
    case diskFull
    case checksumMismatch
    case httpStatus(Int)
    case cancelled
    case invalidManifest
    case unsafePath
    case fileSystem
    case busy

    var userMessage: String {
        switch self {
        case .network: return "The model download could not reach the server. Check your internet connection and try again."
        case .diskFull: return "There is not enough free disk space for the model. Free up space and try again."
        case .checksumMismatch: return "A downloaded model file did not match its pinned checksum and was discarded. Try the download again."
        case .httpStatus(let code): return "The model server returned an error (HTTP \(code)). Try again later."
        case .cancelled: return "The model download was cancelled."
        case .invalidManifest: return "The pinned model manifest is missing or invalid. Reinstall Murmur."
        case .unsafePath: return "The pinned model manifest contains an unsafe file path, so nothing was downloaded."
        case .fileSystem: return "Murmur could not write the model files. Check that the model folder is writable."
        case .busy: return "A model download is already in progress."
        }
    }

    /// Maps file-write failures; ENOSPC / out-of-space becomes `.diskFull`.
    static func fromWrite(_ error: Error) -> ModelDownloadError {
        if let known = error as? ModelDownloadError { return known }
        var current: NSError? = error as NSError
        while let ns = current {
            if (ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT)))
                || (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError) { return .diskFull }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .fileSystem
    }
}

// MARK: - Manifest and license

struct ModelManifestFile: Equatable {
    let rfilename: String
    let size: Int64
    /// Lowercase hex: SHA-256 for LFS files, blob SHA-1 otherwise.
    let checksum: String
    let algorithm: ModelHashAlgorithm
}

struct ModelLicenseDeclaration: Equatable {
    /// Where the declaration comes from, e.g. "Upstream NVIDIA model card".
    let source: String
    let name: String
    let url: URL
}

/// License facts to show before download. `isPinned` is true only when the manifest itself records a
/// license; otherwise the declarations are what the model cards say, and `note` says so plainly.
struct ModelLicenseInfo: Equatable {
    let isPinned: Bool
    let declarations: [ModelLicenseDeclaration]
    let note: String

    /// Facts from MODEL_RESEARCH.md and the Hugging Face model APIs (checked 2026-10-03):
    /// nvidia/parakeet-unified-en-0.6b declares `license: other`, `license_name: nvidia-open-model-license`
    /// with the link below; the pinned conversion repository declares `license: cc-by-4.0`.
    static let parakeetUnifiedUnpinned = ModelLicenseInfo(
        isPinned: false,
        declarations: [
            ModelLicenseDeclaration(source: "Upstream NVIDIA model card (nvidia/parakeet-unified-en-0.6b)",
                                    name: "NVIDIA Open Model License",
                                    url: URL(string: "https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/")!),
            ModelLicenseDeclaration(source: "Core ML conversion model card (FluidInference/parakeet-unified-en-0.6b-coreml)",
                                    name: "CC-BY-4.0",
                                    url: URL(string: "https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml")!),
        ],
        note: "The license is not recorded in Murmur's pinned model manifest. The upstream and conversion model cards declare different licenses, and Murmur has not resolved which terms apply. Review both before downloading.")
}

struct ModelManifest: Equatable {
    static let defaultRepository = "FluidInference/parakeet-unified-en-0.6b-coreml"

    let repository: String
    /// Immutable 40-hex commit; branch or tag names are rejected so the source cannot drift.
    let revision: String
    /// Exactly the pinned `batch_files`, in manifest order.
    let files: [ModelManifestFile]
    let license: ModelLicenseInfo

    /// Sum of pinned file sizes: the download size to show before downloading.
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    init(contentsOf url: URL, repository: String = ModelManifest.defaultRepository) throws {
        guard let data = try? Data(contentsOf: url) else { throw ModelDownloadError.invalidManifest }
        try self.init(data: data, repository: repository)
    }

    /// Parses artifact-pins.json. Throws `.unsafePath` for traversal-like names, otherwise `.invalidManifest`.
    init(data: Data, repository: String = ModelManifest.defaultRepository) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [String: Any],
              let model = models[repository] as? [String: Any],
              let revision = model["revision"] as? String,
              let entries = model["files"] as? [[String: Any]],
              let batch = model["batch_files"] as? [String], !batch.isEmpty,
              ModelManifest.isSafeRepository(repository), ModelManifest.isHex(revision, length: 40)
        else { throw ModelDownloadError.invalidManifest }
        var byName: [String: [String: Any]] = [:]
        for entry in entries { if let name = entry["rfilename"] as? String { byName[name] = entry } }
        var files: [ModelManifestFile] = []
        var seen = Set<String>()
        for name in batch {
            guard ModelManifest.isSafeRelativePath(name) else { throw ModelDownloadError.unsafePath }
            guard seen.insert(name).inserted, let entry = byName[name],
                  let size = (entry["size"] as? NSNumber)?.int64Value, size >= 0 else { throw ModelDownloadError.invalidManifest }
            if let lfs = entry["lfs"] as? [String: Any] {
                guard let sha = lfs["sha256"] as? String, ModelManifest.isHex(sha, length: 64) else { throw ModelDownloadError.invalidManifest }
                if let lfsSize = (lfs["size"] as? NSNumber)?.int64Value, lfsSize != size { throw ModelDownloadError.invalidManifest }
                files.append(ModelManifestFile(rfilename: name, size: size, checksum: sha, algorithm: .sha256))
            } else if let sha1 = entry["git_blob_sha1"] as? String, ModelManifest.isHex(sha1, length: 40) {
                files.append(ModelManifestFile(rfilename: name, size: size, checksum: sha1, algorithm: .blobSHA1))
            } else { throw ModelDownloadError.invalidManifest }
        }
        // Reject names where one file would sit "inside" another file, e.g. "a" and "a/b".
        for file in files where files.contains(where: { $0.rfilename.hasPrefix(file.rfilename + "/") }) {
            throw ModelDownloadError.unsafePath
        }
        self.repository = repository
        self.revision = revision
        self.files = files
        if let license = model["license"] as? [String: Any], let name = license["name"] as? String, !name.isEmpty,
           let link = license["url"] as? String, let url = URL(string: link), url.scheme == "https" {
            self.license = ModelLicenseInfo(isPinned: true,
                                            declarations: [ModelLicenseDeclaration(source: "Pinned model manifest", name: name, url: url)],
                                            note: "This license is recorded in Murmur's pinned model manifest.")
        } else if repository == ModelManifest.defaultRepository {
            self.license = .parakeetUnifiedUnpinned
        } else {
            self.license = ModelLicenseInfo(isPinned: false, declarations: [],
                                            note: "The license for this model is not recorded in Murmur's pinned model manifest.")
        }
    }

    /// Relative, forward-slash path with no empty, ".", or ".." components, no backslashes,
    /// control characters, or leading "~". Anything else could escape the model directory.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".part") }
    }

    static func isSafeRepository(_ repository: String) -> Bool {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return parts.count == 2 && parts.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// `https://huggingface.co/<repo>/resolve/<revision>/<rfilename>`, each path component percent-encoded.
    func resolveURL(for file: ModelManifestFile, base: URL = URL(string: "https://huggingface.co")!) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        let encoded = file.rfilename.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) }
        guard !encoded.contains(where: { $0 == nil }) else { return nil }
        let path = "\(repository)/resolve/\(revision)/" + encoded.map { $0! }.joined(separator: "/")
        return URL(string: base.absoluteString.hasSuffix("/") ? base.absoluteString + path : base.absoluteString + "/" + path)
    }
}

// MARK: - Transport

/// One GET. `rangeStart > 0` asks the server for `Range: bytes=<rangeStart>-`.
struct ModelFetchRequest: Equatable {
    let url: URL
    let rangeStart: Int64
}

/// Blocking, streaming HTTP GET. Implementations follow redirects, call `onResponse` once with the
/// final status code before any body bytes, then `onData` in order. If a callback throws, stop and
/// rethrow that error. Poll `isCancelled` and throw `ModelDownloadError.cancelled` when it is true.
/// Transport failures must be thrown as `ModelDownloadError.network`.
protocol ModelDownloadTransport: AnyObject {
    func fetch(_ request: ModelFetchRequest, isCancelled: @escaping () -> Bool,
               onResponse: @escaping (Int) throws -> Void, onData: @escaping (Data) throws -> Void) throws
}

/// URLSession-backed transport. Ephemeral configuration: no cookies, no shared URL cache.
final class URLSessionModelTransport: ModelDownloadTransport {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        if configuration == nil {
            config.timeoutIntervalForRequest = 60
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
        }
        self.configuration = config
    }

    func fetch(_ request: ModelFetchRequest, isCancelled: @escaping () -> Bool,
               onResponse: @escaping (Int) throws -> Void, onData: @escaping (Data) throws -> Void) throws {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        if request.rangeStart > 0 { urlRequest.setValue("bytes=\(request.rangeStart)-", forHTTPHeaderField: "Range") }
        let delegate = FetchDelegate(onResponse: onResponse, onData: onData)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: urlRequest)
        task.resume()
        while delegate.done.wait(timeout: .now() + 0.1) == .timedOut {
            if isCancelled() { delegate.fail(ModelDownloadError.cancelled); task.cancel() }
        }
        if let error = delegate.failure { throw error }
        if isCancelled() { throw ModelDownloadError.cancelled }
    }

    private final class FetchDelegate: NSObject, URLSessionDataDelegate {
        let done = DispatchSemaphore(value: 0)
        /// Callbacks run serially on the session's one-operation delegate queue; the error is locked.
        private final class State: @unchecked Sendable {
            let onResponse: (Int) throws -> Void
            let onData: (Data) throws -> Void
            private let lock = NSLock()
            private var stored: Error?
            init(onResponse: @escaping (Int) throws -> Void, onData: @escaping (Data) throws -> Void) {
                self.onResponse = onResponse; self.onData = onData
            }
            var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
            func set(_ error: Error) { lock.lock(); if stored == nil { stored = error }; lock.unlock() }
        }
        private let state: State
        private var onResponse: (Int) throws -> Void { state.onResponse }
        private var onData: (Data) throws -> Void { state.onData }

        init(onResponse: @escaping (Int) throws -> Void, onData: @escaping (Data) throws -> Void) {
            state = State(onResponse: onResponse, onData: onData)
        }

        var failure: Error? { state.error }
        func fail(_ error: Error) { state.set(error) }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else { fail(ModelDownloadError.network); completionHandler(.cancel); return }
            do { try onResponse(http.statusCode); completionHandler(.allow) } catch { fail(error); completionHandler(.cancel) }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil else { return }
            do { try onData(data) } catch { fail(error); dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                let code = (error as? URLError)?.code
                fail(code == .cancelled ? ModelDownloadError.cancelled : ModelDownloadError.network)
            }
            done.signal()
        }
    }
}

// MARK: - Downloader

struct ModelDownloadProgress: Equatable {
    let bytesDone: Int64
    let totalBytes: Int64
    var fraction: Double { totalBytes > 0 ? min(1, Double(bytesDone) / Double(totalBytes)) : 0 }
}

enum ModelStatus: Equatable {
    case notDownloaded
    case downloading(ModelDownloadProgress)
    case verifying
    case ready
    /// `reason` is user-facing and content-free.
    case corrupt(String)
    case failed(ModelDownloadError)
}

/// Downloads exactly the pinned batch files into a staging directory beside `target`, verifies each
/// file's size and checksum, then renames the staging directory onto `target`. The target is never
/// partially written: until the final rename it holds either nothing or the previous model.
///
/// `install` blocks; call it off the main thread (or use `start`). `cancel`, `status`, and `license`
/// are safe from any thread.
final class ModelDownloader {
    static let corruptReason = "Some model files are missing or damaged. Remove the model and download it again."
    static let notDirectoryReason = "The model location is not a folder. Remove the model and download it again."

    let manifest: ModelManifest
    let target: URL
    private let transport: ModelDownloadTransport
    private let hasher: FileHasher
    private let baseURL: URL
    private let freeSpace: (URL) -> Int64?
    private let fileManager = FileManager.default

    private let lock = NSLock()
    private var active: ModelStatus?
    private var lastFailure: ModelDownloadError?
    private var cancelRequested = false
    private var running = false
    private var progressCallback: ((ModelDownloadProgress) -> Void)?
    private var lastPublished: ModelDownloadProgress?

    /// - Parameters:
    ///   - target: final model directory; its parent must be on the volume where staging is created.
    ///   - freeSpace: available bytes on the volume holding a URL; nil skips the preflight.
    init(manifest: ModelManifest, target: URL, transport: ModelDownloadTransport = URLSessionModelTransport(),
         hasher: FileHasher = StreamingFileHasher(), baseURL: URL = URL(string: "https://huggingface.co")!,
         freeSpace: @escaping (URL) -> Int64? = ModelDownloader.systemFreeSpace) {
        self.manifest = manifest
        self.target = target.standardizedFileURL
        self.transport = transport
        self.hasher = hasher
        self.baseURL = baseURL
        self.freeSpace = freeSpace
    }

    var license: ModelLicenseInfo { manifest.license }
    /// Bytes to download, from the pinned sizes. Show this before starting.
    var downloadSize: Int64 { manifest.totalBytes }

    /// Hidden sibling of `target`, keyed by revision so a retry resumes the same pinned set.
    var stagingDirectory: URL {
        target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).download-\(manifest.revision.prefix(12))", isDirectory: true)
    }

    static func systemFreeSpace(_ url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return ((try? FileManager.default.attributesOfFileSystem(forPath: probe.path))?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// Cheap status: in-flight state, then the last failure, then an on-disk size check (no hashing).
    /// Use `verifyInstalled()` for a full checksum pass.
    func status() -> ModelStatus {
        lock.lock()
        if let active { lock.unlock(); return active }
        if let lastFailure { lock.unlock(); return .failed(lastFailure) }
        lock.unlock()
        return diskStatus(hash: false)
    }

    /// Full size + checksum check of the installed model. Does not change `status()` state.
    func verifyInstalled(isCancelled: @escaping () -> Bool = { false }) -> ModelStatus {
        diskStatus(hash: true, isCancelled: isCancelled)
    }

    /// Requests cancellation; `install` throws `.cancelled` at the next chunk. Already-verified staged
    /// files are kept so a later `install` can skip them; `remove()` discards them.
    func cancel() { lock.lock(); if running { cancelRequested = true }; lock.unlock() }

    /// Runs `install` on a background queue. Callbacks arrive on that queue.
    func start(progress: ((ModelDownloadProgress) -> Void)? = nil,
               completion: @escaping (Result<Void, ModelDownloadError>) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            do { try install(progress: progress); completion(.success(())) } catch {
                completion(.failure(error as? ModelDownloadError ?? .fileSystem))
            }
        }
    }

    /// Downloads (or resumes) the pinned files, verifies all of them, then installs atomically.
    /// Throws `ModelDownloadError`. An existing `target` is replaced only after every file verifies.
    func install(progress: ((ModelDownloadProgress) -> Void)? = nil) throws {
        lock.lock()
        guard !running else { lock.unlock(); throw ModelDownloadError.busy }
        running = true; cancelRequested = false; lastFailure = nil; progressCallback = progress; lastPublished = nil
        active = .downloading(ModelDownloadProgress(bytesDone: 0, totalBytes: manifest.totalBytes))
        lock.unlock()
        do {
            try performInstall()
            finish(failure: nil)
        } catch {
            let classified = error as? ModelDownloadError ?? ModelDownloadError.fromWrite(error)
            finish(failure: classified)
            throw classified
        }
    }

    /// Deletes the installed model and any staged partial download. Refuses while a download runs.
    func remove() throws {
        lock.lock()
        guard !running else { lock.unlock(); throw ModelDownloadError.busy }
        lastFailure = nil
        lock.unlock()
        for url in [target, stagingDirectory] where fileManager.fileExists(atPath: url.path) || isSymlink(url) {
            do { try fileManager.removeItem(at: url) } catch { throw ModelDownloadError.fileSystem }
        }
    }

    // MARK: Internals

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelRequested }

    private func setActive(_ status: ModelStatus) { lock.lock(); active = status; lock.unlock() }

    private func publish(_ value: ModelDownloadProgress) {
        lock.lock()
        let changed = lastPublished != value
        lastPublished = value
        active = .downloading(value)
        let callback = progressCallback
        lock.unlock()
        if changed { callback?(value) }
    }

    private func finish(failure: ModelDownloadError?) {
        lock.lock(); running = false; active = nil; lastFailure = failure; cancelRequested = false; progressCallback = nil; lock.unlock()
    }

    private func checkCancelled() throws { if isCancelled { throw ModelDownloadError.cancelled } }

    private func isSymlink(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Resolves `rfilename` under `root`, refusing anything that would land outside it.
    private func location(of file: ModelManifestFile, in root: URL) throws -> URL {
        guard ModelManifest.isSafeRelativePath(file.rfilename) else { throw ModelDownloadError.unsafePath }
        let url = root.appendingPathComponent(file.rfilename).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw ModelDownloadError.unsafePath }
        return url
    }

    private func verify(_ file: ModelManifestFile, at url: URL) throws -> Bool {
        guard fileSize(url) == file.size else { return false }
        let digest = try hasher.hexDigest(of: url, algorithm: file.algorithm, isCancelled: { [weak self] in self?.isCancelled ?? true })
        return digest == file.checksum
    }

    private func diskStatus(hash: Bool, isCancelled: @escaping () -> Bool = { false }) -> ModelStatus {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) else { return .notDownloaded }
        guard isDirectory.boolValue, !isSymlink(target) else { return .corrupt(Self.notDirectoryReason) }
        for file in manifest.files {
            guard let url = try? location(of: file, in: target), fileSize(url) == file.size else { return .corrupt(Self.corruptReason) }
            if hash {
                guard let digest = try? hasher.hexDigest(of: url, algorithm: file.algorithm, isCancelled: isCancelled),
                      digest == file.checksum else { return .corrupt(Self.corruptReason) }
            }
        }
        return .ready
    }

    private func performInstall() throws {
        let staging = stagingDirectory
        let total = manifest.totalBytes
        var done: Int64 = 0
        func report() {
            report(done)
        }
        func report(_ bytes: Int64) {
            let value = ModelDownloadProgress(bytesDone: bytes, totalBytes: total)
            publish(value)
        }
        // Validate every path and URL before touching the network or disk.
        let plan: [(ModelManifestFile, URL, URL)] = try manifest.files.map { file in
            guard let url = manifest.resolveURL(for: file, base: baseURL) else { throw ModelDownloadError.invalidManifest }
            return (file, try location(of: file, in: staging), url)
        }
        if isSymlink(staging) { try? fileManager.removeItem(at: staging) }
        do { try fileManager.createDirectory(at: staging, withIntermediateDirectories: true) } catch { throw ModelDownloadError.fromWrite(error) }

        // Preflight: remaining bytes against free space (only counts final, not yet verified, files).
        let staged = plan.reduce(Int64(0)) { sum, item in
            sum + (fileSize(item.1) ?? fileSize(item.1.appendingPathExtension("part")) ?? 0)
        }
        if let free = freeSpace(staging), free < total - staged { throw ModelDownloadError.diskFull }

        report()
        for (file, destination, url) in plan {
            try checkCancelled()
            let partial = destination.appendingPathExtension("part")
            do { try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true) }
            catch { throw ModelDownloadError.fromWrite(error) }
            // A final-named staged file was verified when it was downloaded; re-hash before trusting it.
            if fileManager.fileExists(atPath: destination.path) {
                setActive(.verifying)
                if try verify(file, at: destination) { done += file.size; report(); continue }
                try? fileManager.removeItem(at: destination)
            }
            done = try download(file, from: url, to: partial, startingAt: done, report: report)
            setActive(.verifying)
            guard try verify(file, at: partial) else {
                try? fileManager.removeItem(at: partial)
                throw ModelDownloadError.checksumMismatch
            }
            do { try fileManager.moveItem(at: partial, to: destination) } catch { throw ModelDownloadError.fromWrite(error) }
            report()
        }
        try checkCancelled()
        setActive(.verifying)
        try pruneUnexpected(in: staging, keeping: Set(plan.map { $0.1.path }))
        try checkCancelled()
        try swapIntoPlace(staging)
    }

    /// Streams one file into `partial`, resuming from its current length when the server honors Range.
    private func download(_ file: ModelManifestFile, from url: URL, to partial: URL,
                          startingAt doneBefore: Int64, report: (Int64) -> Void) throws -> Int64 {
        var offset = fileSize(partial) ?? 0
        if offset > file.size { try? fileManager.removeItem(at: partial); offset = 0 }
        if offset == file.size { report(doneBefore + offset); return doneBefore + offset }   // complete but unverified
        report(doneBefore + offset)
        if offset == 0 {
            try? fileManager.removeItem(at: partial)
            guard fileManager.createFile(atPath: partial.path, contents: nil) else { throw ModelDownloadError.fileSystem }
        }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: partial) } catch { throw ModelDownloadError.fromWrite(error) }
        defer { try? handle.close() }

        // State shared with transport callbacks (which may run on another thread, strictly in order).
        final class Box { var written: Int64 = 0; var started = false; var error: Error? }
        let box = Box()
        let startDone = doneBefore
        let sizeLimit = file.size
        var baseOffset = offset
        let progressLock = NSLock()
        var latest = doneBefore + offset
        let request = ModelFetchRequest(url: url, rangeStart: offset)
        do {
            try transport.fetch(request, isCancelled: { [weak self] in self?.isCancelled ?? true }, onResponse: { status in
                switch status {
                case 206 where baseOffset > 0:
                    try handle.seekToEnd()
                case 200:
                    // Server ignored Range (or none was sent): restart the file from zero.
                    try handle.truncate(atOffset: 0)
                    baseOffset = 0
                default:
                    if status == 416 || (status == 206 && baseOffset == 0) { try? handle.truncate(atOffset: 0); baseOffset = 0 }
                    throw ModelDownloadError.httpStatus(status)
                }
                box.started = true
            }, onData: { [weak self] data in
                guard box.started else { throw ModelDownloadError.network }
                if self?.isCancelled ?? true { throw ModelDownloadError.cancelled }
                guard baseOffset + box.written + Int64(data.count) <= sizeLimit else { throw ModelDownloadError.checksumMismatch }
                do { try handle.write(contentsOf: data) } catch { throw ModelDownloadError.fromWrite(error) }
                box.written += Int64(data.count)
                progressLock.lock(); latest = startDone + baseOffset + box.written; progressLock.unlock()
                let value = ModelDownloadProgress(bytesDone: startDone + baseOffset + box.written, totalBytes: self?.manifest.totalBytes ?? 0)
                self?.publish(value)
            })
        } catch let error as ModelDownloadError {
            try? handle.synchronize()
            if error == .checksumMismatch { try? fileManager.removeItem(at: partial) }
            throw error
        } catch {
            throw ModelDownloadError.fromWrite(error)
        }
        do { try handle.synchronize() } catch { throw ModelDownloadError.fromWrite(error) }
        if baseOffset + box.written != file.size { throw ModelDownloadError.network }  // truncated body
        progressLock.lock(); defer { progressLock.unlock() }
        return latest
    }

    /// Deletes anything in staging that is not a pinned file (or a directory leading to one), so no
    /// stray or substituted file can be installed alongside the model.
    private func pruneUnexpected(in staging: URL, keeping expected: Set<String>) throws {
        let root = staging.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(atPath: root) else { throw ModelDownloadError.fileSystem }
        var extras: [String] = []
        while let relative = enumerator.nextObject() as? String {
            let full = root + "/" + relative
            var isDirectory: ObjCBool = false
            _ = fileManager.fileExists(atPath: full, isDirectory: &isDirectory)
            if isDirectory.boolValue && !isSymlink(URL(fileURLWithPath: full)) {
                if !expected.contains(where: { $0.hasPrefix(full + "/") }) { extras.append(full); enumerator.skipDescendants() }
            } else if !expected.contains(full) { extras.append(full) }
        }
        for path in extras { do { try fileManager.removeItem(atPath: path) } catch { throw ModelDownloadError.fileSystem } }
    }

    /// Renames staging onto target. With no existing target this is a single atomic rename; otherwise
    /// the old model is renamed aside first and restored if the second rename fails.
    private func swapIntoPlace(_ staging: URL) throws {
        let parent = target.deletingLastPathComponent()
        if fileManager.fileExists(atPath: target.path) || isSymlink(target) {
            let aside = parent.appendingPathComponent(".\(target.lastPathComponent).old-\(UUID().uuidString)")
            do { try fileManager.moveItem(at: target, to: aside) } catch { throw ModelDownloadError.fromWrite(error) }
            do { try fileManager.moveItem(at: staging, to: target) } catch {
                try? fileManager.moveItem(at: aside, to: target)
                throw ModelDownloadError.fromWrite(error)
            }
            try? fileManager.removeItem(at: aside)
        } else {
            do { try fileManager.moveItem(at: staging, to: target) } catch { throw ModelDownloadError.fromWrite(error) }
        }
    }
}
