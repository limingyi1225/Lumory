import Foundation
import CoreData

/// Service to handle exporting diary entries to a text file.
class DiaryExportService {
    
    /// Generates the export content string from a list of diary entries.
    /// - Parameter entries: The diary entries to export, sorted by date.
    /// - Returns: A formatted string containing all diary entries.
    static func generateExportContent(from entries: [DiaryEntry]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        
        var lines: [String] = []
        
        // Header
        lines.append("========================================")
        lines.append(NSLocalizedString("Lumory 日记导出", comment: "Export title"))
        lines.append(String(format: NSLocalizedString("导出日期: %@", comment: ""), dateFormatter.string(from: Date())))
        lines.append(String(format: NSLocalizedString("共 %d 篇日记", comment: ""), entries.count))
        lines.append("========================================")
        lines.append("")
        
        // Sort entries by date (oldest first for reading order)
        let sortedEntries = entries.sorted { ($0.date ?? Date.distantPast) < ($1.date ?? Date.distantPast) }
        
        for entry in sortedEntries {
            // Date header
            let entryDate = entry.date ?? Date()
            lines.append("----------------------------------------")
            lines.append("📅 \(dateFormatter.string(from: entryDate))")
            
            // Mood indicator
            let moodDescription = moodEmoji(for: entry.moodValue)
            lines.append(String(format: NSLocalizedString("心情: %@", comment: ""), moodDescription))
            
            // Summary if available
            if let summary = entry.summary, !summary.isEmpty {
                lines.append(String(format: NSLocalizedString("摘要: %@", comment: ""), summary))
            }
            
            lines.append("")
            
            // Main content
            lines.append(entry.text ?? "")
            
            lines.append("")
        }
        
        lines.append("----------------------------------------")
        lines.append(NSLocalizedString("--- 导出结束 ---", comment: "Export end"))
        
        return lines.joined(separator: "\n")
    }
    
    /// Returns an emoji representing the mood value.
    private static func moodEmoji(for value: Double) -> String {
        switch value {
        case 0..<0.2:
            return "😢 " + NSLocalizedString("很差", comment: "")
        case 0.2..<0.4:
            // "较差" matches the key in Localizable.strings better than "不好"
            return "😕 " + NSLocalizedString("较差", comment: "")
        case 0.4..<0.6:
            return "😐 " + NSLocalizedString("一般", comment: "")
        case 0.6..<0.8:
            return "🙂 " + NSLocalizedString("不错", comment: "")
        default:
            return "😊 " + NSLocalizedString("很好", comment: "")
        }
    }
    
    /// Creates a temporary file with the export content.
    /// - Parameter content: The content to write.
    /// - Returns: The URL of the created file, or nil if failed.
    static func createExportFile(content: String) -> URL? {
        let isEnglish = UserDefaults.standard.string(forKey: "appLanguage") == "en"
        let baseFileName = isEnglish ? "Lumory_Diary_Export" : "Lumory_日记导出"
        let fileName = "\(baseFileName)_\(formattedDateForFileName()).txt"
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            Log.info("[DiaryExportService] Export file created at: \(fileURL.path)", category: .persistence)
            return fileURL
        } catch {
            Log.error("[DiaryExportService] Failed to create export file: \(error)", category: .persistence)
            return nil
        }
    }
    
    /// Generates a date string suitable for file names.
    private static func formattedDateForFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: Date())
    }
}
