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
// 持久化用 UserDefaults(plist)。数据量小(<200 条 alias 是上限),不引入 CoreData migration
// 风险,以后想多设备同步再迁 NSUbiquitousKeyValueStore 一行接口替换。

@MainActor
final class ThemeAliasResolver: ObservableObject {
    static let shared = ThemeAliasResolver()

    // MARK: - Persisted shape

    /// canonical → 别名集合(不含 canonical 自身)。canonical 大小写保留用户首次选择时的形态。
    /// 反向 index `aliasToCanonical`(lowercased key)由 `rebuildIndex()` 维护。
    @Published private(set) var groups: [String: [String]] = [:]

    /// 用户明确说"这两个不是同一实体"的对子。排序后拼成 "a||b" 存。
    /// 在 enqueue / scan / on-write judge 都会跳过命中此 set 的对子,避免反复打扰。
    @Published private(set) var negativePairs: Set<String> = []

    /// 待审清单。on-write judge 和一次性 scan 都往这写,UI(banner / management page)消费。
    @Published private(set) var pending: [PendingSuggestion] = []

    /// 节流状态:连续点 "稍后/不是" ≥ snoozeThreshold 进入冷却期 coolDuration。
    /// 冷却期内 banner 不弹,Settings 红点也不显示。
    @Published private(set) var coolUntil: Date? = nil {
        didSet {
            // **C4 fix**:`redDotVisible` 计算读 `Date()` 跟 coolUntil 比,SwiftUI 默认只在
            // `coolUntil` 这个 @Published 值**变化**时 re-render,不会因为时间自然流逝重算。
            // 即:coolUntil = T+7d 设上后,T+7d 那一刻到了 redDotVisible 应当 true,但没有任何
            // mutation 触发 view 重算 → 红点该亮但不亮,直到下次 enqueue/confirm 等才补上。
            // 修法:每次 coolUntil 改变,起一个 one-shot Timer 在到期时间点 fire,fire 时 post
            // 通知触发 InsightsView/banner reload 兼 ObservableObject objectWillChange。
            scheduleCoolUntilExpiry()
        }
    }
    private var coolUntilExpiryTimer: Timer?

    /// 一次性自动 scan 标记:首次进入管理页 + alias map 空 + pending 空 时,自动后台 scan 一次。
    /// 持久化到 UserDefaults,view-local @State 重新创建 view 时不重置(codex P2 fix)。
    @Published private(set) var didAutoScanOnce: Bool = false

    private var sessionDismissCount: Int = 0
    private let snoozeThreshold = 3
    private let coolDuration: TimeInterval = 7 * 24 * 60 * 60  // 7 天

    // MARK: - In-memory reverse index

    /// `aliasLowercased → canonical` —— `canonicalize(_:)` 的 O(1) 查找。
    /// canonical 自身也存进来(canonical 命中 canonical),让查找无 special case。
    private var aliasToCanonical: [String: String] = [:]

    // MARK: - Storage

