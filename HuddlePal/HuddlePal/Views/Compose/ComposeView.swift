import SwiftUI

/// The deposit sheet, in two stages: capture a photo with the camera, then
/// face the permanence gate — "This is permanent — post it?" Camera-only:
/// there is no way to import an existing photo into this flow. Once posted,
/// the photo can never be deleted, edited, or replaced.
struct ComposeView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss

    let huddle: Huddle
    var targetDayKey: String?
    /// Called with `true` after a successful deposit, after dismissal.
    var onComplete: (Bool) -> Void = { _ in }

    @State private var viewModel: ComposeViewModel?
    @State private var showCamera = false

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    ComposeContent(viewModel: viewModel, showCamera: $showCamera) {
                        dismiss()
                        onComplete(true)
                    }
                } else {
                    Color.clear
                }
            }
            .background(Theme.background)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                        onComplete(false)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    // Once posting starts it can't be called back: the
                    // photo becomes permanent either way, so the sheet must
                    // stay to report the result.
                    .disabled(viewModel?.isSaving ?? false)
                }
            }
        }
        .interactiveDismissDisabled(viewModel?.isSaving ?? false)
        .fullScreenCover(isPresented: $showCamera) {
            if viewModel?.medium == .video {
                videoCamera
            } else {
                photoCamera
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = ComposeViewModel(deps: deps, huddle: huddle, targetDayKey: targetDayKey)
                // Open the camera immediately (when there is one — the
                // Simulator has none).
                showCamera = CameraPicker.availability() == .ready
            }
        }
    }

    private var navigationTitle: String {
        guard let viewModel else { return "" }
        if viewModel.stage == .confirm { return "Last look" }
        return viewModel.isBackfill ? "Yesterday's photo" : "Today's deposit"
    }

    @ViewBuilder
    private var photoCamera: some View {
        #if DEBUG
        if UITestHooks.fakeCamera {
            FakeCameraView { image in viewModel?.setCapturedImage(image) }
        } else {
            CameraPicker { image in
                viewModel?.setCapturedImage(image)
            }
            .ignoresSafeArea()
        }
        #else
        CameraPicker { image in
            viewModel?.setCapturedImage(image)
        }
        .ignoresSafeArea()
        #endif
    }

    @ViewBuilder
    private var videoCamera: some View {
        #if DEBUG
        if UITestHooks.fakeCamera {
            FakeVideoCameraView { clip in viewModel?.setCapturedVideo(clip) }
        } else {
            VideoCaptureView { clip in viewModel?.setCapturedVideo(clip) }
        }
        #else
        VideoCaptureView { clip in viewModel?.setCapturedVideo(clip) }
        #endif
    }
}

private struct ComposeContent: View {
    @Bindable var viewModel: ComposeViewModel
    @Binding var showCamera: Bool
    let onSuccess: () -> Void

    @FocusState private var captionFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var camera = CameraPicker.availability()
    @State private var paywall: PaywallContext?

    var body: some View {
        Group {
            switch viewModel.stage {
            case .pick:
                pickStage
            case .confirm:
                confirmStage
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.stage)
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings with camera access turned on.
            if phase == .active { camera = CameraPicker.availability() }
        }
        .sheet(item: $paywall, onDismiss: {
            // Bought Plus from the Video switch: straight to the video camera.
            // (A clip kept because Plus had ended just posts now.)
            if viewModel.canRecordVideo, viewModel.medium == .photo, viewModel.clip == nil {
                viewModel.choose(.video)
                if camera == .ready { showCamera = true }
            }
        }) { context in
            PaywallView(context: context)
        }
    }

    // MARK: Stage 1 — capture

