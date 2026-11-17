import BusySignCore
import Foundation
import os
import UserNotifications

private let logger = Logger(subsystem: "io.github.v0rest.busysign", category: "notify")

/// macOS notifications: one when calendar access is missing, notified once until access comes back; the
/// memory is in-process only, so a relaunch may notify once more. Notifications never carry event content.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var notifiedAccess = false
    /// Asked lazily, the first time a notification is needed; kept once granted.
    private var authorization: Task<Bool, Never>?
    /// Runs when the user clicks one of our notifications.
    var onClick: (@MainActor () -> Void)?

    /// UNUserNotificationCenter raises outside an app bundle (a bare `swift build` binary).
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// Becomes the center's delegate at launch, so a click on a notification delivered while the app was
    /// not running still reaches it. Does not ask for authorization.
    func install() {
        guard isBundled else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Call on every observed access state.
    func accessChanged(_ access: AccessState) {
        switch access {
        case .granted:
            notifiedAccess = false
        case .denied:
            guard !notifiedAccess else { return }
            notifiedAccess = true
            post(id: "access", body: SyncEngine.accessNeeded)
        case .notDetermined:
            // The system prompt is showing or about to show.
            break
        }
    }

    private func post(id: String, body: String) {
        guard isBundled else {
            logger.info("not in an app bundle; notification \(id, privacy: .public) skipped")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "BusySign"
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            guard await isAuthorized() else {
                logger.info("notifications not allowed; \(id, privacy: .public) not shown")
                return
            }
            do {
                try await UNUserNotificationCenter.current().add(request)
                logger.info("notification \(id, privacy: .public) posted")
            } catch {
                let ns = error as NSError
                logger.error("notification failed \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            }
        }
    }

    private func isAuthorized() async -> Bool {
        if let authorization { return await authorization.value }
        let task = Task<Bool, Never> {
            do {
                return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                let ns = error as NSError
                logger.error("notification authorization failed \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
                return false
            }
        }
        authorization = task
        let granted = await task.value
        // Asked again next time, so allowing notifications later in System Settings takes effect;
        // macOS prompts only once.
        if !granted { authorization = nil }
        return granted
    }

    private func clicked() {
        logger.info("notification clicked")
        onClick?()
    }

    /// Opens the settings window; nothing of the response leaves this method.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await clicked()
    }

    /// Shows banners even while the settings window has the app active.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
