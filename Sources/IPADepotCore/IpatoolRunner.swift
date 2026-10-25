import Foundation

/// 构造 ipatool 子进程环境变量：在当前环境基础上设置 `XDG_STATE_HOME`，不覆盖 `HOME`。
public enum IpatoolEnvironment {
    public static func make(base: [String: String] = ProcessInfo.processInfo.environment,
                            paths: AppPaths) throws -> [String: String] {
        var env = base
        try paths.ensureDirectory(paths.stateDirectory)
        env["XDG_STATE_HOME"] = paths.stateDirectory.path
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        return env
    }
}

/// ipatool 调用入口：持有可执行文件路径与数据目录，负责拼参数、跑进程、把失败映射成 `IpatoolError`。
public struct IpatoolRunner: Sendable {
    public let executableURL: URL
    public let paths: AppPaths
    public let baseEnvironment: [String: String]

    public init(executableURL: URL,
                paths: AppPaths = .default,
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executableURL = executableURL
        self.paths = paths
        self.baseEnvironment = baseEnvironment
    }

    /// 拼出完整参数：追加 `--format json`，非交互时追加 `--non-interactive`。
    public static func arguments(_ args: [String], interactive: Bool) -> [String] {
        var full = args
        if !full.contains("--format") { full += ["--format", "json"] }
        if !interactive && !full.contains("--non-interactive") { full.append("--non-interactive") }
        return full
    }

    public func makeProcess(_ args: [String], interactive: Bool = false,
                            terminal: PseudoTerminal? = nil,
                            currentDirectoryURL: URL? = nil) throws -> IpatoolProcess {
        IpatoolProcess(executableURL: executableURL,
                       arguments: Self.arguments(args, interactive: interactive),
                       environment: try IpatoolEnvironment.make(base: baseEnvironment, paths: paths),
                       currentDirectoryURL: currentDirectoryURL ?? paths.root,
                       terminal: terminal)
    }

    /// 运行并检查结果：取消 → `.cancelled`；有错误事件或退出码非 0 → 映射后的错误。
    public func run(_ args: [String], interactive: Bool = false,
                    onLine: (@Sendable (IpatoolLine) -> Void)? = nil) async throws -> IpatoolProcess.Result {
        let process = try makeProcess(args, interactive: interactive)
        let result = try await process.run(onLine: onLine)
        try Self.check(result)
        return result
    }

    /// 把一次运行结果转换为错误（若失败）。
    public static func check(_ result: IpatoolProcess.Result) throws {
        if result.wasCancelled {
            throw IpatoolError(kind: .cancelled, exitCode: result.exitCode)
        }
        if let event = result.errorEvent {
            throw IpatoolErrorMapper.map(event.error ?? event.message ?? "unknown error", exitCode: result.exitCode)
        }
        if result.exitCode != 0 {
            let raw = result.textLines.last ?? "ipatool exited with code \(result.exitCode)"
            throw IpatoolErrorMapper.map(raw, exitCode: result.exitCode)
        }
    }
}
