import Foundation
import Observation
import IPADepotCore

extension AccountRegion {
    /// 界面显示的地区名（中英双语见 String Catalog）。
    var title: String {
        switch self {
        case .mainlandChina: return String(localized: "中国大陆")
        case .hongKong: return String(localized: "香港")
        case .taiwan: return String(localized: "台湾")
        case .japan: return String(localized: "日本")
        case .unitedStates: return String(localized: "美国")
        case .korea: return String(localized: "韩国")
        case .other: return String(localized: "其他")
        }
    }
}

extension AccountRecord {
    /// 菜单与列表里的一行：「日本 · a@b.com」。
    var menuTitle: String { "\(regionLabel.title) · \(email)" }

    var accountInfo: AccountInfo { AccountInfo(name: displayName, email: email) }
}

/// 切换失败后的提示。
struct AccountSwitchFailurePresentation: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let presentation: ErrorPresentation
}

/// 需要用户输入密码：补填（切换到「密码待补」的账号）或更新。
struct AccountPasswordPrompt: Identifiable, Equatable {
    enum Purpose: Equatable {
        /// 输入后立即用它切换到该账号（成功后保存到钥匙串）。
        case switchTo
        /// 只更新钥匙串里的密码。
        case update
    }

    let id = UUID()
    let account: AccountRecord
    let purpose: Purpose
}

/// 多账号：账号表、切换进度（遮罩 / 验证码）、补密码、地区选择、管理账号。
@MainActor
@Observable
final class AccountsViewModel {
    private(set) var book = AccountBook()
    /// 进行中的切换（遮罩显示用；添加账号时由登录窗口显示进度，不显示遮罩）。
    private(set) var switchProgress: AccountSwitchProgress?
    var failure: AccountSwitchFailurePresentation?
    var passwordPrompt: AccountPasswordPrompt?
    /// 升级迁移后请用户选一次地区的账号。
    var regionPrompt: AccountRecord?
    var showingManager = false
    /// 遮罩里的验证码输入。
    var code = ""
    private(set) var codeHint: String?
    private(set) var isSubmittingCode = false
    /// 管理页操作的错误。
    var manageError: ErrorPresentation?

    /// 切换（或添加）成功：参数为新账号与切换前的账号。
    @ObservationIgnored var onSwitched: ((AccountRecord, AccountRecord?, AccountSwitchProgress.Kind) -> Void)?
    /// 切换失败（已回滚）。
    @ObservationIgnored var onFailed: ((AccountSwitchProgress, AccountSwitchError) -> Void)?
    /// 添加账号时的进度（转给登录窗口显示）。
    @ObservationIgnored var onAddProgress: ((AccountSwitchProgress) -> Void)?

    @ObservationIgnored let switcher: AccountSwitcher
    @ObservationIgnored private var observeTask: Task<Void, Never>?

    init(switcher: AccountSwitcher) {
        self.switcher = switcher
        book = switcher.store.load()
    }

    var accounts: [AccountRecord] { book.accounts }
    var active: AccountRecord? { book.active }
    var others: [AccountRecord] { book.accounts.filter { $0.id != book.activeAccountID } }

    /// 遮罩是否显示（切换到已保存账号的过程中）。
    var isOverlayVisible: Bool {
        guard let switchProgress, switchProgress.kind == .switchTo else { return false }
        return switchProgress.phase != .done && switchProgress.phase != .failed && switchProgress.phase != .idle
    }

    var isSwitching: Bool { switchProgress != nil }

    func reload() {
        book = switcher.store.load()
    }

    func account(_ id: UUID?) -> AccountRecord? {
        guard let id else { return nil }
        return book.account(id)
    }

    /// 某条任务 / 记录的地区标签：有账号 id 用账号表里的；账号已移除用快照；旧数据（无账号 id）视为当前账号。
    func region(for accountID: UUID?, snapshot: String? = nil) -> AccountRegion? {
        if let accountID, let record = book.account(accountID) { return record.regionLabel }
        if let snapshot, let region = AccountRegion(rawValue: snapshot) { return region }
        if accountID == nil { return book.active?.regionLabel }
        return nil
    }

    // MARK: - 订阅切换进度

