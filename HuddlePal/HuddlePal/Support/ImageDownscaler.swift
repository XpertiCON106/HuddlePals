import UIKit

/// Downscales images before they're uploaded. This is the single biggest
/// lever on upload size, egress, and — because deposits are permanent —
/// storage cost that only ever grows: a full-resolution camera frame
/// (~3–6 MB) becomes a few hundred KB with no visible quality loss at the
/// sizes HuddlePals displays.
enum ImageDownscaler {
    /// Deposit photos are shown full-bleed; 1440px on the long edge is plenty.
    static let depositMaxDimension: CGFloat = 1440
    /// Avatars/profile photos render small; 512px is generous.
    static let avatarMaxDimension: CGFloat = 512

    /// Resizes so the longest edge is at most `maxDimension` (never upscales),
    /// preserving aspect ratio and orientation, and returns JPEG data.
    static func jpegData(
        from image: UIImage,
        maxDimension: CGFloat,
        quality: CGFloat = 0.8
    ) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let factor = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(
            width: (image.size.width * factor).rounded(),
            height: (image.size.height * factor).rounded()
        )

        let format = UIGraphicsImageRendererFormat.default()
        // scale 1 so the output is `target` *pixels*, not ×device-scale.
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
