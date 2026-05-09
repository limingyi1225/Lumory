//
//  DiaryEntryEdgeCaseTests.swift
//  ChronoteTests
//
//  P1 边界覆盖,补 `Chronote/Model/DiaryEntry+Extensions.swift` 三块当前无单测的纯函数:
//    1. `sanitizeThemes` 单 tag 50 字符上限截断(`maxThemeTagLength`)
//       —— 现有 SanitizeThemesTests 覆盖 dedup/CSV/cap-6,**未** 覆盖此条
//       根据源码注释:"防 AI 回一个超长字符串撑爆 themes 列、CloudKit 同步超限,
//       以及 aggregateThemes 里一个 bucket 吃掉所有条目"
//    2. `countWords(in:)` CJK + Latin 混合
//       —— 算法是 `cjkCount + latinWords`(sum,不是 max),CJK 按 unicode scalar 范围
//       (CJK Unified / Hiragana / Katakana / Hangul),Latin 按 whitespace token
//       且必须含 `[a-zA-Z0-9]`
//    3. `loadImageData(fileName:)` 三层回退的 **本地 LumoryImages + legacy 扁平 Documents** 路径
//       —— iCloud ubiquity container 不易 mock,跳过
//

import Testing
import Foundation
@testable import Lumory

// MARK: - sanitizeThemes 边界(50 字符上限)

struct SanitizeThemesEdgeTests {
    @Test func oversizedTag_truncatedToMaxThemeTagLength() {
        let cap = DiaryEntry.maxThemeTagLength
        let oversized = String(repeating: "a", count: 80) // 80 > cap=50
        let out = DiaryEntry.sanitizeThemes([oversized, "normal"])
        let tags = out?.split(separator: ",").map(String.init) ?? []
        #expect(tags.count == 2)
        #expect(tags[0].count == cap)
        #expect(tags[0] == String(repeating: "a", count: cap))
        #expect(tags[1] == "normal")
    }

    @Test func exactlyMaxLength_keptIntact() {
        let cap = DiaryEntry.maxThemeTagLength
        let edge = String(repeating: "x", count: cap)
        let out = DiaryEntry.sanitizeThemes([edge])
        #expect(out == edge)
        #expect(out?.count == cap)
    }

    @Test func oneOverMaxLength_truncatedByOne() {
        let cap = DiaryEntry.maxThemeTagLength
        let oneOver = String(repeating: "y", count: cap + 1)
        let out = DiaryEntry.sanitizeThemes([oneOver])
        #expect(out?.count == cap)
        #expect(out == String(repeating: "y", count: cap))
    }

    @Test func longCJKTag_truncatedByCharacterCount() {
        // CJK 每字一个 grapheme,prefix 按 Character 切,50 字 = 50 grapheme
        let cap = DiaryEntry.maxThemeTagLength
        let cjk = String(repeating: "中", count: 80)
        let out = DiaryEntry.sanitizeThemes([cjk])
        #expect(out?.count == cap)
        #expect(out == String(repeating: "中", count: cap))
    }

    @Test func emojiTag_truncationByGraphemeCluster_locksCurrentBehavior() {
        // String.prefix 走 extended grapheme clusters,emoji(包括 ZWJ 复合 emoji)
        // 算 1 个 Character。固化当前行为防止后续误改 utf16 / unicodeScalars 切法。
        let cap = DiaryEntry.maxThemeTagLength
        let mixedEmoji = String(repeating: "👋", count: 80) // 80 grapheme
        let out = DiaryEntry.sanitizeThemes([mixedEmoji])
        #expect(out?.count == cap, "prefix 切到 \(cap) Character;实际 \(out?.count ?? -1)")
        #expect(out == String(repeating: "👋", count: cap))
    }
}

// MARK: - countWords CJK + Latin 混合

struct CountWordsTests {
    @Test func emptyString_returnsZero() {
        #expect(DiaryEntry.countWords(in: "") == 0)
    }

    @Test func whitespaceOnly_returnsZero() {
        // " " / tab / newline 全是 whitespace → split 后全空 → 0;cjk 0
        #expect(DiaryEntry.countWords(in: "   \n\t  ") == 0)
    }

    @Test func pureLatin_countsByWhitespaceToken() {
        #expect(DiaryEntry.countWords(in: "hello world") == 2)
        #expect(DiaryEntry.countWords(in: "one two three four") == 4)
    }

    @Test func pureCJK_countsByCharacter() {
        // 4 个汉字 = 4 word(cjk path)
        #expect(DiaryEntry.countWords(in: "你好世界") == 4)
    }

    @Test func pureHiragana_countsByCharacter() {
        // 算法包含 Hiragana(0x3040..0x30FF)
        // ありがとう = 5 个假名
        #expect(DiaryEntry.countWords(in: "ありがとう") == 5)
    }

    @Test func pureHangul_countsByCharacter() {
        // 算法包含 Hangul(0xAC00..0xD7AF)
        // 안녕하세요 = 5 个 Hangul syllable
        #expect(DiaryEntry.countWords(in: "안녕하세요") == 5)
    }

    @Test func mixedCJKAndLatin_sumsBothPaths() {
        // 算法是 cjkCount + latinWords(sum,不是 max)
        // "I love 你好" → cjk=2(你+好), latin=2(I, love) → 4
        #expect(DiaryEntry.countWords(in: "I love 你好") == 4)
    }

    @Test func emojiOnly_returnsZero() {
        // emoji 不在 cjk scalar 范围 + 不含 [a-zA-Z0-9] → 两条 path 都给 0
        #expect(DiaryEntry.countWords(in: "👋😀🎉") == 0)
    }

