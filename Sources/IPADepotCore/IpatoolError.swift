import Foundation

/// 错误类别。`raw` 中保留 ipatool 原始英文。
public enum IpatoolErrorKind: String, Sendable, CaseIterable, Codable {
    case licenseRequired
    case licenseAlreadyExists
    case passwordTokenExpired
    case accountDisabled
    case authCodeRequired
    case invalidAuthCodeFormat
    case verificationIncomplete
    case appNotFound
    case notLoggedIn
    case keychainNotFound
    case networkUnreachable
    case packagePlatformMismatch
    case binaryNotFound
    case cancelled
    case invalidOutput
    case verificationFailed
    case unknown
}

public struct IpatoolError: Error, LocalizedError, Sendable, Equatable {
    public let kind: IpatoolErrorKind
    /// ipatool 原始英文信息（没有时为空字符串）。
    public let raw: String
    public let exitCode: Int32?

    public init(kind: IpatoolErrorKind, raw: String = "", exitCode: Int32? = nil) {
        self.kind = kind
        self.raw = raw
        self.exitCode = exitCode
    }

    /// 中文用户文案。
    public var message: String {
        switch kind {
        case .licenseRequired:
            return "当前账号还没有这个 App 的授权。免费 App 可先「获取」（领取授权）后再下载；付费 App 需先在 App Store 购买。"
        case .licenseAlreadyExists:
            return "账号已拥有这个 App 的授权，无需重复获取。"
        case .passwordTokenExpired:
            return "登录状态已过期，请重新登录 Apple ID。"
        case .accountDisabled:
            return "该 Apple ID 已被停用，请到 Apple 官网或 App Store 处理账号问题。"
        case .authCodeRequired:
            return "需要双重认证验证码，请查看受信任设备上弹出的 6 位验证码。"
        case .invalidAuthCodeFormat:
            return "验证码必须是 6 位数字。"
        case .verificationIncomplete:
            return "Apple 未完成验证，请重新获取一个新的双重认证验证码后再试。"
        case .appNotFound:
            return "没有找到这个 App。可能已下架，或不在当前账号所在的地区商店。"
        case .notLoggedIn:
            return "还没有登录 Apple ID，请先登录。"
        case .keychainNotFound:
            return "系统找不到默认钥匙串，无法保存登录信息。请打开「钥匙串访问」确认存在「登录」钥匙串并设为默认。"
        case .networkUnreachable:
            var text = "网络连接失败，无法访问 Apple 服务器。请检查网络或代理设置后重试。"
            if Self.mentionsAppleDownloadHost(raw) {
                text += "在中国大陆网络下，Apple 的购买/下载域名（如 p*-buy.itunes.apple.com）可能无法直连，首次使用还需访问 files.pythonhosted.org 与 swcdn.apple.com 下载组件，可尝试切换网络或使用代理。"
            } else {
                text += "在中国大陆网络下，部分 Apple 购买/下载域名（如 p*-buy.itunes.apple.com）可能无法直连。"
            }
            return text
        case .packagePlatformMismatch:
            return "下载的安装包未声明支持 iPhone，ipatool 2.7.0 拒绝保存（较老的历史版本常见，上游已在后续版本修复）。"
        case .binaryNotFound:
            return "找不到内置的 ipatool 组件，安装包可能已损坏，请重新下载 IPA Depot。"
        case .cancelled:
            return "操作已取消。"
        case .invalidOutput:
            return "ipatool 返回了无法识别的结果。"
        case .verificationFailed:
            return "下载的文件校验失败（不是有效的 IPA 包）。"
        case .unknown:
            return raw.isEmpty ? "发生未知错误。" : "发生错误：\(raw)"
        }
    }

    public var errorDescription: String? { message }
    public var failureReason: String? { raw.isEmpty ? nil : raw }

    static func mentionsAppleDownloadHost(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.range(of: #"p\d+-buy\.itunes\.apple\.com"#, options: .regularExpression) != nil
            || lower.contains("buy.itunes.apple.com")
            || lower.contains("pythonhosted.org")
            || lower.contains("swcdn.apple.com")
    }
}

/// 把 ipatool 原始错误字符串映射为 `IpatoolError`。按顺序匹配，先具体后笼统。
public enum IpatoolErrorMapper {
    static let rules: [(IpatoolErrorKind, [String])] = [
        (.invalidAuthCodeFormat, ["2fa code must contain exactly six digits"]),
        (.verificationIncomplete, ["apple did not complete verification"]),
        (.authCodeRequired, ["auth code is required", "2fa code is required"]),
        (.licenseAlreadyExists, ["license already exists"]),
        (.licenseRequired, ["license is required"]),
        (.passwordTokenExpired, ["password token is expired"]),
        (.accountDisabled, ["account is disabled"]),
        (.appNotFound, ["app not found"]),
        (.keychainNotFound, ["keychain cannot be found", "keychain not found", "no default keychain"]),
        (.notLoggedIn, ["failed to get account", "could not be found in the keychain", "item could not be found",
                        "the specified item could not be found"]),
        (.packagePlatformMismatch, ["does not declare iphoneos support", "failed to validate package platform"]),
        (.networkUnreachable, ["no such host", "dial tcp", "i/o timeout", "connection refused", "connection reset",
                               "network is unreachable", "tls handshake timeout", "context deadline exceeded",
                               "client.timeout exceeded", "host is down", "no route to host",
                               "temporary failure in name resolution", "server misbehaving",
                               "unexpected eof", "send sap request"]),
    ]

    public static func map(_ raw: String, exitCode: Int32? = nil) -> IpatoolError {
        let lower = raw.lowercased()
        for (kind, needles) in rules where needles.contains(where: { lower.contains($0) }) {
            return IpatoolError(kind: kind, raw: raw, exitCode: exitCode)
        }
        return IpatoolError(kind: .unknown, raw: raw, exitCode: exitCode)
    }
}
