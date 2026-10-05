import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Network-free checks for AppServices.swift. Run from the repository root:
// swiftc app/Retention.swift app/ModelDownload.swift app/Updates.swift app/AppServices.swift app/check_app_services.swift -o /tmp/murmur-app-services-check && /tmp/murmur-app-services-check

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if !condition { failures += 1; print("FAIL: \(name)") }
}

struct Item: RetainedHistoryItem, Equatable {
    let id: String
    let recordedAt: Date
    var text: String
}

final class FakeDisk {
    var items: [String: Item] = [:]
    var saves = 0
    var failSave = false
    var disk: HistoryDisk<Item> {
        HistoryDisk(save: { [self] item in
            if self.failSave { throw RetentionError("disk full") }
            self.saves += 1; self.items[item.id] = item
        }, entries: { [self] in Array(self.items.values) },
           delete: { [self] item in
            guard self.items.removeValue(forKey: item.id) != nil else { throw RetentionError("missing") }
        })
    }
}

func item(_ secondsAgo: TimeInterval, _ text: String = "t", now: Date = Date()) -> Item {
    Item(id: UUID().uuidString, recordedAt: now.addingTimeInterval(-secondsAgo), text: text)
}

// MARK: Model facts and row

func checkModelRow() {
    let home = URL(fileURLWithPath: "/Users/someone")
    check(ModelFacts.defaultDirectory(home: home).path == "/Users/someone/Library/Caches/Dictation/module-one/unified-d32e972", "default model directory matches existing installs")
    check(ModelFacts.formatBytes(1_801_783_964) == "1.80 GB", "pinned size formats as 1.80 GB")
    check(ModelFacts.formatBytes(512_400_000) == "512 MB", "megabytes")
    check(ModelFacts.formatBytes(-5) == "0 bytes" && ModelFacts.formatBytes(999) == "999 bytes", "small and negative sizes")
    check(ModelFacts.summary(downloadSize: 1_801_783_964) == "1.80 GB download · English · Runs on this Mac", "row summary")

    let license = ModelLicenseInfo.parakeetUnifiedUnpinned
    let text = ModelFacts.licenseText(license)
    check(text.contains("NVIDIA Open Model License") && text.contains("CC-BY-4.0"), "license text names both declarations")
    check(text.contains("https://www.nvidia.com/") && text.contains("https://huggingface.co/FluidInference/"), "license text has both links")
    check(text.contains("has not resolved"), "license text keeps the unresolved note")
    let confirm = ModelFacts.confirmation(downloadSize: 1_801_783_964, license: license)
    check(confirm.title.contains("1.80 GB") && confirm.body.contains("1.80 GB") && confirm.body.contains("License:") && confirm.body.contains(license.note), "confirmation states size and license before download")

    check(ModelFacts.completionMessage(.success(())).contains("ready"), "success message")
    check(ModelFacts.completionMessage(.failure(.cancelled)).contains("Retry"), "cancel message explains retry")
    check(ModelFacts.completionMessage(.failure(.diskFull)) == ModelDownloadError.diskFull.userMessage, "errors use the downloader's messages")

    let missing = ModelRowPresentation.make(nil)
    check(missing.actions.isEmpty && missing.statusText == ModelDownloadError.invalidManifest.userMessage, "missing manifest offers nothing")
    check(ModelRowPresentation.make(.notDownloaded).actions == [.download], "not downloaded offers Download")
    let half = ModelRowPresentation.make(.downloading(ModelDownloadProgress(bytesDone: 900_891_982, totalBytes: 1_801_783_964)))
    check(half.actions == [.cancel] && half.isWorking && half.progress == 0.5 && half.statusText.contains("50%") && half.statusText.contains("of 1.80 GB"), "downloading shows progress and Cancel")
    let verifying = ModelRowPresentation.make(.verifying)
    check(verifying.actions == [.cancel] && verifying.isWorking && verifying.progress == nil, "verifying offers Cancel")
    let ready = ModelRowPresentation.make(.ready)
    check(ready.actions == [.remove] && ready.isReady && !ready.isWorking, "ready offers Remove")
    check(ModelRowPresentation.make(.corrupt(ModelDownloader.corruptReason)).actions == [.retry, .remove], "corrupt offers Retry and Remove")
    let failed = ModelRowPresentation.make(.failed(.network))
    check(failed.actions == [.retry, .remove] && failed.statusText == ModelDownloadError.network.userMessage, "failed offers Retry and Remove")
    check(ModelRowPresentation.make(.failed(.cancelled)).actions == [.retry, .remove], "cancelled offers Retry and Remove (discard partial)")

    check(ModelGate.startRefusal(modelAvailable: true, runtimeAvailable: true, downloadingActiveModel: false) == nil, "ready model may record")
    check(ModelGate.startRefusal(modelAvailable: true, runtimeAvailable: true, downloadingActiveModel: true) == ModelGate.downloadingMessage, "download of active folder blocks recording")
    check(ModelGate.startRefusal(modelAvailable: false, runtimeAvailable: true, downloadingActiveModel: false)?.contains("Download the model in Settings") == true, "missing model explains recovery")
    check(ModelGate.startRefusal(modelAvailable: true, runtimeAvailable: false, downloadingActiveModel: false) == ModelGate.missingRuntimeMessage, "missing runtime")
    check(ModelGate.removeRefusal(isBusy: true, preview: false, downloading: false) != nil, "remove refused while recording or processing")
    check(ModelGate.removeRefusal(isBusy: false, preview: false, downloading: true) != nil, "remove refused while downloading")
    check(ModelGate.removeRefusal(isBusy: false, preview: true, downloading: false) != nil, "remove refused in preview")
    check(ModelGate.removeRefusal(isBusy: false, preview: false, downloading: false) == nil, "remove allowed when idle")
    check(ModelGate.downloadRefusal(isBusy: true, preview: false, downloading: false) != nil, "download refused while busy")
    check(ModelGate.downloadRefusal(isBusy: false, preview: false, downloading: true) == ModelDownloadError.busy.userMessage, "second download refused")
    check(ModelGate.downloadRefusal(isBusy: false, preview: true, downloading: false) != nil, "download refused in preview")
    check(ModelGate.downloadRefusal(isBusy: false, preview: false, downloading: false) == nil, "download allowed when idle")
    check(Set(license.declarations.map(\.id)).count == license.declarations.count, "license declarations have distinct ids")
}

