import AppKit
import SwiftUI

/// Puts `WelcomeView` on screen.
///
/// The app is an `LSUIElement` accessory with no Dock icon, which also
/// means it can't ordinarily take focus or own a real window. So the
/// activation policy is flipped to `.regular` for as long as the welcome
/// screen is up and dropped back afterwards - otherwise the window opens
/// behind whatever the user was doing, with no way to reach it.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    /// Run when the user completes the flow. Not called if they just close
    /// the window.
    private var onFinish: (() -> Void)?

    func show(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish

        if let window {
            activate(window)
            return
        }

        let view = WelcomeView(
            onFinish: { [weak self] in self?.finish() },
            onHeightChange: { [weak self] height in self?.setContentHeight(height) }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: Self.initialHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Before the hosting view exists: SwiftUI's first height report can
        // arrive during that view's initial layout, and `setContentHeight`
        // drops anything that arrives while this is still nil - which on
        // the relaunch path (straight to the shorter permissions page) is
        // the only report that matters.
        self.window = window
        window.contentView = NSHostingView(rootView: view)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // Nothing in here reflows, and a resized window just puts the
        // careful spacing off.
        window.styleMask.remove(.resizable)
        // NSWindow defaults this to true when built by hand, which means
        // `close()` drops the last retain while this controller is still
        // holding the reference - the next autorelease pool pop then
        // over-releases it and the app segfaults on the way out of the
        // welcome flow.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        activate(window)
    }

    /// The greeting page's height. Starting here rather than at zero and
    /// growing avoids the window visibly unfolding on first paint; the
    /// permissions page then animates down to its own size.
    private static let initialHeight: CGFloat = 560

    /// Resizes the window to the page currently showing, keeping the top
    /// edge where it is so the window appears to grow downwards rather
    /// than drift up the screen.
    private func setContentHeight(_ contentHeight: CGFloat) {
        guard let window else { return }
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let target = (contentHeight + chrome).rounded()
        guard abs(target - window.frame.height) > 1 else { return }

        var frame = window.frame
        frame.origin.y += frame.height - target
        frame.size.height = target
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    private func activate(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        let finished = onFinish
        onFinish = nil
        window?.close()
        finished?()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
        onFinish = nil
        // Back to a menu-bar-only app. Deferred because doing it while the
        // window is still tearing itself down leaves the Dock icon behind.
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
