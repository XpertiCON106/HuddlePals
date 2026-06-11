import UIKit

/// Generates deterministic placeholder photos (warm gradient + SF Symbol)
/// with `UIGraphicsImageRenderer`. No bundled assets, no network.
enum PlaceholderImageGenerator {
    private static let gradients: [(UIColor, UIColor)] = [
        (UIColor(red: 0.91, green: 0.56, blue: 0.26, alpha: 1), UIColor(red: 0.42, green: 0.16, blue: 0.28, alpha: 1)),
        (UIColor(red: 0.30, green: 0.45, blue: 0.58, alpha: 1), UIColor(red: 0.10, green: 0.14, blue: 0.26, alpha: 1)),
        (UIColor(red: 0.49, green: 0.62, blue: 0.36, alpha: 1), UIColor(red: 0.13, green: 0.25, blue: 0.20, alpha: 1)),
        (UIColor(red: 0.76, green: 0.45, blue: 0.62, alpha: 1), UIColor(red: 0.25, green: 0.12, blue: 0.32, alpha: 1)),
        (UIColor(red: 0.89, green: 0.74, blue: 0.42, alpha: 1), UIColor(red: 0.48, green: 0.28, blue: 0.14, alpha: 1)),
        (UIColor(red: 0.36, green: 0.55, blue: 0.54, alpha: 1), UIColor(red: 0.10, green: 0.22, blue: 0.27, alpha: 1)),
    ]

    private static let symbols = [
        "mountain.2.fill", "sun.max.fill", "leaf.fill", "cup.and.saucer.fill",
        "pawprint.fill", "figure.hiking", "sparkles", "camera.macro",
        "moon.stars.fill", "bicycle", "music.note", "book.fill",
        "fork.knife", "tree.fill", "cloud.sun.fill", "wand.and.stars",
    ]

    /// Deterministic for a given seed, so regenerated seed data looks stable.
    static func jpegData(seed: Int, size: CGSize = CGSize(width: 600, height: 800)) -> Data {
        let (top, bottom) = gradients[abs(seed) % gradients.count]
        let symbolName = symbols[abs(seed / 7 + seed) % symbols.count]

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width * 0.3, y: size.height),
                    options: []
                )
            }

            let config = UIImage.SymbolConfiguration(pointSize: size.width * 0.28, weight: .medium)
            if let symbol = UIImage(systemName: symbolName, withConfiguration: config)?
                .withTintColor(UIColor.white.withAlphaComponent(0.85), renderingMode: .alwaysOriginal) {
                let symbolSize = symbol.size
                let origin = CGPoint(
                    x: (size.width - symbolSize.width) / 2,
                    y: (size.height - symbolSize.height) / 2
                )
                symbol.draw(at: origin)
            }
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
}
