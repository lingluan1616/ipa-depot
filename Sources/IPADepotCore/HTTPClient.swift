import Foundation

/// 最小 HTTP 抽象（便于测试替身）。
public protocol HTTPFetching: Sendable {
    /// 返回响应体与 HTTP 状态码。
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int)
}

public struct URLSessionHTTPClient: HTTPFetching {
    public let session: URLSession
    public let timeout: TimeInterval

    /// 默认用 ephemeral 会话：图标与查询结果由本 App 自己缓存在 `cache/` 下，避免系统再往 `~/Library/Caches/<bundle id>` 写一份。
    public static let ephemeralSession = URLSession(configuration: .ephemeral)

    public init(session: URLSession = URLSessionHTTPClient.ephemeralSession, timeout: TimeInterval = 15) {
        self.session = session
        self.timeout = timeout
    }

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
