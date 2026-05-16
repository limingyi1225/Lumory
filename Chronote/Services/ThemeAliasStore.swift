import Foundation

// MARK: - ThemeAliasStore
//
// **Data + persistence 层(2026-05-16 从 `ThemeAliasResolver` 拆出)**。
// 持有所有"主题别名"系统的真源 state(`groups` / `negativePairs` / `pending` /
// `coolUntil` / `didAutoScanOnce`)+ 反向 index + UserDefaults 持久化 + 纯读 API。
//
// **不是 ObservableObject** —— SwiftUI 观察走 `ThemeAliasResolver`(facade)的
// `objectWillChange`。Store 只是后台数据,callsite 永远不直接观察 Store。
//
// ## 拆分动机(SRP)
//
// `ThemeAliasResolver.swift` 历史上 883 行,read / queue / persistence 三件套混一坨。
// 抽 Store 后:
//   - 改 disk schema / 文件存储格式 / NFC 归一规则 → 只读 Store 这个文件
//   - 改 mutation 业务语义(confirm / mergeThemes / enqueue / ...)→ 只读 Resolver
//   - 改 UI signal(cool-down timer / banner 触发) → 只读 Resolver
//
// ## Mutation 入口:`update(_ mutate:)`
//
// 单一 inout 闭包入口。caller 在 `body(&state)` 内自由修改 5 个字段,Store 退出闭包后
// 一次性 `rebuildIndex()` + `save()`。避免一次业务 mutation(如 `mergeThemes` 改 3 个
// 字段)触发 3 次 save / rebuildIndex 的浪费 + race 风险。
//
// ## 关键不变量(继承自旧 Resolver)
//
//   - **NFC 归一**:`canonicalize(_:)` 用 `ThemeKey.make`(NFC + lowercased + trim),
//     反向 index 也用 `ThemeKey.make` 作 key。`enqueue` / `confirm` / `mergeThemes` 等
//     mutation 内部用 `.lowercased()`(不 NFC,沿用旧行为) — 因为 AI 返回的 tag 已经
//     NFC 化,差异在 NFD 历史 entry 上(canonicalize 时一次 NFC 兜底)。
//   - **decode 失败 → corrupted backup**:disk blob 解码失败时备份到
//     `<key>.corrupted-<unix>` 后再走空状态,保留 2 个最新备份。
//   - **persistence 不阻塞 UI**:UserDefaults 写入是同步的(plist 序列化),数据量 <200
//     条 alias 的预期下,save() < 1ms。如果未来 alias 量级爆炸,需迁离 UserDefaults。

@MainActor
final class ThemeAliasStore {

    // MARK: - Persisted state (private setters; mutation 走 `update(_:)`)

    /// canonical → 别名集合(不含 canonical 自身)。canonical 大小写保留用户首次选择时的形态。
    private(set) var groups: [String: [String]] = [:]

    /// 用户明确说"这两个不是同一实体"的对子。排序后拼成 "a||b" 存。
    private(set) var negativePairs: Set<String> = []

    /// 待审清单。on-write judge 和一次性 scan 都往这写,UI(banner / management page)消费。
    private(set) var pending: [PendingSuggestion] = []

    /// 冷却期。SwiftUI 重渲染由 Resolver 的 `scheduleCoolUntilExpiry` Timer 触发(C4 fix)。
    private(set) var coolUntil: Date? = nil

    /// 首次进入管理页 + alias map 空 + pending 空 时,自动后台 scan 一次的 sentinel。
    /// 持久化到 disk,view 重建不重置(codex P2 fix)。
    private(set) var didAutoScanOnce: Bool = false

    // MARK: - In-memory reverse index

    /// `ThemeKey.make(alias) → canonical(原文大小写)`。`canonicalize(_:)` 的 O(1) 查找。
    /// canonical 自身也存进来(canonical → canonical),让查找无 special case。
    private var aliasToCanonical: [String: String] = [:]

    // MARK: - Storage

    private static let storageKey = "lumory.themeAliasStore.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // 测试用 init,不读 UserDefaults(已有空白盘)
    init(testingWithEmptyState defaults: UserDefaults) {
        self.defaults = defaults
        // 字段使用默认空值,只需 rebuild empty index
        rebuildIndex()
    }

