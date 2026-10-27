import AVFoundation
import UIKit

/// Deterministic placeholder video clips for the seed world: a placeholder
/// photo (`PlaceholderImageGenerator`) slowly zooming in, as a silent H.264
/// MP4. The first frame is the photo itself, so its JPEG is the poster. No
/// bundled assets, and it runs on the Simulator, which has no camera.
enum PlaceholderVideoGenerator {
    struct Clip {
        /// The MP4 file's bytes.
        let mp4: Data
        /// Its first frame, as a JPEG.
        let poster: Data
        let durationMs: Int
    }

    enum GeneratorError: Error {
        case cannotWrite
    }

    static func clip(
        seed: Int,
        size: CGSize = CGSize(width: 360, height: 480),
        duration: TimeInterval = 2,
        framesPerSecond: Int32 = 15
    ) async throws -> Clip {
        guard let picture = PlaceholderImageGenerator.image(seed: seed, size: size).cgImage else {
            throw GeneratorError.cannotWrite
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("placeholder-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let width = Int(size.width), height = Int(size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 600_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw GeneratorError.cannotWrite }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? GeneratorError.cannotWrite }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(duration * Double(framesPerSecond))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            // Zooms from 100% to 115% over the clip, around the centre.
            let zoom = 1 + 0.15 * CGFloat(frame) / CGFloat(max(frames - 1, 1))
            guard let pool = adaptor.pixelBufferPool,
                  let buffer = Self.frame(picture, zoom: zoom, width: width, height: height, pool: pool),
                  adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond))
            else {
                writer.cancelWriting()
                throw writer.error ?? GeneratorError.cannotWrite
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? GeneratorError.cannotWrite }

        return Clip(
            mp4: try Data(contentsOf: url),
            poster: PlaceholderImageGenerator.jpegData(seed: seed, size: size),
            durationMs: Int(duration * 1000)
        )
    }

    private static func frame(_ picture: CGImage, zoom: CGFloat, width: Int, height: Int, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let drawn = CGSize(width: CGFloat(width) * zoom, height: CGFloat(height) * zoom)
        context.draw(picture, in: CGRect(
            x: (CGFloat(width) - drawn.width) / 2,
            y: (CGFloat(height) - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        ))
        return buffer
    }
}
