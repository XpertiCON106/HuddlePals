import SwiftUI

/// The deposit sheet, in two stages: capture a photo with the camera, then
/// face the permanence gate — "This is permanent — post it?" Camera-only:
/// there is no way to import an existing photo into this flow. Once posted,
/// the photo can never be deleted, edited, or replaced.
struct ComposeView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss

    let vault: Vault
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
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                viewModel?.setCapturedImage(image)
            }
            .ignoresSafeArea()
        }
        .onAppear {
            if viewModel == nil {
                viewModel = ComposeViewModel(deps: deps, vault: vault, targetDayKey: targetDayKey)
                // Friction killer: open the camera immediately (when there
                // is one — the Simulator has none).
                showCamera = CameraPicker.isAvailable
            }
        }
    }

    private var navigationTitle: String {
        guard let viewModel else { return "" }
        if viewModel.stage == .confirm { return "Last look" }
        return viewModel.isBackfill ? "Yesterday's photo" : "Today's deposit"
    }
}

private struct ComposeContent: View {
    @Bindable var viewModel: ComposeViewModel
    @Binding var showCamera: Bool
    let onSuccess: () -> Void

    @FocusState private var captionFocused: Bool

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
    }

    // MARK: Stage 1 — capture

    private var pickStage: some View {
        VStack(spacing: 18) {
            photoArea
                .padding(.top, 12)

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

    private var photoArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(Theme.surface)
                .strokeBorder(Theme.hairline, lineWidth: 1)
                .aspectRatio(3 / 4, contentMode: .fit)

            if let image = viewModel.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
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
                        .padding(12)
                    }
            } else {
                emptyCapturePrompt
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .onTapGesture {
            if viewModel.previewImage == nil, CameraPicker.isAvailable { showCamera = true }
        }
    }

    @ViewBuilder
    private var emptyCapturePrompt: some View {
        if CameraPicker.isAvailable {
            VStack(spacing: 16) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Take today's photo")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Button {
                    showCamera = true
                } label: {
                    Label("Open camera", systemImage: "camera")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.surfaceElevated, in: Capsule())
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "camera.metering.unknown")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
                Text("No camera available")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("Vault captures today's photo with your camera. Run this on a device to deposit.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    // MARK: Stage 2 — the permanence gate

    private var confirmStage: some View {
        VStack(spacing: 18) {
            if let image = viewModel.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
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
                Text("Once posted it joins the vault forever — no edits, no deletes, no retakes.")
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
