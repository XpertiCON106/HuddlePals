import SwiftUI
import PhotosUI

/// The deposit sheet, in two stages: pick a photo, then face the
/// permanence gate — "This is permanent — post it?" Once posted, the photo
/// can never be deleted, edited, or replaced.
struct ComposeView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss

    let vault: Vault
    var targetDayKey: String?
    /// Called with `true` after a successful deposit, after dismissal.
    var onComplete: (Bool) -> Void = { _ in }

    @State private var viewModel: ComposeViewModel?
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    ComposeContent(viewModel: viewModel, showPicker: $showPicker) {
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
        .onAppear {
            if viewModel == nil {
                viewModel = ComposeViewModel(deps: deps, vault: vault, targetDayKey: targetDayKey)
                // Friction killer: open the picker immediately.
                showPicker = true
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
    @Binding var showPicker: Bool
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
        .photosPicker(isPresented: $showPicker, selection: $viewModel.photoItem, matching: .images)
    }

    // MARK: Stage 1 — pick

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
                            showPicker = true
                        } label: {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .padding(12)
                    }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(Theme.accent)
                    Text("Pick the photo")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)

                    HStack(spacing: 14) {
                        pickerChip(label: "Library", systemImage: "photo.on.rectangle")
                        // Camera routes to the picker too — simulators have
                        // no camera, and MVP keeps a single ingest path.
                        pickerChip(label: "Camera", systemImage: "camera")
                    }
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .onTapGesture {
            if viewModel.previewImage == nil { showPicker = true }
        }
    }

    private func pickerChip(label: String, systemImage: String) -> some View {
        Button {
            showPicker = true
        } label: {
            Label(label, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.surfaceElevated, in: Capsule())
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
