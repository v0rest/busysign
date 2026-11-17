import AppKit
import SwiftUI

/// The Meetings window, managed in AppKit like Settings so it reliably comes to the front for an app
/// without a Dock icon. Resizable; AppKit keeps its frame between launches. Kept after it closes, so it tells the
/// model when it opens and closes (`AppModel.meetingsWindowDidOpen`), which reads the days' own titles only
/// while it is open.
@MainActor
final class MeetingsWindowController: NSObject, NSWindowDelegate {
    private static let frameName = "BusySignMeetingsWindow"
    private let model: AppModel
    /// Settings' own hooks for this window's bar: end editing there before Apply, and revert with it
    /// (`SettingsWindowController.endEditing`, `revertStagedChanges`).
    private let endEditing: @MainActor () -> Void
    private let revert: @MainActor () -> Void
    private var window: NSWindow?

    init(model: AppModel, endEditing: @escaping @MainActor () -> Void,
         revert: @escaping @MainActor () -> Void) {
        self.model = model
        self.endEditing = endEditing
        self.revert = revert
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        model.meetingsWindowDidOpen()
    }

    func windowWillClose(_ notification: Notification) {
        model.meetingsWindowDidClose()
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(
            rootView: MeetingsView(model: model, endEditing: endEditing, revert: revert)
        )
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.title = "BusySign Meetings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 640, height: 640))
        window.center()
        // A frame saved by an earlier launch wins over the default above; from now on moves and resizes
        // are saved.
        window.setFrameUsingName(Self.frameName)
        window.setFrameAutosaveName(Self.frameName)
        return window
    }
}
