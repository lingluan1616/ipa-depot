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
    /// 公开目录结果没有对应地区的账号时的提示（「没有 X 地区的账号」）。
    var missingRegionPrompt: MissingRegionPrompt?
    /// 公开目录操作被拒绝的原因（如有下载进行中，暂不能切换账号）。
    var catalogActionError: ErrorPresentation?
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
    /// 等账号切换（或添加账号）完成后继续的公开目录操作。
    @ObservationIgnored private(set) var pendingCatalogAction: PendingCatalogAction?

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
        downloads.regionLabel = { [weak accounts] accountID in accounts?.regionSnapshot(for: accountID) }
        downloads.regionTitle = { [weak accounts] accountID in accounts?.regionTitle(for: accountID) }
        let artwork = ArtworkStore(lookup: services.lookup)
        self.settings = settings
        self.history = history
        self.downloads = downloads
        self.accounts = accounts
        self.artwork = artwork
        var signedIn: () -> Bool = { false }
        self.search = SearchViewModel(service: services.search, catalog: services.catalog, defaults: services.defaults,
                                      isSignedIn: { signedIn() })
        signedIn = { [weak self] in self?.account != nil }
        downloads.onRecord = { [weak history] record in history?.add(record) }
        settings.onCacheCleared = { [weak artwork] in artwork?.reset() }
        accounts.onSwitched = { [weak self] record, previous, _ in self?.accountSwitched(to: record, from: previous) }
        accounts.onFailed = { [weak self] progress, error in self?.accountSwitchFailed(progress, error: error) }
        accounts.onAddProgress = { [weak self] progress in self?.login?.applySwitchProgress(progress) }
        accounts.onSwitchStarted = { [weak self] in self?.cancelAccountScopedRequests() }
    }

    var account: AccountInfo? {
        if case .signedIn(let info) = accountState { return info }
        return nil
    }

    var setupError: ErrorPresentation? { services.setupError.map(ErrorPresentation.init) }

    /// 是否已完成过首次登录（`UserDefaults` 的 `hasCompletedFirstLogin`）。
    var hasCompletedFirstLogin: Bool { services.defaults.bool(forKey: Self.firstLoginKey) }

    /// 启动：恢复下载队列；完成过首次登录才查询账号状态（未登录不算错误），否则直接显示未登录、不碰钥匙串。
    /// 账号对账（含升级迁移给旧记录盖章）在恢复下载队列之前完成，这样恢复进内存的任务已带上账号 id。
    func bootstrap() async {
        accounts.startObserving()
        await services.queue.setAccountSwitching(services.switcher)
        observeTermination()
        if hasCompletedFirstLogin {
            await refreshAccount()
        } else {
            await services.switcher.reconcile(signedIn: nil)
            accounts.reload()
            accountState = .signedOut
        }
        downloads.startObserving()
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

    /// 查询 ipatool 当前登录的账号，并与账号表对账。登录着的账号不在账号表里时自动加入（密码待补）并请用户选一次地区：
    /// 账号表为空 = 0.1.0 升级迁移，此时还给旧下载记录与队列条目盖上该账号 id；表不为空 = 例如在终端用别的账号登录过。
    func refreshAccount() async {
        accountState = .checking
        do {
            let info = try await services.auth.info()
            let switcher = services.switcher
            if await switcher.reconcile(signedIn: info) == nil,
               let adoption = await switcher.adoptSignedInAccount(info) {
                if adoption.isMigration { stampLegacyRecords(accountID: adoption.record.id) }
                accounts.regionPrompt = adoption.record
            }
            accounts.reload()
            // 账号表里只有一个账号时，没有归属的旧记录 / 队列条目只可能属于它：补盖章（幂等）。
            // 覆盖已装过 0.2.0 早期包、迁移时还没有盖章逻辑的安装。
            if accounts.accounts.count == 1, let only = accounts.accounts.first {
                stampLegacyRecords(accountID: only.id, regionLabel: only.regionLabel.rawValue)
            }
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

    /// 升级迁移：旧 `history.json` / `queue.json` 中没有账号归属的条目统一盖上迁移账号 id（幂等），并刷新记录页。
    private func stampLegacyRecords(accountID: UUID, regionLabel: String? = nil) {
        let queueStore = services.queueStore ?? DownloadQueueStore(fileURL: services.paths.queueFile)
        _ = try? LegacyAccountStamp.stamp(accountID: accountID, regionLabel: regionLabel,
                                          history: services.historyStore, queue: queueStore)
        history.reload()
    }

    // MARK: - 登录 / 登出

    /// 登录 / 添加账号：同一个登录窗口，登录交给账号切换器（成功后写入账号表与钥匙串）。
    /// 还没有任何账号时先显示准备页；已有账号时直接填账号密码。
    /// - Parameters:
    ///   - region / customCode: 预选的地区（「没有 X 地区的账号」→「添加账号…」时为 X）。
    func beginLogin(region: AccountRegion? = nil, customCode: String? = nil) {
        let switcher = services.switcher
        let mode: LoginViewModel.Mode = accounts.accounts.isEmpty ? .signIn : .addAccount
        let model = LoginViewModel(mode: mode, makeSession: { region, customCode in
            SwitcherLoginSession(switcher: switcher, region: region, customRegionCode: customCode)
        })
        if let region {
            model.region = region
            model.customRegionCode = region == .other ? (customCode ?? "") : ""
        }
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
        if accounts.switchProgress == nil { pendingCatalogAction = nil }
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
            resetForAccountChange(label: record.regionTitle)
        }
        if let pending = pendingCatalogAction {
            pendingCatalogAction = nil
            if record.matches(countryCode: pending.countryCode) { run(pending.action) }
        }
    }

    /// 切换失败（切换器已回滚）：按回滚结果更新账号状态。
    func accountSwitchFailed(_ progress: AccountSwitchProgress, error: AccountSwitchError) {
        // 添加账号失败时登录窗口仍开着，用户可能重试，保留待继续的操作；切换失败则放弃。
        if progress.kind == .switchTo { pendingCatalogAction = nil }
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

    /// 切换开始时停掉进行中的搜索与历史版本请求（ipatool 子进程随任务取消而终止）。
    func cancelAccountScopedRequests() {
        search.cancelPending()
        versionModels.values.forEach { $0.cancel() }
    }

    /// `label` 为新账号的地区名；nil = 现在未登录（回到搜索首页）。
    private func resetForAccountChange(label: String?) {
        if label == nil { searchPath = [] }
        search.accountChanged(label: label)
        versionModels.values.forEach { $0.accountChanged(label: label) }
    }

    /// 历史版本页的视图模型（按 App 复用，返回再进入时保留已加载的版本号；切换账号后已清空的重新建）。
    func versionsModel(for row: AppRowModel) -> VersionsViewModel {
        if let existing = versionModels[row.id], existing.platform == row.platform {
            if case .accountChanged = existing.phase {} else { return existing }
        }
        let model = VersionsViewModel(app: row.app, platform: row.platform, service: services.versions)
        versionModels[row.id] = model
        return model
    }

    // MARK: - 浏览地区（公开目录）

    /// 搜索结果行上的「历史版本…」「下载最新版」。公开目录结果先找与浏览地区一致的账号：
    /// 当前账号匹配 → 直接继续；其他账号匹配 → 自动切换（遮罩）后继续；没有 → 提示「没有 X 地区的账号」。
    func perform(_ action: CatalogAction) {
        guard let code = action.row.app.catalogCountry else {
            run(action)
            return
        }
        switch accounts.book.match(countryCode: code) {
        case .current:
            run(action)
        case .other(let record):
            if canSwitchAccounts {
                pendingCatalogAction = PendingCatalogAction(action: action, countryCode: code)
                Task { await accounts.switchTo(record) }
            } else if case .download(let row) = action {
                // 有下载进行中：任务直接绑定到该账号，轮到它时队列会先自动切换
                Task { await downloads.enqueue(Self.latestContext(row), accountID: record.id) }
            } else {
                catalogActionError = ErrorPresentation(
                    message: String(localized: "有下载正在进行，暂时不能切换到 \(record.regionTitle) 账号。请等下载完成后再试。"))
            }
        case .none:
            missingRegionPrompt = MissingRegionPrompt(countryCode: code, action: action)
        }
    }

    /// 「没有 X 地区的账号」→「添加账号…」：登录窗口预选该地区；添加成功后继续原来的操作。
    func addAccount(for prompt: MissingRegionPrompt) {
        missingRegionPrompt = nil
        let region = RegionCatalog.region(forCode: prompt.countryCode) ?? .other
        pendingCatalogAction = PendingCatalogAction(action: prompt.action, countryCode: prompt.countryCode)
        beginLogin(region: region, customCode: region == .other ? prompt.countryCode : nil)
    }

    private func run(_ action: CatalogAction) {
        switch action {
        case .versions(let row):
            page = .search
            if searchPath.last != row { searchPath.append(row) }
        case .download(let row):
            Task { await downloads.enqueue(Self.latestContext(row)) }
        }
    }

    static func latestContext(_ row: AppRowModel) -> DownloadContext {
        DownloadContext(app: row.app, platform: row.platform, externalVersionID: nil, versionLabel: row.version)
    }
}

/// 搜索结果行上需要账号的操作。
enum CatalogAction: Equatable {
    case versions(AppRowModel)
    case download(AppRowModel)

    var row: AppRowModel {
        switch self {
        case .versions(let row), .download(let row): return row
        }
    }
}

/// 等账号切换（或添加）完成后继续的操作：新账号地区与 `countryCode` 一致才继续。
struct PendingCatalogAction: Equatable {
    let action: CatalogAction
    let countryCode: String
}

/// 「没有 X 地区的账号」。
struct MissingRegionPrompt: Identifiable, Equatable {
    let id = UUID()
    let countryCode: String
    let action: CatalogAction

    var regionTitle: String { AccountRegion.title(forCode: countryCode) }
}
