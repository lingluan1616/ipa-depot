import Foundation
import XCTest
@testable import IPADepotCore

// MARK: - 失败的下载：界面状态、重试、持久化、恢复

final class FailedDownloadViewModelTests: VMTestCase {
    private var dir: URL { tempDir.appendingPathComponent("Downloads/IPA Depot") }
    private var store: DownloadQueueStore { DownloadQueueStore(fileURL: tempDir.appendingPathComponent("support/queue.json")) }
    private let eof = IpatoolError(kind: .networkUnreachable, raw: "unexpected EOF")

    private func makeVM(_ factory: FakeTaskFactory) -> DownloadsViewModel {
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let dir = self.dir
        return DownloadsViewModel(queue: queue, store: store, destination: {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        })
    }

    private var context: DownloadContext {
        DownloadContext(app: app(), platform: .ipad, externalVersionID: "893783327", versionLabel: "3.8.5")
    }

    func testFailedTaskStaysWithReasonAndRetryUsesSameParameters() async throws {
        let factory = FakeTaskFactory()
        let vm = makeVM(factory)
        vm.startObserving()
        let idValue = await vm.enqueue(context, purchase: true)
        let id = try XCTUnwrap(idValue)
        await waitUntil { factory.all.first?.isWaiting == true }
        let firstRequest = factory.all[0].request
        factory.all[0].finish(.failed(eof))
        await waitUntil { vm.activeRows.first?.isFailed == true }

        let row = try XCTUnwrap(vm.activeRows.first)
        XCTAssertEqual(row.id, id, "失败任务留在列表（进行中分组）")
        XCTAssertEqual(row.statusText, "失败：\(eof.message)")
        XCTAssertEqual(row.errorRaw, "unexpected EOF")
        XCTAssertTrue(row.canResume)
        XCTAssertTrue(row.isRetry, "按钮显示为「重试」")
        XCTAssertTrue(row.canCancel)

        vm.resume(id)
        await waitUntil { factory.all.first?.isWaiting == true }
        XCTAssertEqual(factory.all.count, 1)
        XCTAssertEqual(factory.all[0].request, firstRequest, "重试 = 同参数重跑（同一输出路径，ipatool 用 .tmp 续传）")
        await waitUntil { vm.activeRows.first?.status == .running }
        XCTAssertNil(vm.activeRows.first?.lastFailure)
    }

    func testFailedTaskIsPersistedWithReasonButLicenseRequiredIsNot() async throws {
        let factory = FakeTaskFactory()
        let vm = makeVM(factory)
        vm.startObserving()
        let failedIDValue = await vm.enqueue(context)
        let failedID = try XCTUnwrap(failedIDValue)
        let licenseIDValue = await vm.enqueue(DownloadContext(app: app(42, name: "要许可"), platform: .iphone,
                                                              externalVersionID: nil, versionLabel: "1.0"))
        let licenseID = try XCTUnwrap(licenseIDValue)
        await waitUntil { factory.all.first?.isWaiting == true }
        factory.all[0].emit(.progress(DownloadProgress(fraction: 0.5, bytes: 500, total: 1000, bytesPerSecond: nil,
                                                       source: .progressBar)))
        await waitUntil { vm.items.first?.progress?.total == 1000 }
        factory.all[0].finish(.failed(eof))
        await waitUntil { self.store.load().first?.failure != nil }

        var saved = store.load()
        XCTAssertEqual(saved.map(\.id), [failedID, licenseID], "失败任务与后面排队的任务都写入 queue.json")
        XCTAssertEqual(saved[0].failure?.message, eof.message, "持久化含中文失败原因")
        XCTAssertEqual(saved[0].failure?.error, eof)
        XCTAssertEqual(saved[0].totalBytes, 1000)
        XCTAssertNil(saved[1].failure)

        // 第二个任务因「需要许可」失败：保持原有处理（弹领取提示，不写入 queue.json）
        await waitUntil { factory.all.count == 2 && factory.all[1].isWaiting }
        factory.all[1].finish(.failed(IpatoolError(kind: .licenseRequired, raw: "license is required")))
        await waitUntil { vm.licensePrompt != nil }
        XCTAssertEqual(vm.licensePrompt?.itemID, licenseID)
        await waitUntil { self.store.load().count == 1 }
        saved = store.load()
        XCTAssertEqual(saved.map(\.id), [failedID])

        // 退出时立即写盘：内容不变
        vm.persistNow()
        XCTAssertEqual(store.load().map(\.id), [failedID])
    }

    func testRestoredFailedTaskIsPausedKeepsReasonAndRetries() async throws {
        let output = dir.appendingPathComponent("谜底黑胶_3.8.5.ipa")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 300).write(to: URL(fileURLWithPath: output.path + ".tmp"))
        let entry = PersistedDownload(id: UUID(), appID: 1606306441, name: "谜底黑胶", bundleID: "com.example.1606306441",
                                      versionLabel: "3.8.5", externalVersionID: "893783327", purchase: false,
                                      outputPath: output.path, platform: "ipad", displayPlatform: "ipad", isFree: true,
                                      totalBytes: 1200, addedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                      failure: PersistedFailure(eof))
        try store.save([entry])

        let factory = FakeTaskFactory()
        let vm = makeVM(factory)
        vm.startObserving()
        await waitUntil { vm.activeRows.count == 1 }
        let row = try XCTUnwrap(vm.activeRows.first)
        XCTAssertEqual(row.status, .paused, "重启恢复为暂停态")
        XCTAssertEqual(row.lastFailure, eof)
        XCTAssertEqual(row.statusText, "已暂停 · 上次失败：\(eof.message)", "保留失败原因文本")
        XCTAssertEqual(row.errorRaw, "unexpected EOF")
        XCTAssertTrue(row.isRetry)
        XCTAssertEqual(row.percentText, "25%")
        XCTAssertFalse(factory.all[0].isWaiting, "不自动开始")
        XCTAssertEqual(store.load(), [entry], "恢复后再保存仍带失败原因")

        vm.resume(entry.id)
        await waitUntil { factory.all[0].isWaiting }
        XCTAssertEqual(factory.all[0].request, entry.request, "重试用同参数")
        await waitUntil { self.store.load().first?.failure == nil }
        XCTAssertEqual(store.load().map(\.id), [entry.id], "重试中仍保存，失败原因已清除")
    }

    func testCancelFailedTaskDeletesTempAndRemovesFromFile() async throws {
        let factory = FakeTaskFactory()
        let vm = makeVM(factory)
        vm.startObserving()
        let idValue = await vm.enqueue(context)
        let id = try XCTUnwrap(idValue)
        await waitUntil { factory.all.first?.isWaiting == true }
        let tmp = URL(fileURLWithPath: factory.all[0].request.output.path + ".tmp")
        try Data(count: 32).write(to: tmp)
        factory.all[0].finish(.failed(eof))
        await waitUntil { self.store.load().first?.failure != nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path), "失败后保留 .tmp")

        vm.cancel(id)
        await waitUntil { vm.rows.isEmpty }
        await waitUntil { self.store.load().isEmpty }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path), "取消删除 .tmp")
    }
}
