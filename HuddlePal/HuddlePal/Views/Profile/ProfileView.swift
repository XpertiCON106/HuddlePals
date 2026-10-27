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
    @State private var navigationGuardID = UUID()

    var body: some View {
        Group {
            if let viewModel {
                ProfileContent(
                    viewModel: viewModel,
                    onCompleteExit: { completeExit($0, using: viewModel) }
                )
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .navigationTitle("Profile")
        .toolbarBackground(Theme.background, for: .navigationBar)
        // The guard stays while this tab exists, including while another tab
        // is showing: the router consults it only when leaving Profile, and
        // removing it on disappear let a tab switch that the tab bar had
        // already started slip past it. Sign-out resets the router.
        .onAppear {
            installNavigationGuard()
        }
    }

    private func installNavigationGuard() {
        let model = viewModel ?? ProfileViewModel(deps: deps)
        viewModel = model
        router.installProfileNavigationGuard(id: navigationGuardID) { [weak model] in
            model?.requestNavigation() ?? true
        }
    }

    private func completeExit(
        _ action: ProfileViewModel.ExitAction,
        using viewModel: ProfileViewModel
    ) {
        switch action {
        case .signOut:
            Task {
                await viewModel.signOut()
                router.resetAll()
            }
        case .deleteAccount:
            Task {
                if await viewModel.deleteAccount() { router.resetAll() }
            }
        case .deleteAccountWithoutApple:
            Task {
                if await viewModel.deleteAccountWithoutApple() { router.resetAll() }
            }
        }
    }
}

private struct ProfileContent: View {
    @Environment(AppRouter.self) private var router
    @Bindable var viewModel: ProfileViewModel
    let onCompleteExit: (ProfileViewModel.ExitAction) -> Void

    @State private var showSignOutConfirmation = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        List {
            photosSection
            identitySection
            notificationsSection
            reminderSection
            appearanceSection
            if let code = viewModel.keyCode {
                keyCodeSection(code)
            }
            accountSection
            #if DEBUG
            // Compile-time gated on top of the runtime backend check: the
            // demo tooling must not exist in a Release binary at all, even
            // one accidentally archived without a Supabase.plist.
            if !viewModel.isLiveBackend {
                debugSection
            }
            #endif
            aboutSection
        }
        .scrollContentBackground(.hidden)
        // The bio is multi-line (Return adds a line), so scrolling is how the
        // keyboard goes away; without this it stayed over the tab bar.
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.background)
        .overlay {
            if viewModel.isLoading {
                ProgressView()
                    .accessibilityLabel("Loading profile")
            }
        }
        .task {
            await viewModel.loadInitialState()
            await viewModel.refreshReminderStatus()
            await viewModel.loadKeyCode()
        }
        .alert(
            "Confirm Changes",
            isPresented: $viewModel.isSaveConfirmationPresented
        ) {
            Button("Save Changes") {
                saveConfirmedDraft()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelSaveConfirmation()
            }
        } message: {
            Text("Are you sure you want to save these changes to your profile?")
        }
        .alert(
            "Unsaved Changes",
            isPresented: $viewModel.isUnsavedChangesWarningPresented
        ) {
            if viewModel.canSaveFromWarning {
                Button("Save Changes") {
                    Task {
                        if await viewModel.saveFromWarning() {
                            router.resumeBlockedNavigation()
                        } else {
                            router.cancelBlockedNavigation()
                        }
                    }
                }
            }
            Button("Discard Changes", role: .destructive) {
                viewModel.discardChanges()
                router.resumeBlockedNavigation()
            }
            Button("Keep Editing", role: .cancel) {
                viewModel.keepEditing()
                router.cancelBlockedNavigation()
            }
        } message: {
            Text("Save or discard your profile changes before you leave.")
        }
        .confirmationDialog(
            "Sign out?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                if let action = viewModel.requestExit(.signOut) {
                    onCompleteExit(action)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                FeatureFlags.emailAndPhoneSignInEnabled
                    ? "You can sign back in any time with the same Apple ID, email, or phone number."
                    : "You can sign back in any time with the same Apple ID."
            )
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                if let action = viewModel.requestExit(.deleteAccount) {
                    onCompleteExit(action)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your account, name, and profile photos are permanently removed and you're signed out. Photos you already deposited stay in your shared huddles as \"Former member\" — a huddle's archive is permanent. This can't be undone.")
        }
        .confirmationDialog(
            "Apple couldn't confirm it's you",
            isPresented: $viewModel.isAppleConfirmationFailurePresented,
            titleVisibility: .visible
        ) {
            Button("Delete account anyway", role: .destructive) {
                if let action = viewModel.requestExit(.deleteAccountWithoutApple) {
                    onCompleteExit(action)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can still delete your account. Afterwards, remove HuddlePals in Settings › your name › Sign-In & Security › Sign in with Apple.")
        }
    }

    private func saveConfirmedDraft() {
        Task {
            _ = await viewModel.confirmAndSave()
        }
    }

    private var photosSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(viewModel.draftPhotos.enumerated()), id: \.element.id) { index, photo in
                        // 122pt tile → 380px covers @3x displays.
                        ProfileDraftPhotoImage(photo: photo)
                            .frame(width: 92, height: 122)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    viewModel.removePhoto(at: index)
                                } label: {
                                    // Padded inside the label so the tap
                                    // target is ~44pt, not the 18pt glyph.
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                        .padding(12)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("Remove photo")
                                .disabled(viewModel.isWorking)
                            }
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                    if viewModel.canAddPhotos {
                        PhotosPicker(
                            selection: $viewModel.photoItems,
                            maxSelectionCount: AuthValidation.maxProfilePhotos - viewModel.draftPhotos.count,
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
                        .disabled(viewModel.isWorking)
                    }
                }
                .animation(
                    .spring(response: 0.35, dampingFraction: 0.8),
                    value: viewModel.draftPhotos.map(\.canonicalReference)
                )
            }
            .listRowBackground(Theme.surface)
        } header: {
            Text("Profile photos")
        } footer: {
            Text("Up to 3 photos — the first is your profile picture and appears as your avatar. Everyone you share a huddle with can see them.")
        }
    }

    private var identitySection: some View {
        Section("Identity") {
            HStack(spacing: 14) {
                AvatarView(
                    name: viewModel.displayName.isEmpty ? "?" : viewModel.displayName,
                    colorHex: viewModel.selectedColorHex,
                    imagePath: viewModel.draftPhotos.first?.persistedPath,
                    imageData: viewModel.draftPhotos.first?.previewData,
                    size: 52
                )
                TextField("Display name", text: $viewModel.displayName)
                    .font(.system(size: 17, weight: .medium))
                    .disabled(viewModel.isWorking)
                    .onChange(of: viewModel.displayName) { _, newValue in
                        if newValue.serverLength > TextLimit.displayName {
                            viewModel.displayName = newValue.prefix(serverLength: TextLimit.displayName)
                        }
                    }
            }
            .listRowBackground(Theme.surface)

            VStack(alignment: .trailing, spacing: 4) {
                TextField("A short bio…", text: $viewModel.bio, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(2...4)
                    .disabled(viewModel.isWorking)
                    .onChange(of: viewModel.bio) { _, newValue in
                        if newValue.serverLength > AuthValidation.bioLimit {
                            viewModel.bio = newValue.prefix(serverLength: AuthValidation.bioLimit)
                        }
                    }
                if viewModel.bio.serverLength > AuthValidation.bioLimit - 30 {
                    Text("\(viewModel.bioRemaining)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)

            ColorRampPicker(selection: $viewModel.selectedColorHex, singleLine: true)
                .padding(.vertical, 4)
                .allowsHitTesting(!viewModel.isWorking)
                .opacity(viewModel.isWorking ? 0.6 : 1)
                .listRowBackground(Theme.surface)

            Button {
                viewModel.requestSaveConfirmation()
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
            .disabled(!viewModel.canSaveChanges)
            .accessibilityHint(
                viewModel.hasUnsavedChanges
                    ? "Presents a confirmation before saving your profile."
                    : "Make a profile change to enable this button."
            )
            .listRowBackground(Theme.surface)
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { viewModel.pushEnabled },
                set: { newValue in Task { await viewModel.setPushEnabled(newValue) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Huddle activity")
                    Text("New photos, comments and reactions on your photos, and new members.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)

            if viewModel.pushPermissionDenied {
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
            Text("Notifications")
        } footer: {
            Text("For this device. Notifications name the huddle and who posted, never what a photo shows.")
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

    private func keyCodeSection(_ code: String) -> some View {
        Section {
            Text(KeyCode.twoLines(code))
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .textSelection(.enabled)
                .accessibilityLabel("Key code \(code)")
                .accessibilityIdentifier("keyCode")
                .listRowBackground(Theme.surface)
        } header: {
            Text("Key code")
        } footer: {
            Text("If someone in a huddle asks for your key code, read this to them in person or on a call. It lets them check it's really you before they share the huddle's key with this phone.")
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

    #if DEBUG
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

            Toggle(isOn: $viewModel.simulateFreeLimits) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free plan limits")
                    Text("3 huddles kept, 4 members, invites paused past the first 3, the 30-day archive. Off: the old rules, as the server ships.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)

            Toggle(isOn: $viewModel.simulatePlus) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simulate: HuddlePals Plus")
                    if let until = viewModel.simulatedPlusUntil {
                        Text("Ends \(until, format: .dateTime.hour().minute().second())")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("10 huddles of up to 10, video drops, the whole archive.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .listRowBackground(Theme.surface)

            Button {
                viewModel.plusExpiresInAMinute()
            } label: {
                Label("Plus that ends in a minute", systemImage: "timer")
            }
            .listRowBackground(Theme.surface)

            Toggle(isOn: $viewModel.simulatePurchasesLinkedElsewhere) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simulate: subscription linked elsewhere")
                    Text("Buying or restoring Plus finds it already linked to another account.")
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
    #endif

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(viewModel.appVersion)
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)

            NavigationLink {
                TermsReaderView(acceptedAt: viewModel.termsAcceptedAt)
            } label: {
                Text("Terms of Service")
            }
            .listRowBackground(Theme.surface)

            externalLink("Privacy Policy", to: AppLinks.privacyPolicy)
            externalLink("Help & Support", to: AppLinks.support)
            externalLink("Contact Us", detail: AppLinks.contactEmail, to: AppLinks.contact)
            externalLink("HuddlePals Website", to: AppLinks.website)
        }
    }

    /// A row that leaves the app (Safari or Mail), marked with ↗.
    private func externalLink(_ title: String, detail: String? = nil, to url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Text(title)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .listRowBackground(Theme.surface)
    }
}

/// Draft-aware profile tile. Persisted photos retain the existing cache-first
/// loader; staged photos render directly from memory and therefore cannot be
/// mistaken for an already-committed profile update.
private struct ProfileDraftPhotoImage: View {
    let photo: ProfilePhotoDraft

    var body: some View {
        Group {
            if let data = photo.previewData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityLabel("New profile photo, not saved yet")
            } else if let path = photo.persistedPath {
                LocalDepositImage(relativePath: path, maxPixelSize: 380)
            } else {
                Theme.surfaceElevated
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityHidden(true)
                    }
            }
        }
        .clipped()
    }
}