    @Test func emojiPlusLatin_emojiExcluded() {
        // "👋 hello" → cjk=0, latin: "👋" 不含字母数字被 filter 掉,"hello" 留 → 1
        #expect(DiaryEntry.countWords(in: "👋 hello") == 1)
    }

    @Test func punctuationOnly_returnsZero() {
        // 纯标点 split 后剩下的 token 不含 [a-zA-Z0-9] → latin=0;cjk 范围内 0
        #expect(DiaryEntry.countWords(in: "...,,!!??") == 0)
    }

    @Test func numbersCountedAsLatinWord() {
        // regex 含 [0-9] → 数字 token 算 1 word
        #expect(DiaryEntry.countWords(in: "test 123") == 2)
    }

    @Test func multipleWhitespace_collapsedByComponentsSeparated() {
        // components(separatedBy:) 会产生空 token,被 filter 掉
        #expect(DiaryEntry.countWords(in: "hello    world") == 2)
        #expect(DiaryEntry.countWords(in: "hello\n\n\nworld") == 2)
    }

    @Test func cjkAndLatinNoSeparator_stillSumsBothPaths() {
        // "中文hello中文" → cjk scalar 算 4,latin token 整串 "中文hello中文"
        // 含 [a-zA-Z] 算 1 latin word → 4 + 1 = 5
        // 锁住当前算法行为(sum 路径,不去重),后人改算法时这条会响。
        #expect(DiaryEntry.countWords(in: "中文hello中文") == 5)
    }
}

// MARK: - loadImageData 三层回退(local LumoryImages + legacy flat Documents)

/// 注意:`DiaryEntry.loadImageData` 用 `FileManager.default.urls(for: .documentDirectory, ...)`
/// —— 在 simulator/test 进程里这是真实 sandbox 路径。我们写到这里测完就清理,
/// 用 UUID 文件名隔离,不会撞已有用户图片。
/// iCloud 路径需要 ubiquity container,test 环境通常没配,自动跳过到 local 这一档,
/// 所以"local hit"测试是干净的。
struct LoadImageDataFallbackTests {

    private static func documentsDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func localImagesDir() -> URL {
        documentsDir().appendingPathComponent("LumoryImages")
    }

    /// 唯一文件名 + 自动清理 helper。每个 test 用独立 UUID 防止 NSCache 命中污染。
    private final class TestFixture {
        let fileName: String
        let payload: Data
        let writtenPaths: [URL]

        init(payload: Data = Data([0xDE, 0xAD, 0xBE, 0xEF]), writeTo paths: [URL] = []) throws {
            self.fileName = "test-\(UUID().uuidString).bin"
            self.payload = payload
            // 调用方传相对位置的 URL builder,我们这里把 fileName 拼上去再写
            var written: [URL] = []
            for dirURL in paths {
                if !FileManager.default.fileExists(atPath: dirURL.path) {
                    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                }
                let fileURL = dirURL.appendingPathComponent(self.fileName)
                try payload.write(to: fileURL)
                written.append(fileURL)
            }
            self.writtenPaths = written
        }

        deinit {
            for url in writtenPaths {
                try? FileManager.default.removeItem(at: url)
            }
            // 清 NSCache 残留(同 fileName 不会再被复用,但保险起见)
            DiaryEntry.clearImageCache()
        }
    }

    @Test func localLumoryImagesPathExists_returnsLocalData() throws {
        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let fixture = try TestFixture(
            payload: payload,
            writeTo: [Self.localImagesDir()]
        )
        let result = DiaryEntry.loadImageData(fileName: fixture.fileName)
        #expect(result == payload)
    }

    @Test func localMissing_legacyFlatDocumentsPresent_returnsLegacyData() throws {
        let payload = Data([0xAA, 0xBB, 0xCC])
        // 只写 legacy 扁平 Documents/ 位置(不写 LumoryImages/)
        let fixture = try TestFixture(
            payload: payload,
            writeTo: [Self.documentsDir()]
        )
        // sanity check:LumoryImages/ 下没这个文件
        let lumoryPath = Self.localImagesDir().appendingPathComponent(fixture.fileName).path
        #expect(!FileManager.default.fileExists(atPath: lumoryPath))

        let result = DiaryEntry.loadImageData(fileName: fixture.fileName)
        #expect(result == payload)
    }

    @Test func bothLocalAndLegacyMissing_returnsNil() {
        DiaryEntry.clearImageCache() // 防止其他 test 残留
        let absent = "absent-\(UUID().uuidString).bin"
        let result = DiaryEntry.loadImageData(fileName: absent)
        #expect(result == nil)
    }

    @Test func localPriorityOverLegacy_returnsLocalWhenBothExist() throws {
        // 文档行为:`loadImageData` 先查 iCloud,后查 LumoryImages/,最后查扁平 Documents/。
        // 锁定当 LumoryImages/ 和扁平 Documents/ 都存在时返 LumoryImages/(中间档优先)。
        let localPayload = Data([0x11, 0x22, 0x33])
        let legacyPayload = Data([0x99, 0x88, 0x77])
        let fileName = "priority-\(UUID().uuidString).bin"

        // 手写两份,共享 fileName
        let localDir = Self.localImagesDir()
        let docsDir = Self.documentsDir()
        if !FileManager.default.fileExists(atPath: localDir.path) {
            try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        }
        let localURL = localDir.appendingPathComponent(fileName)
        let legacyURL = docsDir.appendingPathComponent(fileName)
        try localPayload.write(to: localURL)
        try legacyPayload.write(to: legacyURL)
        defer {
            try? FileManager.default.removeItem(at: localURL)
            try? FileManager.default.removeItem(at: legacyURL)
            DiaryEntry.clearImageCache()
        }

        let result = DiaryEntry.loadImageData(fileName: fileName)
        #expect(result == localPayload, "LumoryImages/ 优先级高于扁平 Documents/")
    }
}
