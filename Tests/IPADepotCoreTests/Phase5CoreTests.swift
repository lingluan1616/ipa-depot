import Foundation
import Security
import XCTest
@testable import IPADepotCore

// MARK: - 测试替身

/// 可编排的 `auth info` / `auth revoke`。
final class ScriptedAuth: AuthServicing, @unchecked Sendable {
    let revokeCount = Box(0)
    let infoCount = Box(0)
    let revokeError = Box<IpatoolError?>(nil)
    let infoResult = Box<Result<AccountInfo, IpatoolError>>(.failure(IpatoolError(kind: .notLoggedIn)))
    /// 每次调用记一笔（"revoke" / "info"），用于核对顺序。
    let log: Box<[String]>

    init(log: Box<[String]> = Box([])) { self.log = log }

    func info() async throws -> AccountInfo {
        infoCount.mutate { $0 += 1 }
        log.mutate { $0.append("info") }
        return try infoResult.value.get()
    }

    func revoke() async throws {
        revokeCount.mutate { $0 += 1 }
        log.mutate { $0.append("revoke") }
        if let error = revokeError.value { throw error }
    }
}

/// 按邮箱决定结果的登录会话；登录时记下当时 Cookie 文件的内容（核对「先换 Cookie 再登录」）。
final class ScriptedLoginSession: LoginSessioning, @unchecked Sendable {
    enum Outcome { case succeed, twoFactor(String), fail(IpatoolError) }

    let outcomes: [String: Outcome]
    let cookieFile: URL?
    let log: Box<[String]>
    /// 每次登录：邮箱 | 密码 | 登录时 Cookie 文件内容（无文件为 "-"）。
    let calls: Box<[String]>
    private let lock = NSLock()
    private var codeContinuation: AsyncStream<String>.Continuation?

    init(outcomes: [String: Outcome], cookieFile: URL?, log: Box<[String]>, calls: Box<[String]>) {
        self.outcomes = outcomes
        self.cookieFile = cookieFile
        self.log = log
        self.calls = calls
    }

    func login(email: String, password: String,
               onEvent: @escaping @Sendable (LoginEvent) -> Void) async -> Result<AccountInfo, IpatoolError> {
        let cookie = cookieFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "-"
        calls.mutate { $0.append("\(email)|\(password)|\(cookie)") }
        log.mutate { $0.append("login:\(email)") }
        onEvent(.preparing)
        let account = AccountInfo(name: "Name \(email)", email: email)
        switch outcomes[email] ?? .fail(IpatoolError(kind: .unknown, raw: "unexpected login")) {
        case .succeed:
            onEvent(.succeeded(account))
            return .success(account)
        case .fail(let error):
            onEvent(.failed(error))
            return .failure(error)
        case .twoFactor(let expected):
            let (stream, continuation) = AsyncStream<String>.makeStream()
            lock.withLock { codeContinuation = continuation }
            onEvent(.needsTwoFactor)
            for await code in stream {
                onEvent(.verifyingTwoFactor)
                if code == expected {
                    onEvent(.succeeded(account))
                    return .success(account)
                }
                onEvent(.needsTwoFactor)
            }
            let error = IpatoolError(kind: .cancelled)
            onEvent(.failed(error))
            return .failure(error)
        }
    }

    func submitTwoFactorCode(_ code: String) throws {
        lock.withLock { codeContinuation }?.yield(code)
    }

    func cancel() {
        lock.withLock { codeContinuation }?.finish()
    }
}

/// 下载队列用的切换替身。
final class FakeDownloadSwitching: DownloadAccountSwitching, @unchecked Sendable {
    let current = Box<UUID?>(nil)
    let calls = Box<[UUID]>([])
    let error = Box<IpatoolError?>(nil)
    /// 非 nil 时切换挂起，直到 `release()`。
    private let gate = Box<CheckedContinuation<Void, Never>?>(nil)
    let holds = Box(false)

    func isCurrentAccount(_ accountID: UUID) -> Bool { current.value == accountID }

    func switchForDownload(to accountID: UUID) async throws {
        calls.mutate { $0.append(accountID) }
        if holds.value {
            await withCheckedContinuation { c in gate.value = c }
        }
        if let error = error.value { throw error }
        current.value = accountID
    }

