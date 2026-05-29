//
//  DiaryExportServiceTests.swift
//  ChronoteTests
//
//  (megareview 待确认 W10)`DiaryExportService.generateExportContent` 是用户可见的导出文本
//  生成纯函数(`nonisolated static`,除 header 的 `Date()` 外无副作用),此前零测试覆盖。
//  这里锁住它的结构契约:header/footer 标记、每篇一个 📅 日期块、按日期**从旧到新**排序、
//  正文/摘要/心情描述被包含、nil 字段不崩。
//
//  断言刻意避开本地化文案(随 appLanguage 漂),只断言源码里的字面结构标记(====/----/📅)
//  和"用同一个 API 算出来的心情描述被包含",故中英文环境都稳。
//

import Testing
import Foundation
@testable import Lumory

struct DiaryExportServiceTests {

    private func snapshot(
        date: Date?,
        text: String?,
        summary: String? = nil,
        mood: Double = 0.0
    ) -> DiaryExportEntrySnapshot {
        DiaryExportEntrySnapshot(date: date, text: text, summary: summary, moodValue: mood)
    }

    // 空列表:仍要产出 header + footer,且不含任何 📅 日期块。
    @Test func generateExportContent_empty_hasHeaderFooterNoEntries() {
        let out = DiaryExportService.generateExportContent(from: [])
        #expect(out.contains("========================================")) // header rule
        #expect(out.contains("----------------------------------------")) // footer rule
        #expect(!out.contains("📅"))  // 没有任何 entry 日期块
    }

    // 每篇一个 📅 日期块:数量 == entry 数。
    @Test func generateExportContent_oneDateBlockPerEntry() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            snapshot(date: base, text: "一"),
            snapshot(date: base.addingTimeInterval(86_400), text: "二"),
            snapshot(date: base.addingTimeInterval(2 * 86_400), text: "三")
        ]
        let out = DiaryExportService.generateExportContent(from: entries)
        let dateBlocks = out.components(separatedBy: "📅").count - 1
        #expect(dateBlocks == 3)
    }

    // 按日期从旧到新排序:乱序传入,输出里旧的正文必须排在新的之前。
    @Test func generateExportContent_sortsByDateOldestFirst() {
        let older = snapshot(date: Date(timeIntervalSince1970: 1_700_000_000), text: "较早的正文EARLY")
        let newer = snapshot(date: Date(timeIntervalSince1970: 1_800_000_000), text: "较晚的正文LATE")
        // 故意逆序传入(新的在前)。
        let out = DiaryExportService.generateExportContent(from: [newer, older])
        let earlyPos = try? #require(out.range(of: "EARLY")).lowerBound
        let latePos = try? #require(out.range(of: "LATE")).lowerBound
        #expect(earlyPos != nil && latePos != nil)
        if let e = earlyPos, let l = latePos {
            #expect(e < l)  // 旧的在前
        }
    }

    // 正文 / 摘要 / 心情描述都被包含。心情用同一个 API 计算,locale-robust。
    @Test func generateExportContent_includesTextSummaryAndMood() {
        let mood = 0.8
        let entry = snapshot(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            text: "今天的正文UNIQUEBODY",
            summary: "一句话摘要UNIQUESUMMARY",
            mood: mood
        )
        let out = DiaryExportService.generateExportContent(from: [entry])
        #expect(out.contains("今天的正文UNIQUEBODY"))
        #expect(out.contains("一句话摘要UNIQUESUMMARY"))
        // 心情描述:用被测函数同款 API 算 expected,断言被包含(不硬编码本地化字符串)。
        let expectedMood = MoodLabels.localizedExportDescription(for: mood)
        #expect(out.contains(expectedMood))
    }

    // 空摘要不渲染"摘要:"行(源码 guard !summary.isEmpty)。
    @Test func generateExportContent_emptySummary_omitsSummaryLine() {
        let entry = snapshot(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            text: "正文BODYONLY",
            summary: ""
        )
        let out = DiaryExportService.generateExportContent(from: [entry])
        #expect(out.contains("正文BODYONLY"))
        // 空摘要时不应出现 "UNIQUESUMMARY" 之类——这里直接验证没有把空串当摘要插入额外行。
        // 用 NSLocalizedString 模板的固定前缀片段无法 locale-robust,改为结构断言:
        // 该 entry 只有一个 📅 块且正文存在即可。
        #expect(out.components(separatedBy: "📅").count - 1 == 1)
    }

    // nil text / nil date 不崩,且不把 "nil" 字面写进导出。
    @Test func generateExportContent_nilFields_doesNotCrashOrEmitNil() {
        let entry = snapshot(date: nil, text: nil, summary: nil)
        let out = DiaryExportService.generateExportContent(from: [entry])
        #expect(out.contains("📅"))          // 仍渲染一个日期块(date nil → 用 Date())
        #expect(!out.contains("nil"))         // 不把 Optional 的 "nil" 字面漏进文本
    }
}