    func startObserving() {
        guard observeTask == nil else { return }
        let switcher = self.switcher
        observeTask = Task { [weak self] in
            for await progress in await switcher.updates() {
                self?.apply(progress)
            }
        }
    }

    func apply(_ progress: AccountSwitchProgress) {
        switch progress.phase {
        case .done:
            switchProgress = nil
            resetCode()
            reload()
            if let record = progress.switched { onSwitched?(record, progress.previous, progress.kind) }
        case .failed:
            switchProgress = nil
            resetCode()
            reload()
            if let error = progress.failure {
                onFailed?(progress, error)
                if progress.kind == .switchTo, let presentation = Self.describeFailure(error, target: progress.target) {
                    failure = presentation
                }
            }
        case .needsTwoFactor:
            if switchProgress?.phase == .verifying { codeHint = String(localized: "验证码不正确或已过期，请重新输入。") }
            isSubmittingCode = false
            code = ""
            switchProgress = progress
        default:
            switchProgress = progress
        }
        if progress.kind == .add { onAddProgress?(progress) }
    }

    private func resetCode() {
        code = ""
        codeHint = nil
        isSubmittingCode = false
    }

    // MARK: - 操作

    /// 切换到已保存的账号；该账号没有保存密码时弹出补填密码。
    func switchTo(_ account: AccountRecord) async {
        switch await switcher.switchTo(account.id) {
        case .success:
            break
        case .failure(let error):
            handleImmediateFailure(error, account: account)
        }
    }

    /// 补填 / 更新密码。
    func submitPassword(_ prompt: AccountPasswordPrompt, password: String) async {
        passwordPrompt = nil
        switch prompt.purpose {
        case .switchTo:
            if case .failure(let error) = await switcher.switchTo(prompt.account.id, password: password) {
                handleImmediateFailure(error, account: prompt.account)
            }
        case .update:
            do {
                try await switcher.updatePassword(password, for: prompt.account.id)
            } catch {
                manageError = ErrorPresentation(message: String(localized: "无法保存密码。"),
                                                raw: (error as? AccountSwitchError)?.rawDescription ?? error.localizedDescription)
            }
            reload()
        }
    }

    /// 切换没开始就失败（没有进度事件）的情况。
    private func handleImmediateFailure(_ error: AccountSwitchError, account: AccountRecord) {
        switch error.reason {
        case .passwordMissing:
            passwordPrompt = AccountPasswordPrompt(account: account, purpose: .switchTo)
        case .busy, .accountNotFound, .vault:
            if let presentation = Self.describeFailure(error, target: account) { failure = presentation }
        default:
            break // 已经通过进度事件处理
        }
    }

    func submitCode() {
        guard LoginViewModel.isValidCode(code) else {
            codeHint = String(localized: "请输入 6 位数字验证码。")
            return
        }
        do {
            try switcher.submitTwoFactorCode(code)
            codeHint = nil
            isSubmittingCode = true
        } catch let e as IpatoolError {
            codeHint = e.message
        } catch {
            codeHint = error.localizedDescription
        }
    }

    func cancelSwitch() {
        switcher.cancel()
    }

    func setRegion(_ region: AccountRegion, for account: AccountRecord) async {
        do {
            try await switcher.setRegion(region, for: account.id)
        } catch {
            manageError = ErrorPresentation(message: String(localized: "无法保存账号列表。"), raw: error.localizedDescription)
        }
        reload()
    }

    func remove(_ account: AccountRecord) async -> Bool {
        do {
            try await switcher.remove(account.id)
            reload()
            return true
        } catch {
            manageError = ErrorPresentation(message: String(localized: "移除账号失败。"),
                                            raw: (error as? IpatoolError)?.raw ?? error.localizedDescription)
            reload()
            return false
        }
    }

    // MARK: - 文案

