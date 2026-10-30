import Foundation
import IPADepotCore

// MARK: - 服务协议（视图模型只依赖这些协议，便于测试替身注入）

// `AuthServicing` 与 `LoginSessioning` 定义在 IPADepotCore（账号切换器也要用）。

protocol SearchServicing: Sendable {
    func search(_ term: String, limit: Int, platform: String) async throws -> [AppSummary]
}

protocol VersionServicing: Sendable {
    func listVersionIDs(appID: Int64, platform: String?) async throws -> [String]
    func metadata(appID: Int64, versionIDs: [String], useCache: Bool,
                  onEach: (@Sendable (VersionMetadata) -> Void)?) async throws -> [VersionMetadata]
}

protocol AppLookupProviding: Sendable {
    func info(appID: Int64) async -> AppLookupInfo?
    func artworkFile(appID: Int64) async -> URL?
    /// 预先放入已知的图标地址与开发者名（公开目录结果）。
    func prime(_ info: AppLookupInfo) async
}

extension AppLookupProviding {
    func prime(_ info: AppLookupInfo) async {}
}

protocol DownloadQueueing: Sendable {
    @discardableResult func add(_ request: DownloadRequest, id: UUID) async -> UUID
    /// 入队（去重）：已有未结束的同一任务时不新建，返回已有 id 与 `isNew = false`。
    func addDeduplicated(_ request: DownloadRequest, id: UUID) async -> (id: UUID, isNew: Bool)
    func pause(_ id: UUID) async
    func resume(_ id: UUID) async
    func cancel(_ id: UUID) async
    func remove(_ id: UUID) async
    func removeCompleted() async
    func updates() async -> AsyncStream<[DownloadQueueItem]>
    /// 放回上次保存的任务（`.paused`，不自动开始；`lastFailure` 为上次失败的原因）。
    func restore(_ request: DownloadRequest, id: UUID, progress: DownloadProgress?, lastFailure: IpatoolError?,
                 addedAt: Date) async
    /// App 退出时同步终止正在运行的下载子进程。
    func terminateRunningTasks()
    /// 下载前的账号切换（任务属于另一个账号时先切换）。
    func setAccountSwitching(_ switching: DownloadAccountSwitching?) async
    /// 同时下载数（1...3）；调小时不打断正在运行的任务。
    func setMaxConcurrent(_ n: Int) async
}

protocol UpdateChecking: Sendable {
    func check(currentVersion: String) async throws -> UpdateCheckResult
}

/// 简单键值存储（`UserDefaults` 实现；测试用内存替身）。
protocol KeyValueStoring: AnyObject {
    func string(forKey defaultName: String) -> String?
    func bool(forKey defaultName: String) -> Bool
    /// 整数值（不存在或不是数字时为 0）。
    func integer(forKey defaultName: String) -> Int
    func set(_ value: Any?, forKey defaultName: String)
}

extension SearchService: SearchServicing {}
extension VersionService: VersionServicing {}
extension AppLookupService: AppLookupProviding {}
extension DownloadQueue: DownloadQueueing {}
extension UpdateChecker: UpdateChecking {}
extension UserDefaults: KeyValueStoring {}

// MARK: - 组合根

/// App 运行时用到的全部服务。`live()` 用内置 ipatool；测试里逐项替换。
struct AppServices {
    var paths: AppPaths
    var auth: AuthServicing
    var makeLoginSession: @Sendable () -> LoginSessioning
    var search: SearchServicing
    var versions: VersionServicing
    var lookup: AppLookupProviding
    var queue: DownloadQueueing
    var historyStore: HistoryStore
    /// 下载队列的跨启动保存（`queue.json`）；nil = 不保存。
    var queueStore: DownloadQueueStore?
    var defaults: KeyValueStoring
    var ipatoolVersion: @Sendable () async throws -> String
    var makeUpdateChecker: @Sendable (String) -> UpdateChecking
    /// 启动时就能确定的问题（如找不到 ipatool）。
    var setupError: IpatoolError?
    /// 当前激活账号 id（版本缓存与下载队列共用）。
    var currentAccount: CurrentAccount
    /// 多账号：账号表、钥匙串密码、每账号 Cookie 与切换流程。
    var switcher: AccountSwitcher
    /// 浏览地区：Apple 公开目录搜索（iTunes Search API）。
    var catalog: PublicCatalogSearching? = nil

    static func live() -> AppServices {
        let paths = AppPaths.default
        let locator = IpatoolLocator()
        var setupError: IpatoolError?
        let executable: URL
        do {
            executable = try locator.locate()
        } catch let error as IpatoolError {
            setupError = error
            executable = locator.candidates.first ?? URL(fileURLWithPath: "/nonexistent/ipatool")
        } catch {
            setupError = IpatoolError(kind: .binaryNotFound, raw: error.localizedDescription)
            executable = URL(fileURLWithPath: "/nonexistent/ipatool")
        }
        let runner = IpatoolRunner(executableURL: executable, paths: paths)
        let auth = AuthService(runner: runner)
        let makeLoginSession: @Sendable () -> LoginSessioning = { LoginSession(runner: runner) }
        let currentAccount = CurrentAccount()
        var vault: CredentialVault = KeychainCredentialVault()
        var cookies = CookieJarArchive(paths: paths)
        #if DEBUG
        // Debug 冒烟（数据根目录被重定向时）：密码存进数据目录里的 JSON 文件、Cookie 主目录也指到数据目录，
        // 绝不读写真实钥匙串条目与 ~/.ipatool。
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[AppPaths.dataRootOverrideKey], !override.isEmpty {
            let vaultPath = environment[FileCredentialVault.environmentKey].flatMap { $0.isEmpty ? nil : $0 }
                ?? paths.root.appendingPathComponent("debug-vault.json").path
            vault = FileCredentialVault(fileURL: URL(fileURLWithPath: vaultPath))
            cookies = CookieJarArchive(paths: paths, homeDirectory: paths.root.appendingPathComponent("home", isDirectory: true))
        }
        #endif
        let switcher = AccountSwitcher(store: AccountStore(fileURL: paths.accountsFile), vault: vault, cookies: cookies,
                                       auth: auth, current: currentAccount, makeLoginSession: makeLoginSession)
        return AppServices(
            paths: paths,
            auth: auth,
            makeLoginSession: makeLoginSession,
            search: SearchService(runner: runner),
            versions: VersionService(runner: runner, account: currentAccount),
            lookup: AppLookupService(directory: paths.artworkCacheDirectory),
            queue: DownloadQueue(runner: runner),
            historyStore: HistoryStore(fileURL: paths.historyFile),
            queueStore: DownloadQueueStore(fileURL: paths.queueFile),
            defaults: UserDefaults.standard,
            ipatoolVersion: { try await locator.detectVersion(paths: paths) },
            makeUpdateChecker: { UpdateChecker(owner: $0, repo: ProjectInfo.repositoryName) },
            setupError: setupError,
            currentAccount: currentAccount,
            switcher: switcher,
            catalog: PublicCatalogService()
        )
    }
}
