import Foundation

/// iTunes Lookup 公共接口返回的补充信息（图标、开发者）。
public struct AppLookupInfo: Sendable, Codable, Equatable {
    public let appID: Int64
    public let artworkURL: URL?
    public let artistName: String?
    /// 命中的商店地区（cn / us / jp）。
    public let country: String

    public init(appID: Int64, artworkURL: URL?, artistName: String?, country: String) {
        self.appID = appID
        self.artworkURL = artworkURL
        self.artistName = artistName
        self.country = country
    }
}

/// 通过 `https://itunes.apple.com/lookup?id=<id>&country=<cc>` 取图标与开发者名，按 cn → us → jp 顺序尝试，有结果即停。
/// 结果与图标缓存在 `cache/artwork/`（`<id>.json` + `<id>.img`）；失败返回 nil（界面显示占位符），同一次运行内不重复请求失败项。
public actor AppLookupService {
    public static let countries = ["cn", "us", "jp"]

    public let directory: URL
    private let http: HTTPFetching
    private var infoCache: [Int64: AppLookupInfo] = [:]
    private var failed: Set<Int64> = []
    private var inflightInfo: [Int64: Task<AppLookupInfo?, Never>] = [:]
    private var inflightImage: [Int64: Task<URL?, Never>] = [:]

    public init(directory: URL, http: HTTPFetching = URLSessionHTTPClient()) {
        self.directory = directory
        self.http = http
    }

    public static func lookupURL(appID: Int64, country: String) -> URL {
        URL(string: "https://itunes.apple.com/lookup?id=\(appID)&country=\(country)")!
    }

    public func infoFileURL(appID: Int64) -> URL { directory.appendingPathComponent("\(appID).json") }
    public func imageFileURL(appID: Int64) -> URL { directory.appendingPathComponent("\(appID).img") }

    /// 查询补充信息（先读内存、再读磁盘、最后联网）。
    public func info(appID: Int64) async -> AppLookupInfo? {
        if let hit = infoCache[appID] { return hit }
        if failed.contains(appID) { return nil }
        if let data = try? Data(contentsOf: infoFileURL(appID: appID)),
           let cached = try? JSONDecoder().decode(AppLookupInfo.self, from: data) {
            infoCache[appID] = cached
            return cached
        }
        if let task = inflightInfo[appID] { return await task.value }
        let http = self.http
        let task = Task<AppLookupInfo?, Never> { await Self.fetchInfo(appID: appID, http: http) }
        inflightInfo[appID] = task
        let result = await task.value
        inflightInfo[appID] = nil
        if let result {
            infoCache[appID] = result
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(result) {
                try? data.write(to: infoFileURL(appID: appID), options: .atomic)
            }
        } else {
            failed.insert(appID)
        }
        return result
    }

    /// 图标本地文件（已缓存直接返回；否则下载 artworkUrl100 写入缓存）。失败返回 nil。
    public func artworkFile(appID: Int64) async -> URL? {
        let file = imageFileURL(appID: appID)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        if let task = inflightImage[appID] { return await task.value }
        guard let info = await info(appID: appID), let remote = info.artworkURL else { return nil }
        let http = self.http
        let dir = directory
        let task = Task<URL?, Never> {
            guard let (data, status) = try? await http.get(remote, headers: [:]), status == 200, !data.isEmpty else { return nil }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
            return file
        }
        inflightImage[appID] = task
        let result = await task.value
        inflightImage[appID] = nil
        return result
    }

    static func fetchInfo(appID: Int64, http: HTTPFetching) async -> AppLookupInfo? {
        for country in countries {
            guard let (data, status) = try? await http.get(lookupURL(appID: appID, country: country), headers: [:]),
                  status == 200,
                  let info = parse(data, appID: appID, country: country) else { continue }
            return info
        }
        return nil
    }

    /// 解析 lookup 响应；`resultCount == 0` 返回 nil。
    public static func parse(_ data: Data, appID: Int64, country: String) -> AppLookupInfo? {
        struct Response: Decodable {
            struct Item: Decodable {
                let artworkUrl100: String?
                let artworkUrl512: String?
                let artistName: String?
                let sellerName: String?
            }
            let resultCount: Int?
            let results: [Item]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let item = response.results?.first else { return nil }
        let artist = [item.artistName, item.sellerName].compactMap { $0 }.first { !$0.isEmpty }
        return AppLookupInfo(appID: appID,
                             artworkURL: (item.artworkUrl100 ?? item.artworkUrl512).flatMap(URL.init(string:)),
                             artistName: artist,
                             country: country)
    }
}
