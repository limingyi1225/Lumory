import Foundation
import CoreData

extension AIConversation {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<AIConversation> {
        return NSFetchRequest<AIConversation>(entityName: "AIConversation")
    }

    /// 全部字段 optional —— CloudKit-first-sync 要求(见 CLAUDE.md / coredata-migration
    /// 规则)。Insert 时调用方走 `insertAskPast` / `insertNarrative` helper 显式赋值。
    @NSManaged public var id: UUID?
    @NSManaged public var kind: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var title: String?
    @NSManaged public var content: String?
    /// JSON-encoded 结构化 DTO(`AskPastPayload` / `NarrativePayload`)。版本控制由
    /// `payloadVersion` 字段管,反序列化时按版本 gate(见 +Extensions.swift)。
    @NSManaged public var payload: Data?
    @NSManaged public var payloadVersion: Int32
    /// JSON-encoded `[UUID]` —— 引用过的日记 entry id。**不**用 to-many CoreData 关系:
    /// CloudKit 关系跨 zone cascade 不可靠 + 删日记不该改 AI 历史(那是过去事实)。
    @NSManaged public var citedEntryIds: Data?
}