    var isHolding: Bool { gate.value != nil }

    func release() {
        let c = gate.value
        gate.value = nil
        c?.resume()
    }
}

// MARK: - 账号表

final class AccountStoreTests: TempDirTestCase {
    func testRoundTripKeepsAccountsAndActive() throws {
        let store = AccountStore(fileURL: tempDir.appendingPathComponent("accounts.json"))
        let a = AccountRecord(email: "a@example.test", displayName: "A", regionLabel: .japan,
                              lastLoginAt: Date(timeIntervalSince1970: 1_800_000_000), passwordState: .saved)
        let b = AccountRecord(email: "b@example.test", regionLabel: .unitedStates, passwordState: .missing)
        try store.save(AccountBook(accounts: [a, b], activeAccountID: b.id))
        let loaded = store.load()
        XCTAssertEqual(loaded.accounts, [a, b])
        XCTAssertEqual(loaded.active, b)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"regionLabel\" : \"jp\""))
        XCTAssertFalse(text.lowercased().contains("password\" :"), "账号表不含密码字段值")
    }

    func testMissingOrCorruptFileIsEmpty() throws {
        let url = tempDir.appendingPathComponent("accounts.json")
        XCTAssertTrue(AccountStore(fileURL: url).load().isEmpty)
        try Data("{not json".utf8).write(to: url)
        XCTAssertTrue(AccountStore(fileURL: url).load().isEmpty)
    }

    func testTolerantDecodingAndDanglingActive() throws {
        let url = tempDir.appendingPathComponent("accounts.json")
        let id = UUID()
        let json = """
        {"version":1,"activeAccountID":"\(UUID().uuidString)",
         "accounts":[{"id":"\(id.uuidString)","email":"x@example.test","regionLabel":"mars","passwordState":"??"}]}
        """
        try Data(json.utf8).write(to: url)
        let book = AccountStore(fileURL: url).load()
        XCTAssertNil(book.activeAccountID, "激活 id 指向不存在的账号时视为未激活")
        XCTAssertEqual(book.accounts.first?.regionLabel, .other, "未知地区按「其他」")
        XCTAssertEqual(book.accounts.first?.passwordState, .missing)
        XCTAssertEqual(book.accounts.first?.displayName, "")
    }

    func testBookEmailMatchingUpsertAndRemove() {
        var book = AccountBook()
        var a = AccountRecord(email: "User@Example.test", regionLabel: .hongKong, passwordState: .saved)
        book.upsert(a)
        book.activeAccountID = a.id
        XCTAssertEqual(book.account(email: " user@example.TEST ")?.id, a.id, "邮箱比较不区分大小写")
        a.regionLabel = .taiwan
        book.upsert(a)
        XCTAssertEqual(book.accounts.count, 1)
        XCTAssertEqual(book.active?.regionLabel, .taiwan)
        book.remove(a.id)
        XCTAssertNil(book.activeAccountID, "移除激活账号后激活置空")
        XCTAssertTrue(book.isEmpty)
    }
}

// MARK: - 钥匙串保险库

final class CredentialVaultTests: XCTestCase {
    func testInMemoryVaultSetUpdateRemove() throws {
        let vault = InMemoryCredentialVault()
        XCTAssertNil(try vault.password(for: "a@example.test"))
        try vault.setPassword("one", for: "A@example.test")
        XCTAssertEqual(try vault.password(for: "a@example.test"), "one", "按规范化邮箱存取")
        try vault.setPassword("two", for: "a@example.test")
        XCTAssertEqual(try vault.password(for: "a@example.test"), "two")
        try vault.removePassword(for: "a@example.test")
        XCTAssertNil(try vault.password(for: "a@example.test"))
        XCTAssertNoThrow(try vault.removePassword(for: "missing@example.test"), "删除不存在的条目不报错")
    }

    func testInMemoryVaultFailureInjection() {
        let vault = InMemoryCredentialVault(["a@example.test": "x"])
        vault.failure = CredentialVaultError(status: errSecInteractionNotAllowed, operation: "读取")
        XCTAssertThrowsError(try vault.password(for: "a@example.test"))
    }