    // 测试用 init,从指定 UserDefaults 读已有 DiskState,验证持久化往返。
    init(testingWithStoredState defaults: UserDefaults) {
        self.defaults = defaults
        load()
    }

    // MARK: - Mutation entry

    /// 单一 mutation 入口。caller 在 inout 闭包内修改 state,退出后自动 `rebuildIndex()` + `save()`。
    /// **不在闭包内调任何 Store 公开方法**(避免递归 + 重复 save)。
    /// `pendingChanged` / `groupsChanged` 等不细分 —— 一次 update 必 rebuild + save 一次。
    func update(_ mutate: (inout State) -> Void) {
        var state = State(
            groups: groups,
            negativePairs: negativePairs,
            pending: pending,
            coolUntil: coolUntil,
            didAutoScanOnce: didAutoScanOnce
        )
        mutate(&state)
        self.groups = state.groups
        self.negativePairs = state.negativePairs
        self.pending = state.pending
        self.coolUntil = state.coolUntil
        self.didAutoScanOnce = state.didAutoScanOnce
        rebuildIndex()
        save()
    }

    /// inout 闭包看到的可变状态。不直接暴露 aliasToCanonical(派生字段,update 后会 rebuild)。
    struct State {
        var groups: [String: [String]]
        var negativePairs: Set<String>
        var pending: [PendingSuggestion]
        var coolUntil: Date?
        var didAutoScanOnce: Bool
    }

    // MARK: - Pure read API

    /// 在聚合 / 展示层使用。命中别名 → 返回 canonical;否则返回 trimmed NFC 化原文。
    /// 大小写不敏感 + NFC 归一化(reverse index 也用 NFC + lowercased key)。
    func canonicalize(_ raw: String) -> String {
        let trimmedNFC = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !trimmedNFC.isEmpty else { return raw }
        return aliasToCanonical[ThemeKey.make(raw)] ?? trimmedNFC
    }

    /// 批量 canonicalize + 去重(保留首次 canonical 的原文大小写)。
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

    /// `lowercased(alias) → canonical(原文大小写)` 的快照。供 InsightsEngine /
    /// ContextPromptGenerator 等非 MainActor 消费者预先抓一份再喂进去。
    func snapshotIndex() -> [String: String] {
        return aliasToCanonical
    }

    /// 一次性扫已合并的 canonical 名 + 各 alias 的 lowercased set。scan service 用来
    /// dedupe 已知对子,不重复打扰。
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

    /// 给 UI 用:预览 `mergeThemes(source:into:)` 会把哪些 alias / canonical **一并**搬移到 target 组。
    /// 返回除 source 自己外会跟着搬过去的标签(原拼写)。空数组表示无附带搬移。
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

    /// `lowercased(a)||lowercased(b)` 的稳定 pair key,a < b 排序。negativePairs / pending dedup
    /// 都用这个。同对子的方向无关性保证 AI 在两次 scan 间 swap 顺序时不会双发。
    static func pairKey(_ a: String, _ b: String) -> String {
        a < b ? "\(a)||\(b)" : "\(b)||\(a)"
    }

    // MARK: - For Resolver mutation logic

    /// 不存进 Store reverse index 的临时反查:供 confirm() 在 stale-pending 清理时,
    /// 用一个**临时 groups** dict 做反查(group 已经被改但 index 还没 rebuild)。
    ///
    /// **关键语义**:只在 key 是某 canonical 的 **alias** 时返回那个 canonical;
    /// 当 key 本身就是某 canonical 时返回 nil ——
    ///   早期版本写成 `if canonical.lowercased() == key { return key }`,
    ///   导致 confirm() 误删一类独立 pending(详见 superreview P1 #4 fix)。
    static func aliasToCanonicalLowerLookup(
        in groups: [String: [String]],
        key: String
    ) -> String? {
        for (canonical, aliases) in groups {
            if canonical.lowercased() == key { continue }
            if aliases.contains(where: { $0.lowercased() == key }) { return canonical.lowercased() }
        }
        return nil
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
            Log.error("[ThemeAliasStore] decode failed, blob backed up to \(backupKeyPrefix)\(now): \(error)", category: .persistence)
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
            Log.error("[ThemeAliasStore] encode failed: \(error)", category: .persistence)
        }
    }

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
}
