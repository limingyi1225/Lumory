import Foundation
import CoreData
import SwiftUI

extension DiaryEntry {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<DiaryEntry> {
        return NSFetchRequest<DiaryEntry>(entityName: "DiaryEntry")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var date: Date?
    @NSManaged public var text: String?
    @NSManaged public var moodValue: Double
    @NSManaged public var summary: String?
    @NSManaged public var audioFileName: String?
    @NSManaged public var imageFileNames: String?
    @NSManaged public var imagesData: Data?

    // AI × 统计 pipeline：主题标签（CSV）、语义向量、字数
    @NSManaged public var themes: String?
    @NSManaged public var embedding: Data?
    @NSManaged public var wordCount: Int32

    // content属性已在DiaryEntry+Extensions.swift中定义，这里不重复定义

    /// 返回音频文件完整 URL（若存在）
    func audioURL() -> URL? {
        guard let fileName = audioFileName else { return nil }

        return Self.resolvedAudioURL(fileName: fileName)
    }

    /// 解析音频文件 URL。可能触发 legacy → iCloud 的一次性迁移,因此不要在 SwiftUI body 内调用。
    nonisolated static func resolvedAudioURL(fileName: String) -> URL? {
        if let url = LumoryAttachmentPaths.existingAudioURL(fileName: fileName) {
            // 触发迁移：成功 → 返新 URL(老 URL 已被同步删除);失败 → 返老 URL,文件保留。
            // 原实现 sync migrate + remove old + 返 oldURL —— caller 拿到一个已被删除的 URL,
            // 后续 `AVAudioPlayer(contentsOf: oldURL)` 直接失败。改成返 newURL 后 caller 可正常用。
            if url.path == LumoryAttachmentPaths.legacyURL(fileName: fileName).path {
                if let newURL = migrateAudioToiCloud(fileName: fileName, oldURL: url) {
                    return newURL
                }
            }
            return url
        }

        return nil
    }

    /// 把音频从老的 Documents 根迁到 iCloud `Documents/LumoryAudio/`,返回新 URL。
    /// 写新 URL 成功后才删老文件;任何失败保留 oldURL,让调用方仍可读取。
    @discardableResult
    nonisolated private static func migrateAudioToiCloud(fileName: String, oldURL: URL) -> URL? {
        guard let audioDir = try? LumoryAttachmentPaths.ensureICloudDirectory(for: .audio) else { return nil }
        guard let audioData = try? Data(contentsOf: oldURL) else { return nil }

        let newURL = audioDir.appendingPathComponent(fileName)
        do {
            try audioData.write(to: newURL, options: .atomic)
            Log.info("[DiaryEntry] Migrated audio \(fileName) to iCloud", category: .persistence)

            // Delete old only after the iCloud copy is durable on disk.
            try? FileManager.default.removeItem(at: oldURL)
            return newURL
        } catch {
            Log.error("[DiaryEntry] Audio migration failed, keeping legacy copy \(fileName): \(error)", category: .persistence)
            return nil
        }
    }

    // 为CloudKit同步添加便利初始化器
    convenience init(context: NSManagedObjectContext, id: UUID = UUID(), text: String, date: Date = Date(), moodValue: Double = 0.5) {
        self.init(context: context)
        self.id = id
        self.text = text
        self.date = date
        self.moodValue = moodValue
    }
}
