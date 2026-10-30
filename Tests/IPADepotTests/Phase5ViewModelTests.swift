import Foundation
import XCTest
@testable import IPADepotCore

/// 阶段五：多账号与地区切换（界面层）。
@MainActor
final class Phase5ViewModelTests: VMTestCase {
    private let oldAccount = AccountInfo(name: "Old User", email: "old@example.test")

    func testUpgradeMigrationCreatesAccountAndAsksForRegion() async {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: AppModel.firstLoginKey)
        let model = AppModel(services: makeServices(root: tempDir, auth: FakeAuth(.success(oldAccount)), defaults: defaults))
        await model.bootstrap()
        XCTAssertEqual(model.accounts.accounts.count, 1)
        let record = model.accounts.active
        XCTAssertEqual(record?.email, "old@example.test")
        XCTAssertEqual(record?.passwordState, .missing, "迁移来的账号密码待补")
        XCTAssertEqual(model.accounts.regionPrompt?.id, record?.id, "弹一次地区选择")
        XCTAssertEqual(model.services.currentAccount.id, record?.id)

        // 选择地区后写入账号表；再次启动不再迁移、不再弹窗
        await model.accounts.setRegion(.japan, for: record!)
        model.accounts.regionPrompt = nil
        let again = AppModel(services: makeServices(root: tempDir, auth: FakeAuth(.success(oldAccount)), defaults: defaults))
        await again.bootstrap()
        XCTAssertEqual(again.accounts.active?.regionLabel, .japan)
        XCTAssertNil(again.accounts.regionPrompt)
    }

    func testFirstLaunchWithoutFlagDoesNotMigrate() async {
        let auth = FakeAuth(.success(oldAccount))
        let model = AppModel(services: makeServices(root: tempDir, auth: auth))
        await model.bootstrap()
        XCTAssertTrue(model.accounts.accounts.isEmpty)
        XCTAssertEqual(auth.infoCount.value, 0)
    }

    /// 两个账号：日本（当前）与美国（已存密码）。
    private func twoAccountModel(search: FakeSearch = FakeSearch(.success([app()])),
                                 versions: FakeVersions = FakeVersions(ids: .success(["1", "2"])),
                                 vault: InMemoryCredentialVault = InMemoryCredentialVault(["us@example.test": "us"]),
                                 login: @escaping @Sendable () -> LoginSessioning = { FakeLoginSession(script: .succeed) })
        async throws -> (AppModel, AccountRecord, AccountRecord) {
        let jp = AccountRecord(email: "jp@example.test", regionLabel: .japan, passwordState: .saved)
        let us = AccountRecord(email: "us@example.test", regionLabel: .unitedStates, passwordState: .saved)
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: AppModel.firstLoginKey)
        let services = makeServices(root: tempDir, auth: FakeAuth(.success(AccountInfo(name: "JP", email: jp.email))),
                                    search: search, versions: versions, login: login, defaults: defaults, vault: vault)
        try services.switcher.store.save(AccountBook(accounts: [jp, us], activeAccountID: jp.id))
        let model = AppModel(services: services)
        await model.bootstrap()
        return (model, jp, us)
    }

    func testSwitchUpdatesAccountAndClearsSearchAndVersions() async throws {
        let (model, jp, us) = try await twoAccountModel()
        XCTAssertEqual(model.accounts.active?.id, jp.id)
        model.search.query = "音乐"
        await model.search.search()
        XCTAssertEqual(model.search.rows.count, 1)
        let row = model.search.rows[0]
        let versions = model.versionsModel(for: row)
        await versions.load()
        XCTAssertEqual(versions.rows.count, 2)

        await model.accounts.switchTo(us)
        await waitUntil { model.account?.email == us.email }
        XCTAssertEqual(model.accounts.active?.id, us.id)
        XCTAssertEqual(model.services.currentAccount.id, us.id)
        XCTAssertEqual(model.search.phase, .accountChanged("美国"), "提示「已切换到 美国 账号，请重新搜索」")
        XCTAssertTrue(model.search.rows.isEmpty)
        XCTAssertEqual(versions.phase, .accountChanged("美国"))
        XCTAssertTrue(versions.rows.isEmpty, "历史版本清空且不自动重新请求")
        XCTAssertFalse(model.accounts.isOverlayVisible)
    }

    func testMissingPasswordAsksThenSwitchesAndStoresIt() async throws {
        let vault = InMemoryCredentialVault()
        let (model, _, us) = try await twoAccountModel(vault: vault)
        await model.accounts.switchTo(us)
        let prompt = try XCTUnwrap(model.accounts.passwordPrompt)
        XCTAssertEqual(prompt.purpose, .switchTo)
        XCTAssertEqual(model.accounts.active?.email, "jp@example.test", "未开始切换")
        await model.accounts.submitPassword(prompt, password: "typed")
        await waitUntil { model.account?.email == us.email }
        XCTAssertEqual(try vault.password(for: us.email), "typed")
        XCTAssertEqual(model.accounts.active?.passwordState, .saved)
    }

    func testFailedSwitchShowsAlertAndKeepsPreviousAccount() async throws {
        let failing = IpatoolError(kind: .accountDisabled, raw: "account is disabled")
        let vault = InMemoryCredentialVault(["us@example.test": "us", "jp@example.test": "jp"])
        let calls = Locked(0)
        let (model, jp, us) = try await twoAccountModel(vault: vault, login: {
            calls.mutate { $0 += 1 }
            // 第一次（美国）失败，第二次（回滚日本）成功
            return calls.value == 1 ? FakeLoginSession(script: .fail(failing)) : FakeLoginSession(script: .succeed)
        })
        await model.accounts.switchTo(us)
        await waitUntil { model.accounts.failure != nil }
        XCTAssertEqual(model.accounts.active?.id, jp.id)
        XCTAssertEqual(model.account?.email, jp.email)
        let message = model.accounts.failure?.presentation.message ?? ""
        XCTAssertTrue(message.contains("已恢复为原来的 日本 账号"), message)
    }

    func testEnqueueStampsAccountAndRecordCarriesRegion() async throws {
        let (model, jp, _) = try await twoAccountModel()
        let context = DownloadContext(app: app(), platform: .iphone, externalVersionID: "9", versionLabel: "1.0")
        model.settings.setDownloadDirectory(tempDir.appendingPathComponent("dl"))
        let enqueued = await model.downloads.enqueue(context)
        let id = try XCTUnwrap(enqueued)
        await waitUntil { model.downloads.items.contains { $0.id == id } }
        let item = try XCTUnwrap(model.downloads.items.first { $0.id == id })
        XCTAssertEqual(item.request.accountID, jp.id)
        XCTAssertEqual(model.downloads.persistableEntries(model.downloads.items).first?.accountID, jp.id)
        XCTAssertEqual(model.downloads.rows.first?.regionTitle, "日本")
        XCTAssertEqual(model.accounts.region(for: nil), .japan, "旧记录（无账号）视为当前账号")
    }

    func testAddAccountThroughLoginSheet() async throws {
        let (model, jp, _) = try await twoAccountModel()
        model.beginLogin()
        let login = try XCTUnwrap(model.login)
        XCTAssertEqual(login.mode, .addAccount)
        XCTAssertEqual(login.step, .credentials, "已有账号时跳过准备页")
        login.appleID = "kr@example.test"
        login.password = "kr"
        login.region = .korea
        await login.submitCredentials()
        await waitUntil { model.login == nil }
        XCTAssertEqual(model.accounts.accounts.count, 3)
        XCTAssertEqual(model.accounts.active?.regionLabel, .korea)
        XCTAssertNotEqual(model.accounts.active?.id, jp.id)
        XCTAssertEqual(try model.services.switcher.vault.password(for: "kr@example.test"), "kr")
    }

    func testManualSwitchBlockedWhileDownloading() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let jp = AccountRecord(email: "jp@example.test", regionLabel: .japan, passwordState: .saved)
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: AppModel.firstLoginKey)
        let services = makeServices(root: tempDir, auth: FakeAuth(.success(AccountInfo(name: "", email: jp.email))),
                                    queue: queue, defaults: defaults)
        try services.switcher.store.save(AccountBook(accounts: [jp], activeAccountID: jp.id))
        let model = AppModel(services: services)
        await model.bootstrap()
        XCTAssertTrue(model.canSwitchAccounts)
        model.settings.setDownloadDirectory(tempDir.appendingPathComponent("dl"))
        await model.downloads.enqueue(DownloadContext(app: app(), platform: .iphone, externalVersionID: nil, versionLabel: nil))
        await waitUntil { model.downloads.hasActiveDownload }
        XCTAssertFalse(model.canSwitchAccounts, "有下载进行中时不能手动切换")
    }

    func testRegionTitlesAndStatusText() {
        XCTAssertEqual(AccountRegion.allCases.map(\.title), ["中国大陆", "香港", "台湾", "日本", "美国", "韩国", "其他"])
        let target = AccountRecord(email: "jp@example.test", regionLabel: .japan, passwordState: .saved)
        let progress = AccountSwitchProgress(kind: .switchTo, phase: .loggingIn, target: target, previous: nil)
        XCTAssertEqual(AccountsViewModel.statusText(progress), "正在登录 日本 账号")
        var saving = progress
        saving.phase = .savingCookies
        XCTAssertEqual(AccountsViewModel.statusText(saving), "正在保存当前会话")
    }
}
