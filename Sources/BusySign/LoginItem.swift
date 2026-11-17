import BusySignCore
import Foundation
import os
import ServiceManagement

private let logger = Logger(subsystem: "io.github.v0rest.busysign", category: "login-item")

/// Start at login through `SMAppService.mainApp`. macOS shows a "background item added" notice on every
/// registration, so the app registers only when the item is missing or the app version changed (which
/// points the item at the upgraded bundle). Every function returns a short reason when something needs
/// the user's attention, `nil` otherwise; the menu and the settings window show it after "Start at login:".
/// Failures are never fatal.
@MainActor
enum LoginItem {
    static let approvalNeeded = "allow BusySign in System Settings → General → Login Items"

    /// Brings the login item in line with the setting at launch.
    static func reconcileAtLaunch(enabled: Bool, settings: SettingsStore) -> String? {
        guard enabled else { return setEnabled(false, settings: settings) }
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            guard settings.loginItemRegisteredVersion != Version.current else { return nil }
            logger.info("app version changed; registering the login item again")
            if let problem = unregister(service) { return problem }
            return register(service, settings: settings)
        case .requiresApproval:
            return approvalNeeded
        default:
            return register(service, settings: settings)
        }
    }

    /// Applies a change of the "Start at login" toggle.
    static func setEnabled(_ enabled: Bool, settings: SettingsStore) -> String? {
        let service = SMAppService.mainApp
        if enabled {
            switch service.status {
            case .enabled: return nil
            case .requiresApproval: return approvalNeeded
            default: return register(service, settings: settings)
            }
        }
        switch service.status {
        case .enabled, .requiresApproval: return unregister(service)
        default: return nil
        }
    }

    private static func register(_ service: SMAppService, settings: SettingsStore) -> String? {
        do {
            try service.register()
        } catch {
            let ns = error as NSError
            logger.error("login item register failed \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            return "could not turn on (\(ns.localizedDescription))"
        }
        settings.loginItemRegisteredVersion = Version.current
        logger.info("login item registered for \(Version.current, privacy: .public)")
        return service.status == .requiresApproval ? approvalNeeded : nil
    }

    private static func unregister(_ service: SMAppService) -> String? {
        do {
            try service.unregister()
        } catch {
            let ns = error as NSError
            logger.error("login item unregister failed \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            return "could not turn off (\(ns.localizedDescription))"
        }
        logger.info("login item unregistered")
        return nil
    }
}
