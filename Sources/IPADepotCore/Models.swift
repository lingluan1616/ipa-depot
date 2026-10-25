import Foundation

/// 搜索结果中的一个 App（对应 ipatool `search` 的 apps[] 元素）。
public struct AppSummary: Sendable, Codable, Hashable, Identifiable {
    public let id: Int64
    public let bundleID: String
    public let name: String
    public let version: String
    public let price: Double
    public let platforms: [String]

    public init(id: Int64, bundleID: String, name: String, version: String, price: Double, platforms: [String]) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.price = price
        self.platforms = platforms
    }

    enum CodingKeys: String, CodingKey { case id, bundleID, name, version, price, platforms }

    /// 容错解码：缺字段给默认值，避免 ipatool 字段微调导致整体失败。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        bundleID = (try? c.decode(String.self, forKey: .bundleID)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        version = (try? c.decode(String.self, forKey: .version)) ?? ""
        price = (try? c.decode(Double.self, forKey: .price)) ?? 0
        platforms = (try? c.decode([String].self, forKey: .platforms)) ?? []
    }

    public var isFree: Bool { price == 0 }
}

/// 当前登录账号（`auth info` / `auth login` 成功时输出）。
public struct AccountInfo: Sendable, Codable, Hashable {
    public let name: String
    public let email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

/// 一个历史版本的元数据（`get-version-metadata`）。
public struct VersionMetadata: Sendable, Codable, Hashable, Identifiable {
    public let externalVersionID: String
    public let displayVersion: String
    public let releaseDate: Date?

    public var id: String { externalVersionID }

    public init(externalVersionID: String, displayVersion: String, releaseDate: Date?) {
        self.externalVersionID = externalVersionID
        self.displayVersion = displayVersion
        self.releaseDate = releaseDate
    }
}
