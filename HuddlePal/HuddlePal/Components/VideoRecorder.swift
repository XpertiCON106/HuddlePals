import AVFoundation
import Observation
import UIKit

/// Records one video drop of up to 6 seconds. An AVCaptureSession feeds
/// AVAssetWriter directly, so the clip is compressed while it records (720p
/// H.264 at about 2 Mbps, AAC mono when the microphone is allowed) and ends
/// at exactly 6.0 seconds by the frames' own timestamps. It goes into
/// `CaptureFiles`, then straight into memory (`ClipPreparer`). The writer
/// adds no metadata: no location, no device, just pictures and sound.
@MainActor
@Observable
final class VideoRecorder {
    enum State: Equatable {
        /// Asking for access and starting the camera.
        case starting
        case ready
        case recording
        /// Writing out the last frames and making the poster.
        case finishing
        /// No camera to record with, and why.
        case unavailable(String)
    }

    private(set) var state: State = .starting
    /// Seconds recorded so far, by the frames' timestamps.
    private(set) var elapsed: TimeInterval = 0
    private(set) var position: AVCaptureDevice.Position = .back
    /// False when the microphone is off for HuddlePals: the clip is silent.
    private(set) var hasAudio = false
    /// Why the last recording didn't make it (an interruption, a failure).
    private(set) var notice: String?
    /// The finished clip.
    @ObservationIgnored var onFinish: ((PreparedClip) -> Void)?

    @ObservationIgnored private let controller = CaptureController()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var session: AVCaptureSession { controller.session }

    init() {
        controller.writer.onProgress = { [weak self] seconds in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.elapsed = min(seconds, HuddleLimits.maxVideoDuration)
            }
        }
        controller.writer.onFinished = { [weak self] result in
            Task { @MainActor in await self?.finished(result) }
        }
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: controller.session, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.discard(because: "Recording stopped: something else took the camera. Try again.") }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() async {
        guard state == .starting else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            state = .unavailable("Camera access is off. Turn on Camera for HuddlePals in Settings.")
            return
        }
        // Asked the first time someone records; without it, a silent clip.
        hasAudio = await AVCaptureDevice.requestAccess(for: .audio)
        let position = position, audio = hasAudio
        do {
            try await controller.run { try self.controllerStart(position: position, audio: audio) }
            state = .ready
        } catch {
            state = .unavailable("The camera couldn't start. Close this and try again.")
        }
    }

    func record() {
        guard state == .ready else { return }
        do {
            let url = try CaptureFiles.newClipURL()
            elapsed = 0
            notice = nil
            state = .recording
            Haptics.light()
            let writer = controller.writer, audio = hasAudio
            controller.queue.async { writer.begin(into: url, withAudio: audio) }
        } catch {
            notice = "Couldn't start recording. Try again."
        }
    }

    /// Stops early; at 6 seconds it stops by itself.
    func stop() {
        guard state == .recording else { return }
        state = .finishing
        let writer = controller.writer
        controller.queue.async { writer.finish() }
    }

    func flip() async {
        guard state == .ready else { return }
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        do {
            try await controller.run { try self.controllerSwitch(to: next) }
            position = next
        } catch {
            notice = "Couldn't switch cameras."
        }
    }

    /// The app left the foreground, or the screen closed mid-recording:
    /// nothing half-recorded is kept.
    func discard(because reason: String? = nil) {
        guard state == .recording || state == .finishing else { return }
        let writer = controller.writer
        controller.queue.async { writer.cancel() }
        elapsed = 0
        notice = reason ?? "Recording stopped. Try again."
        state = .ready
    }

    /// The capture screen closed.
    func shutDown() {
        discard()
        let controller = controller
        controller.queue.async { controller.session.stopRunning() }
    }

    private func finished(_ result: Result<URL, Error>) async {
        guard state == .recording || state == .finishing else {
            // Discarded meanwhile.
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            return
        }
        state = .finishing
        switch result {
        case .success(let url):
            do {
                let clip = try await ClipPreparer.prepare(fileAt: url)
                state = .ready
                elapsed = 0
                onFinish?(clip)
            } catch {
                state = .ready
                notice = error.localizedDescription
            }
        case .failure:
            CaptureFiles.sweep()
            state = .ready
            notice = "That video didn't record properly. Try again."
        }
    }

    // On the capture queue.
    nonisolated private func controllerStart(position: AVCaptureDevice.Position, audio: Bool) throws {
        try controller.configure(position: position, audio: audio)
        controller.session.startRunning()
    }

    nonisolated private func controllerSwitch(to position: AVCaptureDevice.Position) throws {
        try controller.configure(position: position, audio: false)
    }
}

