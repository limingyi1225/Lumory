//
//  MoodSpectrumParityTests.swift
//  ChronoteTests
//
//  ────────────────────────────────────────────────────────────────────────────
//  ⚠️ 主 App ↔ widget extension 心情色谱算法漂移 invariant 锁
//  ────────────────────────────────────────────────────────────────────────────
//
//  锁住三方一致:
//    [A] 主 App   `Chronote/Extensions/Color+MoodSpectrum.swift` 的 `Color.moodSpectrum(value:)`
//    [B] Widget   `LumoryWidgets/MoodColor.swift`                的 `Color.moodSpectrum(value:)`
//    [C] 本文件下方 `widgetMoodSpectrumReference(value:)` 的复刻
//
//  为什么需要 [C] 这个 reference:
//    test target 是 `ChronoteTests`,只链接主 App `Lumory` module。
//    Widget extension target (`LumoryWidgets`) 不能被 test target 链接 ——
//    `@testable import LumoryWidgets` 不可行。所以测试无法直接拿到 [B] 的实
//    现做对比,只能在测试文件里手抄一份 ground-truth reference [C],跟主 App
//    [A] 比对。
//
//  这就形成一个"看似松、实则紧"的三角:
//    - [C] 是 [B] 的逐行 copy(commit 时强制对齐)。
//    - 测试断言 `[A] == [C]`,语义上等同 `[A] == [B]`(只要 [C] 跟 [B] 同步)。
//    - 单 commit 改 [B] 不改 [A]:[B] != [A] = silent regression(本测试发现不
//      到,但 CLAUDE.md 已锁"必须同步改两边",code review 会抓)。
//    - 单 commit 改 [B] + [C] 不改 [A]:测试立即红 —— 因为 [C] 跟 [A] 不一
//      致了。修法是同步改 [A]。
//    - 单 commit 改 [A] 不改 [B] / [C]:测试立即红。修法是同步改 [B] + [C]。
//
//  所以**只要写代码的人在改 [B] 时记得同步改 [C](跟 CLAUDE.md "必须同步
//  改两边"是同一条肌肉记忆),三方就锁死**。这条注释就是给那个时刻的提醒。
//
//  改色谱时**必须同步改三个文件**:
//    1. Chronote/Extensions/Color+MoodSpectrum.swift  (主 App)
//    2. LumoryWidgets/MoodColor.swift                  (widget extension)
//    3. ChronoteTests/MoodSpectrumParityTests.swift    (本文件 reference + 期望值)
//

import Testing
import SwiftUI
import UIKit
@testable import Lumory

// MARK: - Widget reference (手抄自 LumoryWidgets/MoodColor.swift,见顶部注释)

/// 与 widget extension `Color.moodSpectrum(value:)` 完全等价的纯函数复刻。
/// 改 widget 算法时必须同步改这里 —— 见文件顶部 invariant 注释。
private func widgetMoodSpectrumReference(value: Double) -> Color {
    let clampedValue = min(max(value, 0), 1)
    let red       = (r: 1.00, g: 0.25, b: 0.25)
    let pink      = (r: 1.00, g: 0.50, b: 0.70)
    let neutral   = (r: 0.92, g: 0.92, b: 0.95)
    let cyan      = (r: 0.40, g: 0.80, b: 0.95)
    let blue      = (r: 0.10, g: 0.50, b: 1.00)

    switch clampedValue {
    case 0..<0.25:
        let t = clampedValue / 0.25
        return Color(
            red: red.r * (1 - t) + pink.r * t,
            green: red.g * (1 - t) + pink.g * t,
            blue: red.b * (1 - t) + pink.b * t
        )
    case 0.25..<0.45:
        let t = (clampedValue - 0.25) / 0.20
        return Color(
            red: pink.r * (1 - t) + neutral.r * t,
            green: pink.g * (1 - t) + neutral.g * t,
            blue: pink.b * (1 - t) + neutral.b * t
        )
    case 0.45..<0.55:
        return Color(red: neutral.r, green: neutral.g, blue: neutral.b)
    case 0.55..<0.75:
        let t = (clampedValue - 0.55) / 0.20
        return Color(
            red: neutral.r * (1 - t) + cyan.r * t,
            green: neutral.g * (1 - t) + cyan.g * t,
            blue: neutral.b * (1 - t) + cyan.b * t
        )
    default:
        let t = (clampedValue - 0.75) / 0.25
        return Color(
            red: cyan.r * (1 - t) + blue.r * t,
            green: cyan.g * (1 - t) + blue.g * t,
            blue: cyan.b * (1 - t) + blue.b * t
        )
    }
}

// MARK: - RGBA 抽取 helper

