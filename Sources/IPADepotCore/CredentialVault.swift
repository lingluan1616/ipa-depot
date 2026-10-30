import Foundation
import Security

/// 账号密码保险库：按邮箱存取密码。
public protocol CredentialVault: Sendable {
    /// 读取密码；没有保存时返回 nil。
    func password(for email: String) throws -> String?
    /// 保存或更新密码。
    func setPassword(_ password: String, for email: String) throws
    /// 删除密码（不存在时不报错）。
    func removePassword(for email: String) throws
}

public struct CredentialVaultError: Error, LocalizedError, Sendable, Equatable {
    public let status: Int32
    public let operation: String

    public init(status: Int32, operation: String) {
        self.status = status
        self.operation = operation
    }

    public var errorDescription: String? {
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return "钥匙串\(operation)失败：\(detail)"
    }
}

/// macOS 登录钥匙串实现：通用密码条目，service = `app.ipadepot.mac.accounts`，account = 邮箱。
/// - 可访问性 `kSecAttrAccessibleAfterFirstUnlock`，不开 iCloud 同步（`kSecAttrSynchronizable = false`）。
/// - 条目由 IPA Depot 自己创建，ACL 只信任创建它的 App；ad-hoc 签名的 App 每换一个版本，系统可能再弹一次授权。
public struct KeychainCredentialVault: CredentialVault {
    public static let defaultService = "app.ipadepot.mac.accounts"

    public let service: String

    public init(service: String = KeychainCredentialVault.defaultService) {
        self.service = service
    }

    /// 定位某个邮箱条目的查询字典（不含返回选项）。
    public func baseQuery(email: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: AccountRecord.normalize(email),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    /// 新建条目时的属性。
    public func addAttributes(email: String, password: String) -> [String: Any] {
        var attributes = baseQuery(email: email)
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = "IPA Depot (\(AccountRecord.normalize(email)))"
        attributes[kSecAttrDescription as String] = "IPA Depot Apple ID password"
        return attributes
    }

    public func password(for email: String) throws -> String? {
        var query = baseQuery(email: email)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialVaultError(status: status, operation: "读取")
        }
    }

    public func setPassword(_ password: String, for email: String) throws {
        let update: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(baseQuery(email: email) as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addStatus = SecItemAdd(addAttributes(email: email, password: password) as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialVaultError(status: addStatus, operation: "保存") }
        default:
            throw CredentialVaultError(status: status, operation: "更新")
        }
    }

    public func removePassword(for email: String) throws {
        let status = SecItemDelete(baseQuery(email: email) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialVaultError(status: status, operation: "删除")
        }
    }
}

/// 内存实现（测试与 Debug 冒烟用）。
public final class InMemoryCredentialVault: CredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]
    /// 设为非 nil 时，所有操作抛出该错误（测试钥匙串故障）。
    public var failure: CredentialVaultError? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    private var _failure: CredentialVaultError?

    public init(_ initial: [String: String] = [:]) {
        storage = Dictionary(uniqueKeysWithValues: initial.map { (AccountRecord.normalize($0.key), $0.value) })
    }

    public var snapshot: [String: String] { lock.withLock { storage } }

    public func password(for email: String) throws -> String? {
        try lock.withLock {
            if let _failure { throw _failure }
            return storage[AccountRecord.normalize(email)]
        }
    }

    public func setPassword(_ password: String, for email: String) throws {
        try lock.withLock {
            if let _failure { throw _failure }
            storage[AccountRecord.normalize(email)] = password
        }
    }

    public func removePassword(for email: String) throws {
        try lock.withLock {
            if let _failure { throw _failure }
            storage[AccountRecord.normalize(email)] = nil
        }
    }
}

#if DEBUG
/// 仅 Debug：把密码明文存进一个 JSON 文件（界面冒烟用假账号，避免读写真实钥匙串）。
/// 由环境变量 `IPADEPOT_VAULT_FILE` 启用，Release 构建没有此类型。
public struct FileCredentialVault: CredentialVault {
    public static let environmentKey = "IPADEPOT_VAULT_FILE"

    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func save(_ values: [String: String]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: fileURL, options: .atomic)
    }

    public func password(for email: String) throws -> String? { load()[AccountRecord.normalize(email)] }

    public func setPassword(_ password: String, for email: String) throws {
        var values = load()
        values[AccountRecord.normalize(email)] = password
        try save(values)
    }

    public func removePassword(for email: String) throws {
        var values = load()
        values[AccountRecord.normalize(email)] = nil
        try save(values)
    }
}
#endif
