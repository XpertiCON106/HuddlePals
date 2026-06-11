import SwiftUI
import PhotosUI

/// The deposit sheet. Target: under 15 seconds — pick, optionally caption,
/// deposit. Also serves backfill ("add to yesterday") from the archive.
struct ComposeView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss

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
            .navigationTitle(viewModel?.isBackfill == true ? "Add to yesterday" : "Today's deposit")
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
                viewModel = ComposeViewModel(deps: deps, targetDayKey: targetDayKey)
                // Friction killer: open the picker immediately.
                showPicker = true
            }
        }
    }
}

private struct ComposeContent: View {
    @Bindable var viewModel: ComposeViewModel
    @Binding var showPicker: Bool
    let onSuccess: () -> Void

    @FocusState private var captionFocused: Bool

    var body: some View {
        VStack(spacing: 18) {
            photoArea
                .padding(.top, 12)

            CaptionTextField(text: $viewModel.caption)
                .focused($captionFocused)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.destructive)
            }

            Spacer()

            PrimaryButton(
                title: viewModel.isBackfill ? "Deposit to yesterday" : "Deposit",
                systemImage: "lock.open.fill",
                isLoading: viewModel.isSaving,
                isEnabled: viewModel.canDeposit
            ) {
                captionFocused = false
                Task {
                    if await viewModel.deposit() {
                        onSuccess()
                    }
                }
            }
        }
        .padding(Theme.screenPadding)
        .photosPicker(isPresented: $showPicker, selection: $viewModel.photoItem, matching: .images)
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
                            Image(systemName: "arrow.triangle.2.circlepath")
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
                    Text("Pick today's photo")
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
}
