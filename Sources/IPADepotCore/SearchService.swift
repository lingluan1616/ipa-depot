import Foundation

/// `search <term> --limit N --platform iphone`。结果来自账号所在地区的商店。
public struct SearchService: Sendable {
    public let runner: IpatoolRunner

    public init(runner: IpatoolRunner) { self.runner = runner }

    public static func arguments(term: String, limit: Int, platform: String) -> [String] {
        ["search", term, "--limit", String(limit), "--platform", platform]
    }

    public func search(_ term: String, limit: Int = 10, platform: String = "iphone") async throws -> [AppSummary] {
        let result = try await runner.run(Self.arguments(term: term, limit: limit, platform: platform))
        return try Self.parse(result)
    }

    public static func parse(_ result: IpatoolProcess.Result) throws -> [AppSummary] {
        guard let event = result.lastEvent(containing: "apps") else {
            if result.lastEvent(containing: "count")?["count"]?.doubleValue == 0 { return [] }
            throw IpatoolError(kind: .invalidOutput, raw: result.textLines.joined(separator: "\n"))
        }
        struct Payload: Decodable { let apps: [AppSummary]? }
        do {
            return try event.decode(Payload.self).apps ?? []
        } catch {
            throw IpatoolError(kind: .invalidOutput, raw: String(decoding: event.rawData, as: UTF8.self))
        }
    }
}
