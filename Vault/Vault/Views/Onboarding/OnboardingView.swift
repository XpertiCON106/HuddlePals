import SwiftUI

/// Three swipeable concept cards, then mock sign-in (name + avatar color).
struct OnboardingView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: OnboardingViewModel?

    var body: some View {
        Group {
            if let viewModel {
                OnboardingContent(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .onAppear {
            if viewModel == nil { viewModel = OnboardingViewModel(deps: deps) }
        }
    }
}

private struct OnboardingContent: View {
    @Bindable var viewModel: OnboardingViewModel
    private let signInPage = OnboardingViewModel.cards.count

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $viewModel.pageIndex) {
                ForEach(Array(OnboardingViewModel.cards.enumerated()), id: \.element.id) { index, card in
                    ConceptCard(card: card)
                        .tag(index)
                }
                SignInCard(viewModel: viewModel)
                    .tag(signInPage)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            if viewModel.pageIndex < signInPage {
                PrimaryButton(title: "Continue") {
                    withAnimation { viewModel.pageIndex += 1 }
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.background)
    }
}

private struct ConceptCard: View {
    let card: OnboardingViewModel.Card

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: card.systemImage)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(card.title)
                .font(Theme.displayFont(30))
                .foregroundStyle(Theme.textPrimary)
            Text(card.message)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 36)
            Spacer()
            Spacer()
        }
    }
}

private struct SignInCard: View {
    @Bindable var viewModel: OnboardingViewModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            AvatarView(
                name: viewModel.displayName.isEmpty ? "?" : viewModel.displayName,
                colorHex: viewModel.selectedColorHex,
                size: 76
            )

            Text("What should the others call you?")
                .font(Theme.displayFont(24))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            TextField("Your name", text: $viewModel.displayName)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .focused($nameFocused)
                .submitLabel(.done)
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 44)

            HStack(spacing: 12) {
                ForEach(AvatarPalette.hexes.prefix(6), id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 32, height: 32)
                        .overlay {
                            if hex == viewModel.selectedColorHex {
                                Circle().strokeBorder(.white, lineWidth: 2.5)
                            }
                        }
                        .onTapGesture {
                            viewModel.selectedColorHex = hex
                            Haptics.light()
                        }
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.destructive)
            }

            PrimaryButton(
                title: "Open my vault",
                systemImage: "lock.open",
                isLoading: viewModel.isSigningIn,
                isEnabled: viewModel.canSignIn
            ) {
                nameFocused = false
                Task { await viewModel.signIn() }
            }
            .padding(.horizontal, Theme.screenPadding)

            Spacer()
            Spacer()
        }
    }
}
