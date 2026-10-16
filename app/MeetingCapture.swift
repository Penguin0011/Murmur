import Foundation
import AVFoundation
import CoreAudio
import os

// The "Them" stream of a meeting (PRD 11.2): a private, unmuted Core Audio process tap on the call
// app's processes (or every process except Murmur), read through a private aggregate device and
// converted to 16 kHz mono for the speech model. Also the process list detection and Start use.

private let meetingLog = Logger(subsystem: "cc.clouddev.dictation", category: "meeting")

/// Audio clients Core Audio knows about. Reading them needs no permission.
enum AudioProcessList {
    struct Client: Equatable { let id: AudioObjectID; let pid: pid_t; let bundleID: String; let input: Bool; let output: Bool }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result = initial, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : nil
    }

    static func all() -> [Client] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            let bundle = value(id, kAudioProcessPropertyBundleID, Unmanaged<CFString>?.none)??.takeRetainedValue() as String? ?? ""
            return Client(id: id, pid: value(id, kAudioProcessPropertyPID, pid_t(-1)) ?? -1, bundleID: bundle,
                          input: value(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1,
                          output: value(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) == 1)
        }
    }

    static func defaultOutputUID() -> String? {
        guard let device = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(kAudioObjectUnknown)),
              device != kAudioObjectUnknown else { return nil }
        return value(device, kAudioDevicePropertyDeviceUID, Unmanaged<CFString>?.none)??.takeRetainedValue() as String?
    }
}

struct MeetingTapError: Error, CustomStringConvertible {
    let description: String
    init(_ step: String, _ status: OSStatus) { description = "\(step) failed (\(status))" }
}

/// What the tap captures: one call app's processes (matched again at every refresh, so a helper
/// that starts later is added), or everything except Murmur's own processes.
enum TapTarget: Equatable {
    case only(CallApp)
    case allExcept([String])

    func includes(_ bundleID: String) -> Bool {
        switch self {
        case .only(let app): return app.matches(bundleID)
        case .allExcept(let own): return !own.contains { $0.lowercased() == bundleID.lowercased() }
        }
    }
}

final class SystemAudioTap {
    let queue = DispatchQueue(label: "murmur.meeting.tap", qos: .userInitiated)
    /// 16 kHz mono float, the speech model's rate.
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// Queue-owned meter level (0–1) and whether any non-zero sample has arrived; a tap without
    /// permission may deliver silence rather than an error (to record on the test Mac, PRD 11.10).
    private(set) var level = 0.0
    private(set) var heardSignal = false
    private(set) var lastBuffer: TimeInterval?
    /// Queue-owned count of buffers received, for the stall watch.
    private(set) var buffers: Int64 = 0
    private let chunker: Chunker
    private var tapID = AudioObjectID(kAudioObjectUnknown), aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var description: CATapDescription?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private(set) var target: TapTarget = .allExcept([])
    /// Queue-owned: when the next buffer should start if audio were continuous. A tap delivers
    /// nothing while no tapped app plays; that time is filled with silence so the Them stream's
    /// sample clock (and so its line times) keeps step with the meeting.
    private var nextExpected: TimeInterval?
    private static let silence: AVAudioPCMBuffer = {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        return buffer  // zero-filled on allocation
    }()
    private var tappedIDs: [AudioObjectID] = []

    init(chunkFolder: URL) { chunker = Chunker(format: Self.format, directory: chunkFolder, boundaries: false, fileSettings: Chunker.int16(Self.format)) }
    /// Replays earlier events, as Capture.attachChunks does.
    func attachChunks(_ handler: @escaping (Chunker.Event) -> Void) { queue.sync { chunker.attach(handler) } }

    /// Process objects for `target` among the current clients.
    /// Process objects to name in the description: the app's processes to include, or Murmur's to exclude.
    static func processIDs(_ target: TapTarget, clients: [AudioProcessList.Client]) -> [AudioObjectID] {
        switch target {
        case .only(let app): return clients.filter { app.matches($0.bundleID) }.map(\.id)
        case .allExcept: return clients.filter { !target.includes($0.bundleID) }.map(\.id)
        }
    }
    /// Whether any process this tap records is playing audio now; a tap delivers nothing while none is.
    func isPlaying(_ clients: [AudioProcessList.Client]) -> Bool { clients.contains { $0.output && target.includes($0.bundleID) } }

