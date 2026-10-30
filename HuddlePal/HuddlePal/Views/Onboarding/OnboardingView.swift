import AuthenticationServices
import PhotosUI
import SwiftUI

/// Onboarding: concept cards → sign-in method (Apple; email / phone only
/// when `FeatureFlags.emailAndPhoneSignInEnabled`) → code → the Terms of
/// Service (Agree required; Decline signs out, back to the first card) →
/// profile. Returning accounts skip the profile step, and the Terms once
/// they've agreed to the current ones.
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
            case .terms: TermsStep(viewModel: viewModel)
            case .welcome: WelcomeStep(viewModel: viewModel)
            case .age: AgeStep(viewModel: viewModel)
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

/// Asked before any sign-in request or profile information is collected.
private struct AgeStep: View {
    let viewModel: OnboardingViewModel
    @State private var birthday: Birthday?
    @State private var showDeleteAccount = false

    var body: some View {
        Group {
            if viewModel.isUnderage {
                UnderageNotice(signOut: {
                    Task { await viewModel.signOut() }
                }, deleteAccount: viewModel.isSignedIn ? { showDeleteAccount = true } : nil,
                exitTitle: viewModel.isSignedIn ? "Sign out" : "Back to welcome")
            } else {
                ScrollView {
                    VStack(spacing: 22) {
                        Text("When's your birthday?")
                            .font(Theme.displayFont(28))
                            .accessibilityAddTraits(.isHeader)
                        Text("We ask before sign-in. Your birthday is private.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                        BirthdayEntry(birthday: $birthday)
                            .cardSurface()
                        PrimaryButton(title: "Continue", isEnabled: birthday?.isValid == true) {
                            if let birthday { viewModel.continueAfterAgeCheck(birthday) }
                        }
                    }
                    .padding(Theme.screenPadding)
                    .padding(.top, 40)
                }
            }
        }
        .sheet(isPresented: $showDeleteAccount) {
            NavigationStack { DeleteAccountView() }
        }
        .onChange(of: viewModel.isSignedIn) { _, signedIn in
            if !signedIn { showDeleteAccount = false }
        }
    }
}

// MARK: - Terms of Service

/// The full Terms with Agree and Decline. Agree unlocks only once the
/// reader has scrolled to the end, and only Agree goes further.
private struct TermsStep: View {
    @Bindable var viewModel: OnboardingViewModel
    @State private var confirmsSignOut = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Terms of Service")
                    .font(Theme.displayFont(28))
                    .foregroundStyle(Theme.textPrimary)
                Text("Please read and agree to the HuddlePals Terms of Service to continue.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)
            .padding(.bottom, 14)
            .padding(.horizontal, Theme.screenPadding)

            TermsDocumentView(onReachedEnd: viewModel.termsReachedEnd)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .padding(.horizontal, Theme.screenPadding)

            VStack(spacing: 8) {
                Group {
                    if viewModel.hasReachedEndOfTerms {
                        Text("By tapping Agree, you accept these Terms.")
                    } else {
                        Label("Scroll to the end of the Terms to enable Agree.", systemImage: "arrow.down")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 4)
                PrimaryButton(title: "Agree", systemImage: "checkmark", isEnabled: viewModel.hasReachedEndOfTerms) {
                    withAnimation { viewModel.agreeToTerms() }
                }
                Button {
                    Task { await viewModel.declineTerms() }
                } label: {
                    // The frame inside the label: outside it, only the
                    // word itself was tappable.
                    Text("Decline")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

                if viewModel.isSignedIn {
                    HStack(spacing: 4) {
                        Text(viewModel.signedInName.map { "Signed in as \($0)." } ?? "Signed in.")
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Button {
                            confirmsSignOut = true
                        } label: {
                            // The frame inside the label: outside it, only
                            // the words were tappable.
                            Text("Sign out")
                                .fontWeight(.semibold)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .font(.system(size: 13))
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 8)
            .padding(.horizontal, Theme.screenPadding)
        }
        .appDialog(
            "Sign out?",
            isPresented: $confirmsSignOut,
            message: "Then sign in with the account you want. The Terms come first.",
            actions: [
                DialogAction("Sign out", role: .destructive) {
                    Task { await viewModel.signOut() }
                },
                .cancel(),
            ]
        )
    }
}

// MARK: - Step 1: concept cards

private struct WelcomeStep: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        ZStack {
            // The first card's day goes by behind the whole screen, and
            // gives way to the others' pictures as they come in.
            // Only the fade is animated, never the scene itself.
            DayGoesByScene(isActive: viewModel.pageIndex == 0)
                .animation(.easeInOut(duration: 0.45)) { scene in
                    scene.opacity(viewModel.pageIndex == 0 ? 1 : 0)
                }

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
}

private struct ConceptCard: View {
    let card: OnboardingViewModel.Card

    /// The words sit in the same place on every card; each card's picture
    /// fills the space above them (the first card's is behind the screen).
    var body: some View {
        VStack(spacing: 0) {
            WelcomeIllustration(kind: card.illustration)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 14) {
                Text(card.title)
                    .font(Theme.displayFont(30))
                    .foregroundStyle(Theme.textPrimary)
                Text(card.message)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 36)
            }
            .padding(.bottom, 64)
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

                Text("Sign in to keep up with your huddles!")
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
    @FocusState private var focused: Field?

    private enum Field {
        case name, bio
    }

    var body: some View {
        if viewModel.isUnderage {
            // Under 13: nothing of the profile page, just this and a way out.
            UnderageNotice(signOut: {
                Task { await viewModel.signOutUnderage() }
            })
        } else {
            form
        }
    }

    private var form: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 14) {
                    AvatarView(
                        name: viewModel.displayName.isEmpty ? "?" : viewModel.displayName,
                        colorHex: viewModel.selectedColorHex,
                        imageData: viewModel.photos.first,
                        size: 76
                    )
                    Text("Make your profile")
                        .font(Theme.displayFont(28))
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("This is how your huddle sees you.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 32)

                photos

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Your name", text: $viewModel.displayName)
                        .font(.system(size: 17, weight: .medium))
                        .textContentType(.name)
                        .focused($focused, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focused = .bio }
                        .onChange(of: viewModel.displayName) { _, newValue in
                            if newValue.serverLength > AuthValidation.displayNameLimit {
                                viewModel.displayName = newValue.prefix(serverLength: AuthValidation.displayNameLimit)
                            }
                        }
                        .modifier(FormField())

                    VStack(alignment: .leading, spacing: 6) {
                        BirthdayRow(birthday: viewModel.birthday)
                            .font(.system(size: 17))
                            .modifier(FormField(asksToBeFilled: viewModel.birthday == nil))
                        Text(viewModel.birthday == nil
                             ? "Needed to open your huddle. Only you can see it."
                             : "Only you can see your birthday.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)
                    }

                    VStack(alignment: .trailing, spacing: 4) {
                        TextField("A short bio (optional)", text: $viewModel.bio, axis: .vertical)
                            .font(.system(size: 16))
                            .lineLimit(1...3)
                            .focused($focused, equals: .bio)
                            .onChange(of: viewModel.bio) { _, newValue in
                                if newValue.serverLength > AuthValidation.bioLimit {
                                    viewModel.bio = newValue.prefix(serverLength: AuthValidation.bioLimit)
                                }
                            }
                        if viewModel.bio.serverLength > AuthValidation.bioLimit - 15 {
                            Text("\(AuthValidation.bioLimit - viewModel.bio.serverLength)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .modifier(FormField())
                }

                // A profile picture is the avatar: the colours come back
                // when there's none.
                if viewModel.photos.isEmpty {
                    ColorRampPicker(selection: $viewModel.selectedColorHex, singleLine: true)
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.destructive)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    PrimaryButton(
                        title: "Open my huddle",
                        systemImage: "lock.open",
                        isLoading: viewModel.isWorking,
                        isEnabled: viewModel.canCompleteProfile
                    ) {
                        focused = nil
                        Task { await viewModel.completeProfile() }
                    }
                    // The name's there, but not the birthday: say so where they're looking.
                    if viewModel.birthday == nil && !viewModel.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Add your birthday to continue.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.bottom, 36)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Up to 3 photos; the first is the profile picture.
    private var photos: some View {
        HStack(spacing: 10) {
            ForEach(Array(viewModel.photos.enumerated()), id: \.offset) { index, data in
                Group {
                    if let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Theme.surfaceElevated
                    }
                }
                .frame(width: 80, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button {
                        viewModel.removePhoto(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white, .black.opacity(0.55))
                            .padding(10)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Remove photo")
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            if viewModel.canAddPhotos {
                // Read here: the picker's label isn't on the main actor.
                let isProcessing = viewModel.isProcessingPhotos
                let hasPhotos = !viewModel.photos.isEmpty
                PhotosPicker(
                    selection: $viewModel.photoItems,
                    maxSelectionCount: AuthValidation.maxProfilePhotos - viewModel.photos.count,
                    matching: .images
                ) {
                    VStack(spacing: 6) {
                        if isProcessing {
                            HuddleSpinner(size: 22, color: Theme.textSecondary, label: nil)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .semibold))
                        }
                        Text(hasPhotos ? "Add" : "Add photos")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 80, height: 104)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [5]))
                    )
                }
                .accessibilityLabel("Add profile photos")
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.photos.count)
    }
}

/// A form field on the sign-up profile step: a card the width of the screen.
private struct FormField: ViewModifier {
    /// Still to fill in (the birthday): a dashed ink edge, like an empty
    /// photo slot, instead of the hairline.
    var asksToBeFilled = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .padding(.vertical, 2)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        asksToBeFilled ? Theme.accent.opacity(0.5) : Theme.hairline,
                        style: StrokeStyle(lineWidth: asksToBeFilled ? 1.5 : 1, dash: asksToBeFilled ? [5, 4] : [])
                    )
            )
    }
}
