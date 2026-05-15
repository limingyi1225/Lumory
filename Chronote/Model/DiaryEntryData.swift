import Foundation
import CoreData

/// 简单的数据结构，用于在AI服务中传递日记数据，避免CloudKit同步冲突
struct DiaryEntryData {
    let id: UUID
    let date: Date
    let text: String
    let moodValue: Double
    let summary: String
    // Phase 0 扩展：AI × 统计融合需要的额外字段，缺省为空以兼容旧调用点
    let themes: [String]
    let embedding: [Float]?
    let wordCount: Int

    init(id: UUID,
         date: Date,
         text: String,
         moodValue: Double,
         summary: String,
         themes: [String] = [],
         embedding: [Float]? = nil,
         wordCount: Int = 0) {
        self.id = id
        self.date = date
        self.text = text
        self.moodValue = moodValue
        self.summary = summary
        self.themes = themes
        self.embedding = embedding
        self.wordCount = wordCount
    }
    
    // (2026-05-15 megareview OPT-MID-1)`from(fetchedEntry:)` 已删 — grep 全仓 0 caller。
    // 所有构造都走 init 直接传字段,这个便利构造函数从未被引用。原实现保留在 git history。
}
