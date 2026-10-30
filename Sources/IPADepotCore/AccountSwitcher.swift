import Foundation

// MARK: - 认证协议（界面层与切换器共用，便于测试替身注入）

/// `auth info` / `auth revoke`。
public protocol AuthServicing: Sendable {
    func info() async throws -> AccountInfo
    func revoke() async throws
}

/// 与 `LoginSession` 同形的登录会话。
public protocol LoginSessioning: AnyObject, Sendable {
    func login(email: String, password: String,
               onEvent: @escaping @Sendable (LoginEvent) -> Void) async -> Result<AccountInfo, IpatoolError>
    func submitTwoFactorCode(_ code: String) throws
    func cancel()
}

extension AuthService: AuthServicing {}
extension LoginSession: LoginSessioning {}

// MARK: - 切换状态与结果

/// 切换流程所处阶段。
public enum AccountSwitchPhase: Sendable, Equatable {
    case idle
    /// 保存当前账号的 Cookie。
    case savingCookies
    /// `auth revoke`（删除 ipatool 钥匙串槽位里的当前账号）。
    case revoking
    /// 换入目标账号的 Cookie。
    case restoringCookies
    /// 用保存的密码经伪终端 `auth login`。
    case loggingIn
    /// 等待 6 位验证码（调用 `submitTwoFactorCode`）。
    case needsTwoFactor
    case verifying
    /// 切换失败，正在恢复原账号。
    case rollingBack
    case done
    case failed
}

/// 对外发布的切换进度。
public struct AccountSwitchProgress: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// 切换到已保存的账号。
        case switchTo
        /// 添加新账号（登录成功后写入账号表）。
        case add
    }

    public var kind: Kind
    public var phase: AccountSwitchPhase
    /// 目标账号（添加账号时为待写入的记录）。
    public var target: AccountRecord
    /// 切换前的激活账号。
    public var previous: AccountRecord?
    /// ipatool 的日志或补充说明（如「首次准备组件」）。
    public var detail: String?
    /// 是否处于「恢复原账号」的登录中（此时验证码属于原账号）。
    public var isRollback: Bool
    /// `.done` 时：切换后的账号记录（含更新后的姓名、登录时间）。
    public var switched: AccountRecord?
    /// `.failed` 时：失败原因与回滚结果。
    public var failure: AccountSwitchError?

    public init(kind: Kind, phase: AccountSwitchPhase, target: AccountRecord, previous: AccountRecord?,
                detail: String? = nil, isRollback: Bool = false, switched: AccountRecord? = nil,
                failure: AccountSwitchError? = nil) {
        self.kind = kind
        self.phase = phase
        self.target = target
        self.previous = previous
        self.detail = detail
        self.isRollback = isRollback
        self.switched = switched
        self.failure = failure
    }
}

/// 失败后回滚的结果。
public enum AccountRollbackOutcome: Sendable, Equatable {
    /// 无需回滚（还没动到登录状态，或切换前本来就未登录）。
    case notNeeded
    /// 已恢复为原账号。
    case restored(AccountRecord)
    /// 没能恢复原账号，现在处于未登录状态（`reason` 为原因）。
    case signedOut(reason: String)
}

public struct AccountSwitchError: Error, Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// 另一个切换正在进行。
        case busy
        case accountNotFound
        /// 目标账号没有保存密码（需要用户补一次）。
        case passwordMissing
        /// 该邮箱已在账号表中（添加账号时）。
        case alreadyExists
        /// 读写 Cookie 文件失败。
        case cookieStorage(String)
        /// 钥匙串读写失败。
        case vault(String)
        case revokeFailed(IpatoolError)
        case loginFailed(IpatoolError)
    }

    public let reason: Reason
    public let target: AccountRecord?
    public let rollback: AccountRollbackOutcome

    public init(reason: Reason, target: AccountRecord?, rollback: AccountRollbackOutcome = .notNeeded) {
        self.reason = reason
        self.target = target
        self.rollback = rollback
    }

    /// 底层 ipatool 错误（如有）。
    public var ipatoolError: IpatoolError? {
        switch reason {
        case .revokeFailed(let e), .loginFailed(let e): return e
        default: return nil
        }
    }

    /// 是否为用户取消（如在验证码步骤点了取消）。
    public var isCancelled: Bool { ipatoolError?.kind == .cancelled }

    /// 简短的原始说明（英文 / 系统信息），供「查看原始错误」与日志。
    public var rawDescription: String {
        switch reason {
        case .busy: return "another account switch is in progress"
        case .accountNotFound: return "account not found"
        case .passwordMissing: return "no saved password for this account"
        case .alreadyExists: return "account already exists"
        case .cookieStorage(let text), .vault(let text): return text
        case .revokeFailed(let e), .loginFailed(let e): return e.raw.isEmpty ? e.message : e.raw
        }
    }
}

