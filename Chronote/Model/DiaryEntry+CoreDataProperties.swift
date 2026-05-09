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
            // 触发迁移：成功 → 返新 URL(老 URL 已被同步删除);失败 → 返老 URL,文件保留。
            // 原实现 sync migrate + remove old + 返 oldURL —— caller 拿到一个已被删除的 URL,
            // 后续 `AVAudioPlayer(contentsOf: oldURL)` 直接失败。改成返 newURL 后 caller 可正常用。
            if let newURL = migrateAudioToiCloud(fileName: fileName, oldURL: oldURL) {
                return newURL
            }
            return oldURL
        }

        return nil
    }

    /// 把音频从老的 Documents 根迁到 iCloud `Documents/LumoryAudio/`,返回新 URL。
    /// 写新 URL 成功后才删老文件;任何失败保留 oldURL,让调用方仍可读取。
    @discardableResult
    private func migrateAudioToiCloud(fileName: String, oldURL: URL) -> URL? {
        guard let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") else {
            return nil
        }
        guard let audioData = try? Data(contentsOf: oldURL) else { return nil }

        let audioDir = iCloudURL.appendingPathComponent("Documents/LumoryAudio")
        let newURL = audioDir.appendingPathComponent(fileName)
        do {
            if !FileManager.default.fileExists(atPath: audioDir.path) {
                try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true, attributes: nil)
            }
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
