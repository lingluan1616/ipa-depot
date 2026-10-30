import Foundation
import XCTest
@testable import IPADepotCore

// MARK: - 阶段七：同时下载数（多槽位队列）

final class ConcurrentDownloadQueueTests: TempDirTestCase {
    private func request(_ name: String, account: UUID? = nil) -> DownloadRequest {
        DownloadRequest(appID: 1, output: tempDir.appendingPathComponent("\(name).ipa"), accountID: account)
    }

    private func status(_ queue: DownloadQueue, _ id: UUID) async -> DownloadItemStatus? {
        await queue.item(id)?.status
    }

    private func statuses(_ queue: DownloadQueue, _ ids: [UUID]) async -> [DownloadItemStatus?] {
        var result: [DownloadItemStatus?] = []
        for id in ids { result.append(await queue.item(id)?.status) }
        return result
    }

    /// 等若干毫秒，确认「不该发生的事」确实没有发生。
    private func settle() async throws { try await Task.sleep(nanoseconds: 80_000_000) }

    // MARK: 上限与钳制

    func testDefaultLimitIsOneAndSetterClamps() async {
        let queue = DownloadQueue(makeTask: { FakeTaskFactory().make($0) })
        var limit = await queue.maxConcurrentDownloads
        XCTAssertEqual(limit, 1, "默认同时下载 1 个")
        await queue.setMaxConcurrent(0)
        limit = await queue.maxConcurrentDownloads
        XCTAssertEqual(limit, 1)
        await queue.setMaxConcurrent(5)
        limit = await queue.maxConcurrentDownloads
        XCTAssertEqual(limit, 3)
        await queue.setMaxConcurrent(-2)
        limit = await queue.maxConcurrentDownloads
        XCTAssertEqual(limit, 1)
        await queue.setMaxConcurrent(2)
        limit = await queue.maxConcurrentDownloads
        XCTAssertEqual(limit, 2)
        XCTAssertEqual(DownloadQueue.concurrencyRange, 1...3)
    }

    func testLimitOneBehavesLikeSingleSlot() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        await queue.setMaxConcurrent(1)
        let a = await queue.add(request("a"))
        let b = await queue.add(request("b"))
        let c = await queue.add(request("c"))
        await waitUntil { factory[0].isWaiting }
        try await settle()
        var s = await statuses(queue, [a, b, c])
        XCTAssertEqual(s, [.running, .queued, .queued])
        XCTAssertEqual(factory[1].startCount + factory[2].startCount, 0)
        var active = await queue.activeItemIDs
        XCTAssertEqual(active, [a])

