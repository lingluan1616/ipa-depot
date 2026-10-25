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
public struct VersionCache: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func fileURL(appID: Int64) -> URL {
        directory.appendingPathComponent("\(appID).json")
    }

    public func load(appID: Int64) -> CachedVersions? {
        guard let data = try? Data(contentsOf: fileURL(appID: appID)) else { return nil }
        return try? Self.decoder.decode(CachedVersions.self, from: data)
    }

    public func save(_ entry: CachedVersions) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(entry)
        try data.write(to: fileURL(appID: entry.appID), options: .atomic)
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
