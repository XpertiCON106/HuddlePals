import SwiftUI

/// Profile → Terms of Service: the Terms the user agreed to, and when.
struct TermsReaderView: View {
    let acceptedAt: Date?

    var body: some View {
        VStack(spacing: 0) {
            if let acceptedAt {
                Label(
                    "You agreed on \(acceptedAt.formatted(date: .long, time: .shortened))",
                    systemImage: "checkmark.seal"
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            TermsDocumentView()
        }
        .background(Theme.background)
        .navigationTitle("Terms of Service")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
    }
}
