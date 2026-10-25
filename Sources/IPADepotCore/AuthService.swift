import Foundation

/// `auth info` 与 `auth revoke` 封装（登录见 `LoginSession`）。
public struct AuthService: Sendable {
    public let runner: IpatoolRunner

    public init(runner: IpatoolRunner) { self.runner = runner }

    /// 当前账号信息；未登录时抛 `.notLoggedIn`。
    public func info() async throws -> AccountInfo {
        let result = try await runner.run(["auth", "info"])
        guard let event = result.events.last(where: { $0.success == true }) ?? result.lastEvent(containing: "email") else {
            throw IpatoolError(kind: .invalidOutput, raw: result.textLines.joined(separator: "\n"))
        }
        return AccountInfo(name: event["name"]?.stringValue ?? "", email: event["email"]?.stringValue ?? "")
    }

    /// 登出：删除钥匙串中的 ipatool 凭据。（阶段一只封装，不调用。）
    public func revoke() async throws {
        _ = try await runner.run(["auth", "revoke"])
    }
}
