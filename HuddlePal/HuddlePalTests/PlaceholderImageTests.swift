import UIKit
import XCTest

@testable import HuddlePal

/// QA-32: the seeded demo photos are painted edge to edge.
final class PlaceholderImageTests: XCTestCase {
    func testSeedPhotosHaveNoUnpaintedCorner() throws {
        for seed in 0..<8 {
            let image = try XCTUnwrap(UIImage(data: PlaceholderImageGenerator.jpegData(seed: seed)))
            let (r, g, b) = try pixel(of: image, x: Int(image.size.width) - 4, y: Int(image.size.height) - 4)
            XCTAssertFalse(r > 240 && g > 240 && b > 240, "seed \(seed): the bottom-right corner is unpainted white")
        }
    }

    private func pixel(of image: UIImage, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8) {
        let cgImage = try XCTUnwrap(image.cgImage)
        var data = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: -x, y: -(cgImage.height - 1 - y), width: cgImage.width, height: cgImage.height))
        return (data[0], data[1], data[2])
    }
}
