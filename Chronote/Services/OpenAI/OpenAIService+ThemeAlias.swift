import Foundation

// MARK: - Theme Alias(主题别名 AI 子系统)
//
// **wave11 拆出**:从 OpenAIService.swift 把"主题别名"两条入口聚到一起。
// 共同特征:都是"标签去重"业务,模型 = gpt-5.5 + reasoning=medium(mini 抓不住跨语言
// 昵称对应,low 抓不全,medium 是 quality/cost 折中)。`ThemeAliasResolver` 是真源,
// 这里两个 API 都是发请求 + 解析 → 返回结构化结果给 resolver 入队待审。
//
// 包含:
//   - judgeThemeAliases    —— 写日记 hot-path 后跑(新 tags vs 已有库存,挑高置信度对子)
//   - scanThemeAliasGroups —— Settings"扫描已有主题"按钮,一次性全量扫存量
//   - themeKey             —— 静态 wrapper,等于 ThemeKey.make(_:),保留兼容
//   - snippetSummary       —— 私有 helper,prompt 拼接时给 AI 看主题示例片段

@available(iOS 15.0, macOS 12.0, *)
extension OpenAIService {
    // MARK: - Theme alias judge (on-write + scan)
    //
    // 模型 = gpt-5.5 + reasoning=medium。
    // mini 太弱抓不到"宝贝 ↔ Abby"这种跨语言昵称对应;5.5 + medium 是 quality/cost 折中。
    // 这两个接口都是写日记 hot-path 上跑的,延迟不敏感(banner 是异步软提示),但要稳定。

    func judgeThemeAliases(
        newTags: [String],
        inventory: [ThemeAliasJudgeCandidate]
    ) async -> [ThemeAliasJudgeMatch] {
        guard !newTags.isEmpty, !inventory.isEmpty else { return [] }

        // top-100 平衡 token 上限和召回率(经验上日记 App 的实体高频长尾很长,40 截太狠)。
        let topInventory = inventory
            .sorted { $0.count > $1.count }
            .prefix(100)
        // 用 NFC 归一化 + lowercased set 做 hallucination 验证:模型偶尔会回吐 input 里**根本不存在**的
        // tag,直接入队会污染 pending(用户看到"宝贝是不是 Cooper?" 但他从没写过 Cooper)。
        // NFC 归一化:模型偶尔返回组合字符(`á` = `a` + `\u{0301}`),原始输入是 precomposed,
        // 不归一化会被当 hallucination 误丢(codex P2 #14 fix)。
        let allowedNew = Set(newTags.map { Self.themeKey($0) })
        let allowedCanonical = Set(topInventory.map { Self.themeKey($0.tag) })
        let inventoryLines = topInventory.map { c -> String in
            if let snip = c.sampleSnippet, !snip.isEmpty {
                return "- \(c.tag) (\(c.count) 篇) — “\(Self.snippetSummary(snip, max: 60))”"
            }
            return "- \(c.tag) (\(c.count) 篇)"
        }.joined(separator: "\n")

        let newList = newTags.map { "- \($0)" }.joined(separator: "\n")

        let prompt = """
        你是一个日记 App 的标签去重助手。判断**新出现的标签**是否与**用户已有标签库存**里的某个标签指向同一实体(同一个人、宠物、地方、项目、活动)。

        判断标准(严苛宁缺勿滥):
        - HIGH: 强证据,几乎肯定是同一实体(常见昵称/翻译/简称对应,例:Abby ↔ 宝贝、东京 ↔ Tokyo、Mom ↔ 妈妈)
        - MEDIUM: 可能是同一实体但有歧义,需要用户确认
        - LOW: 弱关联,不返回(同名异人例如多个"哥哥",同主题不同实例例如"跑步"和"晨跑"可能是不同活动,都判 LOW)

        **只返回 HIGH 和 MEDIUM,LOW 一律省略。** 找不到任何匹配就返回空数组。

        新标签:
        \(newList)

        已有标签库存(按出现次数排序,括号内为出现条目数,引号内为示例片段):
        \(inventoryLines)

        只返回 JSON,格式:
        {"matches":[{"new":"宝贝","canonical":"Abby","confidence":"high","reason":"昵称对应"}]}
        没有匹配:{"matches":[]}
        """

        // gpt-5.5 + reasoning=medium —— `low` 抓不住"宝贝 ↔ Abby"这种跨语言昵称。
        // medium 的 reasoning token 大概 800-1500,output JSON ~300。max_completion_tokens 升到 4096
        // 给 p99 长 inventory 留余量;原 3072 下长清单 + medium reasoning 会偶发截断 JSON →
        // parse fail → 静默漏匹配。superreview P2 fix。
        // superreview P1 #7 fix:on-write 是 fire-and-forget,失败必须有 Log,
        // 否则持续 401/429 / 解析失败时 alias 索引完全静默失效,无从诊断。
        guard let raw = await chat(
            prompt: prompt,
            model: "gpt-5.5",
            maxTokens: 4096,
            forceJSON: true,
            reasoningEffort: "medium"
        )?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            Log.warning("[OpenAIService] judgeThemeAliases: chat() returned nil — likely rate-limited / auth / network failure", category: .ai)
            return []
        }
        if Task.isCancelled { return [] }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["matches"] as? [[String: Any]] else {
            // 截断诊断:打印 raw length,生产里观察到 length 接近 maxTokens 字符上限就是被吃了。
            Log.error("[OpenAIService] judgeThemeAliases: failed to parse model output as JSON with `matches` array (rawLength=\(raw.count))", category: .ai)
            return []
        }

