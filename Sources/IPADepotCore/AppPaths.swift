import Foundation

/// IPA Depot 自己的数据目录布局。
/// 默认根目录：`~/Library/Application Support/IPA Depot`。
public struct AppPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Debug 构建下可用环境变量 `IPADEPOT_DATA_ROOT` 把数据根目录指到别处（开发期界面冒烟用，避免写真实数据目录）。
    public static let dataRootOverrideKey = "IPADEPOT_DATA_ROOT"

    /// 默认路径（`~/Library/Application Support/IPA Depot`）。
    public static var `default`: AppPaths {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment[dataRootOverrideKey], !override.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return AppPaths(root: base.appendingPathComponent("IPA Depot", isDirectory: true))
    }

    /// 传给 ipatool 的 `XDG_STATE_HOME`。注意：若 `~/.ipatool` 已存在，ipatool 会优先沿用旧目录。
    public var stateDirectory: URL { root.appendingPathComponent("state", isDirectory: true) }
    /// 本 App 自己的缓存根目录（清理缓存只动这里，不碰 `~/Library/Caches/ipatool`）。
    public var cacheDirectory: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public var versionsCacheDirectory: URL { cacheDirectory.appendingPathComponent("versions", isDirectory: true) }
    public var artworkCacheDirectory: URL { cacheDirectory.appendingPathComponent("artwork", isDirectory: true) }
    /// 下载记录。
    public var historyFile: URL { root.appendingPathComponent("history.json") }
    /// 跨启动保存的下载队列（排队中与已暂停的任务）。
    public var queueFile: URL { root.appendingPathComponent("queue.json") }
    /// 多账号列表（不含密码；密码在钥匙串 `app.ipadepot.mac.accounts`）。
    public var accountsFile: URL { root.appendingPathComponent("accounts.json") }
    /// 每个账号独立保存的 ipatool Cookie：`accounts/<账号 id>/cookies`。
    public var accountsDirectory: URL { root.appendingPathComponent("accounts", isDirectory: true) }

    @discardableResult
    public func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// 目录占用统计与清理（只用于本 App 自己的目录）。
public enum DirectoryUsage {
    /// 递归统计目录内常规文件的字节数；目录不存在时为 0。
    public static func size(of directory: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                             options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// 删除目录下的全部内容（保留目录本身）。
    public static func removeContents(of directory: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try fm.removeItem(at: item)
        }
    }
}
