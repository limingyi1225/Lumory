import Foundation
import CoreData

/// Service to handle exporting diary entries to a text file.
class DiaryExportService {
    /// Errors raised when creating an export file.
    enum ExportError: Error {
        /// Disk is full / out of space (`NSFileWriteOutOfSpaceError`, `ENOSPC`, etc.).
        case diskFull
        /// Any other write failure (permissions, I/O, encoding…).
        case writeFailed(underlying: Error)
    }

    /// Subdirectory under Documents where exports are kept. Excluded from iCloud Backup.
    private static let exportFolderName = "ExportedDiaries"

    /// Export files older than this are auto-cleaned on each export call.
    private static let cleanupAgeSeconds: TimeInterval = 7 * 24 * 60 * 60

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
            let moodDescription = MoodLabels.localizedExportDescription(for: entry.moodValue)
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

    /// Creates a persistent file with the export content under
    /// `Documents/ExportedDiaries/`. The folder is excluded from iCloud Backup
    /// and old (>7d) exports are pruned on each call.
    /// - Parameter content: The content to write.
    /// - Returns: The URL of the created file, or nil if failed.
    /// - Note: Existing call sites only check for nil; richer error info is
    ///   available via `createExportFileThrowing(content:)` for callers that
    ///   want to distinguish disk-full vs other failures.
    static func createExportFile(content: String) -> URL? {
        do {
            return try createExportFileThrowing(content: content)
        } catch {
            Log.error("[DiaryExportService] Failed to create export file: \(error)", category: .persistence)
            return nil
        }
    }

    /// Throwing variant that surfaces a distinct `ExportError` for disk-full.
    static func createExportFileThrowing(content: String) throws -> URL {
        let folder = try ensureExportFolder()

        // Cleanup before writing — bound the folder size.
        cleanupOldExports(in: folder)

        let isEnglish = UserDefaults.standard.string(forKey: "appLanguage") == "en"
        let baseFileName = isEnglish ? "Lumory_Diary_Export" : "Lumory_日记导出"
        let fileName = "\(baseFileName)_\(formattedDateForFileName()).txt"
        let fileURL = folder.appendingPathComponent(fileName)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            Log.info("[DiaryExportService] Export file created at: \(fileURL.path)", category: .persistence)
            return fileURL
        } catch {
            if isDiskFull(error) {
                throw ExportError.diskFull
            }
            throw ExportError.writeFailed(underlying: error)
        }
    }

    /// Resolves (creating if needed) `Documents/ExportedDiaries/` and marks it
    /// as excluded from iCloud Backup on first creation.
    private static func ensureExportFolder() throws -> URL {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            // Fall back to temp if Documents is somehow unavailable — extremely
            // unlikely on iOS, but better than crashing.
            throw ExportError.writeFailed(
                underlying: NSError(domain: "DiaryExportService", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Documents directory unavailable"])
            )
        }
        var folder = docs.appendingPathComponent(exportFolderName, isDirectory: true)

        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: folder.path, isDirectory: &isDir)
        if !exists {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Mark fresh folder as excluded from iCloud Backup. setResourceValues
            // requires a `var` URL; ignore failure (best-effort).
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do {
                try folder.setResourceValues(values)
            } catch {
                Log.error("[DiaryExportService] Failed to set isExcludedFromBackup: \(error)", category: .persistence)
            }
        } else if !isDir.boolValue {
            // A regular file is sitting where our folder should be — remove and recreate.
            try fm.removeItem(at: folder)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
        return folder
    }

    /// Deletes `.json` / `.md` / `.txt` files in the export folder older than
    /// `cleanupAgeSeconds`. Best-effort — errors are logged but not thrown.
    private static func cleanupOldExports(in folder: URL) {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let items = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-cleanupAgeSeconds)
        let allowedExtensions: Set<String> = ["json", "md", "txt"]
        for item in items {
            let ext = item.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }
            guard let values = try? item.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true else { continue }
            // If creationDate is missing, treat as old and remove.
            let created = values.creationDate ?? .distantPast
            if created < cutoff {
                do {
                    try fm.removeItem(at: item)
                } catch {
                    Log.error("[DiaryExportService] cleanup failed for \(item.lastPathComponent): \(error)", category: .persistence)
                }
            }
        }
    }

    /// Heuristic: maps a write error to "disk full" for the few codes iOS uses.
    private static func isDiskFull(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) {
            return true
        }
        // Underlying POSIX error wrapped in Cocoa error.
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOSPC) {
                return true
            }
        }
        return false
    }

    /// Generates a date string suitable for file names.
    private static func formattedDateForFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss_SSS"
        return formatter.string(from: Date())
    }
}
