import AppKit
import SwiftUI

private final class DragCheckWindow: NSWindow {
    var dragged = false
    override func performDrag(with event: NSEvent) { dragged = true }
}

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
        let dragWindow = DragCheckWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        var clicks = 0
        let handle = MeetingDragView { clicks += 1 }
        dragWindow.contentView = handle
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 20), modifierFlags: [], timestamp: 0,
                               windowNumber: dragWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        app.postEvent(mouse(.leftMouseUp, 20), atStart: true)
        handle.mouseDown(with: mouse(.leftMouseDown, 20))
        precondition(clicks == 1 && !dragWindow.dragged, "Click still expands the indicator")
        app.postEvent(mouse(.leftMouseDragged, 30), atStart: true)
        handle.mouseDown(with: mouse(.leftMouseDown, 20))
        precondition(clicks == 1 && dragWindow.dragged, "Dragging moves the panel without expanding it")
        print("Meeting start checks passed (standalone consent, cancel, accept, source replacement, indicator click and drag).")
    }
}
