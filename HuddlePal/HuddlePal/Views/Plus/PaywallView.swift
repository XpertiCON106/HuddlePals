import StoreKit
import SwiftUI

/// HuddlePals Plus: what it adds, the plans with their price and renewal
/// terms, links to the Terms of Use (Apple's standard EULA), our Terms and
/// the Privacy Policy, and Restore Purchases. With Plus already on, it says
/// so and offers Apple's subscription settings instead.
struct PaywallView: View {
    let context: PaywallContext
    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PaywallViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    PaywallContent(viewModel: viewModel)
                } else {
                    Color.clear
                }
            }
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .onAppear {
            if viewModel == nil { viewModel = PaywallViewModel(deps: deps, context: context) }
        }
        .onChange(of: viewModel?.didUnlock) { _, unlocked in
            if unlocked == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
            }
        }
    }
}

private struct PaywallContent: View {
    @Bindable var viewModel: PaywallViewModel
    @State private var showManageSubscription = false

    private static let features: [(symbol: String, text: String)] = [
        ("person.3.fill", "Up to 10 people in every huddle you keep"),
        ("square.stack.3d.up.fill", "Keep up to 10 huddles"),
        ("video.fill", "Video drops of up to 6 seconds, with sound"),
        ("archivebox.fill", "Your whole archive, every day ever posted"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
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

                if viewModel.isPremium || viewModel.didUnlock {
                    subscribed
                } else {
                    features
                    plans
                }
                links
            }
            .padding(Theme.screenPadding)
        }
        .task { await viewModel.load() }
        .manageSubscriptionsSheet(isPresented: $showManageSubscription)
    }

    private var features: some View {
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
            VStack(spacing: 12) {
                ForEach(viewModel.products) { product in
                    PlanRow(product: product, isSelected: viewModel.selected?.id == product.id) {
                        viewModel.selectedID = product.id
                    }
                }
            }
            PrimaryButton(title: viewModel.buttonTitle, systemImage: "sparkles", isLoading: viewModel.isWorking) {
                Task { await viewModel.purchase() }
            }
            Text(viewModel.renewalTerms)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("renewalTerms")
            if let message = viewModel.message {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
            }
            Button("Restore Purchases") { Task { await viewModel.restore() } }
                .font(.system(size: 14, weight: .semibold))
                .disabled(viewModel.isWorking)
        }
    }

    private var subscribed: some View {
        VStack(spacing: 12) {
            Label("You have HuddlePals Plus", systemImage: "checkmark.seal.fill")
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
