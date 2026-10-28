import SwiftUI

/// The welcome cards' small moving pictures, in the app's paper-and-ink
/// look: paper-bordered prints, members' colours for the photos. Each loops
/// quietly with a rest between moves. With Reduce Motion (and in UI tests,
/// which wait for the screen to settle) each holds one frame.
struct WelcomeIllustration: View {
    enum Kind {
        /// One photo a day: a print rises and develops; the days count up.
        case onePhotoADay
        /// Locked until you share: blurred prints behind a lock, until
        /// yours drops in and they clear.
        case lockedUntilYouShare
        /// Yours forever: the archive fills in, day by day.
        case yoursForever
    }

    let kind: Kind

    var body: some View {
        // One container, hidden whole: the card's title and words say it.
        ZStack {
            switch kind {
            case .onePhotoADay: DailyPrint()
            case .lockedUntilYouShare: LockedGrid()
            case .yoursForever: ArchiveGrid()
            }
        }
        .frame(height: 200)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }

    /// Whether to move at all.
    static func animates(reduceMotion: Bool) -> Bool {
        !reduceMotion && !UITestHooks.isUITesting
    }

    /// The photo colours: the members' palette, solids first.
    static let tones = AvatarPalette.hexes.map(AvatarStyle.components(of:))
}

/// A photo as the app prints it: a paper border, a little deeper at the
/// bottom, and a sun over a hill standing in for the picture.
private struct Print: View {
    let colors: [Color]
    var width: CGFloat
    /// 0 is a blank print; 1 has fully developed.
    var developed: Double = 1

    var body: some View {
        ZStack {
            Theme.surfaceElevated
            ZStack(alignment: .bottom) {
                LinearGradient(colors: colors.count > 1 ? colors : [colors[0], colors[0].opacity(0.75)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Ellipse()
                    .fill(.white.opacity(0.22))
                    .frame(width: width * 1.3, height: width * 0.55)
                    .offset(x: -width * 0.2, y: width * 0.3)
                Circle()
                    .fill(.white.opacity(0.55))
                    .frame(width: width * 0.2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(width * 0.14)
            }
            .opacity(developed)
        }
        .frame(width: width, height: width * 1.2)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .padding(width * 0.07)
        .padding(.bottom, width * 0.12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: Theme.shadow, radius: 8, x: 0, y: 4)
    }
}

// MARK: - One photo a day

private struct DailyPrint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var day = 1
    @State private var shown = true
    @State private var developed = 1.0
    @State private var settled = true

    private var tone: [Color] { WelcomeIllustration.tones[(day - 1) % WelcomeIllustration.tones.count] }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Print(colors: WelcomeIllustration.tones[3], width: 84)
                    .rotationEffect(.degrees(-9))
                    .offset(x: -38, y: 6)
                    .opacity(0.9)
                Print(colors: WelcomeIllustration.tones[2], width: 84)
                    .rotationEffect(.degrees(8))
                    .offset(x: 40, y: 4)
                    .opacity(0.9)
                Print(colors: tone, width: 96, developed: developed)
                    .rotationEffect(.degrees(settled ? -2 : 3))
                    .offset(y: shown ? 0 : 36)
                    .opacity(shown ? 1 : 0)
            }
            Text("Day \(day)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .contentTransition(.numericText())
        }
        .task {
            guard WelcomeIllustration.animates(reduceMotion: reduceMotion) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeIn(duration: 0.35)) { shown = false }
                try? await Task.sleep(for: .seconds(0.45))
                developed = 0
                settled = false
                withAnimation(.snappy) { day = day % 30 + 1 }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                    shown = true
                    settled = true
                }
                try? await Task.sleep(for: .seconds(0.5))
                withAnimation(.easeInOut(duration: 1.4)) { developed = 1 }
                try? await Task.sleep(for: .seconds(1.4))
            }
        }
    }
}

// MARK: - Locked until you share

private struct LockedGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var yoursIn = false
    @State private var open = false

    private let size: CGFloat = 58

    var body: some View {
        ZStack {
            Grid(horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    theirs(0, tilt: -3)
                    theirs(1, tilt: 2)
                }
                GridRow {
                    theirs(4, tilt: 2)
                    yours
                }
            }
            ZStack {
                Circle()
                    .fill(Theme.surface)
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                    .shadow(color: Theme.shadow, radius: 10, x: 0, y: 4)
                Image(systemName: open ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 54, height: 54)
            .scaleEffect(open ? 0.6 : 1)
            .opacity(open ? 0 : 1)
        }
        .task {
            guard WelcomeIllustration.animates(reduceMotion: reduceMotion) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) { yoursIn = true }
                try? await Task.sleep(for: .seconds(0.7))
                withAnimation(.easeOut(duration: 0.6)) { open = true }
                try? await Task.sleep(for: .seconds(2.2))
                withAnimation(.easeInOut(duration: 0.6)) {
                    open = false
                    yoursIn = false
                }
                try? await Task.sleep(for: .seconds(0.6))
            }
        }
    }

    private func theirs(_ tone: Int, tilt: Double) -> some View {
        Print(colors: WelcomeIllustration.tones[tone], width: size)
            .blur(radius: open ? 0 : 7)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.surface.opacity(open ? 0 : 0.35))
            }
            .rotationEffect(.degrees(tilt))
    }

    /// Your print, or the empty place where it goes.
    private var yours: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.textSecondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(width: size * 1.14, height: size * 1.46)
                .opacity(yoursIn ? 0 : 1)
            Print(colors: WelcomeIllustration.tones[6], width: size)
                .rotationEffect(.degrees(-2))
                .scaleEffect(yoursIn ? 1 : 1.25)
                .opacity(yoursIn ? 1 : 0)
        }
    }
}

// MARK: - Yours forever

private struct ArchiveGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filled = ArchiveGrid.days

    private static let columns = 7
    private static let days = 28
    private let cell: CGFloat = 22

    var body: some View {
        VStack(spacing: 14) {
            Grid(horizontalSpacing: 7, verticalSpacing: 7) {
                ForEach(0..<(Self.days / Self.columns), id: \.self) { row in
                    GridRow {
                        ForEach(0..<Self.columns, id: \.self) { column in
                            day(row * Self.columns + column)
                        }
                    }
                }
            }
            Image(systemName: "archivebox.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
        }
        .task {
            guard WelcomeIllustration.animates(reduceMotion: reduceMotion) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation(.easeInOut(duration: 0.5)) { filled = 0 }
                try? await Task.sleep(for: .seconds(0.7))
                for count in 1...Self.days {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { filled = count }
                    try? await Task.sleep(for: .seconds(0.08))
                }
            }
        }
    }

    private func day(_ index: Int) -> some View {
        let tone = WelcomeIllustration.tones[(index * 5) % WelcomeIllustration.tones.count]
        return ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.surfaceElevated)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: tone.count > 1 ? tone : [tone[0], tone[0].opacity(0.75)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .scaleEffect(index < filled ? 1 : 0.3)
                .opacity(index < filled ? 1 : 0)
        }
        .frame(width: cell, height: cell)
    }
}
