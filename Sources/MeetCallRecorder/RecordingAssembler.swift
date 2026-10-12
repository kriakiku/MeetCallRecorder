import AVFoundation
import CoreImage
import CoreVideo
import CoreGraphics

/// Builds the finished recording from a call's staged segments and the
/// events recorded next to them.
///
/// This is where the welcome/pause/closing plates get drawn, rather than
/// into the capture as it happens. Doing it here is what makes them
/// correct instead of merely timely: assembly reads the whole call at
/// once, so it knows where every pause ended before it has to decide what
/// to draw over its beginning. Live compositing can only react.
///
/// Segments arrive already normalized by ffmpeg (see
/// `CrashRecovery.normalize`): AVFoundation is stricter than ffmpeg about
/// a fragmented MP4 whose writer died without finalizing it, and most
/// segments in a call are exactly that.
enum RecordingAssembler {
    /// A plate to put on the timeline, and the transparent icon/text to
    /// draw on it. The backdrop can't be prepared in advance - a pause or
    /// closing plate sits on the frame the picture was on at that moment,
    /// which only exists part-way through the assembly.
    struct Insert {
        let event: TimelineEvent
        let content: CGImage
    }

    /// The identifying fields stamped into the finished file's own
    /// container metadata - who recorded it, what it's a recording of,
    /// and the two identifiers that tie it back to its source.
    struct RecordingMetadata {
        let sourceApp: String
        let meetingID: String
        let recordingID: String
    }

    /// One plate's position on the *output* timeline, in seconds - written
    /// into the container alongside the simple fields so a future tool can
    /// find and cut every welcome/pause/resize/closing plate without
    /// having to re-detect them from the picture.
    private struct OverlaySpan: Encodable {
        let type: String
        let start: Double
        let end: Double

        init(kind: TimelineEvent.Kind, start: CMTime, end: CMTime) {
            self.type = kind.rawValue
            self.start = CMTimeGetSeconds(start)
            self.end = CMTimeGetSeconds(end)
        }
    }

