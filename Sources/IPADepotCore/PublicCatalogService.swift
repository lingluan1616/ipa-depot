import Foundation

/// 用 Apple 公开的 iTunes Search API 按地区搜索 App（不走 ipatool、不需要登录）：
/// `https://itunes.apple.com/search?term=<q>&country=<cc>&entity=<software|iPadSoftware|macSoftware>&limit=<n>`。
/// 结果映射为 `AppSummary`（`catalogCountry` 为所搜国家代码，另带图标地址与开发者名）。
/// 20 秒超时（本机实测单次 6–12 秒）；网络 / HTTP / 解析错误一律映射为网络错误（`.networkUnreachable`，原始描述放在 `raw`）。
/// 限速：同一组参数（关键词 + 地区 + 平台 + 数量）1 秒内不重复请求，直接复用上一次（或进行中）的结果。
public actor PublicCatalogService {
    public static let timeout: TimeInterval = 20
    public static let minimumInterval: TimeInterval = 1

    private let http: HTTPFetching
    private let now: @Sendable () -> Date
    private var recent: [String: (date: Date, task: Task<[AppSummary], Error>)] = [:]

    public init(http: HTTPFetching = URLSessionHTTPClient(timeout: PublicCatalogService.timeout),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.now = now
    }

    /// ipatool 平台取值（iphone / ipad / macos）→ Search API 的 entity。
    public static func entity(forPlatform platform: String) -> String {
        switch platform.lowercased() {
        case "ipad", "ipados": return "iPadSoftware"
        case "macos", "mac", "osx": return "macSoftware"
        default: return "software"
        }
    }

    public static func searchURL(term: String, country: String, platform: String, limit: Int) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: country.lowercased()),
            URLQueryItem(name: "entity", value: entity(forPlatform: platform)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        return components.url!
    }

    public func search(_ term: String, country: String, limit: Int, platform: String) async throws -> [AppSummary] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code = RegionCatalog.normalizeCode(country) else {
            throw IpatoolError(kind: .networkUnreachable, raw: "invalid country code: \(country)")
        }
        let key = "\(trimmed.lowercased())|\(code)|\(platform)|\(limit)"
        let current = now()
        if let hit = recent[key], current.timeIntervalSince(hit.date) < Self.minimumInterval {
            return try await hit.task.value
        }
        let http = self.http
        let url = Self.searchURL(term: trimmed, country: code, platform: platform, limit: limit)
        let task = Task<[AppSummary], Error> {
            let data: Data
            let status: Int
            do {
                (data, status) = try await http.get(url, headers: [:])
            } catch is CancellationError {
                throw IpatoolError(kind: .cancelled, raw: "cancelled")
            } catch let error as URLError where error.code == .cancelled {
                throw IpatoolError(kind: .cancelled, raw: error.localizedDescription)
            } catch {
                throw IpatoolError(kind: .networkUnreachable, raw: error.localizedDescription)
            }
            guard status == 200 else {
                throw IpatoolError(kind: .networkUnreachable, raw: "iTunes Search API HTTP \(status)")
            }
            return try Self.parse(data, country: code)
        }
        recent[key] = (current, task)
        recent = recent.filter { current.timeIntervalSince($0.value.date) < Self.minimumInterval }
        return try await task.value
    }

    /// 解析 Search API 响应。缺字段给默认值；没有 trackId 的条目跳过；不是合法 JSON 视为网络错误。
    public static func parse(_ data: Data, country: String) throws -> [AppSummary] {
        struct Response: Decodable {
            struct Item: Decodable {
                let trackId: Int64?
                let bundleId: String?
                let trackName: String?
                let version: String?
                let price: Double?
                let artworkUrl100: String?
                let artworkUrl512: String?
                let sellerName: String?
                let artistName: String?
                let supportedDevices: [String]?
                let kind: String?
            }
            let results: [Item]?
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw IpatoolError(kind: .networkUnreachable, raw: "invalid iTunes Search API response: \(error.localizedDescription)")
        }
        let code = country.lowercased()
        return (response.results ?? []).compactMap { item in
            guard let id = item.trackId else { return nil }
            let seller = [item.sellerName, item.artistName].compactMap { $0 }.first { !$0.isEmpty }
            return AppSummary(id: id, bundleID: item.bundleId ?? "", name: item.trackName ?? "",
                              version: item.version ?? "", price: item.price ?? 0,
                              platforms: platforms(supportedDevices: item.supportedDevices, kind: item.kind),
                              artworkURL: (item.artworkUrl100 ?? item.artworkUrl512).flatMap(URL.init(string:)),
                              sellerName: seller, catalogCountry: code)
        }
    }

    /// supportedDevices（如 `iPhone15-iPhone15`、`iPadAir-iPadAir`、`MacDesktop-MacDesktop`）→ 平台（iphone / ipad / macos）。
    /// 只有 `kind == "mac-software"` 视为 Mac：iOS App 的 `MacDesktop` 只表示「可在 Apple 芯片 Mac 上运行」，不是 Mac 版。
    /// 都没有时返回空数组。
    public static func platforms(supportedDevices: [String]?, kind: String?) -> [String] {
        var result: [String] = []
        let devices = (supportedDevices ?? []).map { $0.lowercased() }
        if devices.contains(where: { $0.hasPrefix("iphone") || $0.hasPrefix("ipod") }) { result.append("iphone") }
        if devices.contains(where: { $0.hasPrefix("ipad") }) { result.append("ipad") }
        if kind?.lowercased() == "mac-software" { result.append("macos") }
        return result
    }
}