    /// 只核对查询字典，不调用钥匙串（单元测试不读写真实钥匙串）。
    func testKeychainVaultQueryAttributes() {
        let vault = KeychainCredentialVault()
        XCTAssertEqual(vault.service, "app.ipadepot.mac.accounts")
        let query = vault.baseQuery(email: " Me@Example.test ")
        XCTAssertEqual(query[kSecAttrService as String] as? String, "app.ipadepot.mac.accounts")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "me@example.test")
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false, "不开 iCloud 同步")
        let add = vault.addAttributes(email: "me@example.test", password: "pw")
        XCTAssertEqual(add[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual(add[kSecValueData as String] as? Data, Data("pw".utf8))
    }
}

// MARK: - Cookie 存取

final class CookieJarArchiveTests: TempDirTestCase {
    private func archive() -> CookieJarArchive {
        CookieJarArchive(homeDirectory: tempDir.appendingPathComponent("home", isDirectory: true),
                         stateHome: tempDir.appendingPathComponent("state", isDirectory: true),
                         archiveRoot: tempDir.appendingPathComponent("accounts", isDirectory: true))
    }

    func testStateDirectoryPrefersLegacyWhenItExists() throws {
        let jar = archive()
        XCTAssertEqual(jar.ipatoolStateDirectory.path, tempDir.appendingPathComponent("state/ipatool").path)
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("home/.ipatool"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(jar.ipatoolStateDirectory.path, tempDir.appendingPathComponent("home/.ipatool").path,
                       "~/.ipatool 存在时 ipatool 沿用它")
        XCTAssertEqual(jar.liveCookiesFile.lastPathComponent, "cookies")
    }

    func testSaveAndRestoreAreAtomicCopiesWithPrivatePermissions() throws {
        let jar = archive()
        let id = UUID()
        try FileManager.default.createDirectory(at: jar.ipatoolStateDirectory, withIntermediateDirectories: true)
        try Data("[A]".utf8).write(to: jar.liveCookiesFile)
        try jar.save(accountID: id)
        XCTAssertEqual(try String(contentsOf: jar.archiveFile(for: id), encoding: .utf8), "[A]")
        let perms = try FileManager.default.attributesOfItem(atPath: jar.archiveFile(for: id).path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        try Data("[B]".utf8).write(to: jar.liveCookiesFile)
        try jar.restore(accountID: id)
        XCTAssertEqual(try String(contentsOf: jar.liveCookiesFile, encoding: .utf8), "[A]")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: jar.ipatoolStateDirectory.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "不留临时文件")
    }

    func testRestoreWithoutArchiveClearsLiveCookies() throws {
        let jar = archive()
        try FileManager.default.createDirectory(at: jar.ipatoolStateDirectory, withIntermediateDirectories: true)
        try Data("[old account]".utf8).write(to: jar.liveCookiesFile)
        try jar.restore(accountID: UUID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: jar.liveCookiesFile.path), "目标账号没有 Cookie 时清空，避免串号")
        XCTAssertNoThrow(try jar.clearLive(), "已清空时再清不报错")
    }

    func testSaveWithoutLiveFileKeepsExistingArchive() throws {
        let jar = archive()
        let id = UUID()
        try FileManager.default.createDirectory(at: jar.archiveDirectory(for: id), withIntermediateDirectories: true)
        try Data("[kept]".utf8).write(to: jar.archiveFile(for: id))
        try jar.save(accountID: id)
        XCTAssertEqual(try String(contentsOf: jar.archiveFile(for: id), encoding: .utf8), "[kept]")
        jar.removeArchive(accountID: id)
        XCTAssertFalse(jar.hasArchive(for: id))
    }
}

// MARK: - 切换状态机

final class AccountSwitcherTests: TempDirTestCase {
    var log: Box<[String]>!
    var calls: Box<[String]>!
    var auth: ScriptedAuth!
    var vault: InMemoryCredentialVault!
    var jar: CookieJarArchive!
    var store: AccountStore!
    var current: CurrentAccount!
    var outcomes: [String: ScriptedLoginSession.Outcome] = [:]
    var sessions: Box<[ScriptedLoginSession]>!

