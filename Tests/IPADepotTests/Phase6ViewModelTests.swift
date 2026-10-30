import Foundation
import XCTest
@testable import IPADepotCore

final class FakeCatalog: PublicCatalogSearching, @unchecked Sendable {
    let calls = Locked<[String]>([])
    let result: Result<[AppSummary], IpatoolError>
    init(_ result: Result<[AppSummary], IpatoolError> = .success([])) { self.result = result }
    func search(_ term: String, country: String, limit: Int, platform: String) async throws -> [AppSummary] {
        calls.mutate { $0.append("\(term)|\(country)|\(limit)|\(platform)") }
        return try result.get().map {
            AppSummary(id: $0.id, bundleID: $0.bundleID, name: $0.name, version: $0.version, price: $0.price,
                       platforms: $0.platforms, sellerName: "Seller", catalogCountry: country)
        }
    }
}

/// 阶段六：浏览地区、公开目录结果的账号匹配、启动自动加入账号、迁移盖章（界面层）。
@MainActor
final class Phase6ViewModelTests: VMTestCase {

    private func catalogRow(_ country: String, id: Int64 = 1606306441) -> AppRowModel {
        AppRowModel(app: AppSummary(id: id, bundleID: "tech.example.\(id)", name: "Vinyl", version: "3.8.5", price: 0,
                                    platforms: ["iphone"], catalogCountry: country), platform: .iphone)
    }

    /// 账号表 + 已登录 `active` 的模型。
    private func model(accounts: [AccountRecord], active: AccountRecord?, catalog: FakeCatalog = FakeCatalog(),
                       search: FakeSearch = FakeSearch(.success([app()])),
                       vault: InMemoryCredentialVault = InMemoryCredentialVault(),
                       defaults: MemoryDefaults = MemoryDefaults()) async throws -> AppModel {
        defaults.set(true, forKey: AppModel.firstLoginKey)
        let info: Result<AccountInfo, IpatoolError> = active.map { .success(AccountInfo(name: "", email: $0.email)) }
            ?? .failure(IpatoolError(kind: .notLoggedIn))
        var services = makeServices(root: tempDir, auth: FakeAuth(info), search: search, defaults: defaults, vault: vault)
        services.catalog = catalog
        try services.switcher.store.save(AccountBook(accounts: accounts, activeAccountID: active?.id))
        let model = AppModel(services: services)
        model.settings.setDownloadDirectory(tempDir.appendingPathComponent("dl"))
        await model.bootstrap()
        return model
    }

    private let jp = AccountRecord(email: "jp@example.test", regionLabel: .japan, passwordState: .saved)
    private let us = AccountRecord(email: "us@example.test", regionLabel: .unitedStates, passwordState: .saved)

    func testBrowseRegionSearchesPublicCatalogAndPersists() async throws {
        let catalog = FakeCatalog(.success([app(1), app(2)]))
        let search = FakeSearch(.success([app()]))
        let defaults = MemoryDefaults()
        let model = try await model(accounts: [], active: nil, catalog: catalog, search: search, defaults: defaults)
        XCTAssertEqual(model.search.browseRegion, .followAccount, "默认跟随当前账号")
        model.search.query = "vinyl"
        model.search.setBrowseRegion(.region(.unitedStates, customCode: nil))
        await waitUntil { model.search.phase == .results }
        XCTAssertEqual(catalog.calls.value, ["vinyl|us|25|iphone"], "切换地区后自动重搜，未登录也能搜")
        XCTAssertTrue(model.search.rows.allSatisfy(\.isPublicCatalog))
        XCTAssertTrue(search.calls.value.isEmpty, "不走 ipatool")
        XCTAssertEqual(defaults.string(forKey: BrowseRegion.defaultsKey), "us")
        XCTAssertEqual(model.search.browseRegionTitle, "美国")

        let restored = SearchViewModel(service: search, catalog: catalog, defaults: defaults, isSignedIn: { true })
        XCTAssertEqual(restored.browseRegion, .region(.unitedStates, customCode: nil))
        XCTAssertEqual(BrowseRegion(storageValue: "other:SG"), .region(.other, customCode: "sg"))
        XCTAssertEqual(BrowseRegion(storageValue: "nonsense"), .followAccount)
    }

    func testSwitchingBrowseRegionClearsAndFollowUsesIpatool() async throws {
        let catalog = FakeCatalog(.success([app(1)]))
        let search = FakeSearch(.success([app(9)]))
        let model = try await model(accounts: [jp], active: jp, catalog: catalog, search: search)
        model.search.query = "vinyl"
        model.search.setBrowseRegion(.region(.japan, customCode: nil))
        await waitUntil { model.search.phase == .results }
        model.search.setBrowseRegion(.region(.other, customCode: nil))
        XCTAssertTrue(model.search.rows.isEmpty, "切换地区立即清空结果")
        XCTAssertEqual(catalog.calls.value.count, 1, "「其他」未填代码不搜索")
        model.search.setBrowseRegion(.region(.other, customCode: "sg"))
        await waitUntil { catalog.calls.value.count == 2 && model.search.phase == .results }
        XCTAssertEqual(catalog.calls.value.last, "vinyl|sg|25|iphone")
        model.search.setBrowseRegion(.followAccount)
        await waitUntil { model.search.phase == .results }
        XCTAssertEqual(search.calls.value, ["vinyl|25|iphone"])
        XCTAssertFalse(model.search.rows.contains(where: \.isPublicCatalog))
    }

