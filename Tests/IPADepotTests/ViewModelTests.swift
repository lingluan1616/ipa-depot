import Foundation
import XCTest
@testable import IPADepotCore

// MARK: - 登录状态机

final class LoginViewModelTests: VMTestCase {
    func testSuccessWithoutTwoFactorClearsSecretAndReportsAccount() async {
        let session = FakeLoginSession(script: .succeed)
        let vm = LoginViewModel(makeSession: { session })
        var reported: AccountInfo?
        vm.onSuccess = { reported = $0 }
        vm.continueFromIntro()
        XCTAssertEqual(vm.step, .credentials)
        vm.appleID = "  user@example.com "
        vm.password = "s3cret"
        XCTAssertTrue(vm.canSubmitCredentials)
        await vm.submitCredentials()
        XCTAssertEqual(session.received.value.first, "user@example.com")
        XCTAssertEqual(vm.password, "", "提交后应立即清空")
        XCTAssertEqual(reported?.email, "user@example.com")
        XCTAssertEqual(vm.account?.name, "Test User")
        XCTAssertFalse(vm.isWorking)
        XCTAssertNil(vm.error)
    }

    func testTwoFactorFlowWithLocalValidation() async {
        let session = FakeLoginSession(script: .twoFactor)
        let vm = LoginViewModel(makeSession: { session })
        vm.step = .credentials
        vm.appleID = "u@example.com"
        vm.password = "x"
        let task = Task { await vm.submitCredentials() }
        await waitUntil { vm.step == .twoFactor }
        XCTAssertFalse(vm.isWorking)

        vm.code = "12345"
        XCTAssertFalse(vm.isCodeValid)
        vm.submitCode()
        XCTAssertEqual(session.codes.value, [], "不合格的验证码不应交给 ipatool")
        XCTAssertNotNil(vm.codeHint)

        vm.code = "123456"
        XCTAssertTrue(vm.isCodeValid)
        vm.submitCode()
        await task.value
        XCTAssertEqual(session.codes.value, ["123456"])
        XCTAssertEqual(vm.account?.email, "u@example.com")
    }

    func testWrongCodeShowsHintAndAsksAgain() async {
        let session = FakeLoginSession(script: .twoFactor)
        let vm = LoginViewModel(makeSession: { session })
        vm.step = .credentials
        vm.appleID = "u@example.com"
        vm.password = "x"
        let task = Task { await vm.submitCredentials() }
        await waitUntil { vm.step == .twoFactor }
        vm.code = "000000"
        vm.submitCode()
        await waitUntil { vm.codeHint?.contains("不正确") == true }
        XCTAssertEqual(vm.step, .twoFactor)
        XCTAssertEqual(vm.code, "")
        vm.code = "111111"
        vm.submitCode()
        await task.value
        XCTAssertEqual(vm.step, .credentials, "最终失败后回到账号密码页")
        XCTAssertEqual(vm.error?.raw, "apple did not complete verification")
    }

    func testFailureShowsChineseMessageAndRaw() async {
        let error = IpatoolError(kind: .accountDisabled, raw: "account is disabled")
        let vm = LoginViewModel(makeSession: { FakeLoginSession(script: .fail(error)) })
        vm.step = .credentials
        vm.appleID = "u@example.com"
        vm.password = "x"
        await vm.submitCredentials()
        XCTAssertEqual(vm.error?.message, error.message)
        XCTAssertEqual(vm.error?.raw, "account is disabled")
        XCTAssertNil(vm.account)
    }

    func testCancelSuppressesCancelledError() {
        let vm = LoginViewModel(makeSession: { FakeLoginSession(script: .succeed) })
        vm.cancel()
        vm.handle(.failed(IpatoolError(kind: .cancelled)))
        XCTAssertNil(vm.error)
    }

    func testInputRules() {
        let vm = LoginViewModel(makeSession: { FakeLoginSession(script: .succeed) })
        XCTAssertFalse(vm.canSubmitCredentials)
        vm.appleID = "   "
        vm.password = "x"
        XCTAssertFalse(vm.canSubmitCredentials)
        XCTAssertTrue(LoginViewModel.isValidCode(" 654321 "))
        XCTAssertFalse(LoginViewModel.isValidCode("65432a"))
        XCTAssertFalse(LoginViewModel.isValidCode("１２３４５６"), "全角数字不算")
        XCTAssertEqual(LoginViewModel.describe(log: "downloading unicorn library"), "正在下载认证组件…")
        XCTAssertEqual(LoginViewModel.describe(log: "something else"), "something else")
    }
}