    let japan = AccountRecord(email: "jp@example.test", regionLabel: .japan, passwordState: .saved)
    let usa = AccountRecord(email: "us@example.test", regionLabel: .unitedStates, passwordState: .saved)

    override func setUpWithError() throws {
        try super.setUpWithError()
        log = Box([])
        calls = Box([])
        sessions = Box([])
        auth = ScriptedAuth(log: log)
        vault = InMemoryCredentialVault(["jp@example.test": "jp-pass", "us@example.test": "us-pass"])
        jar = CookieJarArchive(homeDirectory: tempDir.appendingPathComponent("home", isDirectory: true),
                               stateHome: tempDir.appendingPathComponent("state", isDirectory: true),
                               archiveRoot: tempDir.appendingPathComponent("accounts", isDirectory: true))
        store = AccountStore(fileURL: tempDir.appendingPathComponent("accounts.json"))
        current = CurrentAccount()
        outcomes = [:]
    }

    /// 账号表里有日本（当前）与美国两个账号，当前 Cookie 为「jp-live」，美国账号存过「us-saved」。
    private func seed(active: AccountRecord? = nil) throws {
        let active = active ?? japan
        try store.save(AccountBook(accounts: [japan, usa], activeAccountID: active.id))
        current.id = active.id
        try FileManager.default.createDirectory(at: jar.ipatoolStateDirectory, withIntermediateDirectories: true)
        try Data("jp-live".utf8).write(to: jar.liveCookiesFile)
        try FileManager.default.createDirectory(at: jar.archiveDirectory(for: usa.id), withIntermediateDirectories: true)
        try Data("us-saved".utf8).write(to: jar.archiveFile(for: usa.id))
    }

    private func makeSwitcher() -> AccountSwitcher {
        let outcomes = self.outcomes
        let cookieFile = jar.liveCookiesFile
        let log = self.log!, calls = self.calls!, sessions = self.sessions!
        return AccountSwitcher(store: store, vault: vault, cookies: jar, auth: auth, current: current,
                               makeLoginSession: {
                                   let s = ScriptedLoginSession(outcomes: outcomes, cookieFile: cookieFile, log: log, calls: calls)
                                   sessions.mutate { $0.append(s) }
                                   return s
                               },
                               now: { Date(timeIntervalSince1970: 1_900_000_000) })
    }

