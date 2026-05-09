//
//  LumoryDateFormattersLanguageAwareTests.swift
//  ChronoteTests
//
//  P1 回归测:`LumoryDateFormatters` 5 个 language-aware accessor + 内部 cache。
//  覆盖:
//    - zh / en 切换格式正确
//    - cache 跨次调用稳定(同 language 同 key 拿同一 instance)
//    - 并发访问不 crash(防 NSLock 漏锁导致 dict race)
//    - 极端 date(distantPast / distantFuture)不 crash
//
//  **Side-effect 注意**:这些测试会改写真实 `AppGroup.userDefaults` 的 `appLanguage` key
//  来观测 accessor 行为,但 accessor 本身只接受 `language: String` 参数(不读 UserDefaults),
//  所以严格意义上**不需要** mutate UserDefaults。出于"未来可能改 accessor 自动读 AppStorage"
//  的防御性考虑,这里仍 setUp/tearDown save+restore 原值,不污染开发者机器 / 模拟器实际偏好。
//

import Testing
import Foundation
@testable import Lumory

// MARK: - Helpers

/// 2024-05-01 00:00:00 UTC = 1714521600。
/// 用 GMT 固定时间点避开本地 TZ 漂移;断言时给 formatter 显式 set TZ=UTC,
/// 否则在不同 CI 机器(美东 vs 北京)同一秒会落到不同日期。
private let fixedDate = Date(timeIntervalSince1970: 1714521600)

/// 给 formatter 锁 UTC,避免本地 TZ 把 5/1 的 string 渲染成 4/30。
private func lockUTC(_ f: DateFormatter) -> DateFormatter {
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}

// MARK: - Suite

@MainActor
struct LumoryDateFormattersLanguageAwareTests {
    /// 测试期间临时改 appLanguage 的安全包装 —— save / mutate / restore。
    /// `body` 内可任意 set 值,exit 时恢复原状(原本 nil → removeObject)。
    private func withAppLanguage<T>(_ value: String?, body: () throws -> T) rethrows -> T {
        let key = "appLanguage"
        let defaults = AppGroup.userDefaults
        let original = defaults.string(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        return try body()
    }

    // MARK: - monthDay(language:)

    @Test func monthDay_zhVsEn_differentFormat() {
        let zh = lockUTC(LumoryDateFormatters.monthDay(language: "zh-Hans"))
        let en = lockUTC(LumoryDateFormatters.monthDay(language: "en"))

        let zhString = zh.string(from: fixedDate)
        let enString = en.string(from: fixedDate)

        // zh-Hans:"5月1日"(MMMd 模板渲染)
        #expect(zhString.contains("月"), "zh monthDay should contain 月, got: \(zhString)")
        #expect(zhString.contains("5"), "zh monthDay should contain month number 5, got: \(zhString)")

        // en:"May 1"(Latin month name)
        #expect(enString.contains("May"), "en monthDay should contain May, got: \(enString)")

        // 两边内容必然不同 —— 哪怕 MMMd 模板渲染策略变了,zh / en 也不可能一样
        #expect(zhString != enString, "zh and en monthDay should differ; got both = \(zhString)")
    }

    // MARK: - weekdayFull(language:)

    @Test func weekdayFull_zhVsEn_differentText() {
        // 2024-05-01 = Wednesday
        let zh = lockUTC(LumoryDateFormatters.weekdayFull(language: "zh-Hans"))
        let en = lockUTC(LumoryDateFormatters.weekdayFull(language: "en"))

        let zhString = zh.string(from: fixedDate)
        let enString = en.string(from: fixedDate)

        // zh:"星期三"(EEEE 在 zh-Hans locale 下输出 星期X 全称)
        #expect(zhString.contains("星期") || zhString.contains("周"),
                "zh weekday should contain 星期 or 周, got: \(zhString)")
        #expect(zhString.contains("三"),
                "zh weekday for 2024-05-01 should contain 三 (Wednesday), got: \(zhString)")

