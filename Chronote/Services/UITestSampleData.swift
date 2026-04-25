import Foundation
import CoreData

// MARK: - UITestSampleData
//
// 仅在 DEBUG 构建里存在。检测到启动参数 `-LumoryUITestSampleData YES` 时,
// 同步擦库 + 种入一组精心写就的样例日记,用于 App Store screenshot 自动化。
//
// **主角设定 — 林子衿**
//   28 岁,杭州,B 端跨境电商 SaaS 的产品经理。备考 GRE,目标明年秋季入学北美 MBA。
//   备战 11 月西湖半马,常跑九溪。同居女友"小满"是自由插画师。养了只 3 岁英短"麻团"。
//   父母在杭州本地,周日聚餐。
//   暗线:与新来的 leader M 在产品方向上有分歧;爸爸体检指标在波动;和小满讨论
//   要不要搬到西溪那边大一点的房子。
//
// 30 条日记覆盖最近 60 天,密度 ~50%(有连记三天的小爆发,也有断五天的真空)。
// Mood 分布有自然起伏:M 当众怼那天 0.30、半马试跑 PB 那天 0.85。
//
// **重要**:种数据走 background context + batch delete,不会污染用户数据——
// 因为这条路径只有在 launchArg 显式置位时才启用,production build 里整个文件被 #if DEBUG 剥掉。

#if DEBUG
enum UITestSampleData {
    static let launchArgFlag = "-LumoryUITestSampleData"