    func testSuccessfulSwitchSavesRevokesRestoresAndLogsIn() async throws {
        try seed()
        outcomes = ["us@example.test": .succeed]
        let switcher = makeSwitcher()
        let phases = Box<[AccountSwitchPhase]>([])
        let stream = await switcher.updates()
        let collector = Task { for await p in stream { phases.mutate { $0.append(p.phase) }; if p.phase == .done { break } } }

        let result = await switcher.switchTo(usa.id)
        let record = try result.get()
        await collector.value

        XCTAssertEqual(log.value, ["revoke", "login:us@example.test"], "先 revoke 再登录")
        XCTAssertEqual(calls.value, ["us@example.test|us-pass|us-saved"], "登录时 Cookie 已换成目标账号的、密码来自钥匙串")
        XCTAssertEqual(try String(contentsOf: jar.archiveFile(for: japan.id), encoding: .utf8), "jp-live", "原账号 Cookie 已保存")
        XCTAssertEqual(store.load().activeAccountID, usa.id)
        XCTAssertEqual(current.id, usa.id)
        XCTAssertEqual(record.lastLoginAt, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(record.displayName, "Name us@example.test")
        XCTAssertEqual(Array(phases.value.prefix(4)), [.savingCookies, .revoking, .restoringCookies, .loggingIn])
        XCTAssertEqual(phases.value.last, .done)
    }

    func testSwitchWithTwoFactorPublishesPhasesAndAcceptsCode() async throws {
        try seed()
        outcomes = ["us@example.test": .twoFactor("654321")]
        let switcher = makeSwitcher()
        let phases = Box<[AccountSwitchPhase]>([])
        let stream = await switcher.updates()
        let collector = Task {
            for await p in stream {
                phases.mutate { $0.append(p.phase) }
                if p.phase == .needsTwoFactor { try? switcher.submitTwoFactorCode("654321") }
                if p.phase == .done || p.phase == .failed { break }
            }
        }
        let result = await switcher.switchTo(usa.id)
        await collector.value
        XCTAssertEqual(try result.get().id, usa.id)
        XCTAssertTrue(phases.value.contains(.needsTwoFactor))
        XCTAssertTrue(phases.value.contains(.verifying))
        XCTAssertEqual(phases.value.last, .done)
    }

    func testLoginFailureRollsBackToPreviousAccount() async throws {
        try seed()
        outcomes = ["us@example.test": .fail(IpatoolError(kind: .accountDisabled, raw: "account is disabled")),
                    "jp@example.test": .succeed]
        let switcher = makeSwitcher()
        let result = await switcher.switchTo(usa.id)
        guard case .failure(let error) = result else { return XCTFail("应失败") }
        XCTAssertEqual(error.reason, .loginFailed(IpatoolError(kind: .accountDisabled, raw: "account is disabled")))
        XCTAssertEqual(error.rollback, .restored(japan))
        XCTAssertEqual(calls.value.last, "jp@example.test|jp-pass|jp-live", "回滚时换回原账号 Cookie 并用原密码登录")
        XCTAssertEqual(store.load().activeAccountID, japan.id)
        XCTAssertEqual(current.id, japan.id)
    }

    func testRollbackFailureEndsSignedOut() async throws {
        try seed()
        outcomes = ["us@example.test": .fail(IpatoolError(kind: .unknown, raw: "bad")),
                    "jp@example.test": .fail(IpatoolError(kind: .networkUnreachable, raw: "dial tcp"))]
        let switcher = makeSwitcher()
        guard case .failure(let error) = await switcher.switchTo(usa.id) else { return XCTFail("应失败") }
        guard case .signedOut(let reason) = error.rollback else { return XCTFail("应为未登录") }
        XCTAssertEqual(reason, "dial tcp")
        XCTAssertNil(store.load().activeAccountID)
        XCTAssertNil(current.id)
    }

    func testRevokeFailureWhileStillSignedInChangesNothing() async throws {
        try seed()
        auth.revokeError.value = IpatoolError(kind: .keychainNotFound, raw: "keychain cannot be found")
        auth.infoResult.value = .success(AccountInfo(name: "", email: "JP@example.test"))
        let switcher = makeSwitcher()
        guard case .failure(let error) = await switcher.switchTo(usa.id) else { return XCTFail("应失败") }
        XCTAssertEqual(error.reason, .revokeFailed(IpatoolError(kind: .keychainNotFound, raw: "keychain cannot be found")))
        XCTAssertEqual(error.rollback, .notNeeded)
        XCTAssertTrue(calls.value.isEmpty, "仍登录着原账号时不重新登录")
        XCTAssertEqual(store.load().activeAccountID, japan.id)
        XCTAssertEqual(try String(contentsOf: jar.liveCookiesFile, encoding: .utf8), "jp-live", "Cookie 未被替换")
    }

    func testRevokeFailureAfterSignOutRelogsPrevious() async throws {
        try seed()
        auth.revokeError.value = IpatoolError(kind: .unknown, raw: "failed to remove kbsync cache from keychain")
        outcomes = ["jp@example.test": .succeed]
        let switcher = makeSwitcher()
        guard case .failure(let error) = await switcher.switchTo(usa.id) else { return XCTFail("应失败") }
        XCTAssertEqual(error.rollback, .restored(japan))
        XCTAssertEqual(log.value, ["revoke", "info", "login:jp@example.test"])
    }

    func testMissingPasswordFailsBeforeTouchingAnything() async throws {
        try seed()
        try vault.removePassword(for: usa.email)
        let switcher = makeSwitcher()
        guard case .failure(let error) = await switcher.switchTo(usa.id) else { return XCTFail("应失败") }
        XCTAssertEqual(error.reason, .passwordMissing)
        XCTAssertEqual(auth.revokeCount.value, 0)
        XCTAssertEqual(store.load().activeAccountID, japan.id)
    }

    func testPasswordOverrideIsStoredAfterSuccessfulLogin() async throws {
        var migrated = usa
        migrated.passwordState = .missing
        try store.save(AccountBook(accounts: [japan, migrated], activeAccountID: japan.id))
        current.id = japan.id
        try vault.removePassword(for: usa.email)
        outcomes = ["us@example.test": .succeed]
        let switcher = makeSwitcher()
        let record = try await switcher.switchTo(usa.id, password: "typed").get()
        XCTAssertEqual(record.passwordState, .saved)
        XCTAssertEqual(try vault.password(for: usa.email), "typed")
        XCTAssertEqual(calls.value.first, "us@example.test|typed|-", "美国账号没有保存过 Cookie：登录前清空")
    }

    func testAddAccountSavesCurrentClearsCookiesAndRecordsNewAccount() async throws {
        try seed()
        outcomes = ["kr@example.test": .succeed]
        let switcher = makeSwitcher()
        let record = try await switcher.addAccount(email: " kr@example.test ", password: "kr-pass", region: .korea).get()
        XCTAssertEqual(record.email, "kr@example.test")
        XCTAssertEqual(record.regionLabel, .korea)
        XCTAssertEqual(calls.value, ["kr@example.test|kr-pass|-"], "新账号登录前清空 Cookie")
        XCTAssertEqual(auth.revokeCount.value, 1)
        XCTAssertEqual(try vault.password(for: "kr@example.test"), "kr-pass")
        let book = store.load()
        XCTAssertEqual(book.accounts.count, 3)
        XCTAssertEqual(book.activeAccountID, record.id)
        XCTAssertEqual(try String(contentsOf: jar.archiveFile(for: japan.id), encoding: .utf8), "jp-live")
    }

    func testFirstAccountFromSignedOutKeepsCookiesAndSkipsRevoke() async throws {
        try FileManager.default.createDirectory(at: jar.ipatoolStateDirectory, withIntermediateDirectories: true)
        try Data("trusted-device".utf8).write(to: jar.liveCookiesFile)
        outcomes = ["cn@example.test": .succeed]
        let switcher = makeSwitcher()
        let record = try await switcher.addAccount(email: "cn@example.test", password: "p", region: .mainlandChina).get()
        XCTAssertEqual(auth.revokeCount.value, 0, "原本未登录时不 revoke")
        XCTAssertEqual(calls.value, ["cn@example.test|p|trusted-device"], "保留现有 Cookie（与单账号首次登录一致）")
        XCTAssertEqual(try String(contentsOf: jar.archiveFile(for: record.id), encoding: .utf8), "trusted-device")
    }

    func testRemoveActiveAccountRevokesAndClearsEverything() async throws {
        try seed()
        try FileManager.default.createDirectory(at: jar.archiveDirectory(for: japan.id), withIntermediateDirectories: true)
        try Data("jp-saved".utf8).write(to: jar.archiveFile(for: japan.id))
        let switcher = makeSwitcher()
        try await switcher.remove(japan.id)
        XCTAssertEqual(auth.revokeCount.value, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jar.liveCookiesFile.path))
        XCTAssertFalse(jar.hasArchive(for: japan.id))
        XCTAssertNil(try vault.password(for: japan.email))
        XCTAssertEqual(store.load().accounts.map(\.id), [usa.id])
        XCTAssertNil(current.id)
        XCTAssertTrue(jar.hasArchive(for: usa.id), "其他账号不受影响")
    }