        // en:"Wednesday"
        #expect(enString == "Wednesday",
                "en weekday for 2024-05-01 should be Wednesday, got: \(enString)")
    }

    // MARK: - dayNumber(language:)

    @Test func dayNumber_locale_consistency() {
        let zh = lockUTC(LumoryDateFormatters.dayNumber(language: "zh-Hans"))
        let en = lockUTC(LumoryDateFormatters.dayNumber(language: "en"))

        let zhString = zh.string(from: fixedDate)
        let enString = en.string(from: fixedDate)

        // 两边都应是 zero-padded "01" 阿拉伯数字
        #expect(zhString == "01", "zh dayNumber should be 01, got: \(zhString)")
        #expect(enString == "01", "en dayNumber should be 01, got: \(enString)")

        // 防御:某些 locale(如 ar-SA / fa-IR)会用本地数字系。
        // zh-Hans Locale 不会,但仍显式校验:string 应只含 ASCII 数字。
        for ch in zhString {
            #expect(ch.isASCII && ch.isNumber, "zh dayNumber char \(ch) should be ASCII digit")
        }
    }

    // MARK: - monthShortLocalized(language:)

    @Test func monthShortLocalized_zhVsEn_differentFormat() {
        let zh = lockUTC(LumoryDateFormatters.monthShortLocalized(language: "zh-Hans"))
        let en = lockUTC(LumoryDateFormatters.monthShortLocalized(language: "en"))

        let zhString = zh.string(from: fixedDate)
        let enString = en.string(from: fixedDate)

        // zh-Hans MMM 渲染为 "5月"
        #expect(zhString.contains("月"), "zh monthShort should contain 月, got: \(zhString)")
        // en MMM 渲染为 "May"
        #expect(enString == "May", "en monthShort should be May, got: \(enString)")
    }

    // MARK: - timeShortLocalized(language:)

    @Test func timeShortLocalized_zhVsEn_differentFormat() {
        let zh = lockUTC(LumoryDateFormatters.timeShortLocalized(language: "zh-Hans"))
        let en = lockUTC(LumoryDateFormatters.timeShortLocalized(language: "en"))

        // 用一个明确 AM 的时间点:2024-05-01 09:30:00 UTC
        let amDate = Date(timeIntervalSince1970: 1714555800)
        let zhString = zh.string(from: amDate)
        let enString = en.string(from: amDate)

        // 两边都该有 9 / 30 数字
        #expect(zhString.contains("9"), "zh timeShort should contain 9, got: \(zhString)")
        #expect(zhString.contains("30"), "zh timeShort should contain 30, got: \(zhString)")
        #expect(enString.contains("9"), "en timeShort should contain 9, got: \(enString)")
        #expect(enString.contains("30"), "en timeShort should contain 30, got: \(enString)")

        // en 必须含 AM/PM 标识(.short timeStyle 在 en_US 下默认 12-hour)
        let upper = enString.uppercased()
        #expect(upper.contains("AM") || upper.contains("PM"),
                "en timeShort should contain AM/PM, got: \(enString)")
    }

    // MARK: - Cache identity(同 language 同 accessor 跨次拿同实例)

    @Test func cachedFormatter_returnsSameInstance_acrossCalls() {
        // DateFormatter 是 NSObject(class),`===` 可观测引用相等。
        let a1 = LumoryDateFormatters.monthDay(language: "zh-Hans")
        let a2 = LumoryDateFormatters.monthDay(language: "zh-Hans")
        #expect(a1 === a2, "monthDay(zh) cache should return same instance")

        let b1 = LumoryDateFormatters.weekdayFull(language: "en")
        let b2 = LumoryDateFormatters.weekdayFull(language: "en")
        #expect(b1 === b2, "weekdayFull(en) cache should return same instance")

        let c1 = LumoryDateFormatters.dayNumber(language: "zh-Hans")
        let c2 = LumoryDateFormatters.dayNumber(language: "zh-Hans")
        #expect(c1 === c2, "dayNumber(zh) cache should return same instance")

        let d1 = LumoryDateFormatters.monthShortLocalized(language: "en")
        let d2 = LumoryDateFormatters.monthShortLocalized(language: "en")
        #expect(d1 === d2, "monthShortLocalized(en) cache should return same instance")

        let e1 = LumoryDateFormatters.timeShortLocalized(language: "zh-Hans")
        let e2 = LumoryDateFormatters.timeShortLocalized(language: "zh-Hans")
        #expect(e1 === e2, "timeShortLocalized(zh) cache should return same instance")
    }

    @Test func cachedFormatter_differentLanguages_returnDifferentInstances() {
        let zh = LumoryDateFormatters.monthDay(language: "zh-Hans")
        let en = LumoryDateFormatters.monthDay(language: "en")
        #expect(zh !== en, "monthDay(zh) and monthDay(en) must be different cache entries")
    }

    @Test func cachedFormatter_differentAccessors_returnDifferentInstances() {
        // monthDay(zh) vs weekdayFull(zh) 使用不同的 cache key (前缀不同)
        let monthDay = LumoryDateFormatters.monthDay(language: "zh-Hans")
        let weekdayFull = LumoryDateFormatters.weekdayFull(language: "zh-Hans")
        #expect(monthDay !== weekdayFull, "monthDay and weekdayFull should be different cache entries")
    }

    // MARK: - 并发访问

    @Test func concurrentAccess_doesNotCrash() {
        // `concurrentPerform` 在多个 worker thread 并行调用 accessor,
        // 触发 cache dict 读写竞争。NSLock 漏锁会 crash(EXC_BAD_ACCESS / Swift dict mutation race)。
        let iterations = 200
        let collected = NSLock()
        var results: [String] = []

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            // 交错 5 个 accessor + 2 种 language,最大化锁竞争
            let language = (i % 2 == 0) ? "zh-Hans" : "en"
            let formatter: DateFormatter
            switch i % 5 {
            case 0: formatter = LumoryDateFormatters.monthDay(language: language)
            case 1: formatter = LumoryDateFormatters.weekdayFull(language: language)
            case 2: formatter = LumoryDateFormatters.dayNumber(language: language)
            case 3: formatter = LumoryDateFormatters.monthShortLocalized(language: language)
            default: formatter = LumoryDateFormatters.timeShortLocalized(language: language)
            }

            // formatter 读自身设置 + 调 string(from:) 也是 race 入口
            // (DateFormatter since iOS 7 自身 thread-safe,但 cache lookup 路径才是测试目标)
            let _ = formatter.string(from: fixedDate)

            collected.lock()
            results.append("ok-\(i)")
            collected.unlock()
        }

        #expect(results.count == iterations,
                "All concurrent calls should complete; got \(results.count) of \(iterations)")
    }

    @Test func concurrentAccess_outputsAreConsistent() {
        // 跨线程调同一 (accessor, language) 必须输出一致 string
        // —— 防 cache 在 race 中返回半构造的 formatter(缺 locale / 缺 dateFormat)。
        let iterations = 100
        let collector = NSLock()
        var outputs: Set<String> = []

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let f = LumoryDateFormatters.weekdayFull(language: "en")
            let s = f.string(from: fixedDate)
            collector.lock()
            outputs.insert(s)
            collector.unlock()
        }

        #expect(outputs.count == 1,
                "All concurrent calls should produce identical output; got distinct: \(outputs)")
        #expect(outputs.first == "Wednesday",
                "Concurrent weekdayFull(en) should be Wednesday, got: \(outputs)")
    }

    // MARK: - 极端 date

    @Test func distantPast_doesNotCrash() {
        // distantPast 通常 ~ 0001-01-01;某些 calendar 边缘可能炸,但 Gregorian + DateFormatter 不该。
        let f = lockUTC(LumoryDateFormatters.monthDay(language: "en"))
        let s = f.string(from: Date.distantPast)
        #expect(!s.isEmpty, "monthDay(distantPast) should produce non-empty string, got: \(s)")
    }

    @Test func distantFuture_doesNotCrash() {
        let f = lockUTC(LumoryDateFormatters.weekdayFull(language: "en"))
        let s = f.string(from: Date.distantFuture)
        #expect(!s.isEmpty, "weekdayFull(distantFuture) should produce non-empty string, got: \(s)")
    }

    @Test func unknownLanguage_fallsBackGracefully() {
        // 用一个不存在的 BCP-47 tag,Locale 会返回一个 root-ish locale。
        // 不该 crash,且应给出 non-empty 字符串。
        let f = lockUTC(LumoryDateFormatters.monthDay(language: "xx-XX-bogus"))
        let s = f.string(from: fixedDate)
        #expect(!s.isEmpty, "monthDay(unknown language) should not be empty, got: \(s)")
    }

    // MARK: - appLanguage UserDefaults 切换 / restore 路径(防 future regression)

    @Test func appLanguageUserDefaultsSwap_doesNotImpactPureAccessor() {
        // 当前 accessor 签名是 `language: String`,**不**读 UserDefaults。
        // 这条测试锁住该不变量:即便 UserDefaults 变了,显式传 "en" 仍输出英文。
        // 如果未来重构成读 UserDefaults,这条测会坏 —— 提醒重新对齐 caller。
        withAppLanguage("zh-Hans") {
            let f = lockUTC(LumoryDateFormatters.weekdayFull(language: "en"))
            let s = f.string(from: fixedDate)
            #expect(s == "Wednesday",
                    "Pure accessor should ignore appLanguage UserDefaults; got: \(s)")
        }
    }
}
