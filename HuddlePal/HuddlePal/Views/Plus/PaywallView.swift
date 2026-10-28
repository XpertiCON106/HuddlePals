import StoreKit
import SwiftUI

/// HuddlePals+: what it adds, the plans with their price and renewal
/// terms, links to the Terms of Use (Apple's standard EULA), our Terms and
/// the Privacy Policy, and Restore Purchases. With Plus already on, it says
/// so and offers Apple's subscription settings instead. Once bought or
/// restored, a welcome screen stays until Continue.
struct PaywallView: View {
    let context: PaywallContext
    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PaywallViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    PaywallContent(viewModel: viewModel, onContinue: { dismiss() })
                } else {
                    Color.clear
                }
            }
            // The whole sheet, whatever the content's width: a short page
            // would otherwise leave the sheet's grey down both sides.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .toolbar {
                if viewModel?.didUnlock != true {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { dismiss() }
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .presentationBackground(Theme.background)
        .onAppear {
            if viewModel == nil { viewModel = PaywallViewModel(deps: deps, context: context) }
        }
    }
}

private struct PaywallContent: View {
    @Bindable var viewModel: PaywallViewModel
    let onContinue: () -> Void
    @State private var showManageSubscription = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if viewModel.didUnlock {
                    welcome
                } else {
                    Image(systemName: viewModel.context.symbol)
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 8)
                        .accessibilityHidden(true)
                    Text(viewModel.context.headline)
                        .font(Theme.displayFont(26))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    if viewModel.isPremium {
                        subscribed
                    } else {
                        PlusFeatureList()
                        plans
                    }
                    links
                }
            }
            .frame(maxWidth: .infinity)
            .padding(Theme.screenPadding)
        }
        .task { await viewModel.load() }
        .manageSubscriptionsSheet(isPresented: $showManageSubscription)
        .alert("This Apple Account already has HuddlePals+", isPresented: $viewModel.isLinkedElsewhereAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(PaywallViewModel.linkedElsewhere)
        }
    }

    @ViewBuilder
    private var plans: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView()
                .padding(.vertical, 30)
                .accessibilityLabel("Loading prices")
        case .unavailable(let reason):
            VStack(spacing: 12) {
                Text(reason)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await viewModel.load() } }
            }
        case .ready:
            if let message = viewModel.message {
                Callout(text: message)
            }
            if viewModel.offersRestoreInsteadOfBuying {
                alreadySubscribed
            } else {
                VStack(spacing: 12) {
                    ForEach(viewModel.products) { product in
                        PlanRow(product: product, isSelected: viewModel.selected?.id == product.id) {
                            viewModel.selectedID = product.id
                        }
                    }
                }
                PrimaryButton(title: viewModel.buttonTitle, isLoading: viewModel.isWorking) {
                    Task { await viewModel.purchase() }
                }
                Text(viewModel.renewalTerms)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("renewalTerms")
                Button("Restore Purchases") { Task { await viewModel.restore() } }
                    .font(.system(size: 14, weight: .semibold))
                    .disabled(viewModel.isWorking)
            }
        }
    }

    /// This Apple Account is already subscribed: restoring, not buying again.
    private var alreadySubscribed: some View {
        VStack(spacing: 12) {
            Text("You already have HuddlePals+")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("This Apple Account is already subscribed. Restore it to use it here. There's no need to buy it again.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Restore Purchases", systemImage: "arrow.clockwise", isLoading: viewModel.isWorking) {
                Task { await viewModel.restore() }
            }
            .accessibilityIdentifier("restoreInstead")
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 1.5)
        )
    }

    private var subscribed: some View {
        VStack(spacing: 12) {
            Label("You have HuddlePals+", systemImage: "checkmark.seal.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            if let until = viewModel.premiumUntil, until != .distantFuture {
                Text("Current period ends \(until, format: .dateTime.month().day().year())")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            if viewModel.canManageSubscription {
                Button("Manage subscription") { showManageSubscription = true }
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .padding(.vertical, 12)
    }

    /// Just bought or restored: what's theirs now, until they continue.
    private var welcome: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 24)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Welcome to HuddlePals+")
                    .font(Theme.displayFont(28))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("It's all unlocked. Here's what's yours now:")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            PlusFeatureList()
            if let until = viewModel.premiumUntil, until != .distantFuture {
                Text("Current period ends \(until, format: .dateTime.month().day().year()). Manage it any time in Profile.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            PrimaryButton(title: "Continue", systemImage: "arrow.right", action: onContinue)
                .padding(.top, 8)
                .accessibilityIdentifier("welcomeContinue")
        }
    }

    private var links: some View {
        HStack(spacing: 14) {
            Link("Terms of Use", destination: AppLinks.appleStandardEULA)
            Link("Terms of Service", destination: AppLinks.termsOfService)
            Link("Privacy Policy", destination: AppLinks.privacyPolicy)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.textSecondary)
        .padding(.top, 4)
    }
}

/// What HuddlePals+ adds, as a card: on the paywall, its welcome screen and
/// the intro after a first post.
struct PlusFeatureList: View {
    static let features: [(symbol: String, text: String)] = [
        ("person.3.fill", "Up to 10 people in every huddle you keep"),
        ("square.stack.3d.up.fill", "Keep up to 10 huddles"),
        ("video.fill", "Video drops of up to 6 seconds, with sound"),
        ("archivebox.fill", "Your whole archive, every day ever posted"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.features, id: \.text) { feature in
                Label {
                    Text(feature.text)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                } icon: {
                    Image(systemName: feature.symbol)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28)
                }
            }
            Text("Everyone you invite joins free.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
    }
}

/// A message that has to be read: what happened to a purchase or restore.
private struct Callout: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Theme.accent)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paywallMessage")
    }
}

/// One plan: the period, its price, and a trial if there is one.
private struct PlanRow: View {
    let product: PlusProduct
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.period == .year ? "Yearly" : "Monthly")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let days = product.freeTrialDays {
                        Text("\(PaywallViewModel.trialLength(days: days)) free")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Spacer()
                Text(PaywallViewModel.price(product))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(product.period == .year ? "Yearly" : "Monthly"), \(PaywallViewModel.price(product))\(product.freeTrialDays.map { ", \(PaywallViewModel.trialLength(days: $0)) free" } ?? "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