    func testMigrationCreatesRecordOnlyWhenBookIsEmpty() async throws {
        let switcher = makeSwitcher()
        let info = AccountInfo(name: "Old User", email: "old@example.test")
        let migratedValue = await switcher.migrateIfNeeded(signedIn: info)
        let migrated = try XCTUnwrap(migratedValue)
        XCTAssertEqual(migrated.passwordState, .missing)
        XCTAssertEqual(migrated.regionLabel, .other)
        XCTAssertEqual(store.load().activeAccountID, migrated.id)
        XCTAssertEqual(current.id, migrated.id)
        let again = await switcher.migrateIfNeeded(signedIn: info)
        XCTAssertNil(again, "账号表非空时不再迁移")
    }

    func testReconcileMatchesSignedInEmail() async throws {
        try seed(active: usa)
        let switcher = makeSwitcher()
        let matched = await switcher.reconcile(signedIn: AccountInfo(name: "", email: "JP@EXAMPLE.TEST"))
        XCTAssertEqual(matched?.id, japan.id)
        XCTAssertEqual(store.load().activeAccountID, japan.id)
        let none = await switcher.reconcile(signedIn: nil)
        XCTAssertNil(none)
        XCTAssertNil(current.id)
    }

    func testSwitchForDownloadMapsFailureToAccountSwitchError() async throws {
        try seed()
        try vault.removePassword(for: usa.email)
        let switcher = makeSwitcher()
        XCTAssertTrue(switcher.isCurrentAccount(japan.id))
        do {
            try await switcher.switchForDownload(to: usa.id)
            XCTFail("应抛出")
        } catch let error as IpatoolError {
            XCTAssertEqual(error.kind, .accountSwitchFailed)
            XCTAssertTrue(error.raw.contains("no saved password"))
        }
    }
}

