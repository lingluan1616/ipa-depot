import Foundation
import XCTest
@testable import IPADepotCore

// MARK: - 阶段八：重复任务去重（键 = appID + 外部版本 ID + 平台 + 账号）

final class DownloadDedupeTests: TempDirTestCase {
    private let accountA = UUID()
    private let accountB = UUID()

    private func request(app: Int64 = 1001, version: String? = nil, platform: String? = nil, account: UUID? = nil,
                         file: String = UUID().uuidString, purchase: Bool = false) -> DownloadRequest {
        DownloadRequest(appID: app, externalVersionID: version, purchase: purchase,
                        output: tempDir.appendingPathComponent("\(file).ipa"), platform: platform, accountID: account)
    }

    private func count(_ queue: DownloadQueue) async -> Int { await queue.items.count }

    /// 等切换真正挂起后再放行（避免放行早于挂起、切换永远不返回）。
    private func releaseWhenHeld(_ switching: FakeDownloadSwitching) async {
        await waitUntil { switching.calls.value.count == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        switching.release()
    }

    // MARK: 键

    func testKeyNormalizesEmptyValuesAndIgnoresOutputAndPurchase() {
        let a = request(version: "", platform: "", file: "x").dedupeKey
        let b = request(version: nil, platform: nil, file: "y", purchase: true).dedupeKey
        XCTAssertEqual(a, b, "空字符串视为 nil；输出路径与 purchase 不参与")
        XCTAssertEqual(request(platform: "iPadOS").dedupeKey, request(platform: "ipados").dedupeKey, "平台不区分大小写")
        XCTAssertNotEqual(request(version: "1").dedupeKey, request(version: nil).dedupeKey)
    }

    func testKeyAccountNilMeansCurrentAccount() {
        let current = accountA
        let isCurrent: (UUID) -> Bool = { $0 == current }
        let withNil = request(account: nil).dedupeKey
        XCTAssertTrue(withNil.matches(request(account: accountA).dedupeKey, isCurrentAccount: isCurrent))
        XCTAssertTrue(request(account: accountA).dedupeKey.matches(withNil, isCurrentAccount: isCurrent))
        XCTAssertFalse(withNil.matches(request(account: accountB).dedupeKey, isCurrentAccount: isCurrent))
        XCTAssertTrue(withNil.matches(request(account: nil).dedupeKey, isCurrentAccount: isCurrent))
        XCTAssertFalse(request(account: accountA).dedupeKey.matches(request(account: accountB).dedupeKey,
                                                                     isCurrentAccount: { _ in true }))
    }

    // MARK: 队列

    func testSameKeyReturnsExistingIDAndDoesNotCreate() async {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let first = await queue.addDeduplicated(request(account: accountA, file: "a"))
        XCTAssertTrue(first.isNew)
        let second = await queue.addDeduplicated(request(account: accountA, file: "a (2)"), id: UUID())
        XCTAssertFalse(second.isNew, "同一任务：不新建")
        XCTAssertEqual(second.id, first.id, "返回已有任务的 id")
        let legacy = await queue.add(request(account: accountA, file: "a (3)"))
        XCTAssertEqual(legacy, first.id, "旧 add 接口同样去重，返回已有 id")
        let n = await count(queue)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(factory.all.count, 1, "没有为重复任务创建下载任务")
    }

    func testDifferentKeysAreNotDeduplicated() async {
        let queue = DownloadQueue(makeTask: { FakeTaskFactory().make($0) })
        await queue.setMaxConcurrent(3)
        let base = await queue.addDeduplicated(request(app: 1, version: nil, platform: nil, account: accountA))
        XCTAssertTrue(base.isNew)
        let variants = [
            request(app: 2, version: nil, platform: nil, account: accountA),     // appID 不同
            request(app: 1, version: "777", platform: nil, account: accountA),   // 版本不同
            request(app: 1, version: nil, platform: "ipados", account: accountA), // 平台不同
            request(app: 1, version: nil, platform: nil, account: accountB),     // 账号不同
        ]
        for variant in variants {
            let result = await queue.addDeduplicated(variant)
            XCTAssertTrue(result.isNew, "任一键位不同都应新建：\(variant.dedupeKey)")
            XCTAssertNotEqual(result.id, base.id)
        }
        let n = await count(queue)
        XCTAssertEqual(n, 5)
    }

    func testFinishedTasksDoNotBlock() async {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        // 已完成
        let done = await queue.add(request(app: 1, file: "done"))
        await waitUntil { factory.all.first?.isWaiting == true }
        factory[0].finish(.completed(sampleResult(tempDir.appendingPathComponent("done.ipa"))))
        await waitUntil { await queue.item(done)?.status.isFinished == true }
        let again = await queue.addDeduplicated(request(app: 1, file: "done (2)"))
        XCTAssertTrue(again.isNew, "已完成的任务不拦截")
        XCTAssertNotEqual(again.id, done)

        // 失败
        await waitUntil { factory.all.count == 2 && factory[1].isWaiting }
        factory[1].finish(.failed(IpatoolError(kind: .networkUnreachable)))
        await waitUntil {
            if case .failed = await queue.item(again.id)?.status { return true }
            return false
        }
        let third = await queue.addDeduplicated(request(app: 1, file: "done (3)"))
        XCTAssertTrue(third.isNew, "失败的任务不拦截")

        // 取消（从队列移除）
        await waitUntil { factory.all.count == 3 && factory[2].isWaiting }
        await queue.cancel(third.id)
        await waitUntil { await queue.item(third.id) == nil }
        let fourth = await queue.addDeduplicated(request(app: 1, file: "done (4)"))
        XCTAssertTrue(fourth.isNew, "取消的任务不拦截")
    }

    func testCancelRequestedRunningTaskDoesNotBlock() async {
        // 正在停止（已请求取消）的任务马上会被移出队列，不拦截新任务
        let factory = FakeTaskFactory()
        let switching = FakeDownloadSwitching()
        switching.current.value = accountA
        switching.holds.value = true
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        await queue.setAccountSwitching(switching)
        let first = await queue.add(request(app: 5, account: accountB))
        await waitUntil { await queue.item(first)?.status == .switchingAccount }
        await queue.cancel(first)
        let status = await queue.item(first)?.status
        XCTAssertEqual(status, .stopping)
        let again = await queue.addDeduplicated(request(app: 5, account: accountB))
        XCTAssertTrue(again.isNew)
        await releaseWhenHeld(switching)
    }

    func testPausedQueuedAndSwitchingTasksBlock() async {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let running = await queue.add(request(app: 10, file: "r"))
        let queued = await queue.add(request(app: 11, file: "q"))
        await waitUntil { factory.all.first?.isWaiting == true }

        // 排队中
        var dup = await queue.addDeduplicated(request(app: 11, file: "q2"))
        XCTAssertEqual(dup.id, queued); XCTAssertFalse(dup.isNew)
        // 下载中
        dup = await queue.addDeduplicated(request(app: 10, file: "r2"))
        XCTAssertEqual(dup.id, running); XCTAssertFalse(dup.isNew)
        // 已暂停
        await queue.pause(running)
        await waitUntil { await queue.item(running)?.status == .paused }
        dup = await queue.addDeduplicated(request(app: 10, file: "r3"))
        XCTAssertEqual(dup.id, running, "暂停中的任务也拦截")
        XCTAssertFalse(dup.isNew)
        // 排队中被暂停（跳过）
        await queue.pause(queued)
        await waitUntil { await queue.item(queued)?.status == .paused }
        dup = await queue.addDeduplicated(request(app: 11, file: "q3"))
        XCTAssertEqual(dup.id, queued)

        // 切换账号中
        let switching = FakeDownloadSwitching()
        switching.current.value = accountA
        switching.holds.value = true
        let other = DownloadQueue(makeTask: { FakeTaskFactory().make($0) })
        await other.setAccountSwitching(switching)
        let s = await other.add(request(app: 12, account: accountB))
        await waitUntil { await other.item(s)?.status == .switchingAccount }
        dup = await other.addDeduplicated(request(app: 12, account: accountB))
        XCTAssertEqual(dup.id, s, "正在为它切换账号的任务也拦截")
        XCTAssertFalse(dup.isNew)
        await releaseWhenHeld(switching)
        let n = await count(queue)
        XCTAssertEqual(n, 2)
    }

    func testRestoredPausedTaskBlocksAndNilAccountMatchesCurrent() async {
        let switching = FakeDownloadSwitching()
        switching.current.value = accountA
        let queue = DownloadQueue(makeTask: { FakeTaskFactory().make($0) })
        await queue.setAccountSwitching(switching)
        // 上次退出时保存的旧任务（无账号 = 当前账号），恢复为暂停
        let restoredID = UUID()
        await queue.restore(request(app: 20, account: nil), id: restoredID, progress: nil)
        var dup = await queue.addDeduplicated(request(app: 20, account: accountA))
        XCTAssertEqual(dup.id, restoredID, "无账号的旧任务视为当前账号")
        XCTAssertFalse(dup.isNew)
        dup = await queue.addDeduplicated(request(app: 20, account: accountB))
        XCTAssertTrue(dup.isNew, "其他账号的同一 App 不是同一任务")
        let existing = await queue.unfinishedItemID(matching: request(app: 20, account: nil))
        XCTAssertEqual(existing, restoredID)
    }
}
