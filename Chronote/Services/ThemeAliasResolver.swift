import Foundation
import CoreData
import Combine

// MARK: - ThemeAliasResolver
//
// 用户的主题里同一实体常分裂成多个标签:"Abby" / "宝贝" / "老婆" 实际是同一个人。
// 这个模块负责
//   1) 持久化 canonical → aliases 的别名映射(group)
//   2) 维护"用户明确否决"的 negative pair(避免重复打扰)
//   3) 维护一个待审 PendingSuggestion 队列(on-write AI judge + 一次性 scan 都往这里写)
//   4) 给聚合层一个 O(1) 的 `canonicalize(_:)`,在展示层把别名折成 canonical
//
// **不修改 entry 的 themes CSV**——alias 是纯展示层语义,raw 数据永不丢,
// 用户改主意立刻拆开就行。注入点只有两处:
//   - InsightsEngine.aggregateThemes 的 bucket key
//   - ContextPromptGenerator.fetchEntries 构建 Snapshot 时
//
// ## 架构(2026-05-16 拆分后)
//
// Resolver 是 **ObservableObject facade** —— callsite 维持原貌 `ThemeAliasResolver.shared`
// + `@ObservedObject`。底层数据 + 持久化拆到 `ThemeAliasStore`(non-ObservableObject)。
//
// Resolver 持有 `private let store: ThemeAliasStore`,职责:
//   - **read forward**:`groups` / `negativePairs` / `pending` / `coolUntil` / `didAutoScanOnce`
//     是 computed var,转发 store
//   - **mutation**:每个 mutation 方法 `objectWillChange.send()` → `store.update { ... }` →
//     处理 side effects(reschedule timer / post notification / 重置 dismiss count)
//   - **queue/throttle 状态**:`sessionDismissCount` / `coolUntilExpiryTimer` 留这里(UI 层语义)
//   - **read-only API forward**:`canonicalize` / `snapshotIndex` / `knownLowercasedTagsCovered` /
//     `isNegative` / `collateralLabels` 全部转发 store
//
// ## 关键不变量
//
//   - **objectWillChange 必须在 store.update 之前**:Resolver 不是 store 的订阅者,
//     SwiftUI 不会自动追到 store 字段变化。
//   - **`coolUntil` 写入后必须 `scheduleCoolUntilExpiry()`**:替换原本 didSet,
//     C4 fix 的"7 天后 red dot 自动重亮"依赖这个 Timer。
//   - **mutation 完了 post `.themeAliasMapDidChange`**(原条件,不要漏):
//     InsightsView / banner / management view 等 NotificationCenter 订阅者依赖。

@MainActor
final class ThemeAliasResolver: ObservableObject {
    static let shared = ThemeAliasResolver()

    private let store: ThemeAliasStore

    // MARK: - State forwarding (向后兼容,callsite 无感)

    var groups: [String: [String]] { store.groups }
    var negativePairs: Set<String> { store.negativePairs }
    var pending: [PendingSuggestion] { store.pending }
    var coolUntil: Date? { store.coolUntil }
    var didAutoScanOnce: Bool { store.didAutoScanOnce }

    // MARK: - Queue throttle / cool-down(UI 层语义,留 Resolver)

    /// 一次 session 内"稍后/不是"按了几次。达到 `snoozeThreshold` 进入 `coolDuration` 冷却。
    private var sessionDismissCount: Int = 0
    private let snoozeThreshold = 3
    private let coolDuration: TimeInterval = 7 * 24 * 60 * 60  // 7 天

    /// 给 SwiftUI 重渲染补救:`redDotVisible` 读 `Date()` 跟 `coolUntil` 比,光改 `coolUntil`
    /// 触发的 objectWillChange 不够 —— 7 天后真正到期时,如果不主动 fire 一次 view 重算,
    /// red dot 该亮但不亮直到下一次 mutation。C4 fix 由这个 one-shot Timer 兜底。
    private var coolUntilExpiryTimer: Timer?

    // MARK: - Init

    private init() {
        self.store = ThemeAliasStore()
        scheduleCoolUntilExpiry()
    }

    // 测试用 init,不读 UserDefaults
    init(testingWithEmptyState defaults: UserDefaults) {
        self.store = ThemeAliasStore(testingWithEmptyState: defaults)
    }

    // 测试用 init,从指定 UserDefaults 读已有 DiskState,验证持久化往返。
    init(testingWithStoredState defaults: UserDefaults) {
        self.store = ThemeAliasStore(testingWithStoredState: defaults)
        scheduleCoolUntilExpiry()
    }

