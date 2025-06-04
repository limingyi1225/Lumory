import SwiftUI
import CoreData

// MARK: - Core Data DiaryEntry 扩展
extension DiaryEntry {
    /// 获取显示文本（用于列表展示）
    var displayText: String {
        let raw = summary ?? String(text.prefix(30)) + "..."
        // 过滤掉句号、星号和引号
        let filtered = raw
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "\"", with: "")
        return filtered
    }
    
    /// 包装器属性，避免强制解包
    var wrappedText: String {
        text  // 如果 text 不是可选的，直接返回
    }
    
    var wrappedDate: Date {
        date  // 如果 date 不是可选的，直接返回
    }
    
    var wrappedSummary: String? {
        summary
    }
    
    var wrappedId: UUID {
        id  // 如果 id 不是可选的，直接返回
    }
    
    var wrappedAudioFileName: String? {
        audioFileName
    }
    
    /// 格式化日期用于显示
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: wrappedDate)
    }
    
    /// 心情颜色
    var moodColor: Color {
        Color.moodSpectrum(value: moodValue)
    }
    
    /// Content property (alias for text)
    var content: String? {
        text
    }
    
    /// Mood as integer (1-5)
    var mood: Int16 {
        Int16(min(max(Int(moodValue * 4 + 1), 1), 5))
    }
    
    /// Photos data array
    var photos: [Data]? {
        // This would need to be implemented based on how photos are stored
        // For now, return nil
        nil
    }
} 