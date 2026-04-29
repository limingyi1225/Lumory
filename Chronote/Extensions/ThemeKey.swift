import Foundation

// MARK: - ThemeKey
//
// **主题 / 别名 / canonical 比较的统一 key**。任何对主题做比较 / 查 set / 字典 key 的地方
// 都应当走这一个 utility,而不是 ad-hoc `.lowercased()` —— 后者在 NFC vs NFD / 全角半角 /
// 多语言混杂场景下漏命中。
//
// **不变量**:
//   1. NFC 归一化(`precomposedStringWithCanonicalMapping`)—— iOS 各输入法 / 剪贴板 / 网页粘贴
//      可能产 NFC 也可能产 NFD。"café"(NFC,U+00E9)和 "café"(NFD,e + combining acute)
//      raw `.lowercased()` 字节不等,会落到不同 bucket。
//   2. lowercased —— 大小写不敏感。
//   3. trim 首尾空白 —— `"abc"` 跟 `" abc "` 视为同一 key。
//
// **历史**:此函数最早写在 `OpenAIService.swift` 内私有 static,judge / scan 路径独享。
// `ThemeAliasResolver.canonicalize` / `Resolver.rebuildIndex` / `ThemeAliasJudgeService` /
// `ThemeManagementService` 各处仍有 ad-hoc `.lowercased()`(NFC 缺失)。
// 提到这个共享 utility 防止下次有人新加路径时又写一份不一致的归一化。

enum ThemeKey {
    /// 主题/别名比较的标准 key。任何 set / dict / equality 都用这个。
    /// 返回 NFC + lowercased + trimmed。空串保留为空串。
    static func make(_ raw: String) -> String {
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    /// 两个 raw 主题字符串是否归一化后相等。
    static func equal(_ a: String, _ b: String) -> Bool {
        return make(a) == make(b)
    }
}
