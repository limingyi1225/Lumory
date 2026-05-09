import CoreData
import Foundation

/// 把 `HomeView.addEntry` 的"附件 I/O + Core Data save + 派生副作用 + AI writeback"
/// 抽出来。命名跟 `SettingsEntryDeletionService` / `EntryDeletionUndoService` 对称。
///
/// **边界**:
/// - `create` 同步语义:落库 + 触发 reminder + StreakMilestone + fire-and-forget AI writeback。
///   返回 `Result` 反映 Core Data save 是否成功。
/// - `performAIWriteback` 单独可 `await`,**带 stale-write guard**:用户在 AI 请求返回前编辑了
///   entry,丢弃这次结果(等 `DiaryDetailView.refreshAIIndex` 用 v2 文本重算)。单测可直接调
///   验证 stale 行为。
/// - 三个 `*OffMain` helper `nonisolated static`:磁盘 I/O / NSKeyedArchiver 不卡 main。
///
/// **副作用注入**:
/// - `aliasJudge`:默认调 `ThemeAliasJudgeService.shared.judgeAfterWrite`。单测传 spy 验证调用次数。
/// - `requestReminderReschedule`:默认调 `ReminderService.shared.requestReschedule`。单测传 `{}`
///   防 reminder 跑 `fetchLastEntryDate()` 时调 `PersistenceController.shared.container`(单测自己
///   起 in-memory store 时会和 shared 冲突)。
/// - `persistence`:`StreakMilestoneService.evaluateAfterSave` 要的 store 句柄,单测传自己的实例。
@MainActor
enum EntryCreationService {

    struct Input {
        let text: String
        let audioFileName: String?
        let images: [Data]
        let moodValue: Double
    }

    enum Result {
        case saved(UUID)
        case failed
    }