    /// 进度文字（遮罩与登录窗口共用）。
    static func statusText(_ progress: AccountSwitchProgress) -> String {
        let region = progress.target.regionLabel.title
        switch progress.phase {
        case .idle, .savingCookies: return String(localized: "正在保存当前会话")
        case .revoking: return String(localized: "正在退出当前账号")
        case .restoringCookies: return String(localized: "正在恢复 \(region) 账号的会话")
        case .loggingIn:
            // ipatool 每次登录都会打印「the first login may take a few minutes」，切换时不据此提示「首次」
            return String(localized: "正在登录 \(region) 账号")
        case .needsTwoFactor:
            if progress.isRollback, let previous = progress.previous {
                return String(localized: "恢复 \(previous.regionLabel.title) 账号需要验证码")
            }
            return String(localized: "\(region) 账号需要验证码")
        case .verifying: return String(localized: "正在验证…")
        case .rollingBack:
            if let previous = progress.previous {
                return String(localized: "切换失败，正在恢复 \(previous.regionLabel.title) 账号")
            }
            return String(localized: "切换失败，正在恢复")
        case .done: return String(localized: "已切换到 \(region) 账号")
        case .failed: return String(localized: "切换失败")
        }
    }

    /// 失败提示：原因 + 回滚结果。用户取消且已恢复时不提示。
    static func describeFailure(_ error: AccountSwitchError, target: AccountRecord?) -> AccountSwitchFailurePresentation? {
        let name = target.map { "\($0.regionLabel.title)（\($0.email)）" } ?? ""
        var lines: [String] = []
        switch error.reason {
        case .busy: lines.append(String(localized: "另一个账号切换正在进行，请稍后再试。"))
        case .accountNotFound: lines.append(String(localized: "找不到该账号，可能已被移除。"))
        case .passwordMissing: lines.append(String(localized: "该账号没有保存密码。"))
        case .alreadyExists: lines.append(String(localized: "该账号已在列表中。"))
        case .cookieStorage: lines.append(String(localized: "无法读写登录会话文件。"))
        case .vault: lines.append(String(localized: "无法读取钥匙串中保存的密码。"))
        case .revokeFailed(let e): lines.append(String(localized: "无法退出当前账号：\(e.message)"))
        case .loginFailed(let e):
            if e.kind == .cancelled {
                if case .signedOut = error.rollback {} else { return nil }
                lines.append(String(localized: "已取消切换。"))
            } else {
                lines.append(String(localized: "无法登录 \(name)：\(e.message)"))
            }
        }
        switch error.rollback {
        case .notNeeded: break
        case .restored(let previous):
            lines.append(String(localized: "已恢复为原来的 \(previous.regionLabel.title) 账号。"))
        case .signedOut:
            lines.append(String(localized: "未能恢复原来的账号，现在处于未登录状态。请在侧栏账号菜单重新选择账号登录。"))
        }
        var raw = error.rawDescription
        if case .signedOut(let reason) = error.rollback, !reason.isEmpty { raw += "\n" + reason }
        return AccountSwitchFailurePresentation(title: String(localized: "切换账号失败"),
                                                presentation: ErrorPresentation(message: lines.joined(separator: "\n"), raw: raw))
    }
}

/// 「添加账号」用的登录会话：登录窗口照常使用，实际交给切换器（保存并退出当前账号 → 登录新账号 → 写入账号表与钥匙串）。
final class SwitcherLoginSession: LoginSessioning, @unchecked Sendable {
    let switcher: AccountSwitcher
    let region: AccountRegion

    init(switcher: AccountSwitcher, region: AccountRegion) {
        self.switcher = switcher
        self.region = region
    }

    func login(email: String, password: String,
               onEvent: @escaping @Sendable (LoginEvent) -> Void) async -> Result<AccountInfo, IpatoolError> {
        // 内部（含回滚时）的成功 / 失败事件不直接转发，以切换器的最终结果为准
        let result = await switcher.addAccount(email: email, password: password, region: region) { event in
            switch event {
            case .succeeded, .failed: return
            default: onEvent(event)
            }
        }
        switch result {
        case .success(let record):
            let info = record.accountInfo
            onEvent(.succeeded(info))
            return .success(info)
        case .failure(let error):
            let failure = error.ipatoolError ?? IpatoolError(kind: .unknown, raw: error.rawDescription)
            onEvent(.failed(failure))
            return .failure(failure)
        }
    }

    func submitTwoFactorCode(_ code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LoginViewModel.isValidCode(trimmed) else {
            throw IpatoolError(kind: .invalidAuthCodeFormat, raw: "2FA code must contain exactly six digits")
        }
        try switcher.submitTwoFactorCode(trimmed)
    }

    func cancel() {
        switcher.cancel()
    }
}
