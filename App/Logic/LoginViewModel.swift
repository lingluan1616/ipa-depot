import Foundation
import Observation
import IPADepotCore

/// 登录流程状态机：准备页 → 账号密码 → （可选）6 位验证码 → 成功 / 失败。
@MainActor
@Observable
final class LoginViewModel {
    enum Step: Equatable {
        case intro
        case credentials
        case twoFactor
    }

    var step: Step = .intro
    var appleID = ""
    /// 只绑定 SecureField，提交后立即清空；不写日志、不持久化。
    var password = ""
    var code = ""

    private(set) var isWorking = false
    private(set) var statusText: String?
    private(set) var error: ErrorPresentation?
    /// 验证码页的提示（如「验证码不正确」）。
    private(set) var codeHint: String?
    private(set) var account: AccountInfo?

    @ObservationIgnored var onSuccess: ((AccountInfo) -> Void)?
    @ObservationIgnored private let makeSession: @Sendable () -> LoginSessioning
    @ObservationIgnored private var session: LoginSessioning?
    @ObservationIgnored private var userCancelled = false
    @ObservationIgnored private var awaitingVerification = false

    init(makeSession: @escaping @Sendable () -> LoginSessioning) {
        self.makeSession = makeSession
    }

    var canSubmitCredentials: Bool {
        !isWorking && !appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    /// 本地校验：恰好 6 位 ASCII 数字。
    var isCodeValid: Bool { Self.isValidCode(code) }

    static func isValidCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 6 && trimmed.allSatisfy { $0.isASCII && $0.isNumber }
    }

    func continueFromIntro() {
        step = .credentials
    }

    /// 提交 Apple ID 与密码，直到登录结束（成功 / 失败 / 取消）才返回；期间可能切到验证码页。
    func submitCredentials() async {
        guard canSubmitCredentials else { return }
        error = nil
        codeHint = nil
        userCancelled = false
        awaitingVerification = false
        isWorking = true
        statusText = String(localized: "正在连接 Apple…")

        let email = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        password = ""
        let session = makeSession()
        self.session = session

        let (events, continuation) = AsyncStream<LoginEvent>.makeStream()
        Task.detached {
            _ = await session.login(email: email, password: secret) { continuation.yield($0) }
            continuation.finish()
        }
        for await event in events {
            handle(event)
        }
        self.session = nil
        isWorking = false
    }

    /// 回填验证码（本地先校验 6 位数字）。
    func submitCode() {
        guard isCodeValid, let session else {
            codeHint = String(localized: "请输入 6 位数字验证码。")
            return
        }
        do {
            try session.submitTwoFactorCode(code)
            codeHint = nil
        } catch let e as IpatoolError {
            codeHint = e.message
        } catch {
            codeHint = error.localizedDescription
        }
    }

    /// 关闭登录窗口时调用：终止进行中的 ipatool。
    func cancel() {
        userCancelled = true
        session?.cancel()
    }

    func handle(_ event: LoginEvent) {
        switch event {
        case .preparing:
            statusText = String(localized: "正在准备认证组件…首次登录可能需要几分钟。")
        case .log(let message):
            statusText = Self.describe(log: message)
        case .needsTwoFactor:
            if awaitingVerification {
                codeHint = String(localized: "验证码不正确或已过期，请重新输入。")
            }
            awaitingVerification = false
            code = ""
            step = .twoFactor
            isWorking = false
            statusText = nil
        case .verifyingTwoFactor:
            awaitingVerification = true
            isWorking = true
            statusText = String(localized: "正在验证…")
        case .succeeded(let info):
            account = info
            isWorking = false
            statusText = nil
            onSuccess?(info)
        case .failed(let failure):
            isWorking = false
            statusText = nil
            if !(userCancelled && failure.kind == .cancelled) {
                error = ErrorPresentation(failure)
            }
            if step == .twoFactor { step = .credentials }
        }
    }

    /// 把 ipatool 的英文日志转成界面可读的进度文字；不认识的原样显示。
    static func describe(log message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("download") && (lower.contains("unicorn") || lower.contains("component") || lower.contains("python")) {
            return String(localized: "正在下载认证组件…")
        }
        if lower.contains("kbsync") || lower.contains("preparing") {
            return String(localized: "正在准备认证组件…首次登录可能需要几分钟。")
        }
        if lower.contains("authenticat") || lower.contains("signing in") {
            return String(localized: "正在登录…")
        }
        return message
    }
}