// MARK: - 切换器

/// 多账号切换：ipatool 在 macOS 只有一个钥匙串账号槽位，所以切换 =
/// 保存当前账号 Cookie → `auth revoke` → 换入目标账号 Cookie → 用钥匙串里保存的密码经伪终端 `auth login`（必要时 2FA）。
/// 失败时回滚：换回原账号 Cookie 并用原账号密码重新登录；仍失败则进入「未登录」并在结果里说明。
///
/// 调用方须保证切换期间没有其他 ipatool 子进程在运行（下载队列一次只跑一个任务，切换由队列在两个任务之间发起；
/// 界面在切换时用遮罩挡住操作）。
public actor AccountSwitcher {
    public nonisolated let store: AccountStore
    public nonisolated let vault: CredentialVault
    public nonisolated let cookies: CookieJarArchive
    public nonisolated let auth: AuthServicing
    public nonisolated let current: CurrentAccount
    private let makeLoginSession: @Sendable () -> LoginSessioning
    private let now: @Sendable () -> Date

    private var busy = false
    /// 进行中的登录会话（加锁，供界面同步回填验证码 / 取消）。
    private nonisolated let activeSession = SessionBox()
    private var progress: AccountSwitchProgress?
    private var subscribers: [UUID: AsyncStream<AccountSwitchProgress>.Continuation] = [:]

    public init(store: AccountStore, vault: CredentialVault, cookies: CookieJarArchive, auth: AuthServicing,
                current: CurrentAccount, makeLoginSession: @escaping @Sendable () -> LoginSessioning,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.vault = vault
        self.cookies = cookies
        self.auth = auth
        self.current = current
        self.makeLoginSession = makeLoginSession
        self.now = now
    }

    // MARK: 查询 / 订阅

    public var isBusy: Bool { busy }

    public var book: AccountBook { store.load() }

    /// 订阅进度。流在订阅时先发当前进度（如有），之后每次变化发一次。
    public func updates() -> AsyncStream<AccountSwitchProgress> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<AccountSwitchProgress>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(key) }
        }
        subscribers[key] = continuation
        if let progress { continuation.yield(progress) }
        return stream
    }

    private func unsubscribe(_ key: UUID) { subscribers[key] = nil }

    private func publish(_ phase: AccountSwitchPhase, detail: String? = nil, isRollback: Bool? = nil) {
        guard var p = progress else { return }
        p.phase = phase
        p.detail = detail
        if let isRollback { p.isRollback = isRollback }
        progress = p
        for continuation in subscribers.values { continuation.yield(p) }
    }

    // MARK: 2FA / 取消

    /// 回填验证码（转给当前登录会话；可在任意线程同步调用）。
    public nonisolated func submitTwoFactorCode(_ code: String) throws {
        guard let session = activeSession.get() else {
            throw IpatoolError(kind: .unknown, raw: "not waiting for a 2FA code")
        }
        try session.submitTwoFactorCode(code)
    }

    /// 取消进行中的登录（会触发回滚；可在任意线程同步调用）。
    public nonisolated func cancel() {
        activeSession.get()?.cancel()
    }

    // MARK: 切换

    /// 切换到已保存的账号。`password` 非 nil 时使用它（用户补填 / 更新的密码），登录成功后写入钥匙串。
    public func switchTo(_ accountID: UUID, password: String? = nil,
                         onEvent: (@Sendable (LoginEvent) -> Void)? = nil) async -> Result<AccountRecord, AccountSwitchError> {
        guard !busy else { return .failure(AccountSwitchError(reason: .busy, target: nil)) }
        let book = store.load()
        guard let target = book.account(accountID) else {
            return .failure(AccountSwitchError(reason: .accountNotFound, target: nil))
        }
        if book.activeAccountID == accountID, password == nil {
            current.id = accountID
            return .success(target)
        }
        let secret: String
        if let password {
            secret = password
        } else {
            do {
                guard let saved = try vault.password(for: target.email) else {
                    return .failure(AccountSwitchError(reason: .passwordMissing, target: target))
                }
                secret = saved
            } catch {
                return .failure(AccountSwitchError(reason: .vault(error.localizedDescription), target: target))
            }
        }
        return await perform(kind: .switchTo, target: target, password: secret,
                             storePassword: password != nil, book: book, onEvent: onEvent)
    }

    /// 添加新账号：保存并退出当前账号（如有）→ 用新账号登录 → 成功后写入账号表与钥匙串并设为当前账号。
    public func addAccount(email: String, password: String, region: AccountRegion, customRegionCode: String? = nil,
                           onEvent: (@Sendable (LoginEvent) -> Void)? = nil) async -> Result<AccountRecord, AccountSwitchError> {
        guard !busy else { return .failure(AccountSwitchError(reason: .busy, target: nil)) }
        let book = store.load()
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = book.account(email: trimmed) {
            // 已存在：等同于用新密码切换过去（并更新地区标签）
            var updated = existing
            updated.regionLabel = region
            updated.customRegionCode = region == .other ? customRegionCode.flatMap(RegionCatalog.normalizeCode) : nil
            var next = book
            next.upsert(updated)
            try? store.save(next)
            return await perform(kind: .switchTo, target: updated, password: password, storePassword: true,
                                 book: next, onEvent: onEvent)
        }
        let record = AccountRecord(email: trimmed, regionLabel: region, customRegionCode: customRegionCode, passwordState: .saved)
        return await perform(kind: .add, target: record, password: password, storePassword: true,
                             book: book, onEvent: onEvent)
    }

    private func perform(kind: AccountSwitchProgress.Kind, target: AccountRecord, password: String,
                         storePassword: Bool, book: AccountBook,
                         onEvent: (@Sendable (LoginEvent) -> Void)?) async -> Result<AccountRecord, AccountSwitchError> {
        busy = true
        defer {
            busy = false
            activeSession.set(nil)
        }
        let previous = book.active
        progress = AccountSwitchProgress(kind: kind, phase: .idle, target: target, previous: previous)

        // 1. 保存当前账号的 Cookie
        if let previous {
            publish(.savingCookies)
            do {
                try cookies.save(accountID: previous.id)
            } catch {
                return finishFailure(AccountSwitchError(reason: .cookieStorage(error.localizedDescription), target: target))
            }

            // 2. revoke（只在切换前有激活账号时；未登录时登录会直接覆盖槽位）
            publish(.revoking)
            do {
                try await auth.revoke()
            } catch let error as IpatoolError where error.kind == .notLoggedIn {
                // 槽位本来就是空的
            } catch {
                let ipatoolError = (error as? IpatoolError) ?? IpatoolError(kind: .unknown, raw: error.localizedDescription)
                // revoke 失败：确认是否仍登录着原账号；已退出则尝试重登原账号
                let rollback = await rollbackIfSignedOut(previous: previous, onEvent: onEvent)
                return finishFailure(AccountSwitchError(reason: .revokeFailed(ipatoolError), target: target,
                                                        rollback: rollback))
            }
        }

        // 3. 换入目标账号的 Cookie。添加账号且切换前未登录时保留现有 Cookie（与单账号时的首次登录行为一致）
        if previous != nil || kind == .switchTo {
            publish(.restoringCookies)
            do {
                if kind == .add {
                    try cookies.clearLive()
                } else {
                    try cookies.restore(accountID: target.id)
                }
            } catch {
                let rollback = await rollback(previous: previous, onEvent: onEvent)
                return finishFailure(AccountSwitchError(reason: .cookieStorage(error.localizedDescription),
                                                        target: target, rollback: rollback))
            }
        }

        // 4. 登录
        if previous != nil { current.id = nil }
        switch await login(email: target.email, password: password, isRollback: false, onEvent: onEvent) {
        case .success(let info):
            var record = target
            record.lastLoginAt = now()
            if !info.name.trimmingCharacters(in: .whitespaces).isEmpty { record.displayName = info.name }
            var vaultProblem: String?
            if storePassword {
                do {
                    try vault.setPassword(password, for: record.email)
                    record.passwordState = .saved
                } catch {
                    vaultProblem = error.localizedDescription
                    record.passwordState = .missing
                }
            }
            var next = store.load()
            next.upsert(record)
            next.activeAccountID = record.id
            try? store.save(next)
            try? cookies.save(accountID: record.id)
            current.id = record.id
            progress?.switched = record
            publish(.done, detail: vaultProblem)
            progress = nil
            return .success(record)
        case .failure(let error):
            let rollback = await rollback(previous: previous, onEvent: onEvent)
            return finishFailure(AccountSwitchError(reason: .loginFailed(error), target: target, rollback: rollback))
        }
    }

    private func finishFailure(_ error: AccountSwitchError) -> Result<AccountRecord, AccountSwitchError> {
        progress?.failure = error
        publish(.failed, detail: error.rawDescription, isRollback: false)
        progress = nil
        return .failure(error)
    }

    private func login(email: String, password: String, isRollback: Bool,
                       onEvent: (@Sendable (LoginEvent) -> Void)?) async -> Result<AccountInfo, IpatoolError> {
        publish(isRollback ? .rollingBack : .loggingIn, isRollback: isRollback)
        let session = makeLoginSession()
        activeSession.set(session)
        let (events, continuation) = AsyncStream<LoginEvent>.makeStream()
        let relay = Task { [weak self] in
            for await event in events { await self?.handleLoginEvent(event, isRollback: isRollback) }
        }
        let result = await session.login(email: email, password: password) { event in
            continuation.yield(event)
            onEvent?(event)
        }
        continuation.finish()
        await relay.value
        activeSession.set(nil)
        return result
    }

    private func handleLoginEvent(_ event: LoginEvent, isRollback: Bool) {
        switch event {
        case .needsTwoFactor: publish(.needsTwoFactor, isRollback: isRollback)
        case .verifyingTwoFactor: publish(.verifying, isRollback: isRollback)
        case .preparing: publish(isRollback ? .rollingBack : .loggingIn, detail: "preparing", isRollback: isRollback)
        case .log(let text): publish(isRollback ? .rollingBack : .loggingIn, detail: text, isRollback: isRollback)
        case .succeeded, .failed: break
        }
    }

    /// 回滚：换回原账号 Cookie，用原账号保存的密码重新登录。
    private func rollback(previous: AccountRecord?, onEvent: (@Sendable (LoginEvent) -> Void)?) async -> AccountRollbackOutcome {
        guard let previous else {
            markSignedOut()
            return .notNeeded
        }
        publish(.rollingBack, isRollback: true)
        try? cookies.restore(accountID: previous.id)
        let password: String?
        do {
            password = try vault.password(for: previous.email)
        } catch {
            markSignedOut()
            return .signedOut(reason: error.localizedDescription)
        }
        guard let password else {
            markSignedOut()
            return .signedOut(reason: AccountSwitchError(reason: .passwordMissing, target: previous).rawDescription)
        }
        switch await login(email: previous.email, password: password, isRollback: true, onEvent: onEvent) {
        case .success:
            var next = store.load()
            next.update(previous.id) { $0.lastLoginAt = self.now() }
            next.activeAccountID = previous.id
            try? store.save(next)
            try? cookies.save(accountID: previous.id)
            current.id = previous.id
            return .restored(previous)
        case .failure(let error):
            markSignedOut()
            return .signedOut(reason: error.raw.isEmpty ? error.message : error.raw)
        }
    }

    /// revoke 失败时：仍登录着原账号就什么都不做；已退出则走回滚。
    private func rollbackIfSignedOut(previous: AccountRecord, onEvent: (@Sendable (LoginEvent) -> Void)?) async -> AccountRollbackOutcome {
        if let info = try? await auth.info(), previous.matches(email: info.email) {
            return .notNeeded
        }
        return await rollback(previous: previous, onEvent: onEvent)
    }

    private func markSignedOut() {
        var next = store.load()
        next.activeAccountID = nil
        try? store.save(next)
        current.id = nil
    }

    // MARK: 账号表维护

    /// 登出当前账号：保存其 Cookie 后 revoke，账号仍保留在列表里。
    public func signOut() async throws {
        guard !busy else { throw AccountSwitchError(reason: .busy, target: nil) }
        busy = true
        defer { busy = false }
        let book = store.load()
        if let active = book.active { try? cookies.save(accountID: active.id) }
        do {
            try await auth.revoke()
        } catch let error as IpatoolError where error.kind == .notLoggedIn {
            // 已经是未登录状态
        }
        markSignedOut()
    }

    /// 移除账号：删除其 Cookie 与钥匙串里的密码。移除当前激活账号时先 revoke 并清空当前 Cookie 文件。
    public func remove(_ accountID: UUID) async throws {
        guard !busy else { throw AccountSwitchError(reason: .busy, target: nil) }
        busy = true
        defer { busy = false }
        var book = store.load()
        guard let record = book.account(accountID) else { return }
        if book.activeAccountID == accountID {
            do {
                try await auth.revoke()
            } catch let error as IpatoolError where error.kind == .notLoggedIn {
                // 已经是未登录状态
            }
            try cookies.clearLive()
            current.id = nil
        }
        cookies.removeArchive(accountID: accountID)
        try? vault.removePassword(for: record.email)
        book.remove(accountID)
        try store.save(book)
    }

    /// 修改地区标签（「其他」可带自填的两位国家代码）。
    public func setRegion(_ region: AccountRegion, customCode: String? = nil, for accountID: UUID) throws {
        var book = store.load()
        book.update(accountID) {
            $0.regionLabel = region
            $0.customRegionCode = region == .other ? customCode.flatMap(RegionCatalog.normalizeCode) : nil
        }
        try store.save(book)
    }

    /// 补填 / 更新密码（只写钥匙串，不立即登录验证；下次切换到该账号时使用）。
    public func updatePassword(_ password: String, for accountID: UUID) throws {
        var book = store.load()
        guard let record = book.account(accountID) else { throw AccountSwitchError(reason: .accountNotFound, target: nil) }
        do {
            try vault.setPassword(password, for: record.email)
        } catch {
            throw AccountSwitchError(reason: .vault(error.localizedDescription), target: record)
        }
        book.update(accountID) { $0.passwordState = .saved }
        try store.save(book)
    }

    /// 0.1.0 升级迁移：账号表为空且 `auth info` 已登录时，为当前登录账号建一条记录（密码待补、地区「其他」待用户选择）。
    /// 返回新建的记录；不满足条件返回 nil。
    public func migrateIfNeeded(signedIn info: AccountInfo) -> AccountRecord? {
        guard store.load().isEmpty else { return nil }
        return adoptSignedInAccount(info)?.record
    }

    /// 启动时 `auth info` 的账号不在账号表里（表为空 = 0.1.0 升级迁移；表不为空 = 例如在终端用别的账号登录过）：
    /// 自动加入账号表（密码待补、地区「其他」待用户选择）并设为当前账号。与升级迁移共用这一段。
    /// 已在表里或邮箱为空返回 nil。
    public func adoptSignedInAccount(_ info: AccountInfo) -> AccountAdoption? {
        var book = store.load()
        guard !info.email.isEmpty, book.account(email: info.email) == nil else { return nil }
        let isMigration = book.isEmpty
        let record = AccountRecord(email: info.email, displayName: info.name, regionLabel: .other,
                                   lastLoginAt: nil, passwordState: .missing)
        book.upsert(record)
        book.activeAccountID = record.id
        guard (try? store.save(book)) != nil else { return nil }
        try? cookies.save(accountID: record.id)
        current.id = record.id
        return AccountAdoption(record: record, isMigration: isMigration)
    }

    /// 启动时与 `auth info` 的结果对账：已登录且邮箱与账号表中某条一致 → 设为激活；未登录 → 激活置空。
    /// 返回对账后的激活账号。
    @discardableResult
    public func reconcile(signedIn info: AccountInfo?) -> AccountRecord? {
        var book = store.load()
        let active: AccountRecord?
        if let info, let match = book.account(email: info.email) {
            active = match
        } else {
            active = nil
        }
        if book.activeAccountID != active?.id {
            book.activeAccountID = active?.id
            try? store.save(book)
        }
        current.id = active?.id
        return active
    }
}

/// `adoptSignedInAccount` 的结果。
public struct AccountAdoption: Sendable, Equatable {
    public let record: AccountRecord
    /// 账号表原本为空（0.1.0 升级迁移）：此时还要给旧下载记录与队列条目盖上该账号 id。
    public let isMigration: Bool
}

// MARK: - 下载队列的自动切换

extension AccountSwitcher: DownloadAccountSwitching {
    public nonisolated func isCurrentAccount(_ accountID: UUID) -> Bool {
        current.id == accountID
    }

    public func switchForDownload(to accountID: UUID) async throws {
        switch await switchTo(accountID) {
        case .success:
            return
        case .failure(let error):
            throw IpatoolError(kind: .accountSwitchFailed, raw: error.rawDescription)
        }
    }
}

/// 加锁保存进行中的登录会话。
final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: LoginSessioning?
    func set(_ session: LoginSessioning?) { lock.withLock { self.session = session } }
    func get() -> LoginSessioning? { lock.withLock { session } }
}