    func testCatalogActionWithMatchingCurrentAccountContinuesDirectly() async throws {
        let model = try await model(accounts: [jp, us], active: jp)
        let row = catalogRow("jp")
        model.perform(.versions(row))
        XCTAssertEqual(model.searchPath, [row])
        XCTAssertNil(model.missingRegionPrompt)
        XCTAssertFalse(model.accounts.isSwitching)
        XCTAssertNil(model.pendingCatalogAction)
    }

    func testCatalogActionSwitchesToOtherMatchingAccountThenContinues() async throws {
        let model = try await model(accounts: [jp, us], active: jp, vault: InMemoryCredentialVault(["us@example.test": "us"]))
        let row = catalogRow("us")
        model.perform(.versions(row))
        XCTAssertNotNil(model.pendingCatalogAction)
        await waitUntil { model.accounts.active?.id == self.us.id && model.searchPath == [row] }
        XCTAssertEqual(model.account?.email, us.email)
        XCTAssertNil(model.pendingCatalogAction)
        XCTAssertEqual(model.versionsModel(for: row).phase, .loading, "切换后进入历史版本页重新加载")
    }

    func testNoMatchingAccountPromptsAndAddAccountPreselectsRegionThenContinues() async throws {
        let model = try await model(accounts: [jp], active: jp)
        let row = catalogRow("us")
        model.perform(.download(row))
        let prompt = try XCTUnwrap(model.missingRegionPrompt)
        XCTAssertEqual(prompt.countryCode, "us")
        XCTAssertEqual(prompt.regionTitle, "美国")
        XCTAssertTrue(model.downloads.items.isEmpty)

        model.addAccount(for: prompt)
        XCTAssertNil(model.missingRegionPrompt)
        let login = try XCTUnwrap(model.login)
        XCTAssertEqual(login.region, .unitedStates, "地区预选为 X")
        login.appleID = "us@example.test"
        login.password = "us"
        await login.submitCredentials()
        await waitUntil { !model.downloads.items.isEmpty }
        let added = try XCTUnwrap(model.accounts.active)
        XCTAssertEqual(added.regionLabel, .unitedStates)
        XCTAssertEqual(model.downloads.items.first?.request.accountID, added.id)
        let downloadRow = try XCTUnwrap(model.downloads.rows.first)
        XCTAssertTrue(downloadRow.isPublicCatalog)
        XCTAssertEqual(downloadRow.regionTitle, "美国")
        XCTAssertEqual(model.downloads.persistableEntries(model.downloads.items).first?.catalogCountry, "us")
    }

    func testOtherRegionPromptPreselectsCustomCode() async throws {
        let model = try await model(accounts: [jp], active: jp)
        model.perform(.versions(catalogRow("sg")))
        let prompt = try XCTUnwrap(model.missingRegionPrompt)
        XCTAssertEqual(prompt.regionTitle, "SG")
        model.addAccount(for: prompt)
        XCTAssertEqual(model.login?.region, .other)
        XCTAssertEqual(model.login?.customRegionCode, "sg")
    }

    func testStartupAddsSignedInAccountMissingFromBookAndAsksRegion() async throws {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: AppModel.firstLoginKey)
        let services = makeServices(root: tempDir, auth: FakeAuth(.success(AccountInfo(name: "T", email: "terminal@example.test"))),
                                    defaults: defaults)
        try services.switcher.store.save(AccountBook(accounts: [jp], activeAccountID: jp.id))
        try services.historyStore.save([DownloadRecord(appID: 1, name: "A", bundleID: "a", version: "1",
                                                       externalVersionID: nil, size: 1, path: "/a")])
        let model = AppModel(services: services)
        await model.bootstrap()
        XCTAssertEqual(model.accounts.accounts.count, 2)
        let added = try XCTUnwrap(model.accounts.active)
        XCTAssertEqual(added.email, "terminal@example.test")
        XCTAssertEqual(added.passwordState, .missing)
        XCTAssertEqual(model.accounts.regionPrompt?.id, added.id, "弹一次地区选择")
        XCTAssertEqual(model.services.currentAccount.id, added.id)
        XCTAssertNil(services.historyStore.load().first?.accountID, "非迁移不给旧记录盖章")
    }

    func testMigrationStampsLegacyHistoryAndQueue() async throws {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: AppModel.firstLoginKey)
        let services = makeServices(root: tempDir, auth: FakeAuth(.success(AccountInfo(name: "Old", email: "old@example.test"))),
                                    defaults: defaults)
        try services.historyStore.save([DownloadRecord(appID: 1, name: "A", bundleID: "a", version: "1",
                                                       externalVersionID: nil, size: 1, path: "/a")])
        let entry = PersistedDownload(id: UUID(), appID: 2, name: "B", bundleID: "b", versionLabel: "2", externalVersionID: nil,
                                      purchase: false, outputPath: tempDir.appendingPathComponent("b.ipa").path, platform: nil,
                                      displayPlatform: "iphone", isFree: true, totalBytes: nil, addedAt: Date())
        try XCTUnwrap(services.queueStore).save([entry])
        let model = AppModel(services: services)
        await model.bootstrap()
        let id = try XCTUnwrap(model.accounts.active?.id)
        XCTAssertEqual(model.history.records.first?.accountID, id, "记录页已刷新")
        XCTAssertEqual(services.historyStore.load().first?.accountID, id)
        XCTAssertEqual(try XCTUnwrap(services.queueStore).load().first?.accountID, id)
        await waitUntil { model.downloads.items.first?.request.accountID == id }
    }
}
