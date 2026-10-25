import Foundation

/// ipatool 交互登录的提示类型（提示文本来自 ipatool v2.7.0 cmd/auth.go，写在 stderr，不带换行）。
public enum LoginPrompt: String, Sendable, Equatable {
    case appleID = "enter apple id"
    case password = "enter password:"
    case twoFactorCode = "enter 2fa code:"
}

/// 从终端原始输出里识别登录提示。提示不以换行结尾，所以按累积文本匹配，匹配后丢弃已消费部分。
public struct LoginPromptDetector: Sendable {
    private var buffer = ""

    public init() {}

    public mutating func feed(_ chunk: String) -> [LoginPrompt] {
        buffer += LineBuffer.stripANSI(chunk).lowercased()
        var found: [LoginPrompt] = []
        while true {
            var earliest: (LoginPrompt, Range<String.Index>)?
            for prompt in [LoginPrompt.appleID, .password, .twoFactorCode] {
                if let r = buffer.range(of: prompt.rawValue), earliest == nil || r.lowerBound < earliest!.1.lowerBound {
                    earliest = (prompt, r)
                }
            }
            guard let (prompt, range) = earliest else { break }
            found.append(prompt)
            buffer = String(buffer[range.upperBound...])
        }
        if buffer.count > 512 { buffer = String(buffer.suffix(64)) }
        return found
    }
}

public enum LoginEvent: Sendable, Equatable {
    /// ipatool 开始准备认证（首次可能要下载组件，耗时数分钟）。
    case preparing
    /// 需要 2FA 验证码：界面弹框后调用 `submitTwoFactorCode(_:)`。
    case needsTwoFactor
    case verifyingTwoFactor
    case log(String)
    case succeeded(AccountInfo)
    case failed(IpatoolError)
}

public enum LoginState: Sendable, Equatable {
    case idle
    case running
    case awaitingTwoFactor
    case verifyingTwoFactor
    case succeeded(AccountInfo)
    case failed(IpatoolError)
}

/// 伪终端方式运行 `ipatool auth login --format json`（不带 `--non-interactive`）。
/// 邮箱、密码、验证码都在检测到对应提示后写入伪终端，**绝不出现在命令行参数里**。
public final class LoginSession: @unchecked Sendable {
    public let runner: IpatoolRunner

    private let lock = NSLock()
    private var terminal: PseudoTerminal?
    private var process: IpatoolProcess?
    private var email: String?
    private var password: String?
    private var _state: LoginState = .idle
    private var onEvent: (@Sendable (LoginEvent) -> Void)?

    public init(runner: IpatoolRunner) { self.runner = runner }

    public var state: LoginState { lock.lock(); defer { lock.unlock() }; return _state }

    public static let arguments = ["auth", "login"]

    /// 登录，直到成功、失败或取消。2FA 时会发出 `.needsTwoFactor` 并等待 `submitTwoFactorCode`。
    public func login(email: String, password: String,
                      onEvent: @escaping @Sendable (LoginEvent) -> Void) async -> Result<AccountInfo, IpatoolError> {
        let busy: Bool = lock.withLock {
            if _state == .running || _state == .awaitingTwoFactor || _state == .verifyingTwoFactor { return true }
            self.email = email
            self.password = password
            self.onEvent = onEvent
            _state = .running
            return false
        }
        if busy { return .failure(IpatoolError(kind: .unknown, raw: "login already in progress")) }

        let outcome = await run()
        lock.withLock {
            self.email = nil
            self.password = nil
            terminal = nil
            process = nil
            switch outcome {
            case .success(let account): _state = .succeeded(account)
            case .failure(let error): _state = .failed(error)
            }
            self.onEvent = nil
        }
        switch outcome {
        case .success(let account): onEvent(.succeeded(account))
        case .failure(let error): onEvent(.failed(error))
        }
        return outcome
    }

