import AppKit
import SwiftUI

enum Theme {
    // Yuzu's citrus palette. Keep these semantic tokens centralized so the radial
    // can own its identity without changing unrelated operation-specific colors.
    static let yuzuYellowNS = NSColor(srgbRed: 248 / 255, green: 197 / 255, blue: 55 / 255, alpha: 1)
    static let yuzuYellow = Color(nsColor: yuzuYellowNS)
    static let yuzuGoldNS = NSColor(srgbRed: 255 / 255, green: 159 / 255, blue: 28 / 255, alpha: 1)
    static let yuzuGold = Color(nsColor: yuzuGoldNS)
    static let yuzuAmberNS = NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 6 / 255, alpha: 1)
    static let yuzuAmber = Color(nsColor: yuzuAmberNS)
    static let yuzuCreamNS = NSColor(srgbRed: 255 / 255, green: 244 / 255, blue: 194 / 255, alpha: 1)
    static let yuzuCream = Color(nsColor: yuzuCreamNS)
    static let yuzuActiveTextNS = NSColor(srgbRed: 37 / 255, green: 32 / 255, blue: 20 / 255, alpha: 1)
    static let yuzuActiveText = Color(nsColor: yuzuActiveTextNS)

    // Preserve existing callers while keeping a single definition for each color.
    static let citrusYellowNS = yuzuYellowNS
    static let citrusYellow = yuzuYellow
    static let goldenAmberNS = yuzuGoldNS
    static let goldenAmber = yuzuGold
    static let deepAccentNS = yuzuAmberNS
    static let deepAccent = yuzuAmber
    static let softHighlightNS = yuzuCreamNS
    static let softHighlight = yuzuCream
    static let activeTextNS = yuzuActiveTextNS
    static let activeText = yuzuActiveText
    static let activeGradient = LinearGradient(
        colors: [yuzuYellow, yuzuGold],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let activeEdgeHighlight = softHighlight
    static let activeShadow = deepAccent.opacity(0.28)
    static let inactiveStroke = Color(nsColor: .separatorColor).opacity(0.72)
    static let hubStroke = Color(nsColor: .separatorColor).opacity(0.78)
    static let hubShadow = Color.black.opacity(0.2)

    // Shared app accent now follows the Yuzu identity. Literal orange values in
    // tool previews remain operation-specific and are intentionally unchanged.
    static let accentNS = citrusYellowNS
    static let accent = citrusYellow

    static let ink = Color(nsColor: .labelColor)
    static let inkSecondary = Color(nsColor: .secondaryLabelColor)
    static let cardCorner: CGFloat = 12

    // Radial tokens stay separate from ordinary cards so the dial can remain compact and legible.
    static let radialOuterRadius: CGFloat = 166
    static let radialHubDiameter: CGFloat = 118
    static let radialHubRadius: CGFloat = radialHubDiameter / 2
    static let radialHubSeparation: CGFloat = 6
    static let radialSegmentGap: CGFloat = 6
    static let radialSegmentCorner: CGFloat = 15
    static let radialIconSize: CGFloat = 22
    static let radialLabelSize: CGFloat = 12
    static let radialBackdropInset: CGFloat = 8
    // The radial intentionally stays light, including over a dark desktop.
    static let radialBackdrop = Color(nsColor: NSColor(srgbRed: 0.92, green: 0.94, blue: 0.95, alpha: 1))
    static let radialGlassTint = Color.white.opacity(0.35)
    static let radialBackdropOpacity = 0.28
    static let radialBackdropShadow = Color.black.opacity(0.12)
    static let radialSurface = Color(nsColor: NSColor(srgbRed: 0.91, green: 0.93, blue: 0.94, alpha: 1))
    static let radialSurfaceGradient = LinearGradient(colors: [.white, radialSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let radialHub = Color.white
    static let radialInk = Color(nsColor: NSColor(srgbRed: 0.10, green: 0.12, blue: 0.14, alpha: 1))
    static let radialCaption = Color(nsColor: NSColor(srgbRed: 0.31, green: 0.35, blue: 0.38, alpha: 1))
    static let radialStroke = Color(nsColor: NSColor(srgbRed: 0.48, green: 0.54, blue: 0.58, alpha: 1)).opacity(0.35)
    static let radialRim = Color.white.opacity(0.8)
    static let radialHubShadow = Color.black.opacity(0.08)
    static let radialSurfaceOpacity = 0.68
    static let radialHubOpacity = 0.84

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = Theme.cardCorner

    func body(content: Content) -> some View {
        content
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
    }
}

extension View {
    func card(cornerRadius: CGFloat = Theme.cardCorner) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius))
    }
}

struct SegmentedPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { option in
                Text(option.1).tag(option.0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
