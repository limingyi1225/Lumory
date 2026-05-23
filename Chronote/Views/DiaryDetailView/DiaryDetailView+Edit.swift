//
//  DiaryDetailView+Edit.swift
//  Lumory
//
//  DiaryDetailView 的编辑模式 + 删除入口。从主文件抽出来。
//
//  入口(主文件 body / toolbar 调):
//    - `startEditing()`        — toolbar "编辑" Menu / `.onAppear` startInEditMode
//    - `cancelEditing()`       — toolbar "取消" + discardChanges alert "放弃"
//    - `saveChanges()`         — toolbar "保存" 按钮
//    - `deleteEntry()`         — toolbar "删除" Menu(走 4 秒撤销 toast,不再 alert)
//
//  辅助(本文件 private):
//    - `refreshAIIndex(for:newText:ai:)` — 编辑后台 extractThemes + embed + alias judge,
//      含 stale-write guard + partial-failure guard。
//

import SwiftUI
import CoreData

extension DiaryDetailView {

    // MARK: - Delete entry (4 秒撤销 toast)

    func deleteEntry() {
        audioPlaybackController.stopPlayback(clearCurrentFile: true)

        // P1-Home-6 撤销 — 跟 HomeView.deleteEntry 同 pattern。snapshot 在 delete 之前抓,
        // attachment 文件不立刻删,4 秒后由 EntryDeletionUndoService.commitPendingNow 跑。
        let snapshot = EntryDeletionSnapshot(entry: entry)
        viewContext.delete(entry)

        do {
            try viewContext.save()
            HapticManager.shared.destructive()
            // 单删派生缓存清理统一走 EntryWipeOrchestrator。
            EntryWipeOrchestrator.performSingleDeleteCleanup()
            onDeleted?()

            // 注册到 undo service + 弹带"撤销"按钮 toast。dismiss 后 root overlay / 父视图 overlay
            // 接管 toast 渲染(InsightsView / Home 都已挂 lumoryToastOverlay)。
            let viewContextRef = viewContext
            EntryDeletionUndoService.shared.register(snapshot: snapshot)
            LumoryToastCenter.shared.show(
                NSLocalizedString("已删除", comment: "Toast after entry deletion"),
                severity: .success,
                duration: EntryDeletionUndoService.undoWindow,
                action: LumoryToastCenter.Action(
                    label: NSLocalizedString("撤销", comment: "Undo delete action")
                ) {
                    if EntryDeletionUndoService.shared.undo(into: viewContextRef) != nil {
                        #if canImport(UIKit)
                        HapticManager.shared.notification(.success)
                        #endif
                    }
                }
            )
            dismiss()
        } catch {
            viewContext.rollback()
            Log.error("[DiaryDetailView] 删除日记失败: \(error)", category: .ui)
            saveError = NSLocalizedString("删除失败,可能是磁盘空间不足或同步冲突。请稍后重试。", comment: "Generic delete failure fallback")
        }
    }

    // MARK: - Edit mode lifecycle

    func startEditing() {
        Log.info("[DiaryDetailView] Starting edit mode", category: .ui)
        editedSummary = entry.wrappedSummary ?? ""
        editedText = entry.wrappedText
        editedMoodValue = entry.moodValue
        editedDate = Self.dateRoundedToMinute(entry.wrappedDate)
        removedImageFileNames = []
        removedAudioFileName = nil
        originalAudioFileNameAtEditStart = entry.audioFileName
        hasUnsavedChanges = false

        withAnimation(AnimationConfig.gentleSpring) {
            isEditing = true
        }

        HapticManager.shared.impact(.light)
    }

