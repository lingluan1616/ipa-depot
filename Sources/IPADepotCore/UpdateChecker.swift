import Foundation

/// GitHub Releases 最新版本信息。
public struct ReleaseInfo: Sendable, Equatable {
    public let tag: String
    public let version: String
    public let htmlURL: URL
    public let name: String?
}

public enum UpdateCheckResult: Sendable, Equatable {
    case upToDate(latest: String)
    case updateAvailable(ReleaseInfo)
}

/// 语义化版本比较（忽略前缀 v；缺位补 0；预发布后缀不参与数值比较）。
public enum VersionComparator {
    public static func normalize(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("v") { t.removeFirst() }
        return t
    }

    static func components(_ version: String) -> [Int] {
        let core = normalize(version).split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        return core.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = components(a), y = components(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// 调 `https://api.github.com/repos/<owner>/<repo>/releases/latest` 检查更新（第一版不接 Sparkle）。
public struct UpdateChecker: Sendable {
    public let owner: String
    public let repo: String
    private let http: HTTPFetching

    public init(owner: String, repo: String = "ipa-depot", http: HTTPFetching = URLSessionHTTPClient()) {
        self.owner = owner
        self.repo = repo
        self.http = http
    }

    public var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    }

    public func check(currentVersion: String) async throws -> UpdateCheckResult {
        let data: Data
        let status: Int
        do {
            (data, status) = try await http.get(latestReleaseURL, headers: ["Accept": "application/vnd.github+json"])
        } catch {
            throw IpatoolError(kind: .networkUnreachable, raw: error.localizedDescription)
        }
        guard status == 200 else {
            throw IpatoolError(kind: .unknown, raw: "GitHub API HTTP \(status)")
        }
        let release = try Self.parse(data)
        if VersionComparator.compare(release.version, currentVersion) == .orderedDescending {
            return .updateAvailable(release)
        }
        return .upToDate(latest: release.version)
    }

    public static func parse(_ data: Data) throws -> ReleaseInfo {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String
            let name: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let url = URL(string: payload.html_url) else {
            throw IpatoolError(kind: .invalidOutput, raw: String(decoding: data.prefix(500), as: UTF8.self))
        }
        return ReleaseInfo(tag: payload.tag_name, version: VersionComparator.normalize(payload.tag_name),
                           htmlURL: url, name: payload.name)
    }
}