/// The capture queue's side of the recorder: the session, its inputs and
/// outputs, and the writer. Everything here runs on `queue`.
final class CaptureController: @unchecked Sendable {
    enum CaptureError: Error {
        case noCamera
    }

    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "com.huddlepals.video-capture")
    let writer = ClipWriter()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var cameraInput: AVCaptureDeviceInput?
    private var microphoneInput: AVCaptureDeviceInput?

    /// Runs `work` on the capture queue.
    func run(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// The camera at `position`, and the microphone the first time `audio`
    /// is true. Frames come out portrait, mirrored for the front camera (as
    /// the preview shows them).
    func configure(position: AVCaptureDevice.Position, audio: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw CaptureError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: camera)
        if let cameraInput { session.removeInput(cameraInput) }
        guard session.canAddInput(input) else { throw CaptureError.noCamera }
        session.addInput(input)
        cameraInput = input

        if audio, microphoneInput == nil, let microphone = AVCaptureDevice.default(for: .audio),
           let microphoneInput = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(microphoneInput) {
            session.addInput(microphoneInput)
            self.microphoneInput = microphoneInput
        }

        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(writer, queue: queue)
            session.addOutput(videoOutput)
        }
        if microphoneInput != nil, !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
            audioOutput.setSampleBufferDelegate(writer, queue: queue)
            session.addOutput(audioOutput)
        }
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = position == .front }
        }
    }
}

/// Takes the session's sample buffers and writes them, from the first video
/// frame to the 6.0-second mark. Only ever touched on the capture queue.
final class ClipWriter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let maxDuration = CMTime(seconds: HuddleLimits.maxVideoDuration, preferredTimescale: 600)
    /// About 1.5 MB for 6 seconds: well under `HuddleLimits.maxVideoBytes`.
    static let videoBitRate = 2_000_000
    static let audioBitRate = 64_000

    /// Whether a frame `elapsed` after the first is past the end.
    static func isPastEnd(_ elapsed: CMTime) -> Bool {
        CMTimeCompare(elapsed, maxDuration) >= 0
    }

    /// H.264 (plays everywhere, NCMEC included) at the frames' own size.
    static func videoSettings(width: Int, height: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ]
    }

    static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: 44_100,
        AVEncoderBitRateKey: audioBitRate,
    ]

    var onProgress: (@Sendable (TimeInterval) -> Void)?
    var onFinished: (@Sendable (Result<URL, Error>) -> Void)?

    private var url: URL?
    private var withAudio = false
    private var recording = false
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var startTime: CMTime?
    private var lastVideoTime: CMTime?

    func begin(into url: URL, withAudio: Bool) {
        self.url = url
        self.withAudio = withAudio
        writer = nil
        videoInput = nil
        audioInput = nil
        startTime = nil
        lastVideoTime = nil
        recording = true
    }

    /// Ends the clip at the last frame (or at 6.0 seconds) and reports it.
    func finish(atLimit: Bool = false) {
        guard recording else { return }
        recording = false
        guard let writer, writer.status == .writing, let startTime, let lastVideoTime, let url else {
            cancel()
            onFinished?(.failure(CaptureController.CaptureError.noCamera))
            return
        }
        let frame = CMTime(value: 1, timescale: 30)
        let end = atLimit
            ? CMTimeAdd(startTime, Self.maxDuration)
            : CMTimeMinimum(CMTimeAdd(lastVideoTime, frame), CMTimeAdd(startTime, Self.maxDuration))
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: end)
        let onFinished = onFinished
        writer.finishWriting {
            onFinished?(writer.status == .completed ? .success(url) : .failure(writer.error ?? CaptureController.CaptureError.noCamera))
        }
        self.writer = nil
    }

    /// Throws the recording away, file and all.
    func cancel() {
        recording = false
        writer?.cancelWriting()
        writer = nil
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if output is AVCaptureVideoDataOutput {
            if writer == nil, !startWriting(with: sampleBuffer, at: time) {
                cancel()
                onFinished?(.failure(CaptureController.CaptureError.noCamera))
                return
            }
            guard let startTime, let videoInput else { return }
            let elapsed = CMTimeSubtract(time, startTime)
            if Self.isPastEnd(elapsed) {
                finish(atLimit: true)
                return
            }
            if videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) {
                lastVideoTime = time
            }
            onProgress?(elapsed.seconds)
        } else if let audioInput, let startTime, CMTimeCompare(time, startTime) >= 0,
                  !Self.isPastEnd(CMTimeSubtract(time, startTime)), audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }

    /// The writer starts with the first frame, sized to it: portrait when the
    /// connection rotates frames, landscape turned upright otherwise.
    private func startWriting(with sampleBuffer: CMSampleBuffer, at time: CMTime) -> Bool {
        guard let url, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4)
        else { return false }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        // The index up front, so playback from memory starts at once.
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = []
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(width: width, height: height))
        video.expectsMediaDataInRealTime = true
        if width > height { video.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        guard writer.canAdd(video) else { return false }
        writer.add(video)
        if withAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
            }
        }
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        videoInput = video
        startTime = time
        return true
    }
}