private struct RGBA: Equatable {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat
    let a: CGFloat
}

/// 把 SwiftUI `Color` 转成 sRGB 通道值。`UIColor(_:)` bridge + `getRed(...)`
/// 即便 source `Color` 不是 sRGB-init 出来的也会做色彩空间转换,这里 `Color`
/// 都是 `init(red:green:blue:)` 直构出来的(默认 sRGB-non-linear),来回转换无损。
private func extractRGBA(_ color: Color) -> RGBA {
    let ui = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    let ok = ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    // getRed 在转换失败的色彩空间(grayscale/pattern)上会返 false。我们这里
    // 全是 sRGB 三色构造,不应该失败 —— 失败就让测试硬挂,而不是返默认 0。
    precondition(ok, "UIColor.getRed failed — Color expected to be sRGB-convertible")
    return RGBA(r: r, g: g, b: b, a: a)
}

private let epsilon: CGFloat = 1e-4

private func assertParity(at value: Double, sourceLocation: SourceLocation = #_sourceLocation) {
    let main = extractRGBA(Color.moodSpectrum(value: value))
    let ref  = extractRGBA(widgetMoodSpectrumReference(value: value))
    #expect(abs(main.r - ref.r) < epsilon,
            "red channel drift at value=\(value): main=\(main.r) ref=\(ref.r)",
            sourceLocation: sourceLocation)
    #expect(abs(main.g - ref.g) < epsilon,
            "green channel drift at value=\(value): main=\(main.g) ref=\(ref.g)",
            sourceLocation: sourceLocation)
    #expect(abs(main.b - ref.b) < epsilon,
            "blue channel drift at value=\(value): main=\(main.b) ref=\(ref.b)",
            sourceLocation: sourceLocation)
    #expect(abs(main.a - ref.a) < epsilon,
            "alpha channel drift at value=\(value): main=\(main.a) ref=\(ref.a)",
            sourceLocation: sourceLocation)
}

// MARK: - Tests

/// 主 App `Color.moodSpectrum(value:)` 与 widget extension `Color.moodSpectrum(value:)`
/// 在采样点 + clamp 边界的 RGB 通道完全一致(epsilon=1e-4)。
struct MoodSpectrumParityTests {

    // MARK: 段端点(段切换/边界条件)

    @Test func parity_at_lowerBound_0() {
        assertParity(at: 0.0)
    }

    @Test func parity_inside_redToPink_0_10() {
        assertParity(at: 0.10)
    }

    @Test func parity_just_below_segmentBoundary_0_24() {
        assertParity(at: 0.24)
    }

    @Test func parity_at_segmentBoundary_0_25() {
        assertParity(at: 0.25)
    }

    @Test func parity_just_above_segmentBoundary_0_26() {
        assertParity(at: 0.26)
    }

    @Test func parity_just_below_neutralEnter_0_44() {
        assertParity(at: 0.44)
    }

    @Test func parity_at_neutralEnter_0_45() {
        assertParity(at: 0.45)
    }

    @Test func parity_at_neutralExit_0_55() {
        assertParity(at: 0.55)
    }

    @Test func parity_just_below_cyanBoundary_0_74() {
        assertParity(at: 0.74)
    }

    @Test func parity_at_cyanBoundary_0_75() {
        assertParity(at: 0.75)
    }

    @Test func parity_near_upperBound_0_99() {
        assertParity(at: 0.99)
    }

    @Test func parity_at_upperBound_1() {
        assertParity(at: 1.0)
    }

    // MARK: Clamp 边界

    @Test func parity_clampsBelowZero() {
        assertParity(at: -0.5)
    }

    @Test func parity_clampsAboveOne() {
        assertParity(at: 1.5)
    }

    /// Clamp 之后 -0.5 必须等同于 0.0,1.5 必须等同于 1.0(锁住 clamp 行为本身)。
    @Test func clampedValuesEqualBoundaryValues() {
        let belowZero = extractRGBA(Color.moodSpectrum(value: -0.5))
        let atZero    = extractRGBA(Color.moodSpectrum(value: 0.0))
        #expect(abs(belowZero.r - atZero.r) < epsilon)
        #expect(abs(belowZero.g - atZero.g) < epsilon)
        #expect(abs(belowZero.b - atZero.b) < epsilon)

        let aboveOne = extractRGBA(Color.moodSpectrum(value: 1.5))
        let atOne    = extractRGBA(Color.moodSpectrum(value: 1.0))
        #expect(abs(aboveOne.r - atOne.r) < epsilon)
        #expect(abs(aboveOne.g - atOne.g) < epsilon)
        #expect(abs(aboveOne.b - atOne.b) < epsilon)
    }
}
