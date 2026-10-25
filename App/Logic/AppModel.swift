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

    init(services: AppServices) {
        self.services = services
        let settings = SettingsViewModel(defaults: services.defaults, paths: services.paths,
                                         ipatoolVersion: services.ipatoolVersion,
                                         makeUpdateChecker: services.makeUpdateChecker)
        let history = HistoryViewModel(store: services.historyStore)
        let downloads = DownloadsViewModel(queue: services.queue, destination: { try settings.ensureDownloadDirectory() })
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

    /// 启动时查询账号状态（未登录不算错误）。
    func bootstrap() async {
        downloads.startObserving()
        await refreshAccount()
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
