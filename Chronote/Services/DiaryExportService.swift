import Foundation
import CoreData

/// (2026-05-15 superreview-2 P1)Sendable snapshot 让 generateExportContent 能跑 Task.detached
/// 后台线程,主线程零卡顿。`DiaryEntry` 是 `NSManagedObject` 跨 actor 边界违法。
struct DiaryExportEntrySnapshot: Sendable {
    let date: Date?
    let text: String?
    let summary: String?
    let moodValue: Double
}

/// Service to handle exporting diary entries to a text file.
class DiaryExportService {

    /// (2026-05-15 superreview-3 P1)从 background context 走 `NSDictionaryResultType` 抓
    /// 字段值直接构造 Snapshot,**不实例化 NSManagedObject**。
    /// 旧实现 `entries.map { Snapshot($0) }` 在主 actor 上遍历 FetchedResults 触发全表 fault
    /// 到主线程 row cache,抵消上游 `fetchBatchSize=100` 优化。这里整段后台 dict-fetch,
    /// 主线程零开销;跟 `WidgetSnapshotService` / `StreakMilestoneService.computeCurrentStreak` 同 idiom。
    nonisolated static func fetchAllSnapshots(persistence: PersistenceController) async -> [DiaryExportEntrySnapshot] {
        await persistence.container.performBackgroundTask { context in
            let request = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["date", "text", "summary", "moodValue"]
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            guard let dicts = try? context.fetch(request) else { return [] }
            return dicts.map { dict in
                DiaryExportEntrySnapshot(
                    date: dict["date"] as? Date,
                    text: dict["text"] as? String,
                    summary: dict["summary"] as? String,
                    moodValue: (dict["moodValue"] as? Double) ?? 0.5
                )
            }
        }
    }
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

    /// (2026-05-15 superreview-2 P1)`nonisolated` 让 caller 能 Task.detached 后台跑,
    /// 避免主线程一次性拼 ~MB 级 String + sort N entries 卡 watchdog。caller 必须在主线程
    /// 先把 `[DiaryEntry]` 转成 `[DiaryExportEntrySnapshot]`(`NSManagedObject` 不 Sendable)。
    nonisolated static func generateExportContent(from entries: [DiaryExportEntrySnapshot]) -> String {
        let dateFormatter = LumoryDateFormatters.longDateShortTime

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
    /// - Note: 历史上还有一个 `createExportFileThrowing` 暴露 `ExportError.diskFull`,
    ///   但所有 call site 都只看 nil/non-nil,disk-full 极小概率 + 系统已有自身 alert,
    ///   2026-05 删了那条 throwing 路径,inline 进 wrapper。
    nonisolated static func createExportFile(content: String) -> URL? {
        do {
            let folder = try ensureExportFolder()

            // Cleanup before writing — bound the folder size.
            cleanupOldExports(in: folder)

            let isEnglish = AppGroup.userDefaults.string(forKey: "appLanguage") == "en"
            let baseFileName = isEnglish ? "Lumory_Diary_Export" : "Lumory_日记导出"
            let fileName = "\(baseFileName)_\(formattedDateForFileName()).txt"
            let fileURL = folder.appendingPathComponent(fileName)

            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            Log.info("[DiaryExportService] Export file created at: \(fileURL.path)", category: .persistence)
            return fileURL
        } catch {
            Log.error("[DiaryExportService] Failed to create export file: \(error)", category: .persistence)
            return nil
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
    /// (2026-05-15 superreview-4 P2)收编到 `LumoryDateFormatters.fileTimestamp`,跟 view-layer
    /// 同 idiom(共享 cache,POSIX 锁定数字系)。
    private static func formattedDateForFileName() -> String {
        LumoryDateFormatters.fileTimestamp.string(from: Date())
    }
}
