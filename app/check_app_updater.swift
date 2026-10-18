// swiftc -swift-version 5 -parse-as-library -F runtime/Sparkle-2.10.0 -framework Sparkle
//   -Xlinker -rpath -Xlinker "$PWD/runtime/Sparkle-2.10.0" app/AppUpdater.swift app/check_app_updater.swift -o /tmp/murmur-sparkle-check
import AppKit
import Sparkle

@main struct AppUpdaterChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var busy = true
        let service = AppUpdater(isBusy: { busy })
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        assert(service.start(checksEnabled: false) == "Updates are not configured in this build.")
        assert(service.checkForUpdates() == "Updates are not configured in this build.")
        do {
            try service.updater(updater, mayPerform: .updatesInBackground)
            assertionFailure("Recording must block background checks")
        } catch { assert((error as NSError).domain == "MurmurUpdates") }
        do {
            try service.updater(updater, mayPerform: .updates)
            assertionFailure("Recording must block manual checks")
        } catch { assert((error as NSError).domain == "MurmurUpdates") }
        // No appcast parsing is under test; the delegate only needs an item to identify an update.
        let item = SUAppcastItem(dictionary: ["title": "Fixture", "sparkle:version": "2",
            "enclosure": ["url": "https://example.com/Murmur.zip", "sparkle:version": "2", "length": "1"]])!
        var installed = false
        assert(service.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { installed = true }))
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        assert(!installed, "Never relaunch while recording")
        busy = false
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        assert(installed, "Resume the pending install once idle")
        installed = false
        assert(!service.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { installed = true }))
        assert(!installed, "Sparkle invokes its own handler when no postponement is needed")
        try service.updater(updater, mayPerform: .updatesInBackground)
        print("Sparkle recording guards, deferred relaunch and unconfigured-build checks passed")
    }
}