    func start(_ target: TapTarget) throws {
        self.target = target
        queue.sync { nextExpected = ProcessInfo.processInfo.systemUptime }
        let ids = Self.processIDs(target, clients: AudioProcessList.all())
        let description: CATapDescription
        switch target {
        case .only: description = CATapDescription(stereoMixdownOfProcesses: ids)
        case .allExcept: description = CATapDescription(stereoGlobalTapButExcludeProcesses: ids)
        }
        description.isMono = true
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "Murmur meeting notes"
        tappedIDs = ids
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw MeetingTapError("Creating the tap", status) }
        tapID = tap; self.description = description
        do {
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var stream = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &stream)
            guard status == noErr, let input = AVAudioFormat(streamDescription: &stream), let converter = AVAudioConverter(from: input, to: Self.format) else {
                throw MeetingTapError("Reading the tap format", status)
            }
            inputFormat = input; self.converter = converter
            var aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Murmur Meeting Notes",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            // The output device gives the aggregate its clock.
            if let output = AudioProcessList.defaultOutputUID() {
                aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output
                aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
            }
            var device = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
            guard status == noErr else { throw MeetingTapError("Creating the aggregate device", status) }
            aggregateID = device
            status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { [weak self] _, input, _, _, _ in self?.receive(input) }
            guard status == noErr else { throw MeetingTapError("Reading the aggregate device", status) }
            status = AudioDeviceStart(device, procID)
            guard status == noErr else { throw MeetingTapError("Starting the aggregate device", status) }
            // Bundle IDs only (no audio or text): which processes were tapped, and which were playing
            // audio, so a call app whose audio comes from another process shows up in the log.
            let clients = AudioProcessList.all()
            let named = clients.filter { ids.contains($0.id) }.map(\.bundleID).joined(separator: ",")
            let playing = clients.filter(\.output).map(\.bundleID).joined(separator: ",")
            let kind: String
            if case .only = target { kind = "tapped" } else { kind = "excluded" }
            meetingLog.notice("tap-started processes=\(ids.count) \(kind, privacy: .public)=\(named, privacy: .public) playing=\(playing, privacy: .public)")
        } catch { stop(); throw error }
    }

    /// Runs on `queue` (the IO proc's queue): convert, meter, chunk.
    private func receive(_ list: UnsafePointer<AudioBufferList>) {
        guard let inputFormat, let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: list, deallocator: nil), buffer.frameLength > 0,
              let converted = Capture.convert(buffer, with: converter), converted.frameLength > 0, let samples = converted.floatChannelData else { return }
        var energy = 0.0
        for i in 0..<Int(converted.frameLength) { energy += Double(samples[0][i]) * Double(samples[0][i]) }
        if energy > 0 { heardSignal = true }
        level = min(1, sqrt(energy / Double(converted.frameLength)) * 8)
        let now = ProcessInfo.processInfo.systemUptime
        if let expected = nextExpected, now - expected > 0.2 {
            // In 0.1 s pieces, so the chunker can still cut at its usual length.
            var missing = Int((now - expected) * Self.format.sampleRate)
            while missing >= 1600 { chunker.append(Self.silence); missing -= 1600 }
        }
        nextExpected = now + Double(converted.frameLength) / Self.format.sampleRate
        lastBuffer = now; buffers += 1
        chunker.append(converted)
    }

    /// Adds call-app processes that started after the tap (a browser's audio helper, a new call
    /// window). Returns false when the tap could not be updated; the tap keeps what it had.
    @discardableResult
    func refreshProcesses() -> Bool {
        guard case .only = target, let description, tapID != kAudioObjectUnknown else { return true }
        let ids = Self.processIDs(target, clients: AudioProcessList.all())
        guard Set(ids) != Set(tappedIDs), !ids.isEmpty else { return true }
        description.processes = ids
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var reference = description
        let status = withUnsafeMutablePointer(to: &reference) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status == noErr { tappedIDs = ids }
        meetingLog.notice("tap-processes-updated count=\(ids.count) status=\(status)")
        return status == noErr
    }

    /// Stops the device and destroys the aggregate and the tap; the last chunk is cut and sent.
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID { AudioDeviceStop(aggregateID, procID); AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggregateID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown)
        queue.sync { chunker.finish() }
    }
}

/// Turns one stream's chunk events into pump jobs. Each chunk is renamed `<stream>-<start ms>.wav`
/// in the meeting's folder, so whatever a crash leaves can be finished later (PRD 11.5).
final class MeetingStreamFeed {
    let stream: MeetingStream
    private let folder: URL
    /// Seconds between the meeting's start and this stream's start.
    private let offset: Double
    private var next = 0.0
    private let enqueue: (MeetingPump.Job) -> Void
    private let failed: () -> Void

    init(stream: MeetingStream, folder: URL, offset: Double, enqueue: @escaping (MeetingPump.Job) -> Void, failed: @escaping () -> Void) {
        self.stream = stream; self.folder = folder; self.offset = offset; self.enqueue = enqueue; self.failed = failed
    }

    static func seconds(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Called on the capture queue, in order.
    func receive(_ event: Chunker.Event) {
        switch event {
        case .chunk(let url, let last, _):
            let (duration, peak) = Self.measure(url)
            // Content-free: which stream, how long, how loud. A peak of 0 means the audio was silence.
            meetingLog.notice("meeting-chunk stream=\(self.stream.rawValue, privacy: .public) seconds=\(duration, format: .fixed(precision: 1)) peak=\(peak, format: .fixed(precision: 4)) last=\(last, privacy: .public)")
            let start = offset + next
            next += duration
            let named = folder.appendingPathComponent(MeetingAudio.name(stream, start: start))
            let final = (try? FileManager.default.moveItem(at: url, to: named)) != nil ? named : url
            enqueue(.init(stream: stream, url: final, start: start, duration: duration))
        case .boundary(let url): try? FileManager.default.removeItem(at: url)
        case .end: break
        case .failed: meetingLog.notice("meeting-chunk-write-failed stream=\(self.stream.rawValue, privacy: .public)"); failed()
        }
    }

    /// Length in seconds and peak sample of a chunk file.
    static func measure(_ url: URL) -> (Double, Float) {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let samples = buffer.floatChannelData else { return (seconds(url) ?? 0, 0) }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[0][i])) }
        return (Double(file.length) / file.fileFormat.sampleRate, peak)
    }
}