    // MARK: - Pure read API forward

    /// 在聚合 / 展示层使用。命中别名 → 返回 canonical;否则返回 trimmed NFC 原文。
    func canonicalize(_ raw: String) -> String { store.canonicalize(raw) }

    /// 批量 canonicalize + 去重(保留首次 canonical 的原文大小写)。
    func canonicalize(all rawTags: [String]) -> [String] { store.canonicalize(all: rawTags) }

    /// `lowercased(alias) → canonical(原文大小写)`。供非 MainActor 消费者预先抓快照。
    /// **复制一次**:Dict 是值类型,O(N) copy 但 N 通常 <200。
    func snapshotIndex() -> [String: String] { store.snapshotIndex() }

    /// 已合并 group 覆盖的所有 lowercased tag 集合。scan service dedupe 用。
    func knownLowercasedTagsCovered() -> Set<String> { store.knownLowercasedTagsCovered() }

    func isNegative(_ a: String, _ b: String) -> Bool { store.isNegative(a, b) }

    /// 长按合并预览的"会附带搬走"的标签。空数组表示无附带搬移。
    func collateralLabels(forMerging source: String, into target: String) -> [String] {
        store.collateralLabels(forMerging: source, into: target)
    }

    // MARK: - Derived state

    var pendingCount: Int { store.pending.count }

    /// Settings gear 红点 + Home banner 触发条件。冷却期内一律 false。
    var redDotVisible: Bool {
        guard pendingCount > 0 else { return false }
        if let coolUntil = store.coolUntil, Date() < coolUntil { return false }
        return true
    }

    // MARK: - Pending lifecycle

    /// 入队一条建议。会自动跳过:
    ///   - 与已有 group 矛盾(newTag 已是另一个 canonical 的 alias)
    ///   - 命中 negativePairs
    ///   - pending 里已有同对子(unordered)
    /// 返回 true 表示新增成功,false 表示被跳过。
    @discardableResult
    func enqueue(_ suggestion: PendingSuggestion) -> Bool {
        let newKey = suggestion.newTag.lowercased()
        let originalCanonKey = suggestion.canonicalGuess.lowercased()

        // newTag == canonical 没意义
        if newKey == originalCanonKey { return false }

        let indexSnapshot = store.snapshotIndex()

        // newTag 已经是某 canonical 的别名 → 跳过(已合并)
        if let existingCanon = indexSnapshot[newKey],
           existingCanon.lowercased() != newKey {
            return false
        }

        // canonicalGuess 已经是某 canonical 的别名 → **归一化**到该 canonical 而不是丢弃。
        // 之前的实现直接 `return false`,导致用户合理建议"老婆 ↔ 宝贝(已是 Abby alias)"
        // 被静默丢 —— 用户期望"通过现有 alias 加新别名(老婆 → Abby group)"被无声忽略
        // (codex P1 #16 fix)。
        let resolvedCanonical: String
        if let existingCanon = indexSnapshot[originalCanonKey],
           existingCanon.lowercased() != originalCanonKey {
            // canonicalGuess 是别人的 alias —— 重写到那个 canonical
            // 但若那个 canonical 就是 newTag 自己(reversed pair 的 corner case)→ 还是没意义
            if existingCanon.lowercased() == newKey { return false }
            resolvedCanonical = existingCanon
        } else {
            resolvedCanonical = suggestion.canonicalGuess
        }
        let canonKey = resolvedCanonical.lowercased()

        // 双向命中 negativePairs → 跳过。
        // **同时**检查 raw `originalCanonKey` 和 resolved `canonKey`:reject 当时存的是
        // 原对子 (newTag, canonicalGuess),后来 canonicalGuess 被合并成别人的 alias 时,
        // resolved key 跟 reject 时的 key 不同 → 仅检 resolved 会让已 reject 的对子换个 canonical 名又冒出来。
        let resolvedPairKey = ThemeAliasStore.pairKey(newKey, canonKey)
        if store.negativePairs.contains(resolvedPairKey) { return false }
        if originalCanonKey != canonKey {
            let originalPairKey = ThemeAliasStore.pairKey(newKey, originalCanonKey)
            if store.negativePairs.contains(originalPairKey) { return false }
        }

        // pending dedup 用 **unordered pair key**,与 negativePairs 对齐:
        // AI 在两次 scan 间可能 swap newTag/canonicalGuess —— 之前的 direction-aware 比较会让
        // 同一对子重复入队,用户被迫审核两次(codex P2 fix)。
        if store.pending.contains(where: {
            ThemeAliasStore.pairKey($0.newTag.lowercased(), $0.canonicalGuess.lowercased()) == resolvedPairKey
        }) { return false }

        // 入队的是**归一化后**的版本。若 canonicalGuess 被改写成现有 canonical,UI / confirm 都
        // 看到一致结果,不再有"看着像 X 实际合到 Y"的暗坑。
        let normalized: PendingSuggestion
        if resolvedCanonical == suggestion.canonicalGuess {
            normalized = suggestion
        } else {
            normalized = PendingSuggestion(
                id: suggestion.id,
                newTag: suggestion.newTag,
                canonicalGuess: resolvedCanonical,
                confidence: suggestion.confidence,
                sampleEntryIds: suggestion.sampleEntryIds,
                createdAt: suggestion.createdAt,
                source: suggestion.source
            )
        }

        objectWillChange.send()
        store.update { state in
            // L: hard cap pending size。文件顶部注释自称 "<200",这里强制。
            // 超过则丢最旧一条(FIFO 策略 —— 用户半年没处理的老 suggestion 优先级低于刚识别的新对子)。
            // 实际场景下用户主动 confirm/reject 后 pending 会被清掉,200 是工程上限不是日常预期值。
            let maxPending = 200
            state.pending.append(normalized)
            if state.pending.count > maxPending {
                state.pending.removeFirst(state.pending.count - maxPending)
                Log.info("[ThemeAliasResolver] pending 超过 \(maxPending),丢最旧若干条", category: .persistence)
            }
        }
        return true
    }

