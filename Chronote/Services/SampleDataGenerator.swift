import Foundation
import CoreData

// MARK: - SampleDataGenerator
//
// 开发 / 测试工具：批量生成 ~60 天内的样本日记，覆盖各种心情 / 主题组合，
// 用于验证 Phase 1 Insights Dashboard / Phase 2 Ask-Your-Past / Phase 3 Context Prompt
// 这些新功能。文案、主题、mood 都是预先写好的，**不**调 AI，保证离线也能跑。
//
// 生成后若网络可用，会顺便调一次 AIService.embed() 把 embedding 也填上，
// 这样语义搜索 / Ask Your Past 立刻可用。

@available(iOS 15.0, macOS 12.0, *)
@MainActor
final class SampleDataGenerator: ObservableObject {

    static let shared = SampleDataGenerator()

    @Published private(set) var isRunning = false
    @Published private(set) var generated: Int = 0
    @Published private(set) var total: Int = 0
    @Published private(set) var lastError: String?

    private let persistence: PersistenceController
    private let ai: AIServiceProtocol

    init(persistence: PersistenceController = .shared, ai: AIServiceProtocol = OpenAIService(apiKey: "")) {
        self.persistence = persistence
        self.ai = ai
    }

    // MARK: - Entry point

    /// 生成 ~`count` 条日记，覆盖过去 `dayRange` 天。默认 40 条 × 90 天。
    /// - Parameter includeEmbeddings: 若为 true，顺便请求 embedding（需要网络 + API key）
    func generateSamples(count: Int = 40, dayRange: Int = 90, includeEmbeddings: Bool = true) async {
        guard !isRunning else { return }
        isRunning = true
        generated = 0
        total = count
        lastError = nil

        let samples = Self.buildScript(count: count, dayRange: dayRange)
        let context = persistence.container.viewContext

        for sample in samples {
            let entry = DiaryEntry(context: context)
            entry.id = UUID()
            entry.date = sample.date
            entry.text = sample.text
            entry.summary = sample.summary
            entry.moodValue = sample.mood
            entry.setThemes(sample.themes)
            entry.recomputeWordCount()

            if includeEmbeddings {
                if let vector = await ai.embed(text: sample.text) {
                    entry.setEmbedding(vector)
                }
            }
            generated += 1
        }

        do {
            try context.save()
        } catch {
            lastError = error.localizedDescription
            Log.error("[SampleDataGenerator] save failed: \(error)", category: .persistence)
        }

        isRunning = false
        Log.info("[SampleDataGenerator] Generated \(generated) sample entries", category: .persistence)
    }

