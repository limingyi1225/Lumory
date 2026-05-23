import Foundation
import CoreData
#if canImport(UIKit)
import UIKit
#endif

/// **P1-Home-6 删除 undo(4 秒撤销)**
///
/// 设计原则:
/// - **不动 schema**,先在内存维持 4 秒"待清理"快照;窗口过期后写入本地最近删除归档。
/// - **乐观删除**:CoreData entry 立即 `delete + save`(用户看到 row 消失),attachment 文件
///   **延迟 4 秒**才归档并真删。这 4 秒里如果用户点了撤销,从快照重新 insert entry,
///   attachment 文件还在原位。
/// - **撤销快照只在内存**:4 秒内撤销仍是即时重建;窗口过期后再写本地 30 天归档,
///   避免引入 Core Data soft-delete schema。
/// - **多次删除**:新删除会触发上一条的 commit(立即清掉那条的 attachment),保证最多只有一个待撤销。
///
/// **接入点**(2026-05-05 实测):4 处单 entry 删除全部走撤销 toast,跟 CLAUDE.md 一致 ——
/// HomeView.deleteEntry(主时间线 swipe/contextMenu)、DiaryDetailView.deleteEntry(详情删后 dismiss)、
/// ThemeFilteredEntriesView.deleteEntry(主题二级页)、PointDetailSheet.deleteEntry(WritingHeatmap tap-day 二级)。
/// 后两者用 `@State [DiaryEntry]` 缓存 ——`undo(into:)` 返回 restored entry,callsite 自己 splice 回数组,
/// 不然撤销给了 success haptic 但视觉不闭环。
///
/// **不**接的入口:SettingsView "全部删除"(批量,不可单条 undo,保留 alert)、
/// ThemeFilteredEntriesView "删除整个主题"(影响多 entry,保留 alert)、
/// HomeView "删除录音"(子操作,不影响 entry)。

/// 删除前捕获的快照,撤销时从这里重建 entry。所有 @NSManaged 属性都拷贝。
struct EntryDeletionSnapshot: Sendable {
    let id: UUID
    let date: Date?
    let text: String?
    let moodValue: Double
    let summary: String?
    let audioFileName: String?
    let imageFileNames: String?
    let imagesData: Data?
    let themes: String?
    let embedding: Data?
    let wordCount: Int32

    /// 从 entry 抓快照 — 必须在 viewContext.delete 之前调,否则 @NSManaged 访问可能 crash。
    ///
    /// **entry.id 边界**:schema 名义可空(`UUID?`),实际 invariant 是非 nil(addEntry/v2 migration
    /// 都强制 set)。万一为 nil(老数据迁移残留),用 fresh UUID 兜底 — 撤销后该 entry 拿到新
    /// identity。reviewer Wave-A BUG-P1 担心派生数据(embedding/alias/prompt cache)以 id 为 key 时
    /// 撤销后认不出原条;实测项目内派生数据基本不 keyed by entry.id(embedding 在 entity 上随 entry,
    /// alias 走 name,prompt cache per-day,Insights cache 全局),实际影响接近 0。仍 log 一条 warning
    /// 让我们看到这种边界发生的频率,如果非 0 再决定升级到 failable init + caller 降级。
    @MainActor
    init(entry: DiaryEntry) {
        if let id = entry.id {
            self.id = id
        } else {
            let fallback = UUID()
            Log.warning(
                "[EntryDeletionUndo] entry.id is nil, fallback to fresh UUID \(fallback) — undo will assign new identity",
                category: .persistence
            )
            self.id = fallback
        }
        self.date = entry.date
        self.text = entry.text
        self.moodValue = entry.moodValue
        self.summary = entry.summary
        self.audioFileName = entry.audioFileName
        self.imageFileNames = entry.imageFileNames
        self.imagesData = entry.imagesData
        self.themes = entry.themes
        self.embedding = entry.embedding
        self.wordCount = entry.wordCount
    }

    /// 把 attachment 文件名抽出来,给 commit 阶段(撤销窗口过期)清理。
    var attachmentImageFileNames: [String] {
        guard let imageFileNames, !imageFileNames.isEmpty else { return [] }
        return imageFileNames.split(separator: ",").map { String($0) }
    }
}

/// 撤销窗口管理。一次只持有一个 pending 快照 — 新删除会替换,触发上一条立即 commit。
@MainActor
final class EntryDeletionUndoService {
    static let shared = EntryDeletionUndoService()