    /// 用户在 banner / pendingCard 上"接受合并"。
    ///
    /// **语义(2026-04-28 改)**:**只把 `suggestion.newTag` 合并到 `canonicalChoice`,
    /// `canonicalGuess` 不动**。
    ///
    /// 之前的实现把 newTag + canonicalGuess + chosen 三方一起卷进 chosen,等于在用户选
    /// "保存为其他主题"时**附赠把旧的 canonicalGuess 也合并掉** —— 用户原本只是拒绝
    /// 「老婆 ≡ 宝贝」这条具体建议、想给"老婆"找别的归宿,结果"宝贝"也被牵走,违反最小惊讶。
    ///
    /// 新语义:
    ///   - 主按钮 `保存为 canonicalGuess` (chosen == canonicalGuess)→ 只把 newTag 加进 canonicalGuess group
    ///   - "保存为其他主题" + 第三主题(chosen != canonicalGuess && != newTag)→ 只把 newTag 加进 chosen,canonicalGuess 完全独立
    ///   - chosen == newTag(picker UI 已排除,API 防御)→ noop,清掉本条 pending
    ///
    /// **关键**:chosen 在合并前要通过 alias index resolve 一次,否则点了"已是某 group 别名"
    /// 的标签会创建独立 group,index 冲突(codex P1 #1 regression)。
    func confirm(_ suggestion: PendingSuggestion, canonical canonicalChoice: String) {
        let raw = canonicalChoice.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }

        let newTag = suggestion.newTag.trimmingCharacters(in: .whitespaces)
        let newTagLower = newTag.lowercased()
        let chosenLower = raw.lowercased()

        let indexSnapshot = store.snapshotIndex()

        // Step 1: resolve chosen 到当前真正的 canonical
        let resolvedChosen: String = indexSnapshot[chosenLower] ?? raw
        let resolvedChosenLower = resolvedChosen.lowercased()

        // chosen 落到 newTag 自己 → 退化(用户在 picker 选成 newTag,已排除但 API 防御)。
        if newTagLower == resolvedChosenLower {
            objectWillChange.send()
            store.update { state in
                state.pending.removeAll { $0.id == suggestion.id }
            }
            sessionDismissCount = 0
            NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
            return
        }

        // Step 2: 准备要并入 chosen 的 label —— **只有 newTag**(canonicalGuess 不动)。
        // 区分两种情况:
        //   (a) newTag 自己就是某 group 的 canonical → 整组并入 chosen(parent 降级为 alias)
        //   (b) newTag 只是某 group 的 alias → **只**把 newTag 抽出来,parent group 保留剩余 aliases
        //       (codex P2 #7 fix:之前实现把 parent group 整组卷走,等于附赠一次合并)
        //   (c) newTag 是裸标签 → 直接加进 chosen 的 alias 列表
        var canonicalsToAbsorb: Set<String> = []
        var labelsToAdd: Set<String> = []
        // 边界 case (b):需要从 parent group 里把 newTag 单独移除
        var pluckFromParent: (parent: String, alias: String)? = nil

