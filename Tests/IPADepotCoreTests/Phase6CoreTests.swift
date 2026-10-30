import Foundation
import XCTest
@testable import IPADepotCore

/// 阶段六：地区目录、公开目录搜索、账号匹配、迁移盖章、启动自动加入账号（Core）。
final class Phase6CoreTests: TempDirTestCase {

    // MARK: - RegionCatalog

    func testCatalogCoversRegionsInOrderWithCodesAndFlags() {
        XCTAssertEqual(RegionCatalog.regions, [.mainlandChina, .hongKong, .taiwan, .japan, .unitedStates, .korea, .other])
        XCTAssertEqual(RegionCatalog.entries.map(\.countryCode), ["cn", "hk", "tw", "jp", "us", "kr", nil])
        XCTAssertEqual(RegionCatalog.entry(for: .japan).flag, "🇯🇵")
        XCTAssertEqual(RegionCatalog.entry(for: .other).label, "其他")
        XCTAssertEqual(RegionCatalog.entries.map(\.sortOrder), Array(0..<7))
        XCTAssertEqual(AccountRegion.unitedStates.catalogEntry.englishLabel, "United States")
    }

    func testLabelAndCodeLookupBothWays() {
        XCTAssertEqual(RegionCatalog.region(forCode: "US"), .unitedStates)
        XCTAssertEqual(RegionCatalog.region(forCode: " jp "), .japan)
        XCTAssertEqual(RegionCatalog.region(forCode: "sg"), .other, "目录外的有效代码归入「其他」")
        XCTAssertNil(RegionCatalog.region(forCode: "usa"))
        XCTAssertEqual(RegionCatalog.region(forLabel: "香港"), .hongKong)
        XCTAssertEqual(RegionCatalog.region(forLabel: "korea"), .korea)
        XCTAssertNil(RegionCatalog.region(forLabel: "火星"))
        XCTAssertEqual(RegionCatalog.countryCode(for: .taiwan), "tw")
        XCTAssertEqual(RegionCatalog.countryCode(for: .other, customCode: "SG"), "sg")
        XCTAssertNil(RegionCatalog.countryCode(for: .other, customCode: "s1"))
        XCTAssertNil(RegionCatalog.countryCode(for: .other))
    }

    func testCodeNormalizationAndFlags() {
        XCTAssertEqual(RegionCatalog.normalizeCode("GB"), "gb")
        XCTAssertNil(RegionCatalog.normalizeCode("g"))
        XCTAssertNil(RegionCatalog.normalizeCode("日本"))
        XCTAssertNil(RegionCatalog.normalizeCode("1a"))
        XCTAssertEqual(RegionCatalog.flag(forCode: "sg"), "🇸🇬")
        XCTAssertEqual(RegionCatalog.flag(forCode: "x"), "🌐")
    }

    func testResolveStoredValuesForCompatibility() {
        XCTAssertEqual(RegionCatalog.resolve(storedValue: "jp").region, .japan)
        XCTAssertEqual(RegionCatalog.resolve(storedValue: "other").region, .other)
        XCTAssertEqual(RegionCatalog.resolve(storedValue: "日本").region, .japan, "旧值按标签文字映射")
        XCTAssertEqual(RegionCatalog.resolve(storedValue: "United States").region, .unitedStates)
        let sg = RegionCatalog.resolve(storedValue: "SG")
        XCTAssertEqual(sg.region, .other)
        XCTAssertEqual(sg.customCode, "sg")
        XCTAssertEqual(RegionCatalog.resolve(storedValue: "???").region, .other)
        XCTAssertNil(RegionCatalog.resolve(storedValue: "???").customCode)
    }

