import SwiftUI

// 复制自 Chronote/Extensions/Color+MoodSpectrum.swift。
// 故意不挂主 App `Chronote/Extensions/` 给 widget target —— 否则要把整个 CoreData stack 也带上,
// widget binary 会被撑大。这是稳定算法,跟主 App drift 概率低;真要改一起改两边。
extension Color {
    static func moodSpectrum(value: Double) -> Color {
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
}