    func cancelEditing() {
        // 防御:用户在编辑模式开过日期 sheet 没关掉就点取消 → sheet 残留 / 下次进编辑闪一下。
        // cancelEditing 是退出编辑态的 single source of truth,在这里 reset 所有编辑专属 UI 状态。
        showDatePopover = false
        removedImageFileNames = []
        removedAudioFileName = nil
        originalAudioFileNameAtEditStart = nil
        Task { await refreshResolvedAudioURL() }

        withAnimation(AnimationConfig.gentleSpring) {
            isEditing = false
        }
        hasUnsavedChanges = false

        // 隐藏键盘
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    func saveChanges() {
        // **P1 fix (2026-05-15 megareview)**:`body` 顶部已 guard `entry.isDeleted` 自动 dismiss,
        // 但键盘升起 + body 不重 eval 期间,CloudKit pull 删了这条 entry → 用户点保存 →
        // 写入 tombstoned object → 要么静默"复活"、要么 save 抛 merge conflict 被显示为模糊"保存失败"。
        // 这里再 guard 一次,有效兜底"body guard 之后到 save 调用之间"的 race 窗口。
        guard !entry.isDeleted, entry.managedObjectContext != nil else {
            Log.info("[DiaryDetailView] entry 在保存前已被删除/失效, 跳过 save 并 dismiss", category: .ui)
            dismiss()
            return
        }
        // text 变化了就需要在后台重跑 themes + embedding（否则 Insight 主题聚合和
        // Ask Past 的语义检索会继续用旧内容的索引）。先捕获对比值，再写 Core Data。
        let textChanged = entry.wrappedText != editedText
        let normalizedEditedDate = Self.dateRoundedToMinute(min(editedDate, Date()))
        let calendar = Calendar.current
        let dateChanged = !calendar.isDate(entry.wrappedDate, equalTo: normalizedEditedDate, toGranularity: .minute)
        let moodChanged = entry.moodValue != editedMoodValue
        let normalizedSummary = editedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryChanged = (entry.summary ?? "") != normalizedSummary
        let originalImageFileNames = entry.imageFileNameArray
        let removedImages = Set(originalImageFileNames).intersection(removedImageFileNames)
        let remainingImageFileNames = originalImageFileNames.filter { !removedImages.contains($0) }
        let originalSyncedImages = !removedImages.isEmpty ? entry.loadImagesFromSync() : []
        let removedAudio = removedAudioFileName == originalAudioFileNameAtEditStart ? removedAudioFileName : nil
        let mediaChanged = !removedImages.isEmpty || removedAudio != nil
        let narrativeInputChanged = textChanged || dateChanged || moodChanged || summaryChanged
        let entryObjectID = entry.objectID

        entry.summary = normalizedSummary
        entry.text = editedText
        entry.moodValue = editedMoodValue
        entry.date = dateChanged ? normalizedEditedDate : entry.wrappedDate
        if !removedImages.isEmpty {
            entry.imageFileNames = remainingImageFileNames.isEmpty ? nil : remainingImageFileNames.joined(separator: ",")
            entry.imagesData = Self.encodedImagesData(
                originalFileNames: originalImageFileNames,
                remainingFileNames: remainingImageFileNames,
                originalSyncedImages: originalSyncedImages
            )
        }
        if removedAudio != nil {
            entry.audioFileName = nil
        }
        if textChanged {
            entry.recomputeWordCount()   // 本地算，免费，现在就更新
        }

        do {
            // **先 save，再切 UI 状态**。原顺序反了——catch 里只 log，UI 已经切到 "saved"，
            // 用户以为已保存其实没存。save 成功才做"切换到浏览态 / 关键盘 / 触发后台任务"。
            try viewContext.save()

            // 改 date 可能让 entry 移入/移出当前固定周期(cycle-based,锚点对齐),
            // 进而改变 wroteCurrentCycle → reminder 要重排。
            if dateChanged {
                ReminderService.shared.requestReschedule()
            }

            // **改 date 还可能改变 streak 算法的全 unique-days 集合** —— widget cheap fingerprint 仅看
            // (count, latestDate, latestMood, prompt),改老 entry 的 date 不在 fingerprint 范围内,
            // 短路会让 widget streak 不更新。改 mood 也类似(若改的是非最新 entry 的 mood,fingerprint 也不变,
            // 但实际 widget 头像色不受影响 — 只 latest mood 决定;留个保险)。invalidate 让下次 refresh
            // 强制 full path 重抓。NSManagedObjectContextDidSave observer 会 schedule 下一次 refresh。
            if textChanged || dateChanged || moodChanged || summaryChanged {
                Task { await WidgetSnapshotService.shared.invalidateCaches() }
            }

            if dateChanged {
                StreakMilestoneService.shared.evaluateAfterSave(
                    persistence: PersistenceController.shared,
                    latestEntryMood: editedMoodValue
                )
            }

            // 顺序优化(修保存掉帧):
            //   1. 先关键盘 —— 让系统先开始它的 dismiss 动画
            //   2. 再切 isEditing —— 不用 spring(spring 物理重算 + 多视图重排会撞上键盘动画掉帧)
            //   3. 触觉 + 后台任务 放最后
            #if canImport(UIKit)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif

            withAnimation(.smooth(duration: 0.22)) {
                isEditing = false
            }
            hasUnsavedChanges = false
            removedImageFileNames = []
            removedAudioFileName = nil
            originalAudioFileNameAtEditStart = nil
            if mediaChanged {
                let imagesToDelete = Array(removedImages)
                let audioToDelete = removedAudio
                Task.detached(priority: .utility) {
                    for fileName in imagesToDelete {
                        try? DiaryEntry.deleteImageFromDocuments(fileName)
                    }
                    if let audioToDelete {
                        DiaryEntry.deleteAudioFromDocuments(audioToDelete)
                    }
                }
                Task { await refreshResolvedAudioURL() }
            }

            #if canImport(UIKit)
            HapticManager.shared.complete()
            #endif
            // P0-2 全局 toast —— Detail 保存原本只 haptic,新加 visual feedback。
            LumoryToastCenter.shared.show(
                NSLocalizedString("已保存", comment: "Toast after diary entry edit saved"),
                severity: .success
            )

            if textChanged {
                // 快照捕获：Task.detached 是 @Sendable，View struct 不能整个跨线程传。
                // aiService 从 Environment 取，这里捕一个 Sendable 引用传进 static 方法，
                // 便于测试 / Preview 通过 `.environment(\.aiService, MockAIService())` 替换。
                let textSnapshot = editedText
                let ai = aiService
                Task(priority: .utility) {
                    await Self.refreshAIIndex(for: entryObjectID, newText: textSnapshot, ai: ai)
                }
            }
            if narrativeInputChanged {
                // Narrative 输入包含日期 / 心情 / 摘要 / 正文。任一项变化都要让旧回顾退出
                // 浓缩卡 cache,否则会继续显示旧日期、旧心情或旧摘要语义。
                // (2026-05-15 superreview-3 P1)Narrative marker/cancel 只管 narrative,
                // **编辑路径**的 InsightsResultCache 失效在这里 sync 调,
                // 跟删除路径(performSingleDeleteCleanup)对齐。否则 SWR hit 在编辑后
                // 300-600ms 内显示编辑前 themes/dailyCells/entryCount(megareview P1-7 fix)。
                InsightsResultCache.shared.clear()
                EntryWipeOrchestrator.markNarrativeChangedNow()
                Task { await EntryWipeOrchestrator.finishNarrativeInvalidationAfterEntryChange() }
            }
            if mediaChanged {
                Task { await WidgetSnapshotService.shared.invalidateCaches() }
            }
        } catch {
            Log.error("[DiaryDetailView] 保存更改失败: \(error)", category: .ui)
            // **P1 fix (2026-05-15 megareview + superreview)**:save 抛异常时,前面 line 638-644 已经
            // 把 editedText/editedDate/editedMoodValue/normalizedSummary 写进 in-memory entry。
            // 不撤销则屏幕显示脏写值(看起来像保存成功),下次重开才发现旧内容。
            //
            // 用 `refresh(entry, mergeChanges: false)` 只回滚**当前 entry** 的 in-memory 状态,
            // 不动 viewContext 里别的 entry。老用 `viewContext.rollback()` 会把整个共享 context
            // (包括 refreshAIIndex / 别处 sheet 在飞的 best-effort 写)的 in-memory 改动全洗掉。
            viewContext.refresh(entry, mergeChanges: false)
            removedImageFileNames.removeAll()
            removedAudioFileName = nil
            originalAudioFileNameAtEditStart = entry.audioFileName
            Task { await refreshResolvedAudioURL() }
            // **明确告知用户保存失败**——不能静默，否则用户以为改动已入库但下次打开还是旧内容。
            // 用人话 fallback 而不是 NSError.localizedDescription("Cocoa error 134200" 类技术码对终端用户毫无意义)。
            saveError = NSLocalizedString("保存失败,可能是磁盘空间不足或同步冲突。请稍后重试。", comment: "Generic save failure fallback")
        }
    }

    // MARK: - Background AI index refresh

    /// 编辑后台刷新：跑一次 extractThemes + embed，写回 Core Data。
    /// 取 objectID 而不是 entry 引用——viewContext 可能在 Task 跑到时已经切换，直接用 objectID 去
    /// viewContext 重新 fetch 更安全。任何一步失败都静默跳过，不影响用户主动保存的已完成状态。
    ///
    /// 文本空 → 清空 themes/embedding（老的语义索引保留会让 AskPast 检索捞出"空内容带旧主题"的条目）。
    /// 写回前做 staleness guard：用户连续快速保存两次时，两个 Task.detached 都在跑，顺序不保证；
    /// 后提交的（text=v2）可能比先提交的（text=v1）先完成网络调用。没有 guard 的话慢的那条
    /// `setThemes(v1)` 会覆盖快的 `setThemes(v2)`，entry.text 是 v2 但 themes/embedding 是 v1，
    /// 静默污染语义检索。比较 `entry.wrappedText == newText`:只有当前 text 还等于我们当初快照的
    /// 那条才写。
    static func refreshAIIndex(for objectID: NSManagedObjectID, newText: String, ai: AIServiceProtocol) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)

