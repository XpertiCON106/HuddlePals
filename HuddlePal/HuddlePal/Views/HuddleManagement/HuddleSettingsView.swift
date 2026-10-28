import SwiftUI
import UIKit

struct HuddleSettingsView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    let huddle: Huddle

    @State private var viewModel: HuddleSettingsViewModel?

    var body: some View {
        Group {
            if let viewModel {
                SettingsContent(viewModel: viewModel) {
                    router.popToHuddleList()
                }
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .navigationTitle("\(huddle.emoji) \(huddle.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .onAppear {
            if viewModel == nil { viewModel = HuddleSettingsViewModel(deps: deps, huddle: huddle) }
        }
    }
}

private struct SettingsContent: View {
    @Bindable var viewModel: HuddleSettingsViewModel
    let onLeft: () -> Void

    @State private var notificationHour: Int
    @State private var showLeaveConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showResetConfirmation = false
    @State private var copied = false
    @State private var checking: KeyCheck?
    @State private var showPaywall = false

    init(viewModel: HuddleSettingsViewModel, onLeft: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onLeft = onLeft
        _notificationHour = State(initialValue: viewModel.huddle.notificationHour)
    }

    var body: some View {
        List {
            if !viewModel.keyChecks.isEmpty {
                keyCheckSection
            }
            membersSection
            streakSection
            reminderSection
            inviteSection
            leaveSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .task { await viewModel.loadInvite() }
        .task { await viewModel.loadKeyChecks() }
        .task { await viewModel.loadJoinStatus() }
        .sheet(isPresented: $showPaywall, onDismiss: {
            Task { await viewModel.loadJoinStatus() }
        }) {
            PaywallView(context: .invites)
        }
        .sheet(item: $checking) { check in
            KeyCheckSheet(viewModel: viewModel, check: check) { checking = nil }
        }
        .confirmationDialog(
            "Leave \(viewModel.huddle.name)?",
            isPresented: $showLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave huddle", role: .destructive) {
                Task {
                    await viewModel.leaveHuddle()
                    if viewModel.didLeave { onLeft() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll lose access to the shared archive. The huddle keeps existing for everyone else.")
        }
        .confirmationDialog(
            "Delete \(viewModel.huddle.name)?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete huddle", role: .destructive) {
                Task {
                    await viewModel.deleteHuddle()
                    if viewModel.didDelete { onLeft() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone is removed, and every photo and video in it is deleted for good. This can't be undone.")
        }
    }

    private var keyCheckSection: some View {
        Section {
            ForEach(viewModel.keyChecks) { check in
                Button {
                    checking = check
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                        Text(viewModel.name(for: check))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("Check code")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityHint("Compares their key code before sharing this huddle's key with them.")
                .listRowBackground(Theme.surface)
            }
        } header: {
            Text("Waiting for the huddle key")
        } footer: {
            Text("They can't see this huddle's photos until someone here checks their key code and shares the key.")
        }
    }

    private var membersSection: some View {
        Section {
            ForEach(viewModel.memberships) { membership in
                UserLink(user: membership.user) {
                    HStack(spacing: 12) {
                        AvatarView(
                            name: membership.user?.displayName ?? "?",
                            colorHex: membership.user?.avatarColorHex ?? "888888",
                            imagePath: membership.user?.profilePhotoPaths.first,
                            size: 34
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(membership.user?.displayName ?? "Former member")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(membership.role.displayName)
                                .font(.system(size: 12))
                                .foregroundStyle(membership.role == .keeper ? Theme.accent : Theme.textSecondary)
                        }
                        Spacer()
                        // Skip tokens aren't shown: nothing in the app spends
                        // them yet, so a count would promise a feature that
                        // isn't there.
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary.opacity(0.6))
                    }
                    // A plain-style button only takes taps where something
                    // is drawn; without this the gap before the chevron
                    // (most of the row) did nothing.
                    .contentShape(Rectangle())
                }
                .listRowBackground(Theme.surface)
            }
        } header: {
            Text("Members")
        }
    }

    private var streakSection: some View {
        Section("Streak") {
            HStack {
                StreakBadge(count: viewModel.huddle.streakCount)
                Text(viewModel.streakDetail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)
        }
    }

    private var reminderSection: some View {
        Section {
            Picker("Daily reminder", selection: $notificationHour) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(hourLabel(hour)).tag(hour)
                }
            }
            .listRowBackground(Theme.surface)
            .disabled(!viewModel.isKeeper)
            .onChange(of: notificationHour) { _, newValue in
                Task { await viewModel.setNotificationHour(newValue) }
            }
        } header: {
            Text("Reminder")
        } footer: {
            Text(viewModel.isKeeper
                 ? "The huddle's preferred time of day. Turn on your personal upload reminder in Profile to actually get notified."
                 : "The huddle's preferred time of day, set by the keeper. Turn on your personal upload reminder in Profile to get notified.")
        }
    }

    private var inviteSection: some View {
        Section {
            if let closed = viewModel.invitesClosedMessage {
                // No code to share while nobody can join with it.
                Label(closed, systemImage: "person.crop.circle.badge.xmark")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                    .listRowBackground(Theme.surface)
                if viewModel.canReopenWithPlus {
                    Button {
                        showPaywall = true
                    } label: {
                        Text("Get HuddlePals+")
                    }
                    .listRowBackground(Theme.surface)
                }
            } else if let code = viewModel.inviteCode {
                CodeTiles(invite: code, fontSize: 15)
                    .accessibilityLabel(code.displayed)
                    .accessibilityIdentifier("inviteCode")
                    .padding(.vertical, 4)
                    .listRowBackground(Theme.surface)
                HStack {
                    Button {
                        UIPasteboard.general.string = code.displayed
                        copied = true
                        Haptics.success()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    if let url = viewModel.inviteShareURL {
                        InviteShareButton(url: url, huddleName: viewModel.huddle.name, emoji: viewModel.huddle.emoji) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .listRowBackground(Theme.surface)
                if viewModel.isKeeper {
                    Button {
                        showResetConfirmation = true
                    } label: {
                        Label("New invite code", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(viewModel.isResettingInvite)
                    .listRowBackground(Theme.surface)
                    .confirmationDialog(
                        "Make a new invite code?",
                        isPresented: $showResetConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("New code", role: .destructive) {
                            Task { await viewModel.resetInvite() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The current code stops working at once. Anyone who hasn't joined yet will need the new one.")
                    }
                }
            } else if viewModel.isLoadingInvite {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Theme.surface)
            } else {
                Button("Try again") {
                    Task { await viewModel.loadInvite() }
                }
                .listRowBackground(Theme.surface)
            }
            if let message = viewModel.inviteMessage {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.destructive)
                    .listRowBackground(Theme.surface)
            }
        } header: {
            Text("Invite code")
        } footer: {
            if viewModel.invitesClosedMessage == nil {
                Text(viewModel.isKeeper
                     ? "Anyone with this code can join and see every photo and video. Make a new one to stop the old code working."
                     : "Anyone with this code can join and see every photo and video.")
            }
        }
    }

    private var leaveSection: some View {
        Section {
            Button(role: .destructive) {
                showLeaveConfirmation = true
            } label: {
                Label("Leave huddle", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .listRowBackground(Theme.surface)

            if viewModel.isKeeper {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete huddle", systemImage: "trash")
                }
                .disabled(viewModel.isDeleting)
                .listRowBackground(Theme.surface)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.destructive)
                    .listRowBackground(Theme.surface)
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(.dateTime.hour())
    }
}

/// Compare a member's key code before their phone gets the huddle key: the
/// code here is the key the server lists for them; theirs is in their
/// Profile. Only the person themselves can read theirs out, so the check has
/// to happen in person or on a call.
private struct KeyCheckSheet: View {
    let viewModel: HuddleSettingsViewModel
    let check: KeyCheck
    let dismiss: () -> Void

    private var name: String { viewModel.name(for: check) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Check \(name)'s key code")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Before \(name)'s phone gets this huddle's key, make sure it's really them. In person or on a call, ask them to open Profile and read you their key code. It should match this one exactly:")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                CodeTiles(keyCode: check.code, fontSize: 22)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
                    .accessibilityLabel("Key code \(check.code)")
                    .accessibilityIdentifier("keyCheckCode")
                Text("If the codes are different, don't share. Ask \(name) to try again later, and tell us at hello@huddlepals.com if they still don't match.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                if let message = viewModel.keyCheckMessage {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.destructive)
                }
                PrimaryButton(
                    title: "Codes match, share the key",
                    systemImage: "key.fill",
                    isLoading: viewModel.isConfirmingKeyCheck
                ) {
                    Task {
                        if await viewModel.confirm(check) { dismiss() }
                    }
                }
                Button("Not now", action: dismiss)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(Theme.screenPadding)
        }
        .background(Theme.background)
        .presentationDetents([.large])
    }
}
