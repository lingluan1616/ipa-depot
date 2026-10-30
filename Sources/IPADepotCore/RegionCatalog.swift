import Foundation

/// 地区目录里的一条：账号地区标签 ↔ App Store 两位国家代码（iTunes Search API 的 `country` 参数）。
public struct RegionEntry: Sendable, Hashable, Identifiable {
    public let region: AccountRegion
    /// 中文标签（`accounts.json` 旧数据可能直接存了这段文字）。
    public let label: String
    /// 英文标签。
    public let englishLabel: String
    /// 两位国家代码（小写）；「其他」为 nil（由用户自填）。
    public let countryCode: String?
    /// 旗帜 emoji；「其他」为地球。
    public let flag: String
    /// 列表排序（升序）。
    public let sortOrder: Int

    public var id: String { region.rawValue }
}

/// 地区目录：中国大陆 cn / 香港 hk / 台湾 tw / 日本 jp / 美国 us / 韩国 kr，以及「其他」（用户自填两位代码）。
/// 账号地区标签、浏览地区选择、公开目录搜索都以这里为准。
public enum RegionCatalog {
    public static let entries: [RegionEntry] = [
        RegionEntry(region: .mainlandChina, label: "中国大陆", englishLabel: "Mainland China", countryCode: "cn", flag: "🇨🇳", sortOrder: 0),
        RegionEntry(region: .hongKong, label: "香港", englishLabel: "Hong Kong", countryCode: "hk", flag: "🇭🇰", sortOrder: 1),
        RegionEntry(region: .taiwan, label: "台湾", englishLabel: "Taiwan", countryCode: "tw", flag: "🇹🇼", sortOrder: 2),
        RegionEntry(region: .japan, label: "日本", englishLabel: "Japan", countryCode: "jp", flag: "🇯🇵", sortOrder: 3),
        RegionEntry(region: .unitedStates, label: "美国", englishLabel: "United States", countryCode: "us", flag: "🇺🇸", sortOrder: 4),
        RegionEntry(region: .korea, label: "韩国", englishLabel: "Korea", countryCode: "kr", flag: "🇰🇷", sortOrder: 5),
        RegionEntry(region: .other, label: "其他", englishLabel: "Other", countryCode: nil, flag: "🌐", sortOrder: 6),
    ].sorted { $0.sortOrder < $1.sortOrder }

    /// 按排序的地区（界面 Picker 用）。
    public static var regions: [AccountRegion] { entries.map(\.region) }

    public static func entry(for region: AccountRegion) -> RegionEntry {
        entries.first { $0.region == region } ?? entries[entries.count - 1]
    }

    /// 地区 → 国家代码。「其他」用自填代码（无效则 nil）。
    public static func countryCode(for region: AccountRegion, customCode: String? = nil) -> String? {
        if let code = entry(for: region).countryCode { return code }
        return customCode.flatMap(normalizeCode)
    }

    /// 国家代码 → 目录里的地区；不在目录里的有效两位代码返回 `.other`，无效返回 nil。
    public static func region(forCode code: String) -> AccountRegion? {
        guard let normalized = normalizeCode(code) else { return nil }
        return entries.first { $0.countryCode == normalized }?.region ?? .other
    }

    /// 标签文字（中文 / 英文，不区分大小写）→ 地区。
    public static func region(forLabel label: String) -> AccountRegion? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return entries.first { $0.label == text || $0.englishLabel.lowercased() == text.lowercased() }?.region
    }

    /// 兼容旧数据：`accounts.json` 的 `regionLabel` 可能是原始值（cn / other）、标签文字（日本 / Japan）
    /// 或其他两位国家代码（sg）。返回地区与「其他」的自填代码。无法识别的一律按「其他」。
    public static func resolve(storedValue raw: String) -> (region: AccountRegion, customCode: String?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let region = AccountRegion(rawValue: text.lowercased()) { return (region, nil) }
        if let region = region(forLabel: text) { return (region, nil) }
        if let code = normalizeCode(text) {
            let region = region(forCode: code) ?? .other
            return (region, region == .other ? code : nil)
        }
        return (.other, nil)
    }

    /// 两位 ASCII 字母 → 小写代码；否则 nil。
    public static func normalizeCode(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 2, trimmed.unicodeScalars.allSatisfy({ $0.value >= 97 && $0.value <= 122 }) else { return nil }
        return trimmed
    }

    /// 国家代码 → 旗帜 emoji（区域指示符号）；无效代码返回地球。
    public static func flag(forCode code: String) -> String {
        guard let normalized = normalizeCode(code) else { return "🌐" }
        let scalars = normalized.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 97) }
        return String(String.UnicodeScalarView(scalars))
    }
}

extension AccountRecord {
    /// 账号对应的 App Store 国家代码（「其他」用自填代码；未填为 nil）。
    public var countryCode: String? { RegionCatalog.countryCode(for: regionLabel, customCode: customRegionCode) }

    /// 账号地区是否与某个浏览地区（国家代码）一致。
    public func matches(countryCode code: String) -> Bool {
        guard let own = countryCode, let other = RegionCatalog.normalizeCode(code) else { return false }
        return own == other
    }
}

/// 公开目录结果需要一个与浏览地区一致的账号。
public enum RegionAccountMatch: Sendable, Equatable {
    /// 当前账号就是该地区：直接继续。
    case current(AccountRecord)
    /// 另一个已保存的账号是该地区：先自动切换再继续。
    case other(AccountRecord)
    /// 没有该地区的账号：提示添加。
    case none
}

extension AccountBook {
    /// 为浏览地区（国家代码）找账号：当前账号优先；否则取最近登录过的同地区账号。
    public func match(countryCode code: String) -> RegionAccountMatch {
        if let active, active.matches(countryCode: code) { return .current(active) }
        let candidates = accounts.filter { $0.id != activeAccountID && $0.matches(countryCode: code) }
        let best = candidates.max { ($0.lastLoginAt ?? .distantPast) < ($1.lastLoginAt ?? .distantPast) }
        return best.map(RegionAccountMatch.other) ?? .none
    }
}
