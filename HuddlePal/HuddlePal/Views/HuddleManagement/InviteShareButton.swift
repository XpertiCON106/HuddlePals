import LinkPresentation
import SwiftUI
import UIKit

/// Shares a huddle's invite link. Messages gets it as a rich link, a card
/// with the huddle's emoji and name titled "Join “<name>” on HuddlePals",
/// like an App Store link; Mail and other apps get a line with the link.
/// The preview is made on this phone, so the code in the link's fragment is
/// never fetched from anywhere.
struct InviteShareButton<Label: View>: View {
    let url: URL
    let huddleName: String
    let emoji: String
    @ViewBuilder let label: () -> Label

    @State private var isSharing = false

    var body: some View {
        Button(action: { isSharing = true }, label: label)
            .sheet(isPresented: $isSharing) {
                ActivitySheet(
                    item: InviteActivityItem(
                        url: url,
                        huddleName: huddleName,
                        card: InviteCard.image(name: huddleName, emoji: emoji)
                    ),
                    onDone: { isSharing = false }
                )
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
            }
    }
}

/// The invite as the share sheet hands it out.
final class InviteActivityItem: NSObject, UIActivityItemSource {
    let url: URL
    let huddleName: String
    let card: UIImage?

    init(url: URL, huddleName: String, card: UIImage?) {
        self.url = url
        self.huddleName = huddleName
        self.card = card
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    /// The bare link where it becomes a preview (Messages, AirDrop) or is
    /// copied; a line with the link everywhere else.
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        switch activityType {
        case .message?, .airDrop?, .copyToPasteboard?, nil:
            return url
        default:
            return InviteShare.message(huddleName: huddleName, url: url)
        }
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        InviteShare.title(huddleName: huddleName)
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        Self.metadata(url: url, huddleName: huddleName, card: card)
    }

    static func metadata(url: URL, huddleName: String, card: UIImage?) -> LPLinkMetadata {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = InviteShare.title(huddleName: huddleName)
        if let card {
            metadata.imageProvider = NSItemProvider(object: card)
        }
        return metadata
    }
}

/// The picture on an invite's link preview.
enum InviteCard {
    static let size = CGSize(width: 600, height: 315)

    @MainActor
    static func image(name: String, emoji: String) -> UIImage? {
        let renderer = ImageRenderer(content: InviteCardView(name: name, emoji: emoji))
        renderer.scale = 3
        return renderer.uiImage
    }
}

private struct InviteCardView: View {
    let name: String
    let emoji: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "F76B15"), Color(hex: "E5484D")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 10) {
                Text(emoji)
                    .font(.system(size: 88))
                Text(name)
                    .font(.system(size: 38, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("You're invited · HuddlePals")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 40)
        }
        .frame(width: InviteCard.size.width, height: InviteCard.size.height)
        .environment(\.colorScheme, .light)
    }
}

/// UIActivityViewController in a SwiftUI sheet, which closes with it.
private struct ActivitySheet: UIViewControllerRepresentable {
    let item: InviteActivityItem
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onDone() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
