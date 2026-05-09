//
//  LegacyDiaryEntryCompatibilityTests.swift
//  ChronoteTests
//
//  ────────────────────────────────────────────────────────────────────────────
//  契约锁:LegacyDiaryEntry V2 JSON 反序列化容错路径
//  ────────────────────────────────────────────────────────────────────────────
//
//  LegacyDiaryEntry 是 v2 JSON → CoreData 一次性迁移的源模型(见
//  `DataMigrationService.performMigrationIfNeeded`)。不同 v2 schema 版本写出
//  的字段集略有不同(早期用 `mood: String` 老格式,后期用 `moodValue: Double`
//  连续值),所以容错是真用户场景,不是 hypothetical edge case。
//
//  这组测试锁住实际实现(`Chronote/Model/LegacyDiaryEntry.swift`):
//
//    必需字段(missing 即 throw):
//      - date  · text
//
//    容错字段(missing 时有默认值):
//      - id           → 新 UUID
//      - summary      → nil
//      - audioFileName→ nil
//      - moodValue    → fallback 链:
//                       1) `moodValue: Double` 直接采用
//                       2) `mood: String` 映射 great/good/neutral/bad/terrible
//                          → 1.0 / 0.75 / 0.5 / 0.25 / 0.0
//                       3) unknown mood string → 0.5
//                       4) 两个都缺 → 0.5
//
//    对象不存在的字段(顺手锁住,防 future schema 误加进 LegacyDiaryEntry):
//      - themes / imageFileNames / wordCount / embedding —— 这些是 CoreData
//        `DiaryEntry` 的字段,**不在** LegacyDiaryEntry 上。v2 JSON 老用户没有
//        这些数据,迁移后由 `*BackfillService` 派生。新加这些 field 之前请确认
//        v2 历史 JSON 真的写过该字段,否则徒增 schema 表面积。
//

import Testing
import Foundation
@testable import Lumory

// MARK: - Helpers

private func makeJSON(_ fields: [String: String]) -> Data {
    // 手拼 JSON 而不是 JSONEncoder —— 我们要精确控制哪些 key 存在,
    // JSONEncoder 会把 nil 编成 `"key": null` 而不是省略 key。
    let body = fields
        .map { "\"\($0.key)\": \($0.value)" }
        .joined(separator: ",")
    return "{\(body)}".data(using: .utf8)!
}

/// 固定时间戳(ISO8601 epoch),所有 happy-path 测试共用,
/// 让断言 `entry.date == referenceDate` 不依赖系统时钟。
private let referenceDateISO = "\"2026-01-15T08:30:00Z\""
private var referenceDate: Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: "2026-01-15T08:30:00Z")!
}

private func makeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}

// MARK: - Suite

struct LegacyDiaryEntryCompatibilityTests {

    // MARK: 必需字段

    @Test func decode_completeV2JSON_allFieldsPresent() throws {
        let id = UUID()
        let json = makeJSON([
            "id": "\"\(id.uuidString)\"",
            "date": referenceDateISO,
            "text": "\"今天天气不错\"",
            "summary": "\"晴天散步\"",
            "moodValue": "0.82",
            "audioFileName": "\"voice-001.m4a\""
        ])

        let entry = try makeDecoder().decode(LegacyDiaryEntry.self, from: json)

        #expect(entry.id == id)
        #expect(entry.date == referenceDate)
        #expect(entry.text == "今天天气不错")
        #expect(entry.summary == "晴天散步")
        #expect(entry.moodValue == 0.82)
        #expect(entry.audioFileName == "voice-001.m4a")
    }

