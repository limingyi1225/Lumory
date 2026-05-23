import Foundation
import CoreData

// MARK: - ThemeManagementService
//
// 用户在 Insights ThemeCard 长按或 alias 管理页主动"删除某主题" —— 这是**真改 entry.themes CSV**
// 的破坏性操作(和 alias 折叠完全不同,alias 是展示层)。
// 实现:遍历 CoreData 里所有 entry,把 canonical 名 + 它的所有 alias 从 themes CSV 移除,save。
// 同时把 ThemeAliasResolver 里的 group 删掉(否则下次 scan 又会重新建议合并)。

@MainActor
final class ThemeManagementService: ObservableObject {
    static let shared = ThemeManagementService()

    private let persistence: PersistenceController
    private let resolver: ThemeAliasResolver
    /// 注入点 — 默认 `try $0.save()`,**仅测试覆盖 save-failure 路径**用 closure 替换。
    /// 不抽 protocol 是因为只需要这一个方法,closure DI 比 protocol 简洁。
    /// `@Sendable` 必要 — closure 在 `performBackgroundTask` 的 Sendable 闭包内调用,跨 actor 边界。
    private let saveAction: @Sendable (NSManagedObjectContext) throws -> Void

    init(
        persistence: PersistenceController = .shared,
        resolver: ThemeAliasResolver? = nil,
        saveAction: @escaping @Sendable (NSManagedObjectContext) throws -> Void = { try $0.save() }
    ) {
        self.persistence = persistence
        self.resolver = resolver ?? ThemeAliasResolver.shared
        self.saveAction = saveAction
    }

    struct DeletionOutcome {
        /// 受影响的 entry 数(已成功保存)
        let affected: Int
        /// CoreData save 是否成功 —— false 时 alias group 不会被删,UI 应展示错误。
        let succeeded: Bool
        let undoPayload: ThemeDeletionUndoPayload?
    }

    struct ThemeDeletionUndoPayload: Sendable {
        let canonical: String
        /// 每条 entry 上本次删除实际移除的 label。只存移除集,不存完整旧数组,避免撤销时复活
        /// 撤销窗口内被用户/同步/回填移除的无关主题。
        let originalThemesByEntryID: [UUID: [String]]
        let aliasGroupCanonical: String?
        let aliasGroupAliases: [String]
        let removedPending: [PendingSuggestion]
    }

    /// 删除主题 + 所有别名,从所有 entry 的 themes CSV 抹掉。
    /// **如果 CoreData save 失败,alias group 保留**(避免 raw themes 还在但 alias map 已删的不一致状态)。
    @discardableResult
    func deleteTheme(canonical: String) async -> DeletionOutcome {
        let canonicalKey = ThemeKey.make(canonical)

        // 收集要删的所有 normalized tag(canonical 自身 + 已合并别名)
        var tagsToRemove: Set<String> = [canonicalKey]
        if let aliases = resolver.groups[canonical] {
            for a in aliases { tagsToRemove.insert(ThemeKey.make(a)) }
        }
        // canonical 的大小写匹配也一并扫
        for (key, aliases) in resolver.groups where ThemeKey.make(key) == canonicalKey {
            tagsToRemove.insert(ThemeKey.make(key))
            for a in aliases { tagsToRemove.insert(ThemeKey.make(a)) }
        }
        let aliasGroupCanonical = resolver.groups.keys.first { ThemeKey.make($0) == canonicalKey }
        let aliasGroupAliases = aliasGroupCanonical.flatMap { resolver.groups[$0] } ?? []

        // bg task 返回 (success, affected) 而不是 Int —— 之前的 `return 0` 既可能表示
        // "没 entry 命中"(正常)也可能表示"save 失败"(灾难),无法区分。
        // codex review 指出:保存失败时仍 deleteGroup 会让 alias map 删但 raw themes 留下,
        // 用户感知是"主题没删干净"。区分后只在 succeeded=true 时删 group。
        let saveAction = self.saveAction  // capture before sendable closure boundary
        let outcome: (success: Bool, affected: Int, originals: [UUID: [String]]) = await persistence.container.performBackgroundTask { context in
            // 用户在 viewContext 上正改某条 entry 的 themes / 同步刚拉到一份,跟 bg 删除并发
            // 时,默认 errorMergePolicy 会让 save 抛 NSManagedObjectMergeError → rollback,
            // 用户感知是"删除没生效"且无错误信号。
            //
            // ⚠ 注意 policy 不一致(刻意):viewContext 是 `NSMergeByPropertyStoreTrumpMergePolicy`
            // ([PersistenceController.swift:158](../Model/PersistenceController.swift)),
            // 让 CloudKit 远端 import 始终 winning(用户在另一台设备的写入不被本机 stale 内存覆盖)。
            // 这里 bg context 用 ObjectTrump 是因为"删主题"是用户主动 destructive 意图,
            // 与同时段可能正在 import 的旧版本 entry 冲突时,我们要让删除 winning(否则 Insights
            // 上"已删主题"会因 import 复活)。两种 policy 服务于不同冲突源,故意不对齐。
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "themes != nil AND themes != %@", "")
            request.fetchBatchSize = 200
            guard let entries = try? context.fetch(request) else { return (false, 0, [:]) }

            var changed = 0
            var originals: [UUID: [String]] = [:]
            for entry in entries {
                let original = entry.themeArray
                let removed = original.filter { tagsToRemove.contains(ThemeKey.make($0)) }
                let filtered = original.filter { !tagsToRemove.contains(ThemeKey.make($0)) }
                if filtered.count != original.count {
                    if let id = entry.id {
                        originals[id] = removed
                    }
                    entry.setThemes(filtered)
                    changed += 1
                }
            }
            if context.hasChanges {
                do {
                    try saveAction(context)
                    return (true, changed, originals)
                } catch {
                    Log.error("[ThemeManagement] deleteTheme save 失败: \(error)", category: .persistence)
                    context.rollback()
                    return (false, 0, [:])
                }
            }
            // 没有 entry 命中也算"成功"(用户主题在 alias map 里但 raw 数据没用过)
            return (true, 0, [:])
        }

