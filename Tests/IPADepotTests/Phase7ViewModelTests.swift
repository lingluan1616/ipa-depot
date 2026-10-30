import Foundation
import XCTest
@testable import IPADepotCore

// MARK: - 阶段七：同时下载数（设置持久化、接到队列、下载页排版）

final class ConcurrentDownloadsSettingTests: VMTestCase {
    private func makeSettings(_ defaults: MemoryDefaults) -> SettingsViewModel {
        SettingsViewModel(defaults: defaults, paths: AppPaths(root: tempDir), appVersion: "0.2.0", owner: nil,
                          ipatoolVersion: { "2.7.0" },
                          makeUpdateChecker: { _ in FakeUpdateChecker(result: .upToDate(latest: "0.2.0")) })
    }

    func testDefaultIsOneAndChoicePersists() {
        let defaults = MemoryDefaults()
        let vm = makeSettings(defaults)
        XCTAssertEqual(vm.maxConcurrentDownloads, 1, "默认同时下载 1 个")
        XCTAssertEqual(SettingsViewModel.maxConcurrentDownloadsOptions, [1, 2, 3])
        var notified: [Int] = []
        vm.onMaxConcurrentDownloadsChanged = { notified.append($0) }

        vm.setMaxConcurrentDownloads(3)
        XCTAssertEqual(vm.maxConcurrentDownloads, 3)
        XCTAssertEqual(defaults.integer(forKey: SettingsViewModel.maxConcurrentDownloadsKey), 3)
        XCTAssertEqual(SettingsViewModel.maxConcurrentDownloadsKey, "maxConcurrentDownloads")
        vm.setMaxConcurrentDownloads(3) // 未变化：不重复通知
        vm.setMaxConcurrentDownloads(9) // 钳到 3：未变化
        vm.setMaxConcurrentDownloads(2)
        XCTAssertEqual(notified, [3, 2])

        let again = makeSettings(defaults)
        XCTAssertEqual(again.maxConcurrentDownloads, 2, "重新启动后读回")
    }

    func testOutOfRangeStoredValuesAreClamped() {
        let defaults = MemoryDefaults()
        defaults.set(7, forKey: SettingsViewModel.maxConcurrentDownloadsKey)
        XCTAssertEqual(makeSettings(defaults).maxConcurrentDownloads, 3)
        defaults.set(-1, forKey: SettingsViewModel.maxConcurrentDownloadsKey)
        XCTAssertEqual(makeSettings(defaults).maxConcurrentDownloads, 1)
        defaults.set("abc", forKey: SettingsViewModel.maxConcurrentDownloadsKey)
        XCTAssertEqual(makeSettings(defaults).maxConcurrentDownloads, 1)
    }

    func testBootstrapAppliesSavedLimitAndChangesReachQueue() async {
        let defaults = MemoryDefaults()
        defaults.set(2, forKey: SettingsViewModel.maxConcurrentDownloadsKey)
        let queue = DownloadQueue(makeTask: { FakeDownloadTask(request: $0) })
        let model = AppModel(services: makeServices(root: tempDir, queue: queue, defaults: defaults))
        await model.bootstrap()
        var limit = await queue.maxConcurrentDownloads
        XCTAssertEqual(limit, 2, "启动时把保存的同时下载数设给队列")

        model.settings.setMaxConcurrentDownloads(3)
        await waitUntil { await queue.maxConcurrentDownloads == 3 }
        model.settings.setMaxConcurrentDownloads(1)
        await waitUntil { await queue.maxConcurrentDownloads == 1 }
        limit = await queue.maxConcurrentDownloads
        XCTAssertEqual(limit, 1)
    }

    func testDownloadsPageGroupsRunningRowsFirst() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let dir = tempDir.appendingPathComponent("Downloads/IPA Depot")
        let vm = DownloadsViewModel(queue: queue, destination: {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        })
        vm.startObserving()
        await queue.setMaxConcurrent(2)
        var ids: [UUID] = []
        for (offset, name) in ["A", "B", "C"].enumerated() {
            // 阶段八起同一任务会去重：三个任务用不同的 App id
            let context = DownloadContext(app: app(Int64(100 + offset), name: name), platform: .iphone,
                                          externalVersionID: nil, versionLabel: "1.0")
            if let id = await vm.enqueue(context) { ids.append(id) }
        }
        await waitUntil { vm.runningCount == 2 && vm.activeRows.count == 3 }
        XCTAssertEqual(vm.activeRows.map(\.context.name), ["A", "B", "C"])
        XCTAssertEqual(vm.activeRows.map(\.statusText), ["正在开始…", "正在开始…", "排队中"])

        // 暂停第一条 → C 补位；进行中的两条排在前面，暂停的排在后面
        vm.pause(ids[0])
        await waitUntil { vm.runningCount == 2 && vm.activeRows.last?.status == .paused }
        XCTAssertEqual(vm.activeRows.map(\.context.name), ["B", "C", "A"])
        XCTAssertTrue(vm.hasActiveDownload)
    }
}
