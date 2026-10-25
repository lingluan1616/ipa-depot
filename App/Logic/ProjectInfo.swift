import Foundation

/// 项目信息的唯一来源（关于页的项目地址、检查更新都从这里读取）。
///
/// 发布前运行 `scripts/set-owner.sh <GitHub 用户名>`，脚本只改写 `repositoryOwner` 这一行和 README 里的链接。
enum ProjectInfo {
    /// GitHub 账号名（发布前由 `scripts/set-owner.sh` 替换）。
    static let repositoryOwner = "OWNER_PLACEHOLDER"
    static let repositoryName = "ipa-depot"

    /// 未配置时的占位值（`set-owner.sh` 不会改动这一行，用于判断是否已配置）。
    static let placeholderOwner = "OWNER_PLACEHOLDER"

    /// 已配置的账号名；未配置时为 nil（「检查更新」不可用，项目地址不可点）。
    static var owner: String? {
        let value = repositoryOwner.trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == placeholderOwner ? nil : value
    }

    static var displayURL: String { "https://github.com/\(repositoryOwner)/\(repositoryName)" }

    static var projectURL: URL? {
        guard owner != nil else { return nil }
        return URL(string: displayURL)
    }

    static var releasesURL: URL? {
        guard owner != nil else { return nil }
        return URL(string: "\(displayURL)/releases")
    }

    static let ipatoolURL = URL(string: "https://github.com/majd/ipatool")!
}
