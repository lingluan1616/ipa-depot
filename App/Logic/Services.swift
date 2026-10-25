import Foundation
import IPADepotCore

// MARK: - 服务协议（视图模型只依赖这些协议，便于测试替身注入）

protocol AuthServicing: Sendable {
    func info() async throws -> AccountInfo
    func revoke() async throws
}

/// 与 `LoginSession` 同形的登录会话。
protocol LoginSessioning: AnyObject, Sendable {
    func login(email: String, password: String,
               onEvent: @escaping @Sendable (LoginEvent) -> Void) async -> Result<AccountInfo, IpatoolError>
    func submitTwoFactorCode(_ code: String) throws
    func cancel()
}

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
}

protocol DownloadQueueing: Sendable {
    @discardableResult func add(_ request: DownloadRequest, id: UUID) async -> UUID
    func pause(_ id: UUID) async
    func resume(_ id: UUID) async
    func cancel(_ id: UUID) async
    func remove(_ id: UUID) async
    func removeCompleted() async
    func updates() async -> AsyncStream<[DownloadQueueItem]>
    /// 放回上次保存的任务（`.paused`，不自动开始）。
    func restore(_ request: DownloadRequest, id: UUID, progress: DownloadProgress?, addedAt: Date) async
    /// App 退出时同步终止正在运行的下载子进程。
    func terminateRunningTasks()
}

protocol UpdateChecking: Sendable {
    func check(currentVersion: String) async throws -> UpdateCheckResult
}

/// 简单键值存储（`UserDefaults` 实现；测试用内存替身）。
protocol KeyValueStoring: AnyObject {
    func string(forKey defaultName: String) -> String?
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
}

extension AuthService: AuthServicing {}
extension LoginSession: LoginSessioning {}
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
        return AppServices(
            paths: paths,
            auth: AuthService(runner: runner),
            makeLoginSession: { LoginSession(runner: runner) },
            search: SearchService(runner: runner),
            versions: VersionService(runner: runner),
            lookup: AppLookupService(directory: paths.artworkCacheDirectory),
            queue: DownloadQueue(runner: runner),
            historyStore: HistoryStore(fileURL: paths.historyFile),
            queueStore: DownloadQueueStore(fileURL: paths.queueFile),
            defaults: UserDefaults.standard,
            ipatoolVersion: { try await locator.detectVersion(paths: paths) },
            makeUpdateChecker: { UpdateChecker(owner: $0, repo: ProjectInfo.repositoryName) },
            setupError: setupError
        )
    }
}
