import Foundation
import Observation
import IPADepotCore

/// 发起一次下载所需的展示信息（队列本身只认 `DownloadRequest`）。
struct DownloadContext: Equatable, Hashable {
    let appID: Int64
    let name: String
    let bundleID: String
    let isFree: Bool
    let platform: SearchPlatform
    /// nil = 最新版。
    let externalVersionID: String?
    /// 用于文件名与显示的版本号（未知时用外部版本 ID）。
    let versionLabel: String
    /// 从公开目录（浏览地区）发起时为所浏览的国家代码；队列里据此总是显示地区标签。
    let catalogCountry: String?

    init(app: AppSummary, platform: SearchPlatform, externalVersionID: String?, versionLabel: String?) {
        self.catalogCountry = app.catalogCountry
        self.appID = app.id
        self.name = app.name.isEmpty ? app.bundleID : app.name
        self.bundleID = app.bundleID
        self.isFree = app.isFree
        self.platform = platform
        self.externalVersionID = externalVersionID
        let label = versionLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.versionLabel = label.isEmpty ? (externalVersionID ?? app.version) : label
    }

    /// 从上次保存的队列恢复。
    init(persisted entry: PersistedDownload) {
        self.catalogCountry = entry.catalogCountry
        self.appID = entry.appID
        self.name = entry.name
        self.bundleID = entry.bundleID
        self.isFree = entry.isFree
        self.platform = SearchPlatform(rawValue: entry.displayPlatform) ?? .iphone
        self.externalVersionID = entry.externalVersionID
        self.versionLabel = entry.versionLabel
    }
}

/// 需要领取许可时的提示。`itemID` 为触发提示的失败条目（从历史版本页直接领取时为 nil）。
struct LicensePrompt: Identifiable, Equatable {
    let id = UUID()
    let itemID: UUID?
    let context: DownloadContext

    var isFree: Bool { context.isFree }
}

/// 下载页一行。
struct DownloadRow: Identifiable, Equatable {
    let id: UUID
    let context: DownloadContext
    let status: DownloadItemStatus
    let progress: DownloadProgress?
    let lastLog: String?
    let output: URL
    /// 最近一次失败的原因（失败中，或从上次失败恢复为暂停时）；重试后清除。
    var lastFailure: IpatoolError? = nil
    /// 任务所属账号的地区名（多账号时显示；未知为 nil）。
    var regionTitle: String? = nil

    /// 来自公开目录（浏览地区）的任务：队列里总是显示地区标签。
    var isPublicCatalog: Bool { context.catalogCountry != nil }

    var fraction: Double? {
        if case .completed = status { return 1 }
        return progress?.fraction
    }

    var sizeText: String? {
        if case .completed(let result) = status, let size = Self.fileSize(result.fileURL) {
            return Format.bytes(size)
        }
        guard let progress, progress.bytes > 0 || progress.total != nil else { return nil }
        if let total = progress.total {
            return "\(Format.bytes(progress.bytes)) / \(Format.bytes(total))"
        }
        return Format.bytes(progress.bytes)
    }

    var percentText: String? {
        guard status == .running || status == .paused || status == .stopping || isFailed,
              let fraction = progress?.fraction else { return nil }
        return "\(Int((fraction * 100).rounded(.down)))%"
    }

    var speedText: String? {
        guard status == .running, let speed = progress?.bytesPerSecond, speed > 0 else { return nil }
        return Format.speed(speed)
    }

    var statusText: String {
        switch status {
        case .queued: return String(localized: "排队中")
        case .switchingAccount:
            if let region = regionTitle { return String(localized: "正在切换到 \(region) 账号…") }
            return String(localized: "正在切换账号…")
        case .running:
            if progress == nil { return lastLog.map(Self.describe(log:)) ?? String(localized: "正在开始…") }
            return String(localized: "正在下载")
        case .stopping: return String(localized: "正在停止…")
        case .paused:
            if let failure = lastFailure { return String(localized: "已暂停 · 上次失败：\(failure.message)") }
            return String(localized: "已暂停")
        case .verifying: return String(localized: "正在校验安装包")
        case .completed: return String(localized: "已完成")
        case .failed(let error): return String(localized: "失败：\(error.message)")
        }
    }

