import SwiftUI

/// HuddlePals' loading spinner, in place of `ProgressView` everywhere: four
/// members circling, pulling in close and spreading out again as they turn,
/// fading from the brightest like a tail. Each starts upright and spread out
/// on its own clock, so it never appears mid-turn (and a pull to refresh
/// turning into a refresh carries straight on). With Reduce Motion the dots
/// stay put and the brightest steps round; in UI tests (which wait for the
/// screen to settle) it holds still, as the welcome cards do.
struct HuddleSpinner: View {
    var size: CGFloat = 36
    var color: Color = Theme.accent
    /// What VoiceOver reads (as a progress indicator). Nil inside a button,
    /// where it's decoration on a button that's busy.
    var label: String? = "Loading"
    /// How far a pull to refresh has come, 0 to 1: the dots appear one by
    /// one, brightest first, and hold still. Nil: it turns.
    var pulled: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Once round, and in and out once, every 2.4 seconds.
    static let turn = 2.4

    var body: some View {
        if let label {
            spinner.accessibilityRepresentation {
                ProgressView().accessibilityLabel(label)
            }
        } else {
            spinner.accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var spinner: some View {
        if let pulled {
            SpinnerDots(size: size, color: color, shown: pulled)
        } else if UITestHooks.isUITesting && !UITestHooks.motion {
            SpinnerDots(size: size, color: color)
        } else {
            TurningDots(size: size, color: color, stepsOnly: reduceMotion)
        }
    }

    /// Clockwise, a turn per `turn`: quicker mid-turn, slower (never
    /// stopped) at the top.
    static func rotation(at t: Double) -> Double {
        let p = t.truncatingRemainder(dividingBy: turn) / turn
        let eased = 0.2 * p + 0.8 * (0.5 - 0.5 * cos(.pi * p))
        return eased * 2 * .pi
    }

    /// In over the first half of a turn, out over the second, resting a
    /// moment at each end: 1 spread out, 0.42 huddled.
    static func gather(at t: Double) -> CGFloat {
        let q = t.truncatingRemainder(dividingBy: turn) / (turn / 2)
        let p = q < 1 ? q : 2 - q
        let x = min(1, max(0, (p - 0.15) / 0.7))
        return CGFloat(1 - 0.58 * x * x * (3 - 2 * x))
    }
}

/// The spinner moving, timed from when it appears: upright and spread out
/// at first, just as a still one (or a finished pull) shows it. `stepsOnly`
/// (Reduce Motion): no turning, the brightest dot steps round instead.
private struct TurningDots: View {
    let size: CGFloat
    let color: Color
    let stepsOnly: Bool

    @State private var start = Date.now

    var body: some View {
        if stepsOnly {
            TimelineView(.periodic(from: start, by: 0.3)) { timeline in
                SpinnerDots(size: size, color: color, head: Int(max(0, timeline.date.timeIntervalSince(start)) / 0.3) % 4)
            }
        } else {
            TimelineView(.animation) { timeline in
                let t = max(0, timeline.date.timeIntervalSince(start))
                SpinnerDots(
                    size: size, color: color,
                    rotation: HuddleSpinner.rotation(at: t), gather: HuddleSpinner.gather(at: t)
                )
            }
        }
    }
}

/// The four dots, clockwise from the top. `head` is the brightest; the
/// others fade behind it (anticlockwise), so turning clockwise, the tail
/// follows. `gather` is 1 spread out, smaller pulled in. `shown` (0 to 1)
/// brings them in one at a time, from the head down the tail.
private struct SpinnerDots: View {
    let size: CGFloat
    let color: Color
    var rotation: Double = 0
    var gather: CGFloat = 1
    var head = 0
    var shown: Double = 1

    var body: some View {
        let diameter = size * 9 / 44 * gather
        let reach = size * 16 / 44 * gather
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                let angle = Double(index) * .pi / 2 - .pi / 2
                let behind = (head - index + 4) % 4
                let arrived = min(1, max(0, shown * 4 - Double(behind)))
                Circle()
                    .fill(color)
                    .opacity((1 - 0.2 * Double(behind)) * arrived)
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(0.5 + 0.5 * arrived)
                    .offset(x: reach * cos(angle), y: reach * sin(angle))
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.radians(rotation))
    }
}