    /// 落库 + 派生副作用。AI writeback 是 fire-and-forget(单测要 await 走 `performAIWriteback`)。
    static func create(
        _ input: Input,
        in persistence: PersistenceController,
        viewContext: NSManagedObjectContext,
        ai: AIServiceProtocol,
        aliasJudge: @MainActor @Sendable @escaping (UUID, [String]) async -> Void = { id, tags in
            await ThemeAliasJudgeService.shared.judgeAfterWrite(entryID: id, newTags: tags)
        },
        requestReminderReschedule: @MainActor @Sendable () -> Void = {
            ReminderService.shared.requestReschedule()
        }
    ) async -> Result {
        let entryID = UUID()

        // 把磁盘 I/O、CloudKit blob 编码全部挪到非主线程,主线程只做 Core Data 字段赋值 + save。
        // 之前这些都挤在 `await MainActor.run { ... }` 里,附件多一点 UI 就会卡。
        async let preparedAudio: String? = persistAudioOffMain(audioFileName: input.audioFileName)
        async let preparedImages: [String] = persistImagesOffMain(images: input.images, entryID: entryID)
        async let preparedSyncBlob: Data? = encodeImagesForSyncOffMain(images: input.images)

        let (audioName, imageFileNames, syncBlob) = await (preparedAudio, preparedImages, preparedSyncBlob)

        // 函数本身 `@MainActor`,await 后回到 main,直接做 Core Data 写入,无需嵌套 `MainActor.run`。
        let newEntry = DiaryEntry(context: viewContext)
        newEntry.id = entryID
        newEntry.date = Date()
        newEntry.text = input.text
        newEntry.moodValue = input.moodValue
        newEntry.summary = nil  // 标题稍后异步生成
        newEntry.recomputeWordCount()  // 本地计算,供统计使用

        if let audioName = audioName {
            newEntry.audioFileName = audioName
        }

        if !imageFileNames.isEmpty {
            newEntry.imageFileNames = imageFileNames.joined(separator: ",")
            Log.info("[EntryCreationService] Set imageFileNames: \(newEntry.imageFileNames ?? "")", category: .ui)
        }
        if let syncBlob = syncBlob {
            newEntry.imagesData = syncBlob
        }

        do {
            try viewContext.save()
            Log.info("[EntryCreationService] 日记已保存,标题稍后生成", category: .ui)
        } catch {
            Log.error("[EntryCreationService] 保存日记失败: \(error)", category: .ui)
            // 已落盘的 image 文件孤儿清理 — entry save 失败时这些文件已经被 persistImagesOffMain
            // 写到 Documents/LumoryImages,无人引用就是 storage leak,长期累积。best-effort 删,失败静默。
            // (audio 暂不清:persistAudioOffMain 已把本地副本搬到 iCloud,iCloud 路径由 entry.audioURL 三层
            // fallback 解析,这个 catch 分支拿不到 entry 实例,留给后续策略处理。)
            for fileName in imageFileNames {
                try? DiaryEntry.deleteImageFromDocuments(fileName)
            }
            return .failed
        }

        // 智能 reminder reschedule:任何成功 save(含纯录音 / 纯图片 entry)都可能 fulfill
        // 当前固定周期(cycle-based)。requestReschedule 是 task cancel + replace,多入口并发安全。
        // 注入闭包的目的是单测能传 `{}` 防 reminder 内部偷调 `PersistenceController.shared`。
        requestReminderReschedule()

        // Streak milestone 庆祝。fire-and-forget — 内部跑后台 fetch 算 streak,命中
        // 7/14/30/60/100/(+100) 且之前没庆祝过 → set pendingMilestone,ChronoteApp ZStack 顶层
        // overlay 自动渲染。用最新 entry 的 mood 作 overlay 配色。
        StreakMilestoneService.shared.evaluateAfterSave(
            persistence: persistence,
            latestEntryMood: input.moodValue
        )

        // 异步生成摘要、主题、embedding(stale-write guard 见 `performAIWriteback`)。
        // 生产 fire-and-forget;单测要 await 直接调 `performAIWriteback`。
        if !input.text.isEmpty {
            let textSnapshot = input.text
            Task {
                _ = await performAIWriteback(
                    entryID: entryID,
                    textSnapshot: textSnapshot,
                    in: viewContext,
                    ai: ai,
                    aliasJudge: aliasJudge
                )
            }
        }

        return .saved(entryID)
    }

    /// 把 `addEntry` 末尾的 AI writeback Task 拆成可 await 的方法。返回 `didCommitThemes`:
    /// - stale-write 丢弃 → false,**不调** `aliasJudge`(防 ghost 别名建议)
    /// - 写盘成功 → true,且 `themes.isEmpty == false` 时调 `aliasJudge`
    static func performAIWriteback(
        entryID: UUID,
        textSnapshot: String,
        in viewContext: NSManagedObjectContext,
        ai: AIServiceProtocol,
        aliasJudge: @MainActor @Sendable @escaping (UUID, [String]) async -> Void
    ) async -> Bool {
        async let summaryTask = ai.summarize(text: textSnapshot)
        async let themesTask = ai.extractThemes(text: textSnapshot)
        async let embeddingTask = ai.embed(text: textSnapshot)
        let (summary, themes, embedding) = await (summaryTask, themesTask, embeddingTask)

        let fetchRequest: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
        guard let entry = try? viewContext.fetch(fetchRequest).first else { return false }

        // 跟 DiaryDetailView.refreshAIIndex 同一套 stale-write guard:
        // 用户在 AI 请求返回前编辑了 entry,当前 entry.text 已经被更新就跳过这次写入。
        guard entry.wrappedText == textSnapshot else {
            Log.info("[EntryCreationService] 文本已被更新,丢弃 stale AI 结果(v1 不覆盖 v2)", category: .ai)
            return false
        }

        entry.summary = summary
        entry.setThemes(themes)
        if let vector = embedding {
            entry.setEmbedding(vector)
        }

        let didCommit: Bool
        do {
            try viewContext.save()
            Log.info(
                "[EntryCreationService] 摘要+主题+索引已更新: themes=\(themes.count), hasEmbedding=\(embedding != nil)",
                category: .ai
            )
            didCommit = true
        } catch {
            Log.error("[EntryCreationService] AI 写回保存失败: \(error)", category: .ai)
            didCommit = false
        }

        // Theme alias judge —— 仅在 themes 真的写到 entry 上时才跑。否则 alias 建议会基于
        // ghost 数据(参考 codex review)。
        if didCommit, !themes.isEmpty {
            await aliasJudge(entryID, themes)
        }
        return didCommit
    }