    var errorRaw: String? {
        if case .failed(let error) = status, !error.raw.isEmpty { return error.raw }
        if status == .paused, let raw = lastFailure?.raw, !raw.isEmpty { return raw }
        return nil
    }

    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    /// 「继续」按钮显示为「重试」：失败中，或从上次失败恢复的暂停任务。
    var isRetry: Bool { isFailed || (status == .paused && lastFailure != nil) }

    var fileURL: URL? {
        if case .completed(let result) = status { return result.fileURL }
        return nil
    }

    var canPause: Bool {
        status == .running || status == .queued || status == .verifying || status == .switchingAccount
    }
    var canResume: Bool {
        switch status {
        case .paused, .failed: return true
        default: return false
        }
    }
    var canCancel: Bool { !status.isFinished && status != .stopping }

    static func describe(log: String) -> String {
        let lower = log.lowercased()
        if lower.contains("unicorn") || lower.contains("kbsync") || lower.contains("preparing") {
            return String(localized: "正在准备下载组件…首次可能需要几分钟。")
        }
        return log
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

@MainActor
@Observable
final class DownloadsViewModel {
    private(set) var items: [DownloadQueueItem] = []
    private(set) var contexts: [UUID: DownloadContext] = [:]
    var licensePrompt: LicensePrompt?
    var enqueueError: ErrorPresentation?

    /// 下载完成时回调（写入记录）。
    @ObservationIgnored var onRecord: ((DownloadRecord) -> Void)?
    /// 账号 id → 写进下载记录的地区快照（`AccountRegion.rawValue`，「其他」为自填代码）；旧任务（无账号 id）返回当前账号的。
    @ObservationIgnored var regionLabel: ((UUID?) -> String?)?
    /// 账号 id → 界面显示的地区名；未设置时由 `regionLabel` 推出。
    @ObservationIgnored var regionTitle: ((UUID?) -> String?)?

    @ObservationIgnored private let queue: DownloadQueueing
    @ObservationIgnored private let store: DownloadQueueStore?
    @ObservationIgnored private let destination: @MainActor () throws -> URL
    @ObservationIgnored private let currentAccountID: @MainActor () -> UUID?
    /// 最近一次写入 `queue.json` 的内容（相同则不重写）。
    @ObservationIgnored private var lastPersisted: [PersistedDownload] = []
    @ObservationIgnored private var recorded: Set<UUID> = []
    @ObservationIgnored private var prompted: Set<UUID> = []
    @ObservationIgnored private var seen: Set<UUID> = []
    @ObservationIgnored private var outputs: [UUID: URL] = [:]
    @ObservationIgnored private var observeTask: Task<Void, Never>?

    /// - Parameters:
    ///   - store: 队列的跨启动保存；nil = 不保存。
    ///   - destination: 返回（并在需要时创建）下载目录。
    ///   - currentAccountID: 当前账号 id，入队时写进任务（任务属于另一个账号时，队列会先切换账号）。
    init(queue: DownloadQueueing, store: DownloadQueueStore? = nil, destination: @escaping @MainActor () throws -> URL,
         currentAccountID: @escaping @MainActor () -> UUID? = { nil }) {
        self.queue = queue
        self.store = store
        self.destination = destination
        self.currentAccountID = currentAccountID
    }

    var rows: [DownloadRow] {
        items.compactMap { item in
            guard let context = contexts[item.id] else { return nil }
            return DownloadRow(id: item.id, context: context, status: item.status, progress: item.progress,
                               lastLog: item.lastLog, output: item.request.output, lastFailure: item.lastFailure,
                               regionTitle: title(for: item.request.accountID, catalogCountry: context.catalogCountry))
        }
    }

    /// 任务的地区名：账号的地区；账号未知时，公开目录任务用所浏览的地区。
    private func title(for accountID: UUID?, catalogCountry: String?) -> String? {
        if let regionTitle, let title = regionTitle(accountID) { return title }
        if regionTitle == nil, let raw = regionLabel?(accountID) { return AccountRegion.title(forStored: raw) }
        return catalogCountry.map(AccountRegion.title(forCode:))
    }

    /// 未完成的任务：正在下载 / 校验 / 切换账号的排在前面（同时下载多个时聚在一起），其余保持队列顺序。
    var activeRows: [DownloadRow] {
        let unfinished = rows.filter { !$0.status.isFinished }
        return unfinished.filter(\.status.isActive) + unfinished.filter { !$0.status.isActive }
    }
    /// 正在下载 / 校验 / 切换账号的任务数。
    var runningCount: Int { items.filter(\.status.isActive).count }
    var completedRows: [DownloadRow] { rows.filter { $0.status.isFinished } }
    var activeCount: Int { activeRows.count }
    /// 是否有任务正在下载 / 校验 / 为下载切换账号（此时不允许手动切换账号）。
    var hasActiveDownload: Bool { items.contains { $0.status.isActive } }

    /// 恢复上次保存的队列（一律为「已暂停」），然后开始订阅队列快照（App 启动时调用一次）。
    func startObserving() {
        guard observeTask == nil else { return }
        let queue = self.queue
        let restored = store?.load() ?? []
        lastPersisted = restored
        for entry in restored {
            contexts[entry.id] = DownloadContext(persisted: entry)
            outputs[entry.id] = URL(fileURLWithPath: entry.outputPath)
        }
        let progresses = restored.map { $0.restoredProgress() }
        observeTask = Task { [weak self] in
            for (entry, progress) in zip(restored, progresses) {
                await queue.restore(entry.request, id: entry.id, progress: progress,
                                    lastFailure: entry.failure?.error, addedAt: entry.addedAt)
            }
            for await snapshot in await queue.updates() {
                self?.apply(snapshot)
            }
        }
    }

    func stopObserving() {
        observeTask?.cancel()
        observeTask = nil
    }

    /// 入队。目标文件：下载目录 + `<name>_<version>.ipa`（非法字符替换、同名加序号）。
    /// - Parameter accountID: 任务所属账号；nil = 当前账号（公开目录的任务可直接绑定到匹配地区的账号，由队列先切换）。
    @discardableResult
    func enqueue(_ context: DownloadContext, purchase: Bool = false, accountID: UUID? = nil) async -> UUID? {
        let directory: URL
        do {
            directory = try destination()
        } catch {
            enqueueError = ErrorPresentation(message: String(localized: "无法创建下载目录。"), raw: error.localizedDescription)
            return nil
        }
        let reserved = Set(outputs.values.map { $0.standardizedFileURL.path })
        let output = DownloadFileNamer.uniqueURL(in: directory, name: context.name, version: context.versionLabel,
                                                 reserved: reserved)
        let request = DownloadRequest(appID: context.appID, externalVersionID: context.externalVersionID,
                                      purchase: purchase, output: output, platform: context.platform.downloadPlatform,
                                      accountID: accountID ?? currentAccountID())
        let id = UUID()
        contexts[id] = context
        outputs[id] = output
        await queue.add(request, id: id)
        return id
    }

    func pause(_ id: UUID) { Task { await queue.pause(id) } }
    func resume(_ id: UUID) { Task { await queue.resume(id) } }
    func cancel(_ id: UUID) { Task { await queue.cancel(id) } }
    func remove(_ id: UUID) { Task { await queue.remove(id) } }
    func clearCompleted() { Task { await queue.removeCompleted() } }

    // MARK: - 许可

    /// 历史版本页遇到 `.licenseRequired` 时调用：弹出领取许可提示。
    func requestLicense(for context: DownloadContext) {
        licensePrompt = LicensePrompt(itemID: nil, context: context)
    }

    /// 用户确认领取免费许可：以 `purchase: true` 重新发起下载。
    func confirmLicense(_ prompt: LicensePrompt) async {
        licensePrompt = nil
        guard prompt.isFree else { return }
        if let itemID = prompt.itemID {
            await queue.remove(itemID)
            outputs[itemID] = nil
        }
        await enqueue(prompt.context, purchase: true)
    }

    func dismissLicense() {
        licensePrompt = nil
    }

    // MARK: - 跨启动保存

    /// 当前应保存的条目：排队中、进行中（含停止中 / 校验中）、已暂停、失败（连同失败原因，重启后恢复为暂停）。
    /// 完成的不保存；「需要许可」的失败走领取许可提示，不保存（保持原有处理）。
    func persistableEntries(_ snapshot: [DownloadQueueItem]) -> [PersistedDownload] {
        snapshot.compactMap { item in
            switch item.status {
            case .queued, .switchingAccount, .running, .stopping, .verifying, .paused: break
            case .failed(let error) where error.kind == .licenseRequired: return nil
            case .failed: break
            case .completed: return nil
            }
            guard let context = contexts[item.id] else { return nil }
            return PersistedDownload(
                id: item.id, appID: context.appID, name: context.name, bundleID: context.bundleID,
                versionLabel: context.versionLabel, externalVersionID: item.request.externalVersionID,
                purchase: item.request.purchase, outputPath: item.request.output.path,
                platform: item.request.platform, displayPlatform: context.platform.rawValue,
                isFree: context.isFree, totalBytes: item.progress?.total, addedAt: item.addedAt,
                failure: item.lastFailure.map(PersistedFailure.init), accountID: item.request.accountID,
                catalogCountry: context.catalogCountry)
        }
    }

    /// 内容有变化时原子写 `queue.json`（写入失败不打断界面，下次变化时再试）。
    private func persist(_ snapshot: [DownloadQueueItem]) {
        guard let store else { return }
        let entries = persistableEntries(snapshot)
        guard entries != lastPersisted else { return }
        do {
            try store.save(entries)
            lastPersisted = entries
        } catch {
            // 忽略：保持 lastPersisted 不变，下次快照变化时重试。
        }
    }

    /// App 退出时调用：按当前快照立即写盘。
    func persistNow() {
        persist(items)
    }

    // MARK: - 快照处理

    func apply(_ snapshot: [DownloadQueueItem]) {
        items = snapshot
        let ids = Set(snapshot.map(\.id))
        // 曾出现过、现在不在快照里 = 已取消 / 已移除
        for gone in seen.subtracting(ids) {
            contexts[gone] = nil
            outputs[gone] = nil
            seen.remove(gone)
        }
        seen.formUnion(ids)
        persist(snapshot)

        for item in snapshot {
            guard let context = contexts[item.id] else { continue }
            switch item.status {
            case .completed(let result):
                guard recorded.insert(item.id).inserted else { continue }
                let size = DownloadRow.fileSize(result.fileURL) ?? item.progress?.total ?? 0
                let record = DownloadRecord(
                    appID: context.appID,
                    name: context.name,
                    bundleID: context.bundleID.isEmpty ? result.info.bundleIdentifier : context.bundleID,
                    version: result.info.shortVersion ?? context.versionLabel,
                    externalVersionID: context.externalVersionID,
                    size: size,
                    path: result.fileURL.path,
                    accountID: item.request.accountID,
                    regionLabel: regionLabel?(item.request.accountID))
                onRecord?(record)
            case .failed(let error) where error.kind == .licenseRequired:
                guard prompted.insert(item.id).inserted else { continue }
                if licensePrompt == nil {
                    licensePrompt = LicensePrompt(itemID: item.id, context: context)
                }
            default:
                continue
            }
        }
    }
}