// MARK: - 下载队列自动切换

final class QueueAccountSwitchTests: TempDirTestCase {
    private func request(_ name: String, account: UUID?) -> DownloadRequest {
        DownloadRequest(appID: testAppID(name), output: tempDir.appendingPathComponent("\(name).ipa"), accountID: account)
    }

    func testTaskForAnotherAccountSwitchesBeforeStarting() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let switching = FakeDownloadSwitching()
        let a = UUID(), b = UUID()
        switching.current.value = a
        switching.holds.value = true
        await queue.setAccountSwitching(switching)

        let id = await queue.add(request("x", account: b))
        await waitUntil { switching.isHolding }
        let during = await queue.item(id)?.status
        XCTAssertEqual(during, .switchingAccount)
        XCTAssertEqual(factory[0].startCount, 0, "切换完成前不开始下载")
        switching.release()
        await waitUntil { factory[0].startCount == 1 }
        XCTAssertEqual(switching.calls.value, [b])
        let after = await queue.item(id)?.status
        XCTAssertEqual(after, .running)
    }

    func testCurrentAccountAndLegacyTasksDoNotSwitch() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let switching = FakeDownloadSwitching()
        let a = UUID()
        switching.current.value = a
        await queue.setAccountSwitching(switching)
        _ = await queue.add(request("cur", account: a))
        await waitUntil { factory.all.first?.isWaiting == true }
        factory[0].finish(.paused)
        _ = await queue.add(request("legacy", account: nil))
        await waitUntil { factory.all.count == 2 && factory[1].isWaiting }
        XCTAssertTrue(switching.calls.value.isEmpty, "当前账号与旧任务（无账号）不切换")
    }

    func testSwitchFailureFailsTaskAndQueueContinues() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let switching = FakeDownloadSwitching()
        let a = UUID(), b = UUID()
        switching.current.value = a
        switching.error.value = IpatoolError(kind: .accountSwitchFailed, raw: "no saved password for this account")
        await queue.setAccountSwitching(switching)
        let first = await queue.add(request("other", account: b))
        let second = await queue.add(request("mine", account: a))
        await waitUntil { await queue.item(first)?.status.isActive == false && factory[1].isWaiting }
        let failedValue = await queue.item(first)
        let failed = try XCTUnwrap(failedValue)
        guard case .failed(let error) = failed.status else { return XCTFail("应失败") }
        XCTAssertEqual(error.kind, .accountSwitchFailed)
        XCTAssertEqual(failed.lastFailure?.kind, .accountSwitchFailed)
        XCTAssertEqual(factory[0].startCount, 0)
        let secondStatus = await queue.item(second)?.status
        XCTAssertEqual(secondStatus, .running, "下一个任务照常开始")
    }

    func testPauseDuringSwitchKeepsTaskPausedAfterSwitch() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let switching = FakeDownloadSwitching()
        switching.current.value = UUID()
        switching.holds.value = true
        await queue.setAccountSwitching(switching)
        let id = await queue.add(request("p", account: UUID()))
        await waitUntil { switching.isHolding }
        await queue.pause(id)
        switching.release()
        await waitUntil { await queue.item(id)?.status == .paused }
        XCTAssertEqual(factory[0].startCount, 0, "切换期间被暂停：切换后不开始下载")
        let active = await queue.activeItemID
        XCTAssertNil(active)
    }
}