        let themeOutcome: ThemeExtractionOutcome
        let embedding: [Float]?
        if trimmed.isEmpty {
            // 用户把内容清空：直接清 themes + embedding，不发网络
            themeOutcome = .success([])
            embedding = nil
        } else {
            async let themesTask = ai.extractThemesOutcome(text: trimmed)
            async let embeddingTask = ai.embed(text: trimmed)
            (themeOutcome, embedding) = await (themesTask, embeddingTask)
        }

        // 把"是否真的提交了 themes" + entryID 一起跨出 MainActor.run。
        // 如果 stale guard 丢了写入,我们仍要 short-circuit 后面的 alias judge,
        // 否则会基于 ghost 数据生成建议。codex review 标记为 high-priority 修。
        let postWrite: (committed: Bool, entryID: UUID?, themes: [String]) = await MainActor.run {
            let context = PersistenceController.shared.container.viewContext
            guard let entry = try? context.existingObject(with: objectID) as? DiaryEntry else {
                Log.error("[DiaryDetailView] refreshAIIndex: 原条目已不存在", category: .ai)
                return (false, nil, [])
            }
            // Stale-write guard：如果 entry.text 已经被更后的保存改掉了，这次 Task 结果已过期，
            // 直接丢弃不写，让新 Task 的新 themes/embedding 生效。
            // 比较时都做 trim——否则末尾换行 / 空格差异会被误判为"已被更新"。
            let currentTrimmed = entry.wrappedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard currentTrimmed == trimmed else {
                Log.info("[DiaryDetailView] refreshAIIndex: 文本已被更新的保存覆盖，丢弃 stale 结果", category: .ai)
                return (false, entry.id, [])
            }

            let committedThemes: [String]
            if trimmed.isEmpty {
                // 用户明确把内容清空了 → 清掉 themes + embedding（这是用户意图）
                entry.setThemes([])
                entry.embedding = nil
                committedThemes = []
            } else {
                // **Partial-failure guard**：主题抽取现在用 outcome 区分"合法无主题"和"请求失败"。
                // `.success([])` 代表用户把文本改成确实无主题的内容,必须清掉旧 themes;只有
                // `.failed` 或 embedding nil 才保留旧索引,避免 transient 故障污染 entry。
                guard case .success(let themes) = themeOutcome,
                      let vector = embedding,
                      !vector.isEmpty else {
                    Log.info("[DiaryDetailView] refreshAIIndex: AI 部分失败（themeOutcome=\(String(describing: themeOutcome)), embedding=\(embedding != nil ? "ok" : "nil")），保留原值", category: .ai)
                    return (false, entry.id, [])
                }
                entry.setThemes(themes)
                entry.setEmbedding(vector)
                committedThemes = themes
            }

            do {
                try context.save()
                let themeCount: Int
                if case .success(let themes) = themeOutcome {
                    themeCount = themes.count
                } else {
                    themeCount = -1
                }
                Log.info("[DiaryDetailView] refreshAIIndex 完成：themes=\(themeCount), embedding=\(embedding != nil ? "ok" : "nil")", category: .ai)
                return (true, entry.id, committedThemes)
            } catch {
                Log.error("[DiaryDetailView] refreshAIIndex save 失败: \(error)", category: .ai)
                context.refresh(entry, mergeChanges: false)
                return (false, entry.id, [])
            }
        }

