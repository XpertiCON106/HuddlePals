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
    @State private var copied = false

    init(viewModel: HuddleSettingsViewModel, onLeft: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onLeft = onLeft
        _notificationHour = State(initialValue: viewModel.huddle.notificationHour)
    }

    var body: some View {
        List {
            membersSection
            streakSection
            reminderSection
            inviteSection
            leaveSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
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
                        // them yet (QA report, decision 4.4).
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
        Section("Invite code") {
            HStack {
                Text(viewModel.huddle.inviteCode)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .kerning(3)
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button {
                    UIPasteboard.general.string = viewModel.huddle.inviteCode
                    copied = true
                    Haptics.success()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }
            .listRowBackground(Theme.surface)
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
