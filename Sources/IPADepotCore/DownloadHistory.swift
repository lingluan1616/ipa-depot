import Foundation

/// 一条下载记录（持久化在 `history.json`）。
public struct DownloadRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var appID: Int64
    public var name: String
    public var bundleID: String
    public var version: String
    public var externalVersionID: String?
    public var size: Int64
    public var path: String
    public var completedAt: Date

    public init(id: UUID = UUID(), appID: Int64, name: String, bundleID: String, version: String,
                externalVersionID: String?, size: Int64, path: String, completedAt: Date = Date()) {
        self.id = id
        self.appID = appID
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.externalVersionID = externalVersionID
        self.size = size
        self.path = path
        self.completedAt = completedAt
    }

    public var fileURL: URL { URL(fileURLWithPath: path) }
}

/// `history.json` 读写（原子写；文件损坏时视为空记录，不覆盖原文件直到下一次保存）。
public struct HistoryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decoder.decode([DownloadRecord].self, from: data)) ?? []
    }

    public func save(_ records: [DownloadRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(records).write(to: fileURL, options: .atomic)
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