    private static let storageKey = "lumory.themeAliasStore.v1"
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        // didSet 在 init 阶段不触发,需要手动 schedule 一次盘里 coolUntil 的过期通知
        scheduleCoolUntilExpiry()
    }

    // 测试用 init,不读 UserDefaults
    init(testingWithEmptyState defaults: UserDefaults) {
        self.defaults = defaults
        self.groups = [:]
        self.negativePairs = []
        self.pending = []
        self.coolUntil = nil
        rebuildIndex()
    }

    // 测试用 init,从指定 UserDefaults 读已有 DiskState,验证持久化往返。
    init(testingWithStoredState defaults: UserDefaults) {
        self.defaults = defaults
        load()
        scheduleCoolUntilExpiry()
    }

    // MARK: - Public: canonicalize

    /// 在聚合 / 展示层使用。命中别名 → 返回 canonical;否则返回原文。
    /// **大小写不敏感 + NFC 归一化**(reverse index 也用 NFC + lowercased key)。
    /// 返回的 canonical 保留入库时的原文形态(已 NFC 化 — `OpenAIService` 上送前都做过
    /// `precomposedStringWithCanonicalMapping`,Resolver 这边查找时也 NFC 一遍以防
    /// 用户老 entry 的 NFD 形式 "café" 跟 AI 返回的 NFC "café" 落到不同 bucket)。
    func canonicalize(_ raw: String) -> String {
        // 用统一的 ThemeKey.make 做 NFC + lowercased + trim;reverse index 也用同 idiom
        // (见 rebuildIndex)。返回的 canonical 优先保留入库原文(已 NFC 化),命中 index 时返回 group 主名,
        // 否则返回 trimmed NFC 后的原文(保留大小写,只去掉边缘空格 / NFC 化)。
        let trimmedNFC = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !trimmedNFC.isEmpty else { return raw }
        return aliasToCanonical[ThemeKey.make(raw)] ?? trimmedNFC
    }

    /// 批量 canonicalize + 去重(保留首次 canonical 的原文大小写)。
    /// ContextPromptGenerator / aggregateThemes 用得到。
    func canonicalize(all rawTags: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in rawTags {
            let canon = canonicalize(raw)
            let key = canon.lowercased()
            if seen.insert(key).inserted {
                out.append(canon)
            }
        }
        return out
    }

    // MARK: - Public: pending lifecycle

    var pendingCount: Int { pending.count }

    /// Settings gear 红点 + Home banner 触发条件。冷却期内一律 false。
    var redDotVisible: Bool {
        guard pendingCount > 0 else { return false }
        if let coolUntil, Date() < coolUntil { return false }
        return true
    }

    /// 入队一条建议。会自动跳过:
    ///   - 与已有 group 矛盾(newTag 已是另一个 canonical 的 alias)
    ///   - 命中 negativePairs
    ///   - pending 里已有同**对子**(unordered:无论 AI 在两次 scan 中怎么 swap newTag/canonicalGuess,只算一条)
    /// 返回 true 表示新增成功,false 表示被跳过。
    @discardableResult
    func enqueue(_ suggestion: PendingSuggestion) -> Bool {
        let newKey = suggestion.newTag.lowercased()
        let originalCanonKey = suggestion.canonicalGuess.lowercased()

        // newTag == canonical 没意义
        if newKey == originalCanonKey { return false }

        // newTag 已经是某 canonical 的别名 → 跳过(已合并)
        if let existingCanon = aliasToCanonical[newKey],
           existingCanon.lowercased() != newKey {
            return false
        }

        // canonicalGuess 已经是某 canonical 的别名 → **归一化**到该 canonical 而不是丢弃。
        // 之前的实现直接 `return false`,导致用户合理建议"老婆 ↔ 宝贝(已是 Abby alias)"
        // 被静默丢 —— 用户期望"通过现有 alias 加新别名(老婆 → Abby group)"被无声忽略
        // (codex P1 #16 fix)。
        let resolvedCanonical: String
        if let existingCanon = aliasToCanonical[originalCanonKey],
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
        let resolvedPairKey = Self.pairKey(newKey, canonKey)
        if negativePairs.contains(resolvedPairKey) { return false }
        if originalCanonKey != canonKey {
            let originalPairKey = Self.pairKey(newKey, originalCanonKey)
            if negativePairs.contains(originalPairKey) { return false }
        }

        // pending dedup 用 **unordered pair key**,与 negativePairs 对齐:
        // AI 在两次 scan 间可能 swap newTag/canonicalGuess —— 之前的 direction-aware 比较会让
        // 同一对子重复入队,用户被迫审核两次(codex P2 fix)。
        if pending.contains(where: {
            Self.pairKey($0.newTag.lowercased(), $0.canonicalGuess.lowercased()) == resolvedPairKey
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

        // L: hard cap pending size。文件顶部注释自称 "<200",这里强制。
        // 超过则丢最旧一条(FIFO 策略 —— 用户半年没处理的老 suggestion 优先级低于刚识别的新对子)。
        // 实际场景下用户主动 confirm/reject 后 pending 会被清掉,200 是工程上限不是日常预期值。
        let maxPending = 200
        pending.append(normalized)
        if pending.count > maxPending {
            pending.removeFirst(pending.count - maxPending)
            Log.info("[ThemeAliasResolver] pending 超过 \(maxPending),丢最旧若干条", category: .persistence)
        }
        save()
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

        // Step 1: resolve chosen 到当前真正的 canonical
        let resolvedChosen: String = aliasToCanonical[chosenLower] ?? raw
        let resolvedChosenLower = resolvedChosen.lowercased()

        // chosen 落到 newTag 自己 → 退化(用户在 picker 选成 newTag,已排除但 API 防御)。
        if newTagLower == resolvedChosenLower {
            pending.removeAll { $0.id == suggestion.id }
            sessionDismissCount = 0
            save()
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

        if let parent = aliasToCanonical[newTagLower] {
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

        // Step 3a: case (b) 把 newTag 从 parent group 拔出来(parent group 仍然活着)
        if let pluck = pluckFromParent, var parentAliases = groups[pluck.parent] {
            parentAliases.removeAll { $0.lowercased() == pluck.alias.lowercased() }
            if parentAliases.isEmpty {
                // parent 没别的 alias 了 → 整组删掉(仅剩 canonical 自己,语义上等于"无 group")
                groups.removeValue(forKey: pluck.parent)
            } else {
                groups[pluck.parent] = parentAliases
            }
        }

        // Step 3b: case (a) 把 newTag 所属整 group 并入 chosen
        var finalAliases: Set<String> = labelsToAdd
        for absorbed in canonicalsToAbsorb {
            finalAliases.insert(absorbed)  // 旧 canonical 降级为 alias
            if let existing = groups[absorbed] {
                finalAliases.formUnion(existing)
            }
            groups.removeValue(forKey: absorbed)
        }

        // Step 4: chosen 自己已有 group + 大小写 case 处理
        if let existing = groups[resolvedChosen] {
            finalAliases.formUnion(existing)
        }
        if let oldKey = groups.keys.first(where: {
            $0.lowercased() == resolvedChosenLower && $0 != resolvedChosen
        }) {
            if let existing = groups[oldKey] {
                finalAliases.formUnion(existing)
            }
            groups.removeValue(forKey: oldKey)
        }

        // Step 5: 写回
        let aliases = finalAliases
            .filter { $0.lowercased() != resolvedChosenLower }
            .uniqued(byKey: { $0.lowercased() })
            .sorted()
        groups[resolvedChosen] = aliases

        // Step 6: 清当前 suggestion + 任何 newTag 已 resolve 到 chosen 的 stale pending。
        // **canonicalGuess 不动**,后续仍可能有针对 canonicalGuess 的合并建议,不在这里清。
        pending.removeAll { s in
            if s.id == suggestion.id { return true }
            return aliasToCanonicalLowerLookup(in: groups, key: s.newTag.lowercased()) == resolvedChosenLower
        }

        // Step 7: 清掉描述"newTag ↔ 现 chosen group 任意成员"的 stale negativePair —— 用户已经
        // 决定它们是同一实体,旧的"不是"记录就成了悖论(后续 unmerge / 别处合并时若不清,
        // negativePair 会反过来阻塞合理建议)。只清涉及 newTag 这一侧的;canonicalGuess 那边的
        // 拒绝意图(如果有)保留。
        let chosenGroupLowercased: Set<String> = Set(([resolvedChosen] + aliases).map { $0.lowercased() })
        for member in chosenGroupLowercased {
            negativePairs.remove(Self.pairKey(newTagLower, member))
        }

        sessionDismissCount = 0  // 任何"接受"操作都重置反弹计数
        coolUntil = nil  // 用户主动 confirm = 重新 engage,7 天冷却也清掉(否则 banner 会继续被压抑)
        rebuildIndex()
        save()

        NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
    }

    /// 用户点"不是" —— 写 negativePair 永久跳过这一对。
    func reject(_ suggestion: PendingSuggestion) {
        let pairKey = Self.pairKey(
            suggestion.newTag.lowercased(),
            suggestion.canonicalGuess.lowercased()
        )
        negativePairs.insert(pairKey)
        pending.removeAll { $0.id == suggestion.id }
        bumpDismissCount()
        save()
    }

    // (2026-05-15 megareview OPT-MID-1)`snooze(_:)` 已删 — grep 全仓 0 caller。
    // 设计是给"稍后"按钮用,UI 实际没采用此 affordance(用户在管理页直接 confirm/reject)。
    // 原实现保留在 git history。

    /// 一次清空所有 pending —— 给"扫描结果太多想全部丢掉"的用户。
    /// 不写 negativePairs(用户没说"这些都不是同一实体",只是不想现在处理)。
    /// 下次 scan 这些对子还会重新出现。
    func clearAllPending() {
        pending.removeAll()
        save()
    }

    /// 给"全部清空日记" / "数据库重建"等批量删除路径调。
    /// 清:groups / pending / coolUntil / sessionDismissCount / didAutoScanOnce。
    /// **保留 negativePairs** —— 用户的"它们不是同一个"主观判断与 entry 存在与否无关,
    /// 清了反而反人类(下次 scan 这些对子还会被重新建议)。
    /// post `themeAliasMapDidChange` 让监听者(InsightsView / banner / management 页)reload。
    func resetForBulkEntryWipe() {
        groups.removeAll()
        pending.removeAll()
        coolUntil = nil
        sessionDismissCount = 0
        didAutoScanOnce = false
        rebuildIndex()
        save()
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
    ///
    /// 行为:
    ///   - source / target 都通过 aliasToCanonical 解析到当前真正的 canonical
    ///   - 若 source 是某 group 的 canonical,把整个 group(canonical + 所有 aliases)合并进 target
    ///   - 若 source 不在任何 group(只是裸标签),作为 alias 加到 target 下
    ///   - target 解析后若与 source resolved 相同 → noop(已经在同一组)
    ///   - 合并后清掉 pending 里引用任何被并入标签的 stale 建议
    @discardableResult
    func mergeThemes(source: String, into target: String) -> MergeOutcome {
        let sourceTrim = source.trimmingCharacters(in: .whitespaces)
        let targetTrim = target.trimmingCharacters(in: .whitespaces)
        guard !sourceTrim.isEmpty, !targetTrim.isEmpty else { return .noop }

        let sourceLower = sourceTrim.lowercased()
        let targetLower = targetTrim.lowercased()
        guard sourceLower != targetLower else { return .noop }

        // 解析到真正的 canonical(target 可能本身就是别人的 alias)
        let resolvedTarget: String = aliasToCanonical[targetLower] ?? targetTrim
        let resolvedTargetLower = resolvedTarget.lowercased()

        // source 解析:可能本身是 canonical,或某 group 的 alias
        let sourceCanonical: String? = aliasToCanonical[sourceLower]
        if let sc = sourceCanonical, sc.lowercased() == resolvedTargetLower {
            return .noop  // source 已经在 target 的 group 里 —— 无 op
        }

        // 收集所有要并入 target 的标签
        var labelsToMerge: Set<String> = [sourceTrim]
        if let sc = sourceCanonical {
            // source 是某 group 的成员(可能就是它自己作为 canonical 的特例)
            labelsToMerge.insert(sc)
            if let aliases = groups[sc] {
                labelsToMerge.formUnion(aliases)
            }
            groups.removeValue(forKey: sc)
        }
        // target 自己若 case 不同,合并 case
        if let oldKey = groups.keys.first(where: {
            $0.lowercased() == resolvedTargetLower && $0 != resolvedTarget
        }) {
            if let aliases = groups[oldKey] {
                labelsToMerge.formUnion(aliases)
            }
            groups.removeValue(forKey: oldKey)
        }

        // 合并到 target
        var finalAliases: Set<String> = []
        if let existing = groups[resolvedTarget] {
            finalAliases.formUnion(existing)
        }
        finalAliases.formUnion(labelsToMerge)

        let aliases = finalAliases
            .filter { $0.lowercased() != resolvedTargetLower }
            .uniqued(byKey: { $0.lowercased() })
            .sorted()
        groups[resolvedTarget] = aliases

        // 清理 stale pending:任何 newTag/canonicalGuess 命中合并后任意标签的 suggestion
        let mergedLowercased = Set(([resolvedTarget] + aliases).map { $0.lowercased() })
        pending.removeAll { s in
            mergedLowercased.contains(s.newTag.lowercased())
                || mergedLowercased.contains(s.canonicalGuess.lowercased())
        }

        // 清理 stale negativePair:用户主动合并相当于覆盖了之前的"不是"。组内任意两标签
        // 的对子都应清掉,否则未来 unmerge / 改路径时旧拒绝复活,会反过来阻塞合理建议。
        let mergedArray = Array(mergedLowercased)
        for i in 0..<mergedArray.count {
            for j in (i + 1)..<mergedArray.count {
                negativePairs.remove(Self.pairKey(mergedArray[i], mergedArray[j]))
            }
        }

        // 用户主动长按合并 = 重新 engage,7 天冷却也清掉。
        sessionDismissCount = 0
        coolUntil = nil

        rebuildIndex()
        save()
        NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
        return .merged
    }

    /// 给 UI 用:预览 `mergeThemes(source:into:)` 会把哪些 alias / canonical
    /// **一并**搬移到 target 组。返回除 source 自己外会跟着搬过去的标签(原拼写)。
    /// 空数组表示无附带搬移(source 是散标签 / 已在 target 组里 / 同名),UI 直接合并即可。
    /// 非空 → UI 应弹提示让用户知情:long-press 合并语义是吸收整组,不只搬一个名字。
    func collateralLabels(forMerging source: String, into target: String) -> [String] {
        let sourceTrim = source.trimmingCharacters(in: .whitespaces)
        let targetTrim = target.trimmingCharacters(in: .whitespaces)
        guard !sourceTrim.isEmpty, !targetTrim.isEmpty else { return [] }

        let sourceLower = sourceTrim.lowercased()
        let targetLower = targetTrim.lowercased()
        guard sourceLower != targetLower else { return [] }

        let resolvedTargetLower = (aliasToCanonical[targetLower] ?? targetTrim).lowercased()

        guard let sourceCanonical = aliasToCanonical[sourceLower] else { return [] }
        if sourceCanonical.lowercased() == resolvedTargetLower { return [] }

        var collateral: [String] = []
        if sourceCanonical.lowercased() != sourceLower {
            collateral.append(sourceCanonical)
        }
        if let aliases = groups[sourceCanonical] {
            for a in aliases where a.lowercased() != sourceLower {
                collateral.append(a)
            }
        }
        return collateral
    }

    /// 用户在 management page 主动拆分某个 group(把 alias 重新独立)。
    func unmerge(canonical: String, removeAlias alias: String) {
        guard var aliases = groups[canonical] else { return }
        aliases.removeAll { $0.lowercased() == alias.lowercased() }
        if aliases.isEmpty {
            groups.removeValue(forKey: canonical)
        } else {
            groups[canonical] = aliases
        }
        rebuildIndex()
        save()
        NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
    }

    /// 拆掉整组。同时清理 pending 队列里**任何 newTag/canonicalGuess 命中已删 group 标签的建议** ——
    /// 否则用户后续 confirm 那些 stale 建议会无声地把 group 重新建出来(codex P2 fix)。
    func deleteGroup(canonical: String) {
        // 先收集这个 group 覆盖的所有 lowercased 标签(canonical + 它的 aliases)
        var removedLabels = Set<String>()
        // 大小写不敏感找真实 key
        let exactKey = groups.keys.first(where: { $0.lowercased() == canonical.lowercased() })
            ?? canonical
        removedLabels.insert(exactKey.lowercased())
        if let aliases = groups[exactKey] {
            for a in aliases { removedLabels.insert(a.lowercased()) }
        }

        groups.removeValue(forKey: exactKey)

        // 清掉 pending 里指向已删除标签的建议
        purgePending(matchingLowercasedLabels: removedLabels)

        rebuildIndex()
        save()
        NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
    }

    /// 公开版:供 ThemeManagementService.deleteTheme 在删除 entry.themes CSV 中的标签后,
    /// 同步清理任何提到这些标签的 pending 建议。labels 应是 lowercased。
    func purgePending(matchingLowercasedLabels labels: Set<String>) {
        guard !labels.isEmpty else { return }
        let before = pending.count
        pending.removeAll { s in
            labels.contains(s.newTag.lowercased()) || labels.contains(s.canonicalGuess.lowercased())
        }
        if pending.count != before {
            save()
        }
    }

    /// 删除日记后调用 —— 扫所有 pending,把"newTag/canonicalGuess 都不在当前
    /// entry.themes inventory 里"的建议清掉(说明触发它的日记已被删,suggestion 是孤儿)。
    /// **保守策略**:只在两端都不在 inventory 时清,任一端仍存在则保留(可能在别的 entry 里)。
    ///
    /// **alias-aware**:活跃标签做一次 canonicalize,把 group canonical 也算"活"。
    /// 否则 groups[Abby]=[宝贝]、所有日记只写"宝贝"时,pending(亲爱的, Abby) 会被误删
    /// (Abby 不在 raw inventory,但作为 alias group 仍然活着)—— codex P1 #10 fix。
    func cleanupOrphanedPending() async {
        guard !pending.isEmpty else { return }
        // **race-safe snapshot**:在 await bg fetch 前抓一遍 pending IDs。
        // 期间(await 释放 MainActor)其他 MainActor 调用方可能 enqueue 新 pending(典型:
        // 用户刚写完一篇日记触发 judgeAfterWrite → resolver.enqueue)。如果 resume 后用 stale
        // active 集合无差别 removeAll,新 enqueue 的 suggestion 因 newTag 不在 stale active 里
        // 被误删。只针对 await 前就在的 pending 做 cleanup,新加的活下来。
        let beforeIDs = Set(pending.map(\.id))
        guard let rawActiveLabels = await fetchActiveLowercasedLabels() else {
            Log.warning("[ThemeAliasResolver] cleanupOrphanedPending: active label fetch failed, keeping pending queue", category: .persistence)
            return
        }

        // 把每个 raw label 通过 alias map canonicalize 一次,union 进 active set。
        // 一个 alias 在日记里出现 → 它对应的 canonical 也算 active(group 仍然活着)。
        var active = rawActiveLabels
        for raw in rawActiveLabels {
            if let canonical = aliasToCanonical[raw] {
                active.insert(canonical.lowercased())
            }
        }

        let before = pending.count
        pending.removeAll { s in
            beforeIDs.contains(s.id)  // 只动 await 前就在的;新加的一律保留
                && !active.contains(s.newTag.lowercased())
                && !active.contains(s.canonicalGuess.lowercased())
        }
        if pending.count != before {
            Log.info("[ThemeAliasResolver] cleanupOrphanedPending: 清掉 \(before - pending.count) 条孤儿建议", category: .persistence)
            save()
            // post 通知让 InsightsView 红点 / management view 即时刷新。@Published pending 的
            // 变化也驱动 banner,但 NotificationCenter 监听者(InsightsView line 118)只听这个
            // 通知,不挂 ObservableObject —— 缺通知会让 Insights 标记 stale 直到下次 view appear。
            NotificationCenter.default.post(name: .themeAliasMapDidChange, object: nil)
        }
    }

    /// 后台扫所有 entry.themes,返回 lowercased distinct set。给 cleanupOrphanedPending 用。
    /// 用 dictionaryResultType + propertiesToFetch=["themes"] 避免实体化 NSManagedObject —
    /// heavy user(1000+ 篇)上每次 entry 删除后跑都要走一次,实体化全量 entry 会卡顿。
    private func fetchActiveLowercasedLabels() async -> Set<String>? {
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

    // MARK: - Bookkeeping

    private func bumpDismissCount() {
        sessionDismissCount += 1
        if sessionDismissCount >= snoozeThreshold {
            coolUntil = Date().addingTimeInterval(coolDuration)
            sessionDismissCount = 0
        }
    }

    /// coolUntil 变化时调:取消旧 timer,若 coolUntil 在未来则起 one-shot timer 在到期点
    /// 触发 SwiftUI re-render(通过 `objectWillChange.send()` + `themeAliasMapDidChange`)。
    /// 自然过期不需要修改 `coolUntil` 值(redDotVisible 逻辑已经判 `Date() < coolUntil`),
    /// 只要让观察者重读一次。
    private func scheduleCoolUntilExpiry() {
        coolUntilExpiryTimer?.invalidate()
        coolUntilExpiryTimer = nil
        guard let coolUntil else { return }
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
        coolUntil = date
    }
    #endif

    /// 用户在管理页主动清空"曾点过不是"的对子,让下次 scan 重新考虑它们。
    func resetNegativePairs() {
        negativePairs.removeAll()
        save()
    }

    // MARK: - Persistence

    private struct DiskState: Codable {
        var groups: [String: [String]]
        var negativePairs: [String]
        var pending: [PendingSuggestion]
        var coolUntil: Date?
        var didAutoScanOnce: Bool?  // optional 兼容旧 disk state
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            rebuildIndex()
            return
        }
        do {
            let state = try JSONDecoder().decode(DiskState.self, from: data)
            self.groups = state.groups
            self.negativePairs = Set(state.negativePairs)
            self.pending = state.pending
            self.coolUntil = state.coolUntil
            self.didAutoScanOnce = state.didAutoScanOnce ?? false
        } catch {
            // 解码失败 → 把损坏的 blob 备份到 `<key>.corrupted-<unix-ts>` 后再走空状态。
            // 否则下一次 save() 直接覆盖,用户的 alias map 没机会恢复(iCloud 跨版本回滚 / 短暂
            // schema mismatch / disk 半截写入 都会撞这里)。备份 key 不参与 load,只是留个尸体
            // 给以后人肉恢复或 DatabaseRecovery 流程做证据。
            //
            // **rotate**:只保留最近 2 个 corrupt 备份。如果反复触发 decode failure(理论上不会,
            // 但万一坏 schema 一直在),不轮转的话每启动一次堆积一个,UserDefaults 越来越胖。
            let backupKeyPrefix = "\(Self.storageKey).corrupted-"
            let now = Int(Date().timeIntervalSince1970)
            defaults.set(data, forKey: "\(backupKeyPrefix)\(now)")
            // 找出所有现存的备份 key,按时间戳降序保留最新 2 个,删掉更旧的。
            let allKeys = defaults.dictionaryRepresentation().keys
            let backupKeys = allKeys.filter { $0.hasPrefix(backupKeyPrefix) }
                .sorted(by: >)  // 字典序倒序,因为时间戳是定长十进制 → 字典序 = 时间序
            for old in backupKeys.dropFirst(2) {
                defaults.removeObject(forKey: old)
            }
            Log.error("[ThemeAliasResolver] decode failed, blob backed up to \(backupKeyPrefix)\(now): \(error)", category: .persistence)
        }
        rebuildIndex()
    }

    private func save() {
        let state = DiskState(
            groups: groups,
            negativePairs: Array(negativePairs).sorted(),
            pending: pending,
            coolUntil: coolUntil,
            didAutoScanOnce: didAutoScanOnce
        )
        do {
            let data = try JSONEncoder().encode(state)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            Log.error("[ThemeAliasResolver] encode failed: \(error)", category: .persistence)
        }
    }

    /// view-side 触发首次自动 scan 后调,持久化到 disk,后续 view 重建仍能看到。
    func markAutoScanned() {
        guard !didAutoScanOnce else { return }
        didAutoScanOnce = true
        save()
    }

    // MARK: - Index helpers

    private func rebuildIndex() {
        var index: [String: String] = [:]
        for (canonical, aliases) in groups {
            // 用 ThemeKey.make 跟 canonicalize(_:) 入参的归一化对齐,否则 NFD entry / NFC AI return
            // 落到不同 bucket。
            index[ThemeKey.make(canonical)] = canonical
            for alias in aliases {
                index[ThemeKey.make(alias)] = canonical
            }
        }
        self.aliasToCanonical = index
    }

    private static func pairKey(_ a: String, _ b: String) -> String {
        a < b ? "\(a)||\(b)" : "\(b)||\(a)"
    }

    /// 在临时 groups dict 上做反向查找,用 lowercased key。供 confirm() 内联用。
    ///
    /// **关键语义**:只在 key 是某 canonical 的 **alias** 时返回那个 canonical。
    /// 当 key 本身就是某 canonical 时返回 nil ——
    ///   早期版本写成 `if canonical.lowercased() == key { return key }`,
    ///   导致 confirm() Step 6 误删一类独立 pending:
    ///   user confirm `{newTag:"A", canonicalGuess:"B"}` → groups["B"] 多 alias "A" 后,
    ///   另一条 pending `{newTag:"B", canonicalGuess:"C"}` 中 newTag="B" 是独立合法 canonical,
    ///   不该被当 stale 删。superreview P1 #4 fix。
    private func aliasToCanonicalLowerLookup(in groups: [String: [String]], key: String) -> String? {
        for (canonical, aliases) in groups {
            if canonical.lowercased() == key { continue }
            if aliases.contains(where: { $0.lowercased() == key }) { return canonical.lowercased() }
        }
        return nil
    }

    // MARK: - Snapshot for non-MainActor consumers
    //
    // InsightsEngine.aggregateThemes 是 `static` 纯函数(供单测),不能直接 hop 到 MainActor 读。
    // 调用方在 MainActor 上预先取一份 dict 快照,通过 `aliasMap:` 参数喂进去。
    // 单测 / Mock 不传,等价于"无别名"。

    /// `lowercased(alias) → canonical(原文大小写)`。读起来 O(N) copy 一次,N 是 alias 总数,
    /// 即便 1000 条也是几百 µs,Settings/Insights 重算频率远小于此。
    func snapshotIndex() -> [String: String] {
        return aliasToCanonical
    }

    // MARK: - For scan service

    /// 一次性扫已合并的 canonical 名 + 各 alias 的小写 set。
    /// scan service 用来 dedupe 已知对子,不重复打扰。
    func knownLowercasedTagsCovered() -> Set<String> {
        var out = Set<String>()
        for (canonical, aliases) in groups {
            out.insert(canonical.lowercased())
            for a in aliases { out.insert(a.lowercased()) }
        }
        return out
    }

    func isNegative(_ a: String, _ b: String) -> Bool {
        negativePairs.contains(Self.pairKey(a.lowercased(), b.lowercased()))
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
