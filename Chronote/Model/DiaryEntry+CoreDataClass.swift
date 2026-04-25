import Foundation
import CoreData

@objc(DiaryEntry)
public class DiaryEntry: NSManagedObject, Identifiable {
    // Core Data 会通过 @NSManaged 属性来管理数据

    override public func awakeFromInsert() {
        super.awakeFromInsert()
        if id == nil {
            id = UUID()
        }
    }
}
