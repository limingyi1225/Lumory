import Foundation

extension DiaryDetailView {
    var shareText: String {
        var parts: [String] = [
            LumoryDateFormatters.longDateShortTime.string(from: entry.wrappedDate)
        ]

        if let summary = entry.wrappedSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            parts.append(summary)
        }

        let body = entry.wrappedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            parts.append(body)
        }

        let themes = entry.themeArray
        if !themes.isEmpty {
            let separator = appLanguage.hasPrefix("zh") ? "、" : ", "
            parts.append(String(
                format: NSLocalizedString("主题:%@", comment: "Diary detail plain-text share themes line"),
                themes.joined(separator: separator)
            ))
        }

        return parts.joined(separator: "\n\n")
    }
}
