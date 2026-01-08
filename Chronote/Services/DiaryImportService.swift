import Foundation


struct DiaryImportService {
    struct ParsedEntry: Decodable {
        let date: String
        let text: String
    }

    /// 调用 OpenRouter qwen/qwen-turbo 模型解析日记，返回 (Date, String) 数组。若解析失败则返回空数组。
    /// - Parameters:
    ///   - rawText: 用户粘贴的整段日记文本
    /// - Returns: [(date, text)]
    static func parse(rawText: String) async -> [(Date, String)] {
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        // 构造带有当前日期的提示
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
2. 如果日记没有标注年份且日期晚于今天，则为这篇日记分配的年份是2024年。如日记没有标注年份，且日期早于或就是今天，则为这篇日记分配的年份是2025年。
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
- 确保按照上述步骤给日记分配年份（\(todayStr)）。
<<<\(rawText)>>>
"""
        let messages: [[String: String]] = [
            ["role": "user", "content": prompt]
        ]
        let requestDict: [String: Any] = [
            "model": "qwen/qwen-turbo",
            "messages": messages,
            "max_tokens": 16384,
            "temperature": 0.0
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestDict) else { return [] }

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(AppSecrets.openAIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60.0 // 60 second timeout for large imports
        request.httpBody = bodyData

        do {
            // Use sslTolerantSession with retry for better reliability
            let (data, response) = try await NetworkRetryHelper.performWithRetry(maxRetries: 2, retryDelay: 1.0) {
                try await URLSession.sslTolerantSession.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else {
                print("[DiaryImportService] Non-HTTP response: \(response)")
                return []
            }
            guard (200...299).contains(http.statusCode) else {
                let bodyStr = String(decoding: data, as: UTF8.self)
                print("[DiaryImportService] Bad status code: \(http.statusCode), body: \(bodyStr)")
                return []
            }
            struct Response: Decodable {
                struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
                let choices: [Choice]
            }
            let resp = try JSONDecoder().decode(Response.self, from: data)
            guard let content = resp.choices.first?.message.content else {
                print("[DiaryImportService] No content in response choices")
                return []
            }
            print("[DiaryImportService] raw content: \(content)")
            guard let startIndex = content.firstIndex(of: "["), let endIndex = content.lastIndex(of: "]") else { return [] }
            let jsonString = String(content[startIndex...endIndex])
            guard let jsonData2 = jsonString.data(using: String.Encoding.utf8), let entries = try? JSONDecoder().decode([ParsedEntry].self, from: jsonData2) else { return [] }
            let df = ISO8601DateFormatter()
            df.formatOptions = [.withFullDate]
            var results: [(Date, String)] = []
            for entry in entries {
                if let d = df.date(from: entry.date) {
                    results.append((d, entry.text))
                }
            }
            return results
        } catch {
            print("[DiaryImportService] Error: \(error)")
            return []
        }
    }
} 
