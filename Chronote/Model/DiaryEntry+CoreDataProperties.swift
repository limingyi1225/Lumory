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
    
    // content属性已在DiaryEntry+Extensions.swift中定义，这里不重复定义
    
    /// 返回音频文件完整 URL（若存在）
    func audioURL() -> URL? {
        guard let fileName = audioFileName else { return nil }
        
        // Try iCloud location first
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
            let audioURL = iCloudURL.appendingPathComponent("Documents/LumoryAudio").appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: audioURL.path) {
                return audioURL
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
            // Migrate to new location
            migrateAudioToiCloud(fileName: fileName, oldURL: oldURL)
            return audioURL() // Recursive call to get new location
        }
        
        return nil
    }
    
    private func migrateAudioToiCloud(fileName: String, oldURL: URL) {
        guard let audioData = try? Data(contentsOf: oldURL) else { return }
        
        // Save to new location
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
            let audioDir = iCloudURL.appendingPathComponent("Documents/LumoryAudio")
            if !FileManager.default.fileExists(atPath: audioDir.path) {
                try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true, attributes: nil)
            }
            
            let newURL = audioDir.appendingPathComponent(fileName)
            try? audioData.write(to: newURL)
            print("[DiaryEntry] Migrated audio \(fileName) to iCloud")
            
            // Delete from old location
            try? FileManager.default.removeItem(at: oldURL)
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