//
//  PersistenceControllerConcurrentInitTests.swift
//  ChronoteTests
//
//  并发初始化回归测试,补 `PersistenceControllerCachedModelTests` 的盲区。
//
//  CLAUDE.md "⚠️ 但是真的 SIGABRT 不是 clone flake" 段记录的真实事故场景:
//  Core Data `+[DiaryEntry entity]` "Failed to find a unique match" → SIGABRT
//  (.ips 实证 2026-04-29 10:56:44),触发条件是**同进程内多个 `NSManagedObjectModel`
//  实例都声称定义 `DiaryEntry`**。事故路径不是串行多次 init,而是 Xcode 测试套
//  在多 simulator clone / 并发 destination 下**并行 fork**,N 个 PersistenceController
//  几乎同时 init,如果 `cachedModel` 静态共享逻辑被改回"每次 init 重新 load .momd",
//  这条 race 就会复现。
//
//  现有 `PersistenceControllerCachedModelTests.multipleInMemoryInstancesShareManagedObjectModel`
//  只覆盖**串行**两次 init,Swift 的 `static let` lazy init 串行路径天然 thread-safe
//  (single dispatch_once),即便 production 把 cachedModel 拆成"每次 init local 重 load"
//  串行测试也不会挂(只是浪费内存,model 实例 ≠ 同一引用)。串行测试只验"共享",
//  不验"并发安全"。
//
//  这条测试用 `withTaskGroup` 起 8 个并行 init,断言:
//    1. 全部 init 完成不 SIGABRT(测试进程跑完即 pass,fatal 会让进程非零退出)
//    2. 8 个 `container.managedObjectModel` 引用全部 `===` 同一对象(锁住共享路径)
//
//  约束:
//  - `inMemory: true` —— 不污染真实 SQLite store / CloudKit 容器
//  - 不通过 reflection 戳 `private static let cachedModel`,走公开 API
//    `NSPersistentContainer.managedObjectModel` 间接拿引用做身份比较
//  - `PersistenceController` 不是 `@MainActor`,init 可在任意 actor / detached
//    context 跑,所以 `Task { ... }` 直接 init 即可
//

import Testing
import Foundation
import CoreData
@testable import Lumory

struct PersistenceControllerConcurrentInitTests {
    /// 8 个并行 `PersistenceController(inMemory: true)` 全部完成,所有
    /// `container.managedObjectModel` 引用 `===` 第一个 —— 锁住 `cachedModel`
    /// 静态共享在并发路径下仍是 single instance。
    @Test func cachedModel_concurrentInit_singleSharedModelInstance() async {
        let models: [NSManagedObjectModel] = await withTaskGroup(of: NSManagedObjectModel.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let pc = PersistenceController(inMemory: true)
                    return pc.container.managedObjectModel
                }
            }
            var collected: [NSManagedObjectModel] = []
            for await model in group {
                collected.append(model)
            }
            return collected
        }

        #expect(models.count == 8, "8 并发 init 必须全部产出 model 引用 —— 缺失意味着某个 Task 抛出或 fatal")
        guard let first = models.first else { return }
        for (index, m) in models.enumerated() {
            #expect(m === first,
                    "并发 init 第 \(index) 个实例的 managedObjectModel 不是同一引用 —— cachedModel 静态共享被破坏,会在 Xcode 多 clone 跑测试时触发 SIGABRT(+[DiaryEntry entity] Failed to find a unique match)")
        }
    }

    /// 退化版:不验身份,只验"8 个并发 init 全部跑完不 fatal"。
    /// 如果 cachedModel 共享路径出问题导致 init 内部 Core Data 自检 throw fatalError /
    /// SIGABRT,测试进程会非零退出 —— 这条测试函数即便不写任何 `#expect` 也能通过
    /// "进程没崩"这条隐式 invariant。显式写 `#expect(true)` 让测试 trace 里看到一条
    /// 通过记录,而不是"empty test"被 reviewer 误认 dead code。
    @Test func cachedModel_concurrentInit_eightTasksAllSucceedWithoutCrash() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = PersistenceController(inMemory: true)
                }
            }
            await group.waitForAll()
        }
        #expect(Bool(true), "8 个并发 PersistenceController(inMemory: true) init 全部完成,进程未 SIGABRT")
    }
}
