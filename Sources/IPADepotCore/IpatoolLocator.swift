import Foundation

/// 定位 ipatool 可执行文件：优先 App 包内 `Contents/Resources/bin/ipatool`，其次开发期兜底 `/opt/homebrew/bin/ipatool`。
public struct IpatoolLocator: Sendable {
    public static let bundledRelativePath = "bin/ipatool"
    public static let developmentFallbacks = ["/opt/homebrew/bin/ipatool"]

    public let bundleResourceURL: URL?
    public let overridePath: String?
    public let fallbackPaths: [String]

    public init(bundle: Bundle = .main,
                overridePath: String? = nil,
                fallbackPaths: [String] = IpatoolLocator.developmentFallbacks) {
        self.bundleResourceURL = bundle.resourceURL
        self.overridePath = overridePath
        self.fallbackPaths = fallbackPaths
    }

    /// 按顺序列出候选路径。
    public var candidates: [URL] {
        var list: [URL] = []
        if let overridePath { list.append(URL(fileURLWithPath: overridePath)) }
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
