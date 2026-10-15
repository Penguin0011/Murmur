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

/// What the tap captures: the processes of these bundle IDs, or everything except them.
enum TapTarget: Equatable {
    case only([String])
    case allExcept([String])
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
    private let chunker: Chunker
    private var tapID = AudioObjectID(kAudioObjectUnknown), aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var description: CATapDescription?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var target: TapTarget = .allExcept([])
    private var tappedIDs: [AudioObjectID] = []

    init(chunkFolder: URL) { chunker = Chunker(format: Self.format, directory: chunkFolder, boundaries: false) }
    /// Replays earlier events, as Capture.attachChunks does.
    func attachChunks(_ handler: @escaping (Chunker.Event) -> Void) { queue.sync { chunker.attach(handler) } }

    /// Process objects for `target` among the current clients.
    static func processIDs(_ target: TapTarget, clients: [AudioProcessList.Client]) -> [AudioObjectID] {
        let bundleIDs: [String]
        switch target { case .only(let ids), .allExcept(let ids): bundleIDs = ids }
        return clients.filter { bundleIDs.contains($0.bundleID) }.map(\.id)
    }

    func start(_ target: TapTarget) throws {
        self.target = target
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
            meetingLog.notice("tap-started processes=\(ids.count)")
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
        lastBuffer = ProcessInfo.processInfo.systemUptime
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
        case .chunk(let url, _, _):
            let duration = Self.seconds(url) ?? 0
            let start = offset + next
            next += duration
            let named = folder.appendingPathComponent(MeetingAudio.name(stream, start: start))
            let final = (try? FileManager.default.moveItem(at: url, to: named)) != nil ? named : url
            enqueue(.init(stream: stream, url: final, start: start, duration: duration))
        case .boundary(let url): try? FileManager.default.removeItem(at: url)
        case .end: break
        case .failed: failed()
        }
    }
}
