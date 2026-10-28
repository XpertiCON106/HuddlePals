import SwiftUI

/// The welcome cards' photos, drawn: little scenes in soft light, with
/// people and animals as ink silhouettes against the sky (the app's paper
/// and ink), so they read as moments people share without being anyone in
/// particular. Each is drawn on a 100 × 120 canvas and fills its frame.
enum WelcomePicture: CaseIterable {
    case friendsOnTheBeach, dogOnTheHill, birthday, coupleAtGoldenHour, catOnTheSill,
         hikeAtDawn, familyWalk, cityLights, campfire

    /// Neighbouring days differ: people, animals and occasions take turns.
    static func of(day: Int) -> WelcomePicture {
        let all = allCases
        return all[((day % all.count) + all.count) % all.count]
    }

    fileprivate func draw(_ s: Sketch) {
        switch self {
        case .friendsOnTheBeach: Self.friendsOnTheBeach(s)
        case .dogOnTheHill: Self.dogOnTheHill(s)
        case .birthday: Self.birthday(s)
        case .coupleAtGoldenHour: Self.coupleAtGoldenHour(s)
        case .catOnTheSill: Self.catOnTheSill(s)
        case .hikeAtDawn: Self.hikeAtDawn(s)
        case .familyWalk: Self.familyWalk(s)
        case .cityLights: Self.cityLights(s)
        case .campfire: Self.campfire(s)
        }
    }
}

/// A welcome picture, filling its frame like a photo (the long side cropped).
struct WelcomePictureView: View {
    let picture: WelcomePicture