// MARK: - 搜索

final class SearchViewModelTests: VMTestCase {
    func testMapsResults() async {
        let apps = [app(1, name: "免费", price: 0, platforms: ["iphone", "ipad", "ios"]),
                    app(2, name: "付费", price: 12, platforms: ["macos"]),
                    app(1, name: "重复")]
        let service = FakeSearch(.success(apps))
        let vm = SearchViewModel(service: service, isSignedIn: { true })
        vm.query = " 音乐 "
        vm.platform = .ipad
        vm.limit = 50
        await vm.search()
        XCTAssertEqual(service.calls.value, ["音乐|50|ipad"])
        XCTAssertEqual(vm.phase, .results)
        XCTAssertEqual(vm.rows.map(\.id), [1, 2], "按 ID 去重")
        XCTAssertEqual(vm.rows[0].priceText, "免费")
        XCTAssertEqual(vm.rows[1].priceText, "¥12")
        XCTAssertEqual(vm.rows[0].platformTags, ["iPhone", "iPad"])
        XCTAssertEqual(vm.rows[1].platformTags, ["Mac"])
        XCTAssertEqual(vm.lastQuery, "音乐")
    }

    func testEmptyAndSignedOutStates() async {
        let vm = SearchViewModel(service: FakeSearch(.success([])), isSignedIn: { true })
        vm.query = "zzz"
        await vm.search()
        XCTAssertEqual(vm.phase, .empty)

        let service = FakeSearch(.success([app()]))
        let signedOut = SearchViewModel(service: service, isSignedIn: { false })
        signedOut.query = "a"
        await signedOut.search()
        XCTAssertEqual(signedOut.phase, .signedOut)
        XCTAssertEqual(service.calls.value, [], "未登录不调用 ipatool")

        let expired = SearchViewModel(service: FakeSearch(.failure(IpatoolError(kind: .notLoggedIn))), isSignedIn: { true })
        expired.query = "a"
        await expired.search()
        XCTAssertEqual(expired.phase, .signedOut)
    }

    func testNetworkErrorMentionsMainlandProxy() async {
        let error = IpatoolError(kind: .networkUnreachable, raw: "dial tcp: lookup p25-buy.itunes.apple.com: no such host")
        let vm = SearchViewModel(service: FakeSearch(.failure(error)), isSignedIn: { true })
        vm.query = "a"
        await vm.search()
        guard case .failed(let presentation) = vm.phase else { return XCTFail("应为失败态") }
        XCTAssertTrue(presentation.message.contains("中国大陆"))
        XCTAssertEqual(presentation.raw, error.raw)
        vm.reset()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertTrue(vm.rows.isEmpty)
    }

    func testPlatformValues() {
        XCTAssertEqual(SearchPlatform.mac.ipatoolValue, "macos")
        XCTAssertNil(SearchPlatform.iphone.downloadPlatform)
        XCTAssertEqual(SearchPlatform.ipad.downloadPlatform, "ipad")
        XCTAssertEqual(SearchViewModel.limits, [10, 25, 50])
        XCTAssertEqual(Format.price(6.5), "¥6.5")
    }
}

// MARK: - 历史版本

final class VersionsViewModelTests: VMTestCase {
    private func ids(_ n: Int) -> [String] { (1...n).map { String(1000 + $0) } }

    func testReversedOrderWithLatestFirst() async {
        let vm = VersionsViewModel(app: app(), service: FakeVersions(ids: .success(["1", "2", "3", "3"])))
        await vm.load()
        XCTAssertEqual(vm.phase, .loaded)
        XCTAssertEqual(vm.rows.map(\.id), ["3", "2", "1"])
        XCTAssertEqual(vm.rows.map(\.isLatest), [true, false, false])
    }

