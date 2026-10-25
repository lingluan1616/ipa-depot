import Foundation
import XCTest
@testable import IPADepotCore

// MARK: - 首次启动不读钥匙串（hasCompletedFirstLogin）

final class FirstLoginFlagTests: VMTestCase {
    private let account = AccountInfo(name: "A", email: "a@example.com")

    func testFirstLaunchDoesNotCallAuthInfo() async {
        let auth = FakeAuth(.success(account))
        let model = AppModel(services: makeServices(root: tempDir, auth: auth))
        XCTAssertFalse(model.hasCompletedFirstLogin)
        await model.bootstrap()
        XCTAssertEqual(auth.infoCount.value, 0, "标志为假：启动不调用 auth info（不读钥匙串）")
        XCTAssertEqual(model.accountState, .signedOut, "侧栏显示未登录")
    }

    func testLaunchAfterFirstLoginChecksAccount() async {
        let auth = FakeAuth(.success(account))
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: AppModel.firstLoginKey)
        let model = AppModel(services: makeServices(root: tempDir, auth: auth, defaults: defaults))
        await model.bootstrap()
        XCTAssertEqual(auth.infoCount.value, 1)
        XCTAssertEqual(model.account, account)
    }

    func testSearchOnFirstLaunchGuidesToLoginWithoutCallingIpatool() async {
        let search = FakeSearch(.success([app()]))
        let auth = FakeAuth(.success(account))
        let model = AppModel(services: makeServices(root: tempDir, auth: auth, search: search))
        await model.bootstrap()
        model.search.query = "音乐"
        await model.search.search()
        XCTAssertEqual(model.search.phase, .signedOut, "先引导登录")
        XCTAssertTrue(search.calls.value.isEmpty)
        XCTAssertEqual(auth.infoCount.value, 0)
    }

    func testSuccessfulLoginSetsFlagAndLogoutClearsIt() async {
        let defaults = MemoryDefaults()
        let auth = FakeAuth(.failure(IpatoolError(kind: .notLoggedIn)))
        let model = AppModel(services: makeServices(root: tempDir, auth: auth, defaults: defaults))
        await model.bootstrap()
        model.beginLogin()
        let login = model.login!
        XCTAssertEqual(login.step, .intro, "点登录先到准备页")
        login.continueFromIntro()
        login.appleID = "a@example.com"
        login.password = "x"
        await login.submitCredentials()
        XCTAssertEqual(model.account?.email, "a@example.com")
        XCTAssertTrue(model.hasCompletedFirstLogin, "首次登录成功后置真")
        XCTAssertEqual(defaults.values[AppModel.firstLoginKey] as? Bool, true)

        await model.logout()
        XCTAssertFalse(model.hasCompletedFirstLogin, "登出成功后置假")
        XCTAssertEqual(model.accountState, .signedOut)
    }

    func testFailedLoginKeepsFlagFalse() async {
        let defaults = MemoryDefaults()
        let model = AppModel(services: makeServices(root: tempDir,
                                                    login: { FakeLoginSession(script: .fail(IpatoolError(kind: .accountDisabled))) },
                                                    defaults: defaults))
        await model.bootstrap()
        model.beginLogin()
        let login = model.login!
        login.continueFromIntro()
        login.appleID = "a@example.com"
        login.password = "x"
        await login.submitCredentials()
        XCTAssertFalse(model.hasCompletedFirstLogin)
        XCTAssertEqual(model.accountState, .signedOut)
    }
}

// MARK: - 下载队列跨启动保存

final class QueuePersistenceTests: VMTestCase {
    private var dir: URL { tempDir.appendingPathComponent("Downloads/IPA Depot") }
    private var store: DownloadQueueStore { DownloadQueueStore(fileURL: tempDir.appendingPathComponent("support/queue.json")) }

    private func makeVM(_ factory: FakeTaskFactory) -> DownloadsViewModel {
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let dir = self.dir
        return DownloadsViewModel(queue: queue, store: store, destination: {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        })
    }

