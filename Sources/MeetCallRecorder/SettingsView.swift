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
    @State private var icons = AppIcons.shared

    var body: some View {
        SettingsPage {
            SettingsSection("Quality", "Applies to the next call - a recording in progress keeps the size it started at. Sizes are for 30 minutes and approximate: a quiet screen share lands well under them.") {
                ForEach(RecordingQuality.allCases) { quality in
                    ChoiceRow(
                        title: quality.displayName,
                        summary: quality.summary,
                        isSelected: settings.quality == quality,
                        detail: quality.estimatedHalfHourLabel,
                        detailCaption: "30 min"
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
                    SourceRow(
                        source: source,
                        icon: icons.icon(for: source),
                        isEnabled: Binding(
                            get: { settings.isEnabled(source) },
                            set: { settings.setEnabled(source, $0) }
                        ),
                        isDisabled: settings.captureMode != .automatic
                    )
                }
                if settings.enabledSources.isEmpty && settings.captureMode == .automatic {
                    Label("Nothing is being watched - no calls will be recorded.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            }
        }
        // An app can be installed, updated or deleted while the app sits in
        // the menu bar, so the icons are re-read each time this opens
        // rather than only at launch.
        .onAppear { icons.refresh() }
    }
}

// MARK: - Background

private struct BackgroundSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var icons = AppIcons.shared
    @State private var slots = Self.pendingSlots

    /// Smaller than any real canvas: the cards are 256 points wide, so
    /// this is still oversampled on a Retina display. It is also exactly
    /// the size the bundled samples ship at, which makes fitting them a
    /// no-op.
    private static let previewSize = CGSize(width: 640, height: 360)

    private static var pendingSlots: [BackgroundPreviewDeck.Slot] {
        Array(repeating: .loading, count: BackgroundPreviewSample.all.count)
    }

    /// The deck is pinned and the mode list scrolls under it: picking a
    /// mode is the one thing on this tab you want to watch happen, and a
    /// preview that scrolls out of reach of the control that changes it
    /// may as well not be there.
    var body: some View {
        VStack(spacing: 0) {
            preview
            Divider()
            ScrollView {
                SettingsSection("Source", "Fills the margin around the call window.") {
                    ForEach(BackgroundFamily.allCases) { family in
                        BackgroundFamilyRow(
                            family: family,
                            mode: Binding(
                                get: { settings.background },
                                set: { settings.background = $0 }
                            )
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
        }
        .task(id: settings.background) { await loadPreviews() }
        // An app can be installed or removed while the app sits in the
        // menu bar, same as on the Recording tab.
        .onAppear { icons.refresh() }
    }

    private var preview: some View {
        VStack(spacing: 12) {
            BackgroundPreviewDeck(slots: slots, icons: icons)
            Text(explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: BackgroundPreviewDeck.width)
        }
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background { WelcomeBackdrop(bleed: 300) }
    }

    /// What the four cards are demonstrating, which is a different thing
    /// in each mode - under a fixed backdrop they are four copies of one
    /// image, and saying so is the point rather than a disclaimer.
    ///
    /// The two photo decks look equally varied, so the line has to carry
    /// the one difference a still picture can't: whether a meeting would
    /// get this same backdrop again next time.
    private var explanation: String {
        switch settings.background {
        case .desktop:
            return "Four sample meetings. One backdrop for all of them - whatever your desktop is showing when a call starts."
        case .randomPhoto:
            return "Four sample meetings, each with a picture of its own - but a fresh one every call, so none of these would come back a second time. Sample wallpapers; a real call downloads its own."
        case .seededPhoto:
            return "Four sample meetings. The picture comes from the call identifier, so each of these keeps the backdrop it has here across every recording of it. Sample wallpapers; a real call downloads its own."
        case .randomGradient:
            return "Four sample meetings, each with a gradient of its own - and a fresh one every call, so none of these would come back a second time."
        case .seededGradient:
            return "Four sample meetings. The gradient comes from the call identifier, so each of these keeps the backdrop it has here across every recording of it."
        }
    }

    /// One task per card, each landing as it arrives rather than all four
    /// at the end. The photo modes stand in bundled samples rather than
    /// downloading four wallpapers per tab visit (see `SampleBackground`);
    /// every other mode is resolved for real, through the same library the
    /// recorder uses, which is also what makes the seeded gradient hand a
    /// pair the same image without being told to.
    private func loadPreviews() async {
        slots = Self.pendingSlots
        let mode = settings.background
        let size = Self.previewSize
        await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, sample) in BackgroundPreviewSample.all.enumerated() {
                let seed = sample.seed
                group.addTask {
                    if let bundled = BackgroundPreviewSample.sample(for: mode, at: index) {
                        return (index, await SampleBackgrounds.shared.image(bundled, size: size))
                    }
                    return (index, await BackgroundLibrary.shared.background(mode: mode, seed: seed, size: size))
                }
            }
            for await (index, image) in group {
                slots[index] = .resolved(image)
            }
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// Where the sample wallpapers came from, and what the app downloads
    /// at runtime. Bundled rather than linked out so it is readable with
    /// no network, and absent only when the executable is being run
    /// outside the .app - in which case the button isn't offered.
    private var credits: URL? {
        Bundle.main.url(forResource: "CREDITS", withExtension: "txt")
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
                if let credits {
                    Button("Credits") { NSWorkspace.shared.open(credits) }
                }
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

/// One call source: its own app icon, what it covers, and the switch.
///
/// The icon is the installed app's, read off the Mac at launch - a source
/// that isn't installed shows a symbol instead, which is itself the useful
/// signal that there's nothing there to record.
private struct SourceRow: View {
    let source: CallSource
    let icon: NSImage?
    @Binding var isEnabled: Bool
    var isDisabled: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            iconView
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.displayName)
                    .font(.system(size: 13, weight: .medium))
                if let requirement = source.requirement {
                    Text(requirement)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(source.displayName)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }

    /// No plate behind either case: a macOS app icon already carries its
    /// own rounded background, and putting it on a second one reads as a
    /// badge rather than an icon.
    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: source.fallbackSymbol)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        }
    }
}

/// One background family, with its variant picker folded inside.
///
/// The picker lives in the same card as the radio button rather than
/// below it, because it isn't a separate setting - "photo, new each call"
/// and "photo, per meeting" are one choice made in two steps, and
/// splitting them across two controls made the second one look optional.
/// It appears only for the selected family: offering the question for a
/// background you haven't chosen is noise, and for the desktop picture
/// there is no question to ask.
private struct BackgroundFamilyRow: View {
    let family: BackgroundFamily
    @Binding var mode: BackgroundMode

    private var isSelected: Bool { mode.family == family }

    /// Carried over when switching family, so going from a photo per
    /// meeting to a gradient gives you a gradient per meeting rather
    /// than silently changing two things at once.
    private var seeding: BackgroundSeeding { mode.seeding ?? .perMeeting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                mode = BackgroundMode(family: family, seeding: seeding)
            } label: {
                header
            }
            .buttonStyle(.plain)

            if isSelected && family.isSeedable {
                variants
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: isSelected)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(family.displayName).font(.system(size: 13, weight: .medium))
                    if family.usesNetwork {
                        Text("Network")
                            .font(.system(size: 9, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(family.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var variants: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("", selection: Binding(
                get: { seeding },
                set: { mode = BackgroundMode(family: family, seeding: $0) }
            )) {
                ForEach(BackgroundSeeding.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(seeding.note(for: family))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.bottom, 11)
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
    /// A value for the right edge - the quality rows use it for the size
    /// a recording at that setting costs.
    var detail: String?
    var detailCaption: String?
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
                Spacer(minLength: 8)

                if let detail {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(detail)
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                        if let detailCaption {
                            Text(detailCaption)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 1)
                }
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