// MARK: History routing

func checkHistoryRouter() throws {
    let fake = FakeDisk()
    let router = HistoryRouter(disk: fake.disk, persists: true)
    let a = item(60)
    try router.save(a)
    check(fake.items[a.id] == a && router.sessionOnlyIDs.isEmpty, "history on writes to disk")

    router.persistsTranscripts = false
    var held = item(10, "held cleanup")
    try router.save(held)
    check(fake.items[held.id] == nil && router.sessionOnlyIDs == [held.id], "history off keeps the entry in memory only")
    held.text = "insertion failed"
    router.persistsTranscripts = true
    try router.save(held)
    check(fake.items[held.id] == nil && router.sessionOnlyIDs == [held.id], "a memory entry stays in memory after history is turned back on")
    let listed = try router.entries()
    check(listed.map(\.id) == [held.id, a.id] && listed.first?.text == "insertion failed", "entries merge memory and disk, newest first, latest status")

    // Recovery text stays available for the session.
    check(try router.entries().contains { $0.id == held.id && $0.text == "insertion failed" }, "recovery text available in memory")

    // A disk failure is reported, not silently moved to memory.
    fake.failSave = true
    do { try router.save(item(1)); check(false, "disk failure must throw") } catch { }
    fake.failSave = false

    try router.delete(held)
    check(router.sessionOnlyIDs.isEmpty && fake.items[a.id] != nil, "deleting a memory entry leaves disk alone")
    try router.delete(a)
    check(fake.items.isEmpty, "deleting a disk entry removes it from disk")

    // Same id on disk and in memory: memory wins in the list, delete removes the memory copy first.
    let dual = item(5)
    fake.items[dual.id] = dual
    router.persistsTranscripts = false
    var newer = dual; newer.text = "newer"
    try router.save(newer)
    check(try router.entries().filter { $0.id == dual.id }.map(\.text) == ["newer"], "memory copy wins over disk copy")

    // Memory bound and retention.
    let small = HistoryRouter(disk: FakeDisk().disk, persists: false, memoryLimit: 3)
    let now = Date()
    let olds = (0..<5).map { item(Double(50 - $0 * 10), "n\($0)", now: now) }
    for entry in olds { try small.save(entry) }
    check(small.sessionOnlyIDs == Set(olds.suffix(3).map(\.id)), "memory keeps the newest entries within its limit")
    small.purgeSessionOnly(recordedAtOrBefore: now.addingTimeInterval(-25))
    check(small.sessionOnlyIDs == Set(olds.suffix(2).map(\.id)), "memory retention drops entries at or before the cutoff")
    small.clearSessionOnly()
    check(try small.entries().isEmpty, "clear empties memory")

    // Concurrent saves from a background queue while the main thread lists.
    let concurrent = HistoryRouter(disk: FakeDisk().disk, persists: false, memoryLimit: 1000)
    DispatchQueue.concurrentPerform(iterations: 200) { i in
        if i % 2 == 0 { try? concurrent.save(item(Double(i))) } else { _ = try? concurrent.entries() }
    }
    check(concurrent.sessionOnlyIDs.count == 100, "concurrent saves are all kept")
}

