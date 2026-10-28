import AVFoundation
import UIKit

/// A recorded video drop, ready to post: the MP4's bytes and its poster, all
/// in memory. Compose keeps it until it's posted (or the person takes a photo
/// instead), so a clip refused because Plus ended isn't lost.
struct PreparedClip: Identifiable {
    var id = UUID()
    let clip: Data
    /// The first frame as a JPEG, downscaled like a photo (no metadata): what
    /// tiles show, and what app builds from before videos show as a photo.
    let poster: Data
    let posterImage: UIImage
    let durationMs: Int

    var seconds: Double { Double(durationMs) / 1000 }
}

/// Cuts a clip to the part kept in Compose's trim bar.
enum ClipTrimmer {
    /// The part of `clip` from `range.lowerBound` to `range.upperBound`
    /// seconds, copied as recorded (no re-encoding), with a new poster from
    /// its first frame. The plaintext touches disk only in `CaptureFiles`,
    /// as the recording itself did, and is deleted straight after.
    static func trim(_ clip: PreparedClip, to range: ClosedRange<Double>) async throws -> PreparedClip {
        let source = try CaptureFiles.newClipURL()
        defer { try? FileManager.default.removeItem(at: source) }
        try clip.clip.write(to: source, options: .completeFileProtection)
        let output = try CaptureFiles.newClipURL()
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else {
            throw ClipPreparer.ClipError.unreadable
        }
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
        )
        do {
            if #available(iOS 18.0, *) {
                try await export.export(to: output, as: .mp4)
            } else {
                export.outputURL = output
                export.outputFileType = .mp4
                await export.export()
                guard export.status == .completed else { throw ClipPreparer.ClipError.unreadable }
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw ClipPreparer.ClipError.unreadable
        }
        return try await ClipPreparer.prepare(fileAt: output)
    }
}

/// Turns a finished recording into a `PreparedClip` and deletes the file.
enum ClipPreparer {
    enum ClipError: LocalizedError {
        case tooLarge
        case unreadable

        var errorDescription: String? {
            switch self {
            case .tooLarge: DepositError.videoTooLarge.errorDescription
            case .unreadable: "That video didn't record properly. Try again."
            }
        }
    }

    /// Reads the clip at `url` (in `CaptureFiles`) into memory, makes its
    /// poster from the first frame, and deletes the file, whatever happens.
    static func prepare(fileAt url: URL, maxBytes: Int = HuddleLimits.maxVideoBytes) async throws -> PreparedClip {
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let frame: CGImage
        do {
            duration = try await asset.load(.duration)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            frame = try await generator.image(at: .zero).image
        } catch {
            throw ClipError.unreadable
        }
        let clip = try Data(contentsOf: url)
        guard clip.count <= maxBytes else { throw ClipError.tooLarge }
        let posterImage = UIImage(cgImage: frame)
        guard let poster = ImageDownscaler.jpegData(from: posterImage, maxDimension: ImageDownscaler.depositMaxDimension),
              duration.seconds.isFinite, duration.seconds > 0
        else { throw ClipError.unreadable }
        return PreparedClip(
            clip: clip,
            poster: poster,
            posterImage: posterImage,
            durationMs: min(Int((duration.seconds * 1000).rounded()), Int(HuddleLimits.maxVideoDuration * 1000) + 100)
        )
    }

    /// A placeholder clip: the Simulator's stand-in camera, and tests.
    static func placeholder(seed: Int) async throws -> PreparedClip {
        let generated = try await PlaceholderVideoGenerator.clip(seed: seed)
        guard let image = UIImage(data: generated.poster) else { throw ClipError.unreadable }
        return PreparedClip(clip: generated.mp4, poster: generated.poster, posterImage: image, durationMs: generated.durationMs)
    }
}
