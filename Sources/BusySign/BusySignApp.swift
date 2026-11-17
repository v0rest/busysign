import BusySignCore
import Foundation
import SwiftUI

/// Owns the model for the whole app run and starts it once launching has finished, so syncing begins at
/// login without the menu ever being opened.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    // Typed out: each window's closure refers to the other, which type inference cannot follow.
    private(set) lazy var meetingsWindow: MeetingsWindowController = .init(
        model: model,
        endEditing: { [weak self] in self?.settingsWindow.endEditing() },
        revert: { [weak self] in self?.settingsWindow.revertStagedChanges() }
    )
    private(set) lazy var settingsWindow: SettingsWindowController = .init(model: model) { [weak self] in
        self?.meetingsWindow.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onNotificationClick { [weak self] in self?.settingsWindow.show() }
        model.start()
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the settings window: without a Dock icon
    /// there is nothing else to show.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }
}

struct BusySignApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(
                model: appDelegate.model,
                openMeetings: { appDelegate.meetingsWindow.show() },
                openSettings: { appDelegate.settingsWindow.show() },
                endEditing: { appDelegate.settingsWindow.endEditing() }
            )
        } label: {
            MenuBarIcon(model: appDelegate.model)
        }
    }
}

/// Entry point. Handles `--version` before SwiftUI starts.
@main
enum BusySignMain {
    static func main() {
        if CommandLine.arguments.dropFirst().contains("--version") {
            print(Version.current)
            exit(0)
        }
        BusySignApp.main()
    }
}
