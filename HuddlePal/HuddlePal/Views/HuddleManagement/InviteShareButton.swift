import LinkPresentation
import MessageUI
import SwiftUI
import UIKit

/// Shares a huddle's invite link through the app's own card: the invite as
/// it will look, then Messages, Copy link, or More apps. Messages sends the
/// link with the invite's picture; More apps opens iOS's share sheet, where
/// Messages shows the link as a rich card with the huddle's emoji and name,
/// like an App Store link. The picture is made on this phone, so the code
/// in the link's fragment is never fetched from anywhere.
struct InviteShareButton<Label: View>: View {
    let url: URL
    let huddleName: String
    let emoji: String
    @ViewBuilder let label: () -> Label

    @State private var isSharing = false
    @State private var card: UIImage?

    var body: some View {
        Button(action: {
            // Ready before the card rises, so it opens in one smooth move.
            if card == nil { card = InviteCard.image(name: huddleName, emoji: emoji) }
            isSharing = true
        }, label: label)
        .appDialog(
            "Invite to \u{201C}\(huddleName)\u{201D}",
            isPresented: $isSharing,
            message: "Anyone with the link can join and see every photo in it, so send it only to your people.",
            actions: actions
        ) {
            if let card {
                Image(uiImage: card)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Theme.shadow, radius: 10, x: 0, y: 4)
                    .frame(maxHeight: 170)
                    .accessibilityHidden(true)
            }
        }
    }

    private var actions: [DialogAction] {
        var actions: [DialogAction] = []
        if MFMessageComposeViewController.canSendText() {
            actions.append(DialogAction("Messages", systemImage: "message.fill") {
                InviteSharing.sendMessage(url: url, card: card)
            })
        }
        actions.append(DialogAction("Copy link", role: .secondary, systemImage: "link") {
            UIPasteboard.general.url = url
            Haptics.success()
        })
        actions.append(DialogAction("More apps", role: .secondary, systemImage: "square.and.arrow.up") {
            InviteSharing.shareSheet(item: InviteActivityItem(url: url, huddleName: huddleName, card: card))
        })
        actions.append(.cancel())
        return actions
    }
}

/// Apple's own screens for sending an invite, once the app's card has gone:
/// the Messages composer, or the share sheet for every other app.
@MainActor
enum InviteSharing {
    private static let messageDelegate = MessageComposeDismisser()

    static func sendMessage(url: URL, card: UIImage?) {
        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = messageDelegate
        composer.body = url.absoluteString
        if let data = card?.pngData() {
            composer.addAttachmentData(data, typeIdentifier: "public.png", filename: "Invite.png")
        }
        present(composer)
    }

    static func shareSheet(item: InviteActivityItem) {
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        present(controller)
    }

    private static func present(_ controller: UIViewController) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow
                ?? scenes.first?.keyWindow,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        // iPad shows the share sheet as a popover: from the bottom middle.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}

private final class MessageComposeDismisser: NSObject, MFMessageComposeViewControllerDelegate {
    func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        controller.dismiss(animated: true)
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
