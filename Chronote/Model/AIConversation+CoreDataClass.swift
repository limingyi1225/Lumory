import Foundation
import CoreData

@objc(AIConversation)
public class AIConversation: NSManagedObject, Identifiable {
    /// CoreData 通过 `@NSManaged` 属性管理数据(声明在 +CoreDataProperties.swift)。
    /// 跟 DiaryEntry 同 pattern:手动 +CoreDataClass / +CoreDataProperties 文件,model
    /// 里 entity 不带 `codeGenerationType` 属性(避免跟手写文件冲突)。

    override public func awakeFromInsert() {
        super.awakeFromInsert()
        // **不**在这里硬塞 id / createdAt / payloadVersion 默认 —— 调用方走
        // `AIConversation.insertAskPast / insertNarrative` 显式赋值,跟 codex 反馈一致
        // (CoreData model default + awakeFromInsert 双重默认会让 init path 不明)。
    }
}
