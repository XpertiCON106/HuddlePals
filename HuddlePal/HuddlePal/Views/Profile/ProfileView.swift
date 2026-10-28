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
        // With unsaved changes, Back asks first: the system Back button (and
        // with it the swipe back) gives way to one that goes through the
        // router's guard, which shows the warning instead of leaving.
        .navigationBarBackButtonHidden(viewModel?.hasUnsavedChanges ?? false)
        .toolbar {
            if viewModel?.hasUnsavedChanges ?? false {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        router.leaveProfile()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
        // The router consults the guard whenever Profile is on top of the
        // stack (back, a notification, an invite link). Sign-out resets it.
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
        }
    }
}

private struct ProfileContent: View {
    @Environment(AppRouter.self) private var router
    @Bindable var viewModel: ProfileViewModel
    let onCompleteExit: (ProfileViewModel.ExitAction) -> Void

    @State private var showSignOutConfirmation = false
    @State private var showReminderTime = false
    @State private var pickedReminderTime = Date.now
    @State private var showManageSubscription = false
    @State private var showPaywall = false

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
            plusSection
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
                HuddleSpinner(label: "Loading profile")
            }
        }
        .task {
            await viewModel.loadInitialState()
            await viewModel.loadBirthday()
            await viewModel.refreshReminderStatus()
            await viewModel.loadKeyCode()
        }
        .appDialog(
            "Save your changes?",
            isPresented: $viewModel.isSaveConfirmationPresented,
            message: "Your profile updates for everyone you share a huddle with.",
            actions: [
                DialogAction("Save Changes") { saveConfirmedDraft() },
                .cancel { viewModel.cancelSaveConfirmation() },
            ]
        )
        .appDialog(
            "Unsaved Changes",
            isPresented: $viewModel.isUnsavedChangesWarningPresented,
            message: "Save or discard your profile changes before you leave.",
            actions: unsavedChangesActions
        )
        .appDialog(
            "Sign out?",
            isPresented: $showSignOutConfirmation,
            message: FeatureFlags.emailAndPhoneSignInEnabled
                ? "You can sign back in any time with the same Apple ID, email, or phone number."
                : "You can sign back in any time with the same Apple ID.",
            actions: [
                DialogAction("Sign out", role: .destructive) {
                    if let action = viewModel.requestExit(.signOut) {
                        onCompleteExit(action)
                    }
                },
                .cancel(),
            ]
        )
        .appDialog(
            "Reminder time",
            isPresented: $showReminderTime,
            message: "When your daily upload reminder comes.",
            actions: [
                DialogAction("Done") {
                    Task { await viewModel.setReminderTime(pickedReminderTime) }
                },
                .cancel(),
            ]
        ) {
            DatePicker("Reminder time", selection: $pickedReminderTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(height: 150)
        }
        .manageSubscriptionsSheet(isPresented: $showManageSubscription)
        .sheet(isPresented: $showPaywall) {
            PaywallView(context: .profile)
        }
    }

    /// Save (when the draft can be saved), Discard, or Keep Editing; the
    /// first two go on to wherever the person was headed.
    private var unsavedChangesActions: [DialogAction] {
        var actions: [DialogAction] = []
        if viewModel.canSaveFromWarning {
            actions.append(DialogAction("Save Changes") {
                Task {
                    if await viewModel.saveFromWarning() {
                        router.resumeBlockedNavigation()
                    } else {
                        router.cancelBlockedNavigation()
                    }
                }
            })
        }
        actions.append(DialogAction("Discard Changes", role: .destructive) {
            viewModel.discardChanges()
            router.resumeBlockedNavigation()
        })
        actions.append(DialogAction("Keep Editing", role: .cancel) {
            viewModel.keepEditing()
            router.cancelBlockedNavigation()
        })
        return actions
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
                                .allowsHitTesting(!viewModel.isWorking)
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
                        .allowsHitTesting(!viewModel.isWorking)
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
                    imageData: viewModel.draftPhotos.first?.displayData,
                    size: 52
                )
                TextField("Display name", text: $viewModel.displayName)
                    .font(.system(size: 17, weight: .medium))
                    .allowsHitTesting(!viewModel.isWorking)
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
                    .allowsHitTesting(!viewModel.isWorking)
                    .onChange(of: viewModel.bio) { _, newValue in
                        if newValue.serverLength > AuthValidation.bioLimit {
                            viewModel.bio = newValue.prefix(serverLength: AuthValidation.bioLimit)
                        }
                    }
                if viewModel.bio.serverLength > AuthValidation.bioLimit - 15 {
                    Text("\(viewModel.bioRemaining)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)

            // Given when the profile was made, and only shown here: it
            // can't be changed after sign-up.
            if let birthday = viewModel.birthday {
                HStack(spacing: 8) {
                    Text("Birthday")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(birthday.formatted())
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Birthday")
                .accessibilityValue(birthday.formatted())
                .accessibilityHint("Only you can see it.")
                .accessibilityIdentifier("birthdayRow")
                .listRowBackground(Theme.surface)
            }

            // A profile picture is the avatar: the colour choices come back
            // when it's removed. (The colour itself stays, for the places
            // that use it.) While a save runs, the editor ignores taps but
            // looks the same: dimming it made the rows blink on every save.
            if viewModel.draftPhotos.isEmpty {
                ColorRampPicker(selection: $viewModel.selectedColorHex, singleLine: true)
                    .padding(.vertical, 4)
                    .allowsHitTesting(!viewModel.isWorking)
                    .listRowBackground(Theme.surface)
            }

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
                    Text("New photos and videos, comments and reactions on yours, and new members.")
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
            Text("For this device. Notifications name the huddle and who posted, never what a photo or video shows.")
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
                Button {
                    pickedReminderTime = viewModel.reminderTime
                    showReminderTime = true
                } label: {
                    HStack {
                        Text("Reminder time")
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(viewModel.reminderTime, format: .dateTime.hour().minute())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .listRowBackground(Theme.surface)
            }

            if !viewModel.isPremium {
                Toggle(isOn: Binding(
                    get: { viewModel.plusRemindersEnabled },
                    set: { newValue in Task { await viewModel.setPlusRemindersEnabled(newValue) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HuddlePals+ reminders")
                        Text("Now and then, every few weeks at most: what HuddlePals+ adds.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
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
            Text("Upload reminders come only on days you haven't uploaded yet, and stop once you do. HuddlePals+ reminders stop once you have it.")
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
            CodeTiles(keyCode: code, fontSize: 18)
                .padding(.vertical, 4)
                .accessibilityLabel("Key code \(code)")
                .accessibilityIdentifier("keyCode")
                .listRowBackground(Theme.surface)
        } header: {
            Text("Key code")
        } footer: {
            Text("If someone in a huddle asks for your key code, read this to them in person or on a call. It lets them check it's really you before they share the huddle's key with this phone.")
        }
    }

    private var plusSection: some View {
        Section {
            HStack {
                Text("HuddlePals+")
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(viewModel.plusSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(viewModel.isPremium ? Theme.accent : Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)

            if viewModel.canManageSubscription {
                Button("Manage subscription") { showManageSubscription = true }
                    .listRowBackground(Theme.surface)
            } else if !viewModel.isPremium {
                Button("Get HuddlePals+") { showPaywall = true }
                    .listRowBackground(Theme.surface)
            }

            Button("Restore Purchases") {
                Task { await viewModel.restorePurchases() }
            }
            .disabled(viewModel.isRestoring)
            .listRowBackground(Theme.surface)

            if let message = viewModel.plusMessage {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Theme.surface)
            }
        } header: {
            Text("Plan")
        } footer: {
            Text("10 huddles of up to 10 people, video drops, and your whole archive. Everyone you invite joins free.")
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
                router.openDeleteAccount()
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

            Toggle(isOn: $viewModel.simulatePlus) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simulate: HuddlePals+")
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
            if let data = photo.displayData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityLabel(photo.persistedPath == nil ? "New profile photo, not saved yet" : "Profile photo")
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
