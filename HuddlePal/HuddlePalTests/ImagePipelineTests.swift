import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import HuddlePal

/// What leaves the phone: every photo is re-rendered by ImageDownscaler
/// before upload. Family photos taken at home carry GPS coordinates, so none
/// of the source metadata may survive.
final class ImagePipelineTests: XCTestCase {
    private func sourceImage(width: Int, height: Int, type: UTType, gps: Bool) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // `width` × `height` pixels, not points × screen scale
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "taken at home"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"],
        ]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.0090, kCGImagePropertyGPSLongitudeRef: "W",
            ]
        }
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func metadata(of data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    }

    func testUploadsCarryNoLocationOrCameraMetadata() throws {
        for type in [UTType.jpeg, .heic, .png] {
            let original = try sourceImage(width: 1200, height: 900, type: type, gps: true)
            XCTAssertNotNil(try metadata(of: original)[kCGImagePropertyGPSDictionary], "\(type): the fixture has GPS")
            let picked = try XCTUnwrap(UIImage(data: original), "\(type)")
            let upload = try XCTUnwrap(ImageDownscaler.jpegData(from: picked, maxDimension: ImageDownscaler.depositMaxDimension))
            let kept = try metadata(of: upload)
            XCTAssertNil(kept[kCGImagePropertyGPSDictionary], "\(type): GPS must not be uploaded")
            let exif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any]
            XCTAssertNil(exif?[kCGImagePropertyExifUserComment], "\(type): EXIF from the source must not survive")
            let tiff = kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            XCTAssertNil(tiff?[kCGImagePropertyTIFFModel], "\(type): device model must not survive")
        }
    }

    func testLargePhotosAreDownscaledForUpload() throws {
        let huge = try XCTUnwrap(UIImage(data: try sourceImage(width: 6000, height: 4500, type: .jpeg, gps: false)))
        let deposit = try XCTUnwrap(ImageDownscaler.jpegData(from: huge, maxDimension: ImageDownscaler.depositMaxDimension))
        let avatar = try XCTUnwrap(ImageDownscaler.jpegData(from: huge, maxDimension: ImageDownscaler.avatarMaxDimension))
        let depositSize = try XCTUnwrap(UIImage(data: deposit)).size
        XCTAssertEqual(max(depositSize.width, depositSize.height), 1440, accuracy: 1)
        XCTAssertEqual(max(try XCTUnwrap(UIImage(data: avatar)).size.width, 0), 512, accuracy: 1)
        XCTAssertLessThan(deposit.count, LiveMediaService.maxUploadBytes, "fits the bucket's 5 MB limit with room")
    }

    func testSmallPhotosAreNeverUpscaled() throws {
        let small = try XCTUnwrap(UIImage(data: try sourceImage(width: 300, height: 200, type: .png, gps: false)))
        let out = try XCTUnwrap(UIImage(data: try XCTUnwrap(ImageDownscaler.jpegData(from: small, maxDimension: 1440))))
        XCTAssertEqual(out.size.width, 300, accuracy: 1)
    }

    func testCorruptOrDisguisedFilesAreNotImages() {
        // What PhotosPicker / a shared file could hand over: the app only ever
        // proceeds with a decodable UIImage (ProfileViewModel skips the rest).
        XCTAssertNil(UIImage(data: Data("%PDF-1.7 not a photo".utf8)))
        XCTAssertNil(UIImage(data: Data([0xFF, 0xD8, 0xFF, 0x00, 0x01])), "a truncated JPEG header")
    }
}
