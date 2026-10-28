import SwiftUI

/// The welcome cards' small moving pictures, in the app's paper-and-ink
/// look: paper-bordered prints, members' colours for the photos. Each loops
/// quietly with a rest between moves. With Reduce Motion (and in UI tests,
/// which wait for the screen to settle) each holds one frame.
struct WelcomeIllustration: View {
    enum Kind {
        /// One photo a day: a day goes by, behind the whole card
        /// (`DayGoesByScene`, which the welcome step draws).
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
            case .onePhotoADay: Color.clear
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
        !reduceMotion && (!UITestHooks.isUITesting || UITestHooks.motion)
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

// MARK: - One photo a day: a day goes by

/// The first welcome card's backdrop, behind the whole screen: a day passes
/// (dawn, noon, dusk, night, with the sun, clouds, moon and stars), and once
/// a day the camera snaps and that day's print clips onto a line while the
/// older ones move along. Everything runs off one clock, so it loops without
/// drifting; with Reduce Motion (and in UI tests) it holds noon.
struct DayGoesByScene: View {
    /// Moving only while its card shows.
    var isActive = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var start = Date()

    /// One day, in seconds, and when in it the camera snaps.
    static let day = 9.0
    static let snapAt = 0.3 * day

    /// It reaches under the status bar and the home indicator, and keeps
    /// what it says clear of them.
    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width, height: geo.size.height + insets.top + insets.bottom)
            Group {
                if WelcomeIllustration.animates(reduceMotion: reduceMotion) {
                    TimelineView(.animation(paused: !isActive)) { timeline in
                        scene(at: timeline.date.timeIntervalSince(start), size: full, top: insets.top)
                    }
                } else {
                    // Just after the day's photo, settled.
                    scene(at: Self.snapAt + 2.4, size: full, top: insets.top)
                }
            }
            .frame(width: full.width, height: full.height)
            .offset(y: -insets.top)
        }
        .accessibilityHidden(true)
    }

    private func scene(at t: Double, size: CGSize, top: CGFloat) -> some View {
        let w = size.width
        let k = w / 390
        // Clear of the words, the dots and the button below it.
        let skyHeight = min(size.height * 0.66, size.height - 330)
        let cycle = (t / Self.day).rounded(.down)
        let u = t - cycle * Self.day
        let phase = u / Self.day
        let colors = SkyColors(dark: colorScheme == .dark)

        return ZStack(alignment: .topLeading) {
            Theme.background

            // The sky, one gradient per time of day, crossfading.
            ZStack {
                sky(colors.dawn).opacity(ramp(phase, [(0, 1), (0.22, 0), (0.9, 0), (1, 1)]))
                sky(colors.noon).opacity(ramp(phase, [(0, 0), (0.22, 1), (0.38, 1), (0.5, 0)]))
                sky(colors.dusk).opacity(ramp(phase, [(0.38, 0), (0.5, 1), (0.6, 1), (0.72, 0)]))
                ZStack(alignment: .topLeading) {
                    sky(colors.night)
                    ForEach(Self.stars.indices, id: \.self) { i in
                        let star = Self.stars[i]
                        Circle()
                            .fill(.white)
                            .frame(width: 3 * star.size, height: 3 * star.size)
                            .opacity(0.25 + 0.75 * (0.5 + 0.5 * sin(t * 2 * .pi / 2.6 + star.twinkle)))
                            .position(x: star.x * w, y: star.y * skyHeight)
                    }
                }
                .opacity(ramp(phase, [(0.6, 0), (0.72, 1), (0.9, 1), (1, 0)]))
            }
            .frame(width: w, height: skyHeight)

            sunAndMoon(phase: phase, w: w, k: k, skyHeight: skyHeight, colors: colors)
            clouds(t: t, k: k, skyHeight: skyHeight, colors: colors)

            // Into the page's own colour, where the words are.
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .bottom)
                .frame(width: w, height: skyHeight * 0.29)
                .offset(y: skyHeight * 0.71)

            clothesline(t: t, u: u, cycle: Int(cycle), w: w, k: k, skyHeight: skyHeight, colors: colors)
            camera(u: u, w: w, k: k, skyHeight: skyHeight, colors: colors)

            Text("DAY \(Int(cycle) + 1 + (u >= Self.snapAt ? 1 : 0))")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                .padding(.top, top + 10)
                .padding(.leading, 20)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    private func sky(_ pair: (Color, Color)) -> some View {
        LinearGradient(colors: [pair.0, pair.1], startPoint: .top, endPoint: .bottom)
    }

    private func sunAndMoon(phase: Double, w: CGFloat, k: CGFloat, skyHeight: CGFloat, colors: SkyColors) -> some View {
        let base = skyHeight * 0.536
        func arc(_ s: Double, peak: CGFloat) -> CGPoint {
            CGPoint(x: -0.1 * w + 1.2 * w * s, y: base - peak * sin(.pi * s))
        }
        let sun = phase < 0.6 ? arc(phase / 0.6, peak: skyHeight * 0.366) : nil
        let moon = phase >= 0.6 ? arc((phase - 0.6) / 0.4, peak: skyHeight * 0.31) : nil
        return ZStack(alignment: .topLeading) {
            if let sun {
                Circle()
                    .fill(colors.sun)
                    .frame(width: 62 * k, height: 62 * k)
                    .shadow(color: colors.sun.opacity(0.45), radius: 24 * k)
                    .position(sun)
            }
            if let moon {
                Circle()
                    .fill(colors.moon)
                    .frame(width: 44 * k, height: 44 * k)
                    .shadow(color: .white.opacity(0.22), radius: 14 * k)
                    .position(moon)
            }
        }
    }

    private func clouds(t: Double, k: CGFloat, skyHeight: CGFloat, colors: SkyColors) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Self.cloudPaths.indices, id: \.self) { i in
                let cloud = Self.cloudPaths[i]
                let progress = ((t + cloud.lead) / cloud.duration).truncatingRemainder(dividingBy: 1)
                Cloud(width: cloud.width * k)
                    .fill(colors.cloud)
                    .frame(width: cloud.width * k, height: 46 * k)
                    .opacity(cloud.opacity)
                    .position(x: (-170 + 600 * progress) * k + cloud.width * k / 2, y: skyHeight * cloud.y)
            }
        }
    }

    // MARK: The line

    private static let slots: [CGFloat] = [-0.128, 0.133, 0.377, 0.62, 0.864]

    private func clothesline(t: Double, u: Double, cycle n: Int, w: CGFloat, k: CGFloat, skyHeight: CGFloat, colors: SkyColors) -> some View {
        let base = skyHeight * 0.536
        let dip = skyHeight * (45 / 560)
        let left = -10 * k
        let right = w + 10 * k
        func lineY(_ x: CGFloat) -> CGFloat {
            let s = (x - left) / (right - left)
            return base + 2 * dip * s * (1 - s)
        }
        func slotX(_ slot: Double) -> CGFloat {
            let clamped = min(max(slot, 0), 4)
            let i = min(Int(clamped), 3)
            let f = CGFloat(clamped - Double(i))
            return (Self.slots[i] + (Self.slots[i + 1] - Self.slots[i]) * f) * w
        }
        let printWidth = 0.195 * w
        let printHeight = printWidth * 1.28
        let shift = u >= Self.snapAt ? ease(min(1, (u - Self.snapAt) / 0.76)) : 0

        var hung: [HungPrint] = []
        for day in (n - 3)...n {
            let slot = Double(4 - (n - day)) - shift
            let x = slotX(slot)
            hung.append(HungPrint(
                day: day, x: x, top: lineY(x) - 7 * k,
                tilt: 2.4 * sin(t * 2 * .pi / 3.6 + Double(day) * 1.7),
                developed: 1, opacity: min(1, max(0, slot * 2))
            ))
        }
        let dropStart = Self.snapAt + 0.24
        if u >= dropStart {
            let q = min(1, (u - dropStart) / 0.95)
            let x = slotX(4)
            let landed = lineY(x) - 7 * k
            let top: CGFloat
            let tilt: Double
            if q < 0.7 {
                top = -printHeight + (lineY(x) + 8 * k + printHeight) * ease(q / 0.7)
                tilt = 10 - 13 * (q / 0.7)
            } else {
                top = lineY(x) + 8 * k + (landed - lineY(x) - 8 * k) * ease((q - 0.7) / 0.3)
                tilt = -3 + 3 * ((q - 0.7) / 0.3)
            }
            let settle = min(1, max(0, (u - dropStart - 0.95) / 0.6))
            hung.append(HungPrint(
                day: n + 1, x: x, top: top,
                tilt: tilt + settle * 2.4 * sin(t * 2 * .pi / 3.6 + Double(n + 1) * 1.7),
                developed: min(1, max(0, (u - Self.snapAt - 0.44) / 1.5)), opacity: 1
            ))
        }

        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: left, y: base))
                path.addQuadCurve(to: CGPoint(x: right, y: base), control: CGPoint(x: w / 2, y: base + dip))
            }
            .stroke(colors.string, lineWidth: 1.6)

            ForEach(hung) { item in
                let tone = WelcomeIllustration.tones[((item.day % 8) + 8) % 8]
                Print(colors: tone, width: printWidth / 1.14, developed: item.developed)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(colors.peg)
                            .frame(width: 8 * k, height: 22 * k)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                            .offset(y: -11 * k)
                    }
                    .rotationEffect(.degrees(item.tilt), anchor: .top)
                    .opacity(item.opacity)
                    .position(x: item.x, y: item.top + printHeight / 2)
            }
        }
    }

    /// The viewfinder closing in, then the flash.
    private func camera(u: Double, w: CGFloat, k: CGFloat, skyHeight: CGFloat, colors: SkyColors) -> some View {
        let appear = min(1, max(0, (u - (Self.snapAt - 0.48)) / 0.32))
        let gone = min(1, max(0, (u - Self.snapAt - 0.12) / 0.3))
        let finder = u > Self.snapAt + 0.5 ? 0 : appear * (1 - gone)
        let f = (u - Self.snapAt) / 0.44
        let flash = (0...1).contains(f) ? (f < 0.15 ? f / 0.15 : 1 - (f - 0.15) / 0.85) : 0
        return ZStack(alignment: .topLeading) {
            Viewfinder()
                .stroke(.white, style: StrokeStyle(lineWidth: 3 * k, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.35), radius: 1.5)
                .frame(width: 166 * k, height: 124 * k)
                .scaleEffect(1.25 - 0.25 * ease(appear))
                .opacity(finder)
                .position(x: w / 2, y: skyHeight * 0.3)
            colors.flash
                .opacity(flash)
                .frame(width: w, height: skyHeight / 0.66)
        }
    }

    // MARK: Parts

    private struct HungPrint: Identifiable {
        let day: Int
        let x: CGFloat
        let top: CGFloat
        let tilt: Double
        let developed: Double
        let opacity: Double
        var id: Int { day }
    }

    private struct Star {
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let twinkle: Double
    }

    /// Where the stars are: the same sky every time.
    private static let stars: [Star] = {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<26).map { _ in
            Star(x: 0.03 + 0.94 * next(), y: 0.1 + 0.44 * next(), size: 0.6 + 0.8 * next(), twinkle: next() * 2 * .pi)
        }
    }()

    private static let cloudPaths: [(width: CGFloat, y: CGFloat, duration: Double, lead: Double, opacity: Double)] = [
        (112, 124 / 560, 28, 6, 1),
        (84, 206 / 560, 36, 20, 0.8),
        (98, 84 / 560, 44, 31, 0.6),
    ]

    private func ramp(_ x: Double, _ points: [(Double, Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for (a, b) in zip(points, points.dropFirst()) where x <= b.0 {
            return a.1 + (b.1 - a.1) * (x - a.0) / (b.0 - a.0)
        }
        return last.1
    }

    private func ease(_ x: Double) -> CGFloat {
        let c = min(1, max(0, x))
        return CGFloat(c < 0.5 ? 2 * c * c : 1 - pow(-2 * c + 2, 2) / 2)
    }
}

/// The sky's colours, light or dark.
private struct SkyColors {
    let dawn: (Color, Color)
    let noon: (Color, Color)
    let dusk: (Color, Color)
    let night: (Color, Color)
    let sun: Color
    let moon: Color
    let cloud: Color
    let string: Color
    let peg: Color
    let flash: Color

    init(dark: Bool) {
        if dark {
            dawn = (Color(hex: "4A2F2A"), Color(hex: "221C1B"))
            noon = (Color(hex: "1D3346"), Color(hex: "1A2128"))
            dusk = (Color(hex: "352A4C"), Color(hex: "241C26"))
            night = (Color(hex: "0B0D18"), Color(hex: "1A1A2D"))
            sun = Color(hex: "F2B25A")
            moon = Color(hex: "E9E7E1")
            cloud = .white.opacity(0.08)
            string = Color(hex: "6E6D69")
            peg = Color(hex: "9C7D5E")
            flash = .white.opacity(0.4)
        } else {
            dawn = (Color(hex: "F6D3BD"), Color(hex: "FBF0E8"))
            noon = (Color(hex: "CDE2F6"), Color(hex: "F1F6FB"))
            dusk = (Color(hex: "DCC9EE"), Color(hex: "F6E4EA"))
            night = (Color(hex: "22243A"), Color(hex: "3F3A5A"))
            sun = Color(hex: "FFC261")
            moon = Color(hex: "F3F2EF")
            cloud = .white.opacity(0.85)
            string = Color(hex: "8F8E89")
            peg = Color(hex: "C9A27A")
            flash = .white.opacity(0.92)
        }
    }
}

/// A soft cloud: a long base with two puffs on top.
private struct Cloud: Shape {
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        let k = width / 112
        var path = Path()
        let base = CGRect(x: rect.minX, y: rect.maxY - 26 * k, width: rect.width, height: 26 * k)
        path.addRoundedRect(in: base, cornerSize: CGSize(width: 13 * k, height: 13 * k))
        path.addEllipse(in: CGRect(x: rect.minX + 18 * k, y: base.minY - 20 * k, width: 42 * k, height: 42 * k))
        path.addEllipse(in: CGRect(x: rect.minX + 50 * k, y: base.minY - 12 * k, width: 30 * k, height: 30 * k))
        return path
    }
}

/// A camera's four corner brackets.
private struct Viewfinder: Shape {
    func path(in rect: CGRect) -> Path {
        let arm: CGFloat = 22
        var path = Path()
        for (corner, dx, dy) in [
            (CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
            (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0),
        ] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        }
        return path
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