    func testLazyBatchesOnlyNearVisibleRows() async {
        let service = FakeVersions(ids: .success(ids(150)))
        let vm = VersionsViewModel(app: app(), service: service)
        vm.batchSize = 10
        vm.lookahead = 5
        vm.lookbehind = 2
        await vm.load()
        let rows = vm.rows.map(\.id)
        for id in rows.prefix(12) { vm.rowAppeared(id) }
        await vm.pumpTask?.value
        XCTAssertEqual(service.batches.value, [Array(rows[0..<10]), Array(rows[10..<17])])
        XCTAssertEqual(vm.loadedCount, 17)
        XCTAssertNotNil(vm.rows[0].metadata)
        XCTAssertNil(vm.rows[17].metadata, "可见区域 + 预取之外的不加载")

        // 滚动到 100–105
        for id in rows.prefix(12) { vm.rowDisappeared(id) }
        for id in rows[100...105] { vm.rowAppeared(id) }
        await vm.pumpTask?.value
        XCTAssertEqual(service.batches.value.count, 4)
        XCTAssertEqual(service.batches.value[2], Array(rows[98..<108]))
        XCTAssertEqual(service.batches.value[3], Array(rows[108..<111]))
        XCTAssertNil(vm.rows[50].metadata)
    }

    func testFailedRowCanRetry() async {
        let service = FakeVersions(ids: .success(["1", "2", "3"]))
        service.failing.value = ["2"]
        let vm = VersionsViewModel(app: app(), service: service)
        await vm.load()
        for row in vm.rows { vm.rowAppeared(row.id) }
        await vm.pumpTask?.value
        XCTAssertEqual(vm.rows.map(\.failed), [false, true, false])
        service.failing.value = []
        vm.retry("2")
        await vm.pumpTask?.value
        XCTAssertEqual(vm.rows[1].metadata?.displayVersion, "v2")
        XCTAssertFalse(vm.rows[1].failed)
        XCTAssertEqual(service.batches.value.last, ["2"])
    }

    func testLicenseRequiredAndContexts() async {
        let vm = VersionsViewModel(app: app(price: 0),
                                   service: FakeVersions(ids: .failure(IpatoolError(kind: .licenseRequired, raw: "license is required"))))
        await vm.load()
        XCTAssertEqual(vm.phase, .licenseRequired)
        let latest = vm.context(for: nil)
        XCTAssertNil(latest.externalVersionID)
        XCTAssertEqual(latest.versionLabel, "3.8.5")
        let row = VersionsViewModel.Row(id: "846770304", metadata: nil)
        XCTAssertEqual(vm.context(for: row).versionLabel, "846770304", "版本号未加载时用外部版本 ID 命名")
        let loaded = VersionsViewModel.Row(id: "9", metadata: FakeVersions.meta("9"))
        XCTAssertEqual(vm.context(for: loaded).versionLabel, "v9")
    }

    func testOtherErrorsShowFailure() async {
        let vm = VersionsViewModel(app: app(), service: FakeVersions(ids: .failure(IpatoolError(kind: .passwordTokenExpired))))
        await vm.load()
        guard case .failed(let p) = vm.phase else { return XCTFail() }
        XCTAssertEqual(p.message, IpatoolError(kind: .passwordTokenExpired).message)
    }
}

// MARK: - 下载队列与记录

final class DownloadsViewModelTests: VMTestCase {
    private func makeVM(_ factory: FakeTaskFactory) -> (DownloadsViewModel, DownloadQueue, URL) {
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let dir = tempDir.appendingPathComponent("Downloads/IPA Depot")
        let vm = DownloadsViewModel(queue: queue, destination: {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        })
        vm.startObserving()
        return (vm, queue, dir)
    }