    // MARK: - Off-main I/O helpers

    /// 在后台线程把本地录音拷贝到 iCloud 容器,并删掉本地副本。返回最终落库用的文件名。
    /// 非 `@MainActor`:磁盘读写、FileManager、`Data(contentsOf:)` 都没必要卡主线程。
    nonisolated static func persistAudioOffMain(audioFileName: String?) async -> String? {
        guard let audioFileName = audioFileName else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let localURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(audioFileName)

            if FileManager.default.fileExists(atPath: localURL.path),
               let audioData = try? Data(contentsOf: localURL),
               let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
                let audioDir = iCloudURL.appendingPathComponent("Documents/LumoryAudio")
                let iCloudAudioURL = audioDir.appendingPathComponent(audioFileName)
                do {
                    if !FileManager.default.fileExists(atPath: audioDir.path) {
                        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true, attributes: nil)
                    }
                    try audioData.write(to: iCloudAudioURL, options: .atomic)
                    try? FileManager.default.removeItem(at: localURL)
                    Log.info("[EntryCreationService] Saved audio to iCloud: \(audioFileName)", category: .ui)
                } catch {
                    Log.error(
                        "[EntryCreationService] Audio iCloud write failed, keeping local copy \(audioFileName): \(error)",
                        category: .ui
                    )
                }
            }

            return audioFileName
        }.value
    }

    /// 后台线程把图片逐一落到 documents 目录并返回文件名列表。
    nonisolated static func persistImagesOffMain(images: [Data], entryID: UUID) async -> [String] {
        guard !images.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [String] in
            var names: [String] = []
            names.reserveCapacity(images.count)
            for (index, imageData) in images.enumerated() {
                let fileName = "img_\(entryID.uuidString)_\(index).jpg"
                do {
                    let saved = try DiaryEntry.saveImageToDocuments(imageData, fileName: fileName)
                    names.append(saved)
                    Log.info(
                        "[EntryCreationService] Saved image \(index + 1)/\(images.count): \(saved)",
                        category: .ui
                    )
                } catch {
                    Log.error("[EntryCreationService] 保存图片失败: \(error)", category: .ui)
                }
            }
            return names
        }.value
    }

    /// 后台线程把已压缩的图片 NSKeyedArchiver 编码成 Data,落库时直接赋给 `imagesData`。
    /// 替代原来 `saveImagesForSync`(同步版)在 MainActor 里跑的重活。
    nonisolated static func encodeImagesForSyncOffMain(images: [Data]) async -> Data? {
        guard !images.isEmpty else { return nil }
        do {
            let encoded = try NSKeyedArchiver.archivedData(withRootObject: images, requiringSecureCoding: true)
            Log.info(
                "[EntryCreationService] Encoded \(images.count) images for sync, total size: \(encoded.count) bytes",
                category: .ui
            )
            return encoded
        } catch {
            Log.error("[EntryCreationService] 图片编码失败: \(error)", category: .ui)
            return nil
        }
    }
}

extension EntryCreationService.Result {
    /// 兼容 `addEntry` 旧签名(返回 Bool)。callsite 不必关心 entryID 时用这个。
    var didSave: Bool {
        if case .saved = self { return true }
        return false
    }
}