    func testQueuedRunningAndPausedAreSavedFinishedAreNot() async throws {
        let factory = FakeTaskFactory()
        let vm = makeVM(factory)
        vm.startObserving()
        let a = DownloadContext(app: app(), platform: .ipad, externalVersionID: "893783327", versionLabel: "3.8.5")
        let b = DownloadContext(app: app(42, name: "第二个", price: 0, version: "1.0"), platform: .iphone,
                                externalVersionID: nil, versionLabel: nil)
        let idA = await vm.enqueue(a)
        let idB = await vm.enqueue(b, purchase: true)
        await waitUntil { self.store.load().count == 2 }
        var saved = store.load()
        XCTAssertEqual(saved.map(\.id), [idA, idB])
        XCTAssertEqual(saved[0].name, "谜底黑胶")
        XCTAssertEqual(saved[0].versionLabel, "3.8.5")
        XCTAssertEqual(saved[0].externalVersionID, "893783327")
        XCTAssertEqual(saved[0].platform, "ipad")
        XCTAssertEqual(saved[0].displayPlatform, "ipad")
        XCTAssertFalse(saved[0].purchase)
        XCTAssertTrue(saved[1].purchase)
        XCTAssertEqual(saved[1].outputPath, dir.appendingPathComponent("第二个_1.0.ipa").path)

        // 进行中的任务报告了总大小 → 写入 totalBytes
        await waitUntil { factory.all.first?.isWaiting == true }
        let file = dir.appendingPathComponent("谜底黑胶_3.8.5.ipa")
        try Data(count: 10).write(to: file)
        factory.all[0].finish(.completed(DownloadResult(fileURL: file, purchased: false,
                                                        info: IPAInfo(bundleIdentifier: "x", shortVersion: "3.8.5",
                                                                      bundleVersion: "1", appName: "x"))))
        await waitUntil { self.store.load().count == 1 }
        saved = store.load()
        XCTAssertEqual(saved.map(\.id), [idB], "已完成的不再保存")
    }

    func testRestoresAsPausedWithProgressAndResumesWithSameParameters() async throws {
        let output = dir.appendingPathComponent("谜底黑胶_3.8.5.ipa")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 400).write(to: URL(fileURLWithPath: output.path + ".tmp"))
        let entry = PersistedDownload(id: UUID(), appID: 1606306441, name: "谜底黑胶", bundleID: "com.example.1606306441",
                                      versionLabel: "3.8.5", externalVersionID: "893783327", purchase: true,
                                      outputPath: output.path, platform: "ipad", displayPlatform: "ipad", isFree: true,
                                      totalBytes: 1600, addedAt: Date(timeIntervalSince1970: 1_790_000_000))
        try store.save([entry])

        let factory = FakeTaskFactory()
        let vm = makeVM(factory)
        vm.startObserving()
        await waitUntil { vm.activeRows.count == 1 }
        let row = try XCTUnwrap(vm.activeRows.first)
        XCTAssertEqual(row.id, entry.id)
        XCTAssertEqual(row.status, .paused, "恢复为已暂停")
        XCTAssertEqual(row.statusText, "已暂停")
        XCTAssertTrue(row.canResume)
        XCTAssertEqual(row.context.name, "谜底黑胶")
        XCTAssertEqual(row.context.platform, .ipad)
        XCTAssertEqual(row.percentText, "25%")
        XCTAssertEqual(row.progress?.bytes, 400)
        XCTAssertEqual(factory.all.count, 1)
        XCTAssertFalse(factory.all[0].isWaiting, "不自动开始")

        vm.resume(entry.id)
        await waitUntil { factory.all[0].isWaiting }
        XCTAssertEqual(factory.all[0].request, entry.request)
        XCTAssertEqual(store.load().map(\.id), [entry.id], "进行中的任务仍在 queue.json 里（退出即按暂停恢复）")

        // 同名新任务不会占用已恢复任务的文件名
        _ = await vm.enqueue(DownloadContext(app: app(), platform: .ipad, externalVersionID: "893783327", versionLabel: "3.8.5"))
        await waitUntil { factory.all.count == 2 }
        XCTAssertEqual(factory.all[1].request.output.lastPathComponent, "谜底黑胶_3.8.5 (2).ipa")
    }

    func testCancelRestoredDeletesTempAndRemovesFromFile() async throws {
        let output = dir.appendingPathComponent("A_1.0.ipa")
        let tmp = URL(fileURLWithPath: output.path + ".tmp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 5).write(to: tmp)
        let entry = PersistedDownload(id: UUID(), appID: 1, name: "A", bundleID: "a", versionLabel: "1.0",
                                      externalVersionID: nil, purchase: false, outputPath: output.path, platform: nil,
                                      displayPlatform: "iphone", isFree: true, totalBytes: nil, addedAt: Date())
        try store.save([entry])

        let factory = FakeTaskFactory()
        let vm = makeVM(factory)
        vm.startObserving()
        await waitUntil { vm.activeRows.count == 1 }
        vm.cancel(entry.id)
        await waitUntil { vm.rows.isEmpty }
        await waitUntil { self.store.load().isEmpty }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path), "取消仍删除 .tmp")
    }

    func testPersistSkipsUnchangedContent() async throws {
        let factory = FakeTaskFactory()
        let vm = makeVM(factory)
        vm.startObserving()
        _ = await vm.enqueue(DownloadContext(app: app(), platform: .iphone, externalVersionID: nil, versionLabel: "3.8.5"))
        await waitUntil { vm.items.count == 1 }
        try FileManager.default.removeItem(at: store.fileURL)
        vm.persistNow() // 内容未变化时不重复写
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(vm.persistableEntries(vm.items).count, 1)
    }
}
