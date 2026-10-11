import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = CallRecorder()
    private let stagingDir = URL(fileURLWithPath: NSString(string: "~/Movies/MeetCallRecorder-staging").expandingTildeInPath)
    private let destDir = URL(fileURLWithPath: "/Volumes/Speakr")
    private let logURL = URL(fileURLWithPath: NSString(string: "~/Library/Logs/MeetCallRecorder.log").expandingTildeInPath)

    private var inactivePolls = 0
    private let stopGracePolls = 3
    private var paused = false

    private var pollTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        log("MeetCallRecorder starting")
        pollTask = Task { @MainActor in await self.pollLoop() }
        syncTask = Task { @MainActor in await self.syncLoop() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()
        syncTask?.cancel()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        rebuildMenu(recording: false)
    }

    private func setIcon(recording: Bool) {
        let symbolName = recording ? "record.circle.fill" : "record.circle"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = !recording
        statusItem.button?.image = image
        if recording {
            statusItem.button?.contentTintColor = .systemRed
        } else {
            statusItem.button?.contentTintColor = nil
        }
    }

    private func rebuildMenu(recording: Bool) {
        let menu = NSMenu()
        menu.addItem(withTitle: recording ? "Recording…" : "Idle", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        if paused {
            menu.addItem(withTitle: "Resume Detection", action: #selector(resumeDetection), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Pause Detection", action: #selector(pauseDetection), keyEquivalent: "")
        }

        if recording {
            menu.addItem(withTitle: "Stop Recording Now", action: #selector(forceStop), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Start Recording Now (frontmost window)", action: #selector(forceStart), keyEquivalent: "")
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Staging Folder", action: #selector(openStaging), keyEquivalent: "")
        menu.addItem(withTitle: "Open Logs", action: #selector(openLogs), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func pauseDetection() {
        paused = true
        rebuildMenu(recording: false)
    }

    @objc private func resumeDetection() {
        paused = false
        rebuildMenu(recording: false)
    }

    @objc private func forceStart() {
        Task { @MainActor in
            guard let front = NSWorkspace.shared.frontmostApplication,
                  let ownerName = front.localizedName,
                  let window = WindowDetector.findWindow(ownerName: ownerName, titlePrefix: "") else {
                log("force start: no window found for frontmost app")
                return
            }
            await startRecording(window: window)
        }
    }

    @objc private func forceStop() {
        Task { @MainActor in await stopRecording() }
    }

    @objc private func openStaging() {
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(stagingDir)
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(logURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Detection + recording loop

    private func pollLoop() async {
        while !Task.isCancelled {
            if !paused {
                await pollOnce()
            }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
        }
    }

    private func pollOnce() async {
        let meet = WindowDetector.findWindow(ownerName: "Google Meet", titlePrefix: "Meet: ")
        let slack = WindowDetector.findWindow(ownerName: "Slack", titlePrefix: "Huddle")
        let active = meet ?? slack
        let recording = await recorder.isRecording

        if let active {
            inactivePolls = 0
            if !recording {
                await startRecording(window: active)
            }
        } else if recording {
            inactivePolls += 1
            log("no active call (\(inactivePolls)/\(stopGracePolls))")
            if inactivePolls >= stopGracePolls {
                await stopRecording()
                inactivePolls = 0
            }
        }
    }

    private func startRecording(window: DetectedWindow) async {
        do {
            let url = try await recorder.start(window: window, outputDir: stagingDir)
            log("started recording [\(window.ownerName)] \(window.title) -> \(url.lastPathComponent)")
            setIcon(recording: true)
            rebuildMenu(recording: true)
        } catch {
            log("start failed: \(error)")
        }
    }

    private func stopRecording() async {
        do {
            let url = try await recorder.stop()
            log("stopped recording -> \(url.lastPathComponent)")
        } catch {
            log("stop failed: \(error)")
        }
        setIcon(recording: false)
        rebuildMenu(recording: false)
    }

    private func syncLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            let recording = await recorder.isRecording
            guard !recording else { continue }
            let n = Syncer.sync(stagingDir: stagingDir, destDir: destDir)
            if n > 0 { log("synced \(n) file(s) to \(destDir.path)") }
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        print(line, terminator: "")
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }
}
