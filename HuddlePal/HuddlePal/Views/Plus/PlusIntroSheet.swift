import SwiftUI

/// Shown once, after a first post opens a huddle: what HuddlePals+ adds, a
/// way to the plans, and "Remind me later", which is how someone asks for
/// the occasional reminder about it. "Not now" asks for nothing.
struct PlusIntroSheet: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss
    @State private var showsPlans = false
    @State private var isAsking = false

    var body: some View {
        if showsPlans {
            // In the same sheet: Close or Continue there closes this too.
            PaywallView(context: .promotion)
        } else {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 28)
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("Your huddle is open")
                            .font(Theme.displayFont(28))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text("That's HuddlePals: post yours, see theirs. When you want more room, there's HuddlePals+.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    PlusFeatureList()
                    VStack(spacing: 12) {
                        PrimaryButton(title: "See HuddlePals+") { showsPlans = true }
                        Button {
                            Task {
                                isAsking = true
                                await deps.plusPromo.setRemindersEnabled(true)
                                dismiss()
                            }
                        } label: {
                            Text("Remind me later")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(isAsking)
                        Button {
                            dismiss()
                        } label: {
                            Text("Not now")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    Text("Reminders come every few weeks at most, and stop once you have HuddlePals+. Turn them off any time in Profile.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(Theme.screenPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .presentationBackground(Theme.background)
        }
    }
}
