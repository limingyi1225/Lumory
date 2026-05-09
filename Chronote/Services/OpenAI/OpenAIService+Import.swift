import Foundation

// MARK: - Import parsing(从外部文本解析成日记)
//
// **wave11 拆出**:从 OpenAIService.swift 把"导入解析"入口搬过来。这是导入功能的
// AI 接口 —— 用户粘贴外部 JSON / Markdown / 自由文本,AI 解析成 `[ParsedDiaryEntry]`
// 数组。`DiaryImportService` 是真源,这里是它调的接口。
//
// 包含:
//   - parseImportedDiaries —— 主入口,典型错误分流(URL / HTTP / 解析)
//
// 旧实现:`DiaryImportService.parse` 是 static 函数,自己组 URLRequest /
// setValue("X-App-Secret") / `URLSession.sharedRetrySession` / 自己 catch 全部错误
// 返回 `[]` —— 完全绕过 `AIServiceProtocol` 注入,Mock 测试无效,且无法把
// 真实错误冒到 UI。
//
// 现在路由到 `chatThrowing()`(throws variant):复用 session pool / `X-Install-Id` /
// `NetworkRetryHelper` / 统一 `errorForStatus`。catch 后按 URLError / HTTP / 其他三
// 类映射成 `DiaryImportError.network` / `.parsingFailed`,UI 能区分对待。

