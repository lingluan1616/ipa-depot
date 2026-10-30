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

    @ObservationIgnored private let service: SearchServicing
    @ObservationIgnored private let isSignedIn: @MainActor () -> Bool
    @ObservationIgnored private var currentTask: Task<Void, Never>?

    init(service: SearchServicing, isSignedIn: @escaping @MainActor () -> Bool) {
        self.service = service
        self.isSignedIn = isSignedIn
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

    /// 账号切换后：取消进行中的搜索、清空结果并提示「已切换到 X 账号，请重新搜索」（不自动重新搜索）。
    /// `label` 为 nil 表示现在未登录。
    func accountChanged(label: String?) {
        currentTask?.cancel()
        currentTask = nil
        rows = []
        lastQuery = nil
        phase = label.map { .accountChanged($0) } ?? .idle
    }

    /// 登出后清空。
    func reset() {
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