    var body: some View {
        Canvas { context, size in
            let scale = max(size.width / 100, size.height / 120)
            context.translateBy(x: (size.width - 100 * scale) / 2, y: (size.height - 120 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            picture.draw(Sketch(context: context))
        }
    }
}

// MARK: - The scenes

private extension WelcomePicture {
    /// Sunset on the beach: three friends, one mid-jump in front of the sun.
    static func friendsOnTheBeach(_ s: Sketch) {
        s.vertical(CGRect(x: 0, y: 0, width: 100, height: 80), ["8E80C2", "E59EA2", "F6BE8C", "FCDCA6"])
        s.glow(at: CGPoint(x: 50, y: 75), radius: 32, "FFE6AE", 0.9)
        s.disc(CGPoint(x: 50, y: 75), 11, "FFF4D9")
        s.vertical(CGRect(x: 0, y: 79, width: 100, height: 19), ["E39A8E", "B47583"])
        for (row, width) in [24.0, 17, 11, 6].enumerated() {
            s.fill(Path(roundedRect: CGRect(x: 50 - width / 2, y: 82 + Double(row) * 3.6, width: width, height: 1.1), cornerRadius: 0.55),
                   "FFE9C8", 0.75 - Double(row) * 0.14)
        }
        s.vertical(CGRect(x: 0, y: 97, width: 100, height: 23), ["6B4A55", "3D2C3A"])
        let ink = "2A2030"
        s.person(.woman, x: 25, ground: 111, height: 35, rightHand: CGPoint(x: 31, y: 70), color: ink)
        s.person(.man, x: 50, ground: 111, height: 38, leftHand: CGPoint(x: 42, y: 58),
                 rightHand: CGPoint(x: 58, y: 58), lift: 9, color: ink)
        s.person(.woman, x: 75, ground: 111, height: 34, leftHand: CGPoint(x: 68, y: 70),
                 rightHand: CGPoint(x: 82, y: 70), color: ink)
    }

    /// An afternoon on the hills: the dog off after a ball.
    static func dogOnTheHill(_ s: Sketch) {
        s.vertical(CGRect(x: 0, y: 0, width: 100, height: 100), ["A8D3EE", "D3E9F3", "FAE6CF"])
        s.glow(at: CGPoint(x: 76, y: 28), radius: 22, "FFF3D6", 0.9)
        s.disc(CGPoint(x: 76, y: 28), 7, "FFFBEF")
        s.cloud(at: CGPoint(x: 24, y: 26), width: 26, "FFFFFF", 0.85)
        s.cloud(at: CGPoint(x: 56, y: 44), width: 17, "FFFFFF", 0.6)
        s.hill(from: 78, to: 72, control: CGPoint(x: 40, y: 56), "A6CBB3")
        s.hill(from: 92, to: 84, control: CGPoint(x: 72, y: 68), "6C9C82")
        s.hill(from: 104, to: 110, control: CGPoint(x: 44, y: 84), "263229")
        // A tree on the near hill.
        s.fill(Path(CGRect(x: 12.6, y: 80, width: 2.8, height: 22)), "263229")
        s.disc(CGPoint(x: 14, y: 75), 8.5, "263229")
        s.disc(CGPoint(x: 8.5, y: 81), 6, "263229")
        s.disc(CGPoint(x: 19.5, y: 81), 6, "263229")
        s.dog(x: 34, ground: 95, length: 30, color: "263229")
        s.disc(CGPoint(x: 77, y: 72), 2.8, "263229")
        s.bird(at: CGPoint(x: 40, y: 20), size: 3, "263229", 0.6)
        s.bird(at: CGPoint(x: 47, y: 15), size: 2.4, "263229", 0.5)
    }

    /// A birthday by candlelight: the cake, and lights out of focus behind.
    static func birthday(_ s: Sketch) {
        s.vertical(CGRect(x: 0, y: 0, width: 100, height: 120), ["3C2539", "26182B", "1A1220"])
        for (x, y, r, hex) in [(14.0, 18.0, 7.0, "F6B26B"), (31, 36, 5, "E98A9B"), (83, 15, 8, "FCE0A0"),
                               (67, 36, 5, "F6B26B"), (91, 46, 6, "E98A9B"), (7, 50, 6, "FCE0A0"), (48, 12, 4, "E98A9B")] {
            s.glow(at: CGPoint(x: x, y: y), radius: r * 1.7, hex, 0.35)
            s.disc(CGPoint(x: x, y: y), r, hex, 0.22)
        }
        s.glow(at: CGPoint(x: 50, y: 60), radius: 48, "FFB866", 0.32)
        s.vertical(CGRect(x: 0, y: 100, width: 100, height: 20), ["3A2630", "21161D"])
        s.fill(Path(ellipseIn: CGRect(x: 15, y: 94, width: 70, height: 10)), "E8DCD0")
        s.fill(Path(roundedRect: CGRect(x: 24, y: 69, width: 52, height: 30), cornerRadius: 4), "F7E8D8")
        // Pink icing over the top, dripping down the sides.
        var icing = Path()
        icing.move(to: CGPoint(x: 24, y: 76))
        icing.addLine(to: CGPoint(x: 24, y: 73))
        icing.addQuadCurve(to: CGPoint(x: 28, y: 69), control: CGPoint(x: 24, y: 69))
        icing.addLine(to: CGPoint(x: 72, y: 69))
        icing.addQuadCurve(to: CGPoint(x: 76, y: 73), control: CGPoint(x: 76, y: 69))
        icing.addLine(to: CGPoint(x: 76, y: 76))
        for drip in 0..<8 {
            let right = 76 - Double(drip) * 6.5
            let depth = drip % 2 == 0 ? 8.0 : 4.0
            icing.addCurve(to: CGPoint(x: right - 6.5, y: 76),
                           control1: CGPoint(x: right - 0.6, y: 76 + depth),
                           control2: CGPoint(x: right - 5.9, y: 76 + depth))
        }
        icing.closeSubpath()
        s.fill(icing, "F2A6B6")
        for (x, y, hex) in [(33.0, 89.0, "9FCDEB"), (45, 93, "F6C46E"), (58, 88, "BBA5EA"), (68, 93, "9FCDEB"), (51, 84, "FFFFFF")] {
            s.fill(Path(roundedRect: CGRect(x: x, y: y, width: 2.4, height: 1), cornerRadius: 0.5), hex, 0.9)
        }
        for (x, hex) in [(38.0, "9FCDEB"), (50, "F6C46E"), (62, "BBA5EA")] {
            s.fill(Path(roundedRect: CGRect(x: x - 1.4, y: 55, width: 2.8, height: 15), cornerRadius: 0.8), hex)
            s.glow(at: CGPoint(x: x, y: 50), radius: 8, "FFD27A", 0.75)
            s.flame(at: CGPoint(x: x, y: 52.5), height: 7, width: 4.4, "FFE6A6")
            s.flame(at: CGPoint(x: x, y: 52.5), height: 3.6, width: 2, "FFFFFF", 0.85)
        }
    }

    /// Golden hour on a hill: a man and a woman, holding hands.
    static func coupleAtGoldenHour(_ s: Sketch) {
        s.vertical(CGRect(x: 0, y: 0, width: 100, height: 100), ["F9DFAA", "F7BD84", "EE9268"])
        s.glow(at: CGPoint(x: 62, y: 77), radius: 36, "FFE6A6", 0.85)
        s.disc(CGPoint(x: 62, y: 77), 13, "FFF4D8")
        s.bird(at: CGPoint(x: 22, y: 30), size: 3, "2B211E", 0.75)
        s.bird(at: CGPoint(x: 30, y: 24), size: 2.4, "2B211E", 0.65)
        s.bird(at: CGPoint(x: 35, y: 33), size: 2, "2B211E", 0.55)
        s.hill(from: 98, to: 94, control: CGPoint(x: 52, y: 76), "2B211E")
        s.person(.man, x: 43.5, ground: 87.4, height: 36, rightHand: CGPoint(x: 49.6, y: 74.6), color: "2B211E")
        s.person(.woman, x: 56, ground: 87.2, height: 32.5, leftHand: CGPoint(x: 50.2, y: 74.8), color: "2B211E")
    }

    /// Night at the window: the cat watching the moon.
    static func catOnTheSill(_ s: Sketch) {
        s.vertical(CGRect(x: 0, y: 0, width: 100, height: 120), ["2C2F48", "1D1F33"])
        let window = CGRect(x: 14, y: 8, width: 72, height: 82)
        s.vertical(window, ["1E2C56", "37477A", "56649A"])
        for (x, y, r) in [(22.0, 16.0, 0.7), (34, 27, 0.5), (45, 15, 0.6), (27, 42, 0.5), (79, 56, 0.6),
                          (57, 20, 0.5), (39, 60, 0.5), (75, 72, 0.5), (20, 70, 0.6), (82, 16, 0.5)] {
            s.disc(CGPoint(x: x, y: y), r, "FFFFFF", 0.8)
        }
        s.glow(at: CGPoint(x: 66, y: 30), radius: 22, "F6F0DA", 0.28)
        s.crescent(at: CGPoint(x: 66, y: 30), radius: 8.5, "F6F0DA")
        let frame = "15172A"
        s.context.stroke(Path(window), with: .color(Color(hex: frame)), lineWidth: 3)
        s.fill(Path(CGRect(x: 48.8, y: 8, width: 2.4, height: 82)), frame)
        s.fill(Path(CGRect(x: 14, y: 47.8, width: 72, height: 2.4)), frame)
        s.fill(Path(CGRect(x: 6, y: 90, width: 88, height: 7)), "34385A")
        s.fill(Path(CGRect(x: 6, y: 97, width: 88, height: 2)), frame, 0.6)
        // A plant on the sill.
        var pot = Path()
        pot.move(to: CGPoint(x: 70, y: 81))
        pot.addLine(to: CGPoint(x: 80, y: 81))
        pot.addLine(to: CGPoint(x: 78.6, y: 90))
        pot.addLine(to: CGPoint(x: 71.4, y: 90))
        pot.closeSubpath()
        s.fill(pot, "101225")
        for (x, y, r) in [(75.0, 76.0, 4.2), (71.5, 73.0, 3.0), (78.5, 72.0, 3.2), (75, 69.5, 2.6)] {
            s.disc(CGPoint(x: x, y: y), r, "101225")
        }
        s.cat(x: 38, ground: 90.5, height: 30, color: "101225")
    }

    /// Dawn in the mountains: someone at the top, arms up.
    static func hikeAtDawn(_ s: Sketch) {
        s.vertical(CGRect(x: 0, y: 0, width: 100, height: 120), ["F2C2B6", "F8D9CA", "FCEADC"])
        s.glow(at: CGPoint(x: 70, y: 46), radius: 26, "FFF1DA", 0.9)
        s.disc(CGPoint(x: 70, y: 46), 8.5, "FFF8EB")
        s.ridge([(0, 70), (14, 58), (26, 66), (40, 50), (56, 64), (70, 54), (86, 66), (100, 57)], "CBBFDB")
        s.ridge([(0, 82), (18, 70), (32, 80), (48, 66), (62, 78), (80, 68), (100, 80)], "A196C2")
        s.ridge([(0, 98), (22, 84), (40, 93), (58, 80), (76, 92), (100, 85)], "6C6290")
        s.ridge([(0, 112), (16, 100), (30, 90.4), (46, 102), (70, 108), (100, 103)], "2E2942")
        s.person(.man, x: 30, ground: 90.6, height: 22, leftHand: CGPoint(x: 25.6, y: 66.6),
                 rightHand: CGPoint(x: 34.4, y: 66.6), color: "2E2942")
        s.bird(at: CGPoint(x: 58, y: 28), size: 2.6, "2E2942", 0.6)
        s.bird(at: CGPoint(x: 64, y: 24), size: 2, "2E2942", 0.5)
    }

    /// A walk at dusk: mum, dad and their child, hand in hand.
    static func familyWalk(_ s: Sketch) {
        s.vertical(CGRect(x: 0, y: 0, width: 100, height: 100), ["F2BCAE", "F8D5C2", "FBE8D9"])
        s.glow(at: CGPoint(x: 77, y: 84), radius: 30, "FFF0DC", 0.9)
        s.disc(CGPoint(x: 77, y: 84), 10, "FFF7EB")
        s.hill(from: 96, to: 92, control: CGPoint(x: 50, y: 86), "3A2C33")
        s.fill(Path(CGRect(x: 83.3, y: 79, width: 1.4, height: 12)), "3A2C33")
        s.disc(CGPoint(x: 84, y: 77), 5.5, "3A2C33")
        s.fill(Path(CGRect(x: 91.4, y: 81, width: 1.2, height: 10)), "3A2C33")
        s.disc(CGPoint(x: 92, y: 79.5), 4, "3A2C33")
        let ink = "3A2C33"
        s.person(.man, x: 30, ground: 91, height: 36, rightHand: CGPoint(x: 37.2, y: 78.6), color: ink)
        s.person(.child, x: 42, ground: 91, height: 21, leftHand: CGPoint(x: 37.4, y: 78.8),
                 rightHand: CGPoint(x: 46.8, y: 78.8), color: ink)
        s.person(.woman, x: 54, ground: 91, height: 32, leftHand: CGPoint(x: 47, y: 78.8), color: ink)
    }

    /// The city at dusk, its windows lighting up.
    static func cityLights(_ s: Sketch) {
        s.vertical(CGRect(x: 0, y: 0, width: 100, height: 104), ["23254E", "4A3A6D", "A46381", "F09C7A"])
        for (x, y, r) in [(40.0, 10.0, 0.5), (58, 18, 0.6), (76, 8, 0.5), (88, 26, 0.5), (10, 34, 0.5), (66, 30, 0.4)] {
            s.disc(CGPoint(x: x, y: y), r, "FFFFFF", 0.75)
        }
        s.glow(at: CGPoint(x: 22, y: 22), radius: 16, "F5EFD9", 0.25)
        s.crescent(at: CGPoint(x: 22, y: 22), radius: 6.5, "F5EFD9")
        for (x, width, top) in [(4.0, 10.0, 80.0), (24, 12, 74), (44, 10, 82), (66, 12, 76), (86, 10, 80)] {
            s.fill(Path(CGRect(x: x, y: top, width: width, height: 120 - top)), "3A3155")
        }
        var random = SeededRandom(seed: 0xC17)
        s.fill(Path(CGRect(x: 55, y: 44, width: 1, height: 8)), "1C1A2D")
        for (x, width, top) in [(0.0, 12.0, 76.0), (11, 9, 64), (19, 13, 84), (31, 8, 58), (38, 14, 72),
                                (51, 10, 52), (60, 12, 78), (71, 9, 66), (79, 13, 82), (91, 10, 70)] {
            s.fill(Path(CGRect(x: x, y: top, width: width, height: 120 - top)), "1C1A2D")
            var row = top + 4
            while row < 116 {
                var column = x + 2
                while column + 1.5 < x + width - 1 {
                    if random.next() < 0.42 {
                        s.fill(Path(CGRect(x: column, y: row, width: 1.5, height: 2)), "FFD27F", 0.55 + 0.4 * random.next())
                    }
                    column += 3.2
                }
                row += 4
            }
        }
    }

    /// Friends round a campfire, the sky gone dark above them.
    static func campfire(_ s: Sketch) {
        s.vertical(CGRect(x: 0, y: 0, width: 100, height: 96), ["0F1630", "222650", "5B4272"])
        var random = SeededRandom(seed: 0xF1E)
        for _ in 0..<18 {
            s.disc(CGPoint(x: 4 + 92 * random.next(), y: 4 + 56 * random.next()), 0.35 + 0.4 * random.next(), "FFFFFF", 0.5 + 0.4 * random.next())
        }
        s.fill(Path(CGRect(x: 0, y: 94, width: 100, height: 26)), "120F1C")
        s.glow(at: CGPoint(x: 50, y: 94), radius: 42, "FF9A4A", 0.5)
        s.line(from: CGPoint(x: 41, y: 97), to: CGPoint(x: 59, y: 93), width: 2.6, "3B2A22")
        s.line(from: CGPoint(x: 41, y: 93), to: CGPoint(x: 59, y: 97), width: 2.6, "3B2A22")
        s.flame(at: CGPoint(x: 50, y: 95), height: 19, width: 12, "FF7A35")
        s.flame(at: CGPoint(x: 49.4, y: 95), height: 13.5, width: 8.5, "FFA94D")
        s.flame(at: CGPoint(x: 50.4, y: 95), height: 8, width: 5, "FFE19A")
        for (x, y, r) in [(47.0, 70.0, 0.6), (53, 64, 0.5), (50, 57, 0.45), (56, 74, 0.55), (44, 64, 0.4)] {
            s.disc(CGPoint(x: x, y: y), r, "FFD27A", 0.85)
        }
        s.sitting(x: 24, ground: 95, height: 24, facing: 1, color: "0B0A12")
        s.sitting(x: 76, ground: 95, height: 23, facing: -1, color: "0B0A12")
    }
}

// MARK: - Drawing

/// Drawing helpers on a 100 × 120 canvas; colours are hex strings.
private struct Sketch {
    let context: GraphicsContext

    func fill(_ path: Path, _ hex: String, _ opacity: Double = 1) {
        context.fill(path, with: .color(Color(hex: hex).opacity(opacity)))
    }

    /// A gradient top to bottom through `hexes`.
    func vertical(_ rect: CGRect, _ hexes: [String]) {
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: hexes.map { Color(hex: $0) }),
            startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)
        ))
    }

    func disc(_ center: CGPoint, _ radius: CGFloat, _ hex: String, _ opacity: Double = 1) {
        fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)), hex, opacity)
    }

    /// Soft light, fading out to `radius`.
    func glow(at center: CGPoint, radius: CGFloat, _ hex: String, _ opacity: Double) {
        let color = Color(hex: hex).opacity(opacity)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)),
            with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: center, startRadius: 0, endRadius: radius)
        )
    }

    func line(from start: CGPoint, to end: CGPoint, width: CGFloat, _ hex: String, _ opacity: Double = 1) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        stroke(path, width: width, hex, opacity)
    }

    func stroke(_ path: Path, width: CGFloat, _ hex: String, _ opacity: Double = 1) {
        context.stroke(path, with: .color(Color(hex: hex).opacity(opacity)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    /// Land from the left edge at `from` to the right edge at `to`, rising
    /// toward `control`, down to the bottom of the picture.
    func hill(from left: CGFloat, to right: CGFloat, control: CGPoint, _ hex: String) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: left))
        path.addQuadCurve(to: CGPoint(x: 100, y: right), control: control)
        path.addLine(to: CGPoint(x: 100, y: 120))
        path.addLine(to: CGPoint(x: 0, y: 120))
        path.closeSubpath()
        fill(path, hex)
    }

    /// A mountain range through `points`, down to the bottom.
    func ridge(_ points: [(CGFloat, CGFloat)], _ hex: String) {
        var path = Path()
        path.move(to: CGPoint(x: points[0].0, y: 120))
        for (x, y) in points { path.addLine(to: CGPoint(x: x, y: y)) }
        path.addLine(to: CGPoint(x: points[points.count - 1].0, y: 120))
        path.closeSubpath()
        fill(path, hex)
    }

    func cloud(at center: CGPoint, width: CGFloat, _ hex: String, _ opacity: Double) {
        let k = width / 26
        var path = Path()
        path.addRoundedRect(in: CGRect(x: center.x - 13 * k, y: center.y, width: 26 * k, height: 7 * k), cornerSize: CGSize(width: 3.5 * k, height: 3.5 * k))
        path.addEllipse(in: CGRect(x: center.x - 8 * k, y: center.y - 5 * k, width: 10 * k, height: 10 * k))
        path.addEllipse(in: CGRect(x: center.x - 1 * k, y: center.y - 3 * k, width: 8 * k, height: 8 * k))
        fill(path, hex, opacity)
    }

    func bird(at point: CGPoint, size: CGFloat, _ hex: String, _ opacity: Double) {
        var path = Path()
        path.move(to: CGPoint(x: point.x - size, y: point.y - size * 0.45))
        path.addQuadCurve(to: point, control: CGPoint(x: point.x - size * 0.45, y: point.y - size * 0.75))
        path.addQuadCurve(to: CGPoint(x: point.x + size, y: point.y - size * 0.45), control: CGPoint(x: point.x + size * 0.45, y: point.y - size * 0.75))
        stroke(path, width: size * 0.28, hex, opacity)
    }

    /// The moon a few days old.
    func crescent(at center: CGPoint, radius: CGFloat, _ hex: String) {
        let moon = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        let shade = Path(ellipseIn: CGRect(x: center.x - radius * 0.45, y: center.y - radius * 1.35, width: 2 * radius, height: 2 * radius))
        fill(moon.subtracting(shade), hex)
    }

    /// A flame standing on `base`, its tip `height` above.
    func flame(at base: CGPoint, height: CGFloat, width: CGFloat, _ hex: String, _ opacity: Double = 1) {
        var path = Path()
        path.move(to: CGPoint(x: base.x, y: base.y - height))
        path.addQuadCurve(to: CGPoint(x: base.x + width / 2, y: base.y - height * 0.28),
                          control: CGPoint(x: base.x + width * 0.55, y: base.y - height * 0.62))
        path.addQuadCurve(to: CGPoint(x: base.x - width / 2, y: base.y - height * 0.28),
                          control: CGPoint(x: base.x, y: base.y + height * 0.22))
        path.addQuadCurve(to: CGPoint(x: base.x, y: base.y - height),
                          control: CGPoint(x: base.x - width * 0.55, y: base.y - height * 0.62))
        fill(path, hex, opacity)
    }

    enum Build { case man, woman, child }

    /// Someone standing, in silhouette: feet at `ground`, `height` tall.
    /// Hands hang at the sides unless placed; `lift` is a jump, legs apart.
    /// A woman has long hair and a dress.
    func person(_ build: Build, x: CGFloat, ground: CGFloat, height h: CGFloat,
                leftHand: CGPoint? = nil, rightHand: CGPoint? = nil, lift: CGFloat = 0, color: String) {
        let feet = ground - lift
        let r = h * (build == .child ? 0.13 : 0.09)
        let head = CGPoint(x: x, y: feet - h + r)
        let shoulders = head.y + r + h * 0.035
        let hips = feet - h * (build == .child ? 0.4 : 0.46)
        let halfShoulders = h * (build == .man ? 0.13 : 0.11)

        if build == .woman {
            fill(Path(roundedRect: CGRect(x: x - r * 1.2, y: head.y - r * 0.96, width: r * 2.4, height: r * 3.5), cornerRadius: r), color)
        }
        disc(head, r, color)
        fill(Path(CGRect(x: x - h * 0.03, y: head.y + r * 0.5, width: h * 0.06, height: shoulders - head.y - r * 0.5 + h * 0.02)), color)

        var body = Path()
        body.move(to: CGPoint(x: x - halfShoulders, y: shoulders + h * 0.035))
        body.addQuadCurve(to: CGPoint(x: x - halfShoulders + h * 0.045, y: shoulders), control: CGPoint(x: x - halfShoulders, y: shoulders))
        body.addLine(to: CGPoint(x: x + halfShoulders - h * 0.045, y: shoulders))
        body.addQuadCurve(to: CGPoint(x: x + halfShoulders, y: shoulders + h * 0.035), control: CGPoint(x: x + halfShoulders, y: shoulders))
        if build == .woman {
            body.addLine(to: CGPoint(x: x + h * 0.08, y: hips - h * 0.07))
            body.addLine(to: CGPoint(x: x + h * 0.16, y: feet - h * 0.2))
            body.addQuadCurve(to: CGPoint(x: x - h * 0.16, y: feet - h * 0.2), control: CGPoint(x: x, y: feet - h * 0.16))
            body.addLine(to: CGPoint(x: x - h * 0.08, y: hips - h * 0.07))
        } else {
            body.addLine(to: CGPoint(x: x + h * 0.095, y: hips))
            body.addLine(to: CGPoint(x: x - h * 0.095, y: hips))
        }
        body.closeSubpath()
        fill(body, color)

        let legWidth = h * (build == .woman ? 0.056 : 0.088)
        let legTop = build == .woman ? feet - h * 0.24 : hips
        let apart = lift > 0 ? h * 0.11 : h * 0.045
        for side in [-1.0, 1.0] {
            line(from: CGPoint(x: x + side * h * 0.045, y: legTop),
                 to: CGPoint(x: x + side * apart, y: feet - legWidth / 2), width: legWidth, color)
        }

        let armWidth = h * (build == .man ? 0.074 : 0.064)
        for (side, hand) in [(-1.0, leftHand), (1.0, rightHand)] {
            let shoulder = CGPoint(x: x + side * (halfShoulders - h * 0.035), y: shoulders + h * 0.035)
            let end = hand ?? CGPoint(x: x + side * (halfShoulders + h * 0.025), y: hips + h * 0.03)
            line(from: shoulder, to: end, width: armWidth, color)
        }
    }

    /// Someone sitting on the ground, knees up, facing right (1) or left (-1).
    func sitting(x: CGFloat, ground g: CGFloat, height h: CGFloat, facing: CGFloat, color: String) {
        let hip = CGPoint(x: x, y: g - h * 0.1)
        let shoulder = CGPoint(x: x + facing * h * 0.07, y: g - h * 0.62)
        disc(CGPoint(x: shoulder.x + facing * h * 0.05, y: shoulder.y - h * 0.2), h * 0.13, color)
        line(from: hip, to: shoulder, width: h * 0.26, color)
        let knee = CGPoint(x: x + facing * h * 0.34, y: g - h * 0.34)
        let foot = CGPoint(x: x + facing * h * 0.47, y: g - h * 0.05)
        var leg = Path()
        leg.move(to: hip)
        leg.addLine(to: knee)
        leg.addLine(to: foot)
        stroke(leg, width: h * 0.13, color)
        line(from: CGPoint(x: shoulder.x, y: shoulder.y + h * 0.07), to: CGPoint(x: knee.x - facing * h * 0.03, y: knee.y + h * 0.04), width: h * 0.09, color)
    }

    /// A dog in silhouette, facing right: `length` from tail to nose.
    func dog(x: CGFloat, ground g: CGFloat, length l: CGFloat, color: String) {
        let top = g - l * 0.52
        fill(Path(roundedRect: CGRect(x: x, y: top, width: l * 0.6, height: l * 0.28), cornerRadius: l * 0.14), color)
        var chest = Path()
        chest.move(to: CGPoint(x: x + l * 0.4, y: top + l * 0.04))
        chest.addLine(to: CGPoint(x: x + l * 0.6, y: g - l * 0.8))
        chest.addLine(to: CGPoint(x: x + l * 0.78, y: g - l * 0.7))
        chest.addLine(to: CGPoint(x: x + l * 0.62, y: top + l * 0.24))
        chest.closeSubpath()
        fill(chest, color)
        let head = CGPoint(x: x + l * 0.7, y: g - l * 0.76)
        disc(head, l * 0.135, color)
        fill(Path(roundedRect: CGRect(x: head.x + l * 0.02, y: head.y - l * 0.01, width: l * 0.24, height: l * 0.12), cornerRadius: l * 0.06), color)
        // A floppy ear, hanging behind the head.
        fill(Path(roundedRect: CGRect(x: head.x - l * 0.13, y: head.y - l * 0.09, width: l * 0.1, height: l * 0.22), cornerRadius: l * 0.05), color)
        let hips = top + l * 0.22
        for start in [0.08, 0.18, 0.44, 0.53] as [CGFloat] {
            line(from: CGPoint(x: x + l * start, y: hips), to: CGPoint(x: x + l * start, y: g - l * 0.045), width: l * 0.09, color)
        }
        var tail = Path()
        tail.move(to: CGPoint(x: x + l * 0.05, y: top + l * 0.07))
        tail.addQuadCurve(to: CGPoint(x: x - l * 0.12, y: top - l * 0.2), control: CGPoint(x: x - l * 0.13, y: top + l * 0.02))
        stroke(tail, width: l * 0.075, color)
    }

    /// A cat sitting, in silhouette, looking right.
    func cat(x: CGFloat, ground g: CGFloat, height h: CGFloat, color: String) {
        var body = Path()
        body.move(to: CGPoint(x: x - h * 0.3, y: g))
        body.addCurve(to: CGPoint(x: x + h * 0.02, y: g - h * 0.72),
                      control1: CGPoint(x: x - h * 0.44, y: g - h * 0.42), control2: CGPoint(x: x - h * 0.15, y: g - h * 0.7))
        body.addCurve(to: CGPoint(x: x + h * 0.22, y: g),
                      control1: CGPoint(x: x + h * 0.16, y: g - h * 0.6), control2: CGPoint(x: x + h * 0.12, y: g - h * 0.3))
        body.closeSubpath()
        fill(body, color)
        let head = CGPoint(x: x + h * 0.07, y: g - h * 0.8)
        disc(head, h * 0.15, color)
        for dx in [-0.1, 0.08] {
            var ear = Path()
            ear.move(to: CGPoint(x: head.x + (dx - 0.05) * h, y: head.y - h * 0.08))
            ear.addLine(to: CGPoint(x: head.x + (dx + 0.01) * h, y: head.y - h * 0.26))
            ear.addLine(to: CGPoint(x: head.x + (dx + 0.08) * h, y: head.y - h * 0.09))
            ear.closeSubpath()
            fill(ear, color)
        }
        var tail = Path()
        tail.move(to: CGPoint(x: x - h * 0.26, y: g - h * 0.05))
        tail.addQuadCurve(to: CGPoint(x: x + h * 0.4, y: g - h * 0.1), control: CGPoint(x: x + h * 0.05, y: g + h * 0.07))
        stroke(tail, width: h * 0.07, color)
    }
}

/// The same "random" every time: windows and stars stay where they are.
private struct SeededRandom {
    var seed: UInt64

    mutating func next() -> CGFloat {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(Double(seed >> 11) / Double(1 << 53))
    }
}
