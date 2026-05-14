import Foundation

// MARK: - NarrativeStreamSplitter
//
// gpt-5.5 narrative stream 完整结束后,把 raw output 拆成 (headline, body)。
// prompt 让模型按 `[HEADLINE]\n一两句诗意\n[BODY]\n长文` 输出,客户端 done 后一次 split。
//
// **为什么不 mid-stream 切分**:marker 可能跨 chunk(模型 token 拆 "[" "HEAD" "LINE" "]"),
// mid-stream 解析需要 lookahead buffer + 状态机,实现复杂度大且易出 bug。done 后一次 split
// 简单可靠;streaming 期间 UI 用 thinking 占位,3-8 秒后整段 fade-in,体验也合理。
//
// **fallback 行为**:模型不守 marker(只输出文本 / 只 [HEADLINE] 没 [BODY])→ headline=nil
// 全部当 body,view 层用 fallbackHeadline 取 body 第一段第一句作 placeholder。这样模型
// 出格也不会让卡空白,优雅降级。
//
// **健壮性**:headline 长度 > 80(模型 leak 正文进 [HEADLINE])→ 截前两句作 headline,后半
// 部分**并入 body 前**(不静默丢失内容,codex 反馈)。

enum NarrativeStreamSplitter {

    /// 限定 headline 最大长度;超过判模型 leak 正文,截前两句剩下并回 body。
    private static let headlineCharLimit = 80