    func testEnqueueNamesFilesAndAvoidsCollisions() async throws {
        let factory = FakeTaskFactory()
        let (vm, _, dir) = makeVM(factory)
        let context = DownloadContext(app: app(name: "谜底/黑胶"), platform: .iphone, externalVersionID: nil, versionLabel: "3.8.5")
        _ = await vm.enqueue(context)
        _ = await vm.enqueue(context)
        await waitUntil { factory.all.count == 2 }
        XCTAssertEqual(factory.all.map { $0.request.output.lastPathComponent }, ["谜底_黑胶_3.8.5.ipa", "谜底_黑胶_3.8.5 (2).ipa"])
        XCTAssertEqual(factory.all[0].request.output.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertFalse(factory.all[0].request.purchase)
        await waitUntil { vm.activeRows.count == 2 }
        XCTAssertEqual(vm.activeRows.map(\.statusText), ["正在开始…", "排队中"])
    }

    func testCompletionWritesRecordAndMovesToCompleted() async throws {
        let factory = FakeTaskFactory()
        let (vm, _, dir) = makeVM(factory)
        var records: [DownloadRecord] = []
        vm.onRecord = { records.append($0) }
        let context = DownloadContext(app: app(), platform: .iphone, externalVersionID: "893783327", versionLabel: "3.8.5")
        _ = await vm.enqueue(context)
        await waitUntil { factory.all.first?.isWaiting == true }
        let file = dir.appendingPathComponent("谜底黑胶_3.8.5.ipa")
        try Data(count: 2048).write(to: file)
        factory.all[0].finish(.completed(DownloadResult(fileURL: file, purchased: false,
                                                        info: IPAInfo(bundleIdentifier: "x", shortVersion: "3.8.5",
                                                                      bundleVersion: "1", appName: "x"))))
        await waitUntil { vm.completedRows.count == 1 }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.version, "3.8.5")
        XCTAssertEqual(records.first?.externalVersionID, "893783327")
        XCTAssertEqual(records.first?.size, 2048)
        XCTAssertEqual(records.first?.bundleID, "com.example.1606306441")
        XCTAssertEqual(vm.completedRows.first?.fileURL, file)
        XCTAssertEqual(vm.activeCount, 0)
        // 再次收到同一快照不会重复写记录
        vm.apply(vm.items)
        XCTAssertEqual(records.count, 1)
    }

    func testLicenseRequiredPromptsAndRetriesWithPurchase() async throws {
        let factory = FakeTaskFactory()
        let (vm, _, _) = makeVM(factory)
        _ = await vm.enqueue(DownloadContext(app: app(price: 0), platform: .iphone, externalVersionID: nil, versionLabel: nil))
        await waitUntil { factory.all.first?.isWaiting == true }
        factory.all[0].finish(.failed(IpatoolError(kind: .licenseRequired, raw: "license is required")))
        await waitUntil { vm.licensePrompt != nil }
        let prompt = try XCTUnwrap(vm.licensePrompt)
        XCTAssertTrue(prompt.isFree)
        await vm.confirmLicense(prompt)
        await waitUntil { factory.all.count == 2 }
        XCTAssertTrue(factory.all[1].request.purchase)
        await waitUntil { vm.rows.count == 1 }
        XCTAssertEqual(vm.rows.first?.output, factory.all[1].request.output)
    }

    func testPaidAppLicensePromptDoesNotPurchase() async {
        let factory = FakeTaskFactory()
        let (vm, _, _) = makeVM(factory)
        let paid = DownloadContext(app: app(price: 30), platform: .iphone, externalVersionID: nil, versionLabel: nil)
        vm.requestLicense(for: paid)
        let prompt = vm.licensePrompt!
        XCTAssertFalse(prompt.isFree)
        await vm.confirmLicense(prompt)
        XCTAssertNil(vm.licensePrompt)
        XCTAssertEqual(factory.all.count, 0)
    }

    func testRowTextMapping() {
        let ctx = DownloadContext(app: app(), platform: .iphone, externalVersionID: nil, versionLabel: nil)
        let url = URL(fileURLWithPath: "/tmp/a.ipa")
        let progress = DownloadProgress(fraction: 0.25, bytes: 25_000_000, total: 100_000_000, bytesPerSecond: 1_500_000, source: .progressBar)
        let running = DownloadRow(id: UUID(), context: ctx, status: .running, progress: progress, lastLog: nil, output: url)
        XCTAssertEqual(running.statusText, "正在下载")
        XCTAssertEqual(running.percentText, "25%")
        XCTAssertEqual(running.sizeText, "\(Format.bytes(25_000_000)) / \(Format.bytes(100_000_000))")
        XCTAssertEqual(running.speedText, "\(Format.bytes(1_500_000))/s")
        XCTAssertTrue(running.canPause)
        let indeterminate = DownloadRow(id: UUID(), context: ctx, status: .running, progress: nil, lastLog: "preparing kbsync", output: url)
        XCTAssertNil(indeterminate.fraction)
        XCTAssertTrue(indeterminate.statusText.contains("准备下载组件"))
        let verifying = DownloadRow(id: UUID(), context: ctx, status: .verifying, progress: progress, lastLog: nil, output: url)
        XCTAssertEqual(verifying.statusText, "正在校验安装包")
        let failed = DownloadRow(id: UUID(), context: ctx, status: .failed(IpatoolError(kind: .appNotFound, raw: "app not found")),
                                 progress: nil, lastLog: nil, output: url)
        XCTAssertEqual(failed.statusText, IpatoolError(kind: .appNotFound).message)
        XCTAssertEqual(failed.errorRaw, "app not found")
        XCTAssertTrue(failed.canResume)
        XCTAssertEqual(ctx.versionLabel, "3.8.5", "最新版用搜索结果里的版本号命名")
    }
}

