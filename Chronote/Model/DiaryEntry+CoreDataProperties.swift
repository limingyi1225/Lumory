import Foundation
import CoreData
import SwiftUI

extension DiaryEntry {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<DiaryEntry> {
        return NSFetchRequest<DiaryEntry>(entityName: "DiaryEntry")
    }

    @NSManaged public var id: UUID
    @NSManaged public var date: Date
    @NSManaged public var text: String
    @NSManaged public var moodValue: Double
    @NSManaged public var summary: String?
    @NSManaged public var audioFileName: String?
    
    /// 返回音频文件完整 URL（若存在）
    func audioURL() -> URL? {
        guard let fileName = audioFileName else { return nil }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return url.appendingPathComponent(fileName)
    }
} 