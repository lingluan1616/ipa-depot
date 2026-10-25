import Foundation
import XCTest
@testable import IPADepotCore

// MARK: - 下载队列持久化（queue.json）

final class DownloadQueueStoreTests: TempDirTestCase {
    private func entry(_ name: String, total: Int64? = 150_000_000, externalVersionID: String? = "893783327",
                       purchase: Bool = false) -> PersistedDownload {
        PersistedDownload(id: UUID(), appID: 1606306441, name: "谜底黑胶", bundleID: "com.example.mdvinyl",
                          versionLabel: "3.8.5", externalVersionID: externalVersionID, purchase: purchase,
                          outputPath: tempDir.appendingPathComponent("\(name).ipa").path, platform: "ipad",
                          displayPlatform: "ipad", isFree: true, totalBytes: total,
                          addedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testRoundTripKeepsAllFieldsAndWritesVersionedJSON() throws {
        let store = DownloadQueueStore(fileURL: tempDir.appendingPathComponent("sub/queue.json"))
        let items = [entry("a"), entry("b", total: nil, externalVersionID: nil, purchase: true)]
        try store.save(items)
        XCTAssertEqual(store.load(), items)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 1)
        let first = (json?["items"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["appID"] as? Int64, 1606306441)
        XCTAssertEqual(first?["externalVersionID"] as? String, "893783327")
        XCTAssertEqual(first?["purchase"] as? Bool, false)
        XCTAssertEqual(first?["totalBytes"] as? Int64, 150_000_000)
        XCTAssertNotNil(first?["outputPath"] as? String)

        // 再次保存空队列：覆盖为空列表
        try store.save([])
        XCTAssertEqual(store.load(), [])
    }

    func testMissingCorruptOrFutureFileLoadsAsEmpty() throws {
        let url = tempDir.appendingPathComponent("queue.json")
        let store = DownloadQueueStore(fileURL: url)
        XCTAssertEqual(store.load(), [], "文件不存在")
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(store.load(), [], "文件损坏")
        try Data(#"{"version":99,"items":[]}"#.utf8).write(to: url)
        XCTAssertEqual(store.load(), [], "未知的新格式")
    }

    func testRequestAndRestoredProgressFromTempFile() throws {
        let e = entry("a", total: 1000)
        XCTAssertEqual(e.request, DownloadRequest(appID: 1606306441, externalVersionID: "893783327", purchase: false,
                                                  output: URL(fileURLWithPath: e.outputPath), platform: "ipad"))
        XCTAssertEqual(e.restoredProgress()?.bytes, 0, "没有 .tmp 时已下载 0，总大小仍显示")
        XCTAssertEqual(e.restoredProgress()?.total, 1000)

        try Data(count: 250).write(to: URL(fileURLWithPath: e.outputPath + ".tmp"))
        let progress = try XCTUnwrap(e.restoredProgress())
        XCTAssertEqual(progress.bytes, 250)
        XCTAssertEqual(progress.fraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertNil(progress.bytesPerSecond)

        XCTAssertNil(entry("none", total: nil).restoredProgress(), "既无 .tmp 又无总大小")
    }
}

final class DownloadQueueRestoreTests: TempDirTestCase {
    private func request(_ name: String) -> DownloadRequest {
        DownloadRequest(appID: 7, externalVersionID: "123", purchase: true,
                        output: tempDir.appendingPathComponent("\(name).ipa"), platform: "ipad")
    }

    func testRestoredItemIsPausedAndResumesWithSameRequest() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let id = UUID()
        let req = request("a")
        let progress = DownloadProgress(fraction: 0.5, bytes: 50, total: 100, bytesPerSecond: nil, source: .tempFile)
        await queue.restore(req, id: id, progress: progress)
        await queue.restore(req, id: id, progress: nil) // 同 ID 重复恢复被忽略

        let items = await queue.items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.status, .paused)
        XCTAssertEqual(items.first?.progress, progress)
        let active = await queue.activeItemID
        XCTAssertNil(active, "恢复后不自动开始")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(factory[0].startCount, 0)

        await queue.resume(id)
        await waitUntil { factory[0].isWaiting }
        XCTAssertEqual(factory[0].request, req, "继续时用同参数重跑")
        let status = await queue.item(id)?.status
        XCTAssertEqual(status, .running)
    }

    func testCancelRestoredItemDeletesTempFile() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let req = request("b")
        let tmp = URL(fileURLWithPath: req.output.path + ".tmp")
        try Data([1, 2, 3]).write(to: tmp)
        let id = UUID()
        await queue.restore(req, id: id, progress: nil)
        await queue.cancel(id)
        let isEmpty = await queue.items.isEmpty
        XCTAssertTrue(isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
        XCTAssertEqual(factory[0].startCount, 0)
    }

    func testTerminateRunningTasksPausesAndStartsNothingElse() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let id = await queue.add(request("c"))
        let next = await queue.add(request("d"))
        await waitUntil { factory.all.first?.isWaiting == true }
        queue.terminateRunningTasks() // 同步调用（App 退出时在主线程）
        await waitUntil { await queue.item(id)?.status == .paused }
        XCTAssertEqual(factory[0].cancelCount, 0, "退出按暂停处理，不是取消")
        try await Task.sleep(nanoseconds: 50_000_000)
        let nextStatus = await queue.item(next)?.status
        XCTAssertEqual(nextStatus, .queued, "退出途中不启动下一个排队任务")
        XCTAssertEqual(factory[1].startCount, 0)
        queue.terminateRunningTasks() // 没有运行中的任务时无副作用
    }
}
