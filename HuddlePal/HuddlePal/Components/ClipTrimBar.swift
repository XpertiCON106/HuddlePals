import AVFoundation
import SwiftUI
import UIKit

/// Frames of a clip, read from memory (like playing it): a strip for the
/// trim bar, and the frame under a handle while it's dragged.
@MainActor
final class ClipFrames {
    private let loader: InMemoryClipLoader
    private let generator: AVAssetImageGenerator

    init(clip: Data) {
        loader = InMemoryClipLoader(data: clip)
        generator = AVAssetImageGenerator(asset: loader.makeAsset())
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
    }

    func frame(at seconds: Double) async -> UIImage? {
        guard let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else {
            return nil
        }
        return UIImage(cgImage: frame)
    }

    /// `count` frames spread evenly through `duration` seconds.
    func strip(count: Int, duration: Double) async -> [UIImage] {
        var frames: [UIImage] = []
        for index in 0..<count {
            if let frame = await frame(at: duration * (Double(index) + 0.5) / Double(count)) {
                frames.append(frame)
            }
        }
        return frames
    }
}

/// Trims a clip: its frames in a strip, with a handle at each end of the
/// part that's kept (a second at least). Dragging a handle shows the frame
/// under it (`onScrub`); letting go sets `range`, then `onScrub(nil)`.
struct ClipTrimBar: View {
    let duration: Double
    let frames: ClipFrames
    @Binding var range: ClosedRange<Double>
    let onScrub: (Double?) -> Void

    /// The shortest part that can be kept, in seconds.
    static let minimum = 1.0
    private static let height: CGFloat = 40
    private static let handle: CGFloat = 13

    @State private var strip: [UIImage] = []
    /// The range while a handle is held, before it's set.
    @State private var draft: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geo in
            let track = max(1, geo.size.width - 2 * Self.handle)
            let shown = draft ?? range
            let x = { (time: Double) in Self.handle + CGFloat(time / duration) * track }
            ZStack(alignment: .topLeading) {
                filmstrip
                    .frame(width: track, height: Self.height)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .offset(x: Self.handle)
                // What's cut off, dimmed.
                Color.black.opacity(0.55)
                    .frame(width: max(0, x(shown.lowerBound) - Self.handle), height: Self.height)
                    .offset(x: Self.handle)
                Color.black.opacity(0.55)
                    .frame(width: max(0, Self.handle + track - x(shown.upperBound)), height: Self.height)
                    .offset(x: x(shown.upperBound))
                // The part kept: framed top and bottom, a handle each end.
                let kept = x(shown.upperBound) - x(shown.lowerBound)
                VStack {
                    Rectangle().frame(height: 2.5)
                    Spacer()
                    Rectangle().frame(height: 2.5)
                }
                .foregroundStyle(.white)
                .frame(width: kept, height: Self.height)
                .offset(x: x(shown.lowerBound))
                .allowsHitTesting(false)
                handle(.start, at: x(shown.lowerBound) - Self.handle, track: track, shown: shown)
                handle(.end, at: x(shown.upperBound), track: track, shown: shown)
            }
            .coordinateSpace(name: "trim")
        }
        .frame(height: Self.height)
        .task { strip = await frames.strip(count: 8, duration: duration) }
    }

    private var filmstrip: some View {
        HStack(spacing: 0) {
            ForEach(strip.indices, id: \.self) { index in
                Image(uiImage: strip[index])
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .background(Color.white.opacity(0.15))
    }

    private enum End { case start, end }

    /// A white tab at one end, drawn `handle` wide with a grip, held by a
    /// 30 pt wide area; VoiceOver adjusts it a quarter second at a time.
    private func handle(_ end: End, at left: CGFloat, track: CGFloat, shown: ClosedRange<Double>) -> some View {
        let time = end == .start ? shown.lowerBound : shown.upperBound
        return UnevenRoundedRectangle(
            topLeadingRadius: end == .start ? 5 : 0, bottomLeadingRadius: end == .start ? 5 : 0,
            bottomTrailingRadius: end == .end ? 5 : 0, topTrailingRadius: end == .end ? 5 : 0,
            style: .continuous
        )
        .fill(.white)
        .overlay {
            Capsule()
                .fill(.black.opacity(0.35))
                .frame(width: 2.5, height: 14)
        }
        .frame(width: Self.handle, height: Self.height)
        .frame(width: 30, height: Self.height + 8)
        .contentShape(Rectangle())
        .offset(x: left - (30 - Self.handle) / 2, y: -4)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                .onChanged { value in
                    let seconds = Double((value.location.x - Self.handle) / track) * duration
                    let moved = moved(end, to: seconds, from: draft ?? range)
                    draft = moved
                    onScrub(end == .start ? moved.lowerBound : moved.upperBound)
                }
                .onEnded { _ in
                    if let draft { range = draft }
                    draft = nil
                    onScrub(nil)
                }
        )
        .accessibilityElement()
        .accessibilityLabel(end == .start ? "Start of the clip" : "End of the clip")
        .accessibilityValue(String(format: "%.1f seconds", time))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.25 : -0.25
            range = moved(end, to: time + step, from: range)
        }
    }

    /// `current` with one end at `seconds`, kept inside the clip and at
    /// least `minimum` long.
    private func moved(_ end: End, to seconds: Double, from current: ClosedRange<Double>) -> ClosedRange<Double> {
        switch end {
        case .start:
            let start = min(max(0, seconds), current.upperBound - Self.minimum)
            return max(0, start)...current.upperBound
        case .end:
            let finish = max(min(duration, seconds), current.lowerBound + Self.minimum)
            return current.lowerBound...min(duration, finish)
        }
    }
}
