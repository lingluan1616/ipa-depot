import Foundation
import XCTest
@testable import IPADepotCore

// MARK: - 阶段八：下载按钮三态（默认 / 已加入 / 已在队列）与解析中、重复点击去重

@MainActor
final class DownloadButtonPhaseTests: VMTestCase {
    private func makeVM(_ factory: FakeTaskFactory, justAdded: Duration = .milliseconds(150), current: UUID? = nil)
        -> (DownloadsViewModel, DownloadQueue, URL) {
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let dir = tempDir.appendingPathComponent("Downloads/IPA Depot")
        let vm = DownloadsViewModel(queue: queue, destination: {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }, currentAccountID: { current })
        vm.justAddedDuration = justAdded
        vm.startObserving()
        return (vm, queue, dir)
    }

    private func completed(_ file: URL) -> DownloadOutcome {
        .completed(DownloadResult(fileURL: file, purchased: false,
                                  info: IPAInfo(bundleIdentifier: "x", shortVersion: "1.0", bundleVersion: "1", appName: "x")))
    }

    func testIdleThenJustAddedThenInQueueThenIdleAfterCompletion() async throws {
        let factory = FakeTaskFactory()
        let (vm, _, dir) = makeVM(factory)
        let context = DownloadContext(app: app(), platform: .iphone, externalVersionID: nil, versionLabel: "3.8.5")
        XCTAssertEqual(vm.buttonPhase(for: context), .idle, "没有任务：默认")
        XCTAssertTrue(DownloadButtonPhase.idle.isEnabled)

        _ = await vm.enqueue(context)
        XCTAssertEqual(vm.buttonPhase(for: context), .justAdded, "点击后立刻「已加入」")
        XCTAssertFalse(DownloadButtonPhase.justAdded.isEnabled)

        await waitUntil { vm.buttonPhase(for: context) == .inQueue }
        XCTAssertFalse(DownloadButtonPhase.inQueue.isEnabled, "已在队列：禁用")
        XCTAssertTrue(vm.justAdded.isEmpty, "「已加入」约定时长后清除")

        await waitUntil { factory.all.first?.isWaiting == true }
        let file = dir.appendingPathComponent("done.ipa")
        try Data(count: 16).write(to: file)
        factory.all[0].finish(completed(file))
        await waitUntil { vm.completedRows.count == 1 }
        XCTAssertEqual(vm.buttonPhase(for: context), .idle, "任务完成：恢复默认，可再次下载")
    }

    func testFailedTaskRestoresDefaultAndPausedStaysInQueue() async throws {
        let factory = FakeTaskFactory()
        let (vm, queue, _) = makeVM(factory, justAdded: .milliseconds(10))
        let a = DownloadContext(app: app(1, name: "A"), platform: .iphone, externalVersionID: nil, versionLabel: "1.0")
        let b = DownloadContext(app: app(2, name: "B"), platform: .iphone, externalVersionID: nil, versionLabel: "1.0")
        let enqueuedA = await vm.enqueue(a)
        let idA = try XCTUnwrap(enqueuedA)
        _ = await vm.enqueue(b)
        await waitUntil { vm.buttonPhase(for: a) == .inQueue && vm.buttonPhase(for: b) == .inQueue }

        await queue.pause(idA)
        await waitUntil { vm.items.first?.status == .paused }
        XCTAssertEqual(vm.buttonPhase(for: a), .inQueue, "暂停中的任务仍算在队列里")

        await waitUntil { factory.all.count == 2 && factory.all[1].isWaiting }
        factory.all[1].finish(.failed(IpatoolError(kind: .networkUnreachable)))
        await waitUntil { vm.buttonPhase(for: b) == .idle }

        // 取消 → 从队列移除 → 默认
        vm.cancel(idA)
        await waitUntil { vm.buttonPhase(for: a) == .idle }
    }

    func testRapidClicksCreateOneTaskAndReleaseReservedFileNames() async throws {
        let factory = FakeTaskFactory()
        let (vm, _, _) = makeVM(factory)
        let context = DownloadContext(app: app(name: "Vinyl"), platform: .iphone, externalVersionID: nil, versionLabel: "1.0")
        // 连点三次：三个并发入队请求
        async let first = vm.enqueue(context)
        async let second = vm.enqueue(context)
        async let third = vm.enqueue(context)
        let ids = await [first, second, third].compactMap { $0 }
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 1, "三次都返回同一个任务 id")
        await waitUntil { vm.rows.count == 1 }
        XCTAssertEqual(vm.items.count, 1, "下载页只有一条任务")
        XCTAssertEqual(factory.all.count, 1)

