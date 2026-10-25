import AppKit
import Foundation
import Observation
import IPADepotCore

/// 根视图模型：账号状态、侧栏导航、各页面视图模型的组合。
@MainActor
@Observable
final class AppModel {
    enum Page: String, Hashable, CaseIterable, Identifiable {
        case search, downloads, history, settings
        var id: String { rawValue }
    }

    enum AccountState: Equatable {
        case checking
        case signedOut
        case signedIn(AccountInfo)
        /// 查询账号状态失败（非「未登录」），侧栏显示可重试的提示，不弹窗。
        case unknown(ErrorPresentation)
    }

    /// 首次登录成功后置真；为假时启动不调用 `auth info`（不读钥匙串，避免用户看到准备页之前就弹授权框）。
    static let firstLoginKey = "hasCompletedFirstLogin"

    var page: Page? = .search
    /// 搜索页的导航栈（进入历史版本页）。
    var searchPath: [AppRowModel] = []
    private(set) var accountState: AccountState = .checking
    var login: LoginViewModel?
    var isLoggingOut = false
    var logoutError: ErrorPresentation?

    let search: SearchViewModel
    let downloads: DownloadsViewModel
    let history: HistoryViewModel
    let settings: SettingsViewModel
    let artwork: ArtworkStore

    @ObservationIgnored let services: AppServices
    @ObservationIgnored private var versionModels: [Int64: VersionsViewModel] = [:]
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    init(services: AppServices) {
        self.services = services
        let settings = SettingsViewModel(defaults: services.defaults, paths: services.paths,
                                         ipatoolVersion: services.ipatoolVersion,
                                         makeUpdateChecker: services.makeUpdateChecker)
        let history = HistoryViewModel(store: services.historyStore)
        let downloads = DownloadsViewModel(queue: services.queue, store: services.queueStore,
                                           destination: { try settings.ensureDownloadDirectory() })
        let artwork = ArtworkStore(lookup: services.lookup)
        self.settings = settings
        self.history = history
        self.downloads = downloads
        self.artwork = artwork
        var signedIn: () -> Bool = { false }
        self.search = SearchViewModel(service: services.search, isSignedIn: { signedIn() })
        signedIn = { [weak self] in self?.account != nil }
        downloads.onRecord = { [weak history] record in history?.add(record) }
        settings.onCacheCleared = { [weak artwork] in artwork?.reset() }
    }

    var account: AccountInfo? {
        if case .signedIn(let info) = accountState { return info }
        return nil
    }

    var setupError: ErrorPresentation? { services.setupError.map(ErrorPresentation.init) }

    /// 是否已完成过首次登录（`UserDefaults` 的 `hasCompletedFirstLogin`）。
    var hasCompletedFirstLogin: Bool { services.defaults.bool(forKey: Self.firstLoginKey) }

    /// 启动：恢复下载队列；完成过首次登录才查询账号状态（未登录不算错误），否则直接显示未登录、不碰钥匙串。
    func bootstrap() async {
        downloads.startObserving()
        observeTermination()
        if hasCompletedFirstLogin {
            await refreshAccount()
        } else {
            accountState = .signedOut
        }
    }

    /// App 退出时：把队列按暂停写盘，并终止正在运行的下载子进程（`.tmp` 保留，下次续传）。
    func prepareForTermination() {
        downloads.persistNow()
        services.queue.terminateRunningTasks()
    }

    private func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareForTermination() }
        }
    }

    #if DEBUG
    /// 仅供 Debug 冒烟截图展示未登录界面（不调用 ipatool、不改动钥匙串）。
    func debugShowSignedOutState() {
        accountState = .signedOut
    }
    #endif

    func refreshAccount() async {
        accountState = .checking
        do {
            accountState = .signedIn(try await services.auth.info())
        } catch let error as IpatoolError where error.kind == .notLoggedIn {
            accountState = .signedOut
        } catch let error as IpatoolError {
            accountState = .unknown(ErrorPresentation(error))
        } catch {
            accountState = .unknown(ErrorPresentation(message: error.localizedDescription))
        }
    }

    // MARK: - 登录 / 登出

    func beginLogin() {
        let model = LoginViewModel(makeSession: services.makeLoginSession)
        model.onSuccess = { [weak self] info in
            self?.services.defaults.set(true, forKey: Self.firstLoginKey)
            self?.accountState = .signedIn(info)
            self?.login = nil
        }
        login = model
    }

    func dismissLogin() {
        login?.cancel()
        login = nil
    }

    func logout() async {
        isLoggingOut = true
        defer { isLoggingOut = false }
        do {
            try await services.auth.revoke()
        } catch let error as IpatoolError where error.kind == .notLoggedIn {
            // 已经是未登录状态，按成功处理
        } catch let error as IpatoolError {
            logoutError = ErrorPresentation(error)
            return
        } catch {
            logoutError = ErrorPresentation(message: error.localizedDescription)
            return
        }
        services.defaults.set(false, forKey: Self.firstLoginKey)
        accountState = .signedOut
        search.reset()
        searchPath = []
        versionModels.values.forEach { $0.cancel() }
        versionModels = [:]
    }

    /// 历史版本页的视图模型（按 App 复用，返回再进入时保留已加载的版本号）。
    func versionsModel(for row: AppRowModel) -> VersionsViewModel {
        if let existing = versionModels[row.id], existing.platform == row.platform { return existing }
        let model = VersionsViewModel(app: row.app, platform: row.platform, service: services.versions)
        versionModels[row.id] = model
        return model
    }
}
