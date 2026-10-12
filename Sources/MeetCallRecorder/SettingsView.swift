import SwiftUI

/// The settings window's four tabs.
///
/// Everything here writes straight through to `Settings.shared`, which
/// persists on change - there is no apply button and nothing to cancel.
/// What a change does *not* do is reach into a recording already in
/// progress: a call captures its quality and background when it opens, so
/// the effect of anything changed here starts with the next call.
struct SettingsView: View {
    @State private var permissions = PermissionCoordinator()

    var body: some View {
        TabView {
            GeneralSettingsTab(permissions: permissions)
                .tabItem { Label("General", systemImage: "gearshape") }
            RecordingSettingsTab()
                .tabItem { Label("Recording", systemImage: "record.circle") }
            BackgroundSettingsTab()
                .tabItem { Label("Background", systemImage: "photo.on.rectangle.angled") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 560)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    let permissions: PermissionCoordinator
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginNote: String?

    var body: some View {
        SettingsPage {
            SettingsSection("Permissions", "Live status. Revoking one in System Settings shows up here within a second.") {
                VStack(spacing: 10) {
                    ForEach(Permission.allCases) { permission in
                        PermissionRow(permission: permission, coordinator: permissions)
                    }
                }
                if permissions.restartPending {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                        Text("A permission granted since launch only reaches the app after a restart.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Restart") { Onboarding.relaunch() }
                    }
                    .padding(.top, 2)
                }
            }

            SettingsSection("Startup", nil) {
                Toggle(isOn: $launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start MeetCallRecorder at login")
                            .font(.system(size: 13, weight: .medium))
                        Text("Registered as a login item - System Settings › General › Login Items.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(LaunchAtLogin.state == .unavailable)
                .onChange(of: launchAtLogin) { _, enabled in
                    let state = LaunchAtLogin.setEnabled(enabled)
                    launchAtLoginNote = state == .requiresApproval
                        ? "macOS needs you to switch this on in Login Items."
                        : nil
                }

                if let launchAtLoginNote {
                    HStack(spacing: 6) {
                        Text(launchAtLoginNote).font(.system(size: 11)).foregroundStyle(.orange)
                        Button("Open Login Items") { LaunchAtLogin.openLoginItemsSettings() }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                }
            }
        }
        // The switch can be changed from the welcome screen or from
        // System Settings while this window sits open.
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }
}

// MARK: - Recording

private struct RecordingSettingsTab: View {
    @State private var settings = Settings.shared

    var body: some View {
        SettingsPage {
            SettingsSection("Quality", "Applies to the next call - a recording in progress keeps the size it started at.") {
                ForEach(RecordingQuality.allCases) { quality in
                    ChoiceRow(
                        title: quality.displayName,
                        summary: quality.summary,
                        isSelected: settings.quality == quality
                    ) {
                        settings.quality = quality
                    }
                }
            }

            SettingsSection("Capture", nil) {
                ForEach(CaptureMode.allCases) { mode in
                    ChoiceRow(
                        title: mode.displayName,
                        summary: mode == .automatic
                            ? "Watches for call windows and records them unattended."
                            : "Start and stop by hand, recording the whole main display and the default microphone. Not built yet.",
                        isSelected: settings.captureMode == mode,
                        isDisabled: mode == .manual
                    ) {
                        settings.captureMode = mode
                    }
                }
            }

            SettingsSection("Sources", "Which apps automatic capture watches.") {
                ForEach(CallSource.allCases) { source in
                    Toggle(source.displayName, isOn: Binding(
                        get: { settings.isEnabled(source) },
                        set: { settings.setEnabled(source, $0) }
                    ))
                    .toggleStyle(.switch)
                    .disabled(settings.captureMode != .automatic)
                }
                if settings.enabledSources.isEmpty && settings.captureMode == .automatic {
                    Label("Nothing is being watched - no calls will be recorded.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - Background

private struct BackgroundSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var preview: CGImage?
    @State private var isLoadingPreview = false

    /// A stand-in meeting, so the seeded modes have something to hash and
    /// the preview shows what they actually do rather than a placeholder.
    private static let previewSeed = "Google Meet|preview-abc-defg-hij"
    private static let previewSize = CGSize(width: 960, height: 540)

    var body: some View {
        SettingsPage {
            SettingsSection("Preview", nil) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.25))
                    if let preview {
                        // Fill, not fit: the canvas is 16:9 and so is this
                        // frame, so filling it shows the background at the
                        // proportions a recording will actually use.
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    if isLoadingPreview {
                        ProgressView().controlSize(.small)
                    } else if preview == nil {
                        Text("No preview").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.secondary.opacity(0.2), lineWidth: 1)
                }
            }

            SettingsSection("Source", "Fills the margin around the call window.") {
                ForEach(BackgroundMode.allCases) { mode in
                    ChoiceRow(
                        title: mode.displayName,
                        summary: mode.summary,
                        isSelected: settings.background == mode,
                        badge: mode.usesNetwork ? "Network" : nil
                    ) {
                        settings.background = mode
                    }
                }
            }
        }
        .task(id: settings.background) { await loadPreview() }
    }

    private func loadPreview() async {
        isLoadingPreview = true
        defer { isLoadingPreview = false }
        preview = await BackgroundLibrary.shared.background(
            mode: settings.background,
            seed: Self.previewSeed,
            size: Self.previewSize
        )
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            WelcomeIconMark(isVisible: true)
            Text("MeetCallRecorder")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .padding(.top, 18)
            Text("Version \(version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text("Records Google Meet calls and Slack huddles on its own, composites them onto a fixed canvas, and leaves a finished file in your Movies folder.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 14)
                .padding(.horizontal, 40)

            HStack(spacing: 10) {
                Button("Recordings") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSString(string: "~/Movies/MeetCallRecorder").expandingTildeInPath))
                }
                Button("Log") { NSWorkspace.shared.open(Log.url) }
                Button("Setup…") { NSApp.sendAction(Selector(("openWelcome")), to: nil, from: nil) }
            }
            .padding(.top, 22)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared chrome

/// A scrolling tab body with consistent margins.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder let content: Content

    init(_ title: String, _ caption: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
    }
}

/// A radio-style row: the whole card is the hit target, which is a lot
/// easier to hit than a radio dot and leaves room for the explanation
/// each of these options needs.
private struct ChoiceRow: View {
    let title: String
    let summary: String
    let isSelected: Bool
    var isDisabled: Bool = false
    var badge: String?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .medium))
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }
}
