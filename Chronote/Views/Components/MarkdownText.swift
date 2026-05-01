import SwiftUI

// MARK: - MarkdownText
//
// 轻量级 markdown 渲染器。针对 AI 流式响应优化：
// - 块级：段落、标题（# / ## / ###）、无序/有序列表、代码块 (```)、块引用 (>)
// - 行内：**bold**、*italic*、`code`、[text](url) —— 交给 Foundation.AttributedString
// - 容忍不完整 markdown（流式中途），解析失败静默回退为纯文本
// - 轻量解析：O(n) 行扫描，单层结构，不递归嵌套，适合聊天场景

struct MarkdownText: View {
    let markdown: String
    var inlineFont: Font = .body
    var lineSpacing: CGFloat = 4

    // **blocks 缓存**：body 每次重评都 full-parse 的 O(n) 扫描成本在流式下不可接受。
    // 缓存从 task(id:) 异步填充；init/body 都不做 markdown 解析，避免 SwiftUI 重建 view
    // 时 eager 计算再被已有 @State 丢弃。
    @State private var cachedBlocks: [Block] = []
    @State private var cacheKey: String?

    init(markdown: String, inlineFont: Font = .body, lineSpacing: CGFloat = 4) {
        self.markdown = markdown
        self.inlineFont = inlineFont
        self.lineSpacing = lineSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // `id: \.self` (Block 需要 Hashable) 让 SwiftUI 按 block **内容**决定 view identity。
            // 以前 `id: \.offset` 是位置 id——流式中 index N 处从 paragraph 变成 heading 就会
            // destroy + recreate 那行 view，用户正在长按 / textSelection 的选区被打断。
            ForEach(Array(cachedBlocks.enumerated()), id: \.element) { _, block in
                render(block)
            }
        }
        .task(id: markdown) {
            await refreshCache(for: markdown)
        }
    }

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .font(inlineFont)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level))
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level == 1 ? 6 : 2)

        case .listItem(let text, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(inlineFont)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(text)
                    .font(inlineFont)
                    .lineSpacing(lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .codeBlock(let code):
            Text(code)
                .font(.system(.footnote, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 0.5)
                )
                .textSelection(.enabled)

        case .blockquote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(text)
                    .font(inlineFont)
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineSpacing(lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .divider:
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 0.5)
                .padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .title3
        case 2:  return .headline
        default: return .subheadline
        }
    }

    private func refreshCache(for value: String) async {
        guard cacheKey != value else { return }

        if value.isEmpty {
            cachedBlocks = []
            cacheKey = value
            return
        }

        let blocks = await Task.detached(priority: .userInitiated) {
            Self.parse(value)
        }.value

        guard !Task.isCancelled else { return }
        cachedBlocks = blocks
        cacheKey = value
    }

    // MARK: Block model

    enum Block: Equatable, Hashable, Sendable {
        case paragraph(AttributedString)
        case heading(Int, AttributedString)
        case listItem(AttributedString, String)  // text, marker ("•" or "1.")
        case codeBlock(String)
        case blockquote(AttributedString)
        case divider
    }

    // MARK: Parsing

    /// 行扫描式 parser。性能：O(行数)。为 AI 流式响应优化——不抛错，容忍未闭合的 ```块。
    static func parse(_ input: String) -> [Block] {
        let raw = input.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = raw.components(separatedBy: "\n")

        var blocks: [Block] = []
        var paragraph: [String] = []
        var codeBuffer: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.paragraph(Self.inlineAttributed(joined)))
            }
            paragraph.removeAll(keepingCapacity: true)
        }

        // 有序列表匹配："1. "、"12. " 等
        let orderedMarker = try? NSRegularExpression(pattern: #"^(\d+)\.\s+"#)

        for line in lines {
            if inCode {
                if line.hasPrefix("```") {
                    blocks.append(.codeBlock(codeBuffer.joined(separator: "\n")))
                    codeBuffer.removeAll(keepingCapacity: true)
                    inCode = false
                } else {
                    codeBuffer.append(line)
                }
                continue
            }
            if line.hasPrefix("```") {
                flushParagraph()
                inCode = true
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            // 分隔线 --- / ***
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.divider)
                continue
            }
            // 标题
            if let (level, text) = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level, Self.inlineAttributed(text)))
                continue
            }
            // 块引用
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.blockquote(Self.inlineAttributed(String(trimmed.dropFirst(2)))))
                continue
            }
            // 无序列表
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.listItem(Self.inlineAttributed(String(trimmed.dropFirst(2))), "•"))
                continue
            }
            // 有序列表
            if let re = orderedMarker,
               let match = re.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)),
               match.range.location == 0 {
                flushParagraph()
                let nsTrimmed = trimmed as NSString
                let markerRange = match.range
                let numberRange = match.range(at: 1)
                let marker = nsTrimmed.substring(with: numberRange) + "."
                let rest = nsTrimmed.substring(from: markerRange.upperBound)
                blocks.append(.listItem(Self.inlineAttributed(rest), marker))
                continue
            }
            // 普通段落
            paragraph.append(trimmed)
        }

        // 流式响应中 ``` 未闭合 —— 把缓冲当 code block 呈现，不丢内容
        if inCode && !codeBuffer.isEmpty {
            blocks.append(.codeBlock(codeBuffer.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> (Int, String)? {
        if line.hasPrefix("### ") {
            return (3, String(line.dropFirst(4)))
        }
        if line.hasPrefix("## ") {
            return (2, String(line.dropFirst(3)))
        }
        if line.hasPrefix("# ") {
            return (1, String(line.dropFirst(2)))
        }
        return nil
    }

    /// 行内 markdown → AttributedString：粗体、斜体、`code`、[link](url)。
    /// 使用 Foundation 的 markdown 解析，带 fallback。
    static func inlineAttributed(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let attr = try? AttributedString(markdown: text, options: options) {
            return attr
        }
        return AttributedString(text)
    }
}

#Preview {
    ScrollView {
        MarkdownText(markdown: """
        # 最近的你

        这段时间你提到**工作**不下 12 次，也常和*朋友*聚会。下面是几个明显的模式：

        - 周一到周三情绪偏低，写的内容多和加班有关
        - 周末和家人吃饭的日子 mood 明显高
        - 有三天几乎没写

        ## 三个值得回看的时刻

        1. 10 月 3 日：你第一次写到想转行
        2. 10 月 12 日：和妈妈那次视频
        3. 10 月 28 日：凌晨 2 点的那段独白

        > 每一次记录都是一次与自己的对话。

        ```swift
        print("hello")
        ```
        """)
        .padding()
    }
}
