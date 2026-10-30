import Foundation
import XCTest
@testable import IPADepotCore

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&_value); lock.unlock() }
}

/// 每个用例独立的临时目录（`TemporaryDirectory/IPADepotTests-<UUID>`），tearDown 删除。
@MainActor
class VMTestCase: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("IPADepotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func waitUntil(timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等待超时", file: file, line: line)
    }
}

func app(_ id: Int64 = 1606306441, name: String = "谜底黑胶", price: Double = 0, version: String = "3.8.5",
         platforms: [String] = ["iphone", "ipad"]) -> AppSummary {
    AppSummary(id: id, bundleID: "com.example.\(id)", name: name, version: version, price: price, platforms: platforms)
}

// MARK: - 登录

final class FakeLoginSession: LoginSessioning, @unchecked Sendable {
    enum Script { case succeed, twoFactor, fail(IpatoolError) }

    let script: Script
    let received = Locked<[String]>([])
    let codes = Locked<[String]>([])
    let cancelled = Locked(false)
    private let codeStream: AsyncStream<String>
    private let codeContinuation: AsyncStream<String>.Continuation

    init(script: Script) {
        self.script = script
        (codeStream, codeContinuation) = AsyncStream<String>.makeStream()
    }

    func login(email: String, password: String,
               onEvent: @escaping @Sendable (LoginEvent) -> Void) async -> Result<AccountInfo, IpatoolError> {
        received.mutate { $0 = [email, password] }
        onEvent(.preparing)
        onEvent(.log("downloading unicorn"))
        let account = AccountInfo(name: "Test User", email: email)
        switch script {
        case .succeed:
            onEvent(.succeeded(account))
            return .success(account)
        case .fail(let error):
            onEvent(.failed(error))
            return .failure(error)
        case .twoFactor:
            onEvent(.needsTwoFactor)
            var attempts = 0
            for await code in codeStream {
                attempts += 1
                onEvent(.verifyingTwoFactor)
                if code == "123456" {
                    onEvent(.succeeded(account))
                    return .success(account)
                }
                if attempts >= 2 { break }
                onEvent(.needsTwoFactor)
            }
            let error = IpatoolError(kind: .verificationIncomplete, raw: "apple did not complete verification")
            onEvent(.failed(error))
            return .failure(error)
        }
    }

    func submitTwoFactorCode(_ code: String) throws {
        codes.mutate { $0.append(code) }
        codeContinuation.yield(code)
    }

    func cancel() {
        cancelled.value = true
        codeContinuation.finish()
    }
}

final class FakeAuth: AuthServicing, @unchecked Sendable {
    let infoResult: Locked<Result<AccountInfo, IpatoolError>>
    let revokeCount = Locked(0)
    /// `auth info` 被调用的次数（首次启动不应调用 = 不读钥匙串）。
    let infoCount = Locked(0)
    init(_ result: Result<AccountInfo, IpatoolError>) { infoResult = Locked(result) }
    func info() async throws -> AccountInfo {
        infoCount.mutate { $0 += 1 }
        return try infoResult.value.get()
    }
    func revoke() async throws { revokeCount.mutate { $0 += 1 } }
}

// MARK: - 搜索 / 版本 / 图标

final class FakeSearch: SearchServicing, @unchecked Sendable {
    let result: Result<[AppSummary], IpatoolError>
    let calls = Locked<[String]>([])
    init(_ result: Result<[AppSummary], IpatoolError>) { self.result = result }
    func search(_ term: String, limit: Int, platform: String) async throws -> [AppSummary] {
        calls.mutate { $0.append("\(term)|\(limit)|\(platform)") }
        return try result.get()
    }
}

final class FakeVersions: VersionServicing, @unchecked Sendable {
    let ids: Locked<Result<[String], IpatoolError>>
    /// 有元数据的 ID；不在其中的视为单个失败（不出现在结果里）。
    let failing = Locked<Set<String>>([])
    let cached = Locked<Set<String>>([])
    let batches = Locked<[[String]]>([])

    init(ids: Result<[String], IpatoolError>) { self.ids = Locked(ids) }

