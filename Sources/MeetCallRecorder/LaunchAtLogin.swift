import AppKit
import Foundation
import ServiceManagement

/// The "start with the system" checkbox, backed by `SMAppService.mainApp`.
///
/// This registers the app bundle itself as a login item, so it shows up
/// under System Settings > General > Login Items as "MeetCallRecorder"
/// and can be turned off there. The older route - hand-writing a
/// LaunchAgent plist into `~/Library/LaunchAgents` - is deliberately gone:
/// two places writing the same autostart state (the installer script and
/// this checkbox) meant the checkbox could say "off" while launchd
/// happily kept starting the app. See Scripts/manage.sh.
@MainActor
enum LaunchAtLogin {
    enum State {
        case enabled
        /// Registered, but the user has to flick the switch in Login Items
        /// themselves - this is what macOS reports after someone disables
        /// the app there, and re-registering does not clear it.
        case requiresApproval
        case disabled
        /// No bundle to register, i.e. running the bare executable out of
        /// `.build` rather than MeetCallRecorder.app.
        case unavailable
    }

    static var state: State {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    static var isEnabled: Bool { state == .enabled }

    /// Kept so the welcome screen can say *why* the checkbox refused to
    /// stick instead of silently snapping back.
    private(set) static var lastError: Error?

    /// Returns the state the system actually ended up in, which is not
    /// always the one that was asked for - `.requiresApproval` is a
    /// successful registration that still won't launch anything.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> State {
        guard state != .unavailable else { return .unavailable }
        do {
            if enabled {
                // Registering an already-registered service throws, and
                // "it's already on" is not an error worth surfacing.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error
            Log.write("launch at login \(enabled ? "register" : "unregister") failed: \(error)")
        }
        return state
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