    /// 启动参数检测。`xcrun simctl ... -LumoryUITestSampleData YES` 这种形式 —— 紧跟着的 `YES`
    /// 才算开启,任何其他值/缺失都视为关闭。这样手抖加错参数不会意外擦库。
    static var isActive: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: launchArgFlag) else { return false }
        let next = idx + 1
        return next < args.count && args[next].uppercased() == "YES"
    }

    /// 同步执行擦库 + 种数据。在 ChronoteApp.init()(主线程)里 fire-and-forget 调用。
    /// 30 条 + 字数计算 + sanitize themes,实测 ~40ms,不会触发 watchdog。
    ///
    /// **死锁注意**:此方法被 main thread 直接调用 →  performAndWait 内部如果再
    /// `DispatchQueue.main.sync` 会立即死锁(main 已经在等 bg)。所以 batch delete
    /// 拿到的 objectID 列表先暂存,等 performAndWait 返回(回到 main 自然态)再 merge。
    static func seedIfNeeded(into controller: PersistenceController) {
        guard isActive else { return }

        // ⚠️ 安全闸门(reviewer 二轮硬性要求):这条路径会 batch delete 整张 DiaryEntry 表。
        // 唯一允许的执行环境是 **真正的 NSInMemoryStoreType store** —— 由
        // `PersistenceController.shared` 在检测到 `-LumoryUITestSampleData YES` launchArg 时
        // 自动构造,完全旁路 CloudKit、本地 SQLite、用户真实数据。
        //
        // 之前我用过的 escape hatch 全部撤销:
        //   ❌ `CONTAINER_OVERRIDE=inmemory` 环境变量 —— `PersistenceController` 从不读它,
        //      置位只是给 guard 一个空头支票,真实 store 还在 CloudKit-backed 上。
        //   ❌ `ubiquityIdentityToken == nil` —— 没登录 iCloud 的开发机现在不会同步,但用户
        //      日后登录账号时,本地 store 仍会同步上去。
        //   ❌ `count < 5` —— 真实新装的 dev 设备 / 新 iCloud 账号都可能在 < 5 条状态,误擦真实数据。
        //
        // 现在的硬性条件:store 类型 == NSInMemoryStoreType。任何其他情况 → loud-log + return。
        guard isSafeToSeed(controller: controller) else {
            Log.error(
                "[UITestSampleData] ABORT — refusing to seed because the underlying store is not NSInMemoryStoreType. " +
                "Screenshot mode requires `PersistenceController.shared` to detect `-LumoryUITestSampleData YES` " +
                "and construct an in-memory container. If you see this, the launchArg detection in PersistenceController.shared " +
                "static init didn't fire — check ProcessInfo.processInfo.arguments before reaching seedIfNeeded.",
                category: .persistence
            )
            return
        }

        Log.info("[UITestSampleData] launch arg detected — seeding sample diaries", category: .persistence)

        let ctx = controller.container.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        var deletedIDs: [NSManagedObjectID] = []
        ctx.performAndWait {
            deletedIDs = wipeAllReturningIDs(in: ctx)
            seed(in: ctx)
            do {
                try ctx.save()
                Log.info("[UITestSampleData] seeded \(entries.count) entries", category: .persistence)
            } catch {
                Log.error("[UITestSampleData] seed save failed: \(error)", category: .persistence)
            }
        }
        // 回到 main 上下文(我们本来就在 main thread)。把 batch delete 的删除集合
        // merge 进 viewContext,后续 FetchRequest 不会缓存到老对象。
        // 新插入的对象会通过 viewContext 的 automaticallyMergesChangesFromParent 自动可见。
        if !deletedIDs.isEmpty {
            let changes = [NSDeletedObjectsKey: deletedIDs]
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: changes,
                into: [controller.container.viewContext]
            )
        }
    }

    /// 唯一安全条件:underlying store 是 NSInMemoryStoreType。
    /// 任何其他情况(CloudKit-backed / SQLite-backed)都拒绝。
    /// `controller.isInMemory` 是 PersistenceController init 时一次性记录的,不会被运行时改写。
    private static func isSafeToSeed(controller: PersistenceController) -> Bool {
        // 同时校验 (a) controller 自报 in-memory 模式 + (b) coordinator 中真有 NSInMemoryStoreType
        // 双重检查 —— 万一未来有 bug 让 isInMemory 标志和实际 store 不同步,任一不成立就拒绝。
        guard controller.isInMemory else {
            Log.error("[UITestSampleData] unsafe: controller.isInMemory == false", category: .persistence)
            return false
        }
        let stores = controller.container.persistentStoreCoordinator.persistentStores
        let allInMemory = !stores.isEmpty && stores.allSatisfy { $0.type == NSInMemoryStoreType }
        if !allInMemory {
            Log.error("[UITestSampleData] unsafe: store types = \(stores.map(\.type))", category: .persistence)
            return false
        }
        Log.info("[UITestSampleData] safe: confirmed NSInMemoryStoreType across all stores", category: .persistence)
        return true
    }

    /// 走 `NSBatchDeleteRequest`,绕过 context 直接 SQL,~5ms 删完。
    /// 返回删除对象的 NSManagedObjectID 列表给上层 merge。
    private static func wipeAllReturningIDs(in ctx: NSManagedObjectContext) -> [NSManagedObjectID] {
        let req: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: "DiaryEntry")
        let del = NSBatchDeleteRequest(fetchRequest: req)
        del.resultType = .resultTypeObjectIDs
        do {
            if let result = try ctx.execute(del) as? NSBatchDeleteResult,
               let ids = result.result as? [NSManagedObjectID] {
                return ids
            }
        } catch {
            Log.error("[UITestSampleData] batch delete failed: \(error)", category: .persistence)
        }
        return []
    }

    private static func seed(in ctx: NSManagedObjectContext) {
        let now = Date()
        let cal = Calendar.current
        let allEntries = entries + historicalEntries()
        for e in allEntries {
            let obj = DiaryEntry(context: ctx)
            obj.id = UUID()
            // 精确时刻 = 今天午夜 - daysAgo 天 + (hour:minute) —— 让 ThemeStoryChart / Calendar 看到
            // 真实的小时分布,不是同一时刻一柱。
            let day = cal.date(byAdding: .day, value: -e.daysAgo, to: now) ?? now
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = e.hour
            comps.minute = e.minute
            obj.date = cal.date(from: comps) ?? day
            obj.text = e.text
            obj.summary = e.summary
            obj.moodValue = e.mood
            obj.setThemes(e.themes)
            obj.recomputeWordCount()
        }
    }

    // MARK: - Historical (templated) entries

    /// 30 条手写日记覆盖最近 60 天 —— 是 MoodStoryChart 月/季视图、Home 列表、详情页的主舞台。
    /// 但写作热力(WritingHeatmap)默认显示 22 周(~150 天),"全部"模式下情绪图也希望看到更长跨度。
    /// 这里再拼 ~60 条覆盖 day 60-270(约 7 个月)的"历史日记",密度 ~30%(每 3 天一条)。
    ///
    /// 这部分内容**不会单独出现在任何截图里** —— 只贡献热力图的格子颜色和情绪图的小圆点。
    /// 所以走模板 + 种子化 RNG(LCG,固定 seed → 每次 screenshot 完全可复现),代价小、可信。
    private struct Template {
        let mood: Double
        let themes: [String]
        let summary: String
        let text: String
    }

    private static func historicalEntries() -> [E] {
        // 40 个模板覆盖 9 个 theme 池。
        let templates: [Template] = [
            // 跑步(~25%)
            Template(mood: 0.70, themes: ["跑步"],          summary: "周末 LSD 12K",       text: "天气一般,配速 5'30。"),
            Template(mood: 0.75, themes: ["跑步"], summary: "晨跑 7K", text: "公司楼下的环路,跑了三圈。"),
            Template(mood: 0.65, themes: ["跑步", "杭州"], summary: "西溪夜跑", text: "湿地的灯只到一半,后半段全靠手机电筒。"),
            Template(mood: 0.80, themes: ["跑步"], summary: "Tempo 5K", text: "破了 5'00 配速。"),
            Template(mood: 0.55, themes: ["跑步"], summary: "膝盖在叫", text: "今天慢跑 4K,膝盖有点酸。"),
            Template(mood: 0.70, themes: ["跑步", "徒步"], summary: "环湖一圈", text: "平湖秋月那段人太多。"),
            // 咖啡(~20%)
            Template(mood: 0.70, themes: ["咖啡"], summary: "Manner 新款", text: "黑糖丝绒拿铁。还是单品好。"),
            Template(mood: 0.65, themes: ["咖啡"], summary: "BFC 周二", text: "今天的耶加偏酸。"),
            Template(mood: 0.75, themes: ["咖啡", "阅读"], summary: "Soloist 周末", text: "看完了《1Q84》第一卷。"),
            Template(mood: 0.60, themes: ["咖啡"], summary: "便利店冰美式", text: "加班懒得走远。"),
            Template(mood: 0.70, themes: ["咖啡"], summary: "新开的店", text: "院子里有棵桂花树。耶加豆。"),
            // 工作(~20%)
            Template(mood: 0.50, themes: ["工作"], summary: "PRD 改第二版", text: "M 挑了三个点。逻辑没问题,写法他不喜欢。"),
            Template(mood: 0.45, themes: ["工作"], summary: "周会被点名", text: "数据没准备齐。"),
            Template(mood: 0.65, themes: ["工作"], summary: "用户访谈做完三场", text: "比想象的清楚。"),
            Template(mood: 0.40, themes: ["工作"], summary: "OKR review", text: "60% 完成度。我自己也觉得不算高。"),
            Template(mood: 0.70, themes: ["工作"], summary: "方案过了", text: "评审一次过。下班早走半小时。"),
            Template(mood: 0.55, themes: ["工作"], summary: "加班到九点", text: "外卖凉了。"),
            // GRE(~15%)
            Template(mood: 0.50, themes: ["GRE"], summary: "RC 模拟", text: "三篇里错了 6 个。"),
            Template(mood: 0.45, themes: ["GRE"], summary: "Verbal 复习", text: "今天不在状态。"),
            Template(mood: 0.65, themes: ["GRE", "咖啡"], summary: "图书馆刷题", text: "断网 3 小时,效率反而高。"),
            Template(mood: 0.55, themes: ["GRE"], summary: "Magoosh 第六章", text: "讲 GRE issue 写作的逻辑。"),
            Template(mood: 0.35, themes: ["GRE"], summary: "崩了", text: "想哭。"),
            // 家人 / 麻团(~12%)
            Template(mood: 0.70, themes: ["家人"], summary: "周日回家吃饭", text: "妈妈做了红烧排骨。"),
            Template(mood: 0.65, themes: ["家人", "麻团"], summary: "麻团去外婆家", text: "麻团把外婆家的窗帘抓花了。"),
            Template(mood: 0.55, themes: ["家人"], summary: "爸爸生日", text: "送了他一双跑鞋,他没说话。"),
            Template(mood: 0.75, themes: ["家人"], summary: "陪妈逛超市", text: "她非要买打折的橘子,最后烂了一半。"),
            Template(mood: 0.70, themes: ["麻团"], summary: "麻团又掉毛", text: "毛球可以织一只小麻团了。"),
            Template(mood: 0.60, themes: ["家人", "麻团"], summary: "麻团一岁那天", text: "我和小满给他煮了块鸡胸。"),
            // 小满 / 阅读 / 电影(~10%)
            Template(mood: 0.75, themes: ["小满"], summary: "小满画了麻团", text: "贴在冰箱上。麻团认不出自己。"),
            Template(mood: 0.65, themes: ["阅读"], summary: "看完《人生海海》", text: "后半段一直被催泪。"),
            Template(mood: 0.70, themes: ["电影", "小满"], summary: "看《小偷家族》", text: "豆瓣分被低估了。"),
            Template(mood: 0.55, themes: ["小满"], summary: "和小满吵架", text: "为麻团的猫粮品牌。半小时后和好。"),
            Template(mood: 0.75, themes: ["小满", "咖啡"], summary: "和小满去 Berry Beans", text: "她点了两块蛋糕。"),
            // 杂感(~8%)
            Template(mood: 0.50, themes: ["杭州"], summary: "今天累", text: "今天累。地铁上靠着扶手睡了两站。"),
            Template(mood: 0.65, themes: ["杭州"], summary: "西湖边走了一圈", text: "三月的风还冷。"),
            Template(mood: 0.55, themes: [], summary: "睡不着", text: "下午喝了三杯咖啡。"),
            Template(mood: 0.85, themes: ["跑步", "小满"], summary: "PB + 庆功", text: "10K 41 分。小满请的火锅。"),
            Template(mood: 0.45, themes: ["工作", "GRE"], summary: "两边都焦虑", text: "PRD 还没改完,verbal 还没看完。"),
            Template(mood: 0.70, themes: ["咖啡"], summary: "% Arabica", text: "玉鸟集那家。"),
            Template(mood: 0.65, themes: ["跑步", "徒步"], summary: "灵隐慢跑", text: "山里的空气和市区不一样。"),
        ]

        // 种子化 LCG —— 固定 seed,每次跑 screenshot 数据完全一致,差异截图便于对比。
        var seed: UInt64 = 42
        func rand() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed >> 16
        }

        var result: [E] = []
        var day = 60
        let endDay = 270
        while day < endDay {
            let pick = templates[Int(rand() % UInt64(templates.count))]
            let hour = 7 + Int(rand() % 16)        // 7-22 点
            let minute = Int(rand() % 60)
            // mood ±0.10 抖动,clamp 到 [0.05, 0.95]
            let jitter = (Double(rand() % 200) - 100.0) / 1000.0
            let mood = max(0.05, min(0.95, pick.mood + jitter))
            result.append(E(
                daysAgo: day, hour: hour, minute: minute,
                mood: mood, themes: pick.themes,
                summary: pick.summary, text: pick.text
            ))
            // 跳 1-5 天到下一条 → 平均 ~3 天/条 → 210 / 3 ≈ 70 条
            day += 1 + Int(rand() % 5)
        }
        return result
    }

    // MARK: - Entry data

    private struct E {
        let daysAgo: Int
        let hour: Int
        let minute: Int
        let mood: Double
        let themes: [String]
        let summary: String
        let text: String
    }

    /// 30 条日记。daysAgo 从 0(今天)到 58(约两个月前)。
    /// 主题池:工作 / 跑步 / GRE / 小满 / 麻团 / 家人 / 咖啡 / 阅读 / 徒步 / 电影 / 杭州。
    private static let entries: [E] = [
        // ── 本周 ─────────────────────────────────────
        E(daysAgo: 0, hour: 8, minute: 15, mood: 0.65,
          themes: ["工作", "咖啡", "麻团"],
          summary: "周一早上的耶加，比上周酸",
          text: "早起的副作用是刚到公司就开始困。武林路那家 BFC 的耶加，今天的批次酸得直接，不像上周那么柔。M 的周会调到 10 点，理论上还能再续一杯。\n\n麻团的猫粮快没了，下班路上得绕去宠物店。"),

        E(daysAgo: 1, hour: 21, minute: 30, mood: 0.75,
          themes: ["家人"],
          summary: "妈妈的“嗯”，我想了一路",
          text: "周末回家吃饭，妈妈把切好的西瓜装进保鲜盒让我带走，又问什么时候考。我说还要再两个月，她“嗯”了一声没接。爸爸在阳台上和麻团说话，麻团假装听不懂。\n\n回的路上想了一下，可能她那一声“嗯”不是不满意，是不知道还能问什么。"),

        E(daysAgo: 2, hour: 12, minute: 40, mood: 0.80,
          themes: ["跑步", "杭州"],
          summary: "九溪 18K，半马有戏",
          text: "九溪 LSD 18 公里，心率压得住，平均配速 5'12，比上周提了 10 秒。后半段腿沉但呼吸没乱，半马应该还能再啃一啃。\n\n跑完去茶室喝了一壶龙井。老板娘说今年的明前有点淡，我喝不太出来，也许是我嘴太粗。"),

        E(daysAgo: 4, hour: 22, minute: 15, mood: 0.55,
          themes: ["GRE", "阅读"],
          summary: "Manhattan 填空，“突然就懂”复制不了",
          text: "Verbal 还是死磕填空。Manhattan 的逻辑链解释挺清楚——把 main clause 和 modifier 的关系画成箭头之后突然就懂了，这种“突然就懂”完全没法复制到下一道题。\n\n两个月后还有 30 天能用来刷题。算了，不算了。"),

        E(daysAgo: 5, hour: 20, minute: 50, mood: 0.45,
          themes: ["工作"],
          summary: "评审被打回。我居然没接住",
          text: "需求评审被打回。M 一句“这不是用户要的”，我没接住。\n\n回办公位坐了五分钟才打开 Figma。问题不在于他说得对不对——他说得未必对——问题是我在那一秒里居然没有任何东西可以反驳。这才是让我后怕的。"),

        E(daysAgo: 6, hour: 23, minute: 0, mood: 0.70,
          themes: ["小满", "电影"],
          summary: "和小满看《步履不停》重映",
          text: "和小满去 in 影院看《步履不停》重映。她哭得鼻子通红，散场跟我说“以后我妈再喊我回家吃饭，你别拦我”。\n\n我说好。"),

        E(daysAgo: 7, hour: 8, minute: 30, mood: 0.60,
          themes: ["工作", "咖啡"],
          summary: "周一。臻选 fka 的 V60",
          text: "周一。星巴克臻选 fka 的 V60。"),

        // ── 上周 ─────────────────────────────────────
        E(daysAgo: 9, hour: 18, minute: 0, mood: 0.55,
          themes: ["GRE"],
          summary: "模考 V152。习惯比分数更让人警觉",
          text: "模考 V152 + Q165。Verbal 还差。158 是底线，152 离底线还有 6 分，再有两次模考就要正式了。\n\n但今天没有不开心，可能是已经习惯了。习惯本身比分数更让人警觉一点。"),

        E(daysAgo: 10, hour: 19, minute: 40, mood: 0.85,
          themes: ["跑步", "小满"],
          summary: "半马试跑 1:43:20。终点小满举着纸板",
          text: "半马 PB 试跑 1:43:20。\n\n终点小满举着一张 A3 纸板，上面用马克笔写“林选手 加油”，字歪歪扭扭，旁边还画了一只发抖的麻团。我冲过去差点哭。\n\n晚上吃了碗虾仁馄饨，加了一勺辣油，腿酸到下楼梯要扶墙。"),

        E(daysAgo: 11, hour: 22, minute: 30, mood: 0.50,
          themes: ["工作"],
          summary: "OKR 又改了。归属感和职业素养",
          text: "下半年 OKR 又改了。M 想做 AI Agent，我觉得不打地基没用——我们连 user persona 都没跑齐，做 Agent 是给谁用？\n\n但他是 leader，他说做就做。我不知道这事归属感和职业素养之间应该选哪个。"),

        E(daysAgo: 13, hour: 16, minute: 0, mood: 0.75,
          themes: ["咖啡", "阅读"],
          summary: "雨天 Manner，看完《国境以南》",
          text: "雨天泡 Manner，把村上的《国境以南、太阳以西》看完了。后半段男主回到岛本身边那段，我读了三遍。\n\n还是上一本好。"),

        E(daysAgo: 15, hour: 20, minute: 0, mood: 0.65,
          themes: ["家人"],
          summary: "橘子放软了。爸爸的指标又涨了一点",
          text: "妈妈让我带的橘子放冰箱忘了，今天打开发软。\n\n爸爸的体检报告我偷瞄了一眼，转氨酶又涨了一点。他没说，我没问。回来的地铁上想了一路。"),

        E(daysAgo: 16, hour: 13, minute: 30, mood: 0.85,
          themes: ["跑步", "徒步", "杭州"],
          summary: "九溪到龙井村，溪边吃了豆腐花",
          text: "天气太好了。九溪到龙井村 12 公里慢跑，途中喝了一壶豆腐花，老板说豆是当天磨的，加了一勺红糖。坐在溪边的石头上吃完，太阳晒得我半睡着。\n\n杭州的春天就这几个周末。"),

        E(daysAgo: 18, hour: 23, minute: 30, mood: 0.40,
          themes: ["工作", "GRE"],
          summary: "PRD 改到 8 点半，RC 做到 11 点",
          text: "白天 PRD 改到 8 点半，晚上做 RC 到 11 点。眼睛胀得一闭就出现 “Although ... nevertheless ...” 的句式。\n\n今天没空想麻团。"),

        // ── 三月底 ───────────────────────────────────
        E(daysAgo: 20, hour: 21, minute: 0, mood: 0.30,
          themes: ["工作"],
          summary: "M 当众说我“思路太老”",
          text: "M 当着所有人说我“思路太老”。我没回。回办公位的路上手在抖。\n\n气的不是被说，气的是我没有任何一句话能自然地接回去——我应该说什么？“我有 5 年用户研究”？还是“那你说说什么是新思路”？我什么都没说。\n\n这不是第一次。"),

        E(daysAgo: 21, hour: 21, minute: 0, mood: 0.55,
          themes: ["小满", "麻团"],
          summary: "小满说“你这两周整个人是绷着的”",
          text: "小满做了番茄牛肉饭，麻团蹲在餐桌边沿盯着我们看，眼睛随着筷子动。\n\n她说：“你这两周整个人是绷着的。”\n\n我没辩。她说的对。"),

        E(daysAgo: 23, hour: 11, minute: 0, mood: 0.70,
          themes: ["跑步"],
          summary: "西溪 15K，没带耳机反而清楚",
          text: "西溪湿地 15K 慢跑。湖边风太大，戴了帽子，跑到一半被吹掉两次。\n\n今天没带耳机，跑完才发现脑子里反而清楚不少。"),

        E(daysAgo: 25, hour: 22, minute: 0, mood: 0.60,
          themes: ["GRE", "咖啡"],
          summary: "Soloist 续了三杯，对面在看 LSAT",
          text: "Magoosh 的 verbal 课进度推到 40%。\n\n晚上去了 Soloist，咖啡续了三杯。坐我对面的男生在看 LSAT，互相对视了一眼，露出“互相理解”的笑。"),

        E(daysAgo: 27, hour: 19, minute: 30, mood: 0.50,
          themes: ["工作", "阅读"],
          summary: "Hooked 第三章。框架不是问题",
          text: "下班路上读 Hooked 第三章。Trigger → Action → Reward → Investment。\n\nM 想要的方向，这本书也救不了。框架不是问题，问题是我们没有确认过用户真的有那个 trigger。"),

        E(daysAgo: 29, hour: 22, minute: 0, mood: 0.75,
          themes: ["家人", "麻团"],
          summary: "麻团在我妈家嗷叫了一晚",
          text: "回家吃饭，妈妈非要让我把麻团带回去过夜，理由是“它一个人在家可怜”。结果它一晚上嗷叫，凌晨 3 点把我和小满都叫醒了。\n\n明天还要上班。"),

        E(daysAgo: 31, hour: 23, minute: 30, mood: 0.80,
          themes: ["小满", "电影", "咖啡"],
          summary: "看《海街日记》，吃糖油饼",
          text: "下班后去 Felicity 看《海街日记》，散场和小满走到武林夜市。她非要吃糖油饼，我吃了半个就饱。\n\n回家路上路过 Berry Beans，关了。明天再来。"),

        E(daysAgo: 34, hour: 22, minute: 30, mood: 0.35,
          themes: ["GRE"],
          summary: "Verbal 模考最低。生词就慌",
          text: "Verbal 模考最低分。错的题型集中在 Sentence Equivalence，两个空都得选对的那种。\n\nMagoosh 的视频里说“Trust the patterns”，可是我现在的 pattern 是“看到生词就慌”。"),

        E(daysAgo: 36, hour: 20, minute: 0, mood: 0.55,
          themes: ["家人"],
          summary: "陪爸去医院。回家路上他聊 NBA",
          text: "陪爸去医院复诊。挂号大厅的椅子我坐了三个小时。\n\n他出来的时候表情没变，说“医生说还行”。我没追问。回家的车上他主动开口聊了一路 NBA。"),

        E(daysAgo: 38, hour: 17, minute: 0, mood: 0.65,
          themes: ["咖啡", "工作"],
          summary: "Soloist 写 PRD，耶加像柚子皮",
          text: "在 Soloist 写 PRD。今天的耶加尾韵像柚子皮，有点意外。\n\nPRD 的第三版，这次提交之前我自己读了两遍——上次就是没读，被 M 抓到一个明显的逻辑跳跃。"),

        // ── 三月初到中 ───────────────────────────────
        E(daysAgo: 41, hour: 13, minute: 0, mood: 0.75,
          themes: ["跑步"],
          summary: "中午 5K interval，配速 4'30",
          text: "中午 5K interval。配速 4'30。\n\n周二的午休跑步是我一周里最不像自己的时间。"),

        E(daysAgo: 44, hour: 17, minute: 30, mood: 0.80,
          themes: ["徒步", "杭州"],
          summary: "灵隐到北高峰，膝盖叫了两公里",
          text: "灵隐到北高峰来回 4 小时。山顶的风冷，下山膝盖一直在叫，下了两公里之后忽然就不叫了。\n\n身体大概也是这样的，叫一阵就习惯了。"),

        E(daysAgo: 47, hour: 22, minute: 30, mood: 0.60,
          themes: ["工作", "小满"],
          summary: "讨论搬家。她说“你要算到什么时候才停”",
          text: "晚上跟小满讨论搬家。她想去西溪那边的复式，我算了一下房租比现在贵 3500，加上停车一年就是五万。\n\n她说：“你要算到什么时候才停？”\n我没答。她也没追。"),

        E(daysAgo: 50, hour: 20, minute: 30, mood: 0.70,
          themes: ["家人", "麻团"],
          summary: "爸爸给麻团带了纹章款猫绳",
          text: "三月。爸爸给麻团带了条新猫绳，纹章款，说网上有人晒过，麻团死活不肯戴。爸爸在阳台上跟它讲了五分钟道理。\n\n我以前以为他不喜欢猫。"),

        E(daysAgo: 54, hour: 20, minute: 0, mood: 0.55,
          themes: ["GRE", "咖啡"],
          summary: "瓜豆杯加了肉桂粉，像感冒糖浆",
          text: "Verbal 复习。Manner 的瓜豆杯今天加了肉桂粉，闻着像感冒糖浆，但喝起来意外不错。\n\n阅读 RC 还是慢。读完一段总要回去重读一遍才确认没漏掉什么。"),

        E(daysAgo: 58, hour: 13, minute: 0, mood: 0.65,
          themes: ["跑步", "杭州"],
          summary: "今年第一次跑九溪。冬天的腿太生",
          text: "今年第一次跑九溪。\n\n冬天的腿怎么这么生。配速 5'40，喘。前面被一个看上去 50 多岁的大叔超过去，他跟我打了个招呼，“小妹妹，年轻人加油”。\n\n我笑了，然后被风呛到。"),
    ]
}
#endif
