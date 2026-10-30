import Foundation

/// 搜索结果中的一个 App（对应 ipatool `search` 的 apps[] 元素）。
public struct AppSummary: Sendable, Codable, Hashable, Identifiable {
    public let id: Int64
    public let bundleID: String
    public let name: String
    public let version: String
    public let price: Double
    public let platforms: [String]
    /// 图标地址（公开目录结果直接带；ipatool 结果为 nil，界面另走 lookup）。
    public let artworkURL: URL?
    /// 开发者（公开目录的 sellerName；ipatool 结果为 nil）。
    public let sellerName: String?
    /// 来自 Apple 公开目录（iTunes Search API）时为所搜索的国家代码；ipatool 结果为 nil。
    public let catalogCountry: String?

    public init(id: Int64, bundleID: String, name: String, version: String, price: Double, platforms: [String],
                artworkURL: URL? = nil, sellerName: String? = nil, catalogCountry: String? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.price = price
        self.platforms = platforms
        self.artworkURL = artworkURL
        self.sellerName = sellerName
        self.catalogCountry = catalogCountry
    }

    enum CodingKeys: String, CodingKey { case id, bundleID, name, version, price, platforms, artworkURL, sellerName, catalogCountry }

    /// 容错解码：缺字段给默认值，避免 ipatool 字段微调导致整体失败。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        bundleID = (try? c.decode(String.self, forKey: .bundleID)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        version = (try? c.decode(String.self, forKey: .version)) ?? ""
        price = (try? c.decode(Double.self, forKey: .price)) ?? 0
        platforms = (try? c.decode([String].self, forKey: .platforms)) ?? []
        artworkURL = try? c.decodeIfPresent(URL.self, forKey: .artworkURL)
        sellerName = try? c.decodeIfPresent(String.self, forKey: .sellerName)
        catalogCountry = try? c.decodeIfPresent(String.self, forKey: .catalogCountry)
    }

    public var isFree: Bool { price == 0 }

    /// 是否来自 Apple 公开目录（而非当前账号的 ipatool 搜索）。
    public var isPublicCatalog: Bool { catalogCountry != nil }
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
