import Foundation

#if canImport(Sparkle)
import Sparkle

/// Sparkle owns its schedule, signature verification, installation UI and persisted preferences.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private let isBusy: () -> Bool
    private let preferencesChanged: (Bool, Bool) -> Void
    private var observations: [NSKeyValueObservation] = []
    private var controller: SPUStandardUpdaterController?
    private var relaunchTimer: Timer?

    init(isBusy: @escaping () -> Bool, preferencesChanged: @escaping (Bool, Bool) -> Void = { _, _ in }) {
        self.isBusy = isBusy; self.preferencesChanged = preferencesChanged
    }

    var automaticallyChecksForUpdates: Bool { controller?.updater.automaticallyChecksForUpdates ?? false }
    var automaticallyDownloadsUpdates: Bool { controller?.updater.automaticallyDownloadsUpdates ?? false }

    func start(checksEnabled: Bool) -> String {
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil else {
            return "Updates are not configured in this build."
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        // Migrate the existing opt-out once; subsequent launches respect Sparkle's own preferences.
        if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil {
            controller.updater.automaticallyChecksForUpdates = checksEnabled
        }
        do { try controller.updater.start() }
        catch { self.controller = nil; return "Could not start updates: \(error.localizedDescription)" }
        observations = [
            controller.updater.observe(\.automaticallyChecksForUpdates) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.preferencesChanged(updater.automaticallyChecksForUpdates, updater.automaticallyDownloadsUpdates) }
            },
            controller.updater.observe(\.automaticallyDownloadsUpdates) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.preferencesChanged(updater.automaticallyChecksForUpdates, updater.automaticallyDownloadsUpdates) }
            }
        ]
        return "Updates are downloaded from GitHub and verified before installation."
    }

    func setPreferences(checks: Bool, installs: Bool) {
        guard let updater = controller?.updater else { return }
        if updater.automaticallyChecksForUpdates != checks { updater.automaticallyChecksForUpdates = checks }
        if updater.automaticallyDownloadsUpdates != installs { updater.automaticallyDownloadsUpdates = installs }
    }

    func checkForUpdates() -> String {
        guard let controller else { return "Updates are not configured in this build." }
        guard !isBusy() else { return "Finish dictation or meeting recording before updating." }
        guard controller.updater.canCheckForUpdates else { return "An update check is already in progress." }
        controller.checkForUpdates(nil)
        return ""
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if isBusy() { throw NSError(domain: "MurmurUpdates", code: 1, userInfo: [NSLocalizedDescriptionKey: "Updates wait until dictation and meeting recording finish."]) }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        relaunchTimer?.invalidate()
        relaunchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                guard !self.isBusy() else { return }
                timer.invalidate(); self.relaunchTimer = nil
                installHandler()
            }
        }
        return true
    }
}
#else
// Synthetic UI fixtures compile without network dependencies and never start an updater.
@MainActor
final class AppUpdater {
    init(isBusy: @escaping () -> Bool, preferencesChanged: @escaping (Bool, Bool) -> Void = { _, _ in }) {}
    var automaticallyChecksForUpdates: Bool { false }
    var automaticallyDownloadsUpdates: Bool { false }
    func start(checksEnabled: Bool) -> String { "Updates are not configured in this build." }
    func setPreferences(checks: Bool, installs: Bool) {}
    func checkForUpdates() -> String { "Updates are not configured in this build." }
}
#endif