@available(iOS 15.0, macOS 12.0, *)
extension OpenAIService {
    func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] {
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DiaryImportError.emptyInput
        }

        // **Prompt injection 防御**:用户粘贴文本里的 `>>>` / `<<<` 会和我们的 delimiter
        // 混淆,导致后续指令被攻击者覆盖。换成视觉等价但 codepoint 不同的全角对角号
        // (U+203A / U+2039 各重复 3 次),用户读起来几乎无差,LLM 也不会把它误当 delimiter。
        // TODO: migrate to structured JSON payload —— 把 rawText 放进 JSON 字段而不是
        // 用纯文本 delimiter,可以彻底消除 delimiter 注入面。改 prompt 契约成本不大,
        // 但需要同步调整模型 prompt 里的 "Examples" 段落,先用 escape 落地。
        let safe = rawText
            .replacingOccurrences(of: ">>>", with: "\u{203A}\u{203A}\u{203A}")
            .replacingOccurrences(of: "<<<", with: "\u{2039}\u{2039}\u{2039}")

        let today = Date()
        let promptDateFormatter = ISO8601DateFormatter()
        promptDateFormatter.formatOptions = [.withFullDate]
        let todayStr = promptDateFormatter.string(from: today)
        let year = Calendar.current.component(.year, from: today)
        let dateFormatterCN = DateFormatter()
        dateFormatterCN.dateFormat = "yyyy年MM月dd日"
        let todayCNStr = dateFormatterCN.string(from: today)
        let prompt = """
当前年份是 \(year)；今天日期是 \(todayCNStr)（ISO格式：\(todayStr)）。

解析给定的日记文本，将其转换为JSON数组。每个元素应包含两个字段：date字段以ISO 8601（YYYY-MM-DD）格式记录日期，text字段记录对应日期的文本内容。

请按以下步骤解析文本：

1. 提取文本中的日期和对应的日记内容。
2. 如果日记没有标注年份且日期晚于今天，则为这篇日记分配的年份是\(year - 1)年。如日记没有标注年份，且日期早于或就是今天，则为这篇日记分配的年份是\(year)年。
3. 按照上述条件构建JSON数组，其中每个元素包含"date"和"text"字段。

# Output Format

- 输出结果为一个JSON数组。
- 每个元素应包含：
  - "date": 日期字符串，符合ISO 8601格式。
  - "text": 该日期下的日记内容。

# Examples

以下是如何将日记文本解析为JSON的示例格式：

输入：
```
2023年10月1日: 今天是国庆节，我们一家人去了长城。
2023年10月2日: 今天开始下雨，留在家里。
```

输出：
```json
[
    {
        "date": "2023-10-01",
        "text": "今天是国庆节，我们一家人去了长城。"
    },
    {
        "date": "2023-10-02",
        "text": "今天开始下雨，留在家里。"
    }
]
```

# Notes

- 确保输出的日期和时间信息符合ISO 8601标准。
- 确保按照上述步骤给日记分配年份（当前日期：\(todayStr)）。
<<<\(safe)>>>
"""

        // 走 `chatThrowing`(throws variant) 而非旧 `chat`(吞错回 nil)。reviewer 第二轮指出旧路径
        // 把 401/429/offline 全部归到 "AI 未返回内容",defeats 了 `DiaryImportError.network`
        // 与 `.parsingFailed` 的区分。这里 catch 错误后按类型映射:
        //   - URLError(连接失败 / 超时 / DNS) → `.network` 让用户去查网络
        //   - NSError code 100~599(HTTP 状态)→ `.network` 让用户去查后端/认证/限流
        //   - 其他(空内容、解码错误等)→ `.parsingFailed` 提示重试或换内容
        let content: String
        do {
            content = try await self.chatThrowing(
                prompt: prompt,
                model: "gpt-5.5",
                maxTokens: 16384,
                reasoningEffort: "low"
            )
        } catch let urlError as URLError {
            throw DiaryImportError.network(urlError)
        } catch let nsError as NSError where nsError.code >= 100 && nsError.code < 600 {
            // HTTP 状态码全部归为 network 类:401(配置错)/ 403 / 429 / 5xx 都是后端/网络维度的问题,
            // 不是 AI 解析问题。
            throw DiaryImportError.network(nsError)
        } catch let nsError as NSError where nsError.domain == NSURLErrorDomain {
            throw DiaryImportError.network(nsError)
        } catch {
            // 走到这里通常是空内容(code -2)或 JSONDecoder 失败 —— 视为解析失败。
            Log.info("[OpenAIService] parseImportedDiaries: chatThrowing -> parsingFailed: \(error)", category: .persistence)
            throw DiaryImportError.parsingFailed(
                reason: NSLocalizedString("error.import.noContent",
                                          value: "AI 未返回内容,请稍后再试。",
                                          comment: "AI returned empty content during import")
            )
        }

        // 只 log 长度,不要把模型回包(里面套了用户日记原文)落到 sysdiagnose 里。
        Log.info("[OpenAIService] parseImportedDiaries: raw content length \(content.count) chars",
                 category: .persistence)

        guard let startIndex = content.firstIndex(of: "["),
              let endIndex = content.lastIndex(of: "]") else {
            // 模型有内容但不是 JSON 数组结构 —— 算解析失败,不能当成"0 条"。
            throw DiaryImportError.parsingFailed(
                reason: NSLocalizedString("error.import.notJSON",
                                          value: "AI 返回的内容不是合法 JSON 数组。",
                                          comment: "AI response not JSON array")
            )
        }
        let jsonString = String(content[startIndex...endIndex])
        struct RawEntry: Decodable {
            let date: String
            let text: String
        }
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw DiaryImportError.parsingFailed(
                reason: NSLocalizedString("error.import.notJSON",
                                          value: "AI 返回的内容不是合法 JSON 数组。",
                                          comment: "AI response not JSON array")
            )
        }
        let raws: [RawEntry]
        do {
            raws = try JSONDecoder().decode([RawEntry].self, from: jsonData)
        } catch {
            throw DiaryImportError.parsingFailed(reason: error.localizedDescription)
        }

        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]
        var results: [ParsedDiaryEntry] = []
        for raw in raws {
            if let date = df.date(from: raw.date) {
                results.append(ParsedDiaryEntry(date: date, text: raw.text))
            }
        }
        // **空数组是合法成功**:模型读完粘贴内容认定"里面没有日记结构"。UI 会区分对待。
        return results
    }
}