    @Test func decode_missingDate_throws() {
        // date 是 `try container.decode(Date.self)` 必需字段,缺失即抛
        // keyNotFound,锁住契约。如果未来要给 date 加默认值(eg 当前时间),
        // 这条测试要主动改 —— 这是有意识的契约决定,不是 silent regression。
        let json = makeJSON([
            "text": "\"无日期\"",
            "moodValue": "0.5"
        ])

        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(LegacyDiaryEntry.self, from: json)
        }
    }

    @Test func decode_missingText_throws() {
        // text 同理 —— 必需字段,缺失即抛。
        let json = makeJSON([
            "date": referenceDateISO,
            "moodValue": "0.5"
        ])

        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(LegacyDiaryEntry.self, from: json)
        }
    }

    // MARK: id 容错

    @Test func decode_missingId_generatesFreshUUID() throws {
        let json = makeJSON([
            "date": referenceDateISO,
            "text": "\"匿名条目\"",
            "moodValue": "0.5"
        ])

        let a = try makeDecoder().decode(LegacyDiaryEntry.self, from: json)
        let b = try makeDecoder().decode(LegacyDiaryEntry.self, from: json)

        // 两次 decode 必须给两个不同 UUID(每次 decode 走 UUID()),
        // 否则迁移把多条无 id 的 entry 全塞同一个 objectID 会撞库。
        #expect(a.id != b.id)
        #expect(a.text == "匿名条目")
    }

    // MARK: moodValue 三档容错链

    @Test func decode_missingMoodValueWithLegacyMoodString_mapsCorrectly() throws {
        // 老 v2 schema 用 `mood: String`,需映射到连续值。
        // 锁住完整映射表 —— 任何一档变了 backfill 后用户的历史心情会跑偏。
        struct Case { let mood: String; let expected: Double }
        let cases: [Case] = [
            .init(mood: "great",    expected: 1.0),
            .init(mood: "good",     expected: 0.75),
            .init(mood: "neutral",  expected: 0.5),
            .init(mood: "bad",      expected: 0.25),
            .init(mood: "terrible", expected: 0.0)
        ]

        for c in cases {
            let json = makeJSON([
                "date": referenceDateISO,
                "text": "\"测试\"",
                "mood": "\"\(c.mood)\""
            ])
            let entry = try makeDecoder().decode(LegacyDiaryEntry.self, from: json)
            #expect(entry.moodValue == c.expected, "mood=\(c.mood) 应映射到 \(c.expected),实得 \(entry.moodValue)")
        }
    }

    @Test func decode_unknownMoodString_defaultsToHalf() throws {
        // 老 schema 里出现没在映射表里的字符串(eg typo / 实验枚举),
        // 不能让整个迁移崩,默认到中性 0.5 是更安全的退化。
        let json = makeJSON([
            "date": referenceDateISO,
            "text": "\"拼错了 mood\"",
            "mood": "\"meh\""
        ])

        let entry = try makeDecoder().decode(LegacyDiaryEntry.self, from: json)
        #expect(entry.moodValue == 0.5)
    }

    @Test func decode_missingBothMoodFields_defaultsToHalf() throws {
        // moodValue / mood 都缺 → 0.5 中性默认。
        // 防止迁移时心情图直接出 NaN 或全部红色低值。
        let json = makeJSON([
            "date": referenceDateISO,
            "text": "\"无心情字段\""
        ])

        let entry = try makeDecoder().decode(LegacyDiaryEntry.self, from: json)
        #expect(entry.moodValue == 0.5)
    }

    @Test func decode_moodValueTakesPrecedenceOverLegacyMood() throws {
        // 同一条 JSON 同时有 moodValue + mood —— 新字段优先。
        // 这条对应混合迁移期(用户 App 写过 v2.0 老格式,后又升级 v2.5
        // 同时存了新字段),不能让旧 mood string 反向覆盖新 0-1 值。
        let json = makeJSON([
            "date": referenceDateISO,
            "text": "\"双字段\"",
            "moodValue": "0.9",
            "mood": "\"terrible\""  // 0.0,if leaks 会和 0.9 完全相反
        ])

        let entry = try makeDecoder().decode(LegacyDiaryEntry.self, from: json)
        #expect(entry.moodValue == 0.9)
    }

    // MARK: 可选字段容错

    @Test func decode_missingSummary_defaultsToNil() throws {
        let json = makeJSON([
            "date": referenceDateISO,
            "text": "\"无 summary\"",
            "moodValue": "0.5"
        ])

        let entry = try makeDecoder().decode(LegacyDiaryEntry.self, from: json)
        #expect(entry.summary == nil)
    }

    @Test func decode_missingAudioFileName_defaultsToNil() throws {
        let json = makeJSON([
            "date": referenceDateISO,
            "text": "\"无录音\"",
            "moodValue": "0.5"
        ])

        let entry = try makeDecoder().decode(LegacyDiaryEntry.self, from: json)
        #expect(entry.audioFileName == nil)
    }

    @Test func decode_explicitNullSummaryAndAudio_decodesAsNil() throws {
        // JSON 显式写 `null` (而不是 missing) 也要走 decodeIfPresent 路径。
        // 不同 JSON 序列化器的行为分歧:Foundation JSONEncoder 默认不写 null,
        // 但用户从外部工具/旧版本 App 导出的 v2 JSON 可能含 explicit null。
        let raw = """
        {
            "date": \(referenceDateISO),
            "text": "explicit nulls",
            "summary": null,
            "audioFileName": null,
            "moodValue": 0.5
        }
        """.data(using: .utf8)!

        let entry = try makeDecoder().decode(LegacyDiaryEntry.self, from: raw)
        #expect(entry.summary == nil)
        #expect(entry.audioFileName == nil)
    }

    // MARK: 未知字段宽容

    @Test func decode_extraUnknownField_decodesIgnoringIt() throws {
        // future v3 / 实验性 schema 多塞字段不应炸迁移 —— Swift 的
        // keyedBy: CodingKeys 自动忽略 enum 没列的 key。
        // 这条同时锁住 LegacyDiaryEntry **不**会偷偷加上 themes/imageFileNames
        // 字段 —— 那是 CoreData DiaryEntry 的事(由 backfill 派生)。
        let raw = """
        {
            "id": "\(UUID().uuidString)",
            "date": \(referenceDateISO),
            "text": "包含未知字段",
            "moodValue": 0.6,
            "themes": ["未来字段"],
            "imageFileNames": ["a.jpg"],
            "embedding": [0.1, 0.2],
            "wordCount": 42,
            "experimentalFlag": true
        }
        """.data(using: .utf8)!

        let entry = try makeDecoder().decode(LegacyDiaryEntry.self, from: raw)
        #expect(entry.text == "包含未知字段")
        #expect(entry.moodValue == 0.6)
    }

    // MARK: id 类型校验

    @Test func decode_malformedId_throws() {
        // id 字段如果不是合法 UUID 字符串(eg 老导出工具写成 "1" / 纯数字),
        // 走 decodeIfPresent → 解码失败应该抛,不能 silently fallback。
        // 锁住 "格式错的 id 不会被静默换成 fresh UUID 丢失原始引用"。
        let raw = """
        {
            "id": "not-a-uuid",
            "date": \(referenceDateISO),
            "text": "bad id",
            "moodValue": 0.5
        }
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(LegacyDiaryEntry.self, from: raw)
        }
    }
}
