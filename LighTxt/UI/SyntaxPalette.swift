import AppKit

enum SyntaxPalette {
    static func color(for kind: SyntaxSemanticKind) -> NSColor {
        switch kind {
        case .string, .attributeValue:
            dynamic(light: rgb(0.04, 0.40, 0.33), dark: rgb(0.39, 0.81, 0.65))
        case .number:
            dynamic(light: rgb(0.23, 0.39, 0.69), dark: rgb(0.51, 0.68, 0.96))
        case .keyword, .directive:
            dynamic(light: rgb(0.16, 0.38, 0.61), dark: rgb(0.42, 0.69, 0.91))
        case .boolean, .null:
            dynamic(light: rgb(0.42, 0.30, 0.68), dark: rgb(0.72, 0.57, 0.92))
        case .comment, .quoteMarker:
            dynamic(light: rgb(0.43, 0.52, 0.51), dark: rgb(0.43, 0.59, 0.57))
        case .key, .attributeName:
            dynamic(light: rgb(0.07, 0.41, 0.52), dark: rgb(0.36, 0.72, 0.80))
        case .punctuation, .operator:
            dynamic(light: rgb(0.31, 0.39, 0.40), dark: rgb(0.64, 0.70, 0.70))
        case .tag:
            dynamic(light: rgb(0.08, 0.45, 0.55), dark: rgb(0.34, 0.74, 0.80))
        case .entity, .anchor, .alias:
            dynamic(light: rgb(0.53, 0.35, 0.12), dark: rgb(0.91, 0.69, 0.37))
        case .heading:
            dynamic(light: rgb(0.06, 0.36, 0.46), dark: rgb(0.33, 0.72, 0.74))
        case .emphasis, .link:
            dynamic(light: rgb(0.23, 0.40, 0.65), dark: rgb(0.47, 0.68, 0.94))
        case .code, .codeFence:
            dynamic(light: rgb(0.39, 0.32, 0.55), dark: rgb(0.76, 0.64, 0.88))
        case .listMarker:
            LighTxtTheme.accent
        case .error:
            LighTxtTheme.error
        }
    }

    static func attributes(
        for kind: SyntaxSemanticKind,
        appearance: NSAppearance
    ) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .foregroundColor: LighTxtTheme.resolved(color(for: kind), for: appearance)
        ]
        switch kind {
        case .heading, .keyword, .key, .tag:
            result[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        case .comment:
            result[.obliqueness] = 0.08
        case .error:
            result[.underlineStyle] = NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue
            result[.underlineColor] = LighTxtTheme.resolved(LighTxtTheme.error, for: appearance)
        default:
            break
        }
        return result
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