    /// 删除所有 summary 以 "【样本】" 开头的日记。
    func removeAllSamples() async {
        let context = persistence.container.viewContext
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "summary BEGINSWITH %@", Self.sampleMarker)
        guard let entries = try? context.fetch(request) else { return }
        for entry in entries {
            context.delete(entry)
        }
        try? context.save()
        Log.info("[SampleDataGenerator] Removed \(entries.count) sample entries", category: .persistence)
    }

    // MARK: - Script

    static let sampleMarker = "【样本】"

    private struct Sample {
        let date: Date
        let text: String
        let summary: String
        let mood: Double
        let themes: [String]
    }

    private static func buildScript(count: Int, dayRange: Int) -> [Sample] {
        let templates = entryTemplates()
        let calendar = Calendar.current
        let now = Date()
        var samples: [Sample] = []
        var rng = SystemRandomNumberGenerator()
        for index in 0..<count {
            let template = templates[index % templates.count]
            // 均匀铺在过去 dayRange 天，加上随机偏移避免全部 00:00
            let daysAgo = Int(Double(index) / Double(max(count, 1)) * Double(dayRange))
            let hour = Int.random(in: 7...23, using: &rng)
            let minute = Int.random(in: 0...59, using: &rng)
            let baseDay = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            let startOfDay = calendar.startOfDay(for: baseDay)
            let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: startOfDay) ?? baseDay
            samples.append(
                Sample(
                    date: date,
                    text: template.text,
                    summary: "\(sampleMarker)\(template.summary)",
                    mood: template.mood,
                    themes: template.themes
                )
            )
        }
        // 按日期升序以贴近真实写作时间线
        return samples.sorted { $0.date < $1.date }
    }

    private struct Template {
        let text: String
        let summary: String
        let mood: Double
        let themes: [String]
    }

    // 30 条覆盖：工作 / 家人 / 运动 / 睡眠 / 情绪 / 朋友 / 旅行 / 学习 / 健康 / 项目
    // mood 从 0.1 到 0.95 分布。循环使用保证 count>30 也有样本。
    private static func entryTemplates() -> [Template] {
        [
            Template(
                text: "今天项目会议被推到晚上七点，提了两个方向都没拍板。写这段时有点泄气，但知道明天还要推进。",
                summary: "项目会议拖延，略感泄气",
                mood: 0.35,
                themes: ["工作", "项目"]
            ),
            Template(
                text: "和妈妈视频了四十分钟。她最近膝盖又酸了，叮嘱我多穿衣服。想起小时候冬天她给我塞暖手宝。",
                summary: "和妈妈视频，想起童年",
                mood: 0.7,
                themes: ["家人"]
            ),
            Template(
                text: "早上去跑了 5 公里，配速六分二。跑完心情明显好转，原本堵着的一个需求思路也顺了。",
                summary: "晨跑 5km，思路变顺",
                mood: 0.85,
                themes: ["运动", "健康"]
            ),
            Template(
                text: "又是凌晨两点才睡着。反复回看明天要汇报的 slide，越看越觉得逻辑有漏洞。",
                summary: "失眠，担心汇报",
                mood: 0.2,
                themes: ["睡眠", "工作"]
            ),
            Template(
                text: "和 K 聊了两小时。从他读的一本书聊到各自最近的迷茫。有人愿意听你绕来绕去地讲，本身就是幸福。",
                summary: "和朋友深夜长聊",
                mood: 0.8,
                themes: ["朋友"]
            ),
            Template(
                text: "订了去京都的机票。想看看十一月的红叶。已经三年没自己出远门了。",
                summary: "订京都机票，期待",
                mood: 0.9,
                themes: ["旅行"]
            ),
            Template(
                text: "今天又被反馈 API 设计不够 Rest 化。我知道他们想要的规范，但这套我越写越觉得别扭。",
                summary: "API 设计被反馈",
                mood: 0.4,
                themes: ["工作", "项目"]
            ),
            Template(
                text: "上完瑜伽课，髋部明显松了。老师今天教了一个鸽子式变体，回家还想再练。",
                summary: "瑜伽课，身体放松",
                mood: 0.78,
                themes: ["运动", "健康"]
            ),
            Template(
                text: "爸爸住院查肺结节的结果出来了，良性。一瞬间觉得世界又稳当了。",
                summary: "爸爸结节良性",
                mood: 0.92,
                themes: ["家人", "健康"]
            ),
            Template(
                text: "一整天都在改 PPT，眼睛酸得要掉下来。晚饭随便塞了点，太累了，什么都不想说。",
                summary: "加班改 PPT，疲惫",
                mood: 0.25,
                themes: ["工作"]
            ),
            Template(
                text: "看完《降临》。想到语言怎么塑造一个人对时间的感受。那种被震到的感觉，好久没有了。",
                summary: "看《降临》，被语言打动",
                mood: 0.82,
                themes: ["学习"]
            ),
            Template(
                text: "我和她吵架了，她说我最近太少陪她。我也觉得是，但又说不出怎么变成这样。",
                summary: "和她吵架",
                mood: 0.18,
                themes: ["情绪", "家人"]
            ),
            Template(
                text: "把后端的重构 PR 发出去了，自己挺满意。同事也说清爽多了。",
                summary: "重构 PR 提交",
                mood: 0.86,
                themes: ["工作", "项目"]
            ),
            Template(
                text: "体检结果尿酸高。周末开始要调整饮食了，啤酒暂时先停。",
                summary: "体检尿酸偏高",
                mood: 0.5,
                themes: ["健康"]
            ),
            Template(
                text: "地铁上读完了《当呼吸化为空气》的最后几页。在人群里哭了一下，没忍住。",
                summary: "读书落泪",
                mood: 0.55,
                themes: ["学习", "情绪"]
            ),
            Template(
                text: "和弟弟聊到他想转行。我讲了一堆，其实自己也没看清。先别给他灌经验了。",
                summary: "和弟弟聊转行",
                mood: 0.6,
                themes: ["家人"]
            ),
            Template(
                text: "今天是 deadline。最后半小时我才发现少算了一个时区。修完以后整个人像被掏空。",
                summary: "deadline 险过",
                mood: 0.3,
                themes: ["工作", "项目"]
            ),
            Template(
                text: "早上做了一份简单的 overnight oats，加蓝莓。开始一天的节奏好像就对了。",
                summary: "早餐燕麦，节奏对",
                mood: 0.75,
                themes: ["健康"]
            ),
            Template(
                text: "情绪很低，说不上原因。好像只是连续几天没好好睡，也没运动。",
                summary: "情绪低落，无明确原因",
                mood: 0.22,
                themes: ["情绪", "睡眠"]
            ),
            Template(
                text: "试了一下新的番茄钟 App，把早上的时间切成四段。专注度确实高了。",
                summary: "番茄钟试验成功",
                mood: 0.72,
                themes: ["工作", "学习"]
            ),
            Template(
                text: "和好久不见的表姐喝咖啡。她给我讲了她孩子的趣事，一直笑。",
                summary: "和表姐下午茶",
                mood: 0.88,
                themes: ["家人", "朋友"]
            ),
            Template(
                text: "被老板叫去谈晋升的事。有点意外，也有点犹豫。我不确定自己是不是想管更多人。",
                summary: "晋升谈话，犹豫",
                mood: 0.55,
                themes: ["工作"]
            ),
            Template(
                text: "去了一家新开的拉面店。汤底偏咸但叉烧好。北风很大，走回家的一路在想冬天快到了。",
                summary: "拉面店体验",
                mood: 0.68,
                themes: ["朋友"]
            ),
            Template(
                text: "看了一场本地的独立乐队演出，声浪很大。散场出来耳朵嗡嗡的，但心里空出了很多。",
                summary: "独立乐队演出",
                mood: 0.84,
                themes: ["朋友", "情绪"]
            ),
            Template(
                text: "今天不想写太多。只想躺着。",
                summary: "只想躺平",
                mood: 0.3,
                themes: ["情绪"]
            ),
            Template(
                text: "今天终于把老爸生日礼物寄出去了。是一副他念叨过的老花镜。希望他开心。",
                summary: "给爸爸寄生日礼物",
                mood: 0.8,
                themes: ["家人"]
            ),
            Template(
                text: "晚上补看了一节 SwiftUI 动画课。感觉对 matchedGeometryEffect 总算理顺了。",
                summary: "学习 matchedGeometry",
                mood: 0.7,
                themes: ["学习", "工作"]
            ),
            Template(
                text: "今天感冒，鼻塞不止。吃了颗感冒灵，下午一直在睡。醒来觉得世界更轻。",
                summary: "感冒休息",
                mood: 0.45,
                themes: ["健康", "睡眠"]
            ),
            Template(
                text: "组里新来的实习生写代码很有灵气。带她 review 了两小时，我自己也在查漏补缺。",
                summary: "带实习生 review",
                mood: 0.75,
                themes: ["工作"]
            ),
            Template(
                text: "爷爷走后第四年。奶奶今天在视频里说她梦到爷爷了，说他笑得像年轻时那样。",
                summary: "想起爷爷",
                mood: 0.4,
                themes: ["家人", "情绪"]
            )
        ]
    }
}