func checkExpiryAndText() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    check(HistoryExpiry.cutoff(.forever, now: now, calendar: calendar) == nil, "forever has no cutoff")
    check(HistoryExpiry.cutoff(.thirtyDays, now: now, calendar: calendar) == now.addingTimeInterval(-30 * 86400), "30-day cutoff matches HistoryStore")
    check(HistoryExpiry.cutoff(.sixMonths, now: now, calendar: calendar) == calendar.date(byAdding: .month, value: -6, to: now), "six months uses calendar months")

    check(HistoryText.summary(mode: .on, count: 2, sessionOnly: 0) == "Saved locally · 2 transcripts", "history on summary keeps the existing wording")
    check(HistoryText.summary(mode: .on, count: 1, sessionOnly: 1).contains("1 kept only until Murmur quits"), "history on with memory entries says so")
    check(HistoryText.summary(mode: .off, count: 0, sessionOnly: 0).hasPrefix("History is off"), "history off summary")
    check(HistoryText.saved(persists: true) == "Saved in History." && HistoryText.saved(persists: false).contains("until Murmur quits"), "saved wording follows mode")
    check(HistoryMode.offDisclosure.contains("cannot be recovered"), "off disclosure available")
}

// MARK: Delete all data

func checkWipe() throws {
    var order: [PostWipeStep] = []
    let failed = PostWipeStep.run { step in
        order.append(step)
        if step == .recreateRetryAudio { throw RetentionError("no") }
    }
    check(order == PostWipeStep.allCases, "every reload step runs, in order, past a failure")
    check(order.first == .discardInMemoryState && order.last == .refreshViews, "discard first, refresh last")
    check(failed == [.recreateRetryAudio], "failed steps are reported")

    let clean = PostWipeStep.message(report: DeleteAllReport(), failedSteps: [])
    check(clean.succeeded && clean.text.contains("All Murmur data was deleted"), "success message")
    var partial = DeleteAllReport(); partial.failures = ["Could not remove Keychain items: denied"]
    let bad = PostWipeStep.message(report: partial, failedSteps: [.recreateHistory])
    check(!bad.succeeded && bad.text.contains("Keychain") && bad.text.contains("history"), "failure message lists problems")
    check(DeleteAllDataText.body.contains("Keychain") && DeleteAllDataText.body.contains("cannot be undone") && DeleteAllDataText.body.contains("Backups"), "wipe confirmation is explicit")

    // End to end with the real DataWipe on a temporary tree, then the reload plan recreates empty directories.
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-wipe-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let locations = MurmurDataLocations.standard(base: base)
    for dir in [locations.history, locations.dictionary, locations.retryAudio] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("f.json"))
    }
    var keychainCalls = 0
    let report = DataWipe.deleteAllData(locations) { keychainCalls += 1; return ["openrouter"] }
    check(report.succeeded && keychainCalls == 1, "wipe succeeds and removes Keychain items once")
    let fake = FakeDisk()
    var router: HistoryRouter<Item>? = HistoryRouter(disk: fake.disk, persists: false)
    try router?.save(item(1))
    let reloadFailed = PostWipeStep.run { step in
        switch step {
        case .discardInMemoryState: router?.clearSessionOnly(); router = nil
        case .recreateHistory: try FileManager.default.createDirectory(at: locations.history, withIntermediateDirectories: true); router = HistoryRouter(disk: fake.disk, persists: false)
        case .recreateRetryAudio: try FileManager.default.createDirectory(at: locations.retryAudio, withIntermediateDirectories: true)
        case .reloadDictionary: try FileManager.default.createDirectory(at: locations.dictionary, withIntermediateDirectories: true)
        case .refreshViews: break
        }
    }
    let emptyAfter = (try router?.entries().isEmpty) == true
    check(reloadFailed.isEmpty && emptyAfter, "reload leaves empty history, memory entries included")
    check(((try? FileManager.default.contentsOfDirectory(atPath: locations.history.path)) ?? ["x"]).isEmpty, "recreated history directory is empty")
}

// MARK: Updates

