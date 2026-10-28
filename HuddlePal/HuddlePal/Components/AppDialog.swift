import SwiftUI

/// One choice in an `appDialog`.
struct DialogAction: Identifiable {
    enum Role {
        /// The main choice, in ink.
        case primary
        /// Another choice, quieter.
        case secondary
        /// What can't be undone, in brick red.
        case destructive
        /// Closing without choosing; swiping the card away does the same.
        case cancel
    }

    let title: String
    var role: Role
    var systemImage: String?
    var isEnabled: Bool
    let action: () -> Void

    var id: String { title }

    init(
        _ title: String,
        role: Role = .primary,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void = {}
    ) {
        self.title = title
        self.role = role
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.action = action
    }

    static func cancel(_ title: String = "Cancel", action: @escaping () -> Void = {}) -> DialogAction {
        DialogAction(title, role: .cancel, action: action)
    }
}

extension View {
    /// A confirmation, warning or message in the app's own style, where iOS
    /// would show an alert or action sheet: a card that rises from the
    /// bottom, sized to what it says, the title in the display face, then
    /// its choices. Swiping it away is the cancel choice. A choice runs once
    /// the card has gone, so whatever it opens next has the screen to itself.
    func appDialog(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String? = nil,
        actions: [DialogAction]
    ) -> some View {
        appDialog(title, isPresented: isPresented, message: message, actions: actions) { EmptyView() }
    }

    /// The same card with something to set between the words and the
    /// choices (a time wheel, say).
    func appDialog<Extra: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String? = nil,
        actions: [DialogAction],
        @ViewBuilder extra: @escaping () -> Extra
    ) -> some View {
        modifier(AppDialogModifier(
            title: title, message: message, isPresented: isPresented, actions: actions, extra: extra
        ))
    }
}

private struct AppDialogModifier<Extra: View>: ViewModifier {
    let title: String
    let message: String?
    @Binding var isPresented: Bool
    let actions: [DialogAction]
    let extra: () -> Extra

    @State private var chosen: DialogAction?
    @State private var height: CGFloat = 300

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: finish) {
            DialogCard(title: title, message: message, actions: actions, extra: extra) { action in
                chosen = action
                isPresented = false
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .frame(maxHeight: .infinity, alignment: .top)
            .presentationDetents([.height(height)])
            .presentationCornerRadius(28)
            .presentationBackground(Theme.surface)
            .presentationDragIndicator(.hidden)
        }
    }

    private func finish() {
        let action = chosen ?? actions.first { $0.role == .cancel }
        chosen = nil
        action?.action()
    }
}

private struct DialogCard<Extra: View>: View {
    let title: String
    let message: String?
    let actions: [DialogAction]
    let extra: () -> Extra
    let choose: (DialogAction) -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text(title)
                    .font(Theme.displayFont(23))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    // The card's width, so the serif's overhang (a "?")
                    // stays inside the text's own frame.
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
            }

            extra()

            VStack(spacing: 10) {
                ForEach(actions) { action in
                    Button { choose(action) } label: {
                        HStack(spacing: 8) {
                            if let systemImage = action.systemImage {
                                Image(systemName: systemImage)
                            }
                            Text(action.title)
                        }
                    }
                    .buttonStyle(ActionButtonStyle(role: action.role))
                    .disabled(!action.isEnabled)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        // Its own height, whatever the sheet offers while it settles: that
        // height is what the sheet then takes.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appDialog")
    }
}

/// A full-width button in one of the dialog's roles: the dialog's own, and
/// any page that needs the same (Delete account's red button).
struct ActionButtonStyle: ButtonStyle {
    let role: DialogAction.Role
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: role == .cancel ? .medium : .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: role == .cancel ? 44 : 52)
            .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch role {
        case .primary: Theme.onAccent
        case .secondary: Theme.textPrimary
        case .destructive: Theme.onDestructive
        case .cancel: Theme.textSecondary
        }
    }

    private var fill: Color {
        switch role {
        case .primary: Theme.accent
        case .secondary: Theme.surfaceElevated
        case .destructive: Theme.destructive
        case .cancel: .clear
        }
    }
}
