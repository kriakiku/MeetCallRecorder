import AppKit
import SwiftUI

/// Hosts `SettingsView`.
///
/// Same activation-policy dance as the welcome window - an `LSUIElement`
/// app can't focus a window while it's an accessory - but this one is
/// resizable-free and remembers nothing: it's cheap to rebuild and the
/// settings themselves live in `Settings.shared`.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let window {
            activate(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "MeetCallRecorder Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // See WelcomeWindowController: an NSWindow built by hand releases
        // itself on close, which over-releases what this still holds.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        activate(window)
    }

    private func activate(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        Task { @MainActor in
            // Only back to accessory if this was the last window up - the
            // welcome screen can legitimately be open behind it.
            if !NSApp.windows.contains(where: { $0.isVisible }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
