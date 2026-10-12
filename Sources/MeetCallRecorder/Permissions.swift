import AppKit
import ApplicationServices
import CoreGraphics

/// A privacy grant the welcome screen asks the user for: how to read its
/// current state, how to raise the system's own prompt for it, and which
/// System Settings pane to send the user to when the prompt has already
/// been answered once (macOS only ever shows it once per app identity -
/// after that the only way through is the pane).
enum Permission: String, CaseIterable, Identifiable, Sendable {
    case screenRecording
    case accessibility

    var id: String { rawValue }

    /// Whether the app is useless without it. Screen Recording is the
    /// whole app: ScreenCaptureKit needs it to capture a window, and
    /// `CGWindowListCopyWindowInfo` needs it to return window *titles*,
    /// which is how calls are detected in the first place - without it
    /// `kCGWindowName` comes back empty for every window and nothing is
    /// ever recognised as a call. Accessibility is listed so the grant is
    /// already in place for title/window reads that don't go through
    /// Quartz, but nothing today depends on it.
    var isRequired: Bool { self == .screenRecording }

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    var summary: String {
        switch self {
        case .screenRecording:
            return "Captures the call window and its audio, and reads window titles to tell when a call starts."
        case .accessibility:
            return "Reads window details the capture API doesn't expose. Not used yet - granting it now avoids a second restart later."
        }
    }

    var symbolName: String {
        switch self {
        case .screenRecording: return "rectangle.inset.filled.badge.record"
        case .accessibility: return "accessibility"
        }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording:
            // Preflight, never `CGRequestScreenCaptureAccess` - the
            // request variant raises the system prompt as a side effect,
            // and this is called on a timer while the welcome screen is
            // open.
            return CGPreflightScreenCaptureAccess()
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    /// Raises the system prompt if this app identity has never been asked,
    /// and otherwise opens the pane - from the user's side the button does
    /// the same thing either way, which is why there's one of it.
    @MainActor
    func request() {
        switch self {
        case .screenRecording:
            // Blocks until the prompt is dismissed on some releases, so
            // it can't run on the main thread: doing so freezes the
            // welcome window underneath the prompt.
            Task.detached {
                if !CGRequestScreenCaptureAccess() {
                    await self.openSystemSettings()
                }
            }
        case .accessibility:
            // Spelled out rather than using `kAXTrustedCheckOptionPrompt`:
            // that's an imported global `var`, which Swift 6 won't let a
            // concurrent context touch. The string behind it is API.
            let options = ["AXTrustedCheckOptionPrompt": true]
            if !AXIsProcessTrustedWithOptions(options as CFDictionary) {
                // The prompt this raises is only a signpost to Settings -
                // unlike Screen Recording there's no in-prompt "Allow" -
                // so open the pane alongside it rather than instead of it.
                openSystemSettings()
            }
        }
    }

    @MainActor
    func openSystemSettings() {
        let anchor: String
        switch self {
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Tracks the live state of every `Permission` for the welcome screen, and
/// remembers which ones were already granted when the process started.
///
/// That second part is what drives the restart prompt. A TCC grant handed
/// out while the app is running doesn't reach the process that asked for
/// it: ScreenCaptureKit keeps failing until the app is relaunched, and
/// macOS says as much in its own "quit and reopen" alert. So a permission
/// that flipped to granted *during this session* still counts as blocking,
/// and the screen asks for a restart instead of letting the user through
/// into an app that would silently record nothing.
@MainActor
@Observable
final class PermissionCoordinator {
    private(set) var granted: Set<Permission> = []
    /// Granted before this process launched, and therefore actually usable
    /// by it.
    private let grantedAtLaunch: Set<Permission>

    private var pollTask: Task<Void, Never>?

    /// Taken once per process, and deliberately not per instance: the
    /// welcome screen can be closed and reopened from the menu, and a
    /// fresh snapshot on the second showing would quietly decide that a
    /// grant made during the first one had been there all along - no
    /// restart demanded, and an app that records nothing.
    private static var launchSnapshot: Set<Permission>?

    /// Call as early in the launch as possible. Safe to call more than
    /// once; only the first one counts.
    static func captureLaunchState() {
        guard launchSnapshot == nil else { return }
        launchSnapshot = Set(Permission.allCases.filter(\.isGranted))
    }

    init() {
        // Falls back to priming itself, so a missed call at startup costs
        // accuracy for grants made before this point rather than wrongly
        // demanding a restart for everything.
        Self.captureLaunchState()
        grantedAtLaunch = Self.launchSnapshot ?? []
        granted = Set(Permission.allCases.filter(\.isGranted))
    }

    func isGranted(_ permission: Permission) -> Bool { granted.contains(permission) }

    /// Granted, but only since launch - the grant exists and the process
    /// can't use it yet.
    func needsRestart(_ permission: Permission) -> Bool {
        granted.contains(permission) && !grantedAtLaunch.contains(permission)
    }

    var allRequiredGranted: Bool {
        Permission.allCases.allSatisfy { !$0.isRequired || granted.contains($0) }
    }

    /// Every required grant is in place *and* was in place early enough to
    /// be usable. The welcome screen's Continue button hangs off this.
    var readyToRecord: Bool {
        allRequiredGranted && !Permission.allCases.contains { $0.isRequired && needsRestart($0) }
    }

    /// Any grant picked up mid-session, required or not - an optional
    /// permission that needs a restart is worth saying so about, even
    /// though it doesn't block.
    var restartPending: Bool {
        Permission.allCases.contains { needsRestart($0) }
    }

    /// There's no notification for a TCC change, so the only way to see
    /// the user flip the switch in System Settings is to keep asking.
    func startPolling() {
        guard pollTask == nil else { return }
        // Weakly, and bailing out when the reference is gone: closing the
        // welcome window tears the SwiftUI state down without necessarily
        // running `onDisappear`, and a task holding this strongly would
        // then poll TCC forever behind a window nobody can see.
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() {
        granted = Set(Permission.allCases.filter(\.isGranted))
    }
}
