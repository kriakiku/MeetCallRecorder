import AppKit
import Foundation

/// What the welcome flow remembers between launches.
///
/// Granting Screen Recording costs a relaunch - macOS kills the app so the
/// new grant takes - and the relaunch has to land the user back on the
/// permissions page, not at the start of a greeting they already read.
/// That's the only reason `introSeen` is persisted separately from
/// `completed`.
enum Onboarding {
    private static let introSeenKey = "onboarding.introSeen"
    private static let completedKey = "onboarding.completed"

    private static var defaults: UserDefaults { .standard }

    static var introSeen: Bool {
        get { defaults.bool(forKey: introSeenKey) }
        set { defaults.set(newValue, forKey: introSeenKey) }
    }

    static var completed: Bool {
        get { defaults.bool(forKey: completedKey) }
        set { defaults.set(newValue, forKey: completedKey) }
    }

    /// Show the welcome screen when the user has never been through it, or
    /// when a grant it was supposed to secure has since been taken away
    /// (revoked in System Settings, or lost because the app's signing
    /// identity changed). Either way there's nothing to record without it,
    /// so the screen is the honest response - a menu bar icon that
    /// silently never fires is not.
    @MainActor
    static var isNeeded: Bool {
        !completed || !Permission.allCases.allSatisfy { !$0.isRequired || $0.isGranted }
    }

    /// Quits and comes back. Used after a grant that the running process
    /// can't pick up.
    @MainActor
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            // Bare executable (`swift run`): there's no bundle for
            // NSWorkspace to open, so hand off to the binary directly.
            // launchd-managed runs land here too and get restarted by
            // launchd instead, which is why exit is unconditional.
            let path = Bundle.main.executableURL?.path
            if let path {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                try? process.run()
            }
            NSApp.terminate(nil)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        // Without this, NSWorkspace sees us already running and just
        // activates the existing (about to die) instance.
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
