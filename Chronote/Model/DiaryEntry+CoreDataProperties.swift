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

        // Try iCloud location first
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
            let audio = iCloudURL.appendingPathComponent("Documents/LumoryAudio").appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: audio.path) {
                return audio
            }
        }

        // Try local with subdirectory
        let localURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumoryAudio")
            .appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        // Try old location for backward compatibility
        let oldURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: oldURL.path) {
            // 触发迁移（异步，不阻塞），直接返回老位置的 URL 让当前调用继续用。
            // 原实现返回 `audioURL()`（递归）——如果迁移后 iCloud 文件尚未下载完成 或
            // 迁移失败，三条路径都找不到会再次命中老路径，触发新一轮迁移 → 栈溢出。
            migrateAudioToiCloud(fileName: fileName, oldURL: oldURL)
            return oldURL
        }

        return nil
    }

    private func migrateAudioToiCloud(fileName: String, oldURL: URL) {
        guard let audioData = try? Data(contentsOf: oldURL) else { return }

        // Save to new location
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
            let audioDir = iCloudURL.appendingPathComponent("Documents/LumoryAudio")
            let newURL = audioDir.appendingPathComponent(fileName)
            do {
                if !FileManager.default.fileExists(atPath: audioDir.path) {
                    try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true, attributes: nil)
                }
                try audioData.write(to: newURL, options: .atomic)
                Log.info("[DiaryEntry] Migrated audio \(fileName) to iCloud", category: .persistence)

                // Delete from old location only after the iCloud copy is durable.
                try? FileManager.default.removeItem(at: oldURL)
            } catch {
                Log.error("[DiaryEntry] Audio migration failed, keeping legacy copy \(fileName): \(error)", category: .persistence)
            }
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