    private static var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(CallRecorder.frameRate))
    }

    /// How much time an insert adds to the output timeline. The fade-out
    /// isn't part of it: that plays over the real frames that follow,
    /// which is what keeps a plate from hiding any of the call.
    private static func insertedDuration(_ kind: TimelineEvent.Kind) -> Double {
        switch kind {
        case .intro:
            // No entrance animation - it isn't covering anything yet.
            return CallRecorder.cardDuration
        case .pause, .outro:
            return FrameComposer.cardTransitionDuration + CallRecorder.cardDuration
        case .resize:
            // The one insert that adds nothing. A resize plate *replaces*
            // the frames it spans rather than displacing them: the drag is
            // already in the recording and the plate is there to hide it,
            // not to lengthen it. That is also what lets the audio run on
            // underneath, untouched and unsplit - someone talking through
            // a window drag is still heard.
            return 0
        }
    }

    /// Everything half-finished is written to `scratch` - the call's own
    /// staging folder - and only the finished file is moved to
    /// `destination`. The recordings folder should never contain anything
    /// that isn't a recording, not even briefly: assembly takes seconds,
    /// and a failure partway leaves its debris with the call it belongs
    /// to, where retrying picks it up and the folder's eventual deletion
    /// takes it away.
    static func assemble(segments: [URL], durations: [Double], inserts: [Insert], recordingID: CGImage?, metadata: RecordingMetadata, scratch: URL, to destination: URL) async -> Bool {
        guard !segments.isEmpty else { return false }
        let outputSize = CallRecorder.outputSize
        let fm = FileManager.default
        let tempURL = scratch.appendingPathComponent(destination.lastPathComponent + ".video")
        try? fm.removeItem(at: tempURL)

        let context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        ])
        guard let pool = makePool(size: outputSize) else { return false }

        // The outro names the last segment but belongs after it; every
        // other insert sits at an offset inside the segment it names.
        let outro = inserts.first { $0.event.kind == .outro }
        var inSegment: [String: [Insert]] = [:]
        for insert in inserts where insert.event.kind != .outro {
            inSegment[insert.event.segment, default: []].append(insert)
        }
        for key in inSegment.keys {
            inSegment[key]?.sort { $0.event.at < $1.event.at }
        }

        var overlaySpans: [OverlaySpan] = []

        do {
            let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
            // HEVC rather than H.264: ~H.264 quality at ~60% of the rate,
            // QuickTime/Preview play it natively (hardware decode on any
            // Mac since 2017), and so do Safari/Chrome/Edge - Firefox is
            // the one holdout. AVAssetWriter writes the hvc1 sample-entry
            // QuickTime requires (not hev1), and every ffmpeg pass after
            // this one is a stream copy, so the tag survives to the
            // finished file. WebM was tried and rolled back: nothing
            // native plays it, and the VP9 encode was minutes per call
            // where this is a hardware encode plus copies.
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(outputSize.width),
                AVVideoHeightKey: Int(outputSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoExpectedSourceFrameRateKey: CallRecorder.frameRate,
                    AVVideoAverageBitRateKey: CallRecorder.outputBitrate
                ]
            ])
            // Nothing here is real time: the writer is allowed to make us
            // wait, which is the difference between this and the capture
            // path that has to drop whatever it can't take.
            videoInput.expectsMediaDataInRealTime = false

            let videoReceiver = writer.inputPixelBufferReceiver(for: videoInput, pixelBufferAttributes: nil)

            log("assemble: \(segments.count) segment(s), \(inserts.count) insert(s)")
            try writer.start()
            writer.startSession(atSourceTime: .zero)

            var cursor = CMTime.zero
            var frozen: CVPixelBuffer?

            for segment in segments {
                let result = try await append(
                    segment: segment,
                    inserts: inSegment[segment.lastPathComponent] ?? [],
                    startingAt: cursor,
                    frozen: frozen,
                    recordingID: recordingID,
                    outputSize: outputSize,
                    pool: pool,
                    context: context,
                    videoReceiver: videoReceiver
                )
                cursor = result.cursor
                frozen = result.lastFrame ?? frozen
                overlaySpans.append(contentsOf: result.overlaySpans)
            }

            if let outro {
                let outroStart = cursor
                cursor = try await appendPlate(
                    plate(outro, over: frozen, recordingID: recordingID, outputSize: outputSize),
                    over: frozen,
                    startingAt: cursor,
                    fadeIn: true,
                    outputSize: outputSize,
                    pool: pool,
                    context: context,
                    receiver: videoReceiver
                )
                overlaySpans.append(OverlaySpan(kind: .outro, start: outroStart, end: cursor))
            }

            videoReceiver.finish()
            await writer.finishWriting()
            guard writer.status == .completed else {
                log("assemble: writer finished as \(writer.status.rawValue): \(writer.error.map(String.init(describing:)) ?? "no error")")
                try? fm.removeItem(at: tempURL)
                return false
            }
        } catch {
            log("assemble: \(error)")
            try? fm.removeItem(at: tempURL)
            return false
        }

        defer { try? fm.removeItem(at: tempURL) }

        // Audio is assembled separately and muxed in, rather than being
        // written as a second track of the pass above.
        //
        // Not a preference: AVAssetWriter interleaves its tracks, and
        // driving both from one sequential loop of awaiting appends
        // deadlocks - the video append stops returning because the muxer
        // wants audio, and the audio it wants is what the caller would
        // have sent next. Plates make that unavoidable, since they are
        // video with no audio of their own. Measured, not assumed: the
        // identical pass with the audio track removed runs to completion.
        //
        // It also keeps the audio a stream copy instead of a decode and
        // re-encode, which the in-writer version needed to splice
        // silence.
        return await muxAudio(
            into: tempURL,
            segments: segments,
            durations: durations,
            inserts: inserts,
            metadata: metadata,
            overlaySpans: overlaySpans,
            scratch: scratch,
            destination: destination
        )
    }

    /// `-metadata key=value` pairs for the identifying fields, plus the
    /// overlay span list as one JSON string under its own key.
    /// `use_metadata_tags` is what makes the mov/mp4 muxer keep keys it
    /// doesn't already know about - without it, anything other than a
    /// small fixed set (title, comment, artist, ...) is silently dropped
    /// rather than rejected, which is what made this worth checking
    /// against a real mux rather than assuming the flag was unnecessary.
    private static func containerMetadataArguments(_ metadata: RecordingMetadata, overlaySpans: [OverlaySpan]) -> [String] {
        var args = [
            "-movflags", "use_metadata_tags",
            "-metadata", "recorder_app=MeetCallRecorder",
            "-metadata", "source_app=\(metadata.sourceApp)",
            "-metadata", "meeting_id=\(metadata.meetingID)",
            "-metadata", "recording_id=\(metadata.recordingID)"
        ]
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(overlaySpans), let json = String(data: data, encoding: .utf8) {
            args.append(contentsOf: ["-metadata", "overlays=\(json)"])
        }
        return args
    }

    /// Builds the output's audio from the segments' own tracks plus
    /// generated silence for every stretch a plate occupies, then puts it
    /// alongside the assembled video.
    private static func muxAudio(into video: URL, segments: [URL], durations: [Double], inserts: [Insert], metadata: RecordingMetadata, overlaySpans: [OverlaySpan], scratch scratchDir: URL, destination: URL) async -> Bool {
        let metadataArgs = containerMetadataArguments(metadata, overlaySpans: overlaySpans)
        let fm = FileManager.default
        let runID = UUID().uuidString
        var scratch: [URL] = []
        defer { for file in scratch { try? fm.removeItem(at: file) } }

        var pieces: [URL] = []
        var index = 0

        func addSilence(_ duration: Double) async {
            guard duration > 0.001 else { return }
            let url = scratchDir.appendingPathComponent(".audio-\(runID)-\(index).m4a")
            index += 1
            if await CrashRecovery.runFFmpegArgs([
                "-y", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
                "-t", "\(duration)", "-c:a", "aac", "-b:a", "128k", "-f", "mp4", url.path
            ]) {
                scratch.append(url)
                pieces.append(url)
            }
        }

        func addAudio(_ segment: URL, from: Double, to: Double) async {
            guard to - from > 0.001 else { return }
            let url = scratchDir.appendingPathComponent(".audio-\(runID)-\(index).m4a")
            index += 1
            if await CrashRecovery.runFFmpegArgs([
                "-y", "-ss", "\(from)", "-to", "\(to)", "-i", segment.path,
                "-vn", "-c:a", "copy", "-avoid_negative_ts", "make_zero", "-f", "mp4", url.path
            ]) {
                scratch.append(url)
                pieces.append(url)
            }
        }

        for (position, segment) in segments.enumerated() {
            let duration = position < durations.count ? durations[position] : 0
            // Resizes are skipped outright rather than contributing a
            // zero-length silence: every insert here splits the segment's
            // audio into two stream copies that are concatenated back, and
            // a copy can only cut on a packet boundary. A split that buys
            // nothing still costs the rounding.
            let own = inserts
                .filter { $0.event.kind != .outro && $0.event.kind != .resize && $0.event.segment == segment.lastPathComponent }
                .sorted { $0.event.at < $1.event.at }
            var cursor: Double = 0
            for insert in own {
                await addAudio(segment, from: cursor, to: insert.event.at)
                await addSilence(insertedDuration(insert.event.kind))
                cursor = insert.event.at
            }
            await addAudio(segment, from: cursor, to: duration)
        }
        if inserts.contains(where: { $0.event.kind == .outro }) {
            await addSilence(insertedDuration(.outro))
        }

        guard !pieces.isEmpty else {
            // No audio anywhere - the video alone is the recording.
            return await stampAndMove(video, metadataArgs: metadataArgs, scratch: scratchDir, to: destination)
        }

        let listFile = scratchDir.appendingPathComponent(".audio-\(runID).txt")
        let list = pieces.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n") + "\n"
        guard (try? list.write(to: listFile, atomically: true, encoding: .utf8)) != nil else {
            return await stampAndMove(video, metadataArgs: metadataArgs, scratch: scratchDir, to: destination)
        }
        scratch.append(listFile)

        let audioURL = scratchDir.appendingPathComponent(".audio-\(runID).m4a")
        guard await CrashRecovery.runFFmpegArgs([
            "-y", "-f", "concat", "-safe", "0", "-i", listFile.path,
            "-c", "copy", "-f", "mp4", audioURL.path
        ]), fm.fileExists(atPath: audioURL.path) else {
            log("assemble: audio concat failed - keeping the video alone")
            return await stampAndMove(video, metadataArgs: metadataArgs, scratch: scratchDir, to: destination)
        }
        scratch.append(audioURL)

        // Metadata rides along on this same mux pass rather than a
        // separate remux - it's already rewriting the container to add
        // the audio track, so there's no second pass to add here.
        let muxed = scratchDir.appendingPathComponent(destination.lastPathComponent + ".assembling")
        guard await CrashRecovery.runFFmpegArgs([
            "-y", "-i", video.path, "-i", audioURL.path,
            "-map", "0:v:0", "-map", "1:a:0", "-c", "copy"
        ] + metadataArgs + ["-f", "mp4", muxed.path]), fm.fileExists(atPath: muxed.path) else {
            log("assemble: mux failed - keeping the video alone")
            try? fm.removeItem(at: muxed)
            return await stampAndMove(video, metadataArgs: metadataArgs, scratch: scratchDir, to: destination)
        }
        return move(muxed, to: destination)
    }

    /// Stamps the container metadata onto a video-only file via a stream-
    /// copy remux, then moves the result into place - the path every
    /// fallback above takes when there turned out to be no audio to mux
    /// in. Falls back to moving `source` as-is if the remux itself fails,
    /// since losing the metadata is far preferable to losing the
    /// recording.
    private static func stampAndMove(_ source: URL, metadataArgs: [String], scratch scratchDir: URL, to destination: URL) async -> Bool {
        let stamped = scratchDir.appendingPathComponent(destination.lastPathComponent + ".stamping")
        defer { try? FileManager.default.removeItem(at: stamped) }
        guard await CrashRecovery.runFFmpegArgs(
            ["-y", "-i", source.path, "-c", "copy"] + metadataArgs + ["-f", "mp4", stamped.path]
        ), FileManager.default.fileExists(atPath: stamped.path) else {
            log("assemble: metadata stamp failed - keeping the file as-is")
            return move(source, to: destination)
        }
        return move(stamped, to: destination)
    }

    private static func move(_ source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: source, to: destination)
        } catch {
            try? fm.removeItem(at: source)
            return false
        }
        return true
    }

    // MARK: - Segments

    private struct SegmentResult {
        let cursor: CMTime
        let lastFrame: CVPixelBuffer?
        let overlaySpans: [OverlaySpan]
    }

    /// Copies one segment onto the output timeline, inserting its plates
    /// and fading each one out over the frames that follow it.
    private static func append(
        segment: URL,
        inserts: [Insert],
        startingAt start: CMTime,
        frozen: CVPixelBuffer?,
        recordingID: CGImage?,
        outputSize: CGSize,
        pool: CVPixelBufferPool,
        context: CIContext,
        videoReceiver: AVAssetWriterInput.PixelBufferReceiver
    ) async throws -> SegmentResult {
        let asset = AVURLAsset(url: segment)
        let reader = try AVAssetReader(asset: asset)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            return SegmentResult(cursor: start, lastFrame: frozen, overlaySpans: [])
        }
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        reader.startReading()

        // Inserts add time, so everything after one shifts. Both tracks
        // have to shift by the same amount at the same point, which is
        // why the shifts are worked out from the events up front instead
        // of accumulated while walking the video. Resizes contribute
        // nothing here, by way of `insertedDuration`.
        let shifts: [(at: Double, by: Double)] = inserts.map { ($0.event.at, insertedDuration($0.event.kind)) }
        func shift(at offset: Double) -> Double {
            shifts.reduce(0) { $0 + (offset >= $1.at ? $1.by : 0) }
        }
        func outputTime(_ offset: Double) -> CMTime {
            CMTimeAdd(start, CMTime(seconds: offset + shift(at: offset), preferredTimescale: 600))
        }

        var pending = inserts
        var fadeOut: (plate: CIImage, startedAt: Double, duration: Double)?
        /// A resize plate standing in for the live frames, up to the
        /// offset the drag settled at - `startPTS` is where it began on
        /// the output timeline, for the overlay span recorded once it
        /// ends.
        var covering: (plate: CIImage, until: Double, startPTS: CMTime)?
        /// The output pts of the most recent frame `covering` stood in
        /// for - the end of the span once covering stops, since nothing
        /// else records where the *last* covered frame actually landed.
        var lastCoveringPTS: CMTime?
        var lastFrame: CVPixelBuffer? = frozen
        var lastOffset: Double = 0
        var cursor = start
        var videoFrames = 0
        var overlaySpans: [OverlaySpan] = []

        while let sample = videoOutput.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let offset = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let previousOffset = lastOffset
            lastOffset = offset

            // The drag has settled: hand the resize plate over to a fade,
            // which plays out over the live frames - now arriving at the
            // window's new size.
            if let cover = covering, offset > cover.until {
                if let end = lastCoveringPTS {
                    overlaySpans.append(OverlaySpan(kind: .resize, start: cover.startPTS, end: end))
                }
                fadeOut = (cover.plate, offset, FrameComposer.resizeTransitionDuration)
                covering = nil
                lastCoveringPTS = nil
            }

            while let next = pending.first, offset >= next.event.at {
                pending.removeFirst()
                // Built once: it is both what gets held, and what fades
                // back out over the frames that follow.
                let plateImage = plate(next, over: lastFrame, recordingID: recordingID, outputSize: outputSize)

                guard next.event.kind != .resize else {
                    // No frames of its own, and no fade in. The picture
                    // stops dead on `lastFrame` - the frame before the
                    // drag was first noticed - and the plate is simply up
                    // from here until the drag settles. Stopping dead is
                    // the point: every frame between here and `until` is
                    // the window captured at its old, now-stale
                    // dimensions and stretched to fit, which is the one
                    // thing worth hiding.
                    covering = (plateImage, next.event.until ?? .infinity, outputTime(offset))
                    fadeOut = nil
                    continue
                }

                let plateStart = CMTimeAdd(start, CMTime(seconds: next.event.at + shift(at: next.event.at) - insertedDuration(next.event.kind), preferredTimescale: 600))
                cursor = try await appendPlate(
                    plateImage,
                    over: lastFrame,
                    startingAt: plateStart,
                    fadeIn: next.event.kind != .intro,
                    outputSize: outputSize,
                    pool: pool,
                    context: context,
                    receiver: videoReceiver
                )
                overlaySpans.append(OverlaySpan(kind: next.event.kind, start: plateStart, end: cursor))
                fadeOut = (plateImage, offset, FrameComposer.cardTransitionDuration)
            }

            // The fade-out rides on the source's own frames - but the
            // source only has frames where the window actually changed.
            // A static window (nobody's camera, a held slide) can leave
            // the entire fade window frameless: the next real frame
            // lands past the fade's end, `elapsed >= duration` on first
            // sight, and the plate pops off with no transition at all -
            // which is exactly how it looked. So the frames the source
            // doesn't provide are synthesized: the fade plays out at
            // output frame rate over a repeat of the last real picture,
            // and the real frame then lands wherever it was anyway.
            // The underlay is this frame, not `lastFrame`: the gap being
            // filled is a stretch where the source delivered nothing
            // because nothing changed, so the arriving frame *is* what
            // was on screen throughout it - and `lastFrame`'s buffer
            // belongs to the decoder (alwaysCopiesSampleData is false),
            // which may have recycled it by now.
            if let fade = fadeOut, covering == nil {
                let interval = 1.0 / Double(CallRecorder.frameRate)
                var t = max(previousOffset + interval, fade.startedAt + interval)
                let underImage = CIImage(cvPixelBuffer: buffer)
                while t < offset - interval / 2, t - fade.startedAt < fade.duration {
                    let x = (t - fade.startedAt) / fade.duration
                    let eased = x * x * (3 - 2 * x)
                    try await emit(
                        fade.plate.applyingAlpha(1 - eased).composited(over: underImage),
                        at: outputTime(t), pool: pool, context: context, outputSize: outputSize, receiver: videoReceiver
                    )
                    videoFrames += 1
                    t += interval
                }
            }

            var image = covering?.plate ?? CIImage(cvPixelBuffer: buffer)
            if let fade = fadeOut {
                let elapsed = offset - fade.startedAt
                if elapsed >= fade.duration {
                    fadeOut = nil
                } else {
                    let t = elapsed / fade.duration
                    let eased = t * t * (3 - 2 * t)
                    image = fade.plate.applyingAlpha(1 - eased).composited(over: image)
                }
            }

            let pts = outputTime(offset)
            videoFrames += 1
            try await emit(image, at: pts, pool: pool, context: context, outputSize: outputSize, receiver: videoReceiver)
            cursor = CMTimeAdd(pts, frameDuration)
            if covering != nil { lastCoveringPTS = pts }
            // What a later plate freezes on has to be the picture as it
            // last really was. The frames a resize covers are the drag
            // itself, which is the one thing nothing should freeze on.
            if covering == nil { lastFrame = buffer }
        }
        log("assemble: \(segment.lastPathComponent) video done (\(videoFrames) frames)")

        // The segment ended mid-drag - the writer died, say - with no
        // settle to close the span out normally. What was covered up to
        // the last frame still happened and still belongs in the list.
        if let cover = covering, let end = lastCoveringPTS {
            overlaySpans.append(OverlaySpan(kind: .resize, start: cover.startPTS, end: end))
        }

        // A segment that ended before an insert it was supposed to carry -
        // the writer died mid-pause, say - still gets its plate. Except a
        // resize: with no frames left to cover, there is nothing for it to
        // stand in for.
        for insert in pending where insert.event.kind != .resize {
            let plateStart = cursor
            cursor = try await appendPlate(
                plate(insert, over: lastFrame, recordingID: recordingID, outputSize: outputSize),
                over: lastFrame,
                startingAt: cursor,
                fadeIn: insert.event.kind != .intro,
                outputSize: outputSize,
                pool: pool,
                context: context,
                receiver: videoReceiver
            )
            overlaySpans.append(OverlaySpan(kind: insert.event.kind, start: plateStart, end: cursor))
        }

        // Copy the frame the next plate will freeze into a buffer of
        // ours. It currently belongs to this segment's decoder, and the
        // reader is about to be torn down - handing a plate something
        // owned by a dead decoder is how the first version of this
        // stalled partway through the second segment.
        let frozenCopy = own(lastFrame, pool: pool, context: context, outputSize: outputSize)

        if reader.status == .failed {
            log("assemble: reading \(segment.lastPathComponent) failed at \(String(format: "%.2f", lastOffset))s: \(reader.error.map(String.init(describing:)) ?? "no error")")
        }
        reader.cancelReading()
        return SegmentResult(cursor: cursor, lastFrame: frozenCopy ?? frozen, overlaySpans: overlaySpans)
    }

    // MARK: - Plates

    private static func plate(_ insert: Insert, over frozen: CVPixelBuffer?, recordingID: CGImage?, outputSize: CGSize) -> CIImage {
        let still = frozen.flatMap { buffer -> CGImage? in
            let context = CIContext()
            return context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(origin: .zero, size: outputSize))
        }
        let composed = FrameComposer.composeCardOverStill(
            card: insert.content,
            // The welcome plate gets the wallpaper alone: it isn't
            // standing in for a picture that was just there.
            still: insert.event.kind == .intro ? nil : still,
            outputSize: outputSize,
            safeInset: CallRecorder.safeInset,
            recordingID: recordingID
        )
        return composed.map { CIImage(cgImage: $0) } ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    /// Writes an insert's own frames: an optional fade in from the frozen
    /// picture, then the plate held still. Returns where the timeline has
    /// got to.
    private static func appendPlate(
        _ plateImage: CIImage,
        over frozen: CVPixelBuffer?,
        startingAt start: CMTime,
        fadeIn: Bool,
        outputSize: CGSize,
        pool: CVPixelBufferPool,
        context: CIContext,
        receiver: AVAssetWriterInput.PixelBufferReceiver
    ) async throws -> CMTime {
        let still = frozen.map { CIImage(cvPixelBuffer: $0) }
        var pts = start

        if fadeIn, let still {
            let frames = max(1, Int((FrameComposer.cardTransitionDuration * Double(CallRecorder.frameRate)).rounded()))
            for index in 1...frames {
                let t = Double(index) / Double(frames)
                let eased = t * t * (3 - 2 * t)
                let image = plateImage.applyingAlpha(eased).composited(over: still)
                try await emit(image, at: pts, pool: pool, context: context, outputSize: outputSize, receiver: receiver)
                pts = CMTimeAdd(pts, frameDuration)
            }
        }

        let holdFrames = max(1, Int((CallRecorder.cardDuration * Double(CallRecorder.frameRate)).rounded()))
        for _ in 0..<holdFrames {
            try await emit(plateImage, at: pts, pool: pool, context: context, outputSize: outputSize, receiver: receiver)
            pts = CMTimeAdd(pts, frameDuration)
        }
        return pts
    }

    // MARK: - Plumbing

    /// A copy of `buffer` in a pool buffer we own.
    private static func own(_ buffer: CVPixelBuffer?, pool: CVPixelBufferPool, context: CIContext, outputSize: CGSize) -> CVPixelBuffer? {
        guard let buffer else { return nil }
        var copy: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &copy)
        guard let copy else { return nil }
        context.render(CIImage(cvPixelBuffer: buffer).cropped(to: CGRect(origin: .zero, size: outputSize)), to: copy)
        return copy
    }


    private static func emit(
        _ image: CIImage,
        at pts: CMTime,
        pool: CVPixelBufferPool,
        context: CIContext,
        outputSize: CGSize,
        receiver: AVAssetWriterInput.PixelBufferReceiver
    ) async throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else {
            log("emit: no pool buffer at \(String(format: "%.3f", CMTimeGetSeconds(pts)))")
            return
        }
        context.render(image.cropped(to: CGRect(origin: .zero, size: outputSize)), to: buffer)
        try await receiver.append(CVReadOnlyPixelBuffer(unsafeBuffer: SoleOwned(buffer).value), with: pts)
    }

    private static func hasAudio(_ segment: URL) async throws -> Bool {
        try await !AVURLAsset(url: segment).loadTracks(withMediaType: .audio).isEmpty
    }

    private static func makePool(size: CGSize) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ] as CFDictionary, &pool)
        return pool
    }

    private static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write("[\(ts)] \(message)\n".data(using: .utf8)!)
    }
}
