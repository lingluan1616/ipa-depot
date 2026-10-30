import Foundation
import XCTest
@testable import IPADepotCore

// MARK: - 失败的下载：保留、重试、跨启动恢复

final class FailedDownloadQueueTests: TempDirTestCase {
    private func request(_ name: String) -> DownloadRequest {
        DownloadRequest(appID: testAppID(name), externalVersionID: "456", purchase: false,
                        output: tempDir.appendingPathComponent("\(name).ipa"), platform: nil)
    }

    private let eof = IpatoolError(kind: .networkUnreachable, raw: "unexpected EOF")

    func testFailureKeepsItemWithReasonAndRetryUsesSameRequest() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let req = request("a")
        let tmp = URL(fileURLWithPath: req.output.path + ".tmp")
        let id = await queue.add(req)
        await waitUntil { factory.all.first?.isWaiting == true }
        try Data(count: 64).write(to: tmp) // 模拟已下载的部分
        factory[0].finish(.failed(eof))
        await waitUntil { await queue.item(id)?.status == .failed(self.eof) }

        let failedValue = await queue.item(id)
        let failed = try XCTUnwrap(failedValue)
        XCTAssertEqual(failed.lastFailure, eof, "失败时记下原因")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path), "失败不删除 .tmp（重试时续传）")
        let active = await queue.activeItemID
        XCTAssertNil(active)

        await queue.resume(id) // 重试
        await waitUntil { factory[0].startCount == 2 }
        XCTAssertEqual(factory.all.count, 1, "重试复用同一任务，不新建")
        XCTAssertEqual(factory[0].request, req, "重试 = 同参数重跑")
        let retriedValue = await queue.item(id)
        let retried = try XCTUnwrap(retriedValue)
        XCTAssertEqual(retried.status, .running)
        XCTAssertNil(retried.lastFailure, "重试时清除上次失败原因")
    }

    func testRestoreWithFailureIsPausedKeepsReasonAndCancelDeletesTemp() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let req = request("b")
        let tmp = URL(fileURLWithPath: req.output.path + ".tmp")
        try Data(count: 8).write(to: tmp)
        let id = UUID()
        await queue.restore(req, id: id, progress: nil, lastFailure: eof)
        let itemValue = await queue.item(id)
        let item = try XCTUnwrap(itemValue)
        XCTAssertEqual(item.status, .paused, "失败任务重启后恢复为暂停")
        XCTAssertEqual(item.lastFailure, eof, "保留失败原因")
        XCTAssertEqual(factory[0].startCount, 0, "不自动开始")

        await queue.cancel(id)
        let isEmpty = await queue.items.isEmpty
        XCTAssertTrue(isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path), "取消删除 .tmp")
    }

    func testCancelFailedItemDeletesTemp() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let req = request("c")
        let tmp = URL(fileURLWithPath: req.output.path + ".tmp")
        let id = await queue.add(req)
        await waitUntil { factory.all.first?.isWaiting == true }
        try Data(count: 16).write(to: tmp)
        factory[0].finish(.failed(eof))
        await waitUntil { await queue.item(id)?.lastFailure != nil }
        await queue.cancel(id)
        let isEmpty = await queue.items.isEmpty
        XCTAssertTrue(isEmpty, "取消失败任务 = 从列表移除")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
    }
}

final class PersistedFailureTests: TempDirTestCase {
    func testFailureRoundTripsAndOldFilesWithoutFailureStillLoad() throws {
        let store = DownloadQueueStore(fileURL: tempDir.appendingPathComponent("queue.json"))
        let error = IpatoolError(kind: .networkUnreachable, raw: "unexpected EOF")
        let entry = PersistedDownload(id: UUID(), appID: 1, name: "A", bundleID: "a", versionLabel: "1.0",
                                      externalVersionID: nil, purchase: false,
                                      outputPath: tempDir.appendingPathComponent("A_1.0.ipa").path, platform: nil,
                                      displayPlatform: "iphone", isFree: true, totalBytes: 100,
                                      addedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                      failure: PersistedFailure(error))
        try store.save([entry])
        let loaded = store.load()
        XCTAssertEqual(loaded, [entry])
        XCTAssertEqual(loaded.first?.failure?.error, error, "恢复出同类别、同原始错误")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        let failure = ((json?["items"] as? [[String: Any]])?.first?["failure"]) as? [String: Any]
        XCTAssertEqual(failure?["message"] as? String, error.message, "文件里保存中文失败原因")
        XCTAssertEqual(failure?["kind"] as? String, "networkUnreachable")
        XCTAssertEqual(failure?["raw"] as? String, "unexpected EOF")

        // 阶段三写的旧文件没有 failure 字段：照常读取
        let old = #"{"version":1,"items":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","appID":1,"name":"A","bundleID":"a","versionLabel":"1.0","purchase":false,"outputPath":"/tmp/A.ipa","displayPlatform":"iphone","isFree":true,"addedAt":"2026-10-26T00:00:00Z"}]}"#
        try Data(old.utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load().count, 1)
        XCTAssertNil(store.load().first?.failure)

        // 未来出现未知类别：按 unknown 处理，不让整份文件失效
        XCTAssertEqual(PersistedFailure(kind: "somethingNew", message: "x", raw: "boom").error.kind, .unknown)
    }
}
