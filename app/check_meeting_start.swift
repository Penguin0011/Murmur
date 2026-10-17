import AppKit
import SwiftUI

@main struct MeetingStartChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let presenter = MeetingConsentPresenter()
        var answers: [Bool] = []
        presenter.show(source: .microphoneOnly) { answers.append($0) }
        func consent() -> (NSWindow, MeetingConsentSheet) {
            let window = app.windows.first { $0.isVisible && $0.title == "Start Meeting Notes" }!
            return (window, (window.contentView as! NSHostingView<MeetingConsentSheet>).rootView)
        }
        let (first, cancel) = consent()
        precondition(cancel.source == .microphoneOnly)
        precondition(app.windows.filter(\.isVisible).count == 1, "Consent needs no Settings window")
        cancel.done(false)
        precondition(answers == [false] && !first.isVisible)
        presenter.show(source: .microphoneOnly) { answers.append($0) }
        presenter.show(source: .everything) { answers.append($0) }
        let (second, accept) = consent()
        precondition(accept.source == .everything, "The latest selected source is used")
        precondition(app.windows.filter(\.isVisible).count == 1)
        accept.done(true)
        precondition(answers == [false, true] && !second.isVisible)
        print("Meeting start checks passed (standalone consent, cancel, accept, source replacement).")
    }
}