        // 命中去重时预留的文件名已释放：同版本号标签的另一个任务只加 (2)
        let other = DownloadContext(app: app(name: "Vinyl"), platform: .iphone, externalVersionID: "42", versionLabel: "1.0")
        _ = await vm.enqueue(other)
        await waitUntil { factory.all.count == 2 }
        XCTAssertEqual(factory.all.map { $0.request.output.lastPathComponent }, ["Vinyl_1.0.ipa", "Vinyl_1.0 (2).ipa"])
    }

    func testVersionsPageMatchesByExternalVersionID() async throws {
        let factory = FakeTaskFactory()
        let (vm, _, _) = makeVM(factory, justAdded: .milliseconds(10), current: UUID())
        let v111 = DownloadContext(app: app(), platform: .iphone, externalVersionID: "111", versionLabel: "1.1.1")
        let v222 = DownloadContext(app: app(), platform: .iphone, externalVersionID: "222", versionLabel: "2.2.2")
        let latest = DownloadContext(app: app(), platform: .iphone, externalVersionID: nil, versionLabel: "3.8.5")
        let ipad111 = DownloadContext(app: app(), platform: .ipad, externalVersionID: "111", versionLabel: "1.1.1")
        _ = await vm.enqueue(v111)
        await waitUntil { vm.buttonPhase(for: v111) == .inQueue }
        XCTAssertEqual(vm.buttonPhase(for: v222), .idle, "其他版本不受影响")
        XCTAssertEqual(vm.buttonPhase(for: latest), .idle, "最新版入口按 externalVersionID = nil 匹配")
        XCTAssertEqual(vm.buttonPhase(for: ipad111), .idle, "平台不同")
        XCTAssertEqual(vm.buttonPhase(for: v111, accountID: UUID()), .idle, "账号不同")
    }
}

/// 公开目录结果：匹配 / 自动切换账号期间按钮为「解析中」，完成后进入「已加入 / 已在队列」。
@MainActor
final class CatalogResolvingPhaseTests: VMTestCase {
    private let jp = AccountRecord(email: "jp@example.test", regionLabel: .japan, passwordState: .saved)
    private let us = AccountRecord(email: "us@example.test", regionLabel: .unitedStates, passwordState: .saved)

    private func catalogRow(_ country: String, id: Int64 = 1606306441) -> AppRowModel {
        AppRowModel(app: AppSummary(id: id, bundleID: "tech.example.\(id)", name: "Vinyl", version: "3.8.5", price: 0,
                                    platforms: ["iphone"], catalogCountry: country), platform: .iphone)
    }

    private func model(accounts: [AccountRecord], active: AccountRecord,
                       vault: InMemoryCredentialVault = InMemoryCredentialVault()) async throws -> AppModel {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: AppModel.firstLoginKey)
        var services = makeServices(root: tempDir, auth: FakeAuth(.success(AccountInfo(name: "", email: active.email))),
                                    defaults: defaults, vault: vault)
        services.catalog = FakeCatalog()
        try services.switcher.store.save(AccountBook(accounts: accounts, activeAccountID: active.id))
        let model = AppModel(services: services)
        model.settings.setDownloadDirectory(tempDir.appendingPathComponent("dl"))
        await model.bootstrap()
        return model
    }

    func testDownloadAndVersionsButtonsShowResolvingWhileSwitching() async throws {
        let model = try await model(accounts: [jp, us], active: jp, vault: InMemoryCredentialVault(["us@example.test": "us", "jp@example.test": "jp"]))
        let row = catalogRow("us")
        XCTAssertEqual(model.downloadPhase(for: row), .idle)

        model.perform(.download(row))
        XCTAssertEqual(model.downloadPhase(for: row), .resolving, "自动切换账号期间：小菊花并禁用")
        XCTAssertFalse(DownloadButtonPhase.resolving.isEnabled)
        XCTAssertFalse(model.isResolving(.versions(row)), "只影响被点的那个按钮")
        XCTAssertEqual(model.downloadPhase(for: catalogRow("us", id: 7)), .idle, "其他行不受影响")

        await waitUntil { !model.downloads.items.isEmpty }
        XCTAssertEqual(model.accounts.active?.id, us.id)
        XCTAssertNil(model.pendingCatalogAction)
        let phase = model.downloadPhase(for: row)
        XCTAssertTrue(phase == .justAdded || phase == .inQueue, "切换完成并入队：\(phase)")
        await waitUntil { model.downloadPhase(for: row) == .inQueue }

        // 再点「历史版本…」到日本区：切换期间同样为解析中（有任务时不能切换，这里先清空队列）
        let id = try XCTUnwrap(model.downloads.items.first?.id)
        model.downloads.cancel(id)
        await waitUntil { model.downloads.items.isEmpty && model.canSwitchAccounts }
        let jpRow = catalogRow("jp")
        model.perform(.versions(jpRow))
        XCTAssertTrue(model.isResolving(.versions(jpRow)))
        await waitUntil { model.accounts.active?.id == self.jp.id && model.searchPath.last == jpRow }
        XCTAssertFalse(model.isResolving(.versions(jpRow)))
    }

    func testOtherAccountTaskShowsInQueueForCatalogRowWhileDownloading() async throws {
        // 有下载进行中时，公开目录任务直接绑定到匹配地区的账号：按钮按该账号推导「已在队列」
        let model = try await model(accounts: [jp, us], active: jp)
        let jpTask = DownloadContext(app: app(55, name: "Running"), platform: .iphone, externalVersionID: nil, versionLabel: "1.0")
        _ = await model.downloads.enqueue(jpTask)
        await waitUntil { model.downloads.hasActiveDownload }

        let row = catalogRow("us")
        model.perform(.download(row))
        await waitUntil { model.downloads.items.count == 2 }
        XCTAssertEqual(model.downloads.items.last?.request.accountID, us.id)
        await waitUntil { model.downloadPhase(for: row) == .inQueue }
        XCTAssertEqual(model.downloadPhase(for: catalogRow("jp")), .idle, "日本区同一 App 不是同一任务")

        // 再点一次也只有两条（去重）
        await model.downloads.enqueue(AppModel.latestContext(row), accountID: us.id)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.downloads.items.count, 2)
    }
}
