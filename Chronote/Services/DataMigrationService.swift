import Foundation
import CoreData

struct DataMigrationService {
    static let migrationKey = "hasPerformedCoreDataMigration"

    /// 执行从 JSON 到 Core Data 的一次性迁移(prod 入口,零参 wrapper)。
    ///
    /// 实际逻辑在 [`performMigration(defaults:standardDefaults:jsonURL:context:)`](#) 内,
    /// 接受 DI 让单测可以走 isolated UserDefaults suite + temp file + in-memory context
    /// 不污染生产 AppGroup / Documents(megareview OPT-HIGH H3 加 seam)。
    static func performMigrationIfNeeded() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let jsonURL = documentsURL.appendingPathComponent("diary.json")
        _ = performMigration(
            defaults: AppGroup.userDefaults,
            standardDefaults: UserDefaults.standard,
            jsonURL: jsonURL,
            context: PersistenceController.shared.container.newBackgroundContext()
        )
    }

    /// DI 入口 — 给单测注入隔离 deps。生产无 caller,只通过 `performMigrationIfNeeded()` 间接调用。
    ///
    /// 返回 `Outcome` 暴露每一步决策(insert / skip / mark / backup / save error),让 test 不必
    /// 反扫 log 就能断言完整契约。
    ///
    /// `standardDefaults` 用于 sentinel migration(老用户 `.standard` → AppGroup suite 的对称拷贝;
    /// nil = 不做 sentinel 拷贝,纯新装机场景)。
    @discardableResult
    static func performMigration(
        defaults: UserDefaults,
        standardDefaults: UserDefaults?,
        jsonURL: URL,
        context: NSManagedObjectContext
    ) -> Outcome {
        // 老用户从 .standard suite 迁到 AppGroup suite 的 sentinel 拷贝。
        // 对称 pattern:standard 里**任何**显式值(true / false)都搬过来,而不是
        // "只在 standard.bool=true 才拷"。后者会让历史上**显式写过 false 的老用户**
        // 在 AppGroup 永远缺这个 key,启动时重跑 performMigrationIfNeeded —— 若 v2 JSON
        // 文件还在(罕见但可能),就**重导一次,数据翻倍**。CLAUDE.md "Bool UserDefaults
        // 默认值翻转有 silent regression 风险" 一节记的就是这条家族。
        if let standardDefaults,
           defaults.object(forKey: migrationKey) == nil,
           standardDefaults.object(forKey: migrationKey) != nil {
            defaults.set(standardDefaults.bool(forKey: migrationKey), forKey: migrationKey)
        }

        // 检查是否已经迁移过
        guard !defaults.bool(forKey: migrationKey) else {
            Log.info("[DataMigration] 已完成迁移，跳过", category: .migration)
            return Outcome(inserted: 0, skipped: 0, didMark: false, didMoveBackup: false, saveError: nil)
        }

        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            Log.info("[DataMigration] 没有找到旧数据文件，标记为已迁移", category: .migration)
            defaults.set(true, forKey: migrationKey)
            return Outcome(inserted: 0, skipped: 0, didMark: true, didMoveBackup: false, saveError: nil)
        }

        let decoded: (entries: [LegacyDiaryEntry], skipped: Int)
        do {
            let data = try Data(contentsOf: jsonURL)
            decoded = try decodeLegacyEntriesLossy(from: data)
        } catch {
            Log.error("[DataMigration] 迁移失败: \(error)", category: .migration)
            return Outcome(inserted: 0, skipped: 0, didMark: false, didMoveBackup: false, saveError: error)
        }
        let oldEntries = decoded.entries

        Log.info("[DataMigration] 找到 \(oldEntries.count) 条日记待迁移,跳过损坏行 \(decoded.skipped) 条", category: .migration)
        guard !oldEntries.isEmpty || decoded.skipped == 0 else {
            let error = DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "All legacy diary rows failed to decode"
                )
            )
            Log.error("[DataMigration] 所有旧日记行都无法解码,保留原文件等待后续处理", category: .migration)
            return Outcome(inserted: 0, skipped: decoded.skipped, didMark: false, didMoveBackup: false, saveError: error)
        }

        var outcome = Outcome(inserted: 0, skipped: decoded.skipped, didMark: false, didMoveBackup: false, saveError: nil)

        context.performAndWait {
            // **去重守卫**:save 失败路径不会写 `migrationKey`,下次启动会重跑本函数。
            // Core Data 模型没有 uniquenessConstraints,重跑时把同一批 UUID 再插一次
            // **不会**被 Core Data 拦下,会得到同 id 的两条 ghost entry 同步到 CloudKit。
            // 插入前先一次性 fetch 已有 id 集合,按 UUID 去重(O(N) 一次 vs. N × O(log N) 每条 fetch)。
            var seenIDs: Set<UUID> = {
                let req = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
                req.resultType = .dictionaryResultType
                req.propertiesToFetch = ["id"]
                guard let rows = try? context.fetch(req) else { return [] }
                return Set(rows.compactMap { row in
                    (row["id"] as? UUID)
                        ?? (row["id"] as? NSUUID).flatMap { UUID(uuidString: $0.uuidString) }
                })
            }()

            var inserted = 0
            var skipped = decoded.skipped
            for oldEntry in oldEntries {
                if seenIDs.contains(oldEntry.id) {
                    skipped += 1
                    continue
                }
                let newEntry = NSEntityDescription.insertNewObject(forEntityName: "DiaryEntry", into: context)
                newEntry.setValue(oldEntry.id, forKey: "id")
                newEntry.setValue(oldEntry.date, forKey: "date")
                newEntry.setValue(oldEntry.text, forKey: "text")
                newEntry.setValue(oldEntry.moodValue, forKey: "moodValue")
                newEntry.setValue(oldEntry.summary, forKey: "summary")
                if let audioFileName = LumoryAttachmentPaths.normalizedFileName(oldEntry.audioFileName) {
                    newEntry.setValue(audioFileName, forKey: "audioFileName")
                }
                // 回算 wordCount —— 老 v2 JSON 里没这个字段,不补的话 Insights 累计字数 = 0、
                // heatmap 强度全灭,视觉上"好像没写过日记"。`recomputeWordCount` 只读 text,无网络。
                if let typed = newEntry as? DiaryEntry {
                    typed.recomputeWordCount()
                }
                seenIDs.insert(oldEntry.id)
                inserted += 1
            }

            // 保存到 Core Data
            do {
                try context.save()
                Log.info("[DataMigration] 迁移完成:新增 \(inserted) 条,跳过已存在 \(skipped) 条", category: .migration)

                // **同步写标志** —— 不能 DispatchQueue.main.async 到下一 runloop。
                // UserDefaults 是线程安全的(Apple 文档明确),可以直接在 performAndWait
                // 的 bg 队列里同步写入。async 写法下,context.save() 成功到 UserDefaults 写入
                // 之间存在窗口,如果 App 被系统杀(内存压力 / 用户 force-quit),下次启动
                // migrationKey 还没落盘 → performMigrationIfNeeded 再跑一遍 → **数据翻倍导入**。
                defaults.set(true, forKey: migrationKey)

                // 备份原文件(非关键路径,失败可接受)
                let backupURL = jsonURL.appendingPathExtension("backup")
                let didMove = (try? FileManager.default.moveItem(at: jsonURL, to: backupURL)) != nil
                if didMove {
                    Log.info("[DataMigration] 原文件已备份至: \(backupURL.lastPathComponent)", category: .migration)
                }
                outcome = Outcome(inserted: inserted, skipped: skipped, didMark: true, didMoveBackup: didMove, saveError: nil)
            } catch {
                context.rollback()
                Log.error("[DataMigration] Core Data 保存失败: \(error)", category: .migration)
                outcome = Outcome(inserted: 0, skipped: 0, didMark: false, didMoveBackup: false, saveError: error)
            }
        }

        return outcome
    }

    private static func decodeLegacyEntriesLossy(from data: Data) throws -> (entries: [LegacyDiaryEntry], skipped: Int) {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let array = json as? [Any] else {
            throw DecodingError.typeMismatch(
                [Any].self,
                DecodingError.Context(codingPath: [], debugDescription: "Legacy diary JSON root is not an array")
            )
        }

        let decoder = JSONDecoder()
        var entries: [LegacyDiaryEntry] = []
        entries.reserveCapacity(array.count)
        var skipped = 0

        for item in array {
            guard JSONSerialization.isValidJSONObject(item),
                  let rowData = try? JSONSerialization.data(withJSONObject: item),
                  let entry = try? decoder.decode(LegacyDiaryEntry.self, from: rowData) else {
                skipped += 1
                continue
            }
            entries.append(entry)
        }

        return (entries, skipped)
    }

    /// 迁移结果汇报。生产路径不读它(only `performMigrationIfNeeded` wrapper 调用并丢弃),
    /// 单测断言完整契约。
    struct Outcome {
        let inserted: Int
        let skipped: Int
        let didMark: Bool       // migrationKey 是否写盘 true
        let didMoveBackup: Bool // diary.json → diary.json.backup 是否成功
        let saveError: Error?
    }
}
