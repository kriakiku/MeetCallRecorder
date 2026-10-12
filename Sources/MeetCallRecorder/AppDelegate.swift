import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = CallRecorder()
    /// Finished recordings land here. Calls still in progress live under
    /// `stagingDir` until their segments are merged and the result moved
    /// up here.
    private let recordingsDir = URL(fileURLWithPath: NSString(string: "~/Movies/MeetCallRecorder").expandingTildeInPath)
    private var stagingDir: URL { recordingsDir.appendingPathComponent("staging") }
    private let logURL = URL(fileURLWithPath: NSString(string: "~/Library/Logs/MeetCallRecorder.log").expandingTildeInPath)

    // How long a call stays open - and resumable - after its window was
    // last seen. Rejoining within the window, or bouncing to another call
    // and back, continues the same recording instead of starting a new one.
    private let graceInterval: TimeInterval = 90
    // Pauses shorter than this aren't worth a card: the viewer never
    // noticed them, and an in-process writer restart takes under a second.
    private let gapCardThreshold: TimeInterval = 3
    private var paused = false

    /// A call we've started recording and haven't finalized yet.
    ///
    /// Only one call is ever actively being written (that's `activeKey`),
    /// but several can be open at once: switching to a different call
    /// suspends the first rather than finishing it, so coming back inside
    /// its grace window just appends another segment to the same folder
    /// instead of splitting the call across two files.
    private struct OpenCall {
        let ownerName: String
        let callID: String
        let folder: URL
        let startDate: Date
        /// Stamped on every frame of this call and written into its meta.
        let recordingID: String
        var icon: NSImage?
        /// Content duration of the segments already closed - the recorder
        /// only knows about the one it's writing right now.
        var closedDuration: TimeInterval = 0
        /// When this call's window stopped being visible, or nil while
        /// it's on screen. Doubles as the grace clock: a call is finalized
        /// once this is `graceInterval` old.
        var missingSince: Date?
    }
    private var openCalls: [String: OpenCall] = [:]
    /// The call the recorder is writing right now, if any.
    private var activeKey: String?

    private var cachedResizeCard: CGImage?
    private var cachedRecordingIDs: [String: CGImage] = [:]

    private var pollTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        log("MeetCallRecorder starting")
        pollTask = Task { @MainActor in
            await self.recoverStaleCalls()
            await self.pollLoop()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()
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
        menu.addItem(withTitle: "Open Recordings Folder", action: #selector(openRecordings), keyEquivalent: "")
        menu.addItem(withTitle: "Open Logs", action: #selector(openLogs), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func pauseDetection() {
        paused = true
        rebuildMenu(recording: activeKey != nil)
    }

    @objc private func resumeDetection() {
        paused = false
        rebuildMenu(recording: activeKey != nil)
    }

    @objc private func forceStart() {
        Task { @MainActor in
            guard let front = NSWorkspace.shared.frontmostApplication,
                  let ownerName = front.localizedName,
                  let window = WindowDetector.findWindow(ownerName: ownerName, titlePrefix: "") else {
                log("force start: no window found for frontmost app")
                return
            }
            let key = Self.callKey(ownerName: window.ownerName, callID: window.callID)
            guard activeKey != key else { return }
            if activeKey != nil { await suspendActive() }
            await startOrResume(window: window, key: key, gap: 0)
        }
    }

    @objc private func forceStop() {
        Task { @MainActor in
            guard let key = activeKey else { return }
            await finalize(key: key)
        }
    }

    @objc private func openRecordings() {
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordingsDir)
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
            // Short enough that a live window resize or a fullscreen
            // toggle gets picked up quickly, long enough to stay cheap.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func pollOnce() async {
        let meet = WindowDetector.findWindow(ownerName: "Google Meet", titlePrefix: "Meet: ")
        let slack = WindowDetector.findWindow(ownerName: "Slack", titlePrefix: "Huddle")
        let visible = meet ?? slack
        let visibleKey = visible.map { Self.callKey(ownerName: $0.ownerName, callID: $0.callID) }

        // Anything not on screen right now starts counting towards its
        // grace period; anything on screen stops.
        let now = Date()
        for (key, call) in openCalls where key != visibleKey && call.missingSince == nil {
            openCalls[key]?.missingSince = now
        }

        if let visible, let visibleKey {
            let gap = openCalls[visibleKey]?.missingSince.map { now.timeIntervalSince($0) } ?? 0
            openCalls[visibleKey]?.missingSince = nil

            if activeKey == visibleKey {
                await maintainActive(window: visible, key: visibleKey, gap: gap)
            } else {
                if activeKey != nil { await suspendActive() }
                await startOrResume(window: visible, key: visibleKey, gap: gap)
            }
        }

        await sweepExpired()
    }

    /// The call we're already writing is still on screen - deal with a
    /// writer that died under us, a gap this same window sat through
    /// (left the call and came back without the window itself ever
    /// closing), or a stream that needs re-pointing at a new window
    /// (fullscreen/Space transition gives the window a new ID).
    private func maintainActive(window: DetectedWindow, key: String, gap: TimeInterval) async {
        if await recorder.isWriterFailed {
            // `gap` carries through rather than being hardcoded to 0: a
            // writer that died silently is only noticed on the next poll
            // of this same function, and if the call's window also went
            // missing and came back in between - a real, waited-out pause
            // - that poll is the one computing `gap` in the first place.
            // Discarding it here threw away a pause that had already been
            // measured correctly, just because the stale writer failure
            // got noticed on the very poll that would otherwise have
            // reported it. The new segment opens with a pause card
            // instead of a bare restart whenever that gap clears the
            // threshold - see `startSegment`.
            log("writer failed mid-call - continuing in a new segment")
            await closeActiveSegment()
            await startSegment(window: window, key: key, gap: gap)
            return
        }

        // Checked unconditionally, ahead of the reattach guard below - a
        // pause measured through `missingSince` is real regardless of
        // whether the window's *identity* ever changed. Google Meet's
        // native app shows the "you left" screen in the same window it
        // was capturing before, so leaving a call and rejoining from
        // there never touches the stream at all: `attached` stays true
        // and `trackedID` never stops matching, which used to make the
        // reattach guard return before `gap` was ever looked at - a real,
        // deliberately-waited-out pause with nothing to show for it.
        if gap >= gapCardThreshold {
            log("pause of \(TitleCardRenderer.formatDuration(gap)) mid-segment")
            await recorder.recordPause(gap: gap)
        }

        let attached = await recorder.isStreamAttached
        let trackedID = await recorder.currentWindowID
        guard !attached || trackedID != window.windowID else { return }

        do {
            try await recorder.reattach(to: window)
            log("reattached -> [\(window.ownerName)] \(window.title)")
        } catch {
            log("reattach failed (will retry): \(error)")
        }
    }

    /// Begins recording a call we've never seen, or picks one back up that
    /// is still inside its grace window.
    private func startOrResume(window: DetectedWindow, key: String, gap: TimeInterval) async {
        if openCalls[key] != nil {
            log("resuming [\(window.ownerName)] \(window.callID) after \(TitleCardRenderer.formatDuration(gap))")
            await startSegment(window: window, key: key, gap: gap)
            return
        }

        // Before the call folder, not just at launch: creating that folder
        // with intermediate directories would otherwise bring staging into
        // existence unmarked if it had been deleted out from under us.
        CrashRecovery.prepareStagingDirectory(stagingDir)
        let folder = stagingDir.appendingPathComponent(Self.folderName(ownerName: window.ownerName, callID: window.callID))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let startDate = Date()
        let recordingID = RecordingID.generate()
        CrashRecovery.writeCallMeta(
            folder: folder,
            ownerName: window.ownerName,
            callID: window.callID,
            startDate: startDate,
            closedDuration: 0,
            recordingID: recordingID
        )
        openCalls[key] = OpenCall(
            ownerName: window.ownerName,
            callID: window.callID,
            folder: folder,
            startDate: startDate,
            recordingID: recordingID,
            icon: NSRunningApplication(processIdentifier: window.pid)?.icon
        )
        await startSegment(window: window, key: key, gap: 0)
    }

    /// Opens a fresh writer, writing one more segment file into the call's
    /// folder. Gets a pause card if we're coming back from a real gap, an
    /// intro card if this is the call's very first segment, and neither if
    /// it's just a writer being replaced mid-call.
    private func startSegment(window: DetectedWindow, key: String, gap: TimeInterval) async {
        guard var call = openCalls[key] else { return }
        if call.icon == nil {
            call.icon = NSRunningApplication(processIdentifier: window.pid)?.icon
            openCalls[key] = call
        }

        // Which plate this segment opens with is decided here and drawn
        // at assembly. Nothing about it is rendered into the capture.
        var openingEvent: TimelineEvent.Kind?
        if gap >= gapCardThreshold {
            openingEvent = .pause
        } else if CrashRecovery.segments(in: call.folder).isEmpty {
            openingEvent = .intro
        }

        let url = CrashRecovery.nextSegmentURL(in: call.folder)
        do {
            _ = try await recorder.start(window: window, outputURL: url)
            activeKey = key
            if let openingEvent {
                RecordingTimeline.append(
                    TimelineEvent(
                        kind: openingEvent,
                        segment: url.lastPathComponent,
                        at: 0,
                        gap: openingEvent == .pause ? gap : nil
                    ),
                    in: call.folder
                )
            }
            log("recording [\(call.ownerName)] \(call.callID) -> \(call.folder.lastPathComponent)/\(url.lastPathComponent)")
            setIcon(recording: true)
            rebuildMenu(recording: true)
        } catch {
            log("start failed: \(error)")
        }
    }

    /// Closes the active segment, folding what it recorded into its open
    /// call so the call can carry on in a fresh segment later. Leaves the
    /// folder - and therefore the call - intact.
    private func closeActiveSegment() async {
        guard let key = activeKey, var call = openCalls[key] else {
            activeKey = nil
            return
        }
        call.closedDuration += await recorder.contentDuration
        activeKey = nil
        do {
            _ = try await recorder.stop()
        } catch {
            log("closing segment failed: \(error)")
        }
        CrashRecovery.writeCallMeta(
            folder: call.folder,
            ownerName: call.ownerName,
            callID: call.callID,
            startDate: call.startDate,
            closedDuration: call.closedDuration,
            recordingID: call.recordingID
        )
        openCalls[key] = call
    }

    private func suspendActive() async {
        guard let key = activeKey, let call = openCalls[key] else { return }
        await closeActiveSegment()
        log("suspended [\(call.ownerName)] \(call.callID) - resumable for \(Int(graceInterval))s")
        setIcon(recording: false)
        rebuildMenu(recording: false)
    }

    /// Finalizes every call whose grace period has run out - including the
    /// one being actively recorded, which is how an ordinary finished call
    /// gets wrapped up.
    private func sweepExpired() async {
        let now = Date()
        let expired = openCalls.compactMap { key, call -> String? in
            guard let since = call.missingSince, now.timeIntervalSince(since) >= graceInterval else { return nil }
            return key
        }
        for key in expired {
            if let call = openCalls[key] {
                log("grace period expired for [\(call.ownerName)] \(call.callID) - finalizing")
            }
            await finalize(key: key)
        }
    }

    /// Turns a call's staged segments into one finished recording in
    /// `recordingsDir`, then clears its staging folder.
    ///
    /// The plates - welcome, pauses, closing - are drawn here rather than
    /// during capture, from the events logged alongside the segments. See
    /// RecordingAssembler.
    private func finalize(key: String) async {
        guard let call = openCalls.removeValue(forKey: key) else { return }

        var totalDuration = call.closedDuration
        if activeKey == key {
            totalDuration += await recorder.contentDuration
            activeKey = nil
            do {
                _ = try await recorder.stop()
            } catch {
                log("stop failed while finalizing \(call.callID): \(error)")
            }
            setIcon(recording: false)
            rebuildMenu(recording: false)
        }

        let segments = CrashRecovery.segments(in: call.folder)
        guard !segments.isEmpty else {
            try? FileManager.default.removeItem(at: call.folder)
            return
        }

        let events = RecordingTimeline.read(in: call.folder)
        if !events.isEmpty {
            let summary = events.map { event -> String in
                let span = event.until.map { String(format: "%.2f-%.2fs", event.at, $0) }
                    ?? String(format: "%.2fs", event.at)
                let name = event.segment
                    .replacingOccurrences(of: "segment-", with: "")
                    .replacingOccurrences(of: ".mp4", with: "")
                    .replacingOccurrences(of: ".mov", with: "")
                return "\(event.kind.rawValue)@\(name) \(span)"
            }
            log("timeline: \(summary.joined(separator: ", "))")
        }

        var inserts = events.compactMap { event -> RecordingAssembler.Insert? in
            guard let content = plateContent(for: event, call: call) else { return nil }
            return RecordingAssembler.Insert(event: event, content: content)
        }
        // What the outro reports is the meeting's own span, not how much
        // of it we have footage for: `totalDuration` is a sum of captured
        // content, which skips straight over every pause. Every pause the
        // person actually sat through is real time the meeting was
        // running, so it belongs in this number even though nothing was
        // recorded during it - the welcome/closing cards themselves are
        // the only thing deliberately left out, since they're ours, not
        // the meeting's.
        let meetingDuration = totalDuration + events.reduce(0) { $0 + ($1.kind == .pause ? ($1.gap ?? 0) : 0) }
        if let outro = TitleCardRenderer.renderOutro(
            appIcon: call.icon,
            appName: call.ownerName,
            callID: call.callID,
            meetingDuration: meetingDuration,
            outputSize: CallRecorder.outputSize
        ) {
            // Positioned after everything; the segment it names is only
            // there to say which one it follows.
            inserts.append(RecordingAssembler.Insert(
                event: TimelineEvent(kind: .outro, segment: segments.last!.lastPathComponent, at: 0),
                content: outro
            ))
        }

        let normalized = await CrashRecovery.normalizeSegments(segments, scratchDir: call.folder)
        defer { for file in normalized.scratch { try? FileManager.default.removeItem(at: file) } }
        if totalDuration - normalized.total > 1 {
            // Content we composited that never reached a file: every
            // segment that ends in a writer failure takes the fragment it
            // was in the middle of with it. Nothing assembly can recover -
            // logged because it sizes damage that is otherwise invisible.
            log(String(format: "lost %.2fs of %.2fs to failed writers in %@", totalDuration - normalized.total, totalDuration, call.callID))
        }

        // Each insert is named against its original segment; the
        // assembler sees the normalized copies, which carry different
        // names.
        let renamed = Dictionary(uniqueKeysWithValues: zip(
            segments.map(\.lastPathComponent),
            normalized.inputs.map(\.lastPathComponent)
        ))
        inserts = inserts.map { insert in
            guard let name = renamed[insert.event.segment] else { return insert }
            var event = insert.event
            event = TimelineEvent(kind: event.kind, segment: name, at: event.at, until: event.until, gap: event.gap)
            return RecordingAssembler.Insert(event: event, content: insert.content)
        }

        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let destination = recordingsDir.appendingPathComponent(Self.finalFilename(for: call))
        if await RecordingAssembler.assemble(
            segments: normalized.inputs,
            durations: normalized.durations,
            inserts: inserts,
            recordingID: recordingIDImage(for: call.recordingID),
            metadata: RecordingAssembler.RecordingMetadata(
                sourceApp: call.ownerName,
                meetingID: call.callID,
                recordingID: call.recordingID
            ),
            scratch: call.folder,
            to: destination
        ) {
            let duration = await CrashRecovery.probeDuration(destination) ?? 0
            log(String(format: "finalized [%@] %@ (%d segment(s), %.2fs) -> %@", call.ownerName, call.callID, segments.count, duration, destination.lastPathComponent))
            try? FileManager.default.removeItem(at: call.folder)
        } else {
            // Keep the raw segments rather than lose them - the folder is
            // picked back up and retried on the next launch.
            log("assembly failed for \(call.callID) - left \(segments.count) segment(s) in staging/\(call.folder.lastPathComponent)")
        }
    }

    /// The transparent icon/text for a logged event. The assembler puts
    /// it on whatever backdrop that kind of plate calls for.
    private func plateContent(for event: TimelineEvent, call: OpenCall) -> CGImage? {
        switch event.kind {
        case .intro:
            return TitleCardRenderer.renderIntro(
                appIcon: call.icon,
                appName: call.ownerName,
                callID: call.callID,
                startDate: call.startDate,
                outputSize: CallRecorder.outputSize
            )
        case .pause:
            return TitleCardRenderer.renderGap(pauseDuration: event.gap ?? 0, outputSize: CallRecorder.outputSize)
        case .resize:
            // Cached: a call can log a resize every time the window is
            // nudged, and the card is the same one every time.
            return resizeCardImage()
        case .outro:
            // Built by the caller, which is the only place that knows the
            // whole call's duration.
            return nil
        }
    }

    /// Call folders left in staging by a previous run - the app went away
    /// mid-call (crash, `manage.sh update`, a Quit during a call). Each one
    /// is reopened as an ordinary open call whose window simply isn't
    /// visible yet, so the normal loop either resumes it (the call is still
    /// live, e.g. right after an update) or the first sweep finalizes it.
    private func recoverStaleCalls() async {
        CrashRecovery.prepareStagingDirectory(stagingDir)
        for stale in CrashRecovery.findStaleCalls(in: stagingDir) {
            let key = Self.callKey(ownerName: stale.ownerName, callID: stale.callID)
            openCalls[key] = OpenCall(
                ownerName: stale.ownerName,
                callID: stale.callID,
                folder: stale.folder,
                startDate: stale.startDate,
                recordingID: stale.recordingID,
                icon: Self.icon(forAppNamed: stale.ownerName),
                closedDuration: stale.closedDuration,
                missingSince: CrashRecovery.lastWrite(in: stale.folder)
            )
            log("found unfinished call [\(stale.ownerName)] \(stale.callID) (\(CrashRecovery.segments(in: stale.folder).count) segment(s))")
        }
    }

    private func resizeCardImage() -> CGImage? {
        if let cachedResizeCard { return cachedResizeCard }
        let image = TitleCardRenderer.renderResize(outputSize: CallRecorder.outputSize)
        cachedResizeCard = image
        return image
    }

    /// Cached per identifier: a call opens a new writer, and therefore a
    /// new composer, on every segment, and the stamp doesn't change
    /// between them.
    private func recordingIDImage(for identifier: String) -> CGImage? {
        if let cached = cachedRecordingIDs[identifier] { return cached }
        guard let image = TitleCardRenderer.renderRecordingID(identifier) else { return nil }
        cachedRecordingIDs[identifier] = image
        return image
    }

    // MARK: - Naming

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f
    }()

    private static func callKey(ownerName: String, callID: String) -> String {
        "\(ownerName)\u{1}\(callID)"
    }

    /// "<App>-<call id>" - the staging subfolder a call's segments go in.
    private static func folderName(ownerName: String, callID: String) -> String {
        sanitized("\(ownerName)-\(callID)")
    }

    /// "<date> <app> <call id>.mp4" - e.g. "2026-10-11 22-37-05 Google Meet
    /// zas-rvho-gkt.mp4" or "2026-10-11 22-37-05 Slack Huddle.mp4".
    private static func finalFilename(for call: OpenCall) -> String {
        let date = filenameFormatter.string(from: call.startDate)
        return "\(date) \(sanitized("\(call.ownerName) \(call.callID)")).mp4"
    }

    /// "/" and ":" are stripped - a call ID or app name is free to contain
    /// either, and neither survives being used as a path component.
    private static func sanitized(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func icon(forAppNamed name: String) -> NSImage? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.icon
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
