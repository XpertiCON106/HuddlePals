import AVFoundation
import SwiftUI
import UIKit

/// The video drop camera: tap to record, tap again to stop, and at 6 seconds
/// it stops by itself, with a ring that fills as it records. Camera-only,
/// like photos: there's no way to bring in an existing video.
struct VideoCaptureView: View {
    var onCapture: (PreparedClip) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var recorder = VideoRecorder()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if case .unavailable(let reason) = recorder.state {
                Text(reason)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(32)
            } else {
                CameraPreview(session: recorder.session)
                    .ignoresSafeArea()
            }
            controls
        }
        .task {
            recorder.onFinish = { clip in
                onCapture(clip)
                dismiss()
            }
            await recorder.start()
        }
        .onDisappear { recorder.shutDown() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { recorder.discard() }
        }
    }

    private var isRecording: Bool { recorder.state == .recording || recorder.state == .finishing }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                Button {
                    recorder.discard()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel("Cancel")
                Spacer()
                Button {
                    Task { await recorder.flip() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .disabled(recorder.state != .ready)
                .opacity(recorder.state == .ready ? 1 : 0.4)
                .accessibilityLabel(recorder.position == .back ? "Switch to the front camera" : "Switch to the back camera")
            }
            .padding(.horizontal, 20)

            Spacer()

            if let notice = recorder.notice {
                Text(notice)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
            } else if recorder.state == .ready, !recorder.hasAudio {
                Label("No sound: microphone access is off for HuddlePals", systemImage: "mic.slash.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
            }

            RecordButton(progress: recorder.elapsed / HuddleLimits.maxVideoDuration, isRecording: isRecording) {
                if isRecording { recorder.stop() } else { recorder.record() }
            }
            .disabled(recorder.state != .ready && recorder.state != .recording)
            .accessibilityLabel(isRecording ? "Stop recording" : "Record video")
            .accessibilityValue("\(Int(recorder.elapsed)) of \(Int(HuddleLimits.maxVideoDuration)) seconds")

            Text(isRecording ? String(format: "0:%02d", min(Int(recorder.elapsed), Int(HuddleLimits.maxVideoDuration))) : "Up to \(Int(HuddleLimits.maxVideoDuration)) seconds")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.bottom, 24)
        }
    }
}

/// A ring that fills over the 6 seconds around a red record button, which
/// turns into a stop square while recording.
private struct RecordButton: View {
    let progress: Double
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.4), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: progress)
                RoundedRectangle(cornerRadius: isRecording ? 8 : 30, style: .continuous)
                    .fill(Color.red)
                    .frame(width: isRecording ? 30 : 60, height: isRecording ? 30 : 60)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isRecording)
            }
            .frame(width: 82, height: 82)
        }
        .buttonStyle(.plain)
    }
}

/// The camera's live picture, portrait.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The connection exists once the session has a camera.
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }
}

#if DEBUG
/// Stands in for the video camera in UI tests (the Simulator has none): one
/// button that "records" a generated 2-second clip.
struct FakeVideoCameraView: View {
    var onCapture: (PreparedClip) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isRecording = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Test video camera")
                .font(.headline)
            Button("Record test video") {
                isRecording = true
                Task {
                    if let clip = try? await ClipPreparer.placeholder(seed: 7) {
                        onCapture(clip)
                    }
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRecording)
            Button("Cancel") { dismiss() }
        }
    }
}
#endif