    /// 当前 pending 快照(用户还没决定 undo / commit)。nil = 没有待撤销项。
    private var pending: EntryDeletionSnapshot?
    /// commit task — 4 秒后跑 attachment 清理 + 把 pending 清空。
    private var commitTask: Task<Void, Never>?

    /// 撤销窗口长度(秒)。Toast 也用这个值作 duration。
    static let undoWindow: TimeInterval = 4

    private init() {}

    // MARK: - Test seams (DEBUG-only)

    #if DEBUG
    /// **Test-only**:观察 pending 快照(只读)— 用来断言 register/commit/undo 后的状态。
    var pendingSnapshotForTesting: EntryDeletionSnapshot? { pending }
    /// **Test-only**:观察 commitTask 是否还在飞 — 断言 cancel 行为。
    var commitTaskIsActiveForTesting: Bool { commitTask != nil }
    /// **Test-only**:把内部状态 reset 到 init 状态,跨 test 隔离 singleton 污染。
    /// (round-5 D10)改 `async` + `await commitTask?.value` 等被 cancel 的 task 真正退出,
    /// 防"上一条 commit 的 4s sleep task 在下一条 test setUp/初始 register 中途醒来" race。
    /// `Task.sleep` 是 cooperative cancel,sleep 调用点抛 CancellationError 后 body 还要
    /// 走 `guard !Task.isCancelled else { return }` + 主 actor hop 才退,跨 test 边界可能漏。
    func resetForTesting() async {
        let snapshotTask = commitTask
        commitTask?.cancel()
        commitTask = nil
        pending = nil
        _ = await snapshotTask?.value
    }
    #endif

