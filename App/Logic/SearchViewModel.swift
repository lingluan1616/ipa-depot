import Foundation
import Observation
import IPADepotCore

enum SearchPlatform: String, CaseIterable, Identifiable, Hashable {
    case iphone, ipad, mac

    var id: String { rawValue }

    /// ipatool `--platform` 取值。
    var ipatoolValue: String {
        switch self {
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        case .mac: return "macos"
        }
    }

    /// 下载 / 列版本时传给 ipatool 的平台（iPhone 为默认值，不传）。
    var downloadPlatform: String? { self == .iphone ? nil : ipatoolValue }

    var title: String {
        switch self {
        case .iphone: return "iPhone"
        case .ipad: return "iPad"
        case .mac: return "Mac"
        }
    }
}

/// 搜索结果的一行（界面直接使用的字段）。
struct AppRowModel: Identifiable, Equatable, Hashable {
    let app: AppSummary
    let platform: SearchPlatform

    var id: Int64 { app.id }
    var name: String { app.name.isEmpty ? app.bundleID : app.name }
    var bundleID: String { app.bundleID }
    var version: String { app.version }
    var priceText: String { Format.price(app.price) }
    var isFree: Bool { app.isFree }
    var platformTags: [String] {
        var seen = Set<String>()
        return app.platforms.map(Format.platformLabel).filter { seen.insert($0).inserted }
    }
    /// 来自 Apple 公开目录（浏览地区）。
    var isPublicCatalog: Bool { app.isPublicCatalog }
}

/// 公开目录搜索（iTunes Search API；测试用替身）。
protocol PublicCatalogSearching: Sendable {
    func search(_ term: String, country: String, limit: Int, platform: String) async throws -> [AppSummary]
}

extension PublicCatalogService: PublicCatalogSearching {}

/// 搜索页的「浏览地区」：跟随当前账号（ipatool 搜索），或指定地区（公开目录）。
enum BrowseRegion: Equatable, Hashable {
    case followAccount
    /// 指定地区；`.other` 时 `customCode` 为自填的两位代码。
    case region(AccountRegion, customCode: String?)

    /// UserDefaults 的键。
    static let defaultsKey = "browseRegion"

    /// 实际用于公开目录的国家代码；跟随账号或「其他」未填有效代码时为 nil。
    var countryCode: String? {
        switch self {
        case .followAccount: return nil
        case .region(let region, let custom): return RegionCatalog.countryCode(for: region, customCode: custom)
        }
    }

    /// Picker 的选中项（nil = 跟随当前账号）。
    var region: AccountRegion? {
        if case .region(let region, _) = self { return region }
        return nil
    }

    /// 持久化：`follow` / 原始值（`us`）/ `other:sg`。
    var storageValue: String {
        switch self {
        case .followAccount: return "follow"
        case .region(.other, let custom): return "other:\(custom ?? "")"
        case .region(let region, _): return region.rawValue
        }
    }

    init(storageValue raw: String?) {
        guard let raw, raw != "follow", !raw.isEmpty else { self = .followAccount; return }
        if raw.hasPrefix("other:") {
            self = .region(.other, customCode: RegionCatalog.normalizeCode(String(raw.dropFirst(6))))
        } else if let region = AccountRegion(rawValue: raw) {
            self = .region(region, customCode: nil)
        } else {
            self = .followAccount
        }
    }
}

