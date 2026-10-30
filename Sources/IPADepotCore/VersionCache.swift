import Foundation

/// 某个 App 的版本缓存（`cache/versions/<appID>.json`）。
public struct CachedVersions: Sendable, Codable, Equatable {
    public var appID: Int64
    public var bundleID: String?
    /// `list-versions` 返回的外部版本 ID（保持 ipatool 原顺序）。
    public var versionIDs: [String]
    /// 已取到的元数据，键为外部版本 ID。
    public var metadata: [String: VersionMetadata]
    public var updatedAt: Date

    public init(appID: Int64, bundleID: String? = nil, versionIDs: [String] = [],
                metadata: [String: VersionMetadata] = [:], updatedAt: Date = Date()) {
        self.appID = appID
        self.bundleID = bundleID
        self.versionIDs = versionIDs
        self.metadata = metadata
        self.updatedAt = updatedAt
    }
}

/// 版本缓存读写。写入采用原子替换。
/// 多账号：缓存键 = App ID + 账号 id，文件为 `cache/versions/<账号 id>/<appID>.json`（不同地区的账号版本列表可能不同）；
/// 没有账号 id 时沿用旧路径 `cache/versions/<appID>.json`。
public struct VersionCache: Sendable {
    public let directory: URL
    public let accountID: UUID?

    public init(directory: URL, accountID: UUID? = nil) {
        self.directory = directory
        self.accountID = accountID
    }

    /// 同一目录、指定账号的缓存。
    public func scoped(to accountID: UUID?) -> VersionCache {
        VersionCache(directory: directory, accountID: accountID)
    }

    public func fileURL(appID: Int64) -> URL {
        guard let accountID else { return directory.appendingPathComponent("\(appID).json") }
        return directory.appendingPathComponent(accountID.uuidString, isDirectory: true)
            .appendingPathComponent("\(appID).json")
    }

    public func load(appID: Int64) -> CachedVersions? {
        guard let data = try? Data(contentsOf: fileURL(appID: appID)) else { return nil }
        return try? Self.decoder.decode(CachedVersions.self, from: data)
    }

    public func save(_ entry: CachedVersions) throws {
        let url = fileURL(appID: entry.appID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(entry)
        try data.write(to: url, options: .atomic)
    }

    public func remove(appID: Int64) {
        try? FileManager.default.removeItem(at: fileURL(appID: appID))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
