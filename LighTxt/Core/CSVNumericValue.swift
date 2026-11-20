import Foundation

/// CSV fields remain strings for display and export. Analytics additionally recognize
/// US currency and thousands separators, independent of the Mac's display locale.
nonisolated enum CSVNumericValue {
    private static let magnitude = #"(?:[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]*)?|[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?"#

    // Both Foundation and DuckDB validate grouping before removing punctuation.
    // A sign may precede or follow a dollar sign. Accounting parentheses already
    // supply a minus sign, so the enclosed amount must be unsigned.
    static let formattedPattern = #"^(?:(?:[+-]?[ \t]*\$[ \t]*|\$[ \t]*[+-][ \t]*|[+-]?)"# + magnitude
        + #"|\([ \t]*\$?[ \t]*"# + magnitude + #"[ \t]*\))$"#
    private static let formattedExpression = try! NSRegularExpression(pattern: formattedPattern)

    static func parse(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        if let plain = Double(raw) { return plain.isFinite ? plain : nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value != raw, let plain = Double(value) { return plain.isFinite ? plain : nil }
        guard value.contains("$") || value.contains(",") || value.first == "(" else { return nil }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard formattedExpression.rangeOfFirstMatch(in: value, range: range) == range else { return nil }
        let bytes = value.utf8.filter {
            switch $0 {
            case 0x09, 0x20, 0x24, 0x28, 0x29, 0x2C: false // tab, space, $, (, ), comma
            default: true
            }
        }
        guard let amount = Double(String(decoding: bytes, as: UTF8.self)), amount.isFinite else { return nil }
        return value.first == "(" ? -amount : amount
    }
}