        if let parent = indexSnapshot[newTagLower] {
            if parent.lowercased() == resolvedChosenLower {
                // newTag 已经在 chosen group 里 —— 不动 group,只清 pending
            } else if parent.lowercased() == newTagLower {
                // (a) newTag 是 canonical 自己 → 整组 absorb
                canonicalsToAbsorb.insert(parent)
            } else {
                // (b) newTag 是 parent group 的 alias → 只移 newTag
                labelsToAdd.insert(newTag)
                pluckFromParent = (parent: parent, alias: newTag)
            }
        } else {
            // (c) 裸标签
            labelsToAdd.insert(newTag)
        }

        objectWillChange.send()
        store.update { state in
            // Step 3a: case (b) 把 newTag 从 parent group 拔出来(parent group 仍然活着)
            if let pluck = pluckFromParent, var parentAliases = state.groups[pluck.parent] {
                parentAliases.removeAll { $0.lowercased() == pluck.alias.lowercased() }
                if parentAliases.isEmpty {
                    // parent 没别的 alias 了 → 整组删掉(仅剩 canonical 自己,语义上等于"无 group")
                    state.groups.removeValue(forKey: pluck.parent)
                } else {
                    state.groups[pluck.parent] = parentAliases
                }
            }

            // Step 3b: case (a) 把 newTag 所属整 group 并入 chosen
            var finalAliases: Set<String> = labelsToAdd
            for absorbed in canonicalsToAbsorb {
                finalAliases.insert(absorbed)  // 旧 canonical 降级为 alias
                if let existing = state.groups[absorbed] {
                    finalAliases.formUnion(existing)
                }
                state.groups.removeValue(forKey: absorbed)
            }

            // Step 4: chosen 自己已有 group + 大小写 case 处理
            if let existing = state.groups[resolvedChosen] {
                finalAliases.formUnion(existing)
            }
            if let oldKey = state.groups.keys.first(where: {
                $0.lowercased() == resolvedChosenLower && $0 != resolvedChosen
            }) {
                if let existing = state.groups[oldKey] {
                    finalAliases.formUnion(existing)
                }
                state.groups.removeValue(forKey: oldKey)
            }

            // Step 5: 写回
            let aliases = finalAliases
                .filter { $0.lowercased() != resolvedChosenLower }
                .uniqued(byKey: { $0.lowercased() })
                .sorted()
            state.groups[resolvedChosen] = aliases

            // Step 6: 清当前 suggestion + 任何 newTag 已 resolve 到 chosen 的 stale pending。
            // **canonicalGuess 不动**,后续仍可能有针对 canonicalGuess 的合并建议,不在这里清。
            state.pending.removeAll { s in
                if s.id == suggestion.id { return true }
                return ThemeAliasStore.aliasToCanonicalLowerLookup(in: state.groups, key: s.newTag.lowercased()) == resolvedChosenLower
            }

            // Step 7: 清掉描述"newTag ↔ 现 chosen group 任意成员"的 stale negativePair —— 用户已经
            // 决定它们是同一实体,旧的"不是"记录就成了悖论(后续 unmerge / 别处合并时若不清,
            // negativePair 会反过来阻塞合理建议)。只清涉及 newTag 这一侧的;canonicalGuess 那边的
            // 拒绝意图(如果有)保留。
            let chosenGroupLowercased: Set<String> = Set(([resolvedChosen] + aliases).map { $0.lowercased() })
            for member in chosenGroupLowercased {
                state.negativePairs.remove(ThemeAliasStore.pairKey(newTagLower, member))
            }

            state.coolUntil = nil  // 用户主动 confirm = 重新 engage,7 天冷却也清掉(否则 banner 会继续被压抑)
        }