// MARK: - 版本缓存按账号隔离、旧数据兼容

final class AccountScopedDataTests: TempDirTestCase {
    func testVersionCacheIsolatedPerAccount() throws {
        let base = VersionCache(directory: tempDir.appendingPathComponent("versions"))
        let a = UUID(), b = UUID()
        try base.scoped(to: a).save(CachedVersions(appID: 7, versionIDs: ["a1"]))
        try base.scoped(to: b).save(CachedVersions(appID: 7, versionIDs: ["b1", "b2"]))
        XCTAssertEqual(base.scoped(to: a).load(appID: 7)?.versionIDs, ["a1"])
        XCTAssertEqual(base.scoped(to: b).load(appID: 7)?.versionIDs, ["b1", "b2"])
        XCTAssertNil(base.load(appID: 7), "无账号的旧路径不受影响")
        XCTAssertTrue(base.scoped(to: a).fileURL(appID: 7).path.contains(a.uuidString))
    }

    func testVersionServiceUsesCurrentAccountCache() throws {
        let account = CurrentAccount(UUID())
        let runner = IpatoolRunner(executableURL: URL(fileURLWithPath: "/nonexistent"),
                                   paths: AppPaths(root: tempDir.appendingPathComponent("support")))
        let service = VersionService(runner: runner, account: account)
        let first = service.cache.fileURL(appID: 1)
        account.id = UUID()
        XCTAssertNotEqual(service.cache.fileURL(appID: 1), first, "切换账号后使用另一份缓存")
    }

    func testLegacyQueueAndHistoryWithoutAccountDecode() throws {
        let queueURL = tempDir.appendingPathComponent("queue.json")
        let legacyQueue = """
        {"version":1,"items":[{"id":"\(UUID().uuidString)","appID":1,"name":"A","bundleID":"b","versionLabel":"1",
        "purchase":false,"outputPath":"/tmp/a.ipa","displayPlatform":"iphone","isFree":true,
        "addedAt":"2026-10-27T00:00:00Z"}]}
        """
        try Data(legacyQueue.utf8).write(to: queueURL)
        let items = DownloadQueueStore(fileURL: queueURL).load()
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].accountID)
        XCTAssertNil(items[0].request.accountID, "旧任务视为当前账号")

        let historyURL = tempDir.appendingPathComponent("history.json")
        let legacyHistory = """
        [{"id":"\(UUID().uuidString)","appID":1,"name":"A","bundleID":"b","version":"1","size":3,
          "path":"/tmp/a.ipa","completedAt":"2026-10-27T00:00:00Z"}]
        """
        try Data(legacyHistory.utf8).write(to: historyURL)
        let records = HistoryStore(fileURL: historyURL).load()
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].accountID)
        XCTAssertNil(records[0].regionLabel)
    }

    func testPersistedDownloadRoundTripsAccountID() throws {
        let url = tempDir.appendingPathComponent("queue.json")
        let account = UUID()
        let entry = PersistedDownload(id: UUID(), appID: 2, name: "B", bundleID: "b", versionLabel: "2",
                                      externalVersionID: "9", purchase: false, outputPath: "/tmp/b.ipa", platform: nil,
                                      displayPlatform: "iphone", isFree: true, totalBytes: nil,
                                      addedAt: Date(timeIntervalSince1970: 1_800_000_000), accountID: account)
        try DownloadQueueStore(fileURL: url).save([entry])
        let loaded = DownloadQueueStore(fileURL: url).load()
        XCTAssertEqual(loaded, [entry])
        XCTAssertEqual(loaded[0].request.accountID, account)
        XCTAssertEqual(loaded[0].request.arguments, ["download", "-i", "2", "--external-version-id", "9", "-o", "/tmp/b.ipa"],
                       "账号 id 不进 ipatool 参数")
    }
}
