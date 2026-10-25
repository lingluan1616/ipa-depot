import Foundation

/// IPA Depot 自己的数据目录布局。
/// 默认根目录：`~/Library/Application Support/IPA Depot`。
public struct AppPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 默认路径（`~/Library/Application Support/IPA Depot`）。
    public static var `default`: AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return AppPaths(root: base.appendingPathComponent("IPA Depot", isDirectory: true))
    }

    /// 传给 ipatool 的 `XDG_STATE_HOME`。注意：若 `~/.ipatool` 已存在，ipatool 会优先沿用旧目录。
    public var stateDirectory: URL { root.appendingPathComponent("state", isDirectory: true) }
    public var cacheDirectory: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public var versionsCacheDirectory: URL { cacheDirectory.appendingPathComponent("versions", isDirectory: true) }

    @discardableResult
    public func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
