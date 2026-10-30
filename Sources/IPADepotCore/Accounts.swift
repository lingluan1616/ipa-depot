import Foundation

/// 账号的商店地区标签（用户添加账号时选择，可修改）。只是标签：实际地区由 Apple ID 本身决定。
public enum AccountRegion: String, Sendable, Codable, CaseIterable, Identifiable {
    case mainlandChina = "cn"
    case hongKong = "hk"
    case taiwan = "tw"
    case japan = "jp"
    case unitedStates = "us"
    case korea = "kr"
    case other = "other"

    public var id: String { rawValue }

    /// 未知取值（未来版本新增的地区）按「其他」处理，不让整份账号表解析失败。
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AccountRegion(rawValue: raw) ?? .other
    }
}

/// 钥匙串里是否保存了该账号的密码。
public enum PasswordState: String, Sendable, Codable {
    /// 已保存，切换时自动登录。
    case saved
    /// 未保存（如 0.1.0 升级迁移来的账号），切换到它时需要补一次密码。
    case missing

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PasswordState(rawValue: raw) ?? .missing
    }
}

/// 一个已保存的 Apple ID（`accounts.json` 中的一条；不含密码）。
public struct AccountRecord: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    /// 登录用的 Apple ID（同时作为钥匙串条目的 account 字段）。
    public var email: String
    /// ipatool 返回的姓名（可能为空）。
    public var displayName: String
    public var regionLabel: AccountRegion
    /// 预留：账号的商店代码（ipatool `auth info` 不输出，目前为 nil）。
    public var storefrontHint: String?
    public var lastLoginAt: Date?
    public var passwordState: PasswordState

    public init(id: UUID = UUID(), email: String, displayName: String = "", regionLabel: AccountRegion,
                storefrontHint: String? = nil, lastLoginAt: Date? = nil, passwordState: PasswordState) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.regionLabel = regionLabel
        self.storefrontHint = storefrontHint
        self.lastLoginAt = lastLoginAt
        self.passwordState = passwordState
    }

    enum CodingKeys: String, CodingKey {
        case id, email, displayName, regionLabel, storefrontHint, lastLoginAt, passwordState
    }

    /// 容错解码：缺少非关键字段时给默认值。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        email = try c.decode(String.self, forKey: .email)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        regionLabel = (try? c.decode(AccountRegion.self, forKey: .regionLabel)) ?? .other
        storefrontHint = try? c.decodeIfPresent(String.self, forKey: .storefrontHint)
        lastLoginAt = try? c.decodeIfPresent(Date.self, forKey: .lastLoginAt)
        passwordState = (try? c.decode(PasswordState.self, forKey: .passwordState)) ?? .missing
    }

    /// 邮箱比较不区分大小写、忽略首尾空白。
    public func matches(email other: String) -> Bool {
        Self.normalize(email) == Self.normalize(other)
    }

    public static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// 账号表：全部账号 + 当前激活的账号（= ipatool 钥匙串槽位里登录着的那个；未登录为 nil）。
public struct AccountBook: Sendable, Codable, Equatable {
    public var accounts: [AccountRecord]
    public var activeAccountID: UUID?

    public init(accounts: [AccountRecord] = [], activeAccountID: UUID? = nil) {
        self.accounts = accounts
        self.activeAccountID = activeAccountID
    }

    public var isEmpty: Bool { accounts.isEmpty }

    public var active: AccountRecord? {
        guard let activeAccountID else { return nil }
        return account(activeAccountID)
    }

    public func account(_ id: UUID) -> AccountRecord? { accounts.first { $0.id == id } }

    public func account(email: String) -> AccountRecord? { accounts.first { $0.matches(email: email) } }

    /// 按 id 更新或追加。
    public mutating func upsert(_ record: AccountRecord) {
        if let index = accounts.firstIndex(where: { $0.id == record.id }) {
            accounts[index] = record
        } else {
            accounts.append(record)
        }
    }

    /// 移除账号；移除的是激活账号时激活置空。
    @discardableResult
    public mutating func remove(_ id: UUID) -> AccountRecord? {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return nil }
        if activeAccountID == id { activeAccountID = nil }
        return accounts.remove(at: index)
    }

    public mutating func update(_ id: UUID, _ body: (inout AccountRecord) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        body(&accounts[index])
    }
}

/// `accounts.json` 读写：`{"version":1,"activeAccountID":…,"accounts":[…]}`，原子写；文件缺失或损坏时视为空表。
public struct AccountStore: Sendable {
    public static let formatVersion = 1

    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    private struct Envelope: Codable {
        var version: Int
        var activeAccountID: UUID?
        var accounts: [AccountRecord]
    }

    public func load() -> AccountBook {
        guard let data = try? Data(contentsOf: fileURL) else { return AccountBook() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.version <= Self.formatVersion else { return AccountBook() }
        var book = AccountBook(accounts: envelope.accounts, activeAccountID: envelope.activeAccountID)
        // 激活 id 指向不存在的账号时视为未激活
        if let id = book.activeAccountID, book.account(id) == nil { book.activeAccountID = nil }
        return book
    }

    public func save(_ book: AccountBook) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: Self.formatVersion, activeAccountID: book.activeAccountID,
                                               accounts: book.accounts))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// 当前激活账号 id 的线程安全容器：版本缓存、下载队列据此判断「当前账号」。
public final class CurrentAccount: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: UUID?

    public init(_ id: UUID? = nil) { _id = id }

    public var id: UUID? {
        get { lock.withLock { _id } }
        set { lock.withLock { _id = newValue } }
    }

    /// 无账号归属（旧数据）的条目视为当前账号。
    public func isCurrent(_ accountID: UUID?) -> Bool {
        guard let accountID else { return true }
        return id == accountID
    }
}