    /// 注册一条删除,启动 4 秒撤销窗口。
    /// 已有 pending → 立即 commit 上一条(不能让两个同时排队,否则 attachment 清理顺序错乱)。
    ///
    /// **同 entry 重入 guard**(reviewer Wave-A BUG-P0):用户连续 swipe 删同一条 entry 两次
    /// (本来不该可能,但 row 还在 fetch result 里没刷新时可命中),如果不 guard,第二次 register
    /// 立即触发第一次的 commitPendingNow,Task.detached 删 attachment 文件 → 用户 undo 时图片显示 broken。
    /// 简单做法:同 id 重入直接 ignore,第一份快照仍在窗口内继续撑。
    func register(snapshot: EntryDeletionSnapshot) {
        if let existing = pending, existing.id == snapshot.id {
            return
        }
        commitPendingNow()
        pending = snapshot
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.undoWindow))
            guard !Task.isCancelled else { return }
            // 没人 undo → 真的清 attachment + 清快照。
            self.commitPendingNow()
        }
    }

    /// 用户点了撤销。从快照重新 insert entry,清 pending。返 restored DiaryEntry 给 caller(让它
    /// splice 回 sheet 的 `@State` 本地数组);nil = 没东西可撤销 / save 失败。
    /// HomeView 走 `@FetchRequest` 自动响应,不需要 return value;PointDetail / ThemeFiltered 这种
    /// 用 `@State [DiaryEntry]` 缓存的 sheet 必须显式补回,否则视觉不闭环(Codex 抓出)。
    @discardableResult
    func undo(into viewContext: NSManagedObjectContext) -> DiaryEntry? {
        guard let snapshot = pending else { return nil }
        commitTask?.cancel()
        commitTask = nil
        pending = nil

        // 用 NSEntityDescription.insertNewObject 而不是 entity init — 跟 CoreData lifecycle 协议一致。
        guard let entityDesc = NSEntityDescription.entity(forEntityName: "DiaryEntry", in: viewContext) else {
            Log.error("[EntryDeletionUndo] DiaryEntry entity not found", category: .persistence)
            return nil
        }
        let entry = DiaryEntry(entity: entityDesc, insertInto: viewContext)
        entry.id = snapshot.id
        entry.date = snapshot.date
        entry.text = snapshot.text
        entry.moodValue = snapshot.moodValue
        entry.summary = snapshot.summary
        entry.audioFileName = snapshot.audioFileName
        entry.imageFileNames = snapshot.imageFileNames
        entry.imagesData = snapshot.imagesData
        entry.themes = snapshot.themes
        entry.embedding = snapshot.embedding
        entry.wordCount = snapshot.wordCount

        do {
            try viewContext.save()
            // **集合变化 → 复盘"五件套"**(reviewer Wave-A BUG-P0):删除时 deleteEntry 调过一次
            // EntryWipeOrchestrator.performSingleDeleteCleanup,Reminder/Prompt/Insights/Widget cache
            // 已基于"少一条"重排过。undo 把 entry 拉回来后必须再调一次,让上述派生数据重新评估,
            // 否则 banner / widget / 通知 body 持续显示 ghost 状态直到下次主动操作。
            // performSingleDeleteCleanup 内每一项都 idempotent,语义上是"集合变化",对插入也安全。
            EntryWipeOrchestrator.performSingleDeleteCleanup()
            Log.info("[EntryDeletionUndo] Restored entry \(snapshot.id)", category: .persistence)
            return entry
        } catch {
            Log.error("[EntryDeletionUndo] Restore failed: \(error.localizedDescription)", category: .persistence)
            viewContext.rollback()
            return nil
        }
    }

    /// 立即提交当前 pending(清 attachment,清快照)。不撤销。
    /// 给"另一次删除来了"或"4 秒到了"用。
    func commitPendingNow() {
        commitTask?.cancel()
        commitTask = nil
        guard let snapshot = pending else { return }
        pending = nil

        // **dangling undo 防护**(reviewer Wave-C BUG-P1):scenePhase=background 触发 commitPendingNow
        // 时,LumoryToast 上的"撤销"按钮还挂在那。用户回前台点击 → undo() guard let snapshot 直接
        // return false → 静默无反馈 + 数据感知错误。这里把"撤销" toast 一并 dismiss,让用户回前台
        // 看不到那条不再可用的撤销按钮。普通 toast(无 action)不动 — 那些跟 undo 窗口无关。
        LumoryToastCenter.shared.dismissActionToast()

        let imageFiles = snapshot.attachmentImageFileNames
        let audioFile = snapshot.audioFileName
        #if canImport(UIKit)
        let backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "LumoryRecentDeletedArchive")
        #endif
        Task.detached(priority: .utility) {
            #if canImport(UIKit)
            defer {
                Task { @MainActor in
                    Self.endArchiveBackgroundTask(backgroundTaskID)
                }
            }
            #endif
            let didArchive = await RecentDeletedEntryStore.archive(snapshot: snapshot)
            if !didArchive {
                Log.warning("[EntryDeletionUndo] recent-deleted archive failed; deleting orphaned attachments after undo window", category: .persistence)
            }
            await deleteAttachmentFiles(imageFileNames: imageFiles, audioFileName: audioFile)
        }
    }

    /// 批量清空 / 数据库重建时取消当前单条删除的撤销窗口。
    ///
    /// 这里不写入最近删除:用户选择的是 destructive bulk wipe,旧的单条 pending 不应在
    /// "最近删除"里复活。attachment 仍要清,否则 pending entry 已从 CoreData 消失但文件会泄漏。
    func discardPendingForBulkWipe() {
        commitTask?.cancel()
        commitTask = nil
        guard let snapshot = pending else { return }
        pending = nil
        LumoryToastCenter.shared.dismissActionToast()

        let imageFiles = snapshot.attachmentImageFileNames
        let audioFile = snapshot.audioFileName
        Task.detached(priority: .utility) {
            await deleteAttachmentFiles(imageFileNames: imageFiles, audioFileName: audioFile)
        }
    }

    /// 是否当前有 pending(给 caller 判断要不要弹 toast 等)。
    var hasPending: Bool { pending != nil }

    #if canImport(UIKit)
    private static func endArchiveBackgroundTask(_ taskID: UIBackgroundTaskIdentifier) {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
    }
    #endif
}

/// 删除磁盘上的 attachment 文件。**必须**走 `DiaryEntry.delete{Image,Audio}FromDocuments` —
/// 它们覆盖 iCloud / `LumoryImages` / `LumoryAudio` / 老扁平 `Documents/` 三层路径。
/// 早先版本只删扁平 `Documents/<filename>`,**漏删图片**(图片实际写在 `Documents/LumoryImages/`),
/// 每次单删都泄漏照片到磁盘,Codex 抓出。
nonisolated private func deleteAttachmentFiles(imageFileNames: [String], audioFileName: String?) async {
    for fileName in imageFileNames {
        do {
            try DiaryEntry.deleteImageFromDocuments(fileName)
        } catch {
            Log.error("[EntryDeletionUndo] 删除图片附件失败 \(fileName): \(error)", category: .persistence)
        }
    }
    if let audioFileName, !audioFileName.isEmpty {
        DiaryEntry.deleteAudioFromDocuments(audioFileName)
    }
}