        factory[0].finish(.completed(sampleResult(tempDir.appendingPathComponent("a.ipa"))))
        await waitUntil { factory[1].isWaiting }
        try await settle()
        s = await statuses(queue, [b, c])
        XCTAssertEqual(s, [.running, .queued])
        active = await queue.activeItemIDs
        XCTAssertEqual(active, [b])
        let first = await queue.activeItemID
        XCTAssertEqual(first, b, "兼容接口 activeItemID 仍可用")
    }

    func testLimitOneStillSwitchesToHeadOfQueueFirst() async throws {
        // 上限 1：队首属于另一个账号时，仍按先进先出先切换到它（与单槽位时代一致），不越过它先跑当前账号的任务
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let switching = FakeDownloadSwitching()
        let a = UUID(), b = UUID()
        switching.current.value = a
        await queue.setAccountSwitching(switching)
        let other = await queue.add(request("other", account: b))
        let mine = await queue.add(request("mine", account: a))
        await waitUntil { factory[0].isWaiting }
        XCTAssertEqual(switching.calls.value, [b])
        let s = await statuses(queue, [other, mine])
        XCTAssertEqual(s, [.running, .queued])
        XCTAssertEqual(factory[1].startCount, 0)
    }

    func testRaisingLimitStartsQueuedTasksImmediately() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let ids = [await queue.add(request("a")), await queue.add(request("b")), await queue.add(request("c"))]
        await waitUntil { factory[0].isWaiting }
        await queue.setMaxConcurrent(3)
        await waitUntil { factory.all.allSatisfy(\.isWaiting) }
        let s = await statuses(queue, ids)
        XCTAssertEqual(s, [.running, .running, .running])
    }

    // MARK: 同账号并发

    func testLimitThreeRunsThreeSameAccountTasksAndQueuesFourth() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let switching = FakeDownloadSwitching()
        let a = UUID()
        switching.current.value = a
        await queue.setAccountSwitching(switching)
        await queue.setMaxConcurrent(3)
        var ids: [UUID] = []
        for name in ["a1", "a2", "a3", "a4"] { ids.append(await queue.add(request(name, account: a))) }
        await waitUntil { (0..<3).allSatisfy { factory[$0].isWaiting } }
        try await settle()
        var s = await statuses(queue, ids)
        XCTAssertEqual(s, [.running, .running, .running, .queued])
        XCTAssertEqual(factory[3].startCount, 0)
        XCTAssertTrue(switching.calls.value.isEmpty, "同账号不切换")
        let active = await queue.activeItemIDs
        XCTAssertEqual(active, Array(ids.prefix(3)))

        factory[1].finish(.completed(sampleResult(tempDir.appendingPathComponent("a2.ipa"))))
        await waitUntil { factory[3].isWaiting }
        s = await statuses(queue, ids)
        XCTAssertEqual(s[0], .running)
        XCTAssertEqual(s[2], .running)
        XCTAssertEqual(s[3], .running, "空出槽位后补位")
    }

    func testConcurrentProgressEventsDoNotCrossOver() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        await queue.setMaxConcurrent(2)
        let x = await queue.add(request("x"))
        let y = await queue.add(request("y"))
        await waitUntil { factory[0].isWaiting && factory[1].isWaiting }
        let px = DownloadProgress(fraction: 0.25, bytes: 25, total: 100, bytesPerSecond: 10, source: .progressBar)
        let py = DownloadProgress(fraction: 0.75, bytes: 300, total: 400, bytesPerSecond: 50, source: .progressBar)
        factory[0].emit(.progress(px))
        factory[1].emit(.progress(py))
        factory[0].emit(.log("x log"))
        await waitUntil {
            let lx = await queue.item(x)?.lastLog
            let gy = await queue.item(y)?.progress
            return lx == "x log" && gy == py
        }
        let ix = await queue.item(x), iy = await queue.item(y)
        XCTAssertEqual(ix?.progress, px)
        XCTAssertEqual(iy?.progress, py)
        XCTAssertNil(iy?.lastLog, "日志不串到另一个任务")
    }

    // MARK: 跨账号

    func testOtherAccountTaskWaitsUntilAllCurrentAccountTasksFinish() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let switching = FakeDownloadSwitching()
        let a = UUID(), b = UUID()
        switching.current.value = a
        await queue.setAccountSwitching(switching)
        await queue.setMaxConcurrent(3)
        let a1 = await queue.add(request("a1", account: a))
        let b1 = await queue.add(request("b1", account: b))
        let a2 = await queue.add(request("a2", account: a))
        await waitUntil { factory[0].isWaiting && factory[2].isWaiting }
        try await settle()
        var s = await statuses(queue, [a1, b1, a2])
        XCTAssertEqual(s, [.running, .queued, .running], "补位优先取当前账号的任务，跨账号任务排队")
        XCTAssertTrue(switching.calls.value.isEmpty)

        factory[0].finish(.completed(sampleResult(tempDir.appendingPathComponent("a1.ipa"))))
        await waitUntil { await queue.item(a1)?.status.isFinished == true }
        try await settle()
        s = await statuses(queue, [b1])
        XCTAssertEqual(s, [.queued], "当前账号还有任务在跑时不切换")
        XCTAssertTrue(switching.calls.value.isEmpty)

        factory[2].finish(.completed(sampleResult(tempDir.appendingPathComponent("a2.ipa"))))
        await waitUntil { factory[1].isWaiting }
        XCTAssertEqual(switching.calls.value, [b], "当前账号的任务全部结束后才切换")
        s = await statuses(queue, [b1])
        XCTAssertEqual(s, [.running])
    }

    func testNoRefillWhileSwitchingThenRefillWithNewAccount() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let switching = FakeDownloadSwitching()
        let a = UUID(), b = UUID()
        switching.current.value = a
        switching.holds.value = true
        await queue.setAccountSwitching(switching)
        await queue.setMaxConcurrent(3)
        let b1 = await queue.add(request("b1", account: b))
        await waitUntil { switching.isHolding }
        // 切换期间再加入：同为 b 的任务、当前账号 a 的任务、无账号的旧任务——都不能补位
        let b2 = await queue.add(request("b2", account: b))
        let a1 = await queue.add(request("a1", account: a))
        let legacy = await queue.add(request("legacy"))
        try await settle()
        var s = await statuses(queue, [b1, b2, a1, legacy])
        XCTAssertEqual(s, [.switchingAccount, .queued, .queued, .queued], "切换期间不补位")
        XCTAssertEqual(factory.all.map(\.startCount), [0, 0, 0, 0])
        let active = await queue.activeItemIDs
        XCTAssertEqual(active, [b1])

        switching.release()
        await waitUntil { factory[0].isWaiting && factory[1].isWaiting && factory[3].isWaiting }
        try await settle()
        s = await statuses(queue, [b1, b2, a1, legacy])
        XCTAssertEqual(s, [.running, .running, .queued, .running], "切换完成后按新账号补位，旧账号任务继续排队")
        XCTAssertEqual(switching.calls.value, [b])
        XCTAssertEqual(factory[2].startCount, 0)
    }

    // MARK: 运行中调小上限

    func testLoweringLimitKeepsRunningTasksAndStopsRefilling() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        await queue.setMaxConcurrent(3)
        var ids: [UUID] = []
        for name in ["a", "b", "c", "d"] { ids.append(await queue.add(request(name))) }
        await waitUntil { (0..<3).allSatisfy { factory[$0].isWaiting } }

        await queue.setMaxConcurrent(1)
        try await settle()
        var s = await statuses(queue, ids)
        XCTAssertEqual(s, [.running, .running, .running, .queued], "调小不打断已在运行的任务")
        XCTAssertEqual(factory.all.map(\.cancelCount), [0, 0, 0, 0])
        XCTAssertTrue((0..<3).allSatisfy { factory[$0].isWaiting })

        factory[0].finish(.completed(sampleResult(tempDir.appendingPathComponent("a.ipa"))))
        await waitUntil { await queue.item(ids[0])?.status.isFinished == true }
        try await settle()
        s = await statuses(queue, [ids[3]])
        XCTAssertEqual(s, [.queued], "运行数仍不低于上限：不补位")

        factory[1].finish(.completed(sampleResult(tempDir.appendingPathComponent("b.ipa"))))
        await waitUntil { await queue.item(ids[1])?.status.isFinished == true }
        try await settle()
        s = await statuses(queue, [ids[3]])
        XCTAssertEqual(s, [.queued])
        XCTAssertEqual(factory[3].startCount, 0)

        factory[2].finish(.completed(sampleResult(tempDir.appendingPathComponent("c.ipa"))))
        await waitUntil { factory[3].isWaiting }
        let active = await queue.activeItemIDs
        XCTAssertEqual(active, [ids[3]], "降到上限以下才补位，且只补到 1 个")
    }

    // MARK: 暂停 / 取消其中一条

    func testPauseAndCancelOneTaskOthersContinueAndSlotsRefill() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        await queue.setMaxConcurrent(3)
        var ids: [UUID] = []
        for name in ["a", "b", "c", "d", "e"] { ids.append(await queue.add(request(name))) }
        await waitUntil { (0..<3).allSatisfy { factory[$0].isWaiting } }

        await queue.pause(ids[0])
        await waitUntil { await queue.item(ids[0])?.status == .paused && factory[3].isWaiting }
        var s = await statuses(queue, ids)
        XCTAssertEqual(s, [.paused, .running, .running, .running, .queued], "暂停一条：其余继续，第四条补位")

        let tmp = URL(fileURLWithPath: tempDir.appendingPathComponent("b.ipa").path + ".tmp")
        try Data([1, 2, 3]).write(to: tmp)
        await queue.cancel(ids[1])
        await waitUntil { await queue.item(ids[1]) == nil && factory[4].isWaiting }
        XCTAssertEqual(factory[1].cancelCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path), "取消删除 .tmp")
        s = await statuses(queue, [ids[0], ids[2], ids[3], ids[4]])
        XCTAssertEqual(s, [.paused, .running, .running, .running], "取消一条：其余继续，第五条补位")
        XCTAssertEqual(factory[2].cancelCount + factory[3].cancelCount, 0)

        // 继续已暂停的那条：槽位已满，排队
        await queue.resume(ids[0])
        try await settle()
        s = await statuses(queue, [ids[0]])
        XCTAssertEqual(s, [.queued])
        factory[2].finish(.completed(sampleResult(tempDir.appendingPathComponent("c.ipa"))))
        await waitUntil { factory[0].startCount == 2 && factory[0].isWaiting }
        s = await statuses(queue, [ids[0]])
        XCTAssertEqual(s, [.running])
    }

    func testRemoveIsRefusedForAnyRunningTask() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        await queue.setMaxConcurrent(2)
        let a = await queue.add(request("a"))
        let b = await queue.add(request("b"))
        await waitUntil { factory[0].isWaiting && factory[1].isWaiting }
        await queue.remove(b)
        let still = await queue.item(b)
        XCTAssertNotNil(still, "运行中的第二条也不能用 remove 移除")
        _ = a
    }

    // MARK: 恢复与退出

    func testRestoredTasksResumeUpToLimit() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        await queue.setMaxConcurrent(2)
        let ids = [UUID(), UUID(), UUID()]
        for (i, id) in ids.enumerated() { await queue.restore(request("r\(i)"), id: id, progress: nil) }
        try await settle()
        XCTAssertEqual(factory.all.map(\.startCount), [0, 0, 0], "恢复后不自动开始")
        for id in ids { await queue.resume(id) }
        await waitUntil { factory[0].isWaiting && factory[1].isWaiting }
        try await settle()
        let s = await statuses(queue, ids)
        XCTAssertEqual(s, [.running, .running, .queued])
    }

    func testTerminateStopsAllRunningTasksAndStartsNothing() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        await queue.setMaxConcurrent(3)
        var ids: [UUID] = []
        for name in ["a", "b", "c", "d"] { ids.append(await queue.add(request(name))) }
        await waitUntil { (0..<3).allSatisfy { factory[$0].isWaiting } }

        queue.terminateRunningTasks() // 同步调用（App 退出时在主线程）
        await waitUntil {
            let s = await self.statuses(queue, Array(ids.prefix(3)))
            return s.allSatisfy { $0 == .paused }
        }
        XCTAssertEqual(factory.all.map(\.cancelCount), [0, 0, 0, 0], "退出按暂停处理，不是取消")
        XCTAssertTrue((0..<3).allSatisfy { !factory[$0].isWaiting }, "三个子进程都已终止")
        try await settle()
        var s = await statuses(queue, [ids[3]])
        XCTAssertEqual(s, [.queued], "退出途中不补位")
        XCTAssertEqual(factory[3].startCount, 0)

        await queue.setMaxConcurrent(3)
        await queue.resume(ids[0])
        try await settle()
        s = await statuses(queue, [ids[0], ids[3]])
        XCTAssertEqual(s, [.queued, .queued], "退出后不再启动任何任务")
        let active = await queue.activeItemIDs
        XCTAssertTrue(active.isEmpty)
        queue.terminateRunningTasks() // 再次调用无副作用
    }

    func testRunningTaskBoxHoldsAllTasks() {
        let box = RunningTaskBox()
        let factory = FakeTaskFactory()
        let ids = [UUID(), UUID()]
        for id in ids { box.insert(factory.make(request(id.uuidString)), for: id) }
        XCTAssertEqual(box.count, 2)
        box.remove(ids[0])
        XCTAssertEqual(box.count, 1)
        XCTAssertFalse(box.isShutDown)
        XCTAssertEqual(box.shutDown().count, 1)
        XCTAssertTrue(box.isShutDown)
    }
}
