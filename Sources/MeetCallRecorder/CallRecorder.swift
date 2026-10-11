import AVFoundation
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
actor CallRecorder {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var output: StreamOutput?
    private(set) var isRecording = false
    private(set) var currentOutputURL: URL?

    // Fixed output canvas, independent of the actual call window's size -
    // the window is scaled (preserving aspect ratio) to fit a centered
    // safe area, system wallpaper filling whatever's left. See
    // FrameComposer.
    private static let outputSize = CGSize(width: 1920, height: 1080)
    private static let safeInset: CGFloat = 32
    private static let frameRate: Int32 = 30

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f
    }()

    func start(window: DetectedWindow, outputDir: URL) async throws -> URL {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == window.windowID }) else {
            throw RecorderError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = max(2, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
        config.height = max(2, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.frameRate))

        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let filename = Self.filenameFormatter.string(from: Date()) + ".mp4"
        let outputURL = outputDir.appendingPathComponent(filename)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // Fragmented MP4: periodically closes out a playable chunk, so a
        // crash mid-recording loses at most the last few seconds instead of
        // the whole file - the same crash-safety reasoning that made OBS
        // default to mkv, without needing mkv specifically.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 1)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(Self.outputSize.width),
            AVVideoHeightKey: Int(Self.outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: Self.frameRate
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2
        ])
        audioInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)
        writer.add(audioInput)

        let composer = FrameComposer(outputSize: Self.outputSize, safeInset: Self.safeInset)
        let output = StreamOutput(writer: writer, videoInput: videoInput, audioInput: audioInput, composer: composer)
        let scStream = SCStream(filter: filter, configuration: config, delegate: output)
        let queue = DispatchQueue(label: "dev.kriakiku.MeetCallRecorder.samples")
        try scStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        try scStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)

        try await scStream.startCapture()

        self.stream = scStream
        self.writer = writer
        self.output = output
        self.isRecording = true
        self.currentOutputURL = outputURL
        return outputURL
    }

    @discardableResult
    func stop() async throws -> URL {
        guard isRecording, let stream, let writer, let output, let url = currentOutputURL else {
            throw RecorderError.noActiveRecording
        }
        try await stream.stopCapture()
        output.finish()
        while writer.status == .writing {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        self.stream = nil
        self.writer = nil
        self.output = nil
        self.isRecording = false
        self.currentOutputURL = nil
        return url
    }
}

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput
    let composer: FrameComposer
    private var started = false

    init(writer: AVAssetWriter, videoInput: AVAssetWriterInput, audioInput: AVAssetWriterInput, composer: FrameComposer) {
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.composer = composer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        switch type {
        case .screen:
            guard videoInput.isReadyForMoreMediaData, let composed = composer.compose(sampleBuffer) else { return }
            videoInput.append(composed)
        case .audio:
            if audioInput.isReadyForMoreMediaData { audioInput.append(sampleBuffer) }
        default:
            break
        }
    }

    func finish() {
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        writer.finishWriting {}
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("SCStream stopped with error: \(error)\n".data(using: .utf8)!)
    }
}