@MainActor
@Observable
final class SearchViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case results
        case empty
        case signedOut
        /// 刚切换了账号（参数为新账号的地区名）：结果已清空，提示重新搜索。
        case accountChanged(String)
        case failed(ErrorPresentation)
    }

    static let limits = [10, 25, 50]

    var query = ""
    var platform: SearchPlatform = .iphone
    var limit = 25

    private(set) var phase: Phase = .idle
    private(set) var rows: [AppRowModel] = []
    private(set) var lastQuery: String?

    /// 浏览地区（持久化到 UserDefaults）。改用 `setBrowseRegion` 修改。
    private(set) var browseRegion: BrowseRegion = .followAccount
    /// 最近一次结果所用的公开目录国家代码（跟随账号的结果为 nil）。
    private(set) var resultsCountry: String?

    @ObservationIgnored private let service: SearchServicing
    @ObservationIgnored private let catalog: PublicCatalogSearching?
    @ObservationIgnored private let defaults: KeyValueStoring?
    @ObservationIgnored private let isSignedIn: @MainActor () -> Bool
    @ObservationIgnored private var currentTask: Task<Void, Never>?

    init(service: SearchServicing, catalog: PublicCatalogSearching? = nil, defaults: KeyValueStoring? = nil,
         isSignedIn: @escaping @MainActor () -> Bool) {
        self.service = service
        self.catalog = catalog
        self.defaults = defaults
        self.isSignedIn = isSignedIn
        if catalog != nil {
            browseRegion = BrowseRegion(storageValue: defaults?.string(forKey: BrowseRegion.defaultsKey))
        }
    }

    /// 当前是否按公开目录搜索（浏览地区不是「跟随当前账号」且代码有效）。
    var isBrowsingCatalog: Bool { catalog != nil && browseRegion.countryCode != nil }

    /// 浏览地区的显示名（跟随账号时为 nil）。
    var browseRegionTitle: String? { browseRegion.countryCode.map(AccountRegion.title(forCode:)) }

    /// 切换浏览地区：持久化，清空结果，有关键词时自动重新搜索。
    func setBrowseRegion(_ region: BrowseRegion) {
        guard region != browseRegion else { return }
        browseRegion = region
        defaults?.set(region.storageValue, forKey: BrowseRegion.defaultsKey)
        currentTask?.cancel()
        currentTask = nil
        rows = []
        lastQuery = nil
        resultsCountry = nil
        phase = .idle
        if canSearch, region == .followAccount || region.countryCode != nil { submit() }
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSearch: Bool { !trimmedQuery.isEmpty }

    /// 发起搜索（取消上一次未完成的搜索）。
    func submit() {
        currentTask?.cancel()
        currentTask = Task { await search() }
    }

    func search() async {
        let term = trimmedQuery
        guard !term.isEmpty else { return }
        if let catalog, let country = browseRegion.countryCode {
            await searchCatalog(term, country: country, catalog: catalog)
            return
        }
        guard isSignedIn() else {
            rows = []
            phase = .signedOut
            return
        }
        let platform = self.platform
        let limit = self.limit
        phase = .loading
        lastQuery = term
        do {
            let apps = try await service.search(term, limit: limit, platform: platform.ipatoolValue)
            if Task.isCancelled { return }
            resultsCountry = nil
            rows = Self.makeRows(apps, platform: platform)
            phase = rows.isEmpty ? .empty : .results
        } catch let error as IpatoolError {
            if error.kind == .cancelled { return }
            rows = []
            phase = error.kind == .notLoggedIn ? .signedOut : .failed(ErrorPresentation(error))
        } catch is CancellationError {
            return
        } catch {
            rows = []
            phase = .failed(ErrorPresentation(message: error.localizedDescription))
        }
    }

    /// 公开目录搜索（不需要登录，不走 ipatool）。
    private func searchCatalog(_ term: String, country: String, catalog: PublicCatalogSearching) async {
        let platform = self.platform
        let limit = self.limit
        phase = .loading
        lastQuery = term
        do {
            let apps = try await catalog.search(term, country: country, limit: limit, platform: platform.ipatoolValue)
            if Task.isCancelled || browseRegion.countryCode != country { return }
            resultsCountry = country
            rows = Self.makeRows(apps, platform: platform)
            phase = rows.isEmpty ? .empty : .results
        } catch let error as IpatoolError {
            if error.kind == .cancelled || Task.isCancelled { return }
            rows = []
            phase = .failed(ErrorPresentation(error))
        } catch is CancellationError {
            return
        } catch {
            rows = []
            phase = .failed(ErrorPresentation(message: error.localizedDescription))
        }
    }

    /// 账号切换后：取消进行中的搜索、清空结果并提示「已切换到 X 账号，请重新搜索」（不自动重新搜索）。
    /// `label` 为 nil 表示现在未登录。浏览公开目录时结果与账号无关，保持不变。
    func accountChanged(label: String?) {
        if isBrowsingCatalog { return }
        currentTask?.cancel()
        currentTask = nil
        rows = []
        lastQuery = nil
        phase = label.map { .accountChanged($0) } ?? .idle
    }

    /// 取消进行中的搜索（保留已有结果与状态）。公开目录搜索不涉及 ipatool，不取消。
    func cancelPending() {
        if isBrowsingCatalog { return }
        currentTask?.cancel()
        currentTask = nil
        if phase == .loading { phase = .idle }
    }

    /// 登出后清空（浏览公开目录时保留结果：不需要登录）。
    func reset() {
        if isBrowsingCatalog { return }
        currentTask?.cancel()
        currentTask = nil
        rows = []
        lastQuery = nil
        phase = .idle
    }

    static func makeRows(_ apps: [AppSummary], platform: SearchPlatform) -> [AppRowModel] {
        var seen = Set<Int64>()
        return apps.filter { seen.insert($0.id).inserted }.map { AppRowModel(app: $0, platform: platform) }
    }
}
