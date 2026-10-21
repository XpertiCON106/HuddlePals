import SwiftUI

struct JoinHuddleView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: JoinHuddleViewModel?

    var body: some View {
        Group {
            if let viewModel {
                JoinHuddleContent(viewModel: viewModel) { huddle in
                    if let huddle {
                        router.openHuddle(huddle)
                    } else {
                        router.popToHuddleList()
                    }
                }
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .navigationTitle("Join a Huddle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .onAppear {
            if viewModel == nil { viewModel = JoinHuddleViewModel(deps: deps) }
        }
        .onChange(of: deps.session.pendingInviteCode) {
            // A second link while Join is already open isn't pushed again.
            viewModel?.usePendingInvite()
        }
    }
}

private struct JoinHuddleContent: View {
    @Bindable var viewModel: JoinHuddleViewModel
    /// nil = back to the list; a huddle = open it.
    let onDone: (Huddle?) -> Void

    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            if let huddle = viewModel.joinedHuddle {
                joinedState(huddle)
            } else {
                entryState
            }
            Spacer()
        }
        .padding(Theme.screenPadding)
    }

    private var entryState: some View {
        VStack(spacing: 22) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
                .padding(.top, 24)

            Text("Enter your invite code")
                .font(Theme.displayFont(24))
                .foregroundStyle(Theme.textPrimary)

            Text("Ask the huddle's keeper for the 6-character code.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)

            TextField("ABC123", text: $viewModel.code)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($codeFocused)
                .padding(.vertical, 14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .onChange(of: viewModel.code) { _, newValue in
                    if newValue.count > 6 {
                        viewModel.code = String(newValue.prefix(6))
                    }
                }

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.destructive)
                    .multilineTextAlignment(.center)
            }

            PrimaryButton(
                title: "Join huddle",
                isLoading: viewModel.isJoining,
                isEnabled: viewModel.canJoin
            ) {
                codeFocused = false
                Task { await viewModel.join() }
            }
        }
        .onAppear { codeFocused = true }
    }

    private func joinedState(_ huddle: Huddle) -> some View {
        VStack(spacing: 18) {
            Text(huddle.emoji)
                .font(.system(size: 64))
                .padding(.top, 32)
            Text("Welcome to \(huddle.name)")
                .font(Theme.displayFont(26))
                .foregroundStyle(Theme.textPrimary)
            Text("Deposit a photo today to see what everyone else shared.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Step inside", systemImage: "lock.fill") {
                onDone(huddle)
            }
        }
    }
}
