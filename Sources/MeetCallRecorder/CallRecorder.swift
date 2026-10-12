import AVFoundation
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

enum RecorderError: Error {
    case alreadyRecording
    case windowNotFound
    case noActiveRecording
}

/// Captures a single window's video and *that window's owning app's* audio
/// (confirmed empirically - a desktopIndependentWindow filter with
/// capturesAudio=true scopes audio to the window's app, not the whole
/// system: a distinct sound played from an unrelated process during a test
/// capture did not show up in the recording). No OBS, no virtual audio
/// driver - ScreenCaptureKit does this natively.
///
/// The SCStream is a separate, disposable thing from the AVAssetWriter
/// session: `reattach(to:)` can tear down and recreate the stream (new
/// windowID after a fullscreen Space transition, or recovering from a
/// stream error) while the writer keeps appending to the same output file,
/// so a fullscreen toggle or a brief disconnect doesn't split the call into
/// multiple recordings.
actor CallRecorder {
    private var stream: SCStream?
    private var streamConfig: SCStreamConfiguration?
    private var pointPixelScale: CGFloat = 2.0
    private var writer: AVAssetWriter?
    // The macOS 26+ receiver API replaced AVAssetWriterInput.append: a
    // pixel buffer receiver takes (pixel buffer, presentation time) pairs
    // directly, so nothing here builds CMSampleBuffers for video any more,
    // and `append` is an async call with real backpressure instead of a
    // spin on isReadyForMoreMediaData.
    private var videoReceiver: AVAssetWriterInput.PixelBufferReceiver?
    private var audioReceiver: AVAssetWriterInput.SampleBufferReceiver?
    private var output: StreamOutput?
    private var composer: FrameComposer?
    // One serial queue for the whole recording, not a fresh one per
    // attachStream() call. A reattach's new SCStream can start delivering
    // samples before the old one's already-queued-but-not-yet-executed
    // samples finish draining; two *different* serial queues both appending
    // to the same receiver around the same time is a real data race on a
    // type that isn't Sendable, and lines up with recordings dying with
    // VideoToolbox's kVTVideoEncoderMalfunctionErr shortly after a
    // reattach. One shared queue makes old and new samples strictly FIFO
    // relative to each other instead.
    private let sampleQueue = DispatchQueue(label: "dev.kriakiku.MeetCallRecorder.samples")

    private(set) var isRecording = false
    private(set) var isStreamAttached = false
    private(set) var currentOutputURL: URL?
    private(set) var currentWindowID: CGWindowID?

    /// True once the underlying AVAssetWriter has permanently failed.
    ///
    /// In practice this is always AVErrorUnknown (-11800) wrapping
    /// OSStatus -16341, which recurs every 5-21s of recording. That code
    /// is undocumented - it appears in no SDK header, and it is *not*
    /// kVTVideoEncoderMalfunctionErr (-12912) as earlier log messages
    /// here claimed - and it strikes audio appends as well as video, so
    /// the failing component is still unidentified.
    /// `.failed` is terminal per AVFoundation's own docs: nothing in this
    /// process can make this writer start accepting samples again.
    /// Reattaching the SCStream (the normal recovery path for everything
    /// else) does nothing for this - every frame just keeps silently
    /// getting dropped into a writer that will never take it, which is
    /// what was truncating recordings to whatever had already been
    /// flushed before the failure. AppDelegate polls this and, when true,
    /// closes this segment and opens a brand new writer for a new one -
    /// see AppDelegate.handleWriterFailure.
    var isWriterFailed: Bool {
        writer?.status == .failed
    }

    // The output canvas is fixed for the life of a call but no longer
    // fixed for the app: it comes from the chosen RecordingQuality, read
    // once when the call starts. The window is scaled (preserving aspect
    // ratio) to fit a centered safe area, the call's background filling
    // whatever's left. See FrameComposer.
    //
    // The constant survives only as a stand-in for code paths that need
    // *a* size even when the call has none - audio-only finalization,
    // which computes one and then never draws anything with it.
    static let defaultOutputSize = CGSize(width: 1920, height: 1080)
    static let safeInset: CGFloat = 32
    static let frameRate: Int32 = 30

    /// The quality this segment is being written at. Captured at `start`
    /// so changing the setting mid-call can't resize the output halfway
    /// through.
    private(set) var quality: RecordingQuality = .p1080

    /// Shared hold duration for every card - opening, gap, outro. The
    /// enter/exit animation around it is `FrameComposer.cardTransitionDuration`,
    /// on top of this, not carved out of it.
    static let cardDuration: Double = 1.6

    // backgroundColor on SCStreamConfiguration is unowned(unsafe) - the
    // caller is responsible for keeping it alive, so this needs a strong
    // reference held somewhere rather than a CGColor(...) literal passed
    // inline (which gets deallocated immediately, before SCStream reads it).
    private static let transparentBackgroundColor = CGColor(gray: 0, alpha: 0)

    /// Starts a segment. What the recorder writes is the call itself and
    /// nothing else - every plate is drawn later, by RecordingAssembler,
    /// from the events logged alongside the segments.
    func start(window: DetectedWindow, outputURL: URL, quality: RecordingQuality, background: CGImage?) async throws -> URL {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        self.quality = quality

        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // QuickTime, not MP4, deliberately. A fragmented *MP4* writer
        // feeding the hardware H.264 encoder dies intermittently with
        // -11800/-16341 - reproduced in a 50-line synthetic harness with
        // no ScreenCaptureKit involved at all (plain generated frames,
        // real-time pacing), failing within seconds on most runs, which
        // is exactly the "recording keeps breaking up mid-call" symptom.
        // The identical writer configured as fragmented QuickTime does
        // not. Another recorder hit the same pair and the same fix:
        // https://github.com/sebastianfelipe/codetake/pull/1
        // Staging is remuxed by ffmpeg at assembly anyway, so the
        // container never reaches the finished file.
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        // Fragmented MP4: periodically closes out a playable chunk, so a
        // crash mid-recording loses at most the last few seconds instead of
        // the whole file - the same crash-safety reasoning that made OBS
        // default to mkv, without needing mkv specifically.
        //
        // 1s rather than 5s because this interval is exactly how much
        // already-appended video gets thrown away when the writer dies
        // mid-stream: a segment whose encoder failed had 11.3MB on disk but
        // only 5.02s/146 frames readable, the rest sitting in a fragment
        // that never got indexed. Hardware-encoder death (-16341) is a
        // real, recurring event here, so the unflushed window is worth
        // keeping small; the extra moof overhead at 1080p30 is noise.
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 1)

        // Audio-only skips the video input entirely rather than writing a
        // blank track: there's no canvas, no composer, and nothing for the
        // assembler to draw plates onto later.
        let videoInput = quality.outputSize.map { size in
            AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoExpectedSourceFrameRateKey: Self.frameRate,
                    AVVideoAverageBitRateKey: quality.stagingBitrate
                ]
            ])
        }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2
        ])
        // Asking for a receiver is what registers the input with the writer
        // now - there's no separate add().
        //
        // expectsMediaDataInRealTime is still set despite being deprecated
        // in favour of "use appendImmediately instead", because that advice
        // is incomplete: the flag is what makes readiness get computed for a
        // real-time source ("NO only when the input cannot process samples
        // as quickly as they are being provided"), and without it the writer
        // uses the file-based rule that expects the caller to *wait*. Having
        // migrated to appendImmediately without it, the receiver went
        // not-ready about a second in and then refused ~80% of frames, so
        // recordings froze on their first second of picture. There is no
        // non-deprecated way to express this yet.
        videoInput?.expectsMediaDataInRealTime = true
        audioInput.expectsMediaDataInRealTime = true
        let videoReceiver = videoInput.map { writer.inputPixelBufferReceiver(for: $0, pixelBufferAttributes: nil) }
        let audioReceiver = writer.inputReceiver(for: audioInput)

        self.writer = writer
        self.videoReceiver = videoReceiver
        self.audioReceiver = audioReceiver
        self.composer = quality.outputSize.map {
            FrameComposer(outputSize: $0, safeInset: Self.safeInset, background: background)
        }
        // Per segment, not per call: each segment is its own writer with
        // its own session, and a clock carried over from the last one
        // would report the whole call's length as this segment's.
        audioClock.reset()
        self.isRecording = true
        self.currentOutputURL = outputURL

        do {
            try await attachStream(to: window)
        } catch {
            // Don't leave a writer-with-no-stream lying around if the very
            // first attach fails - treat it as a failed start, not a
            // recording waiting for a reattach that nobody asked for.
            await detachStream()
            self.writer = nil
            self.videoReceiver = nil
            self.audioReceiver = nil
            self.composer = nil
            self.isRecording = false
            self.currentOutputURL = nil
            throw error
        }
        return outputURL
    }

    /// Re-targets an in-progress recording at a (possibly new) window - the
    /// AVAssetWriter session and output file are untouched, only the
    /// SCStream is torn down and recreated. Used both when the previous
    /// stream died (fullscreen transition, transient SCStream error) and
    /// when the call window reappeared with a new windowID after the call
    /// was briefly left.
    func reattach(to window: DetectedWindow) async throws {
        guard isRecording else { throw RecorderError.noActiveRecording }
        await detachStream()
        try await attachStream(to: window)
    }

    /// How much has actually been written to the output so far - see
    /// FrameComposer.contentDuration. Call before `stop()` to build an
    /// outro card with an accurate "recording duration" (stop() itself
    /// still appends a few more seconds for the outro transition/hold, so
    /// this is deliberately read just *before* that, not after).
    var contentDuration: TimeInterval {
        // Audio-only writes no frames, so there is no composer and no
        // rendered-PTS span to read. The audio path keeps its own clock
        // for exactly this case; without it every audio-only call would
        // report a zero-length recording and the outro/duration maths
        // downstream would all be wrong.
        composer?.contentDuration ?? audioClock.duration
    }

    /// Tracks the span of appended audio. Only consulted for audio-only
    /// recordings - with a picture, the composer is the authority.
    private let audioClock = MediaClock()

    /// Notes a pause that happened inside the segment being written -
    /// the window went away and came back without the writer being
    /// replaced, so there is no segment boundary to hang the plate on.
    func recordPause(gap: TimeInterval) {
        guard isRecording, let url = currentOutputURL else { return }
        RecordingTimeline.append(
            TimelineEvent(kind: .pause, segment: url.lastPathComponent, at: contentDuration, gap: gap),
            in: url.deletingLastPathComponent()
        )
    }

    /// Closes the segment. Nothing is appended on the way out: the
    /// closing plate belongs to assembly, which is also the only place
    /// that can draw one when the writer has already died - the common
    /// case, since a call sits through a 90s grace period before it is
    /// finalized and a writer that died in there isn't noticed until now.
    @discardableResult
    func stop() async throws -> URL {
        guard isRecording, let writer, let url = currentOutputURL else {
            throw RecorderError.noActiveRecording
        }
        await detachStream()

        videoReceiver?.finish()
        audioReceiver?.finish()
        if writer.status == .writing {
            await writer.finishWriting()
        }
        self.writer = nil
        self.videoReceiver = nil
        self.audioReceiver = nil
        self.composer = nil
        self.isRecording = false
        self.currentOutputURL = nil
        self.currentWindowID = nil
        return url
    }

    // MARK: - Stream lifecycle

    private func attachStream(to window: DetectedWindow) async throws {
        // Video is optional here: an audio-only segment has no receiver
        // and no composer, and requiring them would make `start` succeed
        // and then every attach fail.
        guard let writer, let audioReceiver else {
            throw RecorderError.noActiveRecording
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == window.windowID }) else {
            throw RecorderError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        // SCStreamConfiguration always carries a video size even when
        // nothing consumes the frames, so an audio-only stream asks for
        // the smallest legal one rather than paying to scale and deliver
        // full-size buffers nobody reads.
        if composer == nil {
            config.width = 2
            config.height = 2
        } else {
            config.width = max(2, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
            config.height = max(2, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        }
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.frameRate))
        // Explicit BGRA (alpha-capable) rather than relying on the default -
        // paired with shouldBeOpaque/backgroundColor below for real
        // per-pixel transparency outside the window's actual shape.
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // shouldBeOpaque backs any partially-transparent pixel with WHITE
        // to force full opacity when true (the default) - that's not what
        // was showing up as black. The actual source of the black halo
        // around the rounded corners is the window's own drop shadow:
        // WindowServer renders it as a dark, soft gradient and SCK includes
        // it in the capture unless explicitly told not to.
        config.shouldBeOpaque = false
        config.backgroundColor = Self.transparentBackgroundColor
        config.ignoreShadowsSingleWindow = true
        // The capture buffer keeps the dimensions it had when the stream
        // started - commitResize deliberately never reconfigures a live
        // stream, since that's what kills the hardware encoder. So a window
        // resized mid-call no longer matches this buffer's aspect ratio,
        // and without this it would come through stretched.
        config.scalesToFit = true

        let output = StreamOutput(
            writer: writer,
            videoReceiver: videoReceiver,
            audioReceiver: audioReceiver,
            composer: composer,
            audioClock: audioClock
        ) { [weak self] error in
            Task { await self?.handleStreamStopped(error) }
        }
        let scStream = SCStream(filter: filter, configuration: config, delegate: output)
        // No screen output at all when there's nothing to compose - SCStream
        // would otherwise keep encoding and delivering frames for an
        // audio-only recording to throw away.
        if composer != nil {
            try scStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        }
        try scStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
        try await scStream.startCapture()

        self.stream = scStream
        self.streamConfig = config
        self.pointPixelScale = CGFloat(filter.pointPixelScale)
        self.output = output
        self.isStreamAttached = true
        self.currentWindowID = window.windowID
        startResizeWatch()
    }

    private func detachStream() async {
        stopResizeWatch()
        // A segment closing (or the stream reattaching) mid-drag still has
        // to leave the resize with an end on the timeline.
        recordResize(endedAt: contentDuration)
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamConfig = nil
        output = nil
        isStreamAttached = false
    }

    // MARK: - Resize watch
    //
    // Watching the window's bounds produces one thing: a span on the
    // call's timeline saying "the picture between here and here is a
    // window mid-drag". Assembly is what does something about it. Nothing
    // in the capture path reacts, because nothing in the capture path
    // *can* - a resize isn't known to have ended until after it has.
    //
    // What this deliberately does NOT do is call
    // `stream.updateConfiguration()` to match the window's new pixel
    // dimensions, even though that is the obvious thing to do when you
    // notice a window has been resized.
    //
    // Reconfiguring a live SCStream is what kills the AVAssetWriter's
    // hardware H.264 session with kVTVideoEncoderMalfunctionErr (-16341).
    // Evidence: a test call where the window was resized repeatedly died
    // 7 times in 60s, each death 0-1s after a batch of empty ("no image
    // buffer") samples - the marker for the stream reconfiguring - and
    // with zero reattaches in the log, so stream *recreation* wasn't
    // involved; the only thing touching the stream was that call.
    // Recordings used to just stop dead at the first one.
    //
    // Not reconfiguring means a window resized after capture started
    // keeps being captured into the originally-sized buffer, which
    // `scalesToFit` keeps aspect-correct (letterboxed with the
    // transparent background colour) rather than stretched. Slightly
    // softer than a native-res recapture when the window grows; a
    // reattach (fullscreen/Space change) picks up fresh dimensions
    // anyway. The resize plate covers the drag itself either way.

    private var resizeWatchTask: Task<Void, Never>?
    private var lastKnownBounds: CGRect?
    private var resizing = false
    private var lastSizeChangeAt: Date?
    /// Offset into the current segment where the in-progress resize began.
    private var resizeStartOffset: Double?
    /// Content offset where the bounds stopped moving - the event stays
    /// open past this until a real frame lands beyond it. See the settle
    /// branch of `resizeWatchTick`.
    private var resizeSettledAtContent: Double?
    private static let resizeStabilityThreshold: TimeInterval = 1.0
    // Whatever elapses between the drag starting and the next poll is
    // live resizing baked into the recording, so this is deliberately
    // much shorter than the usual "poll for window changes" interval -
    // it's one CGWindowListCopyWindowInfo call for a single known window.
    private static let resizeWatchInterval: UInt64 = 100_000_000

    private func startResizeWatch() {
        resizeWatchTask?.cancel()
        lastKnownBounds = nil
        resizing = false
        lastSizeChangeAt = nil
        resizeStartOffset = nil
        resizeSettledAtContent = nil
        resizeWatchTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.resizeWatchInterval)
                await self.resizeWatchTick()
            }
        }
    }

    private func stopResizeWatch() {
        resizeWatchTask?.cancel()
        resizeWatchTask = nil
    }

    private func resizeWatchTick() async {
        guard let windowID = currentWindowID, let bounds = Self.liveBounds(for: windowID) else { return }
        defer { lastKnownBounds = bounds }
        guard let last = lastKnownBounds else { return }
        let changed = abs(last.width - bounds.width) > 1 || abs(last.height - bounds.height) > 1
        if changed {
            lastSizeChangeAt = Date()
            // A drag resuming while the previous one's event is still
            // waiting to be closed out below merges into it - the start
            // is kept, the pending end is dropped.
            resizeSettledAtContent = nil
            if !resizing {
                resizing = true
                if resizeStartOffset == nil {
                    // One poll back is the last moment the window is
                    // *known* to have still been its old size, so that -
                    // not now - is where an assembler should freeze the
                    // picture. Recording the corrected offset rather than
                    // the detection one is the whole reason the poll
                    // interval is worth knowing.
                    resizeStartOffset = max(0, contentDuration - Double(Self.resizeWatchInterval) / 1_000_000_000)
                }
                StreamOutput.log("resize started (\(Int(last.width))x\(Int(last.height)) -> \(Int(bounds.width))x\(Int(bounds.height)))")
            }
        } else if resizing, let since = lastSizeChangeAt, Date().timeIntervalSince(since) > Self.resizeStabilityThreshold {
            resizing = false
            // The bounds settling is not the event's end. During a drag
            // the stream stops delivering real frames, and the recording
            // fills with repeats of the pre-drag picture (see
            // FrameComposer.repeatLastFrame) - frames that keep coming
            // for a while *after* the bounds stop moving, until capture
            // catches up and a frame actually showing the new size
            // arrives. Ending the event here uncovered exactly that
            // stretch: the plate lifted onto a stale old-size picture
            // that then snapped around. So the settle only starts the
            // wait below for the next real frame, which is the end.
            resizeSettledAtContent = max(resizeStartOffset ?? 0, contentDuration - Date().timeIntervalSince(since))
            StreamOutput.log("resize settled at \(Int(bounds.width))x\(Int(bounds.height))")
        }
        if !resizing, let settled = resizeSettledAtContent, let composer, composer.realContentDuration > settled {
            resizeSettledAtContent = nil
            recordResize(endedAt: composer.realContentDuration)
        }
    }

    /// Writes the resize span to the call's timeline. Also called when a
    /// segment closes mid-drag, so an unfinished resize still gets an end.
    private func recordResize(endedAt offset: Double) {
        guard let start = resizeStartOffset, let url = currentOutputURL else { return }
        resizeStartOffset = nil
        resizeSettledAtContent = nil
        RecordingTimeline.append(
            TimelineEvent(kind: .resize, segment: url.lastPathComponent, at: start, until: max(start, offset)),
            in: url.deletingLastPathComponent()
        )
    }

    private static func liveBounds(for windowID: CGWindowID) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: AnyObject]],
              let info = infoList.first,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        return CGRect(dictionaryRepresentation: boundsDict)
    }

    private func handleStreamStopped(_ error: Error) {
        FileHandle.standardError.write("[\(ISO8601DateFormatter().string(from: Date()))] SCStream stopped: \(error)\n".data(using: .utf8)!)
        guard isStreamAttached else { return }
        stream = nil
        streamConfig = nil
        output = nil
        isStreamAttached = false
    }
}

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let videoReceiver: AVAssetWriterInput.PixelBufferReceiver?
    let audioReceiver: AVAssetWriterInput.SampleBufferReceiver
    let composer: FrameComposer?
    let audioClock: MediaClock
    let onStopped: @Sendable (Error) -> Void
    private var loggedWriterFailure = false
    private var loggedAudioFormat = false
    // A fullscreen/Space transition can leave SCStream delivering samples
    // that compose() can't turn into a frame (confirmed: going fullscreen
    // mid-recording reliably triggers this) without ever calling
    // didStopWithError - isStreamAttached stays true, so nothing ever
    // reattaches and the recording just rots until AVAssetWriter eventually
    // gives up. Treat a run of failures as "the stream is effectively dead"
    // and force the same recovery path as a real stream error.
    private var consecutiveComposeFailures = 0
    private static let maxConsecutiveComposeFailures = 10
    // Visibility into whether SCStream is calling us at all vs. us silently
    // dropping what it sends - launchd's stderr log has no timestamps and
    // no per-sample detail, which made several earlier "it just stops at
    // ~5s" reports impossible to diagnose precisely.
    private var videoSamplesSeen = 0
    private var videoSamplesAppended = 0
    private var videoSamplesNotReady = 0
    private var audioSamplesSeen = 0
    private var audioSamplesAppended = 0
    private static let heartbeatInterval = 90

    init(
        writer: AVAssetWriter,
        videoReceiver: AVAssetWriterInput.PixelBufferReceiver?,
        audioReceiver: AVAssetWriterInput.SampleBufferReceiver,
        composer: FrameComposer?,
        audioClock: MediaClock,
        onStopped: @escaping @Sendable (Error) -> Void
    ) {
        self.writer = writer
        self.videoReceiver = videoReceiver
        self.audioReceiver = audioReceiver
        self.composer = composer
        self.audioClock = audioClock
        self.onStopped = onStopped
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            Self.log("sample not ready (type=\(type))")
            return
        }
        // Keyed off the writer's own status (not a local flag) so that a
        // *new* StreamOutput created by a reattach doesn't try to start a
        // second writing session on the same writer.
        if writer.status == .unknown {
            do {
                try writer.start()
            } catch {
                Self.log("writer.start() failed: \(Self.describe(error))")
                return
            }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        guard writer.status == .writing else {
            if !loggedWriterFailure {
                loggedWriterFailure = true
                Self.log("writer not writing (status=\(writer.status.rawValue)): \(Self.describe(writer.error))")
            }
            return
        }
        switch type {
        case .screen:
            // Audio-only never registers a screen output, so reaching here
            // without a composer would mean SCStream delivering a type
            // nobody asked for.
            guard let composer, let videoReceiver else { return }
            videoSamplesSeen += 1
            let frame: FrameComposer.Frame?
            if CMSampleBufferGetImageBuffer(sampleBuffer) != nil {
                frame = composer.compose(sampleBuffer)
                if frame == nil { noteComposeFailure(sampleBuffer) } else { consecutiveComposeFailures = 0 }
            } else {
                // No picture in this sample. .idle - the window simply
                // didn't change - is routine and must not count towards
                // the forced reattach, or a still call window would be
                // torn down a third of a second in. Either way the last
                // frame is repeated: see FrameComposer.repeatLastFrame for
                // what a video track that goes quiet does to the writer.
                if Self.frameStatus(sampleBuffer) != .idle { noteComposeFailure(sampleBuffer) }
                frame = composer.repeatLastFrame(at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            }
            guard let composed = frame else { return }
            do {
                // appendImmediately is the realtime path: it returns false
                // rather than blocking when the encoder can't keep up, which
                // is what expectsMediaDataInRealTime used to express.
                if try videoReceiver.appendImmediately(composed.buffer, with: composed.pts) {
                    videoSamplesAppended += 1
                    if videoSamplesAppended % Self.heartbeatInterval == 0 {
                        Self.log("heartbeat: video seen=\(videoSamplesSeen) appended=\(videoSamplesAppended) notReady=\(videoSamplesNotReady) | audio seen=\(audioSamplesSeen) appended=\(audioSamplesAppended)")
                    }
                } else {
                    videoSamplesNotReady += 1
                    if videoSamplesNotReady % 30 == 1 {
                        Self.log("video receiver not ready, frame dropped [\(videoSamplesNotReady) times so far, video seen=\(videoSamplesSeen) appended=\(videoSamplesAppended) | audio seen=\(audioSamplesSeen) appended=\(audioSamplesAppended)]")
                    }
                }
            } catch {
                Self.log("video append failed: \(Self.describe(error)) | writer: \(Self.describe(writer.error))")
            }
        case .audio:
            audioSamplesSeen += 1
            audioClock.note(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), duration: CMSampleBufferGetDuration(sampleBuffer))
            logAudioFormatOnce(sampleBuffer)
            // The receiver takes the sample as `sending`, and this one
            // isn't ours to give away - ScreenCaptureKit owns it and only
            // guarantees it for the duration of this callback. A copy (of
            // the sample buffer object; the underlying block buffer is
            // shared, exactly as the old append did) gives us something we
            // can hand over outright.
            var owned: CMSampleBuffer?
            CMSampleBufferCreateCopy(allocator: nil, sampleBuffer: sampleBuffer, sampleBufferOut: &owned)
            guard let owned else {
                Self.log("audio sample copy failed")
                return
            }
            do {
                if try audioReceiver.appendImmediately(CMReadySampleBuffer(unsafeBuffer: SoleOwned(owned).value)) {
                    audioSamplesAppended += 1
                }
            } catch {
                Self.log("audio append failed: \(Self.describe(error))")
            }
        default:
            break
        }
    }

    private func noteComposeFailure(_ sampleBuffer: CMSampleBuffer) {
        consecutiveComposeFailures += 1
        Self.log("compose() returned nil (\(Self.describePixelBuffer(sampleBuffer))) [\(consecutiveComposeFailures) in a row, seen=\(videoSamplesSeen) appended=\(videoSamplesAppended)]")
        if consecutiveComposeFailures >= Self.maxConsecutiveComposeFailures {
            consecutiveComposeFailures = 0
            Self.log("forcing reattach after \(Self.maxConsecutiveComposeFailures) consecutive compose() failures")
            onStopped(RecorderError.windowNotFound)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Self.log("didStopWithError: \(error) [video seen=\(videoSamplesSeen) appended=\(videoSamplesAppended), audio seen=\(audioSamplesSeen) appended=\(audioSamplesAppended)]")
        onStopped(error)
    }

    static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write("[\(ts)] \(message)\n".data(using: .utf8)!)
    }

    private static func describePixelBuffer(_ sampleBuffer: CMSampleBuffer) -> String {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            // A surface-less sample is not necessarily a problem: SCStream
            // reports *why* in its frame-status attachment, and .idle
            // (nothing changed since the last frame) is routine. Worth
            // knowing which, since these samples land right before every
            // writer failure and have been read as a starvation symptom on
            // nothing but that correlation.
            return "no image buffer (frame status: \(describeFrameStatus(sampleBuffer)))"
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        return "size=\(width)x\(height) format=\(format)"
    }

    static func frameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = array.first?[.status] as? Int else {
            return nil
        }
        return SCFrameStatus(rawValue: raw)
    }

    private static func describeFrameStatus(_ sampleBuffer: CMSampleBuffer) -> String {
        guard let status = frameStatus(sampleBuffer) else { return "absent" }
        switch status {
        case .complete: return "complete"
        case .idle: return "idle"
        case .blank: return "blank"
        case .suspended: return "suspended"
        case .started: return "started"
        case .stopped: return "stopped"
        default: return "raw \(status.rawValue)"
        }
    }

    /// Logged once per segment: ScreenCaptureKit's actual audio format,
    /// against which the AAC settings were declared blind (48kHz stereo).
    /// A mismatch would make the writer's audio converter the suspect for
    /// failures that have been blamed on video all along.
    private func logAudioFormatOnce(_ sampleBuffer: CMSampleBuffer) {
        guard !loggedAudioFormat else { return }
        loggedAudioFormat = true
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            Self.log("audio format: unavailable")
            return
        }
        Self.log("audio format: \(asbd.mSampleRate)Hz ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags) bytesPerFrame=\(asbd.mBytesPerFrame)")
    }

    private static func describe(_ error: Error?) -> String {
        guard let error else { return "unknown error" }
        let nsError = error as NSError
        var parts = ["\(nsError.domain) #\(nsError.code): \(nsError.localizedDescription)"]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying: \(underlying.domain) #\(underlying.code): \(underlying.localizedDescription)")
            // Everything the underlying error carries beyond the code.
            // -16341 appears in no SDK header (kVTVideoEncoderMalfunctionErr
            // is -12912, so this is *not* that despite months of assuming
            // it), and it now shows up on audio appends too, so whatever
            // names the real failure has to come from here.
            let extra = underlying.userInfo.filter { $0.key != NSUnderlyingErrorKey }
            if !extra.isEmpty {
                parts.append("underlying info: \(extra)")
            }
        }
        if let failureReason = nsError.localizedFailureReason {
            parts.append("reason: \(failureReason)")
        }
        let own = nsError.userInfo.filter { $0.key != NSUnderlyingErrorKey }
        if !own.isEmpty {
            parts.append("info: \(own)")
        }
        return parts.joined(separator: " | ")
    }
}