        // Theme alias judge —— **仅当 themes 真写入时才跑**(stale-write 或 partial-failure 时跳过)。
        if postWrite.committed, !postWrite.themes.isEmpty, let entryID = postWrite.entryID {
            await ThemeAliasJudgeService.shared.judgeAfterWrite(
                entryID: entryID,
                newTags: postWrite.themes
            )
        }
    }

    private static func encodedImagesData(
        originalFileNames: [String],
        remainingFileNames: [String],
        originalSyncedImages: [Data]
    ) -> Data? {
        guard !remainingFileNames.isEmpty else { return nil }
        let remainingNameSet = Set(remainingFileNames)
        let remainingPairs: [(String, Data)]
        if originalSyncedImages.count == originalFileNames.count {
            remainingPairs = originalFileNames.enumerated().compactMap { index, fileName in
                remainingNameSet.contains(fileName) ? (fileName, originalSyncedImages[index]) : nil
            }
        } else {
            remainingPairs = remainingFileNames.compactMap { fileName in
                if let originalIndex = originalFileNames.firstIndex(of: fileName),
                   originalSyncedImages.indices.contains(originalIndex) {
                    return (fileName, originalSyncedImages[originalIndex])
                }
                guard let data = DiaryEntry.loadImageData(fileName: fileName) else {
                    Log.warning("[DiaryDetail] Missing retained image data for \(fileName); dropping stale image reference", category: .persistence)
                    return nil
                }
                return (fileName, data)
            }
        }
        let images = remainingPairs.map(\.1)
        guard images.count == remainingFileNames.count else { return nil }
        guard !images.isEmpty else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: images, requiringSecureCoding: true)
    }

    private static func dateRoundedToMinute(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components) ?? date
    }
}