    static func meta(_ id: String) -> VersionMetadata {
        VersionMetadata(externalVersionID: id, displayVersion: "v\(id)", releaseDate: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func listVersionIDs(appID: Int64, platform: String?) async throws -> [String] { try ids.value.get() }

    func metadata(appID: Int64, versionIDs: [String], useCache: Bool,
                  onEach: (@Sendable (VersionMetadata) -> Void)?) async throws -> [VersionMetadata] {
        batches.mutate { $0.append(versionIDs) }
        let failing = self.failing.value
        let metas = versionIDs.filter { !failing.contains($0) }.map(Self.meta)
        let cached = self.cached.value
        for meta in metas where cached.contains(meta.externalVersionID) { onEach?(meta) }
        return metas
    }
}

struct FakeLookup: AppLookupProviding {
    func info(appID: Int64) async -> AppLookupInfo? { nil }
    func artworkFile(appID: Int64) async -> URL? { nil }
}

final class MemoryDefaults: KeyValueStoring {
    var values: [String: Any] = [:]
    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func integer(forKey defaultName: String) -> Int { values[defaultName] as? Int ?? 0 }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

struct FakeUpdateChecker: UpdateChecking {
    let result: UpdateCheckResult
    func check(currentVersion: String) async throws -> UpdateCheckResult { result }
}

// MARK: - 下载任务

final class FakeDownloadTask: DownloadTasking, @unchecked Sendable {
    let request: DownloadRequest
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DownloadOutcome, Never>?
    private var handler: (@Sendable (DownloadEvent) -> Void)?

    init(request: DownloadRequest) { self.request = request }

    var isWaiting: Bool { lock.withLock { continuation != nil } }

    func start(onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> DownloadOutcome {
        await withCheckedContinuation { c in
            lock.withLock {
                continuation = c
                handler = onEvent
            }
        }
    }

    /// 向队列发一个事件（如进度）。
    func emit(_ event: DownloadEvent) { lock.withLock { handler }?(event) }

    func finish(_ outcome: DownloadOutcome) {
        let c: CheckedContinuation<DownloadOutcome, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: outcome)
    }

    func pause() { finish(.paused) }
    func cancel() { finish(.cancelled) }
}

final class FakeTaskFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [FakeDownloadTask] = []
    func make(_ request: DownloadRequest) -> DownloadTasking {
        let task = FakeDownloadTask(request: request)
        lock.withLock { tasks.append(task) }
        return task
    }
    var all: [FakeDownloadTask] { lock.withLock { tasks } }
}

@MainActor
func makeServices(root: URL, auth: AuthServicing = FakeAuth(.failure(IpatoolError(kind: .notLoggedIn))),
                  search: SearchServicing = FakeSearch(.success([])),
                  versions: VersionServicing = FakeVersions(ids: .success([])),
                  queue: DownloadQueueing = DownloadQueue(makeTask: { FakeDownloadTask(request: $0) }),
                  login: @escaping @Sendable () -> LoginSessioning = { FakeLoginSession(script: .succeed) },
                  defaults: MemoryDefaults = MemoryDefaults(),
                  vault: CredentialVault = InMemoryCredentialVault()) -> AppServices {
    let paths = AppPaths(root: root.appendingPathComponent("support"))
    let current = CurrentAccount()
    let cookies = CookieJarArchive(paths: paths, homeDirectory: root.appendingPathComponent("home", isDirectory: true))
    let switcher = AccountSwitcher(store: AccountStore(fileURL: paths.accountsFile), vault: vault, cookies: cookies,
                                   auth: auth, current: current, makeLoginSession: login)
    return AppServices(paths: paths, auth: auth, makeLoginSession: login, search: search, versions: versions,
                       lookup: FakeLookup(), queue: queue, historyStore: HistoryStore(fileURL: paths.historyFile),
                       queueStore: DownloadQueueStore(fileURL: paths.queueFile),
                       defaults: defaults, ipatoolVersion: { "2.7.0" },
                       makeUpdateChecker: { _ in FakeUpdateChecker(result: .upToDate(latest: "0.1.0")) },
                       setupError: nil, currentAccount: current, switcher: switcher)
}
