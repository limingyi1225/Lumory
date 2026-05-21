//
//  HomeView+Helpers.swift
//  Lumory
//
//  HomeView 杂项 helper —— 不够大到单独成文件但都不在主 view body 里的方法集合。
//
//  覆盖:
//   - **草稿持久化**:`handleInputTextChanged(_:)` + `persistDraft(_:)` 500ms debounce
//     写 AppGroup UserDefaults,scenePhase=background 强 flush。
//   - **照片压缩**:`loadPhotosWithCompression(_:)` 后台 actor 跑 JPEG 压缩,保序 + 配对丢弃。
//   - **占位语**:`inputPlaceholder` / `rollPlaceholderIfNeeded(force:)` / `loadContextPrompts()`
//     —— 三级 fallback (AI 池 → 本地模板 → 兜底中文),启动时本地顶上 + AI 后台 silent 刷新。
//   - **生命周期**:`handleReminderComposeFocusIfNeeded()`(通知点击 → composer focus)+
//     `triggerManualSync()`(pull-to-refresh)。
//

import SwiftUI
import PhotosUI

extension HomeView {

    // MARK: - 草稿持久化

    /// composer 文本变化:500ms debounce 写 AppGroup defaults;空白立即同步清(防 send 后 OOM 还原)。
    func handleInputTextChanged(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draftSaveTask?.cancel()
            draftSaveTask = nil
            AppGroup.userDefaults.removeObject(forKey: "lumory.home.draft.text")
        } else {
            draftSaveTask?.cancel()
            draftSaveTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                Self.persistDraft(newValue)
            }
        }
    }

    /// 草稿写盘的单点入口。空白 → remove key,非空 → set。
    /// `HomeComposerCard.onInputTextChanged` 经 parent 内 debounce 调本函数;
    /// scenePhase=background 强 flush 也走这里。
    static func persistDraft(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppGroup.userDefaults.removeObject(forKey: "lumory.home.draft.text")
        } else {
            AppGroup.userDefaults.set(value, forKey: "lumory.home.draft.text")
        }
    }

    // MARK: - 通知点击 / 同步

    func handleReminderComposeFocusIfNeeded() {
        guard let requestID = reminderRouter.consumeComposeFocusRequest() else { return }
        isSettingsOpen = false
        isInsightsPresented = false
        selectedEntry = nil
        searchQuery = ""
        composerFocusRequestID = nil
        Task { @MainActor in
            await Task.yield()
            composerFocusRequestID = requestID
        }
    }

    /// Pull-to-refresh：触发 CloudKit 同步 + 换一条占位语（从当前池里挑一个不同项）。
    /// AI 池的 `refreshIfNeeded` 走**独立 detached Task**，不塞进 refreshable 窗口——
    /// 否则如果指纹变了要调一次 gpt-5.5（~2-3s），用户会感觉"下拉卡好几秒"。
    /// AI 刷完之后下一次下拉/聚焦才用得上，体感上毫无损失。
    func triggerManualSync() async {
        syncMonitor.forceSync()
        rollPlaceholderIfNeeded(force: true)
        Task.detached(priority: .utility) {
            await PromptSuggestionEngine.shared.refreshIfNeeded()
        }
        await Task.yield()
    }

    // MARK: - 照片压缩

    func loadPhotosWithCompression(_ items: [PhotosPickerItem]) async {
        photoVM.photoSelectionGeneration &+= 1
        let generation = photoVM.photoSelectionGeneration
        photoVM.isProcessingSelection = true
        photoVM.compressionFailureCount = 0
        photoVM.selectedImageItems.removeAll()

        guard !items.isEmpty else {
            photoVM.isProcessingSelection = false
            return
        }

        // 新一轮 pick 开始就清掉旧缩略图/失败 banner,不让旧照片在压缩期间还能被发送。
        // 真正的 failed count 在末尾根据本轮结果重新写入。
        // 关键改动 1:每个 item 走 Task.detached 跳到后台 actor —— 之前 addTask 继承父
        // MainActor,compressImage 里的 UIImage 解码 + JPEG 重编码全卡在主线程上,选 9 张图
        // 直接掉帧到底。detached 之后 UI 不再被压死,选完照片到出现缩略图之间也没有阻塞。
        //
        // 关键改动 2:**保序 + 配对收集**。每个 (PhotosPickerItem, Data?) 一起收回来,
        // 失败的丢弃但**两边一起丢弃**。之前只 compactMap selectedImages,
        // selectedPhotos 没动 → 长度不一致 → 删除时按 selectedImageItems 的 idx
        // 然后用同 idx 删 selectedPhotos 删错。F2 fix:同步重建 selectedPhotos。
        var indexed: [(Int, Data?)] = []

        await withTaskGroup(of: (Int, Data?).self) { group in
            for (idx, item) in items.enumerated() {
                group.addTask {
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        return (idx, nil)
                    }
                    let compressed = await Task.detached(priority: .userInitiated) {
                        await data.compressImage(maxSizeKB: 500, maxDimension: 1024)
                    }.value
                    return (idx, compressed)
                }
            }
            for await result in group {
                if Task.isCancelled { return }   // F1:任务被取消立即收手
                indexed.append(result)
            }
        }

        // F1:任务被取消则不更新 state,让新任务去主导。
        if Task.isCancelled { return }

        // 按 idx 排序,只保留压缩成功的 (item, data) 对。
        let successful: [(PhotosPickerItem, Data)] = indexed
            .sorted { $0.0 < $1.0 }
            .compactMap { i, data -> (PhotosPickerItem, Data)? in
                guard let data else { return nil }
                return (items[i], data)
            }

        let prunedItems = successful.map(\.0)
        let imageItems = successful.map { HomePhotoViewModel.SelectedImage(data: $0.1) }
        // **失败提示** —— 9 张选 7 张成功 → 之前 silently drop 2 张,用户以为都加了。把失败数推进 VM
        // 让 banner 显示;0 时不显示。
        let failedCount = items.count - successful.count

        await MainActor.run {
            guard photoVM.photoSelectionGeneration == generation else { return }
            photoVM.compressionFailureCount = failedCount
            photoVM.selectedImageItems = imageItems
            // F2:把 selectedPhotos 也剪枝到只剩压缩成功的 items,保证两边长度严格对齐。
            // 等值检查避免触发自身的 .onChange 死循环 —— PhotosPickerItem 是 Equatable。
            if photoVM.selectedPhotos != prunedItems {
                photoVM.suppressNextPhotoSelectionReload = true
                photoVM.selectedPhotos = prunedItems
            }
            photoVM.isProcessingSelection = false
            Log.info("[HomeView] Total compressed images: \(photoVM.selectedImageItems.count)", category: .ui)
        }
    }

    // MARK: - Context prompt helpers

    /// 输入框占位文字。**stable**：一旦选定就不变，避免 SwiftUI body 重评时反复换。
    /// 重新选只发生在几个明确时刻：进入首页、发送后清空、AI 池更新完成、本地模板加载完成。
    var inputPlaceholder: String {
        let raw = inputVM.stablePlaceholder.isEmpty
            ? NSLocalizedString("今天是怎样的一天呢？", comment: "Daily prompt fallback")
            : inputVM.stablePlaceholder
        return Self.normalizePlaceholderPunctuation(raw)
    }

    /// 用户决定 (2026-05-19) — 输入框 prompt 只在**问句**时保留问号 (?/?),其他时候不要句末
    /// 终结标点。AI 生成池里很多 "今天有什么有趣的事。" 这种陈述句配句号读起来生硬;改成
    /// "今天有什么有趣的事" 更像 placeholder。问句保留 ?/? 因为它本身是邀请用户回答的语义。
    static func normalizePlaceholderPunctuation(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.unicodeScalars.last else { return trimmed }
        // 句末问号一律保留(中英都是邀请回答的语义)。
        if last == "?" || last == "？" { return trimmed }
        // 句末终结标点(中英句号 / 感叹号 / 中文省略号)一律剥掉。
        let strip: Set<Unicode.Scalar> = [".", "。", "!", "！", "…"]
        if strip.contains(last) {
            return String(trimmed.unicodeScalars.dropLast())
        }
        return trimmed
    }

    /// 在三级 fallback 里挑一条写入 `stablePlaceholder`：
    ///   1. AI 池 `PromptSuggestionEngine.randomHomePlaceholder`
    ///   2. 本地 `contextPrompts` 第一条
    ///   3. 不动（保持 "今天是怎样的一天呢？" 兜底）
    func rollPlaceholderIfNeeded(force: Bool = false) {
        if !force && !inputVM.stablePlaceholder.isEmpty { return }
        if let aiLine = PromptSuggestionEngine.shared.randomHomePlaceholder() {
            inputVM.stablePlaceholder = aiLine
            return
        }
        if let first = inputVM.contextPrompts.first {
            inputVM.stablePlaceholder = first.text
            return
        }
        // 保持旧值；下次 AI 池 / 本地模板就绪会再试
    }

    /// 启动 / 进入首页时调。**本地 fallback 顶上,AI 在后台静默刷新**:
    /// 冷启动 + 无 cache + 网慢时,`refreshIfNeeded` 可能要几秒。先把本地
    /// `ContextPromptGenerator` 的结果 apply + roll 一次,AI 写完之后**只更新 cache,
    /// 不在用户面前 re-roll** —— 用户下次下拉刷新 / 发送日记后才看到新的 AI 提示词。
    /// 之前的"AI 完成后强制 re-roll"会在用户盯着首页时占位语突然换字,体验不好。
    func loadContextPrompts() async {
        // AI 在后台静默刷新,完成后落到 PromptSuggestionEngine.shared.current,
        // 等下次 rollPlaceholderIfNeeded(force: true) 被用户主动触发时才用上。
        Task.detached(priority: .utility) {
            await PromptSuggestionEngine.shared.refreshIfNeeded()
        }

        let prompts = await ContextPromptGenerator.shared.generate()
        await MainActor.run {
            withAnimation(AnimationConfig.smoothTransition) {
                inputVM.contextPrompts = prompts
            }
            rollPlaceholderIfNeeded()
        }
    }
}