        sessionDismissCount = 0  // 任何"接受"操作都重置反弹计数
        scheduleCoolUntilExpiry()
        NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
    }

    /// 用户点"不是" —— 写 negativePair 永久跳过这一对。
    func reject(_ suggestion: PendingSuggestion) {
        let pairKey = ThemeAliasStore.pairKey(
            suggestion.newTag.lowercased(),
            suggestion.canonicalGuess.lowercased()
        )
        objectWillChange.send()
        store.update { state in
            state.negativePairs.insert(pairKey)
            state.pending.removeAll { $0.id == suggestion.id }
        }
        bumpDismissCount()
    }

    // (2026-05-15 megareview OPT-MID-1)`snooze(_:)` 已删 — grep 全仓 0 caller。
    // 设计是给"稍后"按钮用,UI 实际没采用此 affordance(用户在管理页直接 confirm/reject)。
    // 原实现保留在 git history。

    /// 一次清空所有 pending —— 给"扫描结果太多想全部丢掉"的用户。
    /// 不写 negativePairs(用户没说"这些都不是同一实体",只是不想现在处理)。
    /// 下次 scan 这些对子还会重新出现。
    func clearAllPending() {
        objectWillChange.send()
        store.update { state in
            state.pending.removeAll()
        }
    }

    /// 给"全部清空日记" / "数据库重建"等批量删除路径调。
    /// 清:groups / pending / coolUntil / sessionDismissCount / didAutoScanOnce。
    /// **保留 negativePairs** —— 用户的"它们不是同一个"主观判断与 entry 存在与否无关,
    /// 清了反而反人类(下次 scan 这些对子还会被重新建议)。
    /// post `themeAliasMapDidChange` 让监听者(InsightsView / banner / management 页)reload。
    func resetForBulkEntryWipe() {
        objectWillChange.send()
        store.update { state in
            state.groups.removeAll()
            state.pending.removeAll()
            state.coolUntil = nil
            state.didAutoScanOnce = false
        }
        sessionDismissCount = 0
        scheduleCoolUntilExpiry()
        Log.info("[ThemeAliasResolver] resetForBulkEntryWipe: groups+pending+coolUntil cleared (negativePairs preserved)", category: .persistence)
        NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
    }

    /// 合并结果:用 caller 端区分"真合了"vs"啥也没动",避免 toast 撒谎(codex P2 #15)。
    enum MergeOutcome: Equatable {
        case merged
        case noop  // 空输入 / source==target / 已在同一 group
    }

    /// 用户**绕过 AI suggestion 流程**,主动把 source 主题合并到 target 主题。
    /// 入口:Insights ThemeCard 长按 → "合并到其他主题"。
    @discardableResult
    func mergeThemes(source: String, into target: String) -> MergeOutcome {
        let sourceTrim = source.trimmingCharacters(in: .whitespaces)
        let targetTrim = target.trimmingCharacters(in: .whitespaces)
        guard !sourceTrim.isEmpty, !targetTrim.isEmpty else { return .noop }

        let sourceLower = sourceTrim.lowercased()
        let targetLower = targetTrim.lowercased()
        guard sourceLower != targetLower else { return .noop }

        let indexSnapshot = store.snapshotIndex()

        // 解析到真正的 canonical(target 可能本身就是别人的 alias)
        let resolvedTarget: String = indexSnapshot[targetLower] ?? targetTrim
        let resolvedTargetLower = resolvedTarget.lowercased()

        // source 解析:可能本身是 canonical,或某 group 的 alias
        let sourceCanonical: String? = indexSnapshot[sourceLower]
        if let sc = sourceCanonical, sc.lowercased() == resolvedTargetLower {
            return .noop  // source 已经在 target 的 group 里 —— 无 op
        }

        objectWillChange.send()
        store.update { state in
            // 收集所有要并入 target 的标签
            var labelsToMerge: Set<String> = [sourceTrim]
            if let sc = sourceCanonical {
                // source 是某 group 的成员(可能就是它自己作为 canonical 的特例)
                labelsToMerge.insert(sc)
                if let aliases = state.groups[sc] {
                    labelsToMerge.formUnion(aliases)
                }
                state.groups.removeValue(forKey: sc)
            }
            // target 自己若 case 不同,合并 case
            if let oldKey = state.groups.keys.first(where: {
                $0.lowercased() == resolvedTargetLower && $0 != resolvedTarget
            }) {
                if let aliases = state.groups[oldKey] {
                    labelsToMerge.formUnion(aliases)
                }
                state.groups.removeValue(forKey: oldKey)
            }

            // 合并到 target
            var finalAliases: Set<String> = []
            if let existing = state.groups[resolvedTarget] {
                finalAliases.formUnion(existing)
            }
            finalAliases.formUnion(labelsToMerge)

            let aliases = finalAliases
                .filter { $0.lowercased() != resolvedTargetLower }
                .uniqued(byKey: { $0.lowercased() })
                .sorted()
            state.groups[resolvedTarget] = aliases

            // 清理 stale pending:任何 newTag/canonicalGuess 命中合并后任意标签的 suggestion
            let mergedLowercased = Set(([resolvedTarget] + aliases).map { $0.lowercased() })
            state.pending.removeAll { s in
                mergedLowercased.contains(s.newTag.lowercased())
                    || mergedLowercased.contains(s.canonicalGuess.lowercased())
            }

            // 清理 stale negativePair:用户主动合并相当于覆盖了之前的"不是"。组内任意两标签
            // 的对子都应清掉,否则未来 unmerge / 改路径时旧拒绝复活,会反过来阻塞合理建议。
            let mergedArray = Array(mergedLowercased)
            for i in 0..<mergedArray.count {
                for j in (i + 1)..<mergedArray.count {
                    state.negativePairs.remove(ThemeAliasStore.pairKey(mergedArray[i], mergedArray[j]))
                }
            }

            // 用户主动长按合并 = 重新 engage,7 天冷却也清掉。
            state.coolUntil = nil
        }

        sessionDismissCount = 0
        scheduleCoolUntilExpiry()
        NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
        return .merged
    }

    /// 用户在 management page 主动拆分某个 group(把 alias 重新独立)。
    func unmerge(canonical: String, removeAlias alias: String) {
        guard store.groups[canonical] != nil else { return }
        objectWillChange.send()
        store.update { state in
            guard var aliases = state.groups[canonical] else { return }
            aliases.removeAll { $0.lowercased() == alias.lowercased() }
            if aliases.isEmpty {
                state.groups.removeValue(forKey: canonical)
            } else {
                state.groups[canonical] = aliases
            }
        }
        NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
    }

    /// 拆掉整组。同时清理 pending 队列里**任何 newTag/canonicalGuess 命中已删 group 标签的建议** ——
    /// 否则用户后续 confirm 那些 stale 建议会无声地把 group 重新建出来(codex P2 fix)。
    func deleteGroup(canonical: String) {
        // **顺序约定**(2026-05-16 superreview P2 #13 文档强化):
        // 1) 先**读** store.groups 算 `removedLabels`(只读,不 mutate);
        // 2) 再 `objectWillChange.send()`(通知 SwiftUI 即将变);
        // 3) 最后 `store.update {}` 在闭包内**写** state.groups + state.pending。
        // SwiftUI willChange 后下一 run loop 才拉值,所以读旧值 → send → 写新值的顺序正确。
        // 算 removedLabels **必须在 send 之前** —— 闭包内重算意义不大且让逻辑分散。

        // 大小写不敏感找真实 key
        let exactKey = store.groups.keys.first(where: { $0.lowercased() == canonical.lowercased() })
            ?? canonical
        // 收集这个 group 覆盖的所有 lowercased 标签(canonical + 它的 aliases)
        var removedLabels = Set<String>()
        removedLabels.insert(exactKey.lowercased())
        if let aliases = store.groups[exactKey] {
            for a in aliases { removedLabels.insert(a.lowercased()) }
        }

        objectWillChange.send()
        store.update { state in
            state.groups.removeValue(forKey: exactKey)
            // 清掉 pending 里指向已删除标签的建议
            state.pending.removeAll { s in
                removedLabels.contains(s.newTag.lowercased())
                    || removedLabels.contains(s.canonicalGuess.lowercased())
            }
        }
        NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
    }

    /// 公开版:供 ThemeManagementService.deleteTheme 在删除 entry.themes CSV 中的标签后,
    /// 同步清理任何提到这些标签的 pending 建议。labels 应是 lowercased。
    func purgePending(matchingLowercasedLabels labels: Set<String>) {
        guard !labels.isEmpty else { return }
        let before = store.pending.count
        // 先看看到底有没有匹配 — 没有就别 fire objectWillChange / save 浪费一次
        let willChange = store.pending.contains { s in
            labels.contains(s.newTag.lowercased()) || labels.contains(s.canonicalGuess.lowercased())
        }
        guard willChange else { return }
        objectWillChange.send()
        store.update { state in
            state.pending.removeAll { s in
                labels.contains(s.newTag.lowercased()) || labels.contains(s.canonicalGuess.lowercased())
            }
        }
        Log.info("[ThemeAliasResolver] purgePending: 清掉 \(before - store.pending.count) 条命中标签的 pending", category: .persistence)
    }

    /// 删除日记后调用 —— 扫所有 pending,把"newTag/canonicalGuess 都不在当前
    /// entry.themes inventory 里"的建议清掉(说明触发它的日记已被删,suggestion 是孤儿)。
    /// **保守策略**:只在两端都不在 inventory 时清,任一端仍存在则保留(可能在别的 entry 里)。
    ///
    /// **alias-aware**:活跃标签做一次 canonicalize,把 group canonical 也算"活"。
    /// 否则 groups[Abby]=[宝贝]、所有日记只写"宝贝"时,pending(亲爱的, Abby) 会被误删
    /// (Abby 不在 raw inventory,但作为 alias group 仍然活着)—— codex P1 #10 fix。
    func cleanupOrphanedPending() async {
        guard !store.pending.isEmpty else { return }
        // **race-safe snapshot**:在 await bg fetch 前抓一遍 pending IDs。
        // 期间(await 释放 MainActor)其他 MainActor 调用方可能 enqueue 新 pending(典型:
        // 用户刚写完一篇日记触发 judgeAfterWrite → resolver.enqueue)。如果 resume 后用 stale
        // active 集合无差别 removeAll,新 enqueue 的 suggestion 因 newTag 不在 stale active 里
        // 被误删。只针对 await 前就在的 pending 做 cleanup,新加的活下来。
        let beforeIDs = Set(store.pending.map(\.id))
        guard let rawActiveLabels = await Self.fetchActiveLowercasedLabels() else {
            Log.warning("[ThemeAliasResolver] cleanupOrphanedPending: active label fetch failed, keeping pending queue", category: .persistence)
            return
        }

        // 把每个 raw label 通过 alias map canonicalize 一次,union 进 active set。
        // 一个 alias 在日记里出现 → 它对应的 canonical 也算 active(group 仍然活着)。
        //
        // **invariant**:`indexSnapshot` 在 await 之**后**抓(此时拿到最新 alias map),
        // 从这行到下面 `store.update` 入口之间**无 await hop**,MainActor 上是连续的 —— 因此
        // `idsToRemove` 计算用的 active set 和实际 mutation 的 store.pending 一致。
        // **未来如在 dry-run 中间引入新的 await,本块需要重新审 freshness**(2026-05-16 superreview P2 #11)。
        let indexSnapshot = store.snapshotIndex()
        var active = rawActiveLabels
        for raw in rawActiveLabels {
            if let canonical = indexSnapshot[raw] {
                active.insert(canonical.lowercased())
            }
        }

        // 先 dry-run 找出要清的;无需清 → 早返,免无谓 objectWillChange.send + 重写盘。
        // 原 Resolver 也走"读 before / 算 after / before != after 才 save + post"的双比对。
        let idsToRemove: Set<UUID> = Set(store.pending.compactMap { s -> UUID? in
            guard beforeIDs.contains(s.id) else { return nil }
            guard !active.contains(s.newTag.lowercased()) else { return nil }
            guard !active.contains(s.canonicalGuess.lowercased()) else { return nil }
            return s.id
        })
        guard !idsToRemove.isEmpty else { return }

        objectWillChange.send()
        store.update { state in
            state.pending.removeAll { idsToRemove.contains($0.id) }
        }
        Log.info("[ThemeAliasResolver] cleanupOrphanedPending: 清掉 \(idsToRemove.count) 条孤儿建议", category: .persistence)
        // post 通知让 InsightsView 红点 / management view 即时刷新。@Published pending 的
        // 变化也驱动 banner,但 NotificationCenter 监听者(InsightsView line 118)只听这个
        // 通知,不挂 ObservableObject —— 缺通知会让 Insights 标记 stale 直到下次 view appear。
        NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
    }

    /// 后台扫所有 entry.themes,返回 lowercased distinct set。给 cleanupOrphanedPending 用。
    /// 用 dictionaryResultType + propertiesToFetch=["themes"] 避免实体化 NSManagedObject —
    /// heavy user(1000+ 篇)上每次 entry 删除后跑都要走一次,实体化全量 entry 会卡顿。
    private static func fetchActiveLowercasedLabels() async -> Set<String>? {
        await PersistenceController.shared.container.performBackgroundTask { context in
            let request = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["themes"]
            request.predicate = NSPredicate(format: "themes != nil AND themes != %@", "")
            let rows: [NSDictionary]
            do {
                rows = try context.fetch(request)
            } catch {
                Log.warning("[ThemeAliasResolver] fetchActiveLowercasedLabels failed: \(error)", category: .persistence)
                return nil
            }
            var labels = Set<String>()
            for row in rows {
                guard let csv = row["themes"] as? String, !csv.isEmpty else { continue }
                // 复刻 DiaryEntry.themeArray 的 split 逻辑(CSV 用 `,` 分隔,trim,丢空)。
                for piece in csv.split(separator: ",") {
                    let tag = piece.trimmingCharacters(in: .whitespaces)
                    if !tag.isEmpty { labels.insert(tag.lowercased()) }
                }
            }
            return labels
        }
    }

    // MARK: - Bookkeeping (cool-down + dismiss counter)

    private func bumpDismissCount() {
        sessionDismissCount += 1
        if sessionDismissCount >= snoozeThreshold {
            objectWillChange.send()
            store.update { state in
                state.coolUntil = Date().addingTimeInterval(coolDuration)
            }
            sessionDismissCount = 0
            scheduleCoolUntilExpiry()
        }
    }

    /// coolUntil 变化时调:取消旧 timer,若 coolUntil 在未来则起 one-shot timer 在到期点
    /// 触发 SwiftUI re-render(通过 `objectWillChange.send()` + `themeAliasMapDidChange`)。
    /// 自然过期不需要修改 `coolUntil` 值(redDotVisible 逻辑已经判 `Date() < coolUntil`),
    /// 只要让观察者重读一次。
    ///
    /// **拆分后变化**:原本走 `coolUntil didSet`,Store 拆出后 Store 不知道 UI signal,
    /// 所有 mutation 完后由 Resolver 显式调一次。
    private func scheduleCoolUntilExpiry() {
        coolUntilExpiryTimer?.invalidate()
        coolUntilExpiryTimer = nil
        guard let coolUntil = store.coolUntil else { return }
        let interval = coolUntil.timeIntervalSinceNow
        guard interval > 0 else { return }  // 已过期,不必 schedule
        // tolerance 给 OS 节能优化空间;到期点偏 30s 完全可接受。
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // SwiftUI ObservableObject 重 re-render
                self.objectWillChange.send()
                // InsightsView 等通过 NotificationCenter 监听,一并通知
                NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
                self.coolUntilExpiryTimer = nil
            }
        }
        timer.tolerance = 30  // 30s tolerance,允许 OS coalesce
        RunLoop.main.add(timer, forMode: .common)
        coolUntilExpiryTimer = timer
    }

    /// **仅测试用**:外部直接设置 coolUntil,绕过累积 dismiss 触发逻辑。
    /// 生产路径应当走 reject/snooze,不应直接调这个。
    #if DEBUG
    func setCoolUntilForTesting(_ date: Date?) {
        objectWillChange.send()
        store.update { state in
            state.coolUntil = date
        }
        scheduleCoolUntilExpiry()
    }
    #endif

    /// 用户在管理页主动清空"曾点过不是"的对子,让下次 scan 重新考虑它们。
    func resetNegativePairs() {
        objectWillChange.send()
        store.update { state in
            state.negativePairs.removeAll()
        }
    }

    /// view-side 触发首次自动 scan 后调,持久化到 disk,后续 view 重建仍能看到。
    func markAutoScanned() {
        guard !store.didAutoScanOnce else { return }
        objectWillChange.send()
        store.update { state in
            state.didAutoScanOnce = true
        }
    }
}