// MARK: - 记录 / 设置 / 根模型

final class HistoryAndSettingsTests: VMTestCase {
    func testHistoryPersistsNewestFirst() {
        let store = HistoryStore(fileURL: tempDir.appendingPathComponent("history.json"))
        let vm = HistoryViewModel(store: store, fileExists: { $0.hasSuffix("exists.ipa") })
        let old = DownloadRecord(appID: 1, name: "旧", bundleID: "a", version: "1", externalVersionID: nil, size: 1,
                                 path: "/x/exists.ipa", completedAt: Date(timeIntervalSince1970: 1))
        let new = DownloadRecord(appID: 2, name: "新", bundleID: "b", version: "2", externalVersionID: "9", size: 2,
                                 path: "/x/gone.ipa", completedAt: Date(timeIntervalSince1970: 2))
        vm.add(old)
        vm.add(new)
        XCTAssertEqual(vm.records.map(\.name), ["新", "旧"])
        XCTAssertTrue(vm.exists(old))
        XCTAssertFalse(vm.exists(new), "文件不存在时灰显")

        let reloaded = HistoryViewModel(store: store)
        XCTAssertEqual(reloaded.records.map(\.name), ["新", "旧"])
        reloaded.remove(new.id)
        XCTAssertEqual(HistoryViewModel(store: store).records.map(\.name), ["旧"])
        reloaded.clear()
        XCTAssertTrue(HistoryViewModel(store: store).records.isEmpty)
    }

