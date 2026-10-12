import SwiftUI

/// The first-run screen: a greeting, then the permissions the app can't
/// work without.
///
/// Flow-wise the interesting part is that the second page has to survive
/// being arrived at cold. Granting Screen Recording forces a relaunch, so
/// "page two" is a destination the app boots directly into (see
/// `Onboarding.introSeen`), not just somewhere you get to by pressing
/// Continue on page one.
struct WelcomeView: View {
    /// Called once the user is through: permissions in place, login-item
    /// choice applied. The app starts detecting calls at this point.
    let onFinish: () -> Void
    /// The height the current page wants. The two pages are very different
    /// shapes - a tall hero and a compact list - and one window size that
    /// suits both leaves the list floating in empty space, so the window
    /// follows the page instead.
    let onHeightChange: (CGFloat) -> Void

    private enum Page {
        case intro
        case permissions
    }

    @State private var page: Page
    @State private var permissions = PermissionCoordinator()
    @State private var launchAtLogin: Bool
    /// Set when flipping the switch didn't produce the state it asked
    /// for, so the screen can explain instead of just snapping back.
    @State private var launchAtLoginNote: String?

    // Intro stagger. Separate flags rather than one phase counter so each
    // element can carry its own curve - the mark springs, the text just
    // drifts up.
    @State private var markIn = false
    @State private var titleIn = false
    @State private var bodyIn = false
    @State private var buttonIn = false

    init(onFinish: @escaping () -> Void, onHeightChange: @escaping (CGFloat) -> Void) {
        self.onFinish = onFinish
        self.onHeightChange = onHeightChange
        // Straight to the permissions page for anyone who has already read
        // the greeting, which after the Screen Recording relaunch is
        // everyone.
        _page = State(initialValue: Onboarding.introSeen ? .permissions : .intro)
        // Defaults to on, as an autostarting menu bar utility should, but
        // reflects reality if the user has been here before and turned it
        // off.
        _launchAtLogin = State(initialValue: Onboarding.completed ? LaunchAtLogin.isEnabled : true)
    }

    var body: some View {
        // Top-aligned so the page keeps its own natural height inside a
        // backdrop that stretches to fill the window - which is what makes
        // the measurement below the page's height rather than the
        // window's.
        ZStack(alignment: .top) {
            backdrop
            Group {
                switch page {
                case .intro: introPage
                case .permissions: permissionsPage
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .frame(width: 640)
        .onPreferenceChange(ContentHeightKey.self) { height in
            guard height > 0 else { return }
            onHeightChange(height)
        }
        .onAppear(perform: startIntroAnimation)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }

    private struct ContentHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        WelcomeBackdrop().ignoresSafeArea()
    }

    // MARK: - Page 1: greeting

    private var introPage: some View {
        VStack(spacing: 0) {
            Spacer()

            WelcomeIconMark(isVisible: markIn)

            Text("MeetCallRecorder")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .padding(.top, 28)
                .opacity(titleIn ? 1 : 0)
                .offset(y: titleIn ? 0 : 14)

            Text("Records your Google Meet calls and Slack huddles on its own.\nIt notices when a call starts, captures the window and its audio,\nand leaves a finished video in your Movies folder.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 14)
                .opacity(bodyIn ? 1 : 0)
                .offset(y: bodyIn ? 0 : 14)

            Spacer()

            Button(action: goToPermissions) {
                Text("Continue")
                    .frame(width: 180)
            }
            .controlSize(.extraLarge)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .opacity(buttonIn ? 1 : 0)
            .offset(y: buttonIn ? 0 : 10)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 48)
        .frame(height: 560)
    }

    private func startIntroAnimation() {
        guard page == .intro, !markIn else { return }
        withAnimation(.spring(response: 0.85, dampingFraction: 0.62)) { markIn = true }
        withAnimation(.easeOut(duration: 0.55).delay(0.30)) { titleIn = true }
        withAnimation(.easeOut(duration: 0.55).delay(0.48)) { bodyIn = true }
        withAnimation(.easeOut(duration: 0.45).delay(0.70)) { buttonIn = true }
    }

    private func goToPermissions() {
        Onboarding.introSeen = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            page = .permissions
        }
    }

    // MARK: - Page 2: permissions

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("A couple of permissions")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("macOS keeps screen capture behind an explicit grant. Nothing is recorded until you allow it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 44)

            VStack(spacing: 10) {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission, coordinator: permissions)
                }
            }
            .padding(.top, 26)

            if permissions.restartPending {
                restartBanner
                    .padding(.top, 18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
                .padding(.top, 30)

            loginItemToggle
                .padding(.vertical, 16)

            HStack {
                Spacer()
                Button(action: finish) {
                    Text("Continue")
                        .frame(width: 160)
                }
                .controlSize(.extraLarge)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!permissions.readyToRecord)
            }
            .padding(.bottom, 36)
        }
        .padding(.horizontal, 44)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: permissions.granted)
    }

    /// The one piece of this screen that exists purely because of a macOS
    /// quirk: a grant made while the app is running doesn't apply to the
    /// running copy.
    private var restartBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text("Restart to finish")
                    .font(.system(size: 13, weight: .semibold))
                Text("macOS hands a new permission to the app only at launch. MeetCallRecorder will reopen on this page.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Restart Now", action: restart)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .padding(14)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
        }
    }

    private var loginItemToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start MeetCallRecorder at login")
                        .font(.system(size: 13, weight: .medium))
                    Text("It lives in the menu bar and only wakes up for a call.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(LaunchAtLogin.state == .unavailable)
            .onChange(of: launchAtLogin) { _, enabled in
                launchAtLoginNote = note(for: LaunchAtLogin.setEnabled(enabled), requested: enabled)
            }

            if LaunchAtLogin.state == .unavailable {
                Text("Unavailable when running the executable directly - launch MeetCallRecorder.app instead.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let launchAtLoginNote {
                HStack(spacing: 6) {
                    Text(launchAtLoginNote)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items") { LaunchAtLogin.openLoginItemsSettings() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
        }
    }

    /// nil when the system ended up where the switch says it is.
    private func note(for state: LaunchAtLogin.State, requested: Bool) -> String? {
        switch state {
        case .requiresApproval:
            return "macOS needs you to switch this on in Login Items."
        case .enabled where requested, .disabled where !requested:
            return nil
        default:
            if let error = LaunchAtLogin.lastError {
                return "Couldn't change this: \(error.localizedDescription)"
            }
            return "macOS didn't accept the change."
        }
    }

    // MARK: - Exits

    private func restart() {
        applyLaunchAtLogin()
        Onboarding.relaunch()
    }

    private func finish() {
        applyLaunchAtLogin()
        Onboarding.completed = true
        onFinish()
    }

    /// Idempotent, and run on both exits: the toggle applies itself as it
    /// is flipped, but a user who never touches it still expects the
    /// default they can see to be the one that takes effect.
    private func applyLaunchAtLogin() {
        guard LaunchAtLogin.isEnabled != launchAtLogin else { return }
        LaunchAtLogin.setEnabled(launchAtLogin)
    }
}