    func testAccountsJSONStaysCompatibleAndRoundTrips() throws {
        let ids = (0..<5).map { _ in UUID() }
        let json = """
        {"version":1,"activeAccountID":"\(ids[0])","accounts":[
          {"id":"\(ids[0])","email":"a@example.test","regionLabel":"jp","passwordState":"saved"},
          {"id":"\(ids[1])","email":"b@example.test","regionLabel":"美国","passwordState":"saved"},
          {"id":"\(ids[2])","email":"c@example.test","regionLabel":"other","customRegionCode":"SG","passwordState":"missing"},
          {"id":"\(ids[3])","email":"d@example.test","regionLabel":"gb","passwordState":"saved"},
          {"id":"\(ids[4])","email":"e@example.test","regionLabel":"jp","customRegionCode":"sg","passwordState":"saved"}
        ]}
        """
        let file = tempDir.appendingPathComponent("accounts.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        let store = AccountStore(fileURL: file)
        let book = store.load()
        XCTAssertEqual(book.accounts.map(\.regionLabel), [.japan, .unitedStates, .other, .other, .japan])
        XCTAssertEqual(book.accounts.map(\.customRegionCode), [nil, nil, "sg", "gb", nil], "自填代码只对「其他」有效")
        XCTAssertEqual(book.accounts.map(\.countryCode), ["jp", "us", "sg", "gb", "jp"])
        try store.save(book)
        XCTAssertEqual(store.load(), book)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"regionLabel\" : \"us\""), "保存时写原始值")
    }

    // MARK: - 账号匹配

    private func book(active: Int?, _ records: [AccountRecord]) -> AccountBook {
        AccountBook(accounts: records, activeAccountID: active.map { records[$0].id })
    }

    func testMatchCurrentAccount() {
        let us = AccountRecord(email: "us@example.test", regionLabel: .unitedStates, passwordState: .saved)
        let jp = AccountRecord(email: "jp@example.test", regionLabel: .japan, passwordState: .saved)
        XCTAssertEqual(book(active: 0, [us, jp]).match(countryCode: "US"), .current(us))
    }

    func testMatchOtherAccountPrefersMostRecentLogin() {
        let jp = AccountRecord(email: "jp@example.test", regionLabel: .japan, passwordState: .saved)
        let us1 = AccountRecord(email: "us1@example.test", regionLabel: .unitedStates,
                                lastLoginAt: Date(timeIntervalSince1970: 100), passwordState: .saved)
        let us2 = AccountRecord(email: "us2@example.test", regionLabel: .unitedStates,
                                lastLoginAt: Date(timeIntervalSince1970: 200), passwordState: .saved)
        XCTAssertEqual(book(active: 0, [jp, us1, us2]).match(countryCode: "us"), .other(us2))
        XCTAssertEqual(book(active: nil, [jp]).match(countryCode: "jp"), .other(jp), "未登录时同地区账号也算「其他账号」")
    }

    func testMatchNone() {
        let jp = AccountRecord(email: "jp@example.test", regionLabel: .japan, passwordState: .saved)
        let other = AccountRecord(email: "x@example.test", regionLabel: .other, passwordState: .saved)
        XCTAssertEqual(book(active: 0, [jp, other]).match(countryCode: "us"), .none)
        XCTAssertEqual(AccountBook().match(countryCode: "us"), .none)
        XCTAssertEqual(book(active: 0, [jp]).match(countryCode: "bad"), .none)
    }

    func testOtherRegionWithSameCustomCodeMatches() {
        let jp = AccountRecord(email: "jp@example.test", regionLabel: .japan, passwordState: .saved)
        let sg = AccountRecord(email: "sg@example.test", regionLabel: .other, customRegionCode: "SG", passwordState: .saved)
        XCTAssertEqual(book(active: 0, [jp, sg]).match(countryCode: "sg"), .other(sg))
        XCTAssertEqual(book(active: 1, [jp, sg]).match(countryCode: "SG"), .current(sg))
        XCTAssertTrue(sg.matches(countryCode: "sg"))
        XCTAssertFalse(sg.matches(countryCode: "gb"))
    }

    // MARK: - 公开目录

    func testSearchURLAndEntityMapping() {
        XCTAssertEqual(PublicCatalogService.entity(forPlatform: "iphone"), "software")
        XCTAssertEqual(PublicCatalogService.entity(forPlatform: "ipad"), "iPadSoftware")
        XCTAssertEqual(PublicCatalogService.entity(forPlatform: "macos"), "macSoftware")
        let url = PublicCatalogService.searchURL(term: "黑胶 vinyl", country: "US", platform: "ipad", limit: 25)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(url.host, "itunes.apple.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }),
                       ["term": "黑胶 vinyl", "country": "us", "entity": "iPadSoftware", "limit": "25"])
    }

    private let sample = """
    {"resultCount":3,"results":[
      {"kind":"software","trackId":1606306441,"bundleId":"tech.miidii.MDVinyl","trackName":"MD Vinyl Music App","version":"3.8.5",
       "price":0.0,"artworkUrl100":"https://example.test/a.jpg","sellerName":"MD Studio",
       "supportedDevices":["iPhone15-iPhone15","iPadAir-iPadAir","MacDesktop-MacDesktop"]},
      {"kind":"mac-software","trackId":42,"bundleId":"com.example.mac","trackName":"Mac Tool","version":"2.0","price":4.99,
       "artistName":"Example Inc."},
      {"kind":"software","trackName":"No ID"}
    ]}
    """

    func testParseMapsFieldsPriceAndPlatforms() throws {
        let apps = try PublicCatalogService.parse(Data(sample.utf8), country: "US")
        XCTAssertEqual(apps.count, 2, "没有 trackId 的条目跳过")
        let first = apps[0]
        XCTAssertEqual(first.id, 1606306441)
        XCTAssertEqual(first.bundleID, "tech.miidii.MDVinyl")
        XCTAssertEqual(first.name, "MD Vinyl Music App")
        XCTAssertEqual(first.version, "3.8.5")
        XCTAssertTrue(first.isFree)
        XCTAssertEqual(first.platforms, ["iphone", "ipad"], "MacDesktop 不算 Mac 版")
        XCTAssertEqual(first.artworkURL, URL(string: "https://example.test/a.jpg"))
        XCTAssertEqual(first.sellerName, "MD Studio")
        XCTAssertEqual(first.catalogCountry, "us")
        XCTAssertTrue(first.isPublicCatalog)
        let mac = apps[1]
        XCTAssertEqual(mac.price, 4.99)
        XCTAssertFalse(mac.isFree)
        XCTAssertEqual(mac.platforms, ["macos"])
        XCTAssertEqual(mac.sellerName, "Example Inc.", "没有 sellerName 时用 artistName")
        XCTAssertNil(mac.artworkURL)
    }

    func testParseToleratesMissingFields() throws {
        let apps = try PublicCatalogService.parse(Data(#"{"results":[{"trackId":7}]}"#.utf8), country: "jp")
        XCTAssertEqual(apps, [AppSummary(id: 7, bundleID: "", name: "", version: "", price: 0, platforms: [],
                                         catalogCountry: "jp")])
        XCTAssertEqual(try PublicCatalogService.parse(Data(#"{"resultCount":0}"#.utf8), country: "jp"), [])
        XCTAssertEqual(PublicCatalogService.platforms(supportedDevices: ["iPodTouchSeventhGen-x"], kind: nil), ["iphone"])
        XCTAssertEqual(PublicCatalogService.platforms(supportedDevices: nil, kind: nil), [])
        // ipatool 的 JSON 没有新字段时照常解码
        let decoded = try JSONDecoder().decode(AppSummary.self, from: Data(#"{"id":1,"name":"A"}"#.utf8))
        XCTAssertNil(decoded.catalogCountry)
        XCTAssertFalse(decoded.isPublicCatalog)
    }

    func testErrorsMapToNetworkError() async {
        XCTAssertThrowsError(try PublicCatalogService.parse(Data("<html>".utf8), country: "us")) { error in
            XCTAssertEqual((error as? IpatoolError)?.kind, .networkUnreachable)
        }
        let status = PublicCatalogService(http: FakeHTTP(responses: { _ in (Data(), 503) }, log: Box([])))
        do {
            _ = try await status.search("vinyl", country: "us", limit: 10, platform: "iphone")
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual((error as? IpatoolError)?.kind, .networkUnreachable)
            XCTAssertTrue((error as? IpatoolError)?.raw.contains("503") == true)
        }
        let offline = PublicCatalogService(http: FakeHTTP(responses: { _ in nil }, log: Box([])))
        do {
            _ = try await offline.search("vinyl", country: "us", limit: 10, platform: "iphone")
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual((error as? IpatoolError)?.kind, .networkUnreachable)
            XCTAssertFalse((error as? IpatoolError)?.message.isEmpty ?? true)
        }
    }

    func testSameKeywordIsNotRequestedTwiceWithinOneSecond() async throws {
        let log = Box<[URL]>([])
        let clock = Box(Date(timeIntervalSince1970: 1_000))
        let body = Data(sample.utf8)
        let service = PublicCatalogService(http: FakeHTTP(responses: { _ in (body, 200) }, log: log),
                                           now: { clock.value })
        let first = try await service.search("vinyl", country: "us", limit: 10, platform: "iphone")
        clock.value = clock.value.addingTimeInterval(0.5)
        let second = try await service.search(" Vinyl ", country: "US", limit: 10, platform: "iphone")
        XCTAssertEqual(first, second)
        XCTAssertEqual(log.value.count, 1, "1 秒内同一关键词复用结果")
        _ = try await service.search("vinyl", country: "jp", limit: 10, platform: "iphone")
        XCTAssertEqual(log.value.count, 2, "换地区照常请求")
        clock.value = clock.value.addingTimeInterval(1.1)
        _ = try await service.search("vinyl", country: "us", limit: 10, platform: "iphone")
        XCTAssertEqual(log.value.count, 3, "超过 1 秒重新请求")
    }

    // MARK: - 迁移盖章 / 启动自动加入账号

    func testLegacyStampIsIdempotentAndKeepsExistingOwners() throws {
        let paths = AppPaths(root: tempDir)
        let history = HistoryStore(fileURL: paths.historyFile)
        let queue = DownloadQueueStore(fileURL: paths.queueFile)
        let migrated = UUID(), other = UUID()
        try history.save([
            DownloadRecord(appID: 1, name: "A", bundleID: "a", version: "1", externalVersionID: nil, size: 1, path: "/a"),
            DownloadRecord(appID: 2, name: "B", bundleID: "b", version: "1", externalVersionID: nil, size: 1, path: "/b",
                           accountID: other, regionLabel: "jp"),
        ])
        func entry(_ id: Int64, account: UUID?) -> PersistedDownload {
            PersistedDownload(id: UUID(), appID: id, name: "Q", bundleID: "q", versionLabel: "1", externalVersionID: nil,
                              purchase: false, outputPath: "/q\(id).ipa", platform: nil, displayPlatform: "iphone",
                              isFree: true, totalBytes: nil, addedAt: Date(timeIntervalSince1970: 0), accountID: account)
        }
        try queue.save([entry(1, account: nil), entry(2, account: other), entry(3, account: nil)])

        let result = try LegacyAccountStamp.stamp(accountID: migrated, history: history, queue: queue)
        XCTAssertEqual(result, LegacyAccountStamp.Result(history: 1, queue: 2))
        XCTAssertEqual(history.load().map(\.accountID), [migrated, other])
        XCTAssertEqual(queue.load().map(\.accountID), [migrated, other, migrated])

        let modified = try FileManager.default.attributesOfItem(atPath: paths.queueFile.path)[.modificationDate] as? Date
        let again = try LegacyAccountStamp.stamp(accountID: UUID(), history: history, queue: queue)
        XCTAssertEqual(again, LegacyAccountStamp.Result(history: 0, queue: 0), "再次执行不改动")
        XCTAssertEqual(queue.load().map(\.accountID), [migrated, other, migrated])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: paths.queueFile.path)[.modificationDate] as? Date,
                       modified, "无变化不重写文件")
    }

    private func makeSwitcher(_ store: AccountStore, current: CurrentAccount) -> AccountSwitcher {
        let paths = AppPaths(root: tempDir.appendingPathComponent("support"))
        return AccountSwitcher(store: store, vault: InMemoryCredentialVault(),
                               cookies: CookieJarArchive(paths: paths, homeDirectory: tempDir.appendingPathComponent("home")),
                               auth: ScriptedAuth(), current: current,
                               makeLoginSession: { ScriptedLoginSession(outcomes: [:], cookieFile: nil, log: Box([]), calls: Box([])) })
    }

    func testAdoptUnknownSignedInAccountWhenBookIsNotEmpty() async throws {
        let store = AccountStore(fileURL: tempDir.appendingPathComponent("accounts.json"))
        let jp = AccountRecord(email: "jp@example.test", regionLabel: .japan, passwordState: .saved)
        try store.save(AccountBook(accounts: [jp], activeAccountID: nil))
        let current = CurrentAccount()
        let switcher = makeSwitcher(store, current: current)
        let terminal = AccountInfo(name: "Terminal", email: "terminal@example.test")

        let adoption = await switcher.adoptSignedInAccount(terminal)
        XCTAssertEqual(adoption?.isMigration, false)
        XCTAssertEqual(adoption?.record.passwordState, .missing)
        XCTAssertEqual(adoption?.record.regionLabel, .other)
        let book = store.load()
        XCTAssertEqual(book.accounts.count, 2)
        XCTAssertEqual(book.activeAccountID, adoption?.record.id)
        XCTAssertEqual(current.id, adoption?.record.id)
        let again = await switcher.adoptSignedInAccount(AccountInfo(name: "", email: "TERMINAL@example.test"))
        XCTAssertNil(again, "已在表里不重复加入")
        let migrate = await switcher.migrateIfNeeded(signedIn: AccountInfo(name: "", email: "z@example.test"))
        XCTAssertNil(migrate, "表不为空时 migrateIfNeeded 不动作")
    }

    func testAdoptIntoEmptyBookIsMigrationAndCustomRegionCodeIsSaved() async throws {
        let store = AccountStore(fileURL: tempDir.appendingPathComponent("accounts.json"))
        let switcher = makeSwitcher(store, current: CurrentAccount())
        let adoption = await switcher.adoptSignedInAccount(AccountInfo(name: "Old", email: "old@example.test"))
        XCTAssertEqual(adoption?.isMigration, true)
        let id = try XCTUnwrap(adoption?.record.id)
        try await switcher.setRegion(.other, customCode: "SG", for: id)
        XCTAssertEqual(store.load().account(id)?.countryCode, "sg")
        try await switcher.setRegion(.japan, customCode: "SG", for: id)
        XCTAssertNil(store.load().account(id)?.customRegionCode, "非「其他」不保留自填代码")
        XCTAssertEqual(store.load().account(id)?.countryCode, "jp")
    }
}
