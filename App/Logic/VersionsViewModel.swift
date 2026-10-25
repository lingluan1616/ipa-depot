import Foundation
import Observation
import IPADepotCore

/// 历史版本列表：ID 倒序（最新在上），版本号与日期按可见区域分批懒加载。
@MainActor
@Observable
final class VersionsViewModel {
    struct Row: Identifiable, Equatable {
        let id: String
        var metadata: VersionMetadata?
        var failed = false
        var isLatest = false
    }

    enum Phase: Equatable {
        case loading
        case loaded
        case licenseRequired
        case failed(ErrorPresentation)
    }

    let app: AppSummary
    let platform: SearchPlatform

    private(set) var phase: Phase = .loading
    private(set) var rows: [Row] = []
    private(set) var loadingIDs: Set<String> = []

    /// 每批请求的 ID 数。
    @ObservationIgnored var batchSize = 10
    /// 可见区域下方额外预取的行数。
    @ObservationIgnored var lookahead = 5
    /// 可见区域上方额外预取的行数。
    @ObservationIgnored var lookbehind = 2
    /// 每批实际请求的 ID（测试与调试用）。
    @ObservationIgnored private(set) var batchLog: [[String]] = []
    @ObservationIgnored private(set) var pumpTask: Task<Void, Never>?

    @ObservationIgnored private let service: VersionServicing
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    @ObservationIgnored private var visible: Set<Int> = []
    @ObservationIgnored private var requested: Set<String> = []

    init(app: AppSummary, platform: SearchPlatform = .iphone, service: VersionServicing) {
        self.app = app
        self.platform = platform
        self.service = service
    }

    var loadedCount: Int { rows.filter { $0.metadata != nil }.count }

    /// 取版本 ID 列表。
    func load() async {
        phase = .loading
        do {
            let ids = try await service.listVersionIDs(appID: app.id, platform: platform.downloadPlatform)
            setRows(Self.ordered(ids))
            phase = .loaded
            if !visible.isEmpty { schedule() }
        } catch let error as IpatoolError {
            if error.kind == .cancelled { return }
            phase = error.kind == .licenseRequired ? .licenseRequired : .failed(ErrorPresentation(error))
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(ErrorPresentation(message: error.localizedDescription))
        }
    }

    /// ipatool 返回的 ID 是从旧到新，界面倒序（最新在上），去重。
    static func ordered(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.reversed().filter { seen.insert($0).inserted }
    }

    func setRows(_ ids: [String]) {
        rows = ids.enumerated().map { Row(id: $1, isLatest: $0 == 0) }
        indexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        requested = []
        loadingIDs = []
    }

    // MARK: - 懒加载

    func rowAppeared(_ id: String) {
        guard let index = indexByID[id] else { return }
        visible.insert(index)
        schedule()
    }

    func rowDisappeared(_ id: String) {
        guard let index = indexByID[id] else { return }
        visible.remove(index)
    }

    /// 重新加载某行（失败后点「重试」）。
    func retry(_ id: String) {
        guard let index = indexByID[id] else { return }
        rows[index].failed = false
        requested.remove(id)
        visible.insert(index)
        schedule()
    }

    /// 下一批要请求的 ID：只在「可见区域 - lookbehind」到「可见区域 + lookahead」范围内，按从上到下的顺序。
    func nextBatch() -> [String] {
        guard let low = visible.min(), let high = visible.max(), !rows.isEmpty else { return [] }
        let start = max(0, low - lookbehind)
        let end = min(rows.count - 1, high + lookahead)
        guard start <= end else { return [] }
        var batch: [String] = []
        for index in start...end {
            let row = rows[index]
            if row.metadata == nil && !row.failed && !requested.contains(row.id) {
                batch.append(row.id)
                if batch.count >= batchSize { break }
            }
        }
        return batch
    }

    private func schedule() {
        guard phase == .loaded, pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            await self?.pump()
            self?.pumpTask = nil
        }
    }

    private func pump() async {
        while !Task.isCancelled {
            let batch = nextBatch()
            if batch.isEmpty { return }
            requested.formUnion(batch)
            loadingIDs.formUnion(batch)
            batchLog.append(batch)
            do {
                let results = try await service.metadata(appID: app.id, versionIDs: batch, useCache: true) { [weak self] meta in
                    Task { @MainActor in self?.apply(meta) }
                }
                for meta in results { apply(meta) }
                for id in batch {
                    if let index = indexByID[id], rows[index].metadata == nil { rows[index].failed = true }
                }
            } catch let error as IpatoolError {
                loadingIDs.subtract(batch)
                switch error.kind {
                case .cancelled:
                    requested.subtract(batch)
                    return
                case .licenseRequired:
                    phase = .licenseRequired
                    return
                default:
                    for id in batch { if let index = indexByID[id] { rows[index].failed = true } }
                }
            } catch {
                loadingIDs.subtract(batch)
                requested.subtract(batch)
                return
            }
            loadingIDs.subtract(batch)
        }
    }

    func apply(_ meta: VersionMetadata) {
        guard let index = indexByID[meta.externalVersionID] else { return }
        rows[index].metadata = meta
        rows[index].failed = false
        loadingIDs.remove(meta.externalVersionID)
    }

    func cancel() {
        pumpTask?.cancel()
    }

    /// 下载上下文。
    func context(for row: Row?) -> DownloadContext {
        DownloadContext(app: app, platform: platform,
                        externalVersionID: row?.id,
                        versionLabel: row?.metadata?.displayVersion ?? (row == nil ? app.version : nil))
    }
}