// MARK: - PendingSuggestion

struct PendingSuggestion: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// 新出现的、待与 canonicalGuess 合并的 tag(本次 entry 写入时新抽出)。
    let newTag: String
    /// AI 判断的 canonical 候选(通常是已有的高频 tag)。
    let canonicalGuess: String
    /// 高 / 中:UI 用置信度决定要不要弹 banner(只有 high 弹,medium 仅红点)
    let confidence: Confidence
    /// 几条样例 entry 的 ID(让用户在卡片上看到引文)。最多 3 条。
    let sampleEntryIds: [UUID]
    let createdAt: Date
    /// 来源:on-write 是某条 entry 触发;scan 是一次性扫描触发。
    let source: Source

    enum Confidence: String, Codable, Sendable { case high, medium }

    enum Source: Codable, Equatable, Sendable {
        case onWrite(entryID: UUID)
        case scan
    }

    init(
        id: UUID = UUID(),
        newTag: String,
        canonicalGuess: String,
        confidence: Confidence,
        sampleEntryIds: [UUID] = [],
        createdAt: Date = Date(),
        source: Source
    ) {
        self.id = id
        self.newTag = newTag
        self.canonicalGuess = canonicalGuess
        self.confidence = confidence
        self.sampleEntryIds = sampleEntryIds
        self.createdAt = createdAt
        self.source = source
    }
}

// MARK: - Notification

extension Notification.Name {
    /// alias map 发生改变(confirm / unmerge / deleteGroup)时广播,Insights / Home 可以
    /// 借此触发重聚合(见 InsightsView 的 onReceive)。
    static let themeAliasMapDidChange = Notification.Name("Lumory.themeAliasMapDidChange")
}

// MARK: - Array uniquing helper

private extension Array {
    func uniqued<Key: Hashable>(byKey key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}
