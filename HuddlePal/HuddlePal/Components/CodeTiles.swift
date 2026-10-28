import SwiftUI

/// A code shown as tidy tiles, one group each, in even rows: an invite code
/// (8 groups of 4) as two rows of four, a key code (6 groups of 5 digits) as
/// two rows of three. Easier to read out or type than one long line.
struct CodeTiles: View {
    let groups: [String]
    let perRow: Int
    var fontSize: CGFloat = 17
    var color: Color = Theme.textPrimary

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, group in
                        Text(group)
                            .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                            .kerning(1)
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
        // One element that reads as the code: callers set the label.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
    }

    private var rows: [[String]] {
        stride(from: 0, to: groups.count, by: perRow).map { Array(groups[$0..<min($0 + perRow, groups.count)]) }
    }
}

extension CodeTiles {
    init(invite code: InviteCode, fontSize: CGFloat = 17, color: Color = Theme.accent) {
        self.init(groups: code.displayed.split(separator: "-").map(String.init), perRow: 4, fontSize: fontSize, color: color)
    }

    init(keyCode code: String, fontSize: CGFloat = 17) {
        self.init(groups: code.split(separator: " ").map(String.init), perRow: 3, fontSize: fontSize)
    }
}