        guard outcome.success else {
            return DeletionOutcome(affected: 0, succeeded: false, undoPayload: nil)
        }

        // 同步从 alias resolver 删 group(用户已经决定它彻底没了,后续不应再被建议合并)。
        // deleteGroup 内部已经清理 pending(matching group labels),codex P2 fix。
        let removedPending = resolver.pendingSuggestions(matchingLowercasedLabels: tagsToRemove)
        let undoPayload = ThemeDeletionUndoPayload(
            canonical: canonical,
            originalThemesByEntryID: outcome.originals,
            aliasGroupCanonical: aliasGroupCanonical,
            aliasGroupAliases: aliasGroupAliases,
            removedPending: removedPending
        )

        if let exactKey = resolver.groups.keys.first(where: { ThemeKey.make($0) == canonicalKey }) {
            resolver.deleteGroup(canonical: exactKey)
        }

        // canonical 本身可能从未在 group 里(用户直接对没合并过的主题点删除)——
        // deleteGroup 不会跑,但 entry.themes CSV 里这个标签已被抹掉,任何 pending 引用
        // 这个标签都已 stale,显式清一次。
        resolver.purgePending(matchingLowercasedLabels: tagsToRemove)

        Log.info("[ThemeManagement] deleted theme \(canonical), affected entries: \(outcome.affected)", category: .persistence)
        NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
        return DeletionOutcome(affected: outcome.affected, succeeded: true, undoPayload: undoPayload)
    }

    @discardableResult
    func restoreDeletedTheme(_ payload: ThemeDeletionUndoPayload) async -> DeletionOutcome {
        let saveAction = self.saveAction
        let originals = payload.originalThemesByEntryID
        let restored: (success: Bool, affected: Int) = await persistence.container.performBackgroundTask { context in
            guard !originals.isEmpty else { return (true, 0) }
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            let ids = Array(originals.keys)
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", ids as NSArray)
            request.fetchBatchSize = 200
            guard let entries = try? context.fetch(request) else { return (false, 0) }

            // (D-01 / codex 终审 2026-05-19) **merge** 回被删除的 label,**不要** 盲覆盖整个 themeArray。
            // 老实现 `entry.setThemes(themes)` 把 4 秒撤销窗口内 用户/CloudKit/backfill 加进来的
            // 新 tag 全打回旧 snapshot 状态。新逻辑:只把 snapshot 里"目前不在 entry 上"的 label
            // 补回去,保留同窗口内的所有并发改动。lowercased 大小写归一,跟 `sanitizeThemes` 的
            // dedup 策略对齐。
            var changed = 0
            for entry in entries {
                guard let id = entry.id, let snapshotThemes = originals[id] else { continue }
                let currentThemes = entry.themeArray
                let currentThemeKeys = Set(currentThemes.map { ThemeKey.make($0) })
                let toRestore = snapshotThemes.filter { !currentThemeKeys.contains(ThemeKey.make($0)) }
                guard !toRestore.isEmpty else { continue }   // 全在 → 已被并发流程加回 → no-op
                entry.setThemes(currentThemes + toRestore)
                changed += 1
            }
            guard context.hasChanges else { return (true, changed) }
            do {
                try saveAction(context)
                return (true, changed)
            } catch {
                Log.error("[ThemeManagement] restoreDeletedTheme save 失败: \(error)", category: .persistence)
                context.rollback()
                return (false, 0)
            }
        }

        guard restored.success else {
            return DeletionOutcome(affected: 0, succeeded: false, undoPayload: nil)
        }

        if let aliasGroupCanonical = payload.aliasGroupCanonical {
            resolver.restoreGroup(canonical: aliasGroupCanonical, aliases: payload.aliasGroupAliases)
        }
        resolver.restorePending(payload.removedPending)
        NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
        Log.info("[ThemeManagement] restored theme \(payload.canonical), affected entries: \(restored.affected)", category: .persistence)
        return DeletionOutcome(affected: restored.affected, succeeded: true, undoPayload: nil)
    }
}