    func testDownloadDirectorySetting() throws {
        let defaults = MemoryDefaults()
        let paths = AppPaths(root: tempDir)
        let vm = SettingsViewModel(defaults: defaults, paths: paths, appVersion: "0.1.0", owner: nil,
                                   ipatoolVersion: { "2.7.0" }, makeUpdateChecker: { _ in FakeUpdateChecker(result: .upToDate(latest: "0.1.0")) })
        XCTAssertEqual(vm.downloadDirectory, SettingsViewModel.defaultDownloadDirectory)
        XCTAssertTrue(vm.downloadDirectory.path.hasSuffix("Downloads/IPA Depot"))
        let custom = tempDir.appendingPathComponent("out", isDirectory: true)
        vm.setDownloadDirectory(custom)
        XCTAssertEqual(defaults.string(forKey: SettingsViewModel.downloadDirectoryKey), custom.standardizedFileURL.path)
        XCTAssertEqual(try vm.ensureDownloadDirectory().path, custom.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: custom.path))
        let again = SettingsViewModel(defaults: defaults, paths: paths, owner: nil, ipatoolVersion: { "" },
                                      makeUpdateChecker: { _ in FakeUpdateChecker(result: .upToDate(latest: "")) })
        XCTAssertEqual(again.downloadDirectory.path, custom.standardizedFileURL.path)
        again.resetDownloadDirectory()
        XCTAssertNil(defaults.string(forKey: SettingsViewModel.downloadDirectoryKey))
    }

    func testCacheClearOnlyTouchesOwnCache() async throws {
        let paths = AppPaths(root: tempDir)
        let fm = FileManager.default
        try fm.createDirectory(at: paths.versionsCacheDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.artworkCacheDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.stateDirectory, withIntermediateDirectories: true)
        try Data(count: 300).write(to: paths.versionsCacheDirectory.appendingPathComponent("1.json"))
        try Data(count: 500).write(to: paths.artworkCacheDirectory.appendingPathComponent("1.img"))
        try Data(count: 10).write(to: paths.stateDirectory.appendingPathComponent("keep"))
        try Data(count: 10).write(to: paths.historyFile)
        let vm = SettingsViewModel(defaults: MemoryDefaults(), paths: paths, owner: nil, ipatoolVersion: { "2.7.0" },
                                   makeUpdateChecker: { _ in FakeUpdateChecker(result: .upToDate(latest: "")) })
        var cleared = false
        vm.onCacheCleared = { cleared = true }
        await vm.refreshCacheSizes()
        XCTAssertEqual(vm.versionsCacheSize, 300)
        XCTAssertEqual(vm.artworkCacheSize, 500)
        await vm.clearCache()
        XCTAssertEqual(vm.totalCacheSize, 0)
        XCTAssertTrue(cleared)
        XCTAssertTrue(fm.fileExists(atPath: paths.stateDirectory.appendingPathComponent("keep").path))
        XCTAssertTrue(fm.fileExists(atPath: paths.historyFile.path))
        await vm.loadIpatoolVersion()
        XCTAssertEqual(vm.ipatoolVersion, "2.7.0")
    }

    func testUpdateCheck() async throws {
        let release = ReleaseInfo(tag: "v0.2.0", version: "0.2.0", htmlURL: URL(string: "https://github.com/o/ipa-depot/releases/tag/v0.2.0")!, name: nil)
        let disabled = SettingsViewModel(defaults: MemoryDefaults(), paths: AppPaths(root: tempDir), appVersion: "0.1.0", owner: nil,
                                         ipatoolVersion: { "" }, makeUpdateChecker: { _ in FakeUpdateChecker(result: .updateAvailable(release)) })
        XCTAssertFalse(disabled.canCheckForUpdates, "owner 未填时禁用")
        await disabled.checkForUpdates()
        XCTAssertEqual(disabled.updateState, .idle)

        let enabled = SettingsViewModel(defaults: MemoryDefaults(), paths: AppPaths(root: tempDir), appVersion: "0.1.0", owner: "o",
                                        ipatoolVersion: { "" }, makeUpdateChecker: { _ in FakeUpdateChecker(result: .updateAvailable(release)) })
        XCTAssertTrue(enabled.canCheckForUpdates)
        await enabled.checkForUpdates()
        XCTAssertEqual(enabled.updateState, .available(release))
        XCTAssertNil(ProjectInfo.projectURL)
        XCTAssertEqual(ProjectInfo.displayURL, "https://github.com/<owner>/ipa-depot")
    }

    func testAppModelBootstrapStates() async {
        let signedOut = AppModel(services: makeServices(root: tempDir))
        await signedOut.refreshAccount()
        XCTAssertEqual(signedOut.accountState, .signedOut, "未登录不是错误")

        let auth = FakeAuth(.success(AccountInfo(name: "A", email: "a@example.com")))
        let signedIn = AppModel(services: makeServices(root: tempDir, auth: auth))
        await signedIn.refreshAccount()
        XCTAssertEqual(signedIn.account?.email, "a@example.com")

        let broken = AppModel(services: makeServices(root: tempDir, auth: FakeAuth(.failure(IpatoolError(kind: .keychainNotFound)))))
        await broken.refreshAccount()
        guard case .unknown(let p) = broken.accountState else { return XCTFail() }
        XCTAssertEqual(p.message, IpatoolError(kind: .keychainNotFound).message)
    }

    func testAppModelLoginAndLogout() async {
        let auth = FakeAuth(.failure(IpatoolError(kind: .notLoggedIn)))
        let search = FakeSearch(.success([app()]))
        let model = AppModel(services: makeServices(root: tempDir, auth: auth, search: search))
        await model.refreshAccount()
        model.beginLogin()
        let login = model.login!
        login.step = .credentials
        login.appleID = "a@example.com"
        login.password = "x"
        await login.submitCredentials()
        XCTAssertNil(model.login, "登录成功后关闭登录窗口")
        XCTAssertEqual(model.account?.email, "a@example.com")

        model.search.query = "音乐"
        await model.search.search()
        XCTAssertEqual(model.search.rows.count, 1)
        let row = model.search.rows[0]
        model.searchPath = [row]
        XCTAssertTrue(model.versionsModel(for: row) === model.versionsModel(for: row), "同一 App 复用版本视图模型")

        await model.logout()
        XCTAssertEqual(auth.revokeCount.value, 1)
        XCTAssertEqual(model.accountState, .signedOut)
        XCTAssertTrue(model.search.rows.isEmpty)
        XCTAssertTrue(model.searchPath.isEmpty)
    }
}
