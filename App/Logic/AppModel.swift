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
    let accounts: AccountsViewModel
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
        let accounts = AccountsViewModel(switcher: services.switcher)
        let currentAccount = services.currentAccount
        let downloads = DownloadsViewModel(queue: services.queue, store: services.queueStore,
                                           destination: { try settings.ensureDownloadDirectory() },
                                           currentAccountID: { currentAccount.id })
        downloads.regionLabel = { [weak accounts] accountID in accounts?.region(for: accountID)?.rawValue }
        let artwork = ArtworkStore(lookup: services.lookup)
        self.settings = settings
        self.history = history
        self.downloads = downloads
        self.accounts = accounts
        self.artwork = artwork
        var signedIn: () -> Bool = { false }
        self.search = SearchViewModel(service: services.search, isSignedIn: { signedIn() })
        signedIn = { [weak self] in self?.account != nil }
        downloads.onRecord = { [weak history] record in history?.add(record) }
        settings.onCacheCleared = { [weak artwork] in artwork?.reset() }
        accounts.onSwitched = { [weak self] record, previous, _ in self?.accountSwitched(to: record, from: previous) }
        accounts.onFailed = { [weak self] progress, error in self?.accountSwitchFailed(progress, error: error) }
        accounts.onAddProgress = { [weak self] progress in self?.login?.applySwitchProgress(progress) }
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
        accounts.startObserving()
        await services.queue.setAccountSwitching(services.switcher)
        downloads.startObserving()
        observeTermination()
        if hasCompletedFirstLogin {
            await refreshAccount()
        } else {
            await services.switcher.reconcile(signedIn: nil)
            accounts.reload()
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

    /// 查询 ipatool 当前登录的账号，并与账号表对账；0.1.0 升级上来（账号表为空）时自动建一条账号并请用户选地区。
    func refreshAccount() async {
        accountState = .checking
        do {
            let info = try await services.auth.info()
            let switcher = services.switcher
            if await switcher.reconcile(signedIn: info) == nil,
               let migrated = await switcher.migrateIfNeeded(signedIn: info) {
                accounts.regionPrompt = migrated
            }
            accounts.reload()
            accountState = .signedIn(info)
        } catch let error as IpatoolError where error.kind == .notLoggedIn {
            await services.switcher.reconcile(signedIn: nil)
            accounts.reload()
            accountState = .signedOut
        } catch let error as IpatoolError {
            accountState = .unknown(ErrorPresentation(error))
        } catch {
            accountState = .unknown(ErrorPresentation(message: error.localizedDescription))
        }
    }

    // MARK: - 登录 / 登出

    /// 登录 / 添加账号：同一个登录窗口，登录交给账号切换器（成功后写入账号表与钥匙串）。
    /// 还没有任何账号时先显示准备页；已有账号时直接填账号密码。
    func beginLogin() {
        let switcher = services.switcher
        let mode: LoginViewModel.Mode = accounts.accounts.isEmpty ? .signIn : .addAccount
        let model = LoginViewModel(mode: mode, makeSession: { region in
            SwitcherLoginSession(switcher: switcher, region: region)
        })
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

    /// 登出当前账号：保存其会话后 revoke；账号保留在列表里，之后可一键切回。
    func logout() async {
        isLoggingOut = true
        defer { isLoggingOut = false }
        do {
            try await services.switcher.signOut()
            accounts.reload()
        } catch let error as IpatoolError where error.kind == .notLoggedIn {
            // 已经是未登录状态，按成功处理
        } catch let error as IpatoolError {
            logoutError = ErrorPresentation(error)
            return
        } catch let error as AccountSwitchError {
            logoutError = ErrorPresentation(message: String(localized: "账号切换正在进行，请稍后再试。"), raw: error.rawDescription)
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

    // MARK: - 多账号

    /// 有下载在进行（含正在为下载切换账号）时不允许手动切换。
    var canSwitchAccounts: Bool { !downloads.hasActiveDownload && !accounts.isSwitching }

    func switchAccount(to account: AccountRecord) {
        guard canSwitchAccounts else { return }
        Task { await accounts.switchTo(account) }
    }

    /// 移除账号（移除当前账号时会先退出登录）。
    func removeAccount(_ account: AccountRecord) async {
        let wasActive = accounts.active?.id == account.id
        guard await accounts.remove(account) else { return }
        if wasActive {
            services.defaults.set(false, forKey: Self.firstLoginKey)
            accountState = .signedOut
            resetForAccountChange(label: nil)
        }
    }

    /// 切换（或添加）成功：更新账号状态，搜索与历史版本页清空并提示重新搜索（不自动发请求）。
    func accountSwitched(to record: AccountRecord, from previous: AccountRecord?) {
        services.defaults.set(true, forKey: Self.firstLoginKey)
        accountState = .signedIn(record.accountInfo)
        if previous != nil {
            resetForAccountChange(label: record.regionLabel.title)
        }
    }

    /// 切换失败（切换器已回滚）：按回滚结果更新账号状态。
    func accountSwitchFailed(_ progress: AccountSwitchProgress, error: AccountSwitchError) {
        switch error.rollback {
        case .restored(let previous):
            accountState = .signedIn(previous.accountInfo)
            if progress.kind == .add {
                login?.rollbackNote = String(localized: "已恢复为原来的 \(previous.regionLabel.title) 账号。")
            }
        case .signedOut:
            accountState = .signedOut
            resetForAccountChange(label: nil)
            if progress.kind == .add {
                login?.rollbackNote = String(localized: "未能恢复原来的账号，现在处于未登录状态。")
            }
        case .notNeeded:
            break
        }
    }

    /// `label` 为新账号的地区名；nil = 现在未登录（回到搜索首页）。
    private func resetForAccountChange(label: String?) {
        if label == nil { searchPath = [] }
        search.accountChanged(label: label)
        versionModels.values.forEach { $0.accountChanged(label: label) }
    }

    /// 历史版本页的视图模型（按 App 复用，返回再进入时保留已加载的版本号）。
    func versionsModel(for row: AppRowModel) -> VersionsViewModel {
        if let existing = versionModels[row.id], existing.platform == row.platform { return existing }
        let model = VersionsViewModel(app: row.app, platform: row.platform, service: services.versions)
        versionModels[row.id] = model
        return model
    }
}
