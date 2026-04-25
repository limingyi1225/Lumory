import Foundation

// 用于读取旧 JSON 数据的临时结构体
struct LegacyDiaryEntry: Decodable, Identifiable {
    let id: UUID
    let date: Date
    let text: String
    let summary: String?
    let moodValue: Double
    let audioFileName: String?
    
    // 向后兼容旧版本
    enum CodingKeys: String, CodingKey {
        case id, date, text, summary, moodValue, audioFileName
        case mood // 旧版本字段
    }
    
    init(id: UUID = UUID(), date: Date, text: String, summary: String?, moodValue: Double, audioFileName: String?) {
        self.id = id
        self.date = date
        self.text = text
        self.summary = summary
        self.moodValue = moodValue
        self.audioFileName = audioFileName
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        text = try container.decode(String.self, forKey: .text)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        
        // 尝试读取新字段
        if let value = try container.decodeIfPresent(Double.self, forKey: .moodValue) {
            moodValue = value
        } else if let oldMood = try container.decodeIfPresent(String.self, forKey: .mood) {
            // 旧版本映射 5 档到连续值
            let mapping: [String: Double] = [
                "great": 1.0,
                "good": 0.75,
                "neutral": 0.5,
                "bad": 0.25,
                "terrible": 0.0
            ]
            moodValue = mapping[oldMood] ?? 0.5
        } else {
            moodValue = 0.5
        }
    }
}
