import SwiftUI

/// A refresh failed: what's on screen is the last synced state, not today's.
/// Says so, with a way to try again (pull-to-refresh works too).
struct LoadErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.destructive)
                .accessibilityHidden(true)
            Text("Couldn't refresh. \(message)")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Try again", action: retry)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}