    static func split(rawOutput: String) -> (headline: String?, body: String) {
        // **P2 fix (2026-05-13 superreview)**:模型在某些后端配置下输出 CRLF 行分隔,
        // 后续 `components(separatedBy: "\n\n")` 在 fallbackHeadline 里识别不到段落。
        // 入口先 normalize 一次,后续逻辑只关心 LF。
        let rawOutput = rawOutput.replacingOccurrences(of: "\r\n", with: "\n")
        // **P2 fix**:空 / 全空白输入(SSE 立刻 done)早返,避免后续 trim 走一遭。
        if rawOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (nil, "")
        }
        // 1. 找 [HEADLINE] 起始
        guard let headlineRange = rawOutput.range(of: "[HEADLINE]") else {
            let cleaned = rawOutput
                .replacingOccurrences(of: "[BODY]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, cleaned)
        }
        let afterHeadline = rawOutput[headlineRange.upperBound...]

        // 2. 找 [BODY] 切分;只 [HEADLINE] 没 [BODY] → 不可信,退化整段当 body
        // **codex review fix**:必须清掉 [HEADLINE] marker,否则 body 里出现 protocol marker
        // 字面量,fallbackHeadline 还会取到 "[HEADLINE]" 当 placeholder 给用户看到,极丑。
        guard let bodyRange = afterHeadline.range(of: "[BODY]") else {
            let cleaned = rawOutput
                .replacingOccurrences(of: "[HEADLINE]", with: "")
                .replacingOccurrences(of: "[BODY]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, cleaned)
        }
        let headline = afterHeadline[..<bodyRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // **P1 fix (2026-05-13 superreview round 2)**:主路径 split 后 body 内仍可能残留
        // `[HEADLINE]` / `[BODY]` 字面 — 模型偶尔在正文里 echo 这些 marker 名(尤其
        // ask-the-model-to-summarize-its-own-output 类 prompt 调试时)。fallback 路径已 strip,
        // 主路径漏 → 直接原样存进 NarrativePayload.body 渲染给用户。统一 strip。
        let body = String(afterHeadline[bodyRange.upperBound...])
            .replacingOccurrences(of: "[HEADLINE]", with: "")
            .replacingOccurrences(of: "[BODY]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. headline 太长 → 截前两句,后半并回 body 前
        if headline.count > headlineCharLimit {
            return truncateLeakingHeadline(headline, body: body)
        }

        return (headline.isEmpty ? nil : headline, body)
    }

    /// fallback:v2 老 cache(无 headline)显示 body 第一段第一句作 placeholder。
    /// 找句末标点(中英全宽 ?! 都覆盖),截到那里;无标点 → 30 字截断 + "…"。
    /// 注意:body 顶部可能有空白段(全空格 + \n\n),要找第一个 trim 后非空的段。
    ///
    /// **P1 fix (2026-05-13 superreview)**:ASCII `.` 在英文里大量歧义(小数 `9.30`、
    /// 缩写 `Dr.`、`a.m.`)。简单 `firstIndex(where:)` 找 `.` 会把 "Dr. Smith said hi today."
    /// 截成 "Dr."。改成要求 `.` 之后跟空白 / 换行 / 字符串末尾才算句末;中文全宽标点 / `?` /
    /// `!` / `…` 单独足以收尾(没有歧义)。同时仍保留 30 字硬上限作兜底。
    static func fallbackHeadline(fromBody body: String) -> String {
        let firstPara = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? body.trimmingCharacters(in: .whitespacesAndNewlines)
        if firstPara.isEmpty { return "" }
        if let endIdx = firstSentenceEndIndex(in: firstPara) {
            return String(firstPara[firstPara.startIndex...endIdx])
        }
        return firstPara.count > 30 ? String(firstPara.prefix(30)) + "…" : firstPara
    }

    /// 找第一个"真句末标点"的位置。ASCII `.` 必须后跟空白 / 换行 / 字符串末尾才算;
    /// 中文全宽标点 / `?` / `!` / `…` 自身明确收尾不要求 lookahead。
    private static func firstSentenceEndIndex(in text: String) -> String.Index? {
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if Self.endingPunctuation.contains(ch) {
                if ch == "." {
                    let next = text.index(after: idx)
                    if next == text.endIndex {
                        return idx
                    }
                    let nextCh = text[next]
                    if nextCh.isWhitespace || nextCh.isNewline {
                        return idx
                    }
                    // ASCII `.` 紧跟字母数字 → 缩写 / 小数,继续找。
                } else {
                    return idx
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    // MARK: - Private

    /// headline 超长(模型把正文 leak 进来)的截断逻辑。前两句作 headline,后半截作 body 前缀
    /// 拼起来不丢内容。找不到 2 个句末标点 → 字符前 80 截 + "…"。
    ///
    /// **P2 fix (2026-05-13 superreview)**:数一句后跳过紧跟的多个连续 endingPunctuation
    /// (`"!!!"` / `"..."` / `"。。"`)再继续,避免标点丛被算成多句。同时复用 ASCII `.` 的
    /// lookahead 判定。
    private static func truncateLeakingHeadline(_ headline: String, body: String) -> (headline: String?, body: String) {
        var sentenceCount = 0
        var splitIdx: String.Index?
        var idx = headline.startIndex
        while idx < headline.endIndex {
            let ch = headline[idx]
            if Self.endingPunctuation.contains(ch) {
                let isRealEnd: Bool
                if ch == "." {
                    let next = headline.index(after: idx)
                    isRealEnd = next == headline.endIndex
                        || headline[next].isWhitespace
                        || headline[next].isNewline
                } else {
                    isRealEnd = true
                }
                if isRealEnd {
                    sentenceCount += 1
                    // skip 连续相同/相邻 endingPunctuation 字符(`!!!` / `...` / `。。`)
                    var skip = headline.index(after: idx)
                    while skip < headline.endIndex, Self.endingPunctuation.contains(headline[skip]) {
                        skip = headline.index(after: skip)
                    }
                    if sentenceCount == 2 {
                        splitIdx = skip
                        break
                    }
                    idx = skip
                    continue
                }
            }
            idx = headline.index(after: idx)
        }
        if let splitIdx {
            let head = String(headline[..<splitIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let leak = String(headline[splitIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let mergedBody = leak.isEmpty ? body : (leak + "\n\n" + body)
            return (head.isEmpty ? nil : head, mergedBody)
        }
        // 找不到 2 个句末 → 字符前 80 截 + "…",剩下并回 body
        let cutIdx = headline.index(headline.startIndex, offsetBy: headlineCharLimit)
        let head = String(headline[..<cutIdx]) + "…"
        let leak = String(headline[cutIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let mergedBody = leak.isEmpty ? body : (leak + "\n\n" + body)
        return (head, mergedBody)
    }

    /// 中英 + 全宽句末标点,fallback 与 truncate 共用。
    private static let endingPunctuation: Set<Character> = [
        ".", "。", "?", "?", "!", "!", "…",
        "\u{FF1F}",  // 全宽 ? (FULLWIDTH QUESTION MARK)
        "\u{FF01}",  // 全宽 ! (FULLWIDTH EXCLAMATION MARK)
    ]
}

enum NarrativeStreamLimits {
    static let rawOutputCharacterLimit = 64_000

    static var localTruncationReason: String {
        NSLocalizedString(
            "narrative.summary.localOutputLimit",
            value: "内容过长,已截断。",
            comment: "Narrative generation truncated locally because output exceeded safety limit"
        )
    }

    /// Appends as much of `chunk` as fits in the local raw-output cap.
    /// Returns true when any part of the chunk had to be dropped.
    static func append(_ chunk: String, to rawOutput: inout String) -> Bool {
        guard !chunk.isEmpty else { return false }
        let remaining = rawOutputCharacterLimit - rawOutput.count
        guard remaining > 0 else { return true }
        if chunk.count <= remaining {
            rawOutput += chunk
            return false
        }
        rawOutput += String(chunk.prefix(remaining))
        return true
    }
}
