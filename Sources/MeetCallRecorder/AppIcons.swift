import AppKit

/// The real app icons for the call sources, read off this Mac.
///
/// Deliberately not bundled assets. Google Meet is installed as a Safari
/// web app, whose bundle identifier carries a per-install UUID
/// (`com.apple.Safari.WebApp.<UUID>`) and whose icon comes from the site's
/// own manifest - there's no identifier to hard-code and no artwork that
/// would stay current past the next reinstall or rebrand. So every icon is
/// looked up at launch, and the settings window falls back to an SF Symbol
/// for a source that isn't installed.
@MainActor
@Observable
final class AppIcons {
    static let shared = AppIcons()

    /// Keyed by `CallSource.ownerName`, which is also what window
    /// detection matches on - the icon and the match come from the same
    /// name, so they can't disagree about which app a source means.
    private var icons: [String: NSImage] = [:]
    private var refreshTask: Task<Void, Never>?

    private init() {}

    func icon(for source: CallSource) -> NSImage? { icons[source.ownerName] }

    func icon(forAppNamed name: String) -> NSImage? {
        // A running app is both the freshest answer and a free one; the
        // cache only has to cover the apps that are closed right now.
        NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.icon
            ?? icons[name]
    }

    /// Re-reads every source's icon. Called at launch and whenever the
    /// settings window opens, so an app installed, updated or removed
    /// since the last look shows up without a relaunch.
    ///
    /// Safe to call repeatedly: a refresh already in flight is left to
    /// finish rather than restarted.
    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor in
            defer { refreshTask = nil }

            var unresolved: [CallSource] = []
            for source in CallSource.allCases {
                if let running = NSWorkspace.shared.runningApplications
                    .first(where: { $0.localizedName == source.ownerName })?.icon {
                    icons[source.ownerName] = running
                } else {
                    unresolved.append(source)
                }
            }

            guard !unresolved.isEmpty else { return }
            // Scanning the app folders touches the disk, so it happens off
            // the main actor. Only paths cross back - an NSImage isn't
            // Sendable, and building one from a path is cheap.
            let requests = unresolved.map { IconRequest(name: $0.ownerName, bundleIdentifier: $0.bundleIdentifier) }
            let paths = await Task.detached { Self.locateBundles(requests) }.value
            for (name, path) in paths {
                icons[name] = NSWorkspace.shared.icon(forFile: path)
            }
            let missing = unresolved.map(\.ownerName).filter { paths[$0] == nil }
            if !missing.isEmpty {
                Log.write("app icons: not installed - \(missing.joined(separator: ", "))")
            }
        }
    }

    private struct IconRequest: Sendable {
        let name: String
        let bundleIdentifier: String?
    }

    /// Where an installed app bundle can be, in the order worth trying.
    /// `~/Applications` leads because that's where Safari puts web apps,
    /// which is the only way Meet ever appears.
    private nonisolated static let searchDirectories = [
        NSString(string: "~/Applications").expandingTildeInPath,
        "/Applications",
        "/System/Applications"
    ]

    /// Finds each request's bundle, by identifier where there is one and by
    /// name otherwise. Returns paths keyed by the requested name.
    private nonisolated static func locateBundles(_ requests: [IconRequest]) -> [String: String] {
        var found: [String: String] = [:]
        for request in requests {
            if let identifier = request.bundleIdentifier,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                found[request.name] = url.path
            } else if let url = locateBundle(named: request.name) {
                found[request.name] = url.path
            }
        }
        return found
    }

    /// Matches on `CFBundleName` rather than the filename: a web app's
    /// folder can be renamed without changing what it reports to the
    /// window server, and the reported name is what detection keys on.
    /// The filename is accepted as a second chance.
    private nonisolated static func locateBundle(named name: String) -> URL? {
        let manager = FileManager.default
        for directory in searchDirectories {
            let contents = (try? manager.contentsOfDirectory(
                at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in contents where url.pathExtension == "app" {
                let bundleName = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                if bundleName == name || url.deletingPathExtension().lastPathComponent == name {
                    return url
                }
            }
        }
        return nil
    }
}