func checkUpdates() async throws {
    let release = ReleaseInfo(version: SemanticVersion("0.2.0")!, tag: "v0.2.0", title: "Murmur 0.2.0", notes: "Fixes.", pageURL: URL(string: "https://github.com/Penguin0011/Murmur/releases/tag/v0.2.0")!, publishedAt: nil)
    let fixed: (Date) -> String = { _ in "10:00" }
    check(UpdateText.status(.updateAvailable(release), manual: false, currentVersion: "0.1.0", timeFormatter: fixed) == "Murmur 0.2.0 is available. This Mac has 0.1.0.", "update available names both versions")
    check(UpdateText.status(.upToDate(latest: nil), manual: true, currentVersion: "0.1.0") == "Murmur 0.1.0 is up to date.", "up to date")
    check(UpdateText.status(.noReleases, manual: false, currentVersion: "0.1.0")?.contains("No Murmur releases") == true, "no releases is quiet text")
    check(UpdateText.status(.throttled(nextCheck: Date()), manual: false, currentVersion: "0.1.0") == nil, "skipped automatic check keeps the current line")
    check(UpdateText.status(.offline, manual: false, currentVersion: "0.1.0")?.contains("try again later") == true, "automatic offline is quiet")
    check(UpdateText.status(.offline, manual: true, currentVersion: "0.1.0")?.contains("internet connection") == true, "manual offline suggests the connection")
    check(UpdateText.status(.rateLimited(until: Date()), manual: true, currentVersion: "0.1.0", timeFormatter: fixed) == "GitHub is limiting update checks. Try again after 10:00.", "rate limit names the time")
    check(UpdateText.status(.rateLimited(until: nil), manual: true, currentVersion: "0.1.0")?.contains("later") == true, "rate limit without time")
    check(UpdateText.status(.failed(.malformedResponse), manual: true, currentVersion: "0.1.0") != nil, "failure is text, not an error state")

    check(UpdateText.release(.updateAvailable(release), previous: nil) == release, "release kept for display")
    check(UpdateText.release(.offline, previous: release) == release, "offline keeps a known release")
    check(UpdateText.release(.upToDate(latest: nil), previous: release) == nil, "up to date clears it")
    check(UpdateText.headline(release) == "Murmur 0.2.0", "headline")
    check(UpdateText.headline(ReleaseInfo(version: release.version, tag: "v0.2.0", title: "  ", notes: "", pageURL: release.pageURL, publishedAt: nil)) == "Murmur 0.2.0", "blank title falls back to the version")
    check(UpdateText.notesExcerpt(String(repeating: "a", count: 2000), limit: 10) == "aaaaaaaaaa…" && UpdateText.notesExcerpt("  short \n") == "short", "notes are trimmed")
    check(UpdateText.menuTitle(nil) == "Check for Updates…" && UpdateText.menuTitle(release) == "Update Available: Murmur 0.2.0…", "menu title")
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    check(UpdateSchedule.shouldAttemptAutomatic(lastAttempt: nil, now: t0), "first automatic attempt runs")
    check(!UpdateSchedule.shouldAttemptAutomatic(lastAttempt: t0, now: t0.addingTimeInterval(60)), "no automatic retry a minute later")
    check(UpdateSchedule.shouldAttemptAutomatic(lastAttempt: t0, now: t0.addingTimeInterval(3600)), "automatic attempt again after an hour")
    check(UpdateSchedule.shouldAttemptAutomatic(lastAttempt: t0.addingTimeInterval(500), now: t0), "a future attempt time (clock change) does not block")
    check(UpdateText.explanation.contains("uses the network") && UpdateText.explanation.contains("Nothing is downloaded"), "automatic-check explanation")

    // The bundled version string parses, and the UserDefaults throttle store skips a second automatic check.
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "app/Info.plist")), format: nil) as? [String: Any]
    let version = plist?["CFBundleShortVersionString"] as? String ?? ""
    check(SemanticVersion(version) != nil, "Info.plist CFBundleShortVersionString is a semantic version (\(version))")
    let suite = "murmur-app-services-check-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    final class CountingClient: UpdateHTTPClient, @unchecked Sendable {
        var calls = 0
        func get(_ request: URLRequest) async throws -> UpdateHTTPResponse { calls += 1; return UpdateHTTPResponse(status: 200, headers: [:], body: Data("[]".utf8)) }
    }
    let client = CountingClient()
    let configuration = try UpdateConfiguration(currentVersion: version)
    let first = await UpdateChecker(configuration: configuration, client: client, store: UserDefaultsUpdateCheckStore(defaults: defaults)).check(manual: false)
    let second = await UpdateChecker(configuration: configuration, client: client, store: UserDefaultsUpdateCheckStore(defaults: defaults)).check(manual: false)
    let manual = await UpdateChecker(configuration: configuration, client: client, store: UserDefaultsUpdateCheckStore(defaults: defaults)).check(manual: true)
    check(first == .noReleases && client.calls == 2, "manual check bypasses the throttle")
    if case .throttled = second {} else { check(false, "second automatic check after relaunch is throttled by UserDefaults") }
    check(manual == .noReleases, "manual result")
}

@main struct AppServicesChecks {
    static func main() async throws {
        checkModelRow()
        try checkHistoryRouter()
        checkExpiryAndText()
        try checkWipe()
        try await checkUpdates()
        if failures > 0 { print("\(failures) app services check(s) failed."); exit(1) }
        print("App services checks passed (model row, gates, history-off routing, retention, wipe reload, update text, throttle).")
    }
}
