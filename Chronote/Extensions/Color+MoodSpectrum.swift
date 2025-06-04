import SwiftUI

// MARK: - Color Interpolation Helper
extension Color {
    /// 心情光谱：红 → 粉 → 灰白（加宽）→ Baby 蓝 → 亮蓝
    static func moodSpectrum(value: Double) -> Color {
        let v = min(max(value, 0), 1)

        // 鲜艳端点
        let red       = (r: 1.00, g: 0.10, b: 0.10)   // 极消极
        let pink      = (r: 1.00, g: 0.40, b: 0.60)   // 消极
        let grayWhite = (r: 0.90, g: 0.90, b: 0.90)   // 中性
        let babyBlue  = (r: 0.60, g: 0.85, b: 1.00)   // 积极
        let blue      = (r: 0.20, g: 0.60, b: 1.00)   // 极积极

        switch v {
        case 0..<0.20:          // 红 → 粉
            let t = v / 0.20
            return Color(
                red:   red.r  * (1 - t) + pink.r  * t,
                green: red.g  * (1 - t) + pink.g  * t,
                blue:  red.b  * (1 - t) + pink.b  * t
            )

        case 0.20..<0.45:       // 粉 → 灰白
            let t = (v - 0.20) / 0.25
            return Color(
                red:   pink.r      * (1 - t) + grayWhite.r * t,
                green: pink.g      * (1 - t) + grayWhite.g * t,
                blue:  pink.b      * (1 - t) + grayWhite.b * t
            )

        case 0.45..<0.55:       // 中性灰白区（加宽 10%）
            return Color(
                red:   grayWhite.r,
                green: grayWhite.g,
                blue:  grayWhite.b
            )

        case 0.55..<0.80:       // 灰白 → Baby 蓝
            let t = (v - 0.55) / 0.25
            return Color(
                red:   grayWhite.r * (1 - t) + babyBlue.r * t,
                green: grayWhite.g * (1 - t) + babyBlue.g * t,
                blue:  grayWhite.b * (1 - t) + babyBlue.b * t
            )

        default:                // Baby 蓝 → 亮蓝
            let t = (v - 0.80) / 0.20
            return Color(
                red:   babyBlue.r * (1 - t) + blue.r * t,
                green: babyBlue.g * (1 - t) + blue.g * t,
                blue:  babyBlue.b * (1 - t) + blue.b * t
            )
        }
    }
    
    /// Convenience method for integer mood values (1-5)
    static func moodSpectrum(for intMood: Int) -> Color {
        let clampedMood = min(max(intMood, 1), 5)
        let value = Double(clampedMood - 1) / 4.0
        return moodSpectrum(value: value)
    }
} 