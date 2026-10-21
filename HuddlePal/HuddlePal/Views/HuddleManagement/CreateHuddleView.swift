import SwiftUI

struct CreateHuddleView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: CreateHuddleViewModel?

    var body: some View {
        Group {
            if let viewModel {
                CreateHuddleContent(viewModel: viewModel) { huddle in
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
        .navigationTitle("Create a Huddle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .onAppear {
            if viewModel == nil { viewModel = CreateHuddleViewModel(deps: deps) }
        }
    }
}

private struct CreateHuddleContent: View {
    @Bindable var viewModel: CreateHuddleViewModel
    /// nil = back to the list; a huddle = open it.
    let onDone: (Huddle?) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let huddle = viewModel.createdHuddle {
                    createdState(huddle)
                } else {
                    formState
                }
            }
            .padding(Theme.screenPadding)
        }
    }

    private var formState: some View {
        VStack(spacing: 24) {
            Text(viewModel.emoji)
                .font(.system(size: 64))
                .padding(.top, 12)

            TextField("Huddle name", text: $viewModel.name)
                .font(.system(size: 18, weight: .medium))
                .multilineTextAlignment(.center)
                .onChange(of: viewModel.name) { _, newValue in
                    if newValue.serverLength > TextLimit.huddleName {
                        viewModel.name = newValue.prefix(serverLength: TextLimit.huddleName)
                    }
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(CreateHuddleViewModel.emojiChoices, id: \.self) { choice in
                    Button {
                        viewModel.emoji = choice
                        Haptics.light()
                    } label: {
                        Text(choice)
                            .font(.system(size: 28))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                choice == viewModel.emoji ? Theme.surfaceElevated : .clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(choice == viewModel.emoji ? .isSelected : [])
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.destructive)
            }

            PrimaryButton(
                title: "Create huddle",
                systemImage: "lock.shield",
                isLoading: viewModel.isCreating,
                isEnabled: viewModel.canCreate
            ) {
                Task { await viewModel.create() }
            }
        }
    }

    private func createdState(_ huddle: Huddle) -> some View {
        VStack(spacing: 20) {
            Text("\(huddle.emoji)")
                .font(.system(size: 64))
                .padding(.top, 12)
            Text(huddle.name)
                .font(Theme.displayFont(26))
                .foregroundStyle(Theme.textPrimary)
            Text("Share this code with up to 7 people you'd trust with the family album.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Text(huddle.inviteCode)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .kerning(6)
                .foregroundStyle(Theme.accent)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )

            if let url = viewModel.shareURL {
                ShareLink(item: url, message: Text("Join our huddle \"\(huddle.name)\" on HuddlePals")) {
                    Label("Share invite link", systemImage: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }

            PrimaryButton(title: "Open the huddle", systemImage: "arrow.right") {
                onDone(huddle)
            }

            Button("Back to my huddles") { onDone(nil) }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