    /// 回填 2FA 验证码（6 位数字）。
    public func submitTwoFactorCode(_ code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw IpatoolError(kind: .invalidAuthCodeFormat, raw: "2FA code must contain exactly six digits")
        }
        lock.lock()
        guard _state == .awaitingTwoFactor, let terminal else {
            lock.unlock()
            throw IpatoolError(kind: .unknown, raw: "not waiting for a 2FA code")
        }
        _state = .verifyingTwoFactor
        let handler = onEvent
        lock.unlock()
        try terminal.write(trimmed + "\n")
        handler?(.verifyingTwoFactor)
    }

    public func cancel() {
        lock.lock()
        let p = process
        lock.unlock()
        p?.cancel()
    }

    // MARK: - 内部

    private func run() async -> Result<AccountInfo, IpatoolError> {
        let pty: PseudoTerminal
        let proc: IpatoolProcess
        do {
            pty = try PseudoTerminal()
            proc = try runner.makeProcess(Self.arguments, interactive: true, terminal: pty)
        } catch let e as IpatoolError {
            return .failure(e)
        } catch {
            return .failure(IpatoolError(kind: .unknown, raw: error.localizedDescription))
        }
        lock.withLock {
            terminal = pty
            process = proc
        }

        let detector = DetectorBox()
        let result: IpatoolProcess.Result
        do {
            result = try await proc.run(onLine: { [weak self] line in
                guard let self else { return }
                switch line {
                case .json(let event):
                    if let message = event.message {
                        if message.contains("preparing authentication") { self.emit(.preparing) }
                        else { self.emit(.log(message)) }
                    }
                case .text(let text):
                    // 提示文本不在这里处理（见 onTerminalOutput），其余文本作为日志
                    if LoginPromptDetector.containsPrompt(text) == false { self.emit(.log(text)) }
                }
            }, onTerminalOutput: { [weak self] chunk in
                guard let self else { return }
                for prompt in detector.feed(chunk) { self.handle(prompt) }
            })
        } catch let e as IpatoolError {
            return .failure(e)
        } catch {
            return .failure(IpatoolError(kind: .unknown, raw: error.localizedDescription))
        }

        do {
            try IpatoolRunner.check(result)
        } catch let e as IpatoolError {
            return .failure(e)
        } catch {
            return .failure(IpatoolError(kind: .unknown, raw: error.localizedDescription))
        }
        if let event = result.events.last(where: { $0.success == true }) {
            return .success(AccountInfo(name: event["name"]?.stringValue ?? "",
                                        email: event["email"]?.stringValue ?? ""))
        }
        let raw = result.events.last?.message ?? result.textLines.last ?? "login finished without result"
        return .failure(IpatoolErrorMapper.map(raw, exitCode: result.exitCode))
    }

    private func emit(_ event: LoginEvent) {
        lock.lock(); let handler = onEvent; lock.unlock()
        handler?(event)
    }

    private func handle(_ prompt: LoginPrompt) {
        lock.lock()
        let terminal = self.terminal
        var toWrite: String?
        var event: LoginEvent?
        var failure = false
        switch prompt {
        case .appleID:
            if let email { toWrite = email + "\n" } else { failure = true }
        case .password:
            if let password {
                toWrite = password + "\r"
                self.password = nil // 只写一次；再次出现密码提示视为异常
            } else {
                failure = true
            }
        case .twoFactorCode:
            _state = .awaitingTwoFactor
            event = .needsTwoFactor
        }
        let proc = process
        lock.unlock()

        if failure { proc?.cancel(); return }
        if let toWrite {
            do { try terminal?.write(toWrite) } catch { proc?.cancel() }
        }
        if let event { emit(event) }
    }

    private final class DetectorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var detector = LoginPromptDetector()
        func feed(_ chunk: String) -> [LoginPrompt] {
            lock.lock(); defer { lock.unlock() }
            return detector.feed(chunk)
        }
    }
}

extension LoginPromptDetector {
    /// 一行文本里是否含有登录提示（用于过滤日志）。
    public static func containsPrompt(_ text: String) -> Bool {
        let lower = text.lowercased()
        return [LoginPrompt.appleID, .password, .twoFactorCode].contains { lower.contains($0.rawValue) }
    }
}
