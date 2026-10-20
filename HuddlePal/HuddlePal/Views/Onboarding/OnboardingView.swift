import AuthenticationServices
import SwiftUI

/// Four-step onboarding: concept cards → sign-in method (Apple; email /
/// phone only when `FeatureFlags.emailAndPhoneSignInEnabled`) → code →
/// profile (name + avatar). Returning accounts skip the profile step
/// automatically.
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

    var body: some View {
        Group {
            switch viewModel.step {
            case .welcome: WelcomeStep(viewModel: viewModel)
            case .method: MethodStep(viewModel: viewModel)
            case .code:
                // Only email/phone sign-in reaches this step; with it off,
                // fall back to the method step rather than dead-end.
                if FeatureFlags.emailAndPhoneSignInEnabled {
                    CodeStep(viewModel: viewModel)
                } else {
                    MethodStep(viewModel: viewModel)
                }
            case .profile: ProfileStep(viewModel: viewModel)
            }
        }
        .background(Theme.background)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.step)
    }
}

// MARK: - Step 1: concept cards

private struct WelcomeStep: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $viewModel.pageIndex) {
                ForEach(Array(OnboardingViewModel.cards.enumerated()), id: \.element.id) { index, card in
                    ConceptCard(card: card)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            PrimaryButton(title: viewModel.isLastWelcomePage ? "Get started" : "Continue") {
                withAnimation { viewModel.advanceWelcome() }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.bottom, 24)
        }
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

// MARK: - Step 2: pick a sign-in method

private struct MethodStep: View {
    @Bindable var viewModel: OnboardingViewModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 48)

                Text("Keep it yours")
                    .font(Theme.displayFont(28))
                    .foregroundStyle(Theme.textPrimary)

                Text("Sign in so your huddle follows you — not your phone.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                appleButton
                    .padding(.top, 8)

                if FeatureFlags.emailAndPhoneSignInEnabled {
                    HStack(spacing: 12) {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        Text("or")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                    .padding(.vertical, 4)

                    Picker("Sign-in method", selection: $viewModel.channel) {
                        ForEach(OnboardingViewModel.Channel.allCases) { channel in
                            Text(channel.rawValue).tag(channel)
                        }
                    }
                    .pickerStyle(.segmented)

                    destinationField

                    if viewModel.channel == .phone {
                        Text("US and Canada numbers. Elsewhere? Start with + and your country code.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.destructive)
                        .multilineTextAlignment(.center)
                }

                if FeatureFlags.emailAndPhoneSignInEnabled {
                    PrimaryButton(
                        title: "Send code",
                        systemImage: "paperplane",
                        isLoading: viewModel.isWorking,
                        isEnabled: viewModel.canSendCode
                    ) {
                        fieldFocused = false
                        Task { await viewModel.sendCode() }
                    }
                }
            }
            .padding(Theme.screenPadding)
            .modifier(CenteredWhenAppleOnly())
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var appleButton: some View {
        if viewModel.isMockBackend {
            // The real Apple sheet needs a live backend to verify against;
            // mock mode fakes the same outcome with a lookalike button.
            Button {
                Task { await viewModel.mockAppleSignIn() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "applelogo")
                        .font(.system(size: 18, weight: .medium))
                    Text("Continue with Apple")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            SignInWithAppleButton(.continue) { request in
                viewModel.configureAppleRequest(request)
            } onCompletion: { result in
                Task { await viewModel.handleAppleCompletion(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private var destinationField: some View {
        Group {
            if viewModel.channel == .email {
                TextField("you@example.com", text: $viewModel.emailInput)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                HStack(spacing: 10) {
                    // US/Canada by default; typing "+" switches to a full
                    // international number and hides the prefix.
                    if !viewModel.phoneInput.hasPrefix("+") {
                        Text("+1")
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityHidden(true)
                    }
                    TextField("(415) 555-0123", text: $viewModel.phoneInput)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .accessibilityLabel("Phone number")
                        .onChange(of: viewModel.phoneInput) { _, newValue in
                            let formatted = AuthValidation.formattedPhoneInput(newValue)
                            if formatted != newValue { viewModel.phoneInput = formatted }
                        }
                }
            }
        }
        .font(.system(size: 17, weight: .medium))
        .focused($fieldFocused)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

/// Apple-only sign-in is a short screen: center it in the scroll view rather
/// than leave it top-heavy. With email/phone on, the layout is unchanged.
private struct CenteredWhenAppleOnly: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if FeatureFlags.emailAndPhoneSignInEnabled {
            content
        } else {
            content.containerRelativeFrame(.vertical)
        }
    }
}

// MARK: - Step 3: verification code

private struct CodeStep: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Text(viewModel.channel == .email ? "Check your inbox" : "Check your messages")
                .font(Theme.displayFont(28))
                .foregroundStyle(Theme.textPrimary)

            Text("We sent a \(viewModel.codeLength)-digit code to\n\(viewModel.destination?.displayValue ?? "")")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            CodeEntryField(code: $viewModel.codeInput, length: viewModel.codeLength)
                .padding(.vertical, 8)
                .onChange(of: viewModel.codeInput) { _, newValue in
                    // Auto-submit the moment the last digit lands.
                    if newValue.count == viewModel.codeLength, !viewModel.attemptsExhausted {
                        Task { await viewModel.verify() }
                    }
                }

            if let hint = viewModel.mockCodeHint {
                Text("Mock mode — the code is always \(hint).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.destructive)
                    .multilineTextAlignment(.center)
            }

            PrimaryButton(
                title: "Verify",
                systemImage: "checkmark",
                isLoading: viewModel.isWorking,
                isEnabled: viewModel.canVerify
            ) {
                Task { await viewModel.verify() }
            }

            HStack {
                Button("Use a different email or phone") {
                    viewModel.backToMethod()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

                Spacer()

                Button(
                    viewModel.resendSecondsRemaining > 0
                        ? "Resend in \(viewModel.resendSecondsRemaining)s"
                        : "Resend code"
                ) {
                    Task { await viewModel.resendCode() }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    viewModel.resendSecondsRemaining > 0 ? Theme.textSecondary : Theme.accent
                )
                .disabled(viewModel.resendSecondsRemaining > 0 || viewModel.isWorking)
            }
            .padding(.top, 4)

            Spacer()
            Spacer()
        }
        .padding(Theme.screenPadding)
    }
}

// MARK: - Step 4: profile

private struct ProfileStep: View {
    @Bindable var viewModel: OnboardingViewModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 22) {
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
                .font(.system(size: 18, weight: .medium))
                .textContentType(.name)
                .multilineTextAlignment(.center)
                .focused($nameFocused)
                .submitLabel(.done)
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .padding(.horizontal, 44)

            ColorRampPicker(selection: $viewModel.selectedColorHex, singleLine: true)
                .padding(.horizontal, Theme.screenPadding)
                .padding(.top, 4)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.destructive)
            }

            PrimaryButton(
                title: "Open my huddle",
                systemImage: "lock.open",
                isLoading: viewModel.isWorking,
                isEnabled: viewModel.canCompleteProfile
            ) {
                nameFocused = false
                Task { await viewModel.completeProfile() }
            }
            .padding(.horizontal, Theme.screenPadding)

            Spacer()
            Spacer()
        }
    }
}
