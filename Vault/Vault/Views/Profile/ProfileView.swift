import SwiftUI
import PhotosUI
import UIKit

/// Your own profile: up to 3 photos, display name, bio, identity color,
/// daily reminder, appearance setting, account, and (mock only) the DEBUG
/// tools.
struct ProfileView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: ProfileViewModel?

    var body: some View {
        Group {
            if let viewModel {
                ProfileContent(viewModel: viewModel) {
                    router.resetAll()
                }
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .navigationTitle("Profile")
        .toolbarBackground(Theme.background, for: .navigationBar)
        .onAppear {
            if viewModel == nil { viewModel = ProfileViewModel(deps: deps) }
        }
    }
}

private struct ProfileContent: View {
    @Bindable var viewModel: ProfileViewModel
    let onSignOut: () -> Void

    @State private var showSignOutConfirmation = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        List {
            photosSection
            identitySection
            reminderSection
            appearanceSection
            accountSection
            if !viewModel.isLiveBackend {
                debugSection
            }
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .task { await viewModel.refreshReminderStatus() }
        .confirmationDialog(
            "Sign out?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                Task {
                    await viewModel.signOut()
                    onSignOut()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can sign back in any time with the same Apple ID, email, or phone number.")
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                Task {
                    if await viewModel.deleteAccount() { onSignOut() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your account, name, and profile photos are permanently removed and you're signed out. Photos you already deposited stay in your shared vaults as \"Former member\" — a vault's archive is permanent. This can't be undone.")
        }
    }

    private var photosSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(viewModel.photoPaths.enumerated()), id: \.element) { index, path in
                        LocalDepositImage(relativePath: path)
                            .frame(width: 92, height: 122)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    viewModel.removePhoto(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                }
                                .padding(5)
                            }
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                    if viewModel.canAddPhotos {
                        PhotosPicker(
                            selection: $viewModel.photoItems,
                            maxSelectionCount: AuthValidation.maxProfilePhotos - viewModel.photoPaths.count,
                            matching: .images
                        ) {
                            VStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 20, weight: .semibold))
                                Text("Add")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 92, height: 122)
                            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [5]))
                            )
                        }
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.photoPaths)
            }
            .listRowBackground(Theme.surface)
        } header: {
            Text("Profile photos")
        } footer: {
            Text("Up to 3 photos — the first is your profile picture and appears as your avatar. Everyone you share a vault with can see them.")
        }
    }

    private var identitySection: some View {
        Section("Identity") {
            HStack(spacing: 14) {
                AvatarView(
                    name: viewModel.displayName.isEmpty ? "?" : viewModel.displayName,
                    colorHex: viewModel.selectedColorHex,
                    imagePath: viewModel.photoPaths.first,
                    size: 52
                )
                TextField("Display name", text: $viewModel.displayName)
                    .font(.system(size: 17, weight: .medium))
            }
            .listRowBackground(Theme.surface)

            VStack(alignment: .trailing, spacing: 4) {
                TextField("A short bio…", text: $viewModel.bio, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(2...4)
                    .onChange(of: viewModel.bio) { _, newValue in
                        if newValue.count > AuthValidation.bioLimit {
                            viewModel.bio = String(newValue.prefix(AuthValidation.bioLimit))
                        }
                    }
                if viewModel.bio.count > AuthValidation.bioLimit - 30 {
                    Text("\(viewModel.bioRemaining)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)

            ColorRampPicker(selection: $viewModel.selectedColorHex, singleLine: true)
                .padding(.vertical, 4)
                .listRowBackground(Theme.surface)

            Button {
                Task { await viewModel.saveProfile() }
            } label: {
                HStack {
                    Text("Save changes")
                    if let status = viewModel.statusMessage {
                        Spacer()
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .disabled(viewModel.isWorking)
            .listRowBackground(Theme.surface)
        }
    }

    private var reminderSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { viewModel.reminderEnabled },
                set: { newValue in Task { await viewModel.setReminderEnabled(newValue) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily upload reminder")
                    Text("A nudge to add today's photo, with a gentle follow-up if you forget.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)

            if viewModel.reminderEnabled {
                DatePicker(
                    "Reminder time",
                    selection: Binding(
                        get: { viewModel.reminderTime },
                        set: { newValue in Task { await viewModel.setReminderTime(newValue) } }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .listRowBackground(Theme.surface)
            }

            if viewModel.reminderPermissionDenied {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Notifications are turned off", systemImage: "bell.slash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.destructive)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
                .listRowBackground(Theme.surface)
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Reminders are sent only on days you haven't uploaded yet, and stop once you do.")
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $viewModel.appearance) {
                ForEach(AppearancePreference.allCases) { preference in
                    Text(preference.label).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Theme.surface)
        } header: {
            Text("Appearance")
        } footer: {
            Text("System follows your device's light/dark setting.")
        }
    }

    private var accountSection: some View {
        Section("Account") {
            Button {
                showSignOutConfirmation = true
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    .foregroundStyle(Theme.textPrimary)
            }
            .listRowBackground(Theme.surface)

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete account", systemImage: "trash")
            }
            .disabled(viewModel.isWorking)
            .listRowBackground(Theme.surface)
        }
    }

    private var debugSection: some View {
        Section {
            Toggle(isOn: $viewModel.simulateNotPostedToday) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simulate: I haven't posted today")
                    Text("Forces the reciprocity gate shut to demo the locked state.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)

            Button {
                Task { await viewModel.advanceMockDay() }
            } label: {
                HStack {
                    Label("Advance mock day by 1", systemImage: "calendar.badge.plus")
                    Spacer()
                    Text("+\(viewModel.mockDayOffset)d")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(viewModel.mockDayOffset > 0 ? Theme.accent : Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)

            Button {
                Task { await viewModel.regenerateSeedData() }
            } label: {
                Label("Regenerate seed data", systemImage: "arrow.clockwise.circle")
            }
            .disabled(viewModel.isWorking)
            .listRowBackground(Theme.surface)
        } header: {
            Label("DEBUG", systemImage: "wrench.and.screwdriver")
                .foregroundStyle(Theme.accent)
        } footer: {
            Text("Demo tools — none of this ships. Advancing the day shifts the injected clock so streak math and the recovery window can be exercised without waiting for midnight.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(viewModel.appVersion)
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)
        }
    }
}