        var out: [ThemeAliasJudgeMatch] = []
        for entry in arr {
            guard let newTagRaw = (entry["new"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let canonicalRaw = (entry["canonical"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !newTagRaw.isEmpty,
                  !canonicalRaw.isEmpty else {
                continue
            }
            // NFC 归一化(模型可能返 decomposed 形态)
            let newTag = newTagRaw.precomposedStringWithCanonicalMapping
            let canonical = canonicalRaw.precomposedStringWithCanonicalMapping
            guard Self.themeKey(newTag) != Self.themeKey(canonical) else { continue }

            // confidence 解析:trim + lowercased 容错(模型偶尔返 "high " 或 "High\n")
            let confRaw = (entry["confidence"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let conf = ThemeAliasJudgeMatch.Confidence(rawValue: confRaw ?? "") else {
                Log.info("[OpenAIService] judgeThemeAliases: 丢弃低/未知置信对子 \(newTag)→\(canonical)", category: .ai)
                continue
            }

            // Hallucination 防御:model 偶尔会回吐 input 里没有的 tag。整体丢弃。
            guard allowedNew.contains(Self.themeKey(newTag)),
                  allowedCanonical.contains(Self.themeKey(canonical)) else {
                Log.info("[OpenAIService] judgeThemeAliases: 丢弃 hallucinated 对子 \(newTag)→\(canonical)", category: .ai)
                continue
            }
            let reason = (entry["reason"] as? String)?.trimmingCharacters(in: .whitespaces)
            out.append(ThemeAliasJudgeMatch(
                newTag: newTag,
                canonical: canonical,
                confidence: conf,
                reason: reason
            ))
        }
        return out
    }

    /// **保留兼容方便,新代码请直接用 `ThemeKey.make(_:)`**(`Extensions/ThemeKey.swift`)。
    /// 这里的 wrapper 让历史 `Self.themeKey(...)` 调用点不动也对。
    static func themeKey(_ raw: String) -> String {
        ThemeKey.make(raw)
    }

    func scanThemeAliasGroups(
        candidates: [ThemeAliasJudgeCandidate]
    ) async throws -> [ThemeAliasJudgeGroup] {
        guard candidates.count >= 2 else { return [] }
        // 一次性 scan 是用户主动行为,可以多送点 tag 给模型 —— top 150 覆盖大部分用户的全部实体。
        let top = candidates.sorted { $0.count > $1.count }.prefix(150)
        let allowedTags = Set(top.map { Self.themeKey($0.tag) })
        let lines = top.map { c -> String in
            if let snip = c.sampleSnippet, !snip.isEmpty {
                return "- \(c.tag) (\(c.count) 篇) — “\(Self.snippetSummary(snip, max: 60))”"
            }
            return "- \(c.tag) (\(c.count) 篇)"
        }.joined(separator: "\n")

        let prompt = """
        你是一个日记 App 的标签去重助手。在用户的全部标签列表里,找出**指向同一实体**(同一个人、宠物、地方、项目)的标签组。

        判断标准(严苛宁缺勿滥):
        - HIGH: 强证据(常见昵称/翻译/简称对应,例:Abby/宝贝/老婆 同一人,Tokyo/东京 同地)
        - MEDIUM: 可能但有歧义
        - LOW: 不返回(同名异人、同类不同实例例如妈妈/母亲可能不是同一称呼习惯)

        每组挑一个最自然的 canonical(通常是出现次数最高的)。**只返回 HIGH 和 MEDIUM**。

        标签列表(按出现次数排序):
        \(lines)

        只返回 JSON:
        {"groups":[{"canonical":"Abby","aliases":["宝贝","老婆"],"confidence":"high","reason":"昵称对应"}]}
        没有任何同实体组:{"groups":[]}
        """

        // gpt-5.5 + reasoning=medium。scan 一次扫全量,JSON 输出可能很大,maxTokens 给到 6144。
        // **throws 区分**:chat() 返 nil → 网络/后端故障 → throw .requestFailed
        //                 JSON 解析失败 → throw .parsingFailed
        //                 真的 0 条匹配 → return [](Settings 显示"没找到")
        guard let raw = await chat(
            prompt: prompt,
            model: "gpt-5.5",
            maxTokens: 6144,
            forceJSON: true,
            reasoningEffort: "medium"
        )?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ThemeAliasError.requestFailed
        }
        if Task.isCancelled { return [] }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["groups"] as? [[String: Any]] else {
            // rawLength 接近 maxTokens(~24KB)→ 多半是被截断,不是模型故障。
            Log.error("[OpenAIService] scanThemeAliasGroups: parse failed (rawLength=\(raw.count))", category: .ai)
            throw ThemeAliasError.parsingFailed
        }

        var out: [ThemeAliasJudgeGroup] = []
        for entry in arr {
            guard let canonicalRaw = (entry["canonical"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !canonicalRaw.isEmpty else {
                continue
            }
            let canonical = canonicalRaw.precomposedStringWithCanonicalMapping

            // aliases shape 容错:模型偶尔返 [{"name":"宝贝"}] / 单 string / [String:Any] 的 alias 字段。
            // 严格 [String] 时整组静默丢,改成多形态接收(codex P2 #14)。
            let aliasesRaw: [String]
            if let arr = entry["aliases"] as? [String] {
                aliasesRaw = arr
            } else if let arr = entry["aliases"] as? [[String: Any]] {
                aliasesRaw = arr.compactMap { obj in
                    (obj["name"] ?? obj["alias"] ?? obj["tag"]) as? String
                }
            } else if let single = entry["aliases"] as? String {
                aliasesRaw = [single]
            } else {
                continue
            }

            // confidence trim + lowercased
            let confRaw = (entry["confidence"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let conf = ThemeAliasJudgeGroup.Confidence(rawValue: confRaw ?? "") else {
                Log.info("[OpenAIService] scan: 丢弃低/未知置信组 \(canonical)", category: .ai)
                continue
            }

            // Hallucination 防御:canonical 必须在 candidate 列表里;aliases 至少有一条命中。
            // 整组若 canonical 是 hallucinated → 丢弃整组(否则后续 confirm 写入 ghost canonical)。
            let canonicalKey = Self.themeKey(canonical)
            guard allowedTags.contains(canonicalKey) else {
                Log.info("[OpenAIService] scan: 丢弃 hallucinated canonical \(canonical)", category: .ai)
                continue
            }
            let aliases = aliasesRaw
                .map { $0.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping }
                .filter { !$0.isEmpty && Self.themeKey($0) != canonicalKey }
                // 同时过滤 aliases 里 hallucinated 的(单个 alias hallucinate 不丢整组,只丢这条)
                .filter { allowedTags.contains(Self.themeKey($0)) }
            guard !aliases.isEmpty else { continue }
            let reason = (entry["reason"] as? String)?.trimmingCharacters(in: .whitespaces)
            out.append(ThemeAliasJudgeGroup(
                canonical: canonical,
                aliases: aliases,
                confidence: conf,
                reason: reason
            ))
        }
        return out
    }

    fileprivate static func snippetSummary(_ raw: String, max: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "\n", with: " ")
        if cleaned.count <= max { return cleaned }
        return String(cleaned.prefix(max)) + "…"
    }
}
