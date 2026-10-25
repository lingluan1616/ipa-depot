import Foundation

/// 定位 ipatool 可执行文件。
///
/// 候选顺序：
/// 1. `overridePath`（调用方显式指定，测试用）；
/// 2. 环境变量 `IPADEPOT_IPATOOL_PATH`（**仅 Debug 构建生效**，开发期界面冒烟用，设置且可执行才会被选中）；
/// 3. App 包内 `Contents/Resources/bin/ipatool`（正式运行只会走到这里）；
/// 4. 开发期兜底 `/opt/homebrew/bin/ipatool` → `/usr/local/bin/ipatool`（**仅 Debug 构建**的默认值）。
public struct IpatoolLocator: Sendable {
    public static let bundledRelativePath = "bin/ipatool"
    public static let environmentOverrideKey = "IPADEPOT_IPATOOL_PATH"

    /// 开发期兜底路径。Release 构建为空：正式运行只使用内置二进制。
    public static var developmentFallbacks: [String] {
        #if DEBUG
        return ["/opt/homebrew/bin/ipatool", "/usr/local/bin/ipatool"]
        #else
        return []
        #endif
    }

    /// 是否读取 `IPADEPOT_IPATOOL_PATH`（仅 Debug 构建）。
    public static var allowsEnvironmentOverride: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    public let bundleResourceURL: URL?
    public let overridePath: String?
    public let environmentOverridePath: String?
    public let fallbackPaths: [String]

    public init(bundle: Bundle = .main,
                overridePath: String? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                fallbackPaths: [String] = IpatoolLocator.developmentFallbacks) {
        self.bundleResourceURL = bundle.resourceURL
        self.overridePath = overridePath
        if Self.allowsEnvironmentOverride, let value = environment[Self.environmentOverrideKey], !value.isEmpty {
            self.environmentOverridePath = value
        } else {
            self.environmentOverridePath = nil
        }
        self.fallbackPaths = fallbackPaths
    }

    /// 按顺序列出候选路径（不可执行的会在 `locate()` 时跳过）。
    public var candidates: [URL] {
        var list: [URL] = []
        if let overridePath { list.append(URL(fileURLWithPath: overridePath)) }
        if let environmentOverridePath { list.append(URL(fileURLWithPath: environmentOverridePath)) }
        if let bundleResourceURL { list.append(bundleResourceURL.appendingPathComponent(Self.bundledRelativePath)) }
        list += fallbackPaths.map { URL(fileURLWithPath: $0) }
        return list
    }

    public func locate() throws -> URL {
        let fm = FileManager.default
        if let url = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) {
            return url.resolvingSymlinksInPath()
        }
        throw IpatoolError(kind: .binaryNotFound, raw: candidates.map(\.path).joined(separator: ", "))
    }

    /// 运行 `ipatool --version`，返回版本号（如 "2.7.0"）。
    public func detectVersion(paths: AppPaths = .default) async throws -> String {
        let url = try locate()
        let process = IpatoolProcess(executableURL: url, arguments: ["--version"],
                                     environment: try IpatoolEnvironment.make(paths: paths))
        let result = try await process.run()
        let text = result.textLines.joined(separator: "\n")
        guard result.exitCode == 0, let version = Self.parseVersion(text) else {
            throw IpatoolError(kind: .invalidOutput, raw: text, exitCode: result.exitCode)
        }
        return version
    }

    /// 解析 `ipatool version 2.7.0` 之类的输出。
    public static func parseVersion(_ output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+\.\d+(?:[-+.][0-9A-Za-z.\-]+)?"#, options: .regularExpression) else {
            return nil
        }
        return String(output[range])
    }
}
