import Foundation

enum MoodLabels {
    struct Option: Hashable {
        let emoji: String
        let labelKey: String
        let value: Double
    }

    static let options: [Option] = [
        Option(emoji: "😢", labelKey: "非常低落", value: 0.0),
        Option(emoji: "😞", labelKey: "有些低落", value: 0.25),
        Option(emoji: "😐", labelKey: "平静", value: 0.5),
        Option(emoji: "😊", labelKey: "愉快", value: 0.75),
        Option(emoji: "😄", labelKey: "非常开心", value: 1.0)
    ]

    static func option(for value: Double) -> Option {
        options.min { lhs, rhs in
            abs(lhs.value - value) < abs(rhs.value - value)
        } ?? options[2]
    }

    static func localizedLabel(for value: Double) -> String {
        NSLocalizedString(option(for: value).labelKey, comment: "Mood label")
    }

    static func localizedExportDescription(for value: Double) -> String {
        let option = option(for: value)
        return "\(option.emoji) \(NSLocalizedString(option.labelKey, comment: "Mood label"))"
    }
}
