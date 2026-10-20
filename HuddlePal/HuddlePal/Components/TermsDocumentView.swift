import SwiftUI

/// The bundled Terms of Service as scrolling, selectable text. Shown by the
/// onboarding gate and by Profile → Terms of Service.
struct TermsDocumentView: View {
    var document: TermsOfService? = TermsOfService.current
    /// Called when the end of the Terms is on screen — the reader has
    /// scrolled all the way down (or the whole text already fits).
    var onReachedEnd: (() -> Void)? = nil

    private static let scrollSpace = "terms-scroll"

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                // A plain VStack, not lazy: every block is laid out, so the
                // end marker below sits exactly at the true end of the text.
                VStack(alignment: .leading, spacing: 12) {
                    if let document {
                        ForEach(document.blocks) { block in
                            blockView(block)
                        }
                    } else {
                        Text("The Terms of Service couldn't be loaded. Read them at huddlepals.com/terms.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

                Color.clear
                    .frame(height: 1)
                    .background(GeometryReader { marker in
                        Color.clear.preference(
                            key: TermsEndOffsetKey.self,
                            value: marker.frame(in: .named(Self.scrollSpace)).minY
                        )
                    })
            }
            .coordinateSpace(name: Self.scrollSpace)
            .onPreferenceChange(TermsEndOffsetKey.self) { endOffset in
                // The marker's top, measured in the visible area: at or above
                // its bottom edge means the last line has been reached.
                if endOffset <= viewport.size.height + 1 { onReachedEnd?() }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: TermsOfService.Block) -> some View {
        switch block.kind {
        case .title:
            Text(block.text)
                .font(Theme.displayFont(24))
                .foregroundStyle(Theme.textPrimary)
        case .heading:
            Text(block.text)
                .font(Theme.displayFont(19))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 10)
        case .paragraph:
            Text(block.text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text(block.text)
                    .lineSpacing(3)
            }
            .font(.system(size: 15))
            .foregroundStyle(Theme.textPrimary)
            .padding(.leading, 4)
        }
    }
}

/// Where the end of the Terms sits within the visible scroll area.
private struct TermsEndOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}
