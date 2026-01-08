import SwiftUI

// MARK: - Color Interpolation Helper
extension Color {
    /// 心情光谱：红 → 粉 → 灰白（加宽）→ Baby 蓝 → 亮蓝
    static func moodSpectrum(value: Double) -> Color {
        let v = min(max(value, 0), 1)

        // 更加通透、液态的配色方案
        let red       = (r: 1.00, g: 0.25, b: 0.25)   // 剔透红
        let pink      = (r: 1.00, g: 0.50, b: 0.70)   // 柔光粉
        let neutral   = (r: 0.92, g: 0.92, b: 0.95)   // 玻璃灰白
        let cyan      = (r: 0.40, g: 0.80, b: 0.95)   // 冰川蓝
        let blue      = (r: 0.10, g: 0.50, b: 1.00)   // 深海蓝

        switch v {
        case 0..<0.25:          // 红 → 粉
            let t = v / 0.25
            return Color(
                red:   red.r  * (1 - t) + pink.r  * t,
                green: red.g  * (1 - t) + pink.g  * t,
                blue:  red.b  * (1 - t) + pink.b  * t
            )

        case 0.25..<0.45:       // 粉 → 灰白
            let t = (v - 0.25) / 0.20
            return Color(
                red:   pink.r      * (1 - t) + neutral.r * t,
                green: pink.g      * (1 - t) + neutral.g * t,
                blue:  pink.b      * (1 - t) + neutral.b * t
            )

        case 0.45..<0.55:       // 中性区
            return Color(
                red:   neutral.r,
                green: neutral.g,
                blue:  neutral.b
            )

        case 0.55..<0.75:       // 灰白 → 冰川蓝
            let t = (v - 0.55) / 0.20
            return Color(
                red:   neutral.r * (1 - t) + cyan.r * t,
                green: neutral.g * (1 - t) + cyan.g * t,
                blue:  neutral.b * (1 - t) + cyan.b * t
            )

        default:                // 冰川蓝 → 深海蓝
            let t = (v - 0.75) / 0.25
            return Color(
                red:   cyan.r * (1 - t) + blue.r * t,
                green: cyan.g * (1 - t) + blue.g * t,
                blue:  cyan.b * (1 - t) + blue.b * t
            )
        }
    }
    
    /// Convenience method for integer mood values (1-5)
    static func moodSpectrum(for intMood: Int) -> Color {
        let clampedMood = min(max(intMood, 1), 5)
        let value = Double(clampedMood - 1) / 4.0
        return moodSpectrum(value: value)
    }

    /// Convert discrete 5-level mood (0-4) to continuous value (0.0-1.0)
    static func discreteMoodValue(from level: Int) -> Double {
        let clamped = min(max(level, 0), 4)
        return Double(clamped) * 0.25
    }

    /// Get mood level (0-4) from continuous value (0.0-1.0)
    static func moodLevel(from value: Double) -> Int {
        return Int(round(value * 4))
    }
} 