    private var pickStage: some View {
        VStack(spacing: 18) {
            mediumPicker
                .padding(.top, 12)

            photoArea

            CaptionTextField(text: $viewModel.caption)
                .focused($captionFocused)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.destructive)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            PrimaryButton(
                title: "Continue",
                systemImage: "arrow.right",
                isEnabled: viewModel.canContinue
            ) {
                captionFocused = false
                viewModel.continueToConfirm()
            }
        }
        .padding(Theme.screenPadding)
    }

    /// Photo or video: switching opens that camera. Video is Plus; without
    /// it the switch opens the paywall and stays on Photo.
    private var mediumPicker: some View {
        Picker("Today's deposit", selection: Binding(
            get: { viewModel.medium },
            set: { medium in
                if medium == .video, !viewModel.canRecordVideo {
                    paywall = .video
                    return
                }
                viewModel.choose(medium)
                if camera == .ready { showCamera = true }
            }
        )) {
            Label("Photo", systemImage: "camera.fill").tag(ComposeViewModel.Medium.photo)
            Label(viewModel.canRecordVideo ? "Video" : "Video · Plus", systemImage: "video.fill")
                .tag(ComposeViewModel.Medium.video)
        }
        .pickerStyle(.segmented)
        .disabled(viewModel.isSaving)
    }

    private var photoArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(Theme.surface)
                .strokeBorder(Theme.hairline, lineWidth: 1)
                .aspectRatio(3 / 4, contentMode: .fit)

            if let clip = viewModel.clip {
                Self.framed { ClipPreview(clip: clip) }
                    .overlay(alignment: .bottomTrailing) {
                        Button {
                            showCamera = true
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .accessibilityLabel("Record again")
                        .padding(12)
                    }
            } else if let image = viewModel.previewImage {
                Self.framed {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .accessibilityLabel("Your photo")
                }
                    .overlay(alignment: .bottomTrailing) {
                        Button {
                            showCamera = true
                        } label: {
                            Image(systemName: "camera.rotate")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .accessibilityLabel("Retake photo")
                        .padding(12)
                    }
            } else {
                emptyCapturePrompt
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .onTapGesture {
            if viewModel.previewImage == nil, viewModel.clip == nil, camera == .ready { showCamera = true }
        }
    }

    @ViewBuilder
    private var emptyCapturePrompt: some View {
        switch camera {
        case .ready:
            VStack(spacing: 16) {
                Image(systemName: viewModel.medium == .video ? "video.fill" : "camera.fill")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text(viewModel.medium == .video ? "Record today's video, up to 6 seconds" : "Take today's photo")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Button {
                    showCamera = true
                } label: {
                    Label("Open camera", systemImage: viewModel.medium == .video ? "video" : "camera")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.surfaceElevated, in: Capsule())
                }
            }
        case .denied:
            cameraUnavailable(
                symbol: "camera.fill",
                title: "Camera access is off",
                message: "HuddlePals takes today's photo in the moment, with your camera. Turn on Camera for HuddlePals in Settings."
            ) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Label("Open Settings", systemImage: "gear")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.surfaceElevated, in: Capsule())
                }
            }
        case .restricted:
            cameraUnavailable(
                symbol: "lock.fill",
                title: "The camera is restricted",
                message: "Screen Time or a device profile blocks the camera on this iPhone, so today's photo can't be taken here."
            ) { EmptyView() }
        case .noCamera:
            cameraUnavailable(
                symbol: "camera.metering.unknown",
                title: "No camera available",
                message: "HuddlePals captures today's photo with your camera. Run this on a device to deposit."
            ) { EmptyView() }
        }
    }

    private func cameraUnavailable<Action: View>(
        symbol: String,
        title: String,
        message: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            action()
        }
    }

    /// A 3:4 card the picture fills. Only the frame takes part in layout, so
    /// a picture of another shape (a video is 9:16) can't make the card
    /// taller and push the buttons off the screen, and on a small phone the
    /// card shrinks to make room for them.
    private static func framed<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay { content() }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
    }

    // MARK: Stage 2 — the permanence gate

    private var confirmStage: some View {
        VStack(spacing: 18) {
            if let clip = viewModel.clip {
                Self.framed { ClipPreview(clip: clip) }
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
                    .padding(.top, 12)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            } else if let image = viewModel.previewImage {
                Self.framed {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .accessibilityLabel("Your photo")
                }
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
                    .padding(.top, 12)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }

            if !viewModel.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(viewModel.caption)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 6) {
                Label("This is permanent", systemImage: "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Once posted it joins the huddle forever — no edits, no deletes, no retakes.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.destructive)
                    .multilineTextAlignment(.center)
            }

            if viewModel.videoNeedsPlus {
                HStack(spacing: 10) {
                    Button {
                        viewModel.takePhotoInstead()
                        if camera == .ready { showCamera = true }
                    } label: {
                        Label("Take a photo instead", systemImage: "camera")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Theme.surfaceElevated, in: Capsule())
                    }
                    Button {
                        paywall = .video
                    } label: {
                        Label("Renew Plus", systemImage: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Theme.surfaceElevated, in: Capsule())
                    }
                }
            }

            Spacer()

            PrimaryButton(
                title: viewModel.isBackfill ? "Post to yesterday — forever" : "Post it — forever",
                systemImage: "lock.open.fill",
                isLoading: viewModel.isSaving
            ) {
                Task {
                    if await viewModel.confirmAndPost() {
                        onSuccess()
                    }
                }
            }
        }
        .padding(Theme.screenPadding)
    }
}
